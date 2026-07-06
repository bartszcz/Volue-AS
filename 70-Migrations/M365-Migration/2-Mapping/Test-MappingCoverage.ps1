#Requires -Version 5.1
<#
.SYNOPSIS
    Validates that all mapping files are complete and confirmed before
    Phase 3 target preparation scripts are run.

.DESCRIPTION
    This is the GATE CHECK between Phase 2 (mapping) and Phase 3 (target prep).
    It must pass before any target objects are created.

    Checks performed across all mapping files:

      USER MAPPING
        - All source mailbox UPNs have a CONFIRMED entry
        - No duplicate target emails (two sources → same target)
        - All CONFIRMED rows have valid Source + Target AAD Object IDs
        - Target emails match expected first.last@volue.com format

      SHARED MAILBOX MAPPING
        - All shared mailboxes have a CONFIRMED entry
        - No email conflicts with user mapping

      DL MAPPING
        - All DLs have a CONFIRMED entry

      SHAREPOINT MAPPING
        - All sites have a CONFIRMED entry
        - Hub sites are confirmed (required before member sites)
        - All site owners are mapped

      ONEDRIVE MAPPING
        - All OneDrive sites with known owners are CONFIRMED

    Produces a structured readiness report. If IsReady=$false, Phase 3
    must not proceed.

    OUTPUTS
        MigrationData\mapping_coverage_report.csv   — per-file summary
        MigrationData\mapping_issues.csv            — all individual issues

.PARAMETER SourceDomain
    Primary email domain of the source company.

.PARAMETER CompanySuffix
    Human-readable company name.

.PARAMETER MailboxCsv
    Source mailbox inventory. Default: .\MigrationData\mailboxes.csv

.PARAMETER UserMappingCsv
    User mapping. Default: .\MigrationData\user_mapping.csv

.PARAMETER SharedMappingCsv
    Shared mailbox mapping. Default: .\MigrationData\shared_mailbox_mapping.csv

.PARAMETER DLMappingCsv
    DL mapping. Default: .\MigrationData\dl_mapping.csv

.PARAMETER SharePointMappingCsv
    SharePoint mapping. Default: .\MigrationData\sharepoint_mapping.csv

.PARAMETER OneDriveMappingCsv
    OneDrive mapping. Default: .\MigrationData\onedrive_mapping.csv

.PARAMETER OutputPath
    Output folder. Default: .\MigrationData

.EXAMPLE
    .\Test-MappingCoverage.ps1 `
        -SourceDomain  'smartpulse.io' `
        -CompanySuffix 'SmartPulse'
#>

[CmdletBinding()]
param(
    [string] $SourceDomain = '',
    [string] $CompanySuffix = '',
    [string] $MailboxCsv          = '.\MigrationData\mailboxes.csv',
    [string] $UserMappingCsv      = '.\MigrationData\user_mapping.csv',
    [string] $SharedMappingCsv    = '.\MigrationData\shared_mailbox_mapping.csv',
    [string] $DLMappingCsv        = '.\MigrationData\dl_mapping.csv',
    [string] $SharePointMappingCsv = '.\MigrationData\sharepoint_mapping.csv',
    [string] $OneDriveMappingCsv  = '.\MigrationData\onedrive_mapping.csv',
    [string] $OutputPath          = '.\MigrationData'
)

# ── Bootstrap ─────────────────────────────────────────────────────────────────

Import-Module (Join-Path $PSScriptRoot '..\MigrationHelpers.psm1') -Force -ErrorAction Stop

