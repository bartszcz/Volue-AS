<#
.SYNOPSIS
    Recommends an Azure VM SKU and estimates monthly cost for one or more Hyper-V VMs.

.DESCRIPTION
    Takes Hyper-V VM configuration data (single VM on the command line, a batch file, or
    a regex-filtered subset of a fleet export) and produces a sized Azure VM
    recommendation plus an estimated monthly cost, using the Azure Retail Prices API.

    Sizing is not a naive 1:1 resource copy:
      - vCPU is sized on observed peak utilization when available, otherwise on the
        allocated vCPU count.
      - RAM is sized on sampled memory demand, then dynamic-memory maximum, then
        assigned/startup RAM - whichever is the most accurate figure available.
      - The vCPU:RAM ratio picks the VM family: ~4 GB/vCPU -> D-series (general
        purpose, default), >6 GB/vCPU -> E-series (memory optimized), <3 GB/vCPU ->
        F-series (compute optimized).
      - Each disk is rounded up to the next standard Azure managed disk size tier, and
        escalated from Standard SSD -> Premium SSD -> Premium SSD v2/Ultra based on
        observed IOPS/throughput. Missing IOPS data defaults to Premium SSD with an
        "unverified" warning rather than silently under-sizing.
      - Generation/SecureBoot/vTPM drive a Trusted Launch eligibility flag.
      - Guest OS is checked against a static endorsed-OS list; Windows Server guests are
        flagged as potentially Azure Hybrid Benefit eligible (license ownership cannot be
        verified programmatically - it is always left for manual confirmation).
      - Differencing and pass-through disks produce a hard warning since they cannot be
        sized/migrated as-is.

    The SKU reference table (vCPU/RAM per SKU) and the storage per-GB rates are
    hardcoded - no API call is needed for the sizing step itself, only for compute
    pricing. A failed or throttled price lookup does not fail the batch: that VM's cost
    fields are left $null with a CostNote explaining why.

.PARAMETER VMName
    (Manual mode) Name of the single VM being sized.

.PARAMETER vCPU
    (Manual mode) Allocated virtual CPU count.

.PARAMETER RAMGB
    (Manual mode) Assigned RAM in GB.

.PARAMETER DiskSizesGB
    (Manual mode) Provisioned size in GB of each disk attached to the VM.

.PARAMETER Generation
    (Manual mode) Hyper-V VM generation, 1 or 2. Default 2.

.PARAMETER SecureBoot
    (Manual mode) Switch - pass it when Secure Boot is enabled on the VM.

.PARAMETER GuestOS
    (Manual mode) Guest operating system name/edition, e.g. 'Windows Server 2022
    Standard' or 'Ubuntu 22.04 LTS'. Used for endorsed-OS and Hybrid Benefit checks.

.PARAMETER InputCsv
    (Batch/Regex mode) Path to a CSV file of VM records - either the CSV produced by
    Get-HyperVAzureSizingInfo.ps1, or a simple manual-style CSV with columns VMName,
    vCPU, RAMGB, DiskSizesGB (pipe- or comma-delimited), Generation, SecureBoot, GuestOS.

.PARAMETER InputJson
    (Batch/Regex mode) Path to a JSON file of VM records, in either of the two schemas
    described above for -InputCsv.

.PARAMETER NameFilter
    (Regex mode) .NET regular expression applied to VMName after loading -InputCsv/
    -InputJson. Only matching VMs are sized. Case-insensitive unless -CaseSensitive is
    supplied. Example: '^SQL\d{2}-(PROD|UAT)$'.

.PARAMETER CaseSensitive
    (Regex mode) Makes -NameFilter matching case-sensitive.

.PARAMETER Region
    Azure region used for both the SKU price lookup and as metadata on the output.
    Default 'westeurope'.

.PARAMETER Currency
    Currency code requested from the Azure Retail Prices API. Default 'EUR'.

.PARAMETER OutputDirectory
    Directory the CSV/JSON output files are written to. Defaults to the script's own
    directory.

.PARAMETER OutputBaseName
    Base file name (without extension) for the CSV/JSON output. Defaults to
    'AzureVMRecommendation'.

.EXAMPLE
    .\Get-AzureVMRecommendation.ps1 -VMName 'APP01' -vCPU 4 -RAMGB 16 -DiskSizesGB 127,512 -Generation 2 -SecureBoot -GuestOS 'Windows Server 2022 Standard'

    Manual single-VM sizing.

.EXAMPLE
    .\Get-AzureVMRecommendation.ps1 -InputJson .\HyperV-AzureSizingInfo.json -Region westeurope -Currency EUR

    Batch-size every VM in a collector export.

.EXAMPLE
    .\Get-AzureVMRecommendation.ps1 -InputJson .\HyperV-AzureSizingInfo.json -NameFilter '^SQL\d{2}-(PROD|UAT)$'

    Size only the production/UAT SQL hosts out of a full fleet export.
