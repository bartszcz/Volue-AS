# decommissions a vm deployed by vm-deploy.ps1: backup protection (with recovery points), cpu alert,
# action group, auto-shutdown schedule, the vm itself, nics, disks and public ips
# vnet, nsg and the recovery vault are left alone (may be shared) unless -DeleteResourceGroup is used
# -DryRun shows what would happen without changing anything; normal run asks y/n before each change

param(
    [string]$VMName,
    [string]$SubscriptionName,
    [string]$ResourceGroupName,       # empty = rg-<vmname> convention from vm-deploy.ps1
    [bool]$DeleteResourceGroup = $false,  # nuke the whole rg after backup is disabled
    [switch]$DryRun,
    [string]$OutputPath = "C:\Temp\vm-delete"
)

# --- settings ---
$TenantId        = "9ce76d42-5ecb-4d8f-939b-a462ad28cf34"
$RequiredModules = @("Az.Accounts", "Az.Resources", "Az.Compute", "Az.Network", "Az.RecoveryServices")

# --- functions ---

function Confirm-Action ($Description) {
    if ($DryRun) {
        Write-Host "DRY RUN: would $Description" -ForegroundColor Yellow
        $script:Summary += [pscustomobject]@{ Action = "dry run"; Item = $Description }
        return $false
    }
    $Answer = Read-Host "Confirm: ${Description}? (y/n)"
    if ($Answer -match "^[Yy]") { return $true }
    $script:Summary += [pscustomobject]@{ Action = "skipped"; Item = $Description }
    return $false
}

function Read-Required ($Prompt) {
    while ($true) {
        $Answer = Read-Host $Prompt
        if (-not [string]::IsNullOrWhiteSpace($Answer)) { return $Answer.Trim() }
        Write-Host "A value is required here" -ForegroundColor Yellow
    }
}

function Read-Value ($Prompt, $Default) {
    if ("$Default" -ne "") { $Answer = Read-Host "$Prompt [$Default]" } else { $Answer = Read-Host $Prompt }
    if ([string]::IsNullOrWhiteSpace($Answer)) { return $Default }
    return $Answer.Trim()
}

function Read-Choice ($Prompt, $Options, $DefaultIndex) {
    Write-Host $Prompt
    for ($i = 0; $i -lt $Options.Count; $i++) { Write-Host ("  {0}. {1}" -f ($i + 1), $Options[$i]) }
    while ($true) {
        $Answer = Read-Host "Choice 1-$($Options.Count) [$($DefaultIndex + 1)]"
        if ([string]::IsNullOrWhiteSpace($Answer)) { return $Options[$DefaultIndex] }
        $Num = 0
        if ([int]::TryParse($Answer, [ref]$Num) -and $Num -ge 1 -and $Num -le $Options.Count) { return $Options[$Num - 1] }
        Write-Host "Pick a number between 1 and $($Options.Count)" -ForegroundColor Yellow
    }
}

# --- main ---

$Summary = @()

foreach ($Module in $RequiredModules) {
    if (-not (Get-Module -ListAvailable -Name $Module)) {
        Write-Error "Module $Module is not installed. Install it first (Install-Module $Module)."
        return
    }
}

$Context = Get-AzContext
if (-not $Context -or $Context.Tenant.Id -ne $TenantId) {
    Write-Host "Connecting to Azure..."
    try {
        Connect-AzAccount -TenantId $TenantId -SkipContextPopulation -ErrorAction Stop | Out-Null
    } catch {
        Write-Error "Login failed: $($_.Exception.Message)"
        return
    }
}

if (-not $PSBoundParameters.ContainsKey("SubscriptionName")) {
    try {
        $Subs = @(Get-AzSubscription -TenantId $TenantId -ErrorAction Stop | Sort-Object Name)
    } catch {
        Write-Error "Listing subscriptions failed: $($_.Exception.Message)"
        return
    }
    if ($Subs.Count -eq 0) { Write-Error "No subscriptions visible in tenant $TenantId"; return }
    if ($Subs.Count -eq 1) { $SubscriptionName = $Subs[0].Name }
    else { $SubscriptionName = Read-Choice "Subscription:" @($Subs | ForEach-Object { $_.Name }) 0 }
}

try {
    Set-AzContext -Subscription $SubscriptionName -Tenant $TenantId -ErrorAction Stop | Out-Null
} catch {
    Write-Error "Subscription selection failed: $($_.Exception.Message)"
    return
}
$SubId = (Get-AzContext).Subscription.Id
Write-Host "Using subscription '$SubscriptionName' ($SubId)"

if (-not $VMName)            { $VMName = Read-Required "VM name to delete" }
if (-not $ResourceGroupName) { $ResourceGroupName = Read-Value "Resource group" "rg-$VMName" }

if ($DryRun) { Write-Host "Dry run - nothing will be changed" -ForegroundColor Yellow }

