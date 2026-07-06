<#
.SYNOPSIS
    Consolidates collected hardware hashes into single import file
.DESCRIPTION
    Downloads all CSV files from Azure Storage and merges into one
    Removes duplicates and validates hash format
    Creates import-ready CSV for Autopilot
.NOTES
    Run after collection period complete
#>

#Requires -Modules Az.Storage, Az.Accounts

Write-Host "=====================================" -ForegroundColor Cyan
Write-Host "Consolidate Hardware Hashes" -ForegroundColor Cyan
Write-Host "=====================================" -ForegroundColor Cyan
Write-Host ""

# Configuration
$configPath = "output/storage-config-SECURE.txt"
if (!(Test-Path $configPath)) {
    Write-Host "Error: Storage configuration not found!" -ForegroundColor Red
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

# Create download directory
$downloadPath = "output/downloaded-hashes"
if (!(Test-Path $downloadPath)) {
    New-Item -ItemType Directory -Path $downloadPath -Force | Out-Null
}

# Connect to Azure
Write-Host "Connecting to Azure..." -ForegroundColor Cyan
try {
    $context = Get-AzContext
    if (!$context) {
        Connect-AzAccount
    }
    $storageAccount = Get-AzStorageAccount -ResourceGroupName $resourceGroupName -Name $storageAccountName
    $ctx = $storageAccount.Context
    Write-Host "Connected successfully" -ForegroundColor Green
} catch {
    Write-Host "Failed to connect: $($_.Exception.Message)" -ForegroundColor Red
    exit 1
}

# Download all CSV files
Write-Host ""
Write-Host "Downloading device hash files..." -ForegroundColor Cyan

try {
    $blobs = Get-AzStorageBlob -Container $containerName -Context $ctx
    
    if ($blobs.Count -eq 0) {
        Write-Host "No hash files found in storage!" -ForegroundColor Red
        Write-Host "Run: scripts/03-monitor-collection.ps1 to check status" -ForegroundColor Yellow
        exit 1
    }
    
    Write-Host "Found $($blobs.Count) device hash files" -ForegroundColor Green
    Write-Host "Downloading..." -ForegroundColor Cyan
    
    $downloadedCount = 0
    foreach ($blob in $blobs) {
        $destinationPath = Join-Path $downloadPath $blob.Name
        Get-AzStorageBlobContent -Blob $blob.Name -Container $containerName -Context $ctx -Destination $destinationPath -Force | Out-Null
        $downloadedCount++
        
        if ($downloadedCount % 10 -eq 0) {
            Write-Host "  Downloaded $downloadedCount of $($blobs.Count)..." -ForegroundColor Gray
        }
    }
    
    Write-Host "Download complete: $downloadedCount files" -ForegroundColor Green
    
} catch {
    Write-Host "Download failed: $($_.Exception.Message)" -ForegroundColor Red
    exit 1
}

# Consolidate CSV files
Write-Host ""
Write-Host "Consolidating hash data..." -ForegroundColor Cyan

try {
    $allHashes = @()
    $csvFiles = Get-ChildItem -Path $downloadPath -Filter "*.csv"
    
    foreach ($file in $csvFiles) {
        $data = Import-Csv $file.FullName
        $allHashes += $data
    }
    
    Write-Host "Loaded $($allHashes.Count) device records" -ForegroundColor Green
    
    # Remove duplicates by serial number
    $uniqueHashes = $allHashes | Sort-Object 'Device Serial Number' -Unique
    $duplicateCount = $allHashes.Count - $uniqueHashes.Count
    
    if ($duplicateCount -gt 0) {
        Write-Host "Removed $duplicateCount duplicate entries" -ForegroundColor Yellow
    }
    
    Write-Host "Final device count: $($uniqueHashes.Count)" -ForegroundColor Green
    
} catch {
    Write-Host "Consolidation failed: $($_.Exception.Message)" -ForegroundColor Red
    exit 1
}

# Validate hash data
Write-Host ""
Write-Host "Validating hash data..." -ForegroundColor Cyan

$missingHashes = $uniqueHashes | Where-Object { [string]::IsNullOrWhiteSpace($_.'Hardware Hash') }
$missingSerials = $uniqueHashes | Where-Object { [string]::IsNullOrWhiteSpace($_.'Device Serial Number') }

if ($missingHashes.Count -gt 0) {
    Write-Host "⚠️  Warning: $($missingHashes.Count) devices missing hardware hash" -ForegroundColor Yellow
    $missingHashes | Select-Object 'Device Name', 'Device Serial Number' | Format-Table
}

if ($missingSerials.Count -gt 0) {
    Write-Host "⚠️  Warning: $($missingSerials.Count) devices missing serial number" -ForegroundColor Yellow
}

$validHashes = $uniqueHashes | Where-Object { 
    ![string]::IsNullOrWhiteSpace($_.'Hardware Hash') -and 
    ![string]::IsNullOrWhiteSpace($_.'Device Serial Number')
}

Write-Host "Valid devices ready for import: $($validHashes.Count)" -ForegroundColor Green

# Generate statistics
Write-Host ""
Write-Host "Device Statistics:" -ForegroundColor Yellow
$manufacturerStats = $validHashes | Group-Object Manufacturer | Sort-Object Count -Descending
foreach ($stat in $manufacturerStats) {
    Write-Host "  $($stat.Name): $($stat.Count) devices" -ForegroundColor White
}

# Export consolidated file
Write-Host ""
Write-Host "Exporting consolidated file..." -ForegroundColor Cyan

$timestamp = Get-Date -Format 'yyyyMMdd_HHmmss'
$outputFile = "output/ConsolidatedAutopilotHashes_$timestamp.csv"

$validHashes | Select-Object `
    'Device Serial Number',
    'Windows Product ID',
    'Hardware Hash',
    'Manufacturer',
    'Model',
    'Device Name',
    'Group Tag' | Export-Csv -Path $outputFile -NoTypeInformation -Encoding UTF8

Write-Host "Consolidated file created: $outputFile" -ForegroundColor Green

# Generate summary report
$reportPath = "output/consolidation-report-$timestamp.txt"
$report = @"
====================================
Autopilot Hash Consolidation Report
====================================
Generated: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')

Summary:
--------
Total files downloaded: $($blobs.Count)
Total device records: $($allHashes.Count)
Duplicate entries removed: $duplicateCount
Unique devices: $($uniqueHashes.Count)
Valid devices (ready for import): $($validHashes.Count)

Issues Found:
-------------
Missing hardware hash: $($missingHashes.Count)
Missing serial number: $($missingSerials.Count)

Manufacturer Breakdown:
-----------------------
$($manufacturerStats | ForEach-Object { "  $($_.Name): $($_.Count) devices" } | Out-String)

Output Files:
-------------
Consolidated CSV: $outputFile
This report: $reportPath

====================================
Next Steps:
====================================
1. Review the consolidated CSV file
2. Verify device count matches expectations
3. Run: scripts/05-import-to-autopilot.ps1
4. Import the CSV to target tenant Autopilot

"@

$report | Out-File -FilePath $reportPath -Encoding UTF8
Write-Host "Report saved: $reportPath" -ForegroundColor Green

Write-Host ""
Write-Host "=====================================" -ForegroundColor Cyan
Write-Host "Consolidation Complete!" -ForegroundColor Green
Write-Host "=====================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "Next Step:" -ForegroundColor Yellow
Write-Host "  Run: .\scripts\05-import-to-autopilot.ps1" -ForegroundColor White
Write-Host ""
Write-Host "The script will import $($validHashes.Count) devices to your Autopilot service." -ForegroundColor Gray
Write-Host ""
