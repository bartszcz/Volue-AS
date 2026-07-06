<#
.SYNOPSIS
    Migrates SharePoint site owners and members from hakom tenant to Volue tenant.

.DESCRIPTION
    Reads current owners/members from each source SharePoint site (hakom.sharepoint.com),
    maps their identities to new Volue UPNs using the mailbox migration CSV,
    then adds them as owners/members to the corresponding target site (volue.sharepoint.com).

    Connects ONCE per tenant (two browser logins total) using -Interactive,
    then reconnects to each individual site silently using the cached credentials.

    SharePoint permission model covered:
      - Owners group  (Full Control) — always migrated
      - Members group (Edit)         — always migrated
      - Visitors group (Read)        — opt-in via -IncludeVisitors
      - Site Collection Admins       — opt-in via -IncludeSiteAdmins

.PREREQUISITES
    Run once as Administrator before using this script:
        Install-Module PnP.PowerShell -Force -AllowClobber

.EXAMPLE
    # Dry run
    .\Migrate-SharePointOwnersAndMembers.ps1 `
        -MailboxMappingCsv "C:\Users\bartlomiej.szczesny\OneDrive - Volue AS\Documents\Scripts\70-Migrations\sharepoint-migrations\MailboxesOffice365ToOffice365.csv" `
        -SiteMigrationCsv  "C:\Users\bartlomiej.szczesny\OneDrive - Volue AS\Documents\Scripts\70-Migrations\sharepoint-migrations\Hakom-SiteMigration.csv" `
        -SourceAdminUrl    "https://hakom-admin.sharepoint.com" `
        -TargetAdminUrl    "https://volue-admin.sharepoint.com" `
        -DryRun

    # Live run
    .\Migrate-SharePointOwnersAndMembers.ps1 `
        -MailboxMappingCsv "C:\Users\bartlomiej.szczesny\OneDrive - Volue AS\Documents\Scripts\70-Migrations\sharepoint-migrations\MailboxesOffice365ToOffice365.csv" `
        -SiteMigrationCsv  "C:\Users\bartlomiej.szczesny\OneDrive - Volue AS\Documents\Scripts\70-Migrations\sharepoint-migrations\Hakom-SiteMigration.csv" `
        -SourceAdminUrl    "https://hakom-admin.sharepoint.com" `
        -TargetAdminUrl    "https://volue-admin.sharepoint.com"

.NOTES
    Author:  Generated for Hakom -> Volue M365 migration
    Date:    2026-03-18

    CSV formats:
      MailboxMappingCsv : comma-delimited — SourceEmail, SourceId, DisplayName,
                          SourceMailboxType, TargetMailboxType, TargetEmail, TargetId
      SiteMigrationCsv  : comma-delimited — Title, Site address,
                          New Site Name Volue, New Site URL Volue
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$MailboxMappingCsv,

    [Parameter(Mandatory)]
    [string]$SiteMigrationCsv,

    [Parameter(Mandatory)]
    [string]$SourceAdminUrl,        # https://hakom-admin.sharepoint.com

    [Parameter(Mandatory)]
    [string]$TargetAdminUrl,        # https://volue-admin.sharepoint.com

    [switch]$IncludeVisitors,
    [switch]$IncludeSiteAdmins,
    [switch]$DryRun,

    [string]$LogFile = ".\SharePointOwnerMemberMigration_$(Get-Date -Format 'yyyyMMdd_HHmmss').log"
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

#region ---- Helpers -------------------------------------------------------

function Resolve-TargetEmail {
    param([string]$LoginName, [hashtable]$UserMap)
    if ($LoginName -match '\|(.+)$') { $LoginName = $Matches[1] }
    $email = $LoginName.ToLower().Trim()
    if ($email -match 'sharepoint$|app@sharepoint|spocrawler|everyone|nt authority|sharepoint\\|spo-|healthmailbox') {
        return $null
    }
    return $UserMap[$email]
}

function Add-SpGroupMember {
    param([string]$GroupNamePattern, [string]$TargetEmail, [switch]$DryRun, [string]$RoleLabel)
    try {
        $group = Get-PnPGroup -ErrorAction Stop | Where-Object { $_.Title -like "*$GroupNamePattern*" } | Select-Object -First 1
        if (-not $group) {
            Write-Log "    WARN: No group matching '*$GroupNamePattern*' found." WARN
            return $false
        }
        if ($DryRun) {
            Write-Log "    [DRY-RUN][$RoleLabel] Would add $TargetEmail to '$($group.Title)'" INFO
            return $true
        }
        Add-PnPGroupMember -LoginName $TargetEmail -Group $group -ErrorAction Stop
        Write-Log "    [$RoleLabel] Added $TargetEmail to '$($group.Title)'" SUCCESS
        return $true
    } catch {
        if ($_ -match 'already|exists') {
            Write-Log "    [$RoleLabel] Already present: $TargetEmail" INFO
            return $true
        }
        Write-Log "    [$RoleLabel] ERROR adding $TargetEmail : $_" ERROR
        return $false
    }
}

function Invoke-GroupMigration {
    param([array]$SourceMembers, [string]$GroupPattern, [string]$RoleLabel,
          [hashtable]$UserMap, [switch]$DryRun)
    foreach ($principal in $SourceMembers) {
        $loginName = if ($principal.LoginName) { $principal.LoginName }
                     elseif ($principal.Email)  { $principal.Email }
                     else                        { $principal.UserPrincipalName }
        $tgtEmail = Resolve-TargetEmail -LoginName $loginName -UserMap $UserMap
        if (-not $tgtEmail) {
            Write-Log "  SKIP $RoleLabel '$loginName' — not in mapping or system account." WARN
            $script:skipCount++
            continue
        }
        $ok = Add-SpGroupMember -GroupNamePattern $GroupPattern -TargetEmail $tgtEmail `
                                -RoleLabel $RoleLabel -DryRun:$DryRun
        if ($ok) { $script:successCount++ } else { $script:errorCount++ }
    }
}

