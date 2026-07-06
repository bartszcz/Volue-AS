<#
.SYNOPSIS
    Monitors hardware hash collection progress in Azure Storage
.DESCRIPTION
    Checks Azure Storage container for uploaded device hashes
    Generates progress reports and identifies missing devices
.NOTES
    Run periodically during collection phase (daily recommended)
#>

#Requires -Modules Az.Storage, Az.Accounts

Write-Host "=====================================" -ForegroundColor Cyan
Write-Host "Monitor Hash Collection Progress" -ForegroundColor Cyan
Write-Host "=====================================" -ForegroundColor Cyan
Write-Host ""

# Check for config file
$configPath = "output/storage-config-SECURE.txt"
if (!(Test-Path $configPath)) {
    Write-Host "Error: Storage configuration not found!" -ForegroundColor Red
    Write-Host "Please run: scripts/01-setup-azure-storage.ps1 first" -ForegroundColor Yellow
    exit 1
}

# Read configuration
$configContent = Get-Content $configPath -Raw
if ($configContent -match 'Storage Account: (.+)') {
    $storageAccountName = $matches[1].Trim()
}
if ($configContent -match 'Container: (.+)') {
    $containerName = $matches[1].Trim()
}
if ($configContent -match 'Resource Group: (.+)') {
    $resourceGroupName = $matches[1].Trim()
}

# Connect to Azure
Write-Host "Connecting to Azure..." -ForegroundColor Cyan
try {
    $context = Get-AzContext
    if (!$context) {
        Connect-AzAccount
    }
    Write-Host "Connected: $($context.Subscription.Name)" -ForegroundColor Green
} catch {
    Write-Host "Failed to connect to Azure" -ForegroundColor Red
    exit 1
}

# Get storage context
Write-Host "Accessing storage account..." -ForegroundColor Cyan
try {
    $storageAccount = Get-AzStorageAccount -ResourceGroupName $resourceGroupName -Name $storageAccountName
    $ctx = $storageAccount.Context
} catch {
    Write-Host "Failed to access storage account: $($_.Exception.Message)" -ForegroundColor Red
    exit 1
}

# List all blobs
Write-Host "Retrieving collected device hashes..." -ForegroundColor Cyan
Write-Host ""

try {
    $blobs = Get-AzStorageBlob -Container $containerName -Context $ctx
    
    if ($blobs.Count -eq 0) {
        Write-Host "No devices have reported in yet." -ForegroundColor Yellow
        Write-Host ""
        Write-Host "Possible reasons:" -ForegroundColor Gray
        Write-Host "  - Devices haven't checked in with Intune yet (wait 8-24 hours)" -ForegroundColor Gray
        Write-Host "  - Script not deployed to devices yet" -ForegroundColor Gray
        Write-Host "  - Network connectivity issues from source devices" -ForegroundColor Gray
        Write-Host "  - SAS token expired or invalid" -ForegroundColor Gray
        exit 0
    }
    
    # Display summary
    Write-Host "=====================================" -ForegroundColor Cyan
    Write-Host "Collection Summary" -ForegroundColor Green
    Write-Host "=====================================" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "Total devices collected: $($blobs.Count)" -ForegroundColor White
    Write-Host ""
    
    # Analyze by date
    $today = Get-Date
    $blobsByDate = $blobs | Group-Object { $_.LastModified.Date }
    
    Write-Host "Collection by date:" -ForegroundColor Yellow
    foreach ($group in ($blobsByDate | Sort-Object Name -Descending)) {
        $date = [DateTime]$group.Name
        $daysAgo = ($today.Date - $date).Days
        $ageText = if ($daysAgo -eq 0) { "Today" } elseif ($daysAgo -eq 1) { "Yesterday" } else { "$daysAgo days ago" }
        Write-Host "  $($date.ToString('yyyy-MM-dd')): $($group.Count) devices ($ageText)" -ForegroundColor White
    }
    Write-Host ""
    
    # Recent collections (last 24 hours)
    $yesterday = $today.AddDays(-1)
    $recentBlobs = $blobs | Where-Object { $_.LastModified -gt $yesterday }
    Write-Host "Collected in last 24 hours: $($recentBlobs.Count)" -ForegroundColor $(if ($recentBlobs.Count -gt 0) { "Green" } else { "Yellow" })
    Write-Host ""
    
    # Optional: Display device list
    $showList = Read-Host "Display device list? (Y/N)"
    if ($showList -eq 'Y') {
        Write-Host ""
        Write-Host "Collected Devices:" -ForegroundColor Yellow
        Write-Host "==================" -ForegroundColor Yellow
        
        $deviceList = $blobs | Sort-Object LastModified -Descending | Select-Object -First 50 | ForEach-Object {
            $deviceName = $_.Name -replace '_.*\.csv$', ''
            [PSCustomObject]@{
                'Device Name' = $deviceName
                'Collected' = $_.LastModified.ToString('yyyy-MM-dd HH:mm')
                'Size (KB)' = [math]::Round($_.Length / 1KB, 2)
            }
        }
        
        $deviceList | Format-Table -AutoSize
        
        if ($blobs.Count -gt 50) {
            Write-Host "(Showing 50 most recent, total: $($blobs.Count))" -ForegroundColor Gray
        }
    }
    
    # Generate report file
    Write-Host ""
    Write-Host "Generating progress report..." -ForegroundColor Cyan
    
    $reportPath = "output/collection-progress-$(Get-Date -Format 'yyyyMMdd_HHmmss').txt"
    
    $report = @"
====================================
Autopilot Hash Collection Progress
====================================
Generated: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')

Summary:
--------
Total Devices Collected: $($blobs.Count)
Collection Period: $($blobs[0].LastModified.ToString('yyyy-MM-dd')) to $($blobs[-1].LastModified.ToString('yyyy-MM-dd'))
Last 24 Hours: $($recentBlobs.Count) devices

Collection by Date:
-------------------
$($blobsByDate | Sort-Object Name -Descending | ForEach-Object { 
    $date = [DateTime]$_.Name
    "  $($date.ToString('yyyy-MM-dd')): $($_.Count) devices"
} | Out-String)

Device List:
------------
$($blobs | Sort-Object LastModified -Descending | ForEach-Object {
    $deviceName = $_.Name -replace '_.*\.csv$', ''
    "  $deviceName - $($_.LastModified.ToString('yyyy-MM-dd HH:mm'))"
} | Out-String)

====================================
Next Steps:
====================================
- Continue monitoring for remaining devices
- Typical collection: 7 days for 95%+ coverage
- When satisfied, run: scripts/04-consolidate-hashes.ps1

"@
    
    $report | Out-File -FilePath $reportPath -Encoding UTF8
    Write-Host "Report saved: $reportPath" -ForegroundColor Green
    
} catch {
    Write-Host "Error: $($_.Exception.Message)" -ForegroundColor Red
    exit 1
}

Write-Host ""
Write-Host "=====================================" -ForegroundColor Cyan
Write-Host "Next Steps" -ForegroundColor Yellow
Write-Host "=====================================" -ForegroundColor Cyan
Write-Host ""

if ($blobs.Count -lt 10) {
    Write-Host "⏳ Wait for more devices to report in (check daily)" -ForegroundColor Yellow
    Write-Host "   Run this script again tomorrow" -ForegroundColor Gray
} else {
    Write-Host "✓ Good progress! Continue monitoring" -ForegroundColor Green
    Write-Host "   When collection complete, run:" -ForegroundColor Gray
    Write-Host "   .\scripts\04-consolidate-hashes.ps1" -ForegroundColor White
}

Write-Host ""
