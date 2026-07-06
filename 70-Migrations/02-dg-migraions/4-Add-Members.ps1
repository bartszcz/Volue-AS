# =============================================================
# Script 4: Add Members to Distribution Groups
# =============================================================
# Usage:
#   .\4-Add-Members.ps1
#   .\4-Add-Members.ps1 -ConfigFile "C:\MyMigration\MigrationConfig.csv"
#
# Must be connected to DESTINATION tenant (TargetDomain in config).
#
# Reads:   NewGroupMembership.csv  (from Script 2 — reflects your edited names)
#          CreateGroups_Log.csv    (from Script 3 — used to verify groups exist)
# Creates: AddMembers_Log.csv
#
# v3 changes:
#   - Tenant domain validation: confirms connected org matches TargetDomain
#   - Cross-references CreateGroups_Log to verify group exists before adding members
#   - Group email taken directly from NewGroupMembership (matches what Script 2 wrote
#     after your edits to NewGroupSummary) — no re-derivation
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
$TargetAdmin  = $config["TargetAdminUPN"]
$TargetDomain = $config["TargetDomain"]

# --- VALIDATE CONFIG ---
$requiredKeys = @("OutputFolder", "TargetAdminUPN", "TargetDomain")
$missingKeys  = $requiredKeys | Where-Object { [string]::IsNullOrWhiteSpace($config[$_]) }
if ($missingKeys) {
    Write-Host "ERROR: Missing or empty values in MigrationConfig.csv:" -ForegroundColor Red
    $missingKeys | ForEach-Object { Write-Host "  - $_" -ForegroundColor Yellow }
    Write-Host "Check that MigrationConfig.csv has a Setting,Value header row and all required keys." -ForegroundColor Yellow
    exit 1
}

$csvFile     = Join-Path $OutputFolder "NewGroupMembership.csv"
$logFilePath = Join-Path $OutputFolder "CreateGroups_Log.csv"
$logFile     = Join-Path $OutputFolder "AddMembers_Log.csv"

if (-not (Test-Path $csvFile)) {
    Write-Host "ERROR: $csvFile not found. Run Script 2 first." -ForegroundColor Red
    exit 1
}
if (-not (Test-Path $logFilePath)) {
    Write-Host "ERROR: $logFilePath not found. Run Script 3 first." -ForegroundColor Red
    exit 1
}

# Load created groups log — build lookup of which groups were actually created
$createdGroups = @{}
Import-Csv -Path $logFilePath | Where-Object { $_.Status -in @("Created","AlreadyExists") } | ForEach-Object {
    $createdGroups[$_.GroupName.Trim()] = $_.Email.Trim()
}

Write-Host "==========================================" -ForegroundColor Cyan
Write-Host " Script 4: Add Members to Groups" -ForegroundColor Cyan
Write-Host " Expected org  : $TargetDomain" -ForegroundColor Gray
Write-Host " Target Admin  : $TargetAdmin" -ForegroundColor Gray
Write-Host " Groups created: $($createdGroups.Count)" -ForegroundColor Gray
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

# --- RESUME: load previous log if exists ---
$completedPairs = @{}
if (Test-Path $logFile) {
    $previousLog = Import-Csv -Path $logFile
    $resumeCount = 0
    $previousLog | Where-Object { $_.Status -in @("Added","AlreadyMember") } | ForEach-Object {
        $key = "$($_.Group)|$($_.Member.ToLower())"
        if (-not $completedPairs.ContainsKey($key)) {
            $completedPairs[$key] = $true
            $resumeCount++
        }
    }
    if ($resumeCount -gt 0) {
        Write-Host "RESUME MODE: Found existing log with $resumeCount completed assignments." -ForegroundColor Yellow
        Write-Host "  These will be skipped automatically." -ForegroundColor DarkYellow
        Write-Host ""
    }
}

