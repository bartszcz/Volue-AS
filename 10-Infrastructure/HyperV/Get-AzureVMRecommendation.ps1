# Get-AzureVMRecommendation.ps1 - recommends an Azure VM SKU + estimated monthly cost for Hyper-V VMs
# bartek / volue ito / 2026-07

# manual: .\Get-AzureVMRecommendation.ps1 -VMName APP01 -vCPU 4 -RAMGB 16 -DiskSizesGB 127,512 -SecureBoot -GuestOS 'Windows Server 2022 Standard'
# batch:  .\Get-AzureVMRecommendation.ps1 -InputJson C:\Temp\Get-HyperVAzureSizingInfo\Get-HyperVAzureSizingInfo_<stamp>.json
# subset: add -NameFilter '^SQL\d{2}-(PROD|UAT)$' (regex on VMName)
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
    [string] $OutputPath = 'C:\Temp\Get-AzureVMRecommendation'
)

# --- settings ---

$CpuHeadroomFactor = 1.3    # sizing margin on top of observed peak cpu
$RamHeadroomFactor = 1.15   # sizing margin on top of sampled memory demand
$RamPerVcpuForE    = 6      # >6 GB/vCPU -> E-series (memory optimized)
$RamPerVcpuForF    = 3      # <3 GB/vCPU -> F-series (compute optimized), else D-series
$HoursPerMonth     = 730

# disk escalates standard ssd -> premium ssd -> premium v2/ultra on summed avg read+write io
$PremiumIopsThreshold  = 500
$PremiumTputThreshold  = 60     # MB/s
$UltraIopsThreshold    = 20000
$UltraTputThreshold    = 900    # MB/s

$PriceApiMaxPages   = 5
$PriceApiTimeoutSec = 20

# reference data - static on purpose, sizing needs no API call, only pricing does
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

# --- functions ---

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
    # json round-trip can wrap a scalar in a one-item array - unwrap before casting
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
    # canonical shape every sizing function consumes, regardless of input source
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
    # understands two csv/json shapes: the Get-HyperVAzureSizingInfo.ps1 collector schema
    # and a simple hand-written one (VMName, vCPU, RAMGB, DiskSizesGB, GuestOS)
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
        # strip BOM/junk before the first [ or { - re-encoded files made ConvertFrom-Json fail silently
        $jsonStart = $jsonText.IndexOfAny(@('[', '{'))
        if ($jsonStart -gt 0) { $jsonText = $jsonText.Substring($jsonStart) }
        # ps5.1 ConvertFrom-Json emits a json array as ONE pipeline object, so
        # @(pipe) wraps it instead of enumerating - assign first, then @()
        $parsed = ConvertFrom-Json -InputObject $jsonText
        $rawRows = @($parsed)
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
                # simple manual-style schema
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
        $eff = [Math]::Ceiling($Record.ProcessorCount * ($Record.CPUUsagePercentMax / 100.0) * $CpuHeadroomFactor)
        if ($eff -lt 1) { $eff = 1 }
        if ($eff -gt $Record.ProcessorCount) { $eff = $Record.ProcessorCount }
        return [pscustomobject]@{ Value = [int]$eff; Basis = "peak utilization ($($Record.CPUUsagePercentMax)% observed, x$CpuHeadroomFactor headroom)" }
    }
    return [pscustomobject]@{ Value = [Math]::Max(1, $Record.ProcessorCount); Basis = 'allocated vCPU (no utilization data)' }
}

