<#
.SYNOPSIS
    Migrates SharePoint site permissions from source (optimeering) to target (volue) tenant.
    Optionally resolves M365 Group membership via Exchange Online for Teams-connected sites.

.DESCRIPTION
    Reads sites-mapping.csv and all-mx-mapping.csv. For each source site, collects direct
    members of Owners, Members, and Visitors SharePoint groups plus Site Collection Admins,
    normalises them to plain email strings, translates via all-mx-mapping.csv, then adds
    them to the matching groups on the target site.

    When -ResolveM365Groups is specified, also queries Exchange Online
    (Get-UnifiedGroupLinks) for the M365 Group linked to each Teams-connected source site.
    The M365 Group owners are merged into the OwnerEmails list; non-owner members are merged
    into the MemberEmails list. This captures the real people behind the group claims that
    the SharePoint group shows only as a GUID.

    Target groups are located via AssociatedOwnerGroup / AssociatedMemberGroup /
    AssociatedVisitorGroup (authoritative SP web properties, not name-pattern search).

    Source auth  : certificate-based via pnp-auth.json.
    Target auth  : certificate-based via pnp-auth-target.json (auto-registered if missing).
    EXO auth     : device code via -SourceAdminUpn (only when -ResolveM365Groups).

.PARAMETER SitesCsv
    Path to sites-mapping.csv.
    Columns: Title, "Site address", "New Site Name Volue", "New Site URL Volue", Status.
    Rows where Status != OK are skipped.

.PARAMETER MappingCsv
    Path to all-mx-mapping.csv (SourceEmail, TargetEmail).
    Defaults to C:\Optimeering\all-mx-mapping.csv.

.PARAMETER PnpAuthJson
    Path to pnp-auth.json (ClientId + Thumbprint) for source tenant.
    Defaults to C:\Optimeering\pnp-auth.json.

.PARAMETER TargetPnpAuthJson
    Path to JSON file for target tenant. Auto-created on first run if missing.
    Defaults to C:\Optimeering\pnp-auth-target.json.

.PARAMETER SourceAdminUrl
    SharePoint admin URL for source tenant.
    Defaults to https://optimeering-admin.sharepoint.com.

.PARAMETER TargetAdminUrl
    SharePoint admin URL for target tenant.
    Defaults to https://volue-admin.sharepoint.com.

.PARAMETER ResolveM365Groups
    Also resolve M365 Group owners/members via Exchange Online for Teams-connected sites
    and merge them into the migration lists. Requires -SourceAdminUpn.

.PARAMETER SourceAdminUpn
    UPN used for Exchange Online device-code auth when -ResolveM365Groups is set.
    E.g. bartlomiej.szczesny@optimeering.com

.PARAMETER IncludeVisitors
    Also migrate Visitors (Read) group.

.PARAMETER IncludeSiteAdmins
    Also migrate Site Collection Admins.

.PARAMETER DryRun
    Resolves all source permissions but makes no changes on the target.

.EXAMPLE
    # Dry run — resolve M365 groups
    .\Migrate-SharePointPermissions.ps1 -ResolveM365Groups `
        -SourceAdminUpn bartlomiej.szczesny@optimeering.com -DryRun

    # Live run — full migration
    .\Migrate-SharePointPermissions.ps1 -ResolveM365Groups `
        -SourceAdminUpn bartlomiej.szczesny@optimeering.com -IncludeVisitors

.NOTES
    Required modules:
      PnP.PowerShell           — Install-Module PnP.PowerShell -Scope CurrentUser
      ExchangeOnlineManagement — Install-Module ExchangeOnlineManagement -Scope CurrentUser
                                 (only needed when -ResolveM365Groups is used)
#>

