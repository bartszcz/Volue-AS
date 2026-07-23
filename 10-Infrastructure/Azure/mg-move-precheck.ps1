# mg-move-precheck.ps1 - checks everything needed BEFORE moving one or more subscriptions to another management group
# bartek / volue ito / 2026-07
#
# read-only, changes nothing. verifies the three documented move requirements per subscription:
#   1. owner-level rights on the subscription (mg write + role assignment write)
#   2. mg write on the TARGET management group (Owner / Contributor / Management Group Contributor)
#   3. mg write on the CURRENT parent management group (not needed when parent is the tenant root)
# and previews which policy / role assignments would start or stop applying after each move.
# run without parameters for pick lists (multiple subscriptions can be selected), or:
#   .\mg-move-precheck.ps1 -SubscriptionIds <guid>,<guid> -TargetManagementGroupId Energy

param(
    [string[]]$SubscriptionIds,
    [string]$TargetManagementGroupId,   # group ID, not display name
    [string]$OutputPath = "C:\Temp\mg-move-precheck"
)

# --- settings ---
$TenantId        = "9ce76d42-5ecb-4d8f-939b-a462ad28cf34"
$RequiredModules = @("Az.Accounts", "Az.Resources")
$EntitiesApi     = "2020-05-01"
$PolicyApi       = "2022-06-01"
$MgWriteRoles    = @("Owner", "Contributor", "Management Group Contributor")

# --- functions ---

function Read-Choice ($Prompt, $Options, $DefaultIndex) {
    Write-Host $Prompt
    for ($i = 0; $i -lt $Options.Count; $i++) { Write-Host ("  {0}. {1}" -f ($i + 1), $Options[$i]) }
    while ($true) {
        $Answer = Read-Host "Choice 1-$($Options.Count) [$($DefaultIndex + 1)]"
        if ([string]::IsNullOrWhiteSpace($Answer)) { return $Options[$DefaultIndex] }
        $Num = 0
        if ([int]::TryParse($Answer, [ref]$Num) -and $Num -ge 1 -and $Num -le $Options.Count) { return $Options[$Num - 1] }
        Write-Host "Pick a number between 1 and $($Options.Count)" -ForegroundColor Yellow
    }
}

# numbered list where several entries can be picked: "1,3,5" or "all". returns the chosen option texts
function Read-MultiChoice ($Prompt, $Options) {
    Write-Host $Prompt
    for ($i = 0; $i -lt $Options.Count; $i++) { Write-Host ("  {0}. {1}" -f ($i + 1), $Options[$i]) }
    while ($true) {
        $Answer = Read-Host "Numbers comma separated, or 'all'"
        if ([string]::IsNullOrWhiteSpace($Answer)) { Write-Host "Pick at least one" -ForegroundColor Yellow; continue }
        if ($Answer.Trim() -eq "all") { return $Options }
        $Picked = @()
        $Valid  = $true
        foreach ($Part in ($Answer -split ",")) {
            $Num = 0
            if ([int]::TryParse($Part.Trim(), [ref]$Num) -and $Num -ge 1 -and $Num -le $Options.Count) {
                $Picked += $Options[$Num - 1]
            } else {
                Write-Host "'$($Part.Trim())' is not a number between 1 and $($Options.Count)" -ForegroundColor Yellow
                $Valid = $false
                break
            }
        }
        if ($Valid -and $Picked.Count -gt 0) { return @($Picked | Sort-Object -Unique) }
    }
}

