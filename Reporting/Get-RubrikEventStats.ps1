#requires -modules Rubrik

# https://build.rubrik.com
# https://www.rubrik.com/blog/get-started-rubrik-powershell-module/
# https://github.com/rubrikinc/rubrik-sdk-for-powershell
# https://github.com/rubrikinc/rubrik-scripts-for-powershell

<#
.SYNOPSIS
Outputs CSV with stats from the event activity logs like scan and fetch durations.
.DESCRIPTION
The Get-EventStats cmdlet is used to pull stats not found in any reports like scan and fetch durations
You can specificy to pull stats for a particular host or a set of fileset IDs
The stats are output to a CSV file
.NOTES
Written by Steven Tong for community usage
GitHub: stevenctong

This requires a stored Credential file 'rubrik_cred.xml'. To create one:
Get-Credential | Export-CliXml -Path ./rubrik_cred.xml
.EXAMPLE
Get-RubrikEventStats -Server 'rubrikhost' -Filesets 'Fileset:::e4ae9fa1-1088-4039-86dd-ce5e4f912204,Fileset:::6eb1cd6a-7ea9-4c0a-a784-e489ad058bff'
This will connect to Rubrik host 'rubrikhost' and get events for the two comma separated Fileset IDs
.EXAMPLE
Get-RubrikEventStats -Server 'rubrikhost' -Hosts 'epic'
This will connect to Rubrik host 'rubrikhost' and get events for any host that contains 'epic' in the name
#>

param (
  [CmdletBinding()]

  # Rubrik cluster hostname or IP address
  [Parameter(Mandatory=$true)]
  [string]$server,

  # Either provide one or more Fileset IDs (comma separated) or host list
  [Parameter(Mandatory=$false)]
  [string]$filesets,

  # Eitehr provide one or more hosts (comma separated) or fileset IDs
  # Hosts are searched with partial matches
  [Parameter(Mandatory=$false)]
  [string]$hosts,

  # CSV filename to output file to
  [Parameter(Mandatory=$false)]
  [string]$outputCSV = 'event_statistics.csv'
)

if (![String]::IsNullOrWhiteSpace($filesets) -and ![String]::IsNullOrWhiteSpace($hosts)) {
  Write-Host "ERROR: No fileset IDs or hosts provided"
  Write-Host "Use '-Filesets <comma_separated_fileset_ids>' and/or '-Hosts <comma_separated_hosts>'"

  exit
}

Import-Module Rubrik

# Create a Rubrik credential file by using the following:
# Get-Credential | Export-CliXml -Path ./rubrik_cred.xml
# The created credential file can only be used by the person that created it

# Import Credential file
$credential  = Import-Clixml -Path rubrik_cred.xml

# Get today's date
$startTimeDate = Get-Date -UFormat %Y-%m-%d

# Number of events to grab
$eventLimit = 5
$eventType = "Backup"

# Helper function to convert logged duration to minute format
# Duration shows up in activity log as e.g. "3 days 2 hours 30 minutes 53 seconds" or
# "3 days 2 hrs 30 min 53 secs"
function ConvertToMinutes {
  param ($duration)

  [float]$days = $duration | Select-String -Pattern '\d+(?= day)' | % {$_.Matches.Groups[0].Value}
  [float]$hours = $duration | Select-String -Pattern '\d+(?= hour)' | % {$_.Matches.Groups[0].Value}
  [float]$minutes = $duration | Select-String -Pattern '\d+(?= min)' | % {$_.Matches.Groups[0].Value}
  [float]$seconds = $duration | Select-String -Pattern '\d+(?= sec)' | % {$_.Matches.Groups[0].Value}

  $minutes += ($days * 24 * 60)
  $minutes += ($hours * 60)
  $minutes += ($seconds / 60)

  return $minutes
}

# Helper function to convert logged duration to HH:MM:SS format
# Duration shows up in activity log as e.g. "3 days 2 hours 30 minutes 53 seconds" or
# "3 days 2 hrs 30 min 53 secs"
function ConvertToHHMMSS {
  param ($duration)

  [int]$days = $duration | Select-String -Pattern '\d+(?= day)' | % {$_.Matches.Groups[0].Value}
  [int]$hours = $duration | Select-String -Pattern '\d+(?= hour)' | % {$_.Matches.Groups[0].Value}
  [int]$minutes = $duration | Select-String -Pattern '\d+(?= min)' | % {$_.Matches.Groups[0].Value}
  [int]$seconds = $duration | Select-String -Pattern '\d+(?= sec)' | % {$_.Matches.Groups[0].Value}

  $hours += ($days * 24)

  if ($hours -lt 100) {
    [string]$hours = "{0:D2}" -f $hours
  }
  [string]$minutes = "{0:D2}" -f $minutes
  [string]$seconds = "{0:D2}" -f $seconds

  return "$hours`:$minutes`:$seconds"
}

