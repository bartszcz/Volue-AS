# =============================================================
# Script 0: Pre-Flight Validation
# =============================================================
# Usage:
#   .\0-Validate.ps1
#   .\0-Validate.ps1 -ConfigFile "C:\MyMigration\MigrationConfig.csv"
#
# Run this BEFORE Scripts 3 and 4. No changes are made.
# Must be connected to DESTINATION tenant.
#
# Checks:
#   1. All target mailboxes in NewGroupMembership.csv exist
#   2. All target group email aliases in NewGroupSummary.csv are available
#   3. External members are flagged (will need mail contacts)
#   4. Nested DL members are flagged (will be added as group members)
#   5. Unmapped members are listed
# =============================================================

param(
    [string]$ConfigFile = ".\MigrationConfig.csv"
)

# --- LOAD CONFIG ---
if (-not (Test-Path $ConfigFile)) {
    Write-Host "ERROR: Config file not found: $ConfigFile" -ForegroundColor Red
    exit 1
}

$config = @{}
Import-Csv -Path $ConfigFile | ForEach-Object {
    $config[$_.Setting] = $_.Value
}

# --- VALIDATE CONFIG ---
$requiredKeys = @("OutputFolder", "TargetDomain", "TargetAdminUPN")
$missingKeys  = $requiredKeys | Where-Object { [string]::IsNullOrWhiteSpace($config[$_]) }
if ($missingKeys) {
    Write-Host "ERROR: Missing or empty values in MigrationConfig.csv:" -ForegroundColor Red
    $missingKeys | ForEach-Object { Write-Host "  - $_" -ForegroundColor Yellow }
    Write-Host "Check that MigrationConfig.csv has a Setting,Value header row and all required keys." -ForegroundColor Yellow
    exit 1
}

$OutputFolder = $config["OutputFolder"]
$TargetDomain = $config["TargetDomain"]
$TargetAdmin  = $config["TargetAdminUPN"]

$summaryFile    = Join-Path $OutputFolder "NewGroupSummary.csv"
$membershipFile = Join-Path $OutputFolder "NewGroupMembership.csv"
$reportFile     = Join-Path $OutputFolder "ValidationReport.csv"

foreach ($f in @($summaryFile, $membershipFile)) {
    if (-not (Test-Path $f)) {
        Write-Host "ERROR: $f not found. Run Script 2 first." -ForegroundColor Red
        exit 1
    }
}

Write-Host "==========================================" -ForegroundColor Cyan
Write-Host " Script 0: Pre-Flight Validation" -ForegroundColor Cyan
Write-Host " Expected org : $TargetDomain" -ForegroundColor Gray
Write-Host " Target Admin : $TargetAdmin" -ForegroundColor Gray
Write-Host "==========================================" -ForegroundColor Cyan
Write-Host ""

# --- CONNECT ---
Write-Host "Verifying Exchange Online connection..." -ForegroundColor White
try {
    $orgConfig = Get-OrganizationConfig -ErrorAction Stop
    Write-Host "Connected." -ForegroundColor Green
}
catch {
    Write-Host "Not connected. Connecting to destination tenant..." -ForegroundColor Yellow
    try {
        Connect-ExchangeOnline -UserPrincipalName $TargetAdmin -ErrorAction Stop
        $orgConfig = Get-OrganizationConfig -ErrorAction Stop
        Write-Host "Connected." -ForegroundColor Green
    }
    catch {
        Write-Host "ERROR: Could not connect." -ForegroundColor Red
        exit 1
    }
}

# --- TENANT VALIDATION ---
$connectedOrg = $orgConfig.Name
Write-Host "Connected org : $connectedOrg" -ForegroundColor Gray

# Accept both vanity domain (volue.com) and onmicrosoft name (volue.onmicrosoft.com)
$domainRoot    = ($TargetDomain -split '\.')[0]
$domainMatches = $connectedOrg -match [regex]::Escape($TargetDomain) -or $connectedOrg -match "^$domainRoot\.onmicrosoft\.com$"

