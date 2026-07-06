<#
.SYNOPSIS
    Builds a CodeTwo O365-to-O365 migration CSV from user accounts and shared mailbox exports.

.DESCRIPTION
    Takes two input CSVs:
      - User accounts CSV with source-to-target email mapping
      - Shared mailboxes CSV exported from source tenant (Get-Mailbox)

    Connects to BOTH source and target Exchange Online tenants to retrieve SourceId and TargetId.

    For shared mailboxes: target email pattern is configurable (default: {Alias}.{SourceDomainPrefix}@{TargetDomain})

.PARAMETER UserAccountsCsvPath
    CSV with user mapping. Will prompt if not provided.

.PARAMETER SharedMailboxCsvPath
    Shared mailbox export from source tenant. Will prompt if not provided.

.PARAMETER SourceDomain
    Source tenant domain (e.g., quorumdev.com). Will prompt if not provided.

.PARAMETER TargetDomain
    Target tenant domain (e.g., volue.com). Will prompt if not provided.

.PARAMETER OutputPath
    Output CSV path. Default: .\CodeTwo_Migration.csv

.PARAMETER SkipSourceEXO
    Skip connecting to source tenant (won't populate SourceId for user mailboxes).

.PARAMETER SkipTargetEXO
    Skip connecting to target tenant (won't populate TargetId).

.EXAMPLE
    .\New-CodeTwoMigrationFile.ps1
    # Prompts for all inputs interactively

.EXAMPLE
    .\New-CodeTwoMigrationFile.ps1 -SourceDomain "quorumdev.com" -TargetDomain "volue.com"
#>

[CmdletBinding()]
param (
    [string]$UserAccountsCsvPath,
    [string]$SharedMailboxCsvPath,
    [string]$SourceDomain,
    [string]$TargetDomain,
    [string]$OutputPath = ".\CodeTwo_Migration.csv",
    [switch]$SkipSourceEXO,
    [switch]$SkipTargetEXO
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# ==============================================================================
# CONFIGURATION - Customize these values
# ==============================================================================

# Shared mailbox target email suffix
# Example: ".quorumdev" creates "SalesTeam.quorumdev@targetdomain.com"
# The full target will be: {Alias}{SharedMailboxTargetSuffix}@{TargetDomain}
$SharedMailboxTargetSuffix = ".quorum"

# User/Shared mailbox types in output
$UserMailboxType   = "Primary"
$SharedMailboxType = "Primary"

# CSV column name patterns for auto-detection (case-insensitive regex)
$SourceEmailColumnPattern = 'quorum|source'
$TargetEmailColumnPattern = '^e-mail$|^email$|target'

# ==============================================================================
# HELPERS
# ==============================================================================

function Write-Ok   { param($m) Write-Host "  [OK] $m" -ForegroundColor Green }
function Write-Info { param($m) Write-Host "  [..] $m" -ForegroundColor Cyan }
function Write-Warn { param($m) Write-Host "  [!!] $m" -ForegroundColor Yellow }
function Write-Fail { param($m) Write-Host "  [XX] $m" -ForegroundColor Red }

function Prompt-Required {
    param([string]$Message)
    do {
        $value = Read-Host $Message
        if ([string]::IsNullOrWhiteSpace($value)) {
            Write-Host "    Required field." -ForegroundColor Yellow
        }
    } while ([string]::IsNullOrWhiteSpace($value))
    return $value.Trim()
}

function Prompt-File {
    param([string]$Message)
    do {
        $path = Prompt-Required -Message $Message
        if (-not (Test-Path $path)) {
            Write-Host "    File not found: $path" -ForegroundColor Yellow
            $path = ""
        } elseif ((Get-Item $path) -is [System.IO.DirectoryInfo]) {
            Write-Host "    That's a directory. Please enter full file path." -ForegroundColor Yellow
            $path = ""
        }
    } while ([string]::IsNullOrWhiteSpace($path))
    return $path
}

function Prompt-Choice {
    param([string]$Message, [string[]]$Options)
    Write-Host "`n$Message" -ForegroundColor Cyan
    for ($i = 0; $i -lt $Options.Count; $i++) {
        Write-Host "  [$($i+1)] $($Options[$i])"
    }
    do {
        $choice = Read-Host "Enter number"
        $num = 0
        if ([int]::TryParse($choice, [ref]$num) -and $num -ge 1 -and $num -le $Options.Count) {
            return $Options[$num - 1]
        }
        Write-Host "    Invalid. Enter 1-$($Options.Count)" -ForegroundColor Yellow
    } while ($true)
}

function Expand-TargetPattern {
    param(
        [string]$Alias,
        [string]$Suffix,
        [string]$TargetDomain
    )
    return "$Alias$Suffix@$TargetDomain"
}

# ==============================================================================
# PREREQUISITES
# ==============================================================================

function Install-RequiredModule {
    param(
        [string]$ModuleName,
        [string]$MinVersion = "3.0.0"
    )
    Write-Info "Checking module: $ModuleName..."
    $installed = Get-Module -ListAvailable -Name $ModuleName |
                 Sort-Object Version -Descending |
                 Select-Object -First 1

    $needsInstall = -not $installed -or ([version]$installed.Version -lt [version]$MinVersion)

    if ($needsInstall) {
        if ($installed) {
            Write-Warn "$ModuleName v$($installed.Version) found but v$MinVersion+ required — updating..."
        } else {
            Write-Warn "$ModuleName not installed — installing from PSGallery..."
        }
        try {
            if (-not (Get-PackageProvider -Name NuGet -ErrorAction SilentlyContinue)) {
                Write-Info "Bootstrapping NuGet provider..."
                Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 -Force -Scope CurrentUser | Out-Null
            }
            Install-Module -Name $ModuleName -MinimumVersion $MinVersion -Scope CurrentUser -Force -AllowClobber -Repository PSGallery -ErrorAction Stop
            Write-Ok "$ModuleName installed"
        } catch {
            Write-Fail "Could not install ${ModuleName}: $_"
            exit 1
        }
    } else {
        Write-Ok "$ModuleName v$($installed.Version) — OK"
    }

    Import-Module $ModuleName -ErrorAction Stop
}

Write-Host ""
Write-Host "======================================" -ForegroundColor DarkCyan
Write-Host "  Prerequisites Check" -ForegroundColor DarkCyan
Write-Host "======================================" -ForegroundColor DarkCyan
Write-Host ""

if ($PSVersionTable.PSVersion.Major -lt 5 -or
    ($PSVersionTable.PSVersion.Major -eq 5 -and $PSVersionTable.PSVersion.Minor -lt 1)) {
    Write-Fail "PowerShell 5.1 or higher is required (found $($PSVersionTable.PSVersion))"
    exit 1
}
Write-Ok "PowerShell $($PSVersionTable.PSVersion)"

Install-RequiredModule -ModuleName "ExchangeOnlineManagement" -MinVersion "3.0.0"

Write-Host ""

# ==============================================================================
# INTERACTIVE SETUP
# ==============================================================================

Write-Host ""
Write-Host "======================================" -ForegroundColor Cyan
Write-Host "  CodeTwo Migration File Generator" -ForegroundColor Cyan
Write-Host "======================================" -ForegroundColor Cyan
Write-Host ""

# Domains
if (-not $SourceDomain) {
    $SourceDomain = Prompt-Required -Message "Source domain (e.g., quorumdev.com)"
}
if (-not $TargetDomain) {
    $TargetDomain = Prompt-Required -Message "Target domain (e.g., volue.com)"
}

# Derived values
$SourceDomain = $SourceDomain.ToLower()
$TargetDomain = $TargetDomain.ToLower()
$SourceDomainPrefix = $SourceDomain.Split('.')[0]  # quorumdev.com -> quorumdev

Write-Host ""
Write-Info "Source: $SourceDomain"
Write-Info "Target: $TargetDomain"
Write-Info "Shared mailbox pattern: {Alias}$SharedMailboxTargetSuffix@{TargetDomain}"
Write-Host ""

# CSV files
if (-not $UserAccountsCsvPath) {
    $UserAccountsCsvPath = Prompt-File -Message "User accounts CSV (source->target mapping)"
}
if (-not $SharedMailboxCsvPath) {
    $SharedMailboxCsvPath = Prompt-File -Message "Shared mailboxes CSV (source tenant export)"
}

# Resolve output path
if (-not [System.IO.Path]::IsPathRooted($OutputPath)) {
    $OutputPath = Join-Path (Get-Location) $OutputPath.TrimStart('.\')
}

# If OutputPath is a directory, append default filename
if ((Test-Path $OutputPath -PathType Container) -or $OutputPath.EndsWith('\') -or $OutputPath.EndsWith('/')) {
    # Remove trailing slash if present for Test-Path to work
    $testPath = $OutputPath.TrimEnd('\', '/')
    if ((Test-Path $testPath -PathType Container) -or -not (Test-Path $testPath)) {
        $OutputPath = Join-Path $OutputPath "CodeTwo_Migration.csv"
    }
}

# Ensure output directory exists
$OutputDir = Split-Path -Parent $OutputPath
if ($OutputDir -and -not (Test-Path $OutputDir)) {
    New-Item -ItemType Directory -Path $OutputDir -Force | Out-Null
    Write-Info "Created directory: $OutputDir"
}

# ==============================================================================
# LOAD CSVs
# ==============================================================================

Write-Host ""
Write-Info "Loading user accounts..."
$users = Import-Csv -Path $UserAccountsCsvPath
$headers = $users[0].PSObject.Properties.Name
Write-Ok "Loaded $($users.Count) users"

# Auto-detect or prompt for columns
$sourceCol = $headers | Where-Object { $_ -match $SourceEmailColumnPattern } | Select-Object -First 1
if (-not $sourceCol) {
    $sourceCol = Prompt-Choice -Message "Select SOURCE email column:" -Options $headers
} else {
    Write-Info "Auto-detected source column: $sourceCol"
}

$targetCol = $headers | Where-Object { $_ -match $TargetEmailColumnPattern -and $_ -ne $sourceCol } | Select-Object -First 1
if (-not $targetCol) {
    $remaining = $headers | Where-Object { $_ -ne $sourceCol }
    $targetCol = Prompt-Choice -Message "Select TARGET email column:" -Options $remaining
} else {
    Write-Info "Auto-detected target column: $targetCol"
}

Write-Info "Loading shared mailboxes..."
$shared = Import-Csv -Path $SharedMailboxCsvPath
Write-Ok "Loaded $($shared.Count) shared mailboxes"

# ==============================================================================
# CONNECT TO EXCHANGE ONLINE (Source + Target)
# ==============================================================================

$sourceMailboxLookup = @{}
$targetMailboxLookup = @{}

# Source tenant - get SourceId for user mailboxes
if (-not $SkipSourceEXO) {
    Write-Host ""
    Write-Info "Connecting to SOURCE tenant ($SourceDomain)..."
    $sourceAdmin = Prompt-Required -Message "Source tenant admin UPN"
    Connect-ExchangeOnline -UserPrincipalName $sourceAdmin -ShowBanner:$false
    
    Write-Info "Fetching source mailboxes..."
    $srcMailboxes = Get-Mailbox -ResultSize Unlimited | Select-Object PrimarySmtpAddress, ExternalDirectoryObjectId
    foreach ($mbx in $srcMailboxes) {
        $sourceMailboxLookup[$mbx.PrimarySmtpAddress.ToLower()] = $mbx.ExternalDirectoryObjectId
    }
    Write-Ok "Cached $($sourceMailboxLookup.Count) source mailboxes"
    
    Disconnect-ExchangeOnline -Confirm:$false -ErrorAction SilentlyContinue
}

# Target tenant - get TargetId
if (-not $SkipTargetEXO) {
    Write-Host ""
    Write-Info "Connecting to TARGET tenant ($TargetDomain)..."
    $targetAdmin = Prompt-Required -Message "Target tenant admin UPN"
    Connect-ExchangeOnline -UserPrincipalName $targetAdmin -ShowBanner:$false
    
    Write-Info "Fetching target mailboxes..."
    $tgtMailboxes = Get-Mailbox -ResultSize Unlimited | Select-Object PrimarySmtpAddress, ExternalDirectoryObjectId
    foreach ($mbx in $tgtMailboxes) {
        $targetMailboxLookup[$mbx.PrimarySmtpAddress.ToLower()] = $mbx.ExternalDirectoryObjectId
    }
    Write-Ok "Cached $($targetMailboxLookup.Count) target mailboxes"
    
    Disconnect-ExchangeOnline -Confirm:$false -ErrorAction SilentlyContinue
}

# ==============================================================================
# BUILD OUTPUT
# ==============================================================================

Write-Host ""
Write-Info "Building CodeTwo migration file..."

$output = @()
$unmapped = @()

# User mailboxes
$userCount = 0
foreach ($row in $users) {
    $src = $row.$sourceCol
    $tgt = $row.$targetCol
    if ([string]::IsNullOrWhiteSpace($src) -or [string]::IsNullOrWhiteSpace($tgt)) { continue }
    
    $srcLower = $src.Trim().ToLower()
    $tgtLower = $tgt.Trim().ToLower()
    
    $srcId = if ($sourceMailboxLookup.ContainsKey($srcLower)) { $sourceMailboxLookup[$srcLower] } else { "" }
    $tgtId = if ($targetMailboxLookup.ContainsKey($tgtLower)) { $targetMailboxLookup[$tgtLower] } else { "" }
    
    $entry = [PSCustomObject]@{
        SourceEmail       = $srcLower
        SourceId          = $srcId
        DisplayName       = ($src.Split('@')[0] -replace '\.', ' ')
        SourceMailboxType = $UserMailboxType
        TargetMailboxType = $UserMailboxType
        TargetEmail       = $tgtLower
        TargetId          = $tgtId
    }
    $output += $entry
    
    if ([string]::IsNullOrWhiteSpace($srcId) -or [string]::IsNullOrWhiteSpace($tgtId)) {
        $unmapped += $entry
    }
    
    $userCount++
}
Write-Ok "Added $userCount user mailboxes"

# Shared mailboxes
$sharedCount = 0
foreach ($row in $shared) {
    $src = $row.PrimarySmtpAddress
    $alias = $row.Alias
    $srcId = $row.ExternalDirectoryObjectId
    $displayName = $row.DisplayName
    
    if ([string]::IsNullOrWhiteSpace($src)) { continue }
    
    # Build target email from suffix
    $tgt = Expand-TargetPattern -Alias $alias -Suffix $SharedMailboxTargetSuffix -TargetDomain $TargetDomain
    
    $tgtLower = $tgt.ToLower()
    $tgtId = if ($targetMailboxLookup.ContainsKey($tgtLower)) { $targetMailboxLookup[$tgtLower] } else { "" }
    
    $entry = [PSCustomObject]@{
        SourceEmail       = $src.Trim().ToLower()
        SourceId          = $srcId
        DisplayName       = $displayName
        SourceMailboxType = $SharedMailboxType
        TargetMailboxType = $SharedMailboxType
        TargetEmail       = $tgtLower
        TargetId          = $tgtId
    }
    $output += $entry
    
    if ([string]::IsNullOrWhiteSpace($tgtId)) {
        $unmapped += $entry
    }
    
    $sharedCount++
}
Write-Ok "Added $sharedCount shared mailboxes"

# ==============================================================================
# EXPORT
# ==============================================================================

Write-Host ""
Write-Info "Writing $OutputPath..."

# CodeTwo format: semicolon-separated with quoted fields
$header = 'SourceEmail;"SourceId";"DisplayName";"SourceMailboxType";"TargetMailboxType";"TargetEmail";"TargetId"'
$lines = @($header)

foreach ($row in $output) {
    $lines += "$($row.SourceEmail);`"$($row.SourceId)`";`"$($row.DisplayName)`";`"$($row.SourceMailboxType)`";`"$($row.TargetMailboxType)`";`"$($row.TargetEmail)`";`"$($row.TargetId)`""
}

$lines | Out-File -FilePath $OutputPath -Encoding UTF8 -Force
Write-Ok "Wrote $($output.Count) rows"

# Export unmapped if any
if ($unmapped.Count -gt 0) {
    $unmappedPath = $OutputPath -replace '\.csv$', '_Unmapped.csv'
    $unmapped | Export-Csv -Path $unmappedPath -NoTypeInformation -Force
    Write-Warn "$($unmapped.Count) rows have missing SourceId or TargetId - see $unmappedPath"
}

# ==============================================================================
# SUMMARY
# ==============================================================================

Write-Host ""
Write-Host "======================================" -ForegroundColor Green
Write-Host "  Done!" -ForegroundColor Green
Write-Host "======================================" -ForegroundColor Green
Write-Host ""
Write-Host "Output:   $OutputPath"
Write-Host "Total:    $($output.Count) rows ($userCount users, $sharedCount shared)"
if ($unmapped.Count -gt 0) {
    Write-Host "Unmapped: $($unmapped.Count) rows need attention"
}
Write-Host ""
