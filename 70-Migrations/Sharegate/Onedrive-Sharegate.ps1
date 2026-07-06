Import-Module Sharegate


#============================================CONFIGURATION - This section contains all the settings
#CSV files paths
$CsvFilePath    = "C:\Users\s.bartlomiej\Desktop\OneDrive_Mapping_Sharegate.csv"
$LogFilePath    = "C:\Users\s.bartlomiej\Desktop\OneDrive_Migration_Errors.log"

#SOURCE TENANT
$SourceTenantName       = "HAKOM"                                    
$SourceTenantRootUrl    = "https://hakom-my.sharepoint.com/"         

#DESTINATION TENANT
$DestinationTenantName  = "VOLUE"                                    
$DestinationTenantRootUrl = "https://volue-my.sharepoint.com/"       

#LIBRARY NAMES
#Document library names in different languages - tenant location seems to be determining this ;-)
#English: "Documents"    German: "Dokumente"    Norwegian: "Dokumenter"
#Put the most likely name first - Volue is Norwegian amd in this case source was German
$SourceLibraryNames      = @("Dokumente", "Documents", "Dokumenter", "Shared Documents")
$DestinationLibraryNames = @("Dokumenter", "Documents", "Dokumente", "Shared Documents")

#CSV FORMAT
$CsvDelimiter = ","

#COPY MODE
#$true = only copy new/updated files (delta/incremental), $false = copy everything (full migration)
$IncrementalCopy = $false

#CLEANUP - Remove collection admins from OneDrives after migration
#Enable this on incremental run
#$true = remove admin accounts from OneDrive after copy, $false = leave admins in place
$RemoveAdmins = $false
#============================================CONFIGURATION - End of settings section

#ACTUAL SCRIPT - no modifications needed below
# Clear previous log
if (Test-Path $LogFilePath) { Clear-Content $LogFilePath }
#Import CSV
$table = Import-Csv $CsvFilePath -Delimiter $CsvDelimiter
# Connect to source
Write-Host "=== LOGIN 1 of 2: Sign in with your $SourceTenantName admin account ===" -ForegroundColor Yellow
$srcSiteConnection = Connect-Site -Url $SourceTenantRootUrl -Browser
# Connect to destination
Write-Host "=== LOGIN 2 of 2: Sign in with your $DestinationTenantName admin account ===" -ForegroundColor Yellow
$dstSiteConnection = Connect-Site -Url $DestinationTenantRootUrl -Browser
Write-Host "`nBoth tenants connected. Starting migration of $($table.Count) OneDrives...`n" -ForegroundColor Green

# Counters for log summary
$successCount = 0
$skipCount    = 0
$errorCount   = 0

foreach ($row in $table) {
    $srcSite = $null
    $dstSite = $null
    $srcList = $null
    $dstList = $null

    # no user - ommit
    if ($row.MatchType -like "Non-user*") {
        Write-Host "SKIPPED (non-user): $($row.DisplayName)" -ForegroundColor DarkYellow
        Add-Content -Path $LogFilePath -Value "[SKIPPED] $($row.DisplayName) - $($row.MatchType)"
        $skipCount++
        continue
    }

    Write-Host "Processing: $($row.DisplayName)" -ForegroundColor Cyan

    try {
        #connect source and destination sites
        $srcSite = Connect-Site -Url $row.SourceSite -UseCredentialsFrom $srcSiteConnection
        $dstSite = Connect-Site -Url $row.DestinationSite -UseCredentialsFrom $dstSiteConnection

        #Determine source document library
        foreach ($name in $SourceLibraryNames) {
            $srcList = Get-List -Site $srcSite -Name $name
            if ($null -ne $srcList) {
                Write-Host "  Source library      : '$name'" -ForegroundColor DarkGray
                break
            }
        }

        # Find destination document library
        foreach ($name in $DestinationLibraryNames) {
            $dstList = Get-List -Site $dstSite -Name $name
            if ($null -ne $dstList) {
                Write-Host "  Destination library : '$name'" -ForegroundColor DarkGray
                break
            }
        }

        
        if ($null -eq $srcList) {
            $msg = "[ERROR] $($row.DisplayName) - Source library not found at $($row.SourceSite)"
            Write-Warning $msg; Add-Content -Path $LogFilePath -Value $msg
            $errorCount++; continue
        }

        
        if ($null -eq $dstList) {
            $msg = "[ERROR] $($row.DisplayName) - Destination library not found at $($row.DestinationSite)"
            Write-Warning $msg; Add-Content -Path $LogFilePath -Value $msg
            $errorCount++; continue
        }

        #start migration - use -OnlyNew for incremental copy if enabled
        if ($IncrementalCopy) {
            $result = Copy-Content -SourceList $srcList -DestinationList $dstList -OnlyNew
        } else {
            $result = Copy-Content -SourceList $srcList -DestinationList $dstList
        }

        $successCount++
        $logLine = "[OK] $($row.DisplayName) | Successes: $($result.Successes) | Warnings: $($result.Warnings) | Errors: $($result.Errors)"
        Write-Host "  $logLine" -ForegroundColor Green
        Add-Content -Path $LogFilePath -Value $logLine

        #Remove collection admins 
        if ($RemoveAdmins) {
            try {
                Set-Site -Site $srcSite -RemoveSiteCollectionAdministrator
                Write-Host "  Admin removed from source OneDrive" -ForegroundColor DarkGray
            } catch {
                $warnMsg = "[WARN] $($row.DisplayName) - Could not remove admin from source: $_"
                Write-Warning $warnMsg
                Add-Content -Path $LogFilePath -Value $warnMsg
            }
            try {
                Set-Site -Site $dstSite -RemoveSiteCollectionAdministrator
                Write-Host "  Admin removed from destination OneDrive" -ForegroundColor DarkGray
            } catch {
                $warnMsg = "[WARN] $($row.DisplayName) - Could not remove admin from destination: $_"
                Write-Warning $warnMsg
                Add-Content -Path $LogFilePath -Value $warnMsg
            }
        }

    } catch {
        $msg = "[EXCEPTION] $($row.DisplayName) - $_"
        Write-Warning $msg
        Add-Content -Path $LogFilePath -Value $msg
        $errorCount++
    }
}

#Job summary
$copyMode    = if ($IncrementalCopy) { "INCREMENTAL (only new/updated)" } else { "FULL (all files)" }
$adminCleanup = if ($RemoveAdmins)   { "YES - admins removed after copy" } else { "NO - admins still in place" }
$summary = @"

====================================================
 MIGRATION SUMMARY
====================================================
 Source Tenant      : $SourceTenantName
 Destination Tenant : $DestinationTenantName
 Copy Mode          : $copyMode
 Admin Cleanup      : $adminCleanup
----------------------------------------------------
 Total rows         : $($table.Count)
 Succeeded          : $successCount
 Skipped            : $skipCount
 Errors             : $errorCount
----------------------------------------------------
 Log file           : $LogFilePath
====================================================
 Admin accounts were NOT removed by default. Left in case
 of troubleshooting needed. Can be cleared afterwards
====================================================
"@

Write-Host $summary -ForegroundColor White
Add-Content -Path $LogFilePath -Value $summary
