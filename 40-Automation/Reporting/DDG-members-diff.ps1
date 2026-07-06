param(
    [Parameter(Mandatory = $true)]
    [string]$File1,

    [Parameter(Mandatory = $true)]
    [string]$File2
)

Write-Host "Loading CSV files (no headers, columns = Name, Email)..." -ForegroundColor Cyan

# Import as headerless CSV: we tell PowerShell what the columns are
$csv1 = Import-Csv -Path $File1 -Header 'Name','Email'
$csv2 = Import-Csv -Path $File2 -Header 'Name','Email'

# If by any chance there IS a header row, drop it (heuristic: Email column without '@')
if ($csv1.Count -gt 0 -and $csv1[0].Email -notmatch '@') {
    $csv1 = $csv1 | Select-Object -Skip 1
}
if ($csv2.Count -gt 0 -and $csv2[0].Email -notmatch '@') {
    $csv2 = $csv2 | Select-Object -Skip 1
}

# Normalize a bit
$csv1 = $csv1 | ForEach-Object {
    [pscustomobject]@{
        Name  = (($_.Name)  -as [string]).Trim()
        Email = (($_.Email) -as [string]).Trim().ToLower()
    }
}
$csv2 = $csv2 | ForEach-Object {
    [pscustomobject]@{
        Name  = (($_.Name)  -as [string]).Trim()
        Email = (($_.Email) -as [string]).Trim().ToLower()
    }
}

Write-Host ""
Write-Host "=== BASIC STATS ===" -ForegroundColor Yellow
Write-Host ("File1: {0}" -f $File1)
Write-Host ("  Rows: {0}" -f $csv1.Count)
Write-Host ("File2: {0}" -f $File2)
Write-Host ("  Rows: {0}" -f $csv2.Count)
Write-Host ""

# Compare by Name+Email pair (unique users)
$u1 = $csv1 | Sort-Object Name,Email -Unique
$u2 = $csv2 | Sort-Object Name,Email -Unique

$diff = Compare-Object $u1 $u2 -Property Name,Email -PassThru

$onlyInFile1 = $diff | Where-Object SideIndicator -eq '<='
$onlyInFile2 = $diff | Where-Object SideIndicator -eq '=>'

Write-Host "=== USERS ONLY IN FILE1 ===" -ForegroundColor Yellow
if ($onlyInFile1) {
    $onlyInFile1 | Sort-Object Name,Email |
        Select-Object Name,Email |
        Format-Table -AutoSize
} else {
    Write-Host "None (all users from File1 exist in File2)." -ForegroundColor Green
}

Write-Host ""
Write-Host "=== USERS ONLY IN FILE2 ===" -ForegroundColor Yellow
if ($onlyInFile2) {
    $onlyInFile2 | Sort-Object Name,Email |
        Select-Object Name,Email |
        Format-Table -AutoSize
} else {
    Write-Host "None (all users from File2 exist in File1)." -ForegroundColor Green
}
