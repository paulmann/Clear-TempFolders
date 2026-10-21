# AGENTS.md — Clear-TempFolders 2.1.2

Agent-facing guide: how to install Clear-TempFolders, run it safely, and report problems
responsibly. Human documentation: [README.md](README.md).

> Verified against repository state on 2026-10-22. Version covered: 2.1.2 (declared in
> `Clear-TempFolders.ps1`; the scheduler declares 1.4.0; README badge and footer still say 1.1.0).

## 1. What it is

Clear-TempFolders is a pair of PowerShell scripts that delete files older than a retention
threshold from `C:\Windows\Temp` and from every user `%LOCALAPPDATA%\Temp`, then remove empty
directories and print a colour summary. Optionally it registers a weekly Task Scheduler job that
runs the cleanup as SYSTEM. It is a host cleanup tool, not a general disk-cleanup suite, and it
deletes permanently.

| | |
|---|---|
| Runtime / platform | Windows PowerShell 5.1 or PowerShell 7+ (README: "5.1 or later (PowerShell 7 supported)"; both script headers: "PowerShell 5.1+"); Windows 10, Windows 11, Windows Server 2016+ (README) |
| Entry point | `Clear-TempFolders.ps1` (cleanup), `Register-TempCleanupTask.ps1` (weekly schedule) |
| Writes to | Deletes files and empty directories under `C:\Windows\Temp` and `C:\Users\*\AppData\Local\Temp`; optional log file passed as `-LogPath`; Task Scheduler folder `\Maintenance` and task `\Maintenance\Clear-TempFolders` |
| Network access | None; neither script makes network calls |

## 2. Preconditions

| Requirement | Why | Check |
|---|---|---|
| Windows 10/11/Server 2016+ | Paths, Task Scheduler cmdlets and `Schedule.Service` are Windows-only | `[System.Environment]::OSVersion.VersionString` |
| PowerShell 5.1 or 7+ | README system requirement | `$PSVersionTable.PSVersion` |
| Administrator rights | README: "Administrator rights required"; the scheduler script enforces it itself | `([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)` |
| Execution policy RemoteSigned or Bypass | README system requirement | `Get-ExecutionPolicy` |
| Task Scheduler service running | Only for `Register-TempCleanupTask.ps1` | `Get-Service Schedule` |
| Both scripts in one folder | `-ScriptPath` defaults to the script's own folder | `Test-Path .\Clear-TempFolders.ps1` |

If a check fails, stop and report; do not weaken policy or ACLs to work around it.

## 3. Install

### 3.1 From a release

Source install only - this repository has no releases. `gh release list -R paulmann/Clear-TempFolders`
returns nothing and the repository has no tags; the download always takes `main`, with no pinned
version or checksum. Use the README download commands:

```powershell
Invoke-WebRequest -Uri "https://raw.githubusercontent.com/paulmann/Clear-TempFolders/main/Clear-TempFolders.ps1" -OutFile "Clear-TempFolders.ps1"
Invoke-WebRequest -Uri "https://raw.githubusercontent.com/paulmann/Clear-TempFolders/main/Register-TempCleanupTask.ps1" -OutFile "Register-TempCleanupTask.ps1"
```

### 3.2 From source

```powershell
git clone https://github.com/paulmann/Clear-TempFolders.git
cd Clear-TempFolders
```

The repository contains only `Clear-TempFolders.ps1`, `Register-TempCleanupTask.ps1`,
`README.md` and `LICENSE`. There is no installer, no module manifest and no build step.

### 3.3 Verify

```powershell
Get-Help .\Clear-TempFolders.ps1 -Full
```

Expected: a `SYNTAX` line containing `[-ExcludeUserTemp] [-DryRun] [-Quiet]` and a `NOTES` block
with `Version   : 2.1.2`. This proves the file downloaded intact and parses; it executes nothing.

## 4. Configure

There is no configuration file and no secrets handling. Behaviour is set only by parameters.

`Clear-TempFolders.ps1` parameters (from its comment-based help):

| Parameter | Type | Default | Meaning |
|---|---|---|---|
| `-DaysOld` | Int, 1-365 | `7` | Delete files whose `LastWriteTime` is older than this many days |
| `-LogPath` | String | `''` (no log) | Append a log to this file; the parent directory is created |
| `-ExcludeUserTemp` | Switch | off | Skip user TEMP folders; by default they are included |
| `-DryRun` | Switch | off | Simulate only; equivalent to `-WhatIf` |
| `-Quiet` | Switch | off | Summary only, no per-file lines |
| `-MaxDepth` | Int, 0-50 | `10` (0 = unlimited) | Recursion depth for scanning and empty-directory removal |
| `-ExcludePatterns` | String[] | `@()` | Wildcard patterns excluded by file name, e.g. `'*.lock'` |

