# Remove Subsites Script
# Run with -ReportOnly first to see what will be deleted
# Usage: .\remove-subsites.ps1 -ReportOnly
# Usage: .\remove-subsites.ps1 -ReportOnly:$false

param(
    [switch]$ReportOnly = $true
)

Import-Module PnP.PowerShell

# ============================================
# CONFIGURATION - Update these values
# ============================================
$clientId  = "cded7ab2-bc80-4bcd-b4b7-001ae28f392a"   # Entra ID → App registrations → your app → Application (client) ID
$tenantId  = "9ce76d42-5ecb-4d8f-939b-a462ad28cf34"                     # Entra ID → App registrations → your app → Directory (tenant) ID
$csvFile   = ".\Hakom-SiteMigration.csv"
# ============================================

$table = Import-Csv $csvFile -Delimiter ","

Write-Output "============================================"
Write-Output "Mode: $(if ($ReportOnly) { 'REPORT ONLY - No deletions' } else { 'DELETE MODE - Will prompt before each deletion' })"
Write-Output "============================================"

foreach ($row in $table) {
    $siteUrl = $row."New Site URL Volue"

    if ([string]::IsNullOrWhiteSpace($siteUrl)) {
        continue
    }

    Write-Output "`nProcessing: $siteUrl"

    try {
        Connect-PnPOnline -Url $siteUrl -Interactive -ClientId $clientId -Tenant $tenantId

        # Get all subsites recursively
        $subsites = Get-PnPSubWeb -Recurse

        if ($subsites.Count -eq 0) {
            Write-Output "  No subsites found"
            continue
        }

        Write-Output "  Found $($subsites.Count) subsite(s):"

        # Sort deepest first to avoid parent-before-child deletion errors
        $subsites = $subsites | Sort-Object -Property ServerRelativeUrl -Descending

        foreach ($subsite in $subsites) {
            Write-Output "    - $($subsite.Title) ($($subsite.ServerRelativeUrl))"

            if (-not $ReportOnly) {
                $confirmation = Read-Host "      Delete '$($subsite.Title)' at $($subsite.ServerRelativeUrl)? (yes/no/all/quit)"

                switch ($confirmation.ToLower()) {
                    "yes" {
                        try {
                            Remove-PnPWeb -Identity $subsite.Id -Force
                            Write-Output "      DELETED"
                        } catch {
                            Write-Output "      ERROR deleting subsite: $($_.Exception.Message)"
                        }
                    }
                    "all" {
                        # Delete this one and all remaining without prompting
                        try {
                            Remove-PnPWeb -Identity $subsite.Id -Force
                            Write-Output "      DELETED"
                        } catch {
                            Write-Output "      ERROR deleting subsite: $($_.Exception.Message)"
                        }
                        # Delete remaining subsites in this site without prompting
                        $remainingSubsites = $subsites | Where-Object { $_.Id -ne $subsite.Id }
                        foreach ($remaining in $remainingSubsites) {
                            Write-Output "    - $($remaining.Title) ($($remaining.ServerRelativeUrl))"
                            try {
                                Remove-PnPWeb -Identity $remaining.Id -Force
                                Write-Output "      DELETED (auto)"
                            } catch {
                                Write-Output "      ERROR deleting subsite: $($_.Exception.Message)"
                            }
                        }
                        break
                    }
                    "quit" {
                        Write-Output "`n  Quit requested - stopping script."
                        exit
                    }
                    default {
                        Write-Output "      SKIPPED"
                    }
                }
            }
        }

    } catch {
        Write-Output "  ERROR connecting to $siteUrl : $($_.Exception.Message)"
    }
}

Write-Output "`n============================================"
Write-Output "Complete!"
if ($ReportOnly) {
    Write-Output "This was REPORT ONLY mode. Run with -ReportOnly:`$false to delete."
}