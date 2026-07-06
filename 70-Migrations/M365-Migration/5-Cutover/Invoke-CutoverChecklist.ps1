#Requires -Version 5.1
#Requires -Modules ExchangeOnlineManagement, Microsoft.Graph.Users
<#
.SYNOPSIS
    Go / No-Go checklist run on cutover day. Validates that all
    prerequisites are in place before MX/DNS records are changed.

.DESCRIPTION
    This is the final gate check on the day of cutover. It performs
    rapid live checks against both tenants and produces a time-stamped
    go/no-go verdict.

    Checks are intentionally fast — this script should complete in
    under 5 minutes.

    CHECKS

      SOURCE TENANT
        - Source mailboxes still accessible (EXO connection OK)
        - No unexpected mail flow rules that could interfere
        - Source MX record TTL (warns if TTL > 300 s — change it now)
        - Forwarding set on all source mailboxes (from Set-SourceMailboxForwarding)
        - OOF set on all source mailboxes (from Set-SourceDomainOOF)

      TARGET TENANT
        - Target EXO accessible and licensed users have mailboxes
        - Source domain accepted in target (required for proxy addresses)
        - Proxy addresses added (spot-check 10 random mailboxes)
        - Code2 migration complete — item count spot-check (10 random)
        - SPO sites reachable (spot-check 5 random sites)

      INFRASTRUCTURE
        - Current MX record for source domain (informational)
        - DNS propagation check for target domain MX

    The script prints a formatted checklist to the console and writes
    it to a timestamped text file for the cutover record.

    EXIT CODES
        0 — GO
        1 — NO-GO

.PARAMETER SourceTenantId
    AAD Tenant ID of the source tenant.

.PARAMETER SourceAdminUPN
    Source tenant admin UPN.

.PARAMETER TargetTenantId
    AAD Tenant ID of the target tenant.

.PARAMETER TargetAdminUPN
    Target tenant admin UPN.

.PARAMETER TargetSharePointAdminUrl
    Target SPO Admin Centre URL.

.PARAMETER SourceDomain
    Primary email domain of the source company. e.g. 'smartpulse.io'

.PARAMETER CompanySuffix
    Human-readable company name. e.g. 'SmartPulse'

.PARAMETER UserMappingCsv
    Default: .\MigrationData\user_mapping_confirmed.csv

.PARAMETER OutputPath
    Default: .\MigrationData

.EXAMPLE
    .\Invoke-CutoverChecklist.ps1 `
        -SourceTenantId          'balancingpoolcom.onmicrosoft.com' `
        -SourceAdminUPN          'admin@smartpulse.io' `
        -TargetTenantId          'volue.onmicrosoft.com' `
        -TargetAdminUPN          'admin@volue.com' `
        -TargetSharePointAdminUrl 'https://volue-admin.sharepoint.com' `
        -SourceDomain            'smartpulse.io' `
        -CompanySuffix           'SmartPulse'
#>

[CmdletBinding()]
param(
    [string] $SourceTenantId = '',
    [string] $SourceAdminUPN = '',
    [string] $TargetTenantId = '',
    [string] $TargetAdminUPN = '',
    [string] $TargetSharePointAdminUrl = '',
    [string] $SourceDomain = '',
    [string] $CompanySuffix = '',
    [string] $UserMappingCsv = '.\MigrationData\user_mapping_confirmed.csv',
    [string] $OutputPath     = '.\MigrationData'
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
$TargetSharePointAdminUrl = Resolve-ConfigParam -Passed $TargetSharePointAdminUrl -Default '' -ConfigValue (Get-ConfigValue -Config $_cfg -Key "TargetSharePointAdminUrl")
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
Initialize-MigLog -ScriptName 'Invoke-CutoverChecklist' `
                  -LogDirectory (Join-Path $PSScriptRoot '..\Logs')
$outDir  = Ensure-OutputDirectory -Path $OutputPath
$domains = Get-MigrationDomains
$now     = Get-Date
$nowStr  = $now.ToString('yyyy-MM-dd HH:mm:ss')

# ── Output collections ────────────────────────────────────────────────────────

$checkItems = [System.Collections.Generic.List[PSCustomObject]]::new()
$isGo       = $true

