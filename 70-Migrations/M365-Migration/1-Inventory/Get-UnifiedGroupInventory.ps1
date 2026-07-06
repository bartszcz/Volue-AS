#Requires -Version 5.1
#Requires -Modules ExchangeOnlineManagement, Microsoft.Graph.Groups, Microsoft.Graph.Teams
<#
.SYNOPSIS
    Exports Microsoft 365 Groups and Teams from the SOURCE tenant —
    including owners, members, private channel members, and guest users.

.DESCRIPTION
    Collects all M365 Groups with:

      GROUP LEVEL
        - Owners (role = Owner)
        - Members (role = Member)
        - Guest members flagged separately (they need special handling
          cross-tenant — guests from source won't exist in target)

      TEAMS LEVEL (for groups backing a Team)
        - Standard channels
        - Private channels + their own member lists
          (private channels have independent membership from the Team)
        - Shared channels (flagged — cross-tenant shared channels
          require separate re-invitation at target)

      OUTPUTS
        MigrationData\unified_groups.csv            — one row per group
        MigrationData\unified_group_members.csv     — owners + members for all groups
        MigrationData\teams_channels.csv            — all channels per Team
        MigrationData\teams_private_channel_members.csv
            — private channel members (separate from team membership)
        MigrationData\unified_group_guests.csv
            — guest members requiring manual re-invitation at target

.PARAMETER SourceTenantId
    AAD Tenant ID of the source tenant.

.PARAMETER SourceAdminUPN
    Source tenant admin UPN.

.PARAMETER SourceDomain
    Primary email domain of the source company. e.g. 'smartpulse.io'

.PARAMETER CompanySuffix
    Human-readable company name. e.g. 'SmartPulse'

.PARAMETER OutputPath
    Output folder. Default: .\MigrationData

.EXAMPLE
    .\Get-UnifiedGroupInventory.ps1 `
        -SourceTenantId 'balancingpoolcom.onmicrosoft.com' `
        -SourceAdminUPN 'admin@smartpulse.io' `
        -SourceDomain   'smartpulse.io' `
        -CompanySuffix  'SmartPulse'
#>

[CmdletBinding()]
param(
    [string] $SourceTenantId = '',
    [string] $SourceAdminUPN = '',
    [string] $SourceDomain = '',
    [string] $CompanySuffix = '',
    [string] $OutputPath = '.\MigrationData'
)

# ── Bootstrap ─────────────────────────────────────────────────────────────────

Import-Module (Join-Path $PSScriptRoot '..\MigrationHelpers.psm1') -Force -ErrorAction Stop

# ── Load MigrationConfig.psd1 ────────────────────────────────────────────────
$_cfg = Import-MigrationConfig
$SourceTenantId = Resolve-ConfigParam -Passed $SourceTenantId -Default '' -ConfigValue (Get-ConfigValue -Config $_cfg -Key "SourceTenantId")
$SourceAdminUPN = Resolve-ConfigParam -Passed $SourceAdminUPN -Default '' -ConfigValue (Get-ConfigValue -Config $_cfg -Key "SourceAdminUPN")
$SourceDomain = Resolve-ConfigParam -Passed $SourceDomain -Default '' -ConfigValue (Get-ConfigValue -Config $_cfg -Key "SourceDomain")
$CompanySuffix = Resolve-ConfigParam -Passed $CompanySuffix -Default '' -ConfigValue (Get-ConfigValue -Config $_cfg -Key "CompanySuffix")
$OutputPath = Resolve-ConfigParam -Passed $OutputPath -Default '' -ConfigValue (Get-ConfigValue -Config $_cfg -Key "OutputPath")

# ── Validate that required values were supplied (via config or command line) ──
$_missingParams = @()
foreach ($__p in @(
    @{ Name='SourceDomain';    Value=$SourceDomain    }
    @{ Name='SourceAdminUPN'; Value=$SourceAdminUPN }
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
Initialize-MigLog -ScriptName 'Get-UnifiedGroupInventory' `
                  -LogDirectory (Join-Path $PSScriptRoot '..\Logs')
$outDir  = Ensure-OutputDirectory -Path $OutputPath
$domains = Get-MigrationDomains

# ── Connect ───────────────────────────────────────────────────────────────────

Connect-SourceTenant -TenantId $SourceTenantId -UserPrincipalName $SourceAdminUPN

# ── Retrieve all M365 Groups ──────────────────────────────────────────────────

Write-MigLog "Retrieving M365 Groups..."
$m365Groups = Invoke-WithRetry {
    Get-MgGroup -All `
        -Filter "groupTypes/any(c:c eq 'Unified')" `
        -Property 'Id,DisplayName,Mail,MailNickname,Description,Visibility,CreatedDateTime,ResourceProvisioningOptions' `
        -ErrorAction Stop
}
Write-MigLog "M365 Groups found: $($m365Groups.Count)"

# Get EXO side for proxy addresses + SPO URL
Write-MigLog "Retrieving Exchange-side unified group details..."
$exoGroups = Invoke-WithRetry {
    Get-UnifiedGroup -ResultSize Unlimited -ErrorAction Stop
}
$exoIndex = @{}
foreach ($g in $exoGroups) { $exoIndex[$g.ExternalDirectoryObjectId] = $g }

# ── Output collections ────────────────────────────────────────────────────────

$groupRows          = [System.Collections.Generic.List[PSCustomObject]]::new()
$memberRows         = [System.Collections.Generic.List[PSCustomObject]]::new()
$channelRows        = [System.Collections.Generic.List[PSCustomObject]]::new()
$privChannelMembers = [System.Collections.Generic.List[PSCustomObject]]::new()
$guestRows          = [System.Collections.Generic.List[PSCustomObject]]::new()

$total = $m365Groups.Count
$i     = 0

foreach ($grp in $m365Groups) {

    $i++
    Write-ProgressHelper -Activity 'Processing M365 Groups' `
                         -Current $i -Total $total `
                         -Status $grp.DisplayName

    $isTeam      = $grp.ResourceProvisioningOptions -contains 'Team'
    $exoGrp      = $exoIndex[$grp.Id]
    $primarySmtp = $exoGrp?.PrimarySmtpAddress ?? $grp.Mail ?? ''
    $allProxies  = ($exoGrp?.EmailAddresses | Where-Object { $_ -notmatch '^x500:' }) -join '|'
    $spoUrl      = $exoGrp?.SharePointSiteUrl ?? ''

    $ownerList  = [System.Collections.Generic.List[string]]::new()
    $memberList = [System.Collections.Generic.List[string]]::new()
    $guestCount = 0

    # ── OWNERS ────────────────────────────────────────────────────────────────
    try {
        $ownerObjs = Invoke-WithRetry {
            Get-MgGroupOwner -GroupId $grp.Id -All -ErrorAction Stop
        }
        foreach ($o in $ownerObjs) {
            $upn         = $o.AdditionalProperties['userPrincipalName'] ?? ''
            $displayName = $o.AdditionalProperties['displayName'] ?? ''
            $userType    = $o.AdditionalProperties['userType'] ?? 'Member'
            $isGuest     = $userType -eq 'Guest'

            $ownerList.Add($upn)

            $memberRows.Add([PSCustomObject]@{
                GroupId           = $grp.Id
                GroupEmail        = $primarySmtp
                GroupDisplayName  = $grp.DisplayName
                UserEmail         = $upn
                UserDisplayName   = $displayName
                UserType          = $userType
                Role              = 'Owner'
                IsGuest           = $isGuest
                TargetGroupEmail  = ''
                TargetUserEmail   = ''
                AppliedAtTarget   = $false
                Notes             = if ($isGuest) { 'Guest — requires re-invitation at target' } else { '' }
            })

            if ($isGuest) {
                $guestCount++
                $guestRows.Add([PSCustomObject]@{
                    GroupId          = $grp.Id
                    GroupEmail       = $primarySmtp
                    GroupDisplayName = $grp.DisplayName
                    GuestEmail       = $upn
                    GuestDisplayName = $displayName
                    Role             = 'Owner'
                    SourceContext    = 'GroupOwner'
                    Notes            = 'Must be re-invited to target tenant'
                })
            }
        }
    }
    catch {
        Write-MigLog "Owner collection failed for $($grp.DisplayName): $_" -Level WARN
    }

    # ── MEMBERS ───────────────────────────────────────────────────────────────
    try {
        $memberObjs = Invoke-WithRetry {
            Get-MgGroupMember -GroupId $grp.Id -All -ErrorAction Stop
        }
        foreach ($m in $memberObjs) {
            $upn         = $m.AdditionalProperties['userPrincipalName'] ?? ''
            $displayName = $m.AdditionalProperties['displayName'] ?? ''
            $userType    = $m.AdditionalProperties['userType'] ?? 'Member'
            $isGuest     = $userType -eq 'Guest'
            $odataType   = $m.AdditionalProperties['@odata.type'] ?? ''
            $isGroup     = $odataType -match 'group'

            # Skip if already captured as owner
            if ($ownerList -contains $upn) { continue }

            $memberList.Add($upn)

            $memberRows.Add([PSCustomObject]@{
                GroupId           = $grp.Id
                GroupEmail        = $primarySmtp
                GroupDisplayName  = $grp.DisplayName
                UserEmail         = $upn
                UserDisplayName   = $displayName
                UserType          = $userType
                Role              = if ($isGroup) { 'NestedGroup' } else { 'Member' }
                IsGuest           = $isGuest
                TargetGroupEmail  = ''
                TargetUserEmail   = ''
                AppliedAtTarget   = $false
                Notes             = if ($isGuest) { 'Guest — requires re-invitation at target' }
                                    elseif ($isGroup) { 'Nested group — ensure target group exists first' }
                                    else { '' }
            })

            if ($isGuest) {
                $guestCount++
                $guestRows.Add([PSCustomObject]@{
                    GroupId          = $grp.Id
                    GroupEmail       = $primarySmtp
                    GroupDisplayName = $grp.DisplayName
                    GuestEmail       = $upn
                    GuestDisplayName = $displayName
                    Role             = 'Member'
                    SourceContext    = 'GroupMember'
                    Notes            = 'Must be re-invited to target tenant'
                })
            }
        }
    }
    catch {
        Write-MigLog "Member collection failed for $($grp.DisplayName): $_" -Level WARN
    }

    # ── TEAMS CHANNELS ────────────────────────────────────────────────────────

    $channelCount        = 0
    $privateChannelCount = 0
    $sharedChannelCount  = 0

    if ($isTeam) {
        try {
            $channels = Invoke-WithRetry {
                Get-MgTeamChannel -TeamId $grp.Id -All -ErrorAction Stop
            }

            foreach ($ch in $channels) {

                $channelCount++
                $isPrivate = $ch.MembershipType -eq 'private'
                $isShared  = $ch.MembershipType -eq 'shared'

                if ($isPrivate)  { $privateChannelCount++ }
                if ($isShared)   { $sharedChannelCount++ }

                $channelRows.Add([PSCustomObject]@{
                    TeamId             = $grp.Id
                    TeamEmail          = $primarySmtp
                    TeamDisplayName    = $grp.DisplayName
                    ChannelId          = $ch.Id
                    ChannelDisplayName = $ch.DisplayName
                    ChannelDescription = $ch.Description
                    MembershipType     = $ch.MembershipType   # standard | private | shared
                    IsGeneralChannel   = ($ch.DisplayName -eq 'General')
                    HasOwnSPOSite      = $isPrivate            # private channels have own SPO site
                    WebUrl             = $ch.WebUrl
                    TargetTeamEmail    = ''
                    CreatedAtTarget    = $false
                    Notes              = if ($isShared) {
                        'Shared channel — cross-tenant re-invitation required at target' }
                                        elseif ($isPrivate) {
                        'Private channel — has own SPO site, collect members separately' }
                                        else { '' }
                })

                # ── PRIVATE CHANNEL MEMBERS (separate membership from Team) ──
                if ($isPrivate) {
                    try {
                        $chMembers = Invoke-WithRetry {
                            Get-MgTeamChannelMember -TeamId $grp.Id `
                                                    -ChannelId $ch.Id `
                                                    -All -ErrorAction Stop
                        }

                        foreach ($cm in $chMembers) {
                            $cmUpn    = $cm.AdditionalProperties['email'] ?? ''
                            $cmName   = $cm.DisplayName ?? ''
                            $cmRoles  = ($cm.Roles -join '|')
                            $isOwner  = $cm.Roles -contains 'owner'
                            $isGuest  = $cmUpn -notmatch [regex]::Escape($domains.SourceDomain)

                            $privChannelMembers.Add([PSCustomObject]@{
                                TeamId             = $grp.Id
                                TeamEmail          = $primarySmtp
                                TeamDisplayName    = $grp.DisplayName
                                ChannelId          = $ch.Id
                                ChannelDisplayName = $ch.DisplayName
                                MemberEmail        = $cmUpn
                                MemberDisplayName  = $cmName
                                Roles              = $cmRoles
                                IsChannelOwner     = $isOwner
                                IsGuest            = $isGuest
                                TargetTeamEmail    = ''
                                TargetMemberEmail  = ''
                                AppliedAtTarget    = $false
                                Notes              = if ($isGuest) {
                                    'External/guest — re-invitation required at target' } else { '' }
                            })

                            if ($isGuest) {
                                $guestRows.Add([PSCustomObject]@{
                                    GroupId          = $grp.Id
                                    GroupEmail       = $primarySmtp
                                    GroupDisplayName = $grp.DisplayName
                                    GuestEmail       = $cmUpn
                                    GuestDisplayName = $cmName
                                    Role             = if ($isOwner) { 'ChannelOwner' } else { 'ChannelMember' }
                                    SourceContext    = "PrivateChannel:$($ch.DisplayName)"
                                    Notes            = 'Must be re-invited to target tenant'
                                })
                            }
                        }
                    }
                    catch {
                        Write-MigLog "Private channel member collection failed — Team: $($grp.DisplayName) Channel: $($ch.DisplayName): $_" -Level WARN
                    }
                }
            }
        }
        catch {
            Write-MigLog "Channel collection failed for $($grp.DisplayName): $_" -Level WARN
        }
    }

    # ── Group summary row ─────────────────────────────────────────────────────

    $suggestedTargetName  = "$($grp.DisplayName) $($domains.CompanySuffix)"
    $suggestedTargetAlias = "$($grp.MailNickname)$($domains.CompanySuffix.ToLower())"
    $suggestedTargetEmail = "$suggestedTargetAlias@$($domains.TargetDomain)"

    $groupRows.Add([PSCustomObject]@{

        GroupId               = $grp.Id
        PrimarySmtpAddress    = $primarySmtp
        DisplayName           = $grp.DisplayName
        MailNickname          = $grp.MailNickname
        Description           = $grp.Description
        AllProxyAddresses     = $allProxies
        Visibility            = $grp.Visibility
        CreatedDateTime       = $grp.CreatedDateTime
        SharePointSiteUrl     = $spoUrl
        IsTeam                = $isTeam

        OwnerCount            = $ownerList.Count
        MemberCount           = $memberList.Count
        GuestCount            = $guestCount
        ChannelCount          = $channelCount
        PrivateChannelCount   = $privateChannelCount
        SharedChannelCount    = $sharedChannelCount

        OwnerEmails           = ($ownerList | Join-String -Separator '|')

        SuggestedTargetName   = $suggestedTargetName
        SuggestedTargetAlias  = $suggestedTargetAlias
        SuggestedTargetEmail  = $suggestedTargetEmail

        TargetGroupId         = ''
        TargetEmail           = ''
        TargetDisplayName     = ''
        MigrationBatch        = ''
        MigrationStatus       = 'PENDING'
        SharegateMigrated     = $false
        Notes                 = if ($guestCount -gt 0) {
            "$guestCount guest(s) require re-invitation at target" } else { '' }
    })
}

Write-Progress -Activity 'Processing M365 Groups' -Completed

# ── Export ────────────────────────────────────────────────────────────────────

$groupRows          | Export-CsvSafe -Path (Join-Path $outDir 'unified_groups.csv')
$memberRows         | Export-CsvSafe -Path (Join-Path $outDir 'unified_group_members.csv')
$channelRows        | Export-CsvSafe -Path (Join-Path $outDir 'teams_channels.csv')

if ($privChannelMembers.Count -gt 0) {
    $privChannelMembers | Export-CsvSafe -Path (Join-Path $outDir 'teams_private_channel_members.csv')
}
if ($guestRows.Count -gt 0) {
    $guestRows | Export-CsvSafe -Path (Join-Path $outDir 'unified_group_guests.csv')
}

# ── Summary ───────────────────────────────────────────────────────────────────

Write-MigSummary -Stats @{
    'Total M365 Groups'             = $groupRows.Count
    'Groups backing a Team'         = ($groupRows | Where-Object { $_.IsTeam -eq $true }).Count
    'Total owner/member rows'       = $memberRows.Count
    'Guest members (all groups)'    = $guestRows.Count
    'Total channels'                = $channelRows.Count
    'Private channels'              = ($channelRows | Where-Object { $_.MembershipType -eq 'private' }).Count
    'Shared channels'               = ($channelRows | Where-Object { $_.MembershipType -eq 'shared' }).Count
    'Private channel member rows'   = $privChannelMembers.Count
    'Next script'                   = 'Get-SharePointInventory.ps1'
}

Disconnect-AllTenants
