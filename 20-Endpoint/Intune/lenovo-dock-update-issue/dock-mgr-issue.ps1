$detected = $false
$findings = New-Object System.Collections.Generic.List[string]

# --- Helper: safe write
function Add-Finding($text) {
    if (-not $findings.Contains($text)) { $findings.Add($text) }
}

# 1) Check for known updater binary
$updaterPath = "C:\Program Files\Lenovo\Dock Manager\dockmgr.schd.exe"
if (Test-Path $updaterPath) {
    $detected = $true
    Add-Finding "UpdaterBinary"
}

# 2) Check scheduled tasks (focused)
try {
    $tasks = Get-ScheduledTask -ErrorAction Stop | Where-Object {
        ($_.TaskName -match "Dock" -or $_.TaskName -match "DockManager" -or $_.TaskName -match "dockmgr" -or $_.TaskPath -match "Lenovo")
    }

    if ($tasks) {
        $detected = $true
        Add-Finding "ScheduledTask"
    }
} catch {
    # If tasks can't be queried (rare), don't fail the script; just note it
    Add-Finding "ScheduledTaskQueryFailed"
}

# 3) Check likely services only (avoid Get-Service on everything)
# If you know exact names, replace this list with the real ones after one manual check.
$serviceNameHints = @(
    "Dock", "DockManager", "dockmgr", "LenovoDock", "LenovoDockManager"
)

foreach ($hint in $serviceNameHints) {
    try {
        $svcs = Get-Service -Name "*$hint*" -ErrorAction SilentlyContinue
        foreach ($svc in $svcs) {
            if ($svc.StartType -eq "Automatic") {
                $detected = $true
                Add-Finding "AutoService:$($svc.Name)"
            }
        }
    } catch {
        # ignore
    }
}

if ($detected) {
    Write-Output ("Dock Manager auto-update components detected: " + ($findings -join ", "))
    exit 1
}

Write-Output "Dock Manager auto-update components not detected"
exit 0
