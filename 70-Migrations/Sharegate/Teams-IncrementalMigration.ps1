# ShareGate Teams Incremental Migration Script
# This script supports both initial migration and incremental updates
#
# Usage:
#   Initial Migration:  .\Teams-IncrementalMigration.ps1 -Mode Initial
#   Incremental Copy:   .\Teams-IncrementalMigration.ps1 -Mode Incremental
#   Incremental (Date): .\Teams-IncrementalMigration.ps1 -Mode Incremental -FromDate "03-01-2026" -ToDate "03-20-2026"
#   Dry Run:            .\Teams-IncrementalMigration.ps1 -Mode Initial -DryRun

param(
    [Parameter(Mandatory=$true)]
    [ValidateSet("Initial", "Incremental")]
    [string]$Mode,
    
    [Parameter(Mandatory=$false)]
    [string]$FromDate,  # Format: MM-dd-yyyy (e.g., "03-01-2026")
    
    [Parameter(Mandatory=$false)]
    [string]$ToDate,    # Format: MM-dd-yyyy (e.g., "03-20-2026")
    
    [Parameter(Mandatory=$false)]
    [switch]$DryRun     # Preview what would be done without actually executing
)

# =====================================================
# CONFIGURATION VARIABLES
# =====================================================
Import-Module Sharegate

# CSV file containing teams mapping
$csvFile = "C:\Users\s.bartlomiej\Desktop\Hakom-TeamsMigrationList.csv"

# Source and destination tenant domains
$SourceDomain = "hakom"
$DestinationDomain = "volue"

# Copy settings - prevents duplicates during content copy
$copysettings = New-CopySettings -OnContentItemExists IncrementalUpdate

# =====================================================
# ESTABLISH TENANT CONNECTIONS
# =====================================================

# Import migration list
$table = Import-Csv $csvFile -Delimiter ","

# Connect to tenants
$SourceConnection = Connect-Tenant -Domain $SourceDomain -Browser 
$TargetConnection = Connect-Tenant -Domain $DestinationDomain -Browser 

$source = Connect-Tenant -Domain $SourceDomain -UseCredentialsFrom $SourceConnection
$destination = Connect-Tenant -Domain $DestinationDomain -UseCredentialsFrom $TargetConnection

# =====================================================
# DRY RUN MODE CHECK
# =====================================================
if ($DryRun) {
    Write-Output "[DRY RUN MODE] No actual changes will be made"
    Write-Output ""
}

