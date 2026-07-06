<#
.SYNOPSIS
    Sets ForwardingSMTPAddress on source tenant mailboxes to forward to target tenant addresses.

.DESCRIPTION
    Reads a mapping CSV (SourceEmail, TargetEmail) and configures ForwardingSMTPAddress on each
    source mailbox. DeliverToMailboxAndForward is set to $false by default — mail is forwarded
    only and NOT kept in the source mailbox. Set -DeliverAndKeep to retain a copy in source.

    Must be connected to the SOURCE tenant Exchange Online before running.

    BLOCKER CHECK: Forwarding will be silently skipped by Exchange Online if the target address
    is not reachable. Validate that target mailboxes exist in the target tenant before running.

.PARAMETER CsvPath
    Path to the mapping CSV. Required columns: SourceEmail, TargetEmail.

.PARAMETER DeliverAndKeep
    If specified, sets DeliverToMailboxAndForward = $true (copy stays in source mailbox).
    Default: $false — forward only, no copy retained in source.

.PARAMETER WhatIf
    Runs in dry-run mode. Shows what would be changed without making any changes.

.EXAMPLE
    # Dry run first — always
    .\Set-MailboxForwarding.ps1 -CsvPath .\all-mx-mapping.csv -WhatIf

    # Apply forwarding (forward-only, no source copy)
    .\Set-MailboxForwarding.ps1 -CsvPath .\all-mx-mapping.csv

    # Apply with source copy retained
    .\Set-MailboxForwarding.ps1 -CsvPath .\all-mx-mapping.csv -DeliverAndKeep

.NOTES
    Module required : ExchangeOnlineManagement
    Connect first   : Connect-ExchangeOnline -UserPrincipalName admin@optimeering.com
    Run context     : SOURCE tenant (optimeering.com)
    Safe to re-run  : Yes — idempotent, re-applying the same forwarding address is a no-op
#>

[CmdletBinding(SupportsShouldProcess)]
param (
    [Parameter(Mandatory)]
    [string]$CsvPath,

    [switch]$DeliverAndKeep
)

#region --- Prerequisites -------------------------------------------------------

Write-Host ""
Write-Host "=== Prerequisites ===" -ForegroundColor DarkCyan

if ($PSVersionTable.PSVersion.Major -lt 5 -or
    ($PSVersionTable.PSVersion.Major -eq 5 -and $PSVersionTable.PSVersion.Minor -lt 1)) {
    throw "PowerShell 5.1 or higher is required (found $($PSVersionTable.PSVersion))"
}
Write-Host "  [OK] PowerShell $($PSVersionTable.PSVersion)" -ForegroundColor Green

$minEXOVersion = [version]"3.0.0"
$installed = Get-Module -ListAvailable -Name ExchangeOnlineManagement |
             Sort-Object Version -Descending | Select-Object -First 1

