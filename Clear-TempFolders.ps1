<#
.SYNOPSIS
    Safely cleans Windows TEMP directories by removing files older than N days.

.DESCRIPTION
    Deletes files older than specified days from C:\Windows\Temp and optionally
    from all user TEMP folders. After deleting files, removes empty directories.
    Supports DryRun mode - shows what WOULD be deleted without touching anything.
    Outputs a formatted summary with statistics.
    
    Supports PowerShell -WhatIf and -Confirm parameters for safe execution.

.PARAMETER DaysOld
    Files older than this many days will be targeted. Must be a positive integer.
    Minimum: 1, Maximum: 365. Default: 7.

.PARAMETER LogPath
    Full path to a log file. If omitted, no log is written.
    Directory will be created automatically if it doesn't exist.

.PARAMETER ExcludeUserTemp
    If specified, skips user TEMP folders (C:\Users\*\AppData\Local\Temp).
    By default, user TEMP folders are included.

.PARAMETER DryRun
    Simulate cleanup only - no files or folders are deleted. Shows projected stats.
    Equivalent to -WhatIf.

.PARAMETER Quiet
    Suppress per-file output. Show only the final summary.

.PARAMETER MaxDepth
    Maximum recursion depth for scanning. Prevents excessive traversal.
    Default: 10 (set to 0 for unlimited). Only supported in PS 5.1+.

.PARAMETER ExcludePatterns
    Array of wildcard patterns to exclude from deletion (e.g., '*.lock', 'important_*').

.EXAMPLE
    .\Clear-TempFolders.ps1
    Default cleanup (7 days, all temp folders)

.EXAMPLE
    .\Clear-TempFolders.ps1 -DryRun
    Simulate cleanup without deleting anything

.EXAMPLE
    .\Clear-TempFolders.ps1 -DaysOld 14 -LogPath "C:\Logs\tempclean.log"
    Clean files older than 14 days with logging

.EXAMPLE
    .\Clear-TempFolders.ps1 -DaysOld 3 -ExcludeUserTemp -Quiet
    Clean only Windows\Temp, 3 days, summary only

.EXAMPLE
    .\Clear-TempFolders.ps1 -WhatIf
    PowerShell native dry-run mode

.EXAMPLE
    .\Clear-TempFolders.ps1 -ExcludePatterns @('*.lock', 'cache_*')
    Exclude specific file patterns from deletion

.NOTES
    Author    : Mikhail Deynekin
    Email     : mid1977@gmail.com
    Site      : https://deynekin.com  
    GitHub    : https://github.com/paulmann/Clear-TempFolders  
    Version   : 2.1.2
    Updated   : 2026-03-15
    Requires  : PowerShell 5.1+ | Run as Administrator
    License   : MIT
#>

[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
param (
    [Parameter(Mandatory = $false)]
    [ValidateRange(1, 365)]
    [int] $DaysOld = 7,

    [Parameter(Mandatory = $false)]
    [string] $LogPath = '',

    [Parameter(Mandatory = $false)]
    [switch] $ExcludeUserTemp,

    [Parameter(Mandatory = $false)]
    [switch] $DryRun,

    [Parameter(Mandatory = $false)]
    [switch] $Quiet,

    [Parameter(Mandatory = $false)]
    [ValidateRange(0, 50)]
    [int] $MaxDepth = 10,

    [Parameter(Mandatory = $false)]
    [string[]] $ExcludePatterns = @()
)

#region ── Initialization ─────────────────────────────────────────────────────
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Continue'

# Sync DryRun with WhatIf
if ($WhatIfPreference) {
    $DryRun = $true
}

# Counters
[int]    $script:cntFiles        = 0
[int]    $script:cntDirs         = 0
[int]    $script:cntSkipped      = 0
[int]    $script:cntDirsSkipped  = 0
[int]    $script:cntExcluded     = 0
[long]   $script:totalBytes      = 0L
[datetime] $script:scriptStart   = Get-Date

# Check PS version for Depth support
$script:supportsDepth = $PSVersionTable.PSVersion.Major -ge 5 -and 
                        $PSVersionTable.PSVersion.Minor -ge 1
#endregion

#region ── Helper Functions ───────────────────────────────────────────────────
function Format-FileSize {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [long] $Bytes
    )
    
    if ($Bytes -lt 0) { return '0 B' }
    if ($Bytes -ge 1TB) { return '{0:N2} TB' -f ($Bytes / 1TB) }
    if ($Bytes -ge 1GB) { return '{0:N2} GB' -f ($Bytes / 1GB) }
    if ($Bytes -ge 1MB) { return '{0:N2} MB' -f ($Bytes / 1MB) }
    if ($Bytes -ge 1KB) { return '{0:N2} KB' -f ($Bytes / 1KB) }
    return "$Bytes B"
}

