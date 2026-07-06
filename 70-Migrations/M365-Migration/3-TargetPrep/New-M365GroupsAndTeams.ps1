#Requires -Version 5.1
#Requires -Modules Microsoft.Graph.Groups, Microsoft.Graph.Teams
<#
.SYNOPSIS
    Creates Microsoft 365 Groups and Teams in the TARGET tenant, then
    adds owners, members, and channels from the Phase 1 inventory.

.DESCRIPTION
    Reads unified_groups.csv (CONFIRMED rows), creates each M365 Group
    and (if IsTeam=True) provisions it as a Team. Then:

        OWNERS          — added from unified_group_members.csv (Role=Owner)
                          resolved via user_mapping_confirmed.csv
        MEMBERS         — added from unified_group_members.csv (Role=Member)
        CHANNELS        — standard and private channels from teams_channels.csv
        PRIVATE CHANNEL MEMBERS
                        — added from teams_private_channel_members.csv

    GUEST MEMBERS
        Rows flagged IsGuest=True are logged to a separate file.
        Guests must be re-invited manually — they cannot be bulk-added
        cross-tenant via Graph without an invitation flow.

    SHARED CHANNELS
        Flagged in output. Re-invitation of external participants is a
        manual post-migration step.

    IDEMPOTENT — existing groups are matched by PrimarySmtpAddress and skipped.

    IMPORTANT TIMING
        Teams provisioning is asynchronous. The script polls for readiness
        before adding channels. Poll timeout is configurable.

    OUTPUTS
        MigrationData\m365group_creation_results.csv
        MigrationData\m365group_creation_errors.csv
        MigrationData\m365group_guest_actions_required.csv   (manual re-invitation list)

.PARAMETER TargetTenantId
    AAD Tenant ID of the target tenant.

.PARAMETER TargetAdminUPN
    Admin UPN for the target tenant.

.PARAMETER SourceDomain
    Primary email domain of the source company. e.g. 'smartpulse.io'

.PARAMETER CompanySuffix
    Human-readable company name. e.g. 'SmartPulse'

.PARAMETER GroupMappingCsv
    Confirmed group mapping. Default: .\MigrationData\unified_groups.csv

.PARAMETER GroupMembersCsv
    Group members from Phase 1. Default: .\MigrationData\unified_group_members.csv

.PARAMETER ChannelsCsv
    Teams channels from Phase 1. Default: .\MigrationData\teams_channels.csv

.PARAMETER PrivateChannelMembersCsv
    Private channel members from Phase 1.
    Default: .\MigrationData\teams_private_channel_members.csv

.PARAMETER UserMappingCsv
    Confirmed user mapping. Default: .\MigrationData\user_mapping_confirmed.csv

.PARAMETER TeamsProvisioningTimeoutSeconds
    Seconds to wait for a new Team to become available via Graph. Default: 120

.PARAMETER WhatIf
    Show what would be created without making changes.

.PARAMETER OutputPath
    Output folder. Default: .\MigrationData

