param(
    [Parameter(Mandatory)]
    [string]$CsvPath,

    [Parameter(Mandatory)]
    [string]$ReportFolder
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

if (-not (Test-Path $CsvPath)) { throw "CSV not found: $CsvPath" }
if (-not (Test-Path $ReportFolder)) { New-Item -ItemType Directory -Path $ReportFolder -Force | Out-Null }

$timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
$reportPath = Join-Path $ReportFolder "dg_external_import_report_$timestamp.csv"

$applyAll = $false

function Get-SafeAlias {
    param([Parameter(Mandatory)][string]$Email)

    $parts = $Email.Trim().ToLowerInvariant().Split("@", 2)
    if ($parts.Count -ne 2) { throw "Invalid email: $Email" }

    $local = $parts[0]
    $domain = $parts[1].Replace(".", "-")

    $alias = ($local + "-" + $domain) -replace "[^a-z0-9\-]", "-"
    $alias = $alias.Trim("-")
    $alias = $alias -replace "\-+", "-"

    if ($alias.Length -gt 64) { $alias = $alias.Substring(0,64) }
    if ([string]::IsNullOrWhiteSpace($alias)) { $alias = "ext-" + ([guid]::NewGuid().ToString("N").Substring(0,12)) }

    return $alias
}

function Get-VendorFromDomain {
    param([Parameter(Mandatory)][string]$Domain)

    $d = $Domain.Trim().ToLowerInvariant()
    $labels = $d.Split(".") | Where-Object { $_ -and $_.Trim() -ne "" }

    if ($labels.Count -eq 0) { return "Vendor" }
    if ($labels.Count -eq 1) { return ($labels[0].Substring(0,1).ToUpper() + $labels[0].Substring(1)) }

    $publicSuffix2 = @(
        "co.uk","org.uk","ac.uk","gov.uk",
        "com.au","net.au","org.au",
        "co.nz","org.nz",
        "co.jp","ne.jp",
        "com.br","com.mx","com.ar",
        "co.za"
    )

    $last2 = ($labels[-2] + "." + $labels[-1])

    $vendorLabel = $null
    if ($publicSuffix2 -contains $last2) {
        $vendorLabel = if ($labels.Count -ge 3) { $labels[-3] } else { $labels[0] }
    } else {
        $vendorLabel = $labels[-2]
    }

    if (-not $vendorLabel) { $vendorLabel = "Vendor" }

    $vendorLabel = $vendorLabel -replace "\-", " "
    $vendorLabel = ($vendorLabel -replace "\s+", " ").Trim()

    $words = $vendorLabel.Split(" ")
    $vendorPretty = foreach ($w in $words) {
        if ($w.Length -gt 1) { $w.Substring(0,1).ToUpper() + $w.Substring(1) } else { $w.ToUpper() }
    }

    return ($vendorPretty -join " ").Trim()
}

function Get-NameFromLocalPart {
    param([Parameter(Mandatory)][string]$LocalPart)

    $lp = $LocalPart.Trim().ToLowerInvariant()
    $clean = $lp -replace "[\._\-]", " "
    $clean = $clean -replace "\s+", " "
    $clean = $clean.Trim()

    if ([string]::IsNullOrWhiteSpace($clean)) { return "External User" }

    $tokens = $clean.Split(" ")
    $proper = foreach ($t in $tokens) {
        if ($t -match "^\d+$") { $t }
        elseif ($t.Length -gt 1) { $t.Substring(0,1).ToUpper() + $t.Substring(1) }
        else { $t.ToUpper() }
    }

    return ($proper -join " ").Trim()
}

function Get-DisplayNameFromEmail {
    param([Parameter(Mandatory)][string]$Email)

    $parts = $Email.Trim().ToLowerInvariant().Split("@", 2)
    if ($parts.Count -ne 2) { throw "Invalid email: $Email" }

    $local = $parts[0]
    $domain = $parts[1]

    $personName = Get-NameFromLocalPart -LocalPart $local
    $vendor = Get-VendorFromDomain -Domain $domain

    return "$personName ($vendor)"
}

function Ensure-GroupExists {
    param([Parameter(Mandatory)][string]$Group)

    $g = Get-DistributionGroup -Identity $Group -ErrorAction Stop
    if ($g.RecipientTypeDetails -ne "MailUniversalDistributionGroup") {
        throw "Group '$Group' is not a static Distribution Group (got: $($g.RecipientTypeDetails))"
    }
    return $g
}

function Get-MailContactByExternalEmail {
    param([Parameter(Mandatory)][string]$ExternalEmail)

    $externalEmailNorm = $ExternalEmail.Trim().ToLowerInvariant()

    $existingByExternal = $null
    try {
        # Exchange stores ExternalEmailAddress with an "SMTP:" prefix — try both forms
        $existingByExternal = Get-MailContact -ResultSize Unlimited -Filter "ExternalEmailAddress -eq 'SMTP:$externalEmailNorm'" -ErrorAction SilentlyContinue
        if (-not $existingByExternal) {
            $existingByExternal = Get-MailContact -ResultSize Unlimited -Filter "ExternalEmailAddress -eq '$externalEmailNorm'" -ErrorAction SilentlyContinue
        }
    } catch { $existingByExternal = $null }

    if ($existingByExternal) {
        return $existingByExternal | Select-Object -First 1
    }
    return $null
}

function Ensure-MailContact {
    param(
        [Parameter(Mandatory)][string]$ExternalEmail,
        [Parameter(Mandatory)][string]$DesiredDisplayName
    )

    $externalEmailNorm = $ExternalEmail.Trim().ToLowerInvariant()

    $c = Get-MailContactByExternalEmail -ExternalEmail $externalEmailNorm
    if ($c) {
        if ($c.DisplayName -ne $DesiredDisplayName) {
            Set-MailContact -Identity $c.Identity -DisplayName $DesiredDisplayName -ErrorAction Stop
            $c = Get-MailContact -Identity $c.Identity
        }
        return [pscustomobject]@{ Contact = $c; Created = $false; Renamed = ($c.DisplayName -eq $DesiredDisplayName) }
    }

    $aliasBase = Get-SafeAlias -Email $externalEmailNorm
    $alias = $aliasBase

    $i = 0
    while ($true) {
        $dup = $null
        try { $dup = Get-Recipient -Identity $alias -ErrorAction Stop } catch { $dup = $null }
        if (-not $dup) { break }

        $i++
        $alias = ($aliasBase + "-" + $i)
        if ($alias.Length -gt 64) { $alias = $alias.Substring(0,64) }
        if ($i -gt 50) { throw "Could not find unique alias for $externalEmailNorm" }
    }

    $new = New-MailContact -Name $DesiredDisplayName -DisplayName $DesiredDisplayName -Alias $alias -ExternalEmailAddress $externalEmailNorm
    return [pscustomobject]@{ Contact = $new; Created = $true; Renamed = $false }
}

function Is-AlreadyMember {
    param(
        [Parameter(Mandatory)][string]$Group,
        [Parameter(Mandatory)][string]$ExternalEmail
    )

    $target = $ExternalEmail.Trim().ToLowerInvariant()
    $members = Get-DistributionGroupMember -Identity $Group -ResultSize Unlimited

    foreach ($m in $members) {
        if ($m.PrimarySmtpAddress -and $m.PrimarySmtpAddress.ToString().ToLowerInvariant() -eq $target) { return $true }

        # ExternalEmailAddress may contain an "SMTP:" prefix — strip it before comparing
        if ($m.PSObject.Properties['ExternalEmailAddress'] -and $m.ExternalEmailAddress) {
            $ext = $m.ExternalEmailAddress.ToString().ToLowerInvariant() -replace '^smtp:', ''
            if ($ext -eq $target) { return $true }
        }

        # Not every recipient type exposes WindowsEmailAddress — check safely
        if ($m.PSObject.Properties['WindowsEmailAddress'] -and $m.WindowsEmailAddress) {
            if ($m.WindowsEmailAddress.ToString().ToLowerInvariant() -eq $target) { return $true }
        }
    }
    return $false
}

function Prompt-Approval {
    param(
        [Parameter(Mandatory)][string]$Group,
        [Parameter(Mandatory)][string]$Email,
        [Parameter(Mandatory)][string]$DesiredDisplayName,
        [string[]]$PlannedActions
    )

    Write-Host ""
    Write-Host "---------------------------------------------"
    Write-Host "Group : $Group"
    Write-Host "Email : $Email"
    Write-Host "Name  : $DesiredDisplayName"
    Write-Host "Plan  :"
    foreach ($a in $PlannedActions) { Write-Host "  - $a" }
    Write-Host "---------------------------------------------"
    Write-Host "Approve? [Y]es / [N]o / [A]ll remaining / [Q]uit"
    $choice = Read-Host "Enter choice"

    switch ($choice.ToUpperInvariant()) {
        "Y" { return "Yes" }
        "N" { return "No" }
        "A" { return "All" }
        "Q" { return "Quit" }
        default { return "No" }
    }
}

$rows = Import-Csv -Path $CsvPath
if (-not $rows) { throw "CSV is empty: $CsvPath" }

$required = @("Group","ExternalEmail")
$missingHeaders = $required | Where-Object { -not ($rows[0].PSObject.Properties.Name -contains $_) }
if ($missingHeaders) { throw "CSV missing required header(s): $($missingHeaders -join ', ')" }

$results = New-Object System.Collections.Generic.List[object]

foreach ($r in $rows) {
    $group = ($r.Group ?? "").Trim()
    $email = ($r.ExternalEmail ?? "").Trim()

    $res = [ordered]@{
        Timestamp     = (Get-Date).ToString("s")
        Group         = $group
        ExternalEmail = $email
        GeneratedName = $null
        ContactId     = $null
        Action        = $null
        Status        = "Failed"
        Error         = $null
    }

    try {
        if ([string]::IsNullOrWhiteSpace($group)) { throw "Missing Group" }
        if ([string]::IsNullOrWhiteSpace($email)) { throw "Missing ExternalEmail" }
        if ($email -notmatch "^[^@\s]+@[^@\s]+\.[^@\s]+$") { throw "Invalid ExternalEmail format: $email" }

        $null = Ensure-GroupExists -Group $group

        $desiredName = Get-DisplayNameFromEmail -Email $email
        $res.GeneratedName = $desiredName

        $planned = New-Object System.Collections.Generic.List[string]

        $existingContact = Get-MailContactByExternalEmail -ExternalEmail $email
        if (-not $existingContact) {
            $planned.Add("Create MailContact '$desiredName' for $email") | Out-Null
        } else {
            if ($existingContact.DisplayName -ne $desiredName) {
                $planned.Add("Rename existing contact '$($existingContact.DisplayName)' -> '$desiredName'") | Out-Null
            } else {
                $planned.Add("Contact exists (no rename needed)") | Out-Null
            }
        }

        $alreadyMember = Is-AlreadyMember -Group $group -ExternalEmail $email
        if ($alreadyMember) {
            $planned.Add("Already in group (no membership change)") | Out-Null
        } else {
            $planned.Add("Add contact to group") | Out-Null
        }

        $decision = $null
        if ($applyAll) {
            $decision = "Yes"
        } else {
            $decision = Prompt-Approval -Group $group -Email $email -DesiredDisplayName $desiredName -PlannedActions $planned.ToArray()
            if ($decision -eq "All") { $applyAll = $true; $decision = "Yes" }
            if ($decision -eq "Quit") { break }
        }

        if ($decision -eq "No") {
            $res.Action = "Skipped"
            $res.Status = "Ok"
            $results.Add([pscustomobject]$res) | Out-Null
            continue
        }

        $contactResult = Ensure-MailContact -ExternalEmail $email -DesiredDisplayName $desiredName
        $contact = $contactResult.Contact
        $res.ContactId = $contact.Identity

        if ($alreadyMember) {
            $res.Action = "NoChange"
            $res.Status = "Ok"
        } else {
            Add-DistributionGroupMember -Identity $group -Member $contact.Identity -ErrorAction Stop
            $res.Action = "Added"
            $res.Status = "Ok"
        }
    }
    catch {
        $res.Error = $_.Exception.Message
    }

    $results.Add([pscustomobject]$res) | Out-Null
}

$results | Export-Csv -Path $reportPath -NoTypeInformation -Encoding UTF8

Write-Host ""
Write-Host "Completed."
Write-Host "Report: $reportPath"
Write-Host ""
Write-Host "Summary:"
$results | Group-Object Status,Action | Sort-Object Name | ForEach-Object {
    "{0,-25} {1}" -f $_.Name, $_.Count | Write-Host
}