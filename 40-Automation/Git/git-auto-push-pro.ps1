# Git Auto-Push Script (Production-Learning Version)
# Teaches production habits for solo development learning

param(
    [string]$Message = "",
    [string]$Type = "",
    [switch]$DryRun = $false,
    [switch]$Force = $false,
    [switch]$SkipPull = $false
)

# Load configuration
$configPath = Join-Path $PSScriptRoot "git-config.json"
if (Test-Path $configPath) {
    $config = Get-Content $configPath | ConvertFrom-Json
} else {
    Write-Host "Warning: Configuration file not found. Using defaults." -ForegroundColor Yellow
    $config = @{
        protectedBranches = @("main", "master", "production")
        requireConfirmationForProtectedBranches = $true
        enableLogging = $true
        logFile = "scripts/git-auto-push.log"
        commitMessagePrefix = "auto"
        enablePreCommitValidation = $false
        lintCommand = ""
        testCommand = ""
        maxFileSizeMB = 50
        autoGenerateMessage = $true
        pullBeforePush = $true
    }
}

# Logging function
function Write-Log {
    param([string]$Message, [string]$Level = "INFO")
    
    if ($config.enableLogging) {
        $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
        $logEntry = "[$timestamp] [$Level] $Message"
        
        $logPath = Join-Path $PSScriptRoot $config.logFile
        Add-Content -Path $logPath -Value $logEntry
    }
}

# Display banner
Write-Host "`n=== Git Auto-Push (Production-Learning Mode) ===" -ForegroundColor Cyan
if ($DryRun) {
    Write-Host "[DRY RUN MODE - No changes will be made]`n" -ForegroundColor Magenta
}

Write-Log "Script started. DryRun: $DryRun, Force: $Force"

# Check if we're in a git repository
if (-not (Test-Path ".git")) {
    Write-Host "Error: Not a git repository. Run 'git init' first." -ForegroundColor Red
    Write-Log "Error: Not in a git repository" "ERROR"
    exit 1
}

# Get current branch
$currentBranch = git rev-parse --abbrev-ref HEAD
Write-Host "Current branch: $currentBranch" -ForegroundColor Cyan
Write-Log "Current branch: $currentBranch"

# Check if on protected branch
$isProtectedBranch = $config.protectedBranches -contains $currentBranch
if ($isProtectedBranch -and $config.requireConfirmationForProtectedBranches -and -not $Force) {
    Write-Host "`nWarning: You are about to push to a protected branch: $currentBranch" -ForegroundColor Yellow
    Write-Host "In production environments, you would typically:" -ForegroundColor Yellow
    Write-Host "  1. Create a feature branch (git checkout -b feature/my-feature)" -ForegroundColor Gray
    Write-Host "  2. Make changes and commit" -ForegroundColor Gray
    Write-Host "  3. Push feature branch and create a Pull Request" -ForegroundColor Gray
    Write-Host "  4. Merge after review`n" -ForegroundColor Gray
    
    if (-not $DryRun) {
        $confirm = Read-Host "Continue pushing to $currentBranch? (yes/no)"
        if ($confirm -ne "yes") {
            Write-Host "Push cancelled." -ForegroundColor Yellow
            Write-Log "Push cancelled by user (protected branch)" "WARN"
            exit 0
        }
    }
}

# Pull latest changes first (production best practice)
if ($config.pullBeforePush -and -not $SkipPull -and -not $DryRun) {
    Write-Host "`nPulling latest changes from remote..." -ForegroundColor Green
    Write-Log "Pulling latest changes"
    
    git pull --rebase 2>&1 | Out-Null
    
    if ($LASTEXITCODE -ne 0) {
        Write-Host "Warning: Pull failed or conflicts detected. Resolve conflicts before pushing." -ForegroundColor Yellow
        Write-Log "Pull failed with conflicts" "WARN"
        exit 1
    }
    Write-Host "Pull successful." -ForegroundColor Green
}

# Check if there are any changes
$status = git status --porcelain
if ([string]::IsNullOrWhiteSpace($status)) {
    Write-Host "`nNo changes to commit." -ForegroundColor Yellow
    Write-Log "No changes detected"
    exit 0
}

Write-Host "`nChanges detected:" -ForegroundColor Green
git status --short

