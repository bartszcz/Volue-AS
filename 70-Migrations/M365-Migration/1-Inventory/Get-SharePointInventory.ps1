#Requires -Version 5.1
<#
.SYNOPSIS
    Exports SharePoint Online sites from the SOURCE tenant with full
    permission details — owners, members, visitors, and external users.

.DESCRIPTION
    Site enumeration uses Microsoft Graph (already connected via Connect-SourceTenant
    — no app registration or additional consent required).

    Per-site permission details (SP groups, members, external users) use PnP PowerShell
    and are OPTIONAL. If PnP cannot connect, the site list CSV is still fully exported.

    To enable detailed permissions without registering an app, run ONCE as Global Admin
    in the source tenant:
        Register-PnPManagementShellAccess

    OUTPUTS
        MigrationData\sharepoint_sites.csv              — one row per site
        MigrationData\sharepoint_site_permissions.csv  — one row per user/group per site
        MigrationData\sharepoint_site_groups.csv       — SP group membership per site
        MigrationData\sharepoint_external_users.csv    — external users per site
        MigrationData\sharepoint_hub_sites.csv         — hub sites only

.PARAMETER SourceTenantId
    AAD Tenant ID of the source tenant.

.PARAMETER SourceAdminUPN
    Source SharePoint admin UPN.

.PARAMETER SourceSharePointAdminUrl
    Source SPO Admin Centre URL. e.g. https://contoso-admin.sharepoint.com

.PARAMETER SourceDomain
    Primary email domain of the source company. e.g. 'smartpulse.io'

.PARAMETER CompanySuffix
    Human-readable company name. e.g. 'SmartPulse'

.PARAMETER TargetTenantName
    Tenant name for target URLs. Default: volue

.PARAMETER SkipDetailedPermissions
    Skip per-site PnP permission collection. Use for a fast first pass.

.PARAMETER IncludePersonalSites
    Include OneDrive personal sites. Default: excluded.

.PARAMETER OutputPath
    Output folder. Default: .\MigrationData

.EXAMPLE
    # Fast run — site list only, no PnP consent needed
    .\Get-SharePointInventory.ps1 -SkipDetailedPermissions

.EXAMPLE
    # Full run with permissions (requires Register-PnPManagementShellAccess once)
    .\Get-SharePointInventory.ps1
#>

[CmdletBinding()]
param(
    [string] $SourceTenantId             = '',
    [string] $SourceAdminUPN             = '',
    [string] $SourceSharePointAdminUrl   = '',
    [string] $SourceDomain               = '',
    [string] $CompanySuffix              = '',
    [string] $TargetTenantName           = 'volue',
    [switch] $SkipDetailedPermissions,
    [switch] $IncludePersonalSites,
    [string] $OutputPath                 = '.\MigrationData'
)

# ── Bootstrap ─────────────────────────────────────────────────────────────────

Import-Module (Join-Path $PSScriptRoot '..\MigrationHelpers.psm1') -Force -ErrorAction Stop

# ── Load MigrationConfig.psd1 ────────────────────────────────────────────────
$_cfg = Import-MigrationConfig
$SourceTenantId           = Resolve-ConfigParam -Passed $SourceTenantId           -Default '' -ConfigValue (Get-ConfigValue -Config $_cfg -Key 'SourceTenantId')
$SourceAdminUPN           = Resolve-ConfigParam -Passed $SourceAdminUPN           -Default '' -ConfigValue (Get-ConfigValue -Config $_cfg -Key 'SourceAdminUPN')
$SourceDomain             = Resolve-ConfigParam -Passed $SourceDomain             -Default '' -ConfigValue (Get-ConfigValue -Config $_cfg -Key 'SourceDomain')
$CompanySuffix            = Resolve-ConfigParam -Passed $CompanySuffix            -Default '' -ConfigValue (Get-ConfigValue -Config $_cfg -Key 'CompanySuffix')
$SourceSharePointAdminUrl = Resolve-ConfigParam -Passed $SourceSharePointAdminUrl -Default '' -ConfigValue (Get-ConfigValue -Config $_cfg -Key 'SourceSharePointAdminUrl')
$OutputPath               = Resolve-ConfigParam -Passed $OutputPath               -Default '' -ConfigValue (Get-ConfigValue -Config $_cfg -Key 'OutputPath')

