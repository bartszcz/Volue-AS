# Set-MailboxForwarding.ps1
# This script sets up auto-forwarding from source mailboxes to destination mailboxes
# Requires Exchange Online PowerShell module

#Requires -Modules ExchangeOnlineManagement

param(
    [Parameter(Mandatory = $false)]
    [string]$CsvPath = ".\MailboxesOffice365ToOffice365.csv",
    
    [Parameter(Mandatory = $false)]
    [switch]$WhatIf,
    
    [Parameter(Mandatory = $false)]
    [switch]$DeliverAndForward = $true  # Set to $true to keep a copy in source mailbox
)

# Import the CSV file
Write-Host "Reading mailbox mapping from: $CsvPath" -ForegroundColor Cyan

if (-not (Test-Path $CsvPath)) {
    Write-Error "CSV file not found: $CsvPath"
    exit 1
}

# Import CSV with semicolon delimiter
$mailboxMappings = Import-Csv -Path $CsvPath -Delimiter ";"

Write-Host "Found $($mailboxMappings.Count) mailbox mappings to process" -ForegroundColor Cyan
Write-Host ""

# Check if connected to Exchange Online
try {
    $null = Get-OrganizationConfig -ErrorAction Stop
    Write-Host "Connected to Exchange Online" -ForegroundColor Green
}
catch {
    Write-Host "Not connected to Exchange Online. Connecting..." -ForegroundColor Yellow
    try {
        Connect-ExchangeOnline -ShowBanner:$false
        Write-Host "Successfully connected to Exchange Online" -ForegroundColor Green
    }
    catch {
        Write-Error "Failed to connect to Exchange Online: $_"
        exit 1
    }
}

Write-Host ""
Write-Host "=" * 80 -ForegroundColor Gray
Write-Host "Starting mailbox forwarding configuration..." -ForegroundColor Cyan
Write-Host "DeliverAndForward: $DeliverAndForward (keep copy in source: $DeliverAndForward)" -ForegroundColor Cyan
Write-Host "WhatIf Mode: $WhatIf" -ForegroundColor Cyan
Write-Host "=" * 80 -ForegroundColor Gray
Write-Host ""

$successCount = 0
$errorCount = 0
$skippedCount = 0
$results = @()

foreach ($mapping in $mailboxMappings) {
    $sourceEmail = $mapping.SourceEmail
    $targetEmail = $mapping.TargetEmail
    $displayName = $mapping.DisplayName
    
    Write-Host "Processing: $displayName" -ForegroundColor White
    Write-Host "  Source: $sourceEmail" -ForegroundColor Gray
    Write-Host "  Target: $targetEmail" -ForegroundColor Gray
    
    try {
        # Check if source mailbox exists
        $sourceMailbox = Get-Mailbox -Identity $sourceEmail -ErrorAction Stop
        
        # Check current forwarding status
        $currentForwarding = $sourceMailbox.ForwardingSmtpAddress
        
        if ($currentForwarding -eq "smtp:$targetEmail") {
            Write-Host "  Status: Already configured - SKIPPED" -ForegroundColor Yellow
            $skippedCount++
            $results += [PSCustomObject]@{
                DisplayName    = $displayName
                SourceEmail    = $sourceEmail
                TargetEmail    = $targetEmail
                Status         = "Skipped"
                Details        = "Forwarding already configured"
            }
            continue
        }
        
        if ($WhatIf) {
            Write-Host "  Status: WHATIF - Would set forwarding to $targetEmail" -ForegroundColor Magenta
            $results += [PSCustomObject]@{
                DisplayName    = $displayName
                SourceEmail    = $sourceEmail
                TargetEmail    = $targetEmail
                Status         = "WhatIf"
                Details        = "Would configure forwarding"
            }
        }
        else {
            # Set the forwarding
            Set-Mailbox -Identity $sourceEmail `
                -ForwardingSmtpAddress $targetEmail `
                -DeliverToMailboxAndForward $DeliverAndForward `
                -ErrorAction Stop
            
            Write-Host "  Status: SUCCESS" -ForegroundColor Green
            $successCount++
            $results += [PSCustomObject]@{
                DisplayName    = $displayName
                SourceEmail    = $sourceEmail
                TargetEmail    = $targetEmail
                Status         = "Success"
                Details        = "Forwarding configured"
            }
        }
    }
    catch {
        Write-Host "  Status: ERROR - $($_.Exception.Message)" -ForegroundColor Red
        $errorCount++
        $results += [PSCustomObject]@{
            DisplayName    = $displayName
            SourceEmail    = $sourceEmail
            TargetEmail    = $targetEmail
            Status         = "Error"
            Details        = $_.Exception.Message
        }
    }
    
    Write-Host ""
}

# Summary
Write-Host "=" * 80 -ForegroundColor Gray
Write-Host "SUMMARY" -ForegroundColor Cyan
Write-Host "=" * 80 -ForegroundColor Gray
Write-Host "Total mailboxes processed: $($mailboxMappings.Count)" -ForegroundColor White
Write-Host "  Successful: $successCount" -ForegroundColor Green
Write-Host "  Skipped (already configured): $skippedCount" -ForegroundColor Yellow
Write-Host "  Errors: $errorCount" -ForegroundColor Red
Write-Host ""

# Export results to CSV
$resultsPath = ".\ForwardingResults_$(Get-Date -Format 'yyyyMMdd_HHmmss').csv"
$results | Export-Csv -Path $resultsPath -NoTypeInformation -Encoding UTF8
Write-Host "Results exported to: $resultsPath" -ForegroundColor Cyan

# Show errors if any
if ($errorCount -gt 0) {
    Write-Host ""
    Write-Host "ERRORS:" -ForegroundColor Red
    $results | Where-Object { $_.Status -eq "Error" } | Format-Table -AutoSize
}