.EXAMPLE
    .\New-M365GroupsAndTeams.ps1 `
        -TargetTenantId 'volue.onmicrosoft.com' `
        -TargetAdminUPN 'admin@volue.com' `
        -SourceDomain   'smartpulse.io' `
        -CompanySuffix  'SmartPulse' `
        -WhatIf
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    [string] $TargetTenantId = '',
    [string] $TargetAdminUPN = '',
    [string] $SourceDomain = '',
    [string] $CompanySuffix = '',
    [string] $GroupMappingCsv             = '.\MigrationData\unified_groups.csv',
    [string] $GroupMembersCsv             = '.\MigrationData\unified_group_members.csv',
    [string] $ChannelsCsv                 = '.\MigrationData\teams_channels.csv',
    [string] $PrivateChannelMembersCsv    = '.\MigrationData\teams_private_channel_members.csv',
    [string] $UserMappingCsv              = '.\MigrationData\user_mapping_confirmed.csv',
    [int]    $TeamsProvisioningTimeoutSeconds = 120,
    [string] $OutputPath                  = '.\MigrationData'
)

# ── Bootstrap ─────────────────────────────────────────────────────────────────

Import-Module (Join-Path $PSScriptRoot '..\MigrationHelpers.psm1') -Force -ErrorAction Stop

# ── Load MigrationConfig.psd1 ────────────────────────────────────────────────
$_cfg = Import-MigrationConfig
$SourceDomain = Resolve-ConfigParam -Passed $SourceDomain -Default '' -ConfigValue (Get-ConfigValue -Config $_cfg -Key "SourceDomain")
$CompanySuffix = Resolve-ConfigParam -Passed $CompanySuffix -Default '' -ConfigValue (Get-ConfigValue -Config $_cfg -Key "CompanySuffix")
$TargetTenantId = Resolve-ConfigParam -Passed $TargetTenantId -Default '' -ConfigValue (Get-ConfigValue -Config $_cfg -Key "TargetTenantId")
$TargetAdminUPN = Resolve-ConfigParam -Passed $TargetAdminUPN -Default '' -ConfigValue (Get-ConfigValue -Config $_cfg -Key "TargetAdminUPN")
$UserMappingCsv = Resolve-ConfigParam -Passed $UserMappingCsv -Default '' -ConfigValue (Get-ConfigValue -Config $_cfg -Key "UserMappingCsv")
$GroupMembersCsv = Resolve-ConfigParam -Passed $GroupMembersCsv -Default '' -ConfigValue (Get-ConfigValue -Config $_cfg -Key "GroupMembersCsv")
$ChannelsCsv = Resolve-ConfigParam -Passed $ChannelsCsv -Default '' -ConfigValue (Get-ConfigValue -Config $_cfg -Key "ChannelsCsv")
$PrivateChannelMembersCsv = Resolve-ConfigParam -Passed $PrivateChannelMembersCsv -Default '' -ConfigValue (Get-ConfigValue -Config $_cfg -Key "PrivateChannelMembersCsv")
$OutputPath = Resolve-ConfigParam -Passed $OutputPath -Default '' -ConfigValue (Get-ConfigValue -Config $_cfg -Key "OutputPath")
$TeamsProvisioningTimeoutSeconds = Resolve-ConfigParam -Passed $TeamsProvisioningTimeoutSeconds -Default '' -ConfigValue (Get-ConfigValue -Config $_cfg -Key "TeamsProvisioningTimeoutSeconds")

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
Initialize-MigLog -ScriptName 'New-M365GroupsAndTeams' `
                  -LogDirectory (Join-Path $PSScriptRoot '..\Logs')
$outDir = Ensure-OutputDirectory -Path $OutputPath

# ── Load inputs ───────────────────────────────────────────────────────────────

$allGroups     = Import-CsvSafe -Path $GroupMappingCsv `
    -RequiredColumns @('PrimarySmtpAddress','DisplayName','Status','MailNickname','Visibility','IsTeam')
$confirmedGrps = $allGroups | Where-Object { $_.Status -eq 'CONFIRMED' }
Write-MigLog "Confirmed M365 Groups to create: $($confirmedGrps.Count)"

Import-UserMapping -Path $UserMappingCsv -ConfirmedOnly

# Build per-group member/owner index
$memberIndex = @{}
if (Test-Path $GroupMembersCsv) {
    foreach ($r in (Import-CsvSafe -Path $GroupMembersCsv)) {
        if (-not $memberIndex.ContainsKey($r.GroupEmail)) {
            $memberIndex[$r.GroupEmail] = [System.Collections.Generic.List[PSCustomObject]]::new()
        }
        $memberIndex[$r.GroupEmail].Add($r)
    }
}

# Build per-team channel index
$channelIndex = @{}
if (Test-Path $ChannelsCsv) {
    foreach ($r in (Import-CsvSafe -Path $ChannelsCsv)) {
        if (-not $channelIndex.ContainsKey($r.TeamEmail)) {
            $channelIndex[$r.TeamEmail] = [System.Collections.Generic.List[PSCustomObject]]::new()
        }
        $channelIndex[$r.TeamEmail].Add($r)
    }
}

# Build private channel member index keyed on "teamEmail|channelName"
$privChMemberIndex = @{}
if (Test-Path $PrivateChannelMembersCsv) {
    foreach ($r in (Import-CsvSafe -Path $PrivateChannelMembersCsv)) {
        $key = "$($r.TeamEmail)|$($r.ChannelDisplayName)"
        if (-not $privChMemberIndex.ContainsKey($key)) {
            $privChMemberIndex[$key] = [System.Collections.Generic.List[PSCustomObject]]::new()
        }
        $privChMemberIndex[$key].Add($r)
    }
}

# ── Connect ───────────────────────────────────────────────────────────────────

Connect-TargetTenant -TenantId $TargetTenantId -UserPrincipalName $TargetAdminUPN

# Build index of existing target M365 Groups by mail address
Write-MigLog "Building existing target group index..."
$existingGroups = Invoke-WithRetry {
    Get-MgGroup -All `
        -Filter "groupTypes/any(c:c eq 'Unified')" `
        -Property 'Id,Mail,MailNickname,DisplayName' `
        -ErrorAction Stop
}
$existingIndex = @{}
foreach ($g in $existingGroups) {
    if ($g.Mail) { $existingIndex[$g.Mail.ToLower()] = $g }
}
Write-MigLog "Existing target M365 Groups: $($existingIndex.Count)"