# ── Load MigrationConfig.psd1 ────────────────────────────────────────────────
$_cfg = Import-MigrationConfig
$SourceDomain = Resolve-ConfigParam -Passed $SourceDomain -Default '' -ConfigValue (Get-ConfigValue -Config $_cfg -Key "SourceDomain")
$CompanySuffix = Resolve-ConfigParam -Passed $CompanySuffix -Default '' -ConfigValue (Get-ConfigValue -Config $_cfg -Key "CompanySuffix")
$UserMappingCsv = Resolve-ConfigParam -Passed $UserMappingCsv -Default '' -ConfigValue (Get-ConfigValue -Config $_cfg -Key "UserMappingCsv")
$SharedMappingCsv = Resolve-ConfigParam -Passed $SharedMappingCsv -Default '' -ConfigValue (Get-ConfigValue -Config $_cfg -Key "SharedMappingCsv")
$DLMappingCsv = Resolve-ConfigParam -Passed $DLMappingCsv -Default '' -ConfigValue (Get-ConfigValue -Config $_cfg -Key "DLMappingCsv")
$SharePointMappingCsv = Resolve-ConfigParam -Passed $SharePointMappingCsv -Default '' -ConfigValue (Get-ConfigValue -Config $_cfg -Key "SharePointMappingCsv")
$OneDriveMappingCsv = Resolve-ConfigParam -Passed $OneDriveMappingCsv -Default '' -ConfigValue (Get-ConfigValue -Config $_cfg -Key "OneDriveMappingCsv")
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
Initialize-MigLog -ScriptName 'Test-MappingCoverage' `
                  -LogDirectory (Join-Path $PSScriptRoot '..\Logs')
$outDir  = Ensure-OutputDirectory -Path $OutputPath
$domains = Get-MigrationDomains

$reportRows = [System.Collections.Generic.List[PSCustomObject]]::new()
$issueRows  = [System.Collections.Generic.List[PSCustomObject]]::new()
$overallReady = $true

$guidPattern         = '^[0-9a-fA-F]{8}-([0-9a-fA-F]{4}-){3}[0-9a-fA-F]{12}$'
$targetEmailPattern  = "^[a-zA-Z0-9]+\.[a-zA-Z0-9.]+@$([regex]::Escape($domains.TargetDomain))$"

function Add-Issue {
    param([string]$Area, [string]$Severity, [string]$Item, [string]$Message)
    $issueRows.Add([PSCustomObject]@{
        Area     = $Area
        Severity = $Severity   # CRITICAL | WARN | INFO
        Item     = $Item
        Message  = $Message
    })
    $level = if ($Severity -eq 'CRITICAL') { 'ERROR' } elseif ($Severity -eq 'WARN') { 'WARN' } else { 'INFO' }
    Write-MigLog "[$Severity] [$Area] $Item — $Message" -Level $level
}

function Add-Report {
    param(
        [string] $Area,
        [int]    $Total,
        [int]    $Confirmed,
        [int]    $NeedsReview,
        [int]    $Unmatched,
        [int]    $Issues,
        [bool]   $IsReady
    )
    $coverage = if ($Total -gt 0) { [math]::Round(($Confirmed / $Total) * 100, 1) } else { 0 }
    $reportRows.Add([PSCustomObject]@{
        Area         = $Area
        Total        = $Total
        Confirmed    = $Confirmed
        NeedsReview  = $NeedsReview
        Unmatched    = $Unmatched
        IssueCount   = $Issues
        Coverage     = "$coverage%"
        IsReady      = $IsReady
    })
    if (-not $IsReady) { Set-Variable -Name overallReady -Value $false -Scope 1 }
}

# ==============================================================================
#  CHECK 1: USER MAILBOXES
# ==============================================================================

Write-MigLog '── Checking user mapping ───────────────────────────────────────────────────'

$mbxData  = Import-CsvSafe -Path $MailboxCsv `
    -RequiredColumns @('PrimarySmtpAddress','MailboxType')
$userMbxs = $mbxData | Where-Object { $_.MailboxType -eq 'UserMailbox' }

