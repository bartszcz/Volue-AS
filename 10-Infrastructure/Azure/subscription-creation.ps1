# creates subscriptions via billing alias, tags them, creates owner/contributor/reader groups and assigns rbac
# safe to re-run: existing aliases, groups, memberships and role assignments are skipped
# -DryRun shows what would happen without changing anything; normal run asks y/n before each change

param(
    [switch]$DryRun,
    [string]$OutputPath = "C:\Temp\subscription-creation"
)

# --- settings ---
$TenantId           = "9ce76d42-5ecb-4d8f-939b-a462ad28cf34"
$BillingAccountName = "d7daa3ab-00b0-5157-f1c1-fee9bc0668ba:6274e3d1-6729-4a2a-90a8-a5074278ea1b_2019-05-31"
$BillingProfileName = "QDNA-A7KS-BG7-PGB"
$InvoiceSectionName = "OTP2-PY5C-PJA-PGB"
$ManagementGroupId  = ""  # empty = tenant default group (usually tenant root), needs no permission. explicit placement needs write access on the group; group ID, not display name
$TechnicalOwnerUPN  = "recep.guleryuz@volue.com"
$Workload           = "Production"  # Production or DevTest

# one entry per subscription to create - add or remove lines as needed
$Subscriptions = @(
    @{ Alias = "Trading-Smarpulse-Prod";    Name = "Trading - Smarpulse - Prod" }
)

$Tags = @{
    "Cost Owner"       = "murat.yilmaz@volue.com"
    "Environment Type" = "Production"
    "Project Code"     = "305"
    "Product Line"     = "Trading Solutions"
    "Project Number"   = "Rigel"
    "Technical Owner"  = $TechnicalOwnerUPN
}

$RequiredModules = @("Az.Accounts", "Az.Resources", "Az.Subscription", "Microsoft.Graph.Authentication", "Microsoft.Graph.Groups", "Microsoft.Graph.Users")
$MaxWaitAttempts = 30
$WaitSeconds     = 10
$RbacRetries     = 5
$RbacRetryWait   = 15

# --- functions ---

# returns $true when the change should be made, $false on dry run or when the user says no
function Confirm-Action ($Description) {
    if ($DryRun) {
        Write-Host "DRY RUN: would $Description" -ForegroundColor Yellow
        $script:Summary += [pscustomobject]@{ Action = "dry run"; Item = $Description }
        return $false
    }
    # ${} needed, otherwise the ? gets eaten as part of the variable name
    $Answer = Read-Host "Confirm: ${Description}? (y/n)"
    if ($Answer -match "^[Yy]") { return $true }
    $script:Summary += [pscustomobject]@{ Action = "skipped"; Item = $Description }
    return $false
}

# --- main ---

$Summary = @()

foreach ($Module in $RequiredModules) {
    if (-not (Get-Module -ListAvailable -Name $Module)) {
        Write-Error "Module $Module is not installed. Install it first (Install-Module $Module)."
        return
    }
}

Write-Host "Connecting to Azure and Graph..."
try {
    Connect-AzAccount -TenantId $TenantId -SkipContextPopulation -ErrorAction Stop | Out-Null
    Connect-MgGraph -TenantId $TenantId -Scopes "Group.ReadWrite.All", "User.Read.All" -ErrorAction Stop
} catch {
    Write-Error "Login failed: $($_.Exception.Message)"
    return
}

if ($DryRun) { Write-Host "Dry run - nothing will be changed" -ForegroundColor Yellow }

$BillingScope = "/providers/Microsoft.Billing/billingAccounts/$BillingAccountName/billingProfiles/$BillingProfileName/invoiceSections/$InvoiceSectionName"

# permission checks - fail early instead of halfway through
Write-Host "Checking permissions..."

# billing: which invoice sections can this user create subscriptions on
try {
    $PermResponse = Invoke-AzRestMethod -Method POST `
        -Path "/providers/Microsoft.Billing/billingAccounts/$BillingAccountName/listInvoiceSectionsWithCreateSubscriptionPermission?api-version=2024-04-01" `
        -ErrorAction Stop
} catch {
    Write-Error "Billing permission check failed: $($_.Exception.Message)"
    return
}
if ($PermResponse.StatusCode -ne 200) {
    Write-Error "Cannot query billing account $BillingAccountName (HTTP $($PermResponse.StatusCode)) - you likely have no billing role on it. $($PermResponse.Content)"
    return
}
$AllowedSections = @(($PermResponse.Content | ConvertFrom-Json).value)
$SectionMatch = $AllowedSections | Where-Object { $_.invoiceSectionId -like "*/invoiceSections/$InvoiceSectionName" } | Select-Object -First 1
if (-not $SectionMatch) {
    $Usable = ($AllowedSections | ForEach-Object { "$($_.invoiceSectionDisplayName) ($($_.invoiceSectionId -replace '.*/invoiceSections/', ''))" }) -join ", "
    Write-Error "You cannot create subscriptions on invoice section $InvoiceSectionName. Sections you can use: $Usable"
    return
}
Write-Host "Billing: subscription creation allowed on invoice section '$($SectionMatch.invoiceSectionDisplayName)'"

