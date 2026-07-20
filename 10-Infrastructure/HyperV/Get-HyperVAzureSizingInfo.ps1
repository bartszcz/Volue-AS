# Get-HyperVAzureSizingInfo.ps1 - collects Hyper-V VM config + utilization as sizing input for Get-AzureVMRecommendation.ps1
# bartek / volue ito / 2026-07

# read-only, does not touch vm/disk/host state. json keeps disks nested, csv flattens them pipe-delimited.
# local:    .\Get-HyperVAzureSizingInfo.ps1
# hosts:    .\Get-HyperVAzureSizingInfo.ps1 -ComputerName HV01,HV02 -SampleUtilization -SampleDurationSeconds 120
# vm list:  .\Get-HyperVAzureSizingInfo.ps1 -ComputerName HV01,HV02 -VMName SQL01,SQL02  (each vm found on whichever host has it)
# vm csv:   .\Get-HyperVAzureSizingInfo.ps1 -VMNameCsv C:\Temp\vms.csv  (plain list: one name per line; headered csv: VMName column = vm filter, ComputerName column = host list, so a previous export of this script works as-is)
# discover: .\Get-HyperVAzureSizingInfo.ps1 -DiscoverHosts -ADHostNamePrefix 'hs' -ADServer contoso.com -Credential (Get-Credential 'DOMAIN\svc-hvadmin')
[CmdletBinding()]
param(
    [Parameter()]
    [string[]] $ComputerName = @('localhost'),

    [Parameter()]
    [switch] $DiscoverHosts,

    [Parameter()]
    [string] $ADSearchBase,

    [Parameter()]
    [string] $ADHostNamePrefix,

    [Parameter()]
    [string] $ADServer,

    [Parameter()]
    [System.Management.Automation.PSCredential] $Credential,

    [Parameter()]
    [string[]] $VMName = @('*'),

    [Parameter()]
    [string] $VMNameCsv,

    [Parameter()]
    [switch] $SampleUtilization,

    [Parameter()]
    [int] $SampleDurationSeconds = 60,

    [Parameter()]
    [int] $SampleIntervalSeconds = 5,

    [Parameter()]
    [string] $OutputPath = 'C:\Temp\Get-HyperVAzureSizingInfo'
)

# --- functions ---

function Write-SkipTips {
    # Get-VM with explicit -Credential falls back to WinRM/CredSSP (DCOM only takes the
    # current logon token) and CredSSP is off by default on clients - surface the fix once
    param([System.Collections.Generic.List[string]] $SkippedItems)
    if (($SkippedItems | Where-Object { $_ -match 'CredSSP' } | Select-Object -First 1)) {
        Write-Host "`nTip: CredSSP failures above usually mean the client needs:" -ForegroundColor Yellow
        Write-Host "  Enable-WSManCredSSP -Role Client -DelegateComputer '*.<yourdomain>'" -ForegroundColor Yellow
        Write-Host '  (run elevated; delegates your credentials to those hosts - scope the pattern narrowly)' -ForegroundColor Yellow
    }
}

function Get-EscapedLdapFilterValue {
    param([string] $Value)
    return $Value -replace '\\', '\5c' -replace '\*', '\2a' -replace '\(', '\28' -replace '\)', '\29'
}

function New-AdDirectoryEntry {
    # DirectoryEntry binds lazily and leaves .Properties $null on failure instead of throwing -
    # RefreshCache() forces the bind now so the real error surfaces here, not further down
    param([string] $Path, [System.Management.Automation.PSCredential] $Credential)
    $entry = if ($Credential) {
        $networkCred = $Credential.GetNetworkCredential()
        New-Object System.DirectoryServices.DirectoryEntry($Path, $Credential.UserName, $networkCred.Password)
    } else {
        New-Object System.DirectoryServices.DirectoryEntry($Path)
    }
    try {
        $entry.RefreshCache()
    } catch {
        throw "Could not bind to '$Path': $($_.Exception.Message)"
    }
    return $entry
}

