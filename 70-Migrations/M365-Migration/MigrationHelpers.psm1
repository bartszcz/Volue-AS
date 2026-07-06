#Requires -Version 5.1
<#
.SYNOPSIS
    Shared helper module for M365 cross-tenant migration scripts.

.DESCRIPTION
    Provides connection management, logging, CSV utilities, retry logic,
    mapping lookups, domain configuration, and validation functions
    used by all migration scripts.

    Target domain is always volue.com.
    Source domain changes per migration — set via Set-MigrationDomains.

.NOTES
    Prerequisites (run once per machine):
        Install-Module ExchangeOnlineManagement  -Scope CurrentUser -Force
        Install-Module Microsoft.Graph           -Scope CurrentUser -Force
        Install-Module PnP.PowerShell            -Scope CurrentUser -Force

    Usage in every script:
        Import-Module ..\MigrationHelpers.psm1 -Force
        Set-MigrationDomains -SourceDomain 'smartpulse.io' -CompanySuffix 'SmartPulse'
#>

Set-StrictMode -Version Latest

#region ── Module-level state ─────────────────────────────────────────────────

$script:LogPath          = $null
$script:LogLevel         = 'INFO'
$script:MappingTable     = $null
$script:ConnectedTenants = @{}

# Domain config — TargetDomain is fixed, SourceDomain set per migration run
$script:TargetDomain     = 'volue.com'
$script:SourceDomain     = ''
$script:CompanySuffix    = ''

#endregion

# ==============================================================================
#  CONFIG FILE LOADER
# ==============================================================================

function Import-MigrationConfig {
    <#
    .SYNOPSIS
        Loads MigrationConfig.psd1 from the repo root and returns it as a hashtable.
        Searches upward from $PSScriptRoot up to 5 levels. Returns $null if not found.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param([string] $ConfigPath = '')

    if ($ConfigPath -and (Test-Path $ConfigPath)) {
        return Import-PowerShellDataFile -Path (Resolve-Path $ConfigPath)
    }

    # Walk upward from the calling script
    $dir = $PSScriptRoot
    for ($i = 0; $i -lt 5; $i++) {
        if (-not $dir) { break }
        $candidate = Join-Path $dir 'MigrationConfig.psd1'
        if (Test-Path $candidate) {
            try   { return Import-PowerShellDataFile -Path $candidate }
            catch { Write-Warning "Config found but failed to load: $_"; return $null }
        }
        $dir = Split-Path $dir -Parent
    }
    return $null
}

function Resolve-ConfigParam {
    <#
    .SYNOPSIS
        Returns the best value for a script parameter:
        explicit caller value > config file value > parameter default.
    #>
    param($Passed, $Default, $ConfigValue)
    if ($null -ne $Passed -and "$Passed" -ne "$Default" -and "$Passed" -ne '') {
        return $Passed
    }
    if ($null -ne $ConfigValue -and "$ConfigValue" -ne '') {
        return $ConfigValue
    }
    return $Passed
}

function Get-ConfigValue {
    <#
    .SYNOPSIS Returns a value from the loaded config hashtable, or $Default if absent.#>
    param([hashtable] $Config, [string] $Key, $Default = '')
    if ($null -eq $Config) { return $Default }
    $val = $Config[$Key]
    if ($null -ne $val -and "$val" -ne '') { return $val }
    return $Default
}


# ==============================================================================
#  DOMAIN CONFIGURATION
# ==============================================================================

function Set-MigrationDomains {
    <#
    .SYNOPSIS
        Sets the source domain and company suffix for the current migration run.
        Call once at the start of every script before any other operations.

    .DESCRIPTION
        Target domain (volue.com) is always fixed — never a parameter.
        Source domain changes per company being migrated.

    .PARAMETER SourceDomain
        Primary email domain of the source company. e.g. 'smartpulse.io'
        The leading @ is optional and will be stripped if present.

    .PARAMETER CompanySuffix
        Human-readable company name appended to display names and URL slugs.
        e.g. 'SmartPulse'
            → shared mailbox  "Careers SmartPulse"
            → SPO URL slug    "/sites/ProjectAlphaSmartPulse"
            → DL display name "All Employees SmartPulse"

    .EXAMPLE
        # Smartpulse migration
        Set-MigrationDomains -SourceDomain 'smartpulse.io' -CompanySuffix 'SmartPulse'

    .EXAMPLE
        # Next company migration — only these two lines change
        Set-MigrationDomains -SourceDomain 'acme.com' -CompanySuffix 'Acme'
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $SourceDomain,
        [Parameter(Mandatory)] [string] $CompanySuffix
    )

    $script:SourceDomain  = $SourceDomain.ToLower().TrimStart('@')
    $script:CompanySuffix = $CompanySuffix

    Write-MigLog ("Migration domains configured:" +
        " Source=@$script:SourceDomain" +
        " | Target=@$script:TargetDomain" +
        " | Suffix='$script:CompanySuffix'") -Level INFO
}


