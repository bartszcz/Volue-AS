#Requires -Version 5.1
#Requires -Modules ExchangeOnlineManagement
<#
.SYNOPSIS
    Creates distribution groups and mail-enabled security groups in the
    TARGET tenant, then adds owners and members using the confirmed mapping.

.DESCRIPTION
    Reads dl_mapping.csv (CONFIRMED rows) and creates each group in the
    Volue Exchange Online tenant. After creation, populates:
        - ManagedBy (owners) — resolved via user_mapping_confirmed.csv
        - Members            — resolved via distribution_group_members.csv
                               and user_mapping_confirmed.csv

    DYNAMIC GROUPS
        RecipientFilter from source is captured but usually cannot be
        applied directly (attribute names differ between tenants).
        Dynamic groups are created as standard DLs with a placeholder
        filter; the Notes column will flag them for manual filter update.

    NESTED GROUP MEMBERS
        If a member row is flagged IsNestedGroup=True, the script attempts
        to add the mapped target group. If the target group doesn't exist
        yet the row is deferred and logged for manual follow-up.

    IDEMPOTENT — existing groups are validated and skipped.

    OUTPUTS
        MigrationData\dl_creation_results.csv
        MigrationData\dl_creation_errors.csv
        MigrationData\dl_member_deferred.csv   (nested groups not yet created)

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

.PARAMETER DLOwnersCsv
    DL owners from Phase 1. Default: .\MigrationData\distribution_group_owners.csv

.PARAMETER DLMembersCsv
    DL members from Phase 1. Default: .\MigrationData\distribution_group_members.csv

.PARAMETER UserMappingCsv
    Confirmed user mapping for resolving source emails to target.
    Default: .\MigrationData\user_mapping_confirmed.csv

.PARAMETER WhatIf
    Show what would be created without making changes.

.PARAMETER OutputPath
    Output folder. Default: .\MigrationData

.EXAMPLE
    .\New-DistributionGroups.ps1 `
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
    [string] $DLMappingCsv   = '.\MigrationData\dl_mapping.csv',
    [string] $DLOwnersCsv    = '.\MigrationData\distribution_group_owners.csv',
    [string] $DLMembersCsv   = '.\MigrationData\distribution_group_members.csv',
    [string] $UserMappingCsv = '.\MigrationData\user_mapping_confirmed.csv',
    [string] $OutputPath     = '.\MigrationData'
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
$DLMappingCsv = Resolve-ConfigParam -Passed $DLMappingCsv -Default '' -ConfigValue (Get-ConfigValue -Config $_cfg -Key "DLMappingCsv")
$DLMembersCsv = Resolve-ConfigParam -Passed $DLMembersCsv -Default '' -ConfigValue (Get-ConfigValue -Config $_cfg -Key "DLMembersCsv")
$DLOwnersCsv = Resolve-ConfigParam -Passed $DLOwnersCsv -Default '' -ConfigValue (Get-ConfigValue -Config $_cfg -Key "DLOwnersCsv")
$OutputPath = Resolve-ConfigParam -Passed $OutputPath -Default '' -ConfigValue (Get-ConfigValue -Config $_cfg -Key "OutputPath")

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
Initialize-MigLog -ScriptName 'New-DistributionGroups' `
                  -LogDirectory (Join-Path $PSScriptRoot '..\Logs')
$outDir = Ensure-OutputDirectory -Path $OutputPath

# ── Load all inputs ───────────────────────────────────────────────────────────

