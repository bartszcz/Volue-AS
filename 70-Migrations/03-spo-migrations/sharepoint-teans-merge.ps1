<#
.SYNOPSIS
    SharePoint Site Collection - Teams Membership Checker

.DESCRIPTION
    Reads a SharePoint Sites CSV and a Microsoft 365 Groups / Teams CSV,
    determines whether each SharePoint site is Teams-connected, and exports
    a new CSV with "Is Teams?" as the LAST column.

    Matching logic:
      1. Prefer direct site CSV signal: "Teams" column
      2. Fallback: URL leaf (/sites/<alias>) matches Group alias
      3. Fallback: Site name matches Group name
#>

function Show-Banner {
    Clear-Host
    Write-Host ""
    Write-Host ("=" * 72) -ForegroundColor Cyan
    Write-Host "   SharePoint Site Collection  -  Teams Membership Checker" -ForegroundColor Cyan
    Write-Host ("=" * 72) -ForegroundColor Cyan
    Write-Host ""
}

function Detect-Encoding {
    param([string]$FilePath)

    $bytes = [System.IO.File]::ReadAllBytes($FilePath)

    if ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) {
        return [System.Text.Encoding]::UTF8
    }
    if ($bytes.Length -ge 2 -and $bytes[0] -eq 0xFF -and $bytes[1] -eq 0xFE) {
        return [System.Text.Encoding]::Unicode
    }
    if ($bytes.Length -ge 2 -and $bytes[0] -eq 0xFE -and $bytes[1] -eq 0xFF) {
        return [System.Text.Encoding]::BigEndianUnicode
    }

    return [System.Text.Encoding]::Default
}

function Import-CsvPreserveEncoding {
    param([string]$FilePath)

    $encoding = Detect-Encoding -FilePath $FilePath

    if ($encoding -eq [System.Text.Encoding]::UTF8) {
        return Import-Csv -LiteralPath $FilePath -Encoding UTF8
    }
    elseif ($encoding -eq [System.Text.Encoding]::Unicode) {
        return Import-Csv -LiteralPath $FilePath -Encoding Unicode
    }
    elseif ($encoding -eq [System.Text.Encoding]::BigEndianUnicode) {
        return Import-Csv -LiteralPath $FilePath -Encoding BigEndianUnicode
    }
    else {
        return Import-Csv -LiteralPath $FilePath -Encoding Default
    }
}

function Export-CsvPreserveEncoding {
    param(
        [object[]]$Data,
        [string]$OutputPath,
        [System.Text.Encoding]$SourceEncoding
    )

    $csvLines = $Data | ConvertTo-Csv -NoTypeInformation
    $csvContent = $csvLines -join "`r`n"
    [System.IO.File]::WriteAllText($OutputPath, $csvContent, $SourceEncoding)
}

function Get-FolderPath {
    while ($true) {
        Write-Host "   Enter the folder containing your CSV files" -ForegroundColor Yellow
        Write-Host ""

        $input_path = (Read-Host "   Folder path").Trim().Trim('"').Trim("'")

        if ([string]::IsNullOrWhiteSpace($input_path)) {
            Write-Host ""
            Write-Host "   [!] No path entered." -ForegroundColor Red
            Write-Host ""
            continue
        }

        if (-not (Test-Path -LiteralPath $input_path -PathType Container)) {
            Write-Host ""
            Write-Host "   [!] Folder not found: $input_path" -ForegroundColor Red
            Write-Host ""
            continue
        }

        $csvFiles = Get-ChildItem -LiteralPath $input_path -Filter "*.csv" -File | Sort-Object Name

        if ($csvFiles.Count -eq 0) {
            Write-Host ""
            Write-Host "   [!] No CSV files found in that folder." -ForegroundColor Red
            Write-Host ""
            continue
        }

        return @{
            FolderPath = $input_path
            CsvFiles   = $csvFiles
        }
    }
}

function Select-CsvFile {
    param(
        [System.IO.FileInfo[]]$CsvFiles,
        [string]$Prompt,
        [int]$ExcludeIndex = -1
    )

    while ($true) {
        Write-Host ""
        Write-Host "   $Prompt" -ForegroundColor Yellow
        Write-Host ""

        for ($i = 0; $i -lt $CsvFiles.Count; $i++) {
            $file = $CsvFiles[$i]
            $marker = if ($i -eq $ExcludeIndex) { " (already selected)" } else { "" }
            $sizeKB = [math]::Round($file.Length / 1KB, 1)
            Write-Host ("   [{0}] {1} ({2} KB){3}" -f ($i + 1), $file.Name, $sizeKB, $marker) -ForegroundColor White
        }

        Write-Host ""
        $choice = (Read-Host "   Enter number").Trim()

        $num = 0
        if (-not [int]::TryParse($choice, [ref]$num)) {
            Write-Host "   [!] Invalid number." -ForegroundColor Red
            continue
        }

        if ($num -lt 1 -or $num -gt $CsvFiles.Count) {
            Write-Host "   [!] Number out of range." -ForegroundColor Red
            continue
        }

        if (($num - 1) -eq $ExcludeIndex) {
            Write-Host "   [!] That file is already selected as the other report." -ForegroundColor Red
            continue
        }

        return @{
            File  = $CsvFiles[$num - 1]
            Index = $num - 1
        }
    }
}