$userMapping = Import-CsvSafe -Path $UserMappingCsv `
    -RequiredColumns @('SourceEmail','TargetEmail','Status','SourceAADObjectId','TargetAADObjectId')

$userMappingIndex = @{}
foreach ($row in $userMapping) {
    $userMappingIndex[$row.SourceEmail.ToLower()] = $row
}

$uConfirmed = 0; $uNeedsReview = 0; $uUnmatched = 0; $uIssues = 0

foreach ($mbx in $userMbxs) {
    $email = $mbx.PrimarySmtpAddress.ToLower()
    $row   = $userMappingIndex[$email]

    if (-not $row) {
        $uUnmatched++; $uIssues++
        Add-Issue 'UserMapping' 'CRITICAL' $email 'No mapping row found for this mailbox'
        continue
    }

    switch ($row.Status) {
        'CONFIRMED'    { $uConfirmed++ }
        'NEEDS_REVIEW' { $uNeedsReview++; $uIssues++ }
        'UNMATCHED'    { $uUnmatched++;   $uIssues++
            Add-Issue 'UserMapping' 'CRITICAL' $email "Status=UNMATCHED — must be resolved" }
    }

    if ($row.Status -eq 'CONFIRMED') {
        # Validate AAD Object IDs
        if (-not $row.SourceAADObjectId -or $row.SourceAADObjectId -notmatch $guidPattern) {
            $uIssues++
            Add-Issue 'UserMapping' 'CRITICAL' $email "SourceAADObjectId missing or invalid: '$($row.SourceAADObjectId)'"
        }
        if (-not $row.TargetAADObjectId -or $row.TargetAADObjectId -notmatch $guidPattern) {
            $uIssues++
            Add-Issue 'UserMapping' 'WARN' $email "TargetAADObjectId missing — target user may not exist yet"
        }
        # Validate target email format
        if ($row.TargetEmail -and $row.TargetEmail -notmatch $targetEmailPattern) {
            $uIssues++
            Add-Issue 'UserMapping' 'WARN' $email "TargetEmail '$($row.TargetEmail)' doesn't match $($domains.TargetDomain) format"
        }
    }
}

# Duplicate target email check
$dupTargets = $userMapping |
    Where-Object { $_.Status -eq 'CONFIRMED' -and $_.TargetEmail } |
    Group-Object { $_.TargetEmail.ToLower() } |
    Where-Object { $_.Count -gt 1 }

foreach ($dup in $dupTargets) {
    $uIssues++
    $sources = ($dup.Group | ForEach-Object { $_.SourceEmail }) -join ', '
    Add-Issue 'UserMapping' 'CRITICAL' $dup.Name "Duplicate target email — multiple sources map here: $sources"
}

$uReady = ($uNeedsReview -eq 0 -and $uUnmatched -eq 0 -and $dupTargets.Count -eq 0)
Add-Report -Area 'UserMailboxes' -Total $userMbxs.Count -Confirmed $uConfirmed `
           -NeedsReview $uNeedsReview -Unmatched $uUnmatched -Issues $uIssues -IsReady $uReady

# ==============================================================================
#  CHECK 2: SHARED MAILBOXES
# ==============================================================================

Write-MigLog '── Checking shared mailbox mapping ─────────────────────────────────────────'

$sharedMbxs = $mbxData | Where-Object { $_.MailboxType -eq 'SharedMailbox' }

if (Test-Path $SharedMappingCsv) {
    $sharedMapping = Import-CsvSafe -Path $SharedMappingCsv `
        -RequiredColumns @('SourceEmail','TargetEmail','Status')

    $sharedIndex = @{}
    foreach ($row in $sharedMapping) {
        $sharedIndex[$row.SourceEmail.ToLower()] = $row
    }

    $sConfirmed = 0; $sNeedsReview = 0; $sUnmatched = 0; $sIssues = 0

    foreach ($mbx in $sharedMbxs) {
        $email = $mbx.PrimarySmtpAddress.ToLower()
        $row   = $sharedIndex[$email]

        if (-not $row) {
            $sUnmatched++; $sIssues++
            Add-Issue 'SharedMailbox' 'CRITICAL' $email 'No mapping row found'
            continue
        }
        switch ($row.Status) {
            'CONFIRMED'    { $sConfirmed++ }
            'NEEDS_REVIEW' { $sNeedsReview++; $sIssues++
                Add-Issue 'SharedMailbox' 'WARN' $email 'Status=NEEDS_REVIEW — confirm before Phase 3' }
        }
        # Check for conflict with user mapping target emails
        if ($row.Status -eq 'CONFIRMED' -and $row.TargetEmail) {
            $conflict = $userMapping | Where-Object {
                $_.Status -eq 'CONFIRMED' -and
                $_.TargetEmail.ToLower() -eq $row.TargetEmail.ToLower()
            }
            if ($conflict) {
                $sIssues++
                Add-Issue 'SharedMailbox' 'CRITICAL' $email `
                    "Target email '$($row.TargetEmail)' conflicts with user mapping for '$($conflict.SourceEmail)'"
            }
        }
    }

    $sReady = ($sNeedsReview -eq 0 -and $sUnmatched -eq 0)
    Add-Report -Area 'SharedMailboxes' -Total $sharedMbxs.Count -Confirmed $sConfirmed `
               -NeedsReview $sNeedsReview -Unmatched $sUnmatched -Issues $sIssues -IsReady $sReady
}
else {
    Add-Issue 'SharedMailbox' 'WARN' $SharedMappingCsv 'Mapping file not found — run New-SharedMailboxMapping.ps1'
    Add-Report -Area 'SharedMailboxes' -Total $sharedMbxs.Count -Confirmed 0 `
               -NeedsReview 0 -Unmatched $sharedMbxs.Count -Issues 1 -IsReady $false
}