# Helper function to calculate scan time (total duration minus total fetch duration)
# Duration shows up in activity log as e.g. "3 days 2 hours 30 minutes 53 seconds" or
# "3 days 2 hrs 30 min 53 secs"
function CalculateScanDuration {
  param ($totalDuration, $fetchDuration)

  [int]$totalDays = $totalDuration | Select-String -Pattern '\d+(?= day)' | % {$_.Matches.Groups[0].Value}
  [int]$totalHours = $totalDuration | Select-String -Pattern '\d+(?= hour)' | % {$_.Matches.Groups[0].Value}
  [int]$totalMinutes = $totalDuration | Select-String -Pattern '\d+(?= min)' | % {$_.Matches.Groups[0].Value}
  [int]$totalSeconds = $totalDuration | Select-String -Pattern '\d+(?= sec)' | % {$_.Matches.Groups[0].Value}

  [int]$fetchDays = $fetchDuration | Select-String -Pattern '\d+(?= day)' | % {$_.Matches.Groups[0].Value}
  [int]$fetchHours = $fetchDuration | Select-String -Pattern '\d+(?= hour)' | % {$_.Matches.Groups[0].Value}
  [int]$fetchMinutes = $fetchDuration | Select-String -Pattern '\d+(?= min)' | % {$_.Matches.Groups[0].Value}
  [int]$fetchSeconds = $fetchDuration | Select-String -Pattern '\d+(?= sec)' | % {$_.Matches.Groups[0].Value}

  $totalHours += ($totalDays * 24)
  $fetchHours += ($fetchDays * 24)

  $scanSeconds = $totalSeconds - $fetchSeconds
  $scanMinutes = $totalMinutes - $fetchMinutes
  $scanHours = $totalHours - $fetchHours

  if ($scanSeconds -lt 0) {
    $scanSeconds += 60
    $scanMinutes -= 1
  }

  if ($scanMinutes -lt 0) {
    $scanMinutes += 60
    $scanHours -= 1
  }

  if ($scanHours -lt 100) {
    [string]$scanHours = "{0:D2}" -f $scanHours
  }
  [string]$scanMinutes = "{0:D2}" -f $scanMinutes
  [string]$scanSeconds = "{0:D2}" -f $scanSeconds

  return "$scanHours`:$scanMinutes`:$scanSeconds"
}

# Helper function to change bytes to largest human readable size - base-10
function ConvertBytesToSize {
  param ([float]$bytes)

  switch ($bytes) {
    # If > 1 PB
    {$bytes -gt 1000000000000000} {
      $newSize =  "$([math]::Round(($bytes / 1000000000000000),2)) PB"
      Break
    }
    # If > 1 TB
    {$bytes -gt 1000000000000} {
      $newSize =  "$([math]::Round(($bytes / 1000000000000),2)) TB"
      Break
    }
    # If > 1 GB
    {$bytes -gt 1000000000} {
      $newSize =  "$([math]::Round(($bytes / 1000000000),2)) GB"
      Break
    }
    # If > 1 MB
    {$bytes -gt 1000000} {
      $newSize =  "$([math]::Round(($bytes / 1000000),2)) MB"
      Break
    }
    # If > 1 KB
    {$bytes -gt 1000} {
      $newSize =  "$([math]::Round(($bytes / 1000),2)) KB"
      Break
    }
    # Otherwise leave it as fundamental unit of Bytes
    Default {
      $newSize = "$bytes B"
    }
  }
  return $newSize
}

# Connect to Rubrik cluster
Connect-Rubrik -Server $server -Credential $credential

# Figure out cluster version (major version)
$rubrikVersion = [float]$global:RubrikConnection.version.substring(0, 3)

# Rubrik PowerShell SDK 'Get-RubrikEvent' needs to be updated
# This will figure out to use the correct endpoint for now
if ($rubrikVersion -like "5.2") {
  $apiVersion = 1
} else {
  $apiVersion = "internal"
}

# Initialize array to store fileset ID list
$filesetsArray = @()

# If Fileset IDs were provided in param, add to array
$filesetsArray = $filesets.split(",")

# If Hosts were provided in param, loop through and add Fileset IDs to array
if (![String]::IsNullOrWhiteSpace($hosts)) {
  foreach ($i in $hosts) {
    $rubrikFilesetInfo = Get-RubrikFileset -HostNameFilter $i | Select-Object 'id'
    $filesetsArray += $rubrikFilesetInfo.id
  }
}

# Get rid of empty and non-unique fileset IDs
$filesetsArray = $filesetsArray | Select -unique | Where-Object {$_}

# Split out fileset IDs to comma separated string to use in URI
$filesets = $filesetsArray -join ','

# Get last events on cluster for the Fileset IDs
$eventList = Invoke-RubrikRESTCall -Method Get -Api $apiVersion -Endpoint "event/latest?limit=$eventLimit&event_type=$eventType&object_ids=$filesets" -Verbose

# Initialize array that will hold each backup's detail statistics
$eventArray = @()

