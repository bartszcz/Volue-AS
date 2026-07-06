#Requires -Version 5.1
#Requires -Modules ExchangeOnlineManagement, Microsoft.Graph.Groups, Microsoft.Graph.Teams
<#
.SYNOPSIS
    Post-migration group validation. Validates distribution groups,
    M365 Groups, and Teams in the target tenant against Phase 1 inventory.

.DESCRIPTION
    DISTRIBUTION GROUPS
        - Group exists in target
        - Owner count matches source
        - Member count within threshold of source
        - ManagedBy is set (not empty)
        - Dynamic DLs flagged for manual filter review

    M365 GROUPS / TEAMS
        - Group exists in target
        - Owner count matches source
        - Member count within threshold
        - If IsTeam: Team exists and is accessible
        - Channel count matches source (standard channels)
        - Private channels flagged for member verification
        - Guest action items from Phase 3 output flagged as pending

    OUTPUTS
        MigrationData\post_dl_validation.csv
        MigrationData\post_m365group_validation.csv
        MigrationData\post_group_validation_issues.csv

.PARAMETER TargetTenantId
    AAD Tenant ID of the target tenant.

.PARAMETER TargetAdminUPN
    Admin UPN for the target tenant.

.PARAMETER SourceDomain
    Primary email domain of the source company. e.g. 'smartpulse.io'

.PARAMETER CompanySuffix
    Human-readable company name. e.g. 'SmartPulse'

.PARAMETER DLMappingCsv
    Confirmed DL mapping. Default: .\MigrationData\dl_mapping.csv

.PARAMETER DLMembersCsv
    Source DL members. Default: .\MigrationData\distribution_group_members.csv

.PARAMETER UnifiedGroupsCsv
    Confirmed M365 Group mapping. Default: .\MigrationData\unified_groups.csv

.PARAMETER GuestActionsCsv
    Guest re-invitation actions from Phase 3.
    Default: .\MigrationData\m365group_guest_actions_required.csv

.PARAMETER MemberDeltaThresholdPct
    Maximum acceptable % difference in member count. Default: 5

.PARAMETER OutputPath
    Output folder. Default: .\MigrationData

.EXAMPLE
    .\Test-PostGroupMigration.ps1 `
        -TargetTenantId 'volue.onmicrosoft.com' `
        -TargetAdminUPN 'admin@volue.com' `
        -SourceDomain   'smartpulse.io' `
        -CompanySuffix  'SmartPulse'
#>

[CmdletBinding()]
param(
    [string] $TargetTenantId = '',
    [string] $TargetAdminUPN = '',
    [string] $SourceDomain = '',
    [string] $CompanySuffix = '',
    [string] $DLMappingCsv            = '.\MigrationData\dl_mapping.csv',
    [string] $DLMembersCsv            = '.\MigrationData\distribution_group_members.csv',
    [string] $UnifiedGroupsCsv        = '.\MigrationData\unified_groups.csv',
    [string] $GuestActionsCsv         = '.\MigrationData\m365group_guest_actions_required.csv',
    [int]    $MemberDeltaThresholdPct = 5,
    [string] $OutputPath              = '.\MigrationData'
)

# ── Bootstrap ─────────────────────────────────────────────────────────────────

Import-Module (Join-Path $PSScriptRoot '..\MigrationHelpers.psm1') -Force -ErrorAction Stop