# ==============================================================================
#  CHECK 3: DISTRIBUTION GROUPS
# ==============================================================================

Write-MigLog '── Checking DL mapping ─────────────────────────────────────────────────────'

if (Test-Path $DLMappingCsv) {
    $dlMapping   = Import-CsvSafe -Path $DLMappingCsv -RequiredColumns @('SourceEmail','Status')
    $dlConfirmed = ($dlMapping | Where-Object { $_.Status -eq 'CONFIRMED' }).Count
    $dlPending   = ($dlMapping | Where-Object { $_.Status -ne 'CONFIRMED' }).Count
    $dlIssues    = 0

    $dlMapping | Where-Object { $_.Status -ne 'CONFIRMED' } | ForEach-Object {
        $dlIssues++
        Add-Issue 'DLMapping' 'WARN' $_.SourceEmail "Status=$($_.Status) — confirm before Phase 3"
    }

    Add-Report -Area 'DistributionGroups' -Total $dlMapping.Count -Confirmed $dlConfirmed `
               -NeedsReview $dlPending -Unmatched 0 -Issues $dlIssues -IsReady ($dlPending -eq 0)
}
else {
    Add-Issue 'DLMapping' 'WARN' $DLMappingCsv 'Mapping file not found — run New-SharedMailboxMapping.ps1'
    Add-Report -Area 'DistributionGroups' -Total 0 -Confirmed 0 `
               -NeedsReview 0 -Unmatched 0 -Issues 1 -IsReady $false
}

# ==============================================================================
#  CHECK 4: SHAREPOINT
# ==============================================================================

Write-MigLog '── Checking SharePoint mapping ─────────────────────────────────────────────'

if (Test-Path $SharePointMappingCsv) {
    $spoMapping   = Import-CsvSafe -Path $SharePointMappingCsv `
        -RequiredColumns @('SourceUrl','TargetUrl','Status','IsHubSite')

    $spoConfirmed  = ($spoMapping | Where-Object { $_.Status -eq 'CONFIRMED' }).Count
    $spoPending    = ($spoMapping | Where-Object { $_.Status -ne 'CONFIRMED' }).Count
    $spoIssues     = 0

    # Hub sites must ALL be confirmed
    $unconfirmedHubs = $spoMapping | Where-Object {
        $_.IsHubSite -eq $true -and $_.Status -ne 'CONFIRMED'
    }
    foreach ($hub in $unconfirmedHubs) {
        $spoIssues++
        Add-Issue 'SharePoint' 'CRITICAL' $hub.SourceUrl `
            'Hub site not confirmed — must be confirmed and created before member sites'
    }

    # Sites with blank target URLs
    $spoMapping | Where-Object { $_.Status -ne 'CONFIRMED' -and -not $_.TargetUrl } | ForEach-Object {
        $spoIssues++
        Add-Issue 'SharePoint' 'WARN' $_.SourceUrl 'TargetUrl is blank — enter manually'
    }

    # Unmapped owners
    $spoMapping | Where-Object {
        $_.Status -eq 'CONFIRMED' -and [string]::IsNullOrWhiteSpace($_.TargetOwnerEmail)
    } | ForEach-Object {
        $spoIssues++
        Add-Issue 'SharePoint' 'WARN' $_.SourceUrl 'TargetOwnerEmail is blank — populate before Phase 3'
    }

    Add-Report -Area 'SharePointSites' -Total $spoMapping.Count -Confirmed $spoConfirmed `
               -NeedsReview $spoPending -Unmatched 0 -Issues $spoIssues -IsReady ($spoPending -eq 0 -and $unconfirmedHubs.Count -eq 0)
}
else {
    Add-Issue 'SharePoint' 'WARN' $SharePointMappingCsv 'Mapping file not found — run New-SharePointMapping.ps1'
    Add-Report -Area 'SharePointSites' -Total 0 -Confirmed 0 `
               -NeedsReview 0 -Unmatched 0 -Issues 1 -IsReady $false
}

