Connect-ExchangeOnline

$Mailbox = "VoluePorvooCR10@volue.com"

$results = Search-UnifiedAuditLog `
    -UserIds $Mailbox `
    -StartDate "2026-05-29 18:00" `
    -EndDate "2026-05-29 23:59" `
    -Operations Send,Create,Update,Move,HardDelete,SoftDelete `
    -ResultSize 5000

$results | ForEach-Object {
    $data = $_.AuditData | ConvertFrom-Json
    [PSCustomObject]@{
        CreationDate         = $_.CreationDate
        LogonUserDisplayName = $data.UserId
        Operation            = $_.Operations
        OperationResult      = $data.ResultStatus
        FolderPath           = $data.ParentFolder.Path ?? $data.FolderPath ?? ""
        ItemSubject          = $data.Item.Subject ?? $data.Subject ?? ""
    }
} | Format-Table -AutoSize