# Check for nested git repositories
$nestedRepos = Get-ChildItem -Path . -Recurse -Filter ".git" -Directory -ErrorAction SilentlyContinue | Where-Object { $_.FullName -ne (Get-Location).Path + "\.git" }
if ($nestedRepos) {
    Write-Host "`nWarning: Found nested git repositories. These will be skipped:" -ForegroundColor Yellow
    foreach ($repo in $nestedRepos) {
        $relativePath = $repo.Parent.FullName.Replace((Get-Location).Path, "").TrimStart("\")
        Write-Host "  - $relativePath" -ForegroundColor Yellow
    }
    Write-Log "Nested repositories detected" "WARN"
}

# Check file sizes
Write-Host "`nChecking file sizes..." -ForegroundColor Green
$changedFiles = git status --porcelain | ForEach-Object { $_.Substring(3) }
$largeFiles = @()

foreach ($file in $changedFiles) {
    if (Test-Path $file) {
        $fileSize = (Get-Item $file).Length / 1MB
        if ($fileSize -gt $config.maxFileSizeMB) {
            $largeFiles += "$file ($([math]::Round($fileSize, 2)) MB)"
        }
    }
}

if ($largeFiles.Count -gt 0) {
    Write-Host "Warning: Large files detected (>${$config.maxFileSizeMB}MB):" -ForegroundColor Yellow
    foreach ($file in $largeFiles) {
        Write-Host "  - $file" -ForegroundColor Yellow
    }
    Write-Host "Consider using Git LFS for large files in production." -ForegroundColor Gray
    Write-Log "Large files detected: $($largeFiles -join ', ')" "WARN"
    
    if (-not $Force -and -not $DryRun) {
        $confirm = Read-Host "Continue? (yes/no)"
        if ($confirm -ne "yes") {
            Write-Host "Push cancelled." -ForegroundColor Yellow
            exit 0
        }
    }
}

if ($DryRun) {
    Write-Host "`n[DRY RUN] Would stage all changes..." -ForegroundColor Magenta
} else {
    Write-Host "`nStaging all changes..." -ForegroundColor Green
    git add . 2>&1 | Out-Null
}

# Verify staged changes
$stagedChanges = git diff --cached --name-only
if ([string]::IsNullOrWhiteSpace($stagedChanges) -and -not $DryRun) {
    Write-Host "Error: No files were staged." -ForegroundColor Red
    Write-Log "No files staged" "ERROR"
    exit 1
}

# Pre-commit validation (if enabled)
if ($config.enablePreCommitValidation -and -not $DryRun) {
    Write-Host "`nRunning pre-commit validation..." -ForegroundColor Green
    
    if (![string]::IsNullOrWhiteSpace($config.lintCommand)) {
        Write-Host "  Running linter..." -ForegroundColor Gray
        Invoke-Expression $config.lintCommand
        if ($LASTEXITCODE -ne 0) {
            Write-Host "Linting failed. Fix issues before committing." -ForegroundColor Red
            Write-Log "Linting failed" "ERROR"
            exit 1
        }
    }
    
    if (![string]::IsNullOrWhiteSpace($config.testCommand)) {
        Write-Host "  Running tests..." -ForegroundColor Gray
        Invoke-Expression $config.testCommand
        if ($LASTEXITCODE -ne 0) {
            Write-Host "Tests failed. Fix issues before committing." -ForegroundColor Red
            Write-Log "Tests failed" "ERROR"
            exit 1
        }
    }
}

# Create structured commit message (Conventional Commits)
$commitTypes = @{
    "feat" = "A new feature"
    "fix" = "A bug fix"
    "docs" = "Documentation changes"
    "style" = "Code style changes (formatting, etc.)"
    "refactor" = "Code refactoring"
    "test" = "Adding or updating tests"
    "chore" = "Maintenance tasks"
    "perf" = "Performance improvements"
}

if ([string]::IsNullOrWhiteSpace($Message)) {
    if ($config.autoGenerateMessage) {
        $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
        
        if ([string]::IsNullOrWhiteSpace($Type)) {
            Write-Host "`nProduction Tip: Use conventional commit types for better history tracking" -ForegroundColor Cyan
            Write-Host "Available types:" -ForegroundColor Gray
            foreach ($key in $commitTypes.Keys | Sort-Object) {
                Write-Host "  $key - $($commitTypes[$key])" -ForegroundColor Gray
            }
            Write-Host "`nExample: .\git-auto-push-pro.ps1 -Type feat -Message 'add user authentication'`n" -ForegroundColor Gray
            
            $Type = "chore"
        }
        
        $Message = "${Type}: auto-commit $timestamp"
    } else {
        Write-Host "Error: Commit message required." -ForegroundColor Red
        exit 1
    }
} else {
    if (![string]::IsNullOrWhiteSpace($Type)) {
        $Message = "${Type}: $Message"
    }
}

if ($DryRun) {
    Write-Host "`n[DRY RUN] Would commit with message: $Message" -ForegroundColor Magenta
} else {
    Write-Host "`nCommitting with message: $Message" -ForegroundColor Green
    git commit -m $Message
    
    if ($LASTEXITCODE -ne 0) {
        Write-Host "Error: Commit failed." -ForegroundColor Red
        Write-Log "Commit failed: $Message" "ERROR"
        exit 1
    }
    Write-Log "Committed: $Message"
}

# Get commit stats
if (-not $DryRun) {
    $stats = git diff HEAD~1 --shortstat
    Write-Host "Changes: $stats" -ForegroundColor Gray
}

if ($DryRun) {
    Write-Host "`n[DRY RUN] Would push to GitHub..." -ForegroundColor Magenta
    Write-Host "`n=== Dry Run Complete ===" -ForegroundColor Cyan
    Write-Host "Run without -DryRun to execute these changes.`n" -ForegroundColor Gray
} else {
    Write-Host "`nPushing to GitHub..." -ForegroundColor Green
    git push
    
    if ($LASTEXITCODE -eq 0) {
        Write-Host "`n✓ Successfully pushed to GitHub!" -ForegroundColor Green
        Write-Log "Push successful to $currentBranch"
        
        # Display summary
        Write-Host "`n=== Summary ===" -ForegroundColor Cyan
        Write-Host "Branch: $currentBranch" -ForegroundColor Gray
        Write-Host "Commit: $Message" -ForegroundColor Gray
        Write-Host "Files changed: $(($stagedChanges | Measure-Object).Count)" -ForegroundColor Gray
        Write-Host ""
    } else {
        Write-Host "`nError: Push failed. Check your remote configuration." -ForegroundColor Red
        Write-Log "Push failed" "ERROR"
        exit 1
    }
}
