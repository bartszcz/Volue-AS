<#
Purpose:
  Upgrade Windows PowerShell 5.1 to the latest PowerShell 7.x using winget.
  Installs silently, idempotent, and verifies installation.

Prerequisites:
  - Windows 10/11 with winget available.
  - Admin rights required for installation.

Parameters:
  -Version   Optional. Specific PowerShell version to install (e.g. "7.4.1").
             If omitted, installs the latest stable.
#>

param(
    [string]$Version
)

Write-Host "Checking for winget..." -ForegroundColor Cyan
if (-not (Get-Command winget.exe -ErrorAction SilentlyContinue)) {
    Write-Host "winget is not installed or not in PATH. Install App Installer from Microsoft Store." -ForegroundColor Red
    exit 1
}

Write-Host "Searching for PowerShell package..." -ForegroundColor Cyan
$pkg = winget search --source winget --exact --name "PowerShell" | Select-String "Microsoft.PowerShell"
if (-not $pkg) {
    Write-Host "PowerShell package not found in winget repository." -ForegroundColor Red
    exit 1
}

Write-Host "Installing PowerShell 7.x..." -ForegroundColor Yellow

try {
    if ($Version) {
        winget install Microsoft.PowerShell --exact --source winget --silent --accept-package-agreements --accept-source-agreements --version $Version
    }
    else {
        winget install Microsoft.PowerShell --exact --source winget --silent --accept-package-agreements --accept-source-agreements
    }
}
catch {
    Write-Host "Installation failed: $($_.Exception.Message)" -ForegroundColor Red
    exit 1
}

Write-Host "Installation complete. Verifying..." -ForegroundColor Cyan

$pwshexe = "$env:ProgramFiles\PowerShell\7\pwsh.exe"
if (Test-Path $pwshexe) {
    Write-Host "PowerShell installed at: $pwshexe" -ForegroundColor Green
    & $pwshexe -NoLogo -NoProfile -Command '$PSVersionTable'
}
else {
    Write-Host "PowerShell 7 not found in the expected directory." -ForegroundColor Red
}
