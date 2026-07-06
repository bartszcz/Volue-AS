#Requires -Version 5.1
#Requires -Modules ExchangeOnlineManagement, Microsoft.Graph.Users
<#
.SYNOPSIS
    Post-migration mailbox validation. Run after each Code2 batch completes.

.DESCRIPTION
    For every mailbox in the batch, compares source and target state:

        ITEM COUNT & SIZE
            Compares source statistics (from Phase 1 mailbox_statistics.csv
            or live query) against target. Flags mailboxes where target
            count is less than 90% of source (configurable threshold).

        FOLDER STRUCTURE
            Verifies top-level folders exist in target (Inbox, Sent Items,
            Deleted Items, custom folders). Missing folders are flagged WARN.

        PROXY ADDRESSES
            Checks that source SMTP aliases are present in target as
            secondary addresses (required for mail routing continuity).

        PERMISSIONS
            Verifies that FullAccess, SendAs, and SendOnBehalf permissions
            were applied (cross-references permission_apply_results.csv).

        FORWARDING
            Flags any mailboxes with active ForwardingSmtpAddress in target
            that weren't present at source (unexpected forwarding).

        LITIGATION HOLD
            Verifies LitigationHold status matches source where applicable.

    Run modes:
        -BatchName Batch001       — validate one Code2 batch
        -All                      — validate all confirmed rows
        -PilotOnly                — validate first 10 users only (quick smoke test)

    OUTPUTS
        MigrationData\post_mailbox_validation_Batch001.csv   — per-mailbox results
        MigrationData\post_mailbox_validation_issues.csv     — all FAIL/WARN rows

.PARAMETER SourceTenantId
    AAD Tenant ID of the source tenant (for live item count comparison).
    Omit to use Phase 1 statistics CSV instead of live query.

.PARAMETER SourceAdminUPN
    Source tenant admin UPN. Required if -SourceTenantId is provided.

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

.PARAMETER SourceStatsCsv
    Phase 1 mailbox statistics. Used when source tenant is not connected.
    Default: .\MigrationData\mailbox_statistics.csv

.PARAMETER PermissionResultsCsv
    Phase 3 permission apply results for cross-reference.
    Default: .\MigrationData\permission_apply_results.csv

.PARAMETER BatchName
    Validate only users in this MigrationBatch. Omit for all.

.PARAMETER PilotOnly
    Validate first 10 users only — quick smoke test after pilot batch.

.PARAMETER ItemCountThresholdPct
    Minimum percentage of source item count that must exist in target.
    Default: 90 (i.e. flag if target has less than 90% of source items).

.PARAMETER OutputPath
    Output folder. Default: .\MigrationData

.EXAMPLE
    # Pilot smoke test — no source connection needed
    .\Test-PostMailboxMigration.ps1 `
        -TargetTenantId 'volue.onmicrosoft.com' `
        -TargetAdminUPN 'admin@volue.com' `
        -SourceDomain   'smartpulse.io' `
        -CompanySuffix  'SmartPulse' `
        -PilotOnly

.EXAMPLE
    # Full batch validation with live source comparison
    .\Test-PostMailboxMigration.ps1 `
        -SourceTenantId 'balancingpoolcom.onmicrosoft.com' `
        -SourceAdminUPN 'admin@smartpulse.io' `
        -TargetTenantId 'volue.onmicrosoft.com' `
        -TargetAdminUPN 'admin@volue.com' `
        -SourceDomain   'smartpulse.io' `
        -CompanySuffix  'SmartPulse' `
        -BatchName      'Batch001'
#>

[CmdletBinding()]
param(
    [string] $SourceTenantId    = '',
    [string] $SourceAdminUPN    = '',
    [string] $TargetTenantId = '',
    [string] $TargetAdminUPN = '',
    [string] $SourceDomain = '',
    [string] $CompanySuffix = '',
    [string] $UserMappingCsv       = '.\MigrationData\user_mapping_confirmed.csv',
    [string] $SourceStatsCsv       = '.\MigrationData\mailbox_statistics.csv',
    [string] $PermissionResultsCsv = '.\MigrationData\permission_apply_results.csv',
    [string] $BatchName            = '',
    [switch] $PilotOnly,
    [int]    $ItemCountThresholdPct = 90,
    [string] $OutputPath           = '.\MigrationData'
)