# Loop through the event list and pull the event details for each event
foreach ($i in $eventList.data.latestEvent) {
  $eventDetail = Invoke-RubrikRESTCall -Method Get -Api $apiVersion -Endpoint "event_series/$($i.eventSeriesid)" -verbose

  # We only care about events that are successful
  if ($eventDetail.Status -eq "Success") {

    # $eventDetail is an array that has each step of the activity
    # We are only interested in the item that contains the stats
    foreach ($j in $eventDetail.eventDetailList) {
      if ($j.eventName -eq "Fileset.FilesetDataFetchFinished") {

        $params = $j.eventInfo | ConvertFrom-Json | Select-Object 'params'

        $fetchDurationHHMMSS = ConvertToHHMMSS $params.params.'${fetchDuration}'
        $copyDurationHHMMSS = ConvertToHHMMSS $params.params.'${copyDuration}'
        $verificationDurationHHMMSS = ConvertToHHMMSS $params.params.'${verificationDuration}'

        $fetchDurationMin = ConvertToMinutes $params.params.'${fetchDuration}'
        $copyDurationMin = ConvertToMinutes $params.params.'${copyDuration}'
        $verificationDurationMin = ConvertToMinutes $params.params.'${verificationDuration}'

        $totalFetchTime = $params.params.'${duration}'
        $totalFetchTimeMin = ConvertToMinutes $params.params.'${duration}'
      }
    }

    $totalDurationMin = ConvertToMinutes $eventDetail.duration
    $totalDurationHHMMSS = ConvertToHHMMSS $eventDetail.duration

    $scanDurationMin = $totalDurationMin - $totalFetchTimeMin
    $scanDurationHHMMSS = CalculateScanDuration $eventDetail.duration $totalFetchTime

    $newEvent = New-Object PSObject

    $newEvent | Add-Member -MemberType NoteProperty -Name "Name" -Value $eventDetail.objectName
    $newEvent | Add-Member -MemberType NoteProperty -Name "Location" -Value $eventDetail.location
    $newEvent | Add-Member -MemberType NoteProperty -Name "StartTime" -Value $eventDetail.startTime
    $newEvent | Add-Member -MemberType NoteProperty -Name "EndTime" -Value $eventDetail.endTime
    $newEvent | Add-Member -MemberType NoteProperty -Name "Status" -Value $eventDetail.status
    $newEvent | Add-Member -MemberType NoteProperty -Name "ObjectId" -Value $eventDetail.objectId

    $newEvent | Add-Member -MemberType NoteProperty -Name "LogicalSize" -Value (ConvertBytesToSize $eventDetail.logicalSize)
    $newEvent | Add-Member -MemberType NoteProperty -Name "DataTransferred" -Value (ConvertBytesToSize $eventDetail.dataTransferred)
    $newEvent | Add-Member -MemberType NoteProperty -Name "TransferRate" -Value (ConvertBytesToSize $eventDetail.throughput)
    $newEvent | Add-Member -MemberType NoteProperty -Name "LogicalSizeBytes" -Value $eventDetail.logicalSize
    $newEvent | Add-Member -MemberType NoteProperty -Name "DataTransferredBytes" -Value $eventDetail.dataTransferred
    $newEvent | Add-Member -MemberType NoteProperty -Name "TransferRateBytes" -Value $eventDetail.throughput

    $newEvent | Add-Member -MemberType NoteProperty -Name "TotalDurationHHMMSS" -Value $totalDurationHHMMSS
    $newEvent | Add-Member -MemberType NoteProperty -Name "ScanDurationHHMMSS" -Value $scanDurationHHMMSS
    $newEvent | Add-Member -MemberType NoteProperty -Name "FetchDurationHHMMSS" -Value $fetchDurationHHMMSS
    $newEvent | Add-Member -MemberType NoteProperty -Name "CopyDurationHHMMSS" -Value $copyDurationHHMMSS
    $newEvent | Add-Member -MemberType NoteProperty -Name "VerificationDurationHHMMSS" -Value $verificationDurationHHMMSS

    $newEvent | Add-Member -MemberType NoteProperty -Name "TotalDurationMin" -Value ([math]::Round($totalDurationMin,3))
    $newEvent | Add-Member -MemberType NoteProperty -Name "ScanDurationMin" -Value ([math]::Round($scanDurationMin,3))
    $newEvent | Add-Member -MemberType NoteProperty -Name "FetchDurationMin" -Value ([math]::Round($fetchDurationMin,3))
    $newEvent | Add-Member -MemberType NoteProperty -Name "CopyDurationMin" -Value ([math]::Round($copyDurationMin,3))
    $newEvent | Add-Member -MemberType NoteProperty -Name "VerificationDurationMin" -Value ([math]::Round($verificationDurationMin,3))

    $eventArray += $newEvent
  }
}

Disconnect-Rubrik -Confirm:$false

# Export data to CSV file
$eventArray | Export-Csv -NoTypeInformation -Path $outputCSV