#>
[CmdletBinding(DefaultParameterSetName = 'Manual')]
param(
    [Parameter(Mandatory, ParameterSetName = 'Manual')]
    [string] $VMName,

    [Parameter(Mandatory, ParameterSetName = 'Manual')]
    [int] $vCPU,

    [Parameter(Mandatory, ParameterSetName = 'Manual')]
    [double] $RAMGB,

    [Parameter(Mandatory, ParameterSetName = 'Manual')]
    [double[]] $DiskSizesGB,

    [Parameter(ParameterSetName = 'Manual')]
    [ValidateSet(1, 2)]
    [int] $Generation = 2,

    [Parameter(ParameterSetName = 'Manual')]
    [switch] $SecureBoot,

    [Parameter(Mandatory, ParameterSetName = 'Manual')]
    [string] $GuestOS,

    [Parameter(ParameterSetName = 'File')]
    [string] $InputCsv,

    [Parameter(ParameterSetName = 'File')]
    [string] $InputJson,

    [Parameter(ParameterSetName = 'File')]
    [string] $NameFilter,

    [Parameter(ParameterSetName = 'File')]
    [switch] $CaseSensitive,

    [Parameter()]
    [string] $Region = 'westeurope',

    [Parameter()]
    [string] $Currency = 'EUR',

    [Parameter()]
    [string] $OutputDirectory = $PSScriptRoot,

    [Parameter()]
    [string] $OutputBaseName = 'AzureVMRecommendation'
)

# ============================================================================
# Reference data (static - no API call needed for sizing, only for pricing)
# ============================================================================

$script:SkuTable = @(
    [pscustomobject]@{ Family = 'D'; Sku = 'D2s_v5';  vCPU = 2;  RAMGB = 8   }
    [pscustomobject]@{ Family = 'D'; Sku = 'D4s_v5';  vCPU = 4;  RAMGB = 16  }
    [pscustomobject]@{ Family = 'D'; Sku = 'D8s_v5';  vCPU = 8;  RAMGB = 32  }
    [pscustomobject]@{ Family = 'D'; Sku = 'D16s_v5'; vCPU = 16; RAMGB = 64  }
    [pscustomobject]@{ Family = 'E'; Sku = 'E2s_v5';  vCPU = 2;  RAMGB = 16  }
    [pscustomobject]@{ Family = 'E'; Sku = 'E4s_v5';  vCPU = 4;  RAMGB = 32  }
    [pscustomobject]@{ Family = 'E'; Sku = 'E8s_v5';  vCPU = 8;  RAMGB = 64  }
    [pscustomobject]@{ Family = 'E'; Sku = 'E16s_v5'; vCPU = 16; RAMGB = 128 }
    [pscustomobject]@{ Family = 'F'; Sku = 'F2s_v2';  vCPU = 2;  RAMGB = 4   }
    [pscustomobject]@{ Family = 'F'; Sku = 'F4s_v2';  vCPU = 4;  RAMGB = 8   }
    [pscustomobject]@{ Family = 'F'; Sku = 'F8s_v2';  vCPU = 8;  RAMGB = 16  }
    [pscustomobject]@{ Family = 'F'; Sku = 'F16s_v2'; vCPU = 16; RAMGB = 32  }
)

# Standard Azure managed disk size tiers (GB).
$script:DiskTierSizesGB = @(4, 8, 16, 32, 64, 128, 256, 512, 1024, 2048, 4096, 8192, 16384, 32767)

# Approximate, hardcoded managed disk rates (EUR/GB/month). Premium SSD v2/Ultra are
# IOPS+throughput priced, not per-GB, so they are flagged instead of computed.
$script:DiskRatePerGB = @{ 'Standard SSD' = 0.10; 'Premium SSD' = 0.15 }

# Endorsed guest OS patterns (regex, case-insensitive). Not exhaustive - anything that
# doesn't match is flagged for manual verification rather than assumed unsupported.
$script:EndorsedOsPatterns = @(
    'Windows Server 20(12 ?R2|16|19|22|25)',
    'Windows (10|11)',
    'Ubuntu ?(1[68]|2[024])\.04',
    'Red ?Hat|RHEL ?[789]',
    'SUSE|SLES ?1[25]',
    'Debian ?(9|10|11|12)'
)

# ============================================================================
# Helpers
# ============================================================================

function ConvertTo-NullableDouble {
    param([object] $Value)
    if ($null -eq $Value) { return $null }
    if ($Value -is [string] -and [string]::IsNullOrWhiteSpace($Value)) { return $null }
    $parsed = 0.0
    if ([double]::TryParse([string]$Value, [ref]$parsed)) { return $parsed }
    return $null
}

function ConvertTo-NullableBool {
    param([object] $Value)
    if ($null -eq $Value) { return $null }
    if ($Value -is [bool]) { return $Value }
    $s = [string]$Value
    if ([string]::IsNullOrWhiteSpace($s)) { return $null }
    if ($s -in @('True', 'true', '1')) { return $true }
    if ($s -in @('False', 'false', '0')) { return $false }
    return $null
}

function ConvertTo-ScalarValue {
    # JSON round-tripping (or a single-item PowerShell collection serialized oddly) can
    # leave a field that should be a scalar wrapped in an array. Unwrap it before casting
    # so a stray wrapper doesn't throw a hard-to-diagnose "Object[] to Int32" error.
    param([object] $Value)
    if ($Value -is [array]) {
        if ($Value.Count -eq 0) { return $null }
        return $Value[0]
    }
    return $Value
}