# management group: must exist and be visible - also catches display names used instead of ids
# plain rest call on purpose, Get-AzManagementGroup tries to register the resource provider on the default subscription
if ($ManagementGroupId) {
    try {
        $MGResponse = Invoke-AzRestMethod -Method GET `
            -Path "/providers/Microsoft.Management/managementGroups/$($ManagementGroupId)?api-version=2020-05-01" `
            -ErrorAction Stop
    } catch {
        Write-Error "Management group check failed: $($_.Exception.Message)"
        return
    }
    if ($MGResponse.StatusCode -ne 200) {
        Write-Error "Management group '$ManagementGroupId' not found or no access (HTTP $($MGResponse.StatusCode)). Use the group ID, not the display name. $($MGResponse.Content)"
        return
    }
    $MG = $MGResponse.Content | ConvertFrom-Json
    Write-Host "Management group: found '$($MG.properties.displayName)' ($ManagementGroupId). Note: placement also needs write access on it."
} else {
    Write-Host "Management group: not set, subscription lands in the tenant default group"
}

# graph: token must carry the scopes the group steps need
$MgContext = Get-MgContext
foreach ($Scope in @("Group.ReadWrite.All", "User.Read.All")) {
    if ($MgContext.Scopes -notcontains $Scope) {
        Write-Error "Graph token is missing scope $Scope - consent was not granted, group steps would fail."
        return
    }
}
Write-Host "Graph: required scopes granted"

# create aliases - skip existing ones, recreating an alias would spawn a duplicate subscription
$SkippedSubs    = @{}
$CreatedAliases = @()
foreach ($Sub in $Subscriptions) {
    $Existing = Get-AzSubscriptionAlias -AliasName $Sub.Alias -ErrorAction SilentlyContinue
    if ($Existing) {
        Write-Host "Alias $($Sub.Alias) already exists (subscription $($Existing.SubscriptionId)), skipping create"
        $Summary += [pscustomobject]@{ Action = "exists"; Item = "subscription $($Sub.Alias) ($($Existing.SubscriptionId))" }
        continue
    }

    $MGText = if ($ManagementGroupId) { "management group $ManagementGroupId" } else { "default management group" }
    if (-not (Confirm-Action "create subscription '$($Sub.Name)' (alias $($Sub.Alias), workload $Workload, $MGText)")) {
        if (-not $DryRun) {
            Write-Host "Skipped $($Sub.Alias) - all further steps for it are skipped too" -ForegroundColor Yellow
            $SkippedSubs[$Sub.Alias] = $true
        }
        continue
    }

    $AdditionalProps = @{ subscriptionTenantId = $TenantId }
    if ($ManagementGroupId) {
        $AdditionalProps.managementGroupId = "/providers/Microsoft.Management/managementGroups/$ManagementGroupId"
    }
    $Body = @{
        properties = @{
            billingScope         = $BillingScope
            displayName          = $Sub.Name
            workload             = $Workload
            additionalProperties = $AdditionalProps
        }
    } | ConvertTo-Json -Depth 5

    try {
        $Response = Invoke-AzRestMethod -Method PUT `
            -Path "/providers/Microsoft.Subscription/aliases/$($Sub.Alias)?api-version=2021-10-01" `
            -Payload $Body -ErrorAction Stop
    } catch {
        Write-Error "Alias request for $($Sub.Alias) failed: $($_.Exception.Message)"
        return
    }

    if ($Response.StatusCode -notin 200, 201, 202) {
        Write-Error "Failed to create alias $($Sub.Alias): HTTP $($Response.StatusCode) $($Response.Content)"
        return
    }
    Write-Host "Alias $($Sub.Alias) submitted (HTTP $($Response.StatusCode))"
    $CreatedAliases += $Sub.Alias
}

$ActiveSubs   = @($Subscriptions | Where-Object { -not $SkippedSubs[$_.Alias] })
$SubIdByAlias = @{}

