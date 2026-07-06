<#
.SYNOPSIS
    Sets up Azure Storage Account for collecting Autopilot hardware hashes
.DESCRIPTION
    Creates storage account, container, and generates SAS token for remote collection
    Run this once in your target company Azure subscription
.NOTES
    Requires: Az.Storage, Az.Accounts modules
    Permissions: Contributor on subscription or resource group
#>

#Requires -Modules Az.Storage, Az.Accounts

Write-Host "=====================================" -ForegroundColor Cyan
Write-Host "Azure Storage Setup for Autopilot Hash Collection" -ForegroundColor Cyan
Write-Host "=====================================" -ForegroundColor Cyan
Write-Host ""

# Configuration - Customize these values
$resourceGroupName = Read-Host "Enter Resource Group name (or press Enter for 'autopilot-migration-rg')"
if ([string]::IsNullOrWhiteSpace($resourceGroupName)) {
    $resourceGroupName = "autopilot-migration-rg"
}

$storageAccountName = Read-Host "Enter Storage Account name (lowercase, no spaces, globally unique)"
while ([string]::IsNullOrWhiteSpace($storageAccountName) -or $storageAccountName -notmatch '^[a-z0-9]{3,24}$') {
    Write-Host "Storage account name must be 3-24 characters, lowercase letters and numbers only" -ForegroundColor Red
    $storageAccountName = Read-Host "Enter Storage Account name"
}

$containerName = "autopilot-hashes"
$location = Read-Host "Enter Azure region (or press Enter for 'eastus')"
if ([string]::IsNullOrWhiteSpace($location)) {
    $location = "eastus"
}

$sasExpiryDays = Read-Host "SAS token expiry in days (or press Enter for '60')"
if ([string]::IsNullOrWhiteSpace($sasExpiryDays)) {
    $sasExpiryDays = 60
}

Write-Host ""
Write-Host "Configuration:" -ForegroundColor Yellow
Write-Host "  Resource Group: $resourceGroupName"
Write-Host "  Storage Account: $storageAccountName"
Write-Host "  Container: $containerName"
Write-Host "  Location: $location"
Write-Host "  SAS Expiry: $sasExpiryDays days"
Write-Host ""

$confirm = Read-Host "Proceed with creation? (Y/N)"
if ($confirm -ne 'Y') {
    Write-Host "Cancelled by user" -ForegroundColor Yellow
    exit
}

# Connect to Azure
Write-Host ""
Write-Host "Connecting to Azure..." -ForegroundColor Cyan
try {
    $context = Get-AzContext
    if (!$context) {
        Connect-AzAccount
    }
    Write-Host "Connected to subscription: $($context.Subscription.Name)" -ForegroundColor Green
} catch {
    Write-Host "Failed to connect to Azure: $($_.Exception.Message)" -ForegroundColor Red
    exit 1
}

# Create Resource Group
Write-Host ""
Write-Host "Creating resource group..." -ForegroundColor Cyan
try {
    $rg = Get-AzResourceGroup -Name $resourceGroupName -ErrorAction SilentlyContinue
    if (!$rg) {
        $rg = New-AzResourceGroup -Name $resourceGroupName -Location $location
        Write-Host "Resource group created: $resourceGroupName" -ForegroundColor Green
    } else {
        Write-Host "Resource group already exists: $resourceGroupName" -ForegroundColor Yellow
    }
} catch {
    Write-Host "Failed to create resource group: $($_.Exception.Message)" -ForegroundColor Red
    exit 1
}