if (-not $domainMatches) {
    Write-Host ""
    Write-Host "ERROR: Wrong tenant! Must connect to DESTINATION tenant." -ForegroundColor Red
    Write-Host "  Expected : *$TargetDomain* or *$domainRoot.onmicrosoft.com*" -ForegroundColor Yellow
    Write-Host "  Connected: $connectedOrg" -ForegroundColor Yellow
    Write-Host ""
    Write-Host "  Disconnect-ExchangeOnline -Confirm:`$false" -ForegroundColor White
    Write-Host "  Connect-ExchangeOnline -UserPrincipalName $TargetAdmin" -ForegroundColor White
    exit 1
}
Write-Host "Tenant validated OK." -ForegroundColor Green
Write-Host ""

$groups     = Import-Csv -Path $summaryFile
$membership = Import-Csv -Path $membershipFile

$report = [System.Collections.ArrayList]::new()
$issues = 0

# =============================================================
# CHECK 1: Group email aliases — do any already exist?
# =============================================================
Write-Host "--- Check 1/4: Group email aliases ---" -ForegroundColor Cyan
$aliasConflicts = 0

foreach ($g in $groups) {
    $email = $g.NewGroupEmail.Trim()
    $existing = $null
    try {
        $existing = Get-Recipient -Identity $email -ErrorAction Stop
    }
    catch { }

    if ($existing) {
        $type = $existing.RecipientType
        Write-Host "  CONFLICT: $email already exists as [$type]" -ForegroundColor Red
        [void]$report.Add([PSCustomObject]@{
            Check   = "GroupAlias"
            Item    = $email
            Result  = "CONFLICT"
            Detail  = "Already exists as $type"
        })
        $aliasConflicts++
        $issues++
    }
    else {
        [void]$report.Add([PSCustomObject]@{
            Check   = "GroupAlias"
            Item    = $email
            Result  = "OK"
            Detail  = "Available"
        })
    }
}

if ($aliasConflicts -eq 0) {
    Write-Host "  All $($groups.Count) group aliases are available." -ForegroundColor Green
} else {
    Write-Host "  $aliasConflicts conflict(s) found — rename in NewGroupSummary.csv and re-run Script 2." -ForegroundColor Red
}
Write-Host ""

# =============================================================
# CHECK 2: Target mailboxes exist for Mapped members
# =============================================================
Write-Host "--- Check 2/4: Target mailbox existence ---" -ForegroundColor Cyan
$mappedRows     = $membership | Where-Object { $_.Status -eq "Mapped" }
$uniqueMailboxes = $mappedRows | Select-Object -ExpandProperty NewMemberEmail -Unique
$missingMailboxes = 0
$checkedCount    = 0

foreach ($email in $uniqueMailboxes) {
    $checkedCount++
    Write-Host "  [$checkedCount/$($uniqueMailboxes.Count)] Checking: $email" -ForegroundColor DarkGray -NoNewline
    $mbx = $null
    try {
        $mbx = Get-Mailbox -Identity $email -ErrorAction Stop
    }
    catch { }

    if ($mbx) {
        Write-Host " -> OK" -ForegroundColor Green
        [void]$report.Add([PSCustomObject]@{
            Check  = "Mailbox"
            Item   = $email
            Result = "OK"
            Detail = "Mailbox found"
        })
    }
    else {
        Write-Host " -> MISSING" -ForegroundColor Red
        [void]$report.Add([PSCustomObject]@{
            Check  = "Mailbox"
            Item   = $email
            Result = "MISSING"
            Detail = "Mailbox not found in destination tenant — M1 may be incomplete"
        })
        $missingMailboxes++
        $issues++
    }
}

if ($missingMailboxes -eq 0) {
    Write-Host "  All $($uniqueMailboxes.Count) target mailboxes exist." -ForegroundColor Green
} else {
    Write-Host "  $missingMailboxes mailbox(es) missing — M1 must complete before Script 4." -ForegroundColor Red
}
Write-Host ""

# =============================================================
# CHECK 3: External members summary
# =============================================================
Write-Host "--- Check 3/4: External members ---" -ForegroundColor Cyan
$externalRows = $membership | Where-Object { $_.Status -eq "External" }

if ($externalRows.Count -eq 0) {
    Write-Host "  No external members." -ForegroundColor Green
}
else {
    Write-Host "  $($externalRows.Count) external member assignment(s) found." -ForegroundColor DarkYellow
    Write-Host "  Script 4 will create mail contacts for these automatically." -ForegroundColor Gray
    $externalRows | Select-Object NewGroupName, MemberName, NewMemberEmail -Unique | ForEach-Object {
        Write-Host "    $($_.MemberName) | $($_.NewMemberEmail) -> [$($_.NewGroupName)]" -ForegroundColor DarkYellow
        [void]$report.Add([PSCustomObject]@{
            Check  = "External"
            Item   = $_.NewMemberEmail
            Result = "INFO"
            Detail = "Will be created as mail contact and added to $($_.NewGroupName)"
        })
    }
}
Write-Host ""

