# ── Configuration ────────────────────────────────────────────────────────────
$TenantId            = "9ce76d42-5ecb-4d8f-939b-a462ad28cf34"
$BillingAccountName  = "d7daa3ab-00b0-5157-f1c1-fee9bc0668ba:6274e3d1-6729-4a2a-90a8-a5074278ea1b_2019-05-31"
$BillingProfileName  = "QDNA-A7KS-BG7-PGB"
$InvoiceSectionName  = "OTP2-PY5C-PJA-PGB"
$ManagementGroupId   = "EnergyTest"
$TechnicalOwnerUPN   = "mariusz.klimczak@volue.com"

$Subscriptions = @(
    @{ Alias = "Energy-SmarTestEnergy-Prod";    Name = "Energy - SmarTestEnergy - Prod" },
    @{ Alias = "Energy-SmarTestEnergy-PreProd"; Name = "Energy - SmarTestEnergy - PreProd" }
)

$Tags = @{
    "Cost Owner"       = "matteo.cabassi@volue.com"
    "Environment Type" = "Test & Development Environment"
    "Project Code"     = "1820"
    "Product Line"     = "Energy"
    "Project Number"   = "201134"
    "Technical Owner"  = $TechnicalOwnerUPN
}

# ── Authentication ────────────────────────────────────────────────────────────
Connect-AzAccount -TenantId $TenantId -SkipContextPopulation
Connect-AzAccount -TenantId $TenantId -AuthScope MicrosoftGraphEndpointResourceId -SkipContextPopulation

# ── Billing Scope ─────────────────────────────────────────────────────────────
$BillingScope = "/providers/Microsoft.Billing/billingAccounts/$BillingAccountName/billingProfiles/$BillingProfileName/invoiceSections/$InvoiceSectionName"

# ── Create Subscriptions ──────────────────────────────────────────────────────
foreach ($Sub in $Subscriptions) {
    Remove-AzSubscriptionAlias -AliasName $Sub.Alias -ErrorAction SilentlyContinue

    $Body = @{
        properties = @{
            billingScope         = $BillingScope
            displayName          = $Sub.Name
            workload             = "DevTest"
            additionalProperties = @{
                subscriptionTenantId = $TenantId
                managementGroupId    = "/providers/Microsoft.Management/managementGroups/$ManagementGroupId"
            }
        }
    } | ConvertTo-Json -Depth 5

    $Response = Invoke-AzRestMethod -Method PUT `
        -Path "/providers/Microsoft.Subscription/aliases/$($Sub.Alias)?api-version=2021-10-01" `
        -Payload $Body

    if ($Response.StatusCode -notin 200, 201, 202) {
        Write-Error "Failed to create alias $($Sub.Alias): $($Response.Content)"
        return
    }
    Write-Host "Alias $($Sub.Alias) submitted (HTTP $($Response.StatusCode))"
}

Write-Host "Waiting for subscriptions to provision..."
$MaxAttempts = 30
$Attempt     = 0
do {
    Start-Sleep -Seconds 10
    $Attempt++
    $ProvStates = $Subscriptions | ForEach-Object {
        Get-AzSubscriptionAlias -AliasName $_.Alias -ErrorAction SilentlyContinue
    }
    Write-Host "Attempt $Attempt`: $($ProvStates | ForEach-Object { "$($_.AliasName)=$($_.ProvisioningState)" })"
} while (($ProvStates | Where-Object { $_.ProvisioningState -ne "Succeeded" }) -and $Attempt -lt $MaxAttempts)

if ($ProvStates | Where-Object { $_.ProvisioningState -ne "Succeeded" }) {
    Write-Error "Subscriptions did not provision within timeout."
    return
}

$SubIdProd    = ($ProvStates | Where-Object { $_.AliasName -eq $Subscriptions[0].Alias }).SubscriptionId
$SubIdPreProd = ($ProvStates | Where-Object { $_.AliasName -eq $Subscriptions[1].Alias }).SubscriptionId

Write-Host "Prod SubId:    $SubIdProd"
Write-Host "PreProd SubId: $SubIdPreProd"

# ── Tags ──────────────────────────────────────────────────────────────────────
foreach ($SubId in @($SubIdProd, $SubIdPreProd)) {
    Update-AzTag -ResourceId "/subscriptions/$SubId" -Tag $Tags -Operation Merge
}

# ── Entra ID Groups ───────────────────────────────────────────────────────────
$GroupIds = @{}

foreach ($Sub in $Subscriptions) {
    foreach ($Role in @("Owners", "Contributors", "Readers")) {
        $DisplayName = "$($Sub.Name) $Role"
        $Existing    = Get-AzADGroup -Filter "displayName eq '$DisplayName'" | Select-Object -First 1
        if ($Existing) {
            Write-Host "Group '$DisplayName' already exists (Id: $($Existing.Id))"
            $GroupIds[$DisplayName] = $Existing.Id
        } else {
            $Nickname = $DisplayName -replace " ", "-" -replace "--", "-"
            $NewGroup = New-AzADGroup -DisplayName $DisplayName -MailNickname $Nickname
            Write-Host "Group '$DisplayName' created (Id: $($NewGroup.Id))"
            $GroupIds[$DisplayName] = $NewGroup.Id
        }
    }
}

# ── Add Technical Owner to Owners Groups ─────────────────────────────────────
$User = Get-AzADUser -UserPrincipalName $TechnicalOwnerUPN

foreach ($Sub in $Subscriptions) {
    Add-AzADGroupMember `
        -TargetGroupObjectId $GroupIds["$($Sub.Name) Owners"] `
        -MemberObjectId      $User.Id
}

# ── RBAC: Assign Owner Role to Owners Groups ──────────────────────────────────
$SubMap = @(
    @{ Id = $SubIdProd;    Name = $Subscriptions[0].Name },
    @{ Id = $SubIdPreProd; Name = $Subscriptions[1].Name }
)

foreach ($Sub in $SubMap) {
    New-AzRoleAssignment `
        -ObjectId           $GroupIds["$($Sub.Name) Owners"] `
        -RoleDefinitionName "Owner" `
        -Scope              "/subscriptions/$($Sub.Id)"
}

Write-Host "Done. Remember to configure PIM for both Owners groups."