# Load membership — filter out unmapped, only include groups that were created
$rows = Import-Csv -Path $csvFile | Where-Object {
    $_.NewMemberEmail -ne "NOT_FOUND" -and
    -not [string]::IsNullOrWhiteSpace($_.NewMemberEmail) -and
    $createdGroups.ContainsKey($_.NewGroupName.Trim())
}

$skippedGroups = Import-Csv -Path $csvFile | Where-Object {
    -not $createdGroups.ContainsKey($_.NewGroupName.Trim())
} | Select-Object -ExpandProperty NewGroupName -Unique

if ($skippedGroups.Count -gt 0) {
    Write-Host "NOTE: The following groups were skipped in Script 3 and will not receive members:" -ForegroundColor DarkYellow
    $skippedGroups | ForEach-Object { Write-Host "  - $_" -ForegroundColor DarkYellow }
    Write-Host ""
}

# Group by distribution group name
$grouped = $rows | Group-Object -Property NewGroupName

Write-Host " Groups with members to add: $($grouped.Count)" -ForegroundColor White
Write-Host " Total member assignments  : $($rows.Count)" -ForegroundColor White
Write-Host ""

$log = [System.Collections.ArrayList]::new()
$groupCounter = 0
$autoAll = $false

# --- Helper ---
function Add-SingleMember {
    param(
        [string]$GroupEmail,
        [string]$GroupName,
        [string]$MemberEmail,
        [string]$MemberName = "",
        [string]$MemberStatus = "Mapped",
        [System.Collections.ArrayList]$Log
    )

    # Normalise to lowercase — Exchange is case-sensitive for external lookups
    $MemberEmail = $MemberEmail.Trim().ToLower()

    # Resume: skip if already successfully processed in a previous run
    $pairKey = "$GroupName|$MemberEmail"
    if ($completedPairs.ContainsKey($pairKey)) {
        Write-Host "    Skipped (already done): $MemberEmail" -ForegroundColor DarkGray
        [void]$Log.Add([PSCustomObject]@{ Group=$GroupName; GroupEmail=$GroupEmail; Member=$MemberEmail; Status="AlreadyMember"; Error="" })
        return
    }

    # External members must exist as mail contacts before they can be added to a group
    if ($MemberStatus -eq "External") {
        $existingContact = $null
        try {
            $existingContact = Get-MailContact -Identity $MemberEmail -ErrorAction Stop
        }
        catch { }

        if (-not $existingContact) {
            # Derive base contact name; fall back to local part of email
            $baseContactName = if (-not [string]::IsNullOrWhiteSpace($MemberName)) {
                $MemberName
            } else {
                ($MemberEmail -split '@')[0]
            }

            # Try base name first; if taken (another contact with same display name
            # from a different domain), append the domain to guarantee uniqueness
            $domain          = ($MemberEmail -split '@')[1]
            $contactName     = $baseContactName
            $contactCreated  = $false

            foreach ($attempt in @($baseContactName, "$baseContactName ($domain)")) {
                $contactName = $attempt
                try {
                    New-MailContact -Name $contactName -DisplayName $contactName -ExternalEmailAddress $MemberEmail -ErrorAction Stop | Out-Null
                    Write-Host "    Contact created: $MemberEmail ($contactName)" -ForegroundColor Cyan
                    $contactCreated = $true
                    break
                }
                catch {
                    $errMsg = $_.Exception.Message
                    if ($errMsg -match "already exists" -and $attempt -eq $baseContactName) {
                        # Name collision — retry with domain suffix
                        Write-Host "    Name collision on '$contactName', retrying with domain suffix..." -ForegroundColor DarkYellow
                        continue
                    }
                    elseif ($errMsg -match "already exists") {
                        # Contact object for this email already exists under a different name
                        Write-Host "    Contact already exists: $MemberEmail" -ForegroundColor DarkYellow
                        $contactCreated = $true
                        break
                    }
                    else {
                        Write-Host "    ERROR creating contact: $MemberEmail - $errMsg" -ForegroundColor Red
                        [void]$Log.Add([PSCustomObject]@{ Group=$GroupName; GroupEmail=$GroupEmail; Member=$MemberEmail; Status="ContactFailed"; Error=$errMsg })
                        return
                    }
                }
            }
        }
        else {
            Write-Host "    Contact exists: $MemberEmail" -ForegroundColor DarkGray
        }
    }

    # Add to group
    try {
        Add-DistributionGroupMember -Identity $GroupEmail -Member $MemberEmail -ErrorAction Stop
        Write-Host "    Added: $MemberEmail" -ForegroundColor Green
        [void]$Log.Add([PSCustomObject]@{ Group=$GroupName; GroupEmail=$GroupEmail; Member=$MemberEmail; Status="Added"; Error="" })
    }
    catch {
        $errMsg = $_.Exception.Message
        if ($errMsg -match "already a member") {
            Write-Host "    Already member: $MemberEmail" -ForegroundColor DarkYellow
            [void]$Log.Add([PSCustomObject]@{ Group=$GroupName; GroupEmail=$GroupEmail; Member=$MemberEmail; Status="AlreadyMember"; Error="" })
        }
        elseif ($errMsg -match "couldn't be found") {
            Write-Host "    Not found: $MemberEmail" -ForegroundColor Red
            [void]$Log.Add([PSCustomObject]@{ Group=$GroupName; GroupEmail=$GroupEmail; Member=$MemberEmail; Status="NotFound"; Error=$errMsg })
        }
        else {
            Write-Host "    ERROR: $MemberEmail - $errMsg" -ForegroundColor Red
            [void]$Log.Add([PSCustomObject]@{ Group=$GroupName; GroupEmail=$GroupEmail; Member=$MemberEmail; Status="Failed"; Error=$errMsg })
        }
    }
}

