<#
.SYNOPSIS
    Creates SharePoint and Teams migration mapping files and optionally preprovisions SharePoint sites.

.DESCRIPTION
    This script:
    1. Reads a combined SharePoint/Teams sites CSV export
    2. Reads migration configuration (source/target tenant info)
    3. Generates two mapping CSV files (Teams and SharePoint) in Sharegate format
    4. Optionally preprovisions SharePoint sites in the target tenant

.PARAMETER ConfigPath
    Path to the MigrationConfig.csv file containing source/target tenant settings

.PARAMETER SitesPath
    Path to the combined SharePoint/Teams sites CSV file

.PARAMETER OutputFolder
    Optional. Override the output folder from config. Defaults to config setting.

.EXAMPLE
    .\SharePoint-Teams-MigrationMapper.ps1 -ConfigPath ".\MigrationConfig.csv" -SitesPath ".\sharepoint-sites-teams.csv"
#>

param(
    [Parameter(Mandatory = $true)]
    [string]$ConfigPath,
    
    [Parameter(Mandatory = $true)]
    [string]$SitesPath,
    
    [Parameter(Mandatory = $false)]
    [string]$OutputFolder
)

#region Functions

function Read-MigrationConfig {
    param([string]$Path)
    
    $config = @{}
    $csvData = Import-Csv -Path $Path
    
    foreach ($row in $csvData) {
        $config[$row.Setting] = $row.Value
    }
    
    return $config
}

function Get-SiteUrlPart {
    param([string]$Url)
    
    # Extract the site name from URL (last part after /sites/)
    if ($Url -match '/sites/([^/]+)/?$') {
        return $Matches[1]
    }
    return $null
}

function New-TargetSiteUrl {
    param(
        [string]$SourceUrl,
        [string]$TargetDomain,
        [string]$Prefix
    )
    
    $siteUrlPart = Get-SiteUrlPart -Url $SourceUrl
    if (-not $siteUrlPart) {
        # Handle root site or special cases
        return $null
    }
    
    # Create target URL with prefix
    $targetTenant = $TargetDomain -replace '\.com$', ''
    $newSiteUrlPart = "${Prefix}${siteUrlPart}"
    
    return "https://${targetTenant}.sharepoint.com/sites/${newSiteUrlPart}"
}

function New-TargetSiteName {
    param(
        [string]$SourceName,
        [string]$Prefix
    )
    
    return "${Prefix} - ${SourceName}"
}

function Test-IsTeamsSite {
    param($SiteRow)
    
    # Check the "Is Teams?" column
    $isTeams = $SiteRow.'Is Teams?'
    return ($isTeams -eq 'Yes' -or $isTeams -eq 'TRUE' -or $isTeams -eq $true)
}

function Get-SiteNameFromRow {
    param($SiteRow)
    
    # Try different possible column names (handles BOM and quote variations)
    $possibleNames = @('Site name', '"Site name"', 'Site Name', 'SiteName', 'Name', 'Title')
    
    foreach ($colName in $possibleNames) {
        $value = $SiteRow.$colName
        if (-not [string]::IsNullOrWhiteSpace($value)) {
            # Clean up any surrounding quotes
            return $value -replace '^"', '' -replace '"$', ''
        }
    }
    
    # Try to get first property that contains 'site' and 'name'
    $props = $SiteRow.PSObject.Properties
    foreach ($prop in $props) {
        if ($prop.Name -match 'site.*name' -and -not [string]::IsNullOrWhiteSpace($prop.Value)) {
            return $prop.Value -replace '^"', '' -replace '"$', ''
        }
    }
    
    # Last resort: try to get first non-URL property value
    foreach ($prop in $props) {
        if ($prop.Value -and $prop.Value -notmatch '^https?://' -and $prop.Name -ne 'URL') {
            return $prop.Value -replace '^"', '' -replace '"$', ''
        }
    }
    
    return ""
}

function Export-TeamsMappingCsv {
    param(
        [array]$Sites,
        [hashtable]$Config,
        [string]$OutputPath
    )
    
    $mappings = @()
    
    foreach ($site in $Sites) {
        $sourceName = Get-SiteNameFromRow -SiteRow $site
        $sourceUrl = $site.URL
        
        if ([string]::IsNullOrWhiteSpace($sourceUrl)) { continue }
        
        $targetUrl = New-TargetSiteUrl -SourceUrl $sourceUrl -TargetDomain $Config.TargetDomain -Prefix $Config.NewGroupPrefix
        $targetName = New-TargetSiteName -SourceName $sourceName -Prefix $Config.NewGroupPrefix
        
        if ($targetUrl) {
            $mappings += [PSCustomObject]@{
                'Title'                = $sourceName
                'Site address'         = $sourceUrl
                'New Site Name Value'  = $targetName
                'New Site URL Value'   = $targetUrl
            }
        }
    }
    
    $mappings | Export-Csv -Path $OutputPath -NoTypeInformation -Encoding UTF8
    return $mappings.Count
}

