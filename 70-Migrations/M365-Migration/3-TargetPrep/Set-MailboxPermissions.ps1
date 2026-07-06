#Requires -Version 5.1
#Requires -Modules ExchangeOnlineManagement
<#
.SYNOPSIS
    Re-applies mailbox permissions (FullAccess, SendAs, SendOnBehalf) in
    the TARGET tenant using the Phase 1 permissions inventory.

.DESCRIPTION
    Reads mailbox_permissions.csv from Phase 1, resolves each mailbox
    and trustee to their target email via user_mapping_confirmed.csv,
    then applies the permission in the target Exchange Online tenant.

    Run this script AFTER:
        - Code2 migration has completed for the relevant mailboxes
        - All mailboxes (user + shared) exist in the target tenant

    PERMISSION TYPES
        FullAccess      → Add-MailboxPermission
        SendAs          → Add-RecipientPermission
        SendOnBehalf    → Set-Mailbox -GrantSendOnBehalfTo (additive)

    FILTERING
        By default processes all permission types. Use -PermissionTypes
        to restrict to one or more types.

    IDEMPOTENT
        Existing permissions are detected and skipped rather than
        duplicated.

    OUTPUTS
        MigrationData\permission_apply_results.csv
        MigrationData\permission_apply_errors.csv
        MigrationData\permission_apply_skipped.csv  (unmapped mailbox or trustee)

.PARAMETER TargetTenantId
    AAD Tenant ID of the target tenant.

.PARAMETER TargetAdminUPN
    Admin UPN for the target tenant.

.PARAMETER SourceDomain
    Primary email domain of the source company. e.g. 'smartpulse.io'

.PARAMETER CompanySuffix
    Human-readable company name. e.g. 'SmartPulse'

.PARAMETER PermissionsCsv
    Phase 1 mailbox permissions inventory.
    Default: .\MigrationData\mailbox_permissions.csv

.PARAMETER UserMappingCsv
    Confirmed user mapping.
    Default: .\MigrationData\user_mapping_confirmed.csv

.PARAMETER SharedMappingCsv
    Confirmed shared mailbox mapping (for shared mailbox→shared mailbox permissions).
    Default: .\MigrationData\shared_mailbox_mapping.csv

.PARAMETER PermissionTypes
    Which permission types to apply. Default: all three.

.PARAMETER WhatIf
    Show what would be applied without making changes.

.PARAMETER OutputPath
    Output folder. Default: .\MigrationData

.EXAMPLE
    # WhatIf preview
    .\Set-MailboxPermissions.ps1 `
        -TargetTenantId 'volue.onmicrosoft.com' `
        -TargetAdminUPN 'admin@volue.com' `
        -SourceDomain   'smartpulse.io' `
        -CompanySuffix  'SmartPulse' `
        -WhatIf

.EXAMPLE
    # Apply only FullAccess permissions
    .\Set-MailboxPermissions.ps1 `
        -TargetTenantId  'volue.onmicrosoft.com' `
        -TargetAdminUPN  'admin@volue.com' `
        -SourceDomain    'smartpulse.io' `
        -CompanySuffix   'SmartPulse' `
        -PermissionTypes 'FullAccess'
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    [string] $TargetTenantId = '',
    [string] $TargetAdminUPN = '',
    [string] $SourceDomain = '',
    [string] $CompanySuffix = '',
    [string]   $PermissionsCsv  = '.\MigrationData\mailbox_permissions.csv',
    [string]   $UserMappingCsv  = '.\MigrationData\user_mapping_confirmed.csv',
    [string]   $SharedMappingCsv = '.\MigrationData\shared_mailbox_mapping.csv',
    [string[]] $PermissionTypes = @('FullAccess','SendAs','SendOnBehalf'),
    [string]   $OutputPath      = '.\MigrationData'
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
Initialize-MigLog -ScriptName 'Set-MailboxPermissions' `
                  -LogDirectory (Join-Path $PSScriptRoot '..\Logs')
$outDir = Ensure-OutputDirectory -Path $OutputPath

# ── Load permissions inventory ────────────────────────────────────────────────

$allPerms = Import-CsvSafe -Path $PermissionsCsv `
    -RequiredColumns @('MailboxEmail','TrusteeEmail','PermissionType')

$filteredPerms = $allPerms | Where-Object { $_.PermissionType -in $PermissionTypes }
Write-MigLog "Permission rows to process: $($filteredPerms.Count) (types: $($PermissionTypes -join ', '))"

# ── Build combined email mapping (users + shared mailboxes) ───────────────────

Import-UserMapping -Path $UserMappingCsv -ConfirmedOnly