#endregion

#region ---- Main ----------------------------------------------------------
Write-Log "=== Hakom -> Volue SharePoint Owner/Member Migration ===" INFO
if ($DryRun) { Write-Log "*** DRY RUN MODE — no changes will be made ***" WARN }
Write-Log "Log file: $LogFile" INFO

# ---- Check PnP.PowerShell module -----------------------------------------
$pnpModule = Get-Module -ListAvailable -Name 'PnP.PowerShell' |
             Sort-Object Version -Descending | Select-Object -First 1
if (-not $pnpModule) {
    $pnpModule = Get-Module -ListAvailable -Name 'SharePointPnPPowerShellOnline' |
                 Sort-Object Version -Descending | Select-Object -First 1
}
if (-not $pnpModule) {
    Write-Log "ERROR: PnP.PowerShell module is not installed." ERROR
    Write-Log "Run: Install-Module PnP.PowerShell -Force -AllowClobber" ERROR
    exit 1
}
Import-Module $pnpModule.Name -ErrorAction Stop
Write-Log "PnP module '$($pnpModule.Name)' v$($pnpModule.Version) loaded OK." INFO

# ---- Load CSVs -----------------------------------------------------------
Write-Log "Loading mailbox mapping CSV: $MailboxMappingCsv" INFO
$mailboxMap = Import-Csv -Path $MailboxMappingCsv -Delimiter ','

$userMap = @{}
foreach ($row in $mailboxMap) { $userMap[$row.SourceEmail.ToLower()] = $row.TargetEmail }

# First-name alias map (e.g. stefan@hakom.at)
$domain = ($mailboxMap[0].SourceEmail -split '@')[1]
$firstNameMap = @{}
foreach ($row in $mailboxMap) {
    $local = ($row.SourceEmail -split '@')[0]
    if ($local -notmatch '\.') { continue }
    $firstName = $local.Split('.')[0].ToLower()
    $alias = "$firstName@$domain"
    if ($firstNameMap.ContainsKey($alias)) { $firstNameMap[$alias] = $null }
    else { $firstNameMap[$alias] = $row.TargetEmail }
}
$firstNameMap['stefan@hakom.at'] = 'stefan.komornyik@volue.com'   # confirmed override
foreach ($alias in $firstNameMap.Keys) {
    if (-not $userMap.ContainsKey($alias) -and $firstNameMap[$alias]) {
        $userMap[$alias] = $firstNameMap[$alias]
    }
}
Write-Log "Loaded $($userMap.Count) user mappings (including first-name aliases)." INFO