function Export-SharePointMappingCsv {
    param(
        [array]$Sites,
        [hashtable]$Config,
        [string]$OutputPath
    )
    
    $mappings = @()
    
    foreach ($site in $Sites) {
        $sourceName = Get-SiteNameFromRow -SiteRow $site
        $sourceUrl = $site.URL
        
        if ([string]::IsNullOrWhiteSpace($sourceUrl)) { continue }
        
        $targetUrl = New-TargetSiteUrl -SourceUrl $sourceUrl -TargetDomain $Config.TargetDomain -Prefix $Config.NewGroupPrefix
        $targetName = New-TargetSiteName -SourceName $sourceName -Prefix $Config.NewGroupPrefix
        
        if ($targetUrl) {
            $mappings += [PSCustomObject]@{
                'Title'                = $sourceName
                'Site address'         = $sourceUrl
                'New Site Name Value'  = $targetName
                'New Site URL Value'   = $targetUrl
            }
        }
    }
    
    $mappings | Export-Csv -Path $OutputPath -NoTypeInformation -Encoding UTF8
    return $mappings.Count
}

function Connect-ToSharePointOnline {
    param(
        [string]$AdminUrl,
        [string]$AdminUPN
    )
    
    try {
        # Check if PnP.PowerShell module is installed
        if (-not (Get-Module -ListAvailable -Name PnP.PowerShell)) {
            Write-Host "PnP.PowerShell module not found. Installing..." -ForegroundColor Yellow
            Install-Module -Name PnP.PowerShell -Scope CurrentUser -Force -AllowClobber
        }
        
        Import-Module PnP.PowerShell -ErrorAction Stop
        
        Write-Host "Connecting to SharePoint Online Admin Center..." -ForegroundColor Cyan
        Write-Host "Admin URL: $AdminUrl" -ForegroundColor Gray
        Write-Host "Admin UPN: $AdminUPN" -ForegroundColor Gray
        
        Connect-PnPOnline -Url $AdminUrl -Interactive
        
        return $true
    }
    catch {
        Write-Host "Failed to connect to SharePoint Online: $_" -ForegroundColor Red
        return $false
    }
}

function New-SharePointSite {
    param(
        [string]$Title,
        [string]$Url,
        [string]$Owner,
        [string]$Template = "STS#3"  # Team site (no M365 group)
    )
    
    try {
        # Extract the site alias from URL
        $siteAlias = Get-SiteUrlPart -Url $Url
        
        Write-Host "  Creating site: $Title" -ForegroundColor Cyan
        Write-Host "    URL: $Url" -ForegroundColor Gray
        
        # Create the site using PnP
        New-PnPSite -Type TeamSiteWithoutMicrosoft365Group `
            -Title $Title `
            -Url $Url `
            -Owner $Owner `
            -ErrorAction Stop
        
        Write-Host "    ✓ Site created successfully" -ForegroundColor Green
        return $true
    }
    catch {
        if ($_.Exception.Message -like "*already exists*") {
            Write-Host "    ⚠ Site already exists - skipping" -ForegroundColor Yellow
            return $true
        }
        else {
            Write-Host "    ✗ Failed to create site: $_" -ForegroundColor Red
            return $false
        }
    }
}

function Show-ProvisioningMenu {
    param(
        [array]$SharePointMappings,
        [string]$TargetAdminUPN
    )
    
    Write-Host ""
    Write-Host "═══════════════════════════════════════════════════════════════" -ForegroundColor Cyan
    Write-Host "  SHAREPOINT SITE PRE-PROVISIONING" -ForegroundColor Cyan
    Write-Host "═══════════════════════════════════════════════════════════════" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "Found $($SharePointMappings.Count) SharePoint sites to provision." -ForegroundColor White
    Write-Host ""
    Write-Host "Options:" -ForegroundColor Yellow
    Write-Host "  [A] Create ALL sites automatically" -ForegroundColor White
    Write-Host "  [I] Interactive mode - confirm each site" -ForegroundColor White
    Write-Host "  [R] Review list only (no provisioning)" -ForegroundColor White
    Write-Host "  [S] Skip provisioning entirely" -ForegroundColor White
    Write-Host ""
    
    $choice = Read-Host "Select option (A/I/R/S)"
    
    return $choice.ToUpper()
}

