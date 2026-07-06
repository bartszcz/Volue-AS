# =============================================================
# Script 2: Build New Group Membership Mapping
# =============================================================
# Usage:
#   .\2-Build-Mapping.ps1
#   .\2-Build-Mapping.ps1 -ConfigFile "C:\MyMigration\MigrationConfig.csv"
#
# Reads MigrationConfig.csv for all settings.
# No Exchange connection needed -- runs locally.
#
# Reads:  GroupMembers.csv (from Script 1)
#         MailboxMapping.csv (your source->target mapping)
# Creates: NewGroupMembership.csv
#          NewGroupSummary.csv
#          GroupNameMapping.csv
#          UnmappedMembers.csv (if any)
#
# FIX v2: MigrationConfig.csv is comma-delimited (default) — no Delimiter needed
#         MailboxMapping.csv is semicolon-delimited — added -Delimiter ';' to that load only
# =============================================================

param(
    [string]$ConfigFile = ".\MigrationConfig.csv"
)

# --- LOAD CONFIG ---
if (-not (Test-Path $ConfigFile)) {
    Write-Host "ERROR: Config file not found: $ConfigFile" -ForegroundColor Red
    exit 1
}

# MigrationConfig.csv is comma-delimited — use default Import-Csv (no Delimiter)
Import-Csv -Path $ConfigFile | ForEach-Object {
    $config[$_.Setting] = $_.Value
}

$OutputFolder    = $config["OutputFolder"]
$SourceCompany   = $config["SourceCompanyName"]
$SourceDomain    = $config["SourceDomain"]
$TargetDomain    = $config["TargetDomain"]
$Prefix          = $config["NewGroupPrefix"]
$Suffix          = $config["NewGroupSuffix"]

if ([string]::IsNullOrWhiteSpace($OutputFolder)) {
    Write-Host "ERROR: OutputFolder not loaded from config. Check that MigrationConfig.csv has columns: Setting,Value" -ForegroundColor Red
    exit 1
}

$membersFile      = Join-Path $OutputFolder "GroupMembers.csv"
$mappingInputFile = Join-Path $OutputFolder "MailboxMapping.csv"
$outputFile       = Join-Path $OutputFolder "NewGroupMembership.csv"
$summaryFile      = Join-Path $OutputFolder "NewGroupSummary.csv"
$groupMapFile     = Join-Path $OutputFolder "GroupNameMapping.csv"
$unmappedFile     = Join-Path $OutputFolder "UnmappedMembers.csv"

# Validate
if (-not (Test-Path $membersFile)) {
    Write-Host "ERROR: $membersFile not found. Run Script 1 first." -ForegroundColor Red
    exit 1
}
if (-not (Test-Path $mappingInputFile)) {
    Write-Host "ERROR: $mappingInputFile not found." -ForegroundColor Red
    Write-Host "Place your MailboxMapping.csv (columns: SourceEmail, TargetEmail) in $OutputFolder" -ForegroundColor Yellow
    exit 1
}

Write-Host "==========================================" -ForegroundColor Cyan
Write-Host " Script 2: Build New Group Membership Map" -ForegroundColor Cyan
Write-Host " Source Company : $SourceCompany" -ForegroundColor Gray
Write-Host " Source Domain  : $SourceDomain" -ForegroundColor Gray
Write-Host " Target Domain  : $TargetDomain" -ForegroundColor Gray
Write-Host " Prefix         : $Prefix" -ForegroundColor Gray
Write-Host " Suffix         : $Suffix" -ForegroundColor Gray
Write-Host "==========================================" -ForegroundColor Cyan
Write-Host ""

# --- LOAD MAILBOX MAPPING ---
$mapping = @{}
$mappingDetails = @{}
# FIX: MailboxMapping.csv uses semicolon delimiter
Import-Csv -Path $mappingInputFile -Delimiter ';' | ForEach-Object {
    $source = $_.SourceEmail
    $target = $_.TargetEmail
    $sourceMailboxName = $_.SourceMailboxName
    $targetMailboxName = $_.TargetMailboxName

    if (-not $source -or -not $target) { return }
    $source = $source.Trim().ToLower()
    $target = $target.Trim()

    if ($target -eq '#N/A' -or [string]::IsNullOrWhiteSpace($target)) { return }

    if (-not $mapping.ContainsKey($source)) {
        $mapping[$source] = $target
        $mappingDetails[$source] = @{
            TargetEmail = $target
            SourceMailboxName = if ([string]::IsNullOrWhiteSpace($sourceMailboxName)) { "" } else { $sourceMailboxName.Trim() }
            TargetMailboxName = if ([string]::IsNullOrWhiteSpace($targetMailboxName)) { "" } else { $targetMailboxName.Trim() }
        }
    }
}
Write-Host "Loaded $($mapping.Count) mailbox mappings." -ForegroundColor Green