# =============================================================
# CHECK 4: Unmapped and Nested DL members
# =============================================================
Write-Host "--- Check 4/4: Unmapped and Nested DL members ---" -ForegroundColor Cyan
$unmappedRows = $membership | Where-Object { $_.Status -eq "Unmapped" }
$nestedDLRows = $membership | Where-Object { $_.Status -eq "NestedDL" }

if ($nestedDLRows.Count -gt 0) {
    Write-Host "  $($nestedDLRows.Count) nested DL assignment(s) — will be added as group members:" -ForegroundColor Cyan
    $nestedDLRows | ForEach-Object {
        Write-Host "    $($_.MemberName) -> $($_.NewMemberEmail) in [$($_.NewGroupName)]" -ForegroundColor Cyan
        [void]$report.Add([PSCustomObject]@{
            Check  = "NestedDL"
            Item   = $_.OldMemberEmail
            Result = "INFO"
            Detail = "Resolved to $($_.NewMemberEmail) in $($_.NewGroupName)"
        })
    }
} else {
    Write-Host "  No nested DL members." -ForegroundColor Green
}

if ($unmappedRows.Count -gt 0) {
    Write-Host "  $($unmappedRows.Count) unmapped member(s) — will NOT be added (review before Script 4):" -ForegroundColor Red
    $unmappedRows | ForEach-Object {
        Write-Host "    $($_.MemberName) | $($_.OldMemberEmail) -> [$($_.NewGroupName)]" -ForegroundColor Red
        [void]$report.Add([PSCustomObject]@{
            Check  = "Unmapped"
            Item   = $_.OldMemberEmail
            Result = "WARNING"
            Detail = "Not in MailboxMapping.csv — will be skipped by Script 4"
        })
        $issues++
    }
} else {
    Write-Host "  No unmapped members." -ForegroundColor Green
}
Write-Host ""

# =============================================================
# SUMMARY
# =============================================================
$report | Export-Csv -Path $reportFile -NoTypeInformation -Encoding UTF8

$blockers = ($report | Where-Object Result -in @("CONFLICT","MISSING")).Count
$warnings = ($report | Where-Object Result -eq "WARNING").Count

Write-Host "==========================================" -ForegroundColor Cyan
Write-Host " Validation Complete" -ForegroundColor $(if ($blockers -gt 0) { 'Red' } elseif ($warnings -gt 0) { 'Yellow' } else { 'Green' })
Write-Host " Group alias conflicts : $aliasConflicts" -ForegroundColor $(if ($aliasConflicts -gt 0) { 'Red' } else { 'Green' })
Write-Host " Missing mailboxes     : $missingMailboxes" -ForegroundColor $(if ($missingMailboxes -gt 0) { 'Red' } else { 'Green' })
Write-Host " External members      : $($externalRows.Count)" -ForegroundColor $(if ($externalRows.Count -gt 0) { 'DarkYellow' } else { 'Green' })
Write-Host " Nested DLs            : $($nestedDLRows.Count)" -ForegroundColor $(if ($nestedDLRows.Count -gt 0) { 'Cyan' } else { 'Green' })
Write-Host " Unmapped members      : $($unmappedRows.Count)" -ForegroundColor $(if ($unmappedRows.Count -gt 0) { 'Red' } else { 'Green' })
Write-Host " Report                : $reportFile" -ForegroundColor Gray
Write-Host "==========================================" -ForegroundColor Cyan
Write-Host ""

if ($blockers -gt 0) {
    Write-Host "BLOCKED: $blockers issue(s) must be resolved before running Scripts 3 and 4." -ForegroundColor Red
    Write-Host "Review $reportFile for details." -ForegroundColor Yellow
} elseif ($warnings -gt 0) {
    Write-Host "WARNINGS: $warnings item(s) need review but will not block migration." -ForegroundColor Yellow
    Write-Host "Safe to proceed with Scripts 3 and 4." -ForegroundColor Green
} else {
    Write-Host "All checks passed. Safe to run Script 3." -ForegroundColor Green
}
