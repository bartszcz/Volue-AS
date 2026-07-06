# ── Configuration ─────────────────────────────────────────────────────────────
$TenantId = "9ce76d42-5ecb-4d8f-939b-a462ad28cf34"

$Subs = @(
    "c53cb188-4cff-47d5-8140-9c39c1a7a22e",
    "c4d2c597-90bf-4a86-a039-32bea091c394"
)

# ── Authentication ─────────────────────────────────────────────────────────────
Connect-AzAccount -TenantId $TenantId -SkipContextPopulation

foreach ($SubId in $Subs) {
    Write-Host "`nChecking subscription: $SubId" -ForegroundColor Cyan

    $null = Set-AzContext -SubscriptionId $SubId -ErrorAction SilentlyContinue
    if (-not (Get-AzContext | Where-Object { $_.Subscription.Id -eq $SubId })) {
        Write-Warning "Cannot access subscription $SubId — skipping"
        continue
    }

    # ── Permission check with fresh-token retry ────────────────────────────────
    $SkipSub = $false
    while ($true) {
        $CurrentUPN    = (Get-AzContext).Account.Id
        $HasPermission = Get-AzRoleAssignment -SignInName $CurrentUPN -Scope "/subscriptions/$SubId" -ErrorAction SilentlyContinue |
            Where-Object { $_.RoleDefinitionName -in @("Owner", "Contributor") }

        if ($HasPermission) {
            Write-Host "Permission OK: $($HasPermission[0].RoleDefinitionName) as '$CurrentUPN'" -ForegroundColor Green
            break
        }

        Write-Warning "'$CurrentUPN' has no Owner or Contributor on subscription $SubId."
        $Retry = Read-Host "Re-authenticate (clears cached token) and check again? (yes/no)"
        if ($Retry -ne "yes") {
            $SkipSub = $true
            break
        }

        # -Force triggers fresh interactive login and discards the cached token
        Connect-AzAccount -TenantId $TenantId -Force -SkipContextPopulation
        $null = Set-AzContext -SubscriptionId $SubId
    }

    if ($SkipSub) { continue }

    # ── Resource / lock check ─────────────────────────────────────────────────
    $Resources      = Get-AzResource
    $ResourceGroups = Get-AzResourceGroup
    $Locks          = Get-AzResourceLock

    Write-Host "Resources: $($Resources.Count)  Resource groups: $($ResourceGroups.Count)  Locks: $($Locks.Count)"

    if ($Locks.Count -gt 0) {
        Write-Host "Locks present — must be removed before deletion:" -ForegroundColor Red
        $Locks | Select-Object Name, ResourceType, LockLevel | Format-Table -AutoSize
        continue
    }

    if ($Resources.Count -gt 0 -or $ResourceGroups.Count -gt 0) {
        Write-Host "Subscription still contains resources:" -ForegroundColor Yellow
        $ResourceGroups | Select-Object ResourceGroupName, Location | Format-Table -AutoSize
        $Resources | Select-Object Name, ResourceType, ResourceGroupName | Format-Table -AutoSize
        continue
    }

    # ── Cancel ────────────────────────────────────────────────────────────────
    Write-Host "Subscription is empty." -ForegroundColor Green
    $Confirm = Read-Host "Cancel subscription $SubId? (y/yes to confirm)"
    if ($Confirm -in @("y", "yes")) {
        $CancelResp = Invoke-AzRestMethod -Method POST `
            -Path "/subscriptions/$SubId/providers/Microsoft.Subscription/cancel?api-version=2021-10-01"
        if ($CancelResp.StatusCode -notin 200, 202) {
            Write-Warning "Cancellation may have failed (HTTP $($CancelResp.StatusCode)): $($CancelResp.Content)"
        } else {
            Write-Host "Cancellation requested for $SubId" -ForegroundColor Green
        }
    }
}
