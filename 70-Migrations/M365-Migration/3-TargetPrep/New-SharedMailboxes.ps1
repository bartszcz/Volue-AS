#Requires -Version 5.1
#Requires -Modules ExchangeOnlineManagement, Microsoft.Graph.Users
<#
.SYNOPSIS
    Creates shared mailboxes in the TARGET tenant from confirmed mapping.

.DESCRIPTION
    Reads shared_mailbox_mapping.csv (Status=CONFIRMED rows only) and
    creates each shared mailbox in the Volue Exchange Online tenant.

    For each mailbox:
        - Creates the mailbox with target display name and email
        - Sets HiddenFromAddressLists if source was hidden
        - Disables automatic licensing (shared mailboxes don't need a
          user license — they use the shared mailbox licence type)
        - Waits for the mailbox to fully provision before moving on
        - Writes the resulting AAD Object ID back to the mapping CSV
          (required for Code2 batch file generation)

    IDEMPOTENT — if a mailbox with the target email already exists,
    the script validates it and records the existing Object ID rather
    than throwing.

    OUTPUTS
        MigrationData\shared_mailbox_mapping.csv    (updated with TargetAADObjectId)
        MigrationData\shared_mailbox_creation_results.csv
        MigrationData\shared_mailbox_creation_errors.csv

.PARAMETER TargetTenantId
    AAD Tenant ID of the target tenant.

.PARAMETER TargetAdminUPN
    Admin UPN for the target tenant.

.PARAMETER SourceDomain
    Primary email domain of the source company. e.g. 'smartpulse.io'

.PARAMETER CompanySuffix
    Human-readable company name. e.g. 'SmartPulse'

.PARAMETER SharedMappingCsv
    Confirmed shared mailbox mapping.
    Default: .\MigrationData\shared_mailbox_mapping.csv

.PARAMETER ProvisioningWaitSeconds
    Seconds to wait after creating each mailbox before continuing.
    Exchange Online provisioning can take 30–120 seconds. Default: 60

.PARAMETER WhatIf
    Show what would be created without making changes.

.PARAMETER OutputPath
    Output folder. Default: .\MigrationData

.EXAMPLE
    .\New-SharedMailboxes.ps1 `
        -TargetTenantId 'volue.onmicrosoft.com' `
        -TargetAdminUPN 'admin@volue.com' `
        -SourceDomain   'smartpulse.io' `
        -CompanySuffix  'SmartPulse' `
        -WhatIf

.EXAMPLE
    .\New-SharedMailboxes.ps1 `
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
    [string] $SharedMappingCsv         = '.\MigrationData\shared_mailbox_mapping.csv',
    [int]    $ProvisioningWaitSeconds  = 60,
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
$SharedMappingCsv = Resolve-ConfigParam -Passed $SharedMappingCsv -Default '' -ConfigValue (Get-ConfigValue -Config $_cfg -Key "SharedMappingCsv")
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
Initialize-MigLog -ScriptName 'New-SharedMailboxes' `
                  -LogDirectory (Join-Path $PSScriptRoot '..\Logs')
$outDir = Ensure-OutputDirectory -Path $OutputPath

# ── Load mapping ──────────────────────────────────────────────────────────────

$allRows       = Import-CsvSafe -Path $SharedMappingCsv `
    -RequiredColumns @('SourceEmail','TargetEmail','TargetDisplayName','Status')

$confirmedRows = $allRows | Where-Object { $_.Status -eq 'CONFIRMED' }
Write-MigLog "Confirmed shared mailboxes to create: $($confirmedRows.Count)"

if ($confirmedRows.Count -eq 0) {
    Write-MigLog "No CONFIRMED rows in $SharedMappingCsv — nothing to create." -Level WARN
    exit 0
}

# ── Connect ───────────────────────────────────────────────────────────────────

Connect-TargetTenant -TenantId $TargetTenantId -UserPrincipalName $TargetAdminUPN

# Build index of existing mailboxes to support idempotency
Write-MigLog "Building existing mailbox index..."
$existingMailboxes = Invoke-WithRetry {
    Get-Mailbox -RecipientTypeDetails SharedMailbox -ResultSize Unlimited -ErrorAction Stop
}
$existingIndex = @{}
foreach ($m in $existingMailboxes) {
    $existingIndex[$m.PrimarySmtpAddress.ToLower()] = $m
}
Write-MigLog "Existing shared mailboxes in target: $($existingIndex.Count)"

# ── Creation loop ─────────────────────────────────────────────────────────────

$resultRows = [System.Collections.Generic.List[PSCustomObject]]::new()
$errorRows  = [System.Collections.Generic.List[PSCustomObject]]::new()

$created  = 0
$existing = 0
$failed   = 0

$total = $confirmedRows.Count
$i     = 0

# We'll update the CSV in memory and re-export at the end
$updatedMapping = [System.Collections.Generic.List[PSCustomObject]]::new()
foreach ($r in $allRows) { $updatedMapping.Add($r) }