# Create Storage Account
Write-Host ""
Write-Host "Creating storage account (this may take a minute)..." -ForegroundColor Cyan
try {
    $storageAccount = Get-AzStorageAccount -ResourceGroupName $resourceGroupName -Name $storageAccountName -ErrorAction SilentlyContinue
    
    if (!$storageAccount) {
        $storageAccount = New-AzStorageAccount `
            -ResourceGroupName $resourceGroupName `
            -Name $storageAccountName `
            -Location $location `
            -SkuName Standard_LRS `
            -Kind StorageV2 `
            -AllowBlobPublicAccess $false `
            -MinimumTlsVersion TLS1_2
        
        Write-Host "Storage account created: $storageAccountName" -ForegroundColor Green
    } else {
        Write-Host "Storage account already exists: $storageAccountName" -ForegroundColor Yellow
    }
} catch {
    Write-Host "Failed to create storage account: $($_.Exception.Message)" -ForegroundColor Red
    exit 1
}

# Get storage context
$ctx = $storageAccount.Context

# Create container
Write-Host ""
Write-Host "Creating blob container..." -ForegroundColor Cyan
try {
    $container = Get-AzStorageContainer -Name $containerName -Context $ctx -ErrorAction SilentlyContinue
    
    if (!$container) {
        $container = New-AzStorageContainer -Name $containerName -Context $ctx -Permission Off
        Write-Host "Container created: $containerName" -ForegroundColor Green
    } else {
        Write-Host "Container already exists: $containerName" -ForegroundColor Yellow
    }
} catch {
    Write-Host "Failed to create container: $($_.Exception.Message)" -ForegroundColor Red
    exit 1
}

# Generate SAS Token
Write-Host ""
Write-Host "Generating SAS token..." -ForegroundColor Cyan
try {
    $startTime = Get-Date
    $expiryTime = $startTime.AddDays($sasExpiryDays)
    
    $sasToken = New-AzStorageContainerSASToken `
        -Name $containerName `
        -Context $ctx `
        -Permission "wac" `
        -StartTime $startTime `
        -ExpiryTime $expiryTime `
        -Protocol HttpsOnly
    
    Write-Host "SAS token generated successfully" -ForegroundColor Green
    Write-Host "  Valid from: $($startTime.ToString('yyyy-MM-dd HH:mm:ss'))" -ForegroundColor Gray
    Write-Host "  Expires on: $($expiryTime.ToString('yyyy-MM-dd HH:mm:ss'))" -ForegroundColor Gray
    Write-Host "  Permissions: Write, Add, Create (no Read/List)" -ForegroundColor Gray
} catch {
    Write-Host "Failed to generate SAS token: $($_.Exception.Message)" -ForegroundColor Red
    exit 1
}

# Build full upload URL
$uploadUrl = "https://$storageAccountName.blob.core.windows.net/$containerName"

# Save configuration to file
Write-Host ""
Write-Host "Saving configuration..." -ForegroundColor Cyan

$configPath = "output/storage-config.txt"
$configSecurePath = "output/storage-config-SECURE.txt"

# Create output directory
New-Item -ItemType Directory -Path "output" -Force | Out-Null

# Public config (without SAS token)
$publicConfig = @"
====================================
Azure Storage Configuration
====================================
Created: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')

Resource Group: $resourceGroupName
Storage Account: $storageAccountName
Container Name: $containerName
Location: $location

Upload URL: $uploadUrl
SAS Token Expiry: $($expiryTime.ToString('yyyy-MM-dd HH:mm:ss'))

====================================
Next Steps:
====================================
1. Review the secure config file (contains SAS token)
2. Run: scripts/02-prepare-collection-script.ps1
3. Provide collection script to source company
4. Monitor collection: scripts/03-monitor-collection.ps1

====================================
"@

$publicConfig | Out-File -FilePath $configPath -Encoding UTF8

# Secure config (with SAS token)
$secureConfig = @"
====================================
Azure Storage Configuration - SECURE
====================================
⚠️  CONTAINS SENSITIVE CREDENTIALS  ⚠️
⚠️  DO NOT SHARE OR COMMIT TO GIT    ⚠️

Storage Account: $storageAccountName
Container: $containerName
Upload URL: $uploadUrl

SAS Token:
$sasToken

Full Upload URL with SAS:
${uploadUrl}/<filename>${sasToken}

SAS Token Details:
- Valid from: $($startTime.ToString('yyyy-MM-dd HH:mm:ss'))
- Expires: $($expiryTime.ToString('yyyy-MM-dd HH:mm:ss'))
- Permissions: Write, Add, Create only
- Protocol: HTTPS only

====================================
"@

$secureConfig | Out-File -FilePath $configSecurePath -Encoding UTF8

Write-Host "Configuration saved:" -ForegroundColor Green
Write-Host "  Public config: $configPath" -ForegroundColor White
Write-Host "  Secure config: $configSecurePath" -ForegroundColor Yellow
Write-Host ""
Write-Host "⚠️  IMPORTANT: Keep the secure config file private!" -ForegroundColor Red
Write-Host ""

# Display summary
Write-Host "=====================================" -ForegroundColor Cyan
Write-Host "Setup Complete!" -ForegroundColor Green
Write-Host "=====================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "Summary:" -ForegroundColor Yellow
Write-Host "  ✓ Resource Group: $resourceGroupName" -ForegroundColor Green
Write-Host "  ✓ Storage Account: $storageAccountName" -ForegroundColor Green
Write-Host "  ✓ Container: $containerName" -ForegroundColor Green
Write-Host "  ✓ SAS Token: Generated (expires in $sasExpiryDays days)" -ForegroundColor Green
Write-Host ""
Write-Host "Next Step:" -ForegroundColor Yellow
Write-Host "  Run: .\scripts\02-prepare-collection-script.ps1" -ForegroundColor White
Write-Host ""
Write-Host "The script will use the SAS token to create the deployment script." -ForegroundColor Gray
Write-Host ""
