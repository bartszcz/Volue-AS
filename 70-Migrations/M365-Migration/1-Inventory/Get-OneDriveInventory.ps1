#Requires -Version 5.1
#Requires -Modules PnP.PowerShell, Microsoft.Graph.Users
<#
.SYNOPSIS
    Exports OneDrive for Business inventory from the SOURCE tenant.

.DESCRIPTION
    Collects all personal OneDrive sites mapped to their owner UPNs.
    OneDrive migration by Sharegate requires:
      - Source OneDrive URL  → owner's source UPN
      - Target OneDrive URL  → owner's target UPN (first.last@volue.com)

    OneDrive URLs follow a predictable pattern:
        Source: https://{tenant}-my.sharepoint.com/personal/{upn_sanitised}
        Target: https://volue-my.sharepoint.com/personal/{upn_sanitised}

    This script cross-references the OneDrive list with user_mapping.csv
    (if available) to pre-populate target URLs. If mapping isn't available
    yet, target URL fields are left blank for later population.

    Outputs:
        MigrationData\onedrive.csv         — one row per OneDrive site
        MigrationData\onedrive_large.csv   — sites over the size threshold

.PARAMETER SourceTenantId
    AAD Tenant ID of the source tenant.

.PARAMETER SourceAdminUPN
    Source SharePoint/OneDrive admin UPN.

.PARAMETER SourceSharePointAdminUrl
    Source SPO Admin Centre URL (same admin centre manages OneDrive).
    e.g. https://balancingpoolcom-admin.sharepoint.com

.PARAMETER SourceDomain
    Primary email domain of the source company. e.g. 'smartpulse.io'

.PARAMETER CompanySuffix
    Human-readable company name. e.g. 'SmartPulse'

.PARAMETER TargetTenantName
    Tenant name for target OneDrive URLs. Default: volue

.PARAMETER UserMappingCsv
    Path to user_mapping.csv — used to pre-populate TargetOwnerEmail.
    If the file doesn't exist yet the script continues without it.
    Default: .\MigrationData\user_mapping.csv

.PARAMETER LargeSiteThresholdGB
    Sites over this size are written to onedrive_large.csv for
    special handling planning. Default: 50

.PARAMETER OutputPath
    Output folder. Default: .\MigrationData

.EXAMPLE
    .\Get-OneDriveInventory.ps1 `
        -SourceTenantId           'balancingpoolcom.onmicrosoft.com' `
        -SourceAdminUPN 'admin@smartpulse.io' `
        -SourceSharePointAdminUrl 'https://balancingpoolcom-admin.sharepoint.com' `
        -SourceDomain             'smartpulse.io' `
        -CompanySuffix            'SmartPulse'
#>

[CmdletBinding()]
param(
    [string] $SourceTenantId = '',
    [string] $SourceAdminUPN = '',
    [string] $SourceSharePointAdminUrl = '',
    [string] $SourceDomain = '',
    [string] $CompanySuffix = '',
    [string] $SourcePnPClientId     = '',
    [string] $TargetTenantName      = 'volue',
    [string] $UserMappingCsv        = '.\MigrationData\user_mapping.csv',
    [int]    $LargeSiteThresholdGB  = 50,
    [string] $OutputPath            = '.\MigrationData'
)

# ── Bootstrap ─────────────────────────────────────────────────────────────────

Import-Module (Join-Path $PSScriptRoot '..\MigrationHelpers.psm1') -Force -ErrorAction Stop

# ── Load MigrationConfig.psd1 ────────────────────────────────────────────────
$_cfg = Import-MigrationConfig
$SourceTenantId = Resolve-ConfigParam -Passed $SourceTenantId -Default '' -ConfigValue (Get-ConfigValue -Config $_cfg -Key "SourceTenantId")
$SourceAdminUPN = Resolve-ConfigParam -Passed $SourceAdminUPN -Default '' -ConfigValue (Get-ConfigValue -Config $_cfg -Key "SourceAdminUPN")
$SourceDomain = Resolve-ConfigParam -Passed $SourceDomain -Default '' -ConfigValue (Get-ConfigValue -Config $_cfg -Key "SourceDomain")
$CompanySuffix = Resolve-ConfigParam -Passed $CompanySuffix -Default '' -ConfigValue (Get-ConfigValue -Config $_cfg -Key "CompanySuffix")
$SourceSharePointAdminUrl = Resolve-ConfigParam -Passed $SourceSharePointAdminUrl -Default '' -ConfigValue (Get-ConfigValue -Config $_cfg -Key "SourceSharePointAdminUrl")
$UserMappingCsv = Resolve-ConfigParam -Passed $UserMappingCsv -Default '' -ConfigValue (Get-ConfigValue -Config $_cfg -Key "UserMappingCsv")
$OutputPath = Resolve-ConfigParam -Passed $OutputPath -Default '' -ConfigValue (Get-ConfigValue -Config $_cfg -Key "OutputPath")

# ── Validate that required values were supplied (via config or command line) ──
$_missingParams = @()
foreach ($__p in @(
    @{ Name='SourceDomain';    Value=$SourceDomain    }
    @{ Name='SourceAdminUPN'; Value=$SourceAdminUPN }
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

Initialize-MigLog -ScriptName 'Get-OneDriveInventory' `
                  -LogDirectory (Join-Path $PSScriptRoot '..\Logs')

