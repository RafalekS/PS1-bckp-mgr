#Requires -Version 5.1

<#
.SYNOPSIS
    Shared backup utilities for file and Windows settings backups
    
.DESCRIPTION
    Common functions for database operations, compression, logging, and utilities
    used by both Main.ps1 and WinBackup.ps1
    
.NOTES
    Version: 1.0
    Used by: Main.ps1, WinBackup.ps1
#>

import-Module CredentialManager

# Load SQLite assembly
Add-Type -Path "db\System.Data.SQLite.dll"

# Global Script Variables
# These variables maintain state across function calls during backup operations
#
# Logging State:
#   $script:LogLevel - Current logging verbosity (DEBUG, INFO, WARNING, ERROR)
#   $script:LogFilePath - Path to current log file
#
# Database Connection Pool:
#   $script:DbConnection - Pooled SQLite database connection (reused across operations)
#   $script:DbPath - Path to backup history database
#
# Progress Tracking:
#   $script:BackupStartTime - Timestamp when backup started (for ETA calculation)
#
# File System Cache:
#   $script:FileSystemCache - Cached Get-ChildItem results (performance optimization)
#
# Backup Speed Tracking (Issue #17):
#   $script:BackupSpeedStats - Hashtable tracking bytes processed and file count for speed calculations
#
$script:LogFilePath = $null
$script:BackupSpeedStats = @{
    StartTime = $null
    BytesProcessed = 0
    FileCount = 0
}

#region Logging Functions

function Initialize-Logging {
    param (
        [string]$LogLevel,
        [string]$LogFilePath,
        [string]$LogFormat = "Text"  # "Text" or "JSON"
    )

    $script:LogLevel = $LogLevel
    $script:LogFilePath = $LogFilePath
    $script:LogFormat = $LogFormat

    $LogFolder = Split-Path $LogFilePath -Parent
    if (-not (Test-Path $LogFolder)) {
        New-Item -ItemType Directory -Path $LogFolder -Force | Out-Null
    }
    Write-Log "Logging initialized (Level: $LogLevel, Format: $LogFormat)" -Level "INFO"
}

function Write-Log {
    param (
        [Parameter(Mandatory=$true)]
        [string]$Message,
        [ValidateSet("DEBUG", "INFO", "WARNING", "ERROR")]
        [string]$Level = "INFO",
        [hashtable]$Context = @{}
    )

    # If logging not initialized yet, don't log anything
    if (-not (Get-Variable -Name "LogLevel" -Scope Script -ErrorAction SilentlyContinue)) {
        return
    }

    # Define log level hierarchy
    $logLevels = @{
        "DEBUG" = 0
        "INFO" = 1
        "WARNING" = 2
        "ERROR" = 3
    }

    # Only log if the message level is equal to or higher than the global log level
    if ($logLevels[$Level] -ge $logLevels[$script:LogLevel]) {

        # Determine format (default to Text if not set)
        $format = if ($script:LogFormat) { $script:LogFormat } else { "Text" }

        if ($format -eq "JSON") {
            # JSON format
            $logEntry = @{
                timestamp = (Get-Date).ToString("o")  # ISO 8601 format
                level = $Level
                message = $Message
                process_id = $PID
                user = $env:USERNAME
            }

            # Add context if provided
            if ($Context.Count -gt 0) {
                $logEntry.context = $Context
            }

            $logMessage = $logEntry | ConvertTo-Json -Compress

            # Console output (pretty print for readability)
            if ($Level -ne "DEBUG" -or $script:LogLevel -eq "DEBUG") {
                $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
                Write-Host "$timestamp|$Level|$Message"
            }
        }
        else {
            # Text format (pipe-delimited)
            $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
            $logMessage = "$timestamp|$Level|$Message"

            # Output to console for INFO and above, or if DEBUG is explicitly set
            if ($Level -ne "DEBUG" -or $script:LogLevel -eq "DEBUG") {
                Write-Host $logMessage
            }
        }

        # Always write to log file (use Out-File for better flushing)
        if ($script:LogFilePath) {
            try {
                $logMessage | Out-File -FilePath $script:LogFilePath -Append -Encoding UTF8 -ErrorAction Stop
            }
            catch {
                Write-Host "[LOG ERROR] Failed to write to log: $_" -ForegroundColor Red
            }
        }
        else {
            # If LogFilePath is not set, show warning once
            if (-not $script:LogPathWarningShown) {
                Write-Host "[LOG WARNING] LogFilePath not initialized - logs only to console" -ForegroundColor Yellow
                $script:LogPathWarningShown = $true
            }
        }
    }
}

function Flush-Log {
    <#
    .SYNOPSIS
        Forces log file to flush to disk

    .DESCRIPTION
        Ensures all buffered log entries are written to disk immediately.
        Call this at critical points like backup completion.
    #>
    if ($script:LogFilePath -and (Test-Path $script:LogFilePath)) {
        # Touch the file to force filesystem flush
        (Get-Item $script:LogFilePath).LastWriteTime = Get-Date
    }
}

function Write-AuditLog {
    <#
    .SYNOPSIS
        Writes audit trail entries for backup operations

    .DESCRIPTION
        Creates separate audit log tracking all backup operations with user, action, and result.
        Audit logs are kept separate from regular logs with longer retention.

    .PARAMETER Action
        The action being audited (e.g., BACKUP_START, RESTORE_COMPLETE)

    .PARAMETER User
        User performing the action (defaults to current user)

    .PARAMETER Target
        Target of the action (e.g., backup type, file path)

    .PARAMETER Result
        Result of the action (e.g., STARTED, SUCCESS, FAILED)

    .PARAMETER AuditLogPath
        Path to audit log file (defaults to log\audit.log)

    .EXAMPLE
        Write-AuditLog -Action "BACKUP_START" -User $env:USERNAME -Target "Full-HomeNet" -Result "STARTED"
    #>
    param(
        [Parameter(Mandatory=$true)]
        [string]$Action,

        [string]$User = $env:USERNAME,

        [Parameter(Mandatory=$true)]
        [string]$Target,

        [Parameter(Mandatory=$true)]
        [string]$Result,

        [string]$AuditLogPath = "log\audit.log"
    )

    try {
        # Ensure audit log directory exists
        $auditDir = Split-Path -Path $AuditLogPath -Parent
        if ($auditDir -and -not (Test-Path $auditDir)) {
            New-Item -ItemType Directory -Path $auditDir -Force | Out-Null
        }

        # Create audit entry with timestamp
        $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
        $auditEntry = "$timestamp|$Action|$User|$Target|$Result"

        # Write to audit log
        Add-Content -Path $AuditLogPath -Value $auditEntry

        # Also log to debug for development
        Write-Log "AUDIT: $Action | $Target | $Result" -Level "DEBUG"
    }
    catch {
        Write-Log "Failed to write audit log: $_" -Level "WARNING"
    }
}

#endregion

#region Error Handling

function Handle-Error {
    <#
    .SYNOPSIS
        Centralized error handling function

    .DESCRIPTION
        Provides standardized error logging, optional notifications, and debug stack traces

    .PARAMETER ErrorRecord
        The error record from catch block ($_)

    .PARAMETER Operation
        Name of the operation that failed

    .PARAMETER SendNotification
        Whether to send Gotify notification for this error

    .PARAMETER Config
        Configuration object for notifications

    .EXAMPLE
        catch {
            Handle-Error -ErrorRecord $_ -Operation "Backup-Files"
            return $false
        }
    #>
    param(
        [Parameter(Mandatory=$true)]
        [System.Management.Automation.ErrorRecord]$ErrorRecord,

        [Parameter(Mandatory=$true)]
        [string]$Operation,

        [switch]$SendNotification,

        [object]$Config = $null
    )

    # Log the error
    $errorMessage = "$Operation failed: $($ErrorRecord.Exception.Message)"
    Write-Log $errorMessage -Level "ERROR"

    # Log stack trace in DEBUG mode
    if ($script:LogLevel -eq "DEBUG") {
        Write-Log "Stack trace: $($ErrorRecord.ScriptStackTrace)" -Level "DEBUG"
        Write-Log "Error details: $($ErrorRecord | Out-String)" -Level "DEBUG"
    }

    # Send notification if requested
    if ($SendNotification -and $Config -and $Config.Notifications.Gotify) {
        try {
            Send-GotifyNotification -Title "Backup Error: $Operation" -Message $errorMessage -Priority 7 -Config $Config
        }
        catch {
            Write-Log "Failed to send error notification: $_" -Level "WARNING"
        }
    }

    # Return error details for caller
    return @{
        Success = $false
        Operation = $Operation
        ErrorMessage = $ErrorRecord.Exception.Message
        ErrorType = $ErrorRecord.Exception.GetType().FullName
    }
}

#endregion

#region Validation Functions

function Test-IsReservedDeviceName {
    <#
    .SYNOPSIS
        Checks if a filename is a reserved Windows device name
    .DESCRIPTION
        Windows reserves certain names like NUL, CON, PRN, AUX, COM1-9, LPT1-9
        These can cause issues when PowerShell tries to access them as files
    #>
    param(
        [string]$Path
    )

    $fileName = Split-Path $Path -Leaf
    $baseName = [System.IO.Path]::GetFileNameWithoutExtension($fileName)

    # Reserved device names (case-insensitive)
    $reservedNames = @(
        'CON', 'PRN', 'AUX', 'NUL',
        'COM1', 'COM2', 'COM3', 'COM4', 'COM5', 'COM6', 'COM7', 'COM8', 'COM9',
        'LPT1', 'LPT2', 'LPT3', 'LPT4', 'LPT5', 'LPT6', 'LPT7', 'LPT8', 'LPT9'
    )

    foreach ($reserved in $reservedNames) {
        if ($baseName -ieq $reserved) {
            return $true
        }
    }

    return $false
}