function Start-SiteProvisioning {
    param(
        [array]$SharePointMappings,
        [hashtable]$Config,
        [string]$Mode
    )
    
    if ($Mode -eq 'S') {
        Write-Host "Provisioning skipped." -ForegroundColor Yellow
        return
    }
    
    if ($Mode -eq 'R') {
        Write-Host ""
        Write-Host "═══════════════════════════════════════════════════════════════" -ForegroundColor Cyan
        Write-Host "  SITE LIST REVIEW" -ForegroundColor Cyan
        Write-Host "═══════════════════════════════════════════════════════════════" -ForegroundColor Cyan
        Write-Host ""
        
        $counter = 1
        foreach ($mapping in $SharePointMappings) {
            Write-Host "[$counter] $($mapping.'New Site Name Value')" -ForegroundColor White
            Write-Host "    Source: $($mapping.'Site address')" -ForegroundColor Gray
            Write-Host "    Target: $($mapping.'New Site URL Value')" -ForegroundColor Gray
            Write-Host ""
            $counter++
        }
        return
    }
    
    # Connect to SharePoint Online
    $targetTenant = $Config.TargetDomain -replace '\.com$', ''
    $adminUrl = "https://${targetTenant}-admin.sharepoint.com"
    
    $connected = Connect-ToSharePointOnline -AdminUrl $adminUrl -AdminUPN $Config.TargetAdminUPN
    
    if (-not $connected) {
        Write-Host "Cannot proceed without SharePoint Online connection." -ForegroundColor Red
        return
    }
    
    Write-Host ""
    Write-Host "═══════════════════════════════════════════════════════════════" -ForegroundColor Cyan
    Write-Host "  STARTING SITE PROVISIONING" -ForegroundColor Cyan
    Write-Host "═══════════════════════════════════════════════════════════════" -ForegroundColor Cyan
    Write-Host ""
    
    $created = 0
    $skipped = 0
    $failed = 0
    $counter = 1
    $total = $SharePointMappings.Count
    
    foreach ($mapping in $SharePointMappings) {
        Write-Host ""
        Write-Host "[$counter/$total] Processing: $($mapping.'New Site Name Value')" -ForegroundColor White
        
        $shouldCreate = $true
        
        if ($Mode -eq 'I') {
            # Interactive mode - ask for each site
            Write-Host "  Source URL: $($mapping.'Site address')" -ForegroundColor Gray
            Write-Host "  Target URL: $($mapping.'New Site URL Value')" -ForegroundColor Gray
            Write-Host ""
            
            $confirm = Read-Host "  Create this site? ([Y]es / [N]o / [A]ll remaining / [Q]uit)"
            $confirm = $confirm.ToUpper()
            
            switch ($confirm) {
                'N' { 
                    $shouldCreate = $false 
                    $skipped++
                }
                'A' { 
                    $Mode = 'A'  # Switch to auto mode for remaining sites
                }
                'Q' { 
                    Write-Host "Provisioning cancelled by user." -ForegroundColor Yellow
                    break 
                }
            }
        }
        
        if ($shouldCreate) {
            # Validate site name before creation
            $proposedUrl = $mapping.'New Site URL Value'
            $proposedName = $mapping.'New Site Name Value'
            
            # Check for naming issues
            $urlPart = Get-SiteUrlPart -Url $proposedUrl
            if ($urlPart.Length -gt 64) {
                Write-Host "  ⚠ Warning: Site URL part exceeds 64 characters!" -ForegroundColor Yellow
                Write-Host "    Current length: $($urlPart.Length)" -ForegroundColor Gray
                
                if ($Mode -eq 'I' -or $Mode -eq 'A') {
                    $newUrlPart = Read-Host "  Enter a shorter URL alias (or press Enter to skip)"
                    if ([string]::IsNullOrWhiteSpace($newUrlPart)) {
                        Write-Host "  Skipping site due to URL length." -ForegroundColor Yellow
                        $skipped++
                        $counter++
                        continue
                    }
                    $targetTenant = $Config.TargetDomain -replace '\.com$', ''
                    $proposedUrl = "https://${targetTenant}.sharepoint.com/sites/${newUrlPart}"
                }
            }
            
            $result = New-SharePointSite -Title $proposedName -Url $proposedUrl -Owner $Config.TargetAdminUPN
            
            if ($result) {
                $created++
            }
            else {
                $failed++
            }
        }
        
        $counter++
    }
    
    # Disconnect
    try {
        Disconnect-PnPOnline -ErrorAction SilentlyContinue
    }
    catch { }
    
    Write-Host ""
    Write-Host "═══════════════════════════════════════════════════════════════" -ForegroundColor Cyan
    Write-Host "  PROVISIONING SUMMARY" -ForegroundColor Cyan
    Write-Host "═══════════════════════════════════════════════════════════════" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "  Created: $created" -ForegroundColor Green
    Write-Host "  Skipped: $skipped" -ForegroundColor Yellow
    Write-Host "  Failed:  $failed" -ForegroundColor Red
    Write-Host ""
}

