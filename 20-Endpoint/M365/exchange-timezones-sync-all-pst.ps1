if (-not (Get-Module -ListAvailable -Name ExchangeOnlineManagement)) {
    Write-Host "ExchangeOnlineManagement module not found. Installing..." -ForegroundColor Yellow
    try {
        Install-Module -Name ExchangeOnlineManagement -Force -AllowClobber -Scope CurrentUser
        Write-Host "Module installed successfully." -ForegroundColor Green
    }
    catch {
        Write-Host "Failed to install module. Please run PowerShell as Administrator and try again." -ForegroundColor Red
        Write-Host "Error: $_" -ForegroundColor Red
        exit
    }
}

Import-Module ExchangeOnlineManagement -ErrorAction SilentlyContinue

$connectionInfo = Get-ConnectionInformation -ErrorAction SilentlyContinue

if (-not $connectionInfo) {
    Write-Host "Connecting to Exchange Online..." -ForegroundColor Cyan
    try {
        Connect-ExchangeOnline -ShowBanner:$false
        Write-Host "Connected successfully." -ForegroundColor Green
    }
    catch {
        Write-Host "Failed to connect to Exchange Online." -ForegroundColor Red
        Write-Host "Error: $_" -ForegroundColor Red
        exit
    }
}
else {
    Write-Host "Already connected to Exchange Online." -ForegroundColor Green
}

Write-Host "`n========================================" -ForegroundColor Cyan
Write-Host " Sync PST WorkingHoursTimeZone with Mailbox TimeZone" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "Finding users with PST working hours timezone...`n" -ForegroundColor Yellow

# PST timezone identifiers to match
$pstTimezones = @(
    "Pacific Standard Time",
    "America/Los_Angeles",
    "PST",
    "(UTC-08:00) Pacific Time (US & Canada)"
)

try {
    Write-Host "Fetching all mailboxes..." -ForegroundColor Gray
    $allMailboxes = Get-Mailbox -ResultSize Unlimited -ErrorAction Stop
    Write-Host "Found $($allMailboxes.Count) total mailboxes." -ForegroundColor Gray
    
    $pstUsers = @()
    $processedCount = 0
    
    Write-Host "Scanning for users with PST working hours timezone..." -ForegroundColor Gray
    
    foreach ($mailbox in $allMailboxes) {
        $processedCount++
        Write-Progress -Activity "Scanning mailboxes" -Status "Processing $processedCount of $($allMailboxes.Count)" -PercentComplete (($processedCount / $allMailboxes.Count) * 100)
        
        try {
            $calendarConfig = Get-MailboxCalendarConfiguration -Identity $mailbox.PrimarySmtpAddress -WarningAction SilentlyContinue -ErrorAction Stop
            $workingHoursTimezone = $calendarConfig.WorkingHoursTimeZone
            
            # Check if working hours timezone is PST
            $isPst = $false
            foreach ($pstTz in $pstTimezones) {
                if ($workingHoursTimezone -like "*$pstTz*" -or $workingHoursTimezone -eq $pstTz) {
                    $isPst = $true
                    break
                }
            }
            
            if ($isPst) {
                $regionalConfig = Get-MailboxRegionalConfiguration -Identity $mailbox.PrimarySmtpAddress -ErrorAction Stop
                $mailboxTimezone = $regionalConfig.TimeZone
                
                # Only add if timezones don't match (need sync)
                if ($workingHoursTimezone -ne $mailboxTimezone -and -not [string]::IsNullOrWhiteSpace($mailboxTimezone)) {
                    $pstUsers += [PSCustomObject]@{
                        DisplayName = $mailbox.DisplayName
                        Email = $mailbox.PrimarySmtpAddress
                        WorkingHoursTimeZone = $workingHoursTimezone
                        MailboxTimeZone = $mailboxTimezone
                    }
                }
            }
        }
        catch {
            # Skip users that can't be queried
            continue
        }
    }
    
    Write-Progress -Activity "Scanning mailboxes" -Completed
    
    if ($pstUsers.Count -eq 0) {
        Write-Host "`nNo users found with PST working hours timezone that need syncing." -ForegroundColor Yellow
        Write-Host "All PST users either have matching timezones or no mailbox timezone set." -ForegroundColor Gray
        exit
    }
    
    Write-Host "`n========================================" -ForegroundColor Cyan
    Write-Host " Found $($pstUsers.Count) user(s) with PST working hours needing sync" -ForegroundColor Cyan
    Write-Host "========================================" -ForegroundColor Cyan
    Write-Host "Press Y to confirm, N to skip, or ESC to exit.`n" -ForegroundColor Yellow
    
    $syncedCount = 0
    $skippedCount = 0
    
    foreach ($user in $pstUsers) {
        Write-Host "----------------------------------------" -ForegroundColor Gray
        Write-Host "User: $($user.DisplayName)" -ForegroundColor White
        Write-Host "Email: $($user.Email)" -ForegroundColor White
        Write-Host "Current WorkingHoursTimeZone: $($user.WorkingHoursTimeZone)" -ForegroundColor Yellow
        Write-Host "Mailbox TimeZone (target): $($user.MailboxTimeZone)" -ForegroundColor Cyan
        Write-Host ""
        Write-Host "Sync WorkingHoursTimeZone to '$($user.MailboxTimeZone)'? (Y/N/ESC): " -ForegroundColor Magenta -NoNewline
        
        while ($true) {
            $key = [System.Console]::ReadKey($true)
            
            if ($key.Key -eq 'Escape') {
                Write-Host "`n`nExiting script." -ForegroundColor Yellow
                Write-Host "`nSummary: Synced $syncedCount, Skipped $skippedCount, Remaining $($pstUsers.Count - $syncedCount - $skippedCount)" -ForegroundColor Cyan
                exit
            }
            elseif ($key.Key -eq 'Y') {
                Write-Host "Y"
                try {
                    Set-MailboxCalendarConfiguration -Identity $user.Email -WorkingHoursTimeZone $user.MailboxTimeZone -WarningAction SilentlyContinue -ErrorAction Stop
                    Write-Host "SUCCESS: Updated WorkingHoursTimeZone to '$($user.MailboxTimeZone)'" -ForegroundColor Green
                    $syncedCount++
                }
                catch {
                    Write-Host "ERROR: Failed to update - $_" -ForegroundColor Red
                }
                break
            }
            elseif ($key.Key -eq 'N') {
                Write-Host "N"
                Write-Host "Skipped." -ForegroundColor Yellow
                $skippedCount++
                break
            }
        }
        Write-Host ""
    }
    
    Write-Host "========================================" -ForegroundColor Cyan
    Write-Host " Sync Complete!" -ForegroundColor Cyan
    Write-Host "========================================" -ForegroundColor Cyan
    Write-Host "Users synced: $syncedCount" -ForegroundColor Green
    Write-Host "Users skipped: $skippedCount" -ForegroundColor Yellow
}
catch {
    Write-Host "ERROR: Failed to fetch mailboxes - $_" -ForegroundColor Red
    exit
}