[CmdletBinding()]
param(
    [string]$SitesCsv          = "C:\Optimeering\sites-mapping.csv",
    [string]$MappingCsv        = "C:\Optimeering\all-mx-mapping.csv",
    [string]$PnpAuthJson       = "C:\Optimeering\pnp-auth.json",
    [string]$TargetPnpAuthJson = "C:\Optimeering\pnp-auth-target.json",
    [string]$SourceAdminUrl    = "https://optimeering-admin.sharepoint.com",
    [string]$TargetAdminUrl    = "https://volue-admin.sharepoint.com",
    [switch]$ResolveM365Groups,
    [string]$SourceAdminUpn    = "",
    [switch]$IncludeVisitors,
    [switch]$IncludeSiteAdmins,
    [switch]$DryRun,
    [string]$LogFile = ".\SharePointPermMigration_$(Get-Date -Format 'yyyyMMdd_HHmmss').log"
)

if ($ResolveM365Groups -and -not $SourceAdminUpn) {
    Write-Error "-SourceAdminUpn is required when -ResolveM365Groups is specified."
    exit 1
}

#region ── Logging ─────────────────────────────────────────────────────────────
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

#region ── Helpers ─────────────────────────────────────────────────────────────
function Resolve-Email {
    param([string]$LoginName)
    if ($LoginName -match '\|([^|]+)$') { $LoginName = $Matches[1] }
    return $LoginName.Trim().ToLower()
}

function Is-SystemAccount {
    param([string]$Email)
    if ($Email -match '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}(_o)?$') { return $true }
    return $Email -match 'sharepoint$|app@sharepoint|spo-|spocrawler|everyone|nt authority|sharepoint\\|healthmailbox|#ext#|urn:spo|federateddirectoryclaimprovider'
}

# Converts raw SP principal objects to a clean array of email strings
function ConvertTo-EmailArray {
    param([object[]]$Principals)
    $result = [System.Collections.Generic.List[string]]::new()
    foreach ($p in $Principals) {
        $login = if ($p.LoginName) { $p.LoginName }
                 elseif ($p.Email) { $p.Email }
                 else              { $p.UserPrincipalName }
        if (-not $login) { continue }
        $email = Resolve-Email $login
        if ($email -match '@' -and -not (Is-SystemAccount $email)) {
            $result.Add($email)
        }
    }
    return ,$result.ToArray()
}
#endregion

#region ── Module check ────────────────────────────────────────────────────────
$pnpModule = Get-Module -ListAvailable -Name 'PnP.PowerShell' |
             Sort-Object Version -Descending | Select-Object -First 1
if (-not $pnpModule) {
    Write-Log "ERROR: PnP.PowerShell module is not installed." ERROR
    Write-Log "Run: Install-Module PnP.PowerShell -Scope CurrentUser" ERROR
    exit 1
}
Import-Module $pnpModule.Name -ErrorAction Stop

if ($ResolveM365Groups) {
    $exoModule = Get-Module -ListAvailable -Name 'ExchangeOnlineManagement' |
                 Sort-Object Version -Descending | Select-Object -First 1
    if (-not $exoModule) {
        Write-Log "ERROR: ExchangeOnlineManagement module is not installed." ERROR
        Write-Log "Run: Install-Module ExchangeOnlineManagement -Scope CurrentUser" ERROR
        exit 1
    }
    Import-Module $exoModule.Name -ErrorAction Stop
    Write-Log "ExchangeOnlineManagement module loaded." INFO
}
#endregion

Write-Log "=== Migrate-SharePointPermissions ===" INFO
if ($DryRun)            { Write-Log "*** DRY RUN MODE — no changes will be made ***" WARN }
if ($ResolveM365Groups) { Write-Log "M365 group resolution: ENABLED" INFO }
Write-Log "Log: $LogFile" INFO

#region ── Load CSVs ───────────────────────────────────────────────────────────
foreach ($f in @($SitesCsv, $MappingCsv, $PnpAuthJson)) {
    if (-not (Test-Path $f)) { Write-Log "ERROR: File not found: $f" ERROR; exit 1 }
}

$sites = Import-Csv -Path $SitesCsv |
    Where-Object { $_.Status -eq 'OK' -and $_.'Site address' -and $_.'New Site URL Volue' }