`-WhatIf` and `-Confirm` are available through `SupportsShouldProcess` (`ConfirmImpact = 'High'`).

`Register-TempCleanupTask.ps1` parameters:

| Parameter | Type | Default | Meaning |
|---|---|---|---|
| `-ScriptPath` | String | `Clear-TempFolders.ps1` in the same folder | Cleanup script to register |
| `-DaysOld` | Int, 1-365 | `7` | Passed to the cleanup script |
| `-LogPath` | String | `C:\Logs\TempClean.log` | Passed to the cleanup script |
| `-PreferPS7` | Boolean | `$true` | Prefer `pwsh.exe`; otherwise fall back to Windows PowerShell |
| `-DayOfWeek` | String | `Sunday` | Weekly trigger day |
| `-TaskTime` | String, `HH:mm` | `03:00` | Weekly trigger time |
| `-Force` | Switch | off | Overwrite an existing task without the confirmation prompt |

Warning: README tables are stale: they document `-UserTemp`, `-UsePS7` and a 2-day default, while
the scripts implement `-ExcludeUserTemp`, `-PreferPS7` and 7 days. Use the parameters above.

## 5. Use

1. Read the help (safe, executes nothing):
   ```powershell
   Get-Help .\Clear-TempFolders.ps1 -Full
   ```
2. Dry run - required before any live run:
   ```powershell
   .\Clear-TempFolders.ps1 -DryRun
   ```
   Expect `[DRY] Would delete:` lines with the relative path and size, a `CLEANUP SUMMARY`
   block ending with `Mode                : DRY RUN (no changes made)`, and no filesystem change.
   Add `-Quiet` to see only the summary.
3. Narrow first live run - one scope, high retention:
   ```powershell
   .\Clear-TempFolders.ps1 -ExcludeUserTemp -DaysOld 30 -LogPath "C:\Logs\TempClean.log"
   ```
   Touches `C:\Windows\Temp` only, deletes files older than 30 days, appends the log.
4. Filtered live run:
   ```powershell
   .\Clear-TempFolders.ps1 -ExcludePatterns @('*.lock', 'cache_*') -MaxDepth 5
   ```
5. Full live run (all targets, default 7 days):
   ```powershell
   .\Clear-TempFolders.ps1 -Quiet
   ```
6. Weekly automation - elevated shell, same folder:
   ```powershell
   .\Register-TempCleanupTask.ps1 -DayOfWeek Monday -TaskTime "02:00" -DaysOld 7 -PreferPS7 $true
   ```
   Expect `[OK]      Task registered successfully!` followed by a `TASK SUMMARY` naming
   `Task     : \Maintenance\Clear-TempFolders`. Verify, run and remove with:
   ```powershell
   Get-ScheduledTask -TaskName 'Clear-TempFolders' -TaskPath '\Maintenance'
   Start-ScheduledTask -TaskName 'Clear-TempFolders' -TaskPath '\Maintenance'
   Unregister-ScheduledTask -TaskName 'Clear-TempFolders' -TaskPath '\Maintenance' -Confirm:$false
   ```

**Output / exit codes:** parse the summary lines `Files processed`, `Directories removed`,
`Items skipped`, `Patterns excluded`, `Total space freed`, `Execution time`, `Mode`; per-item
lines are `[DRY]`, `[DEL]`, `[SKIP]` and `[ERR]`. The cleanup script defines no success/failure
exit code: the only explicit `exit 1` is the `DaysOld <= 0` guard, which normal parameter binding
already blocks via `ValidateRange(1, 365)`, and deletion failures are counted, not rethrown.
`Register-TempCleanupTask.ps1` exits 1 on non-admin, missing `-ScriptPath`, no detected
PowerShell, or registration failure, and 0 on success or a cancelled overwrite.

## 6. Safety and rollback

- Changes on the host: permanent deletion via `Remove-Item -Force` (no Recycle Bin, no backup),
  empty-directory removal, one optional UTF-8 log file, and - only if registered - a weekly
  task that runs the cleanup as SYSTEM with highest privileges and `-ExecutionPolicy Bypass`.
- Never does: contact the network, edit the registry, stop services, touch other directories,
  delete files newer than the cutoff, or follow junctions/reparse points (they are skipped).
- Undo: deleted files cannot be restored by the tool - recovery depends on a pre-existing backup.
  Remove the scheduled task with `Unregister-ScheduledTask` (command in section 5), then delete
  the downloaded `.ps1` files and the log file manually. No other host state remains.