function ConvertTo-NullableInt {
    param([object] $Value)
    $scalar = ConvertTo-ScalarValue $Value
    if ($null -eq $scalar) { return $null }
    if ($scalar -is [string] -and [string]::IsNullOrWhiteSpace($scalar)) { return $null }
    $parsed = 0
    if ([int]::TryParse([string]$scalar, [ref]$parsed)) { return $parsed }
    return $null
}

function Split-DelimitedField {
    param([string] $Value)
    if ([string]::IsNullOrWhiteSpace($Value)) { return @() }
    return $Value -split '[|,]' | ForEach-Object { $_.Trim() }
}

function New-NormalizedVmRecord {
    # Canonical shape every sizing function below consumes, regardless of source
    # (manual params, collector JSON, collector CSV, or a hand-written simple CSV/JSON).
    param(
        [string] $VMName,
        [int] $ProcessorCount,
        [Nullable[double]] $CPUUsagePercentAvg,
        [Nullable[double]] $CPUUsagePercentMax,
        [Nullable[double]] $MemoryAssignedGB,
        [Nullable[double]] $MemoryMaximumGB,
        [Nullable[bool]] $DynamicMemoryEnabled,
        [Nullable[double]] $MemoryDemandGB,
        [object[]] $Disks,
        [int] $Generation,
        [Nullable[bool]] $SecureBootEnabled,
        [Nullable[bool]] $TpmEnabled,
        [string] $GuestOSName,
        [string[]] $SourceWarnings
    )

    return [pscustomobject]@{
        VMName               = $VMName
        ProcessorCount       = $ProcessorCount
        CPUUsagePercentAvg   = $CPUUsagePercentAvg
        CPUUsagePercentMax   = $CPUUsagePercentMax
        MemoryAssignedGB     = $MemoryAssignedGB
        MemoryMaximumGB      = $MemoryMaximumGB
        DynamicMemoryEnabled = $DynamicMemoryEnabled
        MemoryDemandGB       = $MemoryDemandGB
        Disks                = @($Disks)
        Generation           = $Generation
        SecureBootEnabled    = $SecureBootEnabled
        TpmEnabled           = $TpmEnabled
        GuestOSName          = $GuestOSName
        SourceWarnings       = @($SourceWarnings)
    }
}

function ConvertFrom-CollectorDisk {
    param([object] $Disk)
    return [pscustomobject]@{
        SizeGB                 = ConvertTo-NullableDouble $Disk.SizeGB
        FileSizeGB             = ConvertTo-NullableDouble $Disk.FileSizeGB
        IsDifferencing         = [bool](ConvertTo-NullableBool $Disk.IsDifferencing)
        IsPassThrough          = [bool](ConvertTo-NullableBool $Disk.IsPassThrough)
        ReadIOPSAvg            = ConvertTo-NullableDouble $Disk.ReadIOPSAvg
        WriteIOPSAvg           = ConvertTo-NullableDouble $Disk.WriteIOPSAvg
        ReadThroughputMBpsAvg  = ConvertTo-NullableDouble $Disk.ReadThroughputMBpsAvg
        WriteThroughputMBpsAvg = ConvertTo-NullableDouble $Disk.WriteThroughputMBpsAvg
    }
}