foreach ($row in $confirmedRows) {

    $i++
    Write-ProgressHelper -Activity 'Creating shared mailboxes' `
                         -Current $i -Total $total `
                         -Status $row.TargetEmail

    $targetEmail   = $row.TargetEmail.ToLower()
    $targetName    = $row.TargetDisplayName
    $targetAlias   = $row.TargetAlias ?? ($targetEmail -split '@')[0]
    $hideFromGAL   = $row.HiddenFromGAL -eq $true -or $row.HiddenFromGAL -eq 'True'

    # ── Idempotency check ─────────────────────────────────────────────────────

    if ($existingIndex.ContainsKey($targetEmail)) {

        $existingMbx = $existingIndex[$targetEmail]
        $existing++
        Write-MigLog "  EXISTS: $targetEmail — recording existing Object ID"

        # Write Object ID back to mapping row
        $mapRow = $updatedMapping | Where-Object { $_.SourceEmail -eq $row.SourceEmail }
        if ($mapRow) {
            $mapRow.TargetAADObjectId = $existingMbx.ExternalDirectoryObjectId
        }

        $resultRows.Add([PSCustomObject]@{
            SourceEmail        = $row.SourceEmail
            TargetEmail        = $targetEmail
            TargetDisplayName  = $targetName
            TargetAADObjectId  = $existingMbx.ExternalDirectoryObjectId
            Action             = 'ALREADY_EXISTS'
            WhatIf             = $false
            Notes              = 'Mailbox already existed — Object ID recorded'
        })
        continue
    }

    # ── Create ────────────────────────────────────────────────────────────────

    if ($PSCmdlet.ShouldProcess($targetEmail, "Create shared mailbox '$targetName'")) {
        try {
            $newMbx = Invoke-WithRetry {
                New-Mailbox -Shared `
                            -Name          $targetName `
                            -DisplayName   $targetName `
                            -Alias         $targetAlias `
                            -PrimarySmtpAddress $targetEmail `
                            -ErrorAction Stop
            }

            Write-MigLog "  CREATED: $targetEmail"

            # Set HiddenFromAddressLists if required
            if ($hideFromGAL) {
                Invoke-WithRetry {
                    Set-Mailbox -Identity $targetEmail `
                                -HiddenFromAddressListsEnabled $true `
                                -ErrorAction Stop
                }
                Write-MigLog "  HIDDEN: $targetEmail hidden from GAL"
            }

            # Wait for provisioning — AAD Object ID won't be available immediately
            Write-MigLog "  Waiting ${ProvisioningWaitSeconds}s for provisioning..."
            Start-Sleep -Seconds $ProvisioningWaitSeconds

            # Retrieve the provisioned mailbox to get the Object ID
            $provisionedMbx = Invoke-WithRetry {
                Get-Mailbox -Identity $targetEmail -ErrorAction Stop
            }
            $targetObjId = $provisionedMbx.ExternalDirectoryObjectId

            # Write Object ID back to mapping
            $mapRow = $updatedMapping | Where-Object { $_.SourceEmail -eq $row.SourceEmail }
            if ($mapRow) { $mapRow.TargetAADObjectId = $targetObjId }

            $created++
            $resultRows.Add([PSCustomObject]@{
                SourceEmail       = $row.SourceEmail
                TargetEmail       = $targetEmail
                TargetDisplayName = $targetName
                TargetAADObjectId = $targetObjId
                Action            = 'CREATED'
                WhatIf            = $false
                Notes             = ''
            })
        }
        catch {
            $failed++
            Write-MigLog "  FAILED: $targetEmail — $_" -Level ERROR
            $errorRows.Add([PSCustomObject]@{
                SourceEmail       = $row.SourceEmail
                TargetEmail       = $targetEmail
                TargetDisplayName = $targetName
                Error             = $_.Exception.Message
            })
        }
    }
    else {
        # WhatIf
        Write-MigLog "  WHATIF: Would create shared mailbox '$targetName' <$targetEmail>"
        $resultRows.Add([PSCustomObject]@{
            SourceEmail       = $row.SourceEmail
            TargetEmail       = $targetEmail
            TargetDisplayName = $targetName
            TargetAADObjectId = ''
            Action            = 'WHATIF'
            WhatIf            = $true
            Notes             = 'WhatIf — no change made'
        })
    }
}

Write-Progress -Activity 'Creating shared mailboxes' -Completed

# ── Write updated mapping (with TargetAADObjectIds populated) ─────────────────

$updatedMapping | Export-CsvSafe -Path $SharedMappingCsv
Write-MigLog "Updated $SharedMappingCsv with TargetAADObjectIds"

# ── Export results ────────────────────────────────────────────────────────────

$resultRows | Export-CsvSafe -Path (Join-Path $outDir 'shared_mailbox_creation_results.csv')
if ($errorRows.Count -gt 0) {
    $errorRows | Export-CsvSafe -Path (Join-Path $outDir 'shared_mailbox_creation_errors.csv')
}

# ── Summary ───────────────────────────────────────────────────────────────────

Write-MigSummary -Stats @{
    'Total confirmed rows'   = $total
    'Created'                = $created
    'Already existed'        = $existing
    'Failed'                 = $failed
    'WhatIf mode'            = $WhatIfPreference
    'Mapping updated'        = $SharedMappingCsv
    'Next script'            = 'New-RoomEquipmentMailboxes.ps1'
}

Disconnect-AllTenants