function Find-HyperVHostsInAD {
    # every hyper-v host self-registers the "Microsoft Virtual Console Service" SPN, so this is
    # one LDAP query via plain ADSI - no RSAT needed. best-effort: a host with a missing SPN is
    # only found if -NamePrefix also matches it
    param([string] $SearchBase, [string] $NamePrefix, [string] $Server, [System.Management.Automation.PSCredential] $Credential)

    $serverSegment = if ($Server) { "$Server/" } else { '' }
    $results = $null
    try {
        $root = if ($SearchBase) {
            New-AdDirectoryEntry -Path "LDAP://$serverSegment$SearchBase" -Credential $Credential
        } else {
            $rootDse = New-AdDirectoryEntry -Path "LDAP://${serverSegment}RootDSE" -Credential $Credential
            $defaultNCProp = $rootDse.Properties['defaultNamingContext']
            if ($null -eq $defaultNCProp -or $defaultNCProp.Count -eq 0) {
                throw 'Could not contact a domain controller for the current domain (RootDSE returned no data). If this machine is not domain-joined, pass -ADServer (a DC hostname or the domain FQDN) and -Credential explicitly rather than relying on serverless discovery.'
            }
            $defaultNC = $defaultNCProp[0]
            New-AdDirectoryEntry -Path "LDAP://$serverSegment$defaultNC" -Credential $Credential
        }

        $spnClause = '(servicePrincipalName=Microsoft Virtual Console Service/*)'
        $filter = if ($NamePrefix) {
            $nameClause = "(name=$(Get-EscapedLdapFilterValue $NamePrefix)*)"
            "(&(objectCategory=computer)(|$spnClause$nameClause))"
        } else {
            "(&(objectCategory=computer)$spnClause)"
        }

        $searcher = New-Object System.DirectoryServices.DirectorySearcher($root)
        $searcher.Filter = $filter
        $searcher.PageSize = 1000
        $searcher.PropertiesToLoad.AddRange(@('dNSHostName', 'name'))

        $results = $searcher.FindAll()
        $hostNames = foreach ($result in $results) {
            $dnsProp = $result.Properties['dNSHostName']
            if ($dnsProp.Count -gt 0) { $dnsProp[0] } else { $result.Properties['name'][0] }
        }
        return @($hostNames | Where-Object { $_ } | Sort-Object -Unique)
    } catch {
        throw "Active Directory host discovery failed: $($_.Exception.Message). Verify domain connectivity/permissions, or specify -ComputerName explicitly."
    } finally {
        if ($results) { $results.Dispose() }
    }
}

function ConvertBytesToGB {
    param([Nullable[double]] $Bytes)
    if ($null -eq $Bytes) { return $null }
    return [Math]::Round($Bytes / 1GB, 2)
}

function Get-VMGuestOSInfo {
    # best-effort guest os via KVP data exchange - needs the Data Exchange integration service
    # running in the guest. returns $null fields instead of throwing so the vm isn't failed
    param(
        [Parameter(Mandatory)] [string] $Name,
        [Parameter(Mandatory)] [string] $ComputerName,
        [System.Management.Automation.PSCredential] $Credential
    )

    $result = [ordered]@{
        OSName                      = $null
        OSVersion                   = $null
        IntegrationServicesVersion  = $null
    }

    try {
        $cimParams = @{ Namespace = 'root\virtualization\v2'; ClassName = 'Msvm_ComputerSystem' }
        $cimParams.ComputerName = $ComputerName
        if ($Credential) { $cimParams.Credential = $Credential }

        $vmCim = Get-CimInstance @cimParams -Filter "ElementName='$($Name -replace "'", "''")'" -ErrorAction Stop |
            Select-Object -First 1
        if (-not $vmCim) { return $result }

        $assocParams = @{ InputObject = $vmCim; ResultClassName = 'Msvm_KvpExchangeComponent' }
        $kvpComponent = Get-CimAssociatedInstance @assocParams -ErrorAction Stop | Select-Object -First 1
        if (-not $kvpComponent) { return $result }

        $items = $kvpComponent.GuestIntrinsicExchangeItems
        if (-not $items) { return $result }

        $osName = $null
        $osVersion = $null
        $isVersion = $null

        foreach ($xmlItem in $items) {
            try {
                [xml]$doc = $xmlItem
                $nameNode = $doc.SelectSingleNode("//PROPERTY[@NAME='Name']/VALUE")
                $dataNode = $doc.SelectSingleNode("//PROPERTY[@NAME='Data']/VALUE")
                if (-not $nameNode -or -not $dataNode) { continue }

                switch ($nameNode.InnerText) {
                    'OSName'                     { $osName    = $dataNode.InnerText }
                    'OSVersion'                  { $osVersion = $dataNode.InnerText }
                    'IntegrationServicesVersion' { $isVersion = $dataNode.InnerText }
                }
            } catch {
                continue
            }
        }

        $result.OSName = $osName
        $result.OSVersion = $osVersion
        $result.IntegrationServicesVersion = $isVersion
    } catch {
        # data exchange off, older host, or access denied - leave $null, caller warns
    }

    return $result
}

