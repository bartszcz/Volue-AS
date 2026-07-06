<#
.SYNOPSIS
    Pre-provisions shared mailboxes and migrates permissions to target tenant.

.DESCRIPTION
    - Reads configuration from MigrationConfig.csv
    - Reads shared mailbox list from source tenant CSV
    - Uses CodeTwo migration mapping to translate source users to target users
    - Creates shared mailboxes in target tenant (skips if already exists)
    - Migrates permissions (FullAccess, SendAs, SendOnBehalf) using the email mapping
    - Checks if permissions already exist before adding

.PARAMETER ConfigPath
    Path to MigrationConfig.csv with migration settings.

.PARAMETER SharedMailboxCsvPath
    Path to shared mailbox CSV with source mailbox details.

.PARAMETER MappingCsvPath
    Path to CodeTwo migration mapping CSV (SourceEmail -> TargetEmail mapping).

.PARAMETER OutputPath
    Output CSV with provisioned mailbox and permission details.

.PARAMETER MigratePermissionsOnly
    Skip mailbox creation and only migrate permissions (use when mailboxes already exist).

.EXAMPLE
    .\Migrate-SharedMailboxes.ps1 -ConfigPath ".\MigrationConfig.csv" -SharedMailboxCsvPath ".\shared-mailboxes.csv" -MappingCsvPath ".\CodeTwo_Migration.csv"

.NOTES
    Requires ExchangeOnlineManagement module
    Must connect to BOTH source and target tenants during execution
#>

[CmdletBinding(SupportsShouldProcess)]
param (
    [string]$ConfigPath,
    [string]$SharedMailboxCsvPath,
    [string]$MappingCsvPath,
    [string]$OutputPath,
    [switch]$MigratePermissionsOnly
)

# ==============================================================================
# CONFIGURATION DEFAULTS
# ==============================================================================

# Shared mailbox target email suffix
$SharedMailboxTargetSuffix = ".quorum"

# Display name suffix for target mailboxes
$DisplayNameSuffix = ""

# CSV column mappings for CodeTwo migration file
$MappingSourceEmailColumn = "SourceEmail"
$MappingTargetEmailColumn = "TargetEmail"

# Prompt for confirmation
$ConfirmEachMailbox = $false
$ConfirmPermissions = $false

# Configuration variables (will be loaded from config file)
$Config = @{
    SourceCompanyName = ""
    SourceDomain = ""
    TargetDomain = ""
    NewGroupPrefix = ""
    OutputFolder = ""
    SourceAdminUPN = ""
    TargetAdminUPN = ""
}

# ==============================================================================
# HELPER FUNCTIONS
# ==============================================================================

function Write-Info {
    param([string]$Message)
    Write-Host "  [*] $Message" -ForegroundColor Cyan
}

function Write-Ok {
    param([string]$Message)
    Write-Host "  [✓] $Message" -ForegroundColor Green
}

function Write-Fail {
    param([string]$Message)
    Write-Host "  [✗] $Message" -ForegroundColor Red
}

function Write-Warn {
    param([string]$Message)
    Write-Host "  [!] $Message" -ForegroundColor Yellow
}

function Write-Permission {
    param([string]$Message)
    Write-Host "      $Message" -ForegroundColor DarkGray
}

function Prompt-ForInput {
    param(
        [string]$PromptMessage,
        [string]$DefaultValue = ""
    )
    if ($DefaultValue) {
        $input = Read-Host "$PromptMessage [$DefaultValue]"
        if ([string]::IsNullOrWhiteSpace($input)) { return $DefaultValue }
        return $input
    } else {
        do {
            $input = Read-Host $PromptMessage
            if ([string]::IsNullOrWhiteSpace($input)) {
                Write-Host "    This field is required." -ForegroundColor Yellow
            }
        } while ([string]::IsNullOrWhiteSpace($input))
        return $input
    }
}

