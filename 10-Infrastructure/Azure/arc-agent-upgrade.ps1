<#
.SYNOPSIS
    Upgrades Arc agent on old machines via PS Remoting (Invoke-Command). FIXED v2.
    Handles locked MSI files, lingering msiexec processes, and 1618 (installer busy) errors.
    Requires WinRM enabled on target machines (default on domain-joined servers).

.USAGE
    # Run against all machines in the CSV
    .\arc-agent-upgrade.ps1 -CsvPath .\machines.csv

    # Target specific machines only (overrides CSV)
    .\arc-agent-upgrade.ps1 -CsvPath .\machines.csv -Machines @("LBSRVFTP","LBDFS01")

    # Increase parallelism
    .\arc-agent-upgrade.ps1 -CsvPath .\machines.csv -ThrottleLimit 20

.CSV FORMAT
    Export from Resource Graph query - expects a 'name' column (agentVersion optional):
    Search-AzGraph -Query "Resources | where type == 'microsoft.hybridcompute/machines' | where properties.status == 'Connected' | extend agentVersion = tostring(properties.agentVersion) | where agentVersion != '1.61.03319.2737' | project name, agentVersion | order by agentVersion asc"
#>

param(
    [Parameter(Mandatory)][string]$CsvPath,
    [string[]]$Machines     = @(),
    [string]$LogPath        = ".\arc-agent-upgrade-$(Get-Date -Format 'yyyyMMdd-HHmmss').csv",
    [int]$ThrottleLimit     = 10
)

if (-not (Test-Path $CsvPath)) {
    Write-Error "CSV file not found: $CsvPath"
    exit 1
}

$csvData = Import-Csv -Path $CsvPath -Encoding Default
if (-not ($csvData | Get-Member -Name 'name' -MemberType NoteProperty)) {
    Write-Error "CSV must contain a 'name' column."
    exit 1
}

$allMachines = $csvData | Where-Object { $_.name -ne '' } | Select-Object -ExpandProperty name

$targets = if ($Machines.Count -gt 0) { $Machines } else { $allMachines }

$upgradeBlock = {
    $logFile  = "C:\Windows\Temp\arc-agent-upgrade.log"
    $flagFile = "C:\Windows\Temp\arc-agent-upgrade.done"
    $msiPath  = "C:\Windows\Temp\AzureConnectedMachineAgent.msi"
    $msiLog   = "C:\Windows\Temp\arc-agent-msi.log"
    $exe      = "$env:ProgramFiles\AzureConnectedMachineAgent\azcmagent.exe"

    function Log { param($m) "$(Get-Date -Format 'o') $m" | Tee-Object $logFile -Append | Write-Output }

    # Check current version - skip if already on latest
    $currentVer = if (Test-Path $exe) { (& $exe version 2>&1) -replace 'azcmagent version\s+','' } else { "unknown" }
    Log "Current version: $currentVer"

    if ($currentVer -match "1\.61\.") {
        Log "Already on 1.61 - skipping."
        "$(Get-Date -Format 'o') already current" | Out-File $flagFile
        return "SKIPPED:already on $currentVer"
    }

    if (Test-Path $flagFile) {
        Log "Flag file present - skipping."
        return "SKIPPED:flag file exists"
    }

    # Kill any lingering msiexec from previous attempts (SYSTEM session only)
    $linger = Get-Process -Name msiexec -ErrorAction SilentlyContinue |
              Where-Object { $_.SessionId -eq 0 }
    if ($linger) {
        Log "Killing $($linger.Count) lingering msiexec process(es)..."
        $linger | Stop-Process -Force -ErrorAction SilentlyContinue
        Start-Sleep -Seconds 5
    }

    # Release and delete any locked MSI file from previous attempts
    if (Test-Path $msiPath) {
        $retries = 0
        while ((Test-Path $msiPath) -and $retries -lt 10) {
            try {
                Remove-Item $msiPath -Force -ErrorAction Stop
                Log "Removed leftover MSI."
                break
            } catch {
                Log "MSI still locked, waiting 5s... ($retries/10)"
                Start-Sleep -Seconds 5
                $retries++
            }
        }
        if (Test-Path $msiPath) {
            Log "ERROR: could not remove locked MSI after 10 retries"
            return "ERROR:MSI file locked - manual cleanup needed on this machine"
        }
    }
    Remove-Item $msiLog -Force -ErrorAction SilentlyContinue

    # Download latest MSI from Microsoft
    Log "Downloading MSI..."
    try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        Invoke-WebRequest -Uri "https://aka.ms/AzureConnectedMachineAgent" `
                          -OutFile $msiPath -UseBasicParsing -TimeoutSec 120
        Log "MSI downloaded ($([Math]::Round((Get-Item $msiPath).Length/1MB,1)) MB)"
    } catch {
        Log "ERROR downloading: $_"
        return "ERROR:download failed - $_"
    }

    # Install - retry up to 5 times if Windows Installer is busy (exit 1618)
    $wiRetries = 0
    do {
        $proc = Start-Process msiexec.exe `
                    -ArgumentList "/i `"$msiPath`" /qn /l*v `"$msiLog`"" `
                    -Wait -PassThru
        if ($proc.ExitCode -eq 1618) {
            Log "Windows Installer busy (1618), waiting 30s before retry... ($wiRetries/5)"
            Start-Sleep -Seconds 30
            $wiRetries++
        }
    } while ($proc.ExitCode -eq 1618 -and $wiRetries -lt 5)

    Log "msiexec exit: $($proc.ExitCode)"

    if ($proc.ExitCode -notin 0, 3010) {
        Log "ERROR: install failed (exit $($proc.ExitCode))"
        return "ERROR:msiexec exit $($proc.ExitCode)"
    }

    # Wait for agent service to restart
    Start-Sleep -Seconds 15

    # Verify new version
    $newVer = if (Test-Path $exe) { (& $exe version 2>&1) } else { "unknown" }
    Log "Upgrade complete. New version: $newVer"

    # Drop flag so script won't re-run on this machine
    "$(Get-Date -Format 'o') done" | Out-File $flagFile

    # Cleanup
    Remove-Item $msiPath -Force -ErrorAction SilentlyContinue

    return "SUCCESS:$newVer"
}

