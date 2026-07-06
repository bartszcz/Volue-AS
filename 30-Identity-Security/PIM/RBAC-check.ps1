<#
.SYNOPSIS
    Compares Azure RBAC and PIM eligible role assignments between two Entra ID users.

.DESCRIPTION
    Given a reference user and a target user, this script enumerates all Azure
    subscriptions visible to the authenticated account and checks whether the
    target user holds the same active and PIM-eligible role assignments
    (directly or via transitive group membership) as the reference user.

    Output is a CSV report plus a console summary of any missing assignments.

.PARAMETER ReferenceUserUpn
    UPN of the reference (template) user whose assignments are the baseline.

.PARAMETER TargetUserUpn
    UPN of the user being audited / onboarded.

.PARAMETER OutputPath
    Full path for the output CSV file.
    Defaults to: $env:TEMP\AzureAccessCompare_<target>_vs_<reference>.csv

.PARAMETER TenantId
    Optional. Constrain to a specific Entra ID tenant.
    If omitted the default tenant from Connect-AzAccount is used.

.PARAMETER SubscriptionIds
    Optional. Array of subscription IDs to check.
    If omitted all subscriptions visible to the authenticated account are checked.

.PARAMETER IncludePim
    Switch. Include PIM eligible assignments in the comparison (default: $true).
    Pass -IncludePim:$false to skip PIM enumeration (faster, requires fewer permissions).

.PARAMETER ExportMissingOnly
    Switch. When set, only rows where TargetHasSameRoleAtScope is $false
    are written to the CSV.

.EXAMPLE
    # Interactive login, compare two users across all subscriptions
    .\Compare-AzureUserAccess.ps1 `
        -ReferenceUserUpn alice@contoso.com `
        -TargetUserUpn    bob@contoso.com

.EXAMPLE
    # Limit to specific subscriptions and skip PIM
    .\Compare-AzureUserAccess.ps1 `
        -ReferenceUserUpn alice@contoso.com `
        -TargetUserUpn    bob@contoso.com `
        -SubscriptionIds  @("xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx") `
        -IncludePim:$false

.EXAMPLE
    # Export only missing assignments and write to a custom path
    .\Compare-AzureUserAccess.ps1 `
        -ReferenceUserUpn alice@contoso.com `
        -TargetUserUpn    bob@contoso.com `
        -OutputPath       C:\Reports\AccessGap.csv `
        -ExportMissingOnly

.NOTES
    Required modules (install once per machine):
        Install-Module Az.Accounts   -Scope CurrentUser
        Install-Module Az.Resources  -Scope CurrentUser   # 6.0+ for PIM eligible assignments
        Install-Module Microsoft.Graph.Users  -Scope CurrentUser
        Install-Module Microsoft.Graph.Groups -Scope CurrentUser

    Required Graph permissions (delegated):
        User.Read.All, Group.Read.All, Directory.Read.All

    Required Azure permissions:
        Reader (or higher) on each subscription you want to audit.
        Microsoft.Authorization/roleEligibilitySchedules/read for PIM data.
#>