if (-not $installed -or $installed.Version -lt $minEXOVersion) {
    $msg = if ($installed) { "v$($installed.Version) found but v$minEXOVersion+ required — updating..." }
           else { "not installed — installing from PSGallery..." }
    Write-Host "  [!!] ExchangeOnlineManagement $msg" -ForegroundColor Yellow
    try {
        if (-not (Get-PackageProvider -Name NuGet -ErrorAction SilentlyContinue)) {
            Write-Host "  [..] Bootstrapping NuGet provider..." -ForegroundColor Cyan
            Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 -Force -Scope CurrentUser | Out-Null
        }
        Install-Module -Name ExchangeOnlineManagement -MinimumVersion $minEXOVersion `
                       -Scope CurrentUser -Force -AllowClobber -Repository PSGallery -ErrorAction Stop
        Write-Host "  [OK] ExchangeOnlineManagement installed" -ForegroundColor Green
    } catch {
        throw "Could not install ExchangeOnlineManagement: $_"
    }
} else {
    Write-Host "  [OK] ExchangeOnlineManagement v$($installed.Version)" -ForegroundColor Green
}

Import-Module ExchangeOnlineManagement -ErrorAction Stop

# Connect to source tenant if not already connected
$connection = Get-ConnectionInformation -ErrorAction SilentlyContinue | Select-Object -First 1
if (-not $connection) {
    Write-Host ""
    Write-Host "  [..] Not connected to Exchange Online — connecting now..." -ForegroundColor Cyan
    do {
        $adminUPN = (Read-Host "  Source tenant admin UPN").Trim()
    } while ([string]::IsNullOrWhiteSpace($adminUPN))
    try {
        Connect-ExchangeOnline -UserPrincipalName $adminUPN -ShowBanner:$false -ErrorAction Stop
        Write-Host "  [OK] Connected as $adminUPN" -ForegroundColor Green
    } catch {
        throw "Failed to connect to Exchange Online: $_"
    }
} else {
    Write-Host "  [OK] Already connected as $($connection.UserPrincipalName)" -ForegroundColor Green
}

#endregion

#region --- Preflight -----------------------------------------------------------

if (-not (Test-Path $CsvPath)) {
    throw "CSV not found: $CsvPath"
}

$mapping = Import-Csv -Path $CsvPath | Where-Object {
    $_.SourceEmail -and $_.SourceEmail.Trim() -ne '' -and
    $_.TargetEmail -and $_.TargetEmail.Trim() -ne ''
}

if ($mapping.Count -eq 0) {
    throw "No valid rows found in CSV. Check that SourceEmail and TargetEmail columns are populated."
}

Write-Host ""
Write-Host "=== Set-MailboxForwarding ===" -ForegroundColor Cyan
Write-Host "CSV            : $CsvPath"
Write-Host "Rows loaded    : $($mapping.Count)"
Write-Host "Deliver & keep : $DeliverAndKeep"
Write-Host "WhatIf mode    : $($WhatIfPreference -eq 'Continue')"
Write-Host ""

#endregion

#region --- Main loop -----------------------------------------------------------

$results = [System.Collections.Generic.List[PSCustomObject]]::new()

foreach ($row in $mapping) {
    $source = $row.SourceEmail.Trim()
    $target = $row.TargetEmail.Trim()

    Write-Host "Processing: $source → $target" -NoNewline

    # Verify source mailbox exists
    $mbx = Get-Mailbox -Identity $source -ErrorAction SilentlyContinue
    if (-not $mbx) {
        Write-Host "  [SKIP — mailbox not found]" -ForegroundColor Yellow
        $results.Add([PSCustomObject]@{
            SourceEmail    = $source
            TargetEmail    = $target
            Status         = 'SKIPPED'
            Reason         = 'Source mailbox not found'
        })
        continue
    }

    # Check if forwarding is already correctly set
    if ($mbx.ForwardingSMTPAddress -eq "smtp:$target" -and
        $mbx.DeliverToMailboxAndForward -eq $DeliverAndKeep.IsPresent) {
        Write-Host "  [ALREADY SET]" -ForegroundColor Green
        $results.Add([PSCustomObject]@{
            SourceEmail    = $source
            TargetEmail    = $target
            Status         = 'ALREADY_SET'
            Reason         = 'No change required'
        })
        continue
    }

    try {
        if ($PSCmdlet.ShouldProcess($source, "Set ForwardingSMTPAddress to $target")) {
            Set-Mailbox -Identity $source `
                -ForwardingSMTPAddress $target `
                -DeliverToMailboxAndForward $DeliverAndKeep.IsPresent `
                -ErrorAction Stop

            Write-Host "  [OK]" -ForegroundColor Green
            $results.Add([PSCustomObject]@{
                SourceEmail    = $source
                TargetEmail    = $target
                Status         = 'SUCCESS'
                Reason         = ''
            })
        } else {
            # WhatIf branch
            Write-Host "  [WHATIF]" -ForegroundColor DarkCyan
            $results.Add([PSCustomObject]@{
                SourceEmail    = $source
                TargetEmail    = $target
                Status         = 'WHATIF'
                Reason         = 'WhatIf — no change made'
            })
        }
    }
    catch {
        Write-Host "  [ERROR: $($_.Exception.Message)]" -ForegroundColor Red
        $results.Add([PSCustomObject]@{
            SourceEmail    = $source
            TargetEmail    = $target
            Status         = 'ERROR'
            Reason         = $_.Exception.Message
        })
    }
}

#endregion

#region --- Summary & export ----------------------------------------------------

Write-Host ""
Write-Host "=== Summary ===" -ForegroundColor Cyan

$success     = ($results | Where-Object Status -eq 'SUCCESS').Count
$alreadySet  = ($results | Where-Object Status -eq 'ALREADY_SET').Count
$skipped     = ($results | Where-Object Status -eq 'SKIPPED').Count
$errors      = ($results | Where-Object Status -eq 'ERROR').Count
$whatif      = ($results | Where-Object Status -eq 'WHATIF').Count

Write-Host "SUCCESS      : $success"
Write-Host "ALREADY SET  : $alreadySet"
Write-Host "WHATIF       : $whatif"
Write-Host "SKIPPED      : $skipped"
Write-Host "ERROR        : $errors"

$reportPath = "ForwardingReport_$(Get-Date -Format 'yyyyMMdd_HHmmss').csv"
$results | Export-Csv -Path $reportPath -NoTypeInformation -Encoding UTF8
Write-Host ""
Write-Host "Report saved : $reportPath" -ForegroundColor Cyan

if ($errors -gt 0) {
    Write-Host ""
    Write-Host "[BLOCKER] $errors mailbox(es) failed. Review report for details." -ForegroundColor Red
}

if ($skipped -gt 0) {
    Write-Host ""
    Write-Host "[WARNING] $skipped mailbox(es) not found in source tenant. Verify they exist." -ForegroundColor Yellow
}

#endregion