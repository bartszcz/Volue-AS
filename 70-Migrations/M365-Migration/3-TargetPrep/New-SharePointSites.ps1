#Requires -Version 5.1
#Requires -Modules PnP.PowerShell
<#
.SYNOPSIS
    Creates SharePoint site collections in the TARGET tenant from the
    confirmed SharePoint mapping, respecting hub site creation order.

.DESCRIPTION
    Reads sharepoint_mapping.csv (CONFIRMED rows) and creates each site
    collection in the Volue SharePoint Online tenant.

    CREATION ORDER
        Hub sites MUST be created before their member sites so that
        hub association can be applied during member site creation.
        The script automatically processes hub sites first (MigrationPriority
        = '1-HubFirst'), then all other sites.

    PER SITE
        - Creates the site collection with target URL and title
        - Sets the site owner (TargetOwnerEmail)
        - Adds site collection administrators (from sharepoint_site_permissions.csv)
        - Registers the site as a hub (if source IsHubSite=True)
        - Associates the site to its hub (if source HubSiteId is populated)
        - Permissions (SP groups / members) are set by Set-SharePointPermissions.ps1

    IDEMPOTENT — if a site already exists at the target URL it is validated
    and skipped (URL is the identity key).

    SITE TEMPLATES
        Communication sites       : SITEPAGEPUBLISHING#0
        Team sites (no group)     : STS#3
        Group-connected team sites: Already created by New-M365GroupsAndTeams.ps1
                                    — those are skipped here (Template matches GROUP#*)

    OUTPUTS
        MigrationData\sharepoint_creation_results.csv
        MigrationData\sharepoint_creation_errors.csv

.PARAMETER TargetTenantId
    AAD Tenant ID of the target tenant.

.PARAMETER TargetAdminUPN
    Admin UPN for the target tenant.

.PARAMETER TargetSharePointAdminUrl
    Target SPO Admin Centre URL. e.g. https://volue-admin.sharepoint.com

.PARAMETER SourceDomain
    Primary email domain of the source company. e.g. 'smartpulse.io'

.PARAMETER CompanySuffix
    Human-readable company name. e.g. 'SmartPulse'

.PARAMETER SharePointMappingCsv
    Confirmed SharePoint mapping.
    Default: .\MigrationData\sharepoint_mapping.csv

.PARAMETER SitePermissionsCsv
    Site permissions from Phase 1 (for setting admins).
    Default: .\MigrationData\sharepoint_site_permissions.csv

.PARAMETER UserMappingCsv
    Confirmed user mapping.
    Default: .\MigrationData\user_mapping_confirmed.csv

.PARAMETER ProvisioningWaitSeconds
    Seconds to wait for each site to provision. Default: 90

.PARAMETER WhatIf
    Show what would be created without making changes.

.PARAMETER OutputPath
    Output folder. Default: .\MigrationData

.EXAMPLE
    .\New-SharePointSites.ps1 `
        -TargetTenantId          'volue.onmicrosoft.com' `
        -TargetAdminUPN          'admin@volue.com' `
        -TargetSharePointAdminUrl 'https://volue-admin.sharepoint.com' `
        -SourceDomain            'smartpulse.io' `
        -CompanySuffix           'SmartPulse' `
        -WhatIf
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    [string] $TargetTenantId = '',
    [string] $TargetAdminUPN = '',
    [string] $TargetSharePointAdminUrl = '',
    [string] $SourceDomain = '',
    [string] $CompanySuffix = '',
    [string] $SharePointMappingCsv  = '.\MigrationData\sharepoint_mapping.csv',
    [string] $SitePermissionsCsv   = '.\MigrationData\sharepoint_site_permissions.csv',
    [string] $UserMappingCsv       = '.\MigrationData\user_mapping_confirmed.csv',
    [int]    $ProvisioningWaitSeconds = 90,
    [string] $TargetPnPClientId      = '',
    [string] $OutputPath            = '.\MigrationData'
)

# ── Bootstrap ─────────────────────────────────────────────────────────────────

Import-Module (Join-Path $PSScriptRoot '..\MigrationHelpers.psm1') -Force -ErrorAction Stop