function Import-VmSizingRecords {
    <#
        Shared loader for Batch and Regex input modes. Understands two shapes for both
        CSV and JSON: the Get-HyperVAzureSizingInfo.ps1 collector schema (ProcessorCount,
        MemoryAssignedGB, nested/flattened Disks, ...), and a simpler hand-authored
        schema mirroring the manual-mode parameters (vCPU, RAMGB, DiskSizesGB, GuestOS).
    #>
    param(
        [string] $InputCsv,
        [string] $InputJson,
        [System.Collections.Generic.List[string]] $SkippedVMs
    )

    if ($InputCsv -and $InputJson) {
        throw 'Specify only one of -InputCsv or -InputJson, not both.'
    }
    if (-not $InputCsv -and -not $InputJson) {
        throw 'Specify -InputCsv or -InputJson.'
    }

    $rawRows = @()
    $isJson = [bool]$InputJson

    if ($isJson) {
        if (-not (Test-Path -LiteralPath $InputJson)) { throw "Input JSON file not found: $InputJson" }
        $jsonText = Get-Content -LiteralPath $InputJson -Raw
        # A stray BOM or other leading character before the JSON structure (seen from files
        # that have been re-saved/re-encoded by another tool) can make ConvertFrom-Json
        # misparse or silently truncate rather than throw. Strip anything before the first
        # '[' or '{' so parsing always sees clean JSON regardless of how the file got there.
        $jsonStart = $jsonText.IndexOfAny(@('[', '{'))
        if ($jsonStart -gt 0) { $jsonText = $jsonText.Substring($jsonStart) }
        $rawRows = @($jsonText | ConvertFrom-Json)
    } else {
        if (-not (Test-Path -LiteralPath $InputCsv)) { throw "Input CSV file not found: $InputCsv" }
        $rawRows = @(Import-Csv -LiteralPath $InputCsv)
    }

    if ($rawRows.Count -eq 0) { throw 'Input file contained no VM records.' }

    $records = New-Object System.Collections.Generic.List[object]

    foreach ($row in $rawRows) {
        $rowLabel = if ($row.VMName) { [string](ConvertTo-ScalarValue $row.VMName) } else { '(unnamed row)' }
        try {
            $isCollectorSchema = [bool]($row.PSObject.Properties.Name -contains 'ProcessorCount')

            if ($isCollectorSchema) {
                if ($isJson) {
                    $disks = @($row.Disks) | ForEach-Object { ConvertFrom-CollectorDisk $_ }
                } else {
                    $sizes  = Split-DelimitedField $row.DiskSizesGB
                    $used   = Split-DelimitedField $row.DiskUsedGB
                    $diff   = Split-DelimitedField $row.DiskIsDifferencing
                    $pass   = Split-DelimitedField $row.DiskIsPassThrough
                    $rIops  = Split-DelimitedField $row.DiskReadIOPSAvg
                    $wIops  = Split-DelimitedField $row.DiskWriteIOPSAvg
                    $rTput  = Split-DelimitedField $row.DiskReadThroughputMBpsAvg
                    $wTput  = Split-DelimitedField $row.DiskWriteThroughputMBpsAvg
                    $disks = for ($i = 0; $i -lt $sizes.Count; $i++) {
                        [pscustomobject]@{
                            SizeGB                 = ConvertTo-NullableDouble $sizes[$i]
                            FileSizeGB             = ConvertTo-NullableDouble ($used[$i])
                            IsDifferencing         = [bool](ConvertTo-NullableBool ($diff[$i]))
                            IsPassThrough          = [bool](ConvertTo-NullableBool ($pass[$i]))
                            ReadIOPSAvg            = ConvertTo-NullableDouble ($rIops[$i])
                            WriteIOPSAvg           = ConvertTo-NullableDouble ($wIops[$i])
                            ReadThroughputMBpsAvg  = ConvertTo-NullableDouble ($rTput[$i])
                            WriteThroughputMBpsAvg = ConvertTo-NullableDouble ($wTput[$i])
                        }
                    }
                }

                $sourceWarnings = @()
                if ($row.PSObject.Properties.Name -contains 'Warnings' -and $row.Warnings) {
                    $sourceWarnings = if ($isJson) { @($row.Warnings) } else { Split-DelimitedField $row.Warnings }
                }

                $processorCount = ConvertTo-NullableInt $row.ProcessorCount
                if ($null -eq $processorCount) { $processorCount = 0 }
                $generation = ConvertTo-NullableInt $row.Generation
                if ($null -eq $generation) { $generation = 2 }

                $records.Add((New-NormalizedVmRecord `
                    -VMName ([string](ConvertTo-ScalarValue $row.VMName)) `
                    -ProcessorCount $processorCount `
                    -CPUUsagePercentAvg (ConvertTo-NullableDouble $row.CPUUsagePercentAvg) `
                    -CPUUsagePercentMax (ConvertTo-NullableDouble $row.CPUUsagePercentMax) `
                    -MemoryAssignedGB (ConvertTo-NullableDouble $row.MemoryAssignedGB) `
                    -MemoryMaximumGB (ConvertTo-NullableDouble $row.MemoryMaximumGB) `
                    -DynamicMemoryEnabled (ConvertTo-NullableBool $row.DynamicMemoryEnabled) `
                    -MemoryDemandGB (ConvertTo-NullableDouble $row.MemoryDemandGB) `
                    -Disks $disks `
                    -Generation $generation `
                    -SecureBootEnabled (ConvertTo-NullableBool $row.SecureBootEnabled) `
                    -TpmEnabled (ConvertTo-NullableBool $row.TpmEnabled) `
                    -GuestOSName ([string](ConvertTo-ScalarValue $row.GuestOSName)) `
                    -SourceWarnings $sourceWarnings))
            } else {
                # Simple manual-style schema: VMName, vCPU, RAMGB, DiskSizesGB, Generation, SecureBoot, GuestOS
                $sizes = if ($isJson) { @($row.DiskSizesGB) } else { Split-DelimitedField $row.DiskSizesGB }
                $disks = $sizes | ForEach-Object {
                    [pscustomobject]@{
                        SizeGB = ConvertTo-NullableDouble $_; FileSizeGB = $null; IsDifferencing = $false
                        IsPassThrough = $false; ReadIOPSAvg = $null; WriteIOPSAvg = $null
                        ReadThroughputMBpsAvg = $null; WriteThroughputMBpsAvg = $null
                    }
                }

                $genValue = ConvertTo-NullableInt $row.Generation
                if ($null -eq $genValue) { $genValue = 2 }
                $vCPUValue = ConvertTo-NullableInt $row.vCPU
                if ($null -eq $vCPUValue) { $vCPUValue = 0 }

                $records.Add((New-NormalizedVmRecord `
                    -VMName ([string](ConvertTo-ScalarValue $row.VMName)) `
                    -ProcessorCount $vCPUValue `
                    -CPUUsagePercentAvg $null -CPUUsagePercentMax $null `
                    -MemoryAssignedGB (ConvertTo-NullableDouble $row.RAMGB) `
                    -MemoryMaximumGB $null -DynamicMemoryEnabled $false -MemoryDemandGB $null `
                    -Disks $disks `
                    -Generation $genValue `
                    -SecureBootEnabled (ConvertTo-NullableBool $row.SecureBoot) `
                    -TpmEnabled $null `
                    -GuestOSName ([string](ConvertTo-ScalarValue $row.GuestOS)) `
                    -SourceWarnings @()))
            }
        } catch {
            Write-Warning "Skipping VM record '$rowLabel': $($_.Exception.Message)"
            if ($SkippedVMs) { $SkippedVMs.Add("$rowLabel - $($_.Exception.Message)") }
        }
    }

    Write-Host "Loaded $($records.Count) of $($rawRows.Count) VM record(s) from input." -ForegroundColor Cyan
    return $records
}

function Resolve-EffectiveVCPU {
    param($Record)
    if ($Record.CPUUsagePercentMax) {
        $eff = [Math]::Ceiling($Record.ProcessorCount * ($Record.CPUUsagePercentMax / 100.0) * 1.3)
        if ($eff -lt 1) { $eff = 1 }
        if ($eff -gt $Record.ProcessorCount) { $eff = $Record.ProcessorCount }
        return [pscustomobject]@{ Value = [int]$eff; Basis = "peak utilization ($($Record.CPUUsagePercentMax)% observed, +30% headroom)" }
    }
    return [pscustomobject]@{ Value = [Math]::Max(1, $Record.ProcessorCount); Basis = 'allocated vCPU (no utilization data)' }
}

function Resolve-EffectiveRAMGB {
    param($Record)
    if ($Record.MemoryDemandGB) {
        # A VM physically cannot demand more memory than it's been assigned/allotted. Seeing
        # that anyway is a known Hyper-V quirk (a stale Dynamic Memory counter left over from
        # before DM was disabled) rather than a real requirement - clamp to the assigned/max
        # ceiling and flag it instead of sizing off the bogus figure.
        $ceilingCandidates = @()
        if ($Record.MemoryAssignedGB) { $ceilingCandidates += $Record.MemoryAssignedGB }
        if ($Record.MemoryMaximumGB) { $ceilingCandidates += $Record.MemoryMaximumGB }
        $demandCeiling = if ($ceilingCandidates.Count -gt 0) { ($ceilingCandidates | Measure-Object -Maximum).Maximum } else { $null }

        if ($demandCeiling -and $Record.MemoryDemandGB -gt $demandCeiling) {
            return [pscustomobject]@{
                Value   = $demandCeiling
                Basis   = "assigned/max RAM ($demandCeiling GB) - sampled demand exceeded it"
                Warning = "Sampled memory demand ($($Record.MemoryDemandGB) GB) exceeds assigned/maximum RAM ($demandCeiling GB), which isn't physically possible - likely a stale Dynamic Memory counter. Used assigned/max RAM instead; verify manually."
            }
        }

        $eff = [Math]::Ceiling($Record.MemoryDemandGB * 1.15)
        return [pscustomobject]@{ Value = $eff; Basis = "sampled memory demand ($($Record.MemoryDemandGB) GB, +15% headroom)"; Warning = $null }
    }
    if ($Record.DynamicMemoryEnabled -and $Record.MemoryMaximumGB) {
        return [pscustomobject]@{ Value = $Record.MemoryMaximumGB; Basis = 'dynamic memory maximum'; Warning = $null }
    }
    if ($Record.MemoryAssignedGB) {
        return [pscustomobject]@{ Value = $Record.MemoryAssignedGB; Basis = 'assigned/startup RAM'; Warning = $null }
    }
    return [pscustomobject]@{ Value = 0; Basis = 'no memory data available'; Warning = $null }
}

function Get-VMFamily {
    param([double] $EffectiveRAMGB, [int] $EffectiveVCPU)
    if ($EffectiveVCPU -le 0) { return 'D' }
    $ratio = $EffectiveRAMGB / $EffectiveVCPU
    if ($ratio -gt 6) { return 'E' }
    if ($ratio -lt 3) { return 'F' }
    return 'D'
}

function Select-VmSku {
    param([string] $Family, [int] $EffectiveVCPU, [double] $EffectiveRAMGB)

    $candidates = $script:SkuTable | Where-Object { $_.Family -eq $Family } | Sort-Object vCPU
    $fit = $candidates | Where-Object { $_.vCPU -ge $EffectiveVCPU -and $_.RAMGB -ge $EffectiveRAMGB } | Select-Object -First 1

    if ($fit) { return [pscustomobject]@{ Sku = $fit; Warning = $null } }

    $largest = $candidates | Select-Object -Last 1
    return [pscustomobject]@{
        Sku     = $largest
        Warning = "Requirement ($EffectiveVCPU vCPU / $EffectiveRAMGB GB) exceeds the largest $Family-series SKU in the reference table ($($largest.Sku)) - review manually for a larger size."
    }
}

function Get-ManagedDiskTierGB {
    param([double] $SizeGB)
    foreach ($tier in $script:DiskTierSizesGB) {
        if ($SizeGB -le $tier) { return $tier }
    }
    return $script:DiskTierSizesGB[-1]
}

function Get-DiskPerformanceTier {
    param($Disk)

    $hasIoData = ($null -ne $Disk.ReadIOPSAvg) -or ($null -ne $Disk.WriteIOPSAvg) -or `
                 ($null -ne $Disk.ReadThroughputMBpsAvg) -or ($null -ne $Disk.WriteThroughputMBpsAvg)

    if (-not $hasIoData) {
        return [pscustomobject]@{ Tier = 'Premium SSD'; Warning = 'IOPS/throughput unverified - confirm before commit.' }
    }

    $iops = 0.0 + (ConvertTo-NullableDouble $Disk.ReadIOPSAvg) + (ConvertTo-NullableDouble $Disk.WriteIOPSAvg)
    $tput = 0.0 + (ConvertTo-NullableDouble $Disk.ReadThroughputMBpsAvg) + (ConvertTo-NullableDouble $Disk.WriteThroughputMBpsAvg)

    if ($iops -gt 20000 -or $tput -gt 900) {
        return [pscustomobject]@{ Tier = 'Premium SSD v2/Ultra'; Warning = 'Storage cost for this disk requires the Retail Prices API IOPS/throughput meters - call separately, not included in EstimatedMonthlyStorageCost.' }
    }
    if ($iops -gt 500 -or $tput -gt 60) {
        return [pscustomobject]@{ Tier = 'Premium SSD'; Warning = $null }
    }
    return [pscustomobject]@{ Tier = 'Standard SSD'; Warning = $null }
}

function Test-EndorsedGuestOS {
    param([string] $OSName)
    if ([string]::IsNullOrWhiteSpace($OSName)) { return $false }
    foreach ($pattern in $script:EndorsedOsPatterns) {
        if ($OSName -match $pattern) { return $true }
    }
    return $false
}

function Get-AzureRetailPrice {
    <#
        Queries the Azure Retail Prices API for a single SKU/region/currency and returns
        the lowest Consumption retailPrice, excluding Spot/low-priority meters and
        matching the Windows meter only when the guest requires it. Returns $null (never
        throws) so callers can fall back gracefully.
    #>
    param(
        [string] $Sku,
        [string] $Region,
        [string] $Currency,
        [bool] $RequiresWindowsMeter
    )

    try {
        $armSkuName = "Standard_$Sku"
        $filter = "serviceName eq 'Virtual Machines' and armRegionName eq '$Region' and armSkuName eq '$armSkuName' and type eq 'Consumption'"
        $encodedFilter = [uri]::EscapeDataString($filter)
        $uri = "https://prices.azure.com/api/retail/prices?currencyCode=$Currency&`$filter=$encodedFilter"

        $items = New-Object System.Collections.Generic.List[object]
        $page = 0
        while ($uri -and $page -lt 5) {
            $response = Invoke-RestMethod -Uri $uri -Method Get -ErrorAction Stop -TimeoutSec 20
            if ($response.Items) { $items.AddRange(@($response.Items)) }
            $uri = $response.NextPageLink
            $page++
        }

        if ($items.Count -eq 0) { return $null }

        $filtered = $items | Where-Object {
            $_.skuName -notlike '*Spot*' -and $_.meterName -notlike '*Spot*' -and $_.meterName -notlike '*Low Priority*'
        }

        $filtered = if ($RequiresWindowsMeter) {
            $filtered | Where-Object { $_.productName -like '*Windows*' }
        } else {
            $filtered | Where-Object { $_.productName -notlike '*Windows*' }
        }

        if (-not $filtered -or @($filtered).Count -eq 0) { return $null }

        return (@($filtered) | Sort-Object retailPrice | Select-Object -First 1).retailPrice
    } catch {
        return $null
    }
}

function Get-DiskMonthlyCost {
    param([double] $TierGB, [string] $PerformanceTier)
    if ($script:DiskRatePerGB.ContainsKey($PerformanceTier)) {
        return [Math]::Round($TierGB * $script:DiskRatePerGB[$PerformanceTier], 2)
    }
    return $null
}

# ============================================================================
# Sizing engine - one normalized record in, one recommendation object out
# ============================================================================

function Get-VMSizingRecommendation {
    param($Record, [hashtable] $PriceCache, [string] $Region, [string] $Currency)

    $warnings = New-Object System.Collections.Generic.List[string]
    $Record.SourceWarnings | Where-Object { $_ } | ForEach-Object { $warnings.Add($_) }

    $effVCPU = Resolve-EffectiveVCPU -Record $Record
    $effRAM  = Resolve-EffectiveRAMGB -Record $Record

    if ($effRAM.Value -eq 0) {
        $warnings.Add('No RAM data available - sizing may be inaccurate.')
    }
    if ($effRAM.Warning) { $warnings.Add($effRAM.Warning) }

    $family = Get-VMFamily -EffectiveRAMGB $effRAM.Value -EffectiveVCPU $effVCPU.Value
    $skuResult = Select-VmSku -Family $family -EffectiveVCPU $effVCPU.Value -EffectiveRAMGB $effRAM.Value
    if ($skuResult.Warning) { $warnings.Add($skuResult.Warning) }
    $sku = $skuResult.Sku

    # ---- Disks ----
    $diskTierGB = New-Object System.Collections.Generic.List[double]
    $diskPerfTiers = New-Object System.Collections.Generic.List[string]
    $storageCost = 0.0
    $storageCostIsPartial = $false

    foreach ($disk in $Record.Disks) {
        if ($disk.IsDifferencing) {
            $warnings.Add('BLOCKING: disk is a differencing disk - must be converted to a fixed VHD before migration; not sizeable as-is.')
        }
        if ($disk.IsPassThrough) {
            $warnings.Add('BLOCKING: disk is a pass-through (physical) disk - must be converted to a VHD/VHDX before migration; not sizeable as-is.')
        }

        $sizeGB = if ($disk.SizeGB) { $disk.SizeGB } else { 0 }
        $tierGB = Get-ManagedDiskTierGB -SizeGB $sizeGB
        $diskTierGB.Add($tierGB)

        $perf = Get-DiskPerformanceTier -Disk $disk
        $diskPerfTiers.Add($perf.Tier)
        if ($perf.Warning) { $warnings.Add($perf.Warning) }

        $diskCost = Get-DiskMonthlyCost -TierGB $tierGB -PerformanceTier $perf.Tier
        if ($null -eq $diskCost) { $storageCostIsPartial = $true } else { $storageCost += $diskCost }
    }

    # ---- Trusted Launch ----
    $trustedLaunchEligible = $false
    if ($Record.Generation -eq 1) {
        $warnings.Add('Generation 1 VM - not eligible for Trusted Launch; requires conversion to a Generation 2 Azure image.')
    } elseif ($null -eq $Record.SecureBootEnabled -or $null -eq $Record.TpmEnabled) {
        $warnings.Add('SecureBoot/vTPM state unknown - confirm Trusted Launch eligibility manually.')
    } elseif ($Record.SecureBootEnabled -and $Record.TpmEnabled) {
        $trustedLaunchEligible = $true
    } else {
        $warnings.Add('SecureBoot or vTPM disabled - Trusted Launch requires both enabled.')
    }

    # ---- Guest OS / Hybrid Benefit ----
    $isWindowsGuest = $Record.GuestOSName -like '*Windows*'
    if (-not (Test-EndorsedGuestOS -OSName $Record.GuestOSName)) {
        $osLabel = if ($Record.GuestOSName) { $Record.GuestOSName } else { '(unknown)' }
        $warnings.Add("Guest OS '$osLabel' not found in the endorsed-OS reference list - verify Azure endorsement manually.")
    }
    if ($isWindowsGuest) {
        $warnings.Add('Windows Server guest detected - potentially eligible for Azure Hybrid Benefit; confirm an existing eligible license before assuming the discount.')
    }

    # ---- Cost ----
    $cacheKey = "$($sku.Sku)|$Region|$Currency|$isWindowsGuest"
    if (-not $PriceCache.ContainsKey($cacheKey)) {
        $PriceCache[$cacheKey] = Get-AzureRetailPrice -Sku $sku.Sku -Region $Region -Currency $Currency -RequiresWindowsMeter $isWindowsGuest
    }
    $hourlyPrice = $PriceCache[$cacheKey]

    $computeCost = $null
    $totalCost = $null
    $costNote = $null

    if ($null -eq $hourlyPrice) {
        $costNote = 'price lookup failed - retry or use Azure Pricing Calculator manually'
    } else {
        $computeCost = [Math]::Round($hourlyPrice * 730, 2)
        $totalCost = [Math]::Round($computeCost + $storageCost, 2)
        if ($storageCostIsPartial) {
            $costNote = 'storage cost is partial - one or more disks are Premium SSD v2/Ultra tier and require a separate IOPS/throughput-based price lookup'
        }
    }

    return [pscustomobject]@{
        VMName                       = $Record.VMName
        RecommendedSKU               = $sku.Sku
        Family                       = $family
        vCPU                         = $sku.vCPU
        RAMGB                        = $sku.RAMGB
        EffectiveVCPURequired        = $effVCPU.Value
        EffectiveRAMGBRequired       = $effRAM.Value
        SizingBasis                  = "$($effVCPU.Basis); $($effRAM.Basis)"
        DiskTierGB                   = @($diskTierGB)
        DiskPerformanceTiers         = @($diskPerfTiers)
        EstimatedMonthlyComputeCost  = $computeCost
        EstimatedMonthlyStorageCost  = if ($storageCost -gt 0 -or -not $storageCostIsPartial) { [Math]::Round($storageCost, 2) } else { $null }
        EstimatedMonthlyTotalCost    = $totalCost
        Currency                     = $Currency
        Region                       = $Region
        TrustedLaunchEligible        = $trustedLaunchEligible
        CostNote                     = $costNote
        Warnings                     = @($warnings)
    }
}

# ============================================================================
# Main
# ============================================================================

$vmRecords = New-Object System.Collections.Generic.List[object]
$skippedVMs = New-Object System.Collections.Generic.List[string]

if ($PSCmdlet.ParameterSetName -eq 'Manual') {
    $disks = $DiskSizesGB | ForEach-Object {
        [pscustomobject]@{
            SizeGB = $_; FileSizeGB = $null; IsDifferencing = $false; IsPassThrough = $false
            ReadIOPSAvg = $null; WriteIOPSAvg = $null; ReadThroughputMBpsAvg = $null; WriteThroughputMBpsAvg = $null
        }
    }
    $vmRecords.Add((New-NormalizedVmRecord `
        -VMName $VMName -ProcessorCount $vCPU -CPUUsagePercentAvg $null -CPUUsagePercentMax $null `
        -MemoryAssignedGB $RAMGB -MemoryMaximumGB $null -DynamicMemoryEnabled $false -MemoryDemandGB $null `
        -Disks $disks -Generation $Generation -SecureBootEnabled ([bool]$SecureBoot.IsPresent) -TpmEnabled $null `
        -GuestOSName $GuestOS -SourceWarnings @()))
} else {
    $loaded = Import-VmSizingRecords -InputCsv $InputCsv -InputJson $InputJson -SkippedVMs $skippedVMs

    if ($NameFilter) {
        $matched = $loaded | Where-Object {
            if ($CaseSensitive) { $_.VMName -cmatch $NameFilter } else { $_.VMName -match $NameFilter }
        }
        Write-Host "NameFilter '$NameFilter' matched $($matched.Count) of $($loaded.Count) VM(s)." -ForegroundColor Cyan
        if (-not $matched -or @($matched).Count -eq 0) {
            throw "NameFilter '$NameFilter' matched zero VMs out of $($loaded.Count) loaded records. Check the regex and try again."
        }
        $loaded = $matched
    }

    foreach ($rec in $loaded) { $vmRecords.Add($rec) }
}

$recommendations = New-Object System.Collections.Generic.List[object]
$priceCache = @{}

foreach ($record in $vmRecords) {
    if (-not $record.VMName -or $record.ProcessorCount -le 0) {
        Write-Warning "Skipping VM '$($record.VMName)': missing VMName or vCPU count."
        $skippedVMs.Add("$($record.VMName) - missing VMName/vCPU")
        continue
    }

    try {
        $recommendations.Add((Get-VMSizingRecommendation -Record $record -PriceCache $priceCache -Region $Region -Currency $Currency))
    } catch {
        Write-Warning "Skipping VM '$($record.VMName)': $($_.Exception.Message)"
        $skippedVMs.Add("$($record.VMName) - $($_.Exception.Message)")
    }
}

if ($recommendations.Count -eq 0) {
    Write-Warning 'No recommendations produced.'
    if ($skippedVMs.Count -gt 0) {
        Write-Host "`nSkipped $($skippedVMs.Count) VM(s):" -ForegroundColor Yellow
        $skippedVMs | ForEach-Object { Write-Host "  $_" -ForegroundColor Yellow }
    }
    return
}

if (-not (Test-Path -LiteralPath $OutputDirectory)) {
    New-Item -ItemType Directory -Path $OutputDirectory -Force | Out-Null
}

$csvPath = Join-Path $OutputDirectory "$OutputBaseName.csv"
$jsonPath = Join-Path $OutputDirectory "$OutputBaseName.json"

$csvRows = $recommendations | Select-Object VMName, RecommendedSKU, Family, vCPU, RAMGB,
    EffectiveVCPURequired, EffectiveRAMGBRequired, SizingBasis,
    @{N = 'DiskTierGB'; E = { $_.DiskTierGB -join '|' } },
    @{N = 'DiskPerformanceTiers'; E = { $_.DiskPerformanceTiers -join '|' } },
    EstimatedMonthlyComputeCost, EstimatedMonthlyStorageCost, EstimatedMonthlyTotalCost, Currency, Region,
    TrustedLaunchEligible, CostNote,
    @{N = 'Warnings'; E = { $_.Warnings -join '|' } }

$csvRows | Export-Csv -LiteralPath $csvPath -NoTypeInformation -Encoding UTF8
$recommendations | ConvertTo-Json -Depth 6 | Out-File -LiteralPath $jsonPath -Encoding UTF8

Write-Host "`nRecommendations written:" -ForegroundColor Green
Write-Host "CSV  : $csvPath" -ForegroundColor Green
Write-Host "JSON : $jsonPath" -ForegroundColor Green

Write-Host "`n===== Recommendation Summary (sorted by estimated monthly cost, descending) =====" -ForegroundColor Cyan
$recommendations |
    Sort-Object -Property @{ Expression = { if ($null -ne $_.EstimatedMonthlyTotalCost) { $_.EstimatedMonthlyTotalCost } else { -1 } } } -Descending |
    Select-Object VMName, RecommendedSKU, vCPU, RAMGB, EstimatedMonthlyComputeCost, EstimatedMonthlyStorageCost, EstimatedMonthlyTotalCost, Currency,
        @{N = 'Warnings'; E = { if ($_.Warnings.Count -gt 0) { "$($_.Warnings.Count) warning(s)" } else { '' } } } |
    Format-Table -AutoSize | Out-Host

if ($recommendations.Count -gt 1) {
    $priced = $recommendations | Where-Object { $null -ne $_.EstimatedMonthlyTotalCost }
    $totalCost = ($priced | Measure-Object -Property EstimatedMonthlyTotalCost -Sum).Sum
    Write-Host "`nFleet total estimated monthly cost: $([Math]::Round($totalCost, 2)) $Currency (based on $($priced.Count) of $($recommendations.Count) priced VMs)" -ForegroundColor Green
    $unpriced = $recommendations.Count - $priced.Count
    if ($unpriced -gt 0) {
        Write-Host "$unpriced VM(s) excluded from the total due to failed price lookups - see CostNote in the output files." -ForegroundColor Yellow
    }
}

if ($skippedVMs.Count -gt 0) {
    Write-Host "`nSkipped $($skippedVMs.Count) VM(s):" -ForegroundColor Yellow
    $skippedVMs | ForEach-Object { Write-Host "  $_" -ForegroundColor Yellow }
}
