#Requires -Modules Microsoft.Online.SharePoint.PowerShell

<#
.SYNOPSIS
    SharePoint Online site inventory for tenant-to-tenant migration planning.
    Uses SPO Management Shell only -- no Entra app registration required.

.PARAMETER AdminUrl
    SharePoint admin center URL (e.g., https://contoso-admin.sharepoint.com)

.EXAMPLE
    .\Get-SiteInventory.ps1 -AdminUrl "https://hakom-admin.sharepoint.com"
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true, HelpMessage = "SharePoint admin URL, e.g. https://contoso-admin.sharepoint.com")]
    [ValidatePattern('^https:\/\/.+-admin\.sharepoint\.com\/?$')]
    [string]$AdminUrl,

    [Parameter(Mandatory = $false)]
    [string]$OutputPath,

    [switch]$IncludeOneDrive,
    [switch]$SkipSystemSiteFilter
)

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------
$systemTemplates = @(
    'SRCHCENTERLITE#0'
    'SPSMSITEHOST#0'
    'POINTPUBLISHINGHUB#0'
    'APPCATALOG#0'
    'EHS#1'
    'EDISC#0'
    'RedirectSite#0'
    'POINTPUBLISHINGTOPIC#0'
)

$tenantName = ($AdminUrl -replace 'https://' -replace '-admin\.sharepoint\.com/?', '')
if (-not $OutputPath) {
    $timestamp = Get-Date -Format "yyyy-MM-dd_HHmmss"
    $OutputPath = ".\SiteInventory_${tenantName}_${timestamp}.csv"
}

# ---------------------------------------------------------------------------
# Connect
# ---------------------------------------------------------------------------
Write-Host "`n=== SharePoint Site Inventory ===" -ForegroundColor Cyan
Write-Host "Tenant : $tenantName"
Write-Host "Admin  : $AdminUrl"
Write-Host "Output : $OutputPath`n"

try {
    Write-Host "Connecting to $AdminUrl ..." -ForegroundColor Yellow
    Connect-SPOService -Url $AdminUrl -ErrorAction Stop
    Write-Host "Connected.`n" -ForegroundColor Green
} catch {
    Write-Error "Failed to connect: $_"
    exit 1
}

# ---------------------------------------------------------------------------
# Fetch sites
# ---------------------------------------------------------------------------
Write-Host "Fetching site collections..." -ForegroundColor Yellow
$sites = Get-SPOSite -Limit All -Detailed

# Filter OneDrive
if (-not $IncludeOneDrive) {
    $sites = $sites | Where-Object { $_.Url -notlike "*-my.sharepoint.com/personal/*" }
}

# Filter system sites
if (-not $SkipSystemSiteFilter) {
    $before = $sites.Count
    $sites = $sites | Where-Object { $_.Template -notin $systemTemplates }
    $filtered = $before - $sites.Count
    if ($filtered -gt 0) {
        Write-Host "Filtered out $filtered system/infrastructure sites." -ForegroundColor DarkGray
    }
}

Write-Host "Processing $($sites.Count) sites...`n" -ForegroundColor Yellow

# ---------------------------------------------------------------------------
# Build report with owners
# ---------------------------------------------------------------------------
$report  = [System.Collections.Generic.List[PSObject]]::new()
$errors  = [System.Collections.Generic.List[string]]::new()
$counter = 0

foreach ($site in $sites) {
    $counter++
    $pct = [math]::Round(($counter / $sites.Count) * 100)
    Write-Progress -Activity "Processing sites" -Status "$counter / $($sites.Count) - $($site.Url)" -PercentComplete $pct

    # --- Fetch site collection admins (owners) ---
    $siteOwners = ""
    $siteAdmins = ""
    try {
        $admins = Get-SPOUser -Site $site.Url -Limit All -ErrorAction Stop |
                  Where-Object { $_.IsSiteAdmin -eq $true }

        $siteAdmins = ($admins | Select-Object -ExpandProperty DisplayName) -join "; "

        # Primary owner from the site property, rest are additional admins
        $siteOwners = $site.Owner
    } catch {
        $siteOwners = $site.Owner
        $siteAdmins = "(Access denied or unable to retrieve)"
        $errors.Add("$($site.Url) - $($_.Exception.Message)")
    }

    # --- Size formatting ---
    $sizeMB = [math]::Round($site.StorageUsageCurrent, 2)
    $sizeGB = [math]::Round($site.StorageUsageCurrent / 1024, 2)
    $sizeDisplay = if ($sizeMB -ge 1024) { "${sizeGB} GB" } else { "${sizeMB} MB" }

    $report.Add([PSCustomObject]@{
        'Title'               = $site.Title
        'URL'                 = $site.Url
        'Description'         = $site.Description
        'Template'            = $site.Template
        'Size (MB)'           = $sizeMB
        'Size (Friendly)'     = $sizeDisplay
        'Owner (Primary)'     = $siteOwners
        'Site Admins'         = $siteAdmins
        'Created'             = if ($site.Created) { $site.Created.ToString("yyyy-MM-dd") } else { "N/A" }
        'Last Modified'       = if ($site.LastContentModifiedDate) { $site.LastContentModifiedDate.ToString("yyyy-MM-dd") } else { "N/A" }
        'Days Since Modified' = if ($site.LastContentModifiedDate) {
                                    [math]::Round(((Get-Date) - $site.LastContentModifiedDate).TotalDays)
                                } else { "N/A" }
        'Sharing Capability'  = $site.SharingCapability
        'Lock State'          = $site.LockState
        'Is Hub Site'         = if ($site.IsHubSite) { "Yes" } else { "No" }
        'Storage Quota (MB)'  = $site.StorageQuota
        'Storage Used %'      = if ($site.StorageQuota -gt 0) {
                                    [math]::Round(($site.StorageUsageCurrent / $site.StorageQuota) * 100, 1)
                                } else { "N/A" }
        'Is Group Connected'  = if ($site.GroupId -and $site.GroupId -ne [Guid]::Empty) { "Yes" } else { "No" }
        'Group ID'            = if ($site.GroupId -ne [Guid]::Empty) { $site.GroupId } else { "" }
    })
}

Write-Progress -Activity "Processing sites" -Completed

# ---------------------------------------------------------------------------
# Export
# ---------------------------------------------------------------------------
$report | Sort-Object 'Size (MB)' -Descending |
    Export-Csv -Path $OutputPath -NoTypeInformation -Encoding UTF8

Write-Host "`nExported $($report.Count) sites to: $OutputPath" -ForegroundColor Green

# --- Summary ---
$totalSizeMB = ($report | Measure-Object -Property 'Size (MB)' -Sum).Sum
$totalSizeGB = [math]::Round($totalSizeMB / 1024, 2)
$largest     = $report | Sort-Object 'Size (MB)' -Descending | Select-Object -First 1

Write-Host "`n--- Summary ---" -ForegroundColor Cyan
Write-Host "Total sites  : $($report.Count)"
Write-Host "Total size   : $totalSizeGB GB"
Write-Host "Largest site : $($largest.Title) - $($largest.'Size (Friendly)')"

if ($errors.Count -gt 0) {
    Write-Host "`nSites with access errors ($($errors.Count)):" -ForegroundColor DarkYellow
    $errors | ForEach-Object { Write-Host "  - $_" -ForegroundColor DarkYellow }
}

# ---------------------------------------------------------------------------
# Disconnect
# ---------------------------------------------------------------------------
try { Disconnect-SPOService -ErrorAction SilentlyContinue } catch {}
Write-Host "`nDone.`n" -ForegroundColor Green