function Get-MigrationDomains {
    <#
    .SYNOPSIS
        Returns current domain configuration as a hashtable.

    .OUTPUTS
        Hashtable: SourceDomain, TargetDomain, CompanySuffix

    .EXAMPLE
        $d = Get-MigrationDomains
        $targetEmail = "support@$($d.TargetDomain)"
    #>
    [CmdletBinding()]
    param()

    if ([string]::IsNullOrWhiteSpace($script:SourceDomain)) {
        Write-MigLog "SourceDomain not set — call Set-MigrationDomains before running inventory scripts" -Level WARN
    }

    return @{
        SourceDomain  = $script:SourceDomain
        TargetDomain  = $script:TargetDomain
        CompanySuffix = $script:CompanySuffix
    }
}


function Assert-MigrationDomains {
    <#
    .SYNOPSIS
        Throws if Set-MigrationDomains has not been called yet.
        Use at the top of scripts that require domain config.
    #>
    [CmdletBinding()]
    param()

    if ([string]::IsNullOrWhiteSpace($script:SourceDomain) -or
        [string]::IsNullOrWhiteSpace($script:CompanySuffix)) {
        throw "Migration domains not configured. Call Set-MigrationDomains -SourceDomain '...' -CompanySuffix '...' first."
    }
}


# ==============================================================================
#  LOGGING
# ==============================================================================

function Initialize-MigLog {
    <#
    .SYNOPSIS
        Initialises the log file for a migration script run.

    .PARAMETER ScriptName
        Used to build the log filename: ScriptName_yyyyMMdd_HHmmss.log

    .PARAMETER LogDirectory
        Folder to write logs into. Created if it doesn't exist. Default: .\Logs

    .PARAMETER Level
        Minimum level to emit: DEBUG | INFO | WARN | ERROR

    .EXAMPLE
        Initialize-MigLog -ScriptName 'Get-MailboxInventory' -LogDirectory '.\Logs'
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $ScriptName,
        [string] $LogDirectory = '.\Logs',
        [ValidateSet('DEBUG','INFO','WARN','ERROR')]
        [string] $Level = 'INFO'
    )

    if (-not (Test-Path $LogDirectory)) {
        New-Item -ItemType Directory -Path $LogDirectory -Force | Out-Null
    }

    $timestamp        = Get-Date -Format 'yyyyMMdd_HHmmss'
    $script:LogPath   = Join-Path $LogDirectory "$ScriptName`_$timestamp.log"
    $script:LogLevel  = $Level

    $header = @"
================================================================================
  Migration Script : $ScriptName
  Started          : $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
  Log Level        : $Level
  Computer         : $env:COMPUTERNAME
  User             : $env:USERNAME
  Source Domain    : $script:SourceDomain
  Target Domain    : $script:TargetDomain
  Company Suffix   : $script:CompanySuffix
================================================================================
"@
    $header | Out-File -FilePath $script:LogPath -Encoding UTF8
    Write-MigLog "Log initialised: $script:LogPath" -Level INFO
}


