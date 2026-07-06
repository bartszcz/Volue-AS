# =============================================================
# Script 5: Rollback
# =============================================================
# Usage:
#   .\5-Rollback.ps1
#   .\5-Rollback.ps1 -ConfigFile "C:\MyMigration\MigrationConfig.csv"
#
# Must be connected to DESTINATION tenant.
#
# Reads:   CreateGroups_Log.csv   (removes groups created by Script 3)
#          AddMembers_Log.csv     (removes mail contacts created by Script 4)
#
# What it removes:
#   - Distribution groups created by Script 3 (Status = Created)
#   - Mail contacts created by Script 4 for external members
#
# What it does NOT remove:
#   - Groups that already existed before migration (Status = AlreadyExists)
#   - User mailboxes
#   - Any objects not logged by Scripts 3/4
#
# Creates: Rollback_Log.csv
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
    exit 1
}

$OutputFolder = $config["OutputFolder"]
$TargetDomain = $config["TargetDomain"]
$TargetAdmin  = $config["TargetAdminUPN"]

$groupsLogFile  = Join-Path $OutputFolder "CreateGroups_Log.csv"
$membersLogFile = Join-Path $OutputFolder "AddMembers_Log.csv"
$rollbackLog    = Join-Path $OutputFolder "Rollback_Log.csv"

Write-Host "==========================================" -ForegroundColor Cyan
Write-Host " Script 5: Rollback" -ForegroundColor Cyan
Write-Host " Expected org : $TargetDomain" -ForegroundColor Gray
Write-Host " Target Admin : $TargetAdmin" -ForegroundColor Gray
Write-Host "==========================================" -ForegroundColor Cyan
Write-Host ""

if (-not (Test-Path $groupsLogFile) -and -not (Test-Path $membersLogFile)) {
    Write-Host "ERROR: No log files found. Nothing to roll back." -ForegroundColor Red
    exit 1
}

# --- CONNECT ---
Write-Host "Verifying Exchange Online connection..." -ForegroundColor White
try {
    $orgConfig = Get-OrganizationConfig -ErrorAction Stop
    Write-Host "Connected." -ForegroundColor Green
}
catch {
    Write-Host "Not connected. Connecting..." -ForegroundColor Yellow
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
    Write-Host "ERROR: Wrong tenant! Rollback must run against the DESTINATION tenant." -ForegroundColor Red
    Write-Host "  Expected : *$TargetDomain* or *$domainRoot.onmicrosoft.com*" -ForegroundColor Yellow
    Write-Host "  Connected: $connectedOrg" -ForegroundColor Yellow
    Write-Host ""
    Write-Host "  Disconnect-ExchangeOnline -Confirm:`$false" -ForegroundColor White
    Write-Host "  Connect-ExchangeOnline -UserPrincipalName $TargetAdmin" -ForegroundColor White
    exit 1
}
Write-Host "Tenant validated OK." -ForegroundColor Green
Write-Host ""

# =============================================================
# PREVIEW — show what will be removed before doing anything
# =============================================================
$groupsToRemove   = @()
$contactsToRemove = @()

if (Test-Path $groupsLogFile) {
    $groupsToRemove = Import-Csv -Path $groupsLogFile | Where-Object { $_.Status -eq "Created" }
}
if (Test-Path $membersLogFile) {
    # External contacts are identified by Status=Added AND the Member email not in TargetDomain
    $targetDomainEsc = [regex]::Escape($TargetDomain)
    $contactsToRemove = Import-Csv -Path $membersLogFile |
        Where-Object { $_.Status -eq "Added" -and $_.Member -notmatch "@$targetDomainEsc$" } |
        Select-Object -ExpandProperty Member -Unique
}

Write-Host "=========================================" -ForegroundColor Yellow
Write-Host " ROLLBACK PREVIEW — nothing removed yet" -ForegroundColor Yellow
Write-Host ""
Write-Host " Distribution groups to REMOVE ($($groupsToRemove.Count)):" -ForegroundColor White
if ($groupsToRemove.Count -gt 0) {
    $groupsToRemove | ForEach-Object { Write-Host "   - $($_.GroupName) [$($_.Email)]" -ForegroundColor Red }
} else {
    Write-Host "   None" -ForegroundColor DarkGray
}
Write-Host ""
Write-Host " Mail contacts to REMOVE ($($contactsToRemove.Count)):" -ForegroundColor White
if ($contactsToRemove.Count -gt 0) {
    $contactsToRemove | ForEach-Object { Write-Host "   - $_" -ForegroundColor DarkYellow }
} else {
    Write-Host "   None" -ForegroundColor DarkGray
}
Write-Host ""
Write-Host " Groups with Status=AlreadyExists will NOT be removed." -ForegroundColor DarkGray
Write-Host "=========================================" -ForegroundColor Yellow
Write-Host ""

