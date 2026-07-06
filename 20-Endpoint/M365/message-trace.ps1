Connect-ExchangeOnline

$StartDate = "2026-05-29 15:00"
$EndDate   = "2026-05-30 04:00"

$Users = @(
    "VoluePorvooCR10@volue.com",
    "controlroom.fi@volue.com",
    "tommi.murtola@volue.com"
)

$Operations = @(
    "Send",
    "SendAs",
    "SendOnBehalf",
    "MailItemsAccessed",
    "Create",
    "Update",
    "Move",
    "MoveToDeletedItems",
    "SoftDelete",
    "HardDelete"
)

$AllResults = foreach ($User in $Users) {
    Write-Host "Searching audit log for $User..." -ForegroundColor Cyan

    Search-UnifiedAuditLog `
        -StartDate $StartDate `
        -EndDate $EndDate `
        -UserIds $User `
        -Operations $Operations `
        -ResultSize 5000 |
    ForEach-Object {
        $Raw = $_
        $AuditData = $null

        try {
            $AuditData = $Raw.AuditData | ConvertFrom-Json
        }
        catch {
            Write-Warning "Could not parse AuditData for record $($Raw.Id)"
            return
        }

        $Subjects = @()
        $InternetMessageIds = @()
        $FolderPaths = @()

        if ($AuditData.Item) {
            if ($AuditData.Item.Subject) {
                $Subjects += $AuditData.Item.Subject
            }

            if ($AuditData.Item.InternetMessageId) {
                $InternetMessageIds += $AuditData.Item.InternetMessageId
            }
        }

        if ($AuditData.Folders) {
            foreach ($Folder in $AuditData.Folders) {
                if ($Folder.Path) {
                    $FolderPaths += $Folder.Path
                }

                if ($Folder.FolderItems) {
                    foreach ($FolderItem in $Folder.FolderItems) {
                        if ($FolderItem.Subject) {
                            $Subjects += $FolderItem.Subject
                        }

                        if ($FolderItem.InternetMessageId) {
                            $InternetMessageIds += $FolderItem.InternetMessageId
                        }
                    }
                }
            }
        }

        [PSCustomObject]@{
            CreationDate       = $Raw.CreationDate
            Operation          = $Raw.Operations
            ResultStatus       = $Raw.ResultStatus
            UserIds            = ($Raw.UserIds -join "; ")
            UserId             = $AuditData.UserId
            MailboxOwnerUPN    = $AuditData.MailboxOwnerUPN
            LogonType          = $AuditData.LogonType
            ClientIP           = $AuditData.ClientIPAddress
            ClientInfoString   = $AuditData.ClientInfoString
            AppId              = $AuditData.AppId
            DeviceId           = $AuditData.DeviceId
            FolderPath         = ($FolderPaths | Sort-Object -Unique) -join "; "
            Subject            = ($Subjects | Sort-Object -Unique) -join " | "
            InternetMessageId  = ($InternetMessageIds | Sort-Object -Unique) -join " | "
            RawAuditId         = $Raw.Id
        }
    }
}

$AllResults |
Sort-Object CreationDate |
Format-Table CreationDate, Operation, UserId, MailboxOwnerUPN, FolderPath, Subject, ClientIP -AutoSize

$AllResults |
Sort-Object CreationDate |
Export-Csv ".\Purview_MailboxTimeline_2026-05-29.csv" -NoTypeInformation -Encoding UTF8