#endregion Functions

#region Main Script

# Banner
Write-Host ""
Write-Host "╔═══════════════════════════════════════════════════════════════╗" -ForegroundColor Cyan
Write-Host "║     SharePoint & Teams Migration Mapping Tool                 ║" -ForegroundColor Cyan
Write-Host "║     Creates mapping CSVs for Sharegate migration              ║" -ForegroundColor Cyan
Write-Host "╚═══════════════════════════════════════════════════════════════╝" -ForegroundColor Cyan
Write-Host ""

# Validate input files
if (-not (Test-Path $ConfigPath)) {
    Write-Host "Error: Config file not found: $ConfigPath" -ForegroundColor Red
    exit 1
}

if (-not (Test-Path $SitesPath)) {
    Write-Host "Error: Sites file not found: $SitesPath" -ForegroundColor Red
    exit 1
}

# Read configuration
Write-Host "Reading configuration..." -ForegroundColor Cyan
$config = Read-MigrationConfig -Path $ConfigPath

Write-Host "  Source Company: $($config.SourceCompanyName)" -ForegroundColor Gray
Write-Host "  Source Domain:  $($config.SourceDomain)" -ForegroundColor Gray
Write-Host "  Target Domain:  $($config.TargetDomain)" -ForegroundColor Gray
Write-Host "  New Prefix:     $($config.NewGroupPrefix)" -ForegroundColor Gray
Write-Host ""

# Set output folder
if ([string]::IsNullOrWhiteSpace($OutputFolder)) {
    $OutputFolder = $config.OutputFolder
}

# Create output folder if it doesn't exist
if (-not (Test-Path $OutputFolder)) {
    Write-Host "Creating output folder: $OutputFolder" -ForegroundColor Yellow
    New-Item -ItemType Directory -Path $OutputFolder -Force | Out-Null
}

# Read sites data
Write-Host "Reading sites data..." -ForegroundColor Cyan
$allSites = Import-Csv -Path $SitesPath

# Separate Teams and SharePoint sites
$teamsSites = $allSites | Where-Object { Test-IsTeamsSite -SiteRow $_ }
$sharePointSites = $allSites | Where-Object { -not (Test-IsTeamsSite -SiteRow $_) }

Write-Host "  Total sites:      $($allSites.Count)" -ForegroundColor Gray
Write-Host "  Teams sites:      $($teamsSites.Count)" -ForegroundColor Gray
Write-Host "  SharePoint sites: $($sharePointSites.Count)" -ForegroundColor Gray
Write-Host ""

# Generate Teams mapping CSV
$teamsOutputPath = Join-Path $OutputFolder "$($config.SourceCompanyName)-TeamsMigrationList.csv"
Write-Host "Generating Teams mapping CSV..." -ForegroundColor Cyan
$teamsCount = Export-TeamsMappingCsv -Sites $teamsSites -Config $config -OutputPath $teamsOutputPath
Write-Host "  ✓ Created: $teamsOutputPath ($teamsCount entries)" -ForegroundColor Green
Write-Host ""

# Generate SharePoint mapping CSV
$spOutputPath = Join-Path $OutputFolder "$($config.SourceCompanyName)-SharePointSitesMigrationList.csv"
Write-Host "Generating SharePoint mapping CSV..." -ForegroundColor Cyan
$spCount = Export-SharePointMappingCsv -Sites $sharePointSites -Config $config -OutputPath $spOutputPath
Write-Host "  ✓ Created: $spOutputPath ($spCount entries)" -ForegroundColor Green
Write-Host ""

# Load SharePoint mappings for provisioning
$sharePointMappings = Import-Csv -Path $spOutputPath

# Show provisioning menu
$provisionChoice = Show-ProvisioningMenu -SharePointMappings $sharePointMappings -TargetAdminUPN $config.TargetAdminUPN

# Start provisioning based on choice
Start-SiteProvisioning -SharePointMappings $sharePointMappings -Config $config -Mode $provisionChoice

Write-Host ""
Write-Host "═══════════════════════════════════════════════════════════════" -ForegroundColor Cyan
Write-Host "  SCRIPT COMPLETED" -ForegroundColor Cyan
Write-Host "═══════════════════════════════════════════════════════════════" -ForegroundColor Cyan
Write-Host ""
Write-Host "Output files:" -ForegroundColor White
Write-Host "  Teams mapping:      $teamsOutputPath" -ForegroundColor Gray
Write-Host "  SharePoint mapping: $spOutputPath" -ForegroundColor Gray
Write-Host ""

#endregion Main Script
