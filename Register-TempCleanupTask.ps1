<#
.SYNOPSIS
    Registers Clear-TempFolders.ps1 in Windows Task Scheduler.

.DESCRIPTION
    Creates a weekly scheduled task that runs Clear-TempFolders.ps1
    as SYSTEM with highest privileges.
    Compatible with both PowerShell 5.1 and PowerShell 7+.

.PARAMETER ScriptPath
    Full path to Clear-TempFolders.ps1.
    Default: same folder as this script.

.PARAMETER DaysOld
    Passed to Clear-TempFolders.ps1 as -DaysOld. Default: 7.

.PARAMETER LogPath
    Passed to Clear-TempFolders.ps1 as -LogPath.
    Default: C:\Logs\TempClean.log.

.PARAMETER UsePS7
    If specified, runs via pwsh.exe (PowerShell 7+).
    Otherwise uses powershell.exe (PowerShell 5.1).

.PARAMETER DayOfWeek
    Day of the week for the task trigger. Default: Sunday.

.PARAMETER TaskTime
    Time of day to run (HH:mm). Default: 03:00.

.PARAMETER Force
    Overwrite existing task without confirmation.

.EXAMPLE
    .\Register-TempCleanupTask.ps1
    Register with defaults (PS 5.1, Sunday 03:00)

.EXAMPLE
    .\Register-TempCleanupTask.ps1 -UsePS7 -DayOfWeek Monday -TaskTime "02:00" -DaysOld 7
    Register for PS 7, Monday 02:00, keep files 7 days

.EXAMPLE
    .\Register-TempCleanupTask.ps1 -Force
    Force overwrite without confirmation

.NOTES
    Author    : Mikhail Deynekin
    Email     : mid1977@gmail.com
    Site      : https://deynekin.com
    Version   : 1.2.0
    Updated   : 2026-03-15
    Requires  : PowerShell 5.1+ | Run as Administrator
    License   : MIT
#>

[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
param (
    [Parameter(Mandatory = $false)]
    [string] $ScriptPath = (Join-Path -Path $PSScriptRoot -ChildPath 'Clear-TempFolders.ps1'),

    [Parameter(Mandatory = $false)]
    [ValidateRange(1, 365)]
    [int] $DaysOld = 7,

    [Parameter(Mandatory = $false)]
    [string] $LogPath = 'C:\Logs\TempClean.log',

    [Parameter(Mandatory = $false)]
    [switch] $UsePS7,

    [Parameter(Mandatory = $false)]
    [ValidateSet('Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday', 'Sunday')]
    [string] $DayOfWeek = 'Sunday',

    [Parameter(Mandatory = $false)]
    [ValidatePattern('^([0-1]?[0-9]|2[0-3]):[0-5][0-9]$')]
    [string] $TaskTime = '03:00',

    [Parameter(Mandatory = $false)]
    [switch] $Force
)

#region ── Initialization ─────────────────────────────────────────────────────
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Color output helper functions
function Write-LogInfo    { param([string]$Message) Write-Host "[INFO]    $Message" -ForegroundColor Cyan }
function Write-LogSuccess { param([string]$Message) Write-Host "[OK]      $Message" -ForegroundColor Green }
function Write-LogWarning { param([string]$Message) Write-Host "[WARNING] $Message" -ForegroundColor Yellow }
function Write-LogError   { param([string]$Message) Write-Host "[ERROR]   $Message" -ForegroundColor Red }
#endregion

#region ── Admin Check ────────────────────────────────────────────────────────
try {
    $currentPrincipal = New-Object Security.Principal.WindowsPrincipal(
        [Security.Principal.WindowsIdentity]::GetCurrent()
    )
    $isAdmin = $currentPrincipal.IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator
    )
} catch {
    Write-LogError "Failed to check administrator privileges: $_"
    exit 1
}

if (-not $isAdmin) {
    Write-LogError "Please run as Administrator (elevated PowerShell)."
    Write-Host "Hint: Right-click PowerShell icon -> 'Run as Administrator'" -ForegroundColor Gray
    exit 1
}
Write-LogSuccess "Administrator privileges confirmed."
#endregion

#region ── Validate Script Path ───────────────────────────────────────────────
if (-not (Test-Path -Path $ScriptPath -PathType Leaf)) {
    Write-LogError "Script not found: $ScriptPath"
    Write-Host "Hint: Use -ScriptPath to specify the correct location." -ForegroundColor Gray
    exit 1
}

