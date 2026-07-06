Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

function Get-NameParts {
    param(
        [Parameter(Mandatory)]
        [string]$DisplayName
    )

    $dn = ($DisplayName ?? '').Trim()
    if ([string]::IsNullOrWhiteSpace($dn)) {
        return [pscustomobject]@{
            FirstName    = ''
            LastName     = ''
            SortKeyLast  = 'ZZZZZZZZ'
            SortKeyFirst = 'ZZZZZZZZ'
        }
    }

    if ($dn -match '^\s*(?<Last>[^,]+)\s*,\s*(?<First>.+?)\s*$') {
        $last  = $Matches['Last'].Trim()
        $first = $Matches['First'].Trim()
        return [pscustomobject]@{
            FirstName    = $first
            LastName     = $last
            SortKeyLast  = $last.ToLowerInvariant()
            SortKeyFirst = $first.ToLowerInvariant()
        }
    }

    $tokens = $dn -split '\s+' | Where-Object { $_ -and $_.Trim() -ne '' }
    if ($tokens.Count -eq 1) {
        $last = $tokens[0].Trim()
        return [pscustomobject]@{
            FirstName    = ''
            LastName     = $last
            SortKeyLast  = $last.ToLowerInvariant()
            SortKeyFirst = ''
        }
    }

    $last  = $tokens[-1].Trim()
    $first = ($tokens[0..($tokens.Count-2)] -join ' ').Trim()

    return [pscustomobject]@{
        FirstName    = $first
        LastName     = $last
        SortKeyLast  = $last.ToLowerInvariant()
        SortKeyFirst = $first.ToLowerInvariant()
    }
}

function Set-Theme {
    param(
        [Parameter(Mandatory)]
        [System.Windows.Forms.Form]$Form,

        [Parameter(Mandatory)]
        [bool]$IsDark
    )

    if ($IsDark) {
        $bg = [System.Drawing.Color]::FromArgb(32, 32, 32)
        $fg = [System.Drawing.Color]::Gainsboro
        $panelBg = [System.Drawing.Color]::FromArgb(40, 40, 40)
        $btnBg = [System.Drawing.Color]::FromArgb(55, 55, 55)
        $gridBg = [System.Drawing.Color]::FromArgb(30, 30, 30)
        $gridAlt = [System.Drawing.Color]::FromArgb(36, 36, 36)
        $gridHeader = [System.Drawing.Color]::FromArgb(45, 45, 45)
        $gridLines = [System.Drawing.Color]::FromArgb(70, 70, 70)
    } else {
        $bg = [System.Drawing.SystemColors]::Control
        $fg = [System.Drawing.SystemColors]::ControlText
        $panelBg = [System.Drawing.SystemColors]::Control
        $btnBg = [System.Drawing.SystemColors]::Control
        $gridBg = [System.Drawing.Color]::White
        $gridAlt = [System.Drawing.Color]::FromArgb(245, 245, 245)
        $gridHeader = [System.Drawing.SystemColors]::Control
        $gridLines = [System.Drawing.Color]::FromArgb(210, 210, 210)
    }

    $Form.BackColor = $bg
    $Form.ForeColor = $fg

    function Apply-ControlTheme {
        param([System.Windows.Forms.Control]$c)

        switch ($c.GetType().FullName) {
            'System.Windows.Forms.DataGridView' {
                $dg = [System.Windows.Forms.DataGridView]$c
                $dg.BackgroundColor = $gridBg
                $dg.GridColor = $gridLines

                $dg.EnableHeadersVisualStyles = $false
                $dg.ColumnHeadersDefaultCellStyle.BackColor = $gridHeader
                $dg.ColumnHeadersDefaultCellStyle.ForeColor = $fg
                $dg.ColumnHeadersDefaultCellStyle.SelectionBackColor = $gridHeader
                $dg.ColumnHeadersDefaultCellStyle.SelectionForeColor = $fg

                $dg.DefaultCellStyle.BackColor = $gridBg
                $dg.DefaultCellStyle.ForeColor = $fg
                $dg.DefaultCellStyle.SelectionBackColor = [System.Drawing.Color]::FromArgb(
                    [Math]::Min($gridBg.R + 35, 255),
                    [Math]::Min($gridBg.G + 35, 255),
                    [Math]::Min($gridBg.B + 35, 255)
                )
                $dg.DefaultCellStyle.SelectionForeColor = $fg

                $dg.AlternatingRowsDefaultCellStyle.BackColor = $gridAlt
                $dg.AlternatingRowsDefaultCellStyle.ForeColor = $fg
            }
            'System.Windows.Forms.TextBox' {
                $c.BackColor = if ($IsDark) { $panelBg } else { [System.Drawing.Color]::White }
                $c.ForeColor = $fg
                $c.BorderStyle = 'FixedSingle'
            }
            'System.Windows.Forms.Button' {
                $c.BackColor = $btnBg
                $c.ForeColor = $fg
                $c.FlatStyle = 'Standard'
            }
            'System.Windows.Forms.CheckBox' {
                $c.BackColor = $bg
                $c.ForeColor = $fg
            }
            'System.Windows.Forms.Label' {
                $c.BackColor = $bg
                $c.ForeColor = $fg
            }
            default {
                $c.BackColor = $bg
                $c.ForeColor = $fg
            }
        }

        foreach ($child in $c.Controls) {
            Apply-ControlTheme -c $child
        }
    }

    Apply-ControlTheme -c $Form
}

