<#
.SYNOPSIS
    Automated Git commit script with AI-generated commit messages
.DESCRIPTION
    This script stages changes, generates a commit message using Python, and commits/pushes to GitHub
.EXAMPLE
    .\git-commit.ps1
    .\git-commit.ps1 -Push
    .\git-commit.ps1 -Message "Custom commit message" -Push
#>

param(
    [string]$Message = "",
    [switch]$Push = $false,
    [switch]$SkipAI = $false
)

# Configuration
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$pythonScript = Join-Path $scriptDir "generate-commit-message.py"

Write-Host "Git Commit Automation Script" -ForegroundColor Cyan
Write-Host "=============================" -ForegroundColor Cyan
Write-Host ""

# Check if we're in a git repository
if (-not (Test-Path ".git")) {
    Write-Host "ERROR: Not a git repository. Please run 'git init' first." -ForegroundColor Red
    exit 1
}

# Check for unstaged changes
$status = git status --porcelain
if ([string]::IsNullOrWhiteSpace($status)) {
    Write-Host "No changes to commit." -ForegroundColor Yellow
    exit 0
}

Write-Host "Changes detected:" -ForegroundColor Green
git status --short
Write-Host ""

# Stage all changes
Write-Host "Staging all changes..." -ForegroundColor Cyan
git add -A

# Generate or use provided commit message
if ([string]::IsNullOrWhiteSpace($Message) -and -not $SkipAI) {
    Write-Host "Generating commit message..." -ForegroundColor Cyan
    
    # Check if Python script exists
    if (Test-Path $pythonScript) {
        try {
            $Message = python $pythonScript 2>&1
            if ($LASTEXITCODE -ne 0) {
                Write-Host "Warning: Failed to generate commit message. Falling back to manual input." -ForegroundColor Yellow
                $Message = ""
            }
        } catch {
            Write-Host "Warning: Error running Python script: $_" -ForegroundColor Yellow
            $Message = ""
        }
    } else {
        Write-Host "Warning: Python script not found at: $pythonScript" -ForegroundColor Yellow
    }
}

# If still no message, prompt user
if ([string]::IsNullOrWhiteSpace($Message)) {
    Write-Host ""
    $Message = Read-Host "Enter commit message"
    
    if ([string]::IsNullOrWhiteSpace($Message)) {
        Write-Host "ERROR: Commit message cannot be empty." -ForegroundColor Red
        exit 1
    }
}

Write-Host ""
Write-Host "Commit message: $Message" -ForegroundColor Green
Write-Host ""

# Commit changes
Write-Host "Committing changes..." -ForegroundColor Cyan
git commit -m $Message

if ($LASTEXITCODE -ne 0) {
    Write-Host "ERROR: Commit failed." -ForegroundColor Red
    exit 1
}

Write-Host "Successfully committed!" -ForegroundColor Green

# Push if requested
if ($Push) {
    Write-Host ""
    Write-Host "Pushing to remote..." -ForegroundColor Cyan
    
    # Get current branch
    $branch = git rev-parse --abbrev-ref HEAD
    
    git push origin $branch
    
    if ($LASTEXITCODE -eq 0) {
        Write-Host "Successfully pushed to origin/$branch!" -ForegroundColor Green
    } else {
        Write-Host "ERROR: Push failed." -ForegroundColor Red
        exit 1
    }
}

Write-Host ""
Write-Host "Done!" -ForegroundColor Cyan
