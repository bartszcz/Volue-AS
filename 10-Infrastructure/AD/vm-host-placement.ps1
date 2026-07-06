<#
.SYNOPSIS
    Reports Hyper-V host placement and guest OS for a list of VMs via SCVMM.
.DESCRIPTION
    Connects to an SCVMM server, queries each VM for its Hyper-V host and OS,
    and exports results to CSV. Edit only the $VMList section for each engagement.
    Run directly on the jump server with no parameters, or use -JumpServer to
    remote in from a workstation (requires WinRM access).
.PARAMETER SCVMMServer
    SCVMM server hostname.
.PARAMETER JumpServer
    Jump server hostname. Leave empty ("") to run locally.
.PARAMETER OutputPath
    CSV output path. Defaults to the user's desktop.
#>
param(
    [string]$SCVMMServer = "ittrhscvm01",
    [string]$JumpServer  = "pawtrhito01",
    [System.Management.Automation.PSCredential]$Credential,
    [string]$OutputPath  = "$env:USERPROFILE\Desktop\VM-HostPlacement-$(Get-Date -Format 'yyyy-MM-dd').csv"
)

# ============================================================
# VM LIST — update this section for each engagement
# ============================================================
$VMList = @(
    [PSCustomObject]@{ Group = "Build server";    VM = "tdtrhbofbuild01"  }
    [PSCustomObject]@{ Group = "Build server";    VM = "tdtrhbofbuild02"  }
    [PSCustomObject]@{ Group = "Build server";    VM = "tdtrhbofbuild03"  }
    [PSCustomObject]@{ Group = "Test server";     VM = "tdtrhboftest001"  }
    [PSCustomObject]@{ Group = "Test server";     VM = "tdtrhboftest002"  }
    [PSCustomObject]@{ Group = "Test server";     VM = "tdtrhboftest003"  }
    [PSCustomObject]@{ Group = "Test server";     VM = "tdtrhboftest004"  }
    [PSCustomObject]@{ Group = "Test server";     VM = "tdtrhboftest005"  }
    [PSCustomObject]@{ Group = "Test server";     VM = "tdtrhboftest006"  }
    [PSCustomObject]@{ Group = "Test server 2";   VM = "tdtrhmdsdev01"    }
    [PSCustomObject]@{ Group = "Test server 2";   VM = "tdtrhmdsdev02"    }
    [PSCustomObject]@{ Group = "Database server"; VM = "tdtrhbofdb01"     }
    [PSCustomObject]@{ Group = "Database server"; VM = "tdtrhbofdb02"     }
    [PSCustomObject]@{ Group = "Database server"; VM = "tdtrhbofdb03"     }
    [PSCustomObject]@{ Group = "CI/CD Jenkins";   VM = "tdtrhbofjenkins"  }
    [PSCustomObject]@{ Group = "Special server";  VM = "tdtrh3rdparty01"  }
    [PSCustomObject]@{ Group = "Special server";  VM = "tdtrhbofpm001"    }
)
# ============================================================

$queryBlock = {
    param($VMList, $SCVMMServer)

    Import-Module VirtualMachineManager -ErrorAction Stop
    Get-VMMServer -ComputerName $SCVMMServer -ErrorAction Stop | Out-Null

    Write-Host "  Fetching VM inventory from SCVMM..." -ForegroundColor Gray
    $allVMs = Get-SCVirtualMachine -ErrorAction Stop

    foreach ($entry in $VMList) {
        Write-Host "  $($entry.VM.PadRight(25))" -NoNewline

        $vm = $allVMs | Where-Object { $_.Name -like "$($entry.VM)*" } | Select-Object -First 1

        if ($vm) {
            $vmShort   = $vm.Name     -replace '\..*$', ''
            $hostShort = $vm.HostName -replace '\..*$', ''
            Write-Host "[$($vm.Status)] -> $hostShort" -ForegroundColor Green
            [PSCustomObject]@{
                Group      = $entry.Group
                VMName     = $vmShort
                Status     = $vm.Status
                HyperVHost = $hostShort
                GuestOS    = $vm.OperatingSystem.Name
            }
        } else {
            Write-Host "NOT FOUND" -ForegroundColor Red
            [PSCustomObject]@{
                Group      = $entry.Group
                VMName     = $entry.VM
                Status     = "NOT FOUND"
                HyperVHost = ""
                GuestOS    = ""
            }
        }
    }
}

