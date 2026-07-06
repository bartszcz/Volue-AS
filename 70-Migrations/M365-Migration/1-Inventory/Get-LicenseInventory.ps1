#Requires -Version 5.1
#Requires -Modules Microsoft.Graph.Users, Microsoft.Graph.Identity.DirectoryManagement
<#
.SYNOPSIS
    Exports license assignments from the SOURCE tenant.

.DESCRIPTION
    Collects per-user SKU assignments and service plan states.
    Used to ensure target users have equivalent licenses assigned before
    Code2 migration begins (mailboxes can't be migrated to unlicensed users).

    Also produces a SKU summary showing which SKUs exist in the source
    and how many seats are assigned — used for license procurement planning
    at the target tenant.

    Outputs:
        MigrationData\licenses_by_user.csv     — one row per user per SKU
        MigrationData\licenses_sku_summary.csv — one row per SKU with counts
        MigrationData\licenses_unlicensed.csv  — user mailboxes with no license

.PARAMETER SourceTenantId
    AAD Tenant ID of the source tenant.

.PARAMETER SourceAdminUPN
    Source tenant admin UPN.

.PARAMETER SourceDomain
    Primary email domain of the source company. e.g. 'smartpulse.io'

.PARAMETER CompanySuffix
    Human-readable company name. e.g. 'SmartPulse'

.PARAMETER MailboxCsv
    Path to mailboxes.csv — used to cross-reference user mailboxes.
    Default: .\MigrationData\mailboxes.csv

.PARAMETER OutputPath
    Output folder. Default: .\MigrationData

.EXAMPLE
    .\Get-LicenseInventory.ps1 `
        -SourceTenantId 'balancingpoolcom.onmicrosoft.com' `
        -SourceAdminUPN 'admin@smartpulse.io' `
        -SourceDomain   'smartpulse.io' `
        -CompanySuffix  'SmartPulse'
#>

[CmdletBinding()]
param(
    [string] $SourceTenantId = '',
    [string] $SourceAdminUPN = '',
    [string] $SourceDomain = '',
    [string] $CompanySuffix = '',
    [string] $MailboxCsv  = '.\MigrationData\mailboxes.csv',
    [string] $OutputPath  = '.\MigrationData'
)

# ── Bootstrap ─────────────────────────────────────────────────────────────────

Import-Module (Join-Path $PSScriptRoot '..\MigrationHelpers.psm1') -Force -ErrorAction Stop

# ── Load MigrationConfig.psd1 ────────────────────────────────────────────────
$_cfg = Import-MigrationConfig
$SourceTenantId = Resolve-ConfigParam -Passed $SourceTenantId -Default '' -ConfigValue (Get-ConfigValue -Config $_cfg -Key "SourceTenantId")
$SourceAdminUPN = Resolve-ConfigParam -Passed $SourceAdminUPN -Default '' -ConfigValue (Get-ConfigValue -Config $_cfg -Key "SourceAdminUPN")
$SourceDomain = Resolve-ConfigParam -Passed $SourceDomain -Default '' -ConfigValue (Get-ConfigValue -Config $_cfg -Key "SourceDomain")
$CompanySuffix = Resolve-ConfigParam -Passed $CompanySuffix -Default '' -ConfigValue (Get-ConfigValue -Config $_cfg -Key "CompanySuffix")
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

Initialize-MigLog -ScriptName 'Get-LicenseInventory' `
                  -LogDirectory (Join-Path $PSScriptRoot '..\Logs')

$outDir = Ensure-OutputDirectory -Path $OutputPath

# ── Load mailbox inventory for cross-reference ────────────────────────────────

$mailboxes = Import-CsvSafe -Path $MailboxCsv `
    -RequiredColumns @('PrimarySmtpAddress','DisplayName','ExternalDirectoryObjectId')

$userMailboxes = $mailboxes | Where-Object { $_.MailboxType -eq 'UserMailbox' }
Write-MigLog "User mailboxes to cross-reference: $($userMailboxes.Count)"

# Index by AAD ObjectId for fast lookup
$mbxByObjectId = @{}
foreach ($m in $userMailboxes) {
    if ($m.ExternalDirectoryObjectId) {
        $mbxByObjectId[$m.ExternalDirectoryObjectId.ToLower()] = $m
    }
}

# ── Connect ───────────────────────────────────────────────────────────────────

Connect-SourceTenant -TenantId $SourceTenantId -UserPrincipalName $SourceAdminUPN

# ── Get all SKU definitions for friendly name resolution ─────────────────────

Write-MigLog "Retrieving subscribed SKUs..."
$subscribedSkus = Invoke-WithRetry {
    Get-MgSubscribedSku -ErrorAction Stop
}

# Build SKU part number lookup: SkuId → SkuPartNumber
$skuNames = @{}
foreach ($sku in $subscribedSkus) {
    $skuNames[$sku.SkuId] = $sku.SkuPartNumber
}
Write-MigLog "SKUs in tenant: $($subscribedSkus.Count)"

# ── Retrieve all licensed users ───────────────────────────────────────────────

Write-MigLog "Retrieving all AAD users with license details..."
$aadUsers = Invoke-WithRetry {
    Get-MgUser -All `
        -Property 'Id,UserPrincipalName,DisplayName,AssignedLicenses,LicenseAssignmentStates' `
        -ErrorAction Stop
}
Write-MigLog "AAD users retrieved: $($aadUsers.Count)"

# ── Build per-user license rows ───────────────────────────────────────────────

$licenseRows  = [System.Collections.Generic.List[PSCustomObject]]::new()
$skuCounter   = @{}   # SkuPartNumber → count of assigned users
$unlicensed   = [System.Collections.Generic.List[PSCustomObject]]::new()

$total = $aadUsers.Count
$i     = 0

foreach ($user in $aadUsers) {

    $i++
    Write-ProgressHelper -Activity 'Processing licenses' `
                         -Current $i -Total $total `
                         -Status $user.UserPrincipalName

    # Cross-reference with mailbox inventory
    $hasMbx     = $mbxByObjectId.ContainsKey($user.Id.ToLower())
    $mbxDetails = $mbxByObjectId[$user.Id.ToLower()]

    if ($user.AssignedLicenses.Count -eq 0) {

        # No license — flag if this user has a mailbox
        if ($hasMbx) {
            $unlicensed.Add([PSCustomObject]@{
                UserPrincipalName = $user.UserPrincipalName
                DisplayName       = $user.DisplayName
                AADObjectId       = $user.Id
                MailboxType       = $mbxDetails.MailboxType
                Note              = 'User mailbox exists but no AAD license assigned'
            })
            Write-MigLog "Unlicensed user with mailbox: $($user.UserPrincipalName)" -Level WARN
        }
        continue
    }

    foreach ($lic in $user.AssignedLicenses) {

        $skuPartNumber = $skuNames[$lic.SkuId] ?? $lic.SkuId

        # Count assignments per SKU
        if (-not $skuCounter.ContainsKey($skuPartNumber)) {
            $skuCounter[$skuPartNumber] = 0
        }
        $skuCounter[$skuPartNumber]++

        # Determine which service plans are enabled vs disabled
        $enabledPlans  = [System.Collections.Generic.List[string]]::new()
        $disabledPlans = [System.Collections.Generic.List[string]]::new()

        # AssignedLicenses doesn't include plan detail — get from LicenseAssignmentStates
        $assignmentState = $user.LicenseAssignmentStates |
            Where-Object { $_.SkuId -eq $lic.SkuId } |
            Select-Object -First 1

        if ($assignmentState) {
            foreach ($planId in $assignmentState.DisabledPlans) {
                $disabledPlans.Add($planId.ToString())
            }
        }

        $licenseRows.Add([PSCustomObject]@{
            UserPrincipalName  = $user.UserPrincipalName
            DisplayName        = $user.DisplayName
            AADObjectId        = $user.Id
            HasMailbox         = $hasMbx
            MailboxType        = $mbxDetails?.MailboxType ?? ''
            SkuId              = $lic.SkuId
            SkuPartNumber      = $skuPartNumber
            DisabledServicePlans = $disabledPlans -join '|'
            AssignmentType     = if ($assignmentState.AssignedByGroup) { 'Group' } else { 'Direct' }
            AssignedByGroup    = $assignmentState?.AssignedByGroup ?? ''
            # Migration fields
            TargetSkuPartNumber = ''    # filled during license mapping — SKU names may differ
            MigrationStatus     = 'PENDING'
            Notes               = ''
        })
    }
}

Write-Progress -Activity 'Processing licenses' -Completed

# ── Build SKU summary ─────────────────────────────────────────────────────────

$skuSummary = [System.Collections.Generic.List[PSCustomObject]]::new()

foreach ($sku in $subscribedSkus) {
    $partNumber  = $sku.SkuPartNumber
    $assigned    = $skuCounter[$partNumber] ?? 0

    $skuSummary.Add([PSCustomObject]@{
        SkuId              = $sku.SkuId
        SkuPartNumber      = $partNumber
        CapabilityStatus   = $sku.CapabilityStatus
        ConsumedUnits      = $sku.ConsumedUnits
        EnabledUnits       = $sku.PrepaidUnits.Enabled
        WarningUnits       = $sku.PrepaidUnits.Warning
        SuspendedUnits     = $sku.PrepaidUnits.Suspended
        AssignedToUsers    = $assigned
        # Migration planning fields
        TargetSkuPartNumber = ''   # human maps source SKU → target SKU equivalent
        TargetUnitsNeeded   = $assigned
        Notes               = ''
    })
}

# ── Export ────────────────────────────────────────────────────────────────────

$licPath = Join-Path $outDir 'licenses_by_user.csv'
$licenseRows | Export-CsvSafe -Path $licPath

$skuSummary | Export-CsvSafe -Path (Join-Path $outDir 'licenses_sku_summary.csv')

if ($unlicensed.Count -gt 0) {
    $unlicensed | Export-CsvSafe -Path (Join-Path $outDir 'licenses_unlicensed.csv')
}

# ── Summary ───────────────────────────────────────────────────────────────────

$mbxUserCount = ($licenseRows | Where-Object { $_.HasMailbox -eq $true } |
    Select-Object -ExpandProperty UserPrincipalName -Unique).Count

Write-MigSummary -Stats @{
    'Licensed AAD users'          = ($licenseRows | Select-Object -ExpandProperty UserPrincipalName -Unique).Count
    'Licensed mailbox users'      = $mbxUserCount
    'Unlicensed mailbox users'    = $unlicensed.Count
    'Distinct SKUs in use'        = $skuCounter.Keys.Count
    'SKU breakdown'               = ($skuCounter.GetEnumerator() | ForEach-Object { "$($_.Key)=$($_.Value)" }) -join ' | '
    'License rows exported'       = $licenseRows.Count
    'Output'                      = $licPath
    'Next script'                 = 'Get-DistributionGroupInventory.ps1'
}

Disconnect-AllTenants
