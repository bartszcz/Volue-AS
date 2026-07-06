<#
.SYNOPSIS
    Migrates FullAccess, SendAs, and SendOnBehalf permissions from source shared mailboxes
    to their target equivalents using the all-mx-mapping.csv identity map.

.DESCRIPTION
    1. Reads all-mx-mapping.csv to build a source→target identity map.
    2. Connects to source tenant Exchange Online and identifies which entries in the
       CSV are SharedMailbox recipients.
    3. For each shared mailbox, collects:
         - FullAccess  (Get-MailboxPermission)
         - SendAs      (Get-RecipientPermission)
         - SendOnBehalf (Get-Mailbox.GrantSendOnBehalfTo)
    4. Translates grantee identities to target UPNs using the CSV map.
    5. Connects to target tenant Exchange Online and applies the translated permissions.

.PARAMETER MappingCsv
    Path to all-mx-mapping.csv (columns: SourceEmail, TargetEmail, SourceMailboxName, TargetMailboxName).
    Defaults to C:\Optimeering\all-mx-mapping.csv.

.PARAMETER SourceAdminUpn
    UPN to hint to EXO which account to use for the source tenant login (e.g. admin@optimeering.com).

.PARAMETER TargetAdminUpn
    UPN to hint to EXO which account to use for the target tenant login (e.g. admin@volue.com).

.PARAMETER AutoMapping
    If specified, sets AutoMapping=$true when granting FullAccess (auto-mounts mailbox in Outlook).
    Default is $false — recommended for migration scenarios.

.PARAMETER DryRun
    Reads source and resolves mappings but makes no changes on the target tenant.

.EXAMPLE
    # Dry run first — always
    .\Migrate-SharedMailboxPermissions.ps1 -DryRun

    # Live run
    .\Migrate-SharedMailboxPermissions.ps1 `
        -SourceAdminUpn admin@optimeering.com `
        -TargetAdminUpn admin@volue.com

.NOTES
    Module required : ExchangeOnlineManagement  (Install-Module ExchangeOnlineManagement -Scope CurrentUser)
    Run context     : Must be Exchange Admin (or Global Admin) on both tenants.
    Safe to re-run  : Yes — duplicate permission grants are caught and skipped.
#>

[CmdletBinding()]
param(
    [string]$MappingCsv     = "C:\Optimeering\all-mx-mapping.csv",
    [string]$SourceAdminUpn = "",
    [string]$TargetAdminUpn = "",
    [switch]$AutoMapping,
    [switch]$DryRun,
    [string]$LogFile        = ".\SharedMailboxPermMigration_$(Get-Date -Format 'yyyyMMdd_HHmmss').log"
)

#region ── Logging ─────────────────────────────────────────────────────────────
function Write-Log {
    param([string]$Message, [ValidateSet('INFO','WARN','ERROR','SUCCESS')]$Level = 'INFO')
    $ts   = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $line = "[$ts][$Level] $Message"
    $color = switch ($Level) {
        'SUCCESS' { 'Green'  }
        'WARN'    { 'Yellow' }
        'ERROR'   { 'Red'    }
        default   { 'White'  }
    }
    Write-Host $line -ForegroundColor $color
    Add-Content -Path $LogFile -Value $line
}
#endregion

#region ── Module check ────────────────────────────────────────────────────────
if (-not (Get-Module -ListAvailable -Name ExchangeOnlineManagement)) {
    Write-Log "ERROR: ExchangeOnlineManagement module is not installed." ERROR
    Write-Log "Run: Install-Module ExchangeOnlineManagement -Scope CurrentUser" ERROR
    exit 1
}
Import-Module ExchangeOnlineManagement -ErrorAction Stop
#endregion

Write-Log "=== Migrate-SharedMailboxPermissions ===" INFO
if ($DryRun) { Write-Log "*** DRY RUN MODE — no changes will be made ***" WARN }
Write-Log "Log: $LogFile" INFO

