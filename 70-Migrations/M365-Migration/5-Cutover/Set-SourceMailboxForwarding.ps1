#Requires -Version 5.1
#Requires -Modules ExchangeOnlineManagement
<#
.SYNOPSIS
    Sets ForwardingSmtpAddress on every source mailbox to redirect
    inbound mail to the corresponding target address during the cutover
    window. Run immediately before DNS/MX cutover.

.DESCRIPTION
    During cutover there is a window (typically 24–48 h) where old MX
    records still resolve. Any mail arriving at the source tenant during
    that window must be forwarded to the target so nothing is lost.

    This script:
        1. Reads user_mapping_confirmed.csv
        2. For each source mailbox sets ForwardingSmtpAddress = TargetEmail
        3. Optionally enables DeliverToMailboxAndForward (keep a copy in
           source — useful if you need to roll back)
        4. Writes a rollback file: Set-SourceMailboxForwarding_Rollback.ps1
           that removes all forwarding if you need to undo

    IDEMPOTENT — if forwarding is already set to the correct address,
    the mailbox is skipped.

    OUTPUTS
        MigrationData\forwarding_results.csv
        5-Cutover\Set-SourceMailboxForwarding_Rollback.ps1

.PARAMETER SourceTenantId
    AAD Tenant ID of the source tenant.

.PARAMETER SourceAdminUPN
    Admin UPN for the source tenant.

.PARAMETER SourceDomain
    Primary email domain of the source company. e.g. 'smartpulse.io'

.PARAMETER CompanySuffix
    Human-readable company name. e.g. 'SmartPulse'

.PARAMETER UserMappingCsv
    Default: .\MigrationData\user_mapping_confirmed.csv

.PARAMETER DeliverToMailboxAndForward
    Keep a copy in the source mailbox AND forward to target.
    Useful for rollback safety. Default: $false (forward only).

.PARAMETER WhatIf
    Show what would be set without making changes.

.PARAMETER OutputPath
    Output folder. Default: .\MigrationData

.EXAMPLE
    # Preview
    .\Set-SourceMailboxForwarding.ps1 `
        -SourceTenantId 'balancingpoolcom.onmicrosoft.com' `
        -SourceAdminUPN 'admin@smartpulse.io' `
        -SourceDomain   'smartpulse.io' `
        -CompanySuffix  'SmartPulse' `
        -WhatIf

.EXAMPLE
    # Live — forward only (no copy at source)
    .\Set-SourceMailboxForwarding.ps1 `
        -SourceTenantId 'balancingpoolcom.onmicrosoft.com' `
        -SourceAdminUPN 'admin@smartpulse.io' `
        -SourceDomain   'smartpulse.io' `
        -CompanySuffix  'SmartPulse'

.EXAMPLE
    # Live — deliver copy at source AND forward (safer for cutover window)
    .\Set-SourceMailboxForwarding.ps1 `
        -SourceTenantId             'balancingpoolcom.onmicrosoft.com' `
        -SourceAdminUPN             'admin@smartpulse.io' `
        -SourceDomain               'smartpulse.io' `
        -CompanySuffix              'SmartPulse' `
        -DeliverToMailboxAndForward
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    [string] $SourceTenantId = '',
    [string] $SourceAdminUPN = '',
    [string] $SourceDomain = '',
    [string] $CompanySuffix = '',
    [string] $UserMappingCsv              = '.\MigrationData\user_mapping_confirmed.csv',
    [switch] $DeliverToMailboxAndForward,
    [string] $OutputPath                  = '.\MigrationData'
)

# ── Bootstrap ─────────────────────────────────────────────────────────────────

Import-Module (Join-Path $PSScriptRoot '..\MigrationHelpers.psm1') -Force -ErrorAction Stop

# ── Load MigrationConfig.psd1 ────────────────────────────────────────────────
$_cfg = Import-MigrationConfig
$SourceTenantId = Resolve-ConfigParam -Passed $SourceTenantId -Default '' -ConfigValue (Get-ConfigValue -Config $_cfg -Key "SourceTenantId")
$SourceAdminUPN = Resolve-ConfigParam -Passed $SourceAdminUPN -Default '' -ConfigValue (Get-ConfigValue -Config $_cfg -Key "SourceAdminUPN")
$SourceDomain = Resolve-ConfigParam -Passed $SourceDomain -Default '' -ConfigValue (Get-ConfigValue -Config $_cfg -Key "SourceDomain")
$CompanySuffix = Resolve-ConfigParam -Passed $CompanySuffix -Default '' -ConfigValue (Get-ConfigValue -Config $_cfg -Key "CompanySuffix")
$UserMappingCsv = Resolve-ConfigParam -Passed $UserMappingCsv -Default '' -ConfigValue (Get-ConfigValue -Config $_cfg -Key "UserMappingCsv")
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
Initialize-MigLog -ScriptName 'Set-SourceMailboxForwarding' `
                  -LogDirectory (Join-Path $PSScriptRoot '..\Logs')
$outDir = Ensure-OutputDirectory -Path $OutputPath

# ── Load mapping ──────────────────────────────────────────────────────────────

$mapping = Import-CsvSafe -Path $UserMappingCsv `
    -RequiredColumns @('SourceEmail','TargetEmail','Status')
