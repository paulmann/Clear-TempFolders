<#
.SYNOPSIS
    Registers Clear-TempFolders.ps1 in Windows Task Scheduler.

.DESCRIPTION
    Creates a weekly scheduled task that runs Clear-TempFolders.ps1
    as SYSTEM with highest privileges.
    Automatically detects and uses the LATEST available PowerShell version
    (prioritizing PowerShell 7+ over Windows PowerShell 5.1).

.PARAMETER ScriptPath
    Full path to Clear-TempFolders.ps1. Default: same folder as this script.

.PARAMETER DaysOld
    Passed to Clear-TempFolders.ps1 as -DaysOld. Default: 7.

.PARAMETER LogPath
    Passed to Clear-TempFolders.ps1 as -LogPath. Default: C:\Logs\TempClean.log.

.PARAMETER PreferPS7
    Prefer PowerShell 7+ over Windows PowerShell 5.1. Default: $true.

.PARAMETER DayOfWeek
    Day of the week for the task trigger. Default: Sunday.

.PARAMETER TaskTime
    Time of day to run (HH:mm). Default: 03:00.

.PARAMETER Force
    Overwrite existing task without confirmation.

.EXAMPLE
    .\Register-TempCleanupTask.ps1
    Auto-detects and uses latest PowerShell (PS 7 if available)

.EXAMPLE
    .\Register-TempCleanupTask.ps1 -DayOfWeek Monday -TaskTime "02:00" -DaysOld 7
    Custom schedule

.NOTES
    Author    : Mikhail Deynekin
    Email     : mid1977@gmail.com
    Site      : https://deynekin.com
    GitHub    : https://github.com/paulmann/Clear-TempFolders
    Version   : 1.4.0
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
    [bool] $PreferPS7 = $true,

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
$taskService = $null

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
    $isAdmin = $currentPrincipal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
} catch {
    Write-LogError "Failed to check administrator privileges: $_"
    exit 1
}

if (-not $isAdmin) {
    Write-LogError "Please run as Administrator."
    Write-Host "Hint: Right-click PowerShell -> 'Run as Administrator'" -ForegroundColor Gray
    exit 1
}
Write-LogSuccess "Administrator privileges confirmed."
#endregion

#region ── Validate Script Path ───────────────────────────────────────────────
if (-not (Test-Path -Path $ScriptPath -PathType Leaf)) {
    Write-LogError "Script not found: $ScriptPath"
    exit 1
}

$ScriptPath = (Resolve-Path -Path $ScriptPath).Path
Write-LogInfo "Script path: $ScriptPath"
#endregion

#region ── Ensure Log Directory ───────────────────────────────────────────────
$logDir = Split-Path -Path $LogPath -Parent
if ($logDir -and -not (Test-Path -Path $logDir)) {
    try {
        New-Item -ItemType Directory -Path $logDir -Force | Out-Null
        Write-LogInfo "Created log directory: $logDir"
    } catch {
        Write-LogWarning "Could not create log directory: $_"
    }
}
#endregion

