<#
.SYNOPSIS
    Registers Clear-TempFolders.ps1 in Windows Task Scheduler.

.DESCRIPTION
    Creates a weekly scheduled task that runs Clear-TempFolders.ps1
    as SYSTEM with highest privileges.
    Compatible with both PowerShell 5.1 and PowerShell 7.

.PARAMETER ScriptPath
    Full path to Clear-TempFolders.ps1.
    Default: same folder as this script.

.PARAMETER DaysOld
    Passed to Clear-TempFolders.ps1 as -DaysOld. Default: 2.

.PARAMETER LogPath
    Passed to Clear-TempFolders.ps1 as -LogPath.
    Default: C:\Logs\TempClean.log.

.PARAMETER UsePS7
    If $true, runs via pwsh.exe (PowerShell 7).
    If $false (default), runs via powershell.exe (PowerShell 5.1).

.PARAMETER DayOfWeek
    Day of the week for the task trigger. Default: Sunday.

.PARAMETER TaskTime
    Time of day to run (HH:mm). Default: 03:00.

.EXAMPLE
    # Register with defaults (PS 5.1, Sunday 03:00)
    .\Register-TempCleanupTask.ps1

    # Register for PS 7, Monday 02:00, keep files 7 days
    .\Register-TempCleanupTask.ps1 -UsePS7 $true -DayOfWeek Monday -TaskTime "02:00" -DaysOld 7

    # Verify
    Get-ScheduledTask -TaskName 'Clear-TempFolders'

    # Run immediately
    Start-ScheduledTask -TaskName 'Clear-TempFolders' -TaskPath '\Maintenance'

    # Remove
    Unregister-ScheduledTask -TaskName 'Clear-TempFolders' -TaskPath '\Maintenance' -Confirm:$false

.NOTES
    Author  : Mikhail Deynekin
    Email   : mid1977@gmail.com
    Site    : https://deynekin.com
    GitHub  : https://github.com/paulmann/Clear-TempFolders
    Version : 1.1.0
    Requires: PowerShell 5.1+ | Run as Administrator
#>

[CmdletBinding(SupportsShouldProcess)]
param (
    [string] $ScriptPath = (Join-Path -Path $PSScriptRoot -ChildPath 'Clear-TempFolders.ps1'),
    [int]    $DaysOld    = 2,
    [string] $LogPath    = 'C:\Logs\TempClean.log',
    [bool]   $UsePS7     = $false,
    [string] $DayOfWeek  = 'Sunday',
    [string] $TaskTime   = '03:00'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ── Admin check ──────────────────────────────────────────────────────────────
$principal = New-Object Security.Principal.WindowsPrincipal(
    [Security.Principal.WindowsIdentity]::GetCurrent()
)
$isAdmin = $principal.IsInRole(
    [Security.Principal.WindowsBuiltInRole]::Administrator
)
if (-not $isAdmin) {
    Write-Host '[ERROR] Please run as Administrator.' -ForegroundColor Red
    exit 1
}

# ── Validate script path ───────────────────────────────────────────────────────
if (-not (Test-Path -Path $ScriptPath)) {
    Write-Host "[ERROR] Script not found: $ScriptPath" -ForegroundColor Red
    exit 1
}

# ── Ensure log directory exists ───────────────────────────────────────────────────
$logDir = Split-Path -Path $LogPath -Parent
if (-not (Test-Path -Path $logDir)) {
    New-Item -ItemType Directory -Path $logDir -Force | Out-Null
    Write-Host "[INFO] Created log directory: $logDir" -ForegroundColor Gray
}

# ── Resolve PowerShell executable ──────────────────────────────────────────────
if ($UsePS7) {
    $ps7Default = 'C:\Program Files\PowerShell\7\pwsh.exe'
    $ps7Found   = Get-Command -Name pwsh -ErrorAction SilentlyContinue
    if ($ps7Found) {
        $exe = $ps7Found.Source
    } elseif (Test-Path -Path $ps7Default) {
        $exe = $ps7Default
    } else {
        Write-Host '[ERROR] pwsh.exe not found. Install PowerShell 7 or use -UsePS7 $false.' -ForegroundColor Red
        exit 1
    }
} else {
    $exe = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
}

# ── Build task components ─────────────────────────────────────────────────────────
$taskName   = 'Clear-TempFolders'
$taskFolder = '\Maintenance'
$arguments  = "-NonInteractive -NoProfile -ExecutionPolicy Bypass -File `"$ScriptPath`" -DaysOld $DaysOld -LogPath `"$LogPath`""

$action = New-ScheduledTaskAction -Execute $exe -Argument $arguments

$trigger = New-ScheduledTaskTrigger -Weekly -DaysOfWeek $DayOfWeek -At $TaskTime

$settings = New-ScheduledTaskSettingsSet `
    -ExecutionTimeLimit       (New-TimeSpan -Hours 2) `
    -MultipleInstances        IgnoreNew `
    -StartWhenAvailable `
    -RunOnlyIfNetworkAvailable:$false

$principal2 = New-ScheduledTaskPrincipal `
    -UserId   'SYSTEM' `
    -RunLevel Highest

# ── Register ────────────────────────────────────────────────────────────────────
if ($PSCmdlet.ShouldProcess("$taskFolder\$taskName", 'Register-ScheduledTask')) {
    Register-ScheduledTask `
        -TaskName    $taskName `
        -TaskPath    $taskFolder `
        -Action      $action `
        -Trigger     $trigger `
        -Settings    $settings `
        -Principal   $principal2 `
        -Description "Weekly cleanup of Windows TEMP folders. Author: Mikhail Deynekin | https://deynekin.com" `
        -Force | Out-Null

    Write-Host ''
    Write-Host '[OK] Task registered successfully.' -ForegroundColor Green
    Write-Host "     Task     : $taskFolder\$taskName"
    Write-Host "     Engine   : $exe"
    Write-Host "     Schedule : Every $DayOfWeek at $TaskTime"
    Write-Host "     DaysOld  : $DaysOld"
    Write-Host "     Log      : $LogPath"
    Write-Host ''
    Write-Host 'Useful commands:' -ForegroundColor Cyan
    Write-Host "  Verify  : Get-ScheduledTask -TaskName '$taskName'"
    Write-Host "  Run now : Start-ScheduledTask -TaskName '$taskName' -TaskPath '$taskFolder'"
    Write-Host "  Remove  : Unregister-ScheduledTask -TaskName '$taskName' -TaskPath '$taskFolder' -Confirm:`$false"
}