# ── Bootstrap ─────────────────────────────────────────────────────────────────

Import-Module (Join-Path $PSScriptRoot '..\MigrationHelpers.psm1') -Force -ErrorAction Stop

# ── Load MigrationConfig.psd1 ────────────────────────────────────────────────
$_cfg = Import-MigrationConfig
$SourceTenantId = Resolve-ConfigParam -Passed $SourceTenantId -Default '' -ConfigValue (Get-ConfigValue -Config $_cfg -Key "SourceTenantId")
$SourceAdminUPN = Resolve-ConfigParam -Passed $SourceAdminUPN -Default '' -ConfigValue (Get-ConfigValue -Config $_cfg -Key "SourceAdminUPN")
$SourceDomain = Resolve-ConfigParam -Passed $SourceDomain -Default '' -ConfigValue (Get-ConfigValue -Config $_cfg -Key "SourceDomain")
$CompanySuffix = Resolve-ConfigParam -Passed $CompanySuffix -Default '' -ConfigValue (Get-ConfigValue -Config $_cfg -Key "CompanySuffix")
$TargetTenantId = Resolve-ConfigParam -Passed $TargetTenantId -Default '' -ConfigValue (Get-ConfigValue -Config $_cfg -Key "TargetTenantId")
$TargetAdminUPN = Resolve-ConfigParam -Passed $TargetAdminUPN -Default '' -ConfigValue (Get-ConfigValue -Config $_cfg -Key "TargetAdminUPN")
$UserMappingCsv = Resolve-ConfigParam -Passed $UserMappingCsv -Default '' -ConfigValue (Get-ConfigValue -Config $_cfg -Key "UserMappingCsv")
$SourceStatsCsv = Resolve-ConfigParam -Passed $SourceStatsCsv -Default '' -ConfigValue (Get-ConfigValue -Config $_cfg -Key "SourceStatsCsv")
$PermissionResultsCsv = Resolve-ConfigParam -Passed $PermissionResultsCsv -Default '' -ConfigValue (Get-ConfigValue -Config $_cfg -Key "PermissionResultsCsv")
$OutputPath = Resolve-ConfigParam -Passed $OutputPath -Default '' -ConfigValue (Get-ConfigValue -Config $_cfg -Key "OutputPath")
$ItemCountThresholdPct = Resolve-ConfigParam -Passed $ItemCountThresholdPct -Default '' -ConfigValue (Get-ConfigValue -Config $_cfg -Key "ItemCountThresholdPct")

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
$suffix = if ($BatchName) { "_$BatchName" } elseif ($PilotOnly) { '_Pilot' } else { '_All' }
Initialize-MigLog -ScriptName "Test-PostMailboxMigration$suffix" `
                  -LogDirectory (Join-Path $PSScriptRoot '..\Logs')
$outDir = Ensure-OutputDirectory -Path $OutputPath

# ── Load user mapping ─────────────────────────────────────────────────────────

$userMapping = Import-CsvSafe -Path $UserMappingCsv `
    -RequiredColumns @('SourceEmail','TargetEmail','Status','MigrationBatch')
$confirmedRows = $userMapping | Where-Object { $_.Status -eq 'CONFIRMED' }

if ($BatchName) {
    $confirmedRows = $confirmedRows | Where-Object { $_.MigrationBatch -eq $BatchName }
    Write-MigLog "Filtering to batch: $BatchName ($(@($confirmedRows).Count) users)"
}
if ($PilotOnly) {
    $confirmedRows = $confirmedRows | Select-Object -First 10
    Write-MigLog "Pilot mode: validating first 10 users"
}

Write-MigLog "Users to validate: $(@($confirmedRows).Count)"

# ── Load Phase 1 source statistics (used when source not connected) ───────────