$outDir  = Ensure-OutputDirectory -Path $OutputPath
$domains = Get-MigrationDomains

# ── Load user mapping if available ───────────────────────────────────────────

$mappingLoaded = $false
if (Test-Path $UserMappingCsv) {
    Import-UserMapping -Path $UserMappingCsv -ConfirmedOnly
    $mappingLoaded = $true
    Write-MigLog "User mapping loaded for OneDrive URL pre-population"
}
else {
    Write-MigLog "user_mapping.csv not found — TargetOwnerEmail will be blank. Run New-UserMapping.ps1 first, then re-run this script to populate target URLs." -Level WARN
}

# ── Helper: derive target OneDrive URL from source URL ───────────────────────

function Get-TargetOneDriveUrl {
    param(
        [string] $SourceUrl,
        [string] $TargetTenant
    )

    # Source pattern: https://tenant-my.sharepoint.com/personal/sanitised_upn
    if ($SourceUrl -match '/personal/([^/?]+)') {
        $sanitisedUpn = $Matches[1]
        return "https://$TargetTenant-my.sharepoint.com/personal/$sanitisedUpn"
    }

    return ''
}

function Get-TargetOneDriveUrlFromUPN {
    <#
        Derives a OneDrive URL from a target UPN.
        first.last@volue.com → /personal/first_last_volue_com
    #>
    param(
        [string] $TargetUPN,
        [string] $TargetTenant
    )

    if ([string]::IsNullOrWhiteSpace($TargetUPN)) { return '' }

    # Sanitise: replace @ and . with _ (standard OneDrive URL encoding)
    $sanitised = $TargetUPN.ToLower() -replace '@', '_' -replace '\.', '_' -replace '-', '_'
    return "https://$TargetTenant-my.sharepoint.com/personal/$sanitised"
}

# ── Connect ───────���───────────────────────────────────────────────────────────

Write-MigLog "Connecting to source SharePoint Admin: $SourceSharePointAdminUrl"

# Use interactive auth — works with global admin accounts without requiring pre-registered apps
Connect-PnPOnline -Url $SourceSharePointAdminUrl `
    -Interactive `
    -ErrorAction Stop

# ── Retrieve all OneDrive sites ───────────────────────────────────────────────

Write-MigLog "Retrieving OneDrive sites..."
$oneDriveSites = Invoke-WithRetry {
    Get-PnPTenantSite -IncludeOneDriveSites -ErrorAction Stop |
        Where-Object { $_.Url -match '-my\.sharepoint\.com/personal/' }
}
Write-MigLog "OneDrive sites found: $($oneDriveSites.Count)"

# ── Process ───────────────────────────────────────────────────────────────────