if ($Mode -eq "Initial") {
    # =====================================================
    # INITIAL MIGRATION MODE
    # Performs the first-time copy of teams and content
    # =====================================================
    Write-Output "=========================================="
    Write-Output "RUNNING INITIAL MIGRATION"
    Write-Output "=========================================="
    
    foreach ($row in $table) {
        $title = $row.Title
        $newTitle = $row.'New Site Name Volue'
        
        Write-Output "Processing: $title -> $newTitle"

        $srcTeam = Get-Team -Name $title -Tenant $source
        
        if ($null -eq $srcTeam) {
            Write-Warning "Source team not found: $title - SKIPPING"
            continue
        }
        
        # Initial team copy - this creates the session that can be rerun incrementally
        if ($DryRun) {
            Write-Output "[DRY RUN] Would copy team: $title -> $newTitle"
        }
        else {
            $result = Copy-Team -Team $srcTeam -TeamTitle $newTitle -DestinationTenant $destination
            
            if ($result) {
                Write-Output "Team copy session ID: $($result.SessionId) - Save this for incremental runs!"
            }
        }
        
        Write-Output "Copying content for: $title"
        
        $srcSite = Get-Site -Name $title -Tenant $source
        $dstSite = Get-Site -Name $newTitle -Tenant $destination
        
        if ($null -eq $srcSite) {
            Write-Warning "Source site not found: $title - SKIPPING content"
            continue
        }
        
        if ($null -eq $dstSite) {
            Write-Warning "Destination site not found: $newTitle - SKIPPING content"
            continue
        }
        
        if ($DryRun) {
            Write-Output "[DRY RUN] Would copy content from $title to $newTitle"
        }
        else {
            Copy-Content -SourceSite $srcSite -DestinationSite $dstSite -CopySettings $copysettings
        }
        
        Write-Output "Completed: $newTitle"
        Write-Output "------------------------------------------"
    }
    
    Write-Output "=========================================="
    Write-Output "INITIAL MIGRATION COMPLETE"
    Write-Output "=========================================="
}
elseif ($Mode -eq "Incremental") {
    # =====================================================
    # INCREMENTAL MIGRATION MODE
    # Re-runs previous copy sessions to sync changes
    # =====================================================
    Write-Output "=========================================="
    Write-Output "RUNNING INCREMENTAL MIGRATION"
    Write-Output "=========================================="
    
    # Find previous copy sessions
    if ($FromDate -and $ToDate) {
        # Use date range if provided
        $startDate = [DateTime]::ParseExact($FromDate, "MM-dd-yyyy", $null)
        $endDate = [DateTime]::ParseExact($ToDate, "MM-dd-yyyy", $null)
        
        Write-Output "Finding sessions from $FromDate to $ToDate..."
        $allSessions = Find-CopySessions -From $startDate -To $endDate
    }
    elseif ($FromDate) {
        # From a specific date onwards
        $startDate = [DateTime]::ParseExact($FromDate, "MM-dd-yyyy", $null)
        
        Write-Output "Finding sessions from $FromDate onwards..."
        $allSessions = Find-CopySessions -From $startDate
    }
    else {
        # Default: Find all copy sessions
        Write-Output "Finding all previous copy sessions..."
        $allSessions = Find-CopySessions
    }
    
    # Filter for only Teams copy sessions from the migration list
    $sessions = @()
    foreach ($session in $allSessions) {
        $sourceAddress = $session.SourceAddress
        $destAddress = $session.DestinationAddress
        
        # Check if this session matches any team in our migration list
        $matchingTeam = $table | Where-Object { 
            ($sourceAddress -like "*$($_.SourceTeamName)*" -or $sourceAddress -like "*$($_.SourceTeamEmail)*") -and
            ($destAddress -like "*$($_.DestinationTeamName)*" -or $destAddress -like "*$($_.DestinationTeamEmail)*")
        }
        
        if ($matchingTeam) {
            $sessions += $session
        }
    }
    
    if ($null -eq $sessions -or $sessions.Count -eq 0) {
        Write-Warning "No Teams copy sessions found for the specified criteria."
        Write-Output "Make sure you have run an initial migration first."
        exit
    }
    
    Write-Output "Found $($sessions.Count) session(s) to process."
    Write-Output "------------------------------------------"
    
    foreach ($session in $sessions) {
        Write-Output "Processing Session ID: $($session.Id)"
        Write-Output "  Source: $($session.SourceName)"
        Write-Output "  Destination: $($session.DestinationName)"
        Write-Output "  Original Date: $($session.StartTime)"
        
        try {
            # Run incremental copy for this session
            if ($DryRun) {
                Write-Output "  [DRY RUN] Would run incremental copy for session: $($session.Id)"
            }
            else {
                $result = Copy-TeamIncremental -SessionId $session.Id -SourceTenant $source -DestinationTenant $destination
                
                Write-Output "  Status: Incremental copy completed"
                if ($result) {
                    Write-Output "  Items Updated: $($result.ItemsCopied)"
                }
            }
        }
        catch {
            Write-Warning "  Error processing session $($session.Id): $_"
        }
        
        Write-Output "------------------------------------------"
    }
    
    Write-Output "=========================================="
    Write-Output "INCREMENTAL MIGRATION COMPLETE"
    Write-Output "=========================================="
}