function Get-VMDiskRecords {
    param(
        [Parameter(Mandatory)] $VM,
        [Parameter(Mandatory)] [string] $ComputerName,
        [System.Management.Automation.PSCredential] $Credential,
        [hashtable] $DiskIoStats
    )

    $disks = @()
    $vhdParams = @{}
    $hddParams = @{ VM = $VM }
    $vhdParams.ComputerName = $ComputerName
    if ($Credential) {
        $vhdParams.Credential = $Credential
        $hddParams.CimSession = New-CimSession -ComputerName $ComputerName -Credential $Credential -ErrorAction SilentlyContinue
    }

    $drives = Get-VMHardDiskDrive @hddParams -ErrorAction SilentlyContinue
    foreach ($drive in $drives) {
        $record = [ordered]@{
            ControllerType     = $drive.ControllerType
            ControllerNumber   = $drive.ControllerNumber
            ControllerLocation = $drive.ControllerLocation
            Path               = $drive.Path
            IsPassThrough      = ($null -ne $drive.DiskNumber)
            DiskNumber         = $drive.DiskNumber
            VhdType            = $null
            IsDifferencing     = $false
            ParentPath         = $null
            SizeGB             = $null
            FileSizeGB         = $null
            ReadIOPSAvg        = $null
            WriteIOPSAvg       = $null
            ReadThroughputMBpsAvg  = $null
            WriteThroughputMBpsAvg = $null
        }

        if (-not $record.IsPassThrough -and $drive.Path) {
            try {
                $vhd = Get-VHD -Path $drive.Path @vhdParams -ErrorAction Stop
                $record.VhdType        = [string]$vhd.VhdType
                $record.IsDifferencing = ($vhd.VhdType -eq 'Differencing')
                $record.ParentPath     = $vhd.ParentPath
                $record.SizeGB         = ConvertBytesToGB $vhd.Size
                $record.FileSizeGB     = ConvertBytesToGB $vhd.FileSize
            } catch {
                # unreadable vhd (unreachable, orphaned, permissions) - leave sizes $null, caller flags it
            }
        }

        if ($DiskIoStats -and $drive.Path -and $DiskIoStats.ContainsKey($drive.Path)) {
            $io = $DiskIoStats[$drive.Path]
            $record.ReadIOPSAvg            = $io.ReadIOPSAvg
            $record.WriteIOPSAvg           = $io.WriteIOPSAvg
            $record.ReadThroughputMBpsAvg  = $io.ReadThroughputMBpsAvg
            $record.WriteThroughputMBpsAvg = $io.WriteThroughputMBpsAvg
        }

        $disks += [pscustomobject]$record
    }

    return $disks
}

