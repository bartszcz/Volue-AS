<#
.SYNOPSIS
    Splits a combined SharePoint Sites & Teams CSV into two separate migration CSVs.

.DESCRIPTION
    Reads sharepoint-sites-teams.csv, splits rows by the "Is Teams?" column,
    and writes two output files matching the SmartPulse template column structure:
      - SharePointSitesMigrationList.csv  (Is Teams? = No)
      - TeamsMigrationList.csv            (Is Teams? = Yes)

    Rows whose source URL is the bare tenant root (no /sites/ segment) are treated
    as regular site migrations: the destination URL is built as
    /sites/<SlugFromSiteName><Suffix> so the target tenant root is never touched.

    The destination site name and URL are built by appending a user-defined suffix,
    UNLESS the site URL slug already contains the suffix (case-insensitive) -- in
    that case the suffix is omitted to match the template behaviour.

.PARAMETER Suffix
    The suffix to append to each destination site name and URL slug.
    Example: "SmartPulse"

.PARAMETER SourceTenant
    Base URL of the source SharePoint tenant (no trailing slash).
    Example: "https://quorumdev.sharepoint.com"

.PARAMETER DestTenant
    Base URL of the destination SharePoint tenant (no trailing slash).
    Example: "https://volue.sharepoint.com"

.PARAMETER SourceCsv
    Path to the combined input CSV file.
    Defaults to "sharepoint-sites-teams.csv" in the same folder as the script.

.PARAMETER OutSitesCsv
    Output path for the SharePoint Sites migration list.
    Defaults to "SharePointSitesMigrationList.csv" next to the script.

.PARAMETER OutTeamsCsv
    Output path for the Teams migration list.
    Defaults to "TeamsMigrationList.csv" next to the script.

.EXAMPLE
    # Fully interactive - prompts for all three required values
    .\Generate-MigrationLists.ps1

.EXAMPLE
    # Pass everything as parameters
    .\Generate-MigrationLists.ps1 -Suffix "SmartPulse" `
        -SourceTenant "https://quorumdev.sharepoint.com" `
        -DestTenant   "https://volue.sharepoint.com"
#>

[CmdletBinding()]
param (
    [string] $Suffix,
    [string] $SourceTenant,
    [string] $DestTenant,
    [string] $SourceCsv   = (Join-Path $PSScriptRoot "sharepoint-sites-teams.csv"),
    [string] $OutSitesCsv = (Join-Path $PSScriptRoot "SharePointSitesMigrationList.csv"),
    [string] $OutTeamsCsv = (Join-Path $PSScriptRoot "TeamsMigrationList.csv")
)

# ── 1. Prompt for any missing required parameters ─────────────────────────────

if (-not $Suffix) {
    $Suffix = Read-Host "Destination suffix (e.g. SmartPulse)"
}
if (-not $SourceTenant) {
    $SourceTenant = Read-Host "Source tenant URL (e.g. https://quorumdev.sharepoint.com)"
}
if (-not $DestTenant) {
    $DestTenant = Read-Host "Destination tenant URL (e.g. https://volue.sharepoint.com)"
}

$SourceTenant = $SourceTenant.TrimEnd("/")
$DestTenant   = $DestTenant.TrimEnd("/")

# ── 2. Load source CSV ────────────────────────────────────────────────────────

if (-not (Test-Path $SourceCsv)) {
    Write-Error "Source file not found: $SourceCsv"
    exit 1
}

$allRows = Import-Csv -Path $SourceCsv -Encoding UTF8

