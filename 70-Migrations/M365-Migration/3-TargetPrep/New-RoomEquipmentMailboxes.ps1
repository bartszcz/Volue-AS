#Requires -Version 5.1
#Requires -Modules ExchangeOnlineManagement
<#
.SYNOPSIS
    Creates room and equipment mailboxes in the TARGET tenant from the
    Phase 1 mailbox inventory.

.DESCRIPTION
    Room and equipment mailboxes are not covered by Code2 (content is
    typically not migrated — calendars are rebuilt from scratch or by
    migrating relevant calendar items). This script creates the resource
    mailboxes so they exist at the target before go-live.

    Source data comes from mailboxes.csv (Phase 1 inventory) for
    RoomMailbox and EquipmentMailbox types.

    NAMING CONVENTION
        Display name: "{SourceName} {CompanySuffix}"
        Email:        Human-populated in room_equipment_mapping.csv

    On first run the script generates room_equipment_mapping.csv as a
    review template — humans populate TargetEmail and TargetDisplayName,
    then re-run to create.

    IDEMPOTENT — existing mailboxes are validated and skipped.

    OUTPUTS
        MigrationData\room_equipment_mapping.csv        (template / updated)
        MigrationData\room_equipment_creation_results.csv
        MigrationData\room_equipment_creation_errors.csv

.PARAMETER TargetTenantId
    AAD Tenant ID of the target tenant.

.PARAMETER TargetAdminUPN
    Admin UPN for the target tenant.

.PARAMETER SourceDomain
    Primary email domain of the source company. e.g. 'smartpulse.io'

.PARAMETER CompanySuffix
    Human-readable company name. e.g. 'SmartPulse'

.PARAMETER MailboxCsv
    Phase 1 mailbox inventory.
    Default: .\MigrationData\mailboxes.csv

.PARAMETER RoomEquipmentMappingCsv
    Review/mapping file. Generated on first run if absent.
    Default: .\MigrationData\room_equipment_mapping.csv

.PARAMETER ProvisioningWaitSeconds
    Seconds to wait after each mailbox creation. Default: 45

.PARAMETER WhatIf
    Show what would be created without making changes.

.PARAMETER OutputPath
    Output folder. Default: .\MigrationData

.EXAMPLE
    # First run — generates template
    .\New-RoomEquipmentMailboxes.ps1 `
        -TargetTenantId 'volue.onmicrosoft.com' `
        -TargetAdminUPN 'admin@volue.com' `
        -SourceDomain   'smartpulse.io' `
        -CompanySuffix  'SmartPulse'

.EXAMPLE
    # After populating room_equipment_mapping.csv
    .\New-RoomEquipmentMailboxes.ps1 `
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
    [string] $MailboxCsv                  = '.\MigrationData\mailboxes.csv',
    [string] $RoomEquipmentMappingCsv     = '.\MigrationData\room_equipment_mapping.csv',
    [int]    $ProvisioningWaitSeconds     = 45,
    [string] $OutputPath                  = '.\MigrationData'
)

# ── Bootstrap ─────────────────────────────────────────────────────────────────

Import-Module (Join-Path $PSScriptRoot '..\MigrationHelpers.psm1') -Force -ErrorAction Stop

# ── Load MigrationConfig.psd1 ────────────────────────────────────────────────
$_cfg = Import-MigrationConfig
$SourceDomain = Resolve-ConfigParam -Passed $SourceDomain -Default '' -ConfigValue (Get-ConfigValue -Config $_cfg -Key "SourceDomain")
$CompanySuffix = Resolve-ConfigParam -Passed $CompanySuffix -Default '' -ConfigValue (Get-ConfigValue -Config $_cfg -Key "CompanySuffix")
$TargetTenantId = Resolve-ConfigParam -Passed $TargetTenantId -Default '' -ConfigValue (Get-ConfigValue -Config $_cfg -Key "TargetTenantId")
$TargetAdminUPN = Resolve-ConfigParam -Passed $TargetAdminUPN -Default '' -ConfigValue (Get-ConfigValue -Config $_cfg -Key "TargetAdminUPN")
$RoomEquipmentMappingCsv = Resolve-ConfigParam -Passed $RoomEquipmentMappingCsv -Default '' -ConfigValue (Get-ConfigValue -Config $_cfg -Key "RoomEquipmentMappingCsv")
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
Initialize-MigLog -ScriptName 'New-RoomEquipmentMailboxes' `
                  -LogDirectory (Join-Path $PSScriptRoot '..\Logs')
