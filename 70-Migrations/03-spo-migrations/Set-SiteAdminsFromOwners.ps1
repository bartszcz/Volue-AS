<#
.SYNOPSIS
    Removes migration accounts from site permissions and ensures real site owners
    are set as Site Collection Admins on every site.

.DESCRIPTION
    For each site in sites-mapping.csv the script:

    1. Reads the site's ASSOCIATED OWNER GROUP (the authoritative SP owners group,
       not just any group named "*Owners*").
    2. Removes migration accounts from that group.
    3. Sets the remaining real owners as Site Collection Admins.
    4. Changes the PRIMARY site admin to the first real owner (unblocks migration
       account removal — SharePoint protects the primary from direct removal).
    5. Removes migration accounts from SCAs.
    6. Removes any SCA that is not in the Owners group (system accounts untouched).

    If the associated Owners group is empty after filtering, migration accounts
    are still removed from SCAs but other SCAs are left in place to avoid
    leaving the site completely unmanaged.

.PARAMETER MigrationAccountsToRemove
    Accounts removed from the Owners group AND from SCAs on every site.
    Pass all accounts used during migration work.
    Default: migration.volue@volue.onmicrosoft.com

.PARAMETER SitesCsv
    Path to sites-mapping.csv. Defaults to C:\Optimeering\sites-mapping.csv.

.PARAMETER Tenant
    Source, Target, or Both. Defaults to Both.

.PARAMETER SourcePnpAuthJson
    Defaults to C:\Optimeering\pnp-auth.json.

.PARAMETER TargetPnpAuthJson
    Defaults to C:\Optimeering\pnp-auth-target.json.

.PARAMETER SourceAdminUrl
    Defaults to https://optimeering-admin.sharepoint.com.

.PARAMETER TargetAdminUrl
    Defaults to https://volue-admin.sharepoint.com.

.PARAMETER DryRun
    Shows what would change without making any changes.

.PARAMETER Verify
    Read-only audit mode. Reports Owners group members and current SCAs for every
    site and exports a CSV. No changes are made.

.EXAMPLE
    # Dry run — target only, removing specific migration accounts
    .\Set-SiteAdminsFromOwners.ps1 -Tenant Target -DryRun `
        -MigrationAccountsToRemove 'migration.volue@volue.onmicrosoft.com',
                                   'adm-bartlomiej@volue.onmicrosoft.com',
                                   'bartlomiej.szczesny@volue.com'

    # Apply on target
    .\Set-SiteAdminsFromOwners.ps1 -Tenant Target `
        -MigrationAccountsToRemove 'migration.volue@volue.onmicrosoft.com',
                                   'adm-bartlomiej@volue.onmicrosoft.com',
                                   'bartlomiej.szczesny@volue.com'

    # Verify Owners group state before making changes
    .\Set-SiteAdminsFromOwners.ps1 -Verify -Tenant Target
#>

[CmdletBinding()]
param(
    [string[]]$MigrationAccountsToRemove = @('migration.volue@volue.onmicrosoft.com'),

    [string]$SitesCsv          = "C:\Optimeering\sites-mapping.csv",
    [ValidateSet('Source','Target','Both')]
    [string]$Tenant            = "Both",
    [string]$SourcePnpAuthJson = "C:\Optimeering\pnp-auth.json",
    [string]$TargetPnpAuthJson = "C:\Optimeering\pnp-auth-target.json",
    [string]$SourceAdminUrl    = "https://optimeering-admin.sharepoint.com",
    [string]$TargetAdminUrl    = "https://volue-admin.sharepoint.com",
    [switch]$DryRun,
    [switch]$Verify,
    [string]$LogFile           = ".\SetSiteAdmins_$(Get-Date -Format 'yyyyMMdd_HHmmss').log"
)

