#Requires -Version 5.1
# Exercises ram-altman.ps1 with simulated memory and a maildrop instead of SMTP.

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Continue'

$script = Join-Path $PSScriptRoot 'ram-altman.ps1'
$work = Join-Path ([System.IO.Path]::GetTempPath()) ("ram-altman-test-" + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Path (Join-Path $work 'state') -Force | Out-Null

$exe = (Get-Process -Id $PID).Path
if (-not $exe) { $exe = 'powershell.exe' }

$outbox  = Join-Path $work 'outbox'
$meminfo = Join-Path $work 'meminfo'

$env:RAM_ALTMAN_TO        = 'to@example.com'
$env:RAM_ALTMAN_FROM      = 'from@example.com'
$env:RAM_ALTMAN_STATE_DIR = Join-Path $work 'state'
$env:RAM_ALTMAN_MEMINFO   = $meminfo
$env:RAM_ALTMAN_MAILDROP  = $outbox
$env:RAM_ALTMAN_CONFIG    = Join-Path $work 'no-such.ini'   # keep real configs out

$pass = 0
$fail = 0

function Check {
    param([string]$Name, $Got, $Expected)
    if ("$Got" -eq "$Expected") {
        $script:pass++
        Write-Host "ok    $Name"
    }
    else {
        $script:fail++
        Write-Host "FAIL  $Name (expected '$Expected', got '$Got')"
    }
}

function Invoke-Script {
    param([string[]]$ScriptArgs = @())
    $all = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $script) + $ScriptArgs
    $out = & $exe @all 2>$null
    return [pscustomobject]@{ ExitCode = $LASTEXITCODE; Output = ($out -join "`n") }
}

function Get-SentCount {
    if (-not (Test-Path -LiteralPath $outbox)) { return 0 }
    return @(Get-Content -LiteralPath $outbox | Where-Object { $_ -eq '=====END=====' }).Count
}

function Set-Memory {
    param([int64]$TotalKb, [int64]$AvailableKb, $FreeKb = $null)
    $lines = @("TotalKB=$TotalKb", "AvailableKB=$AvailableKb")
    if ($null -ne $FreeKb) { $lines += "FreeKB=$FreeKb" }
    Set-Content -LiteralPath $meminfo -Encoding ASCII -Value $lines
}

function Reset-LastSent {
    Set-Content -LiteralPath (Join-Path $work 'state\last_sent') -Encoding ASCII -Value '2000-01-01'
}