# --- LOAD GROUP MEMBERS ---
$members = Import-Csv -Path $membersFile
Write-Host "Loaded $($members.Count) group membership rows." -ForegroundColor Green
Write-Host ""

# --- HELPER: Transform group name ---
$companyPattern = [regex]::Escape($SourceCompany)

# Extract suffix company name for duplicate detection (e.g., "- Quorum" -> "Quorum")
$suffixCompanyName = ""
if (-not [string]::IsNullOrWhiteSpace($Suffix)) {
    $suffixCompanyName = $Suffix -replace '^\s*[-|]\s*', ''
    $suffixCompanyName = $suffixCompanyName.Trim()
}
$suffixCompanyPattern = if ($suffixCompanyName) { [regex]::Escape($suffixCompanyName) } else { "" }

function Get-NewGroupName {
    param([string]$OriginalName)

    $name = $OriginalName
    # Remove trailing timestamps (14+ digits)
    $name = $name -replace '\d{14,}$', ''
    # Remove "| CompanyName" suffix pattern
    $name = $name -replace "\s*\|\s*(?i)$companyPattern", ''
    # Remove standalone company name anywhere
    $name = $name -replace "(?i)\b$companyPattern\b", ''
    # Clean whitespace and trailing separators
    $name = $name.Trim()
    $name = $name -replace '\s*[-|]\s*$', ''
    $name = $name -replace '\s+', ' '
    $name = $name.Trim()
    
    # Check if original name already contains the suffix company name (case-insensitive)
    $alreadyHasSuffix = $false
    if ($suffixCompanyPattern) {
        # Check if the cleaned name ends with the company name (with separator)
        if ($name -match "[-|]\s*$suffixCompanyPattern\s*$") {
            $alreadyHasSuffix = $true
        }
        # Also check original name for embedded suffix
        if ($OriginalName -match "[-|]\s*$suffixCompanyPattern\s*$") {
            $alreadyHasSuffix = $true
        }
    }
    
    # Build final name with prefix and conditional suffix
    if (-not [string]::IsNullOrWhiteSpace($name)) {
        if ($alreadyHasSuffix -or [string]::IsNullOrWhiteSpace($Suffix)) {
            $name = "$Prefix $name"
        } else {
            $name = "$Prefix $name $Suffix"
        }
    } else {
        if ([string]::IsNullOrWhiteSpace($Suffix)) {
            $name = "$Prefix General"
        } else {
            $name = "$Prefix General $Suffix"
        }
    }
    return $name
}

function Get-EmailAlias {
    param([string]$GroupName)
    $alias = $GroupName -replace '[^a-zA-Z0-9\s-]', ''
    $alias = $alias.Trim() -replace '\s+', '-'
    $alias = $alias.ToLower()
    return "$alias@$TargetDomain"
}

# Escaped source domain for regex
$sourceDomainEscaped = [regex]::Escape($SourceDomain)

# --- PROCESS ---
$results    = [System.Collections.ArrayList]::new()
$unmapped   = [System.Collections.ArrayList]::new()
$groupSet   = @{}

