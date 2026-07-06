<#
.SYNOPSIS
    Bulk-changes login email addresses on Atlassian managed accounts via the
    "Set Email" organization API, using the mapping produced by
    New-AtlassianEmailChangeCsv.ps1.

.DESCRIPTION
    Calls:  PUT https://api.atlassian.com/users/{account_id}/manage/email
            Body: { "email": "<new email>" }

    Reference:
      https://support.atlassian.com/atlassian-cloud/kb/planning-for-bulk-email-address-changes-on-managed-accounts/
      https://developer.atlassian.com/cloud/admin/user-management/rest/api-group-email/#api-users-account-id-manage-email-put

    Prerequisites (per Atlassian docs - verify before running):
      - You are an Organization Admin.
      - The target domain (volue.com) is claimed/verified in the SAME Atlassian
        organization as the source domain (hakom.at). Cross-org moves are not
        supported by this API.
      - You have an Organization API key (admin.atlassian.com > Settings > API keys),
        NOT an OAuth token - Forge/OAuth2 apps cannot call this endpoint.
      - Any account that already owns the target email address has been renamed
        out of the way first (the API will 400/409 on collisions).
      - This call invalidates all active sessions for the affected user and marks
        the new email as verified immediately - there is no confirmation email step.

    This script defaults to a DRY RUN (report only, no API calls). Pass -Execute to
    actually perform the changes. Each change also goes through ShouldProcess, so
    -WhatIf / -Confirm work as usual on top of -Execute.

.PARAMETER InputCsv
    CSV produced by New-AtlassianEmailChangeCsv.ps1 with columns:
    Name, Atlassian ID, Current Email, New Email

.PARAMETER ApiKey
    Organization API key, as a SecureString. If omitted, falls back to the
    ATLASSIAN_ORG_API_KEY environment variable, then prompts interactively.

.PARAMETER Execute
    Actually call the API. Without this switch the script only validates the
    input and writes a dry-run report - no requests are sent.

.PARAMETER ThrottleMs
    Delay in milliseconds between API calls (default 300) to stay well under
    any rate limit and avoid hammering the org's session-invalidation path.

.EXAMPLE
    # Dry run - validates the CSV and shows what would happen, calls nothing
    .\Set-AtlassianManagedEmail.ps1

.EXAMPLE
    # Real run against a handful of accounts first
    Import-Csv .\AtlassianEmailChange.csv | Select-Object -First 3 | Export-Csv .\pilot.csv -NoTypeInformation
    .\Set-AtlassianManagedEmail.ps1 -InputCsv .\pilot.csv -Execute

.EXAMPLE
    # Full run once the pilot looks good
    .\Set-AtlassianManagedEmail.ps1 -Execute
#>

[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
param(
    [string]$InputCsv = "$PSScriptRoot\AtlassianEmailChange.csv",

    [System.Security.SecureString]$ApiKey,

    [switch]$Execute,

    [ValidateRange(0, 60000)]
    [int]$ThrottleMs = 300,

    [string]$ReportCsv = "$PSScriptRoot\AtlassianEmailChange-Report-$(Get-Date -Format 'yyyyMMdd-HHmmss').csv"
)

$ErrorActionPreference = 'Stop'

function Get-PlainText([System.Security.SecureString]$Secure) {
    $bstr = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($Secure)
    try {
        return [System.Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr)
    } finally {
        [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
    }
}

if (-not (Test-Path -LiteralPath $InputCsv)) {
    throw "Input CSV not found: $InputCsv"
}

if (-not $ApiKey) {
    if ($env:ATLASSIAN_ORG_API_KEY) {
        $ApiKey = ConvertTo-SecureString -String $env:ATLASSIAN_ORG_API_KEY -AsPlainText -Force
    } elseif ($Execute) {
        $ApiKey = Read-Host -Prompt 'Atlassian Organization API key' -AsSecureString
    }
}

$rows = Import-Csv -Path $InputCsv

if (-not $rows -or $rows.Count -eq 0) {
    Write-Warning "No rows found in $InputCsv"
    return
}

foreach ($col in 'Atlassian ID', 'Current Email', 'New Email') {
    if (-not ($rows[0].PSObject.Properties.Name -contains $col)) {
        throw "Expected column '$col' not found in $InputCsv"
    }
}

$headers = $null
if ($Execute) {
    if (-not $ApiKey) {
        throw "No API key provided. Pass -ApiKey, set ATLASSIAN_ORG_API_KEY, or run interactively."
    }
    $plainKey = Get-PlainText $ApiKey
    $headers = @{
        Authorization = "Bearer $plainKey"
        'Content-Type' = 'application/json'
    }
}

$report = [System.Collections.Generic.List[object]]::new()
$total = $rows.Count
$i = 0

foreach ($row in $rows) {
    $i++
    $accountId = $row.'Atlassian ID'
    $oldEmail  = $row.'Current Email'
    $newEmail  = $row.'New Email'
    $name      = $row.Name

    $result = [ordered]@{
        Name          = $name
        'Atlassian ID' = $accountId
        'Current Email' = $oldEmail
        'New Email'   = $newEmail
        Mode          = if ($Execute) { 'Execute' } else { 'DryRun' }
        HttpStatus    = ''
        Result        = ''
        Error         = ''
    }

    if ([string]::IsNullOrWhiteSpace($accountId) -or [string]::IsNullOrWhiteSpace($newEmail)) {
        $result.Result = 'Skipped'
        $result.Error  = 'Missing Atlassian ID or New Email'
        $report.Add([pscustomobject]$result)
        Write-Warning "[$i/$total] Skipping '$name' - missing Atlassian ID or New Email"
        continue
    }

    if (-not $Execute) {
        $result.Result = 'WouldChange'
        $report.Add([pscustomobject]$result)
        Write-Host "[$i/$total] DRY RUN: $name  $oldEmail  ->  $newEmail  (account $accountId)"
        continue
    }

    $target = "$name (account $accountId)"
    $action = "Change login email from '$oldEmail' to '$newEmail'"

    if (-not $PSCmdlet.ShouldProcess($target, $action)) {
        $result.Result = 'SkippedByUser'
        $report.Add([pscustomobject]$result)
        continue
    }

    $uri = "https://api.atlassian.com/users/$accountId/manage/email"
    $body = @{ email = $newEmail } | ConvertTo-Json -Compress

    try {
        $response = Invoke-WebRequest -Uri $uri -Method Put -Headers $headers -Body $body -ContentType 'application/json'
        $result.HttpStatus = [int]$response.StatusCode
        $result.Result = 'Success'
        Write-Host "[$i/$total] OK: $name  $oldEmail  ->  $newEmail"
    } catch {
        $statusCode = $null
        $errorBody = $_.ErrorDetails.Message
        if ($_.Exception.Response) {
            $statusCode = [int]$_.Exception.Response.StatusCode
        }
        $result.HttpStatus = $statusCode
        $result.Result = 'Failed'
        $result.Error = if ($errorBody) { $errorBody } else { $_.Exception.Message }
        Write-Warning "[$i/$total] FAILED: $name ($accountId) - $($result.Error)"
    }

    $report.Add([pscustomobject]$result)

    if ($i -lt $total) {
        Start-Sleep -Milliseconds $ThrottleMs
    }
}

$report | Export-Csv -Path $ReportCsv -NoTypeInformation -Encoding UTF8

$summary = $report | Group-Object Result | Select-Object Name, Count
Write-Host ""
Write-Host "Report written to: $ReportCsv"
$summary | Format-Table -AutoSize