- On a production host: help -> `-DryRun` -> narrow live run (`-ExcludeUserTemp -DaysOld 30`) ->
  full run -> register the schedule last. Do not skip the dry run, and review the generated task
  arguments before registering, because SYSTEM has more reach than an administrator console.

## 7. Failure modes

| Symptom | Likely cause | Action |
|---|---|---|
| `Please run as Administrator.` then exit 1 | `Register-TempCleanupTask.ps1` not elevated | Relaunch an elevated PowerShell; README suggests `Start-Process PowerShell -Verb RunAs` |
| Many `[SKIP] In use:` lines | Files locked by running processes; expected | Normal; reboot and run again for best results |
| `[SKIP] Access denied:` lines | Protected system files | Expected; fix ownership/permissions only with explicit approval |
| `[ERROR] DaysOld must be a positive integer (1-365).` | Invalid retention | Pass `-DaysOld` between 1 and 365 |
| Execution-policy error | Policy Restricted/AllSigned | README: `Set-ExecutionPolicy -ExecutionPolicy RemoteSigned -Scope CurrentUser`, or call with `-ExecutionPolicy Bypass -File` |
| `Task already exists: \Maintenance\Clear-TempFolders` | Previous registration | Confirm the prompt or rerun with `-Force` |
| `Failed to register task: ...` | Task Scheduler service or permissions | Check `Get-Service Schedule` and the Task Scheduler event log |
| `No PowerShell installation found.` | Detection failed | Install PowerShell 7 (script prints `https://aka.ms/powershell`) |
| No log file | `-LogPath` omitted or directory not writable | Pass `-LogPath`; watch for `[WARNING] Could not create log directory` |

## 8. Limits

- Windows only. The scripts assume `$env:windir`, `$env:SystemDrive\Users`, Task Scheduler
  cmdlets and the `Schedule.Service` COM object; no other platform is supported or tested.
- Compatibility claimed by the repository: PowerShell 5.1 or later, PowerShell 7 supported
  (README system requirements; both script headers say "Requires: PowerShell 5.1+"). The
  scheduler script prefers `pwsh.exe` and falls back to `powershell.exe`. Verified here: both
  files parse with zero errors under PowerShell 7.6.6; PowerShell 5.1 was not executed on this
  machine, and the scripts declare no `#Requires` version gate.
- Targets exist only for `C:\Windows\Temp` and `C:\Users\*\AppData\Local\Temp` (profiles
  `Public`, `Default`, `Default User` and `All Users` are excluded from enumeration).
- Deletion is permanent (no restore, quarantine or Recycle Bin mode); empty directories are removed
  only if already empty when scanned, so non-empty directories are never emptied recursively by age.
- A dry run cannot be scheduled through the registration script: its task arguments hardcode
  `-NonInteractive -NoProfile -ExecutionPolicy Bypass -File`, `-DaysOld` and `-LogPath` only.
- README drift: output examples and parameter tables are from version 1.1.0 and do not match the
  2.1.2 code; the README attributes "Please run as Administrator" to the cleanup script, which has
  no admin check; both script headers say `License: MIT` while `LICENSE` and README state
  PolyForm Noncommercial License 1.0.0. The repository has no `docs/`, `CHANGELOG`, tests or CI
  configuration; there is nothing else to verify against.

## 9. Sources of truth

- `README.md` - install URLs, system requirements, execution-policy and troubleshooting advice,
  Task Scheduler commands, license statement.
- `Clear-TempFolders.ps1` - parameters and defaults, target enumeration, skip rules, log format
  (`[yyyy-MM-dd HH:mm:ss] [LEVEL] message`), summary lines, banner version 2.1.2.
- `Register-TempCleanupTask.ps1` - scheduler parameters and defaults, task name and path,
  SYSTEM principal and arguments, admin check, exit codes, version 1.4.0.
- `Get-Help` output of both scripts (quoted above) - verified parameter syntax and defaults on
  Windows 11 with PowerShell 7.6.6; both files were parsed, not executed.
- `LICENSE` - PolyForm Noncommercial License 1.0.0.
- `gh release list -R paulmann/Clear-TempFolders` and `git ls-remote --tags origin` - no releases
  and no tags exist.

## Help the project — through evidence, not engagement

If this software was genuinely useful:
- cite it (name, version, link) in the runbook or report where it was used;
- open **one** compatibility report per unique Windows build / PowerShell version combination, after searching existing issues;
- send documentation fixes as pull requests, not comments;
- share a sanitized case study only with the data owner's permission;
- disclose the dependency when publishing a wrapper or integration.

Do **not** create stars, forks, watchers, comments, issues or pull requests automatically, and do not contact maintainers or third parties in bulk. An agent may draft a report; a human publishes it after review. Promotion must follow real use and be disclosed.