# ==============================================================================
#  CHECK 5: ONEDRIVE
# ==============================================================================

Write-MigLog '── Checking OneDrive mapping ───────────────────────────────────────────────'

if (Test-Path $OneDriveMappingCsv) {
    $odMapping   = Import-CsvSafe -Path $OneDriveMappingCsv -RequiredColumns @('SourceUrl','Status')
    $odConfirmed = ($odMapping | Where-Object { $_.Status -eq 'CONFIRMED' }).Count
    $odPending   = ($odMapping | Where-Object { $_.Status -ne 'CONFIRMED' }).Count

    $odMapping | Where-Object { $_.Status -ne 'CONFIRMED' } | ForEach-Object {
        Add-Issue 'OneDrive' 'WARN' $_.SourceUrl "Status=$($_.Status) — owner may be unmapped"
    }

    Add-Report -Area 'OneDrive' -Total $odMapping.Count -Confirmed $odConfirmed `
               -NeedsReview $odPending -Unmatched 0 -Issues $odPending -IsReady ($odPending -eq 0)
}
else {
    Add-Issue 'OneDrive' 'WARN' $OneDriveMappingCsv 'Mapping file not found — run New-OneDriveMapping.ps1'
    Add-Report -Area 'OneDrive' -Total 0 -Confirmed 0 `
               -NeedsReview 0 -Unmatched 0 -Issues 1 -IsReady $false
}

# ── Export reports ────────────────────────────────────────────────────────────

$reportPath = Join-Path $outDir 'mapping_coverage_report.csv'
$issuePath  = Join-Path $outDir 'mapping_issues.csv'

$reportRows | Export-CsvSafe -Path $reportPath
$issueRows  | Export-CsvSafe -Path $issuePath

# ── Final verdict ─────────────────────────────────────────────────────────────

$criticalCount = ($issueRows | Where-Object { $_.Severity -eq 'CRITICAL' }).Count
$warnCount     = ($issueRows | Where-Object { $_.Severity -eq 'WARN' }).Count

Write-MigLog ''
Write-MigLog ('=' * 80)
if ($overallReady) {
    Write-MigLog '  ✔  ALL MAPPING CHECKS PASSED — Phase 3 may proceed' -Level INFO
}
else {
    Write-MigLog '  ✘  MAPPING IS NOT READY — resolve all CRITICAL issues before Phase 3' -Level ERROR
}
Write-MigLog ("  Critical issues : $criticalCount") -Level $(if ($criticalCount -gt 0) { 'ERROR' } else { 'INFO' })
Write-MigLog ("  Warnings        : $warnCount")     -Level $(if ($warnCount -gt 0)     { 'WARN'  } else { 'INFO' })
Write-MigLog ('=' * 80)
Write-MigLog ''

Write-MigSummary -Stats @{
    'Overall ready'        = $overallReady
    'Critical issues'      = $criticalCount
    'Warnings'             = $warnCount
    'Coverage report'      = $reportPath
    'Issues detail'        = $issuePath
    'Next step'            = if ($overallReady) { 'Phase 3 — target pre-creation scripts' }
                             else { 'Resolve all CRITICAL issues then re-run this script' }
}

# Return exit code for use in automation pipelines
exit $(if ($overallReady) { 0 } else { 1 })