foreach ($row in $members) {
    if ([string]::IsNullOrWhiteSpace($row.Group) -or [string]::IsNullOrWhiteSpace($row.PrimarySmtpAddress)) {
        continue
    }

    $originalGroup  = $row.Group.Trim()
    $oldGroupEmail  = if ($row.GroupEmail) { $row.GroupEmail.Trim() } else { "" }
    $oldMemberEmail = $row.PrimarySmtpAddress.Trim().ToLower()
    $memberName     = if ($row.DisplayName) { $row.DisplayName.Trim() } else { "Unknown" }

    $newGroupName  = Get-NewGroupName -OriginalName $originalGroup
    $newGroupEmail = Get-EmailAlias -GroupName $newGroupName

    # Track unique groups
    if (-not $groupSet.ContainsKey($newGroupName)) {
        $groupSet[$newGroupName] = @{
            Email         = $newGroupEmail
            OriginalName  = $originalGroup
            OriginalEmail = $oldGroupEmail
            MemberCount   = 0
            Mapped        = 0
            External      = 0
            Unmapped      = 0
        }
    }

    # Map member email
    $newMemberEmail = ""
    $sourceMailboxName = ""
    $targetMailboxName = ""
    $status = ""

    if ($mapping.ContainsKey($oldMemberEmail)) {
        $newMemberEmail = $mapping[$oldMemberEmail]
        $sourceMailboxName = $mappingDetails[$oldMemberEmail].SourceMailboxName
        $targetMailboxName = $mappingDetails[$oldMemberEmail].TargetMailboxName
        $status = "Mapped"
        $groupSet[$newGroupName].Mapped++
    }
    elseif ($oldMemberEmail -notmatch "@$sourceDomainEscaped$") {
        $newMemberEmail = $row.PrimarySmtpAddress.Trim()
        $status = "External"
        $groupSet[$newGroupName].External++
    }
    else {
        $newMemberEmail = "NOT_FOUND"
        $status = "Unmapped"
        $groupSet[$newGroupName].Unmapped++
        [void]$unmapped.Add([PSCustomObject]@{
            NewGroupName = $newGroupName
            OldEmail     = $oldMemberEmail
            DisplayName  = $memberName
        })
    }

    $groupSet[$newGroupName].MemberCount++

    [void]$results.Add([PSCustomObject]@{
        NewGroupName       = $newGroupName
        NewGroupEmail      = $newGroupEmail
        MemberName         = $memberName
        OldMemberEmail     = $oldMemberEmail
        SourceMailboxName  = $sourceMailboxName
        NewMemberEmail     = $newMemberEmail
        TargetMailboxName  = $targetMailboxName
        Status             = $status
    })
}

# --- GROUP SUMMARY ---
$groupSummary = [System.Collections.ArrayList]::new()
foreach ($g in $groupSet.GetEnumerator() | Sort-Object Key) {
    [void]$groupSummary.Add([PSCustomObject]@{
        NewGroupName   = $g.Key
        NewGroupEmail  = $g.Value.Email
        OriginalName   = $g.Value.OriginalName
        OriginalEmail  = $g.Value.OriginalEmail
        TotalMembers   = $g.Value.MemberCount
        Mapped         = $g.Value.Mapped
        External       = $g.Value.External
        Unmapped       = $g.Value.Unmapped
    })
}

# --- GROUP NAME MAPPING (Source -> Target) ---
$groupNameMap = [System.Collections.ArrayList]::new()
foreach ($g in $groupSet.GetEnumerator() | Sort-Object Key) {
    [void]$groupNameMap.Add([PSCustomObject]@{
        'Source Display Name' = $g.Value.OriginalName
        'Source Address'      = $g.Value.OriginalEmail
        'Target Display Name' = $g.Key
        'Target Address'      = $g.Value.Email
    })
}

# --- EXPORT ---
$results      | Export-Csv -Path $outputFile   -NoTypeInformation -Encoding UTF8
$groupSummary | Export-Csv -Path $summaryFile  -NoTypeInformation -Encoding UTF8
$groupNameMap | Export-Csv -Path $groupMapFile -NoTypeInformation -Encoding UTF8

$mappedCount   = ($results | Where-Object Status -eq 'Mapped'   | Measure-Object).Count
$externalCount = ($results | Where-Object Status -eq 'External' | Measure-Object).Count

Write-Host "==========================================" -ForegroundColor Cyan
Write-Host " Mapping Complete!" -ForegroundColor Green
Write-Host " Groups         : $($groupSet.Count)" -ForegroundColor White
Write-Host " Total members  : $($results.Count)" -ForegroundColor White
Write-Host " Mapped         : $mappedCount" -ForegroundColor Green
Write-Host " External       : $externalCount" -ForegroundColor DarkYellow
Write-Host " Unmapped       : $($unmapped.Count)" -ForegroundColor $(if ($unmapped.Count -gt 0) { 'Red' } else { 'Green' })
Write-Host ""
Write-Host " Files saved:" -ForegroundColor White
Write-Host "   $outputFile" -ForegroundColor Gray
Write-Host "   $summaryFile" -ForegroundColor Gray
Write-Host "   $groupMapFile" -ForegroundColor Gray

if ($unmapped.Count -gt 0) {
    $unmapped | Export-Csv -Path $unmappedFile -NoTypeInformation -Encoding UTF8
    Write-Host "   $unmappedFile" -ForegroundColor Yellow
    Write-Host ""
    Write-Host " WARNING: $($unmapped.Count) members could not be mapped." -ForegroundColor Yellow
    Write-Host " These are likely group-members-of-groups (e.g. nested DLs) not in MailboxMapping.csv." -ForegroundColor Yellow
    Write-Host " Review UnmappedMembers.csv before proceeding." -ForegroundColor Yellow
}

Write-Host "==========================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "Review NewGroupSummary.csv and GroupNameMapping.csv, then run Script 3." -ForegroundColor Yellow