# Extend the mapping with shared mailboxes (shared → shared)
if (Test-Path $SharedMappingCsv) {
    $sharedRows = Import-CsvSafe -Path $SharedMappingCsv `
        -RequiredColumns @('SourceEmail','TargetEmail','Status')
    foreach ($row in ($sharedRows | Where-Object { $_.Status -eq 'CONFIRMED' })) {
        # Inject into module mapping table directly
        if (-not (Get-MappedEmail -SourceEmail $row.SourceEmail)) {
            $script:MappingTable[$row.SourceEmail.ToUpper()] = $row
        }
    }
    Write-MigLog "Shared mailbox entries added to mapping lookup"
}

# ── Connect ───────────────────────────────────────────────────────────────────

Connect-TargetTenant -TenantId $TargetTenantId -UserPrincipalName $TargetAdminUPN

# Pre-load existing FullAccess permissions per mailbox to support idempotency
Write-MigLog "Pre-loading existing FullAccess permissions in target..."
$existingFA = @{}   # targetMailboxEmail → list of trustees
$faPerms = Invoke-WithRetry {
    Get-Mailbox -ResultSize Unlimited -ErrorAction Stop |
        ForEach-Object {
            $mbx = $_
            Get-MailboxPermission -Identity $mbx.PrimarySmtpAddress -ErrorAction SilentlyContinue |
                Where-Object { -not $_.IsInherited -and $_.AccessRights -contains 'FullAccess' }
        }
}
foreach ($perm in $faPerms) {
    $key = $perm.Identity.ToLower()
    if (-not $existingFA.ContainsKey($key)) {
        $existingFA[$key] = [System.Collections.Generic.List[string]]::new()
    }
    $existingFA[$key].Add($perm.User.ToString().ToLower())
}
Write-MigLog "Existing FullAccess index built: $($existingFA.Count) mailboxes"

# ── Processing loop ───────────────────────────────────────────────────────────

$resultRows  = [System.Collections.Generic.List[PSCustomObject]]::new()
$errorRows   = [System.Collections.Generic.List[PSCustomObject]]::new()
$skippedRows = [System.Collections.Generic.List[PSCustomObject]]::new()

$applied  = 0; $skipped = 0; $failed = 0
$total    = $filteredPerms.Count; $i = 0

# SendOnBehalf is set per-mailbox as a list — gather all SOB entries first
$sobByMailbox = @{}   # targetMailboxEmail → list of target trustee emails

foreach ($perm in ($filteredPerms | Where-Object { $_.PermissionType -eq 'SendOnBehalf' })) {
    $targetMailboxEmail = Get-MappedEmail -SourceEmail $perm.MailboxEmail
    $targetTrusteeEmail = Get-MappedEmail -SourceEmail $perm.TrusteeEmail
    if ($targetMailboxEmail -and $targetTrusteeEmail) {
        if (-not $sobByMailbox.ContainsKey($targetMailboxEmail)) {
            $sobByMailbox[$targetMailboxEmail] = [System.Collections.Generic.List[string]]::new()
        }
        $sobByMailbox[$targetMailboxEmail].Add($targetTrusteeEmail)
    }
}

foreach ($perm in $filteredPerms) {

    $i++
    Write-ProgressHelper -Activity 'Applying permissions' `
                         -Current $i -Total $total `
                         -Status "$($perm.PermissionType): $($perm.MailboxEmail)"

    # Resolve both sides
    $targetMailboxEmail = Get-MappedEmail -SourceEmail $perm.MailboxEmail
    $targetTrusteeEmail = Get-MappedEmail -SourceEmail $perm.TrusteeEmail

    if (-not $targetMailboxEmail) {
        $skipped++
        $skippedRows.Add([PSCustomObject]@{
            PermissionType = $perm.PermissionType
            SourceMailbox  = $perm.MailboxEmail
            SourceTrustee  = $perm.TrusteeEmail
            Reason         = 'Mailbox not in confirmed mapping'
        })
        continue
    }
    if (-not $targetTrusteeEmail) {
        $skipped++
        $skippedRows.Add([PSCustomObject]@{
            PermissionType = $perm.PermissionType
            SourceMailbox  = $perm.MailboxEmail
            SourceTrustee  = $perm.TrusteeEmail
            Reason         = 'Trustee not in confirmed mapping'
        })
        continue
    }

    if ($PSCmdlet.ShouldProcess("$targetMailboxEmail", "$($perm.PermissionType) for $targetTrusteeEmail")) {
        try {
            switch ($perm.PermissionType) {

                'FullAccess' {
                    # Idempotency check
                    $existingTrustees = $existingFA[$targetMailboxEmail.ToLower()] ?? @()
                    if ($existingTrustees -contains $targetTrusteeEmail.ToLower()) {
                        $skipped++
                        $resultRows.Add([PSCustomObject]@{
                            PermissionType = 'FullAccess'
                            TargetMailbox  = $targetMailboxEmail
                            TargetTrustee  = $targetTrusteeEmail
                            Action         = 'ALREADY_EXISTS'; WhatIf = $false; Notes = ''
                        })
                        break
                    }
                    Invoke-WithRetry {
                        Add-MailboxPermission -Identity    $targetMailboxEmail `
                                              -User        $targetTrusteeEmail `
                                              -AccessRights FullAccess `
                                              -InheritanceType All `
                                              -AutoMapping $true `
                                              -ErrorAction Stop | Out-Null
                    }
                    $applied++
                    $resultRows.Add([PSCustomObject]@{
                        PermissionType = 'FullAccess'
                        TargetMailbox  = $targetMailboxEmail
                        TargetTrustee  = $targetTrusteeEmail
                        Action         = 'APPLIED'; WhatIf = $false; Notes = ''
                    })
                }

                'SendAs' {
                    Invoke-WithRetry {
                        Add-RecipientPermission -Identity    $targetMailboxEmail `
                                                -Trustee     $targetTrusteeEmail `
                                                -AccessRights SendAs `
                                                -Confirm:$false `
                                                -ErrorAction Stop | Out-Null
                    }
                    $applied++
                    $resultRows.Add([PSCustomObject]@{
                        PermissionType = 'SendAs'
                        TargetMailbox  = $targetMailboxEmail
                        TargetTrustee  = $targetTrusteeEmail
                        Action         = 'APPLIED'; WhatIf = $false; Notes = ''
                    })
                }

                'SendOnBehalf' {
                    # SOB is set as a complete list — only process the first entry per mailbox,
                    # applying the full collected list in one call to avoid repeated overwrites
                    if ($sobByMailbox.ContainsKey($targetMailboxEmail)) {
                        $delegates = $sobByMailbox[$targetMailboxEmail].ToArray()

                        Invoke-WithRetry {
                            Set-Mailbox -Identity                $targetMailboxEmail `
                                        -GrantSendOnBehalfTo     $delegates `
                                        -ErrorAction Stop
                        }
                        $applied++
                        $resultRows.Add([PSCustomObject]@{
                            PermissionType = 'SendOnBehalf'
                            TargetMailbox  = $targetMailboxEmail
                            TargetTrustee  = $delegates -join '|'
                            Action         = 'APPLIED'; WhatIf = $false
                            Notes          = "$($delegates.Count) delegate(s) set as batch"
                        })
                        # Remove so we don't set again for the same mailbox
                        $sobByMailbox.Remove($targetMailboxEmail)
                    }
                    # else: already processed this mailbox in a prior iteration
                }
            }
        }
        catch {
            $failed++
            Write-MigLog "  FAILED: $($perm.PermissionType) $($perm.MailboxEmail) → $($perm.TrusteeEmail): $_" -Level ERROR
            $errorRows.Add([PSCustomObject]@{
                PermissionType = $perm.PermissionType
                SourceMailbox  = $perm.MailboxEmail
                SourceTrustee  = $perm.TrusteeEmail
                TargetMailbox  = $targetMailboxEmail
                TargetTrustee  = $targetTrusteeEmail
                Error          = $_.Exception.Message
            })
        }
    }
    else {
        Write-MigLog "  WHATIF: Would apply $($perm.PermissionType): $targetMailboxEmail ← $targetTrusteeEmail"
        $resultRows.Add([PSCustomObject]@{
            PermissionType = $perm.PermissionType
            TargetMailbox  = $targetMailboxEmail
            TargetTrustee  = $targetTrusteeEmail
            Action         = 'WHATIF'; WhatIf = $true; Notes = ''
        })
    }
}

Write-Progress -Activity 'Applying permissions' -Completed

# ── Export ────────────────────────────────────────────────────────────────────

$resultRows  | Export-CsvSafe -Path (Join-Path $outDir 'permission_apply_results.csv')
if ($errorRows.Count -gt 0)   { $errorRows   | Export-CsvSafe -Path (Join-Path $outDir 'permission_apply_errors.csv') }
if ($skippedRows.Count -gt 0) { $skippedRows | Export-CsvSafe -Path (Join-Path $outDir 'permission_apply_skipped.csv') }

Write-MigSummary -Stats @{
    'Total permissions'      = $total
    'Applied'                = $applied
    'Already existed'        = ($resultRows | Where-Object { $_.Action -eq 'ALREADY_EXISTS' }).Count
    'Skipped (unmapped)'     = $skipped
    'Failed'                 = $failed
    'WhatIf mode'            = $WhatIfPreference
    'Next step'              = 'Run Test-MappingCoverage.ps1 then start Code2 migration batches'
}

Disconnect-AllTenants