# ── Validate required values ──────────────────────────────────────────────────
$_missingParams = @()
foreach ($__p in @(
    @{ Name='SourceDomain';   Value=$SourceDomain   }
    @{ Name='SourceAdminUPN'; Value=$SourceAdminUPN }
    @{ Name='CompanySuffix';  Value=$CompanySuffix  }
)) {
    if (-not $__p.Value) { $_missingParams += $__p.Name }
}
if ($_missingParams.Count -gt 0) {
    Write-Error ("Required parameters not supplied and not found in MigrationConfig.psd1: {0}`n" +
                 'Either fill in MigrationConfig.psd1 or pass these as command-line arguments.' `
                 -f ($_missingParams -join ', '))
    exit 1
}

Set-MigrationDomains -SourceDomain $SourceDomain -CompanySuffix $CompanySuffix
Initialize-MigLog -ScriptName 'Get-SharePointInventory' `
                  -LogDirectory (Join-Path $PSScriptRoot '..\Logs')
$outDir  = Ensure-OutputDirectory -Path $OutputPath
$domains = Get-MigrationDomains

# ── Helper: derive target URL ─────────────────────────────────────────────────

function Get-TargetSiteUrl {
    param([string]$SourceUrl, [string]$TargetTenant, [string]$Suffix)
    if ($SourceUrl -match '/sites/([^/?]+)') {
        return "https://$TargetTenant.sharepoint.com/sites/$($Matches[1])$Suffix"
    }
    if ($SourceUrl -match '/teams/([^/?]+)') {
        return "https://$TargetTenant.sharepoint.com/teams/$($Matches[1])$Suffix"
    }
    if ($SourceUrl -match '^https://[^/]+\.sharepoint\.com/?$') {
        return "https://$TargetTenant.sharepoint.com"
    }
    return ''
}

# ── Connect to source tenant (Graph + Exchange) ───────────────────────────────

Connect-SourceTenant -TenantId $SourceTenantId -UserPrincipalName $SourceAdminUPN

# ── Enumerate all sites via Microsoft Graph ───────────────────────────────────
# Uses the Graph session from Connect-SourceTenant above.
# Sites.Read.All is included in the default Graph scopes — no extra consent needed.

Write-MigLog 'Retrieving all site collections via Microsoft Graph...'
$allSitesRaw = [System.Collections.Generic.List[object]]::new()
$graphUri    = "https://graph.microsoft.com/v1.0/sites?search=*&`$select=id,displayName,webUrl,createdDateTime,lastModifiedDateTime&`$top=200"
do {
    $resp     = Invoke-MgGraphRequest -Uri $graphUri -Method GET -ErrorAction Stop
    foreach ($s in $resp.value) { $allSitesRaw.Add($s) }
    $graphUri = $resp.'@odata.nextLink'
} while ($graphUri)

# Filter personal sites unless requested
$allSites = @($allSitesRaw | Where-Object {
    $IncludePersonalSites -or ($_.webUrl -notmatch '-my\.sharepoint\.com/personal/')
})
Write-MigLog "Sites found: $($allSites.Count)"

# ── Optional PnP connection for per-site permission details ───────────────────
# PnP is ONLY needed for SP group membership and external user collection.
# If it fails, the site list CSV is still fully exported.
#
# To enable: run once as Global Admin in the source tenant:
#     Register-PnPManagementShellAccess

$pnpAvailable = $false
if (-not $SkipDetailedPermissions) {
    if (-not $SourceSharePointAdminUrl) {
        Write-MigLog 'SourceSharePointAdminUrl not set — skipping PnP permissions. Set it in MigrationConfig.psd1.' -Level WARN
        $SkipDetailedPermissions = $true
    } else {
        Write-MigLog 'Attempting PnP connection for detailed permissions...'
        try {
            Connect-PnPOnline -Url $SourceSharePointAdminUrl `
                              -ClientId '31359c7f-bd7e-475c-86db-fdb8c937548e' `
                              -Interactive -ErrorAction Stop
            $pnpAvailable = $true
            Write-MigLog 'PnP connected — detailed permissions will be collected'
        } catch {
            Write-MigLog "PnP connection failed — detailed permissions will be skipped." -Level WARN
            Write-MigLog "  Error: $_" -Level WARN
            Write-MigLog '  To fix: run once as Global Admin: Register-PnPManagementShellAccess' -Level WARN
            $SkipDetailedPermissions = $true
        }
    }
}

# ── Output collections ────────────────────────────────────────────────────────

$siteRows     = [System.Collections.Generic.List[PSCustomObject]]::new()
$permRows     = [System.Collections.Generic.List[PSCustomObject]]::new()
$groupRows    = [System.Collections.Generic.List[PSCustomObject]]::new()
$externalRows = [System.Collections.Generic.List[PSCustomObject]]::new()
$hubRows      = [System.Collections.Generic.List[PSCustomObject]]::new()

$total = $allSites.Count
$i     = 0

foreach ($site in $allSites) {

    $i++
    Write-ProgressHelper -Activity 'Collecting SPO sites' -Current $i -Total $total -Status $site.webUrl

    $targetUrl   = Get-TargetSiteUrl -SourceUrl $site.webUrl `
                                     -TargetTenant $TargetTenantName `
                                     -Suffix $domains.CompanySuffix
    $targetTitle = if ($site.displayName) { "$($site.displayName) $($domains.CompanySuffix)" } else { '' }

    $siteAdmins         = [System.Collections.Generic.List[string]]::new()
    $membersGroupUsers  = [System.Collections.Generic.List[string]]::new()
    $visitorsGroupUsers = [System.Collections.Generic.List[string]]::new()
    $externalUserCount  = 0
    $sharingLinksCount  = 0

    # ── Per-site PnP permission details ──────────────────────────────────────

    if ($pnpAvailable) {
        try {
            $siteConn = Connect-PnPOnline -Url $site.webUrl `
                                          -ClientId '31359c7f-bd7e-475c-86db-fdb8c937548e' `
                                          -Interactive -ReturnConnection -ErrorAction Stop

            # Site collection admins
            $admins = Invoke-WithRetry {
                Get-PnPSiteCollectionAdmin -Connection $siteConn -ErrorAction Stop
            }
            foreach ($admin in $admins) {
                $email = $admin.Email ?? $admin.LoginName
                if (-not $email) { continue }
                $siteAdmins.Add($email)
                $permRows.Add([PSCustomObject]@{
                    SiteUrl         = $site.webUrl
                    SiteTitle       = $site.displayName
                    UserOrGroup     = $email
                    DisplayName     = $admin.Title
                    PermissionLevel = 'SiteCollectionAdmin'
                    IsGroup         = $false
                    IsExternal      = $email -notmatch [regex]::Escape($domains.SourceDomain)
                    TargetSiteUrl   = $targetUrl
                    TargetEmail     = ''
                    AppliedAtTarget = $false
                    Notes           = ''
                })
            }

            # Default SP groups and their members
            $spGroups = Invoke-WithRetry {
                Get-PnPGroup -Connection $siteConn -ErrorAction Stop
            }
            foreach ($spGrp in $spGroups) {
                $roleType = 'CustomGroup'
                if ($spGrp.Title -match 'Members')  { $roleType = 'DefaultMembers'  }
                if ($spGrp.Title -match 'Visitors') { $roleType = 'DefaultVisitors' }
                if ($spGrp.Title -match 'Owners')   { $roleType = 'DefaultOwners'   }

                $permRows.Add([PSCustomObject]@{
                    SiteUrl         = $site.webUrl
                    SiteTitle       = $site.displayName
                    UserOrGroup     = $spGrp.Title
                    DisplayName     = $spGrp.Title
                    PermissionLevel = $roleType
                    IsGroup         = $true
                    IsExternal      = $false
                    TargetSiteUrl   = $targetUrl
                    TargetEmail     = ''
                    AppliedAtTarget = $false
                    Notes           = "SP Group: $($spGrp.Title) ($($spGrp.Users.Count) users)"
                })

                try {
                    $groupUsers = Invoke-WithRetry {
                        Get-PnPGroupMember -Group $spGrp.Title -Connection $siteConn -ErrorAction Stop
                    }
                    foreach ($gu in $groupUsers) {
                        $userEmail = $gu.Email ?? $gu.LoginName
                        if ([string]::IsNullOrWhiteSpace($userEmail)) { continue }
                        $userEmail = $userEmail -replace '^i:0#\.f\|membership\|',             ''
                        $userEmail = $userEmail -replace '^c:0o\.c\|federateddirectoryclaimprovider\|', ''
                        $isExt = $userEmail -notmatch [regex]::Escape($domains.SourceDomain)

                        $groupRows.Add([PSCustomObject]@{
                            SiteUrl         = $site.webUrl
                            SiteTitle       = $site.displayName
                            SPGroupName     = $spGrp.Title
                            SPGroupRole     = $roleType
                            MemberEmail     = $userEmail
                            MemberName      = $gu.Title
                            IsExternal      = $isExt
                            TargetSiteUrl   = $targetUrl
                            TargetEmail     = ''
                            AppliedAtTarget = $false
                            Notes           = if ($isExt) { 'External user — re-invitation required' } else { '' }
                        })

                        if ($roleType -eq 'DefaultMembers')  { $membersGroupUsers.Add($userEmail)  }
                        if ($roleType -eq 'DefaultVisitors') { $visitorsGroupUsers.Add($userEmail) }

                        if ($isExt) {
                            $externalUserCount++
                            $externalRows.Add([PSCustomObject]@{
                                SiteUrl     = $site.webUrl
                                SiteTitle   = $site.displayName
                                UserEmail   = $userEmail
                                UserName    = $gu.Title
                                SPGroup     = $spGrp.Title
                                AccessLevel = $roleType
                                Notes       = 'External user — must be re-invited to target tenant'
                            })
                        }
                    }
                } catch {
                    Write-MigLog "Group member expansion failed — $($site.webUrl) / $($spGrp.Title): $_" -Level WARN
                }
            }

            # Sharing links summary
            try {
                $links             = Get-PnPFileSharingLink -Connection $siteConn -ErrorAction SilentlyContinue
                $sharingLinksCount = if ($links) { @($links).Count } else { 0 }
            } catch {}

            try { Disconnect-PnPOnline -Connection $siteConn -ErrorAction SilentlyContinue } catch {}
        }
        catch {
            Write-MigLog "Detailed permission collection failed for $($site.webUrl): $_" -Level WARN
        }
    }

    # ── Site summary row ──────────────────────────────────────────────────────

    $row = [PSCustomObject]@{
        SourceUrl               = $site.webUrl
        SourceTitle             = $site.displayName
        Template                = ''
        StorageUsedGB           = 0   # Graph v1 does not expose per-site storage
        StorageQuotaGB          = 0
        SharingCapability       = ''
        Status                  = 'Active'
        IsHubSite               = $false
        HubSiteId               = ''
        LastContentModifiedDate = $site.lastModifiedDateTime

        SiteAdmins              = ($siteAdmins       | Join-String -Separator '|')
        SiteAdminCount          = $siteAdmins.Count
        MembersGroupCount       = $membersGroupUsers.Count
        VisitorsGroupCount      = $visitorsGroupUsers.Count
        ExternalUserCount       = $externalUserCount
        SharingLinksCount       = $sharingLinksCount
        PermissionDetailScanned = $pnpAvailable

        TargetUrl               = $targetUrl
        TargetTitle             = $targetTitle
        TargetOwnerEmail        = ''
        URLGenerated            = ($targetUrl -ne '')

        MigrationStatus         = 'PENDING'
        MigrationPriority       = '2-Standard'
        SharegateMigrated       = $false
        MigrationBatch          = ''
        ReviewedBy              = ''
        Notes                   = $(
            $n = @()
            if ($targetUrl -eq '')         { $n += 'URL needs manual entry' }
            if ($externalUserCount -gt 0)  { $n += "$externalUserCount external user(s) need re-invitation" }
            $n -join ' | '
        )
    }

    $siteRows.Add($row)
}

Write-Progress -Activity 'Collecting SPO sites' -Completed

# ── Export ────────────────────────────────────────────────────────────────────

$siteRows  | Export-CsvSafe -Path (Join-Path $outDir 'sharepoint_sites.csv')
$permRows  | Export-CsvSafe -Path (Join-Path $outDir 'sharepoint_site_permissions.csv')
$groupRows | Export-CsvSafe -Path (Join-Path $outDir 'sharepoint_site_groups.csv')

if ($externalRows.Count -gt 0) {
    $externalRows | Export-CsvSafe -Path (Join-Path $outDir 'sharepoint_external_users.csv')
}
if ($hubRows.Count -gt 0) {
    $hubRows | Export-CsvSafe -Path (Join-Path $outDir 'sharepoint_hub_sites.csv')
}

# ── Summary ───────────────────────────────────────────────────────────────────

Write-MigSummary -Stats @{
    'Total sites'                 = $siteRows.Count
    'Permission rows'             = $permRows.Count
    'SP group member rows'        = $groupRows.Count
    'Sites with external users'   = ($siteRows | Where-Object { $_.ExternalUserCount -gt 0 }).Count
    'Total external user entries' = $externalRows.Count
    'Permission detail scanned'   = $pnpAvailable
    'Next script'                 = 'Get-OneDriveInventory.ps1'
}

try { Disconnect-PnPOnline -ErrorAction SilentlyContinue } catch {}
