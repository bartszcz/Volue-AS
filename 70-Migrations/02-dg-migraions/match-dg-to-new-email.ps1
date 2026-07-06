# =============================================================
# Match Distribution Group Membership with New Volue Addresses
# =============================================================
# Input files:
#   - MailboxMapping.csv  (comma-delimited: SourceEmail,SourceId,DisplayName,SourceMailboxType,TargetMailboxType,TargetEmail,TargetId)
#   - GroupMembers.csv    (comma-delimited: Group,GroupEmail,DisplayName,PrimarySmtpAddress)
#
# Output:
#   - NewGroupMembership.csv
#   - UnmappedMembers.csv (if any)
# =============================================================

# --- CONFIGURE PATHS ---
$mappingFile  = "C:\Scripts\MailboxMapping.csv"
$membersFile  = "C:\Scripts\GroupMembers.csv"
$outputFile   = "C:\Scripts\NewGroupMembership.csv"
$domain       = "volue.com"

# --- LOAD MAILBOX MAPPING ---
$mapping = @{}
Import-Csv -Path $mappingFile | ForEach-Object {
    $source = $_.SourceEmail
    $target = $_.TargetEmail

    # Skip rows with empty or invalid data
    if (-not $source -or -not $target) { return }
    $source = $source.Trim().ToLower()
    $target = $target.Trim()

    # Skip #N/A targets (consultants with no new mailbox)
    if ($target -eq '#N/A' -or [string]::IsNullOrWhiteSpace($target)) { return }

    # Only keep the first mapping (skip duplicates like Archive rows)
    if (-not $mapping.ContainsKey($source)) {
        $mapping[$source] = $target
    }
}

Write-Host "Loaded $($mapping.Count) mailbox mappings." -ForegroundColor Cyan

# --- LOAD GROUP MEMBERS (comma-delimited!) ---
$members = Import-Csv -Path $membersFile

Write-Host "Loaded $($members.Count) group membership rows." -ForegroundColor Cyan

# --- PROCESS ---
$results = [System.Collections.ArrayList]::new()
$unmapped = [System.Collections.ArrayList]::new()

foreach ($row in $members) {
    # Skip rows with missing critical data
    if ([string]::IsNullOrWhiteSpace($row.Group) -or [string]::IsNullOrWhiteSpace($row.PrimarySmtpAddress)) {
        continue
    }

    $originalGroup   = $row.Group.Trim()
    $oldMemberEmail  = $row.PrimarySmtpAddress.Trim().ToLower()
    $memberName      = if ($row.DisplayName) { $row.DisplayName.Trim() } else { "Unknown" }

    # --- Build new group name ---
    # 1. Remove trailing date stamps (14+ digits at end)
    $newGroupName = $originalGroup -replace '\d{14,}$', ''

    # 2. Remove "| SmartPulse" / "| Smartpulse" suffix (case insensitive)
    $newGroupName = $newGroupName -replace '\s*\|\s*(?i)SmartPulse', ''

    # 3. Remove standalone SmartPulse/SMARTPULSE anywhere
    $newGroupName = $newGroupName -replace '(?i)\bsmartpulse\b', ''

    # 4. Clean up whitespace and trailing separators
    $newGroupName = $newGroupName.Trim()
    $newGroupName = $newGroupName -replace '\s*[-|]\s*$', ''
    $newGroupName = $newGroupName -replace '\s+', ' '
    $newGroupName = $newGroupName.Trim()

    # 5. Prefix with "Smartpulse"
    $newGroupName = "Smartpulse $newGroupName"

    # Generate new group email alias
    $alias = $newGroupName -replace '[^a-zA-Z0-9\s-]', ''
    $alias = $alias.Trim() -replace '\s+', '-'
    $alias = $alias.ToLower()
    $newGroupEmail = "$alias@$domain"

    # --- Map member email ---
    $newMemberEmail = ""

    if ($mapping.ContainsKey($oldMemberEmail)) {
        $newMemberEmail = $mapping[$oldMemberEmail]
    }
    elseif ($oldMemberEmail -notmatch '@smartpulse\.io$') {
        # External address (edp.com, enery.energy, aplusenerji.com.tr, etc.) -- keep as-is
        $newMemberEmail = $row.PrimarySmtpAddress.Trim()
    }
    else {
        # smartpulse.io address not found in mapping (consultant or DL)
        $newMemberEmail = "NOT_FOUND"
        [void]$unmapped.Add([PSCustomObject]@{
            Group       = $newGroupName
            OldEmail    = $oldMemberEmail
            DisplayName = $memberName
        })
    }

    [void]$results.Add([PSCustomObject]@{
        NewGroupName    = $newGroupName
        NewGroupEmail   = $newGroupEmail
        MemberName      = $memberName
        OldMemberEmail  = $oldMemberEmail
        NewMemberEmail  = $newMemberEmail
    })
}

# --- EXPORT ---
$results | Export-Csv -Path $outputFile -NoTypeInformation -Encoding UTF8
Write-Host ""
Write-Host "Exported $($results.Count) rows to: $outputFile" -ForegroundColor Green

# --- REPORT UNMAPPED ---
if ($unmapped.Count -gt 0) {
    $unmappedFile = "C:\Scripts\UnmappedMembers.csv"
    $unmapped | Export-Csv -Path $unmappedFile -NoTypeInformation -Encoding UTF8
    Write-Host ""
    Write-Host "WARNING: $($unmapped.Count) members could not be mapped!" -ForegroundColor Yellow
    Write-Host "Unmapped members saved to: $unmappedFile" -ForegroundColor Yellow
    Write-Host ""
    $unmapped | Format-Table -AutoSize
}
else {
    Write-Host "All members were successfully mapped." -ForegroundColor Green
}