<#
.SYNOPSIS
    Imports consolidated hardware hashes to Windows Autopilot
.DESCRIPTION
    Uploads device hashes to target tenant's Windows Autopilot service
    Applies group tags and tracks import status
.NOTES
    Requires: Microsoft.Graph.DeviceManagement module
    Permissions: DeviceManagementServiceConfig.ReadWrite.All
#>

#Requires -Modules Microsoft.Graph.Authentication, Microsoft.Graph.DeviceManagement

Write-Host "=====================================" -ForegroundColor Cyan
Write-Host "Import Hashes to Windows Autopilot" -ForegroundColor Cyan
Write-Host "=====================================" -ForegroundColor Cyan
Write-Host ""

# Find the most recent consolidated file
$consolidatedFiles = Get-ChildItem -Path "output" -Filter "ConsolidatedAutopilotHashes_*.csv" | Sort-Object LastWriteTime -Descending

if ($consolidatedFiles.Count -eq 0) {
    Write-Host "Error: No consolidated hash file found!" -ForegroundColor Red
    Write-Host "Please run: scripts/04-consolidate-hashes.ps1 first" -ForegroundColor Yellow
    exit 1
}

$importFile = $consolidatedFiles[0].FullName
Write-Host "Using file: $($consolidatedFiles[0].Name)" -ForegroundColor Green
Write-Host ""

# Load devices from CSV
try {
    $devices = Import-Csv $importFile
    Write-Host "Loaded $($devices.Count) devices from CSV" -ForegroundColor Green
} catch {
    Write-Host "Failed to read CSV file: $($_.Exception.Message)" -ForegroundColor Red
    exit 1
}

# Optional: Override group tag
Write-Host ""
$customGroupTag = Read-Host "Enter custom Group Tag (or press Enter to use CSV values)"
if (![string]::IsNullOrWhiteSpace($customGroupTag)) {
    Write-Host "Will apply group tag: $customGroupTag" -ForegroundColor Yellow
}

# Confirm import
Write-Host ""
Write-Host "Ready to import $($devices.Count) devices to Windows Autopilot" -ForegroundColor Yellow
Write-Host ""
Write-Host "This will:" -ForegroundColor Gray
Write-Host "  - Register devices in your tenant's Autopilot service" -ForegroundColor Gray
Write-Host "  - Allow devices to be managed via Autopilot policies" -ForegroundColor Gray
Write-Host "  - Require device reset/reimage to enroll" -ForegroundColor Gray
Write-Host ""

$confirm = Read-Host "Proceed with import? (Y/N)"
if ($confirm -ne 'Y') {
    Write-Host "Import cancelled" -ForegroundColor Yellow
    exit 0
}

# Connect to Microsoft Graph
Write-Host ""
Write-Host "Connecting to Microsoft Graph..." -ForegroundColor Cyan
try {
    Connect-MgGraph -Scopes "DeviceManagementServiceConfig.ReadWrite.All" -NoWelcome
    $context = Get-MgContext
    Write-Host "Connected to tenant: $($context.TenantId)" -ForegroundColor Green
} catch {
    Write-Host "Failed to connect to Microsoft Graph: $($_.Exception.Message)" -ForegroundColor Red
    exit 1
}

# Import devices
Write-Host ""
Write-Host "Importing devices to Windows Autopilot..." -ForegroundColor Cyan
Write-Host "This may take several minutes for large device counts..." -ForegroundColor Gray
Write-Host ""

$successCount = 0
$failCount = 0
$skipCount = 0
$failedDevices = @()