function Write-MigLog {
    <#
    .SYNOPSIS
        Writes a timestamped, levelled entry to the log file and console.

    .PARAMETER Message
        Text to log.

    .PARAMETER Level
        DEBUG | INFO | WARN | ERROR

    .PARAMETER NoConsole
        Suppress console output (log file only).

    .EXAMPLE
        Write-MigLog "Processing mailbox user@smartpulse.io"
        Write-MigLog "Object not found" -Level WARN
        Write-MigLog "Fatal error" -Level ERROR
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, ValueFromPipeline)] [string] $Message,
        [ValidateSet('DEBUG','INFO','WARN','ERROR')]
        [string] $Level = 'INFO',
        [switch] $NoConsole
    )

    $levelOrder = @{ DEBUG = 0; INFO = 1; WARN = 2; ERROR = 3 }
    if ($levelOrder[$Level] -lt $levelOrder[$script:LogLevel]) { return }

    $entry = "[{0}] [{1,-5}] {2}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level, $Message

    if ($script:LogPath) {
        $entry | Out-File -FilePath $script:LogPath -Append -Encoding UTF8
    }

    if (-not $NoConsole) {
        $colour = switch ($Level) {
            'DEBUG' { 'Gray'   }
            'INFO'  { 'Cyan'   }
            'WARN'  { 'Yellow' }
            'ERROR' { 'Red'    }
        }
        Write-Host $entry -ForegroundColor $colour
    }
}


function Write-MigSummary {
    <#
    .SYNOPSIS
        Writes a structured summary block to the log at the end of a script run.

    .PARAMETER Stats
        Hashtable of label/value pairs to include in the summary.

    .EXAMPLE
        Write-MigSummary -Stats @{ Processed = 150; Skipped = 3; Errors = 1 }
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [hashtable] $Stats
    )

    $lines = @('', ('=' * 80), '  RUN SUMMARY', ('─' * 80))
    foreach ($key in ($Stats.Keys | Sort-Object)) {
        $lines += "  {0,-35} : {1}" -f $key, $Stats[$key]
    }
    $lines += ('=' * 80)
    $lines += ''
    $lines | ForEach-Object { Write-MigLog $_ }
}


# ==============================================================================
#  TENANT CONNECTIONS
# ==============================================================================

function Connect-SourceTenant {
    <#
    .SYNOPSIS
        Connects Exchange Online and Microsoft Graph for the SOURCE tenant.

    .PARAMETER TenantId
        AAD Tenant ID (GUID or .onmicrosoft.com domain).

    .PARAMETER UserPrincipalName
        Admin UPN for the source tenant.

    .PARAMETER AdditionalScopes
        Extra Graph scopes beyond the read-only defaults.

    .EXAMPLE
        Connect-SourceTenant -TenantId 'balancingpoolcom.onmicrosoft.com' `
                             -UserPrincipalName 'admin@smartpulse.io'
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]   $TenantId,
        [Parameter(Mandatory)] [string]   $UserPrincipalName,
        [string[]] $AdditionalScopes = @()
    )

    Write-MigLog "Connecting to SOURCE tenant: $TenantId" -Level INFO

    $defaultScopes = @(
        'User.Read.All', 'Group.Read.All', 'Directory.Read.All',
        'Sites.Read.All', 'TeamSettings.Read.All',
        'ChannelSettings.Read.All', 'Reports.Read.All'
    )

    try {
        Write-MigLog "  Connecting Microsoft Graph (Source)..." -Level DEBUG
        Connect-MgGraph -TenantId $TenantId `
                        -Scopes ($defaultScopes + $AdditionalScopes) `
                        -ErrorAction Stop
        Write-MigLog "  Graph connected (Source)" -Level INFO

        Write-MigLog "  Connecting Exchange Online (Source)..." -Level DEBUG
        Connect-ExchangeOnline -UserPrincipalName $UserPrincipalName `
                               -ShowBanner:$false -ErrorAction Stop
        Write-MigLog "  Exchange Online connected (Source)" -Level INFO

        $script:ConnectedTenants['Source'] = @{
            TenantId    = $TenantId
            UPN         = $UserPrincipalName
            ConnectedAt = Get-Date
        }
    }
    catch {
        Write-MigLog "Source connection failed: $_" -Level ERROR
        throw
    }
}


