param(
    [string]$SubscriptionId = 'b6d274a6-1de3-4287-8cbe-7ca52980ce7e',
    [string]$TargetManagementGroupId = 'Energy',
    [int]$ActivityLogHours = 24,
    [string]$OutputFolder = "./PostMove-Governance-$SubscriptionId"
)

$ErrorActionPreference = 'Stop'

try {
    if (-not (Get-AzContext -ErrorAction SilentlyContinue)) {
        Connect-AzAccount -ErrorAction Stop | Out-Null
    }

    $subscription = Get-AzSubscription `
        -SubscriptionId $SubscriptionId `
        -ErrorAction Stop

    Set-AzContext `
        -SubscriptionId $SubscriptionId `
        -TenantId $subscription.TenantId `
        -ErrorAction Stop | Out-Null

    $subscriptionScope = "/subscriptions/$SubscriptionId"

    New-Item `
        -Path $OutputFolder `
        -ItemType Directory `
        -Force `
        -ErrorAction Stop | Out-Null

    # Verify the subscription is below the intended management group.
    $managementGroupMembership = Get-AzManagementGroupSubscription `
        -GroupName $TargetManagementGroupId `
        -SubscriptionId $SubscriptionId `
        -ErrorAction Stop

    $managementGroupMembership |
        Select-Object DisplayName, Name, ParentId, State |
        Export-Csv `
            -Path (Join-Path $OutputFolder 'Management-Group-Membership.csv') `
            -NoTypeInformation `
            -Encoding UTF8

    # Effective Azure RBAC assignments.
    $roleAssignments = @(
        Get-AzRoleAssignment `
            -Scope $subscriptionScope `
            -ErrorAction Stop
    )

    $roleAssignments |
        Select-Object `
            DisplayName,
            SignInName,
            ObjectId,
            ObjectType,
            RoleDefinitionName,
            RoleDefinitionId,
            Scope,
            Condition,
            ConditionVersion |
        Sort-Object Scope, RoleDefinitionName, DisplayName |
        Export-Csv `
            -Path (Join-Path $OutputFolder 'Effective-RBAC.csv') `
            -NoTypeInformation `
            -Encoding UTF8

    # Effective deny assignments.
    $denyAssignments = @(
        Get-AzDenyAssignment `
            -Scope $subscriptionScope `
            -ErrorAction Stop
    )

    $denyAssignments |
        Select-Object `
            DenyAssignmentName,
            Description,
            Scope,
            IsSystemProtected,
            DoNotApplyToChildScopes,
            Principals,
            ExcludePrincipals,
            Permissions |
        Export-Csv `
            -Path (Join-Path $OutputFolder 'Effective-Deny-Assignments.csv') `
            -NoTypeInformation `
            -Encoding UTF8

    # Applicable policy assignments, including inherited assignments.
    $policyAssignmentsJson = az policy assignment list `
        --scope $subscriptionScope `
        --output json `
        --only-show-errors

    if ($LASTEXITCODE -ne 0) {
        throw 'Unable to retrieve applicable policy assignments.'
    }

    $policyAssignments = @(
        $policyAssignmentsJson | ConvertFrom-Json
    )

    $policyAssignments |
        Select-Object `
            displayName,
            name,
            scope,
            enforcementMode,
            policyDefinitionId,
            notScopes,
            @{
                Name       = 'IdentityType'
                Expression = { $_.identity.type }
            },
            @{
                Name       = 'PrincipalId'
                Expression = { $_.identity.principalId }
            },
            @{
                Name       = 'Parameters'
                Expression = { $_.parameters | ConvertTo-Json -Depth 20 -Compress }
            } |
        Sort-Object scope, displayName |
        Export-Csv `
            -Path (Join-Path $OutputFolder 'Applicable-Policy-Assignments.csv') `
            -NoTypeInformation `
            -Encoding UTF8

    # Policy exemptions applicable above, at, or below subscription scope.
    $policyExemptions = @(
        Get-AzPolicyExemption `
            -Scope $subscriptionScope `
            -IncludeDescendent `
            -ErrorAction Stop
    )

    $policyExemptions |
        Select-Object `
            DisplayName,
            Name,
            Scope,
            PolicyAssignmentId,
            ExemptionCategory,
            ExpiresOn,
            AssignmentScopeValidation |
        Sort-Object Scope, DisplayName |
        Export-Csv `
            -Path (Join-Path $OutputFolder 'Policy-Exemptions.csv') `
            -NoTypeInformation `
            -Encoding UTF8

    # Current policy compliance summary.
    $policySummary = Get-AzPolicyStateSummary `
        -SubscriptionId $SubscriptionId `
        -ErrorAction Stop

    $policySummary |
        ConvertTo-Json -Depth 30 |
        Set-Content `
            -Path (Join-Path $OutputFolder 'Policy-Compliance-Summary.json') `
            -Encoding UTF8

    # Custom roles currently used by assignments in this subscription.
    $customRoles = @(
        $roleAssignments.RoleDefinitionId |
            Sort-Object -Unique |
            ForEach-Object {
                try {
                    Get-AzRoleDefinition -Id $_ -ErrorAction Stop
                }
                catch {
                    Write-Warning "Could not resolve role definition: $_"
                }
            } |
            Where-Object IsCustom
    )

    $customRoles |
        Select-Object `
            Name,
            Id,
            IsCustom,
            Description,
            AssignableScopes,
            Actions,
            NotActions,
            DataActions,
            NotDataActions |
        Export-Csv `
            -Path (Join-Path $OutputFolder 'Custom-Roles-In-Use.csv') `
            -NoTypeInformation `
            -Encoding UTF8

    # Recent failed control-plane operations.
    $failedActivity = @(
        Get-AzActivityLog `
            -StartTime (Get-Date).AddHours(-$ActivityLogHours) `
            -EndTime (Get-Date) `
            -ErrorAction Stop |
            Where-Object {
                $_.Status.Value -eq 'Failed' -or
                $_.SubStatus.Value -eq 'BadRequest' -or
                $_.SubStatus.Value -eq 'Forbidden'
            }
    )

    $failedActivity |
        Select-Object `
            EventTimestamp,
            OperationName,
            Status,
            SubStatus,
            Caller,
            ResourceGroupName,
            ResourceId,
            CorrelationId |
        Sort-Object EventTimestamp -Descending |
        Export-Csv `
            -Path (Join-Path $OutputFolder 'Failed-Activity-Log.csv') `
            -NoTypeInformation `
            -Encoding UTF8

    # Existing resource locks for reference.
    $resourceLocks = @(
        Get-AzResourceLock -ErrorAction Stop
    )

    $resourceLocks |
        Select-Object Name, LockId, LockLevel, Notes, ResourceId |
        Export-Csv `
            -Path (Join-Path $OutputFolder 'Resource-Locks.csv') `
            -NoTypeInformation `
            -Encoding UTF8

    # Defender for Cloud configuration, when Az.Security is available.
    if (Get-Command Get-AzSecurityPricing -ErrorAction SilentlyContinue) {
        Get-AzSecurityPricing |
            Select-Object Name, PricingTier, SubPlan, FreeTrialRemainingTime |
            Export-Csv `
                -Path (Join-Path $OutputFolder 'Defender-Pricing.csv') `
                -NoTypeInformation `
                -Encoding UTF8
    }

    if (Get-Command Get-AzSecurityAutoProvisioningSetting -ErrorAction SilentlyContinue) {
        Get-AzSecurityAutoProvisioningSetting |
            Select-Object Name, AutoProvision |
            Export-Csv `
                -Path (Join-Path $OutputFolder 'Defender-AutoProvisioning.csv') `
                -NoTypeInformation `
                -Encoding UTF8
    }

    [pscustomobject]@{
        SubscriptionName          = $subscription.Name
        SubscriptionId            = $SubscriptionId
        TargetManagementGroup     = $TargetManagementGroupId
        EffectiveRoleAssignments  = $roleAssignments.Count
        EffectiveDenyAssignments  = $denyAssignments.Count
        ApplicablePolicyAssignments = $policyAssignments.Count
        ApplicablePolicyExemptions  = $policyExemptions.Count
        CustomRolesInUse          = $customRoles.Count
        RecentFailedOperations    = $failedActivity.Count
        ResourceLocks             = $resourceLocks.Count
        Result                    = if ($failedActivity.Count -eq 0) {
            'No immediate Azure control-plane failures detected'
        }
        else {
            'Review Failed-Activity-Log.csv'
        }
        ReportFolder              = (Resolve-Path $OutputFolder).Path
    } | Format-List
}
catch {
    Write-Error "Post-move governance verification failed: $($_.Exception.Message)"
    exit 1
}