function Resolve-EffectiveRAMGB {
    param($Record)
    if ($Record.MemoryDemandGB) {
        # demand > assigned/max is a stale dynamic memory counter, not a real requirement -
        # clamp to the ceiling and warn instead of sizing off the bogus figure
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

        $eff = [Math]::Ceiling($Record.MemoryDemandGB * $RamHeadroomFactor)
        return [pscustomobject]@{ Value = $eff; Basis = "sampled memory demand ($($Record.MemoryDemandGB) GB, x$RamHeadroomFactor headroom)"; Warning = $null }
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
    if ($ratio -gt $RamPerVcpuForE) { return 'E' }
    if ($ratio -lt $RamPerVcpuForF) { return 'F' }
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

    if ($iops -gt $UltraIopsThreshold -or $tput -gt $UltraTputThreshold) {
        return [pscustomobject]@{ Tier = 'Premium SSD v2/Ultra'; Warning = 'Storage cost for this disk requires the Retail Prices API IOPS/throughput meters - call separately, not included in EstimatedMonthlyStorageCost.' }
    }
    if ($iops -gt $PremiumIopsThreshold -or $tput -gt $PremiumTputThreshold) {
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
    # lowest consumption price for a sku/region, excluding spot/low-priority meters.
    # returns $null instead of throwing so a failed lookup never kills the batch
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
        while ($uri -and $page -lt $PriceApiMaxPages) {
            $response = Invoke-RestMethod -Uri $uri -Method Get -ErrorAction Stop -TimeoutSec $PriceApiTimeoutSec
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

# sizing engine - one normalized record in, one recommendation object out
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

    # disks
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

    # trusted launch
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

    # guest os / hybrid benefit
    $isWindowsGuest = $Record.GuestOSName -like '*Windows*'
    if (-not (Test-EndorsedGuestOS -OSName $Record.GuestOSName)) {
        $osLabel = if ($Record.GuestOSName) { $Record.GuestOSName } else { '(unknown)' }
        $warnings.Add("Guest OS '$osLabel' not found in the endorsed-OS reference list - verify Azure endorsement manually.")
    }
    if ($isWindowsGuest) {
        $warnings.Add('Windows Server guest detected - potentially eligible for Azure Hybrid Benefit; confirm an existing eligible license before assuming the discount.')
    }

    # cost
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
        $computeCost = [Math]::Round($hourlyPrice * $HoursPerMonth, 2)
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

# --- main ---

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

try {
    if (-not (Test-Path -LiteralPath $OutputPath)) {
        New-Item -ItemType Directory -Path $OutputPath -Force -ErrorAction Stop | Out-Null
    }
} catch {
    throw "Could not create output directory '$OutputPath': $($_.Exception.Message)"
}

$stamp = Get-Date -Format 'yyyyMMdd_HHmm'
$csvPath = Join-Path $OutputPath "Get-AzureVMRecommendation_$stamp.csv"
$jsonPath = Join-Path $OutputPath "Get-AzureVMRecommendation_$stamp.json"

$csvRows = $recommendations | Select-Object VMName, RecommendedSKU, Family, vCPU, RAMGB,
    EffectiveVCPURequired, EffectiveRAMGBRequired, SizingBasis,
    @{N = 'DiskTierGB'; E = { $_.DiskTierGB -join '|' } },
    @{N = 'DiskPerformanceTiers'; E = { $_.DiskPerformanceTiers -join '|' } },
    EstimatedMonthlyComputeCost, EstimatedMonthlyStorageCost, EstimatedMonthlyTotalCost, Currency, Region,
    TrustedLaunchEligible, CostNote,
    @{N = 'Warnings'; E = { $_.Warnings -join '|' } }

try {
    $csvRows | Export-Csv -LiteralPath $csvPath -NoTypeInformation -Encoding UTF8
    $recommendations | ConvertTo-Json -Depth 6 | Out-File -LiteralPath $jsonPath -Encoding UTF8
} catch {
    throw "Failed to write output files to '$OutputPath': $($_.Exception.Message)"
}

Write-Host "`nDone. Exported to:" -ForegroundColor Green
Write-Host "CSV  : $csvPath" -ForegroundColor Green
Write-Host "JSON : $jsonPath" -ForegroundColor Green

Write-Host "`nRecommendation summary (sorted by estimated monthly cost, descending):" -ForegroundColor Cyan
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
