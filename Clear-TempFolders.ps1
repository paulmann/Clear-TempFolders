<#
.SYNOPSIS
    Safely cleans Windows TEMP directories by removing files older than N days.

.DESCRIPTION
    Deletes files and empty directories from C:\Windows\Temp and/or all user
    TEMP folders (C:\Users\*\AppData\Local\Temp).
    Supports -DryRun mode: shows what WOULD be deleted without touching anything.
    Outputs a beautifully formatted summary at the end.

.PARAMETER DaysOld
    Files older than this many days will be targeted. Default: 2.

.PARAMETER LogPath
    Full path to a log file. Omit to skip logging.

.PARAMETER UserTemp
    Also scan all user TEMP folders. Default: $true.

.PARAMETER DryRun
    Simulate cleanup only. No files are deleted. Shows projected stats.

.PARAMETER Quiet
    Suppress per-file output. Show only the final summary.

.EXAMPLE
    .\Clear-TempFolders.ps1
    .\Clear-TempFolders.ps1 -DryRun
    .\Clear-TempFolders.ps1 -DaysOld 7 -LogPath "C:\Logs\tempclean.log"
    .\Clear-TempFolders.ps1 -DaysOld 3 -UserTemp $false -Quiet
    .\Clear-TempFolders.ps1 -DryRun -DaysOld 1 -UserTemp $false

.NOTES
    Author  : Mikhail Deynekin
    Email   : mid1977@gmail.com
    Site    : https://deynekin.com
    GitHub  : https://github.com/paulmann/Clear-TempFolders
    Version : 1.1.0
    Requires: PowerShell 5.1+ | Run as Administrator
#>

[CmdletBinding()]
param (
    [int]    $DaysOld  = 2,
    [string] $LogPath  = '',
    [bool]   $UserTemp = $true,
    [switch] $DryRun,
    [switch] $Quiet
)

# ── Strict mode, keep errors visible ─────────────────────────────────────────
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Continue'

# ── Counters ──────────────────────────────────────────────────────────────────
[int]  $cntFiles   = 0
[int]  $cntDirs    = 0
[int]  $cntSkipped = 0
[long] $totalBytes = 0L

# ── Helpers ───────────────────────────────────────────────────────────────────
function Format-Size {
    param([long] $Bytes)
    if ($Bytes -ge 1GB) { return '{0:N2} GB' -f ($Bytes / 1GB) }
    if ($Bytes -ge 1MB) { return '{0:N2} MB' -f ($Bytes / 1MB) }
    if ($Bytes -ge 1KB) { return '{0:N2} KB' -f ($Bytes / 1KB) }
    return "$Bytes B"
}

function Write-Log {
    param([string] $Line)
    if ($LogPath -ne '') {
        $Line | Out-File -FilePath $LogPath -Append -Encoding UTF8
    }
}

function Print-Line {
    param([string] $Text = '', [ConsoleColor] $Color = 'Gray')
    Write-Host $Text -ForegroundColor $Color
    Write-Log $Text
}

# ── Admin check ──────────────────────────────────────────────────────────────
$principal = New-Object Security.Principal.WindowsPrincipal(
    [Security.Principal.WindowsIdentity]::GetCurrent()
)
$isAdmin = $principal.IsInRole(
    [Security.Principal.WindowsBuiltInRole]::Administrator
)
if (-not $isAdmin) {
    Print-Line '  x  ERROR: Please run as Administrator.' Red
    exit 1
}

# ── Header ────────────────────────────────────────────────────────────────────
$version   = 'v1.1.0'
$width     = 62
$modeLabel = if ($DryRun) { '  *  DRY RUN - no files will be deleted  ' } else { '' }

Print-Line ''
Print-Line ('+-' + ('-' * $width) + '-+') Cyan
Print-Line ('|  CLEAR-TEMP-FOLDERS  {0}{1}' -f $version, $modeLabel).PadRight($width + 3) + '|' Cyan
Print-Line ('+-' + ('-' * $width) + '-+') Cyan
Print-Line ''

$modeColor = if ($DryRun) { 'Yellow' } else { 'Green' }
$modeText  = if ($DryRun) { 'DRY RUN (simulation)' } else { 'LIVE (files WILL be deleted)' }

Print-Line ('  Mode      :  ' + $modeText) $modeColor
Print-Line ('  Retention :  older than {0} day(s)' -f $DaysOld) Gray
Print-Line ('  User Temp :  {0}' -f $(if ($UserTemp) { 'Yes' } else { 'No' })) Gray
Print-Line ('  Log       :  {0}' -f $(if ($LogPath -ne '') { $LogPath } else { '-' })) Gray
Print-Line ('  Quiet     :  {0}' -f $(if ($Quiet) { 'Yes (summary only)' } else { 'No' })) Gray
Print-Line ''

# ── Build target list ─────────────────────────────────────────────────────────
$targets = [System.Collections.Generic.List[string]]::new()
$targets.Add('C:\Windows\Temp')

if ($UserTemp) {
    $profiles = Get-ChildItem -Path 'C:\Users' -Directory -Force -ErrorAction SilentlyContinue
    foreach ($p in $profiles) {
        $ut = Join-Path -Path $p.FullName -ChildPath 'AppData\Local\Temp'
        if (Test-Path -Path $ut) { $targets.Add($ut) }
    }
}