[CmdletBinding()]
param (
    [Parameter(Mandatory, HelpMessage = "UPN of the reference / template user")]
    [ValidateNotNullOrEmpty()]
    [string]$ReferenceUserUpn,

    [Parameter(Mandatory, HelpMessage = "UPN of the target / new user")]
    [ValidateNotNullOrEmpty()]
    [string]$TargetUserUpn,

    [Parameter(HelpMessage = "Output CSV path (auto-generated if omitted)")]
    [string]$OutputPath,

    [Parameter(HelpMessage = "Entra ID tenant ID (uses default tenant if omitted)")]
    [string]$TenantId,

    [Parameter(HelpMessage = "Limit check to these subscription IDs")]
    [string[]]$SubscriptionIds,

    [Parameter(HelpMessage = "Include PIM eligible assignments (default: true)")]
    [switch]$IncludePim = $true,

    [Parameter(HelpMessage = "Write only rows where target is missing the assignment")]
    [switch]$ExportMissingOnly
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

#region ── Helpers ──────────────────────────────────────────────────────────────

function Write-Section {
    param([string]$Message, [ConsoleColor]$Color = "Cyan")
    Write-Host ""
    Write-Host "── $Message" -ForegroundColor $Color
}

function Get-UserTransitiveGroups {
    <#
    .SYNOPSIS Returns all transitive Entra ID group memberships for a user.
    #>
    param([Parameter(Mandatory)][string]$UserId)

    Write-Verbose "Fetching transitive groups for $UserId"

    Get-MgUserTransitiveMemberOf -UserId $UserId -All |
        Where-Object { $_.AdditionalProperties.'@odata.type' -eq '#microsoft.graph.group' } |
        ForEach-Object {
            [PSCustomObject]@{
                Id          = $_.Id
                DisplayName = $_.AdditionalProperties.displayName
                Mail        = $_.AdditionalProperties.mail
            }
        }
}

function Resolve-RoleName {
    <#
    .SYNOPSIS Resolves a role definition display name from a PIM schedule object.
    #>
    param($Schedule)

    $name = $Schedule.RoleDefinitionDisplayName
    if (-not $name) {
        try {
            $id = ($Schedule.RoleDefinitionId -split '/')[-1]
            $name = (Get-AzRoleDefinition -Id $id -ErrorAction SilentlyContinue).Name
        }
        catch {}
    }
    if (-not $name) { $name = ($Schedule.RoleDefinitionId -split '/')[-1] }
    return $name
}

function ConvertTo-NormalisedAssignment {
    <#
    .SYNOPSIS
        Normalises active (Get-AzRoleAssignment) and eligible
        (Get-AzRoleEligibilitySchedule) objects into a common shape.
    #>
    param(
        $Assignment,
        [ValidateSet("Active", "Eligible")]
        [string]$Kind
    )

    if ($Kind -eq "Active") {
        return [PSCustomObject]@{
            PrincipalId  = $Assignment.ObjectId
            RoleName     = $Assignment.RoleDefinitionName
            Scope        = $Assignment.Scope
            DisplayName  = $Assignment.DisplayName
        }
    }

    return [PSCustomObject]@{
        PrincipalId  = $Assignment.PrincipalId
        RoleName     = Resolve-RoleName $Assignment
        Scope        = $Assignment.Scope
        DisplayName  = $Assignment.PrincipalDisplayName
    }
}

function Get-ComparisonRows {
    <#
    .SYNOPSIS
        For a set of assignments, builds output rows that record whether the
        target user holds the same role+scope combination.
    #>
    param(
        [object[]]$Assignments,
        [ValidateSet("Active", "Eligible")]
        [string]$Kind,
        [string[]]$RefPrincipalIds,
        [string[]]$TgtPrincipalIds,
        [string]$SubName,
        [string]$SubId,
        [string]$TenantId,
        [string]$RefUserId,
        [string]$RefUserUpn,
        [string]$TgtUserUpn,
        [object[]]$RefGroups
    )

    $normalised = $Assignments | ForEach-Object {
        ConvertTo-NormalisedAssignment -Assignment $_ -Kind $Kind
    }

    $refMatches = $normalised | Where-Object { $RefPrincipalIds -contains $_.PrincipalId }
    $tgtMatches = $normalised | Where-Object { $TgtPrincipalIds -contains $_.PrincipalId }

    foreach ($a in $refMatches) {

        $assignmentSource = if ($a.PrincipalId -eq $RefUserId) { "Direct" } else { "Group" }
        $sourceGroupName  = if ($assignmentSource -eq "Group") {
            ($RefGroups | Where-Object { $_.Id -eq $a.PrincipalId } | Select-Object -First 1).DisplayName
        } else { $null }

        $matchingTarget = $tgtMatches |
            Where-Object { $_.RoleName -eq $a.RoleName -and $_.Scope -eq $a.Scope }

        $targetHas = [bool]$matchingTarget

        [PSCustomObject]@{
            SubscriptionName         = $SubName
            SubscriptionId           = $SubId
            TenantId                 = $TenantId
            ReferenceUser            = $RefUserUpn
            TargetUser               = $TgtUserUpn
            AssignmentKind           = $Kind
            ReferenceRole            = $a.RoleName
            ReferenceScope           = $a.Scope
            ReferenceAssignmentType  = $assignmentSource
            ReferencePrincipalName   = $a.DisplayName
            ReferencePrincipalId     = $a.PrincipalId
            ReferenceGroupName       = $sourceGroupName
            TargetHasSameRoleAtScope = $targetHas
            TargetMatchingPrincipals = ($matchingTarget |
                                            Select-Object -ExpandProperty DisplayName -Unique) -join "; "
            Notes                    = if ($targetHas) { "OK" } else { "Missing compared to reference user" }
        }
    }
}

#endregion

#region ── Resolve default output path ──────────────────────────────────────────

if (-not $OutputPath) {
    $safeTgt = $TargetUserUpn.Replace('@', '_').Replace('.', '_')
    $safeRef = $ReferenceUserUpn.Replace('@', '_').Replace('.', '_')
    $OutputPath = Join-Path $env:TEMP "AzureAccessCompare_${safeTgt}_vs_${safeRef}.csv"
}

#endregion

#region ── Module check ──────────────────────────────────────────────────────────

$requiredModules = @(
    "Az.Accounts",
    "Az.Resources",
    "Microsoft.Graph.Users",
    "Microsoft.Graph.Groups"
)

foreach ($mod in $requiredModules) {
    if (-not (Get-Module -ListAvailable -Name $mod)) {
        throw "Required module '$mod' is not installed. Run: Install-Module $mod -Scope CurrentUser"
    }
}

Import-Module Az.Accounts, Az.Resources, Microsoft.Graph.Users, Microsoft.Graph.Groups -ErrorAction Stop

#endregion

#region ── Authentication ────────────────────────────────────────────────────────

Write-Section "Connecting to Azure"
$azParams = @{}
if ($TenantId) { $azParams["TenantId"] = $TenantId }
Connect-AzAccount @azParams | Out-Null

Write-Section "Connecting to Microsoft Graph"
Connect-MgGraph -Scopes "User.Read.All", "Group.Read.All", "Directory.Read.All" | Out-Null

#endregion

#region ── Resolve users ────────────────────────────────────────────────────────

Write-Section "Resolving users"

$ReferenceUser = Get-MgUser -UserId $ReferenceUserUpn -ErrorAction Stop
$TargetUser    = Get-MgUser -UserId $TargetUserUpn    -ErrorAction Stop

Write-Host "Reference : $($ReferenceUser.DisplayName)  [$($ReferenceUser.UserPrincipalName)]  ($($ReferenceUser.Id))" -ForegroundColor Green
Write-Host "Target    : $($TargetUser.DisplayName)  [$($TargetUser.UserPrincipalName)]  ($($TargetUser.Id))"           -ForegroundColor Green

#endregion

#region ── Group memberships ────────────────────────────────────────────────────

Write-Section "Fetching transitive group memberships"

$ReferenceGroups = Get-UserTransitiveGroups -UserId $ReferenceUser.Id
$TargetGroups    = Get-UserTransitiveGroups -UserId $TargetUser.Id

Write-Host "Reference group count : $($ReferenceGroups.Count)" -ForegroundColor Green
Write-Host "Target group count    : $($TargetGroups.Count)"    -ForegroundColor Green

$ReferencePrincipalIds = @($ReferenceUser.Id) + @($ReferenceGroups.Id)
$TargetPrincipalIds    = @($TargetUser.Id)    + @($TargetGroups.Id)

#endregion

#region ── Subscriptions ────────────────────────────────────────────────────────

Write-Section "Enumerating subscriptions"

if ($SubscriptionIds -and $SubscriptionIds.Count -gt 0) {
    $Subscriptions = $SubscriptionIds | ForEach-Object { Get-AzSubscription -SubscriptionId $_ } | Sort-Object Name
    Write-Host "Using $($Subscriptions.Count) supplied subscription(s)." -ForegroundColor Green
} else {
    $Subscriptions = Get-AzSubscription | Sort-Object Name
    Write-Host "Found $($Subscriptions.Count) subscription(s) visible to this account." -ForegroundColor Green
}

#endregion

#region ── Main comparison loop ─────────────────────────────────────────────────

$Results = [System.Collections.Generic.List[object]]::new()

foreach ($Sub in $Subscriptions) {
    Write-Host "  Checking: $($Sub.Name)  [$($Sub.Id)]" -ForegroundColor Cyan

    try {
        $ctxParams = @{ SubscriptionId = $Sub.Id }
        if ($TenantId) { $ctxParams["TenantId"] = $TenantId } else { $ctxParams["TenantId"] = $Sub.TenantId }
        Set-AzContext @ctxParams -ErrorAction Stop | Out-Null

        # Active assignments
        $ActiveAssignments = Get-AzRoleAssignment -Scope "/subscriptions/$($Sub.Id)" -ErrorAction Stop

        # PIM eligible assignments
        $EligibleAssignments = @()
        if ($IncludePim) {
            try {
                $EligibleAssignments = Get-AzRoleEligibilitySchedule `
                    -Scope "/subscriptions/$($Sub.Id)" -ErrorAction Stop
            }
            catch {
                Write-Warning "PIM data unavailable for '$($Sub.Name)': $($_.Exception.Message)"
            }
        }

        $commonArgs = @{
            RefPrincipalIds = $ReferencePrincipalIds
            TgtPrincipalIds = $TargetPrincipalIds
            SubName         = $Sub.Name
            SubId           = $Sub.Id
            TenantId        = $Sub.TenantId
            RefUserId       = $ReferenceUser.Id
            RefUserUpn      = $ReferenceUserUpn
            TgtUserUpn      = $TargetUserUpn
            RefGroups       = $ReferenceGroups
        }

        Get-ComparisonRows -Assignments $ActiveAssignments   -Kind "Active"   @commonArgs |
            ForEach-Object { $Results.Add($_) }

        if ($IncludePim -and $EligibleAssignments.Count -gt 0) {
            Get-ComparisonRows -Assignments $EligibleAssignments -Kind "Eligible" @commonArgs |
                ForEach-Object { $Results.Add($_) }
        }
    }
    catch {
        $Results.Add([PSCustomObject]@{
            SubscriptionName         = $Sub.Name
            SubscriptionId           = $Sub.Id
            TenantId                 = $Sub.TenantId
            ReferenceUser            = $ReferenceUserUpn
            TargetUser               = $TargetUserUpn
            AssignmentKind           = $null
            ReferenceRole            = $null
            ReferenceScope           = "/subscriptions/$($Sub.Id)"
            ReferenceAssignmentType  = $null
            ReferencePrincipalName   = $null
            ReferencePrincipalId     = $null
            ReferenceGroupName       = $null
            TargetHasSameRoleAtScope = $false
            TargetMatchingPrincipals = $null
            Notes                    = "ERROR: $($_.Exception.Message)"
        })
    }
}

#endregion

#region ── Export ───────────────────────────────────────────────────────────────

$export = $Results | Sort-Object SubscriptionName, ReferenceRole, ReferenceScope

if ($ExportMissingOnly) {
    $export = $export | Where-Object { $_.TargetHasSameRoleAtScope -eq $false }
}

$export | Export-Csv -Path $OutputPath -NoTypeInformation -Encoding UTF8

Write-Section "Output" "Yellow"
Write-Host $OutputPath -ForegroundColor Yellow

#endregion

#region ── Console summary ──────────────────────────────────────────────────────

Write-Section "Missing ACTIVE assignments" "Magenta"
$Results |
    Where-Object { -not $_.TargetHasSameRoleAtScope -and $_.ReferenceRole -and $_.AssignmentKind -eq "Active" } |
    Select-Object SubscriptionName, ReferenceRole, ReferenceScope,
                  ReferenceAssignmentType, ReferenceGroupName, Notes |
    Format-Table -AutoSize

if ($IncludePim) {
    Write-Section "Missing ELIGIBLE (PIM) assignments" "Magenta"
    $Results |
        Where-Object { -not $_.TargetHasSameRoleAtScope -and $_.ReferenceRole -and $_.AssignmentKind -eq "Eligible" } |
        Select-Object SubscriptionName, ReferenceRole, ReferenceScope,
                      ReferenceAssignmentType, ReferenceGroupName, Notes |
        Format-Table -AutoSize
}

Write-Section "Done" "Green"
Write-Host "Total rows  : $($Results.Count)"
Write-Host "Missing rows: $(($Results | Where-Object { -not $_.TargetHasSameRoleAtScope -and $_.ReferenceRole }).Count)"

#endregion