#region ── Load CSV ─────────────────────────────────────────────────────────────
if (-not (Test-Path $MappingCsv)) {
    Write-Log "ERROR: Mapping CSV not found: $MappingCsv" ERROR
    exit 1
}
$csv = Import-Csv -Path $MappingCsv | Where-Object { $_.SourceEmail -and $_.SourceEmail.Trim() -ne '' }
Write-Log "Loaded $($csv.Count) rows from $MappingCsv" INFO

# Build source→target identity lookup (used to translate permission grantees)
$userMap = @{}
foreach ($row in $csv) {
    $userMap[$row.SourceEmail.ToLower()] = $row.TargetEmail.Trim()
}
# Build source→target mailbox lookup (shared mailboxes to process)
$mailboxMap = @{}
foreach ($row in $csv) {
    $mailboxMap[$row.SourceEmail.ToLower()] = [PSCustomObject]@{
        TargetEmail = $row.TargetEmail.Trim()
        SourceName  = $row.SourceMailboxName
        TargetName  = $row.TargetMailboxName
    }
}
#endregion

#region ── SOURCE: collect permissions ─────────────────────────────────────────
Write-Log "" INFO
Write-Log "Connecting to SOURCE tenant Exchange Online..." WARN
$srcConnectArgs = @{ ShowBanner = $false; ShowProgress = $false; Device = $true }
if ($SourceAdminUpn) { $srcConnectArgs['UserPrincipalName'] = $SourceAdminUpn }
try {
    Connect-ExchangeOnline @srcConnectArgs -ErrorAction Stop
    Write-Log "Connected to source tenant." SUCCESS
} catch {
    Write-Log "ERROR: Failed to connect to source tenant: $_" ERROR
    exit 1
}

$sharedMailboxData = [System.Collections.Generic.List[PSCustomObject]]::new()

foreach ($row in $csv) {
    $srcEmail = $row.SourceEmail.Trim().ToLower()

    Write-Log "" INFO
    Write-Log "Checking: $srcEmail" INFO

    # Confirm it is a SharedMailbox in EXO
    try {
        $mbx = Get-Mailbox -Identity $srcEmail -RecipientTypeDetails SharedMailbox -ErrorAction Stop
    } catch {
        Write-Log "  SKIP — not a shared mailbox or not found: $($_.Exception.Message)" WARN
        continue
    }

    Write-Log "  Confirmed SharedMailbox: $($mbx.DisplayName)" SUCCESS

    # FullAccess permissions
    $fullAccessGrants = @()
    try {
        $fullAccessGrants = Get-MailboxPermission -Identity $srcEmail -ErrorAction Stop |
            Where-Object {
                $_.AccessRights -contains 'FullAccess' -and
                -not $_.IsInherited -and
                $_.User -notmatch 'NT AUTHORITY|S-1-5|SELF|DiscoverySearchMailbox'
            }
        Write-Log "  FullAccess grants : $($fullAccessGrants.Count)" INFO
    } catch {
        Write-Log "  WARN: Could not read FullAccess permissions: $_" WARN
    }

    # SendAs permissions
    $sendAsGrants = @()
    try {
        $sendAsGrants = Get-RecipientPermission -Identity $srcEmail -ErrorAction Stop |
            Where-Object {
                $_.AccessRights -contains 'SendAs' -and
                $_.Trustee -notmatch 'NT AUTHORITY|S-1-5|SELF'
            }
        Write-Log "  SendAs grants     : $($sendAsGrants.Count)" INFO
    } catch {
        Write-Log "  WARN: Could not read SendAs permissions: $_" WARN
    }

    # SendOnBehalf
    $sendOnBehalfGrants = @()
    try {
        $sobRaw = $mbx.GrantSendOnBehalfTo
        if ($sobRaw -and $sobRaw.Count -gt 0) {
            # GrantSendOnBehalfTo returns DN aliases — resolve to SMTP
            foreach ($entry in $sobRaw) {
                try {
                    $resolved = Get-Recipient -Identity $entry.ToString() -ErrorAction Stop
                    $sendOnBehalfGrants += $resolved.PrimarySmtpAddress.ToLower()
                } catch {
                    Write-Log "  WARN: Could not resolve SendOnBehalf entry '$entry': $_" WARN
                }
            }
        }
        Write-Log "  SendOnBehalf      : $($sendOnBehalfGrants.Count)" INFO
    } catch {
        Write-Log "  WARN: Could not read SendOnBehalf: $_" WARN
    }

    $sharedMailboxData.Add([PSCustomObject]@{
        SourceEmail         = $srcEmail
        TargetEmail         = $mailboxMap[$srcEmail].TargetEmail
        SourceName          = $mbx.DisplayName
        FullAccessGrants    = $fullAccessGrants
        SendAsGrants        = $sendAsGrants
        SendOnBehalfGrants  = $sendOnBehalfGrants
    })
}

