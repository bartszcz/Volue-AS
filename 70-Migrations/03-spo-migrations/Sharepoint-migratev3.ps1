<#
.SYNOPSIS
    SharePoint Site Migration - Batch Mode

.PARAMETER Mode
    Full        - Copy all content, overwrite anything that already exists on destination.
    Incremental - Copy only items that have changed since the last run (delta). Default.

.PARAMETER FailedOnly
    Only process sites that failed in a previous run (tracked in migration-state.json).

.PARAMETER WhatIf
    Dry-run. Shows which sites would be processed without authenticating or copying any data.

.EXAMPLE
    # Initial full migration
    .\Migrate-SharePointSites.ps1 -Mode Full

    # Delta migration - pick up changes since last run
    .\Migrate-SharePointSites.ps1 -Mode Incremental

    # Preview what would run
    .\Migrate-SharePointSites.ps1 -Mode Incremental -WhatIf

    # Retry only previously failed sites
    .\Migrate-SharePointSites.ps1 -FailedOnly
#>

[CmdletBinding(SupportsShouldProcess)]
param (
    [ValidateSet("Full", "Incremental")]
    [string]$Mode = "Incremental",

    [switch]$FailedOnly
)

Import-Module Sharegate
Import-Module Microsoft.Online.SharePoint.PowerShell

# ── Configuration ─────────────────────────────────────────────────────────────
$csvFile     = "C:\temp\optimeering\sites-mapping.csv"
$dstOwner    = "migration.volue@volue.onmicrosoft.com"
$srcAdminUrl = "https://optimeering-admin.sharepoint.com"
$dstAdminUrl = "https://volue-admin.sharepoint.com"

$logDir    = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path $csvFile }
$logFile   = "$logDir\migration-batch-log.txt"
$stateFile = "$logDir\migration-state.json"
# ─────────────────────────────────────────────────────────────────────────────

function Load-State {
    if (Test-Path $stateFile) {
        try {
            $raw = Get-Content $stateFile -Raw | ConvertFrom-Json
            $ht = @{}
            foreach ($prop in $raw.PSObject.Properties) {
                $ht[$prop.Name] = $prop.Value
            }
            return $ht
        }
        catch {
            Write-Warning "Could not parse state file - treating as empty."
        }
    }
    return @{}
}

function Save-State ([hashtable]$state) {
    $state | ConvertTo-Json -Depth 3 | Set-Content -Path $stateFile -Encoding UTF8
}

# ── Main ──────────────────────────────────────────────────────────────────────

$copyBehaviour = if ($Mode -eq "Full") { "Overwrite" } else { "IncrementalUpdate" }

Write-Host ""
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "SharePoint Site Migration - Batch Mode"  -ForegroundColor Cyan
Write-Host "Mode:     $Mode ($copyBehaviour)"        -ForegroundColor Cyan
if ($FailedOnly)       { Write-Host "Scope:    Failed sites only"            -ForegroundColor Cyan }
if ($WhatIfPreference) { Write-Host "** WHATIF - no changes will be made **" -ForegroundColor Magenta }
Write-Host "========================================" -ForegroundColor Cyan
Write-Host ""

$table = Import-Csv $csvFile -Delimiter ","
$state = Load-State

# ── Site selection ────────────────────────────────────────────────────────────
if ($FailedOnly) {
    $toProcess = $table | Where-Object {
        $key = $_."Site address"
        $state.ContainsKey($key) -and $state[$key].Status -eq "Failed"
    }
    if (@($toProcess).Count -eq 0) {
        Write-Host "No failed sites found in state file. Nothing to retry." -ForegroundColor Green
        exit 0
    }
} else {
    $toProcess = $table
}

Write-Host "Total sites in CSV: $($table.Count)"        -ForegroundColor Yellow
Write-Host "Sites to process:   $(@($toProcess).Count)" -ForegroundColor Yellow
Write-Host "Copy behaviour:     $copyBehaviour"          -ForegroundColor Yellow
Write-Host ""

# ── WhatIf - print plan and exit ──────────────────────────────────────────────
if ($WhatIfPreference) {
    Write-Host "WHATIF: The following sites would be processed:" -ForegroundColor Magenta
    Write-Host ""
    $i = 0
    foreach ($row in $toProcess) {
        $i++
        $key        = $row."Site address"
        $lastStatus = if ($state.ContainsKey($key)) { $state[$key].Status } else { "Never run" }
        $lastRun    = if ($state.ContainsKey($key) -and $state[$key].CompletedAt) { $state[$key].CompletedAt } `
                      elseif ($state.ContainsKey($key) -and $state[$key].FailedAt) { $state[$key].FailedAt } `
                      else { "-" }

        Write-Host "  [$i] $($row.'Title')" -ForegroundColor Yellow
        Write-Host "      Source:      $($row.'Site address')"
        Write-Host "      Destination: $($row.'New Site URL Volue')"
        Write-Host "      Last status: $lastStatus ($lastRun)"
        Write-Host ""
    }
    Write-Host "----------------------------------------" -ForegroundColor Cyan
    Write-Host "  Would process: $(@($toProcess).Count) sites" -ForegroundColor Yellow
    Write-Host "  Copy mode:     $copyBehaviour"               -ForegroundColor Yellow
    Write-Host ""
    Write-Host "No changes made. Remove -WhatIf to run for real." -ForegroundColor Green
    exit 0
}