function Write-Log {
    param([string]$Msg, [string]$Level = "INFO")
    Write-Host "[$(Get-Date -Format 'HH:mm:ss')][$Level] $Msg"
}

Write-Log "Starting parallel upgrade on $($targets.Count) machines (throttle: $ThrottleLimit)..."

$jobs = Invoke-Command -ComputerName $targets `
                       -ScriptBlock $upgradeBlock `
                       -ThrottleLimit $ThrottleLimit `
                       -AsJob

Write-Log "All jobs dispatched - waiting for results..."

# Stream results as they complete
$completed = @{}
while ($jobs.ChildJobs | Where-Object State -in "Running","NotStarted") {
    foreach ($child in ($jobs.ChildJobs | Where-Object { $_.State -eq "Completed" -and $_.Location -notin $completed.Keys })) {
        $output = Receive-Job $child
        $completed[$child.Location] = $output
        $level = if ($output -match "^SUCCESS|^SKIPPED") { "INFO" } else { "WARN" }
        Write-Log "$($child.Location): $output" $level
    }
    Start-Sleep -Seconds 5
}

# Catch any remaining (failed or timed out)
foreach ($child in ($jobs.ChildJobs | Where-Object { $_.Location -notin $completed.Keys })) {
    $output = if ($child.State -eq "Failed") {
        "ERROR:$($child.JobStateInfo.Reason.Message)"
    } else {
        Receive-Job $child
    }
    $completed[$child.Location] = $output
    Write-Log "$($child.Location): $output" $(if ($output -match "^SUCCESS|^SKIPPED") { "INFO" } else { "WARN" })
}

Remove-Job $jobs -Force

# Write CSV log
$results = $completed.GetEnumerator() | ForEach-Object {
    [PSCustomObject]@{
        MachineName = $_.Key
        Outcome     = ($_.Value -split ":")[0]
        Detail      = ($_.Value -split ":",2)[1]
        Timestamp   = (Get-Date -Format "o")
    }
}

$results | Export-Csv -Path $LogPath -NoTypeInformation -Encoding UTF8

$success = ($results | Where-Object Outcome -eq "SUCCESS").Count
$skipped = ($results | Where-Object Outcome -eq "SKIPPED").Count
$errors  = ($results | Where-Object Outcome -eq "ERROR").Count

Write-Log "------- Complete -------"
Write-Log "SUCCESS : $success"
Write-Log "SKIPPED : $skipped"
Write-Log "ERRORS  : $errors"
Write-Log "Log     : $LogPath"

if ($errors -gt 0) {
    Write-Log "Failed machines:" "WARN"
    $results | Where-Object Outcome -eq "ERROR" |
        ForEach-Object { Write-Log "  - $($_.MachineName): $($_.Detail)" "WARN" }
}