foreach ($group in $grouped) {
    $groupCounter++
    $groupName  = $group.Name.Trim()
    # Use the actual email from CreateGroups_Log — authoritative source
    $groupEmail = $createdGroups[$groupName]
    $members    = $group.Group

    Write-Host "===========================================" -ForegroundColor DarkGray
    Write-Host "Group [$groupCounter/$($grouped.Count)]: " -NoNewline
    Write-Host "$groupName" -ForegroundColor Green
    Write-Host "Email: $groupEmail" -ForegroundColor Gray
    Write-Host ""
    Write-Host "Members to add ($($members.Count)):" -ForegroundColor White

    $i = 0
    foreach ($m in $members) {
        $i++
        $statusColor = switch ($m.Status) {
            "Mapped"   { "Cyan" }
            "External" { "DarkYellow" }
            default    { "White" }
        }
        Write-Host "  $i. " -NoNewline -ForegroundColor DarkGray
        Write-Host "$($m.MemberName)" -NoNewline -ForegroundColor White
        Write-Host " | $($m.OldMemberEmail)" -NoNewline -ForegroundColor Yellow
        Write-Host " -> " -NoNewline
        Write-Host "$($m.NewMemberEmail)" -ForegroundColor $statusColor
        Write-Host "     [$($m.Status)]" -ForegroundColor DarkGray
    }

    Write-Host ""

    if ($autoAll) {
        $choice = "Y"
        Write-Host "  Auto-adding all members..." -ForegroundColor Cyan
    } else {
        $choice = Read-Host "(Y)es add all / (O)ne by one / (N)o skip group / (A)ll remaining groups / (S)top"
    }

    switch ($choice.ToUpper()) {
        "Y" {
            foreach ($m in $members) {
                Add-SingleMember -GroupEmail $groupEmail -GroupName $groupName -MemberEmail $m.NewMemberEmail -MemberName $m.MemberName -MemberStatus $m.Status -Log $log
            }
        }
        "O" {
            foreach ($m in $members) {
                Write-Host ""
                Write-Host "  Member : $($m.MemberName)" -ForegroundColor White
                Write-Host "  Old    : $($m.OldMemberEmail)" -ForegroundColor Yellow
                Write-Host "  New    : $($m.NewMemberEmail)" -ForegroundColor Cyan
                Write-Host "  Status : $($m.Status)" -ForegroundColor DarkGray
                $mc = Read-Host "  Add? (Y/N)"
                if ($mc.ToUpper() -eq "Y") {
                    Add-SingleMember -GroupEmail $groupEmail -GroupName $groupName -MemberEmail $m.NewMemberEmail -MemberName $m.MemberName -MemberStatus $m.Status -Log $log
                } else {
                    Write-Host "    Skipped." -ForegroundColor DarkYellow
                    [void]$log.Add([PSCustomObject]@{ Group=$groupName; GroupEmail=$groupEmail; Member=$m.NewMemberEmail; Status="Skipped"; Error="" })
                }
            }
        }
        "A" {
            $autoAll = $true
            Write-Host "  Auto-adding this and all remaining groups..." -ForegroundColor Cyan
            foreach ($m in $members) {
                Add-SingleMember -GroupEmail $groupEmail -GroupName $groupName -MemberEmail $m.NewMemberEmail -MemberName $m.MemberName -MemberStatus $m.Status -Log $log
            }
        }
        "S" {
            Write-Host "Stopping." -ForegroundColor DarkYellow
            foreach ($rg in $grouped[($groupCounter - 1)..($grouped.Count - 1)]) {
                $rgEmail = $createdGroups[$rg.Name.Trim()]
                foreach ($m in $rg.Group) {
                    [void]$log.Add([PSCustomObject]@{ Group=$rg.Name; GroupEmail=$rgEmail; Member=$m.NewMemberEmail; Status="Skipped"; Error="" })
                }
            }
            break
        }
        default {
            Write-Host "  Skipped group." -ForegroundColor DarkYellow
            foreach ($m in $members) {
                [void]$log.Add([PSCustomObject]@{ Group=$groupName; GroupEmail=$groupEmail; Member=$m.NewMemberEmail; Status="Skipped"; Error="" })
            }
        }
    }
    Write-Host ""
}