# roles the signed-in user has at a scope, group memberships included when the directory allows it. cached per scope
$script:RoleCache = @{}
function Get-MyRolesAtScope ($Scope) {
    if ($script:RoleCache.ContainsKey($Scope)) { return $script:RoleCache[$Scope] }
    $Account = (Get-AzContext).Account
    if ($Account.Type -ne "User") { return $null }  # spn/msi - caller decides how to handle
    try {
        $Assignments = @(Get-AzRoleAssignment -SignInName $Account.Id -ExpandPrincipalGroups -Scope $Scope -ErrorAction Stop)
    } catch {
        # expand needs directory read - fall back to direct assignments only
        try {
            $Assignments = @(Get-AzRoleAssignment -SignInName $Account.Id -Scope $Scope -ErrorAction Stop)
            Write-Warning "Group expansion failed at $Scope - only direct assignments checked ($($_.Exception.Message))"
        } catch {
            Write-Warning "Role lookup failed at ${Scope}: $($_.Exception.Message)"
            return @()
        }
    }
    $Roles = @($Assignments | ForEach-Object { $_.RoleDefinitionName } | Sort-Object -Unique)
    $script:RoleCache[$Scope] = $Roles
    return $Roles
}

# mg-write verdict for a management group scope, root exception handled by the caller
function Test-MgWrite ($MgName) {
    $Roles = Get-MyRolesAtScope "/providers/Microsoft.Management/managementGroups/$MgName"
    if ($null -eq $Roles) { return [pscustomobject]@{ Status = "UNKNOWN"; Detail = "service principal login - check manually" } }
    $HaveWrite = @($Roles | Where-Object { $MgWriteRoles -contains $_ })
    if ($HaveWrite.Count -gt 0) { return [pscustomobject]@{ Status = "OK"; Detail = "$($HaveWrite -join ', ') on $MgName" } }
    return [pscustomobject]@{ Status = "FAIL"; Detail = "need one of [$($MgWriteRoles -join ', ')] on $MgName, you have: $($Roles -join ', ')" }
}

# policy + role assignments created directly at one mg, cached so shared chain parts are only queried once
$script:MgGovCache = @{}
function Get-MgGovernance ($MgName) {
    if ($script:MgGovCache.ContainsKey($MgName)) { return $script:MgGovCache[$MgName] }
    $MgScope = "/providers/Microsoft.Management/managementGroups/$MgName"
    $Items = @()
    try {
        $Path = "$MgScope/providers/Microsoft.Authorization/policyAssignments?api-version=$PolicyApi&`$filter=atExactScope()"
        $Response = Invoke-AzRestMethod -Method GET -Path $Path -ErrorAction Stop
        if ($Response.StatusCode -ne 200) { throw "HTTP $($Response.StatusCode)" }
        foreach ($Pol in @(($Response.Content | ConvertFrom-Json).value)) {
            $DefName = ($Pol.properties.policyDefinitionId -split "/")[-1]
            $Kind = "policy"
            if ($Pol.properties.policyDefinitionId -like "*policySetDefinitions*") { $Kind = "initiative" }
            $Display = $Pol.properties.displayName
            if (-not $Display) { $Display = $Pol.name }
            $Items += [pscustomobject]@{ Type = $Kind; Name = $Display; Detail = "$DefName (enforcement: $($Pol.properties.enforcementMode))" }
        }
    } catch {
        Write-Warning "Could not list policy assignments on ${MgName}: $($_.Exception.Message)"
    }
    try {
        foreach ($Ra in @(Get-AzRoleAssignment -Scope $MgScope -ErrorAction Stop | Where-Object { $_.Scope -eq $MgScope })) {
            $Who = $Ra.DisplayName
            if (-not $Who) { $Who = $Ra.ObjectId }
            $Items += [pscustomobject]@{ Type = "role assignment"; Name = "$($Ra.RoleDefinitionName) -> $Who"; Detail = $Ra.ObjectType }
        }
    } catch {
        Write-Warning "Could not list role assignments on ${MgName}: $($_.Exception.Message)"
    }
    $script:MgGovCache[$MgName] = $Items
    return $Items
}

# --- main ---

foreach ($Module in $RequiredModules) {
    if (-not (Get-Module -ListAvailable -Name $Module)) {
        Write-Error "Module $Module is not installed. Install it first (Install-Module $Module)."
        return
    }
}