$VM = Get-AzVM -ResourceGroupName $ResourceGroupName -Name $VMName -ErrorAction SilentlyContinue
if (-not $VM) {
    Write-Error "VM $VMName not found in resource group $ResourceGroupName."
    return
}

# collect what belongs to the vm before anything is removed
$NicIds  = @($VM.NetworkProfile.NetworkInterfaces | ForEach-Object { $_.Id })
$DiskNames = @($VM.StorageProfile.OsDisk.Name)
$DiskNames += @($VM.StorageProfile.DataDisks | ForEach-Object { $_.Name })
$PipIds = @()
$Nics   = @()
foreach ($NicId in $NicIds) {
    $NicName = ($NicId -split "/")[-1]
    $NicRg   = ($NicId -split "/")[4]
    $NicObj  = Get-AzNetworkInterface -Name $NicName -ResourceGroupName $NicRg -ErrorAction SilentlyContinue
    if ($NicObj) {
        $Nics += $NicObj
        $PipIds += @($NicObj.IpConfigurations | Where-Object { $_.PublicIpAddress } | ForEach-Object { $_.PublicIpAddress.Id })
    }
}

Write-Host ""
Write-Host "Found for ${VMName}:"
Write-Host "  disks: $($DiskNames -join ', ')"
Write-Host "  nics:  $(@($Nics | ForEach-Object { $_.Name }) -join ', ')"
if ($PipIds.Count -gt 0) { Write-Host "  public ips: $(@($PipIds | ForEach-Object { ($_ -split '/')[-1] }) -join ', ')" }

# backup first - a protected vm blocks disk cleanup and the vault
try {
    $BackupStatus = Get-AzRecoveryServicesBackupStatus -Name $VMName -ResourceGroupName $ResourceGroupName -Type AzureVM -ErrorAction Stop
} catch {
    Write-Error "Backup status check failed: $($_.Exception.Message)"
    return
}
if ($BackupStatus.BackedUp) {
    $Vault = Get-AzRecoveryServicesVault | Where-Object { $_.ID -eq $BackupStatus.VaultId } | Select-Object -First 1
    if (-not $Vault) {
        Write-Error "VM is backed up but the vault ($($BackupStatus.VaultId)) is not visible to you."
        return
    }
    if (Confirm-Action "stop backup for $VMName in vault $($Vault.Name) and DELETE all recovery points") {
        try {
            $Container = Get-AzRecoveryServicesBackupContainer -ContainerType AzureVM -FriendlyName $VMName -VaultId $Vault.ID -ErrorAction Stop
            $Item = Get-AzRecoveryServicesBackupItem -Container $Container -WorkloadType AzureVM -VaultId $Vault.ID -ErrorAction Stop
            Disable-AzRecoveryServicesBackupProtection -Item $Item -VaultId $Vault.ID -RemoveRecoveryPoints -Force -ErrorAction Stop | Out-Null
            Write-Host "Backup stopped, recovery points removed"
            Write-Warning "Vault soft delete keeps the backup data for ~14 days - the vault itself cannot be deleted until that expires."
            $Summary += [pscustomobject]@{ Action = "removed"; Item = "backup protection for $VMName" }
        } catch {
            Write-Error "Disabling backup failed: $($_.Exception.Message)"
            return
        }
    }
} else {
    Write-Host "VM is not backed up, nothing to disable"
}