function Get-VMDiskIoStats {
    # per-disk iops/throughput from the "Hyper-V Virtual Storage Device" counters, matched to
    # vhd paths by substring - fuzzy on purpose, instance names vary by host version. fails
    # silent by design: the recommendation script treats missing iops as "unverified" anyway
    param(
        [Parameter(Mandatory)] [string] $ComputerName,
        [Parameter(Mandatory)] [string[]] $DiskPaths,
        [Parameter(Mandatory)] [int] $DurationSeconds,
        [Parameter(Mandatory)] [int] $IntervalSeconds
    )

    if (-not $DiskPaths -or $DiskPaths.Count -eq 0) { return $null }

    try {
        $maxSamples = [Math]::Max(1, [Math]::Floor($DurationSeconds / $IntervalSeconds))
        $counterSet = '\Hyper-V Virtual Storage Device(*)\*'
        $samples = Get-Counter -Counter $counterSet -ComputerName $ComputerName `
            -SampleInterval $IntervalSeconds -MaxSamples $maxSamples -ErrorAction Stop

        $byInstance = @{}
        foreach ($sampleSet in $samples) {
            foreach ($sample in $sampleSet.CounterSamples) {
                $instance = $sample.InstancePath
                if (-not $byInstance.ContainsKey($instance)) {
                    $byInstance[$instance] = [ordered]@{
                        ReadOps  = [System.Collections.Generic.List[double]]::new()
                        WriteOps = [System.Collections.Generic.List[double]]::new()
                        ReadBytes  = [System.Collections.Generic.List[double]]::new()
                        WriteBytes = [System.Collections.Generic.List[double]]::new()
                    }
                }
                if ($sample.Path -like '*read operations/sec*')  { $byInstance[$instance].ReadOps.Add($sample.CookedValue) }
                if ($sample.Path -like '*write operations/sec*') { $byInstance[$instance].WriteOps.Add($sample.CookedValue) }
                if ($sample.Path -like '*read bytes/sec*')       { $byInstance[$instance].ReadBytes.Add($sample.CookedValue) }
                if ($sample.Path -like '*write bytes/sec*')      { $byInstance[$instance].WriteBytes.Add($sample.CookedValue) }
            }
        }

        $result = @{}
        foreach ($path in $DiskPaths) {
            $baseName = [System.IO.Path]::GetFileNameWithoutExtension($path)
            $matchInstance = $byInstance.Keys | Where-Object { $_ -like "*$baseName*" } | Select-Object -First 1
            if (-not $matchInstance) { continue }

            $stats = $byInstance[$matchInstance]
            $result[$path] = [ordered]@{
                ReadIOPSAvg            = if ($stats.ReadOps.Count -gt 0) { [Math]::Round((($stats.ReadOps  | Measure-Object -Average).Average), 1) } else { $null }
                WriteIOPSAvg           = if ($stats.WriteOps.Count -gt 0) { [Math]::Round((($stats.WriteOps | Measure-Object -Average).Average), 1) } else { $null }
                ReadThroughputMBpsAvg  = if ($stats.ReadBytes.Count -gt 0) { [Math]::Round((($stats.ReadBytes  | Measure-Object -Average).Average) / 1MB, 2) } else { $null }
                WriteThroughputMBpsAvg = if ($stats.WriteBytes.Count -gt 0) { [Math]::Round((($stats.WriteBytes | Measure-Object -Average).Average) / 1MB, 2) } else { $null }
            }
        }
        return $result
    } catch {
        return $null
    }
}

# --- main ---

# module alone is enough - no local hyper-v role needed to query remote hosts
if (-not (Get-Module -ListAvailable -Name Hyper-V)) {
    throw @'
The Hyper-V PowerShell module is not installed, so Get-VM/Get-VHD/etc. are unavailable. Install it with one of:
  - Windows Server: Install-WindowsFeature -Name Hyper-V-PowerShell
  - Windows 10/11:  Enable-WindowsOptionalFeature -Online -FeatureName Microsoft-Hyper-V-Management-PowerShell -All
  - Or Settings > Optional Features > "RSAT: Hyper-V Management Tools"
Then re-run this script.
'@
}

# hyper-v remoting rejects a bare username with a cryptic 'logonName' error - warn up front
if ($Credential -and $Credential.UserName -notmatch '[\\@]') {
    Write-Warning "-Credential '$($Credential.UserName)' has no domain qualifier. Hyper-V remote connections require 'DOMAIN\user' or 'user@domain.com' and will reject a bare username for every host."
}

if ($VMNameCsv) {
    if (-not (Test-Path -LiteralPath $VMNameCsv)) { throw "VM list file not found: $VMNameCsv" }

    # headered csv first (e.g. a previous export of this script): VMName column is the vm
    # filter, ComputerName column doubles as the host list. plain list handled below.
    $csvVmNames = @()
    $csvHosts = @()
    $nameColumn = $null
    $rows = @()
    try {
        $rows = @(Import-Csv -LiteralPath $VMNameCsv -ErrorAction Stop)
    } catch {
        $rows = @()
    }
    if ($rows.Count -gt 0) {
        $columns = @($rows[0].PSObject.Properties.Name)
        foreach ($candidate in @('VMName', 'Name', 'VM')) {
            if ($columns -contains $candidate) { $nameColumn = $candidate; break }
        }
        if ($nameColumn -and ($columns -contains 'ComputerName')) {
            $csvHosts = @($rows | ForEach-Object { "$($_.ComputerName)".Trim() } | Where-Object { $_ } | Sort-Object -Unique)
        }
    }

    if ($nameColumn) {
        $csvVmNames = @($rows | ForEach-Object { "$($_.$nameColumn)".Trim() } | Where-Object { $_ })
    } else {
        try {
            # one vm name per line, wildcards allowed; takes the first column and skips blanks
            # and a header line, so both a plain list and a one-column csv with header work
            $csvVmNames = @(Get-Content -LiteralPath $VMNameCsv -ErrorAction Stop | ForEach-Object {
                ($_ -split ',')[0].Trim().Trim('"')
            } | Where-Object { $_ -and $_ -notmatch '^(vmname|vm|name)$' })
        } catch {
            throw "Could not read VM list '$VMNameCsv': $($_.Exception.Message)"
        }
    }
    if ($csvVmNames.Count -eq 0) { throw "VM list '$VMNameCsv' contained no VM names." }
    # merge with -VMName if that was also given, otherwise the csv is the whole filter
    if ($PSBoundParameters.ContainsKey('VMName')) {
        $VMName = @($VMName) + $csvVmNames
    } else {
        $VMName = $csvVmNames
    }
    Write-Host "Loaded $($csvVmNames.Count) VM name(s) from '$VMNameCsv'." -ForegroundColor Cyan

    if ($csvHosts.Count -gt 0) {
        # explicit -ComputerName or -DiscoverHosts still wins over hosts found in the csv
        if ($DiscoverHosts) {
            Write-Host 'CSV has a ComputerName column but -DiscoverHosts was given - hosts will come from AD discovery.' -ForegroundColor Cyan
        } elseif ($PSBoundParameters.ContainsKey('ComputerName')) {
            Write-Host 'CSV has a ComputerName column but -ComputerName was given explicitly - using -ComputerName.' -ForegroundColor Cyan
        } else {
            $ComputerName = $csvHosts
            Write-Host "Using $($csvHosts.Count) host(s) from the CSV ComputerName column: $($csvHosts -join ', ')" -ForegroundColor Cyan
        }
    }
}

if ($DiscoverHosts) {
    if ($PSBoundParameters.ContainsKey('ComputerName')) {
        Write-Warning "-ComputerName was also specified; ignoring it since -DiscoverHosts takes precedence."
    }
    Write-Host 'Discovering Hyper-V hosts from Active Directory (SPN-based, best-effort) ...' -ForegroundColor Cyan
    $ComputerName = Find-HyperVHostsInAD -SearchBase $ADSearchBase -NamePrefix $ADHostNamePrefix -Server $ADServer -Credential $Credential
    if (-not $ComputerName -or @($ComputerName).Count -eq 0) {
        throw 'No Hyper-V hosts discovered via AD lookup. Verify -ADSearchBase (if used), confirm hosts have registered the "Microsoft Virtual Console Service" SPN or match -ADHostNamePrefix, or specify -ComputerName explicitly.'
    }
    Write-Host "Discovered $(@($ComputerName).Count) Hyper-V host(s): $($ComputerName -join ', ')" -ForegroundColor Cyan
}

$allResults = New-Object System.Collections.Generic.List[object]
$skipped = New-Object System.Collections.Generic.List[string]
$matchedFilters = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
$queriedHostCount = 0

foreach ($computer in $ComputerName) {
    Write-Host "Querying Hyper-V host '$computer' ..." -ForegroundColor Cyan

    # get everything and filter here - Get-VM -Name with an exact name errors when the vm
    # isn't on that host, which used to skip the whole host. a specific vm only lives on
    # one host, so exact-name lists across many hosts broke
    $getVmParams = @{ ComputerName = $computer; ErrorAction = 'Stop' }
    if ($Credential) { $getVmParams.Credential = $Credential }

    try {
        $allVms = Get-VM @getVmParams
        $queriedHostCount++
    } catch {
        Write-Warning "Could not query host '$computer': $($_.Exception.Message)"
        $skipped.Add("(host) $computer - $($_.Exception.Message)")
        continue
    }

    $vms = @(foreach ($candidate in $allVms) {
        foreach ($pattern in $VMName) {
            if ($candidate.Name -like $pattern) {
                [void]$matchedFilters.Add($pattern)
                $candidate
                break
            }
        }
    })

    if ($vms.Count -eq 0) {
        Write-Host "  No matching VMs on '$computer'." -ForegroundColor DarkGray
        continue
    }

    foreach ($vm in $vms) {
        Write-Host "  Collecting '$($vm.Name)' ..." -ForegroundColor DarkGray
        $warnings = New-Object System.Collections.Generic.List[string]

        try {
            # cpu / memory demand (one snapshot unless -SampleUtilization)
            $cpuSamples = New-Object System.Collections.Generic.List[double]
            $memDemandSamples = New-Object System.Collections.Generic.List[double]

            $sampleCount = 1
            if ($SampleUtilization) {
                $sampleCount = [Math]::Max(1, [Math]::Floor($SampleDurationSeconds / $SampleIntervalSeconds))
            }

            for ($i = 0; $i -lt $sampleCount; $i++) {
                $liveVmParams = @{ ComputerName = $computer; Name = $vm.Name; ErrorAction = 'SilentlyContinue' }
                if ($Credential) { $liveVmParams.Credential = $Credential }
                $liveVm = Get-VM @liveVmParams

                if ($liveVm) {
                    $cpuSamples.Add([double]$liveVm.CPUUsage)
                    if ($liveVm.MemoryDemand) { $memDemandSamples.Add([double]$liveVm.MemoryDemand) }
                }
                if ($SampleUtilization -and $i -lt ($sampleCount - 1)) {
                    Start-Sleep -Seconds $SampleIntervalSeconds
                }
            }

            $cpuAvg = $null; $cpuMax = $null
            if ($cpuSamples.Count -gt 0) {
                $cpuAvg = [Math]::Round((($cpuSamples | Measure-Object -Average).Average), 2)
                $cpuMax = [Math]::Round((($cpuSamples | Measure-Object -Maximum).Maximum), 2)
            }

            $memDemandGB = $null
            if ($memDemandSamples.Count -gt 0) {
                $memDemandGB = ConvertBytesToGB (($memDemandSamples | Measure-Object -Maximum).Maximum)
            }

            # static memory configuration
            $vmMemory = $null
            try {
                $memParams = @{ VM = $vm; ErrorAction = 'Stop' }
                $vmMemory = Get-VMMemory @memParams
            } catch {
                $warnings.Add('Could not read VMMemory configuration.')
            }

            # generation / trusted launch inputs
            $secureBootEnabled = $null
            if ($vm.Generation -eq 2) {
                try {
                    $fw = Get-VMFirmware -VM $vm -ErrorAction Stop
                    $secureBootEnabled = ($fw.SecureBoot -eq 'On')
                } catch {
                    $warnings.Add('Could not read VM firmware (SecureBoot) state.')
                }
            }

            $tpmEnabled = $null
            try {
                $sec = Get-VMSecurity -VM $vm -ErrorAction Stop
                $tpmEnabled = [bool]$sec.TpmEnabled
            } catch {
                # Get-VMSecurity needs server 2016+ module - leave $null, "unknown" downstream
            }

            # guest os (best effort)
            $osInfo = Get-VMGuestOSInfo -Name $vm.Name -ComputerName $computer -Credential $Credential
            if (-not $osInfo.OSName) {
                $warnings.Add('Guest OS name unavailable - enable Data Exchange integration service inside the guest for endorsed-OS / Hybrid Benefit checks.')
            }

            # disks
            $diskDrivesRaw = Get-VMHardDiskDrive -VM $vm -ErrorAction SilentlyContinue
            $diskPaths = $diskDrivesRaw | Where-Object { $_.Path } | Select-Object -ExpandProperty Path
            $ioStats = $null
            if ($SampleUtilization -and $diskPaths) {
                $ioStats = Get-VMDiskIoStats -ComputerName $computer -DiskPaths $diskPaths -DurationSeconds $SampleDurationSeconds -IntervalSeconds $SampleIntervalSeconds
            }
            $disks = Get-VMDiskRecords -VM $vm -ComputerName $computer -Credential $Credential -DiskIoStats $ioStats

            if (($disks | Where-Object { $_.IsDifferencing }).Count -gt 0) {
                $warnings.Add('One or more disks are differencing disks - must be converted to fixed VHD before migration.')
            }
            if (($disks | Where-Object { $_.IsPassThrough }).Count -gt 0) {
                $warnings.Add('One or more disks are pass-through (physical) disks - must be converted to a VHD/VHDX before migration.')
            }
            if (-not $SampleUtilization) {
                $warnings.Add('Disk IOPS/throughput not sampled (run with -SampleUtilization) - IOPS-based tier selection will be unverified.')
            }

            $record = [ordered]@{
                VMName                     = $vm.Name
                ComputerName               = $computer
                State                      = [string]$vm.State
                Generation                 = $vm.Generation
                ProcessorCount             = $vm.ProcessorCount
                CPUUsagePercentCurrent     = [double]$vm.CPUUsage
                CPUUsagePercentAvg         = $cpuAvg
                CPUUsagePercentMax         = $cpuMax
                UtilizationSampled         = [bool]$SampleUtilization
                MemoryStartupGB            = if ($vmMemory) { ConvertBytesToGB $vmMemory.Startup } else { ConvertBytesToGB $vm.MemoryStartup }
                MemoryMinimumGB            = if ($vmMemory) { ConvertBytesToGB $vmMemory.Minimum } else { $null }
                MemoryMaximumGB            = if ($vmMemory) { ConvertBytesToGB $vmMemory.Maximum } else { $null }
                DynamicMemoryEnabled       = if ($vmMemory) { [bool]$vmMemory.DynamicMemoryEnabled } else { $false }
                MemoryAssignedGB           = ConvertBytesToGB $vm.MemoryAssigned
                MemoryDemandGB             = $memDemandGB
                SecureBootEnabled          = $secureBootEnabled
                TpmEnabled                 = $tpmEnabled
                GuestOSName                = $osInfo.OSName
                GuestOSVersion             = $osInfo.OSVersion
                IntegrationServicesVersion = $osInfo.IntegrationServicesVersion
                Disks                      = $disks
                Warnings                   = @($warnings)
                CollectedAt                = (Get-Date).ToString('o')
            }

            $allResults.Add([pscustomobject]$record)
        } catch {
            Write-Warning "Skipping VM '$($vm.Name)' on '$computer': $($_.Exception.Message)"
            $skipped.Add("$computer\$($vm.Name) - $($_.Exception.Message)")
        }
    }
}

if ($queriedHostCount -gt 0) {
    $unmatchedFilters = @($VMName | Where-Object { -not $matchedFilters.Contains($_) })
    if ($unmatchedFilters.Count -gt 0) {
        Write-Warning "No VM on any queried host matched: $($unmatchedFilters -join ', ')"
    }
}

if ($allResults.Count -eq 0) {
    Write-Warning 'No VM data collected. Nothing to write.'
    if ($skipped.Count -gt 0) {
        Write-Host "`nSkipped:" -ForegroundColor Yellow
        $skipped | ForEach-Object { Write-Host "  $_" -ForegroundColor Yellow }
        Write-SkipTips -SkippedItems $skipped
    }
    return
}