# Helper: resolve source email to target AAD ObjectId
function Resolve-TargetUserId {
    param([string] $SourceEmail)
    $targetEmail = Get-MappedEmail -SourceEmail $SourceEmail
    if (-not $targetEmail) { return $null }
    try {
        $u = Invoke-WithRetry {
            Get-MgUser -Filter "userPrincipalName eq '$targetEmail'" `
                       -Property 'Id' -ErrorAction Stop
        }
        return $u?.Id
    } catch { return $null }
}

# Helper: wait for a Team to become accessible
function Wait-ForTeamProvisioning {
    param([string]$GroupId, [int]$TimeoutSeconds)
    $elapsed = 0
    while ($elapsed -lt $TimeoutSeconds) {
        try {
            $team = Get-MgTeam -TeamId $GroupId -ErrorAction SilentlyContinue
            if ($team) { return $true }
        } catch {}
        Start-Sleep -Seconds 10
        $elapsed += 10
        Write-MigLog "  Waiting for Team provisioning... ${elapsed}s" -Level DEBUG
    }
    return $false
}

# ── Creation loop ─────────────────────────────────────────────────────────────

$resultRows  = [System.Collections.Generic.List[PSCustomObject]]::new()
$errorRows   = [System.Collections.Generic.List[PSCustomObject]]::new()
$guestRows   = [System.Collections.Generic.List[PSCustomObject]]::new()

$created  = 0; $existing = 0; $failed = 0
$total    = $confirmedGrps.Count; $i = 0

foreach ($grp in $confirmedGrps) {

    $i++
    Write-ProgressHelper -Activity 'Creating M365 Groups' `
                         -Current $i -Total $total `
                         -Status $grp.DisplayName

    $targetEmail    = $grp.TargetEmail ?? $grp.PrimarySmtpAddress   # prefer mapping override
    $targetNickname = $grp.SuggestedTargetAlias ?? $grp.MailNickname
    $targetName     = $grp.TargetDisplayName ?? $grp.SuggestedTargetName
    $isTeam         = $grp.IsTeam -eq $true -or $grp.IsTeam -eq 'True'
    $visibility     = if ($grp.Visibility -eq 'Private') { 'Private' } else { 'Public' }

    # ── Idempotency ───────────────────────────────────────────────────────────
    if ($targetEmail -and $existingIndex.ContainsKey($targetEmail.ToLower())) {
        $existing++
        Write-MigLog "  EXISTS: $targetEmail"
        $resultRows.Add([PSCustomObject]@{
            SourceEmail = $grp.PrimarySmtpAddress; TargetEmail = $targetEmail
            IsTeam = $isTeam; Action = 'ALREADY_EXISTS'; WhatIf = $false
            OwnersAdded = 0; MembersAdded = 0; ChannelsAdded = 0; Notes = 'Already existed'
        })
        continue
    }

    if ($PSCmdlet.ShouldProcess($targetEmail, "Create M365 Group '$targetName'")) {
        try {
            # ── Resolve initial owner (required by Graph — use first mapped owner)
            $srcMembers   = $memberIndex[$grp.PrimarySmtpAddress]
            $firstOwnerSrc = ($srcMembers | Where-Object { $_.Role -eq 'Owner' } | Select-Object -First 1)?.UserEmail
            $firstOwnerId  = if ($firstOwnerSrc) { Resolve-TargetUserId -SourceEmail $firstOwnerSrc } else { $null }

            # ── Create M365 Group ─────────────────────────────────────────────
            $groupBody = @{
                DisplayName         = $targetName
                MailNickname        = $targetNickname
                Description         = $grp.Description
                Visibility          = $visibility
                GroupTypes          = @('Unified')
                MailEnabled         = $true
                SecurityEnabled     = $false
            }
            if ($firstOwnerId) {
                $groupBody['Owners@odata.bind'] = @("https://graph.microsoft.com/v1.0/users/$firstOwnerId")
            }

            $newGroup = Invoke-WithRetry {
                New-MgGroup -BodyParameter $groupBody -ErrorAction Stop
            }
            $newGroupId = $newGroup.Id
            Write-MigLog "  CREATED group: $targetName ($newGroupId)"

            $ownersAdded  = if ($firstOwnerId) { 1 } else { 0 }
            $membersAdded = 0
            $channelsAdded = 0

            # ── Add remaining owners ──────────────────────────────────────────
            $ownerRows = $srcMembers | Where-Object { $_.Role -eq 'Owner' -and -not $_.IsGuest }
            foreach ($ownerRow in $ownerRows) {
                if ($ownerRow.UserEmail -eq $firstOwnerSrc) { continue }   # already added
                $ownerId = Resolve-TargetUserId -SourceEmail $ownerRow.UserEmail
                if (-not $ownerId) {
                    Write-MigLog "  Owner not mapped: $($ownerRow.UserEmail)" -Level WARN; continue
                }
                try {
                    Invoke-WithRetry {
                        New-MgGroupOwner -GroupId $newGroupId `
                            -BodyParameter @{ '@odata.id' = "https://graph.microsoft.com/v1.0/users/$ownerId" } `
                            -ErrorAction Stop
                    }
                    $ownersAdded++
                } catch { Write-MigLog "  Owner add failed: $($ownerRow.UserEmail) — $_" -Level WARN }
            }

            # ── Add members ───────────────────────────────────────────────────
            $regularMembers = $srcMembers | Where-Object { $_.Role -eq 'Member' -and -not $_.IsGuest }
            foreach ($memberRow in $regularMembers) {
                $memberId = Resolve-TargetUserId -SourceEmail $memberRow.UserEmail
                if (-not $memberId) {
                    Write-MigLog "  Member not mapped: $($memberRow.UserEmail)" -Level WARN; continue
                }
                try {
                    Invoke-WithRetry {
                        New-MgGroupMember -GroupId $newGroupId `
                            -BodyParameter @{ '@odata.id' = "https://graph.microsoft.com/v1.0/users/$memberId" } `
                            -ErrorAction Stop
                    }
                    $membersAdded++
                } catch { Write-MigLog "  Member add failed: $($memberRow.UserEmail) — $_" -Level WARN }
            }

            # ── Collect guest entries for manual action ───────────────────────
            $guestMembers = $srcMembers | Where-Object { $_.IsGuest -eq $true -or $_.IsGuest -eq 'True' }
            foreach ($guest in $guestMembers) {
                $guestRows.Add([PSCustomObject]@{
                    TargetGroupEmail = $targetEmail
                    TargetGroupName  = $targetName
                    GuestEmail       = $guest.UserEmail
                    Role             = $guest.Role
                    Action           = 'MANUAL_REINVITE_REQUIRED'
                    Notes            = 'Guest users must be re-invited to the target tenant'
                })
            }

            # ── Provision as Team if required ─────────────────────────────────
            if ($isTeam) {
                Invoke-WithRetry {
                    New-MgTeam -GroupId $newGroupId -ErrorAction Stop | Out-Null
                }
                Write-MigLog "  Team provisioning started for $newGroupId — waiting..."

                $teamReady = Wait-ForTeamProvisioning `
                    -GroupId $newGroupId `
                    -TimeoutSeconds $TeamsProvisioningTimeoutSeconds

                if (-not $teamReady) {
                    Write-MigLog "  Team provisioning timed out — channels will be skipped. Re-run to retry." -Level WARN
                }
                else {
                    # ── Create channels ───────────────────────────────────────
                    $teamChannels = $channelIndex[$grp.PrimarySmtpAddress]
                    if ($teamChannels) {
                        foreach ($ch in $teamChannels) {

                            # General channel is auto-created — skip
                            if ($ch.IsGeneralChannel -eq $true -or $ch.IsGeneralChannel -eq 'True') { continue }

                            $isPrivateCh = $ch.MembershipType -eq 'private'
                            $isSharedCh  = $ch.MembershipType -eq 'shared'

                            if ($isSharedCh) {
                                Write-MigLog "  SKIPPED (shared channel): $($ch.ChannelDisplayName) — requires manual re-invitation" -Level WARN
                                continue
                            }

                            try {
                                $chBody = @{
                                    DisplayName    = $ch.ChannelDisplayName
                                    Description    = $ch.ChannelDescription
                                    MembershipType = if ($isPrivateCh) { 'private' } else { 'standard' }
                                }

                                $newChannel = Invoke-WithRetry {
                                    New-MgTeamChannel -TeamId $newGroupId `
                                                      -BodyParameter $chBody `
                                                      -ErrorAction Stop
                                }
                                $channelsAdded++
                                Write-MigLog "  CHANNEL: $($ch.ChannelDisplayName) ($($ch.MembershipType))"

                                # ── Private channel members ───────────────────
                                if ($isPrivateCh) {
                                    $privKey     = "$($grp.PrimarySmtpAddress)|$($ch.ChannelDisplayName)"
                                    $privMembers = $privChMemberIndex[$privKey]
                                    if ($privMembers) {
                                        foreach ($pm in ($privMembers | Where-Object {
                                            -not ($_.IsGuest -eq $true -or $_.IsGuest -eq 'True') })) {

                                            $pmId = Resolve-TargetUserId -SourceEmail $pm.MemberEmail
                                            if (-not $pmId) { continue }
                                            $pmRole = if ($pm.IsChannelOwner -eq $true) { 'owner' } else { 'member' }
                                            try {
                                                Invoke-WithRetry {
                                                    New-MgTeamChannelMember -TeamId $newGroupId `
                                                        -ChannelId $newChannel.Id `
                                                        -BodyParameter @{
                                                            '@odata.type' = '#microsoft.graph.aadUserConversationMember'
                                                            roles          = @($pmRole)
                                                            'user@odata.bind' = "https://graph.microsoft.com/v1.0/users/$pmId"
                                                        } -ErrorAction Stop | Out-Null
                                                }
                                            } catch {
                                                Write-MigLog "  Private ch member failed: $($pm.MemberEmail) — $_" -Level WARN
                                            }
                                        }

                                        # Guests in private channel → manual action list
                                        $privMembers | Where-Object { $_.IsGuest -eq $true -or $_.IsGuest -eq 'True' } |
                                        ForEach-Object {
                                            $guestRows.Add([PSCustomObject]@{
                                                TargetGroupEmail = $targetEmail
                                                TargetGroupName  = $targetName
                                                GuestEmail       = $_.MemberEmail
                                                Role             = if ($_.IsChannelOwner) { 'ChannelOwner' } else { 'ChannelMember' }
                                                Action           = 'MANUAL_REINVITE_REQUIRED'
                                                Notes            = "Private channel: $($ch.ChannelDisplayName)"
                                            })
                                        }
                                    }
                                }
                            }
                            catch {
                                Write-MigLog "  Channel creation failed: $($ch.ChannelDisplayName) — $_" -Level WARN
                            }
                        }
                    }
                }
            }

            $created++
            $resultRows.Add([PSCustomObject]@{
                SourceEmail   = $grp.PrimarySmtpAddress
                TargetEmail   = $targetEmail
                IsTeam        = $isTeam
                Action        = 'CREATED'
                OwnersAdded   = $ownersAdded
                MembersAdded  = $membersAdded
                ChannelsAdded = $channelsAdded
                GuestsSkipped = $guestMembers.Count
                WhatIf        = $false
                Notes         = if ($guestMembers.Count -gt 0) {
                    "$($guestMembers.Count) guest(s) require manual re-invitation" } else { '' }
            })
        }
        catch {
            $failed++
            Write-MigLog "  FAILED: $($grp.DisplayName) — $_" -Level ERROR
            $errorRows.Add([PSCustomObject]@{
                SourceEmail = $grp.PrimarySmtpAddress
                TargetName  = $targetName
                Error       = $_.Exception.Message
            })
        }
    }
    else {
        Write-MigLog "  WHATIF: Would create M365 Group '$targetName'"
        $resultRows.Add([PSCustomObject]@{
            SourceEmail = $grp.PrimarySmtpAddress; TargetEmail = $targetEmail
            IsTeam = $isTeam; Action = 'WHATIF'; OwnersAdded = 0
            MembersAdded = 0; ChannelsAdded = 0; GuestsSkipped = 0; WhatIf = $true; Notes = ''
        })
    }
}

Write-Progress -Activity 'Creating M365 Groups' -Completed

# ── Export ────────────────────────────────────────────────────────────────────

$resultRows | Export-CsvSafe -Path (Join-Path $outDir 'm365group_creation_results.csv')
if ($errorRows.Count -gt 0)  { $errorRows  | Export-CsvSafe -Path (Join-Path $outDir 'm365group_creation_errors.csv') }
if ($guestRows.Count -gt 0)  { $guestRows  | Export-CsvSafe -Path (Join-Path $outDir 'm365group_guest_actions_required.csv') }

Write-MigSummary -Stats @{
    'Total confirmed groups' = $total
    'Created'                = $created
    'Already existed'        = $existing
    'Failed'                 = $failed
    'Guests needing re-invite' = $guestRows.Count
    'WhatIf mode'            = $WhatIfPreference
    'Next script'            = 'New-SharePointSites.ps1'
}

if ($guestRows.Count -gt 0) {
    Write-MigLog "ACTION REQUIRED: $($guestRows.Count) guest(s) need manual re-invitation — see m365group_guest_actions_required.csv" -Level WARN
}

Disconnect-AllTenants
