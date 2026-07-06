#Requires -Version 5.1
#Requires -Modules Microsoft.Graph.Users, Microsoft.Graph.Identity.DirectoryManagement
<#
.SYNOPSIS
    Assigns licenses to target users in the Volue tenant based on the
    source license inventory and a SKU mapping file.

.DESCRIPTION
    Exchange Online mailboxes cannot receive migrated content unless the
    target user holds a license that includes Exchange Online (Plan 1 or
    Plan 2). This script must run — and licenses must propagate — before
    Code2 migration batches start.

    PROCESS
        1. Load licenses_sku_summary.csv   (Phase 1 inventory)
        2. Load sku_mapping.csv            (human-maintained: source SKU → target SKU)
           If sku_mapping.csv does not exist, the script generates a template
           and exits — fill it in then re-run.
        3. Load user_mapping_confirmed.csv (Phase 2)
        4. For each confirmed user, assign the mapped target SKU(s)
           - Skips users already licensed with that SKU
           - Respects disabled service plans from source
        5. Exports a license assignment results file

    SKU MAPPING FILE FORMAT (sku_mapping.csv)
        SourceSkuPartNumber, TargetSkuPartNumber, Notes
        ENTERPRISEPACK, ENTERPRISEPACK,
        SPE_E3, SPE_E3,
        ...
        Leave TargetSkuPartNumber blank to skip that SKU (won't be assigned).

    OUTPUTS
        MigrationData\sku_mapping.csv              (template — fill this in)
        MigrationData\license_assignment_results.csv
        MigrationData\license_assignment_errors.csv

.PARAMETER TargetTenantId
    AAD Tenant ID of the target tenant.

.PARAMETER TargetAdminUPN
    Admin UPN for the target tenant.

.PARAMETER SourceDomain
    Primary email domain of the source company. e.g. 'smartpulse.io'

.PARAMETER CompanySuffix
    Human-readable company name. e.g. 'SmartPulse'

.PARAMETER SkuMappingCsv
    Path to the human-maintained SKU mapping file.
    Default: .\MigrationData\sku_mapping.csv

.PARAMETER UserMappingCsv
    Confirmed user mapping.
    Default: .\MigrationData\user_mapping_confirmed.csv

.PARAMETER LicenseInventoryCsv
    Per-user license data from Phase 1.
    Default: .\MigrationData\licenses_by_user.csv

.PARAMETER WhatIf
    Show what would be assigned without making changes.

.PARAMETER OutputPath
    Output folder. Default: .\MigrationData

.EXAMPLE
    # First run — generates sku_mapping.csv template then exits
    .\Set-TargetLicenses.ps1 `
        -TargetTenantId 'volue.onmicrosoft.com' `
        -TargetAdminUPN 'admin@volue.com' `
        -SourceDomain   'smartpulse.io' `
        -CompanySuffix  'SmartPulse'

.EXAMPLE
    # After filling in sku_mapping.csv — WhatIf to preview
    .\Set-TargetLicenses.ps1 `
        -TargetTenantId 'volue.onmicrosoft.com' `
        -TargetAdminUPN 'admin@volue.com' `
        -SourceDomain   'smartpulse.io' `
        -CompanySuffix  'SmartPulse' `
        -WhatIf

.EXAMPLE
    # Live run
    .\Set-TargetLicenses.ps1 `
        -TargetTenantId 'volue.onmicrosoft.com' `
        -TargetAdminUPN 'admin@volue.com' `
        -SourceDomain   'smartpulse.io' `
        -CompanySuffix  'SmartPulse'
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    [string] $TargetTenantId = '',
    [string] $TargetAdminUPN = '',
    [string] $SourceDomain = '',
    [string] $CompanySuffix = '',
    [string] $SkuMappingCsv      = '.\MigrationData\sku_mapping.csv',
    [string] $UserMappingCsv     = '.\MigrationData\user_mapping_confirmed.csv',
    [string] $LicenseInventoryCsv = '.\MigrationData\licenses_by_user.csv',
    [string] $OutputPath         = '.\MigrationData'
)

# ── Bootstrap ─────────────────────────────────────────────────────────────────

Import-Module (Join-Path $PSScriptRoot '..\MigrationHelpers.psm1') -Force -ErrorAction Stop

# ── Load MigrationConfig.psd1 ────────────────────────────────────────────────
$_cfg = Import-MigrationConfig
$SourceDomain = Resolve-ConfigParam -Passed $SourceDomain -Default '' -ConfigValue (Get-ConfigValue -Config $_cfg -Key "SourceDomain")
$CompanySuffix = Resolve-ConfigParam -Passed $CompanySuffix -Default '' -ConfigValue (Get-ConfigValue -Config $_cfg -Key "CompanySuffix")
$TargetTenantId = Resolve-ConfigParam -Passed $TargetTenantId -Default '' -ConfigValue (Get-ConfigValue -Config $_cfg -Key "TargetTenantId")
$TargetAdminUPN = Resolve-ConfigParam -Passed $TargetAdminUPN -Default '' -ConfigValue (Get-ConfigValue -Config $_cfg -Key "TargetAdminUPN")
$UserMappingCsv = Resolve-ConfigParam -Passed $UserMappingCsv -Default '' -ConfigValue (Get-ConfigValue -Config $_cfg -Key "UserMappingCsv")
$SkuMappingCsv = Resolve-ConfigParam -Passed $SkuMappingCsv -Default '' -ConfigValue (Get-ConfigValue -Config $_cfg -Key "SkuMappingCsv")
$LicenseInventoryCsv = Resolve-ConfigParam -Passed $LicenseInventoryCsv -Default '' -ConfigValue (Get-ConfigValue -Config $_cfg -Key "LicenseInventoryCsv")
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
Initialize-MigLog -ScriptName 'Set-TargetLicenses' `
                  -LogDirectory (Join-Path $PSScriptRoot '..\Logs')
$outDir = Ensure-OutputDirectory -Path $OutputPath

# ── Load inputs ───────────────────────────────────────────────────────────────

$userMapping = Import-CsvSafe -Path $UserMappingCsv `
    -RequiredColumns @('SourceEmail','TargetEmail','TargetAADObjectId','Status')

$licenseData = Import-CsvSafe -Path $LicenseInventoryCsv `
    -RequiredColumns @('UserPrincipalName','SkuPartNumber','DisabledServicePlans')

# Build per-source-user license index: sourceEmail → list of { SkuPartNumber, DisabledPlans }
$sourceLicenseIndex = @{}
foreach ($row in $licenseData) {
    $key = $row.UserPrincipalName.ToLower()
    if (-not $sourceLicenseIndex.ContainsKey($key)) {
        $sourceLicenseIndex[$key] = [System.Collections.Generic.List[PSCustomObject]]::new()
    }
    $sourceLicenseIndex[$key].Add($row)
}

# ── SKU mapping file — generate template if missing ───────────────────────────

if (-not (Test-Path $SkuMappingCsv)) {

    Write-MigLog "sku_mapping.csv not found — generating template from license inventory" -Level WARN

    $skuSummaryPath = Join-Path $OutputPath 'licenses_sku_summary.csv'
    if (-not (Test-Path $skuSummaryPath)) {
        Write-MigLog "licenses_sku_summary.csv also not found. Run Get-LicenseInventory.ps1 first." -Level ERROR
        exit 1
    }

    $skuSummary = Import-CsvSafe -Path $skuSummaryPath
    $templateRows = $skuSummary | ForEach-Object {
        [PSCustomObject]@{
            SourceSkuPartNumber = $_.SkuPartNumber
            TargetSkuPartNumber = $_.SkuPartNumber   # pre-filled with same name — edit if different
            Notes               = "Source seats: $($_.ConsumedUnits) | Status: $($_.CapabilityStatus)"
        }
    }
    $templateRows | Export-CsvSafe -Path $SkuMappingCsv

    Write-MigLog ''
    Write-MigLog "ACTION REQUIRED:" -Level WARN
    Write-MigLog "  1. Open $SkuMappingCsv" -Level WARN
    Write-MigLog '  2. Set TargetSkuPartNumber for each source SKU' -Level WARN
    Write-MigLog '  3. Leave TargetSkuPartNumber blank to skip that SKU' -Level WARN
    Write-MigLog '  4. Re-run this script' -Level WARN
    exit 0
}

# Load and validate SKU mapping
$skuMapping = Import-CsvSafe -Path $SkuMappingCsv `
    -RequiredColumns @('SourceSkuPartNumber','TargetSkuPartNumber')

$skuMap = @{}
foreach ($row in $skuMapping) {
    if ($row.TargetSkuPartNumber) {
        $skuMap[$row.SourceSkuPartNumber] = $row.TargetSkuPartNumber
    }
    else {
        Write-MigLog "SKU skipped (no target mapping): $($row.SourceSkuPartNumber)" -Level INFO
    }
}
Write-MigLog "SKU mappings active: $($skuMap.Count)"

# ── Connect target tenant ─────────────────────────────────────────────────────

Connect-TargetTenant -TenantId $TargetTenantId -UserPrincipalName $TargetAdminUPN

# Get all target SKUs — need SkuId for the assignment API
$targetSkus = Invoke-WithRetry {
    Get-MgSubscribedSku -ErrorAction Stop
}
$targetSkuIndex = @{}   # PartNumber → { SkuId, ServicePlans }
foreach ($sku in $targetSkus) {
    $targetSkuIndex[$sku.SkuPartNumber] = $sku
}

# Get all currently licensed target users — to skip already-licensed ones
Write-MigLog "Building target user license index..."
$targetUsers = Invoke-WithRetry {
    Get-MgUser -All -Property 'Id,UserPrincipalName,AssignedLicenses' -ErrorAction Stop
}
$targetLicenseIndex = @{}
foreach ($u in $targetUsers) {
    $assignedSkuIds = $u.AssignedLicenses | ForEach-Object { $_.SkuId.ToString() }
    $targetLicenseIndex[$u.Id.ToLower()] = $assignedSkuIds
}

# ── Assign licenses ───────────────────────────────────────────────────────────

$resultRows = [System.Collections.Generic.List[PSCustomObject]]::new()
$errorRows  = [System.Collections.Generic.List[PSCustomObject]]::new()

$assigned  = 0
$skipped   = 0
$failed    = 0
$noLicense = 0

$total = $userMapping.Count
$i     = 0

foreach ($user in $userMapping) {

    $i++
    Write-ProgressHelper -Activity 'Assigning licenses' `
                         -Current $i -Total $total `
                         -Status $user.TargetEmail

    $sourceEmail  = $user.SourceEmail.ToLower()
    $targetObjId  = $user.TargetAADObjectId.ToLower()
    $targetEmail  = $user.TargetEmail

    # Get source SKUs for this user
    $sourceLicenses = $sourceLicenseIndex[$sourceEmail]
    if (-not $sourceLicenses -or $sourceLicenses.Count -eq 0) {
        Write-MigLog "No source licenses found for $sourceEmail — skipping" -Level WARN
        $noLicense++
        $resultRows.Add([PSCustomObject]@{
            TargetEmail  = $targetEmail
            SourceEmail  = $sourceEmail
            SkuAssigned  = ''
            Action       = 'SKIPPED_NO_SOURCE_LICENSE'
            WhatIf       = $WhatIfPreference
            Notes        = 'No license in source inventory'
        })
        continue
    }

    # Current target assignments
    $currentSkuIds = $targetLicenseIndex[$targetObjId] ?? @()

    foreach ($srcLic in $sourceLicenses) {

        $srcSku       = $srcLic.SkuPartNumber
        $targetSkuPartNumber = $skuMap[$srcSku]

        if (-not $targetSkuPartNumber) {
            Write-MigLog "  $targetEmail — SKU '$srcSku' has no target mapping — skipping" -Level DEBUG
            continue
        }

        $targetSkuDef = $targetSkuIndex[$targetSkuPartNumber]
        if (-not $targetSkuDef) {
            $failed++
            $errorRows.Add([PSCustomObject]@{
                TargetEmail = $targetEmail
                SourceEmail = $sourceEmail
                SourceSku   = $srcSku
                TargetSku   = $targetSkuPartNumber
                Error       = "Target SKU '$targetSkuPartNumber' not found in target tenant subscriptions"
            })
            Write-MigLog "Target SKU not found: $targetSkuPartNumber for $targetEmail" -Level ERROR
            continue
        }

        # Already licensed?
        if ($currentSkuIds -contains $targetSkuDef.SkuId.ToString()) {
            $skipped++
            Write-MigLog "  $targetEmail already has $targetSkuPartNumber — skipping" -Level DEBUG
            $resultRows.Add([PSCustomObject]@{
                TargetEmail  = $targetEmail
                SourceEmail  = $sourceEmail
                SkuAssigned  = $targetSkuPartNumber
                Action       = 'ALREADY_LICENSED'
                WhatIf       = $false
                Notes        = 'Already had this SKU — no change made'
            })
            continue
        }

        # Build disabled service plans list
        $disabledPlanIds = [System.Collections.Generic.List[string]]::new()
        if ($srcLic.DisabledServicePlans) {
            foreach ($planId in ($srcLic.DisabledServicePlans -split '\|')) {
                if ($planId) { $disabledPlanIds.Add($planId.Trim()) }
            }
        }

        # Assign
        if ($PSCmdlet.ShouldProcess($targetEmail, "Assign license $targetSkuPartNumber")) {
            try {
                $licenseBody = @{
                    AddLicenses = @(
                        @{
                            SkuId         = $targetSkuDef.SkuId
                            DisabledPlans = $disabledPlanIds.ToArray()
                        }
                    )
                    RemoveLicenses = @()
                }

                Invoke-WithRetry {
                    Set-MgUserLicense -UserId $targetObjId -BodyParameter $licenseBody `
                                      -ErrorAction Stop | Out-Null
                }

                $assigned++
                Write-MigLog "  ASSIGNED: $targetEmail ← $targetSkuPartNumber"

                $resultRows.Add([PSCustomObject]@{
                    TargetEmail  = $targetEmail
                    SourceEmail  = $sourceEmail
                    SkuAssigned  = $targetSkuPartNumber
                    Action       = 'ASSIGNED'
                    WhatIf       = $false
                    Notes        = ''
                })
            }
            catch {
                $failed++
                Write-MigLog "  FAILED: $targetEmail ← $targetSkuPartNumber — $_" -Level ERROR
                $errorRows.Add([PSCustomObject]@{
                    TargetEmail = $targetEmail
                    SourceEmail = $sourceEmail
                    SourceSku   = $srcSku
                    TargetSku   = $targetSkuPartNumber
                    Error       = $_.Exception.Message
                })
            }
        }
        else {
            # WhatIf
            $skipped++
            Write-MigLog "  WHATIF: Would assign $targetSkuPartNumber to $targetEmail"
            $resultRows.Add([PSCustomObject]@{
                TargetEmail  = $targetEmail
                SourceEmail  = $sourceEmail
                SkuAssigned  = $targetSkuPartNumber
                Action       = 'WHATIF'
                WhatIf       = $true
                Notes        = 'WhatIf — no change made'
            })
        }
    }
}

Write-Progress -Activity 'Assigning licenses' -Completed

# ── Export ────────────────────────────────────────────────────────────────────

$resultRows | Export-CsvSafe -Path (Join-Path $outDir 'license_assignment_results.csv')
if ($errorRows.Count -gt 0) {
    $errorRows | Export-CsvSafe -Path (Join-Path $outDir 'license_assignment_errors.csv')
}

# ── Summary ───────────────────────────────────────────────────────────────────

Write-MigSummary -Stats @{
    'Users processed'        = $total
    'Licenses assigned'      = $assigned
    'Already licensed'       = $skipped
    'No source license'      = $noLicense
    'Errors'                 = $failed
    'WhatIf mode'            = $WhatIfPreference
    'Next script'            = 'New-SharedMailboxes.ps1'
}

if ($failed -gt 0) {
    Write-MigLog "ACTION REQUIRED: $failed assignment(s) failed — check license_assignment_errors.csv" -Level ERROR
}

Disconnect-AllTenants
