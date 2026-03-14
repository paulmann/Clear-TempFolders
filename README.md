# Clear-TempFolders

[![Version](https://img.shields.io/badge/version-1.1.0-blue.svg)](https://github.com/paulmann/Clear-TempFolders)
[![License](https://img.shields.io/badge/license-MIT-green.svg)](LICENSE)
[![PowerShell](https://img.shields.io/badge/powershell-5.1%2B-blue.svg)](https://docs.microsoft.com/powershell/)
[![Platform](https://img.shields.io/badge/platform-Windows%2010%2F11%2FServer-blue.svg)](https://www.microsoft.com/windows/)

PowerShell script to safely clean Windows TEMP directories (`C:\Windows\Temp` and all user `%LOCALAPPDATA%\Temp`) with DryRun mode, beautifully formatted summary output, and automated Task Scheduler integration.

## Features

- **DryRun Mode**: Simulate cleanup without deleting any files
- **Beautiful Output**: Modern, color-coded summary with statistics
- **Safe Cleanup**: Skips locked/in-use files automatically
- **Flexible Retention**: Configure age threshold (default: 2 days)
- **User TEMP Support**: Clean both system and all user TEMP folders
- **Task Scheduler**: One-command weekly automation setup
- **Logging**: Optional detailed log file generation
- **Quiet Mode**: Summary-only output for scheduled tasks
- **PowerShell 5.1 & 7**: Full compatibility with both versions

## Table of Contents

- [Quick Start](#quick-start)
- [Installation](#installation)
- [Usage Examples](#usage-examples)
- [Parameters](#parameters)
- [Task Scheduler Setup](#task-scheduler-setup)
- [Output Examples](#output-examples)
- [Troubleshooting](#troubleshooting)
- [License](#license)
- [Author](#author)

## Quick Start

```powershell
# Download the script
Invoke-WebRequest -Uri "https://raw.githubusercontent.com/paulmann/Clear-TempFolders/main/Clear-TempFolders.ps1" -OutFile "Clear-TempFolders.ps1"

# Run DryRun to see what would be deleted
.\Clear-TempFolders.ps1 -DryRun

# Clean files older than 2 days (default)
.\Clear-TempFolders.ps1

# Clean with custom retention and logging
.\Clear-TempFolders.ps1 -DaysOld 7 -LogPath "C:\Logs\tempclean.log"
```

## Installation

### Option 1: Direct Download

```powershell
# Download main cleanup script
Invoke-WebRequest -Uri "https://raw.githubusercontent.com/paulmann/Clear-TempFolders/main/Clear-TempFolders.ps1" `
    -OutFile "Clear-TempFolders.ps1"

# Download Task Scheduler registration script (optional)
Invoke-WebRequest -Uri "https://raw.githubusercontent.com/paulmann/Clear-TempFolders/main/Register-TempCleanupTask.ps1" `
    -OutFile "Register-TempCleanupTask.ps1"
```

### Option 2: Git Clone

```powershell
git clone https://github.com/paulmann/Clear-TempFolders.git
cd Clear-TempFolders
```

### System Requirements

- **OS**: Windows 10, Windows 11, Windows Server 2016+
- **PowerShell**: 5.1 or later (PowerShell 7 supported)
- **Privileges**: Administrator rights required
- **Execution Policy**: RemoteSigned or Bypass

## Usage Examples

### Basic Usage

```powershell
# DryRun mode - see what WOULD be deleted
.\Clear-TempFolders.ps1 -DryRun

# Default cleanup (files older than 2 days)
.\Clear-TempFolders.ps1

# System TEMP only (skip user folders)
.\Clear-TempFolders.ps1 -UserTemp $false

# Quiet mode (summary only, no per-file output)
.\Clear-TempFolders.ps1 -Quiet
```

### Advanced Usage

```powershell
# Keep files for 7 days with detailed logging
.\Clear-TempFolders.ps1 -DaysOld 7 -LogPath "C:\Logs\cleanup.log"

# Aggressive cleanup: 1 day retention, quiet mode
.\Clear-TempFolders.ps1 -DaysOld 1 -Quiet

# DryRun with custom retention
.\Clear-TempFolders.ps1 -DryRun -DaysOld 3 -UserTemp $false

# Full cleanup with logging
.\Clear-TempFolders.ps1 -DaysOld 2 -LogPath "C:\Logs\temp_$(Get-Date -Format 'yyyyMMdd').log"
```

## Parameters

| Parameter | Type | Default | Description |
|-----------|------|---------|-------------|
| `-DaysOld` | Int | `2` | Files older than this many days will be deleted |
| `-LogPath` | String | `''` | Full path to log file. Omit for no logging |
| `-UserTemp` | Bool | `$true` | Also clean all user TEMP folders |
| `-DryRun` | Switch | `$false` | Simulate only - no files deleted |
| `-Quiet` | Switch | `$false` | Show summary only, hide per-file output |

## Task Scheduler Setup

### Automatic Weekly Cleanup

```powershell
# Register with defaults (PowerShell 5.1, Sunday 03:00)
.\Register-TempCleanupTask.ps1

# Custom schedule (PowerShell 7, Monday 02:00, 7-day retention)
.\Register-TempCleanupTask.ps1 -UsePS7 $true -DayOfWeek Monday -TaskTime "02:00" -DaysOld 7

# Verify registration
Get-ScheduledTask -TaskName 'Clear-TempFolders'

# Run immediately
Start-ScheduledTask -TaskName 'Clear-TempFolders' -TaskPath '\Maintenance'

# Remove task
Unregister-ScheduledTask -TaskName 'Clear-TempFolders' -TaskPath '\Maintenance' -Confirm:$false
```

### Task Scheduler Parameters

| Parameter | Type | Default | Description |
|-----------|------|---------|-------------|
| `-ScriptPath` | String | (same dir) | Full path to Clear-TempFolders.ps1 |
| `-DaysOld` | Int | `2` | Retention passed to cleanup script |
| `-LogPath` | String | `C:\Logs\TempClean.log` | Log file path |
| `-UsePS7` | Bool | `$false` | Use PowerShell 7 (`pwsh.exe`) |
| `-DayOfWeek` | String | `Sunday` | Day to run task |
| `-TaskTime` | String | `03:00` | Time to run (HH:mm format) |

## Output Examples

### DryRun Mode Output

```
+----------------------------------------------------------------+
|  CLEAR-TEMP-FOLDERS  v1.1.0  *  DRY RUN - no files ...        |
+----------------------------------------------------------------+

  Mode      :  DRY RUN (simulation)
  Retention :  older than 2 day(s)
  User Temp :  Yes
  Log       :  -
  Quiet     :  No

------------------------------------------------------------------
  > Scanning: C:\Windows\Temp

  ~ FILE  C:\Windows\Temp\MsiA12F.tmp                    1.24 MB
  ~ FILE  C:\Windows\Temp\cab_1234\expand.exe             512 KB
  ...

==================================================================

  +------ PROJECTED CLEANUP --------------------------------+
  |  Files to delete    :  1234                            |
  |  Est. space freed   :  487.21 GB                       |
  |  Paths scanned      :  1                               |
  |  Retention          :  older than 2 day(s)             |
  |  Elapsed            :  00m 04s                         |
  +----------------------------------------------------------+

  i  DRY RUN complete. Re-run without -DryRun to apply.
```

### Live Cleanup Output

```
  +---------------- SUMMARY --------------------------------+
  |  Files removed      :  1234                            |
  |  Dirs removed       :    87                            |
  |  Space freed        :  487.21 GB                       |
  |  Skipped (locked)   :    12                            |
  |  Paths processed    :  1                               |
  |  Elapsed            :  01m 23s                         |
  +----------------------------------------------------------+

  +  Cleanup complete  *  2026-03-14 22:05:41
```

## Troubleshooting

### Common Issues

**"Please run as Administrator"**
- Right-click PowerShell → Run as Administrator
- Or use: `Start-Process PowerShell -Verb RunAs`

**"Execution policy" errors**
```powershell
Set-ExecutionPolicy -ExecutionPolicy RemoteSigned -Scope CurrentUser
# Or run with bypass:
powershell -ExecutionPolicy Bypass -File Clear-TempFolders.ps1
```

**No files deleted**
- Check if files are actually older than retention period
- Verify Administrator privileges
- Check if paths exist: `Test-Path "C:\Windows\Temp"`

**Many "SKIP" messages**
- Normal for locked/in-use files
- Reboot and run again for best results
- Files used by Windows services cannot be deleted

## License

This project is licensed under the **MIT License** - see the [LICENSE](LICENSE) file for details.

## Author

**Mikhail Deynekin**
- **Email**: mid1977@gmail.com
- **Website**: [https://deynekin.com](https://deynekin.com)
- **GitHub**: [https://github.com/paulmann](https://github.com/paulmann)

---

⭐ **Star this repository if you find it useful!**

*Last updated: March 14, 2026 | Version: 1.1.0*
