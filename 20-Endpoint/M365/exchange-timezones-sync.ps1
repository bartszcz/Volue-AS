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
Write-Host " Sync WorkingHoursTimeZone with Mailbox TimeZone" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "Press ESC at any time to exit.`n" -ForegroundColor Yellow

while ($true) {
    Write-Host "----------------------------------------" -ForegroundColor Gray
    Write-Host "Enter email address (or press ESC to exit): " -ForegroundColor Cyan -NoNewline

    $inputString = ""

    while ($true) {
        $key = [System.Console]::ReadKey($true)

        if ($key.Key -eq 'Escape') {
            Write-Host "`n`nExiting script. Goodbye!" -ForegroundColor Yellow
            exit
        }
        elseif ($key.Key -eq 'Enter') {
            Write-Host ""
            break
        }
        elseif ($key.Key -eq 'Backspace') {
            if ($inputString.Length -gt 0) {
                $inputString = $inputString.Substring(0, $inputString.Length - 1)
                Write-Host "`b `b" -NoNewline
            }
        }
        else {
            $inputString += $key.KeyChar
            Write-Host $key.KeyChar -NoNewline
        }
    }

    $emailAddress = $inputString.Trim()

    if ([string]::IsNullOrWhiteSpace($emailAddress)) {
        Write-Host "No email entered. Please try again." -ForegroundColor Yellow
        continue
    }

    if ($emailAddress -notmatch "^[\w\.\-]+@[\w\.\-]+\.\w+$") {
        Write-Host "Invalid email format. Please try again." -ForegroundColor Red
        continue
    }

    try {
        Write-Host "Looking up user..." -ForegroundColor Gray
        $regionalConfig = Get-MailboxRegionalConfiguration -Identity $emailAddress -ErrorAction Stop
        $mailboxTimezone = $regionalConfig.TimeZone

        if ([string]::IsNullOrWhiteSpace($mailboxTimezone)) {
            Write-Host "User's mailbox timezone is not set." -ForegroundColor Red
            continue
        }

        $calendarConfig = Get-MailboxCalendarConfiguration -Identity $emailAddress -WarningAction SilentlyContinue -ErrorAction Stop
        $workingHoursTimezone = $calendarConfig.WorkingHoursTimeZone

        $mailbox = Get-Mailbox -Identity $emailAddress -ErrorAction Stop

        Write-Host "`nUser: $($mailbox.DisplayName)" -ForegroundColor White
        Write-Host "Mailbox TimeZone: $mailboxTimezone" -ForegroundColor White
        Write-Host "Current WorkingHoursTimeZone: $workingHoursTimezone" -ForegroundColor White

        if ($workingHoursTimezone -eq $mailboxTimezone) {
            Write-Host "`nTimezones already match. No changes needed." -ForegroundColor Green
            continue
        }

        Write-Host "`nUpdating WorkingHoursTimeZone..." -ForegroundColor Gray
        Set-MailboxCalendarConfiguration -Identity $emailAddress -WorkingHoursTimeZone $mailboxTimezone -WarningAction SilentlyContinue -ErrorAction Stop

        Write-Host "SUCCESS: WorkingHoursTimeZone updated from '$workingHoursTimezone' to '$mailboxTimezone'" -ForegroundColor Green
    }
    catch {
        Write-Host "ERROR: $_" -ForegroundColor Red
    }

    Write-Host ""
}