$Context = Get-AzContext
if (-not $Context -or $Context.Tenant.Id -ne $TenantId) {
    Write-Host "Connecting to Azure..."
    try {
        Connect-AzAccount -TenantId $TenantId -SkipContextPopulation -ErrorAction Stop | Out-Null
    } catch {
        Write-Error "Login failed: $($_.Exception.Message)"
        return
    }
}

# one call gives every mg and subscription the caller can see, with parents and ancestor chains
Write-Host "Reading management group hierarchy..."
try {
    $Response = Invoke-AzRestMethod -Method POST -Path "/providers/Microsoft.Management/getEntities?api-version=$EntitiesApi" -ErrorAction Stop
} catch {
    Write-Error "getEntities call failed: $($_.Exception.Message)"
    return
}
if ($Response.StatusCode -ne 200) {
    Write-Error "getEntities returned HTTP $($Response.StatusCode) - you may have no management group read access at all. $($Response.Content)"
    return
}
$Parsed = $Response.Content | ConvertFrom-Json
$Entities = @($Parsed.value)
if ($Parsed.nextLink) { Write-Warning "Hierarchy listing was paged and only the first page is used - results may be incomplete in very large tenants." }

$MgEntities  = @($Entities | Where-Object { $_.type -like "*managementGroups*" })
$SubEntities = @($Entities | Where-Object { $_.type -eq "/subscriptions" })
if ($MgEntities.Count -eq 0) { Write-Error "No management groups visible to this account."; return }

if (-not $SubscriptionIds -or $SubscriptionIds.Count -eq 0) {
    if ($SubEntities.Count -eq 0) { Write-Error "No subscriptions visible via management groups."; return }
    $Picks = Read-MultiChoice "Subscriptions to move:" @($SubEntities | ForEach-Object { "$($_.properties.displayName) ($($_.name))" } | Sort-Object)
    $SubscriptionIds = @($Picks | ForEach-Object { $_ -replace "^.*\(", "" -replace "\)$", "" })
}
if (-not $TargetManagementGroupId) {
    $TargetManagementGroupId = Read-Choice "Target management group:" @($MgEntities | ForEach-Object { $_.name } | Sort-Object) 0
}

$TargetEntity = $MgEntities | Where-Object { $_.name -eq $TargetManagementGroupId } | Select-Object -First 1
if (-not $TargetEntity) {
    Write-Error "Management group '$TargetManagementGroupId' not found. Use the group ID, not the display name. Visible groups: $(@($MgEntities | ForEach-Object { $_.name }) -join ', ')"
    return
}

# root group has no parent - usually its name is the tenant id
$RootEntity = $MgEntities | Where-Object { -not $_.properties.parent.id } | Select-Object -First 1
$RootName = $TenantId
if ($RootEntity) { $RootName = $RootEntity.name }

# rbac cmdlets want a default subscription in the context - any of the checked ones will do
try {
    Set-AzContext -Subscription $SubscriptionIds[0] -Tenant $TenantId -ErrorAction Stop | Out-Null
} catch {
    Write-Error "Cannot set context to subscription $($SubscriptionIds[0]): $($_.Exception.Message)"
    return
}

# target group rights - same answer for every subscription, checked once
$TargetCheck = $null
if ($TargetManagementGroupId -eq $RootName) {
    $TargetCheck = [pscustomobject]@{ Status = "OK"; Detail = "target is the root group - no permission needed there" }
} else {
    $TargetCheck = Test-MgWrite $TargetManagementGroupId
}

# new ancestor chain - also the same for every subscription
$NewChain = @($TargetEntity.properties.parentNameChain)
if ($NewChain.Count -gt 1 -and $NewChain[-1] -eq $RootName) { [array]::Reverse($NewChain) }
$NewChain += $TargetManagementGroupId

$Checks  = @()
$Changes = @()

