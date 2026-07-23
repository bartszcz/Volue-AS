# sub-delete.ps1 - cancels empty azure subscriptions, links to portal for the final delete
# bartek / volue ito / 2026-07

# --- settings ---
$TenantId = "9ce76d42-5ecb-4d8f-939b-a462ad28cf34"

$Subs = @(
    "c53cb188-4cff-47d5-8140-9c39c1a7a22e",
    "c4d2c597-90bf-4a86-a039-32bea091c394"
)

# --- main ---
if (-not (Get-Command Connect-AzAccount -ErrorAction SilentlyContinue)) {
    Write-Host "Az module not found. Run: Install-Module Az" -ForegroundColor Red
    exit 1
}

try {
    Connect-AzAccount -TenantId $TenantId -SkipContextPopulation -ErrorAction Stop
} catch {
    Write-Host "Login failed: $($_.Exception.Message)" -ForegroundColor Red
    exit 1
}

foreach ($SubId in $Subs) {
    Write-Host "`nChecking subscription: $SubId" -ForegroundColor Cyan

    try {
        $Sub = Get-AzSubscription -SubscriptionId $SubId -TenantId $TenantId -ErrorAction Stop
    } catch {
        Write-Warning "Cannot read subscription $SubId ($($_.Exception.Message)) - skipping"
        continue
    }

    Write-Host "Name: $($Sub.Name)  State: $($Sub.State)"

    # already canceled -> only the final delete is left. no api for that, ms says
    # portal only. button appears ~3 days after cancel (7 for csp/partner subs),
    # needs owner role. azure auto-deletes after 90 days anyway
    if ($Sub.State -eq "Disabled") {
        $PortalUrl = "https://portal.azure.com/#@$TenantId/resource/subscriptions/$SubId/overview"
        Write-Host "Already canceled. Final delete is portal-only (Delete button on the subscription page)." -ForegroundColor Yellow

        # portal refuses to delete while resources remain, so show what's left
        $null = Set-AzContext -SubscriptionId $SubId -ErrorAction SilentlyContinue
        try {
            $Leftover = @(Get-AzResource -ErrorAction Stop)
            if ($Leftover.Count -gt 0) {
                Write-Host "Still contains $($Leftover.Count) resources - portal delete will be blocked until they are gone:" -ForegroundColor Yellow
                $Leftover | Select-Object Name, ResourceType, ResourceGroupName | Format-Table -AutoSize
            } else {
                Write-Host "No resources left - delete should be possible once the waiting period is over." -ForegroundColor Green
            }
        } catch {
            Write-Warning "Could not list resources ($($_.Exception.Message)) - check in portal"
        }

        Write-Host $PortalUrl
        $Open = Read-Host "Open portal page now? (y/yes)"
        if ($Open -in @("y", "yes")) {
            Start-Process $PortalUrl
        }
        continue
    }

    if ($Sub.State -ne "Enabled") {
        Write-Warning "State is '$($Sub.State)' - neither enabled nor canceled, check in portal - skipping"
        continue
    }

    $null = Set-AzContext -SubscriptionId $SubId -ErrorAction SilentlyContinue
    if (-not (Get-AzContext | Where-Object { $_.Subscription.Id -eq $SubId })) {
        Write-Warning "Cannot access subscription $SubId - skipping"
        continue
    }

    # permission check with fresh-token retry
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

    # a failed enumeration must not look like an empty sub - skip instead of cancel
    try {
        $Resources      = @(Get-AzResource -ErrorAction Stop)
        $ResourceGroups = @(Get-AzResourceGroup -ErrorAction Stop)
        $Locks          = @(Get-AzResourceLock -ErrorAction Stop)
    } catch {
        Write-Warning "Could not list resources/locks in $SubId ($($_.Exception.Message)) - skipping to be safe"
        continue
    }

    Write-Host "Resources: $($Resources.Count)  Resource groups: $($ResourceGroups.Count)  Locks: $($Locks.Count)"

    if ($Locks.Count -gt 0) {
        Write-Host "Locks present - must be removed before cancellation:" -ForegroundColor Red
        $Locks | Select-Object Name, ResourceType, LockLevel | Format-Table -AutoSize
        continue
    }

    if ($Resources.Count -gt 0 -or $ResourceGroups.Count -gt 0) {
        Write-Host "Subscription still contains resources:" -ForegroundColor Yellow
        $ResourceGroups | Select-Object ResourceGroupName, Location | Format-Table -AutoSize
        $Resources | Select-Object Name, ResourceType, ResourceGroupName | Format-Table -AutoSize
        continue
    }

    Write-Host "Subscription is empty." -ForegroundColor Green
    $Confirm = Read-Host "Cancel subscription $SubId? (y/yes to confirm)"
    if ($Confirm -in @("y", "yes")) {
        try {
            $CancelResp = Invoke-AzRestMethod -Method POST `
                -Path "/subscriptions/$SubId/providers/Microsoft.Subscription/cancel?api-version=2021-10-01" `
                -ErrorAction Stop
        } catch {
            Write-Warning "Cancel call failed for $SubId : $($_.Exception.Message)"
            continue
        }
        if ($CancelResp.StatusCode -notin 200, 202) {
            Write-Warning "Cancellation may have failed (HTTP $($CancelResp.StatusCode)): $($CancelResp.Content)"
        } else {
            Write-Host "Cancellation requested for $SubId" -ForegroundColor Green
            Write-Host "Delete option shows up in portal ~3 days after cancel. Re-run this script then for the link, or do nothing - Azure auto-deletes after 90 days."
        }
    }
}