try {
    $ScriptPath = (Resolve-Path -Path $ScriptPath -ErrorAction Stop).Path
    Write-LogInfo "Script path: $ScriptPath"
} catch {
    Write-LogError "Failed to resolve script path: $_"
    exit 1
}
#endregion

#region ── Ensure Log Directory Exists ────────────────────────────────────────
try {
    $logDir = Split-Path -Path $LogPath -Parent
    if ($logDir -and -not (Test-Path -Path $logDir -PathType Container)) {
        New-Item -ItemType Directory -Path $logDir -Force -ErrorAction Stop | Out-Null
        Write-LogInfo "Created log directory: $logDir"
        
        # Grant SYSTEM full control on log directory
        try {
            $acl = Get-Acl -Path $logDir
            $systemRule = New-Object System.Security.AccessControl.FileSystemAccessRule(
                'NT AUTHORITY\SYSTEM',
                'FullControl',
                'ContainerInherit,ObjectInherit',
                'None',
                'Allow'
            )
            $acl.SetAccessRule($systemRule)
            Set-Acl -Path $logDir -AclObject $acl
            Write-LogInfo "Granted SYSTEM full control on $logDir"
        } catch {
            Write-LogWarning "Could not set ACL on log directory (will be created by cleanup script): $_"
        }
    }
} catch {
    Write-LogWarning "Could not create log directory: $logDir (will be created by cleanup script)"
}
#endregion

#region ── Resolve PowerShell Executable ──────────────────────────────────────
if ($UsePS7) {
    Write-LogInfo "PowerShell 7+ mode requested (-UsePS7)"
    
    $ps7Candidates = @(
        (Get-Command -Name pwsh -ErrorAction SilentlyContinue).Source,
        "$env:ProgramFiles\PowerShell\7\pwsh.exe",
        "$env:ProgramFiles\PowerShell\8\pwsh.exe",
        "${env:ProgramFiles(x86)}\PowerShell\7\pwsh.exe",
        "${env:ProgramFiles(x86)}\PowerShell\8\pwsh.exe",
        "$env:LOCALAPPDATA\Microsoft\WindowsApps\pwsh.exe"
    )
    
    $exe = $ps7Candidates | 
        Where-Object { $_ -and (Test-Path -Path $_ -PathType Leaf) } | 
        Select-Object -First 1
    
    if (-not $exe) {
        Write-LogError "PowerShell 7+ (pwsh.exe) not found."
        Write-Host "Hint: Install from https://aka.ms/powershell or run without -UsePS7" -ForegroundColor Gray
        exit 1
    }
    Write-LogSuccess "PowerShell 7+ found: $exe"
} else {
    $exe = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
    if (-not (Test-Path -Path $exe -PathType Leaf)) {
        Write-LogError "PowerShell 5.1 not found: $exe"
        exit 1
    }
    Write-LogSuccess "PowerShell 5.1 found: $exe"
}
#endregion

#region ── Build Task Components ──────────────────────────────────────────────
$taskName   = 'Clear-TempFolders'
$taskFolder = '\Maintenance'

# Build argument list with proper quoting for paths containing spaces
$arguments = @(
    '-NonInteractive'
    '-NoProfile'
    '-ExecutionPolicy'
    'Bypass'
    '-File'
    "`"$ScriptPath`""
    '-DaysOld'
    $DaysOld
    '-LogPath'
    "`"$LogPath`""
) -join ' '

Write-LogInfo "Task arguments: $arguments"

try {
    $action = New-ScheduledTaskAction -Execute $exe -Argument $arguments -ErrorAction Stop
} catch {
    Write-LogError "Failed to create scheduled task action: $_"
    exit 1
}

try {
    $trigger = New-ScheduledTaskTrigger -Weekly -DaysOfWeek $DayOfWeek -At $TaskTime -ErrorAction Stop
} catch {
    Write-LogError "Failed to create scheduled task trigger: $_"
    exit 1
}

