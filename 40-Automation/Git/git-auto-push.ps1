# Git Auto-Push Script (PowerShell)
# Automatically commits and pushes all changes to GitHub

param(
    [string]$Message = ""
)

Write-Host "Starting Git auto-push..." -ForegroundColor Cyan

$currentPath = Get-Location
$gitRoot = $currentPath

while ($gitRoot -and -not (Test-Path (Join-Path $gitRoot ".git"))) {
    $parent = Split-Path $gitRoot -Parent
    if ($parent -eq $gitRoot) {
        Write-Host "Error: Not inside a git repository. Run 'git init' first or navigate to your git repository." -ForegroundColor Red
        exit 1
    }
    $gitRoot = $parent
}

if ($gitRoot -ne $currentPath) {
    Write-Host "Found git repository at: $gitRoot" -ForegroundColor Cyan
    Set-Location $gitRoot
}

# Check if there are any changes
$status = git status --porcelain
if ([string]::IsNullOrWhiteSpace($status)) {
    Write-Host "No changes to commit." -ForegroundColor Yellow
    if ($gitRoot -ne $currentPath) { Set-Location $currentPath }
    exit 0
}

# Check for nested git repositories
$nestedRepos = Get-ChildItem -Path . -Recurse -Filter ".git" -Directory -ErrorAction SilentlyContinue | Where-Object { $_.FullName -ne (Get-Location).Path + "\.git" }
if ($nestedRepos) {
    Write-Host "Warning: Found nested git repositories. These will be skipped:" -ForegroundColor Yellow
    foreach ($repo in $nestedRepos) {
        $relativePath = $repo.Parent.FullName.Replace((Get-Location).Path, "").TrimStart("\")
        Write-Host "  - $relativePath" -ForegroundColor Yellow
    }
    Write-Host ""
}

# Stage all changes
Write-Host "Staging all changes..." -ForegroundColor Green
git add . 2>&1 | Out-Null

$stagedChanges = git diff --cached --name-only
if ([string]::IsNullOrWhiteSpace($stagedChanges)) {
    Write-Host "Error: No files were staged. This may be due to nested git repositories." -ForegroundColor Red
    Write-Host "To fix: Remove nested .git folders with: Remove-Item -Path '.\path\to\folder\.git' -Recurse -Force" -ForegroundColor Yellow
    if ($gitRoot -ne $currentPath) { Set-Location $currentPath }
    exit 1
}

# Create commit message
if ([string]::IsNullOrWhiteSpace($Message)) {
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $Message = "Auto-commit: $timestamp"
}

# --- IMPORTANT: ensure commits are attributed to your GitHub account ---
# Use your GitHub noreply email (recommended) or a verified email from GitHub Settings -> Emails.
$gitUserName  = "bartszcz"
$gitUserEmail = "156921985+bartszcz@users.noreply.github.com"

Write-Host "Setting git identity for this repo: $gitUserName <$gitUserEmail>" -ForegroundColor Green
git config user.name  $gitUserName  | Out-Null
git config user.email $gitUserEmail | Out-Null
# ----------------------------------------------------------------------

# Commit changes
Write-Host "Committing with message: $Message" -ForegroundColor Green
git commit -m $Message

if ($LASTEXITCODE -ne 0) {
    Write-Host "Error: Commit failed." -ForegroundColor Red
    if ($gitRoot -ne $currentPath) { Set-Location $currentPath }
    exit 1
}

# Push to remote
Write-Host "Pushing to GitHub..." -ForegroundColor Green
git push

if ($LASTEXITCODE -eq 0) {
    Write-Host "Successfully pushed to GitHub!" -ForegroundColor Green
} else {
    Write-Host "Error: Push failed. Check your remote configuration." -ForegroundColor Red
    if ($gitRoot -ne $currentPath) { Set-Location $currentPath }
    exit 1
}

if ($gitRoot -ne $currentPath) {
    Set-Location $currentPath
}