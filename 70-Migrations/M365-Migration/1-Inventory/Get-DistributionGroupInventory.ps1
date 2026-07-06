#Requires -Version 5.1
#Requires -Modules ExchangeOnlineManagement
<#
.SYNOPSIS
    Exports distribution groups and mail-enabled security groups from the
    SOURCE tenant — including fully resolved owners AND members.

.DESCRIPTION
    Collects all distribution groups (standard, dynamic, mail-enabled
    security groups) with:

      OWNERS
        - ManagedBy is a list that can contain users OR nested groups
        - Each entry is resolved to a primary SMTP address
        - Nested groups are flagged (their own members are not recursed —
          that would require separate resolution in Phase 3)

      MEMBERS
        - Standard groups: direct members resolved to SMTP
        - Dynamic groups: RecipientFilter captured (no static member list)
        - Nested group members flagged for manual review

      OUTPUTS (per run)
        MigrationData\distribution_groups.csv         — one row per group
        MigrationData\distribution_group_owners.csv   — one row per owner entry
        MigrationData\distribution_group_members.csv  — one row per member entry
        MigrationData\distribution_group_errors.csv   — any collection errors

.PARAMETER SourceTenantId
    AAD Tenant ID or .onmicrosoft.com domain of the source tenant.

.PARAMETER SourceAdminUPN
    Source tenant admin UPN.

.PARAMETER SourceDomain
    Primary email domain of the source company. e.g. 'smartpulse.io'

.PARAMETER CompanySuffix
    Human-readable company name. e.g. 'SmartPulse'

.PARAMETER OutputPath
    Output folder. Default: .\MigrationData

.EXAMPLE
    .\Get-DistributionGroupInventory.ps1 `
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
Initialize-MigLog -ScriptName 'Get-DistributionGroupInventory' `
                  -LogDirectory (Join-Path $PSScriptRoot '..\Logs')
$outDir  = Ensure-OutputDirectory -Path $OutputPath
$domains = Get-MigrationDomains

# ── Connect ───────────────────────────────────────────────────────────────────

Connect-SourceTenant -TenantId $SourceTenantId -UserPrincipalName $SourceAdminUPN

# ── Helper: resolve an identity string to a primary SMTP address ──────────────
# ManagedBy / member entries can be:
#   - Display name          "John Smith"
#   - Alias                 "jsmith"
#   - SMTP                  "john@smartpulse.io"
#   - DN                    "CN=John Smith,OU=..."

function Resolve-ToSmtp {
    param([string] $Identity)
    if ([string]::IsNullOrWhiteSpace($Identity)) { return $null }
    try {
        $rec = Invoke-WithRetry {
            Get-Recipient -Identity $Identity -ErrorAction SilentlyContinue
        }
        return $rec?.PrimarySmtpAddress ?? $null
    }
    catch { return $null }
}

# ── Collect all groups ────────────────────────────────────────────────────────

Write-MigLog "Collecting standard distribution groups and mail-enabled security groups..."
$standardGroups = Invoke-WithRetry {
    Get-DistributionGroup -ResultSize Unlimited -ErrorAction Stop
}
Write-MigLog "  Standard / MESG: $($standardGroups.Count)"

Write-MigLog "Collecting dynamic distribution groups..."
$dynamicGroups = Invoke-WithRetry {
    Get-DynamicDistributionGroup -ResultSize Unlimited -ErrorAction Stop
}
Write-MigLog "  Dynamic: $($dynamicGroups.Count)"

# ── Processing ────────────────────────────────────────────────────────────────

$groupRows  = [System.Collections.Generic.List[PSCustomObject]]::new()
$ownerRows  = [System.Collections.Generic.List[PSCustomObject]]::new()
$memberRows = [System.Collections.Generic.List[PSCustomObject]]::new()
$errors     = [System.Collections.Generic.List[PSCustomObject]]::new()

$allGroups = @($standardGroups) + @($dynamicGroups)
$total     = $allGroups.Count
$i         = 0

