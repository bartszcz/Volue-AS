Import-Module Sharegate

# Path to CSV file
$csvFile = "C:\Users\s.bartlomiej\Desktop\Hakom-SiteMigration.csv"

# Import CSV
$sites = Import-Csv $csvFile

Write-Host ""
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "SharePoint Site Migration - Batch Mode" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "Total sites to migrate: $($sites.Count)" -ForegroundColor Yellow
Write-Host ""

# Authenticate once per tenant - these credentials will be reused for all sites
Write-Host "Authenticating to source tenant (Hakom)..." -ForegroundColor Yellow
$sourceConnection = Connect-Site -Url "https://hakom.sharepoint.com" -Browser
Write-Host "Authenticated to source tenant" -ForegroundColor Green

Write-Host "Authenticating to destination tenant (Volue)..." -ForegroundColor Yellow  
$destConnection = Connect-Site -Url "https://volue.sharepoint.com" -Browser
Write-Host "Authenticated to destination tenant" -ForegroundColor Green

# Counter for tracking progress
$successCount = 0
$failureCount = 0
$sitesProcessed = 0

# Create log file
$logFile = "$PSScriptRoot\migration-batch-log.txt"
"Migration started at $(Get-Date)" | Out-File -FilePath $logFile

foreach ($site in $sites) {
    $sitesProcessed++
    $sourceUrl = $site."Site address"
    $destinationUrl = $site."New Site URL Volue"
    $title = $site."Title"
    
    Write-Host ""
    Write-Host "[$sitesProcessed/$($sites.Count)] Migrating: $title" -ForegroundColor Cyan
    Write-Host "  Source:      $sourceUrl"
    Write-Host "  Destination: $destinationUrl"
    Write-Host "  Connecting to source site..." -ForegroundColor Yellow
    
    try {
        # Connect to source site using existing credentials
        $srcSite = Connect-Site -Url $sourceUrl -UseCredentialsFrom $sourceConnection
        
        Write-Host "  Connected to source" -ForegroundColor Green
        Write-Host "  Connecting to destination site..." -ForegroundColor Yellow
        
        # Connect to destination site using existing credentials
        $dstSite = Connect-Site -Url $destinationUrl -UseCredentialsFrom $destConnection
        
        Write-Host "  Connected to destination" -ForegroundColor Green
        Write-Host "  Starting copy operation..." -ForegroundColor Yellow
        
        # Copy site with merge and subsites
        Copy-Site -Site $srcSite -DestinationSite $dstSite -Merge -Subsites
        
        Write-Host "  Migration completed successfully!" -ForegroundColor Green
        
        # Log success
        "[$sitesProcessed/$($sites.Count)] SUCCESS: $title - $sourceUrl -> $destinationUrl" | Out-File -FilePath $logFile -Append
        $successCount++
    }
    catch {
        Write-Host "  Migration failed: $($_.Exception.Message)" -ForegroundColor Red
        
        # Log failure
        "[$sitesProcessed/$($sites.Count)] FAILED: $title - $($_.Exception.Message)" | Out-File -FilePath $logFile -Append
        $failureCount++
    }
}

# Summary
Write-Host ""
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "Migration Summary" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "Total processed: $sitesProcessed" -ForegroundColor Yellow
Write-Host "Successful: $successCount" -ForegroundColor Green
Write-Host "Failed: $failureCount" -ForegroundColor $(if ($failureCount -eq 0) { "Green" } else { "Red" })
Write-Host ""
Write-Host "Log file saved to: $logFile" -ForegroundColor Yellow
Write-Host ""