foreach ($SubId in $SubscriptionIds) {
    $SubEntity = $SubEntities | Where-Object { $_.name -eq $SubId } | Select-Object -First 1
    if (-not $SubEntity) {
        Write-Warning "Subscription $SubId not found in the visible hierarchy, skipping."
        $Checks += [pscustomobject]@{ Subscription = $SubId; Check = "Visibility"; Status = "FAIL"; Detail = "not found in hierarchy" }
        continue
    }
    $SubName = $SubEntity.properties.displayName
    $CurrentParentName = ($SubEntity.properties.parent.id -split "/")[-1]

    Write-Host ""
    Write-Host "--- $SubName ($SubId), current parent: $CurrentParentName ---"

    if ($CurrentParentName -eq $TargetManagementGroupId) {
        Write-Host "Already under '$TargetManagementGroupId' - nothing to move." -ForegroundColor Yellow
        $Checks += [pscustomobject]@{ Subscription = $SubName; Check = "Placement"; Status = "SKIP"; Detail = "already under $TargetManagementGroupId" }
        continue
    }

    # check 1: owner-level rights on the subscription itself
    $SubRoles = Get-MyRolesAtScope "/subscriptions/$SubId"
    if ($null -eq $SubRoles) {
        $Checks += [pscustomobject]@{ Subscription = $SubName; Check = "Subscription rights"; Status = "UNKNOWN"; Detail = "service principal login - check manually" }
    } elseif ($SubRoles -contains "Owner") {
        $Checks += [pscustomobject]@{ Subscription = $SubName; Check = "Subscription rights"; Status = "OK"; Detail = "Owner" }
    } else {
        # custom roles with Microsoft.Management/managementGroups/subscriptions/write are not recognized here
        $Checks += [pscustomobject]@{ Subscription = $SubName; Check = "Subscription rights"; Status = "FAIL"; Detail = "need Owner, you have: $($SubRoles -join ', ')" }
    }

    # check 2: target group rights (shared result)
    $Checks += [pscustomobject]@{ Subscription = $SubName; Check = "Target group rights"; Status = $TargetCheck.Status; Detail = $TargetCheck.Detail }

    # check 3: current parent rights (root exception, cached per group)
    if ($CurrentParentName -eq $RootName) {
        $Checks += [pscustomobject]@{ Subscription = $SubName; Check = "Current parent rights"; Status = "OK"; Detail = "current parent is the root group - no permission needed there" }
    } else {
        $ParentCheck = Test-MgWrite $CurrentParentName
        $Checks += [pscustomobject]@{ Subscription = $SubName; Check = "Current parent rights"; Status = $ParentCheck.Status; Detail = $ParentCheck.Detail }
    }

    # what would change: diff old chain against new chain
    $OldChain = @($SubEntity.properties.parentNameChain)
    if ($OldChain.Count -eq 0) { $OldChain = @($CurrentParentName) }
    if ($OldChain.Count -gt 1 -and $OldChain[0] -eq $CurrentParentName) { [array]::Reverse($OldChain) }
    if ($OldChain[-1] -ne $CurrentParentName) { $OldChain += $CurrentParentName }

    $i = 0
    while ($i -lt $OldChain.Count -and $i -lt $NewChain.Count -and $OldChain[$i] -eq $NewChain[$i]) { $i++ }
    $LeavingMgs  = @(); if ($i -lt $OldChain.Count) { $LeavingMgs = @($OldChain[$i..($OldChain.Count - 1)]) }
    $EnteringMgs = @(); if ($i -lt $NewChain.Count) { $EnteringMgs = @($NewChain[$i..($NewChain.Count - 1)]) }

    Write-Host "Old chain: $($OldChain -join ' > ') > [subscription]"
    Write-Host "New chain: $($NewChain -join ' > ') > [subscription]"

    foreach ($Set in @(@{ Mgs = $LeavingMgs; Action = "stops applying" }, @{ Mgs = $EnteringMgs; Action = "starts applying" })) {
        foreach ($Mg in $Set.Mgs) {
            foreach ($Item in (Get-MgGovernance $Mg)) {
                $Changes += [pscustomobject]@{
                    Subscription = $SubName; Change = $Set.Action; Source = $Mg
                    Type = $Item.Type; Name = $Item.Name; Detail = $Item.Detail
                }
            }
        }
    }
}

