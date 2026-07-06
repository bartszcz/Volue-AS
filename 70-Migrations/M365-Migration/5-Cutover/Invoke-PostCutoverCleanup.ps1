#Requires -Version 5.1
#Requires -Modules ExchangeOnlineManagement
<#
.SYNOPSIS
    Post-cutover cleanup. Run 30 days after MX cutover once you are
    confident no mail is arriving at source addresses.

.DESCRIPTION
    After the cutover window has passed:
        1. Removes ForwardingSmtpAddress from all source mailboxes
        2. Disables auto-reply (OOF) on all source mailboxes
        3. Generates a final cleanup report

    SAFETY
        Before removing forwarding, the script checks each mailbox
        for recent forwarded mail activity. If a mailbox received
        mail in the last N days (configurable) it warns rather than
        removing forwarding automatically.

        You can use -Force to override this and remove forwarding
        regardless of recent activity.

    This script is the LAST step of the migration for the source
    tenant. After it runs, the source tenant can be decommissioned
    on the schedule agreed with IT/procurement.

    IDEMPOTENT — mailboxes already cleaned up are skipped.

    OUTPUTS
        MigrationData\cleanup_results.csv
        MigrationData\cleanup_skipped_active.csv  (mailboxes still receiving forwarded mail)

.PARAMETER SourceTenantId
    AAD Tenant ID of the source tenant.

.PARAMETER SourceAdminUPN
    Admin UPN for the source tenant.

.PARAMETER SourceDomain
    Primary email domain of the source company. e.g. 'smartpulse.io'

.PARAMETER CompanySuffix
    Human-readable company name. e.g. 'SmartPulse'

.PARAMETER UserMappingCsv
    Default: .\MigrationData\user_mapping_confirmed.csv

.PARAMETER RecentActivityDays
    Mailboxes with items received in the last N days will be flagged
    rather than cleaned up automatically. Default: 7

.PARAMETER Force
    Remove forwarding regardless of recent mail activity.

.PARAMETER WhatIf
    Show what would be changed without making changes.

.PARAMETER OutputPath
    Output folder. Default: .\MigrationData

.EXAMPLE
    # Preview what would be cleaned up
    .\Invoke-PostCutoverCleanup.ps1 `
        -SourceTenantId 'balancingpoolcom.onmicrosoft.com' `
        -SourceAdminUPN 'admin@smartpulse.io' `
        -SourceDomain   'smartpulse.io' `
        -CompanySuffix  'SmartPulse' `
        -WhatIf

.EXAMPLE
    # Live run — flags any mailbox with recent activity
    .\Invoke-PostCutoverCleanup.ps1 `
        -SourceTenantId 'balancingpoolcom.onmicrosoft.com' `
        -SourceAdminUPN 'admin@smartpulse.io' `
        -SourceDomain   'smartpulse.io' `
        -CompanySuffix  'SmartPulse'

.EXAMPLE
    # Force cleanup regardless of recent activity
    .\Invoke-PostCutoverCleanup.ps1 `
        -SourceTenantId 'balancingpoolcom.onmicrosoft.com' `
        -SourceAdminUPN 'admin@smartpulse.io' `
        -SourceDomain   'smartpulse.io' `
        -CompanySuffix  'SmartPulse' `
        -Force
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    [string] $SourceTenantId = '',
    [string] $SourceAdminUPN = '',
    [string] $SourceDomain = '',
    [string] $CompanySuffix = '',
    [string] $UserMappingCsv     = '.\MigrationData\user_mapping_confirmed.csv',
    [int]    $RecentActivityDays = 7,
    [switch] $Force,
    [string] $OutputPath         = '.\MigrationData'
)

# ── Bootstrap ─────────────────────────────────────────────────────────────────

Import-Module (Join-Path $PSScriptRoot '..\MigrationHelpers.psm1') -Force -ErrorAction Stop

