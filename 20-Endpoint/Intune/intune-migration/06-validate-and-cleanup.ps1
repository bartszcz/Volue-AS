<#
.SYNOPSIS
    Validates Autopilot import and performs cleanup
.DESCRIPTION
    Verifies devices successfully registered in Autopilot
    Generates final migration report
    Optionally cleans up Azure Storage
.NOTES
    Run after import complete
#>

#Requires -Modules Microsoft.Graph.Authentication, Microsoft.Graph.DeviceManagement, Az.Storage, Az.Accounts

Write-Host "=====================================" -ForegroundColor Cyan
Write-Host "Validate Import & Cleanup" -ForegroundColor Cyan
Write-Host "=====================================" -ForegroundColor Cyan
Write-Host ""

# Connect to Microsoft Graph
Write-Host "Connecting to Microsoft Graph..." -ForegroundColor Cyan
try {
    Connect-MgGraph -Scopes "DeviceManagementServiceConfig.Read.All" -NoWelcome
    Write-Host "Connected successfully" -ForegroundColor Green
} catch {
    Write-Host "Failed to connect: $($_.Exception.Message)" -ForegroundColor Red
    exit 1
}

# Get all Autopilot devices
Write-Host "Retrieving Autopilot devices..." -ForegroundColor Cyan
try {
    $autopilotDevices = Get-MgDeviceManagementWindowsAutopilotDeviceIdentity -All
    Write-Host "Found $($autopilotDevices.Count) total Autopilot devices in tenant" -ForegroundColor Green
} catch {
    Write-Host "Failed to retrieve Autopilot devices: $($_.Exception.Message)" -ForegroundColor Red
    exit 1
}

# Load imported devices from most recent consolidation
$consolidatedFiles = Get-ChildItem -Path "output" -Filter "ConsolidatedAutopilotHashes_*.csv" | Sort-Object LastWriteTime -Descending

if ($consolidatedFiles.Count -eq 0) {
    Write-Host "Warning: No consolidated file found for comparison" -ForegroundColor Yellow
    $importedDevices = @()
} else {
    $importedDevices = Import-Csv $consolidatedFiles[0].FullName
    Write-Host "Loaded $($importedDevices.Count) devices from import file" -ForegroundColor Green
}

Write-Host ""
Write-Host "Validating import..." -ForegroundColor Cyan

# Match imported devices with Autopilot
$matched = 0
$notFound = @()

foreach ($device in $importedDevices) {
    $serialNumber = $device.'Device Serial Number'
    $autopilotDevice = $autopilotDevices | Where-Object { $_.SerialNumber -eq $serialNumber }
    
    if ($autopilotDevice) {
        $matched++
    } else {
        $notFound += $device
    }
}

# Display results
Write-Host ""
Write-Host "=====================================" -ForegroundColor Cyan
Write-Host "Validation Results" -ForegroundColor Yellow
Write-Host "=====================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "Devices in import file: $($importedDevices.Count)" -ForegroundColor White
Write-Host "Successfully registered: $matched" -ForegroundColor Green
Write-Host "Not found in Autopilot: $($notFound.Count)" -ForegroundColor $(if ($notFound.Count -gt 0) { "Red" } else { "Green" })
Write-Host ""

if ($notFound.Count -gt 0) {
    Write-Host "Devices not found in Autopilot:" -ForegroundColor Yellow
    $notFound | Select-Object 'Device Name', 'Device Serial Number' | Format-Table -AutoSize
    
    $timestamp = Get-Date -Format 'yyyyMMdd_HHmmss'
    $notFoundPath = "output/not-found-in-autopilot-$timestamp.csv"
    $notFound | Export-Csv -Path $notFoundPath -NoTypeInformation
    Write-Host "Not found devices saved to: $notFoundPath" -ForegroundColor Gray
    Write-Host ""
}

$successRate = if ($importedDevices.Count -gt 0) {
    [math]::Round(($matched / $importedDevices.Count) * 100, 2)
} else {
    0
}

Write-Host "Import Success Rate: $successRate%" -ForegroundColor $(if ($successRate -gt 95) { "Green" } elseif ($successRate -gt 80) { "Yellow" } else { "Red" })
Write-Host ""

# Generate final report
Write-Host "Generating final migration report..." -ForegroundColor Cyan

$timestamp = Get-Date -Format 'yyyyMMdd_HHmmss'
$finalReportPath = "output/final-migration-report-$timestamp.txt"

$report = @"
====================================
Final Autopilot Migration Report
====================================
Generated: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')

Summary:
--------
Devices in import file: $($importedDevices.Count)
Successfully registered in Autopilot: $matched
Not found in Autopilot: $($notFound.Count)
Import success rate: $successRate%

