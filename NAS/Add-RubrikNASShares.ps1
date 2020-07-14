#requires -modules Rubrik

# https://build.rubrik.com
# https://www.rubrik.com/blog/get-started-rubrik-powershell-module/
# https://github.com/rubrikinc/rubrik-sdk-for-powershell
# https://github.com/rubrikinc/rubrik-scripts-for-powershell

<#
.SYNOPSIS
Reads a .CSV file and adds the NAS shares to the Rubrik cluster. Assumes the NAS Host has already been added to the cluster.
.DESCRIPTION
The Add-RubrikNASShares cmdlet reads in a .CSV file containing a list of NAS shares and adds them to the Rubrik cluster.
This script assumes that the NAS Host has already been added to the Rubrik cluster.
You can use the same CSV file with the 'Set-RubrikNASSLAs' script to add a new fileset + SLA to the NAS shares.

.NOTES
Written by Steven Tong for community usage
GitHub: stevenctong
Date: 7/13/20

You can use a Rubrik credential file for authentication
Default $rubrikCred = './rubrik_cred.xml'
To create a new credential file: Get-Credential | Export-CliXml -Path ./rubrik_cred.xml

You must create a CSV file with the following columns:
- Mandatory columns: hostname, exportPoint, shareType
** hostname - NAS Host that contains the share
** exportPoint - sharename
** shareType - 'SMB' or 'NFS'

- Optional columns: domain, username, password
** If a username (and domain) is provided the script will set the credential at the share level
** If no password is provided for the username (and domain) the script will prompt for a password

See 'rubriknasshares.csv' as an example

.EXAMPLE
Add-RubrikNASShares.ps1
This will prompt for all variables

.EXAMPLE
Add-RubrikNASShares.ps1 -server <rubrik_host> -csvfile <csv_filename>
Reads in CSV file and adds each share to a host and then assigns a Fileset + SLA to the share

#>

param (
  [CmdletBinding()]

  # Rubrik cluster hostname or IP address
  [Parameter(Mandatory=$true, HelpMessage="Rubrik cluster hostname or IP address")]
  [string]$server,

  # Rubrik credential file location
  [Parameter(Mandatory=$false, HelpMessage="Rubrik credential file location")]
  [string]$rubrikCred = "rubrik_cred.xml",

  # Rubrik username if not using credential file
  [Parameter(Mandatory=$false, HelpMessage="Rubrik cluster username")]
  [string]$user = $null,

  # Rubrik password if not using credential file
  [Parameter(Mandatory=$false, HelpMessage="Rubrik cluster password")]
  [string]$password = $null,

  # VM name to restore
  [Parameter(Mandatory=$true, HelpMessage="CSV File containing the following: hostname, exportPoint, shareType; optional: domain, username, password")]
  [string]$csvfile
)

Import-Module Rubrik

# If user is provided then use the username and password
if ($user) {
  if ($password) {
    $password = ConvertTo-SecureString $password -AsPlainText -Force

    Connect-Rubrik -Server $server -Username $user -Password $password
  }
  # If username provided but no password, prompt for password
  else {
    $credential = Get-Credential -Username $user

    Connect-Rubrik -Server $server -Credential $credential
  }
}
# Else if credential file is found then use it
elseif (Test-Path $rubrikCred) {
  # Import Credential file
  $credential  = Import-Clixml -Path $rubrikCred

  Connect-Rubrik -Server $server -Credential $credential
}
# Else if no username or credential file is provided then prompt for credentials
else {
  Write-Host ""
  Write-Host "No username or credential file found ($rubrikCred), please provide Rubrik credentials"

  $credential = Get-Credential
  Connect-Rubrik -Server $server -Credential $credential
}

Write-Host ""

# List to keep track of which shares were added successfully or not
$addList = @()

# Get info from Rubrik cluster
$rubrikLocalId = Get-RubrikClusterInfo | Select-Object -ExpandProperty Id
$rubrikHosts = Get-RubrikHost -PrimaryClusterID $rubrikLocalId
$rubrikShares = Get-RubrikNASShare -PrimaryClusterID $rubrikLocalId

# Import CSV file which contains shares to add
$shareList = Import-Csv $csvfile

# Build list of unique domain\users
$shareCredList = $shareList | Sort-Object -Property 'domain', 'username' -Unique |
Select-Object 'domain', 'username', 'password'

# List of credentials to use
$credList = @()

