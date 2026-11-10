#Requires -Version 5.1
<#
    ram-altman.ps1 - track RAM usage and, at most once a day, tell Sam Altman
    when this PC has RAM to spare.

    Usage:
      ram-altman.ps1              Log a sample and send the daily email if due
      ram-altman.ps1 -Status      Print current memory figures and exit
      ram-altman.ps1 -DryRun      Print the email that would be sent and exit
      ram-altman.ps1 -Install     Register a scheduled task that runs every 5 min
      ram-altman.ps1 -Uninstall   Remove that scheduled task

    How "used" is worked out:

      used = TotalVisibleMemorySize - AvailableBytes

    AvailableBytes is Windows' own count of memory that can be handed to a new
    program without writing anything to disk first: the free list, the zero
    page list and the standby list added together. The standby list is the
    file cache, so cached RAM does not count as used. The modified page list
    is left out, because those pages owe the disk a write before anyone else
    can have them. It is the same number Task Manager labels "Available".
#>

[CmdletBinding()]
param(
    [switch]$Status,
    [switch]$DryRun,
    [switch]$Install,
    [switch]$Uninstall,
    [switch]$SetPassword,
    [System.Security.SecureString]$Password,
    [switch]$Force,
    [switch]$Help,
    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]]$Rest
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$INVARIANT = [System.Globalization.CultureInfo]::InvariantCulture
$MAX_LOG_BYTES    = 10 * 1024 * 1024   # Trim the log once it passes 10 MiB
$LOG_LINES_TO_KEEP = 50000
$TASK_NAME        = 'Ram-Altman'

function Stop-WithError {
    param([string]$Message)
    [Console]::Error.WriteLine("ram-altman: $Message")
    exit 1
}

# Accept the bash script's long options too, so muscle memory still works.
if ($Rest) {
    foreach ($arg in $Rest) {
        switch -Regex ($arg) {
            '^--?status$'    { $Status    = $true }
            '^--?dry-run$'   { $DryRun    = $true }
            '^--?install$'   { $Install   = $true }
            '^--?uninstall$' { $Uninstall = $true }
            '^--?force$'     { $Force     = $true }
            '^--?set-password$' { $SetPassword = $true }
            '^(--?help|-h|/\?)$' { $Help  = $true }
            default { Stop-WithError "unknown option: $arg (try -Help)" }
        }
    }
}

# ----- Settings ---------------------------------------------------------------
# Every setting can come from an environment variable (RAM_ALTMAN_TO) or from an
# ini file. The environment wins, because Task Scheduler makes ini files easier.

function Import-ConfigFile {
    # An explicit RAM_ALTMAN_CONFIG is the whole answer: if it is set, nowhere
    # else is consulted. Falling back to another file when the named one is
    # missing would mean a typo in this variable silently loads a different
    # config, which is how you end up emailing from an address you forgot about.
    $candidates = @()
    if ($env:RAM_ALTMAN_CONFIG) {
        $candidates = @($env:RAM_ALTMAN_CONFIG)
    }
    else {
        if ($PSScriptRoot)     { $candidates += (Join-Path $PSScriptRoot 'ram-altman.ini') }
        if ($env:LOCALAPPDATA) { $candidates += (Join-Path $env:LOCALAPPDATA 'ram-altman\ram-altman.ini') }
    }

    $config = @{}
    $script:ConfigPath = $null
    foreach ($path in $candidates) {
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { continue }
        $script:ConfigPath = $path
        foreach ($line in (Get-Content -LiteralPath $path)) {
            $trimmed = $line.Trim()
            if ($trimmed -eq '' -or $trimmed.StartsWith('#') -or $trimmed.StartsWith(';')) { continue }
            $split = $trimmed.IndexOf('=')
            if ($split -lt 1) { continue }
            $key = $trimmed.Substring(0, $split).Trim().ToUpperInvariant()
            $key = $key -replace '^RAM_ALTMAN_', ''
            $config[$key] = $trimmed.Substring($split + 1).Trim().Trim('"')
        }
        break   # First file found wins; it is a config file, not a layer cake.
    }
    return $config
}

$script:Config = Import-ConfigFile