try {
    # Mostly standby list: almost nothing is free, but plenty is available.
    Set-Memory 16000000 9000000 300000
    Invoke-Script | Out-Null
    Check 'standby counts as available: email sent' (Get-SentCount) 1

    Invoke-Script | Out-Null
    Invoke-Script | Out-Null
    Check 'second and third run same day: no more email' (Get-SentCount) 1

    $csv = Join-Path $work 'state\usage.csv'
    $lastRow = (Get-Content -LiteralPath $csv | Select-Object -Last 1).Split(',')
    Check 'used = total - available' $lastRow[2] 7000000
    Check 'three samples logged' (@(Get-Content -LiteralPath $csv).Count - 1) 3

    # Next day, tight on memory.
    Reset-LastSent
    Set-Memory 16000000 1000000 300000
    Invoke-Script | Out-Null
    Check '6.2% available: no email' (Get-SentCount) 1

    # Exactly 10% is not over 10%.
    Set-Memory 16000000 1600000 300000
    Invoke-Script | Out-Null
    Check 'exactly 10%: no email' (Get-SentCount) 1

    Set-Memory 16000000 1600001 300000
    Invoke-Script | Out-Null
    Check 'just over 10%: email sent' (Get-SentCount) 2

    # A failed send is retried, and only recorded once it works.
    Reset-LastSent
    Set-Memory 16000000 9000000 300000
    $env:RAM_ALTMAN_MAILDROP = Join-Path $work 'no-such-dir\outbox'
    $result = Invoke-Script
    Check 'failed send exits non-zero' $result.ExitCode 1
    Check 'failed send not recorded' (Get-Content -LiteralPath (Join-Path $work 'state\last_sent')) '2000-01-01'

    $env:RAM_ALTMAN_MAILDROP = $outbox
    Invoke-Script | Out-Null
    Check 'retry succeeds' (Get-SentCount) 3

    # No performance counters: the total and available figures still work,
    # but the free/standby split is honestly reported as unknown.
    Set-Memory 16000000 9000000
    $status = (Invoke-Script @('-Status')).Output
    Check 'available survives a missing breakdown' `
        (($status -split "`n" | Where-Object { $_ -like 'Available:*' }) -replace '\s+', ' ') `
        'Available: 8.6 GiB (56.2%)'
    Check 'missing breakdown reported honestly' `
        ([bool](($status -split "`n") -like '*Free:*unknown*')) 'True'

    # Variety: 10 bodies should all appear across 10 days, with no back-to-back repeat.
    Remove-Item -LiteralPath $outbox -ErrorAction SilentlyContinue
    Remove-Item -Path (Join-Path $work 'state\bag_*') -ErrorAction SilentlyContinue
    Set-Memory 16000000 9000000 300000
    for ($i = 0; $i -lt 40; $i++) {
        Reset-LastSent
        Invoke-Script | Out-Null
    }
    $lines = @(Get-Content -LiteralPath $outbox)
    $bodies = @()
    for ($i = 0; $i -lt $lines.Count; $i++) {
        if ($lines[$i] -eq 'Hi Sam,' -and ($i + 2) -lt $lines.Count) { $bodies += $lines[$i + 2] }
    }
    Check 'forty emails composed' $bodies.Count 40
    Check 'all opening lines used' (@($bodies | Select-Object -First 10 | Sort-Object -Unique).Count) 10

    $repeats = 0
    for ($i = 1; $i -lt $bodies.Count; $i++) {
        if ($bodies[$i] -eq $bodies[$i - 1]) { $repeats++ }
    }
    Check 'no back-to-back repeat' $repeats 0

    # Config errors.
    $savedTo = $env:RAM_ALTMAN_TO
    $env:RAM_ALTMAN_TO = ''
    Check 'missing recipient refused' (Invoke-Script).ExitCode 1
    $env:RAM_ALTMAN_TO = $savedTo

    # An ini file supplies settings, and the environment still wins.
    $ini = Join-Path $work 'ram-altman.ini'
    Set-Content -LiteralPath $ini -Encoding ASCII -Value @(
        '# a comment'
        'RAM_ALTMAN_FROM_NAME = From The Ini File'
        "THRESHOLD = 99"
    )
    $env:RAM_ALTMAN_CONFIG = $ini
    $out = (Invoke-Script @('-DryRun')).Output
    Check 'ini file threshold is read' `
        ([bool](($out -split "`n") -like 'No email:*above 99%*')) 'True'

    $env:RAM_ALTMAN_THRESHOLD = '10'
    $out = (Invoke-Script @('-DryRun')).Output
    Check 'environment beats the ini file' `
        ([bool](($out -split "`n") -like 'From: From The Ini File*')) 'True'
    Remove-Item Env:\RAM_ALTMAN_THRESHOLD
    $env:RAM_ALTMAN_CONFIG = Join-Path $work 'no-such.ini'

    # A named config file that does not exist must mean "no config", not "go
    # and find one next to the script". Otherwise a typo in RAM_ALTMAN_CONFIG
    # silently loads somebody else's settings.
    $besideScript = Join-Path $PSScriptRoot 'ram-altman.ini'
    $borrowed = $false
    if (-not (Test-Path -LiteralPath $besideScript)) {
        Set-Content -LiteralPath $besideScript -Encoding ASCII `
            -Value @('TO = should-not-be-used@example.com', 'FROM = nope@example.com')
        $borrowed = $true
    }
    if ($borrowed) {
        $savedTo = $env:RAM_ALTMAN_TO
        $env:RAM_ALTMAN_TO = ''
        Check 'a missing named config does not fall back' (Invoke-Script).ExitCode 1
        $env:RAM_ALTMAN_TO = $savedTo
        Remove-Item -LiteralPath $besideScript -Force
    }
    else {
        Write-Host 'skip  a missing named config does not fall back (ram-altman.ini in use)'
    }

    # The SMTP password: encrypted at rest, never left in plaintext.
    $secretIni = Join-Path $work 'secret.ini'
    Set-Content -LiteralPath $secretIni -Encoding ASCII -Value @(
        '# keep me'
        'TO          = to@example.com'
        'FROM        = from@example.com'
        'SMTP_SERVER = smtp.example.com'
        'SMTP_USER   = someone@example.com'
        'SMTP_PASS   = hunter2'
    )
    $env:RAM_ALTMAN_CONFIG = $secretIni
    'hunter2' | & $exe -NoProfile -ExecutionPolicy Bypass -File $script -SetPassword 2>$null | Out-Null

    $after = @(Get-Content -LiteralPath $secretIni)
    Check 'plaintext SMTP_PASS is removed' (@($after -match '^\s*SMTP_PASS\s*=').Count) 0
    Check 'SMTP_PASS_ENC is written'       (@($after -match '^\s*SMTP_PASS_ENC\s*=').Count) 1
    Check 'other settings survive'         (@($after -match '^\s*TO\s*=').Count) 1
    Check 'comments survive'               (@($after -match '^# keep me$').Count) 1

    $blob = (($after -match '^\s*SMTP_PASS_ENC\s*=') -split '=', 2)[1].Trim()
    Check 'the blob is not the password' ($blob -like '*hunter2*') 'False'
    $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR((ConvertTo-SecureString $blob))
    try { $roundTripped = [Runtime.InteropServices.Marshal]::PtrToStringAuto($bstr) }
    finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }
    Check 'it decrypts back to the password' $roundTripped 'hunter2'

    # The scripted route: -Password, with no stdin and no console involved.
    Set-Content -LiteralPath $secretIni -Encoding ASCII -Value @('TO = to@example.com')
    & $exe -NoProfile -ExecutionPolicy Bypass -Command `
        "& '$script' -SetPassword -Password (ConvertTo-SecureString 'via-param' -AsPlainText -Force)" `
        2>$null | Out-Null
    $blob2 = ((@(Get-Content -LiteralPath $secretIni) -match '^\s*SMTP_PASS_ENC\s*=') -split '=', 2)[1].Trim()
    $bstr2 = [Runtime.InteropServices.Marshal]::SecureStringToBSTR((ConvertTo-SecureString $blob2))
    try { $viaParam = [Runtime.InteropServices.Marshal]::PtrToStringAuto($bstr2) }
    finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr2) }
    Check '-Password works without a console' $viaParam 'via-param'

    # A blob from another account or machine must fail loudly, not silently.
    Set-Content -LiteralPath $secretIni -Encoding ASCII -Value @(
        'TO            = to@example.com'
        'FROM          = from@example.com'
        'SMTP_SERVER   = smtp.invalid'
        'SMTP_USER     = someone@example.com'
        'SMTP_PASS_ENC = 01000000d08c9ddf0115d1118c7a00c04fc297eb0000000deadbeef'
    )
    Remove-Item Env:\RAM_ALTMAN_MAILDROP
    Reset-LastSent
    Check 'an undecryptable blob fails loudly' (Invoke-Script).ExitCode 1
    $env:RAM_ALTMAN_MAILDROP = $outbox
    $env:RAM_ALTMAN_CONFIG = Join-Path $work 'no-such.ini'

    # The real machine: Windows' own numbers should add up the way we claim.
    try {
        $perf = Get-CimInstance -ClassName Win32_PerfRawData_PerfOS_Memory -ErrorAction Stop
        $sum = [int64]$perf.FreeAndZeroPageListBytes +
               [int64]$perf.StandbyCacheNormalPriorityBytes +
               [int64]$perf.StandbyCacheReserveBytes +
               [int64]$perf.StandbyCacheCoreBytes
        # Each counter is sampled a moment apart on a machine that is still
        # running, so allow a few pages of drift rather than exact equality.
        $drift = [math]::Abs($sum - [int64]$perf.AvailableBytes)
        Check 'available = free + standby on this machine' ($drift -lt 4MB) 'True'
    }
    catch {
        Write-Host 'skip  available = free + standby (no performance counters here)'
    }
}
finally {
    Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host ''
Write-Host "$pass passed, $fail failed"

Remove-Item Env:\RAM_ALTMAN_MEMINFO, Env:\RAM_ALTMAN_MAILDROP, Env:\RAM_ALTMAN_STATE_DIR,
            Env:\RAM_ALTMAN_CONFIG -ErrorAction SilentlyContinue

Write-Host ''
Write-Host '--- real machine status ---'
& $exe -NoProfile -ExecutionPolicy Bypass -File $script -Status

Write-Host ''
Write-Host '--- sample dry run ---'
$env:RAM_ALTMAN_MEMINFO = Join-Path ([System.IO.Path]::GetTempPath()) 'ram-altman-sample-meminfo'
Set-Content -LiteralPath $env:RAM_ALTMAN_MEMINFO -Encoding ASCII `
    -Value @('TotalKB=16000000', 'AvailableKB=9000000', 'FreeKB=300000')
& $exe -NoProfile -ExecutionPolicy Bypass -File $script -DryRun
Remove-Item -LiteralPath $env:RAM_ALTMAN_MEMINFO -ErrorAction SilentlyContinue
Remove-Item Env:\RAM_ALTMAN_MEMINFO -ErrorAction SilentlyContinue

exit $fail