function Write-ColorOutput {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string] $Message,
        
        [Parameter(Mandatory = $false)]
        [System.ConsoleColor] $ForegroundColor = [System.ConsoleColor]::Gray,
        
        [Parameter(Mandatory = $false)]
        [switch] $NoLog
    )
    
    Write-Host $Message -ForegroundColor $ForegroundColor
    
    if (-not $NoLog -and $script:LogPath -and -not [string]::IsNullOrWhiteSpace($Message)) {
        Write-LogMessage -Message $Message -Level 'OUTPUT'
    }
}

function Write-LogMessage {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string] $Message,
        
        [Parameter(Mandatory = $false)]
        [ValidateSet('INFO', 'WARNING', 'ERROR', 'OUTPUT')]
        [string] $Level = 'INFO'
    )
    
    if (-not $script:LogPath) { return }
    if ([string]::IsNullOrWhiteSpace($Message)) { return }
    
    try {
        $timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
        $logLine = "[$timestamp] [$Level] $Message"
        
        $logDir = Split-Path -Path $script:LogPath -Parent
        if ($logDir -and -not (Test-Path -Path $logDir -PathType Container)) {
            $null = New-Item -ItemType Directory -Path $logDir -Force -ErrorAction Stop
        }
        
        $logLine | Out-File -FilePath $script:LogPath -Append -Encoding UTF8 -ErrorAction Stop
    } catch {
        Write-Verbose "Failed to write to log: $_"
    }
}

function Test-PathExcluded {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)]
        [string] $Path,
        
        [Parameter(Mandatory = $false)]
        [string[]] $Patterns
    )
    
    if (-not $Patterns -or $Patterns.Count -eq 0) { 
        return $false 
    }
    
    $fileName = Split-Path -Path $Path -Leaf
    
    foreach ($pattern in $Patterns) {
        if ($fileName -like $pattern) {
            return $true
        }
    }
    
    return $false
}

function Get-RelativePath {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [string] $FullPath,
        
        [Parameter(Mandatory)]
        [string] $BasePath
    )
    
    $FullPath = $FullPath.TrimEnd('\')
    $BasePath = $BasePath.TrimEnd('\')
    
    if ($FullPath.StartsWith($BasePath, [StringComparison]::OrdinalIgnoreCase)) {
        $relative = $FullPath.Substring($BasePath.Length).TrimStart('\')
        # ✅ FIX: Proper if-expression syntax for return
        return $(if ($relative) { $relative } else { '.' })
    }
    
    return $FullPath
}

function Test-IsJunctionOrSymlink {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)]
        [string] $Path
    )
    
    try {
        $item = Get-Item -Path $Path -Force -ErrorAction Stop
        return ($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -eq [System.IO.FileAttributes]::ReparsePoint
    } catch {
        return $false
    }
}