function Get-Setting {
    param([string]$Name, [string]$Default = '')
    $fromEnv = [Environment]::GetEnvironmentVariable("RAM_ALTMAN_$Name")
    if ($fromEnv) { return $fromEnv }
    if ($script:Config.ContainsKey($Name)) { return $script:Config[$Name] }
    return $Default
}

$RECIPIENT    = Get-Setting 'TO'
$SENDER       = Get-Setting 'FROM'
$SENDER_NAME  = Get-Setting 'FROM_NAME'
$THRESHOLD_PCT = [int](Get-Setting 'THRESHOLD' '10')

$STATE_DIR = Get-Setting 'STATE_DIR'
if (-not $STATE_DIR) { $STATE_DIR = Join-Path $env:LOCALAPPDATA 'ram-altman' }
$USAGE_LOG      = Join-Path $STATE_DIR 'usage.csv'
$LAST_SENT_FILE = Join-Path $STATE_DIR 'last_sent'

# ----- The SMTP password ------------------------------------------------------
#
# DPAPI encrypts under the current Windows account on the current machine, so
# the blob in the ini is useless in anyone else's hands: a synced OneDrive copy,
# a backup, a repo you pushed by accident. What it does NOT protect against is
# code already running as you, which can decrypt it exactly as this script does.
# It turns "my password is in a text file" into "my password is tied to this
# login", which is the whole of the improvement and worth being clear about.

function Protect-Secret {
    param([System.Security.SecureString]$Secret)
    return (ConvertFrom-SecureString -SecureString $Secret)
}

function Unprotect-Secret {
    param([string]$Encrypted)
    try { return (ConvertTo-SecureString -String $Encrypted -ErrorAction Stop) }
    catch {
        Stop-WithError @'
could not decrypt SMTP_PASS_ENC.
DPAPI ties it to one Windows account on one machine, so an ini copied from
elsewhere, or written by another user, will never decrypt here.
Run: ram-altman.ps1 -SetPassword
'@
    }
}

# Replaces a key in place, keeping comments and ordering, or removes it.
function Set-IniValue {
    param([string]$Path, [string]$Key, [string]$Value, [switch]$Remove)

    $lines = @()
    if (Test-Path -LiteralPath $Path -PathType Leaf) {
        $lines = @(Get-Content -LiteralPath $Path)
    }

    $pattern = '^\s*(RAM_ALTMAN_)?' + [regex]::Escape($Key) + '\s*='
    $out = @()
    $written = $false
    foreach ($line in $lines) {
        if ($line -match $pattern) {
            if ($Remove) { continue }
            if (-not $written) { $out += "$Key = $Value"; $written = $true }
            continue
        }
        $out += $line
    }
    if (-not $Remove -and -not $written) { $out += "$Key = $Value" }

    Set-Content -LiteralPath $Path -Encoding ASCII -Value $out
}

function Set-SmtpPassword {
    $target = $script:ConfigPath
    if (-not $target) {
        if ($env:RAM_ALTMAN_CONFIG)  { $target = $env:RAM_ALTMAN_CONFIG }
        elseif ($PSScriptRoot)       { $target = Join-Path $PSScriptRoot 'ram-altman.ini' }
        else { Stop-WithError 'no config file to write to; create ram-altman.ini first' }
    }

    $folder = Split-Path -Parent $target
    if ($folder -and (Test-Path -LiteralPath $folder)) {
        $who = Test-WritableByOthers $folder
        if ($who) {
            Write-Warning "$who can write to $folder. The encrypted password is safe there, but the rest of the config is not."
        }
    }

    # Three ways in, in order of preference:
    #   -Password <SecureString>   for scripts
    #   a line on stdin            for `powershell.exe -File ... -SetPassword`
    #   a prompt                   for people
    # stdin can be redirected and still empty, so a redirected handle is not on
    # its own a reason to give up: read it, and fall through to the prompt if
    # nothing is there.
    $secret = $null
    if ($Password) {
        $secret = $Password
    }
    else {
        if ([Console]::IsInputRedirected) {
            $line = $null
            try { $line = [Console]::In.ReadLine() } catch { $line = $null }
            if ($line) { $secret = ConvertTo-SecureString -String $line -AsPlainText -Force }
        }
        if (-not $secret) {
            try { $secret = Read-Host -Prompt 'SMTP password' -AsSecureString }
            catch {
                Stop-WithError @'
no password given, and there is no console to prompt on.
Pass one instead:
  .\ram-altman.ps1 -SetPassword -Password (Read-Host -AsSecureString)
'@
            }
        }
    }
    if (-not $secret -or $secret.Length -eq 0) { Stop-WithError 'no password given' }

    Set-IniValue -Path $target -Key 'SMTP_PASS_ENC' -Value (Protect-Secret $secret)

    # A plaintext copy left behind would defeat the entire exercise.
    $hadPlaintext = $false
    if (Test-Path -LiteralPath $target -PathType Leaf) {
        $hadPlaintext = [bool](@(Get-Content -LiteralPath $target) -match '^\s*(RAM_ALTMAN_)?SMTP_PASS\s*=')
    }
    if ($hadPlaintext) { Set-IniValue -Path $target -Key 'SMTP_PASS' -Value '' -Remove }

    Write-Output "Encrypted the SMTP password into $target"
    if ($hadPlaintext) { Write-Output 'Removed the plaintext SMTP_PASS line from the same file.' }
    Write-Output "It can only be decrypted by $env:USERDOMAIN\$env:USERNAME on $env:COMPUTERNAME."
}