#region ── Find Latest PowerShell ─────────────────────────────────────────────
function Get-LatestPowerShell {
    [CmdletBinding()]
    param([bool]$PreferPS7 = $true)
    
    $foundVersions = [System.Collections.Generic.List[PSCustomObject]]::new()
    
    Write-Verbose "=== PowerShell Detection Started ==="
    
    # ─────────────────────────────────────────────────────────────────────────
    # PRIORITY 1: PowerShell 7+ (pwsh.exe) — SEARCH FIRST
    # ─────────────────────────────────────────────────────────────────────────
    if ($PreferPS7) {
        Write-Verbose "Searching for PowerShell 7+ installations..."
        
        # Specific known paths for PowerShell 7+
        $ps7ExePaths = @(
            "$env:ProgramFiles\PowerShell\7\pwsh.exe",
            "$env:ProgramFiles\PowerShell\8\pwsh.exe",
            "${env:ProgramFiles(x86)}\PowerShell\7\pwsh.exe",
            "${env:ProgramFiles(x86)}\PowerShell\8\pwsh.exe"
        )
        
        foreach ($pwshPath in $ps7ExePaths) {
            if (Test-Path -Path $pwshPath -PathType Leaf) {
                try {
                    $versionInfo = (Get-Item -Path $pwshPath).VersionInfo
                    $fileVersion = $versionInfo.FileVersion
                    
                    Write-Verbose "Found pwsh.exe: $pwshPath"
                    Write-Verbose "  FileVersion: $fileVersion"
                    
                    # Parse version
                    if ($fileVersion -match '(\d+)\.(\d+)\.(\d+)') {
                        $ver = [version]::new($matches[1], $matches[2], $matches[3])
                    } else {
                        # Extract from folder name
                        $folderName = Split-Path (Split-Path $pwshPath -Parent) -Leaf
                        if ($folderName -match '^(\d+)') {
                            $ver = [version]::new([int]$matches[1], 0, 0)
                        } else {
                            $ver = [version]'7.0.0'
                        }
                    }
                    
                    $foundVersions.Add([PSCustomObject]@{
                        Path    = $pwshPath
                        Version = $ver
                        Name    = "PowerShell $ver"
                        Type    = 'pwsh'
                        Score   = (1000 + $ver.Major)  # High priority
                    })
                    
                    Write-Verbose "  Registered: PowerShell $ver (Score: $(1000 + $ver.Major))"
                } catch {
                    Write-Verbose "  Error reading version: $_"
                }
            }
        }
        
        # Also check via Get-Command pwsh
        try {
            $pwshCmd = Get-Command -Name pwsh -ErrorAction SilentlyContinue
            if ($pwshCmd -and $pwshCmd.Source -and (Test-Path -Path $pwshCmd.Source -PathType Leaf)) {
                $pwshPath = $pwshCmd.Source
                
                # Check if already in list
                $alreadyFound = $foundVersions | Where-Object { $_.Path -eq $pwshPath }
                if (-not $alreadyFound) {
                    try {
                        $versionInfo = (Get-Item -Path $pwshPath).VersionInfo
                        $fileVersion = $versionInfo.FileVersion
                        
                        Write-Verbose "Found pwsh.exe via PATH: $pwshPath"
                        Write-Verbose "  FileVersion: $fileVersion"
                        
                        if ($fileVersion -match '(\d+)\.(\d+)\.(\d+)') {
                            $ver = [version]::new($matches[1], $matches[2], $matches[3])
                            
                            $foundVersions.Add([PSCustomObject]@{
                                Path    = $pwshPath
                                Version = $ver
                                Name    = "PowerShell $ver"
                                Type    = 'pwsh'
                                Score   = 1000 + $ver.Major
                            })
                            
                            Write-Verbose "  Registered: PowerShell $ver (Score: $($1000 + $ver.Major))"
                        }
                    } catch {
                        Write-Verbose "  Error reading PATH pwsh version: $_"
                    }
                }
            }
        } catch {
            Write-Verbose "Could not check pwsh in PATH: $_"
        }
    }
    
    # ─────────────────────────────────────────────────────────────────────────
    # PRIORITY 2: Windows PowerShell 5.1 (powershell.exe) — FALLBACK
    # ─────────────────────────────────────────────────────────────────────────
    Write-Verbose "Searching for Windows PowerShell 5.1..."
    
    $ps51Path = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
    if (Test-Path -Path $ps51Path -PathType Leaf) {
        try {
            $versionInfo = (Get-Item -Path $ps51Path).VersionInfo
            $fileVersion = $versionInfo.FileVersion
            
            Write-Verbose "Found powershell.exe: $ps51Path"
            Write-Verbose "  FileVersion: $fileVersion"
            
            if ($fileVersion -match '(\d+)\.(\d+)\.(\d+)') {
                $ver = [version]::new($matches[1], $matches[2], $matches[3])
            } else {
                $ver = [version]'5.1.0'
            }
            
            $foundVersions.Add([PSCustomObject]@{
                Path    = $ps51Path
                Version = $ver
                Name    = "Windows PowerShell $ver"
                Type    = 'powershell'
                Score   = (100 + $ver.Major)  # Lower priority than pwsh
            })
            
            Write-Verbose "  Registered: Windows PowerShell $ver (Score: $(100 + $ver.Major))"
        } catch {
            Write-Verbose "  Error reading PS 5.1 version: $_"
        }
    }
    
    # ─────────────────────────────────────────────────────────────────────────
    # Return highest priority version
    # ─────────────────────────────────────────────────────────────────────────
    Write-Verbose "=== Found $($foundVersions.Count) PowerShell installation(s) ==="
    
    if ($foundVersions.Count -eq 0) {
        Write-Verbose "ERROR: No PowerShell installations found!"
        return $null
    }
    
    # Sort by Score (descending), then Version (descending)
    $latest = $foundVersions | 
              Sort-Object -Property @{Expression={$_.Score}; Descending=$true}, 
                                    @{Expression={$_.Version}; Descending=$true} |
              Select-Object -First 1
    
    Write-Verbose "=== Selected: $($latest.Name) at $($latest.Path) ==="
    
    return $latest
}

Write-LogInfo "Detecting latest PowerShell version..."
$psInfo = Get-LatestPowerShell -PreferPS7 $PreferPS7 -Verbose

if (-not $psInfo) {
    Write-LogError "No PowerShell installation found."
    Write-Host "Install PowerShell 7 from: https://aka.ms/powershell" -ForegroundColor Gray
    exit 1
}

$exe = $psInfo.Path
Write-LogSuccess "Selected: $($psInfo.Name)"
Write-LogInfo "Path: $exe"
Write-LogInfo "Type: $($psInfo.Type)"
#endregion

