[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)]
    [string]$InputFile,

    [Parameter(Mandatory=$true)]
    [string]$OutputFile,

    # Set to ';' if your file is semicolon-separated (common in PL/EU)
    [char]$Delimiter = ',',

    # Domain prefix to add
    [string]$DomainPrefix = 'voluead',

    # Only convert emails in this domain (change if needed)
    [string]$EmailDomain = 'volue.com'
)

$ErrorActionPreference = 'Stop'

if (-not (Test-Path $InputFile)) {
    throw "Input file not found: $InputFile"
}

# Import as a headerless 2-column CSV:
#  - Col1: device/VM
#  - Col2: user/owner/primary user
$data = Import-Csv -Path $InputFile -Delimiter $Delimiter -Header @('Device','User')

if (-not $data -or $data.Count -eq 0) {
    throw "CSV imported but contains no rows: $InputFile"
}

$changed = 0
$skipped = 0

foreach ($row in $data) {
    $user = ($row.User -as [string]).Trim()

    if ([string]::IsNullOrWhiteSpace($user)) {
        $skipped++
        continue
    }

    # Already in domain\user format? Leave it.
    if ($user -match '^[^\\]+\\[^\\]+$') {
        $skipped++
        continue
    }

    # Convert emails like firstname.lastname@volue.com -> voluead\firstname.lastname
    # (Only for the domain you specify)
    $pattern = '^(?<name>[^@]+)@' + [regex]::Escape($EmailDomain) + '$'
    if ($user -match $pattern) {
        $row.User = "$DomainPrefix\$($Matches.name)"
        $changed++
        continue
    }

    # Anything else (external domains, weird values) stays unchanged
    $skipped++
}

# Export WITHOUT headers.
# Export-Csv always writes headers, so write to temp then drop first line.
$tmp = [System.IO.Path]::GetTempFileName()
$data | Export-Csv -Path $tmp -Delimiter $Delimiter -NoTypeInformation -Encoding UTF8

Get-Content -Path $tmp | Select-Object -Skip 1 | Set-Content -Path $OutputFile -Encoding UTF8
Remove-Item $tmp -Force

Write-Host "Done."
Write-Host "  Changed: $changed"
Write-Host "  Skipped: $skipped"
Write-Host "  Output : $OutputFile"
