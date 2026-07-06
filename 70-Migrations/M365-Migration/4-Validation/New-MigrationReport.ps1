#Requires -Version 5.1
<#
.SYNOPSIS
    Generates the final migration sign-off report by aggregating all
    Phase 4 validation outputs into a single human-readable document.

.DESCRIPTION
    Reads every validation CSV produced by the Phase 4 scripts and
    produces:

        EXCEL WORKBOOK (migration_signoff_report.xlsx)
            Sheet 1 : Executive Summary — counts by area, overall status
            Sheet 2 : Mailbox Validation — per-mailbox results
            Sheet 3 : SharePoint Validation — per-site results
            Sheet 4 : OneDrive Validation — per-OneDrive results
            Sheet 5 : Group Validation — DL + M365 Group results
            Sheet 6 : Open Issues — all FAIL/WARN rows across all sheets
            Sheet 7 : Guest Actions Required — pending re-invitations
            Sheet 8 : Migration Mapping Summary — confirmed rows by area

        PLAIN TEXT SUMMARY (migration_signoff_summary.txt)
            Single-page readable summary for sign-off email / Teams message.

    The script does NOT require any tenant connections — it only reads
    CSV files produced by earlier scripts.

    SIGN-OFF STATUS
        READY FOR SIGN-OFF   — no FAIL rows, warnings reviewed
        PENDING REVIEW       — WARN rows present, needs human review
        NOT READY            — FAIL rows present, must remediate

.PARAMETER SourceDomain
    Primary email domain of the source company. e.g. 'smartpulse.io'

.PARAMETER CompanySuffix
    Human-readable company name. e.g. 'SmartPulse'

.PARAMETER InputPath
    Folder containing all MigrationData CSVs. Default: .\MigrationData

.PARAMETER OutputPath
    Folder for the report outputs. Default: .\MigrationData

.PARAMETER ReviewedBy
    Name of the person signing off. Stamped into the report.

.EXAMPLE
    .\New-MigrationReport.ps1 `
        -SourceDomain  'smartpulse.io' `
        -CompanySuffix 'SmartPulse' `
        -ReviewedBy    'Jane Smith'
#>

[CmdletBinding()]
param(
    [string] $SourceDomain = '',
    [string] $CompanySuffix = '',
    [string] $InputPath  = '.\MigrationData',
    [string] $OutputPath = '.\MigrationData',
    [string] $ReviewedBy = ''
)

# ── Bootstrap ─────────────────────────────────────────────────────────────────

Import-Module (Join-Path $PSScriptRoot '..\MigrationHelpers.psm1') -Force -ErrorAction Stop

# ── Load MigrationConfig.psd1 ────────────────────────────────────────────────
$_cfg = Import-MigrationConfig
$SourceDomain = Resolve-ConfigParam -Passed $SourceDomain -Default '' -ConfigValue (Get-ConfigValue -Config $_cfg -Key "SourceDomain")
$CompanySuffix = Resolve-ConfigParam -Passed $CompanySuffix -Default '' -ConfigValue (Get-ConfigValue -Config $_cfg -Key "CompanySuffix")
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
Initialize-MigLog -ScriptName 'New-MigrationReport' `
                  -LogDirectory (Join-Path $PSScriptRoot '..\Logs')
$outDir   = Ensure-OutputDirectory -Path $OutputPath
$domains  = Get-MigrationDomains
$now      = Get-Date
$nowStr   = $now.ToString('yyyy-MM-dd HH:mm:ss')
$dateSafe = $now.ToString('yyyyMMdd-HHmm')

# ── Helper: safe CSV load ─────────────────────────────────────────────────────

function Load-Csv {
    param([string]$Name)
    $path = Join-Path $InputPath $Name
    if (Test-Path $path) {
        $rows = Import-Csv -Path $path -ErrorAction SilentlyContinue
        Write-MigLog "  Loaded $Name — $(@($rows).Count) rows"
        return @($rows)
    }
    Write-MigLog "  $Name not found — skipping" -Level WARN
    return @()
}