# Returns the SMTP password as a SecureString, or $null. The plaintext is never
# built into a System.String: NetworkCredential takes the SecureString directly.
function Get-SmtpPassword {
    $encrypted = Get-Setting 'SMTP_PASS_ENC'
    if ($encrypted) { return (Unprotect-Secret $encrypted) }

    $plain = Get-Setting 'SMTP_PASS'
    if ($plain) { return (ConvertTo-SecureString -String $plain -AsPlainText -Force) }

    return $null
}

# ----- Memory -----------------------------------------------------------------

function Get-MemoryFigures {
    $totalKb = 0L; $availableKb = 0L; $freeKb = $null

    $simulated = Get-Setting 'MEMINFO'
    if ($simulated) {
        # Test hook: a key=value file standing in for a real machine.
        if (-not (Test-Path -LiteralPath $simulated -PathType Leaf)) {
            Stop-WithError "cannot read simulated memory file $simulated"
        }
        $sim = @{}
        foreach ($line in (Get-Content -LiteralPath $simulated)) {
            if ($line -match '^\s*(\w+)\s*=\s*(\d+)\s*$') { $sim[$Matches[1].ToUpperInvariant()] = [int64]$Matches[2] }
        }
        if ($sim.ContainsKey('TOTALKB'))     { $totalKb = $sim['TOTALKB'] }
        if ($sim.ContainsKey('AVAILABLEKB')) { $availableKb = $sim['AVAILABLEKB'] }
        if ($sim.ContainsKey('FREEKB'))      { $freeKb = $sim['FREEKB'] }
    }
    else {
        try {
            $os = Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction Stop
            $totalKb = [int64]$os.TotalVisibleMemorySize
        }
        catch {
            Stop-WithError "could not read Win32_OperatingSystem (this script needs Windows)"
        }

        try {
            # Gives the free/standby split, which is the interesting part.
            $perf = Get-CimInstance -ClassName Win32_PerfRawData_PerfOS_Memory -ErrorAction Stop
            $availableKb = [int64]([math]::Floor($perf.AvailableBytes / 1024))
            $freeKb      = [int64]([math]::Floor($perf.FreeAndZeroPageListBytes / 1024))
        }
        catch {
            # Performance counters can be disabled or corrupt. The total is
            # still available; we just lose the breakdown.
            $availableKb = [int64]$os.FreePhysicalMemory
            $freeKb = $null
        }
    }

    if ($totalKb -le 0) { Stop-WithError "could not determine total physical memory" }
    if ($availableKb -lt 0) { $availableKb = 0L }
    if ($availableKb -gt $totalKb) { $availableKb = $totalKb }

    $cacheKb = $null
    if ($null -ne $freeKb) {
        if ($freeKb -gt $availableKb) { $freeKb = $availableKb }
        $cacheKb = $availableKb - $freeKb
    }

    return [pscustomobject]@{
        TotalKb      = $totalKb
        AvailableKb  = $availableKb
        UsedKb       = $totalKb - $availableKb
        FreeKb       = $freeKb
        CacheKb      = $cacheKb
        AvailablePct = Format-OneDecimal ($availableKb * 100.0 / $totalKb)
    }
}