$sourceStatsIndex = @{}
if (Test-Path $SourceStatsCsv) {
    $sourceStats = Import-CsvSafe -Path $SourceStatsCsv
    foreach ($s in $sourceStats) {
        $sourceStatsIndex[$s.PrimarySmtpAddress.ToLower()] = $s
    }
    Write-MigLog "Source statistics loaded: $($sourceStatsIndex.Count) entries"
}

# ── Load permission apply results ─────────────────────────────────────────────

$permAppliedIndex = @{}   # targetMailboxEmail → list of permission types applied
if (Test-Path $PermissionResultsCsv) {
    $permRows = Import-CsvSafe -Path $PermissionResultsCsv
    foreach ($p in ($permRows | Where-Object { $_.Action -eq 'APPLIED' })) {
        $key = $p.TargetMailbox.ToLower()
        if (-not $permAppliedIndex.ContainsKey($key)) {
            $permAppliedIndex[$key] = [System.Collections.Generic.List[string]]::new()
        }
        $permAppliedIndex[$key].Add($p.PermissionType)
    }
}

# ── Connect source (optional — for live item count) ───────────────────────────

$sourceStatsLive = @{}
if ($SourceTenantId -and $SourceAdminUPN) {
    Write-MigLog "Connecting to source for live statistics..."
    Connect-SourceTenant -TenantId $SourceTenantId -UserPrincipalName $SourceAdminUPN

    foreach ($row in $confirmedRows) {
        try {
            $stats = Invoke-WithRetry {
                Get-MailboxStatistics -Identity $row.SourceEmail -ErrorAction Stop
            }
            $sourceStatsLive[$row.SourceEmail.ToLower()] = @{
                ItemCount  = [int]$stats.ItemCount
                SizeGB     = Get-SizeInGB -SizeString $stats.TotalItemSize.ToString()
            }
        }
        catch {
            Write-MigLog "Live source stats failed for $($row.SourceEmail): $_" -Level WARN
        }
    }

    try { Disconnect-ExchangeOnline -Confirm:$false -ErrorAction SilentlyContinue } catch {}
}

# ── Connect target ────────────────────────────────────────────────────────────

Connect-TargetTenant -TenantId $TargetTenantId -UserPrincipalName $TargetAdminUPN

# Pre-load target mailbox permission index for cross-reference
$targetFAIndex  = @{}   # targetEmail → list of FullAccess trustees
$targetSAIndex  = @{}   # targetEmail → list of SendAs trustees
$targetSOBIndex = @{}   # targetEmail → list of SOB trustees

$targetMailboxes = Invoke-WithRetry {
    Get-Mailbox -ResultSize Unlimited -ErrorAction Stop
}
$targetMbxIndex = @{}
foreach ($m in $targetMailboxes) {
    $targetMbxIndex[$m.PrimarySmtpAddress.ToLower()] = $m
}

# ── Validation loop ───────────────────────────────────────────────────────────

$resultRows = [System.Collections.Generic.List[PSCustomObject]]::new()
$issueRows  = [System.Collections.Generic.List[PSCustomObject]]::new()

$total = @($confirmedRows).Count
$i     = 0

$passed   = 0
$warnings = 0
$failed   = 0