function Connect-TargetTenant {
    <#
    .SYNOPSIS
        Connects Exchange Online, Microsoft Graph, and optionally PnP
        for the TARGET tenant (always volue).

    .PARAMETER TenantId
        AAD Tenant ID (GUID or .onmicrosoft.com domain).

    .PARAMETER UserPrincipalName
        Admin UPN for the target tenant (first.last@volue.com).

    .PARAMETER SharePointAdminUrl
        SPO Admin Centre URL: https://volue-admin.sharepoint.com
        Omit if SharePoint scripts won't run in this session.

    .PARAMETER AdditionalScopes
        Extra Graph scopes.

    .EXAMPLE
        Connect-TargetTenant -TenantId 'volue.onmicrosoft.com' `
                             -UserPrincipalName 'admin@volue.com' `
                             -SharePointAdminUrl 'https://volue-admin.sharepoint.com'
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]   $TenantId,
        [Parameter(Mandatory)] [string]   $UserPrincipalName,
        [string]   $SharePointAdminUrl = '',
        [string[]] $AdditionalScopes   = @()
    )

    Write-MigLog "Connecting to TARGET tenant: $TenantId" -Level INFO

    $defaultScopes = @(
        'User.Read.All', 'User.ReadWrite.All',
        'Group.ReadWrite.All', 'Directory.ReadWrite.All',
        'Sites.FullControl.All', 'TeamSettings.ReadWrite.All',
        'RoleManagement.ReadWrite.Directory'
    )

    try {
        Write-MigLog "  Connecting Microsoft Graph (Target)..." -Level DEBUG
        Connect-MgGraph -TenantId $TenantId `
                        -Scopes ($defaultScopes + $AdditionalScopes) `
                        -ErrorAction Stop
        Write-MigLog "  Graph connected (Target)" -Level INFO

        Write-MigLog "  Connecting Exchange Online (Target)..." -Level DEBUG
        Connect-ExchangeOnline -UserPrincipalName $UserPrincipalName `
                               -ShowBanner:$false -ErrorAction Stop
        Write-MigLog "  Exchange Online connected (Target)" -Level INFO

        if ($SharePointAdminUrl) {
            Write-MigLog "  Connecting PnP PowerShell (Target)..." -Level DEBUG
            # PnP Management Shell app is pre-consented in every M365 tenant.
            # First run opens a browser for interactive login - no app registration needed.
            Connect-PnPOnline -Url $SharePointAdminUrl ` -ClientId '14d82eec-204b-4c2f-b7e8-296a70dab67e' -Interactive -ErrorAction Stop
            Write-MigLog "  PnP connected (Target)" -Level INFO
        }

        $script:ConnectedTenants['Target'] = @{
            TenantId           = $TenantId
            UPN                = $UserPrincipalName
            SharePointAdminUrl = $SharePointAdminUrl
            ConnectedAt        = Get-Date
        }
    }
    catch {
        Write-MigLog "Target connection failed: $_" -Level ERROR
        throw
    }
}


function Disconnect-AllTenants {
    <#
    .SYNOPSIS
        Cleanly disconnects all active Exchange Online, Graph, and PnP sessions.
    #>
    [CmdletBinding()]
    param()

    Write-MigLog "Disconnecting all tenant sessions..." -Level INFO
    try { Disconnect-ExchangeOnline -Confirm:$false -ErrorAction SilentlyContinue } catch {}
    try { Disconnect-MgGraph -ErrorAction SilentlyContinue } catch {}
    try { Disconnect-PnPOnline -ErrorAction SilentlyContinue } catch {}
    $script:ConnectedTenants.Clear()
    Write-MigLog "All sessions disconnected." -Level INFO
}


function Test-TenantConnection {
    <#
    .SYNOPSIS
        Returns $true if the specified tenant role is connected in this session.

    .PARAMETER Role
        Source | Target

    .EXAMPLE
        if (-not (Test-TenantConnection -Role Source)) { throw "Connect source first" }
    #>
    [CmdletBinding()]
    param(
        [ValidateSet('Source','Target')]
        [string] $Role = 'Source'
    )
    return $script:ConnectedTenants.ContainsKey($Role)
}


# ==============================================================================
#  RETRY / THROTTLE HANDLING
# ==============================================================================