Write-Log "Loaded $($sites.Count) site(s) with Status=OK from $SitesCsv" INFO

$mappingRows = Import-Csv -Path $MappingCsv |
    Where-Object { $_.SourceEmail -and $_.SourceEmail.Trim() -ne '' }
$userMap = @{}
foreach ($row in $mappingRows) { $userMap[$row.SourceEmail.Trim().ToLower()] = $row.TargetEmail.Trim() }
Write-Log "Loaded $($userMap.Count) user mappings from $MappingCsv" INFO

$pnpCfg          = Get-Content $PnpAuthJson -Raw | ConvertFrom-Json
$srcClientId     = $pnpCfg.ClientId
$srcThumbprint   = $pnpCfg.Thumbprint
$srcTenantDomain = ($SourceAdminUrl -replace 'https://', '' -replace '-admin\.sharepoint\.com.*', '') + '.onmicrosoft.com'
$tgtTenantDomain = ($TargetAdminUrl -replace 'https://', '' -replace '-admin\.sharepoint\.com.*', '') + '.onmicrosoft.com'
#endregion

#region ── TARGET AUTH: load or register ───────────────────────────────────────
$tgtClientId   = $null
$tgtThumbprint = $null
$tgtAppName    = "PnP-SPO-Migration"

if (Test-Path $TargetPnpAuthJson) {
    $tgtCfg = Get-Content $TargetPnpAuthJson -Raw | ConvertFrom-Json
    if ($tgtCfg.ClientId -and $tgtCfg.Thumbprint) {
        $tgtClientId   = $tgtCfg.ClientId
        $tgtThumbprint = $tgtCfg.Thumbprint
        Write-Log "Target app registration loaded from $TargetPnpAuthJson" INFO
    }
}

if (-not $tgtClientId) {
    Write-Log "" INFO
    Write-Log "No target app registration found. Registering '$tgtAppName' on $tgtTenantDomain..." WARN
    Write-Log "A code will appear below — open https://microsoft.com/devicelogin, enter it," WARN
    Write-Log "and sign in as SharePoint/Global Admin on the TARGET tenant ($tgtTenantDomain)." WARN

    $tgtCertOutPath = Split-Path $TargetPnpAuthJson
    $reg = Register-PnPEntraIDApp `
        -ApplicationName $tgtAppName `
        -Tenant $tgtTenantDomain `
        -DeviceLogin `
        -SharePointApplicationPermissions "Sites.FullControl.All" `
        -Store CurrentUser `
        -OutPath $tgtCertOutPath `
        -ErrorAction Stop

    $tgtClientId = ($reg.PSObject.Properties | Where-Object { $_.Name -match 'ClientId' }).Value |
        Select-Object -First 1
    if (-not $tgtClientId) { throw "Could not extract ClientId from target app registration." }

    $tgtCert = Get-ChildItem Cert:\CurrentUser\My |
        Where-Object { $_.Subject -like "*$tgtAppName*" } |
        Sort-Object NotBefore -Descending | Select-Object -First 1
    if (-not $tgtCert) { throw "Certificate for '$tgtAppName' not found after registration." }
    $tgtThumbprint = $tgtCert.Thumbprint

    @{ ClientId = $tgtClientId; Thumbprint = $tgtThumbprint } |
        ConvertTo-Json | Set-Content $TargetPnpAuthJson -Encoding UTF8
    Write-Log "Target app registered. Config saved to: $TargetPnpAuthJson" SUCCESS

    $consentUrl = "https://login.microsoftonline.com/$tgtTenantDomain/adminconsent?client_id=$tgtClientId"
    Write-Log "Admin consent required. Opening browser — sign in as admin and click Accept." WARN
    Start-Process $consentUrl
    Read-Host "Press Enter once you have accepted consent in the browser"
}
#endregion

#region ── SOURCE: collect permissions ─────────────────────────────────────────
Write-Log "" INFO
Write-Log "Connecting to SOURCE admin ($SourceAdminUrl)..." WARN
try {
    Connect-PnPOnline -Url $SourceAdminUrl -ClientId $srcClientId -Thumbprint $srcThumbprint `
        -Tenant $srcTenantDomain -ErrorAction Stop
    Write-Log "Connected to source tenant." SUCCESS
} catch {
    Write-Log "ERROR: Failed to connect to source tenant: $_" ERROR
    exit 1
}

