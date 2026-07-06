#Requires -Version 5.1
#Requires -Modules ExchangeOnlineManagement
<#
.SYNOPSIS
    Exports all mailbox permissions from the SOURCE tenant.

.DESCRIPTION
    Collects Full Access, Send As, and Send on Behalf permissions for every
    mailbox. These are critical to re-apply after Code2 migration completes.

    Both the mailbox owner and each trustee must have entries in user_mapping.csv
    before Phase 3 scripts can re-apply permissions at the target.

    Outputs:
        MigrationData\mailbox_permissions.csv   — one row per permission entry
        MigrationData\mailbox_permissions_unmapped_trustees.csv
            — trustees not found in the mailbox inventory (guest accounts,
              service accounts, deleted users) — requires manual review

.PARAMETER SourceTenantId
    AAD Tenant ID or .onmicrosoft.com domain of the source tenant.

.PARAMETER SourceAdminUPN
    Source tenant admin UPN.

.PARAMETER SourceDomain
    Primary email domain of the source company. e.g. 'smartpulse.io'

.PARAMETER CompanySuffix
    Human-readable company name. e.g. 'SmartPulse'

.PARAMETER MailboxCsv
    Path to mailboxes.csv from Get-MailboxInventory.ps1
    Default: .\MigrationData\mailboxes.csv

.PARAMETER OutputPath
    Output folder. Default: .\MigrationData

.PARAMETER IncludeInherited
    Include inherited permissions (default: excluded — only explicit grants
    are relevant for migration).

.EXAMPLE
    .\Get-MailboxPermissions.ps1 `
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
    [string] $MailboxCsv   = '.\MigrationData\mailboxes.csv',
    [string] $OutputPath   = '.\MigrationData',
    [switch] $IncludeInherited
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

Initialize-MigLog -ScriptName 'Get-MailboxPermissions' `
                  -LogDirectory (Join-Path $PSScriptRoot '..\Logs')

$outDir = Ensure-OutputDirectory -Path $OutputPath

# ── Load mailbox inventory ────────────────────────────────────────────────────