function Invoke-WithRetry {
    <#
    .SYNOPSIS
        Executes a script block with exponential-backoff retry.
        Handles Graph / Exchange Online 429 throttling automatically.

    .PARAMETER ScriptBlock
        The code to execute.

    .PARAMETER MaxAttempts
        Total attempts before giving up. Default: 5

    .PARAMETER BaseDelaySeconds
        Initial wait in seconds; doubles each retry. Default: 2

    .PARAMETER RetryOnPatterns
        Exception message substrings that trigger a retry.

    .EXAMPLE
        $mbx = Invoke-WithRetry { Get-Mailbox -Identity 'user@smartpulse.io' }
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [scriptblock] $ScriptBlock,
        [int]      $MaxAttempts      = 5,
        [int]      $BaseDelaySeconds = 2,
        [string[]] $RetryOnPatterns  = @(
            '429', 'TooManyRequests', 'throttl',
            'temporarily unavailable', 'timeout',
            'ServiceUnavailable', '503', '504'
        )
    )

    $attempt = 0
    while ($attempt -lt $MaxAttempts) {
        $attempt++
        try {
            return (& $ScriptBlock)
        }
        catch {
            $errMsg      = $_.Exception.Message
            $shouldRetry = $RetryOnPatterns | Where-Object { $errMsg -match $_ }

            if ($shouldRetry -and $attempt -lt $MaxAttempts) {
                $delay = $BaseDelaySeconds * [math]::Pow(2, $attempt - 1)
                Write-MigLog "Attempt $attempt failed (transient). Retry in ${delay}s. [$errMsg]" -Level WARN
                Start-Sleep -Seconds $delay
            }
            else {
                Write-MigLog "Attempt $attempt — giving up. [$errMsg]" -Level ERROR
                throw
            }
        }
    }
}


# ==============================================================================
#  CSV UTILITIES
# ==============================================================================

function Export-CsvSafe {
    <#
    .SYNOPSIS
        Exports objects to CSV: UTF-8 encoding, no type headers,
        auto-creates parent directory.

    .PARAMETER InputObject
        Objects to export (accepts pipeline).

    .PARAMETER Path
        Output file path.

    .PARAMETER Append
        Append to existing file instead of overwriting.

    .EXAMPLE
        $mailboxes | Export-CsvSafe -Path '.\MigrationData\mailboxes.csv'
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, ValueFromPipeline)] [object] $InputObject,
        [Parameter(Mandatory)] [string] $Path,
        [switch] $Append
    )

    begin {
        $items = [System.Collections.Generic.List[object]]::new()
        $dir   = Split-Path $Path -Parent
        if ($dir -and -not (Test-Path $dir)) {
            New-Item -ItemType Directory -Path $dir -Force | Out-Null
        }
    }
    process { $items.Add($InputObject) }
    end {
        if ($items.Count -eq 0) {
            Write-MigLog "Nothing to export to $Path" -Level WARN
            return
        }
        $params = @{
            Path              = $Path
            NoTypeInformation = $true
            Encoding          = 'UTF8'
        }
        if ($Append) { $params['Append'] = $true }
        $items | Export-Csv @params
        Write-MigLog "Exported $($items.Count) rows → $Path" -Level INFO
    }
}


