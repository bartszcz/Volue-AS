# =============================================================
# Script 3: Create Distribution Groups on Destination Tenant
# =============================================================
# Usage:
#   .\3-Create-Groups.ps1
#   .\3-Create-Groups.ps1 -ConfigFile "C:\MyMigration\MigrationConfig.csv"
#
# Must be connected to DESTINATION tenant (TargetDomain in config).
#
# Reads:   NewGroupSummary.csv    (edited in Script 2)
# Creates: CreateGroups_Log.csv  (log of what was created)
#
# v3 changes:
#   - Tenant domain validation: confirms connected org matches TargetDomain
#   - Uses name and email exactly as written in NewGroupSummary.csv
#   - No email auto-generation — what you edited is what gets created
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

$OutputFolder = $config["OutputFolder"]
$TargetDomain = $config["TargetDomain"]
$TargetAdmin  = $config["TargetAdminUPN"]

# --- VALIDATE CONFIG ---
$requiredKeys = @("OutputFolder", "TargetDomain", "TargetAdminUPN")
$missingKeys  = $requiredKeys | Where-Object { [string]::IsNullOrWhiteSpace($config[$_]) }
if ($missingKeys) {
    Write-Host "ERROR: Missing or empty values in MigrationConfig.csv:" -ForegroundColor Red
    $missingKeys | ForEach-Object { Write-Host "  - $_" -ForegroundColor Yellow }
    Write-Host "Check that MigrationConfig.csv has a Setting,Value header row and all required keys." -ForegroundColor Yellow
    exit 1
}

$summaryFile = Join-Path $OutputFolder "NewGroupSummary.csv"
$logFile     = Join-Path $OutputFolder "CreateGroups_Log.csv"

if (-not (Test-Path $summaryFile)) {
    Write-Host "ERROR: $summaryFile not found. Run Script 2 first." -ForegroundColor Red
    exit 1
}

$groups = Import-Csv -Path $summaryFile

Write-Host "==========================================" -ForegroundColor Cyan
Write-Host " Script 3: Create Distribution Groups" -ForegroundColor Cyan
Write-Host " Expected org  : $TargetDomain" -ForegroundColor Gray
Write-Host " Target Admin  : $TargetAdmin" -ForegroundColor Gray
Write-Host " Groups to create: $($groups.Count)" -ForegroundColor Gray
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
        Write-Host "ERROR: Could not connect. Run Connect-ExchangeOnline manually first." -ForegroundColor Red
        exit 1
    }
}

# --- TENANT VALIDATION ---
$connectedOrg = $orgConfig.Name
Write-Host "Connected org : $connectedOrg" -ForegroundColor Gray

# Accept both vanity domain (volue.com) and onmicrosoft name (volue.onmicrosoft.com)
$domainRoot     = ($TargetDomain -split '\.')[0]
$domainMatches  = $connectedOrg -match [regex]::Escape($TargetDomain) -or $connectedOrg -match "^$domainRoot\.onmicrosoft\.com$"

if (-not $domainMatches) {
    Write-Host ""
    Write-Host "ERROR: Wrong tenant! This script must run against the DESTINATION tenant." -ForegroundColor Red
    Write-Host "  Expected : *$TargetDomain* or *$domainRoot.onmicrosoft.com*" -ForegroundColor Yellow
    Write-Host "  Connected: $connectedOrg" -ForegroundColor Yellow
    Write-Host ""
    Write-Host "To fix:" -ForegroundColor Cyan
    Write-Host "  Disconnect-ExchangeOnline -Confirm:`$false" -ForegroundColor White
    Write-Host "  Connect-ExchangeOnline -UserPrincipalName $TargetAdmin" -ForegroundColor White
    exit 1
}

Write-Host "Tenant validated OK." -ForegroundColor Green
Write-Host ""

$log = [System.Collections.ArrayList]::new()
$counter = 0
$autoAll = $false