function Get-OutputPath {
    param([string]$SharePointPath)

    $directory  = [System.IO.Path]::GetDirectoryName($SharePointPath)
    $baseName   = [System.IO.Path]::GetFileNameWithoutExtension($SharePointPath)
    $timestamp  = Get-Date -Format "yyyy-MM-dd_HH-mm-ss"
    $defaultOut = Join-Path $directory "${baseName}_with_Teams_Check_${timestamp}.csv"

    Write-Host ""
    Write-Host "   Suggested output file:" -ForegroundColor White
    Write-Host "   $defaultOut" -ForegroundColor Gray
    Write-Host ""

    $response = (Read-Host "   Press ENTER to accept, or type a new file path").Trim()
    if (-not [string]::IsNullOrWhiteSpace($response)) {
        return $response.Trim('"').Trim("'")
    }

    return $defaultOut
}

function Normalize-HeaderName {
    param([string]$Name)

    if ($null -eq $Name) { return "" }

    $clean = [string]$Name
    $clean = $clean -replace '^\uFEFF+', ''
    $clean = $clean -replace '^[\u200B\u200C\u200D\u2060]+', ''
    $clean = $clean.Trim()
    $clean = $clean.Trim('"')
    $clean = $clean.Trim()
    $clean = $clean -replace '\s+', ' '

    return $clean
}

function Get-ColumnName {
    param(
        [string[]]$Columns,
        [string[]]$Candidates,
        [string]$FriendlyName
    )

    foreach ($column in $Columns) {
        $normalizedColumn = Normalize-HeaderName $column

        foreach ($candidate in $Candidates) {
            $normalizedCandidate = Normalize-HeaderName $candidate
            if ($normalizedColumn -ieq $normalizedCandidate) {
                return $column
            }
        }
    }

    throw "Could not find required column for '$FriendlyName'. Looked for: $($Candidates -join ', ')"
}

function Normalize-Text {
    param([object]$Value)

    if ($null -eq $Value) { return "" }

    $text = [string]$Value
    $text = $text.Trim().Trim('"')
    $text = [regex]::Replace($text, '\s+', ' ')

    return $text.ToLowerInvariant()
}

