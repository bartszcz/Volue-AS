#Requires -Version 5.1
#Requires -Modules Microsoft.Graph.Users
<#
.SYNOPSIS
    Builds source-to-target user mapping by matching on First + Last name
    across two HR export files, then enriches with AAD Object IDs from
    both tenants.

.DESCRIPTION
    INPUTS
        Source HR CSV : columns for FirstName, LastName, Email
                        (source tenant addresses — format varies by company)
        Target HR CSV : columns for FirstName, LastName, Email
                        (always first.last@volue.com format)

    MATCH STRATEGY (attempted in order per source row)
        1. FirstName + LastName exact       → CONFIRMED  (confidence 1.0)
        2. LastName exact + FirstName start → NEEDS_REVIEW (confidence 0.8)
           Handles: Bob/Robert, Liz/Elizabeth, etc.
        3. No match                         → UNMATCHED

    POST-MATCH ENRICHMENT
        Each CONFIRMED row is enriched with AAD Object IDs from both
        tenants. Missing AAD Object ID on a CONFIRMED row downgrades it
        to NEEDS_REVIEW (blocks Code2 batch file generation).

    NAME NORMALISATION
        Names are normalised before comparison:
          - Trim / collapse whitespace
          - Lowercase
          - Turkish chars: ı→i ğ→g ş→s ç→c ö→o ü→u
          - Common European accents stripped

    DUPLICATE HANDLING
        - Two target users with identical normalised full name → NEEDS_REVIEW
        - Two source rows mapping to same target email → flagged as critical

    OUTPUTS
        MigrationData\user_mapping.csv            — all rows, all statuses
        MigrationData\user_mapping_review.csv     — NEEDS_REVIEW + UNMATCHED
        MigrationData\user_mapping_confirmed.csv  — CONFIRMED only (Phase 3 input)

.PARAMETER SourceHRCsv
    CSV with source users. Required columns: FirstName, LastName, Email
    Column names configurable via -Source*Col parameters.

.PARAMETER TargetHRCsv
    CSV with target users (Volue). Required columns: FirstName, LastName, Email

.PARAMETER SourceTenantId
    AAD Tenant ID of the source tenant.

.PARAMETER SourceAdminUPN
    Admin UPN for source tenant Graph connection.

.PARAMETER TargetTenantId
    AAD Tenant ID of the target tenant (Volue).

.PARAMETER TargetAdminUPN
    Admin UPN for target tenant Graph connection.

.PARAMETER SourceDomain
    Primary email domain of the source company. e.g. 'smartpulse.io'

.PARAMETER CompanySuffix
    Human-readable company name. e.g. 'SmartPulse'

.PARAMETER SourceFirstNameCol
    Column name for first name in source CSV. Default: FirstName

.PARAMETER SourceLastNameCol
    Column name for last name in source CSV. Default: LastName

.PARAMETER SourceEmailCol
    Column name for email in source CSV. Default: Email

.PARAMETER TargetFirstNameCol
    Column name for first name in target CSV. Default: FirstName

.PARAMETER TargetLastNameCol
    Column name for last name in target CSV. Default: LastName

.PARAMETER TargetEmailCol
    Column name for email in target CSV. Default: Email

.PARAMETER DefaultMigrationBatch
    Batch label stamped on all CONFIRMED rows. Default: Batch001

.PARAMETER OutputPath
    Output folder. Default: .\MigrationData

.EXAMPLE
    .\New-UserMapping.ps1 `
        -SourceHRCsv    '.\SourceUsers.csv' `
        -TargetHRCsv    '.\TargetUsers.csv' `
        -SourceTenantId 'balancingpoolcom.onmicrosoft.com' `
        -SourceAdminUPN 'admin@smartpulse.io' `
        -TargetTenantId 'volue.onmicrosoft.com' `
        -TargetAdminUPN 'admin@volue.com' `
        -SourceDomain   'smartpulse.io' `
        -CompanySuffix  'SmartPulse'