function Prompt-ForFile {
    param(
        [string]$PromptMessage,
        [string]$DefaultValue = ""
    )
    do {
        $path = Prompt-ForInput -PromptMessage $PromptMessage -DefaultValue $DefaultValue
        $resolvedPath = if ([System.IO.Path]::IsPathRooted($path)) { $path } else { Join-Path $PSScriptRoot $path.TrimStart('.\') }
        
        if (-not (Test-Path $resolvedPath)) {
            Write-Host "    File not found: $resolvedPath" -ForegroundColor Yellow
            $path = ""
        }
    } while ([string]::IsNullOrWhiteSpace($path))
    return $resolvedPath
}

function Resolve-ScriptPath {
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { return $Path }
    if ([System.IO.Path]::IsPathRooted($Path)) { return $Path }
    return Join-Path $PSScriptRoot $Path.TrimStart('.\')
}

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

function Load-MigrationConfig {
    param([string]$ConfigPath)
    
    $config = @{}
    $configData = Import-Csv -Path $ConfigPath -Encoding UTF8
    
    foreach ($row in $configData) {
        $config[$row.Setting] = $row.Value
    }
    
    return $config
}

function Get-TargetEmail {
    param(
        [string]$SourceEmail,
        [hashtable]$EmailMapping
    )
    
    $sourceEmailLower = $SourceEmail.ToLower().Trim()
    
    if ($EmailMapping.ContainsKey($sourceEmailLower)) {
        return $EmailMapping[$sourceEmailLower]
    }
    
    return $null
}

# ==============================================================================
# MAIN SCRIPT
# ==============================================================================

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

Write-Host ""
Write-Host "========================================================" -ForegroundColor Cyan
Write-Host "  Shared Mailbox Migration with Permissions" -ForegroundColor Cyan
Write-Host "========================================================" -ForegroundColor Cyan
Write-Host ""

# ==============================================================================
# PREREQUISITES CHECK
# ==============================================================================

Write-Host "--------------------------------------------------------" -ForegroundColor DarkCyan
Write-Info "Prerequisites Check"
Write-Host "--------------------------------------------------------" -ForegroundColor DarkCyan
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
# LOAD CONFIGURATION FILE
# ==============================================================================

if ([string]::IsNullOrWhiteSpace($ConfigPath)) {
    $ConfigPath = Prompt-ForFile -PromptMessage "MigrationConfig.csv path" -DefaultValue ".\MigrationConfig.csv"
}
$ConfigPath = Resolve-ScriptPath $ConfigPath

Write-Info "Loading configuration from: $ConfigPath"
$Config = Load-MigrationConfig -ConfigPath $ConfigPath

# Extract config values
$SourceCompanyName = $Config["SourceCompanyName"]
$SourceDomain = $Config["SourceDomain"]
$TargetDomain = $Config["TargetDomain"]
$NewGroupPrefix = $Config["NewGroupPrefix"]
$OutputFolder = $Config["OutputFolder"]
$SourceAdminUPN = $Config["SourceAdminUPN"]
$TargetAdminUPN = $Config["TargetAdminUPN"]

Write-Ok "Configuration loaded successfully"
Write-Info "  Source: $SourceCompanyName ($SourceDomain)"
Write-Info "  Target: $TargetDomain"
Write-Info "  Source Admin: $SourceAdminUPN"
Write-Info "  Target Admin: $TargetAdminUPN"
Write-Host ""

# Prompt for CSV paths if not provided
if ([string]::IsNullOrWhiteSpace($SharedMailboxCsvPath)) {
    $SharedMailboxCsvPath = Prompt-ForFile -PromptMessage "Shared mailbox CSV path"
}

if ([string]::IsNullOrWhiteSpace($MappingCsvPath)) {
    $MappingCsvPath = Prompt-ForFile -PromptMessage "CodeTwo migration mapping CSV path"
}

# Resolve paths
$SharedMailboxCsvPath = Resolve-ScriptPath $SharedMailboxCsvPath
$MappingCsvPath = Resolve-ScriptPath $MappingCsvPath

# Set output path using OutputFolder from config if not provided
if ([string]::IsNullOrWhiteSpace($OutputPath)) {
    $OutputPath = Join-Path $OutputFolder "SharedMailbox-Migration-Results.csv"
} else {
    $OutputPath = Resolve-ScriptPath $OutputPath
}

Write-Host ""
Write-Info "File Configuration:"
Write-Info "  Shared Mailbox CSV: $SharedMailboxCsvPath"
Write-Info "  Migration Mapping: $MappingCsvPath"
Write-Info "  Output Path: $OutputPath"
Write-Info "  Target Email Pattern: {Alias}$SharedMailboxTargetSuffix@$TargetDomain"
Write-Host ""

# ==============================================================================
# LOAD EMAIL MAPPING
# ==============================================================================

Write-Info "Loading CodeTwo migration mapping..."
$mappingData = @(Import-Csv -Path $MappingCsvPath -Delimiter ';' -Encoding UTF8)
Write-Ok "Loaded $($mappingData.Count) email mappings"

# Build hashtable for fast lookup (source -> target)
$EmailMapping = @{}
foreach ($row in $mappingData) {
    $sourceEmail = $row.$MappingSourceEmailColumn.ToLower().Trim()
    $targetEmail = $row.$MappingTargetEmailColumn.Trim()
    $EmailMapping[$sourceEmail] = $targetEmail
}

Write-Ok "Email mapping hashtable built"

# ==============================================================================
# LOAD SHARED MAILBOXES
# ==============================================================================

Write-Info "Loading shared mailbox list..."
$sharedMailboxes = @(Import-Csv -Path $SharedMailboxCsvPath -Encoding UTF8)
Write-Ok "Loaded $($sharedMailboxes.Count) shared mailboxes"

# Detect columns
$sampleRow = $sharedMailboxes[0]
$SourceEmailColumn = ($sampleRow.PSObject.Properties.Name | Where-Object { $_ -match 'primarysmtpaddress|sourcemail|source.?email' }) | Select-Object -First 1
$DisplayNameColumn = ($sampleRow.PSObject.Properties.Name | Where-Object { $_ -match 'displayname|display_name' }) | Select-Object -First 1

if (-not $SourceEmailColumn) {
    # Try common column names
    if ($sampleRow.PSObject.Properties.Name -contains "PrimarySmtpAddress") {
        $SourceEmailColumn = "PrimarySmtpAddress"
    }
}

Write-Ok "Using columns: SourceEmail=$SourceEmailColumn, DisplayName=$DisplayNameColumn"

# ==============================================================================
# CONNECT TO SOURCE TENANT (for reading permissions)
# ==============================================================================

Write-Host ""
Write-Host "----------------------------------------" -ForegroundColor Yellow
Write-Info "STEP 1: Connect to SOURCE tenant to read permissions"
Write-Info "Source Admin: $SourceAdminUPN"
Write-Host "----------------------------------------" -ForegroundColor Yellow
Write-Host ""

$connectSource = Read-Host "Connect to SOURCE tenant now? (y/n)"
if ($connectSource -eq 'y' -or $connectSource -eq 'yes') {
    try {
        Connect-ExchangeOnline -UserPrincipalName $SourceAdminUPN -ErrorAction Stop -WarningAction SilentlyContinue | Out-Null
        Write-Ok "Connected to source tenant as $SourceAdminUPN"
    } catch {
        Write-Fail "Failed to connect: $_"
        exit 1
    }
}

# ==============================================================================
# READ PERMISSIONS FROM SOURCE
# ==============================================================================

Write-Host ""
Write-Info "Reading permissions from source tenant..."
$sourcePermissions = @{}

foreach ($mailbox in $sharedMailboxes) {
    $sourceEmail = $mailbox.$SourceEmailColumn
    Write-Info "Reading permissions for: $sourceEmail"
    
    $perms = @{
        FullAccess = @()
        SendAs = @()
        SendOnBehalf = @()
    }
    
    try {
        # Get Full Access permissions
        $fullAccess = Get-MailboxPermission -Identity $sourceEmail -ErrorAction SilentlyContinue | 
            Where-Object { 
                $_.User -notlike "NT AUTHORITY\*" -and 
                $_.User -notlike "S-1-5-*" -and 
                $_.AccessRights -contains "FullAccess" -and
                $_.IsInherited -eq $false
            }
        
        foreach ($fa in $fullAccess) {
            $userEmail = $fa.User.ToString()
            # Try to resolve to email if it's a display name
            try {
                $resolved = Get-Mailbox -Identity $userEmail -ErrorAction SilentlyContinue
                if ($resolved) {
                    $userEmail = $resolved.PrimarySmtpAddress.ToString()
                }
            } catch {}
            
            $perms.FullAccess += $userEmail
            Write-Permission "FullAccess: $userEmail"
        }
        
        # Get Send As permissions
        $sendAs = Get-RecipientPermission -Identity $sourceEmail -ErrorAction SilentlyContinue |
            Where-Object {
                $_.Trustee -notlike "NT AUTHORITY\*" -and
                $_.Trustee -notlike "S-1-5-*" -and
                $_.AccessRights -contains "SendAs"
            }
        
        foreach ($sa in $sendAs) {
            $userEmail = $sa.Trustee.ToString()
            try {
                $resolved = Get-Mailbox -Identity $userEmail -ErrorAction SilentlyContinue
                if ($resolved) {
                    $userEmail = $resolved.PrimarySmtpAddress.ToString()
                }
            } catch {}
            
            $perms.SendAs += $userEmail
            Write-Permission "SendAs: $userEmail"
        }
        
        # Get Send On Behalf permissions
        $mailboxDetails = Get-Mailbox -Identity $sourceEmail -ErrorAction SilentlyContinue
        if ($mailboxDetails.GrantSendOnBehalfTo) {
            foreach ($sob in $mailboxDetails.GrantSendOnBehalfTo) {
                $userEmail = $sob.ToString()
                try {
                    $resolved = Get-Mailbox -Identity $sob -ErrorAction SilentlyContinue
                    if ($resolved) {
                        $userEmail = $resolved.PrimarySmtpAddress.ToString()
                    }
                } catch {}
                
                $perms.SendOnBehalf += $userEmail
                Write-Permission "SendOnBehalf: $userEmail"
            }
        }
        
    } catch {
        Write-Warn "  Error reading permissions: $_"
    }
    
    $sourcePermissions[$sourceEmail] = $perms
}

Write-Host ""
Write-Ok "Finished reading source permissions"

# Disconnect from source
Disconnect-ExchangeOnline -Confirm:$false -ErrorAction SilentlyContinue | Out-Null
Write-Ok "Disconnected from source tenant"

# ==============================================================================
# CONNECT TO TARGET TENANT
# ==============================================================================

Write-Host ""
Write-Host "----------------------------------------" -ForegroundColor Yellow
Write-Info "STEP 2: Connect to TARGET tenant to create mailboxes and apply permissions"
Write-Info "Target Admin: $TargetAdminUPN"
Write-Host "----------------------------------------" -ForegroundColor Yellow
Write-Host ""

$connectTarget = Read-Host "Connect to TARGET tenant now? (y/n)"
if ($connectTarget -eq 'y' -or $connectTarget -eq 'yes') {
    try {
        Connect-ExchangeOnline -UserPrincipalName $TargetAdminUPN -ErrorAction Stop -WarningAction SilentlyContinue | Out-Null
        Write-Ok "Connected to target tenant as $TargetAdminUPN"
    } catch {
        Write-Fail "Failed to connect: $_"
        exit 1
    }
} else {
    Write-Fail "Cannot proceed without target tenant connection"
    exit 1
}

# ==============================================================================
# CREATE MAILBOXES AND APPLY PERMISSIONS
# ==============================================================================

Write-Host ""
$results = @()
$mailboxCreated = 0
$mailboxSkipped = 0
$mailboxFailed = 0
$permissionsAdded = 0
$permissionsSkipped = 0
$permissionsFailed = 0

foreach ($mailbox in $sharedMailboxes) {
    $sourceEmail = $mailbox.$SourceEmailColumn
    $displayName = if ($DisplayNameColumn) { $mailbox.$DisplayNameColumn } else { "" }
    
    # Build target email
    $alias = ($sourceEmail -split '@')[0]
    $targetEmail = "$alias$SharedMailboxTargetSuffix@$TargetDomain"
    $targetDisplayName = if ($displayName) { 
        if ($DisplayNameSuffix) { "$displayName $DisplayNameSuffix" } else { $displayName }
    } else { 
        $alias 
    }
    
    Write-Host ""
    Write-Host "========================================" -ForegroundColor Magenta
    Write-Info "Processing: $sourceEmail"
    Write-Info "Target: $targetEmail"
    Write-Host "========================================" -ForegroundColor Magenta
    
    $targetId = ""
    $mailboxStatus = ""
    
    # ----------------------------------
    # CHECK IF MAILBOX EXISTS
    # ----------------------------------
    
    $existingMailbox = $null
    try {
        $existingMailbox = Get-Mailbox -Identity $targetEmail -ErrorAction SilentlyContinue
    } catch {
        # Mailbox doesn't exist - this is expected
    }
    
    if ($existingMailbox) {
        Write-Warn "Mailbox already exists - skipping creation"
        $mailboxSkipped++
        $mailboxStatus = "AlreadyExists"
        $targetId = $existingMailbox.ExternalDirectoryObjectId
    } elseif (-not $MigratePermissionsOnly) {
        # ----------------------------------
        # CREATE MAILBOX
        # ----------------------------------
        
        if ($ConfirmEachMailbox) {
            $confirm = Read-Host "  Create mailbox '$targetDisplayName' <$targetEmail>? (y/n)"
            if ($confirm -ne 'y' -and $confirm -ne 'yes') {
                Write-Warn "Skipped by user"
                $mailboxSkipped++
                continue
            }
        }
        
        try {
            if ($PSCmdlet.ShouldProcess($targetEmail, "Create shared mailbox")) {
                New-Mailbox -Shared `
                    -Name $targetDisplayName `
                    -DisplayName $targetDisplayName `
                    -Alias $alias `
                    -PrimarySmtpAddress $targetEmail `
                    -ErrorAction Stop | Out-Null
                
                Write-Ok "Created mailbox: $targetEmail"
                $mailboxCreated++
                $mailboxStatus = "Created"
                
                # Wait a moment for mailbox to be available
                Start-Sleep -Seconds 2
                
                $newMailbox = Get-Mailbox -Identity $targetEmail -ErrorAction Stop
                $targetId = $newMailbox.ExternalDirectoryObjectId
            }
        } catch {
            Write-Fail "Failed to create mailbox: $_"
            $mailboxFailed++
            $mailboxStatus = "Failed: $_"
            continue
        }
    } else {
        Write-Warn "Mailbox does not exist and -MigratePermissionsOnly is set - skipping"
        $mailboxSkipped++
        continue
    }
    
    # ----------------------------------
    # APPLY PERMISSIONS
    # ----------------------------------
    
    if ($sourcePermissions.ContainsKey($sourceEmail)) {
        $perms = $sourcePermissions[$sourceEmail]
        
        Write-Info "Applying permissions..."
        
        # Full Access
        foreach ($sourceUser in $perms.FullAccess) {
            $targetUser = Get-TargetEmail -SourceEmail $sourceUser -EmailMapping $EmailMapping
            
            if (-not $targetUser) {
                Write-Warn "  No mapping found for: $sourceUser (FullAccess) - SKIPPED"
                $permissionsSkipped++
                continue
            }
            
            # Check if permission already exists
            try {
                $existingPerm = Get-MailboxPermission -Identity $targetEmail -User $targetUser -ErrorAction SilentlyContinue
                if ($existingPerm -and $existingPerm.AccessRights -contains "FullAccess") {
                    Write-Permission "FullAccess: $targetUser - already exists"
                    $permissionsSkipped++
                    continue
                }
            } catch {}
            
            try {
                Add-MailboxPermission -Identity $targetEmail -User $targetUser -AccessRights FullAccess -InheritanceType All -AutoMapping $false -ErrorAction Stop | Out-Null
                Write-Ok "  FullAccess: $targetUser"
                $permissionsAdded++
            } catch {
                Write-Fail "  FullAccess failed for $targetUser : $_"
                $permissionsFailed++
            }
        }
        
        # Send As
        foreach ($sourceUser in $perms.SendAs) {
            $targetUser = Get-TargetEmail -SourceEmail $sourceUser -EmailMapping $EmailMapping
            
            if (-not $targetUser) {
                Write-Warn "  No mapping found for: $sourceUser (SendAs) - SKIPPED"
                $permissionsSkipped++
                continue
            }
            
            # Check if permission already exists
            try {
                $existingPerm = Get-RecipientPermission -Identity $targetEmail -Trustee $targetUser -ErrorAction SilentlyContinue
                if ($existingPerm -and $existingPerm.AccessRights -contains "SendAs") {
                    Write-Permission "SendAs: $targetUser - already exists"
                    $permissionsSkipped++
                    continue
                }
            } catch {}
            
            try {
                Add-RecipientPermission -Identity $targetEmail -Trustee $targetUser -AccessRights SendAs -Confirm:$false -ErrorAction Stop | Out-Null
                Write-Ok "  SendAs: $targetUser"
                $permissionsAdded++
            } catch {
                Write-Fail "  SendAs failed for $targetUser : $_"
                $permissionsFailed++
            }
        }
        
        # Send On Behalf
        foreach ($sourceUser in $perms.SendOnBehalf) {
            $targetUser = Get-TargetEmail -SourceEmail $sourceUser -EmailMapping $EmailMapping
            
            if (-not $targetUser) {
                Write-Warn "  No mapping found for: $sourceUser (SendOnBehalf) - SKIPPED"
                $permissionsSkipped++
                continue
            }
            
            # Check if permission already exists
            try {
                $mailboxCheck = Get-Mailbox -Identity $targetEmail -ErrorAction SilentlyContinue
                if ($mailboxCheck.GrantSendOnBehalfTo -contains $targetUser) {
                    Write-Permission "SendOnBehalf: $targetUser - already exists"
                    $permissionsSkipped++
                    continue
                }
            } catch {}
            
            try {
                Set-Mailbox -Identity $targetEmail -GrantSendOnBehalfTo @{Add=$targetUser} -ErrorAction Stop
                Write-Ok "  SendOnBehalf: $targetUser"
                $permissionsAdded++
            } catch {
                Write-Fail "  SendOnBehalf failed for $targetUser : $_"
                $permissionsFailed++
            }
        }
    } else {
        Write-Info "No permissions to migrate for this mailbox"
    }
    
    # Add to results
    $results += [PSCustomObject]@{
        SourceEmail = $sourceEmail
        TargetEmail = $targetEmail
        TargetId = $targetId
        MailboxStatus = $mailboxStatus
        FullAccessCount = ($perms.FullAccess | Measure-Object).Count
        SendAsCount = ($perms.SendAs | Measure-Object).Count
        SendOnBehalfCount = ($perms.SendOnBehalf | Measure-Object).Count
    }
}

# ==============================================================================
# SUMMARY
# ==============================================================================

Write-Host ""
Write-Host "========================================================" -ForegroundColor Cyan
Write-Host "  Migration Summary" -ForegroundColor Cyan
Write-Host "========================================================" -ForegroundColor Cyan
Write-Host ""
Write-Info "Mailboxes:"
Write-Info "  Created: $mailboxCreated"
Write-Info "  Already Existed: $mailboxSkipped"
Write-Info "  Failed: $mailboxFailed"
Write-Host ""
Write-Info "Permissions:"
Write-Info "  Added: $permissionsAdded"
Write-Info "  Skipped (exists/no mapping): $permissionsSkipped"
Write-Info "  Failed: $permissionsFailed"
Write-Host ""

# Export results
Write-Info "Exporting results to: $OutputPath"
$results | Export-Csv -Path $OutputPath -NoTypeInformation -Encoding UTF8
Write-Ok "Results saved"

Write-Host ""
Disconnect-ExchangeOnline -Confirm:$false -ErrorAction SilentlyContinue | Out-Null
Write-Ok "Disconnected from Exchange Online"
Write-Host ""