Write-Log "" INFO
Write-Log "Disconnecting from source tenant..." INFO
Disconnect-ExchangeOnline -Confirm:$false
Write-Log "Found $($sharedMailboxData.Count) shared mailbox(es) to process." INFO
#endregion

#region ── TARGET: apply permissions ───────────────────────────────────────────
Write-Log "" INFO
Write-Log "Connecting to TARGET tenant Exchange Online..." WARN
$tgtConnectArgs = @{ ShowBanner = $false; ShowProgress = $false; Device = $true }
if ($TargetAdminUpn) { $tgtConnectArgs['UserPrincipalName'] = $TargetAdminUpn }
try {
    Connect-ExchangeOnline @tgtConnectArgs -ErrorAction Stop
    Write-Log "Connected to target tenant." SUCCESS
} catch {
    Write-Log "ERROR: Failed to connect to target tenant: $_" ERROR
    exit 1
}

$successCount = 0
$skipCount    = 0
$errorCount   = 0

$report = [System.Collections.Generic.List[PSCustomObject]]::new()

foreach ($entry in $sharedMailboxData) {
    $tgtMailbox = $entry.TargetEmail
    Write-Log "" INFO
    Write-Log "--- Processing target mailbox: $tgtMailbox ($($entry.SourceName))" INFO

    # Verify the target mailbox exists
    try {
        $tgtMbx = Get-Mailbox -Identity $tgtMailbox -ErrorAction Stop
    } catch {
        Write-Log "  ERROR: Target mailbox '$tgtMailbox' not found — skipping." ERROR
        $errorCount++
        $report.Add([PSCustomObject]@{
            SourceMailbox = $entry.SourceEmail
            TargetMailbox = $tgtMailbox
            PermType      = 'N/A'
            GrantedTo     = 'N/A'
            Status        = 'ERROR'
            Reason        = "Target mailbox not found: $($_.Exception.Message)"
        })
        continue
    }

    # ── FullAccess ────────────────────────────────────────────────────────────
    foreach ($grant in $entry.FullAccessGrants) {
        $srcGrantee = $grant.User.ToString().ToLower()
        if ($srcGrantee -match '@') {
            $srcGrantee = ($srcGrantee -split '@')[0] + '@' + ($srcGrantee -split '@')[1]
        }
        $tgtGrantee = $userMap[$srcGrantee]
        if (-not $tgtGrantee) {
            Write-Log "  SKIP [FullAccess] '$srcGrantee' — not in mapping." WARN
            $skipCount++
            $report.Add([PSCustomObject]@{
                SourceMailbox = $entry.SourceEmail; TargetMailbox = $tgtMailbox
                PermType = 'FullAccess'; GrantedTo = $srcGrantee
                Status = 'SKIPPED'; Reason = 'Grantee not in mapping'
            })
            continue
        }

        if ($DryRun) {
            Write-Log "  [DRY-RUN][FullAccess] Would grant $tgtGrantee on $tgtMailbox (AutoMapping:$($AutoMapping.IsPresent))" INFO
            $successCount++
            $report.Add([PSCustomObject]@{
                SourceMailbox = $entry.SourceEmail; TargetMailbox = $tgtMailbox
                PermType = 'FullAccess'; GrantedTo = $tgtGrantee
                Status = 'DRYRUN'; Reason = ''
            })
        } else {
            try {
                Add-MailboxPermission -Identity $tgtMailbox -User $tgtGrantee `
                    -AccessRights FullAccess -AutoMapping:$AutoMapping.IsPresent `
                    -ErrorAction Stop | Out-Null
                Write-Log "  [FullAccess] Granted $tgtGrantee → $tgtMailbox" SUCCESS
                $successCount++
                $report.Add([PSCustomObject]@{
                    SourceMailbox = $entry.SourceEmail; TargetMailbox = $tgtMailbox
                    PermType = 'FullAccess'; GrantedTo = $tgtGrantee
                    Status = 'SUCCESS'; Reason = ''
                })
            } catch {
                if ($_ -match 'already|duplicate|exists') {
                    Write-Log "  [FullAccess] Already granted: $tgtGrantee" INFO
                    $report.Add([PSCustomObject]@{
                        SourceMailbox = $entry.SourceEmail; TargetMailbox = $tgtMailbox
                        PermType = 'FullAccess'; GrantedTo = $tgtGrantee
                        Status = 'ALREADY_SET'; Reason = 'Permission already exists'
                    })
                } else {
                    Write-Log "  [FullAccess] ERROR granting $tgtGrantee : $_" ERROR
                    $errorCount++
                    $report.Add([PSCustomObject]@{
                        SourceMailbox = $entry.SourceEmail; TargetMailbox = $tgtMailbox
                        PermType = 'FullAccess'; GrantedTo = $tgtGrantee
                        Status = 'ERROR'; Reason = $_.Exception.Message
                    })
                }
            }
        }
    }

    # ── SendAs ────────────────────────────────────────────────────────────────
    foreach ($grant in $entry.SendAsGrants) {
        $srcGrantee = $grant.Trustee.ToString().ToLower()
        $tgtGrantee = $userMap[$srcGrantee]
        if (-not $tgtGrantee) {
            Write-Log "  SKIP [SendAs] '$srcGrantee' — not in mapping." WARN
            $skipCount++
            $report.Add([PSCustomObject]@{
                SourceMailbox = $entry.SourceEmail; TargetMailbox = $tgtMailbox
                PermType = 'SendAs'; GrantedTo = $srcGrantee
                Status = 'SKIPPED'; Reason = 'Grantee not in mapping'
            })
            continue
        }

        if ($DryRun) {
            Write-Log "  [DRY-RUN][SendAs] Would grant $tgtGrantee on $tgtMailbox" INFO
            $successCount++
            $report.Add([PSCustomObject]@{
                SourceMailbox = $entry.SourceEmail; TargetMailbox = $tgtMailbox
                PermType = 'SendAs'; GrantedTo = $tgtGrantee
                Status = 'DRYRUN'; Reason = ''
            })
        } else {
            try {
                Add-RecipientPermission -Identity $tgtMailbox -Trustee $tgtGrantee `
                    -AccessRights SendAs -Confirm:$false -ErrorAction Stop | Out-Null
                Write-Log "  [SendAs] Granted $tgtGrantee → $tgtMailbox" SUCCESS
                $successCount++
                $report.Add([PSCustomObject]@{
                    SourceMailbox = $entry.SourceEmail; TargetMailbox = $tgtMailbox
                    PermType = 'SendAs'; GrantedTo = $tgtGrantee
                    Status = 'SUCCESS'; Reason = ''
                })
            } catch {
                if ($_ -match 'already|duplicate|exists') {
                    Write-Log "  [SendAs] Already granted: $tgtGrantee" INFO
                    $report.Add([PSCustomObject]@{
                        SourceMailbox = $entry.SourceEmail; TargetMailbox = $tgtMailbox
                        PermType = 'SendAs'; GrantedTo = $tgtGrantee
                        Status = 'ALREADY_SET'; Reason = 'Permission already exists'
                    })
                } else {
                    Write-Log "  [SendAs] ERROR granting $tgtGrantee : $_" ERROR
                    $errorCount++
                    $report.Add([PSCustomObject]@{
                        SourceMailbox = $entry.SourceEmail; TargetMailbox = $tgtMailbox
                        PermType = 'SendAs'; GrantedTo = $tgtGrantee
                        Status = 'ERROR'; Reason = $_.Exception.Message
                    })
                }
            }
        }
    }

    # ── SendOnBehalf ──────────────────────────────────────────────────────────
    foreach ($srcGrantee in $entry.SendOnBehalfGrants) {
        $tgtGrantee = $userMap[$srcGrantee.ToLower()]
        if (-not $tgtGrantee) {
            Write-Log "  SKIP [SendOnBehalf] '$srcGrantee' — not in mapping." WARN
            $skipCount++
            $report.Add([PSCustomObject]@{
                SourceMailbox = $entry.SourceEmail; TargetMailbox = $tgtMailbox
                PermType = 'SendOnBehalf'; GrantedTo = $srcGrantee
                Status = 'SKIPPED'; Reason = 'Grantee not in mapping'
            })
            continue
        }

        if ($DryRun) {
            Write-Log "  [DRY-RUN][SendOnBehalf] Would grant $tgtGrantee on $tgtMailbox" INFO
            $successCount++
            $report.Add([PSCustomObject]@{
                SourceMailbox = $entry.SourceEmail; TargetMailbox = $tgtMailbox
                PermType = 'SendOnBehalf'; GrantedTo = $tgtGrantee
                Status = 'DRYRUN'; Reason = ''
            })
        } else {
            try {
                Set-Mailbox -Identity $tgtMailbox `
                    -GrantSendOnBehalfTo @{ Add = $tgtGrantee } -ErrorAction Stop
                Write-Log "  [SendOnBehalf] Granted $tgtGrantee → $tgtMailbox" SUCCESS
                $successCount++
                $report.Add([PSCustomObject]@{
                    SourceMailbox = $entry.SourceEmail; TargetMailbox = $tgtMailbox
                    PermType = 'SendOnBehalf'; GrantedTo = $tgtGrantee
                    Status = 'SUCCESS'; Reason = ''
                })
            } catch {
                if ($_ -match 'already|duplicate|exists') {
                    Write-Log "  [SendOnBehalf] Already granted: $tgtGrantee" INFO
                    $report.Add([PSCustomObject]@{
                        SourceMailbox = $entry.SourceEmail; TargetMailbox = $tgtMailbox
                        PermType = 'SendOnBehalf'; GrantedTo = $tgtGrantee
                        Status = 'ALREADY_SET'; Reason = 'Permission already exists'
                    })
                } else {
                    Write-Log "  [SendOnBehalf] ERROR granting $tgtGrantee : $_" ERROR
                    $errorCount++
                    $report.Add([PSCustomObject]@{
                        SourceMailbox = $entry.SourceEmail; TargetMailbox = $tgtMailbox
                        PermType = 'SendOnBehalf'; GrantedTo = $tgtGrantee
                        Status = 'ERROR'; Reason = $_.Exception.Message
                    })
                }
            }
        }
    }
}

Disconnect-ExchangeOnline -Confirm:$false
#endregion

#region ── Summary & report ────────────────────────────────────────────────────
$reportPath = Join-Path (Split-Path $MappingCsv) "SharedMailboxPermReport_$(Get-Date -Format 'yyyyMMdd_HHmmss').csv"
$report | Export-Csv -Path $reportPath -NoTypeInformation -Encoding UTF8

Write-Log "" INFO
Write-Log "=== Summary ===" INFO
Write-Log "  Shared mailboxes processed : $($sharedMailboxData.Count)" INFO
Write-Log "  Permissions applied        : $successCount" SUCCESS
Write-Log "  Skipped (no mapping)       : $skipCount" WARN
Write-Log "  Errors                     : $errorCount" $(if ($errorCount -gt 0) { 'ERROR' } else { 'INFO' })
Write-Log "  Report saved               : $reportPath" INFO
if ($DryRun) { Write-Log "*** DRY RUN — no changes were made ***" WARN }
#endregion