.EXAMPLE
    # Non-standard CSV column names
    .\New-UserMapping.ps1 `
        -SourceHRCsv        '.\source_staff.csv' `
        -TargetHRCsv        '.\volue_staff.csv' `
        -SourceTenantId     'balancingpoolcom.onmicrosoft.com' `
        -SourceAdminUPN     'admin@smartpulse.io' `
        -TargetTenantId     'volue.onmicrosoft.com' `
        -TargetAdminUPN     'admin@volue.com' `
        -SourceDomain       'smartpulse.io' `
        -CompanySuffix      'SmartPulse' `
        -SourceFirstNameCol 'First' `
        -SourceLastNameCol  'Surname' `
        -SourceEmailCol     'EmailAddress'
#>

[CmdletBinding()]
param(
    [string] $SourceHRCsv = '',
    [string] $TargetHRCsv = '',
    [string] $SourceTenantId = '',
    [string] $SourceAdminUPN = '',
    [string] $TargetTenantId = '',
    [string] $TargetAdminUPN = '',
    [string] $SourceDomain = '',
    [string] $CompanySuffix = '',

    # Column name overrides
    [string] $SourceFirstNameCol = 'FirstName',
    [string] $SourceLastNameCol  = 'LastName',
    [string] $SourceEmailCol     = 'Email',
    [string] $TargetFirstNameCol = 'FirstName',
    [string] $TargetLastNameCol  = 'LastName',
    [string] $TargetEmailCol     = 'Email',

    [string] $DefaultMigrationBatch = 'Batch001',
    [string] $OutputPath            = '.\MigrationData'
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
$OutputPath = Resolve-ConfigParam -Passed $OutputPath -Default '' -ConfigValue (Get-ConfigValue -Config $_cfg -Key "OutputPath")
$SourceHRCsv = Resolve-ConfigParam -Passed $SourceHRCsv -Default '' -ConfigValue (Get-ConfigValue -Config $_cfg -Key "SourceHRCsv")
$TargetHRCsv = Resolve-ConfigParam -Passed $TargetHRCsv -Default '' -ConfigValue (Get-ConfigValue -Config $_cfg -Key "TargetHRCsv")

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
Initialize-MigLog -ScriptName 'New-UserMapping' `
                  -LogDirectory (Join-Path $PSScriptRoot '..\Logs')
$outDir  = Ensure-OutputDirectory -Path $OutputPath
$domains = Get-MigrationDomains

Write-MigLog "Source HR : $SourceHRCsv"
Write-MigLog "Target HR : $TargetHRCsv"

# ── Load HR files ─────────────────────────────────────────────────────────────

$sourceRows = Import-CsvSafe -Path $SourceHRCsv `
    -RequiredColumns @($SourceFirstNameCol, $SourceLastNameCol, $SourceEmailCol)

$targetRows = Import-CsvSafe -Path $TargetHRCsv `
    -RequiredColumns @($TargetFirstNameCol, $TargetLastNameCol, $TargetEmailCol)

Write-MigLog "Source HR rows : $($sourceRows.Count)"
Write-MigLog "Target HR rows : $($targetRows.Count)"

# Validate target email format — must be first.last@volue.com
$targetDomainEscaped = [regex]::Escape($domains.TargetDomain)
$badFormat = $targetRows | Where-Object {
    $_.$TargetEmailCol -notmatch "^[a-zA-Z0-9]+\.[a-zA-Z0-9.]+@$targetDomainEscaped$"
}
if ($badFormat.Count -gt 0) {
    Write-MigLog "$($badFormat.Count) target email(s) don't match expected format — review target HR file" -Level WARN
    $badFormat | ForEach-Object {
        Write-MigLog "  Unexpected: $_.$TargetEmailCol" -Level WARN
    }
}

# ── Build target lookup indices ───────────────────────────────────────────────

# Index 1: "firstname|lastname" (normalised) → row
#          '__AMBIGUOUS__' if two targets share the same full name
$targetByFullName = @{}

# Index 2: "lastname" (normalised) → list of rows (for partial first-name match)
$targetByLastName = @{}