function Test-PathExcluded {
    <#
    .SYNOPSIS
        Checks if a path should be excluded from backup based on GlobalExclusions config
    .DESCRIPTION
        Tests path against exclusion patterns (both exact paths and wildcards)
    #>
    param(
        [string]$Path,
        [object]$Config
    )

    # Check for reserved Windows device names first
    if (Test-IsReservedDeviceName -Path $Path) {
        Write-Log "Excluded (reserved device name): $Path" -Level "WARNING"
        return $true
    }

    if (-not $Config.GlobalExclusions) {
        return $false
    }

    # Normalize the path for comparison
    $normalizedPath = $Path.TrimEnd('\', '/')

    # Check folder exclusions
    if ($Config.GlobalExclusions.Folders) {
        foreach ($exclusion in $Config.GlobalExclusions.Folders) {
            # Exact path match
            if ($normalizedPath -like $exclusion.Replace('/', '\')) {
                Write-Log "Excluded (folder match): $Path" -Level "DEBUG"
                return $true
            }

            # Wildcard pattern match
            if ($exclusion -like '*\**' -or $exclusion -like '*') {
                $pattern = $exclusion.Replace('/', '\')
                if ($normalizedPath -like $pattern) {
                    Write-Log "Excluded (folder pattern): $Path" -Level "DEBUG"
                    return $true
                }
            }

            # Check if path is inside an excluded folder
            $exclusionNormalized = $exclusion.Replace('/', '\').TrimEnd('\')
            if ($normalizedPath -like "$exclusionNormalized\*") {
                Write-Log "Excluded (inside excluded folder): $Path" -Level "DEBUG"
                return $true
            }
        }
    }

    # Check file exclusions (only for files, not directories)
    if ($Config.GlobalExclusions.Files -and (Test-Path $Path -PathType Leaf -ErrorAction SilentlyContinue)) {
        $fileName = Split-Path $Path -Leaf

        foreach ($exclusion in $Config.GlobalExclusions.Files) {
            if ($fileName -like $exclusion) {
                Write-Log "Excluded (file pattern): $Path" -Level "DEBUG"
                return $true
            }
        }
    }

    return $false
}

function Test-BackupItemsExist {
    param(
        [array]$BackupItems,
        [object]$Config
    )

    Write-Log "Validating backup paths..." -Level "INFO"

    $missingItems = @()
    $totalPaths = 0
    $existingPaths = 0

    foreach ($item in $BackupItems) {
        $paths = $Config.BackupItems.$item

        if (-not $paths) {
            Write-Log "Warning: Backup item '$item' not found in configuration" -Level "WARNING"
            continue
        }

        foreach ($path in $paths) {
            $totalPaths++

            # Expand environment variables in path
            $expandedPath = $ExecutionContext.InvokeCommand.ExpandString($path)

            if (-not (Test-Path $expandedPath -ErrorAction SilentlyContinue)) {
                $missingItems += $path
                Write-Log "Missing: $path" -Level "DEBUG"
            } else {
                $existingPaths++
            }
        }
    }

    # Summary
    if ($missingItems.Count -gt 0) {
        Write-Log "Path Validation: $existingPaths/$totalPaths paths exist" -Level "WARNING"
        Write-Log "WARNING: $($missingItems.Count) paths will be skipped (not found):" -Level "WARNING"

        # Show ALL missing items (not just 10)
        foreach ($item in $missingItems) {
            Write-Log "  - $item" -Level "WARNING"
        }

        Write-Log "Backup will continue with existing paths only" -Level "INFO"
    } else {
        Write-Log "Path Validation: All $totalPaths paths exist ✓" -Level "INFO"
    }

    return $true  # Always return true - we only warn, never fail
}

#endregion

#region Windows Settings Export Functions

function Backup-WindowsCredentials {
    param (
        [string]$DestinationPath
    )
    
    Write-Log "Starting Windows credentials backup" -Level "INFO"
    
    # Validate destination path
    if ([string]::IsNullOrWhiteSpace($DestinationPath)) {
        Write-Log "DestinationPath is empty or null. Cannot create credential backup." -Level "ERROR"
        return
    }
    
    # Ensure destination directory exists
    if (-not (Test-Path $DestinationPath)) {
        try {
            New-Item -ItemType Directory -Path $DestinationPath -Force | Out-Null
            Write-Log "Created credential backup directory: $DestinationPath" -Level "DEBUG"
        }
        catch {
            Handle-Error -ErrorRecord $_ -Operation "Create-CredentialBackupDirectory"
            return $false
        }
    }
    
    $credFile = Join-Path $DestinationPath "Win_credentials.txt"
    Write-Log "Credential file path: $credFile" -Level "DEBUG"
    
    try {
        # First try to import the CredentialManager module if available
        $moduleAvailable = $false
        try {
            Import-Module CredentialManager -ErrorAction Stop
            $moduleAvailable = $true
            Write-Log "CredentialManager module imported successfully" -Level "WARNING"
        }
        catch {
            Write-Log "CredentialManager module not available: $_" -Level "WARNING"
        }
        
        if ($moduleAvailable -and (Get-Command Get-StoredCredential -ErrorAction SilentlyContinue)) {
            Write-Log "Attempting to export stored credentials using CredentialManager module" -Level "WARNING"
            
            $credentials = Get-StoredCredential -ErrorAction SilentlyContinue
            
            if ($credentials) {
                $credentialCount = 0
                $credentials | Where-Object { $_.UserName -and $_.TargetName } | ForEach-Object {
                    $credentialCount++
                    $output = "Target: $($_.TargetName)`nUsername: $($_.UserName)`nType: $($_.Type)`nPersistence: $($_.Persistence)`nPassword: [PROTECTED - Use Get-StoredCredential to retrieve]`n`n"
                    Add-Content -Path $credFile -Value $output -Encoding UTF8
                }
                
                if ($credentialCount -gt 0) {
                    Write-Log "Exported $credentialCount stored credentials to $credFile" -Level "INFO"
                } else {
                    Write-Log "No stored credentials found to export" -Level "INFO"
                    "No stored credentials found on $(Get-Date)" | Out-File -FilePath $credFile -Encoding UTF8
                }
            } else {
                Write-Log "No stored credentials found to export" -Level "INFO"
                "No stored credentials found on $(Get-Date)" | Out-File -FilePath $credFile -Encoding UTF8
            }
        } else {
            # Fallback to cmdkey method (doesn't require CredentialManager module)
            Write-Log "Using cmdkey fallback method for credential export" -Level "INFO"
            
            # Validate that Export-CredentialManager function exists
            if (Get-Command Export-CredentialManager -ErrorAction SilentlyContinue) {
                $result = Export-CredentialManager -OutputPath $credFile
                if (-not $result) {
                    Write-Log "Export-CredentialManager returned false" -Level "WARNING"
                    "Failed to export credentials using cmdkey on $(Get-Date)" | Out-File -FilePath $credFile -Encoding UTF8
                }
            } else {
                Write-Log "Export-CredentialManager function not found. Using direct cmdkey approach." -Level "WARNING"
                
                # Direct cmdkey approach as final fallback
                try {
                    $creds = & cmdkey /list 2>$null | Where-Object { $_ -match "Target:" }
                    if ($creds) {
                        $creds | Out-File -FilePath $credFile -Encoding UTF8
                        Write-Log "Exported credential manager list using direct cmdkey to: $credFile" -Level "INFO"
                    } else {
                        "No credentials found using cmdkey on $(Get-Date)" | Out-File -FilePath $credFile -Encoding UTF8
                        Write-Log "No credentials found using cmdkey" -Level "INFO"
                    }
                }
                catch {
                    Write-Log "Direct cmdkey approach failed: $_" -Level "ERROR"
                    "Error occurred during direct cmdkey export on $(Get-Date): $_" | Out-File -FilePath $credFile -Encoding UTF8
                }
            }
        }
    }
    catch {
        Handle-Error -ErrorRecord $_ -Operation "Export-Credentials"
        "Error occurred during credential export on $(Get-Date): $_" | Out-File -FilePath $credFile -Encoding UTF8
        return $false
    }

    Write-Log "Credential backup completed successfully" -Level "INFO"
    return $true
}

function Export-PowerSettings {
    param([string]$OutputPath)
    
    try {
        $powerDir = Split-Path $OutputPath -Parent
        
        # Export power schemes list
        $schemesFile = Join-Path $powerDir "PowerSchemes.txt"
        & powercfg /list | Out-File -FilePath $schemesFile -Encoding UTF8
        
        # Export current power configuration
        $configFile = Join-Path $powerDir "CurrentPowerConfig.txt"
        & powercfg /query | Out-File -FilePath $configFile -Encoding UTF8
        
        # Export sleep study (if available)
        try {
            $sleepFile = Join-Path $powerDir "SleepStudy.html"
            & powercfg /sleepstudy /output $sleepFile 2>$null
        } catch {
            Write-Log "Sleep study not available or failed" -Level "DEBUG"
        }
        
        Write-Log "Exported power settings to: $powerDir" -Level "INFO"
        return $true
    }
    catch {
        Handle-Error -ErrorRecord $_ -Operation "Export-PowerSettings"
        return $false
    }
}

function Export-ScheduledTasks {
    param([string]$OutputPath)

    try {
        # Get user-created tasks (exclude Microsoft built-in tasks)
        $tasks = Get-ScheduledTask | Where-Object {
            $_.Author -notlike "Microsoft*" -and
            $_.Author -ne "" -and
            $_.TaskPath -notlike "\Microsoft\*"
        } | Select-Object TaskName, State, Author, Description, TaskPath

        $tasks | Export-Csv -Path $OutputPath -NoTypeInformation -Encoding UTF8
        Write-Log "Exported scheduled tasks to: $OutputPath" -Level "INFO"
        return $true
    }
    catch {
        Handle-Error -ErrorRecord $_ -Operation "Export-ScheduledTasks"
        return $false
    }
}

function Get-EnvironmentVariables-User {
    param([string]$OutputPath)
    
    try {
        $userVars = @{}
        $envVars = Get-ChildItem Env: | Where-Object Name -notlike "TEMP*" | Where-Object Name -notlike "TMP*"
        
        foreach ($var in $envVars) {
            $userVars[$var.Name] = $var.Value
        }
        
        $userVars | ConvertTo-Json -Depth 3 | Out-File -FilePath $OutputPath -Encoding UTF8
        Write-Log "Exported user environment variables to: $OutputPath" -Level "INFO"
        return $true
    }
    catch {
        Handle-Error -ErrorRecord $_ -Operation "Export-UserEnvironmentVariables"
        return $false
    }
}

function Get-EnvironmentVariables-Machine {
    param([string]$OutputPath)

    try {
        $machineVars = [Environment]::GetEnvironmentVariables([EnvironmentVariableTarget]::Machine)
        $machineVars | ConvertTo-Json -Depth 3 | Out-File -FilePath $OutputPath -Encoding UTF8
        Write-Log "Exported system environment variables to: $OutputPath" -Level "INFO"
        return $true
    }
    catch {
        Handle-Error -ErrorRecord $_ -Operation "Export-SystemEnvironmentVariables"
        return $false
    }
}

function Export-WindowsFeatures {
    param([string]$OutputPath)

    try {
        $features = Get-WindowsOptionalFeature -Online | Select-Object FeatureName, State, Description
        $features | Export-Csv -Path $OutputPath -NoTypeInformation -Encoding UTF8
        Write-Log "Exported Windows features to: $OutputPath" -Level "INFO"
        return $true
    }
    catch {
        Handle-Error -ErrorRecord $_ -Operation "Export-WindowsFeatures"
        return $false
    }
}

function Export-CriticalEvents {
    param([string]$OutputPath)
    
    try {
        # Export system critical/error/warning events from last 30 days
        $events = Get-WinEvent -FilterHashtable @{
            LogName='System'
            Level=1,2,3  # Critical, Error, Warning
            StartTime=(Get-Date).AddDays(-30)
        } -MaxEvents 1000 -ErrorAction SilentlyContinue |
        Select-Object TimeCreated, Id, LevelDisplayName, LogName, Message
        
        $events | Export-Csv -Path $OutputPath -NoTypeInformation -Encoding UTF8
        Write-Log "Exported critical events to: $OutputPath" -Level "INFO"
        return $true
    }
    catch {
        Handle-Error -ErrorRecord $_ -Operation "Export-CriticalEvents"
        return $false
    }
}

function Export-ServiceSettings {
    param([string]$OutputPath)

    try {
        # Get services with non-standard startup types or custom configurations
        $services = Get-WmiObject Win32_Service | Where-Object {
            $_.StartMode -notin @('Auto','Manual','Disabled') -or
            $_.StartName -notlike "LocalSystem*" -or
            $_.PathName -notlike "C:\Windows\*"
        } | Select-Object Name, StartMode, State, StartName, PathName, Description

        $services | Export-Csv -Path $OutputPath -NoTypeInformation -Encoding UTF8
        Write-Log "Exported service settings to: $OutputPath" -Level "INFO"
        return $true
    }
    catch {
        Handle-Error -ErrorRecord $_ -Operation "Export-ServiceSettings"
        return $false
    }
}

function Export-WSLDistributions {
    param([string]$OutputPath)

    try {
        # Check if WSL is available
        if (Get-Command wsl -ErrorAction SilentlyContinue) {
            wsl --list --verbose | Out-File -FilePath $OutputPath -Encoding UTF8
            Write-Log "Exported WSL distributions to: $OutputPath" -Level "INFO"
            return $true
        } else {
            Write-Log "WSL not available on this system" -Level "WARNING"
            return $false
        }
    }
    catch {
        Handle-Error -ErrorRecord $_ -Operation "Export-WSLDistributions"
        return $false
    }
}

function Export-DefenderSettings {
    param([string]$OutputPath)

    try {
        $preferences = Get-MpPreference | Select-Object -Property *
        $preferences | ConvertTo-Json -Depth 3 | Out-File -FilePath $OutputPath -Encoding UTF8
        Write-Log "Exported Windows Defender settings to: $OutputPath" -Level "INFO"
        return $true
    }
    catch {
        Handle-Error -ErrorRecord $_ -Operation "Export-DefenderSettings"
        return $false
    }
}

function Export-NetworkDrives {
    param([string]$OutputPath)

    try {
        $drives = Get-WmiObject Win32_MappedLogicalDisk |
                 Select-Object DeviceID, ProviderName, Size, FreeSpace, Description
        $drives | Export-Csv -Path $OutputPath -NoTypeInformation -Encoding UTF8
        Write-Log "Exported mapped network drives to: $OutputPath" -Level "INFO"
        return $true
    }
    catch {
        Handle-Error -ErrorRecord $_ -Operation "Export-NetworkDrives"
        return $false
    }
}

function Export-CredentialManager {
    param([string]$OutputPath)
    
    try {
        # Export credential manager entries (names only for security)
        $creds = & cmdkey /list 2>$null | Where-Object { $_ -match "Target:" }
        $creds | Out-File -FilePath $OutputPath -Encoding UTF8
        Write-Log "Exported credential manager list to: $OutputPath" -Level "INFO"
        return $true
    }
    catch {
        Handle-Error -ErrorRecord $_ -Operation "Export-CredentialManager"
        return $false
    }
}

function Export-PersonalCertificates {
    param([string]$OutputPath)

    try {
        $certs = Get-ChildItem Cert:\CurrentUser\My |
                Select-Object Subject, Issuer, NotBefore, NotAfter, Thumbprint, FriendlyName
        $certs | Export-Csv -Path $OutputPath -NoTypeInformation -Encoding UTF8
        Write-Log "Exported personal certificates to: $OutputPath" -Level "INFO"
        return $true
    }
    catch {
        Handle-Error -ErrorRecord $_ -Operation "Export-PersonalCertificates"
        return $false
    }
}

function Export-InstalledSoftware {
    param([string]$OutputPath)

    try {
        if (Get-Command winget -ErrorAction SilentlyContinue) {
            winget export --output $OutputPath 2>$null
            if (Test-Path $OutputPath) {
                Write-Log "Exported installed software to: $OutputPath" -Level "INFO"
                return $true
            }
        }
        Write-Log "Winget not available or export failed" -Level "WARNING"
        return $false
    }
    catch {
        Handle-Error -ErrorRecord $_ -Operation "Export-InstalledSoftware"
        return $false
    }
}

<# function Export-PythonPackages {
    param([string]$OutputPath)
    
    try {
        if (Get-Command pip -ErrorAction SilentlyContinue) {
            pip freeze | Out-File -FilePath $OutputPath -Encoding UTF8
            Write-Log "Exported Python packages to: $OutputPath" -Level "INFO"
            return $true
        } else {
            Write-Log "Python/pip not available" -Level "WARNING"
            return $false
        }
    }
    catch {
        Write-Log "Failed to export Python packages: $_" -Level "ERROR"
        return $false
    }
} #>

function Export-ChocolateyPackages {
    param([string]$OutputPath)
    
    try {
        if (Get-Command choco -ErrorAction SilentlyContinue) {
            choco list | Out-File -FilePath $OutputPath -Encoding UTF8
            Write-Log "Exported Chocolatey packages to: $OutputPath" -Level "INFO"
            return $true
        } else {
            Write-Log "Chocolatey not available" -Level "WARNING"
            return $false
        }
    }
    catch {
        Write-Log "Failed to export Chocolatey packages: $_" -Level "ERROR"
        return $false
    }
}

function Export-CargoPackages {
    param([string]$OutputPath)
    
    try {
        if (Get-Command cargo -ErrorAction SilentlyContinue) {
            cargo install --list | Out-File -FilePath $OutputPath -Encoding UTF8
            Write-Log "Exported Cargo packages to: $OutputPath" -Level "INFO"
            return $true
        } else {
            Write-Log "Rust/Cargo not available (skipped)" -Level "DEBUG"
            return $false
        }
    }
    catch {
        Write-Log "Failed to export Cargo packages: $_" -Level "ERROR"
        return $false
    }
}

#endregion

#region Database Functions

# Database connection pooling
$script:DbConnection = $null
$script:DbPath = Join-Path $PSScriptRoot "db/backup_history.db"

function Get-DatabaseConnection {
    <#
    .SYNOPSIS
        Gets or creates a pooled database connection
    .DESCRIPTION
        Returns an open SQLite connection. Creates new connection if one doesn't exist.
        Connection is reused across multiple database operations for better performance.
    #>

    if ($null -eq $script:DbConnection -or $script:DbConnection.State -ne 'Open') {
        try {
            $script:DbConnection = New-Object System.Data.SQLite.SQLiteConnection("Data Source=$script:DbPath;Version=3;")
            $script:DbConnection.Open()
            Write-Log "Database connection opened (pooled)" -Level "DEBUG"
        }
        catch {
            Write-Log "Failed to open database connection: $_" -Level "ERROR"
            throw
        }
    }

    return $script:DbConnection
}

function Close-DatabaseConnection {
    <#
    .SYNOPSIS
        Closes the pooled database connection
    .DESCRIPTION
        Closes and disposes the pooled database connection. Should be called at the end of backup operation.
    #>

    if ($null -ne $script:DbConnection) {
        try {
            if ($script:DbConnection.State -eq 'Open') {
                $script:DbConnection.Close()
                Write-Log "Database connection closed" -Level "DEBUG"
            }
            $script:DbConnection.Dispose()
            $script:DbConnection = $null
        }
        catch {
            Write-Log "Error closing database connection: $_" -Level "WARNING"
        }
    }
}

function Update-BackupDatabase {
    param (
        [string]$BackupSetName,
        [string]$BackupType,
        [string]$DestinationType,
        [string]$DestinationPath,
        [long]$SizeBytes,
        [string]$CompressionMethod,
        [string]$EncryptionMethod,
        [string[]]$SourcePaths,
        [string]$AdditionalMetadata,
        [int]$DurationSeconds = 0,
        [double]$SizeMB = 0.0,
        [int]$FileCount = 0,
        [string]$BackupStrategy = "Full",
        [int]$ParentBackupId = 0
    )

    # Use pooled database connection
    $connection = Get-DatabaseConnection

    try {
        $command = $connection.CreateCommand()
        $command.CommandText = @"
        INSERT INTO backups (
            backup_set_name, backup_type, destination_type, destination_path,
            timestamp, size_bytes, compression_method, encryption_method,
            source_paths, additional_metadata, duration_seconds, size_mb, file_count,
            backup_strategy, parent_backup_id
        ) VALUES (
            @BackupSetName, @BackupType, @DestinationType, @DestinationPath,
            @Timestamp, @SizeBytes, @CompressionMethod, @EncryptionMethod,
            @SourcePaths, @AdditionalMetadata, @DurationSeconds, @SizeMB, @FileCount,
            @BackupStrategy, @ParentBackupId
        )
"@
        [void]$command.Parameters.AddWithValue("@BackupSetName", $BackupSetName)
        [void]$command.Parameters.AddWithValue("@BackupType", $BackupType)
        [void]$command.Parameters.AddWithValue("@DestinationType", $DestinationType)
        [void]$command.Parameters.AddWithValue("@DestinationPath", $DestinationPath)
        [void]$command.Parameters.AddWithValue("@Timestamp", (Get-Date).ToString("yyyy-MM-dd HH:mm:ss"))
        [void]$command.Parameters.AddWithValue("@SizeBytes", $SizeBytes)
        [void]$command.Parameters.AddWithValue("@CompressionMethod", $CompressionMethod)
        [void]$command.Parameters.AddWithValue("@EncryptionMethod", $EncryptionMethod)
        [void]$command.Parameters.AddWithValue("@SourcePaths", ($SourcePaths -join ";"))
        [void]$command.Parameters.AddWithValue("@AdditionalMetadata", $AdditionalMetadata)
        [void]$command.Parameters.AddWithValue("@DurationSeconds", $DurationSeconds)
        [void]$command.Parameters.AddWithValue("@SizeMB", $SizeMB)
        [void]$command.Parameters.AddWithValue("@FileCount", $FileCount)
        [void]$command.Parameters.AddWithValue("@BackupStrategy", $BackupStrategy)

        # Handle NULL parent_backup_id for full backups
        if ($ParentBackupId -gt 0) {
            [void]$command.Parameters.AddWithValue("@ParentBackupId", $ParentBackupId)
        } else {
            [void]$command.Parameters.AddWithValue("@ParentBackupId", [DBNull]::Value)
        }

        [void]$command.ExecuteNonQuery()
        Write-Log "Backup information recorded in database" -Level "INFO"
    }
    catch {
        Write-Log "Failed to update backup database: $_" -Level "ERROR"
        throw $_
    }
    # Note: Connection is not closed here - it will be closed at end of backup via Close-DatabaseConnection
}

function Get-LastFullBackupDate {
    <#
    .SYNOPSIS
        Gets the timestamp of the last successful full backup

    .DESCRIPTION
        Queries the database for the most recent full backup of the specified type.
        Used for differential backup detection (Issue #20 - Phase 4).

    .PARAMETER BackupType
        The backup type to search for (e.g., "Dev", "Full", "Games")

    .EXAMPLE
        $lastFullDate = Get-LastFullBackupDate -BackupType "Dev"

    .NOTES
        Returns null if no full backup is found
    #>
    param(
        [Parameter(Mandatory=$true)]
        [string]$BackupType
    )

    try {
        $connection = Get-DatabaseConnection

        $command = $connection.CreateCommand()
        $command.CommandText = @"
        SELECT id, timestamp FROM backups
        WHERE backup_type = @BackupType AND backup_strategy = 'Full' AND (success = 1 OR success IS NULL)
        ORDER BY timestamp DESC LIMIT 1
"@
        [void]$command.Parameters.AddWithValue("@BackupType", $BackupType)

        $reader = $command.ExecuteReader()

        if ($reader.Read()) {
            $backupId = $reader["id"]
            $timestamp = $reader["timestamp"]
            $reader.Close()

            Write-Log "Last full backup of type '$BackupType': $timestamp (ID: $backupId)" -Level "INFO"

            # Parse timestamp with multiple format support (Issue #20 - Phase 4)
            $parsedDate = $null
            try {
                $parsedDate = [DateTime]::ParseExact($timestamp, "yyyy-MM-dd HH:mm:ss", $null)
            }
            catch {
                try {
                    $parsedDate = [DateTime]::ParseExact($timestamp, "MM/dd/yyyy HH:mm:ss", $null)
                }
                catch {
                    $parsedDate = [DateTime]::Parse($timestamp)
                }
            }

            return @{
                Id = $backupId
                Timestamp = $parsedDate
            }
        }
        else {
            $reader.Close()
            Write-Log "No previous full backup found for type '$BackupType'" -Level "WARNING"
            return $null
        }
    }
    catch {
        Write-Log "Failed to query last full backup: $_" -Level "ERROR"
        return $null
    }
}

function Get-ModifiedFilesSinceLastFull {
    <#
    .SYNOPSIS
        Gets files modified since the last full backup

    .DESCRIPTION
        Filters a list of paths to only include files modified after the last full backup.
        Used for differential backup implementation (Issue #20 - Phase 4).

    .PARAMETER SourcePaths
        Array of file/folder paths to check

    .PARAMETER LastFullBackupDate
        DateTime of the last full backup

    .PARAMETER Config
        Configuration object for exclusion patterns

    .EXAMPLE
        $modifiedPaths = Get-ModifiedFilesSinceLastFull -SourcePaths $paths -LastFullBackupDate $lastFull -Config $config

    .NOTES
        Returns array of path objects with modification info
    #>
    param(
        [Parameter(Mandatory=$true)]
        [array]$SourcePaths,

        [Parameter(Mandatory=$true)]
        [DateTime]$LastFullBackupDate,

        [Parameter(Mandatory=$false)]
        $Config = $null
    )

    $modifiedPaths = @()
    $totalChecked = 0
    $totalModified = 0

    Write-Log "Scanning for files modified since $($LastFullBackupDate.ToString('yyyy-MM-dd HH:mm:ss'))..." -Level "WARNING"

    foreach ($pathInfo in $SourcePaths) {
        try {
            $path = $pathInfo.ExpandedPath

            if (-not (Test-Path $path)) {
                continue
            }

            # Check if file/folder was modified after last full backup
            if (Test-Path $path -PathType Leaf) {
                # Single file
                $file = Get-Item $path -ErrorAction SilentlyContinue
                if ($file -and $file.LastWriteTime -gt $LastFullBackupDate) {
                    $modifiedPaths += $pathInfo
                    $totalModified++
                    Write-Log "Modified: $($pathInfo.OriginalPath) ($($file.LastWriteTime))" -Level "DEBUG"
                }
                $totalChecked++
            }
            else {
                # Directory - check if any files inside were modified
                $modifiedFiles = Get-ChildItem $path -Recurse -File -ErrorAction SilentlyContinue |
                    Where-Object { $_.LastWriteTime -gt $LastFullBackupDate }

                if ($modifiedFiles) {
                    $modifiedPaths += $pathInfo
                    $totalModified++
                    Write-Log "Modified: $($pathInfo.OriginalPath) ($($modifiedFiles.Count) files changed)" -Level "DEBUG"
                }
                $totalChecked++
            }
        }
        catch {
            Write-Log "Error checking modification time for $($pathInfo.OriginalPath): $_" -Level "WARNING"
        }
    }

    Write-Log "Differential scan complete: $totalModified of $totalChecked items modified since last full backup" -Level "WARNING"

    return $modifiedPaths
}

function Update-BackupStatistics {
    <#
    .SYNOPSIS
        Updates backup statistics in config file

    .DESCRIPTION
        Tracks running statistics for backup operations including success rate,
        average size, and average duration

    .PARAMETER Success
        Whether the backup was successful

    .PARAMETER SizeMB
        Size of the backup in MB

    .PARAMETER DurationSeconds
        Duration of the backup in seconds

    .PARAMETER Config
        Configuration object

    .PARAMETER ConfigPath
        Path to configuration file (for saving updates)
    #>
    param(
        [bool]$Success,
        [double]$SizeMB,
        [int]$DurationSeconds,
        [object]$Config,
        [string]$ConfigPath = "config\bkp_cfg.json"
    )

    try {
        # Update counters
        $Config.Statistics.TotalBackups++

        if ($Success) {
            $Config.Statistics.SuccessfulBackups++
        } else {
            $Config.Statistics.FailedBackups++
        }

        # Update last backup date
        $Config.Statistics.LastBackupDate = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")

        # Update running averages (only for successful backups)
        if ($Success) {
            $totalSuccessful = $Config.Statistics.SuccessfulBackups

            # Calculate new average size
            $oldAvgSize = $Config.Statistics.AverageSize_MB
            $Config.Statistics.AverageSize_MB = [math]::Round(
                (($oldAvgSize * ($totalSuccessful - 1)) + $SizeMB) / $totalSuccessful, 2
            )

            # Calculate new average duration
            $oldAvgDuration = $Config.Statistics.AverageDuration_Seconds
            $Config.Statistics.AverageDuration_Seconds = [math]::Round(
                (($oldAvgDuration * ($totalSuccessful - 1)) + $DurationSeconds) / $totalSuccessful, 0
            )
        }

        # Save updated config
        $fullConfigPath = if ([System.IO.Path]::IsPathRooted($ConfigPath)) {
            $ConfigPath
        } else {
            Join-Path $PSScriptRoot "..\$ConfigPath"
        }

        $Config | ConvertTo-Json -Depth 10 | Set-Content -Path $fullConfigPath -Encoding UTF8

        Write-Log "Statistics updated: Total=$($Config.Statistics.TotalBackups), Success=$($Config.Statistics.SuccessfulBackups), Failed=$($Config.Statistics.FailedBackups)" -Level "INFO"
    }
    catch {
        Write-Log "Failed to update backup statistics: $_" -Level "WARNING"
    }
}

#endregion

#region Compression Functions

function Compress-Backup {
    param (
        [string[]]$SourcePaths,
        [string]$DestinationPath,
        [string]$ArchiveName,
        [string]$SevenZipPath,
        [int]$CompressionLevel,
        [string]$TempPath = $env:TEMP
    )
    
    Write-Log "Compressing backup with level: $CompressionLevel" -Level "INFO"
    
    $archiveFile = Join-Path $DestinationPath "$ArchiveName.zip"  # CHANGED FROM .7z TO .zip
    $compressionSwitch = "-mx=$CompressionLevel"
    
    # Ensure destination directory exists
    if (-not (Test-Path $DestinationPath)) {
        New-Item -ItemType Directory -Path $DestinationPath -Force | Out-Null
    }
    
    $result = Invoke-OperationSafely -Operation {
        # Create a temporary file to store the list of source paths
        $tempFile = Join-Path $TempPath "7zip_sources.tmp"
        $SourcePaths | ForEach-Object { (Resolve-Path $_).Path } | Out-File -FilePath $tempFile -Encoding utf8
        # Use the temporary file as input for 7-Zip, and store full paths
        $output = & $SevenZipPath a -tzip $compressionSwitch -spf -y $archiveFile "@$tempFile" 2>&1
        
        # Check for warnings and log them
        $warnings = $output | Where-Object { $_ -match "WARNING:" }
        foreach ($warning in $warnings) {
            Write-Log "7-Zip Warning: $warning" -Level "WARNING"
        }
        # Remove the temporary file
        Remove-Item -Path $tempFile -Force -ErrorAction SilentlyContinue | Out-Null
        # Check if the archive was created despite warnings
        if (Test-Path $archiveFile) {
            Write-Log "Archive created successfully" -Level "INFO"
            return $archiveFile
        } else {
            throw "Failed to create archive file"
        }
    } -OperationName "Compress backup" -OnFailure {
        Write-Log "Failed to compress backup" -Level "ERROR"
    }
    
    if ($result -and (Test-Path $result)) {
        Write-Log "Backup compressed: $result" -Level "INFO"
        return $result
    } else {
        Write-Log "Compressed backup file not found or not accessible" -Level "ERROR"
        return $null
    }
}

#endregion

#region Transfer Functions

function Transfer-BackupToRemote {
    param (
        [string]$SourceFile,
        [string]$RemoteHost,
        [string]$RemotePath,
        [string]$SSHKeyPath,
        [string]$SCPPath
    )
    
    Write-Log "Transferring backup to remote host" -Level "INFO"
    
    if (-not (Test-Path $SourceFile)) {
        Write-Log "Source file not found: $SourceFile" -Level "ERROR"
        return $false
    }
    
    if (-not (Test-Path $SSHKeyPath)) {
        Write-Log "SSH key file not found: $SSHKeyPath" -Level "ERROR"
        return $false
    }
    
    $result = Invoke-OperationSafely -Operation {
        & $SCPPath -i $SSHKeyPath $SourceFile "${RemoteHost}:${RemotePath}"
        if ($LASTEXITCODE -ne 0) {
            throw "SCP transfer failed with exit code $LASTEXITCODE"
        }
    } -OperationName "Transfer backup to remote" -OnSuccess {
        Write-Log "Backup transferred successfully to $RemoteHost" -Level "INFO"
    } -OnFailure {
        Write-Log "Failed to transfer backup to remote host" -Level "ERROR"
    }
    
    return ($result -ne $null)
}

function Backup-ToSSH {
    param (
        [string[]]$SourcePaths,
        [string]$RemoteHost,
        [string]$RemotePath,
        [string]$SSHKeyPath,
        [string]$BackupName,
        [string]$SevenZipPath,
        [string]$TempPath = $env:TEMP
    )

    $localArchiveName = "$BackupName.zip"
    $localArchivePath = Join-Path $TempPath $localArchiveName
    $remoteFolder = "$RemotePath/$BackupName"
    $remoteFilePath = "$remoteFolder/$localArchiveName"

    Write-Log "Starting SSH backup to $RemoteHost" -Level "INFO"

    try {
        # Create 7z archive directly from source paths
        Write-Log "Creating local archive: $localArchivePath" -Level "INFO"
        & $SevenZipPath a -tzip $localArchivePath $SourcePaths | Out-Null
        if ($LASTEXITCODE -ne 0) {
            throw "7-Zip compression failed with exit code $LASTEXITCODE"
        }

        # Verify local archive
        if (-not (Test-Path $localArchivePath)) {
            throw "Local archive was not created: $localArchivePath"
        }
        $localHash = (Get-FileHash -Path $localArchivePath -Algorithm SHA256).Hash
        Write-Log "Local archive created and verified. Hash: $localHash" -Level "INFO"

        # Create remote folder
        Write-Log "Creating remote folder: $remoteFolder" -Level "INFO"
        $mkdirCommand = "mkdir -p `"$remoteFolder`""
        $mkdirResult = ssh -i $SSHKeyPath $RemoteHost $mkdirCommand
        if ($LASTEXITCODE -ne 0) {
            throw "Failed to create remote folder. Exit code: $LASTEXITCODE. Output: $mkdirResult"
        }

        # Transfer archive to remote host
        Write-Log "Transferring archive to $RemoteHost" -Level "INFO"

        # Build SCP command with optional bandwidth limit
        $scpArgs = @("-i", $SSHKeyPath)

        # Add bandwidth limit if configured (in Kbit/s)
        if ($Config.Destinations.SSH.BandwidthLimit -and $Config.Destinations.SSH.BandwidthLimit -gt 0) {
            $scpArgs += @("-l", $Config.Destinations.SSH.BandwidthLimit)
            $limitMBps = [math]::Round($Config.Destinations.SSH.BandwidthLimit / 8000, 2)
            Write-Log "Bandwidth limit: $($Config.Destinations.SSH.BandwidthLimit) Kbit/s (~$limitMBps MB/s)" -Level "INFO"
        } else {
            Write-Log "No bandwidth limit (unlimited transfer speed)" -Level "INFO"
        }

        $scpArgs += @($localArchivePath, "${RemoteHost}:${remoteFilePath}")

        $scpResult = & scp @scpArgs
        if ($LASTEXITCODE -ne 0) {
            throw "SCP transfer failed with exit code $LASTEXITCODE. Output: $scpResult"
        }

        # Verify remote archive
        $remoteHashCommand = "sha256sum `"$remoteFilePath`" | cut -d' ' -f1"
        $remoteHash = (ssh -i $SSHKeyPath $RemoteHost $remoteHashCommand).Trim()
        if ($remoteHash -ne $localHash) {
            throw "Remote file hash does not match local file hash. Transfer may be incomplete."
        }

        Write-Log "Backup successfully transferred and verified on $RemoteHost" -Level "INFO"
        return $true
    }
    catch {
        Write-Log "Error during SSH backup: $_" -Level "ERROR"
        return $false
    }
    finally {
        # Clean up local archive
        if (Test-Path $localArchivePath) {
            Remove-Item -Path $localArchivePath -Force
            Write-Log "Cleaned up local archive file" -Level "INFO"
        }
    }
}

#endregion

#region Security Functions

function Protect-BackupSecret {
    <#
    .SYNOPSIS
        Encrypts a secret using Windows DPAPI

    .DESCRIPTION
        Uses Windows Data Protection API (DPAPI) to encrypt secrets like API tokens.
        Encrypted secrets can only be decrypted by the same Windows user account.
        Part of Phase 3 Security Hardening (Issue #38).

    .PARAMETER Secret
        Plain text secret to encrypt

    .EXAMPLE
        $encrypted = Protect-BackupSecret -Secret "myApiToken123"

    .NOTES
        The encrypted string can be stored in config files. It is user-specific
        and machine-specific (CurrentUser scope).
    #>
    param(
        [Parameter(Mandatory=$true)]
        [string]$Secret
    )

    try {
        $secureString = ConvertTo-SecureString $Secret -AsPlainText -Force
        $encrypted = ConvertFrom-SecureString $secureString
        Write-Log "Secret encrypted successfully using DPAPI" -Level "DEBUG"
        return $encrypted
    }
    catch {
        Write-Log "Failed to encrypt secret: $_" -Level "ERROR"
        throw "Failed to encrypt secret: $_"
    }
}

function Unprotect-BackupSecret {
    <#
    .SYNOPSIS
        Decrypts a DPAPI-encrypted secret

    .DESCRIPTION
        Decrypts secrets that were encrypted using Protect-BackupSecret.
        Can only decrypt secrets encrypted by the same Windows user account.
        Part of Phase 3 Security Hardening (Issue #38).

    .PARAMETER EncryptedSecret
        DPAPI-encrypted secret string

    .EXAMPLE
        $plaintext = Unprotect-BackupSecret -EncryptedSecret $encryptedToken

    .NOTES
        Throws an error if the secret cannot be decrypted (wrong user, corrupted data, etc.)
    #>
    param(
        [Parameter(Mandatory=$true)]
        [string]$EncryptedSecret
    )

    try {
        $secureString = ConvertTo-SecureString $EncryptedSecret
        $bstr = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($secureString)
        $plaintext = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto($bstr)
        [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
        Write-Log "Secret decrypted successfully using DPAPI" -Level "DEBUG"
        return $plaintext
    }
    catch {
        Write-Log "Failed to decrypt secret: $_" -Level "ERROR"
        throw "Failed to decrypt secret. Ensure the secret was encrypted by the same Windows user account."
    }
}

function ConvertTo-SafePath {
    <#
    .SYNOPSIS
        Sanitizes file paths to prevent path traversal and injection attacks

    .DESCRIPTION
        Removes dangerous characters, prevents path traversal attacks, and normalizes paths.
        Part of Phase 3 Security Hardening (Issue #28).

    .PARAMETER Path
        Path to sanitize

    .EXAMPLE
        $safePath = ConvertTo-SafePath -Path "C:\Users\..\..\..\Windows\System32"

    .NOTES
        Removes: <>:"|?* characters and path traversal patterns (../)
    #>
    param(
        [Parameter(Mandatory=$true)]
        [string]$Path
    )

    if ([string]::IsNullOrWhiteSpace($Path)) {
        Write-Log "Empty path provided to ConvertTo-SafePath" -Level "WARNING"
        return ""
    }

    # Remove dangerous characters (but preserve : for drive letters and \ for path separators)
    $sanitized = $Path -replace '[<>"|?*]', ''

    # Prevent path traversal attacks - remove ..\ and ../ patterns
    $sanitized = $sanitized -replace '\.\.[\\/]', ''

    # Remove leading/trailing whitespace
    $sanitized = $sanitized.Trim()

    # Normalize path separators
    $sanitized = $sanitized -replace '/', '\'

    Write-Log "Path sanitized: '$Path' -> '$sanitized'" -Level "DEBUG"
    return $sanitized
}

function ConvertTo-SafeString {
    <#
    .SYNOPSIS
        Sanitizes general string inputs to prevent injection attacks

    .DESCRIPTION
        Removes control characters, limits length, and normalizes whitespace.
        Part of Phase 3 Security Hardening (Issue #28).

    .PARAMETER InputString
        String to sanitize

    .PARAMETER MaxLength
        Maximum allowed length (default: 255)

    .PARAMETER AllowedPattern
        Optional regex pattern for allowed characters

    .EXAMPLE
        $safeInput = ConvertTo-SafeString -InputString "MyBackup`n`r`0Type" -MaxLength 50

    .NOTES
        Removes: Control characters (0x00-0x1F, 0x7F)
    #>
    param(
        [Parameter(Mandatory=$true)]
        [AllowEmptyString()]
        [string]$InputString,

        [Parameter(Mandatory=$false)]
        [int]$MaxLength = 255,

        [Parameter(Mandatory=$false)]
        [string]$AllowedPattern = $null
    )

    if ([string]::IsNullOrWhiteSpace($InputString)) {
        return ""
    }

    # Trim to max length first
    if ($InputString.Length -gt $MaxLength) {
        $sanitized = $InputString.Substring(0, $MaxLength)
        Write-Log "InputString truncated from $($InputString.Length) to $MaxLength characters" -Level "WARNING"
    }
    else {
        $sanitized = $InputString
    }

    # Remove control characters (0x00-0x1F and 0x7F)
    $sanitized = $sanitized -replace '[\x00-\x1F\x7F]', ''

    # Normalize whitespace (replace multiple spaces/tabs with single space)
    $sanitized = $sanitized -replace '\s+', ' '

    # Trim leading/trailing whitespace
    $sanitized = $sanitized.Trim()

    # Apply allowed pattern if specified
    if ($AllowedPattern) {
        if ($sanitized -notmatch $AllowedPattern) {
            Write-Log "InputString failed allowed pattern validation: '$sanitized' (pattern: $AllowedPattern)" -Level "WARNING"
            throw "InputString contains invalid characters. Allowed pattern: $AllowedPattern"
        }
    }

    Write-Log "String sanitized: '$InputString' -> '$sanitized'" -Level "DEBUG"
    return $sanitized
}

#endregion

#region Validation Functions

function Validate-BackupParameters {
    param (
        $Config,
        [string]$BackupType,
        [string]$Destination
    )

    Write-Log "Validating and sanitizing BackupType: $BackupType and Destination: $Destination" -Level "DEBUG"

    # Sanitize inputs (Issue #28 - Phase 3 Security)
    $sanitizedBackupType = ConvertTo-SafeString -InputString $BackupType -MaxLength 50 -AllowedPattern '^[a-zA-Z0-9_\-]+$'
    $sanitizedDestination = ConvertTo-SafeString -InputString $Destination -MaxLength 50 -AllowedPattern '^[a-zA-Z0-9_\-]+$'

    Write-Log "Sanitized inputs: BackupType='$sanitizedBackupType', Destination='$sanitizedDestination'" -Level "DEBUG"

    $validBackupTypes = $Config.BackupTypes | Get-Member -MemberType NoteProperty | Select-Object -ExpandProperty Name
    $validDestinations = $Config.Destinations | Get-Member -MemberType NoteProperty | Select-Object -ExpandProperty Name

    if (-not ($validBackupTypes -contains $sanitizedBackupType)) {
        $errorMessage = "Invalid BackupType: $sanitizedBackupType. Valid types are: $($validBackupTypes -join ', ')"
        Write-Log $errorMessage -Level "ERROR"
        throw $errorMessage
    }

    if (-not ($validDestinations -contains $sanitizedDestination)) {
        $errorMessage = "Invalid Destination: $sanitizedDestination. Valid destinations are: $($validDestinations -join ', ')"
        Write-Log $errorMessage -Level "ERROR"
        throw $errorMessage
    }

    Write-Log "Validation passed for BackupType: $sanitizedBackupType and Destination: $sanitizedDestination" -Level "DEBUG"

    # Return sanitized values
    return @{
        BackupType = $sanitizedBackupType
        Destination = $sanitizedDestination
    }
}

function Test-DestinationWritable {
    <#
    .SYNOPSIS
        Tests write permissions to destination path before backup starts

    .DESCRIPTION
        Creates a temporary test file to verify write access to the destination.
        Helps fail fast with clear error instead of failing midway through backup.
        Part of Phase 3 Security Hardening (Issue #40).

    .PARAMETER DestinationPath
        Path to test for write access

    .EXAMPLE
        Test-DestinationWritable -DestinationPath "C:\Temp\Backups"

    .NOTES
        Returns $true if writable, $false otherwise
    #>
    param(
        [Parameter(Mandatory=$true)]
        [string]$DestinationPath
    )

    Write-Log "Testing write permissions for destination: $DestinationPath" -Level "DEBUG"

    $testFile = Join-Path $DestinationPath ".writetest_$(Get-Random)"
    try {
        # Ensure directory exists first
        if (-not (Test-Path $DestinationPath)) {
            New-Item -ItemType Directory -Path $DestinationPath -Force -ErrorAction Stop | Out-Null
            Write-Log "Created destination directory: $DestinationPath" -Level "INFO"
        }

        # Try to write test file
        "test" | Out-File $testFile -ErrorAction Stop
        Remove-Item $testFile -ErrorAction SilentlyContinue | Out-Null
        Write-Log "Destination is writable: $DestinationPath" -Level "DEBUG"
        return $true
    }
    catch {
        Write-Log "No write permission to $DestinationPath : $_" -Level "ERROR"
        return $false
    }
}

function Check-Dependencies {
    param (
        $Config
    )
    
    Write-Log "Checking dependencies..." -Level "INFO"

    # Check for required PowerShell modules
    $requiredModules = @("CredentialManager")
    foreach ($module in $requiredModules) {
        if (-not (Get-Module -ListAvailable -Name $module)) {
            Write-Log "Required module not found: $module. Attempting to install..." -Level "WARNING"
            try {
                Install-Module -Name $module -Force -Scope CurrentUser
                Write-Log "Successfully installed $module" -Level "INFO"
            }
            catch {
                Write-Log "Failed to install required module: $module. Error: $_" -Level "WARNING"
                Write-Log "Please install the $module module manually to enable Windows Credentials backup." -Level "WARNING"
            }
        }
    }

    # Check for 7-Zip
    if (-not (Test-Path $Config.Tools.'7Zip')) {
        throw "7-Zip not found at specified path: $($Config.Tools.'7Zip')"
    }

    # Check for SCP (only if HomeNet destination is configured)
    if ($Config.Destinations.HomeNet -and -not (Test-Path $Config.Tools.SCP)) {
        throw "SCP not found at specified path: $($Config.Tools.SCP)"
    }

    Write-Log "All dependencies are satisfied" -Level "INFO"
}

#endregion

#region Verification Functions

function Verify-Backup {
    param (
        [string]$BackupFile
    )
    
    Write-Log "Verifying backup integrity: $BackupFile" -Level "INFO"
    
    try {
        if (Test-Path $BackupFile) {
            $hash = Get-FileHash -Path $BackupFile -Algorithm SHA256
            Write-Log "Backup file hash: $($hash.Hash)" -Level "INFO"
            return $hash.Hash
        } else {
            throw "Backup file not found: $BackupFile"
        }
    }
    catch {
        Write-Log "Failed to verify backup integrity: $_" -Level "ERROR"
        return $null
    }
}

function Manage-BackupVersions {
    param (
        [string]$BackupDirectory,
        [int]$VersionsToKeep = 5
    )
    
    Write-Log "Managing backup versions in $BackupDirectory" -Level "INFO"
    
    try {
        $backups = Get-ChildItem -Path $BackupDirectory -Filter "*.zip" | Sort-Object CreationTime -Descending
        
        if ($backups.Count -gt $VersionsToKeep) {
            $backupsToDelete = $backups | Select-Object -Skip $VersionsToKeep
            
            foreach ($backup in $backupsToDelete) {
                Remove-Item -Path $backup.FullName -Force -ErrorAction SilentlyContinue | Out-Null
                Write-Log "Deleted old backup: $($backup.Name)" -Level "INFO"
            }
        }
        
        Write-Log "Backup version management completed" -Level "INFO"
    }
    catch {
        Write-Log "Error during backup version management: $_" -Level "ERROR"
    }
}

#endregion

#region Notification Functions



function Send-GotifyNotification {
    param (
        $Config,
        [string]$Title = "Backup Notification",
        [string]$Message = "Backup operation",
        [int]$Priority = 5
    )

    if (-not $Config.Notifications.Gotify) {
        Write-Log "Gotify configuration not found" -Level "DEBUG"
        return
    }

    # Check if Gotify notifications are enabled
    if (-not $Config.Notifications.Gotify.Enabled) {
        Write-Log "Gotify notifications are disabled in configuration" -Level "DEBUG"
        return
    }

    try {
        $gotifyUrl = $Config.Notifications.Gotify.Url
        $gotifyToken = $null

        # Priority 1: Check for encrypted token (Issue #38 - Phase 3 Security)
        if ($Config.Notifications.Gotify.PSObject.Properties.Name -contains "TokenEncrypted") {
            $encryptedToken = $Config.Notifications.Gotify.TokenEncrypted
            if ($encryptedToken) {
                try {
                    $gotifyToken = Unprotect-BackupSecret -EncryptedSecret $encryptedToken
                    Write-Log "Using DPAPI-encrypted token for Gotify" -Level "DEBUG"
                }
                catch {
                    Write-Log "Failed to decrypt Gotify token: $_" -Level "ERROR"
                    Write-Log "Gotify notification skipped. Re-encrypt token using Setup-BackupCredentials.ps1" -Level "WARNING"
                    return
                }
            }
        }

        # Priority 2: Fall back to plain Token field (backwards compatibility)
        if (-not $gotifyToken) {
            $gotifyToken = $Config.Notifications.Gotify.Token

            # Expand environment variable if token contains $env:
            if ($gotifyToken -match '\$env:(\w+)') {
                $envVarName = $matches[1]
                $gotifyToken = [System.Environment]::GetEnvironmentVariable($envVarName, "User")

                if (-not $gotifyToken) {
                    # Fallback to current session
                    $gotifyToken = [System.Environment]::GetEnvironmentVariable($envVarName, "Process")
                }

                if (-not $gotifyToken) {
                    Write-Log "Environment variable $envVarName not found. Gotify notification skipped." -Level "WARNING"
                    return
                }
            }
        }

        # Validate token exists
        if (-not $gotifyToken) {
            Write-Log "Gotify token not configured. Notification skipped." -Level "WARNING"
            return
        }

        # Prepare notification payload
        $headers = @{
            "X-Gotify-Key" = $gotifyToken
        }

        $body = @{
            title = $Title
            message = $Message
            priority = $Priority
        } | ConvertTo-Json

        # Send notification via REST API
        $response = Invoke-RestMethod -Uri $gotifyUrl -Method Post -Headers $headers -Body $body -ContentType "application/json" -ErrorAction Stop
        Write-Log "Gotify notification sent successfully. ID: $($response.id)" -Level "INFO"
    }
    catch {
        Write-Log "Failed to send Gotify notification: $_" -Level "ERROR"
    }
}



#endregion

#region Progress and Display Functions

# Track backup start time for ETA calculation
$script:BackupStartTime = $null

function Show-Progress {
    param (
        [int]$PercentComplete,
        [string]$Status,
        [string]$CurrentFile = ""  # Issue #43: NEW parameter for current file display
    )

    # Initialize start time on first call
    if ($null -eq $script:BackupStartTime) {
        $script:BackupStartTime = Get-Date
    }

    $consoleWidth = $Host.UI.RawUI.WindowSize.Width
    $width = [Math]::Min(100, $consoleWidth - 20)
    $completedWidth = [Math]::Max(0, [Math]::Min($width, [Math]::Floor($width * ($PercentComplete / 100))))
    $remainingWidth = $width - $completedWidth

    # Create progress bar
    $progressBar = "[" + ("=" * $completedWidth) + (" " * $remainingWidth) + "]"
    $percentage = "{0,3:N0}%" -f [Math]::Max(0, [Math]::Min(100, $PercentComplete))

    # Calculate ETA
    $etaString = ""
    if ($PercentComplete -gt 5 -and $PercentComplete -lt 100) {
        $elapsed = (Get-Date) - $script:BackupStartTime
        $rate = $PercentComplete / $elapsed.TotalSeconds
        $remainingPercent = 100 - $PercentComplete
        $etaSeconds = $remainingPercent / $rate

        if ($etaSeconds -lt 60) {
            $etaString = " (ETA: $([math]::Round($etaSeconds))s)"
        } elseif ($etaSeconds -lt 3600) {
            $etaMinutes = [math]::Floor($etaSeconds / 60)
            $etaSeconds = [math]::Round($etaSeconds % 60)
            $etaString = " (ETA: ${etaMinutes}m ${etaSeconds}s)"
        } else {
            $etaHours = [math]::Floor($etaSeconds / 3600)
            $etaMinutes = [math]::Floor(($etaSeconds % 3600) / 60)
            $etaString = " (ETA: ${etaHours}h ${etaMinutes}m)"
        }
    }

    # Clear previous progress (Issue #43: now clears 3 lines to accommodate file display)
    if ($PercentComplete -gt 0) {
        if ($CurrentFile) {
            Write-Host "`e[3A`e[2K`e[B`e[2K`e[B`e[2K`e[2A" -NoNewline  # Move up 3, clear 3 lines, move back up 2
        } else {
            Write-Host "`e[2A`e[2K`e[B`e[2K`e[A" -NoNewline  # Move up 2, clear 2 lines, move back up 1
        }
    }

    # Write progress bar in light blue (Cyan) on a fresh line
    Write-Host "`r$progressBar" -ForegroundColor Cyan -NoNewline
    Write-Host ""  # Newline after progress bar

    # Write percentage, status, and ETA on next line
    Write-Host "`r$percentage $Status$etaString"

    # Issue #43: Show current file being processed
    if ($CurrentFile) {
        # Truncate long file paths to fit console
        $maxFileLength = 80
        $displayFile = if ($CurrentFile.Length -gt $maxFileLength) {
            "..." + $CurrentFile.Substring($CurrentFile.Length - ($maxFileLength - 3))
        } else {
            $CurrentFile
        }
        Write-Host "  File: $displayFile" -ForegroundColor DarkGray
    }
}

function Reset-ProgressTimer {
    <#
    .SYNOPSIS
        Resets the backup progress timer
    .DESCRIPTION
        Call this at the start of each backup operation to reset ETA calculations
    #>
    $script:BackupStartTime = Get-Date
}

#endregion

#region Utility Functions

function Ensure-Directory {
    param ([string]$Path)
    if (-not (Test-Path $Path)) {
        New-Item -ItemType Directory -Path $Path -Force | Out-Null
    }
}

function Measure-BackupSpeed {
    <#
    .SYNOPSIS
        Calculates backup speed in MB/s

    .DESCRIPTION
        Measures backup speed based on bytes processed over time. Used to display
        real-time transfer speeds during backup operations (Issue #17).

    .PARAMETER StartTime
        Backup start timestamp

    .PARAMETER BytesProcessed
        Total bytes backed up so far

    .EXAMPLE
        $stats = Measure-BackupSpeed -StartTime $script:BackupSpeedStats.StartTime -BytesProcessed $script:BackupSpeedStats.BytesProcessed
        Write-Host "Speed: $($stats.Speed_MBps) MB/s"
    #>
    param(
        [DateTime]$StartTime,
        [long]$BytesProcessed
    )

    $elapsed = (Get-Date) - $StartTime

    # Avoid division by zero
    if ($elapsed.TotalSeconds -lt 1) {
        return @{
            Speed_MBps = 0
            TotalMB = 0
            Duration = $elapsed
        }
    }

    $mbProcessed = [math]::Round($BytesProcessed / 1MB, 2)
    $speed = [math]::Round($mbProcessed / $elapsed.TotalSeconds, 2)

    return @{
        Speed_MBps = $speed
        TotalMB = $mbProcessed
        Duration = $elapsed
    }
}

function Test-PathAndLog {
    param (
        [string]$Path,
        [string]$ItemType = "Path" # Can be "Path", "File", or "Directory"
    )

    if (Test-Path $Path) {
        Write-Log "$ItemType exists: $Path" -Level "DEBUG"
        return $true
    } else {
        Write-Log "$ItemType not found: $Path" -Level "DEBUG"
        return $false
    }
}

function Invoke-OperationSafely {
    param (
        [scriptblock]$Operation,
        [string]$OperationName,
        [scriptblock]$OnSuccess = {},
        [scriptblock]$OnFailure = {}
    )
    
    try {
        $result = & $Operation
        Write-Log "$OperationName completed successfully" -Level "DEBUG"
        & $OnSuccess
        return $result
    }
    catch {
        Handle-Error -ErrorMessage "Error during $OperationName." -ErrorRecord $_ -Operation $OperationName
        & $OnFailure
        return $null
    }
}

function Handle-Error {
    param (
        [string]$ErrorMessage,
        [System.Management.Automation.ErrorRecord]$ErrorRecord,
        [string]$Operation,
        [switch]$SendNotification,
        $Config
    )
    
    $fullErrorMessage = "$ErrorMessage Error details: $($ErrorRecord.Exception.Message)"
    Write-Log $fullErrorMessage -Level "ERROR"
    
    if ($Operation) {
        Write-Log "Failed operation: $Operation" -Level "ERROR"
    }
    
    if ($ErrorRecord.ScriptStackTrace) {
        Write-Log "Stack trace: $($ErrorRecord.ScriptStackTrace)" -Level "DEBUG"
    }

    if ($SendNotification -and $Config.Notifications.Gotify) {
        Send-GotifyNotification -Title "Backup Script Error" -Message $fullErrorMessage -Priority 7 -Config $Config
    }
}

function Parse-ConfigFile {
    param ([string]$ConfigFilePath)
    try {
        $config = Get-Content $ConfigFilePath -Raw | ConvertFrom-Json
        Write-Log "Configuration loaded from $ConfigFilePath" -Level "DEBUG"
        return $config
    }
    catch {
        Write-Log "Failed to parse config file: $_" -Level "ERROR"
        throw "Error parsing config file: $_"
    }
}

#endregion

#region Space and Size Functions

function Check-DiskSpaceAndEstimateSize {
    param (
        $Config,
        [string]$BackupType,
        [string]$Destination
    )

    $backupItems = $Config.BackupTypes.$BackupType
    $destinationConfig = $Config.Destinations.$Destination

    $totalSize = 0
    $estimatedItems = @()
    $sizeCache = @{}  # Cache for repeated path calculations
    $processedPaths = 0
    $totalPaths = 0
    
    # Pre-calculate total paths for progress reporting
    foreach ($item in $backupItems) {
        if ($Config.BackupItems.PSObject.Properties.Name -contains $item) {
            $totalPaths += $Config.BackupItems.$item.Count
        } else {
            $totalPaths += 1  # For special items like Win*, Certificates
        }
    }
    
    Write-Log "Optimized size calculation starting for $totalPaths paths" -Level "INFO"

    foreach ($item in $backupItems) {
        $itemSize = 0
        
        # Handle Windows Settings items differently
        if ($item.StartsWith("Win")) {
            # Windows settings items - estimate smaller size (mostly registry and config files)
            $itemSize = 50MB # Conservative estimate for Windows settings
            $processedPaths++
        }
        elseif ($item -eq "Certificates") {
            # Estimate a small size for certificates
            $itemSize = 1MB
            $processedPaths++
        }
        elseif ($Config.BackupItems.PSObject.Properties.Name -contains $item) {
            $paths = $Config.BackupItems.$item
            foreach ($path in $paths) {
                $processedPaths++
                
                # Show progress for large operations
                if ($totalPaths -gt 10 -and $processedPaths % 5 -eq 0) {
                    $progressPercent = [math]::Round(($processedPaths / $totalPaths) * 100, 1)
                    Write-Progress -Activity "Calculating backup size" -Status "Processing path $processedPaths of $totalPaths" -PercentComplete $progressPercent
                }
                
                # Expand PowerShell environment variables in path
                $expandedPath = $ExecutionContext.InvokeCommand.ExpandString($path)
                
                # Check cache first
                if ($sizeCache.ContainsKey($expandedPath)) {
                    $cachedSize = $sizeCache[$expandedPath]
                    $itemSize += $cachedSize
                    Write-Log "Using cached size for $expandedPath : $([math]::Round($cachedSize / 1MB, 2)) MB" -Level "DEBUG"
                    continue
                }
                
                if (Test-PathAndLog -Path $expandedPath -ItemType "Path") {
                    try {
                        Write-Log "Getting size for: $expandedPath" -Level "DEBUG"
                        $pathSize = Get-OptimizedPathSize -Path $expandedPath -Config $Config

                        # Cache the result
                        $sizeCache[$expandedPath] = $pathSize
                        $itemSize += $pathSize
                        
                        $sizeInMB = [math]::Round($pathSize / 1MB, 2)
                        Write-Log "Size of $expandedPath : $sizeInMB MB" -Level "INFO"
                    } catch {
                        Write-Log "Error getting size for $expandedPath : $_" -Level "WARNING"
                        $defaultSize = 5MB  # Default estimate for error paths
                        $sizeCache[$expandedPath] = $defaultSize
                        $itemSize += $defaultSize
                    }
                } else {
                    # Path doesn't exist - cache this result too
                    $sizeCache[$expandedPath] = 0
                }
            }
        } else {
            Write-Log "BackupItem not found in config: $item" -Level "WARNING"
            $processedPaths++
        }
        
        $totalSize += $itemSize
        $estimatedItems += [PSCustomObject]@{
            Item = $item
            Size = $itemSize
        }
    }
    
    # Clear progress if it was shown
    if ($totalPaths -gt 10) {
        Write-Progress -Activity "Calculating backup size" -Completed
    }

    # Add 10% overhead for compression and metadata
    $estimatedBackupSize = $totalSize * 1.1

    # Check if it's a remote destination
    $isRemoteDestination = $Destination -in @("HomeNet", "SSH")

    if ($isRemoteDestination) {
        # Skip space check for remote destinations
        $freeSpace = [double]::PositiveInfinity
        $sufficientSpace = $true
        Write-Log "Skipping space check for remote destination: $Destination" -Level "INFO"
    } else {
        # Local destination space check
        $drive = Split-Path $destinationConfig -Qualifier
        try {
            $driveInfo = Get-WmiObject Win32_LogicalDisk -Filter "DeviceID='$drive'"
            $freeSpace = $driveInfo.FreeSpace
            $sufficientSpace = $freeSpace -gt $estimatedBackupSize
        }
        catch {
            Write-Log "Unable to get free space for drive $drive. Error: $_" -Level "WARNING"
            $freeSpace = 0
            $sufficientSpace = $false
        }
    }

    # Don't log here - main.ps1 will log the results to avoid duplication

    return @{
        EstimatedSize = $estimatedBackupSize
        FreeSpace = $freeSpace
        SufficientSpace = $sufficientSpace
        ItemizedEstimates = $estimatedItems
    }
}

#endregion

#region Optimized Size Calculation Functions

function Get-OptimizedPathSize {
    param (
        [Parameter(Mandatory=$true)]
        [string]$Path,
        [object]$Config = $null
    )

    try {
        # Check if it's a single file first
        if (Test-Path $Path -PathType Leaf) {
            $fileInfo = Get-Item $Path -Force -ErrorAction SilentlyContinue
            if ($fileInfo) {
                # Optimization 1: Skip recursive scan for files under 1KB
                if ($fileInfo.Length -lt 1KB) {
                    Write-Log "Small file (< 1KB) - direct size: $Path" -Level "DEBUG"
                    return $fileInfo.Length
                }
                # Quick return for any single file
                Write-Log "Single file - direct size: $Path ($([math]::Round($fileInfo.Length / 1MB, 2)) MB)" -Level "DEBUG"
                return $fileInfo.Length
            }
        }

        # Handle directories with optimizations
        if (Test-Path $Path -PathType Container) {
            return Get-DirectorySizeOptimized -Path $Path -Config $Config
        }

        # Path doesn't exist or is inaccessible
        Write-Log "Path not accessible: $Path" -Level "WARNING"
        return 0

    } catch {
        Write-Log "Error in Get-OptimizedPathSize for $Path : $_" -Level "ERROR"
        return 0
    }
}

function Get-DirectorySizeOptimized {
    param (
        [Parameter(Mandatory=$true)]
        [string]$Path,
        [object]$Config = $null
    )
    
    try {
        # Quick sample check: if directory has very few files, calculate directly
        $sampleFiles = Get-ChildItem $Path -File -Force -ErrorAction SilentlyContinue | Select-Object -First 10
        $sampleDirs = Get-ChildItem $Path -Directory -Force -ErrorAction SilentlyContinue | Select-Object -First 5
        
        $totalSampleItems = ($sampleFiles | Measure-Object).Count + ($sampleDirs | Measure-Object).Count
        
        # Optimization 2: For very small directories (< 15 items), calculate directly without jobs
        if ($totalSampleItems -lt 15) {
            Write-Log "Small directory (< 15 items) - direct calculation: $Path" -Level "DEBUG"

            # Get all files and filter by exclusions
            $allFiles = Get-ChildItem $Path -Recurse -File -Force -ErrorAction SilentlyContinue

            # Apply exclusions if Config is provided
            if ($Config -and $Config.GlobalExclusions) {
                $allFiles = $allFiles | Where-Object {
                    $filePath = $_.FullName
                    $shouldInclude = $true

                    # Check for reserved device names
                    if (Test-IsReservedDeviceName -Path $filePath) {
                        return $false
                    }

                    # Check folder exclusions
                    if ($Config.GlobalExclusions.Folders) {
                        foreach ($pattern in $Config.GlobalExclusions.Folders) {
                            $patternNorm = $pattern.Replace('/', '\').TrimEnd('\')
                            if ($filePath -like $patternNorm -or $filePath -like "$patternNorm\*") {
                                $shouldInclude = $false
                                break
                            }
                        }
                    }

                    # Check file exclusions
                    if ($shouldInclude -and $Config.GlobalExclusions.Files) {
                        $fileName = $_.Name
                        foreach ($pattern in $Config.GlobalExclusions.Files) {
                            if ($fileName -like $pattern) {
                                $shouldInclude = $false
                                break
                            }
                        }
                    }

                    $shouldInclude
                }
            }

            $directSize = ($allFiles | Measure-Object -Property Length -Sum -ErrorAction SilentlyContinue).Sum
            if ($directSize) {
                return [long]$directSize
            } else {
                return 0
            }
        }
        
        # Optimization 3: Check if all sample files are tiny (< 1KB each)
        $allFilesSmall = $true
        $totalSampleSize = 0
        
        foreach ($file in $sampleFiles) {
            if ($file.Length -gt 1KB) {
                $allFilesSmall = $false
                break
            }
            $totalSampleSize += $file.Length
        }
        
        # If all sampled files are tiny, estimate based on file count
        if ($allFilesSmall -and $sampleFiles.Count -gt 0) {
            Write-Log "Directory contains only small files - using estimation: $Path" -Level "DEBUG"

            # Extract exclusion patterns for the job
            $excludeFolders = @()
            $excludeFiles = @()
            if ($Config -and $Config.GlobalExclusions) {
                if ($Config.GlobalExclusions.Folders) {
                    $excludeFolders = $Config.GlobalExclusions.Folders
                }
                if ($Config.GlobalExclusions.Files) {
                    $excludeFiles = $Config.GlobalExclusions.Files
                }
            }

            # Get total file count efficiently with exclusions
            $totalFileCount = 0
            try {
                # Use faster counting method with exclusions
                $countJob = Start-Job -ScriptBlock {
                    param($pathToCount, $excludeFolderPatterns, $excludeFilePatterns)

                    function Test-ShouldExclude {
                        param($itemPath, $folderPatterns, $filePatterns)
                        $normalized = $itemPath.TrimEnd('\', '/')

                        # Check for reserved device names
                        $fileName = Split-Path $itemPath -Leaf
                        $baseName = [System.IO.Path]::GetFileNameWithoutExtension($fileName)
                        $reservedNames = @('CON', 'PRN', 'AUX', 'NUL', 'COM1', 'COM2', 'COM3', 'COM4', 'COM5', 'COM6', 'COM7', 'COM8', 'COM9', 'LPT1', 'LPT2', 'LPT3', 'LPT4', 'LPT5', 'LPT6', 'LPT7', 'LPT8', 'LPT9')
                        if ($reservedNames -contains $baseName.ToUpper()) {
                            return $true
                        }

                        foreach ($pattern in $folderPatterns) {
                            $patternNorm = $pattern.Replace('/', '\').TrimEnd('\')
                            if ($normalized -like $patternNorm -or $normalized -like "$patternNorm\*") {
                                return $true
                            }
                        }

                        if (Test-Path $itemPath -PathType Leaf -ErrorAction SilentlyContinue) {
                            $fileName = Split-Path $itemPath -Leaf
                            foreach ($pattern in $filePatterns) {
                                if ($fileName -like $pattern) {
                                    return $true
                                }
                            }
                        }

                        return $false
                    }

                    $allFiles = Get-ChildItem $pathToCount -Recurse -File -Force -ErrorAction SilentlyContinue
                    $filteredFiles = $allFiles | Where-Object {
                        -not (Test-ShouldExclude -itemPath $_.FullName -folderPatterns $excludeFolderPatterns -filePatterns $excludeFilePatterns)
                    }
                    ($filteredFiles | Measure-Object).Count
                } -ArgumentList $Path, $excludeFolders, $excludeFiles

                if ($countJob | Wait-Job -Timeout 15) {
                    $totalFileCount = Receive-Job $countJob
                    Remove-Job $countJob
                } else {
                    Stop-Job $countJob
                    Remove-Job $countJob
                    $totalFileCount = $sampleFiles.Count * 10  # Conservative estimate
                }
            } catch {
                $totalFileCount = $sampleFiles.Count * 10  # Fallback estimate
            }

            # Estimate total size based on average small file size
            if ($sampleFiles.Count -gt 0) {
                $avgFileSize = $totalSampleSize / $sampleFiles.Count
                $estimatedSize = $avgFileSize * $totalFileCount
                Write-Log "Estimated size for small files directory: $([math]::Round($estimatedSize / 1MB, 2)) MB" -Level "DEBUG"
                return [long]$estimatedSize
            }
        }
        
        # Optimization 4: Use timeout-based calculation for larger directories
        return Get-DirectorySizeWithTimeout -Path $Path -TimeoutSeconds 45 -Config $Config

    } catch {
        Write-Log "Error in Get-DirectorySizeOptimized for $Path : $_" -Level "ERROR"
        return 10MB  # Default estimate for error cases
    }
}

function Get-DirectorySizeWithTimeout {
    param (
        [Parameter(Mandatory=$true)]
        [string]$Path,
        [int]$TimeoutSeconds = 45,
        [object]$Config = $null
    )

    try {
        Write-Log "Calculating directory size with $TimeoutSeconds second timeout: $Path" -Level "DEBUG"

        # Use PowerShell method only (robocopy removed for reliability)
        Write-Log "Using PowerShell method for size calculation" -Level "DEBUG"

        # Determine if we need elevated permissions
        $needsElevation = $Path.StartsWith("C:\Windows") -or $Path.StartsWith("C:\Program Files")

        # Extract exclusion patterns from config
        $excludeFolders = @()
        $excludeFiles = @()
        if ($Config -and $Config.GlobalExclusions) {
            if ($Config.GlobalExclusions.Folders) {
                $excludeFolders = $Config.GlobalExclusions.Folders
                Write-Log "Using $($excludeFolders.Count) folder exclusion patterns" -Level "DEBUG"
            }
            if ($Config.GlobalExclusions.Files) {
                $excludeFiles = $Config.GlobalExclusions.Files
                Write-Log "Using $($excludeFiles.Count) file exclusion patterns" -Level "DEBUG"
            }
        } else {
            Write-Log "WARNING: No Config or GlobalExclusions provided - size may be incorrect" -Level "WARNING"
        }

        # Create size calculation job with better error handling
        $sizeJob = Start-Job -ScriptBlock {
            param($pathToCheck, $useGsudo, $excludeFolderPatterns, $excludeFilePatterns)

            try {
                # Helper function to check if path should be excluded
                function Test-ShouldExclude {
                    param($itemPath, $folderPatterns, $filePatterns)

                    $normalized = $itemPath.TrimEnd('\', '/')

                    # Check folder exclusions
                    foreach ($pattern in $folderPatterns) {
                        $patternNorm = $pattern.Replace('/', '\').TrimEnd('\')
                        if ($normalized -like $patternNorm -or $normalized -like "$patternNorm\*") {
                            return $true
                        }
                    }

                    # Check file exclusions
                    if (Test-Path $itemPath -PathType Leaf -ErrorAction SilentlyContinue) {
                        $fileName = Split-Path $itemPath -Leaf
                        foreach ($pattern in $filePatterns) {
                            if ($fileName -like $pattern) {
                                return $true
                            }
                        }
                    }

                    return $false
                }

                if ($useGsudo -and (Get-Command gsudo -ErrorAction SilentlyContinue)) {
                    $allFiles = gsudo Get-ChildItem -Path $pathToCheck -Recurse -File -Force -ErrorAction SilentlyContinue
                } else {
                    $allFiles = Get-ChildItem -Path $pathToCheck -Recurse -File -Force -ErrorAction SilentlyContinue
                }

                $totalFiles = ($allFiles | Measure-Object).Count

                # Filter out excluded files
                $filteredFiles = $allFiles | Where-Object {
                    -not (Test-ShouldExclude -itemPath $_.FullName -folderPatterns $excludeFolderPatterns -filePatterns $excludeFilePatterns)
                }

                $filteredCount = ($filteredFiles | Measure-Object).Count

                # Calculate size with detailed debugging
                $sizeCalc = $filteredFiles | Measure-Object -Property Length -Sum -ErrorAction SilentlyContinue
                $sizeInBytes = $sizeCalc.Sum

                # Debug: Check a sample file
                $sampleFile = $filteredFiles | Select-Object -First 1
                $sampleInfo = if ($sampleFile) {
                    "Sample file: $($sampleFile.FullName), Length: $($sampleFile.Length), Type: $($sampleFile.GetType().Name)"
                } else {
                    "No sample file available"
                }

                # Return both size and debug info
                # Use proper null handling instead of -or which returns boolean
                $finalSize = if ($sizeInBytes) { [long]$sizeInBytes } else { 0 }

                return @{
                    Size = $finalSize
                    TotalFiles = $totalFiles
                    FilteredFiles = $filteredCount
                    ExcludedFiles = ($totalFiles - $filteredCount)
                    SumResult = $sizeInBytes
                    SampleDebug = $sampleInfo
                }
            } catch {
                # Return error info for better handling
                return @{ Error = $_.Exception.Message; Size = 0 }
            }
        } -ArgumentList $Path, $needsElevation, $excludeFolders, $excludeFiles
        
        # Wait for job with specified timeout
        if ($sizeJob | Wait-Job -Timeout $TimeoutSeconds) {
            $result = Receive-Job $sizeJob
            $jobState = $sizeJob.State
            $jobErrors = $sizeJob.ChildJobs[0].Error
            Remove-Job $sizeJob

            # Handle error results from the job
            if ($result -is [hashtable] -and $result.ContainsKey('Error')) {
                Write-Log "Permission/access error for $Path : $($result.Error)" -Level "WARNING"
                return 5MB  # Conservative estimate for permission errors
            }

            # Handle new hashtable format with debug info
            if ($result -is [hashtable] -and $result.ContainsKey('Size')) {
                $finalSize = $result.Size
                Write-Log "File count for $Path - Total: $($result.TotalFiles), After exclusions: $($result.FilteredFiles), Excluded: $($result.ExcludedFiles)" -Level "DEBUG"
                if ($result.ContainsKey('SampleDebug')) {
                    Write-Log "Sample file debug: $($result.SampleDebug)" -Level "DEBUG"
                }
                if ($result.ContainsKey('SumResult')) {
                    $sumType = if ($result.SumResult) { $result.SumResult.GetType().Name } else { 'null' }
                    Write-Log "Raw Sum result: $($result.SumResult) (Type: $sumType)" -Level "DEBUG"
                }
                Write-Log "Calculated size for $Path : $([math]::Round($finalSize / 1MB, 2)) MB" -Level "DEBUG"
                return $finalSize
            }

            # Legacy format (single value)
            $finalSize = if ($result) { [long]$result } else { 0 }

            # Debug logging for 0 results
            if ($finalSize -eq 0) {
                Write-Log "Size calculation returned 0 for $Path (Job State: $jobState)" -Level "WARNING"
                if ($jobErrors.Count -gt 0) {
                    Write-Log "Job errors: $($jobErrors -join '; ')" -Level "WARNING"
                }
            }

            Write-Log "Calculated size for $Path : $([math]::Round($finalSize / 1MB, 2)) MB" -Level "DEBUG"
            return $finalSize
        } 
        else {
            # Job timed out
            Write-Log "Directory size calculation timed out after $TimeoutSeconds seconds: $Path" -Level "WARNING"
            Stop-Job $sizeJob -ErrorAction SilentlyContinue
            Remove-Job $sizeJob -ErrorAction SilentlyContinue
            
            # Return size estimate based on timeout duration (larger timeout = bigger directory estimate)
            $timeoutEstimate = [math]::Max(10MB, $TimeoutSeconds * 1MB)
            return $timeoutEstimate
        }
        
    } catch {
        Write-Log "Error in Get-DirectorySizeWithTimeout for $Path : $_" -Level "ERROR"
        return 10MB  # Default fallback estimate
    }
}

# Robocopy size calculation removed - was causing timeouts and reliability issues

#endregion

#region Missing Backup Functions

function Export-Certificates {
    param (
        [string]$DestinationPath,
        [string]$BackupName = "CertificateExport"
    )
    
    Write-Log "Starting certificate export to: $DestinationPath" -Level "INFO"
    
    try {
        # Ensure destination directory exists
        if (-not (Test-Path $DestinationPath)) {
            New-Item -ItemType Directory -Path $DestinationPath -Force | Out-Null
        }
        
        # Define certificate stores to backup
        $certStores = @(
            @{ Location = "CurrentUser"; Store = "My"; Description = "Personal" },
            @{ Location = "CurrentUser"; Store = "Root"; Description = "Trusted Root" },
            @{ Location = "CurrentUser"; Store = "CA"; Description = "Intermediate CA" },
            @{ Location = "CurrentUser"; Store = "TrustedPeople"; Description = "Trusted People" }
        )
        
        $totalExported = 0
        
        foreach ($storeInfo in $certStores) {
            try {
                $storePath = "Cert:\$($storeInfo.Location)\$($storeInfo.Store)"
                
                if (Test-Path $storePath) {
                    $certificates = Get-ChildItem -Path $storePath -ErrorAction SilentlyContinue
                    
                    if ($certificates.Count -gt 0) {
                        $storeFolder = Join-Path $DestinationPath $storeInfo.Store
                        if (-not (Test-Path $storeFolder)) {
                            New-Item -ItemType Directory -Path $storeFolder -Force | Out-Null
                        }
                        
                        # Export certificate inventory
                        $certInventory = $certificates | Select-Object Subject, Issuer, NotBefore, NotAfter, Thumbprint, FriendlyName, HasPrivateKey
                        $inventoryFile = Join-Path $storeFolder "certificate_inventory.csv"
                        $certInventory | Export-Csv -Path $inventoryFile -NoTypeInformation -Encoding UTF8
                        
                        # Export individual certificates
                        foreach ($cert in $certificates) {
                            try {
                                $certFileName = $cert.Thumbprint
                                
                                # Export public certificate (.cer)
                                $cerFile = Join-Path $storeFolder "$certFileName.cer"
                                Export-Certificate -Cert $cert -FilePath $cerFile -ErrorAction SilentlyContinue | Out-Null
                                
                                # Export with private key (.pfx) if available and exportable
                                if ($cert.HasPrivateKey) {
                                    try {
                                        $pfxFile = Join-Path $storeFolder "$certFileName.pfx"
                                        $securePassword = ConvertTo-SecureString -String "BackupPassword123!" -Force -AsPlainText
                                        Export-PfxCertificate -Cert $cert -FilePath $pfxFile -Password $securePassword -ErrorAction SilentlyContinue | Out-Null
                                    } catch {
                                        # Private key not exportable or other issue
                                        Write-Log "Could not export private key for certificate: $($cert.Subject)" -Level "DEBUG"
                                    }
                                }
                                
                                $totalExported++
                            } catch {
                                Write-Log "Error exporting individual certificate $($cert.Subject): $_" -Level "WARNING"
                            }
                        }
                        
                        Write-Log "Exported $($certificates.Count) certificates from $($storeInfo.Description) store" -Level "INFO"
                    } else {
                        Write-Log "No certificates found in $($storeInfo.Description) store" -Level "DEBUG"
                    }
                } else {
                    Write-Log "Certificate store not found: $storePath" -Level "DEBUG"
                }
            } catch {
                Write-Log "Error processing certificate store $($storeInfo.Description): $_" -Level "WARNING"
            }
        }
        
        # Create summary file
        $summaryFile = Join-Path $DestinationPath "certificate_export_summary.txt"
        $summary = @"
Certificate Export Summary
==========================
Export Date: $(Get-Date)
Total Certificates Exported: $totalExported
Destination: $DestinationPath

Stores Processed:
$($certStores | ForEach-Object { "- $($_.Description) ($($_.Location)\$($_.Store))" } | Out-String)

Note: 
- .cer files contain public certificates only
- .pfx files contain private keys (password: BackupPassword123!)
- certificate_inventory.csv contains certificate details
"@
        
        $summary | Out-File -FilePath $summaryFile -Encoding UTF8
        
        Write-Log "Certificate export completed. Total exported: $totalExported" -Level "INFO"
        return $true
        
    } catch {
        Write-Log "Error during certificate export: $_" -Level "ERROR"
        return $false
    }
}

function Backup-DoskeyMacros {
    param (
        [string]$DestinationPath
    )
    
    Write-Log "Starting Doskey macros backup to: $DestinationPath" -Level "INFO"
    
    try {
        # Ensure destination directory exists
        if (-not (Test-Path $DestinationPath)) {
            New-Item -ItemType Directory -Path $DestinationPath -Force | Out-Null
        }
        
        $macroFile = Join-Path $DestinationPath "doskey_macros.txt"
        $installScript = Join-Path $DestinationPath "install_macros.cmd"
        
        # Export all doskey macros
        try {
            $macros = & doskey /MACROS 2>$null
            
            if ($macros -and $macros.Count -gt 0) {
                # Save raw macro output
                $macros | Out-File -FilePath $macroFile -Encoding UTF8
                
                # Create installation script
                $installContent = @"
@echo off
REM Doskey Macros Installation Script
REM Generated on $(Get-Date)
echo Installing Doskey macros...

"@
                
                foreach ($macro in $macros) {
                    if ($macro -and $macro.Trim() -ne "") {
                        $installContent += "doskey $macro`n"
                    }
                }
                
                $installContent += "`necho Doskey macros installed successfully!"
                $installContent | Out-File -FilePath $installScript -Encoding UTF8
                
                Write-Log "Exported $($macros.Count) Doskey macros" -Level "INFO"
            } else {
                # No macros found, create empty files with explanation
                "No Doskey macros found on $(Get-Date)" | Out-File -FilePath $macroFile -Encoding UTF8
                "@echo off`necho No Doskey macros to install." | Out-File -FilePath $installScript -Encoding UTF8
                
                Write-Log "No Doskey macros found to export" -Level "INFO"
            }
            
            # Create summary file
            $summaryFile = Join-Path $DestinationPath "doskey_summary.txt"
            $summary = @"
Doskey Macros Backup Summary
============================
Backup Date: $(Get-Date)
Macros Found: $($macros.Count)
Files Created:
- doskey_macros.txt (raw macro definitions)
- install_macros.cmd (installation script)

To restore macros:
1. Run install_macros.cmd
2. Or manually run: doskey /MACROFILE=doskey_macros.txt
"@
            
            $summary | Out-File -FilePath $summaryFile -Encoding UTF8
            
            return $true
            
        } catch {
            Write-Log "Error executing doskey command: $_" -Level "ERROR"
            
            # Create error file for debugging
            $errorFile = Join-Path $DestinationPath "doskey_error.txt"
            "Error backing up Doskey macros on $(Get-Date): $_" | Out-File -FilePath $errorFile -Encoding UTF8
            
            return $false
        }
        
    } catch {
        Write-Log "Error during Doskey macros backup: $_" -Level "ERROR"
        return $false
    }
}

#endregion

#region Windows Settings Specific Functions

function Export-RegistryKey {
    param(
        [string]$KeyPath,
        [string]$FileName,
        [string]$BackupDir
    )
    
    try {
        $regFile = Join-Path $BackupDir "Registry\$FileName.reg"
        
        # Ensure Registry directory exists
        $registryDir = Join-Path $BackupDir "Registry"
        if (-not (Test-Path $registryDir)) {
            New-Item -ItemType Directory -Path $registryDir -Force | Out-Null
        }
        
        # Skip problematic large registry keys
        $problematicKeys = @(
            "HKEY_CLASSES_ROOT",
            "HKEY_LOCAL_MACHINE\SOFTWARE\Classes",
            "HKEY_LOCAL_MACHINE\SOFTWARE\Classes\*\shellex\ContextMenuHandlers",
            "HKEY_CLASSES_ROOT\*\shellex\ContextMenuHandlers"
        )
        
        if ($problematicKeys -contains $KeyPath) {
            Write-Log "Skipping large registry key that could hang: $KeyPath" -Level "WARNING"
            return $false
        }
        
        Write-Log "Exporting registry key: $KeyPath" -Level "DEBUG"
        
        # Export registry key with proper quoting and timeout
        $processInfo = New-Object System.Diagnostics.ProcessStartInfo
        $processInfo.FileName = "regedit.exe"
        $processInfo.Arguments = "/e `"$regFile`" `"$KeyPath`""
        $processInfo.WindowStyle = [System.Diagnostics.ProcessWindowStyle]::Hidden
        $processInfo.UseShellExecute = $false
        
        $process = [System.Diagnostics.Process]::Start($processInfo)
        
        # Wait for process with 30 second timeout
        $timeoutMs = 90000 # 90 seconds
        if ($process.WaitForExit($timeoutMs)) {
            if ($process.ExitCode -eq 0) {
                if (Test-Path $regFile) {
                    $fileSize = (Get-Item $regFile).Length
                    Write-Log "Exported registry: $FileName.reg ($fileSize bytes)" -Level "INFO"
                    return $true
                } else {
                    Write-Log "Registry export succeeded but file not found: $regFile (key may not exist: $KeyPath)" -Level "WARNING"
                    return $false
                }
            } else {
                Write-Log "Registry export failed with exit code: $($process.ExitCode) for key: $KeyPath" -Level "ERROR"
                return $false
            }
        } else {
            # Process timed out
            Write-Log "Registry export timed out after 30 seconds: $KeyPath" -Level "ERROR"
            try {
                $process.Kill()
                $process.WaitForExit(5000) # Wait up to 5 seconds for cleanup
            } catch {
                Write-Log "Could not kill timed out registry process: $_" -Level "WARNING"
            }
            return $false
        }
    }
    catch {
        Write-Log "Error exporting registry $FileName : $($_.Exception.Message)" -Level "ERROR"
        return $false
    }
    finally {
        if ($process -and -not $process.HasExited) {
            try {
                $process.Kill()
            } catch {
                # Process already ended
            }
        }
    }
}

function Initialize-WindowsBackupDirectory {
    param([string]$Path)
    
    $subFolders = @("Registry", "Files", "Lists", "Scripts")
    $fileSubFolders = @("QuickAccess", "Libraries", "SendTo", "StartupAll", "StartupUser", "Tasks", "EventViewer", "SSH", "Browsers", "Office", "SnippingTool")
    
    if (!(Test-Path $Path)) {
        New-Item -ItemType Directory -Path $Path -Force | Out-Null
    }
    
    foreach ($folder in $subFolders) {
        $folderPath = Join-Path $Path $folder
        if (!(Test-Path $folderPath)) {
            New-Item -ItemType Directory -Path $folderPath -Force | Out-Null
        }
    }
    
    # Create Files subfolders
    $filesPath = Join-Path $Path "Files"
    foreach ($subFolder in $fileSubFolders) {
        $subFolderPath = Join-Path $filesPath $subFolder
        if (!(Test-Path $subFolderPath)) {
            New-Item -ItemType Directory -Path $subFolderPath -Force | Out-Null
        }
    }
    
    Write-Log "Windows backup directory structure created: $Path" -Level "INFO"
}

function Copy-WindowsSettingsFile {
    param(
        [string]$SourcePath,
        [string]$DestinationPath,
        [string]$Description = ""
    )
    
    try {
        # Expand PowerShell environment variables correctly
        $expandedSource = $ExecutionContext.InvokeCommand.ExpandString($SourcePath)
        
        if (Test-Path $expandedSource) {
            $destinationDir = Split-Path $DestinationPath -Parent
            if (-not (Test-Path $destinationDir)) {
                New-Item -ItemType Directory -Path $destinationDir -Force | Out-Null
            }
            
            Copy-Item $expandedSource $DestinationPath -Force -Recurse -ErrorAction Stop
            Write-Log "Copied file: $expandedSource to $DestinationPath" -Level "INFO"
            return $true
        } else {
            Write-Log "Source file not found: $expandedSource" -Level "WARNING"
            return $false
        }
    }
    catch {
        Write-Log "Error copying file $SourcePath : $($_.Exception.Message)" -Level "ERROR"
        return $false
    }
}

function Copy-WindowsSettingsFolder {
    param(
        [string]$SourcePath,
        [string]$DestinationPath,
        [string]$Description = ""
    )
    
    try {
        # Expand environment variables and handle special folders
        if ($SourcePath -eq "SendTo") {
            $expandedSource = [Environment]::GetFolderPath("SendTo")
        } elseif ($SourcePath -eq "Startup") {
            $expandedSource = [Environment]::GetFolderPath("Startup")
        } else {
            $expandedSource = $ExecutionContext.InvokeCommand.ExpandString($SourcePath)
        }
        
        if (Test-Path $expandedSource) {
            if (-not (Test-Path $DestinationPath)) {
                New-Item -ItemType Directory -Path $DestinationPath -Force | Out-Null
            }
            
            Copy-Item "$expandedSource\*" $DestinationPath -Recurse -Force -ErrorAction SilentlyContinue
            $itemCount = (Get-ChildItem $DestinationPath -Recurse).Count
            Write-Log "Copied folder: $expandedSource to $DestinationPath ($itemCount items)" -Level "INFO"
            return $true
        } else {
            Write-Log "Source folder not found: $expandedSource" -Level "WARNING"
            return $false
        }
    }
    catch {
        Write-Log "Error copying folder $SourcePath : $($_.Exception.Message)" -Level "ERROR"
        return $false
    }
}

#endregion

#region Performance Enhanced Functions

# Get-SmartBackupFileName - Intelligently name backup files based on source path
function Get-SmartBackupFileName {
    param (
        [string]$SourcePath
    )

    $fileName = Split-Path $SourcePath -Leaf
    $pathLower = $SourcePath.ToLower()

    # Determine appropriate prefix based on path content
    $prefix = ""

    # Handle PowerShell paths
    if ($pathLower -like "*windowspowershell*") {
        $prefix = "PS5_"
    }
    elseif ($pathLower -like "*powershell*") {
        $prefix = "PS7_"
    }
    # Handle browser paths
    elseif ($pathLower -like "*chrome*") {
        $prefix = "Chrome_"
    }
    elseif ($pathLower -like "*edge*") {
        $prefix = "Edge_"
    }
    elseif ($pathLower -like "*brave*") {
        $prefix = "Brave_"
    }
    elseif ($pathLower -like "*firefox*") {
        $prefix = "Firefox_"
    }
    # Handle Adult/Games paths
    elseif ($pathLower -like "*\games\adult\*" -or $pathLower -like "*/games/adult/*") {
        # Extract game name from path
        $gameName = ""
        $pathParts = $SourcePath -split '[\\\/]'
        $adultIndex = -1
        for ($i = 0; $i -lt $pathParts.Length; $i++) {
            if ($pathParts[$i].ToLower() -eq "adult") {
                $adultIndex = $i
                break
            }
        }
        if ($adultIndex -ge 0 -and ($adultIndex + 1) -lt $pathParts.Length) {
            $gameName = $pathParts[$adultIndex + 1]
            $gameName = $gameName -replace '[^\w\-\.]', '_'
            if ($gameName.Length -gt 15) {
                $gameName = $gameName.Substring(0, 15)
            }
            $prefix = "Game_${gameName}_"
        }
    }
    elseif ($pathLower -like "*\appdata\locallow\*" -or $pathLower -like "*/appdata/locallow/*") {
        # Handle LocalLow game saves
        $gameName = ""
        $pathParts = $SourcePath -split '[\\\/]'
        $localLowIndex = -1
        for ($i = 0; $i -lt $pathParts.Length; $i++) {
            if ($pathParts[$i].ToLower() -eq "locallow") {
                $localLowIndex = $i
                break
            }
        }
        if ($localLowIndex -ge 0 -and ($localLowIndex + 1) -lt $pathParts.Length) {
            $gameName = $pathParts[$localLowIndex + 1]
            $gameName = $gameName -replace '[^\w\-\.]', '_'
            if ($gameName.Length -gt 15) {
                $gameName = $gameName.Substring(0, 15)
            }
            $prefix = "Game_${gameName}_"
        }
    }
    elseif ($pathLower -like "*\games\*" -or $pathLower -like "*/games/*") {
        # Handle other Games paths
        $gameName = ""
        $pathParts = $SourcePath -split '[\\\/]'
        $gamesIndex = -1
        for ($i = 0; $i -lt $pathParts.Length; $i++) {
            if ($pathParts[$i].ToLower() -eq "games") {
                $gamesIndex = $i
                break
            }
        }
        if ($gamesIndex -ge 0 -and ($gamesIndex + 1) -lt $pathParts.Length) {
            $nextFolder = $pathParts[$gamesIndex + 1]
            if ($nextFolder.ToLower() -eq "adult" -and ($gamesIndex + 2) -lt $pathParts.Length) {
                $gameName = $pathParts[$gamesIndex + 2]
            } else {
                $gameName = $nextFolder
            }
            $gameName = $gameName -replace '[^\w\-\.]', '_'
            if ($gameName.Length -gt 15) {
                $gameName = $gameName.Substring(0, 15)
            }
            $prefix = "Game_${gameName}_"
        }
    }

    return "$prefix$fileName"
}

# Optimized file backup with intelligent path validation
function Backup-Files-Optimized {
    param (
        [string[]]$SourcePaths,
        [string]$DestinationPath,
        [string]$BackupName,
        [switch]$UseParallel = $false,
        [int]$MaxParallelJobs = 4,
        [object]$Config = $null
    )

    Write-Log "Starting optimized file backup for $BackupName (Copy-Item based)" -Level "INFO"

    if (-not (Test-PathAndLog -Path $DestinationPath -ItemType "Directory")) {
        New-Item -ItemType Directory -Path $DestinationPath -Force | Out-Null
    }

    # Pre-validate paths to avoid redundant checks during processing
    $validPaths = Get-ValidatedPaths -Paths $SourcePaths -Config $Config
    Write-Log "Pre-validated paths: $($validPaths.Count) out of $($SourcePaths.Count) paths are valid" -Level "INFO"

    # Use optimized sequential processing
    Write-Log "Using optimized Copy-Item sequential processing" -Level "DEBUG"
    Backup-Files-Sequential-Optimized -ValidatedPaths $validPaths -DestinationPath $DestinationPath -Config $Config

    return $DestinationPath
}

function Get-ValidatedPaths {
    param (
        [string[]]$Paths,
        [object]$Config = $null
    )

    $validPaths = @()
    $batchSize = 10

    # Process paths in batches for better performance feedback
    for ($i = 0; $i -lt $Paths.Count; $i += $batchSize) {
        $batch = $Paths[$i..([Math]::Min($i + $batchSize - 1, $Paths.Count - 1))]

        foreach ($path in $batch) {
            # Expand environment variables efficiently
            $expandedPath = [System.Environment]::ExpandEnvironmentVariables($path)

            # Check if path is excluded
            if ($Config -and (Test-PathExcluded -Path $expandedPath -Config $Config)) {
                Write-Log "Path excluded by GlobalExclusions: $path" -Level "INFO"
                continue
            }

            if (Test-Path $expandedPath -ErrorAction SilentlyContinue) {
                $validPaths += [PSCustomObject]@{
                    OriginalPath = $path
                    ExpandedPath = $expandedPath
                    IsDirectory = Test-Path $expandedPath -PathType Container
                    Size = if (Test-Path $expandedPath -PathType Leaf) { (Get-Item $expandedPath).Length } else { 0 }
                }
            } else {
                Write-Log "Path validation failed (skipping): $path" -Level "DEBUG"
            }
        }

        # Show progress for large path lists
        if ($Paths.Count -gt 20) {
            $percentComplete = [Math]::Min(100, ($i / $Paths.Count) * 100)
            Write-Progress -Activity "Validating paths" -PercentComplete $percentComplete -Status "$i of $($Paths.Count)"
        }
    }

    if ($Paths.Count -gt 20) {
        Write-Progress -Activity "Validating paths" -Completed
    }

    return $validPaths
}

function Copy-ItemWithExclusions {
    param(
        [string]$Source,
        [string]$Destination,
        [object]$Config,
        [bool]$IsDirectory
    )

    if ($IsDirectory) {
        # Create destination directory
        if (-not (Test-Path $Destination)) {
            New-Item -ItemType Directory -Path $Destination -Force | Out-Null
        }

        # Get all items in the source directory
        $items = Get-ChildItem -Path $Source -ErrorAction SilentlyContinue

        foreach ($item in $items) {
            # Check if item is excluded
            if ($Config -and (Test-PathExcluded -Path $item.FullName -Config $Config)) {
                Write-Log "Skipping excluded item: $($item.FullName)" -Level "DEBUG"
                continue
            }

            $destItem = Join-Path $Destination $item.Name

            if ($item.PSIsContainer) {
                # Recursively copy subdirectory with exclusions
                Copy-ItemWithExclusions -Source $item.FullName -Destination $destItem -Config $Config -IsDirectory $true
            } else {
                # Copy file
                Copy-Item -Path $item.FullName -Destination $destItem -Force -ErrorAction Stop
            }
        }
    } else {
        # Simple file copy
        Copy-Item -Path $Source -Destination $Destination -Force -ErrorAction Stop
    }
}

function Backup-Files-Sequential-Optimized {
    param (
        [PSCustomObject[]]$ValidatedPaths,
        [string]$DestinationPath,
        [object]$Config = $null
    )

    # Initialize speed tracking (Issue #17)
    $script:BackupSpeedStats.StartTime = Get-Date
    $script:BackupSpeedStats.BytesProcessed = 0
    $script:BackupSpeedStats.FileCount = 0

    foreach ($pathInfo in $ValidatedPaths) {
        try {
            # Use Get-SmartBackupFileName for consistent naming
            $itemName = Get-SmartBackupFileName -SourcePath $pathInfo.ExpandedPath
            $destPath = Join-Path $DestinationPath $itemName

            Write-Log "Copying: $($pathInfo.OriginalPath)" -Level "DEBUG"

            # Use custom copy function that respects exclusions
            Copy-ItemWithExclusions -Source $pathInfo.ExpandedPath `
                                   -Destination $destPath `
                                   -Config $Config `
                                   -IsDirectory $pathInfo.IsDirectory

            # Track bytes processed for speed calculation (Issue #17)
            try {
                if (Test-Path $pathInfo.ExpandedPath -PathType Leaf -ErrorAction SilentlyContinue) {
                    $fileItem = Get-Item $pathInfo.ExpandedPath -ErrorAction SilentlyContinue
                    if ($fileItem -and $fileItem.Length) {
                        $script:BackupSpeedStats.BytesProcessed += $fileItem.Length
                    }
                } elseif (Test-Path $pathInfo.ExpandedPath -PathType Container -ErrorAction SilentlyContinue) {
                    $folderSize = (Get-ChildItem $pathInfo.ExpandedPath -Recurse -File -ErrorAction SilentlyContinue |
                                   Measure-Object -Property Length -Sum -ErrorAction SilentlyContinue).Sum
                    if ($folderSize) {
                        $script:BackupSpeedStats.BytesProcessed += $folderSize
                    }
                }
            } catch {
                # Silently ignore size calculation errors
            }
            $script:BackupSpeedStats.FileCount++

            # Update speed every 10 files (Issue #17)
            if ($script:BackupSpeedStats.FileCount % 10 -eq 0) {
                $stats = Measure-BackupSpeed -StartTime $script:BackupSpeedStats.StartTime -BytesProcessed $script:BackupSpeedStats.BytesProcessed
                Write-Log "Backup progress: $($script:BackupSpeedStats.FileCount) items, $($stats.TotalMB) MB at $($stats.Speed_MBps) MB/s" -Level "INFO"
            }

            Write-Log "Successfully backed up: $($pathInfo.OriginalPath)" -Level "INFO"
        } catch {
            $errorMessage = "Failed to backup $($pathInfo.OriginalPath). Error: $_"
            Write-Log $errorMessage -Level "ERROR"
            throw $errorMessage
        }
    }

    # Final speed report (Issue #17) - always show, even if 0 MB
    $finalStats = Measure-BackupSpeed -StartTime $script:BackupSpeedStats.StartTime -BytesProcessed $script:BackupSpeedStats.BytesProcessed
    Write-Log "Backup completed: $($script:BackupSpeedStats.FileCount) items, $($finalStats.TotalMB) MB, average speed: $($finalStats.Speed_MBps) MB/s" -Level "INFO"
}

# Optimized 7zip compression with multi-threading
function Build-SevenZipArguments {
    <#
    .SYNOPSIS
    Builds optimized 7zip command line arguments.
    .DESCRIPTION
    Helper function extracted for better readability (Phase 5 #25).
    #>
    param (
        [string]$ArchiveFile,
        [string]$ArchiveFormat,
        [int]$CompressionLevel,
        [bool]$UseMultiThreading
    )

    $sevenZipArgs = @(
        "a",                                    # Add to archive
        "-t$ArchiveFormat",                     # Archive format
        "-mx=$CompressionLevel",                # Compression level
        "-spf",                                 # Store full paths
        "-y"                                    # Yes to all prompts
    )

    # Add multi-threading support
    if ($UseMultiThreading) {
        $sevenZipArgs += "-mmt=on"              # Enable multi-threading

        # Optimize based on archive format
        if ($ArchiveFormat -eq "7z") {
            $sevenZipArgs += "-md=64m"          # Dictionary size for better compression
            $sevenZipArgs += "-mfb=64"          # Fast bytes for 7z
        } else {
            $sevenZipArgs += "-mem=AES256"      # Encryption method for ZIP
        }
    }

    # Add archive file path (quoted to handle spaces)
    $sevenZipArgs += "`"$ArchiveFile`""

    return $sevenZipArgs
}

function Compress-Backup-Optimized {
    <#
    .SYNOPSIS
    Compresses backup files using 7-Zip with progress monitoring.
    .DESCRIPTION
    Refactored to extract argument building (Phase 5 #25).
    Main function reduced from 177 to ~140 lines.
    #>
    param (
        [string[]]$SourcePaths,
        [string]$DestinationPath,
        [string]$ArchiveName,
        [string]$SevenZipPath,
        [int]$CompressionLevel,
        [string]$TempPath = $env:TEMP,
        [switch]$UseMultiThreading = $true,
        [string]$ArchiveFormat = "zip"  # "zip" or "7z"
    )

    Write-Log "Starting optimized compression (level: $CompressionLevel, format: $ArchiveFormat)" -Level "INFO"

    $archiveExtension = if ($ArchiveFormat -eq "7z") { ".7z" } else { ".zip" }
    $archiveFile = Join-Path $DestinationPath "$ArchiveName$archiveExtension"

    # Ensure destination directory exists
    if (-not (Test-Path $DestinationPath)) {
        New-Item -ItemType Directory -Path $DestinationPath -Force | Out-Null
    }

    # Build optimized 7zip arguments
    $sevenZipArgs = Build-SevenZipArguments -ArchiveFile $archiveFile `
                                            -ArchiveFormat $ArchiveFormat `
                                            -CompressionLevel $CompressionLevel `
                                            -UseMultiThreading $UseMultiThreading.IsPresent

    # Create a temporary file list for better performance with many files
    $tempFile = Join-Path $TempPath "7zip_sources_optimized.tmp"
    try {
        # Convert source paths to absolute paths and write to temp file
        $absolutePaths = $SourcePaths | ForEach-Object {
            (Resolve-Path $_).Path
        }
        $absolutePaths | Out-File -FilePath $tempFile -Encoding UTF8

        # Add temp file reference
        $sevenZipArgs += "@$tempFile"

        Write-Log "7zip command: $SevenZipPath $($sevenZipArgs -join ' ')" -Level "DEBUG"

        # Execute 7zip with progress monitoring
        $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()

        # Add progress output flag
        $sevenZipArgs += "-bsp1"  # Output progress to stdout

        # Create progress output file
        $progressFile = Join-Path $TempPath "7zip_progress.txt"
        if (Test-Path $progressFile) { Remove-Item $progressFile -Force -ErrorAction SilentlyContinue | Out-Null }

        # Start 7-Zip process
        $processInfo = New-Object System.Diagnostics.ProcessStartInfo
        $processInfo.FileName = $SevenZipPath
        $processInfo.Arguments = ($sevenZipArgs -join ' ')
        $processInfo.RedirectStandardOutput = $true
        $processInfo.RedirectStandardError = $true
        $processInfo.UseShellExecute = $false
        $processInfo.CreateNoWindow = $true

        $process = New-Object System.Diagnostics.Process
        $process.StartInfo = $processInfo

        # Capture output for later analysis
        $outputBuilder = New-Object System.Text.StringBuilder
        $errorBuilder = New-Object System.Text.StringBuilder

        $outputHandler = {
            if ($EventArgs.Data) {
                $null = $outputBuilder.AppendLine($EventArgs.Data)

                # Parse progress percentage
                if ($EventArgs.Data -match '(\d+)%') {
                    $percent = [int]$matches[1]
                    Write-Progress -Activity "Compressing backup archive" `
                                   -Status "Progress: $percent%" `
                                   -PercentComplete $percent
                }
            }
        }

        $errorHandler = {
            if ($EventArgs.Data) {
                $null = $errorBuilder.AppendLine($EventArgs.Data)
            }
        }

        # Register event handlers
        $outputEvent = Register-ObjectEvent -InputObject $process `
            -EventName OutputDataReceived `
            -Action $outputHandler

        $errorEvent = Register-ObjectEvent -InputObject $process `
            -EventName ErrorDataReceived `
            -Action $errorHandler

        try {
            $process.Start() | Out-Null
            $process.BeginOutputReadLine()
            $process.BeginErrorReadLine()
            $process.WaitForExit()

            # Complete the progress bar
            Write-Progress -Activity "Compressing backup archive" -Completed

            $stopwatch.Stop()

            # Get output
            $output = $outputBuilder.ToString() -split "`n"
            $errorOutput = $errorBuilder.ToString()

            # Log compression time
            Write-Log "Compression completed in $($stopwatch.Elapsed.TotalSeconds.ToString('F2')) seconds" -Level "INFO"
        }
        finally {
            # Clean up event handlers
            Unregister-Event -SourceIdentifier $outputEvent.Name -ErrorAction SilentlyContinue
            Unregister-Event -SourceIdentifier $errorEvent.Name -ErrorAction SilentlyContinue
            $outputEvent, $errorEvent | Remove-Job -Force -ErrorAction SilentlyContinue

            if (Test-Path $progressFile) {
                Remove-Item $progressFile -Force -ErrorAction SilentlyContinue | Out-Null
            }
        }

        # Check for warnings and errors
        $warnings = $output | Where-Object { $_ -match "WARNING:" }
        $errors = $output | Where-Object { $_ -match "ERROR:" }

        foreach ($warning in $warnings) {
            Write-Log "7-Zip Warning: $warning" -Level "WARNING"
        }

        foreach ($error in $errors) {
            Write-Log "7-Zip Error: $error" -Level "ERROR"
        }

        # Verify archive was created
        if (Test-Path $archiveFile) {
            $archiveSize = (Get-Item $archiveFile).Length
            $archiveSizeMB = [math]::Round($archiveSize / 1MB, 2)
            Write-Log "Archive created successfully: $archiveFile ($archiveSizeMB MB)" -Level "INFO"
            return $archiveFile
        } else {
            throw "Archive file was not created: $archiveFile"
        }

    } catch {
        Write-Log "Failed to create optimized archive: $_" -Level "ERROR"
        return $null
    } finally {
        # Clean up temp file
        if (Test-Path $tempFile) {
            Remove-Item -Path $tempFile -Force -ErrorAction SilentlyContinue | Out-Null
        }
    }
}

# Performance measurement function
function Measure-BackupPerformance {
    param (
        [scriptblock]$Operation,
        [string]$OperationName
    )

    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    $memoryBefore = [GC]::GetTotalMemory($false)

    try {
        $result = & $Operation
        $success = $true
    } catch {
        $success = $false
        $error = $_
        throw $_
    } finally {
        $stopwatch.Stop()
        $memoryAfter = [GC]::GetTotalMemory($false)
        $memoryUsed = [math]::Round(($memoryAfter - $memoryBefore) / 1MB, 2)

        $perfMessage = "$OperationName completed in $($stopwatch.Elapsed.TotalSeconds.ToString('F2'))s"
        if ($memoryUsed -gt 0) {
            $perfMessage += " (Memory: +$memoryUsed MB)"
        }

        if ($success) {
            Write-Log "PERFORMANCE: $perfMessage" -Level "INFO"
        } else {
            Write-Log "PERFORMANCE: $perfMessage (FAILED)" -Level "ERROR"
        }
    }

    return $result
}

# Optimized registry export with timeout handling
function Export-RegistryKey-Optimized {
    param(
        [string]$KeyPath,
        [string]$FileName,
        [string]$BackupDir,
        [int]$TimeoutSeconds = 60
    )

    # Skip known problematic large keys entirely
    $problematicKeys = @(
        "HKEY_CLASSES_ROOT",
        "HKEY_LOCAL_MACHINE\SOFTWARE\Classes",
        "HKEY_LOCAL_MACHINE\SOFTWARE\Classes\*\shellex\ContextMenuHandlers"
    )

    if ($problematicKeys -contains $KeyPath) {
        Write-Log "Skipping known problematic large registry key: $KeyPath" -Level "INFO"
        return $false
    }

    try {
        $regFile = Join-Path $BackupDir "Registry\$FileName.reg"

        # Ensure Registry directory exists
        $registryDir = Join-Path $BackupDir "Registry"
        if (-not (Test-Path $registryDir)) {
            New-Item -ItemType Directory -Path $registryDir -Force | Out-Null
        }

        Write-Log "Exporting registry key with $TimeoutSeconds second timeout: $KeyPath" -Level "DEBUG"

        # Use Start-Process for better timeout control
        $processInfo = New-Object System.Diagnostics.ProcessStartInfo
        $processInfo.FileName = "regedit.exe"
        $processInfo.Arguments = "/e `"$regFile`" `"$KeyPath`""
        $processInfo.WindowStyle = [System.Diagnostics.ProcessWindowStyle]::Hidden
        $processInfo.UseShellExecute = $false
        $processInfo.CreateNoWindow = $true

        $process = [System.Diagnostics.Process]::Start($processInfo)

        if ($process.WaitForExit($TimeoutSeconds * 1000)) {
            if ($process.ExitCode -eq 0) {
                if (Test-Path $regFile) {
                    $fileSize = (Get-Item $regFile).Length
                    Write-Log "Registry exported successfully: $FileName.reg ($fileSize bytes)" -Level "INFO"
                    return $true
                } else {
                    Write-Log "Registry export succeeded but file not found: $regFile (key may not exist: $KeyPath)" -Level "WARNING"
                    return $false
                }
            } else {
                Write-Log "Registry export failed with exit code: $($process.ExitCode) for key: $KeyPath" -Level "ERROR"
                return $false
            }
        } else {
            # Process timed out
            Write-Log "Registry export timed out after $TimeoutSeconds seconds: $KeyPath" -Level "WARNING"
            try {
                $process.Kill()
                $process.WaitForExit(5000)
            } catch {
                Write-Log "Could not kill timed out registry process: $_" -Level "WARNING"
            }
            return $false
        }
    }
    catch {
        Write-Log "Error exporting registry $FileName : $($_.Exception.Message)" -Level "ERROR"
        return $false
    }
    finally {
        if ($process -and -not $process.HasExited) {
            try {
                $process.Kill()
                $process.Dispose()
            } catch {
                # Process already ended
            }
        }
    }
}

#endregion

# Functions are available through dot-sourcing