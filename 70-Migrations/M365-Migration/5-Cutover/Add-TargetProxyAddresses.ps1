#Requires -Version 5.1
#Requires -Modules ExchangeOnlineManagement
<#
.SYNOPSIS
    Adds each user's source email address as a secondary SMTP proxy
    address on their target mailbox, so mail sent to old addresses
    continues to route correctly after MX cutover.

.DESCRIPTION
    For this to work the source domain (e.g. smartpulse.io) must first
    be added as an accepted domain in the Volue Exchange Online tenant.
    The script checks for this and aborts if the domain is not yet
    accepted.

    For each confirmed user:
        1. Checks the source email is not already a proxy on the target
        2. Adds it as a secondary smtp: address (lowercase = non-primary)
        3. Also adds the source addresses for shared mailboxes from
           shared_mailbox_mapping.csv

    Source aliases (SmtpAliases column from mailboxes.csv) are also
    added as proxies, preserving the full source address space.

    IDEMPOTENT — existing proxies are skipped.

    OUTPUTS
        MigrationData\proxy_address_results.csv
        MigrationData\proxy_address_errors.csv

.PARAMETER TargetTenantId
    AAD Tenant ID of the target tenant.

.PARAMETER TargetAdminUPN
    Admin UPN for the target tenant.

.PARAMETER SourceDomain
    Primary email domain of the source company. e.g. 'smartpulse.io'

.PARAMETER CompanySuffix
    Human-readable company name. e.g. 'SmartPulse'

.PARAMETER UserMappingCsv
    Default: .\MigrationData\user_mapping_confirmed.csv

.PARAMETER SharedMappingCsv
    Default: .\MigrationData\shared_mailbox_mapping.csv

.PARAMETER MailboxInventoryCsv
    Phase 1 mailbox inventory — used to retrieve source aliases.
    Default: .\MigrationData\mailboxes.csv

.PARAMETER WhatIf
    Show what would be added without making changes.

.PARAMETER OutputPath
    Output folder. Default: .\MigrationData

.EXAMPLE
    # Preview
    .\Add-TargetProxyAddresses.ps1 `
        -TargetTenantId 'volue.onmicrosoft.com' `
        -TargetAdminUPN 'admin@volue.com' `
        -SourceDomain   'smartpulse.io' `
        -CompanySuffix  'SmartPulse' `
        -WhatIf

.EXAMPLE
    # Live run
    .\Add-TargetProxyAddresses.ps1 `
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
    [string] $UserMappingCsv      = '.\MigrationData\user_mapping_confirmed.csv',
    [string] $SharedMappingCsv    = '.\MigrationData\shared_mailbox_mapping.csv',
    [string] $MailboxInventoryCsv = '.\MigrationData\mailboxes.csv',
    [string] $OutputPath          = '.\MigrationData'
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
$MailboxInventoryCsv = Resolve-ConfigParam -Passed $MailboxInventoryCsv -Default '' -ConfigValue (Get-ConfigValue -Config $_cfg -Key "MailboxInventoryCsv")
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
Initialize-MigLog -ScriptName 'Add-TargetProxyAddresses' `
                  -LogDirectory (Join-Path $PSScriptRoot '..\Logs')
$outDir = Ensure-OutputDirectory -Path $OutputPath

# ── Load mappings ─────────────────────────────────────────────────────────────

$userMapping   = Import-CsvSafe -Path $UserMappingCsv `
    -RequiredColumns @('SourceEmail','TargetEmail','Status')
$confirmed     = $userMapping | Where-Object { $_.Status -eq 'CONFIRMED' }

$sharedMapping = if (Test-Path $SharedMappingCsv) {
    Import-CsvSafe -Path $SharedMappingCsv | Where-Object { $_.Status -eq 'CONFIRMED' }
} else { @() }

# Build source alias index: sourceEmail → list of all source smtp addresses
$sourceAliasIndex = @{}
if (Test-Path $MailboxInventoryCsv) {
    $mbxData = Import-CsvSafe -Path $MailboxInventoryCsv
    foreach ($row in $mbxData) {
        $aliases = [System.Collections.Generic.List[string]]::new()
        $aliases.Add($row.PrimarySmtpAddress.ToLower())
        if ($row.SmtpAliases) {
            foreach ($a in ($row.SmtpAliases -split '\|' | Where-Object { $_ })) {
                $aliases.Add($a.ToLower())
            }
        }
        $sourceAliasIndex[$row.PrimarySmtpAddress.ToLower()] = $aliases
    }
}

# ── Connect target ────────────────────────────────────────────────────────────

Connect-TargetTenant -TenantId $TargetTenantId -UserPrincipalName $TargetAdminUPN

# ── Check source domain is accepted in target ─────────────────────────────────

Write-MigLog "Checking '$SourceDomain' is an accepted domain in target tenant..."
$acceptedDomains = Invoke-WithRetry {
    Get-AcceptedDomain -ErrorAction Stop
}
$domainAccepted = $acceptedDomains | Where-Object { $_.DomainName -eq $SourceDomain }

