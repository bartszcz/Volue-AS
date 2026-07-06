#Requires -Version 5.1
#Requires -Modules ExchangeOnlineManagement, Microsoft.Graph.Users
<#
.SYNOPSIS
    Exports a full mailbox inventory from the SOURCE tenant.

.DESCRIPTION
    Collects user, shared, room, and equipment mailboxes with all attributes
    needed for HR matching, Code2 batch file generation, and target
    pre-creation. Enriches each user mailbox with Graph data (department,
    manager, employeeId) for use as matching signals.

    Source domain is variable (changes per migration).
    Target domain is always volue.com (set in MigrationHelpers).

    Outputs:
        MigrationData\mailboxes.csv
        MigrationData\mailbox_statistics.csv  (if -IncludeStatistics)
        MigrationData\mailbox_errors.csv      (if any errors occurred)

.PARAMETER SourceTenantId
    AAD Tenant ID or .onmicrosoft.com domain of the source tenant.

.PARAMETER SourceAdminUPN
    Source tenant admin UPN.

.PARAMETER SourceDomain
    Primary email domain of the source company. e.g. 'smartpulse.io'

.PARAMETER CompanySuffix
    Human-readable company name. e.g. 'SmartPulse'

.PARAMETER OutputPath
    Folder to write CSV files into. Default: .\MigrationData

.PARAMETER MailboxTypes
    Mailbox types to collect.
    Default: UserMailbox, SharedMailbox, RoomMailbox, EquipmentMailbox

.PARAMETER IncludeStatistics
    Also retrieve per-mailbox item count and size (one extra API call per
    mailbox — significantly slower on large tenants).

.EXAMPLE
    .\Get-MailboxInventory.ps1 `
        -SourceTenantId 'balancingpoolcom.onmicrosoft.com' `
        -SourceAdminUPN 'admin@smartpulse.io' `
        -SourceDomain   'smartpulse.io' `
        -CompanySuffix  'SmartPulse' `
        -IncludeStatistics

.EXAMPLE
    # User mailboxes only, no statistics (fastest run)
    .\Get-MailboxInventory.ps1 `
        -SourceTenantId 'balancingpoolcom.onmicrosoft.com' `
        -SourceAdminUPN 'admin@smartpulse.io' `
        -SourceDomain   'smartpulse.io' `
        -CompanySuffix  'SmartPulse' `
        -MailboxTypes   UserMailbox
#>

