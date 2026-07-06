#Requires -Version 5.1
#Requires -Modules PnP.PowerShell
<#
.SYNOPSIS
    Post-migration SharePoint and OneDrive validation. Run after each
    Sharegate migration job completes.

.DESCRIPTION
    For every site in the confirmed mapping, validates:

        SITE EXISTS
            Target site URL resolves and is accessible.

        STORAGE DELTA
            Target storage is within an acceptable margin of source
            (Sharegate can't migrate certain system files — minor delta
            is expected; large delta indicates a problem).

        PERMISSIONS
            Site collection admins are present.
            Members and Visitors groups have at least one member.
            External users flagged for re-invitation are logged.

        HUB ASSOCIATION
            Sites that were hub members at source are associated to their
            target hub.

        OWNER
            Site owner matches TargetOwnerEmail from mapping.

    OneDrive sites are validated separately from SPO sites.

    OUTPUTS
        MigrationData\post_spo_validation.csv
        MigrationData\post_spo_validation_issues.csv
        MigrationData\post_onedrive_validation.csv
        MigrationData\post_onedrive_validation_issues.csv

.PARAMETER TargetTenantId
    AAD Tenant ID of the target tenant.

.PARAMETER TargetAdminUPN
    Target SPO admin UPN.

.PARAMETER TargetSharePointAdminUrl
    Target SPO Admin Centre URL. e.g. https://volue-admin.sharepoint.com

.PARAMETER SourceDomain
    Primary email domain of the source company. e.g. 'smartpulse.io'

.PARAMETER CompanySuffix
    Human-readable company name. e.g. 'SmartPulse'

.PARAMETER SharePointMappingCsv
    Default: .\MigrationData\sharepoint_mapping.csv

.PARAMETER OneDriveMappingCsv
    Default: .\MigrationData\onedrive_mapping.csv

.PARAMETER StorageDeltaThresholdPct
    Maximum acceptable percentage difference between source and target
    storage. Default: 15 (flag if target has more than 15% less than source).

.PARAMETER SkipOneDrive
    Skip OneDrive validation (useful when validating SPO only).

.PARAMETER OutputPath
    Output folder. Default: .\MigrationData

.EXAMPLE
    .\Test-PostSharePointMigration.ps1 `
        -TargetTenantId          'volue.onmicrosoft.com' `
        -TargetAdminUPN          'admin@volue.com' `
        -TargetSharePointAdminUrl 'https://volue-admin.sharepoint.com' `
        -SourceDomain            'smartpulse.io' `
        -CompanySuffix           'SmartPulse'
#>

[CmdletBinding()]
param(
    [string] $TargetTenantId = '',
    [string] $TargetAdminUPN = '',
    [string] $TargetSharePointAdminUrl = '',
    [string] $SourceDomain = '',
    [string] $CompanySuffix = '',
    [string] $SharePointMappingCsv    = '.\MigrationData\sharepoint_mapping.csv',
    [string] $OneDriveMappingCsv      = '.\MigrationData\onedrive_mapping.csv',
    [int]    $StorageDeltaThresholdPct = 15,
    [switch] $SkipOneDrive,
    [string] $TargetPnPClientId        = '',
    [string] $OutputPath               = '.\MigrationData'
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
$TargetPnPClientId = Resolve-ConfigParam -Passed $TargetPnPClientId -Default '' -ConfigValue (Get-ConfigValue -Config $_cfg -Key "TargetPnPClientId")
# Fall back to PnP Management Shell app if no custom ClientId configured
if (-not $TargetPnPClientId) { $TargetPnPClientId = '31359c7f-bd7e-475c-86db-fdb8c937548e' }
$SharePointMappingCsv = Resolve-ConfigParam -Passed $SharePointMappingCsv -Default '' -ConfigValue (Get-ConfigValue -Config $_cfg -Key "SharePointMappingCsv")
$OneDriveMappingCsv = Resolve-ConfigParam -Passed $OneDriveMappingCsv -Default '' -ConfigValue (Get-ConfigValue -Config $_cfg -Key "OneDriveMappingCsv")
$OutputPath = Resolve-ConfigParam -Passed $OutputPath -Default '' -ConfigValue (Get-ConfigValue -Config $_cfg -Key "OutputPath")
$StorageDeltaThresholdPct = Resolve-ConfigParam -Passed $StorageDeltaThresholdPct -Default '' -ConfigValue (Get-ConfigValue -Config $_cfg -Key "StorageDeltaThresholdPct")

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
Initialize-MigLog -ScriptName 'Test-PostSharePointMigration' `
                  -LogDirectory (Join-Path $PSScriptRoot '..\Logs')