$siteData = [System.Collections.Generic.List[PSCustomObject]]::new()

foreach ($site in $sites) {
    $srcUrl   = $site.'Site address'.TrimEnd('/')
    $tgtUrl   = $site.'New Site URL Volue'.TrimEnd('/')
    $srcTitle = $site.Title

    Write-Log "" INFO
    Write-Log "Reading source site: $srcTitle" INFO
    Write-Log "  $srcUrl" INFO

    try {
        Connect-PnPOnline -Url $srcUrl -ClientId $srcClientId -Thumbprint $srcThumbprint `
            -Tenant $srcTenantDomain -ErrorAction Stop
    } catch {
        Write-Log "  ERROR: Cannot connect to source site: $_" ERROR
        continue
    }

    # Capture M365 Group ID — empty GUID for non-Teams-connected sites
    $groupId = [Guid]::Empty
    try {
        $spSite = Get-PnPSite -Includes GroupId -ErrorAction Stop
        if ($spSite.GroupId -and $spSite.GroupId -ne [Guid]::Empty) {
            $groupId = $spSite.GroupId
            Write-Log "  M365 GroupId: $groupId" INFO
        }
    } catch {
        Write-Log "  WARN: Could not read GroupId: $_" WARN
    }

    $ownerEmails   = @()
    $memberEmails  = @()
    $visitorEmails = @()
    $adminEmails   = @()

    foreach ($role in @('Owners','Members','Visitors')) {
        try {
            $grp = Get-PnPGroup -ErrorAction Stop |
                   Where-Object { $_.Title -like "*$role*" } |
                   Select-Object -First 1
            if ($grp) {
                $raw    = Get-PnPGroupMember -Group $grp -ErrorAction Stop
                $emails = ConvertTo-EmailArray $raw
                Write-Log "  $role : $($raw.Count) raw → $($emails.Count) resolved" INFO
                switch ($role) {
                    'Owners'   { $ownerEmails   = $emails }
                    'Members'  { $memberEmails  = $emails }
                    'Visitors' { $visitorEmails = $emails }
                }
            } else {
                Write-Log "  WARN: No '$role' group on this site." WARN
            }
        } catch {
            Write-Log "  WARN: Could not read $role group: $_" WARN
        }
    }

    if ($IncludeSiteAdmins) {
        try {
            $rawAdmins   = Get-PnPSiteCollectionAdmin -ErrorAction Stop
            $adminEmails = ConvertTo-EmailArray $rawAdmins
            Write-Log "  Site Collection Admins: $($rawAdmins.Count) raw → $($adminEmails.Count) resolved" INFO
        } catch {
            Write-Log "  WARN: Could not read Site Collection Admins: $_" WARN
        }
    }

    $siteData.Add([PSCustomObject]@{
        SourceTitle    = $srcTitle
        SourceUrl      = $srcUrl
        TargetUrl      = $tgtUrl
        GroupId        = $groupId
        OwnerEmails    = $ownerEmails
        MemberEmails   = $memberEmails
        VisitorEmails  = $visitorEmails
        AdminEmails    = $adminEmails
    })
}

Write-Log "" INFO
Write-Log "Disconnecting from source tenant..." INFO
Disconnect-PnPOnline
#endregion

#region ── M365 GROUP RESOLUTION (Exchange Online) ──────────────────────────────
if ($ResolveM365Groups) {
    Write-Log "" INFO
    Write-Log "=== Phase: Resolving M365 Group membership via Exchange Online ===" INFO
    Write-Log "Connecting as $SourceAdminUpn (device code — check your browser)..." WARN

    $exoConnected = $false
    try {
        Connect-ExchangeOnline -UserPrincipalName $SourceAdminUpn -Device -ShowProgress $false `
            -ErrorAction Stop
        $exoConnected = $true
        Write-Log "Connected to Exchange Online." SUCCESS
    } catch {
        Write-Log "ERROR: Failed to connect to Exchange Online: $_" ERROR
        Write-Log "Skipping M365 Group resolution — SP-only data will be used." WARN
    }

    if ($exoConnected) {
        foreach ($entry in $siteData) {
            if ($entry.GroupId -eq [Guid]::Empty) {
                Write-Log "  '$($entry.SourceTitle)' — not Teams-connected, skipping EXO lookup." INFO
                continue
            }

            $gidStr = $entry.GroupId.ToString()
            Write-Log "" INFO
            Write-Log "  Resolving M365 Group $gidStr — '$($entry.SourceTitle)'..." INFO

            # M365 Group owners → merge into OwnerEmails
            try {
                $exoOwners = Get-UnifiedGroupLinks -Identity $gidStr -LinkType Owners `
                             -ResultSize Unlimited -ErrorAction Stop
                $exoOwnerEmails = @(
                    $exoOwners |
                    Where-Object { $_.PrimarySmtpAddress } |
                    ForEach-Object { $_.PrimarySmtpAddress.Trim().ToLower() } |
                    Where-Object { -not (Is-SystemAccount $_) }
                )
                Write-Log "  EXO Owners: $($exoOwnerEmails.Count)" INFO

                $ownerSet = [System.Collections.Generic.HashSet[string]]::new(
                    [System.StringComparer]::OrdinalIgnoreCase)
                foreach ($e in $entry.OwnerEmails)  { [void]$ownerSet.Add($e) }
                foreach ($e in $exoOwnerEmails)      { [void]$ownerSet.Add($e) }
                $entry.OwnerEmails = $ownerSet.ToArray()
            } catch {
                Write-Log "  WARN: Could not read EXO Owners for $gidStr : $_" WARN
            }

            # M365 Group members (excluding owners) → merge into MemberEmails
            try {
                $exoMembers = Get-UnifiedGroupLinks -Identity $gidStr -LinkType Members `
                              -ResultSize Unlimited -ErrorAction Stop
                $currentOwnerSet = [System.Collections.Generic.HashSet[string]]::new(
                    $entry.OwnerEmails, [System.StringComparer]::OrdinalIgnoreCase)

                $exoMemberEmails = @(
                    $exoMembers |
                    Where-Object { $_.PrimarySmtpAddress } |
                    ForEach-Object { $_.PrimarySmtpAddress.Trim().ToLower() } |
                    Where-Object { -not (Is-SystemAccount $_) } |
                    Where-Object { -not $currentOwnerSet.Contains($_) }
                )
                Write-Log "  EXO Members (excl. owners): $($exoMemberEmails.Count)" INFO

                $memberSet = [System.Collections.Generic.HashSet[string]]::new(
                    [System.StringComparer]::OrdinalIgnoreCase)
                foreach ($e in $entry.MemberEmails)  { [void]$memberSet.Add($e) }
                foreach ($e in $exoMemberEmails)      { [void]$memberSet.Add($e) }
                $entry.MemberEmails = $memberSet.ToArray()
            } catch {
                Write-Log "  WARN: Could not read EXO Members for $gidStr : $_" WARN
            }

            Write-Log "  After merge — Owners: $($entry.OwnerEmails.Count)  Members: $($entry.MemberEmails.Count)" INFO
        }

        Write-Log "" INFO
        Write-Log "Disconnecting from Exchange Online..." INFO
        Disconnect-ExchangeOnline -Confirm:$false
    }
}
#endregion