$log | Export-Csv -Path $logFile -NoTypeInformation -Encoding UTF8

$added         = ($log | Where-Object Status -eq "Added").Count
$existed       = ($log | Where-Object Status -eq "AlreadyMember").Count
$notfound      = ($log | Where-Object Status -eq "NotFound").Count
$failed        = ($log | Where-Object Status -eq "Failed").Count
$contactFailed = ($log | Where-Object Status -eq "ContactFailed").Count
$skipped       = ($log | Where-Object Status -eq "Skipped").Count

Write-Host "==========================================" -ForegroundColor Cyan
Write-Host " Member Assignment Complete!" -ForegroundColor Green
Write-Host " Added           : $added" -ForegroundColor Green
Write-Host " Already member  : $existed" -ForegroundColor DarkYellow
Write-Host " Not found       : $notfound" -ForegroundColor $(if ($notfound -gt 0) { 'Red' } else { 'Green' })
Write-Host " Contact failed  : $contactFailed" -ForegroundColor $(if ($contactFailed -gt 0) { 'Red' } else { 'Green' })
Write-Host " Failed          : $failed" -ForegroundColor $(if ($failed -gt 0) { 'Red' } else { 'Green' })
Write-Host " Skipped         : $skipped" -ForegroundColor DarkYellow
Write-Host " Log             : $logFile" -ForegroundColor Gray
Write-Host "==========================================" -ForegroundColor Cyan
Write-Host ""
if ($notfound -gt 0 -or $failed -gt 0 -or $contactFailed -gt 0) {
    Write-Host "Review $logFile for errors." -ForegroundColor Yellow
    Write-Host "Script 4 is safe to re-run — AlreadyMember and existing contacts are handled automatically." -ForegroundColor Gray
} else {
    Write-Host "Migration complete!" -ForegroundColor Green
}
