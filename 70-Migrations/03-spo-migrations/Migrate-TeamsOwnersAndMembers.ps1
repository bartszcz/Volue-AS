<#
.SYNOPSIS
    Migrates Microsoft Teams owners and members from hakom tenant to Volue tenant.

.DESCRIPTION
    Reads current owners/members from each source Team (hakom.sharepoint.com),
    maps their identities to new Volue UPNs using the mailbox migration CSV,
    then adds them as owners/members to the corresponding target Team (volue.sharepoint.com).

.PREREQUISITES
    Run once as Administrator before using this script:
        Install-Module MicrosoftTeams -Force -AllowClobber

.EXAMPLE
    # Dry run — connects for real and reads all data, but does NOT call Add-TeamUser
    .\Migrate-TeamsOwnersAndMembers.ps1 `
        -MailboxMappingCsv ".\MailboxesOffice365ToOffice365.csv" `
        -TeamsMigrationCsv ".\Hakom-TeamsMigrationList.csv" `
        -SourceTenantId "ba990d86-1367-4abd-979b-6f3154787ca9" `
        -TargetTenantId "9ce76d42-5ecb-4d8f-939b-a462ad28cf34" `
        -DryRun

    # Live run — actually adds owners and members
    .\Migrate-TeamsOwnersAndMembers.ps1 `
        -MailboxMappingCsv ".\MailboxesOffice365ToOffice365.csv" `
        -TeamsMigrationCsv ".\Hakom-TeamsMigrationList.csv" `
        -SourceTenantId "ba990d86-1367-4abd-979b-6f3154787ca9" `
        -TargetTenantId "9ce76d42-5ecb-4d8f-939b-a462ad28cf34"

.NOTES
    Author:  Generated for Hakom -> Volue M365 migration
    Date:    2026-03-18
#>

# Plain CmdletBinding — NO SupportsShouldProcess, so -WhatIf never cascades into Teams cmdlets
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$MailboxMappingCsv,

    [Parameter(Mandatory)]
    [string]$TeamsMigrationCsv,

    [Parameter(Mandatory)]
    [string]$SourceTenantId,

    [Parameter(Mandatory)]
    [string]$TargetTenantId,

    # Use -DryRun instead of -WhatIf to avoid cascading into Teams module cmdlets
    [switch]$DryRun,

    [string]$LogFile = ".\TeamsOwnerMemberMigration_$(Get-Date -Format 'yyyyMMdd_HHmmss').log"
)

#region ---- Logging -------------------------------------------------------
function Write-Log {
    param([string]$Message, [ValidateSet('INFO','WARN','ERROR','SUCCESS')]$Level = 'INFO')
    $ts   = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $line = "[$ts][$Level] $Message"
    $color = switch ($Level) {
        'SUCCESS' { 'Green'  }
        'WARN'    { 'Yellow' }
        'ERROR'   { 'Red'    }
        default   { 'White'  }
    }
    Write-Host $line -ForegroundColor $color
    Add-Content -Path $LogFile -Value $line
}
#endregion

#region ---- Main ----------------------------------------------------------
Write-Log "=== Hakom -> Volue Teams Owner/Member Migration ===" INFO
if ($DryRun) { Write-Log "*** DRY RUN MODE — no changes will be made ***" WARN }
Write-Log "Log file: $LogFile" INFO

# ---- Check MicrosoftTeams module -----------------------------------------
if (-not (Get-Module -ListAvailable -Name MicrosoftTeams)) {
    Write-Log "ERROR: MicrosoftTeams module is not installed." ERROR
    Write-Log "Run this in an elevated (Admin) PowerShell, then re-run the script:" ERROR
    Write-Log "    Install-Module MicrosoftTeams -Force -AllowClobber" ERROR
    exit 1
}
Import-Module MicrosoftTeams -ErrorAction Stop
Write-Log "MicrosoftTeams module loaded OK." INFO

# ---- Load CSVs -----------------------------------------------------------
Write-Log "Loading mailbox mapping CSV: $MailboxMappingCsv" INFO
$mailboxMap = Import-Csv -Path $MailboxMappingCsv -Delimiter ';'

# Primary lookup: full source email -> target email  (e.g. Stefan.Komornyik@hakom.at)
$userMap = @{}
foreach ($row in $mailboxMap) {
    $userMap[$row.SourceEmail.ToLower()] = $row.TargetEmail
}

# Secondary lookup: first-name alias -> target email  (e.g. stefan@hakom.at)
# Built automatically from the CSV - first name is the part before the dot.
# Ambiguous aliases (multiple people share a first name) are resolved via manual overrides below.
$domain = ($mailboxMap[0].SourceEmail -split '@')[1]
$firstNameMap = @{}
foreach ($row in $mailboxMap) {
    $local = ($row.SourceEmail -split '@')[0]
    if ($local -notmatch '\.') { continue }           # skip shared mailboxes without a dot
    $firstName = $local.Split('.')[0].ToLower()
    $alias     = "$firstName@$domain"
    if ($firstNameMap.ContainsKey($alias)) {
        $firstNameMap[$alias] = $null                   # mark ambiguous
    } else {
        $firstNameMap[$alias] = $row.TargetEmail
    }
}

# Manual overrides - stefan@hakom.at is ambiguous (Komornyik vs Schuttengruber), confirmed: Komornyik
$firstNameMap['stefan@hakom.at'] = 'stefan.komornyik@volue.com'

# Merge aliases into primary map (only where full-email match doesn't already exist)
foreach ($alias in $firstNameMap.Keys) {
    if (-not $userMap.ContainsKey($alias) -and $firstNameMap[$alias]) {
        $userMap[$alias] = $firstNameMap[$alias]
    }
}

Write-Log "Loaded $($userMap.Count) user mappings (including first-name aliases)." INFO

Write-Log "Loading Teams migration CSV: $TeamsMigrationCsv" INFO
$teamsList = Import-Csv -Path $TeamsMigrationCsv
Write-Log "Loaded $($teamsList.Count) Teams." INFO

# ---- Connect to SOURCE tenant (hakom) ------------------------------------
Write-Log "Connecting to SOURCE tenant ($SourceTenantId) — a browser login window will open..." INFO
try {
    Connect-MicrosoftTeams -TenantId $SourceTenantId -ErrorAction Stop | Out-Null
    Write-Log "Connected to source tenant." SUCCESS
} catch {
    Write-Log "ERROR: Failed to connect to source tenant: $_" ERROR
    exit 1
}

$membershipData = @()

foreach ($team in $teamsList) {
    $srcSiteUrl = $team.'Site address'.TrimEnd('/')
    $srcTitle   = $team.Title
    $tgtSiteUrl = $team.'New Site URL Volue'.TrimEnd('/')
    $tgtName    = $team.'New Site Name Volue'

    Write-Log "Reading source team: '$srcTitle'" INFO

    try {
        $sourceTeam = Get-Team -DisplayName $srcTitle -ErrorAction Stop
        if (-not $sourceTeam) { throw "Not found by exact name" }
    } catch {
        $sourceTeam = Get-Team | Where-Object { $_.DisplayName -like "*$srcTitle*" }
    }

    if (-not $sourceTeam) {
        Write-Log "  SKIP: Could not find source Team '$srcTitle'" WARN
        continue
    }

    if ($sourceTeam -is [array]) { $sourceTeam = $sourceTeam[0] }

    $groupId = $sourceTeam.GroupId
    Write-Log "  GroupId: $groupId" INFO

    try {
        $owners = Get-TeamUser -GroupId $groupId -Role Owner -ErrorAction Stop
    } catch {
        Write-Log "  WARN: Could not read owners: $_" WARN
        $owners = @()
    }

    try {
        $members = Get-TeamUser -GroupId $groupId -Role Member -ErrorAction Stop
    } catch {
        Write-Log "  WARN: Could not read members: $_" WARN
        $members = @()
    }

    Write-Log "  Found $($owners.Count) owner(s) and $($members.Count) member(s)." INFO

    $membershipData += [PSCustomObject]@{
        SourceTitle   = $srcTitle
        SourceSiteUrl = $srcSiteUrl
        TargetSiteUrl = $tgtSiteUrl
        TargetName    = $tgtName
        Owners        = $owners
        Members       = $members
    }
}

Write-Log "Disconnecting from source tenant..." INFO
Disconnect-MicrosoftTeams

# ---- Connect to TARGET tenant (volue) ------------------------------------
Write-Log "Connecting to TARGET tenant ($TargetTenantId) — a browser login window will open..." INFO
try {
    Connect-MicrosoftTeams -TenantId $TargetTenantId -ErrorAction Stop | Out-Null
    Write-Log "Connected to target tenant." SUCCESS
} catch {
    Write-Log "ERROR: Failed to connect to target tenant: $_" ERROR
    exit 1
}

$successCount = 0
$skipCount    = 0
$errorCount   = 0

foreach ($entry in $membershipData) {
    $tgtName = $entry.TargetName
    Write-Log "--- Target team: '$tgtName'" INFO

    try {
        $targetTeam = Get-Team -DisplayName $tgtName -ErrorAction Stop
        if (-not $targetTeam) { throw "Not found by exact name" }
    } catch {
        $targetTeam = Get-Team | Where-Object { $_.DisplayName -like "*$tgtName*" }
    }

    if (-not $targetTeam) {
        Write-Log "  ERROR: Target team '$tgtName' not found. Skipping." ERROR
        $errorCount++
        continue
    }

    if ($targetTeam -is [array]) { $targetTeam = $targetTeam[0] }

    $tgtGroupId = $targetTeam.GroupId
    Write-Log "  GroupId: $tgtGroupId" INFO

    # --- Owners -----------------------------------------------------------
    foreach ($owner in $entry.Owners) {
        $srcEmail = $owner.User.ToLower()
        $tgtEmail = $userMap[$srcEmail]

        if (-not $tgtEmail) {
            Write-Log "  SKIP owner '$srcEmail' — not in mailbox mapping." WARN
            $skipCount++
            continue
        }

        if ($DryRun) {
            Write-Log "  [DRY-RUN][OWNER] Would add: $tgtEmail" INFO
            $successCount++
        } else {
            try {
                Add-TeamUser -GroupId $tgtGroupId -User $tgtEmail -Role Owner -ErrorAction Stop
                Write-Log "  [OWNER] Added: $tgtEmail" SUCCESS
                $successCount++
            } catch {
                if ($_ -match 'already exists' -or $_ -match 'already a member') {
                    Write-Log "  [OWNER] Already present: $tgtEmail" INFO
                } else {
                    Write-Log "  [OWNER] ERROR adding $tgtEmail : $_" ERROR
                    $errorCount++
                }
            }
        }
    }

    # --- Members ----------------------------------------------------------
    foreach ($member in $entry.Members) {
        $srcEmail = $member.User.ToLower()
        $tgtEmail = $userMap[$srcEmail]

        if (-not $tgtEmail) {
            Write-Log "  SKIP member '$srcEmail' — not in mailbox mapping." WARN
            $skipCount++
            continue
        }

        if ($DryRun) {
            Write-Log "  [DRY-RUN][MEMBER] Would add: $tgtEmail" INFO
            $successCount++
        } else {
            try {
                Add-TeamUser -GroupId $tgtGroupId -User $tgtEmail -Role Member -ErrorAction Stop
                Write-Log "  [MEMBER] Added: $tgtEmail" SUCCESS
                $successCount++
            } catch {
                if ($_ -match 'already exists' -or $_ -match 'already a member') {
                    Write-Log "  [MEMBER] Already present: $tgtEmail" INFO
                } else {
                    Write-Log "  [MEMBER] ERROR adding $tgtEmail : $_" ERROR
                    $errorCount++
                }
            }
        }
    }
}

Disconnect-MicrosoftTeams

# ---- Summary -------------------------------------------------------------
Write-Log "=== Migration Complete ===" INFO
if ($DryRun) { Write-Log "*** DRY RUN — no changes were made ***" WARN }
Write-Log "  $(if ($DryRun) {'Would add'} else {'Successfully added'}): $successCount" SUCCESS
Write-Log "  Skipped (no mapping) : $skipCount" WARN
Write-Log "  Errors               : $errorCount" $(if ($errorCount -gt 0) {'ERROR'} else {'INFO'})
Write-Log "Full log saved to: $LogFile" INFO
#endregion