foreach ($g in $groups) {
    $counter++

    Write-Host "-------------------------------------------" -ForegroundColor DarkGray
    Write-Host "[$counter/$($groups.Count)]" -ForegroundColor DarkGray
    Write-Host "Original Name  : " -NoNewline; Write-Host "$($g.OriginalName)" -ForegroundColor Yellow
    Write-Host "New Name       : " -NoNewline; Write-Host "$($g.NewGroupName)" -ForegroundColor Green
    Write-Host "New Email      : " -NoNewline; Write-Host "$($g.NewGroupEmail)" -ForegroundColor Green
    Write-Host "Members        : $($g.TotalMembers) (Mapped: $($g.Mapped), External: $($g.External), Unmapped: $($g.Unmapped))" -ForegroundColor White
    Write-Host ""

    if ($autoAll) {
        $choice = "Y"
    } else {
        $choice = Read-Host "(Y)es / (N)o skip / (A)ll remaining / (S)top"
    }

    # Use name/email exactly from CSV — no re-derivation
    $finalName  = $g.NewGroupName.Trim()
    $finalEmail = $g.NewGroupEmail.Trim()

    switch ($choice.ToUpper()) {
        "Y" {
            try {
                New-DistributionGroup -Name $finalName -DisplayName $finalName -PrimarySmtpAddress $finalEmail -ErrorAction Stop
                Write-Host "  -> Created!" -ForegroundColor Green
                [void]$log.Add([PSCustomObject]@{ OriginalName=$g.OriginalName; GroupName=$finalName; Email=$finalEmail; Status="Created"; Error="" })
            }
            catch {
                $errMsg = $_.Exception.Message
                if ($errMsg -match "already exists") {
                    Write-Host "  -> Already exists, skipping." -ForegroundColor DarkYellow
                    [void]$log.Add([PSCustomObject]@{ OriginalName=$g.OriginalName; GroupName=$finalName; Email=$finalEmail; Status="AlreadyExists"; Error="" })
                } else {
                    Write-Host "  -> ERROR: $errMsg" -ForegroundColor Red
                    [void]$log.Add([PSCustomObject]@{ OriginalName=$g.OriginalName; GroupName=$finalName; Email=$finalEmail; Status="Failed"; Error=$errMsg })
                }
            }
        }
        "A" {
            $autoAll = $true
            try {
                New-DistributionGroup -Name $finalName -DisplayName $finalName -PrimarySmtpAddress $finalEmail -ErrorAction Stop
                Write-Host "  -> Created!" -ForegroundColor Green
                [void]$log.Add([PSCustomObject]@{ OriginalName=$g.OriginalName; GroupName=$finalName; Email=$finalEmail; Status="Created"; Error="" })
            }
            catch {
                $errMsg = $_.Exception.Message
                if ($errMsg -match "already exists") {
                    Write-Host "  Already exists: $finalName" -ForegroundColor DarkYellow
                    [void]$log.Add([PSCustomObject]@{ OriginalName=$g.OriginalName; GroupName=$finalName; Email=$finalEmail; Status="AlreadyExists"; Error="" })
                } else {
                    Write-Host "  ERROR: $finalName - $errMsg" -ForegroundColor Red
                    [void]$log.Add([PSCustomObject]@{ OriginalName=$g.OriginalName; GroupName=$finalName; Email=$finalEmail; Status="Failed"; Error=$errMsg })
                }
            }
        }
        "S" {
            Write-Host "Stopping." -ForegroundColor DarkYellow
            foreach ($rg in $groups[($counter - 1)..($groups.Count - 1)]) {
                [void]$log.Add([PSCustomObject]@{ OriginalName=$rg.OriginalName; GroupName=$rg.NewGroupName; Email=$rg.NewGroupEmail; Status="Skipped"; Error="" })
            }
            break
        }
        default {
            Write-Host "  -> Skipped." -ForegroundColor DarkYellow
            [void]$log.Add([PSCustomObject]@{ OriginalName=$g.OriginalName; GroupName=$finalName; Email=$finalEmail; Status="Skipped"; Error="" })
        }
    }
    Write-Host ""
}

$log | Export-Csv -Path $logFile -NoTypeInformation -Encoding UTF8

$created = ($log | Where-Object Status -eq "Created").Count
$exists  = ($log | Where-Object Status -eq "AlreadyExists").Count
$failed  = ($log | Where-Object Status -eq "Failed").Count
$skipped = ($log | Where-Object Status -eq "Skipped").Count

Write-Host "==========================================" -ForegroundColor Cyan
Write-Host " Group Creation Complete!" -ForegroundColor Green
Write-Host " Created : $created" -ForegroundColor Green
Write-Host " Existed : $exists" -ForegroundColor DarkYellow
Write-Host " Failed  : $failed" -ForegroundColor $(if ($failed -gt 0) { 'Red' } else { 'Green' })
Write-Host " Skipped : $skipped" -ForegroundColor DarkYellow
Write-Host " Log     : $logFile" -ForegroundColor Gray
Write-Host "==========================================" -ForegroundColor Cyan
Write-Host ""
if ($failed -gt 0) {
    Write-Host "WARNING: $failed group(s) failed to create. Review $logFile before running Script 4." -ForegroundColor Red
    Write-Host ""
}
Write-Host "Next: Run Script 4 to add members." -ForegroundColor Yellow
Write-Host "Stay connected to the DESTINATION tenant ($TargetDomain)." -ForegroundColor Gray