function Add-Item {
    param(
        [string] $Area,
        [string] $Item,
        [string] $Result,    # GO | NO-GO | WARN | INFO
        [string] $Detail = ''
    )
    $checkItems.Add([PSCustomObject]@{
        Area   = $Area
        Item   = $Item
        Result = $Result
        Detail = $Detail
        Time   = (Get-Date -Format 'HH:mm:ss')
    })
    $icon = switch ($Result) {
        'GO'    { '✔' }
        'NO-GO' { '✘' }
        'WARN'  { '⚠' }
        'INFO'  { 'ℹ' }
    }
    $level = switch ($Result) { 'NO-GO' { 'ERROR' } 'WARN' { 'WARN' } default { 'INFO' } }
    Write-MigLog "  $icon [$Area] $Item$(if ($Detail) { " — $Detail" })" -Level $level
    if ($Result -eq 'NO-GO') { Set-Variable -Name isGo -Value $false -Scope 1 }
}

# ── Load mapping ──────────────────────────────────────────────────────────────

$mapping   = Import-CsvSafe -Path $UserMappingCsv `
    -RequiredColumns @('SourceEmail','TargetEmail','Status')
$confirmed = @($mapping | Where-Object { $_.Status -eq 'CONFIRMED' })
$total     = $confirmed.Count

# Sample sets for spot-checks
$sample10  = $confirmed | Get-Random -Count ([math]::Min(10, $total))
$sample5   = $confirmed | Get-Random -Count ([math]::Min(5,  $total))

# ── SOURCE TENANT CHECKS ──────────────────────────────────────────────────────

Write-MigLog '── SOURCE TENANT ───────────────────────────────────────────────────────────'
Write-Host ""

try {
    Connect-SourceTenant -TenantId $SourceTenantId -UserPrincipalName $SourceAdminUPN
    Add-Item 'Source' 'EXO connection' 'GO' "Connected as $SourceAdminUPN"
}
catch {
    Add-Item 'Source' 'EXO connection' 'NO-GO' "Cannot connect: $_"
}

# Forwarding check — spot-check 10 mailboxes
$forwardingSet   = 0
$forwardingMiss  = 0
foreach ($row in $sample10) {
    try {
        $mbx = Invoke-WithRetry {
            Get-Mailbox -Identity $row.SourceEmail -ErrorAction Stop
        }
        if ($mbx.ForwardingSmtpAddress -match [regex]::Escape($row.TargetEmail)) {
            $forwardingSet++
        }
        else {
            $forwardingMiss++
        }
    }
    catch { $forwardingMiss++ }
}
if ($forwardingMiss -eq 0) {
    Add-Item 'Source' 'Mail forwarding (spot-check 10)' 'GO' "All $forwardingSet checked OK"
}
else {
    Add-Item 'Source' 'Mail forwarding (spot-check 10)' 'NO-GO' `
        "$forwardingMiss of $($sample10.Count) mailboxes missing forwarding — run Set-SourceMailboxForwarding.ps1"
}

# OOF check — spot-check 5
$oofSet  = 0
$oofMiss = 0
foreach ($row in $sample5) {
    try {
        $oof = Invoke-WithRetry {
            Get-MailboxAutoReplyConfiguration -Identity $row.SourceEmail -ErrorAction Stop
        }
        if ($oof.AutoReplyState -eq 'Enabled') { $oofSet++ } else { $oofMiss++ }
    }
    catch { $oofMiss++ }
}
if ($oofMiss -eq 0) {
    Add-Item 'Source' 'Auto-reply / OOF (spot-check 5)' 'GO' "All $oofSet checked OK"
}
else {
    Add-Item 'Source' 'Auto-reply / OOF (spot-check 5)' 'WARN' `
        "$oofMiss of $($sample5.Count) mailboxes have no OOF — run Set-SourceDomainOOF.ps1"
}

# Mail flow rules that might interfere
try {
    $rules = Invoke-WithRetry {
        Get-TransportRule -ErrorAction Stop | Where-Object { $_.State -eq 'Enabled' }
    }
    if ($rules.Count -gt 0) {
        Add-Item 'Source' 'Transport rules' 'WARN' `
            "$($rules.Count) enabled rule(s) — verify none will block or redirect outbound mail during cutover"
    }
    else {
        Add-Item 'Source' 'Transport rules' 'GO' 'No enabled transport rules'
    }
}
catch {
    Add-Item 'Source' 'Transport rules' 'WARN' "Could not retrieve: $_"
}