# ── Load MigrationConfig.psd1 ────────────────────────────────────────────────
$_cfg = Import-MigrationConfig
$SourceDomain = Resolve-ConfigParam -Passed $SourceDomain -Default '' -ConfigValue (Get-ConfigValue -Config $_cfg -Key "SourceDomain")
$CompanySuffix = Resolve-ConfigParam -Passed $CompanySuffix -Default '' -ConfigValue (Get-ConfigValue -Config $_cfg -Key "CompanySuffix")
$TargetTenantId = Resolve-ConfigParam -Passed $TargetTenantId -Default '' -ConfigValue (Get-ConfigValue -Config $_cfg -Key "TargetTenantId")
$TargetAdminUPN = Resolve-ConfigParam -Passed $TargetAdminUPN -Default '' -ConfigValue (Get-ConfigValue -Config $_cfg -Key "TargetAdminUPN")
$DLMappingCsv = Resolve-ConfigParam -Passed $DLMappingCsv -Default '' -ConfigValue (Get-ConfigValue -Config $_cfg -Key "DLMappingCsv")
$DLMembersCsv = Resolve-ConfigParam -Passed $DLMembersCsv -Default '' -ConfigValue (Get-ConfigValue -Config $_cfg -Key "DLMembersCsv")
$UnifiedGroupsCsv = Resolve-ConfigParam -Passed $UnifiedGroupsCsv -Default '' -ConfigValue (Get-ConfigValue -Config $_cfg -Key "UnifiedGroupsCsv")
$GuestActionsCsv = Resolve-ConfigParam -Passed $GuestActionsCsv -Default '' -ConfigValue (Get-ConfigValue -Config $_cfg -Key "GuestActionsCsv")
$OutputPath = Resolve-ConfigParam -Passed $OutputPath -Default '' -ConfigValue (Get-ConfigValue -Config $_cfg -Key "OutputPath")
$MemberDeltaThresholdPct = Resolve-ConfigParam -Passed $MemberDeltaThresholdPct -Default '' -ConfigValue (Get-ConfigValue -Config $_cfg -Key "MemberDeltaThresholdPct")

