# Arc Agent Upgrade Script

Upgrades the Azure Connected Machine Agent (Arc agent) on multiple machines in parallel via PowerShell Remoting (`Invoke-Command`). Handles common installer failure modes including locked MSI files, lingering `msiexec` processes, and Windows Installer busy errors (exit 1618).

## Requirements

- WinRM enabled on all target machines (default on domain-joined servers)
- PowerShell remoting access to targets
- `Az.ResourceGraph` module if using the Resource Graph query to generate the CSV

## Parameters

| Parameter | Required | Default | Description |
|-----------|----------|---------|-------------|
| `-CsvPath` | Yes | — | Path to CSV file containing machines to upgrade |
| `-Machines` | No | `@()` | Override list of machine names; skips CSV machine list |
| `-LogPath` | No | `.\arc-agent-upgrade-<timestamp>.csv` | Path for the output results CSV |
| `-ThrottleLimit` | No | `10` | Max number of parallel remote jobs |

## CSV Format

The CSV must contain a `name` column. The easiest way to generate it is by exporting the Resource Graph query below directly to CSV.

```
name,agentVersion
LBDFS01,1.45.02345.1234
LBHV01,1.50.02567.1234
```

### Resource Graph Query

Run in Azure Portal (Resource Graph Explorer) or via PowerShell to get all connected Arc machines not yet on the target version:

```kusto
Resources
| where type == 'microsoft.hybridcompute/machines'
| where properties.status == 'Connected'
| extend agentVersion = tostring(properties.agentVersion)
| where agentVersion != '1.61.03319.2737'
| project name, agentVersion
| order by agentVersion asc
```

```powershell
Search-AzGraph -Query "Resources | where type == 'microsoft.hybridcompute/machines' | where properties.status == 'Connected' | extend agentVersion = tostring(properties.agentVersion) | where agentVersion != '1.61.03319.2737' | project name, agentVersion | order by agentVersion asc" | Export-Csv .\machines.csv -NoTypeInformation
```

## Usage

```powershell
# Run against all machines in the CSV
.\arc-agent-upgrade.ps1 -CsvPath .\machines.csv

# Target specific machines only (overrides CSV list)
.\arc-agent-upgrade.ps1 -CsvPath .\machines.csv -Machines @("LBSRVFTP","LBDFS01")

# Increase parallelism and custom log path
.\arc-agent-upgrade.ps1 -CsvPath .\machines.csv -ThrottleLimit 20 -LogPath .\results.csv
```

## How It Works

1. Imports the machine list from the CSV (`name` column)
2. Dispatches parallel `Invoke-Command` jobs (one per machine) up to `-ThrottleLimit`
3. On each machine the remote block:
   - Checks the current agent version — skips if already on `1.61.x`
   - Skips if a flag file (`C:\Windows\Temp\arc-agent-upgrade.done`) exists
   - Kills any lingering `msiexec` processes in session 0
   - Removes any leftover locked MSI from a previous attempt (retries 10×)
   - Downloads the latest MSI from `https://aka.ms/AzureConnectedMachineAgent`
   - Installs silently with `msiexec /qn`, retrying up to 5× on error 1618
   - Verifies the new version and writes the flag file
4. Results are streamed to the console as jobs complete
5. A summary CSV is written to `-LogPath` on completion

## Output

### Console

```
[14:22:01][INFO] Starting parallel upgrade on 52 machines (throttle: 10)...
[14:22:01][INFO] All jobs dispatched - waiting for results...
[14:22:45][INFO] LBDFS01: SUCCESS:azcmagent version 1.61.03319.2737
[14:22:48][WARN] MSSQL01: ERROR:msiexec exit 1603
```

### Results CSV

| Column | Description |
|--------|-------------|
| `MachineName` | Target machine name |
| `Outcome` | `SUCCESS`, `SKIPPED`, or `ERROR` |
| `Detail` | New version string, skip reason, or error message |
| `Timestamp` | ISO 8601 timestamp of result |

## Flag File

On successful upgrade, the script writes `C:\Windows\Temp\arc-agent-upgrade.done` on the remote machine. Re-running the script will skip that machine unless the file is removed.

## Troubleshooting

| Symptom | Likely Cause | Resolution |
|---------|-------------|------------|
| `ERROR:MSI file locked` | Previous failed install left MSI open | Kill `msiexec` manually on the target and delete `C:\Windows\Temp\AzureConnectedMachineAgent.msi` |
| `ERROR:msiexec exit 1603` | General install failure | Check `C:\Windows\Temp\arc-agent-msi.log` on the target machine |
| `ERROR:download failed` | No internet access from the machine | Ensure outbound HTTPS to `aka.ms` is allowed |
| Job never completes | WinRM not reachable | Verify `Test-WSMan <machine>` succeeds from the management host |
