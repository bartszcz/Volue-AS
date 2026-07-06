<#
.SYNOPSIS
    Sets all source SharePoint sites from the mapping CSV to read-only (NoAccess lock state).

.DESCRIPTION
    Reads a mapping CSV (must contain a 'Site address' column) and sets the LockState on each
    source site to ReadOnly. Users attempting to write will receive a standard SharePoint
    read-only notice. Site admins and Global Admins retain full access regardless of lock state.

    LockState options applied by this script:
        ReadOnly  — users can read but not write (default action)
        Unlock    — removes the lock (use -Unlock to revert)

.PARAMETER Unlock
    If specified, removes the ReadOnly lock (sets LockState to Unlock) instead of applying it.
    Use this to revert if you need to re-enable writes on the source sites.

.PARAMETER WhatIf
    Runs in dry-run mode. Shows what would be changed without making any changes.

.EXAMPLE
    # Dry run first — always
    .\set-site-readonly.ps1 -WhatIf

    # Apply read-only lock to all source sites
    .\set-site-readonly.ps1

    # Revert — remove read-only lock from all source sites
    .\set-site-readonly.ps1 -Unlock

.NOTES
    Module required : PnP.PowerShell  (Install-Module PnP.PowerShell -Scope CurrentUser)
    Run context     : SOURCE tenant admin (optimeering.com)
    Safe to re-run  : Yes — setting an already-locked site to ReadOnly is idempotent
    Timing          : Run AFTER Sharegate migration is complete and delta passes are done.
                      Do NOT run while Sharegate jobs are still active — it will block them.
#>

[CmdletBinding(SupportsShouldProcess)]
param (
    [switch]$Unlock
)

Import-Module PnP.PowerShell

# ── Configuration ─────────────────────────────────────────────────────────────
$csvFile     = "C:\Optimeering\sites-mapping.csv"
$srcAdminUrl = "https://optimeering-admin.sharepoint.com"

$pnpAppName    = "PnP-SPO-Migration"
$certOutPath   = Split-Path $csvFile
$appConfigFile = Join-Path $certOutPath "pnp-auth.json"
$tenantPrefix  = ($srcAdminUrl -replace 'https://', '' -replace '-admin\.sharepoint\.com.*', '')
$tenantDomain  = "$tenantPrefix.onmicrosoft.com"
# ─────────────────────────────────────────────────────────────────────────────

if (-not (Test-Path $csvFile)) {
    throw "CSV not found: $csvFile"
}

$csv = Import-Csv -Path $csvFile | Where-Object {
    $_.'Site address' -and $_.'Site address'.Trim() -ne ''
}

if ($csv.Count -eq 0) {
    throw "No valid rows found in CSV. Check that the 'Site address' column is populated."
}

$targetLockState = if ($Unlock) { 'Unlock' } else { 'ReadOnly' }

Write-Host ""
Write-Host "=== Set-SharePointSitesReadOnly ===" -ForegroundColor Cyan
Write-Host "CSV          : $csvFile"
Write-Host "Sites loaded : $($csv.Count)"
Write-Host "Action       : Set LockState = $targetLockState"
if ($WhatIfPreference) { Write-Host "WhatIf mode  : YES" -ForegroundColor Magenta }
Write-Host ""