# --- report ---

Write-Host ""
Write-Host "Pre-move checks:"
$Checks | Format-Table -Property Subscription, Check, Status, Detail -AutoSize -Wrap | Out-String -Width 220 | Write-Host

if ($Changes.Count -gt 0) {
    Write-Host "Governance changes after the move ($($Changes.Count)):"
    $Changes | Format-Table -Property Subscription, Change, Source, Type, Name, Detail -AutoSize -Wrap | Out-String -Width 240 | Write-Host
} else {
    Write-Host "No inherited policy or role assignment changes detected."
}

try {
    if (-not (Test-Path $OutputPath)) { New-Item -ItemType Directory -Path $OutputPath -Force | Out-Null }
    $Stamp    = Get-Date -Format "yyyyMMdd_HHmm"
    $JsonFile = Join-Path $OutputPath "mg-move-precheck_$Stamp.json"
    $CsvFile  = Join-Path $OutputPath "mg-move-precheck_$Stamp.csv"
    $Report = [pscustomobject]@{
        SubscriptionIds = $SubscriptionIds
        TargetGroup     = $TargetManagementGroupId
        NewChain        = $NewChain
        Checks          = $Checks
        Changes         = $Changes
    }
    ConvertTo-Json -InputObject $Report -Depth 6 | Out-File -FilePath $JsonFile -Encoding utf8
    $Changes | Export-Csv -Path $CsvFile -NoTypeInformation -Encoding utf8
    Write-Host "Report written to $JsonFile and $CsvFile"
} catch {
    Write-Warning "Could not write report files to ${OutputPath}: $($_.Exception.Message)"
}

# per-subscription verdict: ready subs get the move command, blocked subs get the reasons
Write-Host ""
$ReadyCommands = @()
foreach ($SubId in $SubscriptionIds) {
    $SubEntity = $SubEntities | Where-Object { $_.name -eq $SubId } | Select-Object -First 1
    $SubName = $SubId
    if ($SubEntity) { $SubName = $SubEntity.properties.displayName }
    $SubChecks = @($Checks | Where-Object { $_.Subscription -eq $SubName })
    $Failed    = @($SubChecks | Where-Object { $_.Status -eq "FAIL" })
    $Unknown   = @($SubChecks | Where-Object { $_.Status -eq "UNKNOWN" })
    $Skipped   = @($SubChecks | Where-Object { $_.Status -eq "SKIP" })
    if ($Skipped.Count -gt 0) {
        Write-Host "${SubName}: already in place" -ForegroundColor Yellow
    } elseif ($Failed.Count -gt 0) {
        Write-Host "${SubName}: NOT ready" -ForegroundColor Red
        foreach ($F in $Failed) { Write-Host "  $($F.Check): $($F.Detail)" -ForegroundColor Red }
    } elseif ($Unknown.Count -gt 0) {
        Write-Host "${SubName}: checks incomplete (service principal login) - verify manually" -ForegroundColor Yellow
    } else {
        Write-Host "${SubName}: ready to move" -ForegroundColor Green
        $ReadyCommands += "New-AzManagementGroupSubscription -GroupName '$TargetManagementGroupId' -SubscriptionId '$SubId'"
    }
}
if (@($Checks | Where-Object { $_.Status -eq "FAIL" }).Count -gt 0) {
    Write-Host "Note: custom roles are not evaluated by this check - if you use one with the required permissions, the move may still work."
}
if ($ReadyCommands.Count -gt 0) {
    Write-Host ""
    Write-Host "This script does NOT move anything - when ready, run:" -ForegroundColor Green
    foreach ($Cmd in $ReadyCommands) { Write-Host "  $Cmd" }
}