$dlMapping     = Import-CsvSafe -Path $DLMappingCsv `
    -RequiredColumns @('SourceEmail','TargetEmail','TargetDisplayName','Status')
$confirmedDLs  = $dlMapping | Where-Object { $_.Status -eq 'CONFIRMED' }
Write-MigLog "Confirmed DLs to create: $($confirmedDLs.Count)"

Import-UserMapping -Path $UserMappingCsv -ConfirmedOnly

# Build source DL → owners index
$ownerIndex = @{}
if (Test-Path $DLOwnersCsv) {
    $ownerRows = Import-CsvSafe -Path $DLOwnersCsv
    foreach ($r in $ownerRows) {
        if (-not $ownerIndex.ContainsKey($r.GroupEmail)) {
            $ownerIndex[$r.GroupEmail] = [System.Collections.Generic.List[PSCustomObject]]::new()
        }
        $ownerIndex[$r.GroupEmail].Add($r)
    }
}
else { Write-MigLog "DL owners file not found — groups will be created without ManagedBy" -Level WARN }

# Build source DL → members index
$memberIndex = @{}
if (Test-Path $DLMembersCsv) {
    $memberRows = Import-CsvSafe -Path $DLMembersCsv
    foreach ($r in $memberRows) {
        if (-not $memberIndex.ContainsKey($r.GroupEmail)) {
            $memberIndex[$r.GroupEmail] = [System.Collections.Generic.List[PSCustomObject]]::new()
        }
        $memberIndex[$r.GroupEmail].Add($r)
    }
}
else { Write-MigLog "DL members file not found — groups will be created without members" -Level WARN }

# ── Connect ───────────────────────────────────────────────────────────────────

Connect-TargetTenant -TenantId $TargetTenantId -UserPrincipalName $TargetAdminUPN

$existingGroups = Invoke-WithRetry {
    Get-DistributionGroup -ResultSize Unlimited -ErrorAction Stop
}
$existingIndex = @{}
foreach ($g in $existingGroups) {
    $existingIndex[$g.PrimarySmtpAddress.ToLower()] = $g
}
Write-MigLog "Existing target DLs: $($existingIndex.Count)"

# ── Creation loop ─────────────────────────────────────────────────────────────

$resultRows  = [System.Collections.Generic.List[PSCustomObject]]::new()
$errorRows   = [System.Collections.Generic.List[PSCustomObject]]::new()
$deferredRows = [System.Collections.Generic.List[PSCustomObject]]::new()

$created  = 0; $existing = 0; $failed = 0
$total    = $confirmedDLs.Count; $i = 0

foreach ($dl in $confirmedDLs) {

    $i++
    Write-ProgressHelper -Activity 'Creating distribution groups' `
                         -Current $i -Total $total `
                         -Status $dl.TargetEmail

    $targetEmail = $dl.TargetEmail.ToLower()
    $targetName  = $dl.TargetDisplayName
    $targetAlias = $dl.TargetAlias ?? ($targetEmail -split '@')[0]
    $isDynamic   = $dl.IsDynamic -eq $true -or $dl.IsDynamic -eq 'True'
    $requireAuth = $dl.RequireSenderAuth -eq $true -or $dl.RequireSenderAuth -eq 'True'
    $hideFromGAL = $dl.HiddenFromGAL -eq $true -or $dl.HiddenFromGAL -eq 'True'

    # ── Idempotency ───────────────────────────────────────────────────────────
    if ($existingIndex.ContainsKey($targetEmail)) {
        $existing++
        Write-MigLog "  EXISTS: $targetEmail"
        $resultRows.Add([PSCustomObject]@{
            SourceEmail = $dl.SourceEmail; TargetEmail = $targetEmail
            Action = 'ALREADY_EXISTS'; MembersAdded = 0; OwnersAdded = 0
            WhatIf = $false; Notes = 'Group already existed'
        })
        continue
    }

    if ($PSCmdlet.ShouldProcess($targetEmail, "Create DL '$targetName'")) {
        try {
            # Create — dynamic groups become standard DLs (filter translated manually)
            $newGrp = Invoke-WithRetry {
                New-DistributionGroup -Name        $targetName `
                                      -DisplayName $targetName `
                                      -Alias       $targetAlias `
                                      -PrimarySmtpAddress $targetEmail `
                                      -RequireSenderAuthenticationEnabled $requireAuth `
                                      -ErrorAction Stop
            }
            Write-MigLog "  CREATED: $targetEmail"

            if ($hideFromGAL) {
                Invoke-WithRetry {
                    Set-DistributionGroup -Identity $targetEmail `
                                          -HiddenFromAddressListsEnabled $true -ErrorAction Stop
                }
            }

            # ── Set owners (ManagedBy) ────────────────────────────────────────
            $ownersAdded   = 0
            $managedByList = [System.Collections.Generic.List[string]]::new()

            $srcOwners = $ownerIndex[$dl.SourceEmail]
            if ($srcOwners) {
                foreach ($owner in $srcOwners) {
                    if ($owner.IsNestedGroup -eq $true -or $owner.IsNestedGroup -eq 'True') {
                        # Nested group owner — try to find mapped target group
                        $targetGroupEmail = Get-MappedEmail -SourceEmail $owner.OwnerEmail
                        if ($targetGroupEmail) { $managedByList.Add($targetGroupEmail) }
                        else {
                            Write-MigLog "  Nested group owner '$($owner.OwnerEmail)' not mapped — skipped" -Level WARN
                        }
                    }
                    else {
                        $targetOwnerEmail = Get-MappedEmail -SourceEmail $owner.OwnerEmail
                        if ($targetOwnerEmail) {
                            $managedByList.Add($targetOwnerEmail)
                            $ownersAdded++
                        }
                        else {
                            Write-MigLog "  Owner '$($owner.OwnerEmail)' not in user mapping — skipped" -Level WARN
                        }
                    }
                }

                if ($managedByList.Count -gt 0) {
                    Invoke-WithRetry {
                        Set-DistributionGroup -Identity  $targetEmail `
                                              -ManagedBy $managedByList.ToArray() `
                                              -ErrorAction Stop
                    }
                }
            }

            # ── Add members ───────────────────────────────────────────────────
            $membersAdded = 0
            $srcMembers   = $memberIndex[$dl.SourceEmail]

            if ($srcMembers -and -not $isDynamic) {
                foreach ($member in $srcMembers) {

                    $isNested = $member.IsNestedGroup -eq $true -or $member.IsNestedGroup -eq 'True'

                    if ($isNested) {
                        # Nested group member — try to find mapped target group
                        $targetMemberEmail = Get-MappedEmail -SourceEmail $member.MemberEmail
                        if (-not $targetMemberEmail) {
                            $deferredRows.Add([PSCustomObject]@{
                                GroupEmail     = $targetEmail
                                MemberEmail    = $member.MemberEmail
                                Reason         = 'Nested group member — target group may not exist yet'
                            })
                            continue
                        }
                    }
                    else {
                        $targetMemberEmail = Get-MappedEmail -SourceEmail $member.MemberEmail
                    }

                    if (-not $targetMemberEmail) {
                        Write-MigLog "  Member '$($member.MemberEmail)' not in user mapping — skipped" -Level WARN
                        continue
                    }

                    try {
                        Invoke-WithRetry {
                            Add-DistributionGroupMember -Identity $targetEmail `
                                                        -Member   $targetMemberEmail `
                                                        -ErrorAction Stop
                        }
                        $membersAdded++
                    }
                    catch {
                        Write-MigLog "  Member add failed: $targetMemberEmail → $targetEmail — $_" -Level WARN
                    }
                }
            }

            $created++
            Write-MigLog "  $targetEmail — $ownersAdded owners | $membersAdded members"

            $resultRows.Add([PSCustomObject]@{
                SourceEmail  = $dl.SourceEmail
                TargetEmail  = $targetEmail
                Action       = 'CREATED'
                MembersAdded = $membersAdded
                OwnersAdded  = $ownersAdded
                IsDynamic    = $isDynamic
                WhatIf       = $false
                Notes        = if ($isDynamic) { 'Dynamic DL created as standard — update RecipientFilter manually' } else { '' }
            })
        }
        catch {
            $failed++
            Write-MigLog "  FAILED: $targetEmail — $_" -Level ERROR
            $errorRows.Add([PSCustomObject]@{
                SourceEmail = $dl.SourceEmail
                TargetEmail = $targetEmail
                Error       = $_.Exception.Message
            })
        }
    }
    else {
        Write-MigLog "  WHATIF: Would create DL '$targetName' <$targetEmail>"
        $resultRows.Add([PSCustomObject]@{
            SourceEmail = $dl.SourceEmail; TargetEmail = $targetEmail
            Action = 'WHATIF'; MembersAdded = 0; OwnersAdded = 0
            WhatIf = $true; Notes = ''
        })
    }
}

Write-Progress -Activity 'Creating distribution groups' -Completed

# ── Export ────────────────────────────────────────────────────────────────────

$resultRows  | Export-CsvSafe -Path (Join-Path $outDir 'dl_creation_results.csv')
if ($errorRows.Count -gt 0)   { $errorRows   | Export-CsvSafe -Path (Join-Path $outDir 'dl_creation_errors.csv') }
if ($deferredRows.Count -gt 0) { $deferredRows | Export-CsvSafe -Path (Join-Path $outDir 'dl_member_deferred.csv') }

Write-MigSummary -Stats @{
    'Total confirmed DLs' = $total
    'Created'             = $created
    'Already existed'     = $existing
    'Failed'              = $failed
    'Deferred members'    = $deferredRows.Count
    'WhatIf mode'         = $WhatIfPreference
    'Next script'         = 'New-M365GroupsAndTeams.ps1'
}

Disconnect-AllTenants
