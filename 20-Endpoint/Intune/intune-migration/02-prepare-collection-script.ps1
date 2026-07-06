<#
.SYNOPSIS
    Prepares the collection script with embedded Azure Storage credentials
.DESCRIPTION
    Creates deployment-ready PowerShell script with SAS token embedded
    This script will be deployed via Intune to source company devices
.NOTES
    Requires storage-config-SECURE.txt from previous step
#>

Write-Host "=====================================" -ForegroundColor Cyan
Write-Host "Prepare Collection Script" -ForegroundColor Cyan
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
Write-Host "Reading storage configuration..." -ForegroundColor Cyan
$configContent = Get-Content $configPath -Raw

# Extract values using regex
if ($configContent -match 'Storage Account: (.+)') {
    $storageAccountName = $matches[1].Trim()
}
if ($configContent -match 'Container: (.+)') {
    $containerName = $matches[1].Trim()
}
if ($configContent -match 'SAS Token:\s*\n(.+?)\s*\n') {
    $sasToken = $matches[1].Trim()
}

if ([string]::IsNullOrWhiteSpace($storageAccountName) -or [string]::IsNullOrWhiteSpace($sasToken)) {
    Write-Host "Error: Could not parse configuration file" -ForegroundColor Red
    exit 1
}

Write-Host "Configuration loaded:" -ForegroundColor Green
Write-Host "  Storage Account: $storageAccountName" -ForegroundColor White
Write-Host "  Container: $containerName" -ForegroundColor White
Write-Host "  SAS Token: $($sasToken.Substring(0, 20))..." -ForegroundColor Gray
Write-Host ""

# Optional: Add group tag for tracking
$groupTag = Read-Host "Enter Group Tag for devices (or press Enter to skip)"
if ([string]::IsNullOrWhiteSpace($groupTag)) {
    $groupTag = ""
}

# Create deployment script
Write-Host "Generating collection script..." -ForegroundColor Cyan

$deploymentScript = @"
<#
.SYNOPSIS
    Collects Windows Autopilot hardware hash and uploads to Azure Storage
.DESCRIPTION
    Deployed via Intune to collect device hardware hash for tenant migration
    Uploads hash data to secure Azure Blob Storage
.NOTES
    Auto-generated for Autopilot migration project
    Generated: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
#>

# Configuration
`$storageAccount = "$storageAccountName"
`$containerName = "$containerName"
`$sasToken = "$sasToken"
`$groupTag = "$groupTag"

# Create temp directory
`$tempPath = "C:\Windows\Temp\AutopilotHash"
if (!(Test-Path `$tempPath)) {
    New-Item -ItemType Directory -Path `$tempPath -Force | Out-Null
}

`$logFile = "`$tempPath\collection.log"

function Write-Log {
    param([string]`$Message)
    `$timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    `$logMessage = "[`$timestamp] `$Message"
    Add-Content -Path `$logFile -Value `$logMessage
    Write-Output `$logMessage
}

Write-Log "Starting hardware hash collection..."

try {
    # Get device information
    Write-Log "Gathering device information..."
    
    `$computerName = `$env:COMPUTERNAME
    `$serialNumber = (Get-WmiObject -Class Win32_BIOS).SerialNumber
    `$manufacturer = (Get-CimInstance -ClassName Win32_ComputerSystem).Manufacturer
    `$model = (Get-CimInstance -ClassName Win32_ComputerSystem).Model
    
    Write-Log "Device: `$computerName, Serial: `$serialNumber"
    
    # Get hardware hash
    Write-Log "Collecting hardware hash..."
    
    `$deviceHash = (Get-WmiObject -Namespace root/cimv2/mdm/dmmap -Class MDM_DevDetail_Ext01 -Filter "InstanceID='Ext' AND ParentID='./DevDetail'").DeviceHardwareData
    
    if ([string]::IsNullOrWhiteSpace(`$deviceHash)) {
        Write-Log "ERROR: Failed to retrieve hardware hash"
        exit 1
    }
    
    Write-Log "Hardware hash collected successfully (length: `$(`$deviceHash.Length))"
    
    # Create CSV data
    `$csvData = [PSCustomObject]@{
        'Device Serial Number' = `$serialNumber
        'Windows Product ID' = ''
        'Hardware Hash' = `$deviceHash
        'Manufacturer' = `$manufacturer
        'Model' = `$model
        'Device Name' = `$computerName
        'Group Tag' = `$groupTag
        'Collected Date' = (Get-Date -Format "yyyy-MM-dd HH:mm:ss")
    }
    
    # Save locally
    `$localFile = "`$tempPath\`$computerName`_hash.csv"
    `$csvData | Export-Csv -Path `$localFile -NoTypeInformation -Force
    Write-Log "CSV saved locally: `$localFile"
    
    # Upload to Azure Storage
    Write-Log "Uploading to Azure Storage..."
    
    `$fileName = "`$computerName`_`$(Get-Date -Format 'yyyyMMdd_HHmmss').csv"
    `$uploadUrl = "https://`$storageAccount.blob.core.windows.net/`$containerName/`$fileName`$sasToken"
    
    `$headers = @{
        "x-ms-blob-type" = "BlockBlob"
        "x-ms-blob-content-type" = "text/csv"
    }
    
    `$fileContent = Get-Content -Path `$localFile -Raw
    `$fileBytes = [System.Text.Encoding]::UTF8.GetBytes(`$fileContent)
    
    `$response = Invoke-RestMethod -Uri `$uploadUrl -Method Put -Headers `$headers -Body `$fileBytes -ContentType "text/csv"
    
    Write-Log "Upload successful!"
    Write-Log "SUCCESS: Hash collected and uploaded for `$computerName"
    
    # Cleanup local file after successful upload
    Remove-Item -Path `$localFile -Force -ErrorAction SilentlyContinue
    
    exit 0
    
} catch {
    Write-Log "ERROR: `$(`$_.Exception.Message)"
    Write-Log "ERROR: Failed to collect or upload hardware hash"
    exit 1
}
"@

# Save deployment script
$outputScriptPath = "deployment/collect-autopilot-hash.ps1"
New-Item -ItemType Directory -Path "deployment" -Force | Out-Null
$deploymentScript | Out-File -FilePath $outputScriptPath -Encoding UTF8 -Force

Write-Host "Collection script created successfully!" -ForegroundColor Green
Write-Host ""
Write-Host "Output file: $outputScriptPath" -ForegroundColor White
Write-Host ""
Write-Host "=====================================" -ForegroundColor Cyan
Write-Host "Next Steps" -ForegroundColor Yellow
Write-Host "=====================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "1. Review the generated script (optional)" -ForegroundColor White
Write-Host "   File: $outputScriptPath" -ForegroundColor Gray
Write-Host ""
Write-Host "2. Provide this script to source company Intune admin" -ForegroundColor White
Write-Host "   They will deploy it via Intune → Devices → Scripts" -ForegroundColor Gray
Write-Host ""
Write-Host "3. Refer to deployment guide:" -ForegroundColor White
Write-Host "   docs/intune-deployment-guide.md" -ForegroundColor Gray
Write-Host ""
Write-Host "4. Monitor collection progress:" -ForegroundColor White
Write-Host "   .\scripts\03-monitor-collection.ps1" -ForegroundColor Gray
Write-Host ""
Write-Host "⚠️  Security reminder:" -ForegroundColor Yellow
Write-Host "   - The script contains a SAS token (write-only access)" -ForegroundColor Gray
Write-Host "   - Token expires based on your configuration" -ForegroundColor Gray
Write-Host "   - Safe to share with source company admin only" -ForegroundColor Gray
Write-Host ""