$runLocal = -not $JumpServer -or $JumpServer -eq $env:COMPUTERNAME

Write-Host ""
if ($runLocal) {
    Write-Host "Querying SCVMM: $SCVMMServer (local)" -ForegroundColor Cyan
    if (-not (Get-Module VirtualMachineManager -ListAvailable)) {
        Write-Error "VirtualMachineManager module not found. Install the SCVMM console or run from the jump server."
        exit 1
    }
    try {
        $results = & $queryBlock $VMList $SCVMMServer
    } catch {
        Write-Error "Failed: $_"
        exit 1
    }
} else {
    Write-Host "Querying via jump server: $JumpServer -> SCVMM: $SCVMMServer" -ForegroundColor Cyan
    if (-not $Credential) {
        $Credential = Get-Credential -Message "Credentials for $JumpServer"
    }
    try {
        $results = Invoke-Command -ComputerName $JumpServer -Credential $Credential `
                       -Authentication Negotiate `
                       -ScriptBlock $queryBlock -ArgumentList $VMList, $SCVMMServer -ErrorAction Stop
    } catch {
        Write-Error "Remote execution failed: $_"
        exit 1
    }
}

# Console display
Write-Host ""
$results | Format-Table Group, VMName, Status, HyperVHost, GuestOS -AutoSize

# Build HTML table for clipboard (renders properly in Word, Outlook, Teams)
Add-Type -AssemblyName System.Windows.Forms

$thStyle = "padding:5px 12px;border:1px solid #2F5496;background:#4472C4;color:white;font-weight:bold;font-family:Calibri,sans-serif"
$tdStyle = "padding:4px 12px;border:1px solid #ccc;font-family:Calibri,sans-serif"

$thead = "<tr>" + (@('Group','VM Name','Status','Hyper-V Host','Guest OS') |
    ForEach-Object { "<th style='$thStyle'>$_</th>" } ) -join "" + "</tr>"

$tbody = ($results | ForEach-Object {
    $r = $_
    "<tr>" + (@($r.Group, $r.VMName, $r.Status, $r.HyperVHost, $r.GuestOS) |
        ForEach-Object { "<td style='$tdStyle'>$_</td>" }) -join "" + "</tr>"
}) -join ""

$htmlFrag = "<table style='border-collapse:collapse'>$thead$tbody</table>"

$enc    = [System.Text.Encoding]::UTF8
$pre    = "Version:0.9`r`nStartHTML:{0:D10}`r`nEndHTML:{1:D10}`r`nStartFragment:{2:D10}`r`nEndFragment:{3:D10}`r`n"
$open   = "<html><body><!--StartFragment-->"
$close  = "<!--EndFragment--></body></html>"
$preLen = $enc.GetByteCount($pre -f 0,0,0,0)
$sFrag  = $preLen + $enc.GetByteCount($open)
$eFrag  = $sFrag  + $enc.GetByteCount($htmlFrag)
$eHtml  = $eFrag  + $enc.GetByteCount($close)
$cfHtml = ($pre -f $preLen, $eHtml, $sFrag, $eFrag) + $open + $htmlFrag + $close

[System.Windows.Forms.Clipboard]::SetText($cfHtml, [System.Windows.Forms.TextDataFormat]::Html)
Write-Host "HTML table copied to clipboard — paste into Word, Outlook or Teams." -ForegroundColor Green

# CSV export
$results | Select-Object Group, VMName, Status, HyperVHost, GuestOS |
           Export-Csv -Path $OutputPath -NoTypeInformation -Encoding UTF8
Write-Host "Exported:  $OutputPath" -ForegroundColor Cyan