try {
    if (-not (Test-Path -LiteralPath $OutputPath)) {
        New-Item -ItemType Directory -Path $OutputPath -Force -ErrorAction Stop | Out-Null
    }
} catch {
    throw "Could not create output directory '$OutputPath': $($_.Exception.Message)"
}

$stamp = Get-Date -Format 'yyyyMMdd_HHmm'
$csvPath = Join-Path $OutputPath "Get-HyperVAzureSizingInfo_$stamp.csv"
$jsonPath = Join-Path $OutputPath "Get-HyperVAzureSizingInfo_$stamp.json"

$flattened = foreach ($r in $allResults) {
    $diskSizes  = ($r.Disks | ForEach-Object { $_.SizeGB })     -join '|'
    $diskUsed   = ($r.Disks | ForEach-Object { $_.FileSizeGB }) -join '|'
    $diskTypes  = ($r.Disks | ForEach-Object { $_.VhdType })    -join '|'
    $diskDiff   = ($r.Disks | ForEach-Object { $_.IsDifferencing }) -join '|'
    $diskPass   = ($r.Disks | ForEach-Object { $_.IsPassThrough })  -join '|'
    $diskPaths  = ($r.Disks | ForEach-Object { $_.Path })       -join '|'
    $diskReadIOPS  = ($r.Disks | ForEach-Object { $_.ReadIOPSAvg })  -join '|'
    $diskWriteIOPS = ($r.Disks | ForEach-Object { $_.WriteIOPSAvg }) -join '|'
    $diskReadTput  = ($r.Disks | ForEach-Object { $_.ReadThroughputMBpsAvg })  -join '|'
    $diskWriteTput = ($r.Disks | ForEach-Object { $_.WriteThroughputMBpsAvg }) -join '|'

    [pscustomobject][ordered]@{
        VMName                     = $r.VMName
        ComputerName               = $r.ComputerName
        State                      = $r.State
        Generation                 = $r.Generation
        ProcessorCount             = $r.ProcessorCount
        CPUUsagePercentCurrent     = $r.CPUUsagePercentCurrent
        CPUUsagePercentAvg         = $r.CPUUsagePercentAvg
        CPUUsagePercentMax         = $r.CPUUsagePercentMax
        UtilizationSampled         = $r.UtilizationSampled
        MemoryStartupGB            = $r.MemoryStartupGB
        MemoryMinimumGB            = $r.MemoryMinimumGB
        MemoryMaximumGB            = $r.MemoryMaximumGB
        DynamicMemoryEnabled       = $r.DynamicMemoryEnabled
        MemoryAssignedGB           = $r.MemoryAssignedGB
        MemoryDemandGB             = $r.MemoryDemandGB
        SecureBootEnabled          = $r.SecureBootEnabled
        TpmEnabled                 = $r.TpmEnabled
        GuestOSName                = $r.GuestOSName
        GuestOSVersion             = $r.GuestOSVersion
        IntegrationServicesVersion = $r.IntegrationServicesVersion
        DiskSizesGB                = $diskSizes
        DiskUsedGB                 = $diskUsed
        DiskVhdTypes               = $diskTypes
        DiskIsDifferencing         = $diskDiff
        DiskIsPassThrough          = $diskPass
        DiskPaths                  = $diskPaths
        DiskReadIOPSAvg            = $diskReadIOPS
        DiskWriteIOPSAvg           = $diskWriteIOPS
        DiskReadThroughputMBpsAvg  = $diskReadTput
        DiskWriteThroughputMBpsAvg = $diskWriteTput
        Warnings                   = ($r.Warnings -join '|')
        CollectedAt                = $r.CollectedAt
    }
}

try {
    $flattened | Export-Csv -LiteralPath $csvPath -NoTypeInformation -Encoding UTF8
    # Out-File -Encoding UTF8 writes a BOM on ps5.1 and some json readers choke on it -
    # write via .NET to skip the BOM
    $jsonContent = $allResults | ConvertTo-Json -Depth 6
    [System.IO.File]::WriteAllText($jsonPath, $jsonContent, (New-Object System.Text.UTF8Encoding($false)))
} catch {
    throw "Failed to write output files to '$OutputPath': $($_.Exception.Message)"
}

Write-Host "`nCollected $($allResults.Count) VM(s). Exported to:" -ForegroundColor Green
Write-Host "CSV  : $csvPath" -ForegroundColor Green
Write-Host "JSON : $jsonPath" -ForegroundColor Green

if ($skipped.Count -gt 0) {
    Write-Host "`nSkipped $($skipped.Count) item(s):" -ForegroundColor Yellow
    $skipped | ForEach-Object { Write-Host "  $_" -ForegroundColor Yellow }
    Write-SkipTips -SkippedItems $skipped
}

$allResults | Select-Object VMName, ComputerName, State, Generation, ProcessorCount, MemoryAssignedGB, @{N='Disks';E={$_.Disks.Count}} |
    Format-Table -AutoSize | Out-Host
