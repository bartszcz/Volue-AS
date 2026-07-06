#Requires -RunAsAdministrator

$compname    = hostname
$Compdomain  = "$compname.voluead.volue.com"
$RDSlicServer = "ITTRHRDLIC01.voluead.volue.com"
$RDSCALMode  = 4
$taskName    = "RDS-Part2-Setup"
$selfPath    = "C:\Windows\Temp\RDS-Deploy.ps1"
$flagFile    = "C:\Windows\ccm\deploy\rds-part1-complete.flag"

# ── HELPER: Verification check ────────────────────────────────
function Run-Verification {
    $results = [System.Collections.Generic.List[PSCustomObject]]::new()

    function Check-Item {
        param($Name, $Status, $Expected, $Actual, $Critical = $false)
        $results.Add([PSCustomObject]@{
            Check    = $Name
            Status   = if ($Status) { "PASS" } else { "FAIL" }
            Expected = $Expected
            Actual   = $Actual
            Critical = $Critical
        })
    }

    Write-Host "`n========== RDS DEPLOYMENT VERIFICATION ==========" -ForegroundColor Cyan
    Write-Host "Computer: $Compdomain" -ForegroundColor Cyan
    Write-Host "==================================================`n" -ForegroundColor Cyan

    $rdModule     = Get-Module -ListAvailable -Name RemoteDesktop
    $broker       = Get-RDServer -Role RDS-CONNECTION-BROKER -ErrorAction SilentlyContinue
    $webAccess    = Get-RDServer -Role RDS-WEB-ACCESS -ErrorAction SilentlyContinue
    $sessionHost  = Get-RDServer -Role RDS-RD-SERVER -ErrorAction SilentlyContinue
    $regPath      = "HKLM:\SYSTEM\CurrentControlSet\Services\TermService\Parameters\LicenseServers"
    $regKeyExists = Test-Path $regPath
    $licModeKey   = "HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server\RCM\Licensing Core"
    $licMode      = (Get-ItemProperty $licModeKey -Name LicensingMode -ErrorAction SilentlyContinue).LicensingMode
    $termService  = Get-Service -Name TermService -ErrorAction SilentlyContinue
    $markerFile   = "C:\Windows\ccm\deploy\licenserver-ok.txt"

    Check-Item "RemoteDesktop Module"       ($rdModule -ne $null)                          "Installed"   ($rdModule.Version ?? "Not found")                              -Critical $true
    Check-Item "RD Connection Broker Role"  ($broker -ne $null)                            $Compdomain   ($broker.Server ?? "Not configured")                            -Critical $true
    Check-Item "RD Web Access Role"         ($webAccess -ne $null)                         $Compdomain   ($webAccess.Server ?? "Not configured")                         -Critical $true
    Check-Item "RD Session Host Role"       ($sessionHost -ne $null)                       $Compdomain   ($sessionHost.Server ?? "Not configured")                       -Critical $true

    try {
        $wmiObj   = Get-WmiObject -Namespace "Root/CIMV2/TerminalServices" Win32_TerminalServiceSetting -ErrorAction Stop
        $wmiLic   = $wmiObj.GetSpecifiedLicenseServerList()
        $wmiMatch = $wmiLic.SpecifiedLSList -contains $RDSlicServer
        Check-Item "WMI License Server" $wmiMatch $RDSlicServer ($wmiLic.SpecifiedLSList -join ", ")
    } catch {
        Check-Item "WMI License Server" $false $RDSlicServer "WMI query failed"
    }

    try {
        $licConfig = Get-RDLicenseConfiguration -ErrorAction Stop
        $licServer = ($licConfig.LicenseServer -join ",")
        Check-Item "RD License Server Config" ($licServer -like "*ITTRHRDLIC01*") $RDSlicServer ($licServer -ne "" ? $licServer : "(empty)")
    } catch {
        Check-Item "RD License Server Config" $false $RDSlicServer "Not retrievable"
    }

    Check-Item "Registry Key Exists"        $regKeyExists                                  $regPath      (if ($regKeyExists) { "Present" } else { "Missing" })
    if ($regKeyExists) {
        $regValue = (Get-ItemProperty $regPath -Name SpecifiedLicenseServers -ErrorAction SilentlyContinue).SpecifiedLicenseServers
        Check-Item "Registry License Server"  ($regValue -contains $RDSlicServer)          $RDSlicServer ($regValue -join ", ")
    } else {
        Check-Item "Registry License Server"  $false                                        $RDSlicServer "Registry key missing"
    }

    Check-Item "Licensing Mode (PerUser=4)" ($licMode -eq $RDSCALMode)                    "4 (PerUser)"  $licMode
    Check-Item "TermService Running"        ($termService.Status -eq "Running")            "Running"      $termService.Status                                            -Critical $true
    Check-Item "SCCM Marker File"           (Test-Path $markerFile)                        $markerFile   (if (Test-Path $markerFile) { "Present" } else { "Missing" })

    $results | Format-Table Check, Status, Expected, Actual -AutoSize -Wrap

    $passed       = ($results | Where-Object { $_.Status -eq "PASS" }).Count
    $failed       = ($results | Where-Object { $_.Status -eq "FAIL" }).Count
    $criticalFails = ($results | Where-Object { $_.Status -eq "FAIL" -and $_.Critical }).Count

    Write-Host "========== SUMMARY ==========" -ForegroundColor Cyan
    Write-Host "Passed : $passed" -ForegroundColor Green
    Write-Host "Failed : $failed" -ForegroundColor $(if ($failed -gt 0) { "Red" } else { "Green" })
    if ($criticalFails -gt 0) {
        Write-Host "WARNING: $criticalFails critical check(s) failed." -ForegroundColor Red
    } else {
        Write-Host "All critical checks passed." -ForegroundColor Green
    }
}