# ── Authenticate ──────────────────────────────────────────────────────────────
Write-Host "Connecting to source tenant..." -ForegroundColor Yellow
try {
    $connected = $false

    if (Test-Path $appConfigFile) {
        $cfg = Get-Content $appConfigFile -Raw | ConvertFrom-Json
        if ($cfg.ClientId -and $cfg.Thumbprint) {
            try {
                Connect-PnPOnline -Url $srcAdminUrl -Tenant $tenantDomain `
                    -ClientId $cfg.ClientId -Thumbprint $cfg.Thumbprint -ErrorAction Stop
                Write-Host "Connected (using saved app registration)" -ForegroundColor Green
                $connected = $true
            }
            catch {
                Write-Host "  Saved registration invalid, re-registering..." -ForegroundColor Yellow
            }
        }
    }

    if (-not $connected) {
        Write-Host "  No valid app registration found. Registering '$pnpAppName'..." -ForegroundColor Yellow
        Write-Host "  A code will appear below — open https://microsoft.com/devicelogin, enter it," -ForegroundColor Yellow
        Write-Host "  and sign in as SharePoint/Global Admin on the SOURCE tenant ($tenantDomain)." -ForegroundColor Yellow

        $reg = Register-PnPEntraIDApp `
            -ApplicationName $pnpAppName `
            -Tenant $tenantDomain `
            -DeviceLogin `
            -SharePointApplicationPermissions "Sites.FullControl.All" `
            -Store CurrentUser `
            -OutPath $certOutPath `
            -ErrorAction Stop

        $clientId = ($reg.PSObject.Properties | Where-Object { $_.Name -match 'ClientId' }).Value |
            Select-Object -First 1
        if (-not $clientId) { throw "Could not extract ClientId from registration output." }

        $cert = Get-ChildItem Cert:\CurrentUser\My |
            Where-Object { $_.Subject -like "*$pnpAppName*" } |
            Sort-Object NotBefore -Descending |
            Select-Object -First 1
        if (-not $cert) { throw "Certificate for '$pnpAppName' not found in cert store after registration." }

        # Save config before connecting so it isn't lost if connect fails
        @{ ClientId = $clientId; Thumbprint = $cert.Thumbprint } |
            ConvertTo-Json | Set-Content $appConfigFile -Encoding UTF8
        Write-Host "  App registered. Config saved to: $appConfigFile" -ForegroundColor Green

        # Grant admin consent via browser — required before certificate auth will work
        $consentUrl = "https://login.microsoftonline.com/$tenantDomain/adminconsent?client_id=$clientId"
        Write-Host ""
        Write-Host "  STEP 2 of 2: Admin consent required." -ForegroundColor Yellow
        Write-Host "  Opening browser to grant consent. Sign in as admin, click Accept." -ForegroundColor Yellow
        Start-Process $consentUrl
        Read-Host "  Press Enter once you have accepted consent in the browser"

        Connect-PnPOnline -Url $srcAdminUrl -Tenant $tenantDomain `
            -ClientId $clientId -Thumbprint $cert.Thumbprint -ErrorAction Stop
        Write-Host "Connected to source tenant" -ForegroundColor Green
    }
}
catch {
    Write-Host "ERROR: Failed to connect to source tenant: $($_.Exception.Message)" -ForegroundColor Red
    exit 1
}
Write-Host ""

# ── Main loop ─────────────────────────────────────────────────────────────────

$results = [System.Collections.Generic.List[PSCustomObject]]::new()

foreach ($row in $csv) {
    $siteUrl   = $row.'Site address'.Trim()
    $siteTitle = $row.Title.Trim()

    Write-Host "Processing: $siteTitle" -ForegroundColor White
    Write-Host "  URL: $siteUrl" -NoNewline

    try {
        $site = Get-PnPTenantSite -Url $siteUrl -ErrorAction Stop
    }
    catch {
        Write-Host "  [SKIP — site not found or no access: $($_.Exception.Message)]" -ForegroundColor Yellow
        $results.Add([PSCustomObject]@{
            Title       = $siteTitle
            SiteUrl     = $siteUrl
            CurrentLock = 'UNKNOWN'
            TargetLock  = $targetLockState
            Status      = 'SKIPPED'
            Reason      = $_.Exception.Message
        })
        continue
    }

    $currentLock = $site.LockState

    if ($currentLock -eq $targetLockState) {
        Write-Host "  [ALREADY $targetLockState]" -ForegroundColor Green
        $results.Add([PSCustomObject]@{
            Title       = $siteTitle
            SiteUrl     = $siteUrl
            CurrentLock = $currentLock
            TargetLock  = $targetLockState
            Status      = 'ALREADY_SET'
            Reason      = 'No change required'
        })
        continue
    }

    try {
        if ($PSCmdlet.ShouldProcess($siteUrl, "Set LockState from '$currentLock' to '$targetLockState'")) {
            Set-PnPTenantSite -Url $siteUrl -LockState $targetLockState -ErrorAction Stop

            Write-Host "  [OK — $currentLock → $targetLockState]" -ForegroundColor Green
            $results.Add([PSCustomObject]@{
                Title       = $siteTitle
                SiteUrl     = $siteUrl
                CurrentLock = $currentLock
                TargetLock  = $targetLockState
                Status      = 'SUCCESS'
                Reason      = ''
            })
        }
        else {
            Write-Host "  [WHATIF — would set $currentLock → $targetLockState]" -ForegroundColor DarkCyan
            $results.Add([PSCustomObject]@{
                Title       = $siteTitle
                SiteUrl     = $siteUrl
                CurrentLock = $currentLock
                TargetLock  = $targetLockState
                Status      = 'WHATIF'
                Reason      = 'WhatIf — no change made'
            })
        }
    }
    catch {
        Write-Host "  [ERROR: $($_.Exception.Message)]" -ForegroundColor Red
        $results.Add([PSCustomObject]@{
            Title       = $siteTitle
            SiteUrl     = $siteUrl
            CurrentLock = $currentLock
            TargetLock  = $targetLockState
            Status      = 'ERROR'
            Reason      = $_.Exception.Message
        })
    }
}

# ── Summary & export ──────────────────────────────────────────────────────────

Write-Host ""
Write-Host "=== Summary ===" -ForegroundColor Cyan

$success    = ($results | Where-Object Status -eq 'SUCCESS').Count
$alreadySet = ($results | Where-Object Status -eq 'ALREADY_SET').Count
$skipped    = ($results | Where-Object Status -eq 'SKIPPED').Count
$errors     = ($results | Where-Object Status -eq 'ERROR').Count
$whatif     = ($results | Where-Object Status -eq 'WHATIF').Count

Write-Host "SUCCESS      : $success"
Write-Host "ALREADY SET  : $alreadySet"
Write-Host "WHATIF       : $whatif"
Write-Host "SKIPPED      : $skipped"
Write-Host "ERROR        : $errors"

$reportPath = Join-Path (Split-Path $csvFile) "SiteReadOnlyReport_$(Get-Date -Format 'yyyyMMdd_HHmmss').csv"
$results | Export-Csv -Path $reportPath -NoTypeInformation -Encoding UTF8
Write-Host ""
Write-Host "Report saved : $reportPath" -ForegroundColor Cyan

if ($errors -gt 0) {
    Write-Host ""
    Write-Host "[BLOCKER] $errors site(s) failed. Review report before proceeding." -ForegroundColor Red
}

if ($skipped -gt 0) {
    Write-Host ""
    Write-Host "[WARNING] $skipped site(s) not found or inaccessible. Verify URLs in source tenant." -ForegroundColor Yellow
}

Write-Host ""
if ($Unlock) {
    Write-Host "Sites are now UNLOCKED. Writes are re-enabled on all successfully processed sites." -ForegroundColor Yellow
} else {
    Write-Host "Sites are now READ-ONLY. To revert, re-run with -Unlock." -ForegroundColor Cyan
}