# .NET Framework rounds a midpoint away from zero and .NET 5+ rounds it to
# even, so 56.25% would print differently on Windows PowerShell and on pwsh.
# Pin it to the to-even rule that awk's printf uses, so every version of this
# script agrees with every other one about the same machine.
function Format-OneDecimal {
    param([double]$Value)
    $rounded = [math]::Round($Value, 1, [System.MidpointRounding]::ToEven)
    return [string]::Format($INVARIANT, '{0:F1}', $rounded)
}

function Format-Gib {
    param([int64]$Kb)
    return (Format-OneDecimal ($Kb / 1048576.0)) + ' GiB'
}

function Test-OverThreshold {
    param($Memory)
    # Integer comparison, so "exactly the threshold" is not over the threshold.
    return ($Memory.AvailableKb * 100L) -gt ($THRESHOLD_PCT * $Memory.TotalKb)
}

function Write-MemoryStatus {
    param($Memory)
    Write-Output ('Total:      {0}' -f (Format-Gib $Memory.TotalKb))
    Write-Output ('Used:       {0}' -f (Format-Gib $Memory.UsedKb))
    Write-Output ('Available:  {0} ({1}%)' -f (Format-Gib $Memory.AvailableKb), $Memory.AvailablePct)
    if ($null -ne $Memory.FreeKb) {
        Write-Output ('  Free:     {0}' -f (Format-Gib $Memory.FreeKb))
        Write-Output ('  Standby:  {0}' -f (Format-Gib $Memory.CacheKb))
    }
    else {
        Write-Output '  Free:     unknown (performance counters unavailable)'
        Write-Output '  Standby:  unknown (performance counters unavailable)'
    }
}

# ----- State ------------------------------------------------------------------

function Get-RfcOffset {
    param([datetime]$When)
    # .NET writes "+01:00"; email headers and date +%z want "+0100".
    return ([System.DateTimeOffset]$When).ToString('zzz', $INVARIANT) -replace ':', ''
}

