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
    Version   : 2.1.0
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
    <#
    .SYNOPSIS
        Formats byte count into human-readable size
    #>
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
    <#
    .SYNOPSIS
        Writes colored output to console and optionally to log
    #>
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
    
    if (-not $NoLog -and $script:LogPath) {
        Write-LogMessage -Message $Message -Level 'OUTPUT'
    }
}

function Write-LogMessage {
    <#
    .SYNOPSIS
        Writes timestamped message to log file
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string] $Message,
        
        [Parameter(Mandatory = $false)]
        [ValidateSet('INFO', 'WARNING', 'ERROR', 'OUTPUT')]
        [string] $Level = 'INFO'
    )
    
    if (-not $script:LogPath) { return }
    
    try {
        $timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
        $logLine = "[$timestamp] [$Level] $Message"
        
        # Ensure log directory exists
        $logDir = Split-Path -Path $script:LogPath -Parent
        if ($logDir -and -not (Test-Path -Path $logDir -PathType Container)) {
            $null = New-Item -ItemType Directory -Path $logDir -Force -ErrorAction Stop
        }
        
        $logLine | Out-File -FilePath $script:LogPath -Append -Encoding UTF8 -ErrorAction Stop
    } catch {
        # Silently ignore logging errors to not interrupt cleanup
        Write-Verbose "Failed to write to log: $_"
    }
}

function Test-PathExcluded {
    <#
    .SYNOPSIS
        Tests if a file path matches any exclusion pattern
    #>
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
    <#
    .SYNOPSIS
        Returns relative path from base path
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [string] $FullPath,
        
        [Parameter(Mandatory)]
        [string] $BasePath
    )
    
    # Normalize paths
    $FullPath = $FullPath.TrimEnd('\')
    $BasePath = $BasePath.TrimEnd('\')
    
    if ($FullPath.StartsWith($BasePath, [StringComparison]::OrdinalIgnoreCase)) {
        $relative = $FullPath.Substring($BasePath.Length).TrimStart('\')
        return if ($relative) { $relative } else { '.' }
    }
    
    return $FullPath
}

function Test-IsJunctionOrSymlink {
    <#
    .SYNOPSIS
        Tests if path is a junction point or symbolic link
    #>
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
    <#
    .SYNOPSIS
        Gets files recursively with optional depth limit
    #>
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
    
    # Only add -Depth if supported AND MaxDepth > 0
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
    <#
    .SYNOPSIS
        Gets directories recursively with optional depth limit, sorted deepest-first
    #>
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
    $script:LogPath = $LogPath  # Store in script scope
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

# Warn if MaxDepth specified but not supported
if ($MaxDepth -gt 0 -and -not $script:supportsDepth) {
    Write-ColorOutput "[WARNING] -MaxDepth requires PowerShell 5.1+. Will scan all depths." -ForegroundColor Yellow
    Write-LogMessage "MaxDepth not supported in PS $($PSVersionTable.PSVersion), ignoring" -Level 'WARNING'
}
#endregion

#region ── Header Display ─────────────────────────────────────────────────────
$modeLabel = if ($DryRun) { '  ·  DRY RUN - no files will be deleted  ' } else { '' }
$version   = 'v2.1.0'
$width     = 70

Write-ColorOutput ''
Write-ColorOutput ('╔' + ('═' * $width) + '╗') -ForegroundColor Cyan
Write-ColorOutput ('║  CLEAR-TEMP-FOLDERS  {0}{1}