function Get-FilesRecursive {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string] $Path,
        
        [Parameter(Mandatory = $false)]
        [int] $MaxDepth,
        
        [Parameter(Mandatory = $false)]
        [datetime] $OlderThan,
        
        [Parameter(Mandatory = $false)]
        [string[]] $ExcludePatterns
    )
    
    $getChildItemParams = @{
        Path        = $Path
        File        = $true
        Force       = $true
        Recurse     = $true
        ErrorAction = 'SilentlyContinue'
    }
    
    if ($script:supportsDepth -and $MaxDepth -gt 0) {
        $getChildItemParams.Depth = $MaxDepth
    }
    
    $files = Get-ChildItem @getChildItemParams |
             Where-Object { 
                 $_.LastWriteTime -lt $OlderThan -and
                 -not (Test-PathExcluded -Path $_.FullName -Patterns $ExcludePatterns) -and
                 -not (Test-IsJunctionOrSymlink -Path $_.FullName)
             }
    
    return $files
}

function Get-DirectoriesRecursive {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string] $Path,
        
        [Parameter(Mandatory = $false)]
        [int] $MaxDepth
    )
    
    $getChildItemParams = @{
        Path        = $Path
        Directory   = $true
        Force       = $true
        Recurse     = $true
        ErrorAction = 'SilentlyContinue'
    }
    
    if ($script:supportsDepth -and $MaxDepth -gt 0) {
        $getChildItemParams.Depth = $MaxDepth
    }
    
    $dirs = Get-ChildItem @getChildItemParams |
            Where-Object { -not (Test-IsJunctionOrSymlink -Path $_.FullName) } |
            Sort-Object { $_.FullName.Split('\').Count } -Descending
    
    return $dirs
}
#endregion

#region ── Validate Parameters ────────────────────────────────────────────────
if ($DaysOld -le 0) {
    Write-ColorOutput '[ERROR] DaysOld must be a positive integer (1-365).' -ForegroundColor Red
    exit 1
}

if ($LogPath) {
    $script:LogPath = $LogPath
    try {
        $logDir = Split-Path -Path $LogPath -Parent
        if ($logDir -and -not (Test-Path -Path $logDir -PathType Container)) {
            $null = New-Item -ItemType Directory -Path $logDir -Force -ErrorAction Stop
            Write-LogMessage "Created log directory: $logDir"
        }
    } catch {
        Write-ColorOutput "[WARNING] Could not create log directory: $logDir" -ForegroundColor Yellow
        $script:LogPath = ''
    }
} else {
    $script:LogPath = ''
}

if ($MaxDepth -gt 0 -and -not $script:supportsDepth) {
    Write-ColorOutput "[WARNING] -MaxDepth requires PowerShell 5.1+. Will scan all depths." -ForegroundColor Yellow
    Write-LogMessage "MaxDepth not supported in PS $($PSVersionTable.PSVersion), ignoring" -Level 'WARNING'
}
#endregion

#region ── Header Display ─────────────────────────────────────────────────────
$modeLabel = if ($DryRun) { '· DRY RUN · ' } else { '' }
$version   = 'v2.1.2'
$width     = 70

$borderTop    = '╔' + ('═' * $width) + '╗'
$borderMiddle = '╠' + ('═' * $width) + '╣'
$borderBottom = '╚' + ('═' * $width) + '╝'

$titleText = "CLEAR-TEMP-FOLDERS  $modeLabel$version"
$titlePadding = ' ' * [Math]::Max(0, $width - $titleText.Length - 2)
$titleLine = "║  $titleText$titlePadding║"

$daysText = "Cleaning TEMP folders older than $DaysOld day(s)..."
$daysPadding = ' ' * [Math]::Max(0, $width - $daysText.Length - 2)
$daysLine = "║  $daysText$daysPadding║"

$targetText = if ($ExcludeUserTemp) { 'Windows\Temp only' } else { 'System + User TEMP folders' }
$targetFull = "Target: $targetText"
$targetPadding = ' ' * [Math]::Max(0, $width - $targetFull.Length - 2)
$targetLine = "║  $targetFull$targetPadding║"

Write-ColorOutput ''
Write-ColorOutput $borderTop -ForegroundColor Cyan
Write-ColorOutput $titleLine -ForegroundColor Cyan
Write-ColorOutput $borderMiddle -ForegroundColor Cyan
Write-ColorOutput $daysLine -ForegroundColor Gray
Write-ColorOutput $targetLine -ForegroundColor Gray
Write-ColorOutput $borderBottom -ForegroundColor Cyan
Write-ColorOutput ''
#endregion

#region ── Main Cleanup Logic ─────────────────────────────────────────────────
$thresholdDate = (Get-Date).AddDays(-$DaysOld)
$windowsTemp = "$env:windir\Temp"
$userTempRoot = "$env:USERPROFILE\AppData\Local\Temp"

$targetDirs = @()
if (Test-Path -Path $windowsTemp -PathType Container) {
    $targetDirs += $windowsTemp
}

if (-not $ExcludeUserTemp) {
    $userTemps = Get-ChildItem -Path "$env:SystemDrive\Users" -Directory -Force -ErrorAction SilentlyContinue |
                 Where-Object { $_.Name -notmatch '^(Public|Default|Default User|All Users)$' } |
                 ForEach-Object { "$($_.FullName)\AppData\Local\Temp" } |
                 Where-Object { Test-Path -Path $_ -PathType Container }
    $targetDirs += $userTemps
}

Write-LogMessage "Starting cleanup: DaysOld=$DaysOld, DryRun=$DryRun, Targets=$($targetDirs.Count)" -Level 'INFO'

foreach ($tempPath in $targetDirs) {
    Write-ColorOutput "`n[SCAN] Processing: $tempPath" -ForegroundColor Cyan -NoLog:$Quiet
    
    $files = Get-FilesRecursive -Path $tempPath -MaxDepth $MaxDepth -OlderThan $thresholdDate -ExcludePatterns $ExcludePatterns
    
    foreach ($file in $files) {
        $relativePath = Get-RelativePath -FullPath $file.FullName -BasePath $tempPath
        $size = Format-FileSize -Bytes $file.Length
        
        if ($DryRun -or $WhatIfPreference) {
            if (-not $Quiet) {
                Write-ColorOutput "  [DRY] Would delete: $relativePath ($size)" -ForegroundColor Yellow
            }
            $script:cntFiles++
            $script:totalBytes += $file.Length
        }
        else {
            if ($PSCmdlet.ShouldProcess($file.FullName, 'Delete file')) {
                try {
                    Remove-Item -Path $file.FullName -Force -ErrorAction Stop
                    if (-not $Quiet) {
                        Write-ColorOutput "  [DEL] Deleted: $relativePath ($size)" -ForegroundColor Green
                    }
                    $script:cntFiles++
                    $script:totalBytes += $file.Length
                    Write-LogMessage "Deleted: $($file.FullName) ($size)" -Level 'INFO'
                }
                catch [System.IO.IOException] {
                    # File locked/in-use - expected for some system temp files
                    if (-not $Quiet) {
                        Write-ColorOutput "  [SKIP] In use: $relativePath" -ForegroundColor DarkYellow
                    }
                    $script:cntSkipped++
                    Write-LogMessage "Skipped (in use): $($file.FullName)" -Level 'WARNING'
                }
                catch [System.UnauthorizedAccessException] {
                    # Access denied - expected for protected files
                    if (-not $Quiet) {
                        Write-ColorOutput "  [SKIP] Access denied: $relativePath" -ForegroundColor DarkYellow
                    }
                    $script:cntSkipped++
                    Write-LogMessage "Skipped (access denied): $($file.FullName)" -Level 'WARNING'
                }
                catch {
                    # Unexpected error
                    if (-not $Quiet) {
                        Write-ColorOutput "  [ERR] Failed: $relativePath - $($_.Exception.Message)" -ForegroundColor Red
                    }
                    $script:cntSkipped++
                    Write-LogMessage "Failed to delete: $($file.FullName) - $($_.Exception.Message)" -Level 'ERROR'
                }
            }
            else {
                $script:cntSkipped++
            }
        }
    }
    
    # Remove empty directories (deepest first)
    $emptyDirs = Get-DirectoriesRecursive -Path $tempPath -MaxDepth $MaxDepth |
                 Where-Object { 
                     # ✅ FIX: Use @() to ensure .Count works on single items or $null
                     $items = Get-ChildItem -Path $_.FullName -Force -ErrorAction SilentlyContinue
                     $null -eq $items -or @($items).Count -eq 0
                 }
    
    foreach ($dir in $emptyDirs) {
        $relativePath = Get-RelativePath -FullPath $dir.FullName -BasePath $tempPath
        
        if ($DryRun -or $WhatIfPreference) {
            if (-not $Quiet) {
                Write-ColorOutput "  [DRY] Would remove empty dir: $relativePath" -ForegroundColor Yellow
            }
            $script:cntDirs++
        }
        else {
            if ($PSCmdlet.ShouldProcess($dir.FullName, 'Remove empty directory')) {
                try {
                    Remove-Item -Path $dir.FullName -Force -ErrorAction Stop
                    if (-not $Quiet) {
                        Write-ColorOutput "  [DEL] Removed empty dir: $relativePath" -ForegroundColor Green
                    }
                    $script:cntDirs++
                    Write-LogMessage "Removed empty directory: $($dir.FullName)" -Level 'INFO'
                }
                catch [System.IO.IOException] {
                    if (-not $Quiet) {
                        Write-ColorOutput "  [SKIP] Dir in use: $relativePath" -ForegroundColor DarkYellow
                    }
                    $script:cntDirsSkipped++
                    Write-LogMessage "Skipped dir (in use): $($dir.FullName)" -Level 'WARNING'
                }
                catch [System.UnauthorizedAccessException] {
                    if (-not $Quiet) {
                        Write-ColorOutput "  [SKIP] Access denied: $relativePath" -ForegroundColor DarkYellow
                    }
                    $script:cntDirsSkipped++
                    Write-LogMessage "Skipped dir (access denied): $($dir.FullName)" -Level 'WARNING'
                }
                catch {
                    if (-not $Quiet) {
                        Write-ColorOutput "  [ERR] Failed to remove dir: $relativePath - $($_.Exception.Message)" -ForegroundColor Red
                    }
                    $script:cntDirsSkipped++
                    Write-LogMessage "Failed to remove directory: $($dir.FullName) - $($_.Exception.Message)" -Level 'ERROR'
                }
            }
            else {
                $script:cntDirsSkipped++
            }
        }
    }
}
#endregion

#region ── Summary Report ─────────────────────────────────────────────────────
$scriptDuration = (Get-Date) - $script:scriptStart

Write-ColorOutput ''
Write-ColorOutput ('─' * 70) -ForegroundColor Gray
Write-ColorOutput '  CLEANUP SUMMARY' -ForegroundColor Cyan
Write-ColorOutput ('─' * 70) -ForegroundColor Gray

$summaryLines = @(
    "  Files processed     : $($script:cntFiles)"
    "  Directories removed : $($script:cntDirs)"
    "  Items skipped       : $($script:cntSkipped + $script:cntDirsSkipped)"
    "  Patterns excluded   : $($script:cntExcluded)"
    "  Total space freed   : $(Format-FileSize -Bytes $script:totalBytes)"
    "  Execution time      : $($scriptDuration.ToString('hh\:mm\:ss'))"
    "  Mode                : $(if ($DryRun) { 'DRY RUN (no changes made)' } else { 'LIVE (changes applied)' })"
)

foreach ($line in $summaryLines) {
    Write-ColorOutput $line -ForegroundColor Gray
}

Write-ColorOutput ('─' * 70) -ForegroundColor Gray
Write-ColorOutput ''

if ($script:LogPath) {
    Write-ColorOutput "  Log file: $($script:LogPath)" -ForegroundColor Gray
    Write-LogMessage "Cleanup complete: Files=$($script:cntFiles), Dirs=$($script:cntDirs), Bytes=$($script:totalBytes), Duration=$($scriptDuration)" -Level 'INFO'
}

Write-ColorOutput ''
#endregion