Total Autopilot devices in tenant: $($autopilotDevices.Count)

Manufacturer Breakdown:
-----------------------
$($autopilotDevices | Group-Object Manufacturer | Sort-Object Count -Descending | ForEach-Object {
    "  $($_.Name): $($_.Count) devices"
} | Out-String)

Migration Status: $(if ($successRate -gt 95) { "✓ SUCCESSFUL" } elseif ($successRate -gt 80) { "⚠ PARTIAL SUCCESS" } else { "✗ NEEDS ATTENTION" })

$( if ($notFound.Count -gt 0) {
@"

Devices Not Found:
------------------
$($notFound | ForEach-Object { "  $($_.'Device Name') (S/N: $($_.'Device Serial Number'))" } | Out-String)

Recommendations:
- Review import error logs
- Check if devices were already registered
- Verify hardware hash format for missing devices
- Consider manual re-import for failed devices

"@
} else {
"All devices successfully imported to Autopilot!"
})

====================================
Next Steps:
====================================
1. ✓ Devices registered in Windows Autopilot

2. Create Autopilot Deployment Profile:
   - Navigate to: Intune → Devices → Windows → Windows enrollment → Deployment Profiles
   - Create profile with desired settings
   - Assign to devices (use Group Tag if configured)

3. Prepare for device transition:
   - Plan device reset/reimage schedule
   - Communicate with users
   - Ensure Azure AD accounts ready
   - Verify Intune policies configured

4. Device Enrollment:
   - Devices will auto-enroll on next reset/reimage
   - OOBE experience controlled by deployment profile
   - Monitor enrollment in Intune portal

5. Cleanup (optional):
   - Remove collection script from source Intune
   - Clean up Azure Storage (see below)

====================================
"@

$report | Out-File -FilePath $finalReportPath -Encoding UTF8
Write-Host "Final report saved: $finalReportPath" -ForegroundColor Green

# Cleanup options
Write-Host ""
Write-Host "=====================================" -ForegroundColor Cyan
Write-Host "Cleanup Options" -ForegroundColor Yellow
Write-Host "=====================================" -ForegroundColor Cyan
Write-Host ""

$cleanup = Read-Host "Clean up Azure Storage (delete collected CSV files)? (Y/N)"
if ($cleanup -eq 'Y') {
    Write-Host ""
    Write-Host "Cleaning up Azure Storage..." -ForegroundColor Cyan
    
    # Connect to Azure
    try {
        $azContext = Get-AzContext
        if (!$azContext) {
            Connect-AzAccount
        }
        
        # Load config
        $configPath = "output/storage-config-SECURE.txt"
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
        
        $storageAccount = Get-AzStorageAccount -ResourceGroupName $resourceGroupName -Name $storageAccountName
        $ctx = $storageAccount.Context
        
        # Delete all blobs
        $blobs = Get-AzStorageBlob -Container $containerName -Context $ctx
        Write-Host "Deleting $($blobs.Count) CSV files..." -ForegroundColor Yellow
        
        foreach ($blob in $blobs) {
            Remove-AzStorageBlob -Blob $blob.Name -Container $containerName -Context $ctx -Force
        }
        
        Write-Host "Azure Storage cleaned up successfully" -ForegroundColor Green
        
        # Option to delete container and storage account
        $deleteAll = Read-Host "Delete container and storage account completely? (Y/N)"
        if ($deleteAll -eq 'Y') {
            Remove-AzStorageContainer -Name $containerName -Context $ctx -Force
            Write-Host "Container deleted" -ForegroundColor Green
            
            $deleteAccount = Read-Host "Delete storage account '$storageAccountName'? (Y/N)"
            if ($deleteAccount -eq 'Y') {
                Remove-AzStorageAccount -ResourceGroupName $resourceGroupName -Name $storageAccountName -Force
                Write-Host "Storage account deleted" -ForegroundColor Green
            }
        }
        
    } catch {
        Write-Host "Cleanup failed: $($_.Exception.Message)" -ForegroundColor Red
    }
}

# Disconnect
Disconnect-MgGraph | Out-Null
Write-Host ""
Write-Host "=====================================" -ForegroundColor Cyan
Write-Host "Validation Complete!" -ForegroundColor Green
Write-Host "=====================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "Migration Summary:" -ForegroundColor Yellow
Write-Host "  Devices imported: $matched of $($importedDevices.Count)" -ForegroundColor White
Write-Host "  Success rate: $successRate%" -ForegroundColor $(if ($successRate -gt 95) { "Green" } else { "Yellow" })
Write-Host ""
Write-Host "Review the final report for next steps:" -ForegroundColor Gray
Write-Host "  $finalReportPath" -ForegroundColor White
Write-Host ""