$mailboxes = Import-CsvSafe -Path $MailboxCsv `
    -RequiredColumns @('PrimarySmtpAddress','DisplayName','MailboxType')

# Work from user + shared mailboxes only — rooms/equipment don't have delegates
$inScope = $mailboxes | Where-Object { $_.MailboxType -in @('UserMailbox','SharedMailbox') }
Write-MigLog "Mailboxes in scope for permissions: $($inScope.Count)"

# Build a quick lookup of known mailbox addresses (for trustee validation)
$knownAddresses = @{}
foreach ($m in $mailboxes) {
    $knownAddresses[$m.PrimarySmtpAddress.ToLower()] = $m.DisplayName
}

# ── Connect ───────────────────────────────────────────────────────────────────

Connect-SourceTenant -TenantId $SourceTenantId -UserPrincipalName $SourceAdminUPN

# ── Collection ────────────────────────────────────────────────────────────────

$permRows         = [System.Collections.Generic.List[PSCustomObject]]::new()
$unmappedTrustees = [System.Collections.Generic.List[PSCustomObject]]::new()
$errors           = [System.Collections.Generic.List[PSCustomObject]]::new()

$total = $inScope.Count
$i     = 0

foreach ($mbx in $inScope) {

    $i++
    Write-ProgressHelper -Activity 'Collecting permissions' `
                         -Current $i -Total $total `
                         -Status $mbx.PrimarySmtpAddress

    # ── Full Access ───────────────────────────────────────────────────────────
    try {
        $faPerms = Invoke-WithRetry {
            Get-MailboxPermission -Identity $mbx.PrimarySmtpAddress -ErrorAction Stop
        }

        foreach ($perm in $faPerms) {

            # Skip system trustees and (optionally) inherited permissions
            if ($perm.User -like 'NT AUTHORITY\*') { continue }
            if ($perm.User -like 'S-1-5-*')        { continue }
            if (-not $IncludeInherited -and $perm.IsInherited) { continue }
            if ($perm.AccessRights -notcontains 'FullAccess') { continue }

            $trusteeEmail = $perm.User.ToString().ToLower()

            # Normalise trustee — Exchange sometimes returns DOMAIN\user format
            if ($trusteeEmail -match '^.+\\.+$') {
                # Try to resolve to an email via Get-Recipient
                try {
                    $rec = Invoke-WithRetry {
                        Get-Recipient -Identity $perm.User.ToString() -ErrorAction SilentlyContinue
                    }
                    $trusteeEmail = $rec?.PrimarySmtpAddress.ToLower() ?? $trusteeEmail
                }
                catch { }
            }

            $isKnown = $knownAddresses.ContainsKey($trusteeEmail)

            $permRows.Add([PSCustomObject]@{
                MailboxEmail        = $mbx.PrimarySmtpAddress
                MailboxDisplayName  = $mbx.DisplayName
                MailboxType         = $mbx.MailboxType
                PermissionType      = 'FullAccess'
                TrusteeEmail        = $trusteeEmail
                TrusteeDisplayName  = $knownAddresses[$trusteeEmail] ?? ''
                IsInherited         = $perm.IsInherited
                TrusteeKnown        = $isKnown
                # Migration fields
                TargetMailboxEmail  = ''
                TargetTrusteeEmail  = ''
                AppliedAtTarget     = $false
                Notes               = ''
            })

            if (-not $isKnown) {
                $unmappedTrustees.Add([PSCustomObject]@{
                    MailboxEmail   = $mbx.PrimarySmtpAddress
                    PermissionType = 'FullAccess'
                    TrusteeEmail   = $trusteeEmail
                    Reason         = 'Trustee not in mailbox inventory (guest/service/deleted?)'
                })
            }
        }
    }
    catch {
        Write-MigLog "FullAccess collection failed for $($mbx.PrimarySmtpAddress): $_" -Level ERROR
        $errors.Add([PSCustomObject]@{
            Mailbox        = $mbx.PrimarySmtpAddress
            PermissionType = 'FullAccess'
            Error          = $_.Exception.Message
        })
    }

    # ── Send As ───────────────────────────────────────────────────────────────
    try {
        $saPerms = Invoke-WithRetry {
            Get-RecipientPermission -Identity $mbx.PrimarySmtpAddress -ErrorAction Stop
        }

        foreach ($perm in $saPerms) {

            if ($perm.Trustee -like 'NT AUTHORITY\*') { continue }
            if ($perm.Trustee -like 'S-1-5-*')        { continue }
            if ($perm.AccessControlType -ne 'Allow')  { continue }

            $trusteeEmail = $perm.Trustee.ToString().ToLower()
            $isKnown      = $knownAddresses.ContainsKey($trusteeEmail)

            $permRows.Add([PSCustomObject]@{
                MailboxEmail        = $mbx.PrimarySmtpAddress
                MailboxDisplayName  = $mbx.DisplayName
                MailboxType         = $mbx.MailboxType
                PermissionType      = 'SendAs'
                TrusteeEmail        = $trusteeEmail
                TrusteeDisplayName  = $knownAddresses[$trusteeEmail] ?? ''
                IsInherited         = $false
                TrusteeKnown        = $isKnown
                TargetMailboxEmail  = ''
                TargetTrusteeEmail  = ''
                AppliedAtTarget     = $false
                Notes               = ''
            })

            if (-not $isKnown) {
                $unmappedTrustees.Add([PSCustomObject]@{
                    MailboxEmail   = $mbx.PrimarySmtpAddress
                    PermissionType = 'SendAs'
                    TrusteeEmail   = $trusteeEmail
                    Reason         = 'Trustee not in mailbox inventory'
                })
            }
        }
    }
    catch {
        Write-MigLog "SendAs collection failed for $($mbx.PrimarySmtpAddress): $_" -Level ERROR
        $errors.Add([PSCustomObject]@{
            Mailbox        = $mbx.PrimarySmtpAddress
            PermissionType = 'SendAs'
            Error          = $_.Exception.Message
        })
    }

    # ── Send on Behalf ────────────────────────────────────────────────────────
    try {
        $sobMbx = Invoke-WithRetry {
            Get-Mailbox -Identity $mbx.PrimarySmtpAddress -ErrorAction Stop
        }

        foreach ($delegate in $sobMbx.GrantSendOnBehalfTo) {

            $delegateStr = $delegate.ToString()
            if ([string]::IsNullOrWhiteSpace($delegateStr)) { continue }

            # Resolve to email address
            $trusteeEmail = ''
            try {
                $rec = Invoke-WithRetry {
                    Get-Recipient -Identity $delegateStr -ErrorAction SilentlyContinue
                }
                $trusteeEmail = $rec?.PrimarySmtpAddress.ToLower() ?? $delegateStr.ToLower()
            }
            catch {
                $trusteeEmail = $delegateStr.ToLower()
            }

            $isKnown = $knownAddresses.ContainsKey($trusteeEmail)

            $permRows.Add([PSCustomObject]@{
                MailboxEmail        = $mbx.PrimarySmtpAddress
                MailboxDisplayName  = $mbx.DisplayName
                MailboxType         = $mbx.MailboxType
                PermissionType      = 'SendOnBehalf'
                TrusteeEmail        = $trusteeEmail
                TrusteeDisplayName  = $knownAddresses[$trusteeEmail] ?? ''
                IsInherited         = $false
                TrusteeKnown        = $isKnown
                TargetMailboxEmail  = ''
                TargetTrusteeEmail  = ''
                AppliedAtTarget     = $false
                Notes               = ''
            })

            if (-not $isKnown) {
                $unmappedTrustees.Add([PSCustomObject]@{
                    MailboxEmail   = $mbx.PrimarySmtpAddress
                    PermissionType = 'SendOnBehalf'
                    TrusteeEmail   = $trusteeEmail
                    Reason         = 'Trustee not in mailbox inventory'
                })
            }
        }
    }
    catch {
        Write-MigLog "SendOnBehalf collection failed for $($mbx.PrimarySmtpAddress): $_" -Level ERROR
        $errors.Add([PSCustomObject]@{
            Mailbox        = $mbx.PrimarySmtpAddress
            PermissionType = 'SendOnBehalf'
            Error          = $_.Exception.Message
        })
    }
}

Write-Progress -Activity 'Collecting permissions' -Completed

# ── Export ────────────────────────────────────────────────────────────────────

$permPath = Join-Path $outDir 'mailbox_permissions.csv'
$permRows | Export-CsvSafe -Path $permPath

if ($unmappedTrustees.Count -gt 0) {
    $unmappedTrustees | Export-CsvSafe -Path (Join-Path $outDir 'mailbox_permissions_unmapped_trustees.csv')
}

if ($errors.Count -gt 0) {
    $errors | Export-CsvSafe -Path (Join-Path $outDir 'mailbox_permissions_errors.csv')
}

# ── Summary ───────────────────────────────────────────────────────────────────

$byType = $permRows | Group-Object PermissionType |
    ForEach-Object { "$($_.Name)=$($_.Count)" }

Write-MigSummary -Stats @{
    'Mailboxes scanned'        = $inScope.Count
    'Total permission entries' = $permRows.Count
    'By type'                  = $byType -join ' | '
    'Unmapped trustees'        = $unmappedTrustees.Count
    'Errors'                   = $errors.Count
    'Output'                   = $permPath
    'Next script'              = 'Get-LicenseInventory.ps1'
}

Disconnect-AllTenants