# The first column may have a BOM or surrounding quotes in its name (e.g. "Site name").
# Detect the actual column name and normalise it so we can reference it reliably.
$rawFirstCol   = ($allRows[0].PSObject.Properties.Name)[0]
$cleanFirstCol = $rawFirstCol -replace '^\xEF\xBB\xBF', '' `
                              -replace '^\uFEFF',        '' `
                              -replace '^"',             '' `
                              -replace '"$',             ''

# Rename the column in every row if the raw name differs from the clean name
if ($rawFirstCol -ne $cleanFirstCol) {
    $allRows = $allRows | ForEach-Object {
        $row = $_
        $obj = [ordered]@{}
        $obj[$cleanFirstCol] = $row.$rawFirstCol
        foreach ($col in ($row.PSObject.Properties.Name | Select-Object -Skip 1)) {
            $obj[$col] = $row.$col
        }
        [PSCustomObject]$obj
    }
}

Write-Host ""
Write-Host "Loaded $($allRows.Count) rows from: $SourceCsv"
Write-Host "Site name column detected as: '$cleanFirstCol'"

# ── 3. Split rows ─────────────────────────────────────────────────────────────

$teamRows = $allRows | Where-Object { $_.'Is Teams?' -match '^yes$' }
$siteRows = $allRows | Where-Object { $_.'Is Teams?' -notmatch '^yes$' }

Write-Host ""
Write-Host "  -> $($teamRows.Count) Teams rows"
Write-Host "  -> $($siteRows.Count) SharePoint Sites rows"

# ── 4. Helper: build a URL-safe slug from a display name ─────────────────────
# Strips anything that isn't a letter, digit, or hyphen.

function Get-Slug {
    param ([string] $Name)
    # Remove all characters that are not alphanumeric or hyphen, collapse spaces
    $slug = $Name -replace '[^A-Za-z0-9\-]', ''
    return $slug
}

# ── 5. Build one output row ───────────────────────────────────────────────────
#
# Suffix logic (mirrors the SmartPulse templates):
#   - If the source URL has a /sites/ segment, use that slug directly.
#   - If the source URL is the bare tenant root (no /sites/), build a slug
#     from the site display name and place it under /sites/ on the destination.
#   - If the slug already contains the suffix (case-insensitive) -> do NOT append
#     the suffix to either the display name or the destination URL.
#   - Otherwise -> append " {Suffix}" to the display name and "{Suffix}" to the URL.

function Build-OutputRow {
    param (
        [string] $Title,
        [string] $SrcUrl,
        [string] $SourceTenant,
        [string] $DestTenant,
        [string] $Suffix
    )

    $SrcUrl = $SrcUrl.TrimEnd("/")

    $isRootUrl = $SrcUrl -notmatch '/sites/'

    if ($isRootUrl) {
        # Build slug from site display name - root site gets its own /sites/ path
        $slug             = Get-Slug -Name $Title
        $alreadyHasSuffix = $slug -match [regex]::Escape($Suffix)

        if ($alreadyHasSuffix) {
            $newName = $Title
            $destUrl = "$DestTenant/sites/$slug"
        } else {
            $newName = "$Title $Suffix"
            $destUrl = "$DestTenant/sites/$slug$Suffix"
        }
    } else {
        # Normal /sites/ URL - extract existing slug
        $slug             = $SrcUrl -replace '.*\/sites\/', ''
        $alreadyHasSuffix = $slug -match [regex]::Escape($Suffix)

        if ($alreadyHasSuffix) {
            $newName = $Title
        } else {
            $newName = "$Title $Suffix"
        }

        if ($SrcUrl.StartsWith($SourceTenant, [System.StringComparison]::OrdinalIgnoreCase)) {
            $pathPart = $SrcUrl.Substring($SourceTenant.Length)
            $destUrl  = if ($alreadyHasSuffix) { $DestTenant + $pathPart } else { $DestTenant + $pathPart + $Suffix }
        } else {
            $destUrl = $SrcUrl -replace [regex]::Escape($SourceTenant), $DestTenant
            if (-not $alreadyHasSuffix) { $destUrl += $Suffix }
        }
    }

    [PSCustomObject] @{
        'Title'               = $Title
        'Site address'        = $SrcUrl
        'New Site Name Volue' = $newName
        'New Site URL Volue'  = $destUrl
    }
}

# ── 6. Convert all rows ───────────────────────────────────────────────────────

function Convert-Rows {
    param ($rows, [string]$SiteNameCol)
    $rows | ForEach-Object {
        $title = [string]$_.$SiteNameCol
        $url   = [string]$_.URL
        Build-OutputRow -Title $title.Trim() -SrcUrl $url.Trim() `
            -SourceTenant $SourceTenant -DestTenant $DestTenant -Suffix $Suffix
    }
}

$outSites = Convert-Rows -rows $siteRows -SiteNameCol $cleanFirstCol
$outTeams = Convert-Rows -rows $teamRows -SiteNameCol $cleanFirstCol

# ── 7. Export CSVs ────────────────────────────────────────────────────────────

$outSites | Export-Csv -Path $OutSitesCsv -NoTypeInformation -Encoding UTF8
$outTeams | Export-Csv -Path $OutTeamsCsv -NoTypeInformation -Encoding UTF8

Write-Host ""
Write-Host "Written: $OutSitesCsv  ($($outSites.Count) rows)"
Write-Host "Written: $OutTeamsCsv  ($($outTeams.Count) rows)"

# ── 8. Preview ────────────────────────────────────────────────────────────────

Write-Host ""
Write-Host "-- SharePoint Sites -------------------------------------------------"
$outSites | Format-Table -AutoSize

Write-Host "-- Teams ------------------------------------------------------------"
$outTeams | Format-Table -AutoSize