<#
.SYNOPSIS
    Collects Hyper-V VM configuration and (optionally) utilization data as input for
    Azure VM sizing/cost estimation (see Get-AzureVMRecommendation.ps1).

.DESCRIPTION
    Enumerates VMs on one or more Hyper-V hosts and captures the fields needed to size
    an equivalent Azure VM: vCPU count, memory configuration (static + dynamic +
    live demand), per-disk provisioned/used size and type (including differencing and
    pass-through disk detection), Generation/SecureBoot/vTPM (Trusted Launch inputs),
    and best-effort guest OS identification via KVP data exchange.

    Utilization (CPU %, memory demand, disk IOPS/throughput) is a point-in-time read by
    default. Pass -SampleUtilization to poll repeatedly over a window and record
    average/max, which produces a much more reliable sizing input than a single sample.

    Output is written as both CSV and JSON (same dual-output pattern used elsewhere in
    this repo). The JSON file preserves each VM's disks as a nested array; the CSV
    flattens disks into pipe-delimited columns (DiskSizesGB, DiskUsedGB, etc.) since CSV
    has no native concept of a nested array. Get-AzureVMRecommendation.ps1's loader
    understands both shapes.

    Read-only: this script does not modify any VM, disk, or host state.

.PARAMETER ComputerName
    One or more Hyper-V host names to query. Defaults to the local computer. Ignored (with a
    warning) if -DiscoverHosts is also supplied.

.PARAMETER DiscoverHosts
    Instead of specifying -ComputerName, discover Hyper-V hosts by querying Active Directory
    for computer accounts that have registered the "Microsoft Virtual Console Service" SPN -
    every Hyper-V host registers this automatically when the role/VMMS service starts. Uses
    built-in ADSI, no RSAT/ActiveDirectory module required. This is best-effort: a host whose
    SPN registration failed or was removed (e.g. by GPO restricting computer self-write) will
    not be found this way - cross-check the discovered count against your known inventory.

.PARAMETER ADSearchBase
    Optional LDAP distinguished name (e.g. 'OU=HyperV,OU=Servers,DC=contoso,DC=com') to scope
    -DiscoverHosts to a specific OU instead of the whole domain. Ignored without -DiscoverHosts.

.PARAMETER ADHostNamePrefix
    Optional computer-name prefix (e.g. 'hs' to match hs01, hs02, ...) widening -DiscoverHosts
    to also match on name, in case a host's SPN registration is missing. Matched with OR
    against the SPN check, so it only adds coverage - it never excludes an SPN-registered host
    that doesn't happen to match the prefix. Ignored without -DiscoverHosts.

.PARAMETER ADServer
    Domain controller or domain FQDN to bind to explicitly for -DiscoverHosts (e.g.
    'dc01.contoso.com' or 'contoso.com'). Required if the machine running this script is not
    domain-joined: ADSI's serverless bind ("LDAP://RootDSE" with no server) relies on Windows'
    domain locator, which only works from a domain-joined machine. Naming a server bypasses
    that locator and connects directly instead. Ignored without -DiscoverHosts.

.PARAMETER Credential
    Credential used for both the -DiscoverHosts AD query and for querying the Hyper-V hosts
    themselves. Required whenever the identity running this script (e.g. your day-to-day
    Windows logon) isn't the one with AD read / Hyper-V admin rights - common in environments
    that use separate privileged accounts for server management.

.PARAMETER VMName
    Optional name filter(s) passed to Get-VM (wildcards supported, e.g. 'SQL*'). Defaults
    to all VMs on each host. For regex-based filtering, collect everything here and apply
    -NameFilter in Get-AzureVMRecommendation.ps1 instead.

.PARAMETER SampleUtilization
    When set, polls CPU/memory/disk counters repeatedly instead of taking a single
    snapshot, and records average and maximum values.

.PARAMETER SampleDurationSeconds
    Total time to sample when -SampleUtilization is set. Default 60 seconds.

.PARAMETER SampleIntervalSeconds
    Time between samples when -SampleUtilization is set. Default 5 seconds.

.PARAMETER OutputDirectory
    Directory the CSV/JSON output files are written to. Defaults to the script's own
    directory.

.PARAMETER OutputBaseName
    Base file name (without extension) for the CSV/JSON output. Defaults to
    'HyperV-AzureSizingInfo'.

.EXAMPLE
    .\Get-HyperVAzureSizingInfo.ps1

    Snapshot every VM on the local Hyper-V host, no utilization sampling.

.EXAMPLE
    .\Get-HyperVAzureSizingInfo.ps1 -ComputerName HV-HOST01,HV-HOST02 -SampleUtilization -SampleDurationSeconds 120

    Sample CPU/memory/disk utilization for two hosts over a 2-minute window.

.EXAMPLE
    .\Get-HyperVAzureSizingInfo.ps1 -VMName 'SQL*' -OutputDirectory 'C:\Reports' -OutputBaseName 'SQL-Fleet'

    Collect only VMs whose name starts with SQL, writing C:\Reports\SQL-Fleet.csv/.json.