if ($groupsToRemove.Count -eq 0 -and $contactsToRemove.Count -eq 0) {
    Write-Host "Nothing to roll back." -ForegroundColor Green
    exit 0
}

$confirm = Read-Host "Type YES to proceed with rollback, anything else to abort"
if ($confirm -ne "YES") {
    Write-Host "Aborted. No changes made." -ForegroundColor DarkYellow
    exit 0
}

Write-Host ""
$log = [System.Collections.ArrayList]::new()

# =============================================================
# REMOVE DISTRIBUTION GROUPS
# =============================================================
if ($groupsToRemove.Count -gt 0) {
    Write-Host "--- Removing distribution groups ---" -ForegroundColor Cyan
    foreach ($g in $groupsToRemove) {
        Write-Host "  Removing: $($g.GroupName) [$($g.Email)]" -ForegroundColor Gray -NoNewline
        try {
            Remove-DistributionGroup -Identity $g.Email -Confirm:$false -ErrorAction Stop
            Write-Host " -> Removed" -ForegroundColor Green
            [void]$log.Add([PSCustomObject]@{ Type="Group"; Name=$g.GroupName; Email=$g.Email; Status="Removed"; Error="" })
        }
        catch {
            $errMsg = $_.Exception.Message
            if ($errMsg -match "couldn't be found|doesn't exist") {
                Write-Host " -> Already gone" -ForegroundColor DarkYellow
                [void]$log.Add([PSCustomObject]@{ Type="Group"; Name=$g.GroupName; Email=$g.Email; Status="AlreadyGone"; Error="" })
            }
            else {
                Write-Host " -> ERROR: $errMsg" -ForegroundColor Red
                [void]$log.Add([PSCustomObject]@{ Type="Group"; Name=$g.GroupName; Email=$g.Email; Status="Failed"; Error=$errMsg })
            }
        }
    }
    Write-Host ""
}

# =============================================================
# REMOVE MAIL CONTACTS
# =============================================================
if ($contactsToRemove.Count -gt 0) {
    Write-Host "--- Removing mail contacts ---" -ForegroundColor Cyan
    foreach ($email in $contactsToRemove) {
        Write-Host "  Removing contact: $email" -ForegroundColor Gray -NoNewline
        try {
            Remove-MailContact -Identity $email -Confirm:$false -ErrorAction Stop
            Write-Host " -> Removed" -ForegroundColor Green
            [void]$log.Add([PSCustomObject]@{ Type="Contact"; Name=""; Email=$email; Status="Removed"; Error="" })
        }
        catch {
            $errMsg = $_.Exception.Message
            if ($errMsg -match "couldn't be found|doesn't exist") {
                Write-Host " -> Already gone" -ForegroundColor DarkYellow
                [void]$log.Add([PSCustomObject]@{ Type="Contact"; Name=""; Email=$email; Status="AlreadyGone"; Error="" })
            }
            else {
                Write-Host " -> ERROR: $errMsg" -ForegroundColor Red
                [void]$log.Add([PSCustomObject]@{ Type="Contact"; Name=""; Email=$email; Status="Failed"; Error=$errMsg })
            }
        }
    }
    Write-Host ""
}

$log | Export-Csv -Path $rollbackLog -NoTypeInformation -Encoding UTF8

$removed = ($log | Where-Object Status -eq "Removed").Count
$gone    = ($log | Where-Object Status -eq "AlreadyGone").Count
$failed  = ($log | Where-Object Status -eq "Failed").Count

Write-Host "==========================================" -ForegroundColor Cyan
Write-Host " Rollback Complete" -ForegroundColor Green
Write-Host " Removed     : $removed" -ForegroundColor Green
Write-Host " Already gone: $gone" -ForegroundColor DarkYellow
Write-Host " Failed      : $failed" -ForegroundColor $(if ($failed -gt 0) { 'Red' } else { 'Green' })
Write-Host " Log         : $rollbackLog" -ForegroundColor Gray
Write-Host "==========================================" -ForegroundColor Cyan
Write-Host ""
if ($failed -gt 0) {
    Write-Host "Some items could not be removed. Review $rollbackLog and remove manually." -ForegroundColor Yellow
} else {
    Write-Host "Rollback complete. You can now re-run from Script 2 if needed." -ForegroundColor Green
}