# ── ALREADY FULLY CONFIGURED? Run verification and exit ───────
$rdsInstalled  = (Get-WindowsFeature -Name rds-rd-server).Installed
$brokerPresent = (Get-RDServer -Role RDS-CONNECTION-BROKER -ErrorAction SilentlyContinue) -ne $null

if ($rdsInstalled -and $brokerPresent) {
    Write-Host "RDS appears already configured on $compname." -ForegroundColor Green
    Run-Verification
    exit 0
}

# ── SAFEGUARD: Confirm target host ────────────────────────────
Write-Host ""
Write-Host "========================================" -ForegroundColor Red
Write-Host "  RDS DEPLOYMENT SCRIPT"                  -ForegroundColor Red
Write-Host "========================================" -ForegroundColor Red
Write-Host ""
Write-Host "  Hostname   : $compname"                 -ForegroundColor Yellow
Write-Host "  FQDN       : $Compdomain"               -ForegroundColor Yellow
Write-Host "  IP Address : $((Get-NetIPAddress -AddressFamily IPv4 | Where-Object { $_.InterfaceAlias -notlike '*Loopback*' } | Select-Object -First 1).IPAddress)" -ForegroundColor Yellow
Write-Host "  Logged-in  : $env:USERDOMAIN\$env:USERNAME" -ForegroundColor Yellow
Write-Host ""
$confirm = Read-Host "Is this the correct server? Type the hostname [$compname] to confirm"
if ($confirm -ne $compname) {
    Write-Host "Hostname mismatch. Aborting." -ForegroundColor Red
    exit 1
}

Import-Module RemoteDesktop -Verbose
Import-Module ServerManager -Verbose

