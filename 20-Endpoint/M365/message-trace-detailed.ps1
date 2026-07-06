$Trace = Get-MessageTraceV2 `
    -StartDate "2026-06-02 00:00" `
    -EndDate "2026-06-02 23:59" `
    -SenderAddress "VoluePorvooCR10@volue.com"

$Trace | Format-Table Received, SenderAddress, RecipientAddress, Subject, Status, MessageTraceId -AutoSize

foreach ($Item in $Trace) {
    Get-MessageTraceDetailV2 `
        -MessageTraceId $Item.MessageTraceId `
        -RecipientAddress $Item.RecipientAddress |
    Select-Object `
        Date,
        Event,
        Action,
        Detail,
        Data |
    Format-List
}