# Loop through unique domain\users to prompt for password or encrypt password to use later
foreach ($i in $shareCredList) {
  # If no password is in CSV, prompt for and store password into $credList
  if ($i.username -ne '' -and $i.password -eq '') {
    Write-Host "Please supply password for domain: '$($i.domain)', user: '$($i.username)'"
    if ($i.domain -eq '') {
      $cred = Get-Credential -Username $i.username
    }
    else {
      $cred = Get-Credential -Username "$($i.domain)\$($i.username)"
    }

    $credList += [PSCustomObject] @{
      domain = $i.domain
      username = $i.username
      password = $cred.password
    }
  }
  # If password is provided in CSV encrypt it and store into $credList
  elseif ($i.username -ne '') {
    $credList += [PSCustomObject] @{
      domain = $i.domain
      username = $i.username
      password = ConvertTo-SecureString $i.password -AsPlainText -Force
    }
  }
}

# Iterate through share list
foreach ($i in $shareList) {

  # Get the Host ID of associated share
  $hostID = $rubrikHosts | Where-Object "Name" -eq $i.hostname | Select-Object -ExpandProperty "ID"

  # Skip if NAS Host does not exist - script assumes Host pre-exists
  if ($hostID -eq $null) {
    Write-Warning "Error adding share: '$($i.exportPoint)' - host not found: '$($i.hostname)'"

    $addList += [PSCustomObject] @{
      hostname = $i.hostname
      exportPoint = $i.exportPoint
      shareType = $i.shareType
      status = 'NotAdded'
    }
  }
  # If NAS Host exists - continue
  else {
    # See if share already exists on cluster
    $shareID = $rubrikShares | Where-Object {$_.hostname -eq $i.hostname -and $_.exportPoint -eq $i.exportPoint -and $_.shareType -eq $i.ShareType} | Select-Object -ExpandProperty 'id'

    # If share doesn't exist, try adding the share to the cluster
    if ($shareID -eq $null) {

      $req = $null
      try {
        # If a username and password is specified for the share then use it
        if ($i.username -ne '') {
          if ($i.domain -eq '') {
            $shareUser = $i.username
          }
          else {
            $shareUser = $i.domain + '\' + $i.username
          }

          # New-RubrikNASShare uses credential as $PSCredential
          # Looks up the domain\user and password to use in $credList to use
          $userCred = $credList | Where-Object {$_.domain -eq $i.domain -and $_.username -eq $i.username}
          $shareCred = New-Object System.Management.Automation.PSCredential($shareUser, $userCred.password)

          # Add NAS share to Rubrik with share credential
          $req = New-RubrikNASShare -HostID $hostID -ShareType $i.shareType -ExportPoint $i.exportPoint -Credential $shareCred
        }
        else {
          # Add NAS share without share credential
          $req = New-RubrikNASShare -HostID $hostID -ShareType $i.shareType -ExportPoint $i.exportPoint
        }
        Write-Host "Added share: '$($i.exportPoint)' on host: '$($i.hostname)'" -ForegroundColor Green

        $addList += [PSCustomObject] @{
          hostname = $i.hostname
          exportPoint = $i.exportPoint
          shareType = $i.shareType
          status = 'Added'
        }
      }
      catch {
        Write-Warning "Error adding share: '$($i.exportPoint)' on host: '$($i.hostname)'"
        Write-Warning $Error[0]

        $addList = [PSCustomObject] @{
          hostname = $i.hostname
          exportPoint = $i.exportPoint
          shareType = $i.shareType
          status = 'NotAdded'
        }
      }
    }
    # If share exists, skip adding share
    else {
      Write-Warning "Skipping adding share: '$($i.exportPoint)' on host: '$($i.hostname)' - share already exists"

      $addList += [PSCustomObject] @{
        hostname = $i.hostname
        exportPoint = $i.exportPoint
        shareType = $i.shareType
        status = 'PreExisting'
      }
    }
  } # else to try adding share
} # foreach

  Write-Host ""
  Write-Host "# shares added: " $($addList | Where-Object Status -eq "Added" | Measure-Object | Select-Object -ExpandProperty Count)
  Write-Host "# shares not added: " $($addList | Where-Object Status -eq "NotAdded" | Measure-Object | Select-Object -ExpandProperty Count)
  Write-Host "# shares pre-existing: " $($addList | Where-Object Status -eq "PreExisting" | Measure-Object | Select-Object -ExpandProperty Count)

  $curDateTime = Get-Date -Format "yyyy-MM-dd_HHmm"
  $addList | Export-Csv -NoTypeInformation -Path "./shares_added_$($curDateTime).csv"

  Write-Host "`nResults output to: ./shares_added_$($curDateTime).csv"

  $disconnect = Disconnect-Rubrik -Confirm:$false