$outDir  = Ensure-OutputDirectory -Path $OutputPath
$domains = Get-MigrationDomains

# ── Generate mapping template if absent ──────────────────────────────────────

if (-not (Test-Path $RoomEquipmentMappingCsv)) {

    Write-MigLog "room_equipment_mapping.csv not found — generating template" -Level WARN

    $mbxData   = Import-CsvSafe -Path $MailboxCsv `
        -RequiredColumns @('PrimarySmtpAddress','DisplayName','MailboxType')
    $resources = $mbxData | Where-Object { $_.MailboxType -in @('RoomMailbox','EquipmentMailbox') }

    $templateRows = $resources | ForEach-Object {
        [PSCustomObject]@{
            SourceEmail          = $_.PrimarySmtpAddress
            SourceDisplayName    = $_.DisplayName
            SourceMailboxType    = $_.MailboxType
            SourceAADObjectId    = $_.ExternalDirectoryObjectId
            TargetEmail          = ''   # HUMAN FILLS
            TargetDisplayName    = "$($_.DisplayName) $($domains.CompanySuffix)"  # suggested
            TargetMailboxType    = $_.MailboxType
            TargetAADObjectId    = ''
            Status               = 'NEEDS_REVIEW'
            Notes                = ''
        }
    }

    $templateRows | Export-CsvSafe -Path $RoomEquipmentMappingCsv

    Write-MigLog ''
    Write-MigLog "ACTION REQUIRED:" -Level WARN
    Write-MigLog "  1. Open $RoomEquipmentMappingCsv" -Level WARN
    Write-MigLog '  2. Populate TargetEmail for each resource mailbox' -Level WARN
    Write-MigLog '  3. Verify TargetDisplayName' -Level WARN
    Write-MigLog '  4. Set Status=CONFIRMED' -Level WARN
    Write-MigLog '  5. Re-run this script' -Level WARN
    Write-MigLog "  Template written: $($templateRows.Count) resources" -Level INFO
    exit 0
}

# ── Load confirmed rows ───────────────────────────────────────────────────────

$allRows       = Import-CsvSafe -Path $RoomEquipmentMappingCsv `
    -RequiredColumns @('SourceEmail','TargetEmail','TargetDisplayName','TargetMailboxType','Status')
$confirmedRows = $allRows | Where-Object { $_.Status -eq 'CONFIRMED' }
Write-MigLog "Confirmed resources to create: $($confirmedRows.Count)"

if ($confirmedRows.Count -eq 0) {
    Write-MigLog "No CONFIRMED rows — set Status=CONFIRMED in $RoomEquipmentMappingCsv" -Level WARN
    exit 0
}

# ── Connect ───────────────────────────────────────────────────────────────────

Connect-TargetTenant -TenantId $TargetTenantId -UserPrincipalName $TargetAdminUPN

$existingResources = Invoke-WithRetry {
    Get-Mailbox -RecipientTypeDetails RoomMailbox, EquipmentMailbox `
                -ResultSize Unlimited -ErrorAction Stop
}
$existingIndex = @{}
foreach ($r in $existingResources) {
    $existingIndex[$r.PrimarySmtpAddress.ToLower()] = $r
}

# ── Creation loop ─────────────────────────────────────────────────────────────

$resultRows = [System.Collections.Generic.List[PSCustomObject]]::new()
$errorRows  = [System.Collections.Generic.List[PSCustomObject]]::new()
$created    = 0; $existing = 0; $failed = 0

$updatedMapping = [System.Collections.Generic.List[PSCustomObject]]::new()
foreach ($r in $allRows) { $updatedMapping.Add($r) }

$total = $confirmedRows.Count
$i     = 0

foreach ($row in $confirmedRows) {

    $i++
    Write-ProgressHelper -Activity 'Creating resource mailboxes' `
                         -Current $i -Total $total `
                         -Status $row.TargetEmail

    $targetEmail = $row.TargetEmail.ToLower()
    $targetName  = $row.TargetDisplayName
    $targetAlias = ($targetEmail -split '@')[0]
    $isRoom      = $row.TargetMailboxType -eq 'RoomMailbox'

    if ($existingIndex.ContainsKey($targetEmail)) {
        $existing++
        Write-MigLog "  EXISTS: $targetEmail"
        $mapRow = $updatedMapping | Where-Object { $_.SourceEmail -eq $row.SourceEmail }
        if ($mapRow) { $mapRow.TargetAADObjectId = $existingIndex[$targetEmail].ExternalDirectoryObjectId }
        $resultRows.Add([PSCustomObject]@{
            SourceEmail       = $row.SourceEmail
            TargetEmail       = $targetEmail
            TargetDisplayName = $targetName
            MailboxType       = $row.TargetMailboxType
            TargetAADObjectId = $existingIndex[$targetEmail].ExternalDirectoryObjectId
            Action            = 'ALREADY_EXISTS'
            WhatIf            = $false
            Notes             = ''
        })
        continue
    }

    if ($PSCmdlet.ShouldProcess($targetEmail, "Create $($row.TargetMailboxType) '$targetName'")) {
        try {
            $newMbx = if ($isRoom) {
                Invoke-WithRetry {
                    New-Mailbox -Room `
                                -Name               $targetName `
                                -DisplayName        $targetName `
                                -Alias              $targetAlias `
                                -PrimarySmtpAddress $targetEmail `
                                -ErrorAction Stop
                }
            }
            else {
                Invoke-WithRetry {
                    New-Mailbox -Equipment `
                                -Name               $targetName `
                                -DisplayName        $targetName `
                                -Alias              $targetAlias `
                                -PrimarySmtpAddress $targetEmail `
                                -ErrorAction Stop
                }
            }

            Write-MigLog "  CREATED: $($row.TargetMailboxType) $targetEmail"
            Start-Sleep -Seconds $ProvisioningWaitSeconds

            $prov   = Invoke-WithRetry { Get-Mailbox -Identity $targetEmail -ErrorAction Stop }
            $objId  = $prov.ExternalDirectoryObjectId

            $mapRow = $updatedMapping | Where-Object { $_.SourceEmail -eq $row.SourceEmail }
            if ($mapRow) { $mapRow.TargetAADObjectId = $objId }

            $created++
            $resultRows.Add([PSCustomObject]@{
                SourceEmail       = $row.SourceEmail
                TargetEmail       = $targetEmail
                TargetDisplayName = $targetName
                MailboxType       = $row.TargetMailboxType
                TargetAADObjectId = $objId
                Action            = 'CREATED'
                WhatIf            = $false
                Notes             = ''
            })
        }
        catch {
            $failed++
            Write-MigLog "  FAILED: $targetEmail — $_" -Level ERROR
            $errorRows.Add([PSCustomObject]@{
                SourceEmail = $row.SourceEmail
                TargetEmail = $targetEmail
                Error       = $_.Exception.Message
            })
        }
    }
    else {
        Write-MigLog "  WHATIF: Would create $($row.TargetMailboxType) '$targetName' <$targetEmail>"
        $resultRows.Add([PSCustomObject]@{
            SourceEmail       = $row.SourceEmail
            TargetEmail       = $targetEmail
            TargetDisplayName = $targetName
            MailboxType       = $row.TargetMailboxType
            TargetAADObjectId = ''
            Action            = 'WHATIF'
            WhatIf            = $true
            Notes             = ''
        })
    }
}

Write-Progress -Activity 'Creating resource mailboxes' -Completed

$updatedMapping | Export-CsvSafe -Path $RoomEquipmentMappingCsv
$resultRows     | Export-CsvSafe -Path (Join-Path $outDir 'room_equipment_creation_results.csv')
if ($errorRows.Count -gt 0) {
    $errorRows  | Export-CsvSafe -Path (Join-Path $outDir 'room_equipment_creation_errors.csv')
}

Write-MigSummary -Stats @{
    'Total confirmed'   = $total
    'Created'           = $created
    'Already existed'   = $existing
    'Failed'            = $failed
    'WhatIf mode'       = $WhatIfPreference
    'Next script'       = 'New-DistributionGroups.ps1'
}

Disconnect-AllTenants