Write-Log "Loading site migration CSV: $SiteMigrationCsv" INFO
$sitesList = Import-Csv -Path $SiteMigrationCsv -Delimiter ','
Write-Log "Loaded $($sitesList.Count) sites." INFO

# ---- Connect to SOURCE tenant — ONE login for all source sites -----------
Write-Log "Connecting to SOURCE tenant ($SourceAdminUrl) — browser login will open..." INFO
try {
    Connect-PnPOnline -Url $SourceAdminUrl -Interactive -ClientId "31359c7f-bd7e-475c-86db-fdb8c937548e" -ErrorAction Stop
    Write-Log "Connected to source tenant." SUCCESS
} catch {
    Write-Log "ERROR: Failed to connect to source tenant: $_" ERROR
    exit 1
}
# Note: TenantId is inferred from the URL in PnP.PowerShell v3+

$siteData = @()

foreach ($site in $sitesList) {
    $srcUrl   = $site.'Site address'.TrimEnd('/')
    $srcTitle = $site.Title
    $tgtUrl   = $site.'New Site URL Volue'.TrimEnd('/')
    $tgtName  = $site.'New Site Name Volue'

    Write-Log "Reading source site: '$srcTitle' ($srcUrl)" INFO

    try {
        # Re-use the existing auth cookie — no new browser popup
        Connect-PnPOnline -Url $srcUrl -Interactive -ClientId "31359c7f-bd7e-475c-86db-fdb8c937548e" -ErrorAction Stop
        # Note: TenantId inferred from URL in PnP v3+
    } catch {
        Write-Log "  ERROR: Cannot connect to '$srcUrl': $_" ERROR
        continue
    }

    $groups = @{ Owners = @(); Members = @(); Visitors = @() }
    foreach ($pattern in @('Owners', 'Members', 'Visitors')) {
        try {
            $grp = Get-PnPGroup -ErrorAction Stop | Where-Object { $_.Title -like "*$pattern*" } | Select-Object -First 1
            if ($grp) {
                $grpMembers       = Get-PnPGroupMember -Group $grp -ErrorAction Stop
                $groups[$pattern] = $grpMembers
                Write-Log "  Found $($grpMembers.Count) $pattern." INFO
            } else {
                Write-Log "  WARN: No '$pattern' group found." WARN
            }
        } catch {
            Write-Log "  WARN: Could not read $pattern group: $_" WARN
        }
    }

    $admins = @()
    if ($IncludeSiteAdmins) {
        try {
            $admins = Get-PnPSiteCollectionAdmin -ErrorAction Stop
            Write-Log "  Found $($admins.Count) Site Collection Admin(s)." INFO
        } catch {
            Write-Log "  WARN: Could not read Site Collection Admins: $_" WARN
        }
    }

    $siteData += [PSCustomObject]@{
        SourceTitle = $srcTitle
        SourceUrl   = $srcUrl
        TargetUrl   = $tgtUrl
        TargetName  = $tgtName
        Owners      = $groups.Owners
        Members     = $groups.Members
        Visitors    = $groups.Visitors
        SiteAdmins  = $admins
    }
}

Write-Log "Disconnecting from source tenant..." INFO
Disconnect-PnPOnline

# ---- Connect to TARGET tenant — ONE login for all target sites -----------
Write-Log "Connecting to TARGET tenant ($TargetAdminUrl) — browser login will open..." INFO
try {
    Connect-PnPOnline -Url $TargetAdminUrl -Interactive -ClientId "31359c7f-bd7e-475c-86db-fdb8c937548e" -ErrorAction Stop
    Write-Log "Connected to target tenant." SUCCESS
} catch {
    Write-Log "ERROR: Failed to connect to target tenant: $_" ERROR
    exit 1
}

$successCount = 0
$skipCount    = 0
$errorCount   = 0
$removeCount  = 0