#region ── Logging ─────────────────────────────────────────────────────────────
function Write-Log {
    param([string]$Message, [ValidateSet('INFO','WARN','ERROR','SUCCESS')]$Level = 'INFO')
    $ts   = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $line = "[$ts][$Level] $Message"
    $color = switch ($Level) { 'SUCCESS'{'Green'} 'WARN'{'Yellow'} 'ERROR'{'Red'} default{'White'} }
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

function Test-SystemAccount {
    param([string]$Email)
    if ($Email -match '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}(_o)?$') { return $true }
    return $Email -match 'sharepoint$|app@sharepoint|spo-|spocrawler|everyone|nt authority|sharepoint\\|healthmailbox|#ext#|urn:spo|federateddirectoryclaimprovider'
}

function Get-GroupEmails {
    param($Group)
    if (-not $Group) { return @() }
    try {
        return (Get-PnPGroupMember -Group $Group -ErrorAction Stop) | ForEach-Object {
            $login = if ($_.LoginName) { $_.LoginName } elseif ($_.Email) { $_.Email } else { $_.UserPrincipalName }
            Resolve-Email $login
        } | Where-Object { $_ -match '@' -and -not (Test-SystemAccount $_) }
    } catch { return @() }
}

$migrationSet = $MigrationAccountsToRemove | ForEach-Object { $_.ToLower() }
$verifyReport = [System.Collections.Generic.List[PSCustomObject]]::new()
#endregion

#region ── Verify ──────────────────────────────────────────────────────────────
function Get-SiteOwnerState {
    param([string]$SiteUrl, [string]$SiteTitle, [string]$TenantLabel,
          [string]$ClientId, [string]$Thumbprint, [string]$TenantDomain)

    Write-Log "" INFO
    Write-Log "Verifying: $SiteTitle" INFO
    Write-Log "  $SiteUrl" INFO

    try {
        Connect-PnPOnline -Url $SiteUrl -ClientId $ClientId -Thumbprint $Thumbprint `
            -Tenant $TenantDomain -ErrorAction Stop
    } catch {
        Write-Log "  ERROR: Cannot connect: $_" ERROR
        $script:verifyReport.Add([PSCustomObject]@{
            Tenant = $TenantLabel; SiteTitle = $SiteTitle; SiteUrl = $SiteUrl
            OwnersGroup = 'ERROR'; OwnersGroupMember = ''; IsSCA = ''
            SCAsNotInOwners = ''; Status = "Connect error: $($_.Exception.Message)"
        })
        return
    }

    # Use AssociatedOwnerGroup — the authoritative owners group set by SharePoint
    $ownersGrp    = $null
    $ownersEmails = @()
    try {
        $web       = Get-PnPWeb -Includes AssociatedOwnerGroup -ErrorAction Stop
        $ownersGrp = $web.AssociatedOwnerGroup
        if ($ownersGrp) {
            $ownersEmails = Get-GroupEmails $ownersGrp |
                            Where-Object { $_ -notin $migrationSet }
        }
    } catch {
        Write-Log "  WARN: Could not read Owners group: $_" WARN
    }

    # Current SCAs (excluding system and migration accounts)
    $scaEmails = @()
    try {
        $scaEmails = (Get-PnPSiteCollectionAdmin -ErrorAction Stop) | ForEach-Object {
            $login = if ($_.LoginName) { $_.LoginName } elseif ($_.Email) { $_.Email } else { $_.UserPrincipalName }
            Resolve-Email $login
        } | Where-Object { $_ -match '@' -and -not (Test-SystemAccount $_) -and $_ -notin $migrationSet }
    } catch {
        Write-Log "  WARN: Could not read SCAs: $_" WARN
    }

    $grpName         = if ($ownersGrp) { $ownersGrp.Title } else { '(none)' }
    $scasNotInOwners = $scaEmails | Where-Object { $_ -notin $ownersEmails }

    if ($ownersEmails.Count -eq 0) {
        Write-Log "  Owners group : $grpName — EMPTY or no real users" WARN
    } else {
        Write-Log "  Owners group : $grpName" INFO
        foreach ($m in $ownersEmails) {
            $isSca = if ($m -in $scaEmails) { 'YES' } else { 'NO — not yet SCA' }
            Write-Log "    $m  [$isSca]" $(if ($m -notin $scaEmails) { 'WARN' } else { 'SUCCESS' })
        }
    }
    if ($scasNotInOwners) {
        Write-Log "  SCAs not in Owners group: $($scasNotInOwners -join ', ')" WARN
    }

    if ($ownersEmails.Count -eq 0 -and $scasNotInOwners.Count -eq 0) {
        $script:verifyReport.Add([PSCustomObject]@{
            Tenant = $TenantLabel; SiteTitle = $SiteTitle; SiteUrl = $SiteUrl
            OwnersGroup = $grpName; OwnersGroupMember = '(empty)'; IsSCA = ''
            SCAsNotInOwners = ''; Status = 'OWNERS GROUP EMPTY'
        })
    } else {
        foreach ($email in $ownersEmails) {
            $script:verifyReport.Add([PSCustomObject]@{
                Tenant = $TenantLabel; SiteTitle = $SiteTitle; SiteUrl = $SiteUrl
                OwnersGroup = $grpName; OwnersGroupMember = $email
                IsSCA = if ($email -in $scaEmails) { 'Yes' } else { 'No' }
                SCAsNotInOwners = ($scasNotInOwners -join '; ')
                Status = if ($email -in $scaEmails) { 'OK' } else { 'NEEDS SCA' }
            })
        }
        foreach ($email in $scasNotInOwners) {
            $script:verifyReport.Add([PSCustomObject]@{
                Tenant = $TenantLabel; SiteTitle = $SiteTitle; SiteUrl = $SiteUrl
                OwnersGroup = $grpName; OwnersGroupMember = ''
                IsSCA = 'Yes'; SCAsNotInOwners = $email
                Status = 'SCA NOT IN OWNERS GROUP'
            })
        }
    }
}
#endregion

#region ── Sync ────────────────────────────────────────────────────────────────
function Sync-Site {
    param([string]$SiteUrl, [string]$SiteTitle, [string]$ClientId, [string]$Thumbprint, [string]$TenantDomain)

    Write-Log "" INFO
    Write-Log "Processing: $SiteTitle" INFO
    Write-Log "  $SiteUrl" INFO

    try {
        Connect-PnPOnline -Url $SiteUrl -ClientId $ClientId -Thumbprint $Thumbprint `
            -Tenant $TenantDomain -ErrorAction Stop
    } catch {
        Write-Log "  ERROR: Cannot connect: $_" ERROR
        return
    }

    # ── Find the site's associated Owners group ───────────────────────────────
    $ownersGrp     = $null
    $memberObjects = @()
    try {
        $web       = Get-PnPWeb -Includes AssociatedOwnerGroup -ErrorAction Stop
        $ownersGrp = $web.AssociatedOwnerGroup
        if ($ownersGrp) {
            $memberObjects = Get-PnPGroupMember -Group $ownersGrp -ErrorAction Stop
        }
    } catch {
        Write-Log "  WARN: Could not read Owners group: $_" WARN
    }

    # ── Remove migration accounts from the Owners group ───────────────────────
    foreach ($m in $memberObjects) {
        $login = if ($m.LoginName) { $m.LoginName } elseif ($m.Email) { $m.Email } else { $m.UserPrincipalName }
        $email = Resolve-Email $login
        if ($email -in $migrationSet) {
            if ($DryRun) { Write-Log "  [DRY-RUN] Would remove '$email' from '$($ownersGrp.Title)'" WARN }
            else {
                try {
                    Remove-PnPGroupMember -LoginName $login -Group $ownersGrp -ErrorAction Stop
                    Write-Log "  [REMOVED FROM GROUP] $email" SUCCESS
                } catch {
                    Write-Log "  WARN: Cannot remove '$email' from group: $_" WARN
                }
            }
        }
    }

    # ── Re-read group; real owners = non-system, non-migration members ────────
    $realOwners = @()
    if ($ownersGrp) {
        try { $memberObjects = Get-PnPGroupMember -Group $ownersGrp -ErrorAction SilentlyContinue } catch {}
        $realOwners = $memberObjects | ForEach-Object {
            $login = if ($_.LoginName) { $_.LoginName } elseif ($_.Email) { $_.Email } else { $_.UserPrincipalName }
            Resolve-Email $login
        } | Where-Object { $_ -match '@' -and -not (Test-SystemAccount $_) -and $_ -notin $migrationSet }
    }

    $grpLabel = if ($ownersGrp) { "'$($ownersGrp.Title)'" } else { '(none)' }
    if ($realOwners.Count -gt 0) {
        Write-Log "  Owners group $grpLabel : $($realOwners -join ', ')" INFO
    } else {
        Write-Log "  Owners group $grpLabel : no real owners — will only remove migration accounts from SCAs" WARN
    }

    # ── Current SCAs ──────────────────────────────────────────────────────────
    $currentAdmins = @()
    try { $currentAdmins = Get-PnPSiteCollectionAdmin -ErrorAction Stop }
    catch { Write-Log "  ERROR: Could not read Site Admins: $_" ERROR; return }

    $currentAdminEmails = $currentAdmins | ForEach-Object {
        $login = if ($_.LoginName) { $_.LoginName } elseif ($_.Email) { $_.Email } else { $_.UserPrincipalName }
        Resolve-Email $login
    }

    # ── Add real owners as SCAs ───────────────────────────────────────────────
    foreach ($email in $realOwners) {
        if ($email -notin $currentAdminEmails) {
            if ($DryRun) { Write-Log "  [DRY-RUN] Would ADD SCA: $email" INFO }
            else {
                try { Add-PnPSiteCollectionAdmin -Owners $email -ErrorAction Stop; Write-Log "  [ADD SCA] $email" SUCCESS }
                catch { Write-Log "  ERROR adding SCA '$email': $_" ERROR }
            }
        }
    }

    # ── Remove migration accounts from SCAs ───────────────────────────────────
    # Re-read after additions so the list is current
    try { $currentAdmins = Get-PnPSiteCollectionAdmin -ErrorAction Stop } catch {}
    $currentAdminEmails = $currentAdmins | ForEach-Object {
        $login = if ($_.LoginName) { $_.LoginName } elseif ($_.Email) { $_.Email } else { $_.UserPrincipalName }
        Resolve-Email $login
    }

    foreach ($email in $currentAdminEmails) {
        if (Test-SystemAccount $email) { continue }
        if ($email -in $migrationSet) {
            if ($DryRun) { Write-Log "  [DRY-RUN] Would REMOVE SCA: $email" WARN }
            else {
                try { Remove-PnPSiteCollectionAdmin -Owners $email -ErrorAction Stop; Write-Log "  [REMOVE SCA] $email" SUCCESS }
                catch { Write-Log "  WARN removing SCA '$email': $_" WARN }
            }
        }
    }

    # ── Remove SCAs not in Owners group (only when real owners are known) ─────
    # Skip this step if Owners group is empty — don't leave the site unmanaged
    if ($realOwners.Count -gt 0) {
        try { $currentAdmins = Get-PnPSiteCollectionAdmin -ErrorAction Stop } catch {}
        $currentAdminEmails = $currentAdmins | ForEach-Object {
            $login = if ($_.LoginName) { $_.LoginName } elseif ($_.Email) { $_.Email } else { $_.UserPrincipalName }
            Resolve-Email $login
        }
        foreach ($email in $currentAdminEmails) {
            if (Test-SystemAccount $email) { continue }
            if ($email -in $migrationSet) { continue }
            if ($email -notin $realOwners) {
                if ($DryRun) { Write-Log "  [DRY-RUN] Would REMOVE SCA (not in Owners): $email" WARN }
                else {
                    try { Remove-PnPSiteCollectionAdmin -Owners $email -ErrorAction Stop; Write-Log "  [REMOVE SCA] $email" SUCCESS }
                    catch { Write-Log "  WARN removing SCA '$email': $_" WARN }
                }
            }
        }
    }
}
#endregion

Import-Module PnP.PowerShell -ErrorAction Stop

Write-Log "=== Set-SiteAdminsFromOwners ===" INFO
Write-Log "Tenant             : $Tenant" INFO
Write-Log "Migration accounts : $($migrationSet -join ', ')" INFO
if ($DryRun)   { Write-Log "*** DRY RUN MODE ***" WARN }
if ($Verify)   { Write-Log "*** VERIFY MODE — read-only, no changes will be made ***" WARN }

if (-not (Test-Path $SitesCsv)) { Write-Log "ERROR: $SitesCsv not found." ERROR; exit 1 }
$sites = Import-Csv -Path $SitesCsv | Where-Object { $_.Status -eq 'OK' }
Write-Log "Loaded $($sites.Count) site(s)." INFO

#region ── SOURCE ──────────────────────────────────────────────────────────────
if ($Tenant -in @('Source','Both')) {
    if (-not (Test-Path $SourcePnpAuthJson)) { Write-Log "ERROR: $SourcePnpAuthJson not found." ERROR; exit 1 }
    $srcCfg    = Get-Content $SourcePnpAuthJson -Raw | ConvertFrom-Json
    $srcTenant = ($SourceAdminUrl -replace 'https://', '' -replace '-admin\.sharepoint\.com.*', '') + '.onmicrosoft.com'

    Write-Log "" INFO
    Write-Log "── SOURCE TENANT ──────────────────────────────" INFO

    foreach ($site in $sites) {
        if ($Verify) {
            Get-SiteOwnerState -SiteUrl $site.'Site address'.TrimEnd('/') `
                               -SiteTitle $site.Title `
                               -TenantLabel 'Source' `
                               -ClientId $srcCfg.ClientId `
                               -Thumbprint $srcCfg.Thumbprint `
                               -TenantDomain $srcTenant
        } else {
            Sync-Site -SiteUrl $site.'Site address'.TrimEnd('/') `
                      -SiteTitle $site.Title `
                      -ClientId $srcCfg.ClientId `
                      -Thumbprint $srcCfg.Thumbprint `
                      -TenantDomain $srcTenant
        }
    }
    Disconnect-PnPOnline
}
#endregion

#region ── TARGET ──────────────────────────────────────────────────────────────
if ($Tenant -in @('Target','Both')) {
    if (-not (Test-Path $TargetPnpAuthJson)) { Write-Log "ERROR: $TargetPnpAuthJson not found." ERROR; exit 1 }
    $tgtCfg    = Get-Content $TargetPnpAuthJson -Raw | ConvertFrom-Json
    $tgtTenant = ($TargetAdminUrl -replace 'https://', '' -replace '-admin\.sharepoint\.com.*', '') + '.onmicrosoft.com'

    Write-Log "" INFO
    Write-Log "── TARGET TENANT ──────────────────────────────" INFO

    foreach ($site in $sites) {
        if ($Verify) {
            Get-SiteOwnerState -SiteUrl $site.'New Site URL Volue'.TrimEnd('/') `
                               -SiteTitle $site.'New Site Name Volue' `
                               -TenantLabel 'Target' `
                               -ClientId $tgtCfg.ClientId `
                               -Thumbprint $tgtCfg.Thumbprint `
                               -TenantDomain $tgtTenant
        } else {
            Sync-Site -SiteUrl $site.'New Site URL Volue'.TrimEnd('/') `
                      -SiteTitle $site.'New Site Name Volue' `
                      -ClientId $tgtCfg.ClientId `
                      -Thumbprint $tgtCfg.Thumbprint `
                      -TenantDomain $tgtTenant
        }
    }
    Disconnect-PnPOnline
}
#endregion

#region ── Verify report ───────────────────────────────────────────────────────
if ($Verify -and $verifyReport.Count -gt 0) {
    $verifyPath = ".\VerifyOwnersReport_$(Get-Date -Format 'yyyyMMdd_HHmmss').csv"
    $verifyReport | Export-Csv -Path $verifyPath -NoTypeInformation
    Write-Log "" INFO
    Write-Log "Verify report exported: $verifyPath" SUCCESS

    $okCount        = ($verifyReport | Where-Object { $_.Status -eq 'OK' }).Count
    $needsSca       = ($verifyReport | Where-Object { $_.Status -eq 'NEEDS SCA' }).Count
    $scaNotInOwners = ($verifyReport | Where-Object { $_.Status -eq 'SCA NOT IN OWNERS GROUP' }).Count
    $emptyGroups    = ($verifyReport | Where-Object { $_.Status -in @('OWNERS GROUP EMPTY','ERROR') }).Count
    Write-Log "Summary  : $okCount OK  |  $needsSca need SCA  |  $scaNotInOwners SCA not in Owners  |  $emptyGroups empty/error sites" INFO
}
#endregion

Write-Log "" INFO
Write-Log "=== Done ===" INFO
if ($DryRun)  { Write-Log "*** DRY RUN — no changes were made ***" WARN }
if ($Verify)  { Write-Log "*** VERIFY — no changes were made ***" WARN }
