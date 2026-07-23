# exchange-timezones.ps1 - report and fix WorkingHoursTimeZone vs mailbox TimeZone mismatches in EXO
# bartek / volue ito / 2026-07
# usage: -Mode Report (default) | FixOne -User x@y | FixAll, optional -TimeZoneFilter "Pacific Standard Time"

param(
    [ValidateSet("Report", "FixOne", "FixAll")]
    [string]$Mode = "Report",

    [string]$User = "",

    # only mailboxes whose WorkingHoursTimeZone matches this, empty = no filter
    [string]$TimeZoneFilter = "",

    [string]$OutputPath = "C:\Temp\exchange-timezones"
)

# --- settings ---
$RecipientTypes = "UserMailbox"

# --- functions ---
function Get-TzInfo {
    param([string]$Identity)
    try {
        $regional = Get-MailboxRegionalConfiguration -Identity $Identity -ErrorAction Stop
        $calendar = Get-MailboxCalendarConfiguration -Identity $Identity -WarningAction SilentlyContinue -ErrorAction Stop
        return [PSCustomObject]@{
            MailboxTimeZone      = [string]$regional.TimeZone
            WorkingHoursTimeZone = [string]$calendar.WorkingHoursTimeZone
        }
    }
    catch {
        return $null
    }
}

# --- main ---
if (-not (Get-Module -ListAvailable -Name ExchangeOnlineManagement)) {
    Write-Host "ExchangeOnlineManagement module missing, installing..." -ForegroundColor Yellow
    try {
        Install-Module -Name ExchangeOnlineManagement -Force -AllowClobber -Scope CurrentUser -ErrorAction Stop
    }
    catch {
        Write-Host "Module install failed: $_" -ForegroundColor Red
        exit 1
    }
}
Import-Module ExchangeOnlineManagement -ErrorAction SilentlyContinue

if (-not (Get-ConnectionInformation -ErrorAction SilentlyContinue)) {
    Write-Host "Connecting to Exchange Online..."
    try {
        Connect-ExchangeOnline -ShowBanner:$false -ErrorAction Stop
    }
    catch {
        Write-Host "Exchange Online connect failed: $_" -ForegroundColor Red
        exit 1
    }
}

if ($Mode -eq "FixOne") {
    while ($true) {
        if ($User) { $target = $User }
        else { $target = Read-Host "Email address (blank to quit)" }
        if ([string]::IsNullOrWhiteSpace($target)) { break }

        $info = Get-TzInfo -Identity $target
        if (-not $info) {
            Write-Host "Cannot read config for $target (no mailbox or no access)" -ForegroundColor Red
        }
        elseif ([string]::IsNullOrWhiteSpace($info.MailboxTimeZone)) {
            Write-Host "$target has no mailbox timezone set, nothing to sync to" -ForegroundColor Yellow
        }
        elseif ($info.WorkingHoursTimeZone -eq $info.MailboxTimeZone) {
            Write-Host "$target already in sync ($($info.MailboxTimeZone))" -ForegroundColor Green
        }
        else {
            Write-Host "$target working hours '$($info.WorkingHoursTimeZone)' -> mailbox '$($info.MailboxTimeZone)'"
            if ((Read-Host "Update working hours timezone? (Y/N)") -match '^[Yy]') {
                try {
                    Set-MailboxCalendarConfiguration -Identity $target -WorkingHoursTimeZone $info.MailboxTimeZone -WarningAction SilentlyContinue -ErrorAction Stop
                    Write-Host "Updated." -ForegroundColor Green
                }
                catch {
                    Write-Host "Update failed: $_" -ForegroundColor Red
                }
            }
        }

        if ($User) { break }
    }
    exit 0
}

# Report and FixAll both need the full scan
Write-Host "Fetching mailboxes..."
try {
    $mailboxes = @(Get-Mailbox -ResultSize Unlimited -RecipientTypeDetails $RecipientTypes -ErrorAction Stop)
}
catch {
    Write-Host "Get-Mailbox failed: $_" -ForegroundColor Red
    exit 1
}
if ($mailboxes.Count -eq 0) {
    Write-Host "No mailboxes found." -ForegroundColor Yellow
    exit 0
}
Write-Host "Found $($mailboxes.Count) mailboxes, reading calendar configs (one call per mailbox, takes a while)..."