[CmdletBinding()]
param(
    [string]   $SourceTenantId = '',
    [string] $SourceAdminUPN = '',
    [string]   $SourceDomain = '',
    [string]   $CompanySuffix = '',
    [string]   $OutputPath   = '.\MigrationData',
    [string[]] $MailboxTypes = @('UserMailbox','SharedMailbox','RoomMailbox','EquipmentMailbox'),
    [switch]   $IncludeStatistics
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

Initialize-MigLog -ScriptName 'Get-MailboxInventory' `
                  -LogDirectory (Join-Path $PSScriptRoot '..\Logs')

$outDir = Ensure-OutputDirectory -Path $OutputPath
$domains = Get-MigrationDomains

Write-MigLog "Tenant    : $SourceTenantId"
Write-MigLog "Types     : $($MailboxTypes -join ', ')"
Write-MigLog "Statistics: $IncludeStatistics"

# ── Connect ───────────────────────────────────────────────────────────────────

Connect-SourceTenant -TenantId $SourceTenantId -UserPrincipalName $SourceAdminUPN

# ── Helper: get delegates summary for a mailbox ───────────────────────────────

function Get-DelegateSummary {
    param([string] $Identity)

    $parts = [System.Collections.Generic.List[string]]::new()

    try {
        $fa = Get-MailboxPermission -Identity $Identity -ErrorAction SilentlyContinue |
              Where-Object { $_.User -notlike 'NT AUTHORITY\*' -and $_.IsInherited -eq $false }
        foreach ($p in $fa) { $parts.Add("FA:$($p.User)") }
    } catch {}

    try {
        $sa = Get-RecipientPermission -Identity $Identity -ErrorAction SilentlyContinue |
              Where-Object { $_.Trustee -notlike 'NT AUTHORITY\*' }
        foreach ($p in $sa) { $parts.Add("SA:$($p.Trustee)") }
    } catch {}

    try {
        $sob = Get-Mailbox -Identity $Identity -ErrorAction SilentlyContinue |
               Select-Object -ExpandProperty GrantSendOnBehalfTo
        foreach ($p in $sob) { $parts.Add("SOB:$p") }
    } catch {}

    return ($parts | Select-Object -Unique) -join '|'
}

# ── Main collection ───────────────────────────────────────────────────────────

$allMailboxes = [System.Collections.Generic.List[PSCustomObject]]::new()
$allStats     = [System.Collections.Generic.List[PSCustomObject]]::new()
$errors       = [System.Collections.Generic.List[PSCustomObject]]::new()

foreach ($mbxType in $MailboxTypes) {

    Write-MigLog "──── Collecting: $mbxType ────"

    $mailboxes = Invoke-WithRetry {
        Get-Mailbox -RecipientTypeDetails $mbxType -ResultSize Unlimited -ErrorAction Stop
    }
    Write-MigLog "  Found: $($mailboxes.Count)"

    $typeCount = 0

    foreach ($mbx in $mailboxes) {

        $typeCount++
        Write-ProgressHelper -Activity "Collecting $mbxType" `
                             -Current $typeCount -Total $mailboxes.Count `
                             -Status $mbx.PrimarySmtpAddress

        try {

            # ── Graph enrichment (user mailboxes only) ────────────────────────
            $department  = ''
            $employeeId  = ''
            $managerUPN  = ''
            $mobilePhone = ''
            $officePhone = ''
            $country     = ''
            $city        = ''
            $jobTitle    = ''

            if ($mbxType -eq 'UserMailbox' -and $mbx.ExternalDirectoryObjectId) {
                try {
                    $gu = Invoke-WithRetry {
                        Get-MgUser -UserId $mbx.ExternalDirectoryObjectId `
                            -Property 'Department,EmployeeId,MobilePhone,BusinessPhones,Country,City,JobTitle' `
                            -ErrorAction SilentlyContinue
                    }
                    if ($gu) {
                        $department  = $gu.Department   ?? ''
                        $employeeId  = $gu.EmployeeId   ?? ''
                        $mobilePhone = $gu.MobilePhone  ?? ''
                        $officePhone = ($gu.BusinessPhones | Select-Object -First 1) ?? ''
                        $country     = $gu.Country      ?? ''
                        $city        = $gu.City         ?? ''
                        $jobTitle    = $gu.JobTitle     ?? ''
                    }

                    # Manager UPN — separate call
                    $mgr = Invoke-WithRetry {
                        Get-MgUserManager -UserId $mbx.ExternalDirectoryObjectId `
                            -ErrorAction SilentlyContinue
                    }
                    if ($mgr) {
                        $managerUPN = $mgr.AdditionalProperties['userPrincipalName'] ?? ''
                    }
                }
                catch {
                    Write-MigLog "Graph enrichment failed for $($mbx.PrimarySmtpAddress): $_" -Level WARN
                }
            }

            # ── Mailbox statistics ────────────────────────────────────────────
            $sizeGB    = 0
            $itemCount = 0

            if ($IncludeStatistics) {
                try {
                    $stats = Invoke-WithRetry {
                        Get-MailboxStatistics -Identity $mbx.PrimarySmtpAddress -ErrorAction Stop
                    }
                    $sizeGB    = Get-SizeInGB -SizeString $stats.TotalItemSize.ToString()
                    $itemCount = [int]$stats.ItemCount

                    $allStats.Add([PSCustomObject]@{
                        PrimarySmtpAddress    = $mbx.PrimarySmtpAddress
                        DisplayName           = $mbx.DisplayName
                        MailboxType           = $mbxType
                        SizeGB                = $sizeGB
                        ItemCount             = $itemCount
                        DeletedItemSizeGB     = Get-SizeInGB -SizeString $stats.TotalDeletedItemSize.ToString()
                        DeletedItemCount      = $stats.DeletedItemCount
                        LastLogonTime         = $stats.LastLogonTime
                        WhenCreated           = $mbx.WhenCreated
                    })
                }
                catch {
                    Write-MigLog "Statistics failed for $($mbx.PrimarySmtpAddress): $_" -Level WARN
                }
            }

            # ── Delegates (summary — full detail in Get-MailboxPermissions.ps1) ─
            $delegates = ''
            if ($mbxType -in @('UserMailbox','SharedMailbox')) {
                $delegates = Get-DelegateSummary -Identity $mbx.PrimarySmtpAddress
            }

            # ── Proxy addresses ───────────────────────────────────────────────
            $allProxies  = ($mbx.EmailAddresses | Where-Object { $_ -notmatch '^x500:' }) -join '|'
            $smtpAliases = ($mbx.EmailAddresses |
                            Where-Object { $_ -match '^smtp:' -and
                                           $_ -notmatch "^SMTP:$([regex]::Escape($mbx.PrimarySmtpAddress))$" }) -join '|'

            # ── Assemble record ───────────────────────────────────────────────
            $allMailboxes.Add([PSCustomObject]@{

                # Core identity — used for HR file matching
                PrimarySmtpAddress        = $mbx.PrimarySmtpAddress
                DisplayName               = $mbx.DisplayName
                FirstName                 = $mbx.FirstName
                LastName                  = $mbx.LastName
                Alias                     = $mbx.Alias
                ExternalDirectoryObjectId = $mbx.ExternalDirectoryObjectId   # AAD Object ID (SourceId for Code2)

                # Type
                MailboxType               = $mbxType
                RecipientTypeDetails      = $mbx.RecipientTypeDetails

                # All proxy addresses — important for cross-tenant identity signals
                AllProxyAddresses         = $allProxies
                SmtpAliases               = $smtpAliases

                # Graph-enriched directory attributes (matching helpers)
                Department                = $department
                JobTitle                  = $jobTitle
                EmployeeId                = $employeeId
                ManagerUPN                = $managerUPN
                MobilePhone               = $mobilePhone
                OfficePhone               = $officePhone
                Country                   = $country
                City                      = $city

                # Mailbox configuration (needed for target pre-creation)
                HiddenFromAddressListsEnabled = $mbx.HiddenFromAddressListsEnabled
                ForwardingSmtpAddress     = $mbx.ForwardingSmtpAddress
                DeliverToMailboxAndForward = $mbx.DeliverToMailboxAndForward
                LitigationHoldEnabled     = $mbx.LitigationHoldEnabled
                ArchiveStatus             = $mbx.ArchiveStatus
                RetentionPolicy           = $mbx.RetentionPolicy
                Languages                 = ($mbx.Languages -join '|')
                TimeZone                  = $mbx.TimeZone

                # Delegates summary (full detail in mailbox_permissions.csv)
                DelegateSummary           = $delegates

                # Size (populated if -IncludeStatistics)
                SizeGB                    = $sizeGB
                ItemCount                 = $itemCount

                # Timestamps
                WhenCreated               = $mbx.WhenCreated
                WhenMailboxCreated        = $mbx.WhenMailboxCreated
                WhenChanged               = $mbx.WhenChanged

                # Migration fields (blank here — filled during mapping phase)
                TargetEmail               = ''
                TargetAADObjectId         = ''
                MigrationBatch            = ''
                MigrationStatus           = 'PENDING'
                Notes                     = ''
            })
        }
        catch {
            Write-MigLog "ERROR processing $($mbx.PrimarySmtpAddress): $_" -Level ERROR
            $errors.Add([PSCustomObject]@{
                PrimarySmtpAddress = $mbx.PrimarySmtpAddress
                MailboxType        = $mbxType
                Error              = $_.Exception.Message
            })
        }
    }

    Write-Progress -Activity "Collecting $mbxType" -Completed
}

# ── Export ────────────────────────────────────────────────────────────────────

$csvPath = Join-Path $outDir 'mailboxes.csv'
$allMailboxes | Export-CsvSafe -Path $csvPath

if ($IncludeStatistics -and $allStats.Count -gt 0) {
    $allStats | Export-CsvSafe -Path (Join-Path $outDir 'mailbox_statistics.csv')
}

if ($errors.Count -gt 0) {
    $errors | Export-CsvSafe -Path (Join-Path $outDir 'mailbox_errors.csv')
}

# ── Summary ───────────────────────────────────────────────────────────────────

$byType = $allMailboxes | Group-Object MailboxType |
    ForEach-Object { "$($_.Name)=$($_.Count)" }

Write-MigSummary -Stats @{
    'Source domain'           = $domains.SourceDomain
    'Total mailboxes'         = $allMailboxes.Count
    'By type'                 = $byType -join ' | '
    'Statistics collected'    = $IncludeStatistics.IsPresent
    'Errors'                  = $errors.Count
    'Output'                  = $csvPath
    'Next script'             = 'Get-MailboxPermissions.ps1'
}

Disconnect-AllTenants