$progress = 0
foreach ($device in $devices) {
    $progress++
    
    # Validate required fields
    if ([string]::IsNullOrWhiteSpace($device.'Device Serial Number') -or 
        [string]::IsNullOrWhiteSpace($device.'Hardware Hash')) {
        Write-Host "⊘ Skipped: $($device.'Device Name') - Missing required data" -ForegroundColor Gray
        $skipCount++
        continue
    }
    
    try {
        # Prepare device parameters
        $groupTag = if (![string]::IsNullOrWhiteSpace($customGroupTag)) {
            $customGroupTag
        } else {
            $device.'Group Tag'
        }
        
        $params = @{
            SerialNumber = $device.'Device Serial Number'
            HardwareIdentifier = $device.'Hardware Hash'
        }
        
        # Add optional fields
        if (![string]::IsNullOrWhiteSpace($groupTag)) {
            $params.GroupTag = $groupTag
        }
        if (![string]::IsNullOrWhiteSpace($device.'Windows Product ID')) {
            $params.ProductKey = $device.'Windows Product ID'
        }
        
        # Import to Autopilot
        New-MgDeviceManagementWindowsAutopilotDeviceIdentity -BodyParameter $params | Out-Null
        
        Write-Host "✓ Imported: $($device.'Device Name') (S/N: $($device.'Device Serial Number'))" -ForegroundColor Green
        $successCount++
        
        # Rate limiting
        if ($progress % 10 -eq 0) {
            Write-Host "  Progress: $progress of $($devices.Count)..." -ForegroundColor Gray
            Start-Sleep -Milliseconds 500
        }
        
    } catch {
        $errorMessage = $_.Exception.Message
        Write-Host "✗ Failed: $($device.'Device Name') - $errorMessage" -ForegroundColor Red
        $failCount++
        
        $failedDevices += [PSCustomObject]@{
            'Device Name' = $device.'Device Name'
            'Serial Number' = $device.'Device Serial Number'
            'Error' = $errorMessage
        }
    }
}

# Display summary
Write-Host ""
Write-Host "=====================================" -ForegroundColor Cyan
Write-Host "Import Complete" -ForegroundColor Green
Write-Host "=====================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "Summary:" -ForegroundColor Yellow
Write-Host "  ✓ Successfully imported: $successCount" -ForegroundColor Green
Write-Host "  ✗ Failed: $failCount" -ForegroundColor $(if ($failCount -gt 0) { "Red" } else { "Gray" })
Write-Host "  ⊘ Skipped: $skipCount" -ForegroundColor Gray
Write-Host "  Total processed: $($devices.Count)" -ForegroundColor White
Write-Host ""

# Save failed devices report
if ($failedDevices.Count -gt 0) {
    $timestamp = Get-Date -Format 'yyyyMMdd_HHmmss'
    $failedReportPath = "output/failed-imports-$timestamp.csv"
    $failedDevices | Export-Csv -Path $failedReportPath -NoTypeInformation
    
    Write-Host "Failed devices saved to: $failedReportPath" -ForegroundColor Yellow
    Write-Host ""
    Write-Host "Failed Devices:" -ForegroundColor Yellow
    $failedDevices | Format-Table -AutoSize
}

# Generate import report
$timestamp = Get-Date -Format 'yyyyMMdd_HHmmss'
$reportPath = "output/import-report-$timestamp.txt"

$report = @"
====================================
Autopilot Import Report
====================================
Generated: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
Tenant: $($context.TenantId)

Summary:
--------
Total devices processed: $($devices.Count)
Successfully imported: $successCount
Failed: $failCount
Skipped (invalid data): $skipCount

Import Success Rate: $([math]::Round(($successCount / $devices.Count) * 100, 2))%

$( if ($failedDevices.Count -gt 0) { 
@"

Failed Devices:
---------------
$($failedDevices | ForEach-Object { "  $($_.'Device Name') (S/N: $($_.'Serial Number'))`n    Error: $($_.Error)" } | Out-String)

Failed device details saved to: $failedReportPath
"@ 
} else { "" })

====================================
Next Steps:
====================================
1. Verify devices in Intune portal:
   Devices → Windows → Windows enrollment → Devices

2. Create Autopilot deployment profile:
   Devices → Windows → Windows enrollment → Deployment Profiles

3. Assign profile to imported devices

4. Run validation script:
   scripts/06-validate-and-cleanup.ps1

5. Plan device reset/reimage strategy for enrollment

"@

$report | Out-File -FilePath $reportPath -Encoding UTF8
Write-Host "Import report saved: $reportPath" -ForegroundColor Green

# Disconnect
Disconnect-MgGraph | Out-Null
Write-Host "Disconnected from Microsoft Graph" -ForegroundColor Gray

Write-Host ""
Write-Host "=====================================" -ForegroundColor Cyan
Write-Host "Next Steps" -ForegroundColor Yellow
Write-Host "=====================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "1. Verify devices in Intune portal:" -ForegroundColor White
Write-Host "   Devices → Windows → Windows enrollment → Devices" -ForegroundColor Gray
Write-Host ""
Write-Host "2. Run validation:" -ForegroundColor White
Write-Host "   .\scripts\06-validate-and-cleanup.ps1" -ForegroundColor Gray
Write-Host ""
Write-Host "3. Create Autopilot deployment profiles" -ForegroundColor White
Write-Host ""
