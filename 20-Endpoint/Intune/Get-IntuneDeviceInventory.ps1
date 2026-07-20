param(
    [string]$OutputPath = "C:\Temp\Get-IntuneDeviceInventory",
    [string]$NameFilter = "LB*"    # wildcard on device name, e.g. "LB*" - empty = all devices
)

# --- settings ---
$RequiredModule = "Microsoft.Graph.Authentication"
# User.Read.All needed to resolve last logged on user id to a upn
$GraphScopes    = @("DeviceManagementManagedDevices.Read.All", "User.Read.All")
# chassisType and usersLoggedOn are beta-only, v1.0 doesn't have them
$GraphUri       = "https://graph.microsoft.com/beta/deviceManagement/managedDevices?`$select=deviceName,model,serialNumber,enrolledDateTime,lastSyncDateTime,chassisType,operatingSystem,skuFamily,usersLoggedOn"
$IncludeChassis = @("desktop", "laptop", "worksWorkstation")
$ExcludeChassis = @("enterpriseServer", "phone", "tablet", "mobileOther", "mobileUnknown")
# vms and server hardware - chassisType is unknown for these in our tenant, so filter on model
$ExcludeModels  = @("Virtual Machine", "VMware*", "VirtualBox*", "Parallels*", "PowerEdge*", "ProLiant*")

# --- main ---
if (-not (Get-Module -ListAvailable -Name $RequiredModule)) {
    Write-Host "Module $RequiredModule is not installed. Run: Install-Module $RequiredModule" -ForegroundColor Red
    exit 1
}

$context = Get-MgContext
$missingScopes = @($GraphScopes | Where-Object { -not $context -or $context.Scopes -notcontains $_ })
if ($missingScopes.Count -gt 0) {
    Write-Host "Connecting to Graph..."
    try {
        Connect-MgGraph -Scopes $GraphScopes -NoWelcome -ErrorAction Stop
    } catch {
        Write-Host "Failed to connect to Graph: $($_.Exception.Message)" -ForegroundColor Red
        exit 1
    }
}

Write-Host "Querying Intune managed devices..."
$devices = @()
$uri = $GraphUri
try {
    while ($uri) {
        $response = Invoke-MgGraphRequest -Method GET -Uri $uri -ErrorAction Stop
        $devices += $response.value
        $uri = $response.'@odata.nextLink'
    }
} catch {
    Write-Host "Graph query failed: $($_.Exception.Message)" -ForegroundColor Red
    exit 1
}
Write-Host "Found $($devices.Count) devices total"

# cache so each user id only gets looked up once
$userCache = @{}

$results = foreach ($d in $devices) {

    if ($NameFilter -and $d.deviceName -notlike $NameFilter) { continue }

    $chassis = "$($d.chassisType)"
    if ($ExcludeChassis -contains $chassis) { continue }

    $isVmOrServer = $false
    foreach ($pattern in $ExcludeModels) {
        if ($d.model -like $pattern) { $isVmOrServer = $true; break }
    }
    if ($isVmOrServer) { continue }

    # chassis often reports unknown - fall back to OS, still skip anything server-like
    if ($IncludeChassis -notcontains $chassis) {
        $os = "$($d.operatingSystem)"
        $sku = "$($d.skuFamily)"
        if ($os -notlike "Windows*" -and $os -ne "macOS") { continue }
        if ($os -like "*Server*" -or $sku -like "*Server*") { continue }
    }

    $enrolled = ""
    if ($d.enrolledDateTime) { $enrolled = ([datetime]$d.enrolledDateTime).ToString("yyyy-MM-dd HH:mm") }
    $lastCheckin = ""
    if ($d.lastSyncDateTime) { $lastCheckin = ([datetime]$d.lastSyncDateTime).ToString("yyyy-MM-dd HH:mm") }

    # most recent entry in usersLoggedOn, resolve id to upn
    $lastUser = ""
    if ($d.usersLoggedOn) {
        $latest = $d.usersLoggedOn | Sort-Object { [datetime]$_.lastLogOnDateTime } | Select-Object -Last 1
        $uid = "$($latest.userId)"
        if ($uid) {
            if (-not $userCache.ContainsKey($uid)) {
                try {
                    $u = Invoke-MgGraphRequest -Method GET -Uri "https://graph.microsoft.com/v1.0/users/$uid`?`$select=userPrincipalName" -ErrorAction Stop
                    $userCache[$uid] = $u.userPrincipalName
                } catch {
                    # deleted user or no permission - keep the id so the row isn't blank
                    $userCache[$uid] = $uid
                }
            }
            $lastUser = $userCache[$uid]
        }
    }

    [PSCustomObject]@{
        DeviceName      = $d.deviceName
        Model           = $d.model
        SerialNumber    = $d.serialNumber
        EnrollmentDate  = $enrolled
        LastCheckin     = $lastCheckin
        LastUser        = $lastUser
        OperatingSystem = $d.operatingSystem
    }
}
$results = @($results | Sort-Object DeviceName)
Write-Host "Kept $($results.Count) laptops/desktops after filtering"

if ($results.Count -eq 0) {
    Write-Host "Nothing to export." -ForegroundColor Yellow
    exit 0
}

if (-not (Test-Path $OutputPath)) {
    try {
        New-Item -ItemType Directory -Path $OutputPath -Force -ErrorAction Stop | Out-Null
    } catch {
        Write-Host "Could not create output folder $OutputPath : $($_.Exception.Message)" -ForegroundColor Red
        exit 1
    }
}

$stamp = Get-Date -Format "yyyyMMdd_HHmm"
$csvFile = Join-Path $OutputPath "Get-IntuneDeviceInventory_$stamp.csv"
$jsonFile = Join-Path $OutputPath "Get-IntuneDeviceInventory_$stamp.json"
try {
    $results | Export-Csv -Path $csvFile -NoTypeInformation -Encoding UTF8 -ErrorAction Stop
    $results | ConvertTo-Json -Depth 3 | Out-File -FilePath $jsonFile -Encoding UTF8 -ErrorAction Stop
} catch {
    Write-Host "Export failed: $($_.Exception.Message)" -ForegroundColor Red
    exit 1
}

Write-Host "Done. Exported to $csvFile and $jsonFile"