if (-not $domainAccepted) {
    Write-MigLog "CRITICAL: '$SourceDomain' is NOT an accepted domain in the Volue tenant." -Level ERROR
    Write-MigLog "ACTION: Add '$SourceDomain' as an accepted domain in the M365 Admin Centre" -Level ERROR
    Write-MigLog "        before running this script. The domain must be verified first." -Level ERROR
    Write-MigLog "        Admin Centre → Settings → Domains → Add domain" -Level ERROR
    exit 1
}
Write-MigLog "'$SourceDomain' is accepted: $($domainAccepted.DomainType)"

# ── Process mailboxes ─────────────────────────────────────────────────────────

$resultRows = [System.Collections.Generic.List[PSCustomObject]]::new()
$errorRows  = [System.Collections.Generic.List[PSCustomObject]]::new()

$added   = 0; $skipped = 0; $failed = 0

# Combine user and shared mailbox rows
$allRows = @(
    $confirmed     | ForEach-Object { @{ Source=$_.SourceEmail; Target=$_.TargetEmail; Type='User'   } }
    $sharedMapping | ForEach-Object { @{ Source=$_.SourceEmail; Target=$_.TargetEmail; Type='Shared' } }
)

$total = $allRows.Count; $i = 0

foreach ($entry in $allRows) {

    $i++
    Write-ProgressHelper -Activity 'Adding proxy addresses' `
                         -Current $i -Total $total `
                         -Status $entry.Target

    # Collect all source smtp addresses for this mailbox
    $sourceAddresses = $sourceAliasIndex[$entry.Source.ToLower()]
    if (-not $sourceAddresses) {
        $sourceAddresses = @($entry.Source.ToLower())
    }

    try {
        # Get current target mailbox
        $targetMbx = Invoke-WithRetry {
            Get-Mailbox -Identity $entry.Target -ErrorAction Stop
        }

        $currentProxies = $targetMbx.EmailAddresses |
            ForEach-Object { $_.ToString().ToLower() } |
            Where-Object { $_ -match '^smtp:' } |
            ForEach-Object { $_ -replace '^smtp:', '' }

        $proxiesToAdd = [System.Collections.Generic.List[string]]::new()
        foreach ($addr in $sourceAddresses) {
            if ($addr -notin $currentProxies) {
                $proxiesToAdd.Add("smtp:$addr")   # lowercase smtp: = non-primary
            }
        }

        if ($proxiesToAdd.Count -eq 0) {
            $skipped++
            Write-MigLog "  SKIPPED (all already present): $($entry.Target)" -Level DEBUG
            $resultRows.Add([PSCustomObject]@{
                TargetEmail    = $entry.Target
                SourceEmail    = $entry.Source
                MailboxType    = $entry.Type
                AddedAddresses = ''
                Action         = 'ALREADY_PRESENT'
                WhatIf         = $false
            })
            continue
        }

        if ($PSCmdlet.ShouldProcess($entry.Target, "Add proxy addresses: $($proxiesToAdd -join ', ')")) {

            # Build new EmailAddresses array — preserve existing + add new
            $newProxies = @($targetMbx.EmailAddresses) + $proxiesToAdd.ToArray()

            Invoke-WithRetry {
                Set-Mailbox -Identity       $entry.Target `
                            -EmailAddresses $newProxies `
                            -ErrorAction Stop
            }

            $added++
            Write-MigLog "  ADDED: $($entry.Target) ← $($proxiesToAdd -join ', ')"

            $resultRows.Add([PSCustomObject]@{
                TargetEmail    = $entry.Target
                SourceEmail    = $entry.Source
                MailboxType    = $entry.Type
                AddedAddresses = ($proxiesToAdd | Join-String -Separator ' | ')
                Action         = 'ADDED'
                WhatIf         = $false
            })
        }
        else {
            Write-MigLog "  WHATIF: Would add to $($entry.Target): $($proxiesToAdd -join ', ')"
            $resultRows.Add([PSCustomObject]@{
                TargetEmail    = $entry.Target
                SourceEmail    = $entry.Source
                MailboxType    = $entry.Type
                AddedAddresses = ($proxiesToAdd | Join-String -Separator ' | ')
                Action         = 'WHATIF'
                WhatIf         = $true
            })
        }
    }
    catch {
        $failed++
        Write-MigLog "  FAILED: $($entry.Target) — $_" -Level ERROR
        $errorRows.Add([PSCustomObject]@{
            TargetEmail = $entry.Target
            SourceEmail = $entry.Source
            Error       = $_.Exception.Message
        })
    }
}

Write-Progress -Activity 'Adding proxy addresses' -Completed

$resultRows | Export-CsvSafe -Path (Join-Path $outDir 'proxy_address_results.csv')
if ($errorRows.Count -gt 0) {
    $errorRows | Export-CsvSafe -Path (Join-Path $outDir 'proxy_address_errors.csv')
}

Write-MigSummary -Stats @{
    'Total mailboxes'     = $total
    'Proxy addresses added' = $added
    'Already present'     = $skipped
    'Failed'              = $failed
    'WhatIf mode'         = $WhatIfPreference
    'Next step'           = 'Run Invoke-CutoverChecklist.ps1 for final go-live verification'
}

Disconnect-AllTenants
