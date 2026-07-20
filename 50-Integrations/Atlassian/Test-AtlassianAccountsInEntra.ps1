# checks atlassian user emails from a csv against entra id, appends match/status columns
param(
    [Parameter(Mandatory)]
    [string]$CsvPath,

    [string]$OutputPath = "C:\Temp\Test-AtlassianAccountsInEntra",

    [string]$EmailColumn = "email",

    [string]$TenantId,

    [switch]$IncludeSignInActivity,   # needs AuditLog.Read.All + Entra P1/P2

    [switch]$UseDeviceAuthentication
)

# --- settings ---
$RequiredModules = @("Microsoft.Graph.Authentication", "Microsoft.Graph.Users")

$Scopes = @("User.Read.All")
if ($IncludeSignInActivity) { $Scopes += "AuditLog.Read.All" }

$UserProperties = @(
    "id", "displayName", "userPrincipalName", "mail", "accountEnabled",
    "userType", "proxyAddresses", "otherMails", "createdDateTime",
    "onPremisesSyncEnabled", "employeeId", "companyName", "department", "jobTitle"
)
if ($IncludeSignInActivity) { $UserProperties += "signInActivity" }

$Timestamp = Get-Date -Format "yyyyMMdd_HHmm"
$CsvOut    = Join-Path $OutputPath "Test-AtlassianAccountsInEntra_$Timestamp.csv"
$JsonOut   = Join-Path $OutputPath "Test-AtlassianAccountsInEntra_$Timestamp.json"

# --- functions ---
function Get-NormalizedEmail {
    param([string]$Value)
    if ([string]::IsNullOrWhiteSpace($Value)) { return $null }
    # strip smtp:/SMTP: prefix from proxyAddresses
    $v = ($Value.Trim() -replace '^(?i)smtp:', '').Trim().ToLowerInvariant()
    if ($v) { return $v }
    return $null
}

function Add-IndexEntry {
    param($Index, $Address, $User, $Method, [int]$Priority)
    $key = Get-NormalizedEmail $Address
    if (-not $key) { return }
    if (-not $Index.ContainsKey($key)) {
        $Index[$key] = [System.Collections.Generic.List[object]]::new()
    }
    $Index[$key].Add([pscustomobject]@{ User = $User; Method = $Method; Priority = $Priority })
}

# --- main ---
foreach ($m in $RequiredModules) {
    if (-not (Get-Module -ListAvailable -Name $m)) {
        Write-Host "Module $m is not installed. Run: Install-Module $m -Scope CurrentUser" -ForegroundColor Red
        exit 1
    }
}
foreach ($m in $RequiredModules) { Import-Module $m -ErrorAction Stop }

if (-not (Test-Path -LiteralPath $CsvPath -PathType Leaf)) {
    Write-Host "Input CSV not found: $CsvPath" -ForegroundColor Red
    exit 1
}

try {
    $rows = @(Import-Csv -LiteralPath $CsvPath)
}
catch {
    Write-Host "Failed to read CSV '$CsvPath': $($_.Exception.Message)" -ForegroundColor Red
    exit 1
}

if ($rows.Count -eq 0) {
    Write-Host "CSV has no data rows: $CsvPath" -ForegroundColor Red
    exit 1
}

$availableColumns = @($rows[0].PSObject.Properties.Name)
if ($availableColumns -notcontains $EmailColumn) {
    Write-Host "Column '$EmailColumn' not found. Available columns: $($availableColumns -join ', ')" -ForegroundColor Red
    exit 1
}

Write-Host "Read $($rows.Count) rows from $CsvPath"

$connectParams = @{ Scopes = $Scopes }
if ($TenantId) { $connectParams.TenantId = $TenantId }
if ($UseDeviceAuthentication) { $connectParams.UseDeviceCode = $true }

Write-Host "Connecting to Graph..."
try {
    Connect-MgGraph @connectParams | Out-Null
}
catch {
    Write-Host "Graph connection failed: $($_.Exception.Message)" -ForegroundColor Red
    exit 1
}

$context = Get-MgContext
if (-not $context) {
    Write-Host "No Graph context after connect - authentication failed" -ForegroundColor Red
    exit 1
}
Write-Host "Connected to tenant $($context.TenantId) as $($context.Account)"

if ($TenantId -and $context.TenantId -ne $TenantId) {
    Write-Host "Connected to tenant '$($context.TenantId)' but '$TenantId' was requested" -ForegroundColor Red
    exit 1
}

