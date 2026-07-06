# ============================================================
# Repair-MissingServicePrincipals.ps1
#
# Finds app registrations in the current tenant that have no
# corresponding Service Principal (Enterprise App) and creates
# the missing ones.
#
# USAGE:
#   .\Repair-MissingServicePrincipals.ps1
#   .\Repair-MissingServicePrincipals.ps1 -DisplayNameFilter "Grafana*"
#   .\Repair-MissingServicePrincipals.ps1 -AppIds @("client-id-1","client-id-2")
#   .\Repair-MissingServicePrincipals.ps1 -DryRun
#
# REQUIREMENTS:
#   Install-Module Microsoft.Graph -Scope CurrentUser
# ============================================================

#Requires -Modules Microsoft.Graph.Applications, Microsoft.Graph.Authentication

[CmdletBinding()]
param(
    [Parameter(HelpMessage = "Only check apps whose display name matches this wildcard (e.g. 'Grafana*')")]
    [string] $DisplayNameFilter,

    [Parameter(HelpMessage = "Only check specific app Client IDs (appId, not objectId)")]
    [string[]] $AppIds,

    [Parameter(HelpMessage = "Show what would be fixed without making any changes")]
    [switch] $DryRun
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Write-Section($title) {
    Write-Host ""
    Write-Host "━━━ $title ━━━" -ForegroundColor Cyan
}

# -----------------------------------------------------------
# Connect
# -----------------------------------------------------------
Write-Section "Connecting to Microsoft Graph"

Connect-MgGraph -Scopes "Application.ReadWrite.All", "AppRoleAssignment.ReadWrite.All" -NoWelcome

$tenantId = (Get-MgContext).TenantId
$account  = (Get-MgContext).Account
Write-Host "Connected as : $account"
Write-Host "Tenant       : $tenantId"

# -----------------------------------------------------------
# Get app registrations to check
# -----------------------------------------------------------
Write-Section "Scanning App Registrations"

if ($AppIds -and $AppIds.Count -gt 0) {
    # Fetch specific apps by client ID
    $apps = @()
    foreach ($id in $AppIds) {
        $app = Get-MgApplication -Filter "appId eq '$id'" -ErrorAction SilentlyContinue
        if ($app) { $apps += $app }
        else { Write-Warning "App with AppId '$id' not found — skipping." }
    }
} elseif ($DisplayNameFilter) {
    $apps = @(Get-MgApplication -All | Where-Object { $_.DisplayName -like $DisplayNameFilter })
} else {
    # No filter — scan all app registrations
    Write-Host "No filter specified — scanning ALL app registrations in the tenant." -ForegroundColor Yellow
    Write-Host "This may take a moment..." -ForegroundColor Yellow
    $apps = @(Get-MgApplication -All)
}

Write-Host "Found $($apps.Count) app registration(s) to check."

# -----------------------------------------------------------
# Find which ones are missing a Service Principal
# -----------------------------------------------------------
Write-Section "Checking for Missing Service Principals"

$missing    = @()
$missingTag = @()

foreach ($app in $apps) {
    $sp = Get-MgServicePrincipal -Filter "appId eq '$($app.AppId)'" -ErrorAction SilentlyContinue
    if (-not $sp) {
        $missing += $app
        Write-Host "  ✗ MISSING SP : $($app.DisplayName) (AppId: $($app.AppId))" -ForegroundColor Yellow
    } elseif (@($sp.Tags) -notcontains "WindowsAzureActiveDirectoryIntegratedApp") {
        $missingTag += $sp
        Write-Host "  ⚠ HIDDEN SP  : $($app.DisplayName) — SP exists but missing portal visibility tag" -ForegroundColor Yellow
    } else {
        Write-Host "  ✓ OK         : $($app.DisplayName)" -ForegroundColor Green
    }
}

if ($missing.Count -eq 0 -and $missingTag.Count -eq 0) {
    Write-Host ""
    Write-Host "All app registrations already have a visible Service Principal. Nothing to fix." -ForegroundColor Green
    exit 0
}

Write-Host ""
if ($missing.Count -gt 0)    { Write-Host "  $($missing.Count) app(s) are missing a Service Principal." -ForegroundColor Yellow }
if ($missingTag.Count -gt 0) { Write-Host "  $($missingTag.Count) SP(s) exist but are hidden from the Enterprise Apps portal blade." -ForegroundColor Yellow }

if ($DryRun) {
    Write-Host ""
    Write-Host "DRY RUN — no changes made. Remove -DryRun to fix." -ForegroundColor Cyan
    exit 0
}

# -----------------------------------------------------------
# Create missing Service Principals
# -----------------------------------------------------------
Write-Section "Creating Missing Service Principals"

$results = @()

foreach ($app in $missing) {
    Write-Host ""
    Write-Host "  Creating SP for: $($app.DisplayName)..." -NoNewline

    try {
        $sp = New-MgServicePrincipal `
            -AppId $app.AppId `
            -DisplayName $app.DisplayName `
            -Tags @("HideApp", "WindowsAzureActiveDirectoryIntegratedApp") `
            -AppRoleAssignmentRequired $false

        Write-Host " Done" -ForegroundColor Green
        Write-Host "    SP Object ID   : $($sp.Id)"
        Write-Host "    Enterprise App : https://portal.azure.com/#view/Microsoft_AAD_IAM/ManagedAppMenuBlade/~/Overview/objectId/$($sp.Id)" -ForegroundColor Cyan

        $results += [ordered]@{
            DisplayName        = $app.DisplayName
            ClientId           = $app.AppId
            AppRegistrationId  = $app.Id
            ServicePrincipalId = $sp.Id
            Status             = "Created"
            EnterpriseAppUrl   = "https://portal.azure.com/#view/Microsoft_AAD_IAM/ManagedAppMenuBlade/~/Overview/objectId/$($sp.Id)"
        }
    } catch {
        Write-Host " FAILED" -ForegroundColor Red
        Write-Warning "  Error: $_"
        $results += [ordered]@{
            DisplayName        = $app.DisplayName
            ClientId           = $app.AppId
            AppRegistrationId  = $app.Id
            ServicePrincipalId = $null
            Status             = "Failed: $_"
            EnterpriseAppUrl   = $null
        }
    }
}

# -----------------------------------------------------------
# Fix hidden Service Principals (missing portal visibility tag)
# -----------------------------------------------------------
if ($missingTag.Count -gt 0) {
    Write-Section "Fixing Hidden Service Principals"

    foreach ($sp in $missingTag) {
        Write-Host ""
        Write-Host "  Adding visibility tag to: $($sp.DisplayName)..." -NoNewline
        try {
            $updatedTags = @($sp.Tags) + "WindowsAzureActiveDirectoryIntegratedApp"
            Update-MgServicePrincipal -ServicePrincipalId $sp.Id -Tags $updatedTags
            Write-Host " Done" -ForegroundColor Green
            Write-Host "    Enterprise App : https://portal.azure.com/#view/Microsoft_AAD_IAM/ManagedAppMenuBlade/~/Overview/objectId/$($sp.Id)" -ForegroundColor Cyan

            $results += [ordered]@{
                DisplayName        = $sp.DisplayName
                ClientId           = $sp.AppId
                AppRegistrationId  = $null
                ServicePrincipalId = $sp.Id
                Status             = "TagFixed"
                EnterpriseAppUrl   = "https://portal.azure.com/#view/Microsoft_AAD_IAM/ManagedAppMenuBlade/~/Overview/objectId/$($sp.Id)"
            }
        } catch {
            Write-Host " FAILED" -ForegroundColor Red
            Write-Warning "  Error: $_"
            $results += [ordered]@{
                DisplayName        = $sp.DisplayName
                ClientId           = $sp.AppId
                AppRegistrationId  = $null
                ServicePrincipalId = $sp.Id
                Status             = "TagFailed: $_"
                EnterpriseAppUrl   = $null
            }
        }
    }
}

# -----------------------------------------------------------
# Summary
# -----------------------------------------------------------
Write-Section "Summary"

$created  = @($results | Where-Object { $_.Status -eq "Created" })
$tagFixed = @($results | Where-Object { $_.Status -eq "TagFixed" })
$failed   = @($results | Where-Object { $_.Status -notin @("Created", "TagFixed") })

Write-Host "  Created   : $($created.Count)" -ForegroundColor Green
Write-Host "  Tag fixed : $($tagFixed.Count)" -ForegroundColor Green
if ($failed.Count -gt 0) {
    Write-Host "  Failed    : $($failed.Count)" -ForegroundColor Red
    $failed | ForEach-Object { Write-Host "    - $($_.DisplayName): $($_.Status)" -ForegroundColor Red }
}

# Save results
$runStamp  = Get-Date -Format "yyyy-MM-dd_HHmmss"
$outputDir = Join-Path $PSScriptRoot "output\repair\$runStamp"
New-Item -ItemType Directory -Path $outputDir -Force | Out-Null
$outputPath = Join-Path $outputDir "results.json"
$results | ConvertTo-Json -Depth 5 | Out-File -FilePath $outputPath -Encoding utf8
Write-Host ""
Write-Host "Results saved to: $outputPath" -ForegroundColor Cyan
Write-Host ""
Write-Host "Next steps for each fixed app:" -ForegroundColor Cyan
Write-Host "  1. Grant admin consent in the portal"
Write-Host "  2. Assign users/groups to app roles if needed"