# ── Load MigrationConfig.psd1 ────────────────────────────────────────────────
$_cfg = Import-MigrationConfig
$SourceDomain = Resolve-ConfigParam -Passed $SourceDomain -Default '' -ConfigValue (Get-ConfigValue -Config $_cfg -Key "SourceDomain")
$CompanySuffix = Resolve-ConfigParam -Passed $CompanySuffix -Default '' -ConfigValue (Get-ConfigValue -Config $_cfg -Key "CompanySuffix")
$TargetTenantId = Resolve-ConfigParam -Passed $TargetTenantId -Default '' -ConfigValue (Get-ConfigValue -Config $_cfg -Key "TargetTenantId")
$TargetAdminUPN = Resolve-ConfigParam -Passed $TargetAdminUPN -Default '' -ConfigValue (Get-ConfigValue -Config $_cfg -Key "TargetAdminUPN")
$TargetSharePointAdminUrl = Resolve-ConfigParam -Passed $TargetSharePointAdminUrl -Default '' -ConfigValue (Get-ConfigValue -Config $_cfg -Key "TargetSharePointAdminUrl")
$UserMappingCsv = Resolve-ConfigParam -Passed $UserMappingCsv -Default '' -ConfigValue (Get-ConfigValue -Config $_cfg -Key "UserMappingCsv")
$SharePointMappingCsv = Resolve-ConfigParam -Passed $SharePointMappingCsv -Default '' -ConfigValue (Get-ConfigValue -Config $_cfg -Key "SharePointMappingCsv")
$TargetPnPClientId = Resolve-ConfigParam -Passed $TargetPnPClientId -Default '' -ConfigValue (Get-ConfigValue -Config $_cfg -Key "TargetPnPClientId")
# Fall back to PnP Management Shell app if no custom ClientId configured
if (-not $TargetPnPClientId) { $TargetPnPClientId = '31359c7f-bd7e-475c-86db-fdb8c937548e' }
$OutputPath = Resolve-ConfigParam -Passed $OutputPath -Default '' -ConfigValue (Get-ConfigValue -Config $_cfg -Key "OutputPath")