Write-Host "Retrieving Entra users..."
try {
    $entraUsers = @(Get-MgUser -All -Property $UserProperties -ErrorAction Stop)
}
catch {
    Write-Host "Failed to retrieve Entra users: $($_.Exception.Message)" -ForegroundColor Red
    if ($IncludeSignInActivity) {
        Write-Host "Sign-in activity needs AuditLog.Read.All consent and Entra P1/P2 licensing" -ForegroundColor Yellow
    }
    exit 1
}
Write-Host "Found $($entraUsers.Count) Entra users"

# index every known address per user, lower priority = better match
$emailIndex = @{}
foreach ($user in $entraUsers) {
    Add-IndexEntry $emailIndex $user.UserPrincipalName $user "UserPrincipalName" 10
    Add-IndexEntry $emailIndex $user.Mail $user "Mail" 20
    foreach ($proxy in @($user.ProxyAddresses)) {
        if (([string]$proxy) -cmatch '^SMTP:') {
            Add-IndexEntry $emailIndex ([string]$proxy) $user "PrimaryProxyAddress" 30
        }
        else {
            Add-IndexEntry $emailIndex ([string]$proxy) $user "ProxyAddress" 40
        }
    }
    foreach ($other in @($user.OtherMails)) {
        Add-IndexEntry $emailIndex ([string]$other) $user "OtherMail" 50
    }
}

$results = [System.Collections.Generic.List[object]]::new()