function Get-SiteUrlLeaf {
    param([string]$Url)

    if ([string]::IsNullOrWhiteSpace($Url)) { return "" }

    $m = [regex]::Match($Url, '/sites/([^/?#]+)', [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
    if ($m.Success) {
        return $m.Groups[1].Value.Trim().ToLowerInvariant()
    }

    return ""
}

function Convert-ToBoolean {
    param([object]$Value)

    if ($null -eq $Value) { return $false }

    $text = ([string]$Value).Trim().Trim('"').ToLowerInvariant()
    return $text -in @('true', 'yes', '1')
}

function Main {
    Show-Banner

    Write-Host "   STEP 1 - Select folder" -ForegroundColor White
    $folderInfo = Get-FolderPath
    $csvFiles = $folderInfo.CsvFiles

    Write-Host ""
    Write-Host "   STEP 2 - Select SharePoint Sites CSV" -ForegroundColor White
    $spSelection = Select-CsvFile -CsvFiles $csvFiles -Prompt "Which file is the SharePoint Sites report?"
    $spFile  = $spSelection.File
    $spIndex = $spSelection.Index

    Write-Host ""
    Write-Host "   STEP 3 - Select Groups / Teams CSV" -ForegroundColor White
    $teamsSelection = Select-CsvFile -CsvFiles $csvFiles -Prompt "Which file is the Microsoft 365 Groups / Teams report?" -ExcludeIndex $spIndex
    $teamsFile = $teamsSelection.File

    Write-Host ""
    Write-Host "   Reading files..." -ForegroundColor White

    $spEncoding = Detect-Encoding -FilePath $spFile.FullName

    try {
        $spData    = Import-CsvPreserveEncoding -FilePath $spFile.FullName
        $teamsData = Import-CsvPreserveEncoding -FilePath $teamsFile.FullName
    }
    catch {
        Write-Host "   [ERROR] Failed to read CSV files: $_" -ForegroundColor Red
        return
    }

    if (-not $spData -or $spData.Count -eq 0) {
        Write-Host "   [ERROR] SharePoint CSV is empty." -ForegroundColor Red
        return
    }

    if (-not $teamsData -or $teamsData.Count -eq 0) {
        Write-Host "   [ERROR] Groups / Teams CSV is empty." -ForegroundColor Red
        return
    }

    $spColumns = $spData[0].PSObject.Properties.Name
    $teamsColumns = $teamsData[0].PSObject.Properties.Name

    try {
        $spSiteNameProp = Get-ColumnName -Columns $spColumns -Candidates @('Site name', 'Title', 'Name') -FriendlyName 'SharePoint Site Name'
        $spUrlProp      = Get-ColumnName -Columns $spColumns -Candidates @('URL', 'Url', 'Site URL') -FriendlyName 'SharePoint URL'
        $spTeamsProp    = Get-ColumnName -Columns $spColumns -Candidates @('Teams') -FriendlyName 'SharePoint Teams flag'

        $groupNameProp  = Get-ColumnName -Columns $teamsColumns -Candidates @('Group name', 'Name') -FriendlyName 'Group Name'
        $groupAliasProp = Get-ColumnName -Columns $teamsColumns -Candidates @('Group alias', 'MailNickname', 'Alias') -FriendlyName 'Group Alias'
        $hasTeamsProp   = Get-ColumnName -Columns $teamsColumns -Candidates @('Has Teams', 'HasTeams') -FriendlyName 'Has Teams'
    }
    catch {
        Write-Host "   [ERROR] $_" -ForegroundColor Red
        Write-Host ""
        Write-Host "   SharePoint columns found:" -ForegroundColor Yellow
        $spColumns | ForEach-Object { Write-Host "     - $_" -ForegroundColor Gray }
        Write-Host ""
        Write-Host "   Groups columns found:" -ForegroundColor Yellow
        $teamsColumns | ForEach-Object { Write-Host "     - $_" -ForegroundColor Gray }
        return
    }

    $teamAliasSet = @{}
    $teamNameSet  = @{}

    foreach ($row in $teamsData) {
        if (-not (Convert-ToBoolean $row.$hasTeamsProp)) {
            continue
        }

        $groupAlias = Normalize-Text $row.$groupAliasProp
        $groupName  = Normalize-Text $row.$groupNameProp

        if (-not [string]::IsNullOrWhiteSpace($groupAlias)) {
            $teamAliasSet[$groupAlias] = $true
        }

        if (-not [string]::IsNullOrWhiteSpace($groupName)) {
            $teamNameSet[$groupName] = $true
        }
    }

    $outputRows = New-Object System.Collections.Generic.List[object]
    $yesCount = 0
    $noCount = 0

    foreach ($row in $spData) {
        $siteName = Normalize-Text $row.$spSiteNameProp
        $siteUrl  = [string]$row.$spUrlProp
        $siteLeaf = Get-SiteUrlLeaf $siteUrl

        $siteTeamsFlag = Convert-ToBoolean $row.$spTeamsProp

        $isTeams = $false

        if ($siteTeamsFlag) {
            $isTeams = $true
        }
        elseif (-not [string]::IsNullOrWhiteSpace($siteLeaf) -and $teamAliasSet.ContainsKey($siteLeaf)) {
            $isTeams = $true
        }
        elseif (-not [string]::IsNullOrWhiteSpace($siteName) -and $teamNameSet.ContainsKey($siteName)) {
            $isTeams = $true
        }

        if ($isTeams) {
            $yesCount++
        }
        else {
            $noCount++
        }

        # Rebuild row so "Is Teams?" is always the LAST column
        $ordered = [ordered]@{}

        foreach ($prop in $row.PSObject.Properties) {
            $ordered[$prop.Name] = $prop.Value
        }

        $ordered['Is Teams?'] = if ($isTeams) { 'Yes' } else { 'No' }

        $outputRows.Add([pscustomobject]$ordered)
    }

    Write-Host ""
    Write-Host ("=" * 60) -ForegroundColor Cyan
    Write-Host "   RESULTS SUMMARY" -ForegroundColor Cyan
    Write-Host ("=" * 60) -ForegroundColor Cyan
    Write-Host ""
    Write-Host ("   Total SharePoint sites:   {0}" -f $spData.Count) -ForegroundColor White
    Write-Host ("   Total groups in CSV:      {0}" -f $teamsData.Count) -ForegroundColor White
    Write-Host ("   Teams-connected sites:    {0}" -f $yesCount) -ForegroundColor Green
    Write-Host ("   Not Teams-connected:      {0}" -f $noCount) -ForegroundColor Yellow
    Write-Host ""

    Write-Host "   STEP 4 - Save output file" -ForegroundColor White
    $outputPath = Get-OutputPath -SharePointPath $spFile.FullName

    try {
        Export-CsvPreserveEncoding -Data $outputRows -OutputPath $outputPath -SourceEncoding $spEncoding

        Write-Host ""
        Write-Host "   [SUCCESS] Output file saved:" -ForegroundColor Green
        Write-Host "   $outputPath" -ForegroundColor White
        Write-Host ""
        Write-Host "   'Is Teams?' has been added as the last column." -ForegroundColor Gray
        Write-Host ""
    }
    catch {
        Write-Host ""
        Write-Host "   [ERROR] Could not save file: $_" -ForegroundColor Red
    }
}

try {
    Main
}
catch {
    Write-Host ""
    Write-Host "   [ERROR] Unexpected error: $_" -ForegroundColor Red
}
finally {
    Write-Host ""
    Write-Host "   Press any key to exit..." -ForegroundColor DarkGray
    $null = $Host.UI.RawUI.ReadKey('NoEcho,IncludeKeyDown')
}