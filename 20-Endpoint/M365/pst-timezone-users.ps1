if (-not (Get-Module -ListAvailable -Name ExchangeOnlineManagement)) {
    Install-Module -Name ExchangeOnlineManagement -Force -AllowClobber -Scope CurrentUser
}

Import-Module ExchangeOnlineManagement -ErrorAction SilentlyContinue

if (-not (Get-ConnectionInformation -ErrorAction SilentlyContinue)) {
    Connect-ExchangeOnline -ShowBanner:$false
}

$results = @()
$mailboxes = Get-Mailbox -ResultSize Unlimited -RecipientTypeDetails UserMailbox
$count = 0

foreach ($mailbox in $mailboxes) {
    $count++
    Write-Progress -Activity "Checking" -Status "$count/$($mailboxes.Count)" -PercentComplete (($count / $mailboxes.Count) * 100)

    try {
        $config = Get-MailboxCalendarConfiguration -Identity $mailbox.UserPrincipalName -WarningAction SilentlyContinue -ErrorAction Stop
        if ($config.WorkingHoursTimeZone -like "*Pacific Standard Time*") {
            $user = Get-User -Identity $mailbox.UserPrincipalName -ErrorAction SilentlyContinue
            $results += [PSCustomObject]@{
                Name    = $mailbox.DisplayName
                UPN     = $mailbox.UserPrincipalName
                Email   = $mailbox.PrimarySmtpAddress
                Country = $user.CountryOrRegion
                TZ      = $config.WorkingHoursTimeZone
            }
        }
    }
    catch { }
}

Write-Progress -Activity "Checking" -Completed

Write-Host "`nFound $($results.Count) PST mailboxes" -ForegroundColor Green

if ($results.Count -gt 0) {
    $results | Format-Table -AutoSize
    
    if ((Read-Host "Export? (Y/N)") -match '^[Yy]$') {
        $path = ".\PacificTimeZoneMailboxes.csv"
        $results | Export-Csv -Path $path -NoTypeInformation
        Write-Host "Saved: $path"
    }
}