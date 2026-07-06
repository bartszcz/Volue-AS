<#
.SYNOPSIS
    Builds an Atlassian bulk email-change CSV by matching active managed accounts
    (hakom.at) against the Office365->Office365 mailbox migration mapping (volue.com).

.DESCRIPTION
    Input 1: Atlassian "managed accounts" export (Name, Email, Atlassian ID, Status, ...)
    Input 2: Sharegate/Exchange mailbox migration mapping (SourceEmail -> TargetEmail)

    Output: one row per ACTIVE Atlassian account whose hakom.at email has a matching
    TargetEmail in the mailbox mapping - ready to feed into Atlassian's bulk
    "change email address" import (Atlassian account id + new email).

    Active accounts with no match in the mailbox mapping are written to a separate
    "unmatched" CSV so they can be handled manually.
#>

[CmdletBinding()]
param(
    [string]$ManagedAccountsCsv = "$HOME\Downloads\2026-07-05T15_11_44Z_managed_accounts.csv",
    [string]$MailboxMappingCsv  = "$HOME\OneDrive - Volue AS\Documents\02.Projects\hakom-migration\MailboxesOffice365ToOffice365.csv",
    [string]$OutputCsv          = "$PSScriptRoot\AtlassianEmailChange.csv",
    [string]$UnmatchedCsv       = "$PSScriptRoot\AtlassianEmailChange-Unmatched.csv"
)

$ErrorActionPreference = 'Stop'

$managedAccounts = Import-Csv -Path $ManagedAccountsCsv -Encoding UTF8
$mailboxMapping  = Import-Csv -Path $MailboxMappingCsv -Encoding UTF8

# Build a case-insensitive lookup: hakom source email -> volue target email
$emailMap = @{}
foreach ($row in $mailboxMapping) {
    $source = $row.SourceEmail.Trim().ToLowerInvariant()
    if (-not $emailMap.ContainsKey($source)) {
        $emailMap[$source] = $row.TargetEmail.Trim()
    }
}

$activeAccounts = $managedAccounts | Where-Object { $_.Status -eq 'Active' }

$matched   = [System.Collections.Generic.List[object]]::new()
$unmatched = [System.Collections.Generic.List[object]]::new()

foreach ($account in $activeAccounts) {
    $hakomEmail = $account.Email.Trim()
    $key = $hakomEmail.ToLowerInvariant()

    if ($key -like '*@volue.com') {
        # Already on a volue.com login - no change needed, skip entirely.
        continue
    }

    if ($emailMap.ContainsKey($key)) {
        $matched.Add([pscustomobject]@{
            Name              = $account.Name
            'Atlassian ID'    = $account.'Atlassian ID'
            'Current Email'   = $hakomEmail
            'New Email'       = $emailMap[$key]
        })
    } else {
        $unmatched.Add([pscustomobject]@{
            Name             = $account.Name
            'Atlassian ID'   = $account.'Atlassian ID'
            'Current Email'  = $hakomEmail
        })
    }
}

$matched   | Export-Csv -Path $OutputCsv -NoTypeInformation -Encoding UTF8
$unmatched | Export-Csv -Path $UnmatchedCsv -NoTypeInformation -Encoding UTF8

Write-Host "Active accounts total : $($activeAccounts.Count)"
Write-Host "Matched (mapped)      : $($matched.Count)  -> $OutputCsv"
Write-Host "Unmatched (no mapping): $($unmatched.Count)  -> $UnmatchedCsv"
