<#
.SYNOPSIS
    Full permission reset on all target sites after migration is complete.
    Empties all SharePoint group memberships and removes non-default Site Collection Admins.

.DESCRIPTION
    For each site in sites-mapping.csv:
      - Removes all members from the Owners, Members, and Visitors SharePoint groups
      - Removes all Site Collection Admins that are not the currently connected app/service account

    Run this AFTER migration is complete and verified. Safe to re-run.

.PARAMETER SitesCsv
    Path to sites-mapping.csv. Defaults to C:\Optimeering\sites-mapping.csv.

.PARAMETER Tenant
    Which tenant to reset: Source, Target, or Both. Defaults to Target.

.PARAMETER SourcePnpAuthJson
    Auth config for source tenant. Defaults to C:\Optimeering\pnp-auth.json.

.PARAMETER TargetPnpAuthJson
    Auth config for target tenant. Defaults to C:\Optimeering\pnp-auth-target.json.

.PARAMETER SourceAdminUrl
    Defaults to https://optimeering-admin.sharepoint.com.

.PARAMETER TargetAdminUrl
    Defaults to https://volue-admin.sharepoint.com.

.PARAMETER DryRun
    Shows what would be removed without making any changes.

.EXAMPLE
    # Dry run on target only
    .\Reset-SharePointPermissions.ps1 -DryRun

    # Full reset on target
    .\Reset-SharePointPermissions.ps1

    # Full reset on both tenants
    .\Reset-SharePointPermissions.ps1 -Tenant Both
#>

[CmdletBinding()]
param(
    [string]$SitesCsv          = "C:\Optimeering\sites-mapping.csv",
    [ValidateSet('Source','Target','Both')]
    [string]$Tenant            = "Target",
    [string]$SourcePnpAuthJson = "C:\Optimeering\pnp-auth.json",
    [string]$TargetPnpAuthJson = "C:\Optimeering\pnp-auth-target.json",
    [string]$SourceAdminUrl    = "https://optimeering-admin.sharepoint.com",
    [string]$TargetAdminUrl    = "https://volue-admin.sharepoint.com",
    [switch]$DryRun,
    [string]$LogFile           = ".\ResetSharePointPerms_$(Get-Date -Format 'yyyyMMdd_HHmmss').log"
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
#endregion

function Reset-Site {
    param([string]$SiteUrl, [string]$SiteTitle, [string]$ClientId, [string]$Thumbprint, [string]$TenantDomain)

    Write-Log "" INFO
    Write-Log "Resetting: $SiteTitle" INFO
    Write-Log "  $SiteUrl" INFO

    try {
        Connect-PnPOnline -Url $SiteUrl -ClientId $ClientId -Thumbprint $Thumbprint `
            -Tenant $TenantDomain -ErrorAction Stop
    } catch {
        Write-Log "  ERROR: Cannot connect: $_" ERROR
        return
    }

    # ── Clear group memberships ───────────────────────────────────────────────
    try {
        $allGroups = Get-PnPGroup -ErrorAction Stop
    } catch {
        Write-Log "  ERROR: Cannot enumerate groups: $_" ERROR
        return
    }

    foreach ($grp in $allGroups) {
        try {
            $members = Get-PnPGroupMember -Group $grp -ErrorAction Stop
        } catch {
            Write-Log "  WARN: Cannot read group '$($grp.Title)': $_" WARN
            continue
        }

        foreach ($m in $members) {
            $login = if ($m.LoginName) { $m.LoginName } elseif ($m.Email) { $m.Email } else { $m.UserPrincipalName }
            $email = Resolve-Email $login

            # Never remove system accounts or M365 group claims — SharePoint put them there
            if (Is-SystemAccount $email) { continue }
            if (-not ($email -match '@')) { continue }

            if ($DryRun) {
                Write-Log "  [DRY-RUN] Would remove '$email' from '$($grp.Title)'" WARN
            } else {
                try {
                    Remove-PnPGroupMember -LoginName $login -Group $grp -ErrorAction Stop
                    Write-Log "  [REMOVED] '$email' from '$($grp.Title)'" SUCCESS
                } catch {
                    Write-Log "  ERROR removing '$email' from '$($grp.Title)': $_" ERROR
                }
            }
        }
    }

    # ── Clear extra Site Collection Admins ────────────────────────────────────
    try {
        $currentAdmins = Get-PnPSiteCollectionAdmin -ErrorAction Stop
    } catch {
        Write-Log "  WARN: Cannot read SCAs: $_" WARN
        return
    }

    foreach ($admin in $currentAdmins) {
        $login = if ($admin.LoginName) { $admin.LoginName } elseif ($admin.Email) { $admin.Email } else { $admin.UserPrincipalName }
        $email = Resolve-Email $login

        if (Is-SystemAccount $email) { continue }
        if (-not ($email -match '@')) { continue }

        if ($DryRun) {
            Write-Log "  [DRY-RUN] Would remove SCA: $email" WARN
        } else {
            try {
                Remove-PnPSiteCollectionAdmin -Owners $email -ErrorAction Stop
                Write-Log "  [REMOVED SCA] $email" SUCCESS
            } catch {
                Write-Log "  ERROR removing SCA $email : $_" ERROR
            }
        }
    }
}

Import-Module PnP.PowerShell -ErrorAction Stop

Write-Log "=== Reset-SharePointPermissions ===" INFO
Write-Log "Tenant: $Tenant" INFO
if ($DryRun) { Write-Log "*** DRY RUN MODE ***" WARN }

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
        Reset-Site -SiteUrl $site.'Site address'.TrimEnd('/') `
                   -SiteTitle $site.Title `
                   -ClientId $srcCfg.ClientId `
                   -Thumbprint $srcCfg.Thumbprint `
                   -TenantDomain $srcTenant
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
        Reset-Site -SiteUrl $site.'New Site URL Volue'.TrimEnd('/') `
                   -SiteTitle $site.'New Site Name Volue' `
                   -ClientId $tgtCfg.ClientId `
                   -Thumbprint $tgtCfg.Thumbprint `
                   -TenantDomain $tgtTenant
    }
    Disconnect-PnPOnline
}
#endregion

Write-Log "" INFO
Write-Log "=== Done ===" INFO
if ($DryRun) { Write-Log "*** DRY RUN — no changes were made ***" WARN }