$results = @()
$readFailed = 0
$i = 0
foreach ($mailbox in $mailboxes) {
    $i++
    Write-Progress -Activity "Scanning" -Status "$i / $($mailboxes.Count)" -PercentComplete (($i / $mailboxes.Count) * 100)

    $info = Get-TzInfo -Identity $mailbox.PrimarySmtpAddress
    if (-not $info) { $readFailed++; continue }

    if ($TimeZoneFilter) {
        if ($info.WorkingHoursTimeZone -notlike "*$TimeZoneFilter*") { continue }
    }
    else {
        # no filter = mismatches only, otherwise this dumps the whole tenant
        if ($info.WorkingHoursTimeZone -eq $info.MailboxTimeZone) { continue }
    }

    $country = ""
    try {
        $country = [string](Get-User -Identity $mailbox.UserPrincipalName -ErrorAction Stop).CountryOrRegion
    }
    catch { }

    $results += [PSCustomObject]@{
        DisplayName          = $mailbox.DisplayName
        Email                = [string]$mailbox.PrimarySmtpAddress
        Country              = $country
        WorkingHoursTimeZone = $info.WorkingHoursTimeZone
        MailboxTimeZone      = $info.MailboxTimeZone
        InSync               = ($info.WorkingHoursTimeZone -eq $info.MailboxTimeZone)
    }
}
Write-Progress -Activity "Scanning" -Completed

if ($readFailed -gt 0) {
    Write-Host "$readFailed mailbox(es) could not be read and were skipped" -ForegroundColor Yellow
}
Write-Host "Found $($results.Count) matching mailbox(es)"

if (-not (Test-Path $OutputPath)) {
    try {
        New-Item -ItemType Directory -Path $OutputPath -Force -ErrorAction Stop | Out-Null
    }
    catch {
        Write-Host "Cannot create ${OutputPath}: $_" -ForegroundColor Red
        exit 1
    }
}
$stamp = Get-Date -Format "yyyyMMdd_HHmm"

if ($Mode -eq "Report") {
    if ($results.Count -eq 0) {
        Write-Host "Nothing to report." -ForegroundColor Green
        exit 0
    }
    $results | Format-Table -AutoSize

    $csv = Join-Path $OutputPath "exchange-timezones-report_$stamp.csv"
    $json = Join-Path $OutputPath "exchange-timezones-report_$stamp.json"
    try {
        $results | Export-Csv -Path $csv -NoTypeInformation -Encoding UTF8
        ConvertTo-Json -InputObject @($results) | Out-File -FilePath $json -Encoding UTF8
    }
    catch {
        Write-Host "Export failed: $_" -ForegroundColor Red
        exit 1
    }
    Write-Host "Done. Report written to $csv and $json"
    exit 0
}

# FixAll
$toFix = @($results | Where-Object { -not $_.InSync -and -not [string]::IsNullOrWhiteSpace($_.MailboxTimeZone) })
if ($toFix.Count -eq 0) {
    Write-Host "Nothing to fix, all matching mailboxes are in sync." -ForegroundColor Green
    exit 0
}

Write-Host "$($toFix.Count) mailbox(es) out of sync. Y = fix, N = skip, A = fix all remaining, Q = quit"
$log = @()
$fixAllRest = $false
foreach ($entry in $toFix) {
    Write-Host ""
    Write-Host "$($entry.DisplayName) <$($entry.Email)> working hours '$($entry.WorkingHoursTimeZone)' -> mailbox '$($entry.MailboxTimeZone)'"

    $answer = "Y"
    if (-not $fixAllRest) {
        $answer = Read-Host "Fix? (Y/N/A/Q)"
        if ($answer -match '^[Qq]') { break }
        if ($answer -match '^[Aa]') { $fixAllRest = $true; $answer = "Y" }
    }

    $result = "Skipped"
    if ($answer -match '^[Yy]') {
        try {
            Set-MailboxCalendarConfiguration -Identity $entry.Email -WorkingHoursTimeZone $entry.MailboxTimeZone -WarningAction SilentlyContinue -ErrorAction Stop
            $result = "Fixed"
            Write-Host "Fixed." -ForegroundColor Green
        }
        catch {
            $result = "Failed: $_"
            Write-Host "Failed: $_" -ForegroundColor Red
        }
    }
    else {
        Write-Host "Skipped." -ForegroundColor Yellow
    }

    $log += [PSCustomObject]@{
        DisplayName          = $entry.DisplayName
        Email                = $entry.Email
        WorkingHoursTimeZone = $entry.WorkingHoursTimeZone
        MailboxTimeZone      = $entry.MailboxTimeZone
        Result               = $result
    }
}

$fixed = @($log | Where-Object { $_.Result -eq "Fixed" }).Count
$skipped = @($log | Where-Object { $_.Result -eq "Skipped" }).Count
$failed = @($log | Where-Object { $_.Result -like "Failed*" }).Count
Write-Host ""
Write-Host "Fixed $fixed, skipped $skipped, failed $failed, not asked $($toFix.Count - $log.Count)"

if ($log.Count -gt 0) {
    $csv = Join-Path $OutputPath "exchange-timezones-fixall_$stamp.csv"
    $json = Join-Path $OutputPath "exchange-timezones-fixall_$stamp.json"
    try {
        $log | Export-Csv -Path $csv -NoTypeInformation -Encoding UTF8
        ConvertTo-Json -InputObject @($log) | Out-File -FilePath $json -Encoding UTF8
        Write-Host "Done. Log written to $csv and $json"
    }
    catch {
        Write-Host "Log export failed: $_" -ForegroundColor Red
    }
}