if ($DryRun) {
    # just resolve ids for aliases that already exist, nothing to wait for
    foreach ($Sub in $ActiveSubs) {
        $State = Get-AzSubscriptionAlias -AliasName $Sub.Alias -ErrorAction SilentlyContinue
        if ($State) { $SubIdByAlias[$Sub.Alias] = $State.SubscriptionId }
    }
} elseif ($ActiveSubs.Count -gt 0) {
    Write-Host "Waiting for subscriptions to provision..."
    $Attempt = 0
    $AllDone = $false
    do {
        $Attempt++
        $ProvStates = @()
        foreach ($Sub in $ActiveSubs) {
            $State = Get-AzSubscriptionAlias -AliasName $Sub.Alias -ErrorAction SilentlyContinue
            if ($State) { $ProvStates += $State }
        }
        Write-Host "Attempt $Attempt`: $(($ProvStates | ForEach-Object { "$($_.AliasName)=$($_.ProvisioningState)" }) -join ", ")"
        # every alias must be found AND succeeded, an empty lookup is not success
        $Succeeded = @($ProvStates | Where-Object { $_.ProvisioningState -eq "Succeeded" })
        $AllDone = ($Succeeded.Count -eq $ActiveSubs.Count)
        if (-not $AllDone) { Start-Sleep -Seconds $WaitSeconds }
    } while (-not $AllDone -and $Attempt -lt $MaxWaitAttempts)

    if (-not $AllDone) {
        Write-Error "Subscriptions did not all reach Succeeded within timeout."
        return
    }

    foreach ($State in $ProvStates) { $SubIdByAlias[$State.AliasName] = $State.SubscriptionId }
    foreach ($Sub in $ActiveSubs) { Write-Host "$($Sub.Alias): $($SubIdByAlias[$Sub.Alias])" }
    foreach ($Alias in $CreatedAliases) { $Summary += [pscustomobject]@{ Action = "created"; Item = "subscription $Alias ($($SubIdByAlias[$Alias]))" } }
} else {
    Write-Host "No subscriptions left to process."
}

foreach ($Sub in $ActiveSubs) {
    $SubId  = $SubIdByAlias[$Sub.Alias]
    $IdText = if ($SubId) { $SubId } else { "id known after creation" }
    if (-not (Confirm-Action "merge $($Tags.Count) tags onto $($Sub.Alias) ($IdText)")) { continue }
    try {
        Update-AzTag -ResourceId "/subscriptions/$SubId" -Tag $Tags -Operation Merge -ErrorAction Stop | Out-Null
        Write-Host "Tags set on $($Sub.Alias)"
        $Summary += [pscustomobject]@{ Action = "tagged"; Item = "$($Tags.Count) tags merged onto $($Sub.Alias)" }
    } catch {
        Write-Error "Tagging $($Sub.Alias) failed: $($_.Exception.Message)"
        return
    }
}

$GroupIds = @{}
foreach ($Sub in $ActiveSubs) {
    foreach ($Role in @("Owners", "Contributors", "Readers")) {
        $DisplayName = "$($Sub.Name) $Role"
        try {
            $ExistingGroup = Get-MgGroup -Filter "displayName eq '$DisplayName'" -ErrorAction Stop | Select-Object -First 1
        } catch {
            Write-Error "Group lookup for '$DisplayName' failed: $($_.Exception.Message)"
            return
        }
        if ($ExistingGroup) {
            Write-Host "Group '$DisplayName' already exists (Id: $($ExistingGroup.Id))"
            $GroupIds[$DisplayName] = $ExistingGroup.Id
            $Summary += [pscustomobject]@{ Action = "exists"; Item = "group '$DisplayName' ($($ExistingGroup.Id))" }
            continue
        }
        if (-not (Confirm-Action "create group '$DisplayName'")) { continue }
        $Nickname = $DisplayName -replace " ", "-" -replace "-{2,}", "-"
        try {
            $NewGroup = New-MgGroup -DisplayName $DisplayName -MailNickname $Nickname -MailEnabled:$false -SecurityEnabled -ErrorAction Stop
        } catch {
            Write-Error "Creating group '$DisplayName' failed: $($_.Exception.Message)"
            return
        }
        Write-Host "Group '$DisplayName' created (Id: $($NewGroup.Id))"
        $GroupIds[$DisplayName] = $NewGroup.Id
        $Summary += [pscustomobject]@{ Action = "created"; Item = "group '$DisplayName' ($($NewGroup.Id))" }
    }
}

try {
    $User = Get-MgUser -UserId $TechnicalOwnerUPN -ErrorAction Stop
} catch {
    Write-Error "User lookup for $TechnicalOwnerUPN failed: $($_.Exception.Message)"
    return
}