foreach ($entry in $siteData) {
    $tgtUrl  = $entry.TargetUrl
    $tgtName = $entry.TargetName
    Write-Log "--- Target site: '$tgtName' ($tgtUrl)" INFO

    try {
        Connect-PnPOnline -Url $tgtUrl -Interactive -ClientId "31359c7f-bd7e-475c-86db-fdb8c937548e" -ErrorAction Stop
        # Note: TenantId inferred from URL in PnP v3+
    } catch {
        Write-Log "  ERROR: Cannot connect to '$tgtUrl': $_" ERROR
        $errorCount++
        continue
    }

    Invoke-GroupMigration -SourceMembers $entry.Owners  -GroupPattern 'Owners'  -RoleLabel 'OWNER'  -UserMap $userMap -DryRun:$DryRun
    Invoke-GroupMigration -SourceMembers $entry.Members -GroupPattern 'Members' -RoleLabel 'MEMBER' -UserMap $userMap -DryRun:$DryRun

    if ($IncludeVisitors) {
        Invoke-GroupMigration -SourceMembers $entry.Visitors -GroupPattern 'Visitors' -RoleLabel 'VISITOR' -UserMap $userMap -DryRun:$DryRun
    }

    if ($IncludeSiteAdmins -and $entry.SiteAdmins.Count -gt 0) {
        foreach ($admin in $entry.SiteAdmins) {
            $loginName = if ($admin.LoginName) { $admin.LoginName }
                         elseif ($admin.Email) { $admin.Email }
                         else                   { $admin.UserPrincipalName }
            $tgtEmail = Resolve-TargetEmail -LoginName $loginName -UserMap $userMap
            if (-not $tgtEmail) {
                Write-Log "  SKIP SCA '$loginName' — not in mapping or system account." WARN
                $skipCount++
                continue
            }
            if ($DryRun) {
                Write-Log "  [DRY-RUN][SCA] Would set Site Collection Admin: $tgtEmail" INFO
                $successCount++
            } else {
                try {
                    Set-PnPSiteCollectionAdmin -Owners $tgtEmail -ErrorAction Stop
                    Write-Log "  [SCA] Set Site Collection Admin: $tgtEmail" SUCCESS
                    $successCount++
                } catch {
                    if ($_ -match 'already') { Write-Log "  [SCA] Already admin: $tgtEmail" INFO }
                    else { Write-Log "  [SCA] ERROR setting $tgtEmail : $_" ERROR; $errorCount++ }
                }
            }
        }
    }

    # --- Remove hakom.at accounts from all groups on this target site -----
    Write-Log "  Checking for hakom.at accounts to remove..." INFO
    try { $allGroups = Get-PnPGroup -ErrorAction Stop } catch {
        Write-Log "  WARN: Could not enumerate groups for cleanup: $_" WARN
        $allGroups = @()
    }

    foreach ($grp in $allGroups) {
        try { $grpMembers = Get-PnPGroupMember -Group $grp -ErrorAction Stop } catch { continue }
        $hakoms = $grpMembers | Where-Object {
            ($_.LoginName -like '*@hakom.at*') -or ($_.Email -like '*@hakom.at*')
        }
        foreach ($hakom in $hakoms) {
            $hakomLogin = if ($hakom.Email) { $hakom.Email } else { $hakom.LoginName }
            if ($DryRun) {
                Write-Log "  [DRY-RUN][REMOVE] Would remove '$hakomLogin' from '$($grp.Title)'" WARN
                $removeCount++
            } else {
                try {
                    Remove-PnPGroupMember -LoginName $hakomLogin -Group $grp -ErrorAction Stop
                    Write-Log "  [REMOVE] Removed '$hakomLogin' from '$($grp.Title)'" SUCCESS
                    $removeCount++
                } catch {
                    Write-Log "  [REMOVE] ERROR removing '$hakomLogin': $_" ERROR
                    $errorCount++
                }
            }
        }
    }
}

Disconnect-PnPOnline

# ---- Summary -------------------------------------------------------------
Write-Log "=== Migration Complete ===" INFO
if ($DryRun) { Write-Log "*** DRY RUN — no changes were made ***" WARN }
Write-Log "  $(if ($DryRun) {'Would add'} else {'Successfully added'})    : $successCount" SUCCESS
Write-Log "  $(if ($DryRun) {'Would remove'} else {'Successfully removed'}) : $removeCount" SUCCESS
Write-Log "  Skipped (no mapping)    : $skipCount" WARN
Write-Log "  Errors                  : $errorCount" $(if ($errorCount -gt 0) {'ERROR'} else {'INFO'})
Write-Log "Full log saved to: $LogFile" INFO
#endregion