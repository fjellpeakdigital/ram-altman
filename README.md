# Ram-Altman for Windows

**A PowerShell script that writes to Sam Altman once a day to report the RAM he missed.**

![Global DRAM allocation: quite terrible](https://img.shields.io/badge/global%20DRAM%20allocation-quite%20terrible-red)
![Utilization: maybe 5%](https://img.shields.io/badge/utilization-maybe%205%25-orange)
![Emails: 1 per day](https://img.shields.io/badge/emails-1%20per%20day-blue)
![Written in PowerShell, not Electron](https://img.shields.io/badge/written%20in-powershell%2C%20not%20electron-brightgreen)

This is a Windows port of [IainKay/ram-altman](https://github.com/IainKay/ram-altman), which is written in bash and reads `/proc/meminfo`. The original's FAQ notes that it doesn't work on macOS. It doesn't work here either. Now it does.

Everything that made the original worth running is intact: the once-a-day limit, the shuffled templates, the CSV log, the refusal to send when the machine is genuinely busy. Only the parts that were Linux have changed.

## What's different from the bash original

| | bash original | this |
| --- | --- | --- |
| Memory source | `/proc/meminfo` | `Win32_PerfRawData_PerfOS_Memory`, `Win32_OperatingSystem` |
| "Available" | `MemAvailable` | `AvailableBytes` (free + zero + standby lists) |
| Reclaimable cache | buffers + cached + slab − shmem | the standby list |
| Sending mail | `sendmail`, `msmtp`, `mail` | SMTP, Outlook, or a maildrop file |
| Scheduling | `cron` every 5 minutes | Task Scheduler, via `-Install` |
| Overlap lock | `flock` | an exclusively-opened lock file |
| State | `~/.local/state/ram-altman` | `%LOCALAPPDATA%\ram-altman` |
| Settings | environment variables in the crontab | environment variables or `ram-altman.ini` |

Runs on Windows PowerShell 5.1 (the one already on your machine) and on PowerShell 7. Needs no admin rights.

## Installation

```powershell
git clone https://github.com/fjellpeakdigital/ram-altman.git
cd ram-altman
Get-ChildItem *.ps1 | Unblock-File   # Windows marks downloaded scripts
```

Then have a look at the evidence against you:

```powershell
.\ram-altman.ps1 -Status
```

```text
Total:      47.7 GiB
Used:       27.6 GiB
Available:  20.1 GiB (42.2%)
  Free:     0.1 GiB
  Standby:  20.0 GiB
```

And preview an email without sending anything:

```powershell
.\ram-altman.ps1 -DryRun
```

If PowerShell refuses to run the script at all, your execution policy is doing its job. Either `Unblock-File` as above, or run it as `powershell.exe -ExecutionPolicy Bypass -File .\ram-altman.ps1 -DryRun`.

## What counts as "used"?

```text
used = TotalVisibleMemorySize - AvailableBytes
```

`AvailableBytes` is Windows' own count of memory it could hand to a new program without writing anything to disk first. It is the free list, the zero page list and the standby list added together, and it is the number Task Manager prints next to **Available**.

The standby list is the file cache. It counts as available because Windows gives it back the instant anyone asks. The modified page list does *not* count, because those pages owe the disk a write before anyone else can have them. This is the same distinction the bash original draws when it subtracts `Shmem` and keeps `SReclaimable`.

This is why your **Free** figure is about 100 MB and always has been. Windows didn't eat your RAM. It filed it.

Strictly speaking the standby list is doing useful work, so counting it as available is a generous concession to the other side. Think of it as a plea bargain.

If the performance counters are disabled or corrupt, the script falls back to `Win32_OperatingSystem` for the total and available figures and prints the free/standby split as `unknown`, rather than inventing one.

## A sample of today's correspondence

```text
Subject: You missed a spot

Hi Sam,

Please don't be alarmed, but there is 8.6 GiB of RAM on my desk that isn't in
a data centre. That's 56.2% of what's installed here, and as far as I can tell
it has no plans today.

Hoarding responsibly,
A concerned RAM owner

--
Sent automatically, at most once a day, by a small script on one PC.
Reply if you'd like it to stop.
```

The figures are real. They come from your machine. That's the worrying part.

## Settings

Every setting can come from an environment variable or from `ram-altman.ini`. The environment wins, because Task Scheduler makes environment variables awkward and ini files easy.

Copy [`ram-altman.example.ini`](ram-altman.example.ini) to `ram-altman.ini` next to the script, or to `%LOCALAPPDATA%\ram-altman\ram-altman.ini`.

| Setting | What it does | Default |
| --- | --- | --- |
| `RAM_ALTMAN_TO` | Who receives the bad news | Required |
| `RAM_ALTMAN_FROM` | A real address you can send from | Required |
| `RAM_ALTMAN_FROM_NAME` | Your name, or your nom de RAM | Optional |
| `RAM_ALTMAN_THRESHOLD` | Email when available RAM is above this percentage (whole number) | `10` |
| `RAM_ALTMAN_STATE_DIR` | Where the log and state files live | `%LOCALAPPDATA%\ram-altman` |
| `RAM_ALTMAN_CONFIG` | An ini file somewhere else entirely | Optional |
| `RAM_ALTMAN_SMTP_SERVER` | SMTP host. Set this and SMTP is used | Optional |
| `RAM_ALTMAN_SMTP_PORT` | SMTP port | `587` |
| `RAM_ALTMAN_SMTP_USER` | SMTP username, if the server wants one | Optional |
| `RAM_ALTMAN_SMTP_PASS_ENC` | The password, DPAPI-encrypted. Written by `-SetPassword` | Optional |
| `RAM_ALTMAN_SMTP_PASS` | The password in plain text. Use the line above instead | Optional |
| `RAM_ALTMAN_SMTP_SSL` | `false` to turn STARTTLS off, which you shouldn't | `true` |
| `RAM_ALTMAN_MAILDROP` | Write messages to this file instead of sending them | Optional |

### How it sends mail

In order of preference:

1. **A maildrop file**, if `RAM_ALTMAN_MAILDROP` is set. Nothing leaves the machine. This is how the tests run, and it's a pleasant way to read a week of these before inflicting one on anybody.
2. **SMTP**, if `RAM_ALTMAN_SMTP_SERVER` is set.
3. **Outlook**, if it's installed. The message goes out through your normal account, from your normal address, which is either very convenient or a good reason to use the maildrop first.

### Storing the password

Putting an SMTP password in a plain ini file is exactly as bad an idea as it sounds. Don't:

```powershell
.\ram-altman.ps1 -SetPassword
```

It prompts without echoing, encrypts the password with DPAPI, writes it back as `SMTP_PASS_ENC`, and deletes any plaintext `SMTP_PASS` line from the same file. Comments and your other settings are left alone.

```text
Encrypted the SMTP password into C:\Users\you\ram-altman\ram-altman.ini
Removed the plaintext SMTP_PASS line from the same file.
It can only be decrypted by CONTOSO\you on THIS-PC.
```

That last line is the point. DPAPI encrypts under your Windows account on that machine, so the blob is inert anywhere else: in a OneDrive copy, in a backup, in a repo you pushed by accident. The scheduled task runs as you, so it decrypts fine.

For scripted setup, where there is no console to prompt on:

```powershell
.\ram-altman.ps1 -SetPassword -Password (Read-Host -AsSecureString)
```

Either way the password reaches `System.Net.Mail` as a `SecureString` and is never assembled into an ordinary string.

**What DPAPI does not do** is protect you from code already running as your account — that code can decrypt it exactly as this script does. It turns "my password is in a text file" into "my password is tied to this login". That is a real improvement and it is the whole of the improvement.

Still use an app password that can do nothing but send mail, and consider the maildrop or Outlook instead.

## Running it for real

```powershell
.\ram-altman.ps1 -Install
```

That registers a Task Scheduler job called `Ram-Altman` that runs every five minutes as you, with no window. It samples every run and emails at most once a day. If a send fails it tries again next time, because this message matters.

```powershell
Get-ScheduledTask -TaskName Ram-Altman     # confirm it's there
.\ram-altman.ps1 -Uninstall                # Sam will have to guess
```

`-Install` records the full path of the PowerShell it should use. It deliberately avoids the Microsoft Store build of PowerShell 7, whose path contains a version number and moves every time it updates, taking your scheduled task with it.

It also refuses to install if this script sits somewhere other users can write to. See [Security](#security) for why. `-Force` overrides that if you know better.

## Security

This script reads memory counters, appends to a CSV and sends one small email a day. It downloads nothing, listens on nothing, and runs no external program except the PowerShell you installed the task with. The ini parser splits strings on `=`; nothing from a config file, an environment variable or a simulated-memory file is ever evaluated as code. But `-Install` creates persistence, and persistence deserves a straight answer.

**The one that matters: where you put the file.**

A scheduled task stores the script's full path and re-runs it as you, every five minutes, forever. Anyone who can modify that file — or drop a file into its folder — therefore gets code execution as you, every five minutes, forever, with `-ExecutionPolicy Bypass` already supplied. Put this in `C:\ProgramData`, `C:\Windows\Temp`, a shared drive or any other folder where `BUILTIN\Users` can write, and you have installed a back door with a joke attached.

`-Install` now checks the ACL on both the script and its folder and refuses if `Everyone`, `Users`, `Authenticated Users`, `Guests` or `ANONYMOUS LOGON` can write to either. Keep it in your own profile. The task itself runs at `Limited` run level as you, never as SYSTEM and never elevated, and the script path is quoted in the task argument, so there is no unquoted-path hijack.

**Your SMTP password, if you use one.** Run [`-SetPassword`](#storing-the-password) and it is DPAPI-encrypted under your Windows account, so a synced, backed-up or accidentally-pushed copy of the ini is inert in anyone else's hands, and the plaintext never becomes an ordinary string in memory. `SMTP_PASS` in plain text still works for anyone who wants it, and still has every problem it sounds like it has. Note that DPAPI stops file theft, not code running as you: anything with your login can decrypt it as readily as this script does. Use an app password that can do nothing but send mail.

**The Outlook path sends as you, silently.** No prompt, no draft, your real address. That is the convenience and it is also the catch: a script automating Outlook to send mail on a timer is a textbook worm signature, so expect your antivirus or EDR to take an interest, and expect Outlook's programmatic-access guard to block it on a managed machine. On a work device, ask first.

**Whoever controls the config controls the recipient.** `TO`, `FROM` and `MAILDROP` all come from the ini or the environment. A hostile config cannot run code, but it can redirect the mail and it can append text to any file your account can write. That only matters if someone else can write your config — which, in your own profile, means they are already you.

Fixed along the way, and worth knowing if you are reading the diff: config values are stripped of CR/LF before they reach a mail header, so a crafted `FROM_NAME` cannot inject extra headers; an explicitly-set `RAM_ALTMAN_CONFIG` is now authoritative rather than falling through to another file when the named one is missing; and a failed task registration is now detected and reported instead of printing "Registered" over a task that does not exist.

**`Unblock-File` is a real safety control.** The install instructions above tell you to remove the mark-of-the-web from scripts you downloaded. That is the correct step for scripts you have read and trust, and the wrong one for everything else. Read this one first; it is 500 lines and most of them are jokes.

## Audit yourself

Let it run for a while, then find out how your machine compares:

```powershell
$rows = Import-Csv "$env:LOCALAPPDATA\ram-altman\usage.csv"
$used = ($rows | Measure-Object used_kb -Sum).Sum
$total = ($rows | Measure-Object total_kb -Sum).Sum
"Your RAM in use: {0:F1}% (the claim: maybe 5%)" -f ($used * 100 / $total)
```

Yes, share of memory in use isn't the same thing as share of time spent in use. If you came here to say that, welcome to Hacker News. We're glad you're here.

## Please be a good neighbour

One email a day from one person is a joke. Ten thousand of them is a denial-of-service attack with better material.

- **`-DryRun` is the best way to enjoy this.** It costs nothing and all the jokes are there.
- **`RAM_ALTMAN_MAILDROP` is the second best way.** It writes the real thing to a file.
- **This repo doesn't ship with anyone's email address,** and please don't add one.
- **Use your own real address.** No spoofing, and emphatically no Group Policy deployment across the fleet.
- **If anyone asks you to stop, stop.** The footer of every email promises this, so keep the promise.

## Tests

```powershell
.\test-ram-altman.ps1
```

28 tests, using simulated memory and a maildrop. No inboxes are harmed. They cover the threshold boundary, the once-a-day rule, retry after a failed send, the shuffled templates, the ini/environment precedence, the password round-trip through DPAPI, and a check that Windows' own counters still add up the way this script claims they do.

The suite passes on Windows PowerShell 5.1 and PowerShell 7, which took one bug fix: .NET Framework rounds a midpoint away from zero and .NET 5+ rounds it to even, so 56.25% printed as `56.3` on one and `56.2` on the other. It is pinned to the to-even rule that the original's `awk` uses, so every version of this agrees with every other one about the same machine.

`-Install` and `-Uninstall` are the one part the suite does not cover, because a test that registers scheduled tasks is a test that eventually forgets to remove one. They have been exercised by hand instead: registered, triggered, confirmed to produce an email and a log row through Task Scheduler, and removed.

## FAQ

**Does this help with the DRAM shortage?**
No.

**Is this a serious tool?**
The memory accounting is. The correspondence isn't.

**Does it work on Linux?**
No. [There's a bash one for that](https://github.com/IainKay/ram-altman), by the person who thought of this first.

**Why is my Free memory basically zero?**
Because Windows is using it as cache, which is the correct thing to do with it. See above. Free RAM is wasted RAM, a sentence sysadmins have been saying for thirty years and which has only recently acquired a powerful ally.

**Does it need administrator rights?**
No. The scheduled task runs as you, which is also the only account whose RAM is any of your business.

**Does running this use RAM?**
Briefly. It's then returned to the global pool, which is more than can be said for the rest of us.

**Will this work on Windows Server?**
Yes, and please don't. A server is the one machine in this story that's already doing its bit.

**What should I do with all this RAM?**
Open another browser tab. You've still got time.

## Credit

The idea, the jokes, the once-a-day restraint and most of the template text are from [IainKay/ram-altman](https://github.com/IainKay/ram-altman). Read the sample emails at [ram-altman.lol](https://ram-altman.lol), no install needed. This port changes the operating system and keeps the point.

## License

Public domain (Unlicense), same as the original. Free as in unallocated.