$odRows    = [System.Collections.Generic.List[PSCustomObject]]::new()
$largeRows = [System.Collections.Generic.List[PSCustomObject]]::new()

$total = $oneDriveSites.Count
$i     = 0

foreach ($site in $oneDriveSites) {

    $i++
    Write-ProgressHelper -Activity 'Collecting OneDrive' `
                         -Current $i -Total $total `
                         -Status $site.Url

    $storageUsedGB  = [math]::Round($site.StorageUsageCurrent / 1024, 2)
    $storageQuotaGB = [math]::Round($site.StorageQuota / 1024, 2)

    # Owner UPN is typically the site owner — derive from URL if Owner not set
    $ownerEmail = $site.Owner ?? ''

    # Try to resolve target email from mapping
    $targetOwnerEmail    = ''
    $targetOneDriveUrl   = ''

    if ($mappingLoaded -and $ownerEmail) {
        $targetOwnerEmail = Get-MappedEmail -SourceEmail $ownerEmail
        if ($targetOwnerEmail) {
            # Build target OneDrive URL from mapped target UPN
            $targetOneDriveUrl = Get-TargetOneDriveUrlFromUPN `
                -TargetUPN    $targetOwnerEmail `
                -TargetTenant $TargetTenantName
        }
    }

    # Fallback: derive from source URL (only works if UPN format is similar)
    if (-not $targetOneDriveUrl) {
        $targetOneDriveUrl = Get-TargetOneDriveUrl `
            -SourceUrl    $site.Url `
            -TargetTenant $TargetTenantName
    }

    $isLarge = $storageUsedGB -ge $LargeSiteThresholdGB

    $row = [PSCustomObject]@{

        # Source
        SourceUrl            = $site.Url
        OwnerEmail           = $ownerEmail
        StorageUsedGB        = $storageUsedGB
        StorageQuotaGB       = $storageQuotaGB
        Status               = $site.Status
        LastContentModifiedDate = $site.LastContentModifiedDate

        # Target
        TargetOwnerEmail     = $targetOwnerEmail
        TargetOneDriveUrl    = $targetOneDriveUrl
        TargetUrlSource      = if ($targetOwnerEmail) { 'MappedUPN' }
                               elseif ($targetOneDriveUrl) { 'DerivedFromSource' }
                               else { 'Unknown' }

        # Flags
        IsLargeSite          = $isLarge
        MappingFound         = $targetOwnerEmail -ne ''

        # Migration planning
        MigrationStatus      = 'PENDING'
        SharegateMigrated    = $false
        MigrationBatch       = ''
        Notes                = if (-not $targetOwnerEmail) {
            'Target owner not mapped — run New-UserMapping.ps1 then re-run this script' } else { '' }
    }

    $odRows.Add($row)
    if ($isLarge) { $largeRows.Add($row) }
}

Write-Progress -Activity 'Collecting OneDrive' -Completed

# ── Export ────────────────────────────────────────────────────────────────────

$odPath = Join-Path $outDir 'onedrive.csv'
$odRows | Export-CsvSafe -Path $odPath

if ($largeRows.Count -gt 0) {
    $largeRows | Export-CsvSafe -Path (Join-Path $outDir 'onedrive_large.csv')
}

# ── Summary ───────────────────────────────────────────────────────────────────

$totalStorageGB = [math]::Round(($odRows | Measure-Object StorageUsedGB -Sum).Sum, 2)
$mappedCount    = ($odRows | Where-Object { $_.MappingFound -eq $true }).Count

Write-MigSummary -Stats @{
    'OneDrive sites'           = $odRows.Count
    'Total storage (GB)'       = $totalStorageGB
    "Large sites (>= ${LargeSiteThresholdGB}GB)" = $largeRows.Count
    'Target owner mapped'      = $mappedCount
    'Target owner missing'     = ($odRows.Count - $mappedCount)
    'Mapping was loaded'       = $mappingLoaded
    'Output'                   = $odPath
    'Next script'              = 'Phase 2 — New-UserMapping.ps1'
}

try { Disconnect-PnPOnline -ErrorAction SilentlyContinue } catch {}