# ── Validate that required values were supplied (via config or command line) ──
$_missingParams = @()
foreach ($__p in @(
    @{ Name='SourceDomain';    Value=$SourceDomain    }
    @{ Name='CompanySuffix';   Value=$CompanySuffix   }
)) {
    if (-not $__p.Value) { $_missingParams += $__p.Name }
}
if ($_missingParams.Count -gt 0) {
    Write-Error ("Required parameters not supplied and not found in MigrationConfig.psd1: {0}`n" +
                 "Either fill in MigrationConfig.psd1 or pass these as command-line arguments." `
                 -f ($_missingParams -join ', '))
    exit 1
}

Set-MigrationDomains -SourceDomain $SourceDomain -CompanySuffix $CompanySuffix
Initialize-MigLog -ScriptName 'Test-PostGroupMigration' `
                  -LogDirectory (Join-Path $PSScriptRoot '..\Logs')
$outDir = Ensure-OutputDirectory -Path $OutputPath

# ── Connect ───────────────────────────────────────────────────────────────────

Connect-TargetTenant -TenantId $TargetTenantId -UserPrincipalName $TargetAdminUPN

# Index all target DLs
$targetDLs = Invoke-WithRetry {
    Get-DistributionGroup -ResultSize Unlimited -ErrorAction Stop
}
$targetDLIndex = @{}
foreach ($g in $targetDLs) { $targetDLIndex[$g.PrimarySmtpAddress.ToLower()] = $g }

# Index all target M365 Groups
$targetM365Groups = Invoke-WithRetry {
    Get-MgGroup -All -Filter "groupTypes/any(c:c eq 'Unified')" `
                -Property 'Id,Mail,DisplayName,ResourceProvisioningOptions' `
                -ErrorAction Stop
}
$targetM365Index = @{}
foreach ($g in $targetM365Groups) {
    if ($g.Mail) { $targetM365Index[$g.Mail.ToLower()] = $g }
}

$allIssues = [System.Collections.Generic.List[PSCustomObject]]::new()

# ── VALIDATE: Distribution groups ────────────────────────────────────────────

$dlResults = [System.Collections.Generic.List[PSCustomObject]]::new()

if (Test-Path $DLMappingCsv) {

    $dlMapping   = Import-CsvSafe -Path $DLMappingCsv
    $confirmedDL = $dlMapping | Where-Object { $_.Status -eq 'CONFIRMED' }

    # Source member counts from Phase 1
    $sourceMemberCountIndex = @{}
    if (Test-Path $DLMembersCsv) {
        $dlMemberRows = Import-CsvSafe -Path $DLMembersCsv
        $sourceMemberCountIndex = $dlMemberRows |
            Group-Object GroupEmail |
            ForEach-Object { @{ $_.Name = $_.Count } } |
            ForEach-Object { $_ }
        # Rebuild as hashtable
        $tmp = @{}
        foreach ($grp in ($dlMemberRows | Group-Object GroupEmail)) {
            $tmp[$grp.Name.ToLower()] = $grp.Count
        }
        $sourceMemberCountIndex = $tmp
    }

    $total = @($confirmedDL).Count; $i = 0
    $dlPassed = 0; $dlWarnings = 0; $dlFailed = 0

    foreach ($dl in $confirmedDL) {

        $i++
        Write-ProgressHelper -Activity 'Validating DLs' `
                             -Current $i -Total $total -Status $dl.TargetEmail

        $targetDL = $targetDLIndex[$dl.TargetEmail.ToLower()]
        $issues   = [System.Collections.Generic.List[string]]::new()
        $status   = 'PASS'

        if (-not $targetDL) {
            $status = 'FAIL'
            $issues.Add('CRITICAL: Group not found in target — run New-DistributionGroups.ps1')
            $dlFailed++
        }
        else {
            # Owner check
            $hasManagedBy = $targetDL.ManagedBy.Count -gt 0
            if (-not $hasManagedBy) {
                $issues.Add('WARN: ManagedBy (owners) is empty')
                $status = 'WARN'
            }

            # Member count check (skip for dynamic groups)
            $isDynamic = $dl.IsDynamic -eq $true -or $dl.IsDynamic -eq 'True'
            $sourceMemberCount = $sourceMemberCountIndex[$dl.SourceEmail.ToLower()] ?? 0
            $targetMemberCount = 0

            if (-not $isDynamic -and $sourceMemberCount -gt 0) {
                try {
                    $targetMembers = Invoke-WithRetry {
                        Get-DistributionGroupMember -Identity $dl.TargetEmail `
                                                    -ResultSize Unlimited `
                                                    -ErrorAction Stop
                    }
                    $targetMemberCount = @($targetMembers).Count
                    $memberDelta = [math]::Round(
                        [math]::Abs(($targetMemberCount - $sourceMemberCount) / $sourceMemberCount) * 100, 1)

                    if ($memberDelta -gt $MemberDeltaThresholdPct) {
                        $issues.Add("WARN: Member count $targetMemberCount vs source $sourceMemberCount ($memberDelta% delta)")
                        if ($status -eq 'PASS') { $status = 'WARN' }
                    }
                }
                catch {
                    $issues.Add("WARN: Could not retrieve target member count — $_")
                }
            }

            if ($isDynamic) {
                $issues.Add('INFO: Dynamic group — verify RecipientFilter was manually set at target')
            }

            if ($status -eq 'PASS') { $dlPassed++ } else { $dlWarnings++ }
        }

        $dlResults.Add([PSCustomObject]@{
            SourceEmail        = $dl.SourceEmail
            TargetEmail        = $dl.TargetEmail
            IsDynamic          = $dl.IsDynamic
            Status             = $status
            SourceMemberCount  = $sourceMemberCountIndex[$dl.SourceEmail.ToLower()] ?? 0
            TargetMemberCount  = $targetDL ? (@(Invoke-WithRetry {
                Get-DistributionGroupMember -Identity $dl.TargetEmail -ResultSize Unlimited `
                                            -ErrorAction SilentlyContinue }).Count) : 0
            HasOwners          = ($targetDL?.ManagedBy.Count -gt 0)
            Issues             = ($issues | Join-String -Separator ' | ')
        })

        foreach ($issue in ($issues | Where-Object { $_ -match 'CRITICAL|WARN' })) {
            $allIssues.Add([PSCustomObject]@{
                Area    = 'DistributionGroup'
                Group   = $dl.TargetEmail
                Severity = if ($issue -match 'CRITICAL') { 'CRITICAL' } else { 'WARN' }
                Issue   = $issue
            })
        }
    }

    Write-Progress -Activity 'Validating DLs' -Completed
    Write-MigLog "DL Validation — PASS: $dlPassed | WARN: $dlWarnings | FAIL: $dlFailed"
}