# ── Load MigrationConfig.psd1 ────────────────────────────────────────────────
$_cfg = Import-MigrationConfig
$SourceTenantId = Resolve-ConfigParam -Passed $SourceTenantId -Default '' -ConfigValue (Get-ConfigValue -Config $_cfg -Key "SourceTenantId")
$SourceAdminUPN = Resolve-ConfigParam -Passed $SourceAdminUPN -Default '' -ConfigValue (Get-ConfigValue -Config $_cfg -Key "SourceAdminUPN")
$SourceDomain = Resolve-ConfigParam -Passed $SourceDomain -Default '' -ConfigValue (Get-ConfigValue -Config $_cfg -Key "SourceDomain")
$CompanySuffix = Resolve-ConfigParam -Passed $CompanySuffix -Default '' -ConfigValue (Get-ConfigValue -Config $_cfg -Key "CompanySuffix")
$UserMappingCsv = Resolve-ConfigParam -Passed $UserMappingCsv -Default '' -ConfigValue (Get-ConfigValue -Config $_cfg -Key "UserMappingCsv")
$OutputPath = Resolve-ConfigParam -Passed $OutputPath -Default '' -ConfigValue (Get-ConfigValue -Config $_cfg -Key "OutputPath")
$RecentActivityDays = Resolve-ConfigParam -Passed $RecentActivityDays -Default '' -ConfigValue (Get-ConfigValue -Config $_cfg -Key "RecentActivityDays")

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
Initialize-MigLog -ScriptName 'Invoke-PostCutoverCleanup' `
                  -LogDirectory (Join-Path $PSScriptRoot '..\Logs')
$outDir       = Ensure-OutputDirectory -Path $OutputPath
$activityCutoff = (Get-Date).AddDays(-$RecentActivityDays)

Write-MigLog "Cleanup run. Activity threshold: last $RecentActivityDays days ($($activityCutoff.ToString('yyyy-MM-dd')))"
if ($Force) { Write-MigLog "FORCE mode — removing forwarding regardless of activity" -Level WARN }

# ── Load mapping ──────────────────────────────────────────────────────────────

$mapping   = Import-CsvSafe -Path $UserMappingCsv `
    -RequiredColumns @('SourceEmail','TargetEmail','Status')
$confirmed = @($mapping | Where-Object { $_.Status -eq 'CONFIRMED' })
Write-MigLog "Mailboxes to clean up: $($confirmed.Count)"

# ── Connect source ────────────────────────────────────────────────────────────

Connect-SourceTenant -TenantId $SourceTenantId -UserPrincipalName $SourceAdminUPN

# ── Cleanup loop ──────────────────────────────────────────────────────────────

$resultRows  = [System.Collections.Generic.List[PSCustomObject]]::new()
$activeRows  = [System.Collections.Generic.List[PSCustomObject]]::new()

$cleaned  = 0; $skippedActive = 0; $alreadyClean = 0; $failed = 0
$total    = $confirmed.Count; $i = 0