# ── Authenticate ──────────────────────────────────────────────────────────────
Write-Host "Authenticating to source tenant..." -ForegroundColor Yellow
try {
    $sourceConnection = Connect-Site -Url $srcAdminUrl -Browser -ErrorAction Stop
    if (-not $sourceConnection) { throw "Connect-Site returned null for source tenant." }
    Write-Host "Authenticated to source tenant" -ForegroundColor Green
}
catch {
    Write-Host "ERROR: Failed to authenticate to source tenant: $($_.Exception.Message)" -ForegroundColor Red
    Write-Host "Check your ShareGate subscription and license status." -ForegroundColor Red
    exit 1
}

Write-Host "Authenticating to destination tenant (Volue)..." -ForegroundColor Yellow
try {
    $destConnection = Connect-Site -Url $dstAdminUrl -Browser -ErrorAction Stop
    if (-not $destConnection) { throw "Connect-Site returned null for destination tenant." }
    Write-Host "Authenticated to destination tenant" -ForegroundColor Green
}
catch {
    Write-Host "ERROR: Failed to authenticate to destination tenant: $($_.Exception.Message)" -ForegroundColor Red
    Write-Host "Check your ShareGate subscription and license status." -ForegroundColor Red
    exit 1
}

# ── Create destination sites if missing ───────────────────────────────────────
Write-Host ""
Write-Host "Creating destination sites on Volue..." -ForegroundColor Yellow
try {
    Connect-SPOService -Url $dstAdminUrl -ErrorAction Stop
}
catch {
    Write-Host "WARNING: Connect-SPOService failed (401 Unauthorized). Site creation will be skipped." -ForegroundColor Red
    Write-Host "Ensure your account has SharePoint Admin role on the destination tenant and re-authenticate." -ForegroundColor Red
}

foreach ($row in $toProcess) {
    $destUrl   = $row."New Site URL Volue"
    $destTitle = $row."New Site Name Volue"

    Write-Host "  Creating: $destUrl" -ForegroundColor Yellow
    try {
        New-SPOSite -Url $destUrl -Owner $dstOwner -Title $destTitle `
                    -StorageQuota 20971520 -Template "STS#3" -ErrorAction Stop
        Write-Host "  Created: $destTitle" -ForegroundColor Green
    }
    catch {
        Write-Host "  Skipped (may already exist): $($_.Exception.Message)" -ForegroundColor DarkYellow
    }
}

# ── Migrate ───────────────────────────────────────────────────────────────────
Write-Host ""
Write-Host "Starting migrations..." -ForegroundColor Cyan
Write-Host ""

"Migration ($Mode$(if ($FailedOnly){', FailedOnly'})) started at $(Get-Date)" |
    Out-File -FilePath $logFile -Append

$successCount   = 0
$failureCount   = 0
$sitesProcessed = 0
$sitesTotal     = @($toProcess).Count

foreach ($row in $toProcess) {
    $sitesProcessed++
    $sourceUrl = $row."Site address"
    $destUrl   = $row."New Site URL Volue"
    $title     = $row."Title"

    Write-Host "[$sitesProcessed/$sitesTotal] Migrating: $title" -ForegroundColor Cyan
    Write-Host "  Source:      $sourceUrl"
    Write-Host "  Destination: $destUrl"
    Write-Host "  Copy mode:   $copyBehaviour"

    try {
        $srcSite = Connect-Site -Url $sourceUrl -UseCredentialsFrom $sourceConnection -AllowConnectionFallback
        Write-Host "  Connected to source" -ForegroundColor Green

        $dstSite = Connect-Site -Url $destUrl -UseCredentialsFrom $destConnection -AllowConnectionFallback
        Write-Host "  Connected to destination" -ForegroundColor Green

        $copySettings = New-CopySettings -OnContentItemExists $copyBehaviour

        Copy-Site -Site $srcSite -DestinationSite $dstSite -CopySettings $copySettings -Merge -Subsites

        Write-Host "  Completed successfully!" -ForegroundColor Green

        $state[$sourceUrl] = @{
            Status      = "Success"
            Title       = $title
            Destination = $destUrl
            CompletedAt = (Get-Date -Format "o")
            Mode        = $Mode
        }
        Save-State $state

        "[$sitesProcessed/$sitesTotal] SUCCESS: $title - $sourceUrl -> $destUrl" |
            Out-File -FilePath $logFile -Append
        $successCount++
    }
    catch {
        $errMsg = $_.Exception.Message
        Write-Host "  Failed: $errMsg" -ForegroundColor Red

        $state[$sourceUrl] = @{
            Status      = "Failed"
            Title       = $title
            Destination = $destUrl
            Error       = $errMsg
            FailedAt    = (Get-Date -Format "o")
            Mode        = $Mode
        }
        Save-State $state

        "[$sitesProcessed/$sitesTotal] FAILED: $title - $sourceUrl | Error: $errMsg" |
            Out-File -FilePath $logFile -Append
        $failureCount++
    }
}

# ── Summary ───────────────────────────────────────────────────────────────────
Write-Host ""
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "Migration Summary"                        -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "Total processed: $sitesProcessed" -ForegroundColor Yellow
Write-Host "Successful:      $successCount"   -ForegroundColor Green
Write-Host "Failed:          $failureCount"   -ForegroundColor $(if ($failureCount -eq 0) { "Green" } else { "Red" })
Write-Host ""
Write-Host "Log file saved to: $logFile"   -ForegroundColor Yellow
Write-Host "State file:        $stateFile" -ForegroundColor Yellow
Write-Host ""

"Migration ($Mode) completed at $(Get-Date) | Success: $successCount | Failed: $failureCount" |
    Out-File -FilePath $logFile -Append