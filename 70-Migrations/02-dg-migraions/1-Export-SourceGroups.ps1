# =============================================================
# Script 1: Export Distribution Groups & Members from Source
# =============================================================
# Usage:
#   .\1-Export-SourceGroups.ps1
#   .\1-Export-SourceGroups.ps1 -ConfigFile "C:\MyMigration\MigrationConfig.csv"
#
# Reads MigrationConfig.csv for settings.
# Must be connected to SOURCE tenant (SourceDomain in config).
#
# v3 changes:
#   - Tenant domain validation: confirms connected org matches SourceDomain
#   - Ambiguity fix: uses PrimarySmtpAddress as group identity
# =============================================================

param(
    [string]$ConfigFile = ".\MigrationConfig.csv"
)

# --- LOAD CONFIG ---
if (-not (Test-Path $ConfigFile)) {
    Write-Host "ERROR: Config file not found: $ConfigFile" -ForegroundColor Red
    Write-Host "Place MigrationConfig.csv in the same folder or specify -ConfigFile path." -ForegroundColor Yellow
    exit 1
}

$config = @{}
Import-Csv -Path $ConfigFile | ForEach-Object {
    $config[$_.Setting] = $_.Value
}

$OutputFolder  = $config["OutputFolder"]
$SourceAdmin   = $config["SourceAdminUPN"]
$SourceCompany = $config["SourceCompanyName"]
$SourceDomain  = $config["SourceDomain"]

# --- VALIDATE CONFIG ---
$requiredKeys = @("OutputFolder", "SourceAdminUPN", "SourceCompanyName", "SourceDomain")
$missingKeys  = $requiredKeys | Where-Object { [string]::IsNullOrWhiteSpace($config[$_]) }
if ($missingKeys) {
    Write-Host "ERROR: Missing or empty values in MigrationConfig.csv:" -ForegroundColor Red
    $missingKeys | ForEach-Object { Write-Host "  - $_" -ForegroundColor Yellow }
    Write-Host "Check that MigrationConfig.csv has a Setting,Value header row and all required keys." -ForegroundColor Yellow
    exit 1
}

if (-not (Test-Path $OutputFolder)) {
    New-Item -ItemType Directory -Path $OutputFolder -Force | Out-Null
}

$groupsFile  = Join-Path $OutputFolder "GroupMembers.csv"
$summaryFile = Join-Path $OutputFolder "GroupSummary.csv"

Write-Host "==========================================" -ForegroundColor Cyan
Write-Host " Script 1: Export Source Distribution Groups" -ForegroundColor Cyan
Write-Host " Company      : $SourceCompany" -ForegroundColor Gray
Write-Host " Expected org : $SourceDomain" -ForegroundColor Gray
Write-Host " Admin        : $SourceAdmin" -ForegroundColor Gray
Write-Host " Output       : $OutputFolder" -ForegroundColor Gray
Write-Host "==========================================" -ForegroundColor Cyan
Write-Host ""

# --- CONNECT ---
Write-Host "Verifying Exchange Online connection..." -ForegroundColor White
try {
    $orgConfig = Get-OrganizationConfig -ErrorAction Stop
    Write-Host "Connected." -ForegroundColor Green
}
catch {
    Write-Host "Not connected. Connecting to source tenant..." -ForegroundColor Yellow
    try {
        Connect-ExchangeOnline -UserPrincipalName $SourceAdmin -ErrorAction Stop
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
$domainRoot     = ($SourceDomain -split '\.')[0]
$domainMatches  = $connectedOrg -match [regex]::Escape($SourceDomain) -or $connectedOrg -match "^$domainRoot\.onmicrosoft\.com$"

if (-not $domainMatches) {
    Write-Host ""
    Write-Host "ERROR: Wrong tenant! This script must run against the SOURCE tenant." -ForegroundColor Red
    Write-Host "  Expected : *$SourceDomain* or *$domainRoot.onmicrosoft.com*" -ForegroundColor Yellow
    Write-Host "  Connected: $connectedOrg" -ForegroundColor Yellow
    Write-Host ""
    Write-Host "To fix:" -ForegroundColor Cyan
    Write-Host "  Disconnect-ExchangeOnline -Confirm:`$false" -ForegroundColor White
    Write-Host "  Connect-ExchangeOnline -UserPrincipalName $SourceAdmin" -ForegroundColor White
    exit 1
}

Write-Host "Tenant validated OK." -ForegroundColor Green
Write-Host ""

# --- EXPORT ---
Write-Host "Fetching distribution groups..." -ForegroundColor White
$groups = Get-DistributionGroup -ResultSize Unlimited
Write-Host "Found $($groups.Count) distribution groups." -ForegroundColor Green
Write-Host ""

$allMembers   = [System.Collections.ArrayList]::new()
$groupSummary = [System.Collections.ArrayList]::new()
$counter = 0

foreach ($group in $groups) {
    $counter++
    Write-Host "[$counter/$($groups.Count)] $($group.DisplayName)" -ForegroundColor Gray -NoNewline

    # Use PrimarySmtpAddress to avoid display name ambiguity (e.g. group + user with same name)
    try {
        $members = Get-DistributionGroupMember -Identity $group.PrimarySmtpAddress -ResultSize Unlimited -ErrorAction Stop
    }
    catch {
        Write-Host " -> ERROR: $($_.Exception.Message)" -ForegroundColor Red
        $members = @()
    }

    Write-Host " -> $($members.Count) members" -ForegroundColor DarkGray

    [void]$groupSummary.Add([PSCustomObject]@{
        GroupName   = $group.DisplayName
        GroupEmail  = $group.PrimarySmtpAddress
        MemberCount = $members.Count
        GroupType   = $group.RecipientType
    })

    foreach ($member in $members) {
        [void]$allMembers.Add([PSCustomObject]@{
            Group              = $group.DisplayName
            GroupEmail         = $group.PrimarySmtpAddress
            DisplayName        = $member.DisplayName
            PrimarySmtpAddress = $member.PrimarySmtpAddress
            RecipientType      = $member.RecipientType
        })
    }
}

$allMembers   | Export-Csv -Path $groupsFile  -NoTypeInformation -Encoding UTF8
$groupSummary | Export-Csv -Path $summaryFile -NoTypeInformation -Encoding UTF8

Write-Host ""
Write-Host "==========================================" -ForegroundColor Cyan
Write-Host " Export Complete!" -ForegroundColor Green
Write-Host " Groups exported : $($groups.Count)" -ForegroundColor White
Write-Host " Member rows     : $($allMembers.Count)" -ForegroundColor White
Write-Host " Files:" -ForegroundColor White
Write-Host "   $groupsFile" -ForegroundColor Gray
Write-Host "   $summaryFile" -ForegroundColor Gray
Write-Host "==========================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "Next: Place your MailboxMapping.csv in $OutputFolder, then run Script 2." -ForegroundColor Yellow