$limit     = (Get-Date).AddDays(-$DaysOld)
$startTime = Get-Date

# ── Main cleanup loop ─────────────────────────────────────────────────────────
foreach ($target in $targets) {
    Print-Line ('-' * ($width + 4)) DarkGray

    if (-not (Test-Path -Path $target)) {
        Print-Line ("  !  Path not found, skipping: $target") DarkYellow
        continue
    }

    Print-Line ("  > Scanning: $target") White
    Print-Line ''

    # Files
    $files = Get-ChildItem -Path $target -File -Recurse -Force `
             -ErrorAction SilentlyContinue |
             Where-Object { $_.LastWriteTime -lt $limit }

    $fileCount = 0
    if ($null -ne $files) {
        foreach ($file in $files) {
            $fileCount++
            $fileSize = $file.Length

            if ($DryRun) {
                $cntFiles++
                $totalBytes += $fileSize
                if (-not $Quiet) {
                    Print-Line ('  ~ FILE  {0,-52} {1,9}' -f `
                        ($file.FullName), (Format-Size $fileSize)) DarkCyan
                }
            } else {
                try {
                    Remove-Item -Path $file.FullName -Force -ErrorAction Stop
                    $cntFiles++
                    $totalBytes += $fileSize
                    if (-not $Quiet) {
                        Print-Line ('  + FILE  {0,-52} {1,9}' -f `
                            ($file.FullName), (Format-Size $fileSize)) Green
                    }
                    Write-Log "[REMOVED] $($file.FullName)"
                }
                catch {
                    $cntSkipped++
                    if (-not $Quiet) {
                        Print-Line ('  - SKIP  {0}' -f $file.FullName) DarkYellow
                    }
                    Write-Log "[SKIPPED] $($file.FullName) | $($_.Exception.Message)"
                }
            }
        }
    }

    if ($fileCount -eq 0) {
        Print-Line '  i  No matching files found in this path.' DarkGray
    }

    # Directories (deepest first)
    if (-not $DryRun) {
        $dirs = Get-ChildItem -Path $target -Directory -Recurse -Force `
                -ErrorAction SilentlyContinue |
                Where-Object  { $_.LastWriteTime -lt $limit } |
                Sort-Object   -Property FullName -Descending

        if ($null -ne $dirs) {
            foreach ($dir in $dirs) {
                try {
                    Remove-Item -Path $dir.FullName -Recurse -Force -ErrorAction Stop
                    $cntDirs++
                    if (-not $Quiet) {
                        Print-Line ('  + DIR   {0}' -f $dir.FullName) DarkGreen
                    }
                    Write-Log "[REMOVED DIR] $($dir.FullName)"
                }
                catch {
                    $cntSkipped++
                    if (-not $Quiet) {
                        Print-Line ('  - SKIP  [DIR] {0}' -f $dir.FullName) DarkYellow
                    }
                }
            }
        }
    }

    Print-Line ''
}

# ── Summary ───────────────────────────────────────────────────────────────────
$elapsed = (Get-Date) - $startTime
$elapsedStr = '{0:mm}m {0:ss}s' -f $elapsed

Print-Line ('=' * ($width + 4)) Cyan
Print-Line ''

if ($DryRun) {
    Print-Line '  +------ PROJECTED CLEANUP --------------------------------+' Yellow
    Print-Line ('  |  Files to delete    :  {0,-34}|' -f $cntFiles) Yellow
    Print-Line ('  |  Est. space freed   :  {0,-34}|' -f (Format-Size $totalBytes)) Yellow
    Print-Line ('  |  Paths scanned      :  {0,-34}|' -f $targets.Count) Yellow
    Print-Line ('  |  Retention          :  older than {0,-24}|' -f "$DaysOld day(s)") Yellow
    Print-Line ('  |  Elapsed            :  {0,-34}|' -f $elapsedStr) Yellow
    Print-Line '  +----------------------------------------------------------+' Yellow
    Print-Line ''
    Print-Line '  i  DRY RUN complete. Re-run without -DryRun to apply.' DarkCyan
} else {
    $summaryColor = if ($cntFiles -gt 0) { 'Green' } else { 'DarkGray' }
    Print-Line '  +---------------- SUMMARY --------------------------------+' $summaryColor
    Print-Line ('  |  Files removed      :  {0,-34}|' -f $cntFiles) $summaryColor
    Print-Line ('  |  Dirs removed       :  {0,-34}|' -f $cntDirs) $summaryColor
    Print-Line ('  |  Space freed        :  {0,-34}|' -f (Format-Size $totalBytes)) $summaryColor
    Print-Line ('  |  Skipped (locked)   :  {0,-34}|' -f $cntSkipped) $summaryColor
    Print-Line ('  |  Paths processed    :  {0,-34}|' -f $targets.Count) $summaryColor
    Print-Line ('  |  Elapsed            :  {0,-34}|' -f $elapsedStr) $summaryColor
    Print-Line '  +----------------------------------------------------------+' $summaryColor
    Print-Line ''
    Print-Line ('  +  Cleanup complete  *  {0}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')) $summaryColor
}

Print-Line ''