foreach ($row in $targetRows) {
    $fn  = Normalize-Name $row.$TargetFirstNameCol
    $ln  = Normalize-Name $row.$TargetLastNameCol
    $key = "$fn|$ln"

    if ($targetByFullName.ContainsKey($key)) {
        Write-MigLog "Duplicate full name in target HR: '$fn $ln' — both '$($targetByFullName[$key].$TargetEmailCol)' and '$($row.$TargetEmailCol)'" -Level WARN
        $targetByFullName[$key] = '__AMBIGUOUS__'
    }
    else {
        $targetByFullName[$key] = $row
    }

    if (-not $targetByLastName.ContainsKey($ln)) {
        $targetByLastName[$ln] = [System.Collections.Generic.List[object]]::new()
    }
    $targetByLastName[$ln].Add($row)
}

Write-MigLog "Target index: $($targetByFullName.Count) full-name keys | $($targetByLastName.Count) last-name keys"

# ── Connect SOURCE tenant → AAD Object IDs ────────────────────────────────────

Write-MigLog "Connecting to SOURCE tenant for AAD Object IDs..."
Connect-SourceTenant -TenantId $SourceTenantId -UserPrincipalName $SourceAdminUPN

Write-MigLog "Retrieving source AAD users..."
$sourceAADUsers = Invoke-WithRetry {
    Get-MgUser -All `
        -Property 'Id,UserPrincipalName,DisplayName,GivenName,Surname,Mail,EmployeeId' `
        -ErrorAction Stop
}

# Index by UPN and Mail (both, since source email might differ from UPN)
$sourceAADIndex = @{}
foreach ($u in $sourceAADUsers) {
    foreach ($key in @($u.UserPrincipalName, $u.Mail)) {
        if ($key -and -not $sourceAADIndex.ContainsKey($key.ToLower())) {
            $sourceAADIndex[$key.ToLower()] = $u
        }
    }
}
Write-MigLog "Source AAD index: $($sourceAADIndex.Count) entries ($($sourceAADUsers.Count) users)"

# ── Connect TARGET tenant → AAD Object IDs ───────────────────────────────────

# Must disconnect source Graph before connecting target
try { Disconnect-MgGraph -ErrorAction SilentlyContinue } catch {}

Write-MigLog "Connecting to TARGET tenant for AAD Object IDs..."
Connect-MgGraph -TenantId $TargetTenantId `
                -Scopes @('User.Read.All') `
                -ErrorAction Stop

Write-MigLog "Retrieving target AAD users..."
$targetAADUsers = Invoke-WithRetry {
    Get-MgUser -All `
        -Property 'Id,UserPrincipalName,DisplayName,GivenName,Surname,Mail' `
        -ErrorAction Stop
}

$targetAADIndex = @{}
foreach ($u in $targetAADUsers) {
    foreach ($key in @($u.UserPrincipalName, $u.Mail)) {
        if ($key -and -not $targetAADIndex.ContainsKey($key.ToLower())) {
            $targetAADIndex[$key.ToLower()] = $u
        }
    }
}
Write-MigLog "Target AAD index: $($targetAADIndex.Count) entries ($($targetAADUsers.Count) users)"

# ── Main matching loop ────────────────────────────────────────────────────────

$mappingRows = [System.Collections.Generic.List[PSCustomObject]]::new()
$confirmed   = 0
$needsReview = 0
$unmatched   = 0

$total = $sourceRows.Count
$i     = 0

