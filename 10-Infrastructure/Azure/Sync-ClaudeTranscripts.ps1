<#
.SYNOPSIS
    Mirrors recent Claude Code session transcripts to an unprotected staging
    folder so the Cowork "weekly-knowledge-powershell-harvest" task can read
    them (Cowork cannot mount %USERPROFILE%\.claude\ - protected location).
.NOTES
    PowerShell 5.1 compatible. Read-only on source. Idempotent.
    Copies only projects\*.jsonl - never touches credentials or settings.
#>

$Source     = Join-Path $env:USERPROFILE ".claude\projects"
$Staging    = "C:\Temp\claude-transcripts"
$LogDir     = "C:\Temp\Sync-ClaudeTranscripts"
$LogFile    = Join-Path $LogDir "sync.log"
$MaxAgeDays = 8
$RetainDays = 14

foreach ($dir in @($Staging, $LogDir)) {
    if (-not (Test-Path $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }
}

if (-not (Test-Path $Source)) {
    Add-Content $LogFile "$(Get-Date -Format s) SKIP - source missing: $Source"
    exit 0
}

robocopy $Source $Staging *.jsonl /S /MAXAGE:$MaxAgeDays /R:2 /W:5 /NP /NDL /NJH "/LOG+:$LogFile"

if ($LASTEXITCODE -ge 8) {
    Add-Content $LogFile "$(Get-Date -Format s) ERROR - robocopy exit code $LASTEXITCODE"
    exit 1
} else {
    Add-Content $LogFile "$(Get-Date -Format s) OK - robocopy exit code $LASTEXITCODE"
}

$cutoff = (Get-Date).AddDays(-$RetainDays)
Get-ChildItem -Path $Staging -Filter *.jsonl -Recurse -File |
    Where-Object { $_.LastWriteTime -lt $cutoff } |
    Remove-Item -Force

Get-ChildItem -Path $Staging -Recurse -Directory |
    Sort-Object FullName -Descending |
    Where-Object { @(Get-ChildItem -LiteralPath $_.FullName -Force).Count -eq 0 } |
    Remove-Item -Force

exit 0