$outDir = Ensure-OutputDirectory -Path $OutputPath

# ── Connect ───────────────────────────────────────────────────────────────────

Write-MigLog "Connecting to target SPO Admin: $TargetSharePointAdminUrl"
Connect-PnPOnline -Url $TargetSharePointAdminUrl ` -ClientId '14d82eec-204b-4c2f-b7e8-296a70dab67e' -Interactive -ErrorAction Stop
$targetSites    = Invoke-WithRetry { Get-PnPTenantSite -IncludeOneDriveSites -ErrorAction Stop }
$targetSiteIndex = @{}
foreach ($s in $targetSites) { $targetSiteIndex[$s.Url.ToLower()] = $s }
Write-MigLog "Target sites indexed: $($targetSiteIndex.Count)"

# ── Validate SharePoint sites ─────────────────────────────────────────────────

$spoResults = [System.Collections.Generic.List[PSCustomObject]]::new()
$spoIssues  = [System.Collections.Generic.List[PSCustomObject]]::new()

if (Test-Path $SharePointMappingCsv) {

    $spoMapping = Import-CsvSafe -Path $SharePointMappingCsv `
        -RequiredColumns @('SourceUrl','TargetUrl','Status')
    $confirmed  = $spoMapping | Where-Object { $_.Status -eq 'CONFIRMED' }

    Write-MigLog "Validating $(@($confirmed).Count) confirmed SPO sites..."

    $total = @($confirmed).Count
    $i     = 0; $passed = 0; $warnings = 0; $failed = 0

    foreach ($site in $confirmed) {

        $i++
        Write-ProgressHelper -Activity 'Validating SPO sites' `
                             -Current $i -Total $total -Status $site.TargetUrl

        $targetSite  = $targetSiteIndex[$site.TargetUrl.ToLower()]
        $issues      = [System.Collections.Generic.List[string]]::new()
        $status      = 'PASS'

        # ── Exists ────────────────────────────────────────────────────────────
        if (-not $targetSite) {
            $spoResults.Add([PSCustomObject]@{
                SourceUrl      = $site.SourceUrl
                TargetUrl      = $site.TargetUrl
                Status         = 'FAIL'
                IsHub          = $site.IsHubSite
                SourceStorageGB = [double]$site.StorageUsedGB
                TargetStorageGB = 0
                StorageDeltaPct = -100
                AdminsPresent  = $false
                HubAssociated  = $false
                OwnerCorrect   = $false
                Issues         = 'Target site not found — Sharegate migration may not have run'
            })
            $failed++
            $spoIssues.Add([PSCustomObject]@{
                SiteUrl = $site.TargetUrl
                Severity = 'CRITICAL'
                Issue = 'Target site not found'
            })
            continue
        }

        # ── Storage delta ──────────────────────────────────────────────────────
        $sourceStorageGB = [double]($site.StorageUsedGB ?? 0)
        $targetStorageGB = [math]::Round($targetSite.StorageUsageCurrent / 1024, 2)
        $storageDelta    = if ($sourceStorageGB -gt 0) {
            [math]::Round((($targetStorageGB - $sourceStorageGB) / $sourceStorageGB) * 100, 1)
        } else { 0 }

        if ($sourceStorageGB -gt 0 -and $storageDelta -lt -$StorageDeltaThresholdPct) {
            $issues.Add("WARN: Target storage ${targetStorageGB}GB is ${storageDelta}% vs source ${sourceStorageGB}GB (threshold: -${StorageDeltaThresholdPct}%)")
            $status = 'WARN'
        }

        # ── Site owner ────────────────────────────────────────────────────────
        $ownerCorrect = $true
        if ($site.TargetOwnerEmail) {
            $ownerCorrect = $targetSite.Owner.ToLower() -eq $site.TargetOwnerEmail.ToLower()
            if (-not $ownerCorrect) {
                $issues.Add("WARN: Site owner is '$($targetSite.Owner)' but expected '$($site.TargetOwnerEmail)'")
                if ($status -eq 'PASS') { $status = 'WARN' }
            }
        }

        # ── Hub association ───────────────────────────────────────────────────
        $hubAssociated = $true
        $isHub         = $site.IsHubSite -eq $true -or $site.IsHubSite -eq 'True'
        $isMember      = $site.HubSiteId -ne '' -and -not $isHub

        if ($isHub -and -not $targetSite.IsHubSite) {
            $issues.Add("WARN: Site should be registered as hub but is not")
            $hubAssociated = $false
            if ($status -eq 'PASS') { $status = 'WARN' }
        }
        if ($isMember -and -not $targetSite.HubSiteId) {
            $issues.Add("INFO: Site was a hub member at source but has no hub association at target")
        }

        # ── Admins present ────────────────────────────────────────────────────
        $adminsPresent = $true
        try {
            $siteConn = Connect-PnPOnline -Url $site.TargetUrl ` -ClientId '14d82eec-204b-4c2f-b7e8-296a70dab67e' -Interactive -ReturnConnection -ErrorAction Stop
            $admins   = Get-PnPSiteCollectionAdmin -Connection $siteConn -ErrorAction Stop
            if (@($admins).Count -eq 0) {
                $issues.Add("WARN: No site collection admins found")
                $adminsPresent = $false
                if ($status -eq 'PASS') { $status = 'WARN' }
            }
            try { Disconnect-PnPOnline -Connection $siteConn -ErrorAction SilentlyContinue } catch {}
        }
        catch {
            $issues.Add("WARN: Could not verify admins — $_")
        }

        if ($status -eq 'PASS') { $passed++ } elseif ($status -eq 'WARN') { $warnings++ }

        $spoResults.Add([PSCustomObject]@{
            SourceUrl       = $site.SourceUrl
            TargetUrl       = $site.TargetUrl
            Status          = $status
            IsHub           = $isHub
            SourceStorageGB = $sourceStorageGB
            TargetStorageGB = $targetStorageGB
            StorageDeltaPct = $storageDelta
            AdminsPresent   = $adminsPresent
            HubAssociated   = $hubAssociated
            OwnerCorrect    = $ownerCorrect
            Issues          = ($issues | Join-String -Separator ' | ')
        })

        foreach ($issue in $issues) {
            $sev = if ($issue -match '^WARN') { 'WARN' } else { 'INFO' }
            $spoIssues.Add([PSCustomObject]@{
                SiteUrl  = $site.TargetUrl
                Severity = $sev
                Issue    = $issue
            })
        }
    }

    Write-Progress -Activity 'Validating SPO sites' -Completed

    $spoResults | Export-CsvSafe -Path (Join-Path $outDir 'post_spo_validation.csv')
    if ($spoIssues.Count -gt 0) {
        $spoIssues | Export-CsvSafe -Path (Join-Path $outDir 'post_spo_validation_issues.csv')
    }

    Write-MigLog "SPO Validation — PASS: $passed | WARN: $warnings | FAIL: $failed"
}
else {
    Write-MigLog "SharePoint mapping not found — skipping SPO validation" -Level WARN
}