.EXAMPLE
    .\Get-HyperVAzureSizingInfo.ps1 -DiscoverHosts -ADSearchBase 'OU=HyperV,OU=Servers,DC=contoso,DC=com'

    Discover every Hyper-V host under a specific OU via its AD SPN, then collect from all of them.

.EXAMPLE
    .\Get-HyperVAzureSizingInfo.ps1 -DiscoverHosts -ADHostNamePrefix 'hs'

    Discover Hyper-V hosts domain-wide, matching either the SPN or a name starting with 'hs'.

.EXAMPLE
    $cred = Get-Credential 'CONTOSO\svc-hvadmin'
    .\Get-HyperVAzureSizingInfo.ps1 -DiscoverHosts -ADHostNamePrefix 'hs' -ADServer 'contoso.com' -Credential $cred

    From a non-domain-joined workstation, using a separate privileged account: bind to AD
    explicitly by domain FQDN/DC name with -ADServer, and use -Credential for both the AD
    query and the subsequent per-host Get-VM calls.
#>
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
    [switch] $SampleUtilization,

    [Parameter()]
    [int] $SampleDurationSeconds = 60,

    [Parameter()]
    [int] $SampleIntervalSeconds = 5,

    [Parameter()]
    [string] $OutputDirectory = $PSScriptRoot,

    [Parameter()]
    [string] $OutputBaseName = 'HyperV-AzureSizingInfo'
)

if (-not (Get-Module -ListAvailable -Name Hyper-V)) {
    throw @'
The Hyper-V PowerShell module is not installed on this machine, so Get-VM/Get-VHD/etc. are unavailable.
This module does not require the Hyper-V role itself to be installed locally - it just needs to be present
so this script can query remote hosts via -ComputerName. Install it with one of:
  - Windows Server (as a management box, no Hyper-V role needed): Install-WindowsFeature -Name Hyper-V-PowerShell
  - Windows 10/11 client: Enable-WindowsOptionalFeature -Online -FeatureName Microsoft-Hyper-V-Management-PowerShell -All
  - Or via Settings > Optional Features > "RSAT: Hyper-V Management Tools"
Then re-run this script.
'@
}

if ($Credential -and $Credential.UserName -notmatch '[\\@]') {
    Write-Warning @"
-Credential '$($Credential.UserName)' has no domain qualifier. Hyper-V's remote host connection
(WMI/DCOM) requires 'DOMAIN\user' or 'user@domain.com' and will reject a bare username with
"The user name '...' is not valid. (Parameter 'logonName')" for every host. Re-run Get-Credential
as e.g. 'DOMAIN\$($Credential.UserName)' if you see that error.
"@
}

function Write-SkipTips {
    # Get-VM with an explicit -Credential can't use plain DCOM (which only supports the
    # current logon token), so the Hyper-V module falls back to a WinRM/CredSSP session -
    # and CredSSP is off by default on a client. Surface the fix once, not once per host.
    param([System.Collections.Generic.List[string]] $SkippedItems)
    if (($SkippedItems | Where-Object { $_ -match 'CredSSP' } | Select-Object -First 1)) {
        Write-Host "`nTip: CredSSP failures above usually mean the client needs:" -ForegroundColor Yellow
        Write-Host "  Enable-WSManCredSSP -Role Client -DelegateComputer '*.<yourdomain>'" -ForegroundColor Yellow
        Write-Host '  (run elevated; delegates your credentials to those hosts - scope the pattern narrowly)' -ForegroundColor Yellow
    }
}

function Get-EscapedLdapFilterValue {
    # Escapes the handful of characters that are special inside an LDAP filter clause.
    param([string] $Value)
    return $Value -replace '\\', '\5c' -replace '\*', '\2a' -replace '\(', '\28' -replace '\)', '\29'
}