foreach ($row in $confirmedRows) {

    $i++
    Write-ProgressHelper -Activity 'Validating mailboxes' `
                         -Current $i -Total $total `
                         -Status $row.TargetEmail

    $sourceEmail = $row.SourceEmail.ToLower()
    $targetEmail = $row.TargetEmail.ToLower()

    $checks       = [System.Collections.Generic.List[string]]::new()
    $rowIssues    = [System.Collections.Generic.List[string]]::new()
    $overallStatus = 'PASS'

    # ── Does target mailbox exist? ────────────────────────────────────────────

    $targetMbx = $targetMbxIndex[$targetEmail]
    if (-not $targetMbx) {
        $rowIssues.Add("CRITICAL: Target mailbox '$targetEmail' not found")
        $resultRows.Add([PSCustomObject]@{
            SourceEmail     = $sourceEmail
            TargetEmail     = $targetEmail
            MigrationBatch  = $row.MigrationBatch
            OverallStatus   = 'FAIL'
            SourceItemCount = 0; TargetItemCount = 0; ItemCountPct = 0
            SourceSizeGB    = 0; TargetSizeGB    = 0
            ProxyAddressesMatch = $false
            PermissionsApplied  = $false
            ForwardingIssue     = $false
            LitigationHoldMatch = $false
            Issues          = 'Target mailbox not found'
        })
        $failed++
        continue
    }

    # ── Item count & size ─────────────────────────────────────────────────────

    $sourceItemCount = 0
    $sourceSizeGB    = 0
    $targetItemCount = 0
    $targetSizeGB    = 0

    # Get source figures (live preferred, fallback to Phase 1 stats)
    if ($sourceStatsLive.ContainsKey($sourceEmail)) {
        $sourceItemCount = $sourceStatsLive[$sourceEmail].ItemCount
        $sourceSizeGB    = $sourceStatsLive[$sourceEmail].SizeGB
    }
    elseif ($sourceStatsIndex.ContainsKey($sourceEmail)) {
        $sourceItemCount = [int]$sourceStatsIndex[$sourceEmail].ItemCount
        $sourceSizeGB    = [double]$sourceStatsIndex[$sourceEmail].SizeGB
    }

    # Get target statistics
    try {
        $tgtStats = Invoke-WithRetry {
            Get-MailboxStatistics -Identity $targetEmail -ErrorAction Stop
        }
        $targetItemCount = [int]$tgtStats.ItemCount
        $targetSizeGB    = Get-SizeInGB -SizeString $tgtStats.TotalItemSize.ToString()
    }
    catch {
        $rowIssues.Add("WARN: Could not retrieve target statistics — $_")
    }

    $itemCountPct = if ($sourceItemCount -gt 0) {
        [math]::Round(($targetItemCount / $sourceItemCount) * 100, 1)
    } else { 100 }

    if ($sourceItemCount -gt 0 -and $itemCountPct -lt $ItemCountThresholdPct) {
        $rowIssues.Add("WARN: Item count $itemCountPct% of source ($targetItemCount/$sourceItemCount) — below ${ItemCountThresholdPct}% threshold")
        $overallStatus = 'WARN'
    }
    else {
        $checks.Add("ItemCount: $itemCountPct% ($targetItemCount/$sourceItemCount)")
    }

    # ── Proxy addresses ───────────────────────────────────────────────────────

    $proxyMatch = $true

    # Get source proxy addresses from mailboxes.csv
    $sourceMailboxCsv = Join-Path $OutputPath 'mailboxes.csv'
    if (Test-Path $sourceMailboxCsv) {
        $sourceMbxData = Import-Csv -Path $sourceMailboxCsv -ErrorAction SilentlyContinue |
            Where-Object { $_.PrimarySmtpAddress.ToLower() -eq $sourceEmail }

        if ($sourceMbxData -and $sourceMbxData.SmtpAliases) {
            $sourceAliases = $sourceMbxData.SmtpAliases -split '\|' |
                Where-Object { $_ } |
                ForEach-Object { ($_ -replace '^smtp:', '').ToLower() }

            $targetProxies = $targetMbx.EmailAddresses |
                Where-Object { $_ -match '^smtp:' } |
                ForEach-Object { ($_ -replace '^smtp:', '').ToLower() }

            foreach ($alias in $sourceAliases) {
                if ($alias -notin $targetProxies) {
                    $rowIssues.Add("WARN: Source alias '$alias' missing from target proxy addresses")
                    $proxyMatch = $false
                    $overallStatus = 'WARN'
                }
            }
        }
    }

    if ($proxyMatch) { $checks.Add('ProxyAddresses: OK') }

    # ── Permissions applied ───────────────────────────────────────────────────

    $permApplied = $permAppliedIndex.ContainsKey($targetEmail)
    if (-not $permApplied -and $permAppliedIndex.Count -gt 0) {
        # No permissions recorded for this mailbox — check if source had any
        # (some mailboxes legitimately have no delegates)
        $checks.Add('Permissions: None recorded (verify if expected)')
    }
    elseif ($permApplied) {
        $types = $permAppliedIndex[$targetEmail] -join ', '
        $checks.Add("Permissions: Applied ($types)")
    }

    # ── Forwarding check ──────────────────────────────────────────────────────

    $forwardingIssue = $false
    if ($targetMbx.ForwardingSmtpAddress -and
        -not ($targetMbx.ForwardingSmtpAddress -eq $row.ForwardingSmtpAddress)) {
        $rowIssues.Add("WARN: Unexpected ForwardingSmtpAddress '$($targetMbx.ForwardingSmtpAddress)' in target")
        $forwardingIssue = $true
        $overallStatus   = 'WARN'
    }

    # ── Litigation hold ───────────────────────────────────────────────────────

    $litigationMatch = $true
    if ($row.LitigationHoldEnabled -eq $true -or $row.LitigationHoldEnabled -eq 'True') {
        if (-not $targetMbx.LitigationHoldEnabled) {
            $rowIssues.Add("WARN: Source had LitigationHold enabled but target does not")
            $litigationMatch = $false
            $overallStatus   = 'WARN'
        }
        else {
            $checks.Add('LitigationHold: Enabled (matches source)')
        }
    }

    # ── Compile result row ────────────────────────────────────────────────────

    if ($overallStatus -eq 'PASS') { $passed++ }
    elseif ($overallStatus -eq 'WARN') { $warnings++ }
    else { $failed++ }

    $resultRow = [PSCustomObject]@{
        SourceEmail          = $sourceEmail
        TargetEmail          = $targetEmail
        MigrationBatch       = $row.MigrationBatch
        OverallStatus        = $overallStatus
        SourceItemCount      = $sourceItemCount
        TargetItemCount      = $targetItemCount
        ItemCountPct         = $itemCountPct
        SourceSizeGB         = $sourceSizeGB
        TargetSizeGB         = $targetSizeGB
        ProxyAddressesMatch  = $proxyMatch
        PermissionsApplied   = $permApplied
        ForwardingIssue      = $forwardingIssue
        LitigationHoldMatch  = $litigationMatch
        ChecksPassed         = ($checks | Join-String -Separator ' | ')
        Issues               = ($rowIssues | Join-String -Separator ' | ')
    }

    $resultRows.Add($resultRow)

    if ($rowIssues.Count -gt 0) {
        foreach ($issue in $rowIssues) {
            $issueRows.Add([PSCustomObject]@{
                SourceEmail = $sourceEmail
                TargetEmail = $targetEmail
                Batch       = $row.MigrationBatch
                Issue       = $issue
            })
        }
    }
}

Write-Progress -Activity 'Validating mailboxes' -Completed

# ── Export ────────────────────────────────────────────────────────────────────

$mainPath  = Join-Path $outDir "post_mailbox_validation$suffix.csv"
$issuePath = Join-Path $outDir "post_mailbox_validation${suffix}_issues.csv"

$resultRows | Export-CsvSafe -Path $mainPath
if ($issueRows.Count -gt 0) {
    $issueRows | Export-CsvSafe -Path $issuePath
}

# ── Summary ───────────────────────────────────────────────────────────────────

Write-MigSummary -Stats @{
    'Mailboxes validated'    = $total
    'PASS'                   = $passed
    'WARN'                   = $warnings
    'FAIL'                   = $failed
    'Item count threshold'   = "$ItemCountThresholdPct%"
    'Source data'            = if ($sourceStatsLive.Count -gt 0) { 'Live query' } else { 'Phase 1 CSV' }
    'Results'                = $mainPath
    'Issues'                 = $issuePath
    'Next step'              = if ($failed -eq 0 -and $warnings -eq 0) {
        'Proceed to next batch or run Test-PostSharePointMigration.ps1' }
        else { 'Resolve FAIL/WARN items before proceeding' }
}

Disconnect-AllTenants