# ── PART 2: We're resuming after reboot ───────────────────────
if (Test-Path $flagFile) {
    Write-Host "Resuming Part 2 after reboot..." -ForegroundColor Cyan

    Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue

    New-RDSessionDeployment -ConnectionBroker $Compdomain `
                            -WebAccessServer  $Compdomain `
                            -SessionHost      $Compdomain

    # WMI license (fixes grace period)
    $obj = Get-WmiObject -Namespace "Root/CIMV2/TerminalServices" Win32_TerminalServiceSetting
    $obj.SetSpecifiedLicenseServerList($RDSlicServer)

    # RD Deployment level license
    Set-RDLicenseConfiguration -LicenseServer $RDSlicServer -Mode PerUser `
                               -ConnectionBroker $Compdomain -Force

    # Verify and create SCCM marker
    try {
        $licConfig = Get-RDLicenseConfiguration -ErrorAction Stop
        $licServer = ($licConfig.LicenseServer -join ",")
        if ($licServer -like "*ITTRHRDLIC01*") {
            Write-Host "hura! License server confirmed." -ForegroundColor Green
            New-Item -Path "C:\Windows\ccm\deploy\licenserver-ok.txt" -ItemType File -Force
        } else {
            Write-Warning "License server unexpected: $licServer"
        }
    } catch {
        Write-Warning "Could not verify RDLicenseConfiguration: $_"
    }

    # Registry licensing settings
    New-Item "HKLM:\SYSTEM\CurrentControlSet\Services\TermService\Parameters\LicenseServers" -Force
    New-ItemProperty "HKLM:\SYSTEM\CurrentControlSet\Services\TermService\Parameters\LicenseServers" `
        -Name SpecifiedLicenseServers -Value $RDSlicServer -PropertyType "MultiString" -Force
    Set-ItemProperty "HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server\RCM\Licensing Core\" `
        -Name "LicensingMode" -Value $RDSCALMode

    Get-Service -Name TermService | Restart-Service -Force

    # Cleanup
    Remove-Item $flagFile -Force -ErrorAction SilentlyContinue
    Remove-Item $selfPath -Force -ErrorAction SilentlyContinue

    Write-Host "RDS deployment complete!" -ForegroundColor Green
    Run-Verification
    exit 0
}

# ── PART 1: Install RDS role ──────────────────────────────────
Write-Host "Part 1: Installing RDS role..." -ForegroundColor Cyan
Add-WindowsFeature -Name rds-rd-server -IncludeManagementTools -Verbose

if ((Get-WindowsFeature -Name rds-rd-server).Installed) {
    Write-Host "hura! RDS role installed." -ForegroundColor Green
    New-Item -Path "C:\Windows\ccm\deploy\rds-rd-server-ok.txt" -ItemType File -Force

    # Embed this script to survive reboot
    Copy-Item -Path $PSCommandPath -Destination $selfPath -Force -ErrorAction SilentlyContinue
    # If pasted (no $PSCommandPath), write the script content directly
    if (-not (Test-Path $selfPath)) {
        $MyInvocation.MyCommand.ScriptBlock | Out-File -FilePath $selfPath -Encoding UTF8
    }

    New-Item -Path $flagFile -ItemType File -Force

    # Register scheduled task to resume after reboot
    $action    = New-ScheduledTaskAction -Execute "powershell.exe" `
                   -Argument "-ExecutionPolicy Bypass -NonInteractive -File `"$selfPath`""
    $trigger   = New-ScheduledTaskTrigger -AtStartup
    $principal = New-ScheduledTaskPrincipal -UserId "SYSTEM" -RunLevel Highest
    Register-ScheduledTask -TaskName $taskName -Action $action `
                           -Trigger $trigger -Principal $principal -Force

    Write-Host ""
    Write-Host "========================================" -ForegroundColor Red
    Write-Host "  REBOOT REQUIRED"                        -ForegroundColor Red
    Write-Host "========================================" -ForegroundColor Red
    Write-Host "  Part 2 will run automatically on next startup." -ForegroundColor Yellow
    Write-Host ""
    $rebootConfirm = Read-Host "Type 'REBOOT' to reboot now, or anything else to cancel"
    if ($rebootConfirm -eq "REBOOT") {
        Restart-Computer -Force
    } else {
        Write-Host "Reboot cancelled. Reboot manually when ready -- Part 2 will run at startup." -ForegroundColor Yellow
    }
} else {
    Write-Error "RDS role installation failed!"
}