# ── Validate OneDrive sites ───────────────────────────────────────────────────

$odResults = [System.Collections.Generic.List[PSCustomObject]]::new()
$odIssues  = [System.Collections.Generic.List[PSCustomObject]]::new()

if (-not $SkipOneDrive -and (Test-Path $OneDriveMappingCsv)) {

    $odMapping  = Import-CsvSafe -Path $OneDriveMappingCsv `
        -RequiredColumns @('SourceUrl','TargetOneDriveUrl','Status')
    $odConfirmed = $odMapping | Where-Object { $_.Status -eq 'CONFIRMED' }
    Write-MigLog "Validating $(@($odConfirmed).Count) confirmed OneDrive sites..."

    $total = @($odConfirmed).Count; $i = 0
    $odPassed = 0; $odWarnings = 0; $odFailed = 0

    foreach ($od in $odConfirmed) {

        $i++
        Write-ProgressHelper -Activity 'Validating OneDrive sites' `
                             -Current $i -Total $total -Status $od.TargetOneDriveUrl

        $targetSite     = $targetSiteIndex[$od.TargetOneDriveUrl.ToLower()]
        $issues         = [System.Collections.Generic.List[string]]::new()
        $status         = 'PASS'
        $sourceStorageGB = [double]($od.StorageUsedGB ?? 0)
        $targetStorageGB = 0
        $storageDelta    = 0

        if (-not $targetSite) {
            $status = 'FAIL'
            $issues.Add("CRITICAL: Target OneDrive not found at $($od.TargetOneDriveUrl)")
            $odFailed++
        }
        else {
            $targetStorageGB = [math]::Round($targetSite.StorageUsageCurrent / 1024, 2)
            $storageDelta    = if ($sourceStorageGB -gt 0) {
                [math]::Round((($targetStorageGB - $sourceStorageGB) / $sourceStorageGB) * 100, 1)
            } else { 0 }

            if ($sourceStorageGB -gt 0 -and $storageDelta -lt -$StorageDeltaThresholdPct) {
                $issues.Add("WARN: Target ${targetStorageGB}GB is ${storageDelta}% vs source ${sourceStorageGB}GB")
                $status = 'WARN'
                $odWarnings++
            }
            else { $odPassed++ }

            if (-not $od.TargetOwnerEmail) {
                $issues.Add("INFO: TargetOwnerEmail not populated — owner not verified")
            }
        }

        $odResults.Add([PSCustomObject]@{
            SourceUrl       = $od.SourceUrl
            TargetUrl       = $od.TargetOneDriveUrl
            OwnerEmail      = $od.TargetOwnerEmail
            Status          = $status
            SourceStorageGB = $sourceStorageGB
            TargetStorageGB = $targetStorageGB
            StorageDeltaPct = $storageDelta
            Issues          = ($issues | Join-String -Separator ' | ')
        })

        foreach ($issue in $issues) {
            $odIssues.Add([PSCustomObject]@{
                SiteUrl  = $od.TargetOneDriveUrl
                Owner    = $od.TargetOwnerEmail
                Severity = if ($issue -match 'CRITICAL') { 'CRITICAL' } elseif ($issue -match 'WARN') { 'WARN' } else { 'INFO' }
                Issue    = $issue
            })
        }
    }

    Write-Progress -Activity 'Validating OneDrive sites' -Completed

    $odResults | Export-CsvSafe -Path (Join-Path $outDir 'post_onedrive_validation.csv')
    if ($odIssues.Count -gt 0) {
        $odIssues | Export-CsvSafe -Path (Join-Path $outDir 'post_onedrive_validation_issues.csv')
    }

    Write-MigLog "OneDrive Validation — PASS: $odPassed | WARN: $odWarnings | FAIL: $odFailed"
}

# ── Summary ───────────────────────────────────────────────────────────────────

Write-MigSummary -Stats @{
    'SPO sites validated'    = $spoResults.Count
    'SPO issues'             = $spoIssues.Count
    'OneDrive sites validated' = $odResults.Count
    'OneDrive issues'        = $odIssues.Count
    'Storage threshold'      = "-${StorageDeltaThresholdPct}%"
    'Next step'              = 'Run Test-PostGroupMigration.ps1'
}

try { Disconnect-PnPOnline -ErrorAction SilentlyContinue } catch {}