$members = @()
$ddg = $null
$script:currentDataTable = $null
$script:isDarkTheme = $false

if (-not (Get-Module -ListAvailable -Name ExchangeOnlineManagement)) {
    [System.Windows.Forms.MessageBox]::Show(
        "ExchangeOnlineManagement module not found. Installing...",
        "Installing Module",
        [System.Windows.Forms.MessageBoxButtons]::OK,
        [System.Windows.Forms.MessageBoxIcon]::Information
    )
    try {
        Install-Module -Name ExchangeOnlineManagement -Force -AllowClobber -Scope CurrentUser
    } catch {
        [System.Windows.Forms.MessageBox]::Show(
            "Error installing module: $_`n`nPlease run PowerShell as Administrator and try again.",
            "Error",
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Error
        )
        exit
    }
}

Import-Module ExchangeOnlineManagement -ErrorAction SilentlyContinue

try {
    $null = Get-OrganizationConfig -ErrorAction Stop
} catch {
    try {
        Connect-ExchangeOnline -ShowBanner:$false
    } catch {
        [System.Windows.Forms.MessageBox]::Show(
            "Error connecting to Exchange Online: $_",
            "Connection Error",
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Error
        )
        exit
    }
}

$form = New-Object System.Windows.Forms.Form
$form.Text = "Dynamic Distribution Group Members"
$form.Size = New-Object System.Drawing.Size(1000, 600)
$form.StartPosition = "CenterScreen"

$label = New-Object System.Windows.Forms.Label
$label.Location = New-Object System.Drawing.Point(10, 20)
$label.Size = New-Object System.Drawing.Size(100, 20)
$label.Text = "Group Name:"
$form.Controls.Add($label)

$textBox = New-Object System.Windows.Forms.TextBox
$textBox.Location = New-Object System.Drawing.Point(110, 18)
$textBox.Size = New-Object System.Drawing.Size(450, 23)
$form.Controls.Add($textBox)

$searchButton = New-Object System.Windows.Forms.Button
$searchButton.Location = New-Object System.Drawing.Point(570, 16)
$searchButton.Size = New-Object System.Drawing.Size(100, 27)
$searchButton.Text = "Search"
$form.Controls.Add($searchButton)

$exportButton = New-Object System.Windows.Forms.Button
$exportButton.Location = New-Object System.Drawing.Point(680, 16)
$exportButton.Size = New-Object System.Drawing.Size(120, 27)
$exportButton.Text = "Export to CSV"
$exportButton.Enabled = $false
$form.Controls.Add($exportButton)

$themeCheckbox = New-Object System.Windows.Forms.CheckBox
$themeCheckbox.Location = New-Object System.Drawing.Point(820, 20)
$themeCheckbox.Size = New-Object System.Drawing.Size(160, 20)
$themeCheckbox.Text = "Dark theme"
$themeCheckbox.Checked = $false
$form.Controls.Add($themeCheckbox)

$dataGridView = New-Object System.Windows.Forms.DataGridView
$dataGridView.Location = New-Object System.Drawing.Point(10, 100)
$dataGridView.Size = New-Object System.Drawing.Size(960, 450)
$dataGridView.AutoSizeColumnsMode = "Fill"
$dataGridView.ReadOnly = $true
$dataGridView.AllowUserToAddRows = $false
$dataGridView.SelectionMode = 'FullRowSelect'
$dataGridView.MultiSelect = $false
$form.Controls.Add($dataGridView)

$statusLabel = New-Object System.Windows.Forms.Label
$statusLabel.Location = New-Object System.Drawing.Point(10, 50)
$statusLabel.Size = New-Object System.Drawing.Size(960, 40)
$statusLabel.Text = "Enter a group name and click Search"
$statusLabel.AutoSize = $false
$form.Controls.Add($statusLabel)

Set-Theme -Form $form -IsDark:$script:isDarkTheme

$themeCheckbox.Add_CheckedChanged({
    $script:isDarkTheme = [bool]$themeCheckbox.Checked
    Set-Theme -Form $form -IsDark:$script:isDarkTheme
    $form.Refresh()
})