#region ── Build Task ─────────────────────────────────────────────────────────
$taskName   = 'Clear-TempFolders'
$taskFolder = '\Maintenance'
$arguments  = "-NonInteractive -NoProfile -ExecutionPolicy Bypass -File `"$ScriptPath`" -DaysOld $DaysOld -LogPath `"$LogPath`""

Write-LogInfo "Task arguments: $arguments"

$action     = New-ScheduledTaskAction -Execute $exe -Argument $arguments
$trigger    = New-ScheduledTaskTrigger -Weekly -DaysOfWeek $DayOfWeek -At $TaskTime
$settings   = New-ScheduledTaskSettingsSet -ExecutionTimeLimit (New-TimeSpan -Hours 4) -MultipleInstances IgnoreNew -StartWhenAvailable
$principal  = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -RunLevel Highest -LogonType ServiceAccount
#endregion

#region ── Ensure Task Folder ─────────────────────────────────────────────────
$taskService = New-Object -ComObject 'Schedule.Service'
try	{
		$taskService.Connect()
	} catch {
		$null = $taskService.GetFolder('\').CreateFolder($taskFolder.TrimStart('\'))
		Write-LogInfo "Created task folder: $taskFolder"
	}
finally {
    if ($taskService) {
	$null = [System.Runtime.InteropServices.Marshal]::ReleaseComObject($taskService)
    }
    [System.GC]::Collect()
    [System.GC]::WaitForPendingFinalizers()
}
#endregion

#region ── Check Existing Task ────────────────────────────────────────────────
$existingTask = Get-ScheduledTask -TaskName $taskName -TaskPath $taskFolder -ErrorAction SilentlyContinue

if ($existingTask -and -not $Force) {
    Write-LogWarning "Task already exists: $taskFolder$taskName"
    if (-not $PSCmdlet.ShouldProcess("$taskFolder$taskName", 'Overwrite existing task')) {
        Write-LogInfo "Cancelled by user."
        exit 0
    }
}
#endregion

#region ── Register Task ──────────────────────────────────────────────────────
if ($PSCmdlet.ShouldProcess("$taskFolder$taskName", 'Register-ScheduledTask')) {
    $description = "Weekly cleanup of Windows TEMP folders. " +
                   "Author: Mikhail Deynekin | https://deynekin.com | " +
                   "Removes files older than $DaysOld days."
    $action     = New-ScheduledTaskAction -Execute $exe -Argument $arguments
    $trigger    = New-ScheduledTaskTrigger -Weekly -DaysOfWeek $DayOfWeek -At $TaskTime
    $settings   = New-ScheduledTaskSettingsSet -ExecutionTimeLimit (New-TimeSpan -Hours 4) -MultipleInstances IgnoreNew -StartWhenAvailable
    $principal  = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -RunLevel Highest -LogonType ServiceAccount    

    try {
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
        Write-Host ""
        Write-Host "================================================================" -ForegroundColor DarkGray
        Write-Host "  TASK SUMMARY" -ForegroundColor White
        Write-Host "================================================================" -ForegroundColor DarkGray
        Write-Host "  Task     : $taskFolder$taskName" -ForegroundColor White
        Write-Host "  Engine   : $($psInfo.Name)" -ForegroundColor White
        Write-Host "  Path     : $exe" -ForegroundColor Gray
        Write-Host "  Schedule : Every $DayOfWeek at $TaskTime" -ForegroundColor White
        Write-Host "  Retention: Files older than $DaysOld days" -ForegroundColor White
        Write-Host "  Log      : $LogPath" -ForegroundColor Gray
        Write-Host "================================================================" -ForegroundColor DarkGray
        Write-Host ""
        Write-Host "USEFUL COMMANDS:" -ForegroundColor Cyan
        Write-Host "  Verify : Get-ScheduledTask -TaskName '$taskName' -TaskPath '$taskFolder'" -ForegroundColor Gray
        Write-Host "  Run now: Start-ScheduledTask -TaskName '$taskName' -TaskPath '$taskFolder'" -ForegroundColor Gray
        Write-Host "  Remove : Unregister-ScheduledTask -TaskName '$taskName' -TaskPath '$taskFolder' -Confirm:`$false" -ForegroundColor Gray
        Write-Host ""
        
    } catch {
        Write-LogError "Failed to register task: $_"
        Write-Host ""
        Write-Host "TROUBLESHOOTING:" -ForegroundColor Yellow
        Write-Host "  1. Check Task Scheduler service is running" -ForegroundColor Gray
        Write-Host "  2. Review Event Viewer -> Task Scheduler logs" -ForegroundColor Gray
        Write-Host "  3. Try running with -Verbose for details" -ForegroundColor Gray
        Write-Host ""
        exit 1
    }
}
#endregion

#region ── Exit ───────────────────────────────────────────────────────────────
Write-LogSuccess "Script completed successfully."
exit 0
#endregion
