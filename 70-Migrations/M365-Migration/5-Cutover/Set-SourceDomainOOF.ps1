#Requires -Version 5.1
#Requires -Modules ExchangeOnlineManagement
<#
.SYNOPSIS
    Sets an out-of-office / auto-reply on source mailboxes after MX
    cutover, informing senders that the user has moved to a new address.

.DESCRIPTION
    After DNS cutover, mail sent to old @source addresses is forwarded
    to target. However, senders who have the old address cached in their
    mail client or who email from outside the tenant need to know to
    update their contacts.

    This script sets an automatic reply on every source mailbox:
        Internal (within source tenant) : configurable message
        External (outside source tenant): configurable message

    The message templates support these substitution tokens:
        {SourceEmail}   — the old source address
        {TargetEmail}   — the new target address
        {DisplayName}   — the user's display name
        {CompanySuffix} — e.g. SmartPulse
        {CutoverDate}   — today's date

    IDEMPOTENT — if auto-reply is already correctly set, mailbox is skipped.

    OUTPUTS
        MigrationData\oof_results.csv
        5-Cutover\Set-SourceDomainOOF_Rollback.ps1  (disables all auto-replies)

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

.PARAMETER InternalMessage
    Auto-reply body for senders inside the source tenant.
    Supports: {SourceEmail} {TargetEmail} {DisplayName} {CompanySuffix} {CutoverDate}

.PARAMETER ExternalMessage
    Auto-reply body for external senders.
    Supports the same tokens.

.PARAMETER WhatIf
    Show what would be set without making changes.

.PARAMETER OutputPath
    Output folder. Default: .\MigrationData

.EXAMPLE
    .\Set-SourceDomainOOF.ps1 `
        -SourceTenantId 'balancingpoolcom.onmicrosoft.com' `
        -SourceAdminUPN 'admin@smartpulse.io' `
        -SourceDomain   'smartpulse.io' `
        -CompanySuffix  'SmartPulse'
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    [string] $SourceTenantId = '',
    [string] $SourceAdminUPN = '',
    [string] $SourceDomain = '',
    [string] $CompanySuffix = '',
    [string] $UserMappingCsv = '.\MigrationData\user_mapping_confirmed.csv',

    [string] $InternalMessage = @'
Hi,

Our email system has been migrated. My new email address is {TargetEmail}.

Please update your contacts and send future emails to {TargetEmail}.
Emails sent to {SourceEmail} will continue to be delivered automatically,
but updating your contacts now will ensure you always reach me directly.

Best regards,
{DisplayName}
'@,

    [string] $ExternalMessage = @'
Hi,

{CompanySuffix} has migrated its email platform as of {CutoverDate}.
My new email address is {TargetEmail}.

Please update your contacts and send future emails to {TargetEmail}.
Emails to this address ({SourceEmail}) will be forwarded automatically
during the transition period.

Best regards,
{DisplayName}
'@,

    [string] $OutputPath = '.\MigrationData'
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
Initialize-MigLog -ScriptName 'Set-SourceDomainOOF' `
                  -LogDirectory (Join-Path $PSScriptRoot '..\Logs')
$outDir      = Ensure-OutputDirectory -Path $OutputPath
$cutoverDate = Get-Date -Format 'dd MMMM yyyy'

# ── Load mapping ──────────────────────────────────────────────────────────────

$mapping   = Import-CsvSafe -Path $UserMappingCsv `
    -RequiredColumns @('SourceEmail','TargetEmail','Status','SourceDisplayName')
$confirmed = $mapping | Where-Object { $_.Status -eq 'CONFIRMED' }
Write-MigLog "Mailboxes to configure OOF: $(@($confirmed).Count)"

# ── Connect ───────────────────────────────────────────────────────────────────

Connect-SourceTenant -TenantId $SourceTenantId -UserPrincipalName $SourceAdminUPN

# ── Set OOF ───────────────────────────────────────────────────────────────────

$resultRows    = [System.Collections.Generic.List[PSCustomObject]]::new()
$rollbackLines = [System.Collections.Generic.List[string]]::new()
$rollbackLines.Add('# Rollback: disables all auto-replies set by Set-SourceDomainOOF.ps1')
$rollbackLines.Add("# Generated: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')")
$rollbackLines.Add('')
$rollbackLines.Add("Connect-ExchangeOnline -UserPrincipalName '$SourceAdminUPN'")
$rollbackLines.Add('')

