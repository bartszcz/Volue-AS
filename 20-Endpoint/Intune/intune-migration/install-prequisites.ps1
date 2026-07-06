<#
.SYNOPSIS
    Installs required PowerShell modules for Autopilot migration project
.DESCRIPTION
    Installs Azure PowerShell, Microsoft Graph SDK, and other dependencies
    Run this once on the machine that will execute migration scripts
.NOTES
    Run as Administrator
    Internet connection required
#>

#Requires -RunAsAdministrator

Write-Host "=====================================" -ForegroundColor Cyan
Write-Host "Autopilot Migration - Prerequisites" -ForegroundColor Cyan
Write-Host "=====================================" -ForegroundColor Cyan
Write-Host ""

# Check PowerShell version
$psVersion = $PSVersionTable.PSVersion
Write-Host "PowerShell Version: $($psVersion.ToString())" -ForegroundColor Yellow

if ($psVersion.Major -lt 7) {
    Write-Warning "PowerShell 7+ recommended for best experience"
    Write-Host "Download from: https://aka.ms/powershell" -ForegroundColor Yellow
    $continue = Read-Host "Continue with PowerShell $($psVersion.Major)? (Y/N)"
    if ($continue -ne 'Y') { exit }
}

Write-Host ""

# Required modules
$requiredModules = @(
    @{ Name = 'Az.Storage'; Description = 'Azure Storage management' }
    @{ Name = 'Az.Accounts'; Description = 'Azure authentication' }
    @{ Name = 'Microsoft.Graph.Authentication'; Description = 'Microsoft Graph authentication' }
    @{ Name = 'Microsoft.Graph.DeviceManagement'; Description = 'Intune/Autopilot management' }
    @{ Name = 'Microsoft.Graph.Identity.DirectoryManagement'; Description = 'Azure AD device management' }
)

Write-Host "Checking and installing required modules..." -ForegroundColor Cyan
Write-Host ""

foreach ($module in $requiredModules) {
    Write-Host "Module: $($module.Name)" -ForegroundColor White
    Write-Host "  Purpose: $($module.Description)" -ForegroundColor Gray
    
    $installed = Get-Module -ListAvailable -Name $module.Name
    
    if ($installed) {
        Write-Host "  Status: Already installed (v$($installed[0].Version))" -ForegroundColor Green
    } else {
        Write-Host "  Status: Not found - installing..." -ForegroundColor Yellow
        try {
            Install-Module -Name $module.Name -Scope CurrentUser -Force -AllowClobber -ErrorAction Stop
            Write-Host "  Status: Installed successfully" -ForegroundColor Green
        } catch {
            Write-Host "  Status: Installation failed - $($_.Exception.Message)" -ForegroundColor Red
        }
    }
    Write-Host ""
}

Write-Host "=====================================" -ForegroundColor Cyan
Write-Host "Prerequisites check complete!" -ForegroundColor Green
Write-Host "=====================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "Next steps:" -ForegroundColor Yellow
Write-Host "  1. Run: scripts/01-setup-azure-storage.ps1" -ForegroundColor White
Write-Host "  2. Follow the migration plan in README.md" -ForegroundColor White
Write-Host ""