$searchButton.Add_Click({
    $groupName = $textBox.Text

    if ([string]::IsNullOrWhiteSpace($groupName)) {
        [System.Windows.Forms.MessageBox]::Show(
            "Group name cannot be empty",
            "Error",
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Error
        )
        return
    }

    try {
        $statusLabel.Text = "Looking up group: $groupName..."
        $form.Refresh()

        $script:ddg = Get-DynamicDistributionGroup -Identity $groupName -ErrorAction Stop

        $statusLabel.Text = "Retrieving members..."
        $form.Refresh()

        $rawMembers = Get-Recipient -RecipientPreviewFilter $script:ddg.RecipientFilter -ResultSize Unlimited

        $script:members = ($rawMembers | ForEach-Object {
            $np = Get-NameParts -DisplayName $_.DisplayName
            [pscustomobject]@{
                DisplayName        = $_.DisplayName
                FirstName          = $np.FirstName
                LastName           = $np.LastName
                PrimarySmtpAddress = $_.PrimarySmtpAddress
                RecipientType      = $_.RecipientType
                _SortLast          = $np.SortKeyLast
                _SortFirst         = $np.SortKeyFirst
            }
        }) | Sort-Object _SortLast, _SortFirst, DisplayName

        $memberCount = ($script:members | Measure-Object).Count
        $statusLabel.Text = "Group: $($script:ddg.Name) | Email: $($script:ddg.PrimarySmtpAddress) | Total Members: $memberCount"

        $dataTable = New-Object System.Data.DataTable
        [void]$dataTable.Columns.Add("Last Name")
        [void]$dataTable.Columns.Add("First Name")
        [void]$dataTable.Columns.Add("Display Name")
        [void]$dataTable.Columns.Add("Email Address")
        [void]$dataTable.Columns.Add("Recipient Type")

        foreach ($member in $script:members) {
            $row = $dataTable.NewRow()
            $row["Last Name"]      = $member.LastName
            $row["First Name"]     = $member.FirstName
            $row["Display Name"]   = $member.DisplayName
            $row["Email Address"]  = $member.PrimarySmtpAddress
            $row["Recipient Type"] = $member.RecipientType
            [void]$dataTable.Rows.Add($row)
        }

        $script:currentDataTable = $dataTable
        $dataGridView.DataSource = $dataTable

        if ($dataGridView.Columns["Last Name"]) {
            $dataGridView.Sort($dataGridView.Columns["Last Name"], [System.ComponentModel.ListSortDirection]::Ascending)
        }

        $exportButton.Enabled = $true
        Set-Theme -Form $form -IsDark:$script:isDarkTheme

    } catch {
        [System.Windows.Forms.MessageBox]::Show(
            "Error: $_`n`nPlease verify the group name and try again.",
            "Error",
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Error
        )
        $statusLabel.Text = "Error retrieving group information"
        $exportButton.Enabled = $false
        $dataGridView.DataSource = $null
        $script:members = @()
    }
})

$exportButton.Add_Click({
    if (-not $script:members -or $script:members.Count -eq 0) {
        [System.Windows.Forms.MessageBox]::Show(
            "No data to export",
            "Export",
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Information
        )
        return
    }

    $saveFileDialog = New-Object System.Windows.Forms.SaveFileDialog
    $saveFileDialog.Filter = "CSV files (*.csv)|*.csv"
    $saveFileDialog.InitialDirectory = [Environment]::GetFolderPath("MyDocuments")
    $saveFileDialog.FileName = "$($script:ddg.Name)_Members_$(Get-Date -Format 'yyyyMMdd_HHmmss').csv"

    if ($saveFileDialog.ShowDialog() -eq "OK") {
        try {
            $script:members |
                Select-Object LastName, FirstName, DisplayName, PrimarySmtpAddress, RecipientType |
                Export-Csv -Path $saveFileDialog.FileName -NoTypeInformation -Encoding UTF8

            [System.Windows.Forms.MessageBox]::Show(
                "Export completed successfully!`n`nFile saved to: $($saveFileDialog.FileName)",
                "Export Complete",
                [System.Windows.Forms.MessageBoxButtons]::OK,
                [System.Windows.Forms.MessageBoxIcon]::Information
            )
        } catch {
            [System.Windows.Forms.MessageBox]::Show(
                "Error exporting to CSV: $_",
                "Export Error",
                [System.Windows.Forms.MessageBoxButtons]::OK,
                [System.Windows.Forms.MessageBoxIcon]::Error
            )
        }
    }
})

$textBox.Add_KeyDown({
    if ($_.KeyCode -eq 'Enter') {
        $searchButton.PerformClick()
        $_.Handled = $true
        $_.SuppressKeyPress = $true
    }
})

[void]$form.ShowDialog()