# whole rg mode - backup is handled above, the rest goes with the group
if ($DeleteResourceGroup) {
    $ResCount = @(Get-AzResource -ResourceGroupName $ResourceGroupName -ErrorAction SilentlyContinue).Count
    if (Confirm-Action "DELETE THE WHOLE resource group $ResourceGroupName with $ResCount resources") {
        try {
            Remove-AzResourceGroup -Name $ResourceGroupName -Force -ErrorAction Stop | Out-Null
            Write-Host "Resource group $ResourceGroupName deleted"
            $Summary += [pscustomobject]@{ Action = "deleted"; Item = "resource group $ResourceGroupName" }
        } catch {
            Write-Error "Deleting resource group failed (a vault with soft-deleted backup data blocks this for ~14 days): $($_.Exception.Message)"
            return
        }
    }
} else {
    # auto-shutdown schedule
    $ScheduleId = "/subscriptions/$SubId/resourceGroups/$ResourceGroupName/providers/microsoft.devtestlab/schedules/shutdown-computevm-$VMName"
    if (Get-AzResource -ResourceId $ScheduleId -ErrorAction SilentlyContinue) {
        if (Confirm-Action "delete auto-shutdown schedule for $VMName") {
            try {
                Remove-AzResource -ResourceId $ScheduleId -ApiVersion "2018-09-15" -Force -ErrorAction Stop | Out-Null
                Write-Host "Auto-shutdown schedule deleted"
                $Summary += [pscustomobject]@{ Action = "deleted"; Item = "auto-shutdown schedule" }
            } catch {
                Write-Error "Deleting schedule failed: $($_.Exception.Message)"
                return
            }
        }
    }

    # cpu alert + action group, only when Az.Monitor is around
    if (Get-Module -ListAvailable -Name Az.Monitor) {
        $AlertName = "alert-$VMName-cpu"
        if (Get-AzMetricAlertRuleV2 -ResourceGroupName $ResourceGroupName -Name $AlertName -ErrorAction SilentlyContinue) {
            if (Confirm-Action "delete cpu alert $AlertName") {
                try {
                    Remove-AzMetricAlertRuleV2 -ResourceGroupName $ResourceGroupName -Name $AlertName -ErrorAction Stop | Out-Null
                    Write-Host "CPU alert deleted"
                    $Summary += [pscustomobject]@{ Action = "deleted"; Item = "cpu alert $AlertName" }
                } catch {
                    Write-Error "Deleting alert failed: $($_.Exception.Message)"
                    return
                }
            }
        }
        $AgName = "ag-$VMName"
        if (Get-AzActionGroup -ResourceGroupName $ResourceGroupName -Name $AgName -ErrorAction SilentlyContinue) {
            if (Confirm-Action "delete action group $AgName") {
                try {
                    Remove-AzActionGroup -ResourceGroupName $ResourceGroupName -Name $AgName -ErrorAction Stop | Out-Null
                    Write-Host "Action group deleted"
                    $Summary += [pscustomobject]@{ Action = "deleted"; Item = "action group $AgName" }
                } catch {
                    Write-Error "Deleting action group failed: $($_.Exception.Message)"
                    return
                }
            }
        }
    }

    # vm, then nics, then pips and disks
    if (Confirm-Action "delete vm $VMName") {
        try {
            Remove-AzVM -ResourceGroupName $ResourceGroupName -Name $VMName -Force -ErrorAction Stop | Out-Null
            Write-Host "VM $VMName deleted"
            $Summary += [pscustomobject]@{ Action = "deleted"; Item = "vm $VMName" }
        } catch {
            Write-Error "Deleting vm failed: $($_.Exception.Message)"
            return
        }

        foreach ($NicObj in $Nics) {
            try {
                Remove-AzNetworkInterface -Name $NicObj.Name -ResourceGroupName $NicObj.ResourceGroupName -Force -ErrorAction Stop
                Write-Host "NIC $($NicObj.Name) deleted"
                $Summary += [pscustomobject]@{ Action = "deleted"; Item = "nic $($NicObj.Name)" }
            } catch {
                Write-Error "Deleting nic $($NicObj.Name) failed: $($_.Exception.Message)"
                return
            }
        }

        foreach ($PipId in $PipIds) {
            $PipName = ($PipId -split "/")[-1]
            $PipRg   = ($PipId -split "/")[4]
            try {
                Remove-AzPublicIpAddress -Name $PipName -ResourceGroupName $PipRg -Force -ErrorAction Stop
                Write-Host "Public ip $PipName deleted"
                $Summary += [pscustomobject]@{ Action = "deleted"; Item = "public ip $PipName" }
            } catch {
                Write-Error "Deleting public ip $PipName failed: $($_.Exception.Message)"
                return
            }
        }

        foreach ($DiskName in $DiskNames) {
            if (-not $DiskName) { continue }
            try {
                Remove-AzDisk -ResourceGroupName $ResourceGroupName -DiskName $DiskName -Force -ErrorAction Stop | Out-Null
                Write-Host "Disk $DiskName deleted"
                $Summary += [pscustomobject]@{ Action = "deleted"; Item = "disk $DiskName" }
            } catch {
                Write-Error "Deleting disk $DiskName failed: $($_.Exception.Message)"
                return
            }
        }
    }
    Write-Host "Left in place (may be shared): vnet, nsg, recovery vault, bastion. Use -DeleteResourceGroup to remove everything."
}

Write-Host ""
Write-Host "Summary:"
if ($Summary.Count -gt 0) {
    $Summary | Format-Table -Property Action, Item -AutoSize -Wrap | Out-String -Width 200 | Write-Host
    try {
        if (-not (Test-Path $OutputPath)) { New-Item -ItemType Directory -Path $OutputPath -Force | Out-Null }
        $Stamp    = Get-Date -Format "yyyyMMdd_HHmm"
        $JsonFile = Join-Path $OutputPath "vm-delete_${VMName}_$Stamp.json"
        $CsvFile  = Join-Path $OutputPath "vm-delete_${VMName}_$Stamp.csv"
        # -InputObject keeps a single entry as a json array
        ConvertTo-Json -InputObject $Summary | Out-File -FilePath $JsonFile -Encoding utf8
        $Summary | Export-Csv -Path $CsvFile -NoTypeInformation -Encoding utf8
        Write-Host "Summary written to $JsonFile and $CsvFile"
    } catch {
        Write-Warning "Could not write summary files to ${OutputPath}: $($_.Exception.Message)"
    }
} else {
    Write-Host "Nothing to report."
}

if ($DryRun) { Write-Host "Dry run complete. Nothing was changed." -ForegroundColor Yellow } else { Write-Host "Done." }