$confirmed = $mapping | Where-Object { $_.Status -eq 'CONFIRMED' }
Write-MigLog "Mailboxes to forward: $(@($confirmed).Count)"

# ── Connect source ────────────────────────────────────────────────────────────

Connect-SourceTenant -TenantId $SourceTenantId -UserPrincipalName $SourceAdminUPN

# ── Set forwarding ────────────────────────────────────────────────────────────

$resultRows   = [System.Collections.Generic.List[PSCustomObject]]::new()
$rollbackLines = [System.Collections.Generic.List[string]]::new()

$rollbackLines.Add('# Auto-generated rollback script — removes all forwarding set by Set-SourceMailboxForwarding.ps1')
$rollbackLines.Add("# Generated: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')")
$rollbackLines.Add("# Migration: $CompanySuffix → Volue")
$rollbackLines.Add('')
$rollbackLines.Add("Connect-ExchangeOnline -UserPrincipalName '$SourceAdminUPN'")
$rollbackLines.Add('')

$set      = 0; $skipped = 0; $failed = 0
$total    = @($confirmed).Count; $i = 0

foreach ($row in $confirmed) {

    $i++
    Write-ProgressHelper -Activity 'Setting forwarding' `
                         -Current $i -Total $total `
                         -Status $row.SourceEmail

    try {
        # Check current state
        $mbx = Invoke-WithRetry {
            Get-Mailbox -Identity $row.SourceEmail -ErrorAction Stop
        }

        # Already correctly set?
        if ($mbx.ForwardingSmtpAddress -eq "smtp:$($row.TargetEmail)") {
            $skipped++
            $resultRows.Add([PSCustomObject]@{
                SourceEmail     = $row.SourceEmail
                TargetEmail     = $row.TargetEmail
                Action          = 'ALREADY_SET'
                PreviousForward = $mbx.ForwardingSmtpAddress
                WhatIf          = $false
            })
            $rollbackLines.Add("Set-Mailbox -Identity '$($row.SourceEmail)' -ForwardingSmtpAddress `$null -DeliverToMailboxAndForward `$false")
            continue
        }

        $prevForward = $mbx.ForwardingSmtpAddress

        if ($PSCmdlet.ShouldProcess($row.SourceEmail, "Set ForwardingSmtpAddress → $($row.TargetEmail)")) {
            Invoke-WithRetry {
                Set-Mailbox -Identity                   $row.SourceEmail `
                            -ForwardingSmtpAddress      $row.TargetEmail `
                            -DeliverToMailboxAndForward $DeliverToMailboxAndForward.IsPresent `
                            -ErrorAction Stop
            }
            $set++
            Write-MigLog "  SET: $($row.SourceEmail) → $($row.TargetEmail)"

            $rollbackLines.Add("Set-Mailbox -Identity '$($row.SourceEmail)' -ForwardingSmtpAddress `$null -DeliverToMailboxAndForward `$false")

            $resultRows.Add([PSCustomObject]@{
                SourceEmail     = $row.SourceEmail
                TargetEmail     = $row.TargetEmail
                Action          = 'SET'
                PreviousForward = $prevForward
                WhatIf          = $false
            })
        }
        else {
            Write-MigLog "  WHATIF: Would set $($row.SourceEmail) → $($row.TargetEmail)"
            $resultRows.Add([PSCustomObject]@{
                SourceEmail     = $row.SourceEmail
                TargetEmail     = $row.TargetEmail
                Action          = 'WHATIF'
                PreviousForward = $prevForward
                WhatIf          = $true
            })
        }
    }
    catch {
        $failed++
        Write-MigLog "  FAILED: $($row.SourceEmail) — $_" -Level ERROR
        $resultRows.Add([PSCustomObject]@{
            SourceEmail = $row.SourceEmail; TargetEmail = $row.TargetEmail
            Action = 'FAILED'; PreviousForward = ''; WhatIf = $false
        })
    }
}

Write-Progress -Activity 'Setting forwarding' -Completed

# ── Write rollback script ─────────────────────────────────────────────────────

$rollbackLines.Add('')
$rollbackLines.Add('Disconnect-ExchangeOnline -Confirm:$false')

$rollbackPath = Join-Path $PSScriptRoot 'Set-SourceMailboxForwarding_Rollback.ps1'
$rollbackLines | Out-File -FilePath $rollbackPath -Encoding UTF8 -Force
Write-MigLog "Rollback script written: $rollbackPath"

# ── Export ────────────────────────────────────────────────────────────────────

$resultRows | Export-CsvSafe -Path (Join-Path $outDir 'forwarding_results.csv')

Write-MigSummary -Stats @{
    'Total mailboxes'            = $total
    'Forwarding set'             = $set
    'Already correctly set'      = $skipped
    'Failed'                     = $failed
    'DeliverToMailboxAndForward' = $DeliverToMailboxAndForward.IsPresent
    'WhatIf mode'                = $WhatIfPreference
    'Rollback script'            = $rollbackPath
    'Next step'                  = 'Update MX records / DNS cutover, then run Set-SourceDomainOOF.ps1'
}

Disconnect-AllTenants