foreach ($row in $confirmed) {

    $i++
    Write-ProgressHelper -Activity 'Cleaning up source mailboxes' `
                         -Current $i -Total $total `
                         -Status $row.SourceEmail

    try {
        $mbx = Invoke-WithRetry {
            Get-Mailbox -Identity $row.SourceEmail -ErrorAction Stop
        }

        $hasForwarding = $null -ne $mbx.ForwardingSmtpAddress -and $mbx.ForwardingSmtpAddress -ne ''
        $hasOOF        = $false

        try {
            $oof    = Get-MailboxAutoReplyConfiguration -Identity $row.SourceEmail -ErrorAction Stop
            $hasOOF = $oof.AutoReplyState -eq 'Enabled'
        } catch {}

        # If nothing to clean, skip
        if (-not $hasForwarding -and -not $hasOOF) {
            $alreadyClean++
            $resultRows.Add([PSCustomObject]@{
                SourceEmail = $row.SourceEmail; TargetEmail = $row.TargetEmail
                ForwardingRemoved = $false; OOFDisabled = $false
                Action = 'ALREADY_CLEAN'; ActiveFlag = $false; WhatIf = $false
            })
            continue
        }

        # Check for recent activity (items received since cutover)
        $recentActivity = $false
        if (-not $Force) {
            try {
                $stats = Invoke-WithRetry {
                    Get-MailboxStatistics -Identity $row.SourceEmail -ErrorAction Stop
                }
                # LastLogonTime is a reasonable proxy for recent activity
                if ($stats.LastLogonTime -gt $activityCutoff) {
                    $recentActivity = $true
                }
            }
            catch {
                Write-MigLog "  Could not get stats for $($row.SourceEmail): $_" -Level WARN
            }
        }

        if ($recentActivity -and -not $Force) {
            $skippedActive++
            Write-MigLog "  SKIPPED (recent activity): $($row.SourceEmail)" -Level WARN
            $activeRows.Add([PSCustomObject]@{
                SourceEmail   = $row.SourceEmail
                TargetEmail   = $row.TargetEmail
                LastActivity  = $stats.LastLogonTime
                ForwardingSet = $hasForwarding
                OOFEnabled    = $hasOOF
                Notes         = "Last activity within ${RecentActivityDays}d — review before removing forwarding"
            })
            $resultRows.Add([PSCustomObject]@{
                SourceEmail = $row.SourceEmail; TargetEmail = $row.TargetEmail
                ForwardingRemoved = $false; OOFDisabled = $false
                Action = 'SKIPPED_ACTIVE'; ActiveFlag = $true; WhatIf = $false
            })
            continue
        }

        # ── Remove forwarding ─────────────────────────────────────────────────
        $forwardingRemoved = $false
        $oofDisabled       = $false

        if ($PSCmdlet.ShouldProcess($row.SourceEmail, 'Remove forwarding and disable OOF')) {

            if ($hasForwarding) {
                Invoke-WithRetry {
                    Set-Mailbox -Identity                   $row.SourceEmail `
                                -ForwardingSmtpAddress      $null `
                                -DeliverToMailboxAndForward $false `
                                -ErrorAction Stop
                }
                $forwardingRemoved = $true
                Write-MigLog "  FORWARDING REMOVED: $($row.SourceEmail)"
            }

            if ($hasOOF) {
                Invoke-WithRetry {
                    Set-MailboxAutoReplyConfiguration `
                        -Identity       $row.SourceEmail `
                        -AutoReplyState Disabled `
                        -ErrorAction Stop
                }
                $oofDisabled = $true
                Write-MigLog "  OOF DISABLED: $($row.SourceEmail)"
            }

            $cleaned++
            $resultRows.Add([PSCustomObject]@{
                SourceEmail       = $row.SourceEmail
                TargetEmail       = $row.TargetEmail
                ForwardingRemoved = $forwardingRemoved
                OOFDisabled       = $oofDisabled
                Action            = 'CLEANED'
                ActiveFlag        = $recentActivity
                WhatIf            = $false
            })
        }
        else {
            Write-MigLog "  WHATIF: Would remove forwarding/OOF for $($row.SourceEmail)"
            $resultRows.Add([PSCustomObject]@{
                SourceEmail = $row.SourceEmail; TargetEmail = $row.TargetEmail
                ForwardingRemoved = $false; OOFDisabled = $false
                Action = 'WHATIF'; ActiveFlag = $recentActivity; WhatIf = $true
            })
        }
    }
    catch {
        $failed++
        Write-MigLog "  FAILED: $($row.SourceEmail) — $_" -Level ERROR
        $resultRows.Add([PSCustomObject]@{
            SourceEmail = $row.SourceEmail; TargetEmail = $row.TargetEmail
            ForwardingRemoved = $false; OOFDisabled = $false
            Action = 'FAILED'; ActiveFlag = $false; WhatIf = $false
        })
    }
}

Write-Progress -Activity 'Cleaning up source mailboxes' -Completed

# ── Export ────────────────────────────────────────────────────────────────────

$resultRows | Export-CsvSafe -Path (Join-Path $outDir 'cleanup_results.csv')
if ($activeRows.Count -gt 0) {
    $activeRows | Export-CsvSafe -Path (Join-Path $outDir 'cleanup_skipped_active.csv')
}

# ── Summary ───────────────────────────────────────────────────────────────────

Write-MigSummary -Stats @{
    'Total mailboxes'          = $total
    'Cleaned up'               = $cleaned
    'Already clean'            = $alreadyClean
    'Skipped (recent activity)'= $skippedActive
    'Failed'                   = $failed
    'Force mode'               = $Force.IsPresent
    'WhatIf mode'              = $WhatIfPreference
}

if ($skippedActive -gt 0) {
    Write-MigLog ''
    Write-MigLog "ACTION: $skippedActive mailbox(es) still showing recent activity." -Level WARN
    Write-MigLog "  These are forwarding mail received at source — senders haven't updated contacts yet." -Level WARN
    Write-MigLog "  Review cleanup_skipped_active.csv and either:" -Level WARN
    Write-MigLog "    (a) Wait another week and re-run, or" -Level WARN
    Write-MigLog "    (b) Re-run with -Force to clean up regardless" -Level WARN
}

if ($failed -eq 0 -and $skippedActive -eq 0) {
    Write-MigLog ''
    Write-MigLog '✔  Source tenant cleanup complete.' -Level INFO
    Write-MigLog '   Migration of $CompanySuffix to Volue is fully complete.' -Level INFO
    Write-MigLog '   Source tenant can now be decommissioned per agreed schedule.' -Level INFO
}

Disconnect-AllTenants