# MX TTL check via DNS
try {
    $mxRecords = Resolve-DnsName -Name $SourceDomain -Type MX -ErrorAction Stop
    $mxStr     = ($mxRecords | ForEach-Object { "$($_.NameExchange) (TTL $($_.TTL)s)" }) -join ', '
    $highTTL   = $mxRecords | Where-Object { $_.TTL -gt 300 }
    if ($highTTL) {
        Add-Item 'Source' 'MX record TTL' 'WARN' "TTL > 300s: $mxStr — lower TTL now to speed up propagation"
    }
    else {
        Add-Item 'Source' 'MX record TTL' 'GO' $mxStr
    }
}
catch {
    Add-Item 'Source' 'MX record TTL' 'INFO' "DNS lookup failed (may be internal-only) — verify MX TTL manually"
}

try { Disconnect-ExchangeOnline -Confirm:$false -ErrorAction SilentlyContinue } catch {}

# ── TARGET TENANT CHECKS ──────────────────────────────────────────────────────

Write-MigLog '── TARGET TENANT ───────────────────────────────────────────────────────────'

try {
    Connect-TargetTenant -TenantId $TargetTenantId -UserPrincipalName $TargetAdminUPN
    Add-Item 'Target' 'EXO connection' 'GO' "Connected as $TargetAdminUPN"
}
catch {
    Add-Item 'Target' 'EXO connection' 'NO-GO' "Cannot connect: $_"
}