foreach ($grp in $allGroups) {

    $i++
    Write-ProgressHelper -Activity 'Processing distribution groups' `
                         -Current $i -Total $total `
                         -Status $grp.PrimarySmtpAddress

    $isDynamic    = $grp.RecipientTypeDetails -eq 'DynamicDistributionGroup'
    $ownerEmails  = [System.Collections.Generic.List[string]]::new()
    $memberCount  = 0
    $memberEmails = [System.Collections.Generic.List[string]]::new()

    # ── OWNERS — resolve each ManagedBy entry ─────────────────────────────────
    foreach ($managedByEntry in $grp.ManagedBy) {

        $entryStr = $managedByEntry.ToString()
        if ([string]::IsNullOrWhiteSpace($entryStr)) { continue }

        $resolvedSmtp = Resolve-ToSmtp -Identity $entryStr
        $recipientType = ''
        $isGroup       = $false

        if ($resolvedSmtp) {
            # Determine whether owner is a user or a group
            try {
                $rec = Invoke-WithRetry {
                    Get-Recipient -Identity $resolvedSmtp -ErrorAction SilentlyContinue
                }
                $recipientType = $rec?.RecipientTypeDetails ?? ''
                $isGroup       = $recipientType -match 'Group|List'
            } catch {}

            $ownerEmails.Add($resolvedSmtp)

            $ownerRows.Add([PSCustomObject]@{
                GroupEmail         = $grp.PrimarySmtpAddress
                GroupDisplayName   = $grp.DisplayName
                GroupType          = $grp.RecipientTypeDetails
                OwnerEmail         = $resolvedSmtp
                OwnerRawIdentity   = $entryStr
                OwnerRecipientType = $recipientType
                IsNestedGroup      = $isGroup
                # Migration fields
                TargetGroupEmail   = ''
                TargetOwnerEmail   = ''
                AppliedAtTarget    = $false
                Notes              = if ($isGroup) {
                    'Nested group owner — resolve members separately in Phase 3' } else { '' }
            })
        }
        else {
            Write-MigLog "Could not resolve owner '$entryStr' for group $($grp.PrimarySmtpAddress)" -Level WARN
            $ownerRows.Add([PSCustomObject]@{
                GroupEmail         = $grp.PrimarySmtpAddress
                GroupDisplayName   = $grp.DisplayName
                GroupType          = $grp.RecipientTypeDetails
                OwnerEmail         = ''
                OwnerRawIdentity   = $entryStr
                OwnerRecipientType = 'UNRESOLVED'
                IsNestedGroup      = $false
                TargetGroupEmail   = ''
                TargetOwnerEmail   = ''
                AppliedAtTarget    = $false
                Notes              = 'Could not resolve to SMTP — manual review required'
            })
        }
    }

    # ── MEMBERS ───────────────────────────────────────────────────────────────

    if (-not $isDynamic) {
        try {
            $members = Invoke-WithRetry {
                Get-DistributionGroupMember -Identity $grp.PrimarySmtpAddress `
                    -ResultSize Unlimited -ErrorAction Stop
            }
            $memberCount = $members.Count

            foreach ($member in $members) {

                $memberSmtp    = $member.PrimarySmtpAddress
                $memberType    = $member.RecipientTypeDetails
                $isNestedGroup = $memberType -match 'Group|List'

                $memberEmails.Add($memberSmtp)

                $memberRows.Add([PSCustomObject]@{
                    GroupEmail         = $grp.PrimarySmtpAddress
                    GroupDisplayName   = $grp.DisplayName
                    GroupType          = $grp.RecipientTypeDetails
                    MemberEmail        = $memberSmtp
                    MemberDisplayName  = $member.DisplayName
                    MemberType         = $memberType
                    IsNestedGroup      = $isNestedGroup
                    # Migration fields
                    TargetGroupEmail   = ''
                    TargetMemberEmail  = ''
                    AddedAtTarget      = $false
                    Notes              = if ($isNestedGroup) {
                        'Nested group member — ensure target group exists before adding' } else { '' }
                })
            }
        }
        catch {
            Write-MigLog "Member collection failed for $($grp.PrimarySmtpAddress): $_" -Level ERROR
            $errors.Add([PSCustomObject]@{
                GroupEmail = $grp.PrimarySmtpAddress
                Stage      = 'MemberCollection'
                Error      = $_.Exception.Message
            })
        }
    }

    # ── Group summary row ─────────────────────────────────────────────────────

    $allProxies          = ($grp.EmailAddresses | Where-Object { $_ -notmatch '^x500:' }) -join '|'
    $suggestedTargetName = "$($grp.DisplayName) $($domains.CompanySuffix)"

    $groupRows.Add([PSCustomObject]@{

        # Identity
        PrimarySmtpAddress                 = $grp.PrimarySmtpAddress
        DisplayName                        = $grp.DisplayName
        Alias                              = $grp.Alias
        AllProxyAddresses                  = $allProxies
        RecipientTypeDetails               = $grp.RecipientTypeDetails
        IsDynamic                          = $isDynamic

        # Configuration
        HiddenFromAddressListsEnabled      = $grp.HiddenFromAddressListsEnabled
        RequireSenderAuthenticationEnabled = $grp.RequireSenderAuthenticationEnabled
        MemberJoinRestriction              = if ($isDynamic) { '' } else { $grp.MemberJoinRestriction }
        MemberDepartRestriction            = if ($isDynamic) { '' } else { $grp.MemberDepartRestriction }
        AcceptMessagesOnlyFrom             = ($grp.AcceptMessagesOnlyFrom -join '|')
        BypassModerationFromSendersOrMembers = ($grp.BypassModerationFromSendersOrMembers -join '|')

        # Dynamic filter (manual review needed for translation at target)
        RecipientFilter                    = if ($isDynamic) { $grp.RecipientFilter } else { '' }

        # Ownership & membership counts
        OwnerCount                         = $ownerEmails.Count
        OwnerEmails                        = ($ownerEmails | Join-String -Separator '|')
        MemberCount                        = $memberCount
        HasNestedGroups                    = ($memberRows | Where-Object {
            $_.GroupEmail -eq $grp.PrimarySmtpAddress -and $_.IsNestedGroup -eq $true }).Count -gt 0

        # Suggested target (for review in New-SharedMailboxMapping.ps1)
        SuggestedTargetName                = $suggestedTargetName
        SuggestedTargetAlias               = "$($grp.Alias)$($domains.CompanySuffix.ToLower())"

        # Migration fields
        TargetEmail                        = ''
        TargetDisplayName                  = ''
        TargetAADObjectId                  = ''
        MigrationBatch                     = ''
        MigrationStatus                    = 'PENDING'
        Notes                              = ''
    })
}

Write-Progress -Activity 'Processing distribution groups' -Completed

# ── Export ────────────────────────────────────────────────────────────────────

$grpPath    = Join-Path $outDir 'distribution_groups.csv'
$ownerPath  = Join-Path $outDir 'distribution_group_owners.csv'
$memberPath = Join-Path $outDir 'distribution_group_members.csv'

$groupRows  | Export-CsvSafe -Path $grpPath
$ownerRows  | Export-CsvSafe -Path $ownerPath
$memberRows | Export-CsvSafe -Path $memberPath

if ($errors.Count -gt 0) {
    $errors | Export-CsvSafe -Path (Join-Path $outDir 'distribution_group_errors.csv')
}

# ── Summary ───────────────────────────────────────────────────────────────────

$nestedMemberGroups = ($groupRows | Where-Object { $_.HasNestedGroups -eq $true }).Count
$unresolvedOwners   = ($ownerRows | Where-Object { $_.OwnerRecipientType -eq 'UNRESOLVED' }).Count
$nestedOwners       = ($ownerRows | Where-Object { $_.IsNestedGroup -eq $true }).Count

Write-MigSummary -Stats @{
    'Total groups'              = $groupRows.Count
    'Standard / MESG'          = ($groupRows | Where-Object { -not $_.IsDynamic }).Count
    'Dynamic groups'           = ($groupRows | Where-Object { $_.IsDynamic -eq $true }).Count
    'Total owner rows'         = $ownerRows.Count
    'Unresolved owners'        = $unresolvedOwners
    'Nested group owners'      = $nestedOwners
    'Total member rows'        = $memberRows.Count
    'Groups with nested members' = $nestedMemberGroups
    'Errors'                   = $errors.Count
    'Groups output'            = $grpPath
    'Owners output'            = $ownerPath
    'Members output'           = $memberPath
}

Disconnect-AllTenants