foreach ($row in $rows) {
    $sourceEmail = [string]$row.$EmailColumn
    $normalizedEmail = Get-NormalizedEmail $sourceEmail

    $selectedMatch = $null
    $uniqueMatches = @()
    $matchWarning = $null
    $matchStatus = "Not found"

    if ($normalizedEmail -and $emailIndex.ContainsKey($normalizedEmail)) {
        # dedupe candidates by user id, keep the best (lowest) priority per user
        $byUserId = @{}
        foreach ($candidate in ($emailIndex[$normalizedEmail] | Sort-Object Priority)) {
            $id = [string]$candidate.User.Id
            if (-not $byUserId.ContainsKey($id)) { $byUserId[$id] = $candidate }
        }
        $uniqueMatches = @($byUserId.Values | Sort-Object Priority)

        if ($uniqueMatches.Count -eq 1) {
            $selectedMatch = $uniqueMatches[0]
            $matchStatus = "Matched"
        }
        else {
            $bestPriority = ($uniqueMatches | Measure-Object -Property Priority -Minimum).Minimum
            $bestMatches = @($uniqueMatches | Where-Object { $_.Priority -eq $bestPriority })
            if ($bestMatches.Count -eq 1) {
                $selectedMatch = $bestMatches[0]
                $matchStatus = "Matched with warning"
                $matchWarning = "Multiple Entra users matched; picked the highest-priority one"
            }
            else {
                $matchStatus = "Ambiguous"
                $matchWarning = "Multiple Entra users matched with equal priority; none selected"
            }
        }
    }

    $entraUser = $null
    if ($selectedMatch) { $entraUser = $selectedMatch.User }

    $accountEnabled = $null
    $userType = $null
    $orgStatus = "Not found"
    $activeInternal = "No"
    $lastSignIn = $null
    $daysSinceSignIn = $null

    if ($matchStatus -eq "Ambiguous") {
        $orgStatus = "Ambiguous match"
    }
    elseif ($entraUser) {
        $accountEnabled = $entraUser.AccountEnabled
        $userType = [string]$entraUser.UserType
        if (-not $userType) { $userType = "Unknown" }

        if ($accountEnabled -eq $true -and $userType -eq "Member") {
            $orgStatus = "Active member"
            $activeInternal = "Yes"
        }
        elseif ($accountEnabled -eq $false -and $userType -eq "Member") { $orgStatus = "Disabled member" }
        elseif ($accountEnabled -eq $true -and $userType -eq "Guest") { $orgStatus = "Enabled guest" }
        elseif ($accountEnabled -eq $false -and $userType -eq "Guest") { $orgStatus = "Disabled guest" }
        elseif ($accountEnabled -eq $true) { $orgStatus = "Enabled - unknown user type" }
        elseif ($accountEnabled -eq $false) { $orgStatus = "Disabled - unknown user type" }
        else { $orgStatus = "Matched - enabled state unavailable" }

        if ($IncludeSignInActivity -and $entraUser.SignInActivity) {
            $lastSignIn = $entraUser.SignInActivity.LastSuccessfulSignInDateTime
            # older sdk versions only expose it via additional properties
            if (-not $lastSignIn -and $entraUser.SignInActivity.AdditionalProperties) {
                $lastSignIn = $entraUser.SignInActivity.AdditionalProperties["lastSuccessfulSignInDateTime"]
            }
            if ($lastSignIn) {
                try {
                    $parsed = [DateTimeOffset]::Parse([string]$lastSignIn)
                    $lastSignIn = $parsed.UtcDateTime.ToString("yyyy-MM-ddTHH:mm:ssZ")
                    $daysSinceSignIn = [math]::Floor(((Get-Date).ToUniversalTime() - $parsed.UtcDateTime).TotalDays)
                }
                catch {
                    Write-Host "Could not parse sign-in date '$lastSignIn' for $($entraUser.UserPrincipalName), keeping raw value" -ForegroundColor Yellow
                }
            }
        }
    }

    # original columns first, then entra status columns
    $outputRow = [ordered]@{}
    foreach ($property in $row.PSObject.Properties) {
        $outputRow[$property.Name] = $property.Value
    }

    $outputRow["EntraMatchStatus"] = $matchStatus
    $outputRow["EntraFound"] = if ($entraUser) { "Yes" } else { "No" }
    $outputRow["EntraActiveInternalAccount"] = $activeInternal
    $outputRow["EntraOrgStatus"] = $orgStatus
    $outputRow["EntraAccountEnabled"] = if ($null -ne $accountEnabled) { [string]$accountEnabled } else { $null }
    $outputRow["EntraUserType"] = $userType
    $outputRow["EntraMatchMethod"] = if ($selectedMatch) { $selectedMatch.Method } else { $null }
    $outputRow["EntraMatchCount"] = $uniqueMatches.Count
    $outputRow["EntraMatchWarning"] = $matchWarning
    $outputRow["EntraCandidateIds"] = if ($uniqueMatches.Count -gt 0) { @($uniqueMatches | ForEach-Object { $_.User.Id }) -join ";" } else { $null }
    $outputRow["EntraObjectId"] = if ($entraUser) { $entraUser.Id } else { $null }
    $outputRow["EntraDisplayName"] = if ($entraUser) { $entraUser.DisplayName } else { $null }
    $outputRow["EntraUPN"] = if ($entraUser) { $entraUser.UserPrincipalName } else { $null }
    $outputRow["EntraMail"] = if ($entraUser) { $entraUser.Mail } else { $null }
    $outputRow["EntraCreated"] = if ($entraUser) { [string]$entraUser.CreatedDateTime } else { $null }
    $outputRow["EntraOnPremSynced"] = if ($entraUser -and $null -ne $entraUser.OnPremisesSyncEnabled) { [string]$entraUser.OnPremisesSyncEnabled } else { $null }
    $outputRow["EntraEmployeeId"] = if ($entraUser) { $entraUser.EmployeeId } else { $null }
    $outputRow["EntraCompany"] = if ($entraUser) { $entraUser.CompanyName } else { $null }
    $outputRow["EntraDepartment"] = if ($entraUser) { $entraUser.Department } else { $null }
    $outputRow["EntraJobTitle"] = if ($entraUser) { $entraUser.JobTitle } else { $null }

    if ($IncludeSignInActivity) {
        $outputRow["EntraLastSuccessfulSignInUtc"] = $lastSignIn
        $outputRow["EntraDaysSinceLastSignIn"] = $daysSinceSignIn
    }

    $results.Add([pscustomobject]$outputRow)
}

if (-not (Test-Path -LiteralPath $OutputPath)) {
    New-Item -ItemType Directory -Path $OutputPath -Force | Out-Null
}

try {
    $results | Export-Csv -LiteralPath $CsvOut -NoTypeInformation -Encoding UTF8
    $results | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $JsonOut -Encoding UTF8
}
catch {
    Write-Host "Failed to write output files: $($_.Exception.Message)" -ForegroundColor Red
    exit 1
}

Write-Host ""
Write-Host "Entra status summary:"
$results | Group-Object EntraOrgStatus | Sort-Object Count -Descending |
    Select-Object @{ Name = "Status"; Expression = { $_.Name } }, Count |
    Format-Table -AutoSize

Write-Host "Done. Exported to $CsvOut and $JsonOut"