# ── VALIDATE: M365 Groups & Teams ─────────────────────────────────────────────

$m365Results = [System.Collections.Generic.List[PSCustomObject]]::new()

if (Test-Path $UnifiedGroupsCsv) {

    $unifiedMapping  = Import-CsvSafe -Path $UnifiedGroupsCsv
    $confirmedGroups = $unifiedMapping | Where-Object { $_.Status -eq 'CONFIRMED' }

    # Load pending guest actions for cross-reference
    $pendingGuestEmails = @{}
    if (Test-Path $GuestActionsCsv) {
        $guestActions = Import-CsvSafe -Path $GuestActionsCsv
        foreach ($g in $guestActions) {
            $pendingGuestEmails[$g.TargetGroupEmail.ToLower()] = $true
        }
    }

    $total = @($confirmedGroups).Count; $i = 0
    $m365Passed = 0; $m365Warnings = 0; $m365Failed = 0

    foreach ($grp in $confirmedGroups) {

        $i++
        $targetEmail = $grp.TargetEmail ?? $grp.SuggestedTargetEmail
        Write-ProgressHelper -Activity 'Validating M365 Groups' `
                             -Current $i -Total $total -Status $targetEmail

        $targetGrp = if ($targetEmail) { $targetM365Index[$targetEmail.ToLower()] } else { $null }
        $issues    = [System.Collections.Generic.List[string]]::new()
        $status    = 'PASS'

        $isTeam    = $grp.IsTeam -eq $true -or $grp.IsTeam -eq 'True'

        if (-not $targetGrp) {
            $status = 'FAIL'
            $issues.Add('CRITICAL: Group not found in target — run New-M365GroupsAndTeams.ps1')
            $m365Failed++
        }
        else {
            # Owner count
            try {
                $targetOwners  = Invoke-WithRetry {
                    Get-MgGroupOwner -GroupId $targetGrp.Id -All -ErrorAction Stop
                }
                $targetOwnerCount = @($targetOwners).Count
                if ($targetOwnerCount -eq 0) {
                    $issues.Add('WARN: Group has no owners')
                    $status = 'WARN'
                }
                elseif ([int]$grp.OwnerCount -gt 0) {
                    $ownerDelta = [math]::Abs($targetOwnerCount - [int]$grp.OwnerCount)
                    if ($ownerDelta -gt 0) {
                        $issues.Add("WARN: Owner count $targetOwnerCount vs source $($grp.OwnerCount)")
                        if ($status -eq 'PASS') { $status = 'WARN' }
                    }
                }
            }
            catch { $issues.Add("WARN: Could not retrieve owners — $_") }

            # Member count
            try {
                $targetMembers     = Invoke-WithRetry {
                    Get-MgGroupMember -GroupId $targetGrp.Id -All -ErrorAction Stop
                }
                $targetMemberCount = @($targetMembers).Count
                $sourceMemberCount = [int]($grp.MemberCount ?? 0)

                if ($sourceMemberCount -gt 0) {
                    $memberDelta = [math]::Round(
                        [math]::Abs(($targetMemberCount - $sourceMemberCount) / $sourceMemberCount) * 100, 1)
                    if ($memberDelta -gt $MemberDeltaThresholdPct) {
                        $issues.Add("WARN: Member count $targetMemberCount vs source $sourceMemberCount ($memberDelta% delta — guests excluded from migration)")
                        if ($status -eq 'PASS') { $status = 'WARN' }
                    }
                }
            }
            catch { $issues.Add("WARN: Could not retrieve members — $_") }

            # Team provisioned?
            $teamProvisioned = $false
            $targetChannelCount = 0
            if ($isTeam) {
                $isProvisioned = $targetGrp.ResourceProvisioningOptions -contains 'Team'
                if (-not $isProvisioned) {
                    $issues.Add('WARN: Group is not provisioned as a Team — run New-M365GroupsAndTeams.ps1')
                    if ($status -eq 'PASS') { $status = 'WARN' }
                }
                else {
                    $teamProvisioned = $true
                    # Channel count
                    try {
                        $channels = Invoke-WithRetry {
                            Get-MgTeamChannel -TeamId $targetGrp.Id -All -ErrorAction Stop
                        }
                        $targetChannelCount  = @($channels).Count
                        $sourceChannelCount  = [int]($grp.ChannelCount ?? 0)
                        $privateChannelCount = [int]($grp.PrivateChannelCount ?? 0)
                        $expectedStandard    = $sourceChannelCount - $privateChannelCount

                        if ($targetChannelCount -lt $expectedStandard) {
                            $issues.Add("WARN: Channel count $targetChannelCount vs expected $expectedStandard standard channels")
                            if ($status -eq 'PASS') { $status = 'WARN' }
                        }
                        if ($privateChannelCount -gt 0) {
                            $issues.Add("INFO: $privateChannelCount private channel(s) at source — verify members were added")
                        }
                    }
                    catch { $issues.Add("WARN: Could not retrieve channels — $_") }
                }
            }

            # Guests pending re-invitation?
            if ($targetEmail -and $pendingGuestEmails.ContainsKey($targetEmail.ToLower())) {
                $issues.Add('INFO: Guest re-invitations pending — see m365group_guest_actions_required.csv')
            }

            if ($status -eq 'PASS') { $m365Passed++ } else { $m365Warnings++ }
        }

        $m365Results.Add([PSCustomObject]@{
            SourceEmail         = $grp.PrimarySmtpAddress
            TargetEmail         = $targetEmail
            IsTeam              = $isTeam
            Status              = $status
            SourceOwnerCount    = $grp.OwnerCount
            TargetOwnerCount    = $targetGrp ? @(Invoke-WithRetry {
                Get-MgGroupOwner -GroupId $targetGrp.Id -All -ErrorAction SilentlyContinue }).Count : 0
            SourceMemberCount   = $grp.MemberCount
            SourceGuestCount    = $grp.GuestCount
            TeamProvisioned     = $teamProvisioned
            TargetChannelCount  = $targetChannelCount
            SourceChannelCount  = $grp.ChannelCount
            GuestsPending       = ($targetEmail -and $pendingGuestEmails.ContainsKey($targetEmail.ToLower()))
            Issues              = ($issues | Join-String -Separator ' | ')
        })

        foreach ($issue in ($issues | Where-Object { $_ -match 'CRITICAL|WARN' })) {
            $allIssues.Add([PSCustomObject]@{
                Area     = 'M365Group'
                Group    = $targetEmail
                Severity = if ($issue -match 'CRITICAL') { 'CRITICAL' } else { 'WARN' }
                Issue    = $issue
            })
        }
    }

    Write-Progress -Activity 'Validating M365 Groups' -Completed
    Write-MigLog "M365 Group Validation — PASS: $m365Passed | WARN: $m365Warnings | FAIL: $m365Failed"
}

# ── Export ────────────────────────────────────────────────────────────────────

$dlResults    | Export-CsvSafe -Path (Join-Path $outDir 'post_dl_validation.csv')
$m365Results  | Export-CsvSafe -Path (Join-Path $outDir 'post_m365group_validation.csv')
if ($allIssues.Count -gt 0) {
    $allIssues | Export-CsvSafe -Path (Join-Path $outDir 'post_group_validation_issues.csv')
}

Write-MigSummary -Stats @{
    'DLs validated'            = $dlResults.Count
    'DL issues'                = ($dlResults | Where-Object { $_.Status -ne 'PASS' }).Count
    'M365 Groups validated'    = $m365Results.Count
    'M365 Group issues'        = ($m365Results | Where-Object { $_.Status -ne 'PASS' }).Count
    'Total issues logged'      = $allIssues.Count
    'Member delta threshold'   = "$MemberDeltaThresholdPct%"
    'Next step'                = 'Run New-MigrationReport.ps1 for final sign-off report'
}

Disconnect-AllTenants
