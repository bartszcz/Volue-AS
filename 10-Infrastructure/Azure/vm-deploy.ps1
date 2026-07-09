# deploys a vm from a standard order form: rg, network (new or existing vnet), optional public ip / bastion,
# vm from any marketplace image (with plan/terms handling), optional data disk, backup, auto-shutdown,
# cpu alert, local accounts / entra login for access users
# interactive: run without parameters and it prompts for everything (pick lists where possible,
# enter accepts the shown default). any parameter passed on the command line is not asked again.
# checks permissions, resource providers and vcpu quota before creating anything
# safe to re-run: existing resources are found and skipped
# -DryRun shows what would happen without changing anything; normal run asks y/n before each change
#
# example - sp-mikro order, non-interactive:
#   .\vm-deploy.ps1 -VMName sp-mikro -SubscriptionName "Trading - Smarpulse - Prod" `
#       -CostOwner murat.yilmaz@volue.com -TechnicalOwner hilmi.sozer@volue.com `
#       -Department Accounting -Team Smartpulse -VMFunction "Accounting Software" `
#       -DataDiskSizeGB 256 -TicketNumber "REQ0012345" `
#       -AccessUsers hilmi.sozer@volue.com,diyar.turk@volue.com,recep.guleryuz@volue.com `
#       -CreateLocalAccounts $true -DryRun
#
# batch mode: -OrderCsv C:\Temp\orders.csv - one row per vm, column names = parameter names,
# AccessUsers separated with ";". missing columns are prompted per vm.
#
# access: vms are often not peered with AD, so -CreateLocalAccounts makes local accounts on the box
# (password per user prompted at runtime). -EnableEntraLogin only works with entra-joined clients
# and a network path to the vm. access users always end up in the "Access Users" tag either way.

param(
    [string]$VMName,
    [string]$SubscriptionName,
    [string]$CostOwner,
    [string]$TechnicalOwner,
    [string]$Location,
    [string]$VMSize,
    [int]$OSDiskSizeGB,
    [int]$DataDiskSizeGB,
    [string]$ImagePublisher,         # any marketplace image works; third party plans/terms handled automatically
    [string]$ImageOffer,
    [string]$ImageSku,
    [string]$SecurityType,           # empty = auto (TrustedLaunch for gen2 images, Standard otherwise)
    [string]$AdminUsername,          # password prompted at runtime, never stored
    [string]$VnetName,               # empty = new vnet named vnet-<vmname>
    [string]$VnetResourceGroup,      # set together with VnetName to use an existing vnet in another rg
    [string]$SubnetName,
    [string]$VnetAddressSpace,       # only used when creating a new vnet - check with network team
    [string]$SubnetPrefix,
    [string]$RdpSourcePrefix,        # where rdp is allowed from - tighten to office/vpn range
    [bool]$CreatePublicIp,           # standard static public ip on the nic
    [bool]$DeployBastion,            # bastion basic in the vnet - costs run while it exists
    [string]$BastionSubnetPrefix,
    [string[]]$AccessUsers,          # upns from the order form
    [string]$AccessRole,             # "Virtual Machine Administrator Login" or "Virtual Machine User Login"
    [bool]$CreateLocalAccounts,      # create a local account per access user on the vm
    [string]$LocalAccountGroup,      # "Remote Desktop Users" or "Administrators"
    [string]$Department,
    [string]$Team,
    [string]$VMFunction,
    [string]$TicketNumber,
    [string]$Environment = "Production",
    [bool]$EnableBackup,
    [string]$BackupPolicyName,       # empty = pick from vault policies interactively, fallback DefaultPolicy
    [string]$AutoShutdownTime,       # "19:00" style, empty = no auto-shutdown
    [bool]$EnableCpuAlert,           # cpu alert with email to AlertEmail
    [string]$AlertEmail,             # empty = technical owner
    [bool]$EnableEntraLogin,         # needs entra-joined client + network path to the vm
    [bool]$UseHybridBenefit,         # true if windows license covered by SA / hybrid benefit
    [string]$OrderCsv,               # batch mode: csv with one row per vm
    [switch]$DryRun,
    [string]$OutputPath = "C:\Temp\vm-deploy"
)

# --- settings ---
$TenantId             = "9ce76d42-5ecb-4d8f-939b-a462ad28cf34"
$ImageVersion         = "latest"
$DiskSku              = "Premium_LRS"
$AutoShutdownTimeZone = "W. Europe Standard Time"
$CpuAlertThreshold    = 90

$RequiredModules      = @("Az.Accounts", "Az.Resources", "Az.Compute", "Az.Network", "Az.RecoveryServices")
$ProviderWaitAttempts = 30
$ProviderWaitSeconds  = 10

# --- functions ---

# returns $true when the change should be made, $false on dry run or when the user says no
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

# prompt with default, enter accepts the default
function Read-Value ($Prompt, $Default) {
    if ("$Default" -ne "") { $Answer = Read-Host "$Prompt [$Default]" } else { $Answer = Read-Host $Prompt }
    if ([string]::IsNullOrWhiteSpace($Answer)) { return $Default }
    return $Answer.Trim()
}

function Read-Required ($Prompt) {
    while ($true) {
        $Answer = Read-Host $Prompt
        if (-not [string]::IsNullOrWhiteSpace($Answer)) { return $Answer.Trim() }
        Write-Host "A value is required here" -ForegroundColor Yellow
    }
}

function Read-Int ($Prompt, $Default) {
    while ($true) {
        $Answer = Read-Host "$Prompt [$Default]"
        if ([string]::IsNullOrWhiteSpace($Answer)) { return $Default }
        $Num = 0
        if ([int]::TryParse($Answer, [ref]$Num)) { return $Num }
        Write-Host "Enter a number" -ForegroundColor Yellow
    }
}

function Read-YesNo ($Prompt, $Default) {
    $Hint = "y/N"
    if ($Default) { $Hint = "Y/n" }
    $Answer = Read-Host "$Prompt ($Hint)"
    if ([string]::IsNullOrWhiteSpace($Answer)) { return $Default }
    return ($Answer -match "^[Yy]")
}