#region ── TARGET: apply permissions ───────────────────────────────────────────
Write-Log "" INFO
Write-Log "Connecting to TARGET admin ($TargetAdminUrl)..." WARN
try {
    Connect-PnPOnline -Url $TargetAdminUrl -ClientId $tgtClientId -Thumbprint $tgtThumbprint `
        -Tenant $tgtTenantDomain -ErrorAction Stop
    Write-Log "Connected to target tenant." SUCCESS
} catch {
    Write-Log "ERROR: Failed to connect to target tenant: $_" ERROR
    exit 1
}

$successCount    = 0
$skipCount       = 0
$errorCount      = 0
$report          = [System.Collections.Generic.List[PSCustomObject]]::new()
$targetInventory = [System.Collections.Generic.List[PSCustomObject]]::new()

foreach ($entry in $siteData) {
    $tgtUrl = $entry.TargetUrl
    Write-Log "" INFO
    Write-Log "--- Target site: $($entry.SourceTitle)" INFO
    Write-Log "  $tgtUrl" INFO

    try {
        Connect-PnPOnline -Url $tgtUrl -ClientId $tgtClientId -Thumbprint $tgtThumbprint `
            -Tenant $tgtTenantDomain -ErrorAction Stop
    } catch {
        Write-Log "  ERROR: Cannot connect to target site: $_" ERROR
        $errorCount++
        continue
    }

    # ── Target inventory ─────────────────────────────────────────────────────
    try {
        $tgtGroups = Get-PnPGroup -ErrorAction Stop
        foreach ($grp in $tgtGroups) {
            try {
                $grpMembers = Get-PnPGroupMember -Group $grp -ErrorAction Stop
                if ($grpMembers.Count -eq 0) {
                    $targetInventory.Add([PSCustomObject]@{
                        SiteTitle = $entry.SourceTitle; SiteUrl = $tgtUrl
                        GroupName = $grp.Title; MemberLogin = '(empty)'; MemberEmail = ''
                    })
                } else {
                    foreach ($m in $grpMembers) {
                        $rawLogin = if ($m.LoginName) { $m.LoginName } elseif ($m.Email) { $m.Email } else { $m.UserPrincipalName }
                        $targetInventory.Add([PSCustomObject]@{
                            SiteTitle   = $entry.SourceTitle; SiteUrl     = $tgtUrl
                            GroupName   = $grp.Title;         MemberLogin = $rawLogin
                            MemberEmail = $m.Email
                        })
                    }
                }
            } catch { }
        }
    } catch {
        Write-Log "  WARN: Could not enumerate groups on target site: $_" WARN
    }

    # ── Pre-fetch associated groups (authoritative, locale-independent) ───────
    $tgtOwnerGroup   = $null
    $tgtMemberGroup  = $null
    $tgtVisitorGroup = $null
    try {
        $tgtWeb = Get-PnPWeb `
            -Includes AssociatedOwnerGroup,AssociatedMemberGroup,AssociatedVisitorGroup `
            -ErrorAction Stop
        $tgtOwnerGroup   = $tgtWeb.AssociatedOwnerGroup
        $tgtMemberGroup  = $tgtWeb.AssociatedMemberGroup
        $tgtVisitorGroup = $tgtWeb.AssociatedVisitorGroup
        Write-Log "  Owners group  : $($tgtOwnerGroup.Title)"   INFO
        Write-Log "  Members group : $($tgtMemberGroup.Title)"  INFO
        Write-Log "  Visitors group: $($tgtVisitorGroup.Title)" INFO
    } catch {
        Write-Log "  WARN: Could not fetch associated groups: $_" WARN
    }

    # ── Apply permission closure ──────────────────────────────────────────────
    # Accepts plain email strings already resolved/filtered during source pass
    $applyPermission = {
        param([string]$SourceEmail, [string]$RoleLabel, $TargetGroup)

        $tgtEmail = $userMap[$SourceEmail]
        if (-not $tgtEmail) {
            Write-Log "  SKIP [$RoleLabel] '$SourceEmail' — not in mapping." WARN
            $script:skipCount++
            $script:report.Add([PSCustomObject]@{
                SourceSite = $entry.SourceTitle; TargetSite = $tgtUrl
                Role = $RoleLabel; SourceUser = $SourceEmail; TargetUser = ''
                Status = 'SKIPPED'; Reason = 'Not in user mapping'
            })
            return
        }

        # If the Owners AssociatedGroup is missing, create one for Communication Sites
        if (-not $TargetGroup -and $RoleLabel -eq 'OWNER') {
            try {
                $webTitle    = (Get-PnPWeb -ErrorAction SilentlyContinue).Title
                $rawTitle    = if ($webTitle) { "$webTitle Owners" } else { "$($entry.SourceTitle) Owners" }
                $newGrpTitle = ($rawTitle -replace '["/\\[\]:|<>+=;,?*''@]', ' ' -replace '\s+', ' ').Trim()
                Write-Log "  [CREATE GROUP] '$newGrpTitle' — no AssociatedOwnerGroup found." WARN
                $fcRole     = Get-PnPRoleDefinition -ErrorAction Stop |
                              Where-Object { $_.RoleTypeKind -eq 'Administrator' } |
                              Select-Object -First 1
                $fcRoleName = if ($fcRole) { $fcRole.Name } else { 'Full Control' }
                New-PnPGroup -Title $newGrpTitle -Description "Site owners" -ErrorAction Stop | Out-Null
                Set-PnPGroupPermissions -Identity $newGrpTitle -AddRole $fcRoleName -ErrorAction Stop
                $TargetGroup = Get-PnPGroup -Identity $newGrpTitle -ErrorAction Stop
                $script:tgtOwnerGroup = $TargetGroup
            } catch {
                Write-Log "  ERROR creating Owners group: $_" ERROR
                $script:errorCount++
                return
            }
        }

        if (-not $TargetGroup) {
            Write-Log "  WARN [$RoleLabel]: No associated group on target — skipping $tgtEmail." WARN
            $script:errorCount++
            return
        }

        if ($DryRun) {
            Write-Log "  [DRY-RUN][$RoleLabel] Would add $tgtEmail → '$($TargetGroup.Title)'" INFO
            $script:successCount++
            $script:report.Add([PSCustomObject]@{
                SourceSite = $entry.SourceTitle; TargetSite = $tgtUrl
                Role = $RoleLabel; SourceUser = $SourceEmail; TargetUser = $tgtEmail
                Status = 'DRYRUN'; Reason = ''
            })
            return
        }

        try {
            Add-PnPGroupMember -LoginName $tgtEmail -Group $TargetGroup -ErrorAction Stop
            Write-Log "  [$RoleLabel] Added $tgtEmail → '$($TargetGroup.Title)'" SUCCESS
            $script:successCount++
            $script:report.Add([PSCustomObject]@{
                SourceSite = $entry.SourceTitle; TargetSite = $tgtUrl
                Role = $RoleLabel; SourceUser = $SourceEmail; TargetUser = $tgtEmail
                Status = 'SUCCESS'; Reason = ''
            })
        } catch {
            if ($_ -match 'already|exists') {
                Write-Log "  [$RoleLabel] Already present: $tgtEmail" INFO
                $script:report.Add([PSCustomObject]@{
                    SourceSite = $entry.SourceTitle; TargetSite = $tgtUrl
                    Role = $RoleLabel; SourceUser = $SourceEmail; TargetUser = $tgtEmail
                    Status = 'ALREADY_SET'; Reason = ''
                })
            } else {
                Write-Log "  [$RoleLabel] ERROR adding $tgtEmail : $_" ERROR
                $script:errorCount++
                $script:report.Add([PSCustomObject]@{
                    SourceSite = $entry.SourceTitle; TargetSite = $tgtUrl
                    Role = $RoleLabel; SourceUser = $SourceEmail; TargetUser = $tgtEmail
                    Status = 'ERROR'; Reason = $_.Exception.Message
                })
            }
        }
    }

    foreach ($email in $entry.OwnerEmails)  { & $applyPermission $email 'OWNER'   $tgtOwnerGroup  }
    foreach ($email in $entry.MemberEmails) { & $applyPermission $email 'MEMBER'  $tgtMemberGroup }
    if ($IncludeVisitors) {
        foreach ($email in $entry.VisitorEmails) { & $applyPermission $email 'VISITOR' $tgtVisitorGroup }
    }

    # ── Site Collection Admins ────────────────────────────────────────────────
    if ($IncludeSiteAdmins -and $entry.AdminEmails.Count -gt 0) {
        foreach ($email in $entry.AdminEmails) {
            $tgtEmail = $userMap[$email]
            if (-not $tgtEmail) {
                Write-Log "  SKIP [SCA] '$email' — not in mapping." WARN
                $skipCount++
                $report.Add([PSCustomObject]@{
                    SourceSite = $entry.SourceTitle; TargetSite = $tgtUrl
                    Role = 'SCA'; SourceUser = $email; TargetUser = ''
                    Status = 'SKIPPED'; Reason = 'Not in user mapping'
                })
                continue
            }
            if ($DryRun) {
                Write-Log "  [DRY-RUN][SCA] Would set admin: $tgtEmail" INFO
                $successCount++
            } else {
                try {
                    Add-PnPSiteCollectionAdmin -Owners $tgtEmail -ErrorAction Stop
                    Write-Log "  [SCA] Set admin: $tgtEmail" SUCCESS
                    $successCount++
                    $report.Add([PSCustomObject]@{
                        SourceSite = $entry.SourceTitle; TargetSite = $tgtUrl
                        Role = 'SCA'; SourceUser = $email; TargetUser = $tgtEmail
                        Status = 'SUCCESS'; Reason = ''
                    })
                } catch {
                    if ($_ -match 'already') {
                        Write-Log "  [SCA] Already admin: $tgtEmail" INFO
                        $report.Add([PSCustomObject]@{
                            SourceSite = $entry.SourceTitle; TargetSite = $tgtUrl
                            Role = 'SCA'; SourceUser = $email; TargetUser = $tgtEmail
                            Status = 'ALREADY_SET'; Reason = ''
                        })
                    } else {
                        Write-Log "  [SCA] ERROR: $tgtEmail — $_" ERROR
                        $errorCount++
                        $report.Add([PSCustomObject]@{
                            SourceSite = $entry.SourceTitle; TargetSite = $tgtUrl
                            Role = 'SCA'; SourceUser = $email; TargetUser = $tgtEmail
                            Status = 'ERROR'; Reason = $_.Exception.Message
                        })
                    }
                }
            }
        }
    }
}

Disconnect-PnPOnline
#endregion

#region ── Summary & report ────────────────────────────────────────────────────
$ts            = Get-Date -Format 'yyyyMMdd_HHmmss'
$reportPath    = Join-Path (Split-Path $SitesCsv) "SharePointPermReport_$ts.csv"
$inventoryPath = Join-Path (Split-Path $SitesCsv) "SharePointTargetInventory_$ts.csv"
$report          | Export-Csv -Path $reportPath    -NoTypeInformation -Encoding UTF8
$targetInventory | Export-Csv -Path $inventoryPath -NoTypeInformation -Encoding UTF8

Write-Log "" INFO
Write-Log "=== Summary ===" INFO
Write-Log "  Sites processed      : $($siteData.Count)" INFO
Write-Log "  Permissions applied  : $successCount" SUCCESS
Write-Log "  Skipped (no mapping) : $skipCount" WARN
Write-Log "  Errors               : $errorCount" $(if ($errorCount -gt 0) { 'ERROR' } else { 'INFO' })
Write-Log "  Migration report     : $reportPath" INFO
Write-Log "  Target inventory     : $inventoryPath" INFO
if ($DryRun) { Write-Log "*** DRY RUN — no changes were made ***" WARN }
#endregion