$set = 0; $skipped = 0; $failed = 0
$total = @($confirmed).Count; $i = 0

foreach ($row in $confirmed) {

    $i++
    Write-ProgressHelper -Activity 'Setting OOF' `
                         -Current $i -Total $total `
                         -Status $row.SourceEmail

    # Substitute tokens in message templates
    $displayName = $row.SourceDisplayName -ne '' ? $row.SourceDisplayName : $row.SourceEmail
    $tokens = @{
        '{SourceEmail}'   = $row.SourceEmail
        '{TargetEmail}'   = $row.TargetEmail
        '{DisplayName}'   = $displayName
        '{CompanySuffix}' = $CompanySuffix
        '{CutoverDate}'   = $cutoverDate
    }

    $internalBody = $InternalMessage
    $externalBody = $ExternalMessage
    foreach ($token in $tokens.GetEnumerator()) {
        $internalBody = $internalBody -replace [regex]::Escape($token.Key), $token.Value
        $externalBody = $externalBody -replace [regex]::Escape($token.Key), $token.Value
    }

    try {
        # Check current state
        $currentOOF = Invoke-WithRetry {
            Get-MailboxAutoReplyConfiguration -Identity $row.SourceEmail -ErrorAction Stop
        }

        if ($currentOOF.AutoReplyState -eq 'Enabled' -and
            $currentOOF.InternalMessage -eq $internalBody) {
            $skipped++
            $resultRows.Add([PSCustomObject]@{
                SourceEmail = $row.SourceEmail; TargetEmail = $row.TargetEmail
                Action = 'ALREADY_SET'; WhatIf = $false
            })
            $rollbackLines.Add("Set-MailboxAutoReplyConfiguration -Identity '$($row.SourceEmail)' -AutoReplyState Disabled")
            continue
        }

        if ($PSCmdlet.ShouldProcess($row.SourceEmail, 'Enable auto-reply')) {
            Invoke-WithRetry {
                Set-MailboxAutoReplyConfiguration `
                    -Identity        $row.SourceEmail `
                    -AutoReplyState  Enabled `
                    -InternalMessage $internalBody `
                    -ExternalMessage $externalBody `
                    -ExternalAudience All `
                    -ErrorAction Stop
            }
            $set++
            Write-MigLog "  OOF SET: $($row.SourceEmail)"
            $rollbackLines.Add("Set-MailboxAutoReplyConfiguration -Identity '$($row.SourceEmail)' -AutoReplyState Disabled")
            $resultRows.Add([PSCustomObject]@{
                SourceEmail = $row.SourceEmail; TargetEmail = $row.TargetEmail
                Action = 'SET'; WhatIf = $false
            })
        }
        else {
            Write-MigLog "  WHATIF: Would enable OOF for $($row.SourceEmail)"
            $resultRows.Add([PSCustomObject]@{
                SourceEmail = $row.SourceEmail; TargetEmail = $row.TargetEmail
                Action = 'WHATIF'; WhatIf = $true
            })
        }
    }
    catch {
        $failed++
        Write-MigLog "  FAILED: $($row.SourceEmail) — $_" -Level ERROR
        $resultRows.Add([PSCustomObject]@{
            SourceEmail = $row.SourceEmail; TargetEmail = $row.TargetEmail
            Action = 'FAILED'; WhatIf = $false
        })
    }
}

Write-Progress -Activity 'Setting OOF' -Completed

$rollbackLines.Add('')
$rollbackLines.Add('Disconnect-ExchangeOnline -Confirm:$false')
$rollbackPath = Join-Path $PSScriptRoot 'Set-SourceDomainOOF_Rollback.ps1'
$rollbackLines | Out-File -FilePath $rollbackPath -Encoding UTF8 -Force

$resultRows | Export-CsvSafe -Path (Join-Path $outDir 'oof_results.csv')

Write-MigSummary -Stats @{
    'Total mailboxes'   = $total
    'OOF set'           = $set
    'Already set'       = $skipped
    'Failed'            = $failed
    'WhatIf mode'       = $WhatIfPreference
    'Rollback script'   = $rollbackPath
    'Next step'         = 'Run Add-TargetProxyAddresses.ps1 to add source domain as alias at target'
}

Disconnect-AllTenants