function New-AdDirectoryEntry {
    # Binds an LDAP path, using explicit credentials when supplied instead of the current
    # Windows logon - required when the caller's own identity has no AD/Hyper-V rights
    # (separate privileged account model) and/or this machine isn't domain-joined.
    # DirectoryEntry binds lazily and silently leaves .Properties as $null on failure rather
    # than throwing, so RefreshCache() forces the bind now to surface the real error instead
    # of a confusing "cannot index into a null array" further down when .Properties is read.
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
    <#
        Best-effort Hyper-V host discovery via Active Directory: every host registers a
        "Microsoft Virtual Console Service" SPN on its own computer account when the Hyper-V
        role/VMMS service starts, so this is a single LDAP query rather than a network scan.
        Uses plain ADSI (System.DirectoryServices) - no RSAT ActiveDirectory module needed.
        A host with a missing/removed SPN registration will not be found this way unless
        -NamePrefix is also supplied to widen the match.

        -Server/-Credential bind directly to a named DC/domain with explicit credentials
        instead of the "serverless" LDAP://RootDSE + current-logon-token path, which only
        works from a domain-joined machine running as an account with AD read rights.
    #>
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

function ConvertBytesToGB {
    param([Nullable[double]] $Bytes)
    if ($null -eq $Bytes) { return $null }
    return [Math]::Round($Bytes / 1GB, 2)
}

function Get-VMGuestOSInfo {
    <#
        Best-effort guest OS lookup via Hyper-V's KVP (Key-Value Pair) data exchange.
        Requires the "Guest Service Interface" / Data Exchange integration service to be
        running inside the guest. Returns $null fields (not a throw) when unavailable so
        callers can flag it as a warning instead of failing the VM.
    #>
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
        # Data Exchange not enabled, older host without this WMI class, or access denied.
        # Leave fields $null; caller records a warning.
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
                # Could not read the VHD (host unreachable, orphaned path, permissions). Leave
                # size fields $null so the caller can flag it rather than sizing on bad data.
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
    <#
        Best-effort per-disk IOPS/throughput sampling via the "Hyper-V Virtual Storage
        Device" counter set, matched back to a VHD path by substring. Matching disk
        counter instances to VHD paths is inherently fuzzy on Hyper-V (instance names
        vary by host version), so failures here are silent by design — the recommendation
        script already treats missing IOPS data as "unverified" rather than an error.
        Returns a hashtable keyed by VHD path, or $null on any failure.
    #>
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

$allResults = New-Object System.Collections.Generic.List[object]
$skipped = New-Object System.Collections.Generic.List[string]

foreach ($computer in $ComputerName) {
    Write-Host "Querying Hyper-V host '$computer' ..." -ForegroundColor Cyan

    $getVmParams = @{ ComputerName = $computer; Name = $VMName; ErrorAction = 'Stop' }
    if ($Credential) { $getVmParams.Credential = $Credential }

    try {
        $vms = Get-VM @getVmParams
    } catch {
        Write-Warning "Could not query host '$computer': $($_.Exception.Message)"
        $skipped.Add("(host) $computer - $($_.Exception.Message)")
        continue
    }

    if (-not $vms) {
        Write-Warning "No VMs matched on host '$computer'."
        continue
    }

    foreach ($vm in $vms) {
        Write-Host "  Collecting '$($vm.Name)' ..." -ForegroundColor DarkGray
        $warnings = New-Object System.Collections.Generic.List[string]

        try {
            # ---- CPU / memory (single snapshot, refreshed by sampling loop below) ----
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

            # ---- Static memory configuration ----
            $vmMemory = $null
            try {
                $memParams = @{ VM = $vm; ErrorAction = 'Stop' }
                $vmMemory = Get-VMMemory @memParams
            } catch {
                $warnings.Add('Could not read VMMemory configuration.')
            }

            # ---- Generation / Trusted Launch inputs ----
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
                # Get-VMSecurity requires Server 2016+/Hyper-V module version with shielded VM
                # support. Not present -> leave $null, treated as "unknown" downstream.
            }

            # ---- Guest OS (best effort) ----
            $osInfo = Get-VMGuestOSInfo -Name $vm.Name -ComputerName $computer -Credential $Credential
            if (-not $osInfo.OSName) {
                $warnings.Add('Guest OS name unavailable - enable Data Exchange integration service inside the guest for endorsed-OS / Hybrid Benefit checks.')
            }

            # ---- Disks ----
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

if ($allResults.Count -eq 0) {
    Write-Warning 'No VM data collected. Nothing to write.'
    if ($skipped.Count -gt 0) {
        Write-Host "`nSkipped:" -ForegroundColor Yellow
        $skipped | ForEach-Object { Write-Host "  $_" -ForegroundColor Yellow }
        Write-SkipTips -SkippedItems $skipped
    }
    return
}

if (-not (Test-Path -LiteralPath $OutputDirectory)) {
    New-Item -ItemType Directory -Path $OutputDirectory -Force | Out-Null
}

$csvPath = Join-Path $OutputDirectory "$OutputBaseName.csv"
$jsonPath = Join-Path $OutputDirectory "$OutputBaseName.json"

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

$flattened | Export-Csv -LiteralPath $csvPath -NoTypeInformation -Encoding UTF8

# Out-File -Encoding UTF8 writes a BOM in Windows PowerShell 5.1, which some JSON readers
# choke on or misparse depending on how the file is subsequently handled/re-encoded.
# Writing via .NET directly avoids the BOM so downstream ConvertFrom-Json is unambiguous.
$jsonContent = $allResults | ConvertTo-Json -Depth 6
[System.IO.File]::WriteAllText($jsonPath, $jsonContent, (New-Object System.Text.UTF8Encoding($false)))

Write-Host "`nCollected $($allResults.Count) VM(s)." -ForegroundColor Green
Write-Host "CSV  : $csvPath" -ForegroundColor Green
Write-Host "JSON : $jsonPath" -ForegroundColor Green

if ($skipped.Count -gt 0) {
    Write-Host "`nSkipped $($skipped.Count) item(s):" -ForegroundColor Yellow
    $skipped | ForEach-Object { Write-Host "  $_" -ForegroundColor Yellow }
    Write-SkipTips -SkippedItems $skipped
}

$allResults | Select-Object VMName, ComputerName, State, Generation, ProcessorCount, MemoryAssignedGB, @{N='Disks';E={$_.Disks.Count}} |
    Format-Table -AutoSize | Out-Host