foreach ($Sub in $ActiveSubs) {
    $GroupName = "$($Sub.Name) Owners"
    if (-not $GroupIds.ContainsKey($GroupName)) {
        if ($DryRun) {
            Write-Host "DRY RUN: would add $TechnicalOwnerUPN to '$GroupName'" -ForegroundColor Yellow
        } else {
            Write-Host "Group '$GroupName' was not created, skipping member add" -ForegroundColor Yellow
        }
        continue
    }
    $GroupId = $GroupIds[$GroupName]
    try {
        $Members = Get-MgGroupMember -GroupId $GroupId -All -ErrorAction Stop
    } catch {
        Write-Error "Member lookup for '$GroupName' failed: $($_.Exception.Message)"
        return
    }
    if ($Members.Id -contains $User.Id) {
        Write-Host "$TechnicalOwnerUPN already in '$GroupName'"
        $Summary += [pscustomobject]@{ Action = "exists"; Item = "$TechnicalOwnerUPN in '$GroupName'" }
        continue
    }
    if (-not (Confirm-Action "add $TechnicalOwnerUPN to '$GroupName'")) { continue }
    try {
        New-MgGroupMember -GroupId $GroupId -DirectoryObjectId $User.Id -ErrorAction Stop
        Write-Host "Added $TechnicalOwnerUPN to '$GroupName'"
        $Summary += [pscustomobject]@{ Action = "added"; Item = "$TechnicalOwnerUPN to '$GroupName'" }
    } catch {
        Write-Error "Adding $TechnicalOwnerUPN to '$GroupName' failed: $($_.Exception.Message)"
        return
    }
}

# fresh groups can take a moment to replicate, so retry the role assignment
foreach ($Sub in $ActiveSubs) {
    $GroupName = "$($Sub.Name) Owners"
    $SubId     = $SubIdByAlias[$Sub.Alias]

    if (-not $GroupIds.ContainsKey($GroupName) -or -not $SubId) {
        if ($DryRun) {
            Write-Host "DRY RUN: would assign Owner role to '$GroupName' on subscription $($Sub.Alias)" -ForegroundColor Yellow
        } else {
            Write-Host "Missing group or subscription id for '$GroupName', skipping role assignment" -ForegroundColor Yellow
        }
        continue
    }

    $GroupId = $GroupIds[$GroupName]
    $Scope   = "/subscriptions/$SubId"

    $ExistingAssignment = Get-AzRoleAssignment -ObjectId $GroupId -RoleDefinitionName "Owner" -Scope $Scope -ErrorAction SilentlyContinue
    if ($ExistingAssignment) {
        Write-Host "Owner assignment for '$GroupName' already exists on $Scope"
        $Summary += [pscustomobject]@{ Action = "exists"; Item = "Owner role for '$GroupName' on $Scope" }
        continue
    }

    if (-not (Confirm-Action "assign Owner role to '$GroupName' on $Scope")) { continue }

    $Assigned = $false
    for ($i = 1; $i -le $RbacRetries -and -not $Assigned; $i++) {
        try {
            New-AzRoleAssignment -ObjectId $GroupId -RoleDefinitionName "Owner" -Scope $Scope -ErrorAction Stop | Out-Null
            $Assigned = $true
            Write-Host "Owner role assigned to '$GroupName' on $Scope"
            $Summary += [pscustomobject]@{ Action = "assigned"; Item = "Owner role for '$GroupName' on $Scope" }
        } catch {
            if ($i -lt $RbacRetries) {
                Write-Host "Role assignment attempt $i for '$GroupName' failed, retrying in $RbacRetryWait s..." -ForegroundColor Yellow
                Start-Sleep -Seconds $RbacRetryWait
            } else {
                Write-Error "Owner assignment for '$GroupName' on $Scope failed after $RbacRetries attempts: $($_.Exception.Message)"
                return
            }
        }
    }
}

Write-Host ""
Write-Host "Summary:"
if ($Summary.Count -gt 0) {
    $Summary | Format-Table -Property Action, Item -AutoSize -Wrap | Out-String -Width 200 | Write-Host
    try {
        if (-not (Test-Path $OutputPath)) { New-Item -ItemType Directory -Path $OutputPath -Force | Out-Null }
        $Stamp    = Get-Date -Format "yyyyMMdd_HHmm"
        $JsonFile = Join-Path $OutputPath "subscription-creation_$Stamp.json"
        $CsvFile  = Join-Path $OutputPath "subscription-creation_$Stamp.csv"
        # -InputObject keeps a single entry as a json array
        ConvertTo-Json -InputObject $Summary | Out-File -FilePath $JsonFile -Encoding utf8
        $Summary | Export-Csv -Path $CsvFile -NoTypeInformation -Encoding utf8
        Write-Host "Summary written to $JsonFile and $CsvFile"
    } catch {
        Write-Warning "Could not write summary files to ${OutputPath}: $($_.Exception.Message)"
    }
} else {
    Write-Host "Nothing to report."
}

if ($DryRun) {
    Write-Host "Dry run complete. Nothing was changed." -ForegroundColor Yellow
} else {
    Write-Host "Done. Remember to configure PIM for the Owners group(s)."
}