# ── Load all validation CSVs ──────────────────────────────────────────────────

Write-MigLog "Loading validation data from $InputPath..."

$mbxValidation    = Load-Csv 'post_mailbox_validation_All.csv'
# Also look for batch-specific files if _All not present
if ($mbxValidation.Count -eq 0) {
    $mbxFiles = Get-ChildItem -Path $InputPath -Filter 'post_mailbox_validation_Batch*.csv' `
                              -ErrorAction SilentlyContinue
    $mbxValidation = $mbxFiles | ForEach-Object { Import-Csv $_.FullName } | ForEach-Object { $_ }
    if ($mbxValidation.Count -gt 0) {
        Write-MigLog "  Loaded $($mbxValidation.Count) rows from batch files"
    }
}

$spoValidation    = Load-Csv 'post_spo_validation.csv'
$odValidation     = Load-Csv 'post_onedrive_validation.csv'
$dlValidation     = Load-Csv 'post_dl_validation.csv'
$m365Validation   = Load-Csv 'post_m365group_validation.csv'
$guestActions     = Load-Csv 'm365group_guest_actions_required.csv'
$preReadiness     = Load-Csv 'pre_migration_readiness.csv'
$userMapping      = Load-Csv 'user_mapping_confirmed.csv'
$sharedMapping    = Load-Csv 'shared_mailbox_mapping.csv'
$dlMapping        = Load-Csv 'dl_mapping.csv'
$spoMapping       = Load-Csv 'sharepoint_mapping.csv'
$licenseResults   = Load-Csv 'license_assignment_results.csv'
$permResults      = Load-Csv 'permission_apply_results.csv'

# ── Compute summary statistics ────────────────────────────────────────────────

function Get-StatusCounts {
    param($Rows)
    @{
        Total    = @($Rows).Count
        Pass     = @($Rows | Where-Object { $_.Status -eq 'PASS' -or $_.OverallStatus -eq 'PASS' }).Count
        Warn     = @($Rows | Where-Object { $_.Status -eq 'WARN' -or $_.OverallStatus -eq 'WARN' }).Count
        Fail     = @($Rows | Where-Object { $_.Status -eq 'FAIL' -or $_.OverallStatus -eq 'FAIL' }).Count
    }
}

$mbxCounts  = Get-StatusCounts $mbxValidation
$spoCounts  = Get-StatusCounts $spoValidation
$odCounts   = Get-StatusCounts $odValidation
$dlCounts   = Get-StatusCounts $dlValidation
$m365Counts = Get-StatusCounts $m365Validation

$totalFail  = $mbxCounts.Fail  + $spoCounts.Fail  + $odCounts.Fail  + $dlCounts.Fail  + $m365Counts.Fail
$totalWarn  = $mbxCounts.Warn  + $spoCounts.Warn  + $odCounts.Warn  + $dlCounts.Warn  + $m365Counts.Warn
$totalPass  = $mbxCounts.Pass  + $spoCounts.Pass  + $odCounts.Pass  + $dlCounts.Pass  + $m365Counts.Pass

$signOffStatus = if ($totalFail -gt 0)  { 'NOT READY — remediate FAIL items' }
                 elseif ($totalWarn -gt 0) { 'PENDING REVIEW — warnings need sign-off' }
                 else { 'READY FOR SIGN-OFF' }

$totalConfirmedUsers   = @($userMapping  | Where-Object { $_.Status -eq 'CONFIRMED' }).Count
$totalConfirmedShared  = @($sharedMapping | Where-Object { $_.Status -eq 'CONFIRMED' }).Count
$totalConfirmedDLs     = @($dlMapping    | Where-Object { $_.Status -eq 'CONFIRMED' }).Count
$totalConfirmedSPO     = @($spoMapping   | Where-Object { $_.Status -eq 'CONFIRMED' }).Count

$totalStorageSource = [math]::Round(($spoMapping | Measure-Object StorageUsedGB -Sum).Sum, 2)
$totalStorageTarget = [math]::Round(($spoValidation | Measure-Object TargetStorageGB -Sum).Sum, 2)

$licensesAssigned = @($licenseResults | Where-Object { $_.Action -eq 'ASSIGNED' }).Count
$permsApplied     = @($permResults    | Where-Object { $_.Action -eq 'APPLIED' }).Count
$guestsPending    = @($guestActions).Count

# ── Collect all open issues ───────────────────────────────────────────────────

$openIssues = [System.Collections.Generic.List[PSCustomObject]]::new()

foreach ($row in $mbxValidation  | Where-Object { $_.OverallStatus -ne 'PASS' -and $_.Issues }) {
    $openIssues.Add([PSCustomObject]@{ Area='Mailbox';    Item=$row.TargetEmail; Status=$row.OverallStatus; Issues=$row.Issues })
}
foreach ($row in $spoValidation  | Where-Object { $_.Status -ne 'PASS' -and $_.Issues }) {
    $openIssues.Add([PSCustomObject]@{ Area='SharePoint'; Item=$row.TargetUrl;   Status=$row.Status;        Issues=$row.Issues })
}
foreach ($row in $odValidation   | Where-Object { $_.Status -ne 'PASS' -and $_.Issues }) {
    $openIssues.Add([PSCustomObject]@{ Area='OneDrive';   Item=$row.TargetUrl;   Status=$row.Status;        Issues=$row.Issues })
}
foreach ($row in $dlValidation   | Where-Object { $_.Status -ne 'PASS' -and $_.Issues }) {
    $openIssues.Add([PSCustomObject]@{ Area='DL';         Item=$row.TargetEmail; Status=$row.Status;        Issues=$row.Issues })
}
foreach ($row in $m365Validation | Where-Object { $_.Status -ne 'PASS' -and $_.Issues }) {
    $openIssues.Add([PSCustomObject]@{ Area='M365Group';  Item=$row.TargetEmail; Status=$row.Status;        Issues=$row.Issues })
}

# ── Build Excel workbook ──────────────────────────────────────────────────────

Write-MigLog "Building Excel workbook..."

# Check if ImportExcel is available — install if not
if (-not (Get-Module -ListAvailable -Name ImportExcel)) {
    Write-MigLog "Installing ImportExcel module (required for report generation)..."
    Install-Module -Name ImportExcel -Scope CurrentUser -Force -ErrorAction Stop
}
Import-Module ImportExcel -Force

$xlPath = Join-Path $outDir "migration_signoff_report_${CompanySuffix}_$dateSafe.xlsx"

# ── Sheet 1: Executive Summary ────────────────────────────────────────────────

$execSummary = @(
    [PSCustomObject]@{ Metric = 'Report generated';            Value = $nowStr }
    [PSCustomObject]@{ Metric = 'Migration';                   Value = "$CompanySuffix ($SourceDomain) → Volue (volue.com)" }
    [PSCustomObject]@{ Metric = 'Reviewed by';                 Value = $ReviewedBy }
    [PSCustomObject]@{ Metric = '';                            Value = '' }
    [PSCustomObject]@{ Metric = '── SIGN-OFF STATUS';          Value = $signOffStatus }
    [PSCustomObject]@{ Metric = '';                            Value = '' }
    [PSCustomObject]@{ Metric = '── MAPPING SUMMARY';          Value = '' }
    [PSCustomObject]@{ Metric = 'Confirmed user mailboxes';    Value = $totalConfirmedUsers }
    [PSCustomObject]@{ Metric = 'Confirmed shared mailboxes';  Value = $totalConfirmedShared }
    [PSCustomObject]@{ Metric = 'Confirmed DLs';               Value = $totalConfirmedDLs }
    [PSCustomObject]@{ Metric = 'Confirmed SPO sites';         Value = $totalConfirmedSPO }
    [PSCustomObject]@{ Metric = '';                            Value = '' }
    [PSCustomObject]@{ Metric = '── VALIDATION RESULTS';       Value = '' }
    [PSCustomObject]@{ Metric = 'Mailboxes — Total';           Value = $mbxCounts.Total }
    [PSCustomObject]@{ Metric = 'Mailboxes — PASS';            Value = $mbxCounts.Pass }
    [PSCustomObject]@{ Metric = 'Mailboxes — WARN';            Value = $mbxCounts.Warn }
    [PSCustomObject]@{ Metric = 'Mailboxes — FAIL';            Value = $mbxCounts.Fail }
    [PSCustomObject]@{ Metric = 'SharePoint — Total';          Value = $spoCounts.Total }
    [PSCustomObject]@{ Metric = 'SharePoint — PASS';           Value = $spoCounts.Pass }
    [PSCustomObject]@{ Metric = 'SharePoint — WARN';           Value = $spoCounts.Warn }
    [PSCustomObject]@{ Metric = 'SharePoint — FAIL';           Value = $spoCounts.Fail }
    [PSCustomObject]@{ Metric = 'OneDrive — Total';            Value = $odCounts.Total }
    [PSCustomObject]@{ Metric = 'OneDrive — PASS';             Value = $odCounts.Pass }
    [PSCustomObject]@{ Metric = 'OneDrive — WARN';             Value = $odCounts.Warn }
    [PSCustomObject]@{ Metric = 'OneDrive — FAIL';             Value = $odCounts.Fail }
    [PSCustomObject]@{ Metric = 'DLs — Total';                 Value = $dlCounts.Total }
    [PSCustomObject]@{ Metric = 'DLs — PASS';                  Value = $dlCounts.Pass }
    [PSCustomObject]@{ Metric = 'DLs — WARN';                  Value = $dlCounts.Warn }
    [PSCustomObject]@{ Metric = 'DLs — FAIL';                  Value = $dlCounts.Fail }
    [PSCustomObject]@{ Metric = 'M365 Groups — Total';         Value = $m365Counts.Total }
    [PSCustomObject]@{ Metric = 'M365 Groups — PASS';          Value = $m365Counts.Pass }
    [PSCustomObject]@{ Metric = 'M365 Groups — WARN';          Value = $m365Counts.Warn }
    [PSCustomObject]@{ Metric = 'M365 Groups — FAIL';          Value = $m365Counts.Fail }
    [PSCustomObject]@{ Metric = '';                            Value = '' }
    [PSCustomObject]@{ Metric = '── TOTALS';                   Value = '' }
    [PSCustomObject]@{ Metric = 'Total checks PASS';           Value = $totalPass }
    [PSCustomObject]@{ Metric = 'Total checks WARN';           Value = $totalWarn }
    [PSCustomObject]@{ Metric = 'Total checks FAIL';           Value = $totalFail }
    [PSCustomObject]@{ Metric = 'Open issues';                 Value = $openIssues.Count }
    [PSCustomObject]@{ Metric = '';                            Value = '' }
    [PSCustomObject]@{ Metric = '── MIGRATION ACTIONS';        Value = '' }
    [PSCustomObject]@{ Metric = 'Licenses assigned';           Value = $licensesAssigned }
    [PSCustomObject]@{ Metric = 'Permissions applied';         Value = $permsApplied }
    [PSCustomObject]@{ Metric = 'Guest re-invitations pending';Value = $guestsPending }
    [PSCustomObject]@{ Metric = '';                            Value = '' }
    [PSCustomObject]@{ Metric = '── STORAGE';                  Value = '' }
    [PSCustomObject]@{ Metric = 'Source SPO total (GB)';       Value = $totalStorageSource }
    [PSCustomObject]@{ Metric = 'Target SPO total (GB)';       Value = $totalStorageTarget }
)

$xl = $execSummary | Export-Excel -Path $xlPath -WorksheetName 'Executive Summary' `
    -AutoSize -FreezeTopRow -BoldTopRow -PassThru

# Colour the sign-off status cell
$ws = $xl.Workbook.Worksheets['Executive Summary']
for ($r = 1; $r -le $ws.Dimension.Rows; $r++) {
    $cell = $ws.Cells[$r, 2]
    if ($cell.Value -eq 'READY FOR SIGN-OFF') {
        $cell.Style.Font.Color.SetColor([System.Drawing.Color]::FromArgb(0, 112, 0))
        $cell.Style.Font.Bold = $true
    }
    elseif ($cell.Value -like 'PENDING REVIEW*') {
        $cell.Style.Font.Color.SetColor([System.Drawing.Color]::FromArgb(156, 87, 0))
        $cell.Style.Font.Bold = $true
    }
    elseif ($cell.Value -like 'NOT READY*') {
        $cell.Style.Font.Color.SetColor([System.Drawing.Color]::FromArgb(192, 0, 0))
        $cell.Style.Font.Bold = $true
    }
}

# ── Remaining sheets ──────────────────────────────────────────────────────────

$sheetDefs = @(
    @{ Data = $mbxValidation;   Name = 'Mailbox Validation'    }
    @{ Data = $spoValidation;   Name = 'SharePoint Validation'  }
    @{ Data = $odValidation;    Name = 'OneDrive Validation'    }
    @{ Data = $dlValidation;    Name = 'DL Validation'          }
    @{ Data = $m365Validation;  Name = 'M365 Group Validation'  }
    @{ Data = $openIssues;      Name = 'Open Issues'            }
    @{ Data = $guestActions;    Name = 'Guest Actions Required' }
)

foreach ($sheet in $sheetDefs) {
    if ($sheet.Data.Count -gt 0) {
        $xl = $sheet.Data | Export-Excel -ExcelPackage $xl `
            -WorksheetName $sheet.Name `
            -AutoSize -FreezeTopRow -BoldTopRow -PassThru

        # Colour status column
        $ws = $xl.Workbook.Worksheets[$sheet.Name]
        for ($r = 2; $r -le $ws.Dimension.Rows; $r++) {
            # Find the Status or OverallStatus column
            for ($c = 1; $c -le $ws.Dimension.Columns; $c++) {
                $header = $ws.Cells[1, $c].Value
                if ($header -in @('Status','OverallStatus')) {
                    $val = $ws.Cells[$r, $c].Value
                    $color = switch ($val) {
                        'PASS' { [System.Drawing.Color]::FromArgb(198, 239, 206) }
                        'WARN' { [System.Drawing.Color]::FromArgb(255, 235, 156) }
                        'FAIL' { [System.Drawing.Color]::FromArgb(255, 199, 206) }
                        default { [System.Drawing.Color]::White }
                    }
                    $ws.Cells[$r, $c].Style.Fill.PatternType = [OfficeOpenXml.Style.ExcelFillStyle]::Solid
                    $ws.Cells[$r, $c].Style.Fill.BackgroundColor.SetColor($color)
                    break
                }
            }
        }
    }
}

Close-ExcelPackage $xl
Write-MigLog "Excel report written: $xlPath"

# ── Plain text summary ────────────────────────────────────────────────────────

$bar = '=' * 72
$div = '─' * 72

$txtLines = @(
    $bar
    "  MIGRATION SIGN-OFF REPORT"
    "  $($domains.CompanySuffix) ($SourceDomain) → Volue (volue.com)"
    "  Generated : $nowStr"
    if ($ReviewedBy) { "  Reviewed by : $ReviewedBy" }
    $div
    "  SIGN-OFF STATUS: $signOffStatus"
    $div
    "  SCOPE"
    "    User mailboxes    : $totalConfirmedUsers"
    "    Shared mailboxes  : $totalConfirmedShared"
    "    Distribution lists: $totalConfirmedDLs"
    "    SPO sites         : $totalConfirmedSPO"
    "    Source storage    : ${totalStorageSource} GB"
    "    Target storage    : ${totalStorageGB} GB"
    $div
    "  VALIDATION RESULTS"
    "    Area              Total  Pass  Warn  Fail"
    "    Mailboxes         $($mbxCounts.Total.ToString().PadLeft(5))  $($mbxCounts.Pass.ToString().PadLeft(4))  $($mbxCounts.Warn.ToString().PadLeft(4))  $($mbxCounts.Fail.ToString().PadLeft(4))"
    "    SharePoint        $($spoCounts.Total.ToString().PadLeft(5))  $($spoCounts.Pass.ToString().PadLeft(4))  $($spoCounts.Warn.ToString().PadLeft(4))  $($spoCounts.Fail.ToString().PadLeft(4))"
    "    OneDrive          $($odCounts.Total.ToString().PadLeft(5))  $($odCounts.Pass.ToString().PadLeft(4))  $($odCounts.Warn.ToString().PadLeft(4))  $($odCounts.Fail.ToString().PadLeft(4))"
    "    Distribution Lists$($dlCounts.Total.ToString().PadLeft(5))  $($dlCounts.Pass.ToString().PadLeft(4))  $($dlCounts.Warn.ToString().PadLeft(4))  $($dlCounts.Fail.ToString().PadLeft(4))"
    "    M365 Groups       $($m365Counts.Total.ToString().PadLeft(5))  $($m365Counts.Pass.ToString().PadLeft(4))  $($m365Counts.Warn.ToString().PadLeft(4))  $($m365Counts.Fail.ToString().PadLeft(4))"
    $div
    "  MIGRATION ACTIONS COMPLETED"
    "    Licenses assigned     : $licensesAssigned"
    "    Permissions applied   : $permsApplied"
    "    Guest re-invites TODO : $guestsPending"
    $div
)

if ($totalFail -gt 0) {
    $txtLines += "  FAIL ITEMS (must remediate):"
    foreach ($issue in ($openIssues | Where-Object { $_.Status -eq 'FAIL' } | Select-Object -First 20)) {
        $txtLines += "    ✘ [$($issue.Area)] $($issue.Item)"
        $txtLines += "        $($issue.Issues)"
    }
    if ($openIssues.Count -gt 20) { $txtLines += "    ... and $($openIssues.Count - 20) more — see Excel report" }
    $txtLines += $div
}

if ($totalWarn -gt 0) {
    $txtLines += "  WARNINGS (review required):"
    foreach ($issue in ($openIssues | Where-Object { $_.Status -eq 'WARN' } | Select-Object -First 10)) {
        $txtLines += "    ⚠ [$($issue.Area)] $($issue.Item)"
    }
    if (($openIssues | Where-Object { $_.Status -eq 'WARN' }).Count -gt 10) {
        $txtLines += "    ... see Excel report for full list"
    }
    $txtLines += $div
}

if ($guestsPending -gt 0) {
    $txtLines += "  GUEST RE-INVITATION ACTION REQUIRED:"
    $txtLines += "    $guestsPending guest user(s) need manual re-invitation."
    $txtLines += "    See 'm365group_guest_actions_required.csv' and the"
    $txtLines += "    'Guest Actions Required' sheet in the Excel report."
    $txtLines += $div
}

$txtLines += "  Excel report : $xlPath"
$txtLines += $bar

$txtPath = Join-Path $outDir "migration_signoff_summary_${CompanySuffix}_$dateSafe.txt"
$txtLines | Out-File -FilePath $txtPath -Encoding UTF8 -Force
$txtLines | ForEach-Object { Write-Host $_ }

# ── Final log ─────────────────────────────────────────────────────────────────

Write-MigSummary -Stats @{
    'Sign-off status'        = $signOffStatus
    'Total PASS'             = $totalPass
    'Total WARN'             = $totalWarn
    'Total FAIL'             = $totalFail
    'Open issues'            = $openIssues.Count
    'Guest actions pending'  = $guestsPending
    'Excel report'           = $xlPath
    'Text summary'           = $txtPath
    'Next step'              = if ($totalFail -gt 0) {
        'Remediate FAIL items then re-run validation scripts' }
        elseif ($totalWarn -gt 0) {
        'Review warnings with stakeholders, obtain sign-off, then run Phase 5 cutover' }
        else { 'Obtain sign-off, then run Phase 5 — Invoke-Cutover.ps1' }
}