$settings = New-ScheduledTaskSettingsSet `
    -ExecutionTimeLimit (New-TimeSpan -Hours 4) `
    -MultipleInstances IgnoreNew `
    -StartWhenAvailable `
    -RunOnlyIfNetworkAvailable:$false `
    -AllowStartIfOnBatteries `
    -DontStopIfGoingOnBatteries `
    -WakeToRun:$false `
    -Hidden:$false `
    -RestartCount 3 `
    -RestartInterval (New-TimeSpan -Minutes 1)

$principal = New-ScheduledTaskPrincipal `
    -UserId 'SYSTEM' `
    -RunLevel Highest `
    -LogonType ServiceAccount
#endregion

#region ── Ensure Task Folder Exists (COM approach) ───────────────────────────
function New-TaskFolder {
    param([string]$Path)
    
    $taskService = $null
    try {
        $taskService = New-Object -ComObject 'Schedule.Service'
        $taskService.Connect()
        
        $rootFolder = $taskService.GetFolder('\')
        $folderName = $Path.TrimStart('\')
        
        # Check if folder already exists
        try {
            $null = $taskService.GetFolder($Path)
            return $true  # Folder exists
        } catch {
            # Folder doesn't exist, create it
            try {
                $null = $rootFolder.CreateFolder($folderName)
                return $true
            } catch {
                Write-LogError "Failed to create task folder '$Path': $_"
                return $false
            }
        }
    } catch {
        Write-LogError "Failed to connect to Task Scheduler service: $_"
        return $false
    } finally {
        if ($taskService) {
            [System.Runtime.InteropServices.Marshal]::ReleaseComObject($taskService) | Out-Null
            [System.GC]::Collect()
            [System.GC]::WaitForPendingFinalizers()
        }
    }
}

if (-not (New-TaskFolder -Path $taskFolder)) {
    Write-LogError "Failed to ensure task folder exists: $taskFolder"
    exit 1
}
Write-LogInfo "Task folder confirmed: $taskFolder"
#endregion

#region ── Check Existing Task ────────────────────────────────────────────────
$existingTask = Get-ScheduledTask -TaskName $taskName -TaskPath $taskFolder -ErrorAction SilentlyContinue
$taskExists = $null -ne $existingTask

if ($taskExists) {
    Write-LogWarning "Task already exists: $taskFolder$taskName"
    
    if (-not $Force -and -not $PSCmdlet.ShouldProcess(
            "$taskFolder$taskName", 
            'Overwrite existing scheduled task'
        )) {
        Write-LogInfo "Operation cancelled by user."
        exit 0
    }
    Write-LogInfo "Force overwrite enabled."
}
#endregion

#region ── Register Task ──────────────────────────────────────────────────────
if ($PSCmdlet.ShouldProcess("$taskFolder$taskName", 'Register-ScheduledTask')) {
    try {
        $description = "Weekly cleanup of Windows TEMP folders. " +
                       "Author: Mikhail Deynekin | https://deynekin.com | " +
                       "Runs as SYSTEM with highest privileges. " +
                       "Removes files older than $DaysOld days."

        Register-ScheduledTask `
            -TaskName $taskName `
            -TaskPath $taskFolder `
            -Action $action `
            -Trigger $trigger `
            -Settings $settings `
            -Principal $principal `
            -Description $description `
            -Force `
            -ErrorAction Stop | Out-Null

        Write-LogSuccess "Task registered successfully!"
        
        # Display summary
        Write-Host ""
        Write-Host "═══════════════════════════════════════════════════════════" -ForegroundColor DarkGray
        Write-Host "  TASK SUMMARY" -ForegroundColor White
        Write-Host "═══════════════════════════════════════════════════════════" -ForegroundColor DarkGray
        Write-Host "  Task Name : $taskFolder$taskName" -ForegroundColor White
        Write-Host "  Engine    : $(Split-Path $exe -Leaf) ($exe)" -ForegroundColor Gray
        Write-Host "  Schedule  : Every $DayOfWeek at $TaskTime" -ForegroundColor White
        Write-Host "  Retention : Files older than $DaysOld days" -ForegroundColor White
        Write-Host "  Log Path  : $LogPath" -ForegroundColor Gray
        Write-Host "  PS Version: $(if ($UsePS7) { 'PowerShell 7+' } else { 'PowerShell 5.1' })" -ForegroundColor White
        Write-Host "  Run As    : SYSTEM (highest privileges)" -ForegroundColor Gray
        Write-Host "═══════════════════