function Import-CsvSafe {
    <#
    .SYNOPSIS
        Imports a CSV with validation. Throws on missing file or required columns.

    .PARAMETER Path
        Path to CSV file.

    .PARAMETER RequiredColumns
        Column names that must be present. Throws if any are absent.

    .EXAMPLE
        $mapping = Import-CsvSafe '.\MigrationData\user_mapping.csv' `
                       -RequiredColumns 'SourceEmail','TargetEmail','Status'
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]   $Path,
        [string[]] $RequiredColumns = @()
    )

    if (-not (Test-Path $Path)) {
        Write-MigLog "File not found: $Path" -Level ERROR
        throw "File not found: $Path"
    }

    $data = Import-Csv -Path $Path -Encoding UTF8

    if ($RequiredColumns.Count -gt 0 -and $data.Count -gt 0) {
        $actual  = $data[0].PSObject.Properties.Name
        $missing = $RequiredColumns | Where-Object { $_ -notin $actual }
        if ($missing) {
            Write-MigLog "Missing columns in ${Path}: $($missing -join ', ')" -Level ERROR
            throw "Missing columns: $($missing -join ', ')"
        }
    }

    Write-MigLog "Imported $($data.Count) rows from $Path" -Level DEBUG
    return $data
}


# ==============================================================================
#  MAPPING
# ==============================================================================

function Import-UserMapping {
    <#
    .SYNOPSIS
        Loads user_mapping.csv into module memory for fast lookups.
        Must be called before Get-MappedUPN.

    .PARAMETER Path
        Path to user_mapping.csv

    .PARAMETER ConfirmedOnly
        When set, only CONFIRMED rows are loaded.
        NEEDS_REVIEW rows are logged as warnings and skipped.

    .EXAMPLE
        Import-UserMapping -Path '.\MigrationData\user_mapping.csv' -ConfirmedOnly
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $Path,
        [switch] $ConfirmedOnly
    )

    $rows = Import-CsvSafe -Path $Path `
        -RequiredColumns @('SourceEmail','TargetEmail','Status')

    if ($ConfirmedOnly) {
        $rows | Where-Object { $_.Status -ne 'CONFIRMED' } | ForEach-Object {
            Write-MigLog "Mapping skipped (Status=$($_.Status)): $($_.SourceEmail)" -Level WARN
        }
        $rows = $rows | Where-Object { $_.Status -eq 'CONFIRMED' }
    }

    $script:MappingTable = @{}
    foreach ($row in $rows) {
        $key = $row.SourceEmail.ToUpper()
        if ($script:MappingTable.ContainsKey($key)) {
            Write-MigLog "Duplicate SourceEmail in mapping (last wins): $($row.SourceEmail)" -Level WARN
        }
        $script:MappingTable[$key] = $row
    }

    Write-MigLog "Mapping loaded: $($script:MappingTable.Count) entries from $Path"
}


function Get-MappedEmail {
    <#
    .SYNOPSIS
        Resolves a source email to its mapped target email.
        Returns $null if not found (or throws if -Strict).

    .PARAMETER SourceEmail
        Email address from the source tenant.

    .PARAMETER Strict
        Throw instead of returning $null when no mapping found.

    .EXAMPLE
        $target = Get-MappedEmail 'john@smartpulse.io'
        $target = Get-MappedEmail 'john@smartpulse.io' -Strict
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $SourceEmail,
        [switch] $Strict
    )

    if ($null -eq $script:MappingTable) {
        throw "Mapping not loaded. Call Import-UserMapping first."
    }

    $entry = $script:MappingTable[$SourceEmail.ToUpper()]

    if ($null -eq $entry) {
        $msg = "No mapping found for: $SourceEmail"
        if ($Strict) { Write-MigLog $msg -Level ERROR; throw $msg }
        Write-MigLog $msg -Level WARN
        return $null
    }

    return $entry.TargetEmail
}


function Get-MappedEmailList {
    <#
    .SYNOPSIS
        Resolves an array of source emails to a Source→Target hashtable.
        Unmapped addresses are logged as warnings.

    .PARAMETER SourceEmails
        Array of source email addresses to resolve.

    .EXAMPLE
        $resolved      = Get-MappedEmailList -SourceEmails $groupMembers
        $targetMembers = $resolved.Values
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string[]] $SourceEmails
    )

    $result  = @{}
    $missing = [System.Collections.Generic.List[string]]::new()

    foreach ($email in $SourceEmails) {
        $target = Get-MappedEmail -SourceEmail $email
        if ($target) { $result[$email] = $target }
        else          { $missing.Add($email) }
    }

    if ($missing.Count -gt 0) {
        Write-MigLog "$($missing.Count) email(s) could not be mapped: $($missing -join '; ')" -Level WARN
    }

    return $result
}


