# Git Diagnosis Script
# Run this to figure out why files aren't being staged/pushed

Write-Host "=== GIT DIAGNOSIS ===" -ForegroundColor Cyan
Write-Host ""

# 1. Where are we?
Write-Host "[1] Current directory:" -ForegroundColor Yellow
Write-Host "    $(Get-Location)"
Write-Host ""

# 2. Is this a git repo?
Write-Host "[2] Git repo check:" -ForegroundColor Yellow
if (Test-Path ".git") {
    Write-Host "    .git folder EXISTS here" -ForegroundColor Green
} else {
    Write-Host "    NO .git folder here - not a git root!" -ForegroundColor Red
    Write-Host "    Searching upward..." -ForegroundColor Yellow
    $p = Get-Location
    while ($p) {
        $parent = Split-Path $p -Parent
        if ($parent -eq $p) { Write-Host "    No git repo found in any parent." -ForegroundColor Red; break }
        $p = $parent
        if (Test-Path (Join-Path $p ".git")) { Write-Host "    Found .git at: $p" -ForegroundColor Green; break }
    }
}
Write-Host ""

# 3. Git remote
Write-Host "[3] Remote configuration:" -ForegroundColor Yellow
git remote -v
Write-Host ""

# 4. Current branch
Write-Host "[4] Current branch:" -ForegroundColor Yellow
git branch --show-current
Write-Host ""

# 5. git status (raw)
Write-Host "[5] git status --porcelain (raw):" -ForegroundColor Yellow
$raw = git status --porcelain
if ([string]::IsNullOrWhiteSpace($raw)) {
    Write-Host "    (empty - nothing to commit)" -ForegroundColor Red
} else {
    $raw -split "`n" | ForEach-Object { Write-Host "    $_" }
}
Write-Host ""

# 6. git status (human)
Write-Host "[6] git status (full):" -ForegroundColor Yellow
git status
Write-Host ""

# 7. Check .gitignore for anything suspicious
Write-Host "[7] .gitignore contents (if exists):" -ForegroundColor Yellow
if (Test-Path ".gitignore") {
    Get-Content ".gitignore" | ForEach-Object { Write-Host "    $_" }
} else {
    Write-Host "    No .gitignore found"
}
Write-Host ""

# 8. Check if files are tracked at all
Write-Host "[8] Total tracked files in repo:" -ForegroundColor Yellow
$tracked = git ls-files | Measure-Object
Write-Host "    $($tracked.Count) files currently tracked"
Write-Host ""

# 9. Check for OneDrive attribute issues (common problem!)
Write-Host "[9] OneDrive sync check:" -ForegroundColor Yellow
Write-Host "    Path contains 'OneDrive': $(if ((Get-Location).Path -like '*OneDrive*') { 'YES - this may cause issues!' } else { 'No' })" -ForegroundColor $(if ((Get-Location).Path -like '*OneDrive*') { 'Red' } else { 'Green' })
Write-Host ""

# 10. File attribute check - OneDrive 'offline' files show as present but have no local content
Write-Host "[10] Checking for cloud-only (offline) files in root:" -ForegroundColor Yellow
$cloudFiles = Get-ChildItem -Path . -File -Force | Where-Object {
    $_.Attributes -band [System.IO.FileAttributes]::Offline
}
if ($cloudFiles.Count -gt 0) {
    Write-Host "    WARNING: Found $($cloudFiles.Count) cloud-only files Git cannot read:" -ForegroundColor Red
    $cloudFiles | ForEach-Object { Write-Host "    - $($_.Name)" -ForegroundColor Red }
} else {
    Write-Host "    No cloud-only files detected in root" -ForegroundColor Green
}
Write-Host ""

Write-Host "=== END DIAGNOSIS ===" -ForegroundColor Cyan