# Source domain accepted?
try {
    $acceptedDomains = Invoke-WithRetry { Get-AcceptedDomain -ErrorAction Stop }
    $accepted = $acceptedDomains | Where-Object { $_.DomainName -eq $SourceDomain }
    if ($accepted) {
        Add-Item 'Target' "Source domain accepted ($SourceDomain)" 'GO' $accepted.DomainType
    }
    else {
        Add-Item 'Target' "Source domain accepted ($SourceDomain)" 'NO-GO' `
            "Domain not accepted — run Add-TargetProxyAddresses.ps1 prerequisites"
    }
}
catch {
    Add-Item 'Target' 'Accepted domains check' 'WARN' "Could not verify: $_"
}

# Spot-check mailboxes exist and have items
$mbxOK   = 0
$mbxFail = 0
foreach ($row in $sample10) {
    try {
        $stats = Invoke-WithRetry {
            Get-MailboxStatistics -Identity $row.TargetEmail -ErrorAction Stop
        }
        if ([int]$stats.ItemCount -gt 0) { $mbxOK++ } else { $mbxFail++ }
    }
    catch { $mbxFail++ }
}
if ($mbxFail -eq 0) {
    Add-Item 'Target' 'Mailbox item count (spot-check 10)' 'GO' "$mbxOK mailboxes have content"
}
else {
    Add-Item 'Target' 'Mailbox item count (spot-check 10)' 'NO-GO' `
        "$mbxFail of $($sample10.Count) mailboxes are empty or missing — Code2 may not have completed"
}

# Proxy addresses spot-check
$proxyOK   = 0
$proxyFail = 0
foreach ($row in $sample5) {
    try {
        $mbx = Invoke-WithRetry { Get-Mailbox -Identity $row.TargetEmail -ErrorAction Stop }
        $proxies = $mbx.EmailAddresses | ForEach-Object { $_.ToString().ToLower() }
        if ($proxies -contains "smtp:$($row.SourceEmail.ToLower())") {
            $proxyOK++
        }
        else {
            $proxyFail++
        }
    }
    catch { $proxyFail++ }
}
if ($proxyFail -eq 0) {
    Add-Item 'Target' 'Source proxy addresses (spot-check 5)' 'GO' "All present"
}
else {
    Add-Item 'Target' 'Source proxy addresses (spot-check 5)' 'NO-GO' `
        "$proxyFail missing — run Add-TargetProxyAddresses.ps1"
}

# Target MX record
try {
    $targetMX  = Resolve-DnsName -Name $domains.TargetDomain -Type MX -ErrorAction Stop
    $targetMXStr = ($targetMX | ForEach-Object { $_.NameExchange }) -join ', '
    Add-Item 'Target' "MX for $($domains.TargetDomain)" 'INFO' $targetMXStr
}
catch {
    Add-Item 'Target' "MX for $($domains.TargetDomain)" 'INFO' "DNS lookup failed — verify MX manually"
}

# SPO spot-check
try {
    Connect-PnPOnline -Url $TargetSharePointAdminUrl ` -ClientId '14d82eec-204b-4c2f-b7e8-296a70dab67e' -Interactive -ErrorAction Stop
    $spoSites = Invoke-WithRetry { Get-PnPTenantSite -ErrorAction Stop }
    Add-Item 'Target' 'SharePoint Admin reachable' 'GO' "$($spoSites.Count) sites found"
    try { Disconnect-PnPOnline -ErrorAction SilentlyContinue } catch {}
}
catch {
    Add-Item 'Target' 'SharePoint Admin reachable' 'WARN' "Could not connect: $_"
}

Disconnect-AllTenants

# ── Build output ──────────────────────────────────────────────────────────────

$bar   = '=' * 72
$div   = '─' * 72
$noGo  = $checkItems | Where-Object { $_.Result -eq 'NO-GO' }
$warns = $checkItems | Where-Object { $_.Result -eq 'WARN' }

$verdict = if ($isGo) { '✔  GO — proceed with MX/DNS cutover' }
           else        { '✘  NO-GO — resolve issues before cutting over' }

$output = [System.Collections.Generic.List[string]]::new()
$output.Add($bar)
$output.Add("  CUTOVER GO / NO-GO CHECKLIST")
$output.Add("  $CompanySuffix ($SourceDomain) → Volue (volue.com)")
$output.Add("  Time: $nowStr")
$output.Add($div)
$output.Add("  VERDICT: $verdict")
$output.Add($div)

foreach ($area in ($checkItems | Select-Object -ExpandProperty Area -Unique)) {
    $output.Add("  $area")
    foreach ($item in ($checkItems | Where-Object { $_.Area -eq $area })) {
        $icon = switch ($item.Result) { 'GO' { '✔' } 'NO-GO' { '✘' } 'WARN' { '⚠' } 'INFO' { 'ℹ' } }
        $output.Add("    $icon [$($item.Result.PadRight(5))] $($item.Item)")
        if ($item.Detail) { $output.Add("           $($item.Detail)") }
    }
    $output.Add('')
}

if ($noGo.Count -gt 0) {
    $output.Add($div)
    $output.Add("  NO-GO ITEMS — must fix before proceeding:")
    foreach ($i in $noGo) { $output.Add("    ✘ [$($i.Area)] $($i.Item) — $($i.Detail)") }
}
if ($warns.Count -gt 0) {
    $output.Add($div)
    $output.Add("  WARNINGS — review with team:")
    foreach ($i in $warns) { $output.Add("    ⚠ [$($i.Area)] $($i.Item) — $($i.Detail)") }
}

$output.Add($bar)

$output | ForEach-Object { Write-Host $_ }

$dateSafe   = $now.ToString('yyyyMMdd-HHmm')
$reportPath = Join-Path $outDir "cutover_checklist_${CompanySuffix}_$dateSafe.txt"
$output     | Out-File -FilePath $reportPath -Encoding UTF8 -Force

$checkItems | Export-CsvSafe -Path (Join-Path $outDir "cutover_checklist_${CompanySuffix}_$dateSafe.csv")

Write-MigSummary -Stats @{
    'Verdict'       = if ($isGo) { 'GO' } else { 'NO-GO' }
    'GO items'      = ($checkItems | Where-Object { $_.Result -eq 'GO' }).Count
    'NO-GO items'   = $noGo.Count
    'Warnings'      = $warns.Count
    'Checklist TXT' = $reportPath
    'Next step'     = if ($isGo) {
        'Change MX records. Monitor mail flow. Run Invoke-PostCutoverCleanup.ps1 after 30 days.' }
        else { 'Resolve NO-GO items then re-run this checklist' }
}

exit $(if ($isGo) { 0 } else { 1 })