function Test-MappingCoverage {
    <#
    .SYNOPSIS
        Validates that every email in a list has a CONFIRMED mapping.
        Use as a Phase 3 gate — IsReady must be $true before creating target objects.

    .PARAMETER SourceEmails
        Complete list of source emails that must be covered.

    .PARAMETER MappingPath
        Path to user_mapping.csv (read fresh for this check).

    .OUTPUTS
        PSCustomObject: TotalRequired, Confirmed, NeedsReview, Unmatched[],
                        CoveragePercent, IsReady

    .EXAMPLE
        $check = Test-MappingCoverage -SourceEmails $allEmails `
                     -MappingPath '.\MigrationData\user_mapping.csv'
        if (-not $check.IsReady) { throw "Coverage insufficient" }
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string[]] $SourceEmails,
        [Parameter(Mandatory)] [string]   $MappingPath
    )

    $mapping = Import-CsvSafe -Path $MappingPath `
        -RequiredColumns @('SourceEmail','Status')
    $index   = @{}
    foreach ($row in $mapping) { $index[$row.SourceEmail.ToUpper()] = $row.Status }

    $confirmed   = 0
    $needsReview = 0
    $unmatched   = [System.Collections.Generic.List[string]]::new()

    foreach ($email in $SourceEmails) {
        switch ($index[$email.ToUpper()]) {
            'CONFIRMED'    { $confirmed++ }
            'NEEDS_REVIEW' { $needsReview++ }
            default        { $unmatched.Add($email) }
        }
    }

    $total    = $SourceEmails.Count
    $coverage = if ($total -gt 0) { [math]::Round(($confirmed / $total) * 100, 1) } else { 0 }
    $isReady  = ($unmatched.Count -eq 0 -and $needsReview -eq 0)

    Write-MigLog ("Coverage: {0}/{1} confirmed ({2}%) | NeedsReview={3} | Unmatched={4}" -f
        $confirmed, $total, $coverage, $needsReview, $unmatched.Count)

    if ($unmatched.Count -gt 0) {
        Write-MigLog "Unmatched (first 20): $($unmatched | Select-Object -First 20 | Join-String -Separator '; ')" -Level WARN
    }

    return [PSCustomObject]@{
        TotalRequired   = $total
        Confirmed       = $confirmed
        NeedsReview     = $needsReview
        Unmatched       = $unmatched.ToArray()
        CoveragePercent = $coverage
        IsReady         = $isReady
    }
}


# ==============================================================================
#  GENERAL UTILITIES
# ==============================================================================

function ConvertTo-FriendlySize {
    <#
    .SYNOPSIS  Converts a byte count to a human-readable string.
    .EXAMPLE   ConvertTo-FriendlySize -Bytes 1073741824  →  "1.00 GB"
    #>
    param([long] $Bytes)
    switch ($Bytes) {
        { $_ -ge 1TB } { return "{0:N2} TB" -f ($_ / 1TB) }
        { $_ -ge 1GB } { return "{0:N2} GB" -f ($_ / 1GB) }
        { $_ -ge 1MB } { return "{0:N2} MB" -f ($_ / 1MB) }
        { $_ -ge 1KB } { return "{0:N2} KB" -f ($_ / 1KB) }
        default        { return "$_ B" }
    }
}


function Get-SizeInGB {
    <#
    .SYNOPSIS
        Converts an Exchange mailbox size string or raw byte count to GB (rounded).

    .EXAMPLE
        Get-SizeInGB -SizeString "1.5 GB (1,610,612,736 bytes)"
        Get-SizeInGB -Bytes 1073741824
    #>
    param(
        [string] $SizeString = '',
        [long]   $Bytes      = 0
    )

    if ($Bytes -gt 0) { return [math]::Round($Bytes / 1GB, 3) }

    if ($SizeString -match '\(([0-9,]+)\s+bytes\)') {
        $raw = [long]($Matches[1] -replace ',', '')
        return [math]::Round($raw / 1GB, 3)
    }

    return 0
}


function Normalize-Name {
    <#
    .SYNOPSIS
        Normalises a display name for comparison: trim, lowercase, collapse
        spaces, strip common accented characters (covers Turkish + European).

    .EXAMPLE
        Normalize-Name 'Mehmet Yılmaz'   →  'mehmet yilmaz'
        Normalize-Name '  John  Smith '  →  'john smith'
    #>
    param([string] $Value)

    if ([string]::IsNullOrWhiteSpace($Value)) { return '' }

    $n = $Value.Trim().ToLower() -replace '\s+', ' '

    # Turkish characters
    $n = $n -replace 'ı', 'i' -replace 'ğ', 'g' -replace 'ş', 's' `
             -replace 'ç', 'c' -replace 'ö', 'o' -replace 'ü', 'u'
    # Other common European accents
    $n = $n -replace '[àáâãä]', 'a' -replace '[èéêë]', 'e' `
             -replace '[ìíîï]',  'i' -replace '[òóôõ]', 'o' `
             -replace '[ùúûü]',  'u' -replace '[ýÿ]',   'y' `
             -replace 'ñ', 'n'  -replace 'ß', 'ss'

    return $n
}


