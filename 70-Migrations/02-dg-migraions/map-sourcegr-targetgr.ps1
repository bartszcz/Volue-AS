# =============================================================
# Map Source (Smartpulse) Groups to Target (Volue) Groups
# Output: GroupMapping.csv
# =============================================================

$sourceFile = "C:\Scripts\Smartpulse-Groups.csv"
$targetFile = "C:\Scripts\Volue-Groups.csv"
$outputFile = "C:\Scripts\GroupMapping.csv"

# Load both CSVs
$sourceGroups = Import-Csv -Path $sourceFile
$targetGroups = Import-Csv -Path $targetFile

# Build a lookup for target groups by normalized name
# Normalize: lowercase, remove "smartpulse", remove pipes, trim
function Normalize-GroupName {
    param([string]$name)
    $n = $name.ToLower()
    $n = $n -replace '\s*\|\s*smartpulse', ''
    $n = $n -replace '\bsmartpulse\b', ''
    $n = $n.Trim() -replace '\s+', ' '
    $n = $n.Trim()
    return $n
}

# Build target lookup
$targetLookup = @{}
foreach ($t in $targetGroups) {
    $key = Normalize-GroupName -name $t.'Group name'
    $targetLookup[$key] = $t
}

# Match and build results
$results = [System.Collections.ArrayList]::new()
$unmatched = [System.Collections.ArrayList]::new()

foreach ($s in $sourceGroups) {
    $sourceName  = $s.'Group name'
    $sourceEmail = $s.'Group primary email'
    $key         = Normalize-GroupName -name $sourceName

    if ($targetLookup.ContainsKey($key)) {
        $t = $targetLookup[$key]
        [void]$results.Add([PSCustomObject]@{
            'Source Display Name' = $sourceName
            'Source Address'      = $sourceEmail
            'Target Display Name' = $t.'Group name'
            'Target Address'      = $t.'Group primary email'
        })
    }
    else {
        # Try partial match as fallback
        $found = $false
        foreach ($t in $targetGroups) {
            $tKey = Normalize-GroupName -name $t.'Group name'
            if ($tKey -like "*$key*" -or $key -like "*$tKey*") {
                [void]$results.Add([PSCustomObject]@{
                    'Source Display Name' = $sourceName
                    'Source Address'      = $sourceEmail
                    'Target Display Name' = $t.'Group name'
                    'Target Address'      = $t.'Group primary email'
                })
                $found = $true
                break
            }
        }
        if (-not $found) {
            Write-Host "No match for: $sourceName ($sourceEmail)" -ForegroundColor Yellow
            [void]$unmatched.Add([PSCustomObject]@{
                'Source Display Name' = $sourceName
                'Source Address'      = $sourceEmail
                'Target Display Name' = "NOT_FOUND"
                'Target Address'      = "NOT_FOUND"
            })
        }
    }
}

# Add unmatched to results so they're visible in the CSV
$results.AddRange($unmatched)

# Export
$results | Export-Csv -Path $outputFile -NoTypeInformation -Encoding UTF8

Write-Host ""
Write-Host "========================================" -ForegroundColor Cyan
Write-Host " Matched: $($results.Count - $unmatched.Count) groups" -ForegroundColor Green
Write-Host " Unmatched: $($unmatched.Count) groups" -ForegroundColor Yellow
Write-Host " Output: $outputFile" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan