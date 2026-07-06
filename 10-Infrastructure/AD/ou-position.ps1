$servers = @(
    'tdtrhbofbuild01'
    'tdtrhbofbuild02'
    'tdtrhbofbuild03'
    'tdtrhboftest001'
    'tdtrhboftest002'
    'tdtrhboftest003'
    'tdtrhboftest004'
    'tdtrhboftest005'
    'tdtrhboftest006'
    'tdtrhmdsdev01'
    'tdtrhmdsdev02'
    'tdtrhbofdb01'
    'tdtrhbofdb02'
    'tdtrhbofdb03'
    'tdtrhbofjenkins'
    'tdtrh3rdparty01'
    'tdtrhbofpm001'
)

$results = foreach ($name in $servers) {
    $computer = Get-ADComputer -Filter { Name -eq $name } -Properties DistinguishedName -ErrorAction SilentlyContinue
    [PSCustomObject]@{
        Name = $name
        OU   = if ($computer) { $computer.DistinguishedName } else { 'NOT FOUND' }
    }
}

$results | Format-Table -AutoSize