function Ensure-OutputDirectory {
    <#
    .SYNOPSIS  Creates a directory if it doesn't exist. Returns the resolved path.
    .EXAMPLE   $out = Ensure-OutputDirectory -Path '.\MigrationData'
    #>
    param([Parameter(Mandatory)] [string] $Path)

    if (-not (Test-Path $Path)) {
        New-Item -ItemType Directory -Path $Path -Force | Out-Null
        Write-MigLog "Created directory: $Path" -Level DEBUG
    }
    return (Resolve-Path $Path).Path
}


function Get-BatchName {
    <#
    .SYNOPSIS  Returns a zero-padded batch label.
    .EXAMPLE   Get-BatchName -Number 3  →  "Batch003"
    #>
    param([int] $Number)
    return "Batch{0:D3}" -f $Number
}


function ConvertFrom-ExchangeTimestamp {
    <#
    .SYNOPSIS  Safely parses Exchange date strings into DateTime (returns $null on failure).
    .EXAMPLE   $dt = ConvertFrom-ExchangeTimestamp -Value $mbx.WhenCreated
    #>
    param([string] $Value)
    if ([string]::IsNullOrWhiteSpace($Value)) { return $null }
    try   { return [datetime]::Parse($Value) }
    catch { return $null }
}


function Write-ProgressHelper {
    <#
    .SYNOPSIS
        Writes Write-Progress and a DEBUG log entry in one call.

    .EXAMPLE
        Write-ProgressHelper -Activity 'Exporting mailboxes' `
            -Current 45 -Total 200 -Status 'user@smartpulse.io'
    #>
    param(
        [string] $Activity,
        [int]    $Current,
        [int]    $Total,
        [string] $Status = ''
    )
    $pct = if ($Total -gt 0) { [math]::Round(($Current / $Total) * 100) } else { 0 }
    Write-Progress -Activity $Activity `
                   -Status "$Current/$Total  $Status" `
                   -PercentComplete $pct
    Write-MigLog "$Activity  [$Current/$Total]  $Status" -Level DEBUG
}


function New-MigrationFolderStructure {
    <#
    .SYNOPSIS
        Creates the standard folder layout for a migration project.

    .PARAMETER Root
        Root path for the migration working directory. Default: .\

    .EXAMPLE
        New-MigrationFolderStructure -Root 'C:\Migrations\SmartPulse'
    #>
    [CmdletBinding()]
    param([string] $Root = '.\')

    $folders = @('1-Inventory', '2-Mapping', '3-TargetPrep', '4-Validation',
                 'MigrationData', 'Logs')

    foreach ($folder in $folders) {
        $path = Join-Path $Root $folder
        if (-not (Test-Path $path)) {
            New-Item -ItemType Directory -Path $path -Force | Out-Null
            Write-MigLog "Created: $path"
        }
        else {
            Write-MigLog "Exists : $path" -Level DEBUG
        }
    }

    Write-MigLog "Migration folder structure ready under: $(Resolve-Path $Root)"
}


# ==============================================================================
#  MODULE EXPORT
# ==============================================================================

Export-ModuleMember -Function @(
    # Config loader
    'Import-MigrationConfig', 'Resolve-ConfigParam', 'Get-ConfigValue',

    # Domain config
    'Set-MigrationDomains', 'Get-MigrationDomains', 'Assert-MigrationDomains',

    # Logging
    'Initialize-MigLog', 'Write-MigLog', 'Write-MigSummary',

    # Connections
    'Connect-SourceTenant', 'Connect-TargetTenant',
    'Disconnect-AllTenants', 'Test-TenantConnection',

    # Retry
    'Invoke-WithRetry',

    # CSV
    'Export-CsvSafe', 'Import-CsvSafe',

    # Mapping
    'Import-UserMapping', 'Get-MappedEmail', 'Get-MappedEmailList', 'Test-MappingCoverage',

    # Utilities
    'ConvertTo-FriendlySize', 'Get-SizeInGB', 'Normalize-Name',
    'Ensure-OutputDirectory', 'Get-BatchName',
    'ConvertFrom-ExchangeTimestamp', 'Write-ProgressHelper',
    'New-MigrationFolderStructure'
)