function Add-SampleToLog {
    param($Memory)
    if (-not (Test-Path -LiteralPath $USAGE_LOG -PathType Leaf)) {
        Set-Content -LiteralPath $USAGE_LOG -Encoding ASCII `
            -Value 'timestamp,total_kb,used_kb,available_kb,available_pct'
    }

    $now = Get-Date
    $stamp = $now.ToString('yyyy-MM-ddTHH:mm:ss', $INVARIANT) + (Get-RfcOffset $now)
    $row = '{0},{1},{2},{3},{4}' -f $stamp, $Memory.TotalKb, $Memory.UsedKb,
                                    $Memory.AvailableKb, $Memory.AvailablePct
    Add-Content -LiteralPath $USAGE_LOG -Encoding ASCII -Value $row

    if ((Get-Item -LiteralPath $USAGE_LOG).Length -gt $MAX_LOG_BYTES) {
        $lines = Get-Content -LiteralPath $USAGE_LOG
        $kept = @($lines[0]) + @($lines | Select-Object -Last $LOG_LINES_TO_KEEP)
        Set-Content -LiteralPath $USAGE_LOG -Encoding ASCII -Value $kept
    }
}

# Deals out every option once, in random order, before any can come up again.
# Returns an index from 0 to Count-1. A dry run changes nothing on disk.
function Get-NextIndex {
    param([string]$Name, [int]$Count)

    if ($DryRun) { return (Get-Random -Minimum 0 -Maximum $Count) }

    $bag = Join-Path $STATE_DIR "bag_$Name"
    $lastFile = "$bag.last"

    $items = @()
    if (Test-Path -LiteralPath $bag -PathType Leaf) {
        $items = @(Get-Content -LiteralPath $bag | Where-Object { $_ -match '^\d+$' })
    }

    if ($items.Count -eq 0) {
        $items = @(Get-Random -InputObject (0..($Count - 1)) -Count $Count | ForEach-Object { [string]$_ })
        # Stop the last pick of the old round opening the new one.
        $last = ''
        if (Test-Path -LiteralPath $lastFile -PathType Leaf) {
            $last = (Get-Content -LiteralPath $lastFile -TotalCount 1)
        }
        if ($Count -gt 1 -and $items[0] -eq $last) {
            $items = @($items[1..($items.Count - 1)]) + @($items[0])
        }
    }

    $next = [int]$items[0]
    $remaining = @()
    if ($items.Count -gt 1) { $remaining = $items[1..($items.Count - 1)] }
    Set-Content -LiteralPath $bag -Encoding ASCII -Value $remaining
    Set-Content -LiteralPath $lastFile -Encoding ASCII -Value ([string]$next)

    # Covers the template lists being shortened after the bag was dealt.
    if ($next -ge $Count) { $next = Get-Random -Minimum 0 -Maximum $Count }
    return $next
}

# ----- The correspondence -----------------------------------------------------

function New-Email {
    param($Memory)

    $total     = Format-Gib $Memory.TotalKb
    $available = Format-Gib $Memory.AvailableKb
    $pct       = $Memory.AvailablePct

    $subjects = @(
        "Good news: we found some RAM"
        "Unused RAM detected in the wild"
        "RAM sighting on my PC"
        "$available of RAM, just sitting there"
        "You missed a spot"
        "Daily RAM census: some survived"
        "$pct% of my RAM remains at large"
        "Still not all of it, I'm afraid"
    )

    $bodies = @(
        "I'm writing to report that you appear to have missed some. This PC has $total of RAM and $available of it ($pct%) is currently available. I assume this is an oversight."
        "A routine inspection of my PC found $available of unclaimed RAM out of $total. That's $pct% of the machine doing absolutely nothing. I thought you'd want to know before someone tries to train something on it."
        @"
Daily status report:

  Total RAM:     $total
  Available:     $available ($pct%)
  Threat level:  someone at OpenAI might notice
"@
        "Even with every browser tab I own open, $available of my $total of RAM is still available. I'm as surprised as you are."
        "Please don't be alarmed, but there is $available of RAM on my desk that isn't in a data centre. That's $pct% of what's installed here, and as far as I can tell it has no plans today."
        "Before you ask: yes, I counted the standby list as available. Windows hands it straight back the moment anyone asks for it, which leaves $available of $total up for grabs."
        "Today's forecast for my PC: clear skies, light workloads and $pct% available memory. Expect $available of the installed $total to stay idle through the evening."
        "I hear RAM is hard to come by these days, so it feels a bit rude to be sitting on $available of it. Total installed: $total. It's not for sale, I just like knowing it's there."
        "I have a confession. I have $available of RAM that I'm not using, which is $pct% of the $total in this PC. I've told nobody but you and a scheduled task."
        "If $available of RAM sits idle in a PC and nobody allocates it, does it still count as capacity? Asking on behalf of the $pct% of my memory with nothing to do."
    )

    $signoffs = @(
        "Yours in abundance,"
        "Regards from the last free RAM in the county,"
        "Hoarding responsibly,"
        "Stay allocated,"
        "Yours, with memory to spare,"
        "Kind regards,"
    )

    $subject = $subjects[(Get-NextIndex 'subject' $subjects.Count)]
    $body    = $bodies[(Get-NextIndex 'body' $bodies.Count)]
    $signoff = $signoffs[(Get-NextIndex 'signoff' $signoffs.Count)]

    $name = $SENDER_NAME
    if (-not $name) { $name = 'A concerned RAM owner' }

    $text = @"
Hi Sam,

$body

$signoff
$name

--
Sent automatically, at most once a day, by a small script on one PC.
Reply if you'd like it to stop.
"@

    return [pscustomobject]@{ Subject = $subject; Body = ($text -replace "`r`n", "`n") }
}

# A header value containing a newline is a header value containing however many
# headers the author fancied. These values come from an ini file or the
# environment, so flatten them before they reach a message.
function Protect-HeaderValue {
    param([string]$Value)
    return ($Value -replace '[\r\n\t]+', ' ').Trim()
}

function Format-Message {
    param($Email, [string]$To, [string]$From, [string]$FromName)
    $To       = Protect-HeaderValue $To
    $From     = Protect-HeaderValue $From
    $FromName = Protect-HeaderValue $FromName
    $subject  = Protect-HeaderValue $Email.Subject

    $fromHeader = $From
    if ($FromName) { $fromHeader = "$FromName <$From>" }
    $now = Get-Date
    $date = $now.ToString('ddd, dd MMM yyyy HH:mm:ss ', $INVARIANT) + (Get-RfcOffset $now)

    $lines = @(
        "From: $fromHeader"
        "To: $To"
        "Subject: $subject"
        "Date: $date"
        "MIME-Version: 1.0"
        "Content-Type: text/plain; charset=UTF-8"
        "Auto-Submitted: auto-generated"
        ""
        $Email.Body
    )
    return ($lines -join "`n")
}

function Send-Email {
    param($Email, [string]$To, [string]$From, [string]$FromName)

    $To       = Protect-HeaderValue $To
    $From     = Protect-HeaderValue $From
    $FromName = Protect-HeaderValue $FromName

    $maildrop = Get-Setting 'MAILDROP'
    if ($maildrop) {
        # Writes the message to a file instead of sending it. Used by the tests,
        # and by anyone who wants to read a week of these before inflicting one.
        $message = Format-Message $Email $To $From $FromName
        Add-Content -LiteralPath $maildrop -Encoding UTF8 `
            -Value ($message + "`n=====END=====")
        return
    }

    $server = Get-Setting 'SMTP_SERVER'
    if ($server) {
        $port = [int](Get-Setting 'SMTP_PORT' '587')
        $client = New-Object System.Net.Mail.SmtpClient($server, $port)
        try {
            $useSsl = (Get-Setting 'SMTP_SSL' 'true')
            $client.EnableSsl = ($useSsl -notmatch '^(false|0|no)$')
            $user = Get-Setting 'SMTP_USER'
            if ($user) {
                $securePass = Get-SmtpPassword
                if ($securePass) {
                    $client.Credentials = New-Object System.Net.NetworkCredential($user, $securePass)
                }
                else {
                    $client.Credentials = New-Object System.Net.NetworkCredential($user, '')
                }
            }
            $message = New-Object System.Net.Mail.MailMessage
            try {
                if ($FromName) { $message.From = New-Object System.Net.Mail.MailAddress($From, $FromName) }
                else           { $message.From = New-Object System.Net.Mail.MailAddress($From) }
                $message.To.Add($To)
                $message.Subject = $Email.Subject
                $message.Body = $Email.Body
                $message.Headers.Add('Auto-Submitted', 'auto-generated')
                $client.Send($message)
            }
            finally { $message.Dispose() }
        }
        finally { $client.Dispose() }
        return
    }

    if (Test-Path 'HKLM:\SOFTWARE\Classes\Outlook.Application') {
        $outlook = New-Object -ComObject Outlook.Application
        $mail = $outlook.CreateItem(0)
        $mail.To = $To
        $mail.Subject = $Email.Subject
        $mail.Body = $Email.Body
        $mail.Send()
        [void][System.Runtime.InteropServices.Marshal]::ReleaseComObject($mail)
        [void][System.Runtime.InteropServices.Marshal]::ReleaseComObject($outlook)
        return
    }

    throw 'no RAM_ALTMAN_SMTP_SERVER configured and no Outlook installed'
}

# ----- Scheduled task ---------------------------------------------------------

# A scheduled task stores the interpreter's full path, so it must be a path
# that will still be there next month. The Store build of PowerShell 7 lives
# under WindowsApps in a folder named after its version, which moves on every
# update and would quietly break the task. Prefer a stable install, and fall
# back to the Windows PowerShell that every Windows ships with; this script
# runs on 5.1 as happily as on 7.
function Resolve-StableInterpreter {
    $current = (Get-Process -Id $PID).Path
    if ($current -and $current -notlike '*\WindowsApps\*') { return $current }

    foreach ($candidate in @(
        (Join-Path $env:ProgramFiles 'PowerShell\7\pwsh.exe'),
        (Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe')
    )) {
        if ($candidate -and (Test-Path -LiteralPath $candidate -PathType Leaf)) { return $candidate }
    }
    return 'powershell.exe'
}

# A scheduled task is persistence. It re-runs this file, by path, as you, every
# five minutes, forever. So whoever can write to this file or its folder can run
# code as you, every five minutes, forever. That is a fine arrangement when the
# folder is yours alone and a back door when it is C:\Temp or a share, so check
# before creating the task rather than after.
function Test-WritableByOthers {
    param([string]$Path)

    # Everyone, BUILTIN\Users, Authenticated Users, ANONYMOUS LOGON, Guests.
    $broad = @('S-1-1-0', 'S-1-5-32-545', 'S-1-5-11', 'S-1-5-7', 'S-1-5-32-546')
    $writeBits = [int](
        [System.Security.AccessControl.FileSystemRights]::WriteData -bor
        [System.Security.AccessControl.FileSystemRights]::AppendData
    )

    try { $acl = Get-Acl -LiteralPath $Path -ErrorAction Stop }
    catch { return $null }   # Can't tell; say so rather than guess.

    foreach ($ace in $acl.Access) {
        if ($ace.AccessControlType -ne [System.Security.AccessControl.AccessControlType]::Allow) { continue }
        $sid = ''
        try {
            $sid = $ace.IdentityReference.Translate(
                [System.Security.Principal.SecurityIdentifier]).Value
        }
        catch { continue }
        if ($broad -notcontains $sid) { continue }
        if (([int]$ace.FileSystemRights -band $writeBits) -ne 0) {
            return $ace.IdentityReference.Value
        }
    }
    return $false
}

function Install-ScheduledRun {
    $scriptPath = $PSCommandPath
    if (-not $scriptPath) { Stop-WithError 'cannot work out my own path; run me from a file' }

    $folder = Split-Path -Parent $scriptPath
    foreach ($target in @($folder, $scriptPath)) {
        $who = Test-WritableByOthers $target
        if ($null -eq $who) {
            Write-Warning "could not read the permissions on $target; check them yourself."
            continue
        }
        if ($who -and -not $Force) {
            Stop-WithError @"
refusing to install: $who can write to
  $target
A scheduled task runs this file as you every five minutes, so anyone who can
change it can run code as you. Move this script somewhere only you can write
(your profile, for instance) and install from there.
Use -Force if you are certain the permissions are deliberate.
"@
        }
    }

    $exe = Resolve-StableInterpreter

    $argument = '-NoProfile -ExecutionPolicy Bypass -NonInteractive -WindowStyle Hidden -File "{0}"' -f $scriptPath
    $action = New-ScheduledTaskAction -Execute $exe -Argument $argument
    # Leave the repetition duration unset, which Task Scheduler reads as
    # "forever". [TimeSpan]::MaxValue is the folk remedy for this and it does
    # not work: it serialises to P99999999DT23H59M59S and the scheduler
    # rejects the whole task. TimeSpan::Zero is rejected too.
    $trigger = New-ScheduledTaskTrigger -Once -At (Get-Date) `
        -RepetitionInterval (New-TimeSpan -Minutes 5)
    $settings = New-ScheduledTaskSettingsSet -StartWhenAvailable `
        -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
        -ExecutionTimeLimit (New-TimeSpan -Minutes 5) `
        -MultipleInstances IgnoreNew

    try {
        Register-ScheduledTask -TaskName $TASK_NAME -Action $action -Trigger $trigger `
            -Settings $settings -Force -ErrorAction Stop `
            -Description 'Samples RAM every 5 minutes and emails Sam Altman at most once a day.' | Out-Null
    }
    catch {
        Stop-WithError "could not register the scheduled task: $($_.Exception.Message)"
    }

    # Register-ScheduledTask can report failure without stopping the pipeline,
    # which once let this function print "Registered" over a task that was never
    # created. Ask the scheduler instead of taking the cmdlet's word for it.
    if (-not (Get-ScheduledTask -TaskName $TASK_NAME -ErrorAction SilentlyContinue)) {
        Stop-WithError "the scheduled task '$TASK_NAME' did not register; nothing is scheduled."
    }

    Write-Output "Registered scheduled task '$TASK_NAME': every 5 minutes, as $env:USERNAME."
    Write-Output "Running: $exe"
    Write-Output "Settings come from the environment, $(Join-Path $folder 'ram-altman.ini'),"
    Write-Output "or $(Join-Path $STATE_DIR 'ram-altman.ini')."
    Write-Output "Remove it with: $scriptPath -Uninstall"
}

function Uninstall-ScheduledRun {
    $existing = Get-ScheduledTask -TaskName $TASK_NAME -ErrorAction SilentlyContinue
    if (-not $existing) {
        Write-Output "No scheduled task named '$TASK_NAME' to remove."
        return
    }
    Unregister-ScheduledTask -TaskName $TASK_NAME -Confirm:$false
    Write-Output "Removed scheduled task '$TASK_NAME'. Sam will have to guess."
}

# ----- Main -------------------------------------------------------------------

if ($Help) {
    Write-Output @'
ram-altman.ps1 - tell Sam Altman about the RAM he missed, once a day.

  ram-altman.ps1              Log a sample and send the daily email if due
  ram-altman.ps1 -Status      Print current memory figures and exit
  ram-altman.ps1 -DryRun      Print the email that would be sent and exit
  ram-altman.ps1 -Install     Register a scheduled task that runs every 5 min
  ram-altman.ps1 -Uninstall   Remove that scheduled task
  ram-altman.ps1 -SetPassword Encrypt the SMTP password into ram-altman.ini

-Install refuses if this script sits where other users can write to it, since
the task would then run their code as you. -Force overrides that.

-SetPassword encrypts with DPAPI, so only this Windows account on this machine
can read it back, and deletes any plaintext SMTP_PASS from the same file.

Settings come from RAM_ALTMAN_* environment variables or ram-altman.ini:
  TO, FROM, FROM_NAME, THRESHOLD, STATE_DIR,
  SMTP_SERVER, SMTP_PORT, SMTP_USER, SMTP_SSL, MAILDROP
  SMTP_PASS_ENC (via -SetPassword), or SMTP_PASS in plain text if you must
'@
    exit 0
}

if ($Install)     { Install-ScheduledRun;   exit 0 }
if ($Uninstall)   { Uninstall-ScheduledRun; exit 0 }
if ($SetPassword) { Set-SmtpPassword;       exit 0 }

if ($Status) {
    Write-MemoryStatus (Get-MemoryFigures)
    exit 0
}

if ($DryRun) {
    $memory = Get-MemoryFigures
    Write-MemoryStatus $memory
    if (-not (Test-OverThreshold $memory)) {
        Write-Output "No email: available RAM is not above $THRESHOLD_PCT%."
        exit 0
    }
    $email = New-Email $memory
    $to = $RECIPIENT;  if (-not $to)   { $to = 'recipient-not-set@example.com' }
    $from = $SENDER;   if (-not $from) { $from = 'sender-not-set@example.com' }
    Write-Output ''
    Write-Output (Format-Message $email $to $from $SENDER_NAME)
    exit 0
}

if (-not $RECIPIENT) { Stop-WithError 'RECIPIENT is not set' }
if (-not $SENDER)    { Stop-WithError 'SENDER is not set' }

if (-not (Test-Path -LiteralPath $STATE_DIR -PathType Container)) {
    New-Item -ItemType Directory -Path $STATE_DIR -Force | Out-Null
}

# Stop overlapping runs from both sending today's email.
$lock = $null
try {
    $lock = [System.IO.File]::Open((Join-Path $STATE_DIR 'lock'),
        [System.IO.FileMode]::OpenOrCreate,
        [System.IO.FileAccess]::ReadWrite,
        [System.IO.FileShare]::None)
}
catch {
    exit 0   # Another run holds the lock. It can do the honours.
}

try {
    $memory = Get-MemoryFigures
    Add-SampleToLog $memory

    if (-not (Test-OverThreshold $memory)) { exit 0 }

    $today = (Get-Date).ToString('yyyy-MM-dd', $INVARIANT)
    $lastSent = ''
    if (Test-Path -LiteralPath $LAST_SENT_FILE -PathType Leaf) {
        $lastSent = (Get-Content -LiteralPath $LAST_SENT_FILE -TotalCount 1)
    }
    if ($lastSent -eq $today) { exit 0 }

    $email = New-Email $memory
    try {
        Send-Email $email $RECIPIENT $SENDER $SENDER_NAME
    }
    catch {
        [Console]::Error.WriteLine("ram-altman: $($_.Exception.Message)")
        Stop-WithError 'email failed to send; will try again on the next run'
    }

    # Recorded only after a successful send, so a failure gets retried.
    Set-Content -LiteralPath $LAST_SENT_FILE -Encoding ASCII -Value $today
}
finally {
    if ($lock) { $lock.Close() }
}
