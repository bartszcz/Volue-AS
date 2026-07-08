param(
    [string]$AppDisplayName = "Atlassian Cloud Hakom",
    [string]$GroupPrefix = "Hakom",
    [string]$OutputFolder = "$PSScriptRoot\output\clone-groups"
)

$requiredModules = @("Microsoft.Graph.Authentication", "Microsoft.Graph.Groups", "Microsoft.Graph.Applications")
$graphScopes = @("Group.ReadWrite.All", "Application.ReadWrite.All", "AppRoleAssignment.ReadWrite.All")
$timestamp = Get-Date -Format "yyyyMMdd_HHmm"

foreach ($mod in $requiredModules) {
    if (-not (Get-Module -ListAvailable -Name $mod)) {
        Write-Host "Module $mod is not installed. Run: Install-Module $mod" -ForegroundColor Red
        exit 1
    }
}

Write-Host "Connecting to Graph..."
try {
    Connect-MgGraph -Scopes $graphScopes -NoWelcome -ErrorAction Stop
}
catch {
    Write-Host "Could not connect to Graph: $($_.Exception.Message)" -ForegroundColor Red
    exit 1
}

# find the enterprise app (service principal)
try {
    $escapedName = $AppDisplayName -replace "'", "''"
    $sp = Get-MgServicePrincipal -Filter "displayName eq '$escapedName'" -ErrorAction Stop
}
catch {
    Write-Host "Lookup of service principal '$AppDisplayName' failed: $($_.Exception.Message)" -ForegroundColor Red
    exit 1
}
if (-not $sp) {
    Write-Host "Enterprise app '$AppDisplayName' not found" -ForegroundColor Red
    exit 1
}
if ($sp.Count -gt 1) {
    Write-Host "Multiple service principals named '$AppDisplayName' found, refusing to guess" -ForegroundColor Red
    exit 1
}
Write-Host "Found app: $($sp.DisplayName) ($($sp.Id))"

# group assignments on the app
try {
    $assignments = Get-MgServicePrincipalAppRoleAssignedTo -ServicePrincipalId $sp.Id -All -ErrorAction Stop |
        Where-Object { $_.PrincipalType -eq "Group" -and $_.PrincipalDisplayName -like "$GroupPrefix*" }
}
catch {
    Write-Host "Could not read app role assignments: $($_.Exception.Message)" -ForegroundColor Red
    exit 1
}
if (-not $assignments) {
    Write-Host "No groups starting with '$GroupPrefix' assigned to this app. Nothing to do."
    exit 0
}
Write-Host "Found $(@($assignments).Count) groups starting with '$GroupPrefix'"

$results = @()
foreach ($assignment in $assignments) {
    $oldName = $assignment.PrincipalDisplayName
    # strip leading prefix plus separators: "Hakom - X" / "Hakom-X" / "Hakom X" -> "X"
    $newName = ($oldName -replace "^$GroupPrefix[\s\-–]+", "").Trim()

    $result = [pscustomobject]@{
        OriginalGroup   = $oldName
        OriginalGroupId = $assignment.PrincipalId
        NewGroup        = $newName
        NewGroupId      = ""
        MemberCount     = 0
        MembersAdded    = 0
        AppRoleAssigned = $false
        Status          = ""
    }

    if ([string]::IsNullOrWhiteSpace($newName) -or $newName -eq $oldName) {
        Write-Host "Skipping '$oldName' - could not build a sensible new name" -ForegroundColor Yellow
        $result.Status = "skipped - bad name"
        $results += $result
        continue
    }

    Write-Host "`nProcessing: $oldName -> $newName"

    # do not touch anything if target name already exists
    try {
        $escapedNew = $newName -replace "'", "''"
        $existing = Get-MgGroup -Filter "displayName eq '$escapedNew'" -ErrorAction Stop
    }
    catch {
        Write-Host "  Lookup of '$newName' failed: $($_.Exception.Message)" -ForegroundColor Red
        $result.Status = "error - lookup failed"
        $results += $result
        continue
    }
    if ($existing) {
        Write-Host "  Group '$newName' already exists ($($existing.Id | Select-Object -First 1)). Skipping - not reusing." -ForegroundColor Yellow
        $result.Status = "skipped - name already exists"
        $results += $result
        continue
    }

    try {
        $mailNickname = ($newName -replace "[^a-zA-Z0-9]", "")
        if (-not $mailNickname) { $mailNickname = "group$(Get-Random)" }
        $newGroup = New-MgGroup -DisplayName $newName -MailEnabled:$false -MailNickname $mailNickname -SecurityEnabled -Description "Cloned from '$oldName' on $(Get-Date -Format yyyy-MM-dd)" -ErrorAction Stop
        $result.NewGroupId = $newGroup.Id
        Write-Host "  Created group $($newGroup.Id)"
    }
    catch {
        Write-Host "  Could not create group '$newName': $($_.Exception.Message)" -ForegroundColor Red
        $result.Status = "error - create failed"
        $results += $result
        continue
    }

    # copy members
    try {
        $members = Get-MgGroupMember -GroupId $assignment.PrincipalId -All -ErrorAction Stop
    }
    catch {
        Write-Host "  Could not read members of '$oldName': $($_.Exception.Message)" -ForegroundColor Red
        $result.Status = "error - member read failed"
        $results += $result
        continue
    }
    $result.MemberCount = @($members).Count
    foreach ($member in $members) {
        try {
            New-MgGroupMember -GroupId $newGroup.Id -DirectoryObjectId $member.Id -ErrorAction Stop
            $result.MembersAdded++
        }
        catch {
            Write-Host "  Could not add member $($member.Id): $($_.Exception.Message)" -ForegroundColor Red
        }
    }
    Write-Host "  Members: $($result.MembersAdded)/$($result.MemberCount) added"

    # assign to the app with the same role as the original
    try {
        New-MgServicePrincipalAppRoleAssignedTo -ServicePrincipalId $sp.Id -PrincipalId $newGroup.Id -ResourceId $sp.Id -AppRoleId $assignment.AppRoleId -ErrorAction Stop | Out-Null
        $result.AppRoleAssigned = $true
        Write-Host "  Assigned to app '$AppDisplayName'"
    }
    catch {
        Write-Host "  Could not assign '$newName' to app: $($_.Exception.Message)" -ForegroundColor Red
        $result.Status = "error - app assignment failed"
        $results += $result
        continue
    }

    if ($result.MembersAdded -lt $result.MemberCount) {
        $result.Status = "done with member errors"
    }
    else {
        $result.Status = "done"
    }
    $results += $result
}

if (-not (Test-Path $OutputFolder)) {
    New-Item -ItemType Directory -Path $OutputFolder -Force | Out-Null
}
$jsonPath = Join-Path $OutputFolder "Clone-HakomGroups_$timestamp.json"
$csvPath = Join-Path $OutputFolder "Clone-HakomGroups_$timestamp.csv"
try {
    $results | ConvertTo-Json -Depth 5 | Out-File $jsonPath -Encoding utf8
    $results | Export-Csv $csvPath -NoTypeInformation -Encoding utf8
}
catch {
    Write-Host "Could not write report: $($_.Exception.Message)" -ForegroundColor Red
}

Write-Host "`nSummary:"
$results | Format-Table OriginalGroup, NewGroup, MemberCount, MembersAdded, AppRoleAssigned, Status -AutoSize
Write-Host "Done. Report: $csvPath"