# numbered pick list. returns the chosen option text; with -AllowCustom any other input is taken as a value
function Read-Choice ($Prompt, $Options, $DefaultIndex, [switch]$AllowCustom) {
    Write-Host $Prompt
    for ($i = 0; $i -lt $Options.Count; $i++) { Write-Host ("  {0}. {1}" -f ($i + 1), $Options[$i]) }
    $Hint = "1-$($Options.Count)"
    if ($AllowCustom) { $Hint = "$Hint or type a value" }
    while ($true) {
        $Answer = Read-Host "Choice $Hint [$($DefaultIndex + 1)]"
        if ([string]::IsNullOrWhiteSpace($Answer)) { return $Options[$DefaultIndex] }
        $Num = 0
        if ([int]::TryParse($Answer, [ref]$Num) -and $Num -ge 1 -and $Num -le $Options.Count) { return $Options[$Num - 1] }
        if ($AllowCustom) { return $Answer.Trim() }
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

# reuse an existing login when it matches the tenant - also what makes batch mode log in only once
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

# --- batch mode - one row per vm, columns named like the parameters ---

if ($OrderCsv) {
    if (-not (Test-Path $OrderCsv)) { Write-Error "Order csv not found: $OrderCsv"; return }
    try {
        $Orders = @(Import-Csv -Path $OrderCsv)
    } catch {
        Write-Error "Reading $OrderCsv failed: $($_.Exception.Message)"
        return
    }
    if ($Orders.Count -eq 0) { Write-Error "No rows in $OrderCsv"; return }

    $KnownParams = @("VMName","SubscriptionName","CostOwner","TechnicalOwner","Location","VMSize","OSDiskSizeGB","DataDiskSizeGB",
        "ImagePublisher","ImageOffer","ImageSku","SecurityType","AdminUsername","VnetName","VnetResourceGroup","SubnetName",
        "VnetAddressSpace","SubnetPrefix","RdpSourcePrefix","CreatePublicIp","DeployBastion","BastionSubnetPrefix",
        "AccessUsers","AccessRole","CreateLocalAccounts","LocalAccountGroup","Department","Team","VMFunction","TicketNumber",
        "Environment","EnableBackup","BackupPolicyName","AutoShutdownTime","EnableCpuAlert","AlertEmail","EnableEntraLogin","UseHybridBenefit")
    $BoolParams = @("CreatePublicIp","DeployBastion","CreateLocalAccounts","EnableBackup","EnableCpuAlert","EnableEntraLogin","UseHybridBenefit")
    $IntParams  = @("OSDiskSizeGB","DataDiskSizeGB")

    $Unknown = @($Orders[0].PSObject.Properties.Name | Where-Object { $KnownParams -notcontains $_ })
    if ($Unknown.Count -gt 0) { Write-Warning "Ignoring unknown csv columns: $($Unknown -join ', ')" }

    $RowNum = 0
    foreach ($Row in $Orders) {
        $RowNum++
        $Splat = @{}
        foreach ($Prop in $Row.PSObject.Properties) {
            if ($KnownParams -notcontains $Prop.Name) { continue }
            $Val = "$($Prop.Value)".Trim()
            if ($Val -eq "") { continue }
            if ($Prop.Name -eq "AccessUsers") {
                $Splat[$Prop.Name] = @($Val -split ";" | ForEach-Object { $_.Trim() } | Where-Object { $_ })
            } elseif ($BoolParams -contains $Prop.Name) {
                $Splat[$Prop.Name] = ($Val -match "^(true|yes|y|1)$")
            } elseif ($IntParams -contains $Prop.Name) {
                $Splat[$Prop.Name] = [int]$Val
            } else {
                $Splat[$Prop.Name] = $Val
            }
        }
        Write-Host ""
        Write-Host "=== order $RowNum of $($Orders.Count): $($Splat["VMName"]) ===" -ForegroundColor Cyan
        & $PSCommandPath @Splat -DryRun:$DryRun -OutputPath $OutputPath
    }
    Write-Host ""
    Write-Host "Batch done, $($Orders.Count) orders processed."
    return
}

# --- interactive input - anything not passed as a parameter gets prompted ---

if (-not $PSBoundParameters.ContainsKey("SubscriptionName")) {
    try {
        $Subs = @(Get-AzSubscription -TenantId $TenantId -ErrorAction Stop | Sort-Object Name)
    } catch {
        Write-Error "Listing subscriptions failed: $($_.Exception.Message)"
        return
    }
    if ($Subs.Count -eq 0) { Write-Error "No subscriptions visible in tenant $TenantId"; return }
    if ($Subs.Count -eq 1) {
        $SubscriptionName = $Subs[0].Name
        Write-Host "Only one subscription visible, using '$SubscriptionName'"
    } else {
        $SubscriptionName = Read-Choice "Subscription:" @($Subs | ForEach-Object { $_.Name }) 0
    }
}

try {
    Set-AzContext -Subscription $SubscriptionName -Tenant $TenantId -ErrorAction Stop | Out-Null
} catch {
    Write-Error "Subscription selection failed: $($_.Exception.Message)"
    return
}
$Context = Get-AzContext
$SubId   = $Context.Subscription.Id
Write-Host "Using subscription '$SubscriptionName' ($SubId)"

if (-not $PSBoundParameters.ContainsKey("VMName")) { $VMName = Read-Required "VM name" }

if (-not $PSBoundParameters.ContainsKey("Location")) {
    $Location = Read-Choice "Region:" @("westeurope", "northeurope", "norwayeast", "germanywestcentral") 0 -AllowCustom
}

if (-not $PSBoundParameters.ContainsKey("VMSize")) {
    $Pick = Read-Choice "VM size:" @(
        "Standard_D2s_v5 (2 vcpu, 8 gb)",
        "Standard_D4s_v5 (4 vcpu, 16 gb) - order form default",
        "Standard_D8s_v5 (8 vcpu, 32 gb)",
        "Standard_E4s_v5 (4 vcpu, 32 gb, memory heavy)"
    ) 1 -AllowCustom
    $VMSize = ($Pick -split " ")[0]
}

if (-not $PSBoundParameters.ContainsKey("ImageSku") -and -not $PSBoundParameters.ContainsKey("ImagePublisher")) {
    $Pick = Read-Choice "Operating system / image:" @(
        "2022-datacenter-azure-edition (windows server 2022)",
        "2025-datacenter-azure-edition (windows server 2025)",
        "2019-datacenter-gensecond (windows server 2019)",
        "search the azure marketplace for another image"
    ) 0 -AllowCustom
    if ($Pick -like "search the azure marketplace*") {
        # cascading marketplace search: term -> publisher -> offer -> sku
        while (-not $ImageSku) {
            $Term = Read-Required "Search term for image publisher (e.g. sql, canonical, fortinet)"
            try {
                $Pubs = @(Get-AzVMImagePublisher -Location $Location -ErrorAction Stop | Where-Object { $_.PublisherName -like "*$Term*" })
            } catch {
                Write-Error "Publisher search failed: $($_.Exception.Message)"
                return
            }
            if ($Pubs.Count -eq 0) { Write-Host "No publishers match '$Term', try again" -ForegroundColor Yellow; continue }
            if ($Pubs.Count -gt 30) {
                Write-Host "Showing first 30 of $($Pubs.Count) matches - refine the term if yours is missing" -ForegroundColor Yellow
                $Pubs = @($Pubs | Select-Object -First 30)
            }
            $ImagePublisher = Read-Choice "Publisher:" @($Pubs | ForEach-Object { $_.PublisherName }) 0
            try {
                $Offers = @(Get-AzVMImageOffer -Location $Location -PublisherName $ImagePublisher -ErrorAction Stop)
            } catch {
                Write-Error "Offer lookup failed: $($_.Exception.Message)"
                return
            }
            if ($Offers.Count -eq 0) { Write-Host "Publisher has no offers in $Location, search again" -ForegroundColor Yellow; $ImagePublisher = ""; continue }
            $ImageOffer = Read-Choice "Offer:" @($Offers | ForEach-Object { $_.Offer }) 0
            try {
                $Skus = @(Get-AzVMImageSku -Location $Location -PublisherName $ImagePublisher -Offer $ImageOffer -ErrorAction Stop)
            } catch {
                Write-Error "Sku lookup failed: $($_.Exception.Message)"
                return
            }
            if ($Skus.Count -eq 0) { Write-Host "Offer has no skus in $Location, search again" -ForegroundColor Yellow; continue }
            $ImageSku = Read-Choice "Sku:" @($Skus | ForEach-Object { $_.Skus }) 0
        }
    } else {
        $ImageSku = ($Pick -split " ")[0]
    }
}

if (-not $PSBoundParameters.ContainsKey("OSDiskSizeGB"))   { $OSDiskSizeGB   = Read-Int "OS disk size in GB" 160 }
if (-not $PSBoundParameters.ContainsKey("DataDiskSizeGB")) { $DataDiskSizeGB = Read-Int "Data disk size in GB (0 = no data disk)" 0 }
if (-not $PSBoundParameters.ContainsKey("AdminUsername"))  { $AdminUsername  = Read-Value "Local admin username" "vmadmin" }
if (-not $PSBoundParameters.ContainsKey("UseHybridBenefit")) { $UseHybridBenefit = Read-YesNo "Use azure hybrid benefit for the windows license?" $false }

if (-not $PSBoundParameters.ContainsKey("CostOwner"))      { $CostOwner      = Read-Required "Cost owner (email)" }
if (-not $PSBoundParameters.ContainsKey("TechnicalOwner")) { $TechnicalOwner = Read-Required "Technical owner (email)" }
if (-not $PSBoundParameters.ContainsKey("Department"))     { $Department     = Read-Value "Department (empty to skip tag)" "" }
if (-not $PSBoundParameters.ContainsKey("Team"))           { $Team           = Read-Value "Team / project (empty to skip tag)" "" }
if (-not $PSBoundParameters.ContainsKey("VMFunction"))     { $VMFunction     = Read-Value "VM function (empty to skip tag)" "" }
if (-not $PSBoundParameters.ContainsKey("TicketNumber"))   { $TicketNumber   = Read-Value "Ticket / order number (empty to skip tag)" "" }

if (-not $PSBoundParameters.ContainsKey("VnetName")) {
    $NetMode = Read-Choice "Network:" @("create a new vnet for this vm", "use an existing vnet") 0
    if ($NetMode -like "use an existing*") {
        try {
            $AllVnets = @(Get-AzVirtualNetwork -ErrorAction Stop)
        } catch {
            Write-Error "Listing vnets failed: $($_.Exception.Message)"
            return
        }
        if ($AllVnets.Count -eq 0) {
            Write-Host "No vnets in this subscription, creating a new one instead" -ForegroundColor Yellow
        } else {
            $VnetPick = Read-Choice "VNet:" @($AllVnets | ForEach-Object { "$($_.Name)  rg=$($_.ResourceGroupName)  $(@($_.AddressSpace.AddressPrefixes) -join ',')" }) 0
            $SelVnet = $AllVnets | Where-Object { $VnetPick -like "$($_.Name)  rg=$($_.ResourceGroupName)*" } | Select-Object -First 1
            $VnetName          = $SelVnet.Name
            $VnetResourceGroup = $SelVnet.ResourceGroupName
            $SubOptions = @($SelVnet.Subnets | Where-Object { $_.Name -ne "AzureBastionSubnet" } | ForEach-Object { "$($_.Name) ($(@($_.AddressPrefix) -join ','))" })
            $SubOptions += "new subnet in this vnet"
            $SubPick = Read-Choice "Subnet:" $SubOptions 0
            if ($SubPick -eq "new subnet in this vnet") {
                $SubnetName   = Read-Required "New subnet name"
                $SubnetPrefix = Read-Required "New subnet prefix (cidr, must fit the vnet address space)"
            } else {
                $SubnetName = ($SubPick -split " ")[0]
            }
        }
    }
    if (-not $VnetName) {
        $VnetAddressSpace = Read-Value "New vnet address space (check with network team)" "10.200.0.0/24"
        $SubnetPrefix     = Read-Value "Subnet prefix" "10.200.0.0/26"
    }
}

if (-not $PSBoundParameters.ContainsKey("CreatePublicIp")) { $CreatePublicIp = Read-YesNo "Add a public ip to the vm?" $false }
if (-not $PSBoundParameters.ContainsKey("RdpSourcePrefix")) {
    $RdpHint = "10.0.0.0/8"
    if ($CreatePublicIp) { $RdpHint = "" }
    if ($CreatePublicIp) {
        $RdpSourcePrefix = Read-Required "Allow rdp from (cidr) - vm gets a public ip, use your office/vpn PUBLIC range, never *"
    } else {
        $RdpSourcePrefix = Read-Value "Allow rdp from (cidr)" $RdpHint
    }
}
if (-not $PSBoundParameters.ContainsKey("DeployBastion")) { $DeployBastion = Read-YesNo "Deploy azure bastion for browser rdp (no peering needed, costs run while it exists)?" $false }
if ($DeployBastion -and -not $PSBoundParameters.ContainsKey("BastionSubnetPrefix")) {
    $BastionSubnetPrefix = Read-Value "AzureBastionSubnet prefix (/26 or larger, inside the vnet space)" "10.200.0.64/26"
}

if (-not $PSBoundParameters.ContainsKey("EnableBackup")) { $EnableBackup = Read-YesNo "Enable backup?" $true }

if (-not $PSBoundParameters.ContainsKey("AutoShutdownTime")) {
    while ($true) {
        $AutoShutdownTime = Read-Value "Auto-shutdown time HH:mm (empty = no auto-shutdown, prod vms usually none)" ""
        if (-not $AutoShutdownTime -or $AutoShutdownTime -match "^\d{1,2}:\d{2}$") { break }
        Write-Host "Use HH:mm, e.g. 19:00" -ForegroundColor Yellow
    }
}

if (-not $PSBoundParameters.ContainsKey("EnableCpuAlert")) { $EnableCpuAlert = Read-YesNo "Create a cpu alert (>$CpuAlertThreshold% for 15 min, emails the technical owner)?" $false }
if ($EnableCpuAlert -and -not $PSBoundParameters.ContainsKey("AlertEmail")) {
    $AlertEmail = Read-Value "Alert email" $TechnicalOwner
}

if (-not $PSBoundParameters.ContainsKey("AccessUsers")) {
    $Raw = Read-Value "Access users, comma separated emails (empty for none)" ""
    $AccessUsers = @($Raw -split "," | ForEach-Object { $_.Trim() } | Where-Object { $_ })
}
if (-not $AccessUsers) { $AccessUsers = @() }

if ($AccessUsers.Count -gt 0) {
    if (-not $PSBoundParameters.ContainsKey("CreateLocalAccounts")) {
        $CreateLocalAccounts = Read-YesNo "Create local accounts on the vm for the access users? (usual choice - vms rarely have a path to AD)" $true
    }
    if ($CreateLocalAccounts -and -not $PSBoundParameters.ContainsKey("LocalAccountGroup")) {
        $LocalAccountGroup = Read-Choice "Local group for the accounts:" @("Remote Desktop Users", "Administrators") 0
    }
    if (-not $PSBoundParameters.ContainsKey("EnableEntraLogin")) {
        $EnableEntraLogin = Read-YesNo "Also set up entra login? (needs entra-joined client + network path to the vm)" $false
    }
    if ($EnableEntraLogin -and -not $PSBoundParameters.ContainsKey("AccessRole")) {
        $AccessRole = Read-Choice "Entra login role for the access users:" @("Virtual Machine Administrator Login", "Virtual Machine User Login") 0
    }
}

# --- defaults for anything still empty ---

if (-not $ImagePublisher)      { $ImagePublisher = "MicrosoftWindowsServer" }
if (-not $ImageOffer)          { $ImageOffer = "WindowsServer" }
if (-not $ImageSku)            { $ImageSku = "2022-datacenter-azure-edition" }
if (-not $Location)            { $Location = "westeurope" }
if (-not $VMSize)              { $VMSize = "Standard_D4s_v5" }
if ($OSDiskSizeGB -le 0)       { $OSDiskSizeGB = 160 }
if (-not $AdminUsername)       { $AdminUsername = "vmadmin" }
if (-not $VnetName)            { $VnetName = "vnet-$VMName" }
if (-not $SubnetName)          { $SubnetName = "snet-$VMName" }
if (-not $VnetAddressSpace)    { $VnetAddressSpace = "10.200.0.0/24" }
if (-not $SubnetPrefix)        { $SubnetPrefix = "10.200.0.0/26" }
if (-not $RdpSourcePrefix)     { $RdpSourcePrefix = "10.0.0.0/8" }
if (-not $BastionSubnetPrefix) { $BastionSubnetPrefix = "10.200.0.64/26" }
if (-not $LocalAccountGroup)   { $LocalAccountGroup = "Remote Desktop Users" }
if (-not $AccessRole)          { $AccessRole = "Virtual Machine Administrator Login" }
if (-not $AlertEmail)          { $AlertEmail = $TechnicalOwner }

$ResourceGroupName = "rg-$VMName"
$NsgName           = "nsg-$VMName"
$NicName           = "$VMName-nic"
$VaultName         = "rsv-$VMName"
$VnetRG            = $ResourceGroupName
if ($VnetResourceGroup) { $VnetRG = $VnetResourceGroup }
$VnetIsExternal    = ($VnetRG -ne $ResourceGroupName)

$Tags = @{
    "Cost Owner"       = $CostOwner
    "Technical Owner"  = $TechnicalOwner
    "Environment Type" = $Environment
}
if ($Department)   { $Tags["Department"]  = $Department }
if ($Team)         { $Tags["Team"]        = $Team }
if ($VMFunction)   { $Tags["VM Function"] = $VMFunction }
if ($TicketNumber) { $Tags["Ticket"]      = $TicketNumber }
if ($AccessUsers.Count -gt 0) { $Tags["Access Users"] = ($AccessUsers -join ", ") }  # keeps the order info on the resource

# --- image check: plan (third party marketplace) and security type ---

$ImagePlan = $null
$SecurityTypeAuto = "TrustedLaunch"
try {
    $Versions = @(Get-AzVMImage -Location $Location -PublisherName $ImagePublisher -Offer $ImageOffer -Skus $ImageSku -ErrorAction Stop)
    if ($Versions.Count -eq 0) { throw "no versions found in $Location" }
    $LatestVer = ($Versions | Select-Object -Last 1).Version
    $ImageDetail = Get-AzVMImage -Location $Location -PublisherName $ImagePublisher -Offer $ImageOffer -Skus $ImageSku -Version $LatestVer -ErrorAction Stop
    if ($ImageDetail.PurchasePlan) { $ImagePlan = $ImageDetail.PurchasePlan }
    if ($ImageDetail.HyperVGeneration -ne "V2") { $SecurityTypeAuto = "Standard" }
    $PlanText = ""
    if ($ImagePlan) { $PlanText = ", marketplace plan - terms acceptance handled before deploy" }
    Write-Host "Image ok: $ImagePublisher / $ImageOffer / $ImageSku (gen $($ImageDetail.HyperVGeneration)$PlanText)"
} catch {
    Write-Warning "Could not verify image ${ImagePublisher}/${ImageOffer}/${ImageSku}: $($_.Exception.Message)"
    if ($ImagePublisher -ne "MicrosoftWindowsServer") { $SecurityTypeAuto = "Standard" }
}
if (-not $SecurityType) { $SecurityType = $SecurityTypeAuto }

# --- recap ---

$DataDiskText = "none"
if ($DataDiskSizeGB -gt 0) { $DataDiskText = "$DataDiskSizeGB GB" }
$LocalAccountText = "no"
if ($CreateLocalAccounts) { $LocalAccountText = "yes, group '$LocalAccountGroup'" }
$EntraText = "no"
if ($EnableEntraLogin) { $EntraText = "yes, role '$AccessRole'" }
$NetworkText = "$VnetName (new, $VnetAddressSpace, subnet $SubnetName $SubnetPrefix)"
if ($VnetIsExternal) { $NetworkText = "$VnetName (existing, rg $VnetRG, subnet $SubnetName)" }
$ShutdownText = "no"
if ($AutoShutdownTime) { $ShutdownText = "$AutoShutdownTime $AutoShutdownTimeZone" }
$AlertText = "no"
if ($EnableCpuAlert) { $AlertText = "cpu >$CpuAlertThreshold% -> $AlertEmail" }

Write-Host ""
Write-Host "Deployment settings:"
$Recap = [ordered]@{
    "Subscription"     = $SubscriptionName
    "VM name"          = $VMName
    "Region"           = $Location
    "Size"             = $VMSize
    "Image"            = "$ImagePublisher / $ImageOffer / $ImageSku"
    "Security"         = $SecurityType
    "OS disk"          = "$OSDiskSizeGB GB"
    "Data disk"        = $DataDiskText
    "Admin user"       = $AdminUsername
    "Hybrid benefit"   = $UseHybridBenefit
    "Resource group"   = $ResourceGroupName
    "Network"          = $NetworkText
    "Public IP"        = $CreatePublicIp
    "Bastion"          = $DeployBastion
    "RDP allowed from" = $RdpSourcePrefix
    "Backup"           = $EnableBackup
    "Auto-shutdown"    = $ShutdownText
    "CPU alert"        = $AlertText
    "Ticket"           = $TicketNumber
    "Cost owner"       = $CostOwner
    "Technical owner"  = $TechnicalOwner
    "Access users"     = ($AccessUsers -join ", ")
    "Local accounts"   = $LocalAccountText
    "Entra login"      = $EntraText
}
foreach ($Key in $Recap.Keys) { Write-Host ("  {0,-17} {1}" -f "${Key}:", $Recap[$Key]) }
Write-Host ""

if ($CreatePublicIp -and $RdpSourcePrefix -match "^(10\.|172\.(1[6-9]|2[0-9]|3[01])\.|192\.168\.)") {
    Write-Warning "Public ip requested but rdp is only allowed from a private range ($RdpSourcePrefix) - rdp over internet will not work with this rule."
}

if ($DryRun) {
    Write-Host "Dry run - nothing will be changed" -ForegroundColor Yellow
} else {
    $Answer = Read-Host "Proceed with these settings? (y/n)"
    if ($Answer -notmatch "^[Yy]") { Write-Host "Stopped, nothing was changed."; return }
}

# --- permission checks - fail early instead of halfway through ---

Write-Host "Checking permissions..."

if ($EnableCpuAlert -and -not (Get-Module -ListAvailable -Name Az.Monitor)) {
    Write-Error "Az.Monitor module is needed for the cpu alert. Install it first (Install-Module Az.Monitor)."
    return
}
if ($ImagePlan -and -not (Get-Module -ListAvailable -Name Az.MarketplaceOrdering)) {
    Write-Error "Az.MarketplaceOrdering module is needed for this marketplace image. Install it first (Install-Module Az.MarketplaceOrdering)."
    return
}

# rbac: need create rights on the subscription
if ($Context.Account.Type -eq "User") {
    try {
        $Assignments = Get-AzRoleAssignment -SignInName $Context.Account.Id -ExpandPrincipalGroups -Scope "/subscriptions/$SubId" -ErrorAction Stop
    } catch {
        Write-Error "Role assignment lookup failed - you likely have no access on this subscription: $($_.Exception.Message)"
        return
    }
    $Roles = @($Assignments | ForEach-Object { $_.RoleDefinitionName } | Sort-Object -Unique)
    if ($Roles -notcontains "Owner" -and $Roles -notcontains "Contributor") {
        # custom roles are not recognized here - comment this check out if you use one
        Write-Error "You need Owner or Contributor on the subscription to create resources. Your roles: $($Roles -join ', ')"
        return
    }
    Write-Host "RBAC: create rights ok (roles: $($Roles -join ', '))"
    if ($EnableEntraLogin -and $AccessUsers.Count -gt 0 `
        -and $Roles -notcontains "Owner" `
        -and $Roles -notcontains "User Access Administrator" `
        -and $Roles -notcontains "Role Based Access Control Administrator") {
        Write-Warning "No Owner / User Access Administrator role - assigning '$AccessRole' to access users will fail. Answer n on those confirms or get the rights first."
    }
} else {
    Write-Host "Signed in as $($Context.Account.Type), skipping rbac pre-check"
}

# resource providers: fresh subscriptions have nothing registered
$ProvidersToCheck = @("Microsoft.Compute", "Microsoft.Network", "Microsoft.Storage")
if ($EnableBackup)     { $ProvidersToCheck += "Microsoft.RecoveryServices" }
if ($AutoShutdownTime) { $ProvidersToCheck += "Microsoft.DevTestLab" }
if ($EnableCpuAlert)   { $ProvidersToCheck += "Microsoft.Insights" }
$Registering = @()
foreach ($Ns in $ProvidersToCheck) {
    try {
        $State = (Get-AzResourceProvider -ProviderNamespace $Ns -ErrorAction Stop | Select-Object -First 1).RegistrationState
    } catch {
        Write-Error "Resource provider check for $Ns failed: $($_.Exception.Message)"
        return
    }
    if ($State -eq "Registered") {
        Write-Host "Provider $Ns registered"
        continue
    }
    if (Confirm-Action "register resource provider $Ns (state: $State)") {
        try {
            Register-AzResourceProvider -ProviderNamespace $Ns -ErrorAction Stop | Out-Null
            $Registering += $Ns
            $Summary += [pscustomobject]@{ Action = "registering"; Item = "provider $Ns" }
        } catch {
            Write-Error "Registering provider $Ns failed: $($_.Exception.Message)"
            return
        }
    } elseif (-not $DryRun) {
        Write-Error "Provider $Ns is not registered - resource creation would fail. Stopping."
        return
    }
}

if ($Registering.Count -gt 0) {
    Write-Host "Waiting for provider registration..."
    $Attempt = 0
    do {
        $Attempt++
        Start-Sleep -Seconds $ProviderWaitSeconds
        $Pending = @()
        foreach ($Ns in $Registering) {
            $State = (Get-AzResourceProvider -ProviderNamespace $Ns -ErrorAction SilentlyContinue | Select-Object -First 1).RegistrationState
            if ($State -ne "Registered") { $Pending += "$Ns=$State" }
        }
        if ($Pending.Count -gt 0) { Write-Host "Attempt $Attempt`: $($Pending -join ', ')" }
    } while ($Pending.Count -gt 0 -and $Attempt -lt $ProviderWaitAttempts)
    if ($Pending.Count -gt 0) {
        Write-Error "Providers still registering after timeout: $($Pending -join ', '). Re-run the script in a few minutes."
        return
    }
    Write-Host "All providers registered"
}

# quota: size must exist in the region and regional vcpu quota must have room
try {
    $SizeInfo = Get-AzVMSize -Location $Location -ErrorAction Stop | Where-Object { $_.Name -eq $VMSize }
    if (-not $SizeInfo) {
        Write-Error "VM size $VMSize is not available in $Location."
        return
    }
    $CoreUsage = Get-AzVMUsage -Location $Location -ErrorAction Stop | Where-Object { $_.Name.Value -eq "cores" }
    if ($CoreUsage) {
        $Free = $CoreUsage.Limit - $CoreUsage.CurrentValue
        if ($Free -lt $SizeInfo.NumberOfCores) {
            Write-Error "Not enough regional vcpu quota in ${Location}: need $($SizeInfo.NumberOfCores), free $Free of $($CoreUsage.Limit). Request a quota increase first."
            return
        }
        Write-Host "Quota: ok ($($SizeInfo.NumberOfCores) vcpus needed, $Free free of $($CoreUsage.Limit) regional)"
    }
} catch {
    Write-Warning "Quota check skipped: $($_.Exception.Message)"
}

# --- resources ---

# resource group
$RG = Get-AzResourceGroup -Name $ResourceGroupName -ErrorAction SilentlyContinue
if ($RG) {
    Write-Host "Resource group $ResourceGroupName already exists"
    $Summary += [pscustomobject]@{ Action = "exists"; Item = "resource group $ResourceGroupName" }
} elseif (Confirm-Action "create resource group $ResourceGroupName in $Location") {
    try {
        $RG = New-AzResourceGroup -Name $ResourceGroupName -Location $Location -Tag $Tags -ErrorAction Stop
        Write-Host "Resource group $ResourceGroupName created"
        $Summary += [pscustomobject]@{ Action = "created"; Item = "resource group $ResourceGroupName" }
    } catch {
        Write-Error "Creating resource group failed: $($_.Exception.Message)"
        return
    }
}
if (-not $RG -and -not $DryRun) { Write-Host "No resource group - stopping" -ForegroundColor Yellow; return }

# vnet and subnet - existing vnets are used as-is, new ones are created in the vm resource group
$Vnet = Get-AzVirtualNetwork -Name $VnetName -ResourceGroupName $VnetRG -ErrorAction SilentlyContinue
if ($Vnet) {
    Write-Host "VNet $VnetName found (rg $VnetRG)"
    $Summary += [pscustomobject]@{ Action = "exists"; Item = "vnet $VnetName" }
} elseif ($VnetIsExternal) {
    Write-Error "VNet $VnetName not found in resource group $VnetRG."
    return
} elseif (Confirm-Action "create vnet $VnetName ($VnetAddressSpace) with subnet $SubnetName ($SubnetPrefix)") {
    try {
        $SubnetCfg = New-AzVirtualNetworkSubnetConfig -Name $SubnetName -AddressPrefix $SubnetPrefix
        $Vnet = New-AzVirtualNetwork -Name $VnetName -ResourceGroupName $ResourceGroupName -Location $Location `
            -AddressPrefix $VnetAddressSpace -Subnet $SubnetCfg -Tag $Tags -ErrorAction Stop
        Write-Host "VNet $VnetName created"
        $Summary += [pscustomobject]@{ Action = "created"; Item = "vnet $VnetName" }
    } catch {
        Write-Error "Creating vnet failed: $($_.Exception.Message)"
        return
    }
}

$Subnet = $null
if ($Vnet) {
    $Subnet = $Vnet.Subnets | Where-Object { $_.Name -eq $SubnetName } | Select-Object -First 1
    if (-not $Subnet -and (Confirm-Action "add subnet $SubnetName ($SubnetPrefix) to vnet $VnetName")) {
        try {
            Add-AzVirtualNetworkSubnetConfig -Name $SubnetName -AddressPrefix $SubnetPrefix -VirtualNetwork $Vnet -ErrorAction Stop | Out-Null
            $Vnet = Set-AzVirtualNetwork -VirtualNetwork $Vnet -ErrorAction Stop
            $Subnet = $Vnet.Subnets | Where-Object { $_.Name -eq $SubnetName } | Select-Object -First 1
            Write-Host "Subnet $SubnetName added"
            $Summary += [pscustomobject]@{ Action = "created"; Item = "subnet $SubnetName" }
        } catch {
            Write-Error "Adding subnet failed: $($_.Exception.Message)"
            return
        }
    }
}

# nsg with rdp rule
$Nsg = Get-AzNetworkSecurityGroup -Name $NsgName -ResourceGroupName $ResourceGroupName -ErrorAction SilentlyContinue
if ($Nsg) {
    Write-Host "NSG $NsgName already exists"
    $Summary += [pscustomobject]@{ Action = "exists"; Item = "nsg $NsgName" }
} elseif (Confirm-Action "create nsg $NsgName with rdp allowed from $RdpSourcePrefix") {
    try {
        $RdpRule = New-AzNetworkSecurityRuleConfig -Name "allow-rdp" -Protocol Tcp -Direction Inbound -Priority 1000 `
            -SourceAddressPrefix $RdpSourcePrefix -SourcePortRange * -DestinationAddressPrefix * -DestinationPortRange 3389 -Access Allow
        $Nsg = New-AzNetworkSecurityGroup -Name $NsgName -ResourceGroupName $ResourceGroupName -Location $Location `
            -SecurityRules $RdpRule -Tag $Tags -ErrorAction Stop
        Write-Host "NSG $NsgName created"
        $Summary += [pscustomobject]@{ Action = "created"; Item = "nsg $NsgName" }
    } catch {
        Write-Error "Creating nsg failed: $($_.Exception.Message)"
        return
    }
}

# public ip for the vm (optional)
$Pip = $null
if ($CreatePublicIp) {
    $PipName = "$VMName-pip"
    $Pip = Get-AzPublicIpAddress -Name $PipName -ResourceGroupName $ResourceGroupName -ErrorAction SilentlyContinue
    if ($Pip) {
        Write-Host "Public ip $PipName already exists ($($Pip.IpAddress))"
        $Summary += [pscustomobject]@{ Action = "exists"; Item = "public ip $PipName" }
    } elseif (Confirm-Action "create public ip $PipName (standard, static)") {
        try {
            $Pip = New-AzPublicIpAddress -Name $PipName -ResourceGroupName $ResourceGroupName -Location $Location `
                -Sku Standard -AllocationMethod Static -Tag $Tags -ErrorAction Stop
            Write-Host "Public ip $PipName created: $($Pip.IpAddress)"
            $Summary += [pscustomobject]@{ Action = "created"; Item = "public ip $PipName ($($Pip.IpAddress))" }
        } catch {
            Write-Error "Creating public ip failed: $($_.Exception.Message)"
            return
        }
    }
}

# nic
$Nic = Get-AzNetworkInterface -Name $NicName -ResourceGroupName $ResourceGroupName -ErrorAction SilentlyContinue
if ($Nic) {
    Write-Host "NIC $NicName already exists"
    $Summary += [pscustomobject]@{ Action = "exists"; Item = "nic $NicName" }
} elseif ($Subnet -and $Nsg) {
    $PipText = "no public ip"
    if ($Pip) { $PipText = "public ip $($Pip.IpAddress)" }
    if (Confirm-Action "create nic $NicName in subnet $SubnetName ($PipText)") {
        try {
            $NicArgs = @{
                Name                   = $NicName
                ResourceGroupName      = $ResourceGroupName
                Location               = $Location
                SubnetId               = $Subnet.Id
                NetworkSecurityGroupId = $Nsg.Id
                Tag                    = $Tags
                ErrorAction            = "Stop"
            }
            if ($Pip) { $NicArgs["PublicIpAddressId"] = $Pip.Id }
            $Nic = New-AzNetworkInterface @NicArgs
            Write-Host "NIC $NicName created"
            $Summary += [pscustomobject]@{ Action = "created"; Item = "nic $NicName" }
        } catch {
            Write-Error "Creating nic failed: $($_.Exception.Message)"
            return
        }
    }
} elseif ($DryRun) {
    Write-Host "DRY RUN: would create nic $NicName in subnet $SubnetName" -ForegroundColor Yellow
    $Summary += [pscustomobject]@{ Action = "dry run"; Item = "nic $NicName" }
}

# bastion (optional) - browser rdp without any peering
if ($DeployBastion) {
    $BastionName = "bas-$VMName"
    $Bastion = Get-AzBastion -ResourceGroupName $ResourceGroupName -Name $BastionName -ErrorAction SilentlyContinue
    if ($Bastion) {
        Write-Host "Bastion $BastionName already exists"
        $Summary += [pscustomobject]@{ Action = "exists"; Item = "bastion $BastionName" }
    } elseif (-not $Vnet) {
        if ($DryRun) {
            Write-Host "DRY RUN: would deploy bastion $BastionName" -ForegroundColor Yellow
            $Summary += [pscustomobject]@{ Action = "dry run"; Item = "bastion $BastionName" }
        }
    } elseif (Confirm-Action "deploy bastion $BastionName (sku Basic, takes ~10 min, billed while it exists)") {
        try {
            $BasSubnet = $Vnet.Subnets | Where-Object { $_.Name -eq "AzureBastionSubnet" } | Select-Object -First 1
            if (-not $BasSubnet) {
                Add-AzVirtualNetworkSubnetConfig -Name "AzureBastionSubnet" -AddressPrefix $BastionSubnetPrefix -VirtualNetwork $Vnet -ErrorAction Stop | Out-Null
                $Vnet = Set-AzVirtualNetwork -VirtualNetwork $Vnet -ErrorAction Stop
                Write-Host "AzureBastionSubnet added to $VnetName"
            }
            $BasPipName = "$BastionName-pip"
            $BasPip = Get-AzPublicIpAddress -Name $BasPipName -ResourceGroupName $ResourceGroupName -ErrorAction SilentlyContinue
            if (-not $BasPip) {
                $BasPip = New-AzPublicIpAddress -Name $BasPipName -ResourceGroupName $ResourceGroupName -Location $Location `
                    -Sku Standard -AllocationMethod Static -ErrorAction Stop
            }
            Write-Host "Creating bastion $BastionName, this takes a while..."
            New-AzBastion -ResourceGroupName $ResourceGroupName -Name $BastionName -PublicIpAddress $BasPip `
                -VirtualNetwork $Vnet -Sku "Basic" -ErrorAction Stop | Out-Null
            Write-Host "Bastion $BastionName created"
            $Summary += [pscustomobject]@{ Action = "created"; Item = "bastion $BastionName" }
        } catch {
            Write-Error "Creating bastion failed: $($_.Exception.Message)"
            return
        }
    }
}

# marketplace terms for third party images - must be accepted before the vm can deploy
if ($ImagePlan) {
    try {
        $Terms = Get-AzMarketplaceTerms -Publisher $ImagePlan.Publisher -Product $ImagePlan.Product -Name $ImagePlan.Name -ErrorAction Stop
    } catch {
        Write-Error "Marketplace terms lookup failed: $($_.Exception.Message)"
        return
    }
    if ($Terms.Accepted) {
        Write-Host "Marketplace terms for $($ImagePlan.Publisher)/$($ImagePlan.Product) already accepted"
        $Summary += [pscustomobject]@{ Action = "exists"; Item = "marketplace terms $($ImagePlan.Product)" }
    } elseif (Confirm-Action "accept marketplace terms for $($ImagePlan.Publisher)/$($ImagePlan.Product)/$($ImagePlan.Name) on this subscription") {
        try {
            $Terms | Set-AzMarketplaceTerms -Accept -ErrorAction Stop | Out-Null
            Write-Host "Marketplace terms accepted"
            $Summary += [pscustomobject]@{ Action = "accepted"; Item = "marketplace terms $($ImagePlan.Product)" }
        } catch {
            Write-Error "Accepting marketplace terms failed: $($_.Exception.Message)"
            return
        }
    } elseif (-not $DryRun) {
        Write-Error "Terms not accepted - the vm deployment would fail. Stopping."
        return
    }
}

# vm
$DiskText = "$OSDiskSizeGB GB os"
if ($DataDiskSizeGB -gt 0) { $DiskText = "$DiskText + $DataDiskSizeGB GB data disk" }
$VM = Get-AzVM -ResourceGroupName $ResourceGroupName -Name $VMName -ErrorAction SilentlyContinue
if ($VM) {
    Write-Host "VM $VMName already exists, skipping create"
    $Summary += [pscustomobject]@{ Action = "exists"; Item = "vm $VMName" }
} elseif (-not $Nic) {
    if ($DryRun) {
        Write-Host "DRY RUN: would create vm $VMName ($VMSize, $ImageSku, $DiskText)" -ForegroundColor Yellow
        $Summary += [pscustomobject]@{ Action = "dry run"; Item = "vm $VMName" }
    } else {
        Write-Host "No nic available, skipping vm create" -ForegroundColor Yellow
    }
} elseif (Confirm-Action "create vm $VMName ($VMSize, $ImageSku, $DiskText, security $SecurityType)") {
    Write-Host "Enter the local admin password for account '$AdminUsername'"
    $Cred = Get-Credential -UserName $AdminUsername -Message "Local admin for $VMName"
    if (-not $Cred) { Write-Error "No credential provided"; return }
    try {
        $VMConfig = New-AzVMConfig -VMName $VMName -VMSize $VMSize
        $VMConfig = Set-AzVMOperatingSystem -VM $VMConfig -Windows -ComputerName $VMName -Credential $Cred -ProvisionVMAgent -EnableAutoUpdate
        $VMConfig = Set-AzVMSourceImage -VM $VMConfig -PublisherName $ImagePublisher -Offer $ImageOffer -Skus $ImageSku -Version $ImageVersion
        if ($ImagePlan) {
            $VMConfig = Set-AzVMPlan -VM $VMConfig -Publisher $ImagePlan.Publisher -Product $ImagePlan.Product -Name $ImagePlan.Name
        }
        $VMConfig = Set-AzVMOSDisk -VM $VMConfig -Name "$VMName-osdisk" -CreateOption FromImage -DiskSizeInGB $OSDiskSizeGB -StorageAccountType $DiskSku
        if ($DataDiskSizeGB -gt 0) {
            $VMConfig = Add-AzVMDataDisk -VM $VMConfig -Name "$VMName-data01" -Lun 0 -CreateOption Empty -DiskSizeInGB $DataDiskSizeGB -StorageAccountType $DiskSku -Caching ReadOnly
        }
        $VMConfig = Add-AzVMNetworkInterface -VM $VMConfig -Id $Nic.Id
        $VMConfig = Set-AzVMBootDiagnostic -VM $VMConfig -Enable
        if ($SecurityType -eq "TrustedLaunch") {
            $VMConfig = Set-AzVMSecurityProfile -VM $VMConfig -SecurityType "TrustedLaunch"
            $VMConfig = Set-AzVMUefi -VM $VMConfig -EnableVtpm $true -EnableSecureBoot $true
        }
        if ($UseHybridBenefit) { $VMConfig.LicenseType = "Windows_Server" }

        Write-Host "Creating VM $VMName, this takes a few minutes..."
        New-AzVM -ResourceGroupName $ResourceGroupName -Location $Location -VM $VMConfig -Tag $Tags -ErrorAction Stop | Out-Null
        $VM = Get-AzVM -ResourceGroupName $ResourceGroupName -Name $VMName -ErrorAction Stop
        Write-Host "VM $VMName created"
        $Summary += [pscustomobject]@{ Action = "created"; Item = "vm $VMName" }
    } catch {
        Write-Error "Creating vm failed: $($_.Exception.Message)"
        return
    }
}

# backup - vault, then protection with a policy from the vault
if ($EnableBackup) {
    $Vault = Get-AzRecoveryServicesVault -ResourceGroupName $ResourceGroupName -Name $VaultName -ErrorAction SilentlyContinue
    if ($Vault) {
        Write-Host "Recovery vault $VaultName already exists"
        $Summary += [pscustomobject]@{ Action = "exists"; Item = "vault $VaultName" }
    } elseif (Confirm-Action "create recovery services vault $VaultName") {
        try {
            $Vault = New-AzRecoveryServicesVault -Name $VaultName -ResourceGroupName $ResourceGroupName -Location $Location -ErrorAction Stop
            Write-Host "Vault $VaultName created"
            $Summary += [pscustomobject]@{ Action = "created"; Item = "vault $VaultName" }
        } catch {
            Write-Error "Creating vault failed: $($_.Exception.Message)"
            return
        }
    }

    if ($VM -and $Vault) {
        try {
            $BackupStatus = Get-AzRecoveryServicesBackupStatus -Name $VMName -ResourceGroupName $ResourceGroupName -Type AzureVM -ErrorAction Stop
        } catch {
            Write-Error "Backup status check failed: $($_.Exception.Message)"
            return
        }
        if ($BackupStatus.BackedUp) {
            Write-Host "VM $VMName is already backed up"
            $Summary += [pscustomobject]@{ Action = "exists"; Item = "backup for $VMName" }
        } else {
            # pick a policy from the vault when none was given
            if (-not $BackupPolicyName) {
                try {
                    $Policies = @(Get-AzRecoveryServicesBackupProtectionPolicy -VaultId $Vault.ID -ErrorAction Stop | Where-Object { $_.WorkloadType -eq "AzureVM" })
                } catch {
                    Write-Error "Listing backup policies failed: $($_.Exception.Message)"
                    return
                }
                if ($Policies.Count -gt 1) {
                    $DefIdx = 0
                    for ($i = 0; $i -lt $Policies.Count; $i++) { if ($Policies[$i].Name -eq "DefaultPolicy") { $DefIdx = $i } }
                    $BackupPolicyName = Read-Choice "Backup policy:" @($Policies | ForEach-Object { $_.Name }) $DefIdx
                } elseif ($Policies.Count -eq 1) {
                    $BackupPolicyName = $Policies[0].Name
                } else {
                    $BackupPolicyName = "DefaultPolicy"
                }
            }
            if (Confirm-Action "enable backup for $VMName with policy $BackupPolicyName") {
                try {
                    $Policy = Get-AzRecoveryServicesBackupProtectionPolicy -Name $BackupPolicyName -VaultId $Vault.ID -ErrorAction Stop
                    Enable-AzRecoveryServicesBackupProtection -Policy $Policy -Name $VMName -ResourceGroupName $ResourceGroupName -VaultId $Vault.ID -ErrorAction Stop | Out-Null
                    Write-Host "Backup enabled for $VMName"
                    $Summary += [pscustomobject]@{ Action = "enabled"; Item = "backup for $VMName ($BackupPolicyName)" }
                } catch {
                    Write-Error "Enabling backup failed: $($_.Exception.Message)"
                    return
                }
            }
        }
    } elseif ($DryRun) {
        Write-Host "DRY RUN: would enable backup for $VMName" -ForegroundColor Yellow
        $Summary += [pscustomobject]@{ Action = "dry run"; Item = "backup for $VMName" }
    }
}

# auto-shutdown schedule (optional)
if ($AutoShutdownTime) {
    $ScheduleId = "/subscriptions/$SubId/resourceGroups/$ResourceGroupName/providers/microsoft.devtestlab/schedules/shutdown-computevm-$VMName"
    if ($VM) {
        $Schedule = Get-AzResource -ResourceId $ScheduleId -ErrorAction SilentlyContinue
        if ($Schedule) {
            Write-Host "Auto-shutdown schedule already exists"
            $Summary += [pscustomobject]@{ Action = "exists"; Item = "auto-shutdown for $VMName" }
        } elseif (Confirm-Action "set auto-shutdown at $AutoShutdownTime ($AutoShutdownTimeZone) for $VMName") {
            try {
                $Props = @{
                    status               = "Enabled"
                    taskType             = "ComputeVmShutdownTask"
                    dailyRecurrence      = @{ time = ($AutoShutdownTime -replace ":", "") }
                    timeZoneId           = $AutoShutdownTimeZone
                    notificationSettings = @{ status = "Disabled"; timeInMinutes = 30 }
                    targetResourceId     = $VM.Id
                }
                New-AzResource -ResourceId $ScheduleId -Location $Location -Properties $Props -ApiVersion "2018-09-15" -Force -ErrorAction Stop | Out-Null
                Write-Host "Auto-shutdown set for $AutoShutdownTime"
                $Summary += [pscustomobject]@{ Action = "created"; Item = "auto-shutdown $AutoShutdownTime for $VMName" }
            } catch {
                Write-Error "Setting auto-shutdown failed: $($_.Exception.Message)"
                return
            }
        }
    } elseif ($DryRun) {
        Write-Host "DRY RUN: would set auto-shutdown at $AutoShutdownTime" -ForegroundColor Yellow
        $Summary += [pscustomobject]@{ Action = "dry run"; Item = "auto-shutdown for $VMName" }
    }
}

# cpu alert with email to the owner (optional)
if ($EnableCpuAlert) {
    if ($VM) {
        $AgName    = "ag-$VMName"
        $AlertName = "alert-$VMName-cpu"
        $Ag = Get-AzActionGroup -ResourceGroupName $ResourceGroupName -Name $AgName -ErrorAction SilentlyContinue
        if ($Ag) {
            Write-Host "Action group $AgName already exists"
            $Summary += [pscustomobject]@{ Action = "exists"; Item = "action group $AgName" }
        } elseif (Confirm-Action "create action group $AgName mailing $AlertEmail") {
            try {
                $ShortName = "ag$VMName" -replace "[^a-zA-Z0-9]", ""
                if ($ShortName.Length -gt 12) { $ShortName = $ShortName.Substring(0, 12) }
                $Receiver = New-AzActionGroupEmailReceiverObject -EmailAddress $AlertEmail -Name "owner-email"
                $Ag = New-AzActionGroup -Name $AgName -ResourceGroupName $ResourceGroupName -Location "global" `
                    -GroupShortName $ShortName -EmailReceiver $Receiver -Enabled -ErrorAction Stop
                Write-Host "Action group $AgName created"
                $Summary += [pscustomobject]@{ Action = "created"; Item = "action group $AgName" }
            } catch {
                Write-Error "Creating action group failed: $($_.Exception.Message)"
                return
            }
        }

        $Alert = Get-AzMetricAlertRuleV2 -ResourceGroupName $ResourceGroupName -Name $AlertName -ErrorAction SilentlyContinue
        if ($Alert) {
            Write-Host "CPU alert already exists"
            $Summary += [pscustomobject]@{ Action = "exists"; Item = "cpu alert for $VMName" }
        } elseif ($Ag -and (Confirm-Action "create cpu alert (>$CpuAlertThreshold% avg over 15 min) for $VMName")) {
            try {
                $Crit = New-AzMetricAlertRuleV2Criteria -MetricName "Percentage CPU" -TimeAggregation Average -Operator GreaterThan -Threshold $CpuAlertThreshold
                Add-AzMetricAlertRuleV2 -Name $AlertName -ResourceGroupName $ResourceGroupName -WindowSize 0:15 -Frequency 0:15 `
                    -TargetResourceId $VM.Id -Condition $Crit -Severity 3 -ActionGroupId $Ag.Id -ErrorAction Stop | Out-Null
                Write-Host "CPU alert created"
                $Summary += [pscustomobject]@{ Action = "created"; Item = "cpu alert for $VMName" }
            } catch {
                Write-Error "Creating cpu alert failed: $($_.Exception.Message)"
                return
            }
        }
    } elseif ($DryRun) {
        Write-Host "DRY RUN: would create action group + cpu alert mailing $AlertEmail" -ForegroundColor Yellow
        $Summary += [pscustomobject]@{ Action = "dry run"; Item = "cpu alert for $VMName" }
    }
}

# local accounts - vms often have no line of sight to AD, access happens with accounts on the box
if ($CreateLocalAccounts -and $AccessUsers.Count -gt 0) {
    if ($VM) {
        foreach ($Upn in $AccessUsers) {
            $LocalName = ($Upn -split "@")[0]
            if ($LocalName.Length -gt 20) { $LocalName = $LocalName.Substring(0, 20) }  # windows account name limit
            if (-not (Confirm-Action "create local account '$LocalName' on $VMName (resets password if it exists) and add to '$LocalAccountGroup'")) { continue }
            $UserCred = Get-Credential -UserName $LocalName -Message "Password for local account $LocalName on $VMName - share it with the user out of band"
            if (-not $UserCred) { Write-Warning "No password given for $LocalName, skipping"; continue }
            # single quotes doubled so the password survives embedding in the remote script
            $PlainPw = $UserCred.GetNetworkCredential().Password.Replace("'", "''")
            $RemoteScript = @"
`$u = '$LocalName'
`$p = ConvertTo-SecureString '$PlainPw' -AsPlainText -Force
if (Get-LocalUser -Name `$u -ErrorAction SilentlyContinue) {
    Set-LocalUser -Name `$u -Password `$p
    "user `$u already existed, password reset"
} else {
    New-LocalUser -Name `$u -Password `$p -FullName `$u | Out-Null
    "user `$u created"
}
if (Get-LocalGroupMember -Group '$LocalAccountGroup' -Member `$u -ErrorAction SilentlyContinue) {
    "`$u already in $LocalAccountGroup"
} else {
    Add-LocalGroupMember -Group '$LocalAccountGroup' -Member `$u
    "`$u added to $LocalAccountGroup"
}
"@
            try {
                $Result = Invoke-AzVMRunCommand -ResourceGroupName $ResourceGroupName -VMName $VMName `
                    -CommandId "RunPowerShellScript" -ScriptString $RemoteScript -ErrorAction Stop
                $Msg = ($Result.Value | Where-Object { $_.Code -like "*StdOut*" } | Select-Object -First 1).Message
                if (-not $Msg) { $Msg = "done" }
                Write-Host "Local account ${LocalName}: $($Msg.Trim() -replace "`r`n", "; ")"
                $Summary += [pscustomobject]@{ Action = "local account"; Item = "$LocalName in '$LocalAccountGroup' on $VMName" }
            } catch {
                Write-Error "Creating local account $LocalName failed: $($_.Exception.Message)"
                return
            }
        }
    } elseif ($DryRun) {
        Write-Host "DRY RUN: would create local accounts for $($AccessUsers -join ', ') in '$LocalAccountGroup'" -ForegroundColor Yellow
        $Summary += [pscustomobject]@{ Action = "dry run"; Item = "local accounts on $VMName" }
    }
}

# entra login + rbac for the access users
if ($EnableEntraLogin -and $AccessUsers.Count -gt 0) {
    if ($VM) {
        $Ext = Get-AzVMExtension -ResourceGroupName $ResourceGroupName -VMName $VMName -Name "AADLoginForWindows" -ErrorAction SilentlyContinue
        if ($Ext) {
            Write-Host "Entra login extension already installed"
            $Summary += [pscustomobject]@{ Action = "exists"; Item = "entra login extension" }
        } elseif (Confirm-Action "install entra login extension on $VMName") {
            try {
                Set-AzVMExtension -ResourceGroupName $ResourceGroupName -VMName $VMName -Name "AADLoginForWindows" `
                    -Publisher "Microsoft.Azure.ActiveDirectory" -ExtensionType "AADLoginForWindows" `
                    -TypeHandlerVersion "1.0" -Location $Location -ErrorAction Stop | Out-Null
                Write-Host "Entra login extension installed"
                $Summary += [pscustomobject]@{ Action = "installed"; Item = "entra login extension" }
            } catch {
                Write-Error "Installing entra login extension failed: $($_.Exception.Message)"
                return
            }
        }

        foreach ($Upn in $AccessUsers) {
            $Existing = Get-AzRoleAssignment -SignInName $Upn -RoleDefinitionName $AccessRole -Scope $VM.Id -ErrorAction SilentlyContinue
            if ($Existing) {
                Write-Host "$Upn already has $AccessRole on $VMName"
                $Summary += [pscustomobject]@{ Action = "exists"; Item = "$AccessRole for $Upn" }
                continue
            }
            if (-not (Confirm-Action "assign $AccessRole to $Upn on $VMName")) { continue }
            try {
                New-AzRoleAssignment -SignInName $Upn -RoleDefinitionName $AccessRole -Scope $VM.Id -ErrorAction Stop | Out-Null
                Write-Host "$AccessRole assigned to $Upn"
                $Summary += [pscustomobject]@{ Action = "assigned"; Item = "$AccessRole for $Upn" }
            } catch {
                Write-Error "Role assignment for $Upn failed: $($_.Exception.Message)"
                return
            }
        }
    } elseif ($DryRun) {
        Write-Host "DRY RUN: would install entra login extension and assign $AccessRole to $($AccessUsers -join ', ')" -ForegroundColor Yellow
        $Summary += [pscustomobject]@{ Action = "dry run"; Item = "entra login + role assignments" }
    }
}

Write-Host ""
Write-Host "Summary:"
if ($Summary.Count -gt 0) {
    $Summary | Format-Table -Property Action, Item -AutoSize -Wrap | Out-String -Width 200 | Write-Host
    try {
        if (-not (Test-Path $OutputPath)) { New-Item -ItemType Directory -Path $OutputPath -Force | Out-Null }
        $Stamp    = Get-Date -Format "yyyyMMdd_HHmm"
        $JsonFile = Join-Path $OutputPath "vm-deploy_${VMName}_$Stamp.json"
        $CsvFile  = Join-Path $OutputPath "vm-deploy_${VMName}_$Stamp.csv"
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

if ($DryRun) {
    Write-Host "Dry run complete. Nothing was changed." -ForegroundColor Yellow
} else {
    Write-Host "Done. Manual steps left: install required software/roles on the vm, initialize the data disk in disk management (if added), ask network team about vnet peering/dns, set up user access if not created here."
}
