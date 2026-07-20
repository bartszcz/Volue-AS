param(
    # one email address per line
    [string]$UserListPath = "C:\Temp\set-mailbox-access\users.txt"
)

# --- settings ---
$Mailbox = "ops-maintenance@volue.com"

# Automatically add the shared mailbox to Outlook
$AutoMapping = $true

# re-add existing permissions so automapping matches the setting above
# (automapping can only be changed by removing and re-adding the permission)
$FixAutoMapping = $false

# --- main ---
if (-not (Test-Path $UserListPath)) {
    Write-Host "User list not found: $UserListPath" -ForegroundColor Red
    Write-Host "Create it with one email address per line."
    exit 1
}

$Users = @(Get-Content $UserListPath | ForEach-Object { $_.Trim() } | Where-Object { $_ -like "*@*" })
if ($Users.Count -eq 0) {
    Write-Host "No email addresses found in $UserListPath" -ForegroundColor Red
    exit 1
}
Write-Host "Read $($Users.Count) users from $UserListPath"

if (-not (Get-Module -ListAvailable -Name ExchangeOnlineManagement)) {
    try {
        Install-Module ExchangeOnlineManagement -Scope CurrentUser -Force -ErrorAction Stop
    }
    catch {
        Write-Host "Failed to install ExchangeOnlineManagement module: $($_.Exception.Message)" -ForegroundColor Red
        exit 1
    }
}

Import-Module ExchangeOnlineManagement

Write-Host "Connecting to Exchange Online..."
try {
    Connect-ExchangeOnline -ShowBanner:$false -ErrorAction Stop
}
catch {
    Write-Host "Failed to connect to Exchange Online: $($_.Exception.Message)" -ForegroundColor Red
    exit 1
}

try {
    # Confirm that the target mailbox exists
    try {
        $null = Get-EXOMailbox -Identity $Mailbox -ErrorAction Stop
    }
    catch {
        Write-Host "Mailbox $Mailbox not found: $($_.Exception.Message)" -ForegroundColor Red
        exit 1
    }

    $Results = foreach ($User in $Users) {
        try {
            # Confirm that the user exists in Exchange Online
            $null = Get-Recipient -Identity $User -ErrorAction Stop

            $ExistingPermission = Get-MailboxPermission `
                -Identity $Mailbox `
                -User $User `
                -ErrorAction SilentlyContinue |
                Where-Object {
                    $_.AccessRights -contains "FullAccess" -and
                    $_.Deny -eq $false
                }

            if ($ExistingPermission -and -not $FixAutoMapping) {
                [pscustomobject]@{
                    User   = $User
                    Status = "Already assigned"
                    Error  = $null
                }

                continue
            }

            if ($ExistingPermission -and $FixAutoMapping) {
                Remove-MailboxPermission `
                    -Identity $Mailbox `
                    -User $User `
                    -AccessRights FullAccess `
                    -InheritanceType All `
                    -Confirm:$false `
                    -ErrorAction Stop | Out-Null
            }

            Add-MailboxPermission `
                -Identity $Mailbox `
                -User $User `
                -AccessRights FullAccess `
                -InheritanceType All `
                -AutoMapping $AutoMapping `
                -Confirm:$false `
                -ErrorAction Stop | Out-Null

            [pscustomobject]@{
                User   = $User
                Status = if ($ExistingPermission) { "Re-added (automapping fix)" } else { "Granted" }
                Error  = $null
            }
        }
        catch {
            [pscustomobject]@{
                User   = $User
                Status = "Failed"
                Error  = $_.Exception.Message
            }
        }
    }

    $Results | Format-Table -AutoSize

    Write-Host "`nCurrent explicit Full Access assignments:"

    Get-MailboxPermission -Identity $Mailbox |
        Where-Object {
            $_.IsInherited -eq $false -and
            $_.Deny -eq $false -and
            $_.AccessRights -contains "FullAccess"
        } |
        Select-Object User, AccessRights |
        Sort-Object User |
        Format-Table -AutoSize
}
finally {
    Disconnect-ExchangeOnline -Confirm:$false
}
