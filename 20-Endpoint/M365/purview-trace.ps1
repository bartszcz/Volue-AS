# Fetch-EntraEmails.ps1
Connect-MgGraph -Scopes "User.Read.All"

$names = @(
    @{ First = "Ali";         Last = "Güleç" },
    @{ First = "Corc";        Last = "Berirmen" },
    @{ First = "Ece Naz";     Last = "Karamağara" },
    @{ First = "Efe";         Last = "Özdemir" },
    @{ First = "Gizem";       Last = "Yalçın" },
    @{ First = "Gizem Ceren"; Last = "Demir" },
    @{ First = "Gülce";       Last = "Baysal" },
    @{ First = "İlayda";      Last = "Kenar" },
    @{ First = "İlkay";       Last = "Arbaş Suray" },
    @{ First = "Mert";        Last = "Bozkurt" },
    @{ First = "Mert İzzet";  Last = "Tanaltay" },
    @{ First = "Nagihan";     Last = "Çiftçi" },
    @{ First = "Pelin";       Last = "Aydoğdu" },
    @{ First = "Rifat Anıl";  Last = "Aydın" },
    @{ First = "Tuncay";      Last = "Karatut" },
    @{ First = "Zeynep Selin";Last = "Gür" }
)

$results = foreach ($person in $names) {
    $displayName = "$($person.First) $($person.Last)"

    $found = Get-MgUser -Filter "startsWith(displayName,'$($person.First)') and surname eq '$($person.Last)'" `
                        -ConsistencyLevel eventual `
                        -All `
                        -ErrorAction SilentlyContinue

    if (-not $found) {
        $found = Get-MgUser -Filter "surname eq '$($person.Last)'" `
                            -ConsistencyLevel eventual `
                            -All `
                            -ErrorAction SilentlyContinue
    }

    if (-not $found) {
        [PSCustomObject]@{ Name = $displayName; Email = ""; Status = "Not found" }
        continue
    }

    $users = $found | ForEach-Object {
        Get-MgUser -UserId $_.Id | Select-Object DisplayName, Mail, UserPrincipalName
    }

    if ($users.Count -eq 1) {
        [PSCustomObject]@{
            Name   = $displayName
            Email  = if ($users[0].Mail) { $users[0].Mail } else { $users[0].UserPrincipalName }
            Status = "Found"
        }
    } else {
        [PSCustomObject]@{
            Name   = $displayName
            Email  = ($users | ForEach-Object { if ($_.Mail) { $_.Mail } else { $_.UserPrincipalName } }) -join " | "
            Status = "Multiple matches — review manually"
        }
    }
}

# Summary table
$results | Format-Table -AutoSize

# Export to CSV
$results | Export-Csv -Path ".\entra-emails.csv" -NoTypeInformation -Encoding UTF8
Write-Host "Saved to .\entra-emails.csv" -ForegroundColor Green

# Clean list for copying
Write-Host "`n--- Email Addresses ---" -ForegroundColor Cyan
$results | Where-Object { $_.Email } | ForEach-Object { Write-Host $_.Email }