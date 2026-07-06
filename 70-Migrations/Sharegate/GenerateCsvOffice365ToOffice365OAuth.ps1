<#
.SYNOPSIS
Generates CSV chunks with mailbox fields for Office 365 -> Office 365 migration mapping.

.NOTES
- Joins Source and Target users by DisplayName (case-insensitive).
- Outputs rows for Primary/Archive mapping depending on $migrations configuration.
- Writes multiple CSV files with $ItemsPerFile rows each.
#>

# =================== configuration of script ===============================

# type your source tenant principal name below, e.g. admin@source.onmicrosoft.com
$SourceUPN = 'breadervolue@hakom.at'

# type your target tenant principal name below, e.g. admin@target.onmicrosoft.com
$TargetUPN = 'adm-bartlomiej@volue.onmicrosoft.com'

$migrations = @()

# comment the four lines below for primary mailbox to archive mailbox migration (cross-migration)
$migrations += [PSCustomObject]@{
  Source = 'Primary'
  Target = 'Primary'
}

# comment the four lines below for archive mailbox to primary mailbox migration (cross-migration)
$migrations += [PSCustomObject]@{
  Source = 'Archive'
  Target = 'Archive'
}

# uncomment the four lines below for primary mailbox to archive mailbox migration (cross-migration)
#$migrations += [PSCustomObject]@{
#  Source = 'Primary'
#  Target = 'Archive'
#}

# uncomment the four lines below for archive mailbox to primary mailbox migration (cross-migration)
#$migrations += [PSCustomObject]@{
#  Source = 'Archive'
#  Target = 'Primary'
#}

$ItemsPerFile = 1000

# ===========================================================================

$ErrorActionPreference = 'Stop'

# TLS 1.2 (mostly relevant for Windows PowerShell 5.1)
try {
  [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
} catch {
  # Ignore on platforms where it doesn't apply
}

function Ensure-ExchangeOnlineModule {
  [CmdletBinding()]
  param(
    [Version]$MinimumVersion = [Version]'3.7.0'
  )

  $installed = Get-Module -ListAvailable -Name ExchangeOnlineManagement |
    Sort-Object Version -Descending |
    Select-Object -First 1

  if (-not $installed) {
    Write-Host "ExchangeOnlineManagement not found. Installing latest..." -ForegroundColor Yellow
    Install-Module -Name ExchangeOnlineManagement -Scope CurrentUser -Force -AllowClobber
  }
  elseif ($installed.Version -lt $MinimumVersion) {
    Write-Host "ExchangeOnlineManagement $($installed.Version) found, upgrading to meet minimum $MinimumVersion..." -ForegroundColor Yellow
    Install-Module -Name ExchangeOnlineManagement -Scope CurrentUser -Force -AllowClobber
  }

  Import-Module ExchangeOnlineManagement -Force
}

function Get-UserMailboxList {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)][string]$AdminUPN,
    [Parameter(Mandatory)][ValidateSet('Source','Target')][string]$Label
  )

  Write-Host "Connecting to $Label tenant as $AdminUPN ..." -ForegroundColor Cyan
  Connect-ExchangeOnline -UserPrincipalName $AdminUPN -ShowBanner:$false

  try {
    # Wrap in @() so "no results" becomes an empty array, not $null
    $users = @(
      Get-User -Filter 'RecipientType -eq "UserMailbox"' -ResultSize Unlimited |
        Select-Object UserPrincipalName, ExternalDirectoryObjectId, DisplayName
    )

    Write-Host "$Label tenant: $($users.Count) user mailbox objects returned." -ForegroundColor Green
    return $users
  }
  finally {
    Disconnect-ExchangeOnline -Confirm:$false | Out-Null
  }
}

Ensure-ExchangeOnlineModule

$SourceUsers = Get-UserMailboxList -AdminUPN $SourceUPN -Label Source
$TargetUsers = Get-UserMailboxList -AdminUPN $TargetUPN -Label Target

# Defensive: LINQ hates $null, so ensure not null even if something went sideways
if ($null -eq $SourceUsers) { $SourceUsers = @() }
if ($null -eq $TargetUsers) { $TargetUsers = @() }

# Keys used for GroupJoin (case-insensitive comparer is passed to GroupJoin)
[System.Func[System.Object, string]]$SourceKey = {
  param($Source)
  $Source.DisplayName
}

[System.Func[System.Object, string]]$TargetKey = {
  param($Target)
  $Target.DisplayName
}

# Projection per matched group
[System.Func[System.Object, [Collections.Generic.IEnumerable[System.Object]], System.Object]]$query = {
  param($Source, $TargetGroup)

  $TargetOrDefault = [System.Linq.Enumerable]::FirstOrDefault($TargetGroup)

  [PSCustomObject]@{
    SourceEmail = $Source.UserPrincipalName
    SourceId    = $Source.ExternalDirectoryObjectId
    DisplayName = $Source.DisplayName
    TargetEmail = $TargetOrDefault.UserPrincipalName
    TargetId    = $TargetOrDefault.ExternalDirectoryObjectId
  }
}

function Multiply-Migrations {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory, ValueFromPipeline)]
    [pscustomobject]$InputObject
  )
  process {
    foreach ($migration in $migrations) {
      [PSCustomObject]@{
        SourceEmail       = $InputObject.SourceEmail
        SourceId          = $InputObject.SourceId
        DisplayName       = $InputObject.DisplayName
        SourceMailboxType = $migration.Source
        TargetMailboxType = $migration.Target
        TargetEmail       = $InputObject.TargetEmail
        TargetId          = $InputObject.TargetId
      }
    }
  }
}

# GroupJoin Source->Target by DisplayName (case-insensitive)
$myTempArray = [System.Linq.Enumerable]::ToArray(
  [System.Linq.Enumerable]::GroupJoin(
    $SourceUsers,
    $TargetUsers,
    $SourceKey,
    $TargetKey,
    $query,
    [StringComparer]::OrdinalIgnoreCase
  )
)

$myOutputArray = $myTempArray | Multiply-Migrations

$PageSize = [int]$ItemsPerFile
$NumberOfPages = [int][Math]::Ceiling($myOutputArray.Count / $PageSize)

Write-Host "Total output rows: $($myOutputArray.Count). Files to write: $NumberOfPages (PageSize=$PageSize)" -ForegroundColor Cyan

# Split csv on chunks with $ItemsPerFile mailboxes per chunk
for ($i = 0; $i -lt $NumberOfPages; $i++) {
  $file = ".\MailboxesOffice365ToOffice365_$($i + 1).csv"
  $myOutputArray |
    Select-Object -Skip ($PageSize * $i) -First $PageSize |
    Export-Csv -Path $file -NoTypeInformation -Encoding utf8 -Delimiter ';'

  Write-Host "Wrote $file" -ForegroundColor Green
}