foreach ($srcRow in $sourceRows) {

    $i++
    $srcEmail = $srcRow.$SourceEmailCol.Trim().ToLower()

    Write-ProgressHelper -Activity 'Matching users' `
                         -Current $i -Total $total `
                         -Status $srcEmail

    $srcFN   = Normalize-Name $srcRow.$SourceFirstNameCol
    $srcLN   = Normalize-Name $srcRow.$SourceLastNameCol
    $fullKey = "$srcFN|$srcLN"

    $matchedRow      = $null
    $matchMethod     = 'UNMATCHED'
    $matchNote       = ''
    $status          = 'UNMATCHED'

    # ── Strategy 1: Exact FirstName + LastName ────────────────────────────────

    $exactHit = $targetByFullName[$fullKey]

    if ($exactHit -and $exactHit -ne '__AMBIGUOUS__') {
        $matchedRow  = $exactHit
        $matchMethod = 'FullNameExact'
        $status      = 'CONFIRMED'
    }
    elseif ($exactHit -eq '__AMBIGUOUS__') {
        $matchMethod = 'FullNameAmbiguous'
        $matchNote   = "Multiple target users share the name '$srcFN $srcLN' — select correct target manually"
        $status      = 'NEEDS_REVIEW'
        Write-MigLog "Ambiguous: '$srcFN $srcLN' → $matchNote" -Level WARN
    }

    # ── Strategy 2: LastName exact + FirstName starts-with ───────────────────
    # Catches: Bob/Robert, Liz/Elizabeth, Ali/Alia, Mehmet/Mehmed etc.

    if ($status -eq 'UNMATCHED' -and $targetByLastName.ContainsKey($srcLN)) {

        $lnCandidates = $targetByLastName[$srcLN]
        $partialHits  = $lnCandidates | Where-Object {
            $tFN = Normalize-Name $_.$TargetFirstNameCol
            $tFN.StartsWith($srcFN) -or $srcFN.StartsWith($tFN)
        }

        if ($partialHits.Count -eq 1) {
            $matchedRow  = $partialHits[0]
            $tFN         = Normalize-Name $matchedRow.$TargetFirstNameCol
            $matchMethod = 'LastNameExact+FirstPartial'
            $matchNote   = "First name partial match: source='$srcFN' target='$tFN' — verify correct person"
            $status      = 'NEEDS_REVIEW'
            Write-MigLog "Partial: $srcEmail → $($matchedRow.$TargetEmailCol) [$matchNote]" -Level WARN
        }
        elseif ($partialHits.Count -gt 1) {
            $candidates  = ($partialHits | ForEach-Object { $_.$TargetEmailCol }) -join ', '
            $matchMethod = 'LastNameAmbiguous'
            $matchNote   = "Multiple partial first-name matches on surname '$srcLN': $candidates"
            $status      = 'NEEDS_REVIEW'
            Write-MigLog "Multi-partial: $srcEmail → $matchNote" -Level WARN
        }
    }

    # ── Resolve target email ──────────────────────────────────────────────────

    $targetEmail = if ($matchedRow) { $matchedRow.$TargetEmailCol.Trim().ToLower() } else { '' }

    # ── Look up AAD Object IDs ────────────────────────────────────────────────

    $srcAAD         = $sourceAADIndex[$srcEmail]
    $tgtAAD         = if ($targetEmail) { $targetAADIndex[$targetEmail] } else { $null }
    $srcAADObjectId = $srcAAD?.Id ?? ''
    $tgtAADObjectId = $tgtAAD?.Id ?? ''

    # AAD lookup failures on confirmed rows → downgrade to NEEDS_REVIEW
    # (missing Object ID blocks Code2 batch file generation)
    if ($status -eq 'CONFIRMED') {
        $aadIssues = @()
        if (-not $srcAADObjectId) { $aadIssues += "Source AAD user not found for '$srcEmail'" }
        if (-not $tgtAADObjectId) { $aadIssues += "Target AAD user not found for '$targetEmail'" }
        if ($aadIssues.Count -gt 0) {
            $matchNote += " | AAD: $($aadIssues -join '; ')"
            $status     = 'NEEDS_REVIEW'
            $aadIssues | ForEach-Object { Write-MigLog $_ -Level WARN }
        }
    }

    # ── Update counters ───────────────────────────────────────────────────────
    switch ($status) {
        'CONFIRMED'    { $confirmed++ }
        'NEEDS_REVIEW' { $needsReview++ }
        'UNMATCHED'    { $unmatched++ }
    }

    $mappingRows.Add([PSCustomObject]@{

        # ── Source ────────────────────────────────────────────────────────────
        SourceFirstName       = $srcRow.$SourceFirstNameCol.Trim()
        SourceLastName        = $srcRow.$SourceLastNameCol.Trim()
        SourceEmail           = $srcEmail
        SourceDisplayName     = $srcAAD?.DisplayName `
                                ?? "$($srcRow.$SourceFirstNameCol) $($srcRow.$SourceLastNameCol)"
        SourceAADObjectId     = $srcAADObjectId      # ← SourceId for Code2

        # ── Target ────────────────────────────────────────────────────────────
        TargetFirstName       = $matchedRow?.$TargetFirstNameCol ?? ''
        TargetLastName        = $matchedRow?.$TargetLastNameCol  ?? ''
        TargetEmail           = $targetEmail
        TargetDisplayName     = $tgtAAD?.DisplayName ?? $targetEmail
        TargetAADObjectId     = $tgtAADObjectId      # ← TargetId for Code2

        # ── Match metadata ────────────────────────────────────────────────────
        MatchMethod           = $matchMethod
        Status                = $status              # CONFIRMED | NEEDS_REVIEW | UNMATCHED
        Notes                 = $matchNote

        # ── Migration planning ────────────────────────────────────────────────
        MigrationBatch        = if ($status -eq 'CONFIRMED') { $DefaultMigrationBatch } else { '' }
        MigrationPriority     = ''
        CutoverWindow         = ''

        # ── Audit trail ───────────────────────────────────────────────────────
        ReviewedBy            = ''
        ReviewDate            = ''
    })
}

Write-Progress -Activity 'Matching users' -Completed

# ── Duplicate target email check (critical — two sources → same target) ───────

$dupTargets = $mappingRows |
    Where-Object { $_.Status -eq 'CONFIRMED' -and $_.TargetEmail -ne '' } |
    Group-Object TargetEmail |
    Where-Object { $_.Count -gt 1 }

if ($dupTargets.Count -gt 0) {
    Write-MigLog "CRITICAL: $($dupTargets.Count) target email(s) mapped from multiple sources!" -Level ERROR
    foreach ($dup in $dupTargets) {
        $srcs = ($dup.Group | ForEach-Object { $_.SourceEmail }) -join ' | '
        Write-MigLog "  DUPLICATE TARGET: $($dup.Name)  ←  $srcs" -Level ERROR
    }
}

# ── Export ────────────────────────────────────────────────────────────────────

$fullPath      = Join-Path $outDir 'user_mapping.csv'
$reviewPath    = Join-Path $outDir 'user_mapping_review.csv'
$confirmedPath = Join-Path $outDir 'user_mapping_confirmed.csv'

$mappingRows | Export-CsvSafe -Path $fullPath
$mappingRows | Where-Object { $_.Status -in @('NEEDS_REVIEW','UNMATCHED') } |
    Export-CsvSafe -Path $reviewPath
$mappingRows | Where-Object { $_.Status -eq 'CONFIRMED' } |
    Export-CsvSafe -Path $confirmedPath

# ── Summary ───────────────────────────────────────────────────────────────────

$coverage = if ($total -gt 0) { [math]::Round(($confirmed / $total) * 100, 1) } else { 0 }

Write-MigSummary -Stats @{
    'Source HR rows'               = $total
    'Target HR rows'               = $targetRows.Count
    'CONFIRMED'                    = $confirmed
    'NEEDS_REVIEW'                 = $needsReview
    'UNMATCHED'                    = $unmatched
    'Coverage (confirmed %)'       = "$coverage%"
    'Duplicate target warnings'    = $dupTargets.Count
    'Full mapping'                 = $fullPath
    'Review file'                  = $reviewPath
    'Confirmed-only (Phase 3 in)'  = $confirmedPath
    'Next script'                  = 'New-SharedMailboxMapping.ps1'
}

if ($needsReview -gt 0 -or $unmatched -gt 0) {
    Write-MigLog '' -Level WARN
    Write-MigLog 'ACTION REQUIRED before running Phase 3:' -Level WARN
    Write-MigLog "  1. Open $reviewPath" -Level WARN
    Write-MigLog '  2. NEEDS_REVIEW: verify match is correct → set Status=CONFIRMED' -Level WARN
    Write-MigLog '  3. UNMATCHED: add TargetEmail + TargetAADObjectId → set Status=CONFIRMED' -Level WARN
    Write-MigLog '  4. Save edits directly into user_mapping.csv (or re-run with corrections in HR file)' -Level WARN
    Write-MigLog '  5. Export-Code2BatchFile.ps1 reads user_mapping_confirmed.csv' -Level WARN
}

Disconnect-AllTenants