# ── Validate that required values were supplied (via config or command line) ──
$_missingParams = @()
foreach ($__p in @(
    @{ Name='SourceDomain';    Value=$SourceDomain    }
    @{ Name='CompanySuffix';   Value=$CompanySuffix   }
)) {
    if (-not $__p.Value) { $_missingParams += $__p.Name }
}
if ($_missingParams.Count -gt 0) {
    Write-Error ("Required parameters not supplied and not found in MigrationConfig.psd1: {0}`n" +
                 "Either fill in MigrationConfig.psd1 or pass these as command-line arguments." `
                 -f ($_missingParams -join ', '))
    exit 1
}

Set-MigrationDomains -SourceDomain $SourceDomain -CompanySuffix $CompanySuffix
Initialize-MigLog -ScriptName 'New-SharePointSites' `
                  -LogDirectory (Join-Path $PSScriptRoot '..\Logs')
$outDir = Ensure-OutputDirectory -Path $OutputPath

# ── Load inputs ───────────────────────────────────────────────────────────────

$allSites      = Import-CsvSafe -Path $SharePointMappingCsv `
    -RequiredColumns @('SourceUrl','TargetUrl','TargetTitle','Status','IsHubSite','MigrationPriority')
$confirmedSites = $allSites | Where-Object { $_.Status -eq 'CONFIRMED' }

# Skip group-connected team sites — provisioned by New-M365GroupsAndTeams.ps1
$confirmedSites = $confirmedSites | Where-Object {
    $_.Template -notmatch '^GROUP'
}

# Sort: hub sites first, then all others
$orderedSites = $confirmedSites | Sort-Object MigrationPriority
Write-MigLog "Confirmed SPO sites to create: $($orderedSites.Count) (hub sites first)"

Import-UserMapping -Path $UserMappingCsv -ConfirmedOnly

# Build admin index per source URL: sourceUrl → list of admin emails
$adminIndex = @{}
if (Test-Path $SitePermissionsCsv) {
    $permRows = Import-CsvSafe -Path $SitePermissionsCsv
    foreach ($r in ($permRows | Where-Object { $_.PermissionLevel -eq 'SiteCollectionAdmin' })) {
        if (-not $adminIndex.ContainsKey($r.SiteUrl)) {
            $adminIndex[$r.SiteUrl] = [System.Collections.Generic.List[string]]::new()
        }
        $adminIndex[$r.SiteUrl].Add($r.UserOrGroup)
    }
}

# ── Connect ───────────────────────────────────────────────────────────────────

Write-MigLog "Connecting to target SharePoint Admin: $TargetSharePointAdminUrl"
Connect-PnPOnline -Url $TargetSharePointAdminUrl ` -ClientId '14d82eec-204b-4c2f-b7e8-296a70dab67e' -Interactive -ErrorAction Stop

# Index existing target sites
$targetSiteList  = Invoke-WithRetry { Get-PnPTenantSite -ErrorAction Stop }
$existingIndex   = @{}
foreach ($s in $targetSiteList) { $existingIndex[$s.Url.ToLower()] = $s }

# Hub site ID mapping: source HubSiteId GUID → target hub site URL
# (populated as we create hub sites during this run)
$hubIdToTargetUrl = @{}

# ── Creation loop ─────────────────────────────────────────────────────────────

$resultRows = [System.Collections.Generic.List[PSCustomObject]]::new()
$errorRows  = [System.Collections.Generic.List[PSCustomObject]]::new()

$created  = 0; $existing = 0; $failed = 0
$total    = $orderedSites.Count; $i = 0

foreach ($site in $orderedSites) {

    $i++
    Write-ProgressHelper -Activity 'Creating SharePoint sites' `
                         -Current $i -Total $total `
                         -Status $site.TargetUrl

    $targetUrl   = $site.TargetUrl
    $targetTitle = $site.TargetTitle
    $isHub       = $site.IsHubSite -eq $true -or $site.IsHubSite -eq 'True'
    $ownerEmail  = $site.TargetOwnerEmail

    # Resolve owner to target email (in case mapping wasn't pre-populated)
    if (-not $ownerEmail -and $site.SourceOwner) {
        $ownerEmail = Get-MappedEmail -SourceEmail $site.SourceOwner
    }
    if (-not $ownerEmail) {
        Write-MigLog "  No owner for $targetUrl — using admin UPN as fallback" -Level WARN
        $ownerEmail = $TargetAdminUPN
    }

    # Determine template
    $template = switch -Regex ($site.Template) {
        'SITEPAGEPUBLISHING' { 'SITEPAGEPUBLISHING#0' }
        'STS#0|TEAMCHANNEL'  { 'STS#3' }
        default              { 'STS#3' }
    }

    # ── Idempotency ───────────────────────────────────────────────────────────
    if ($existingIndex.ContainsKey($targetUrl.ToLower())) {
        $existing++
        Write-MigLog "  EXISTS: $targetUrl"

        # If this is a hub site, record it for member site association
        if ($isHub) { $hubIdToTargetUrl[$site.SourceUrl] = $targetUrl }

        $resultRows.Add([PSCustomObject]@{
            SourceUrl = $site.SourceUrl; TargetUrl = $targetUrl
            IsHub = $isHub; Action = 'ALREADY_EXISTS'; WhatIf = $false
            AdminsAdded = 0; Notes = 'Site already existed'
        })
        continue
    }

    if ($PSCmdlet.ShouldProcess($targetUrl, "Create SPO site '$targetTitle'")) {
        try {
            # Create site
            Invoke-WithRetry {
                New-PnPTenantSite -Title    $targetTitle `
                                  -Url      $targetUrl `
                                  -Owner    $ownerEmail `
                                  -Template $template `
                                  -TimeZone 4 `
                                  -Wait `
                                  -ErrorAction Stop | Out-Null
            }
            Write-MigLog "  CREATED: $targetUrl"

            Start-Sleep -Seconds $ProvisioningWaitSeconds

            # ── Register as hub site ──────────────────────────────────────────
            if ($isHub) {
                Invoke-WithRetry {
                    Register-PnPHubSite -Site $targetUrl -ErrorAction Stop | Out-Null
                }
                Write-MigLog "  REGISTERED as hub: $targetUrl"
                $hubIdToTargetUrl[$site.SourceUrl] = $targetUrl
            }

            # ── Associate to hub (if this site was a hub member at source) ────
            if ($site.HubSiteId -and -not $isHub) {
                # Try to find the target hub URL using the source URL lookup we built
                $targetHubUrl = $hubIdToTargetUrl.Values |
                    Where-Object { $_ } | Select-Object -First 1

                # Better: look up by matching SourceUrl in the mapping
                $hubSiteRow = $allSites | Where-Object {
                    $_.IsHubSite -eq $true -and $_.SourceUrl -eq $site.HubSiteId
                } | Select-Object -First 1

                if ($hubSiteRow) { $targetHubUrl = $hubSiteRow.TargetUrl }

                if ($targetHubUrl) {
                    try {
                        Invoke-WithRetry {
                            Add-PnPHubSiteAssociation -Site $targetUrl `
                                                      -HubSite $targetHubUrl `
                                                      -ErrorAction Stop | Out-Null
                        }
                        Write-MigLog "  ASSOCIATED to hub: $targetHubUrl"
                    }
                    catch { Write-MigLog "  Hub association failed: $_" -Level WARN }
                }
                else {
                    Write-MigLog "  Hub site not found for association — HubSiteId: $($site.HubSiteId)" -Level WARN
                }
            }

            # ── Add site collection admins ────────────────────────────────────
            $adminsAdded  = 0
            $srcAdmins    = $adminIndex[$site.SourceUrl]
            if ($srcAdmins) {
                $siteConn = Connect-PnPOnline -Url $targetUrl ` -ClientId '14d82eec-204b-4c2f-b7e8-296a70dab67e' -Interactive -ReturnConnection -ErrorAction Stop
                foreach ($adminEmail in $srcAdmins) {
                    $targetAdminEmail = Get-MappedEmail -SourceEmail $adminEmail
                    if (-not $targetAdminEmail) {
                        Write-MigLog "  Admin '$adminEmail' not in mapping — skipped" -Level WARN; continue
                    }
                    try {
                        Invoke-WithRetry {
                            Add-PnPSiteCollectionAdmin -Owners $targetAdminEmail `
                                                       -Connection $siteConn `
                                                       -ErrorAction Stop
                        }
                        $adminsAdded++
                    }
                    catch { Write-MigLog "  Admin add failed: $targetAdminEmail — $_" -Level WARN }
                }
                try { Disconnect-PnPOnline -Connection $siteConn -ErrorAction SilentlyContinue } catch {}
            }

            $created++
            $resultRows.Add([PSCustomObject]@{
                SourceUrl   = $site.SourceUrl
                TargetUrl   = $targetUrl
                IsHub       = $isHub
                Action      = 'CREATED'
                AdminsAdded = $adminsAdded
                WhatIf      = $false
                Notes       = ''
            })
        }
        catch {
            $failed++
            Write-MigLog "  FAILED: $targetUrl — $_" -Level ERROR
            $errorRows.Add([PSCustomObject]@{
                SourceUrl  = $site.SourceUrl
                TargetUrl  = $targetUrl
                Error      = $_.Exception.Message
            })
        }
    }
    else {
        Write-MigLog "  WHATIF: Would create SPO site '$targetTitle' at $targetUrl"
        $resultRows.Add([PSCustomObject]@{
            SourceUrl = $site.SourceUrl; TargetUrl = $targetUrl
            IsHub = $isHub; Action = 'WHATIF'; AdminsAdded = 0; WhatIf = $true; Notes = ''
        })
    }
}

Write-Progress -Activity 'Creating SharePoint sites' -Completed

$resultRows | Export-CsvSafe -Path (Join-Path $outDir 'sharepoint_creation_results.csv')
if ($errorRows.Count -gt 0) {
    $errorRows | Export-CsvSafe -Path (Join-Path $outDir 'sharepoint_creation_errors.csv')
}

Write-MigSummary -Stats @{
    'Total confirmed sites' = $total
    'Created'               = $created
    'Already existed'       = $existing
    'Failed'                = $failed
    'Hub sites registered'  = ($resultRows | Where-Object { $_.IsHub -eq $true -and $_.Action -eq 'CREATED' }).Count
    'WhatIf mode'           = $WhatIfPreference
    'Next script'           = 'Set-MailboxPermissions.ps1'
}

try { Disconnect-PnPOnline -ErrorAction SilentlyContinue } catch {}
