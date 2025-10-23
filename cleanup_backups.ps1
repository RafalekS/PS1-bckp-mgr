#Requires -Version 5.1

<#
.SYNOPSIS
    Automated backup cleanup script
    
.DESCRIPTION
    Cleans up old backup files and database entries based on retention policies.
    Supports dry-run mode for safe testing and scheduled task automation.
    
.PARAMETER Force
    Actually delete backups. Without this parameter, script runs in dry-run mode.
    
.PARAMETER OlderThan
    Delete backups older than specified number of days, regardless of count limits.
    Takes priority over MaxPerType limits.
    
.PARAMETER DryRun
    Explicitly enable dry-run mode (show what would be deleted without deleting).
    This is the default behavior when no parameters are provided.
    
.PARAMETER LogLevel
    Sets the logging level. Default: INFO
    
.PARAMETER ConfigFile
    Path to the backup configuration file. Default: config\bkp_cfg.json
    
.EXAMPLES
    .\cleanup_backups.ps1
    Shows what would be deleted (dry-run mode)
    
    .\cleanup_backups.ps1 -Force
    Actually deletes old backups based on retention policy
    
    .\cleanup_backups.ps1 -OlderThan 30 -DryRun
    Shows backups older than 30 days that would be deleted
    
    .\cleanup_backups.ps1 -OlderThan 30 -Force
    Deletes all backups older than 30 days
    
.NOTES
    Retention Policy:
    - Games: Keep 10 backups
    - All other types: Keep 5 backups
    - OlderThan parameter overrides count limits
    - Only deletes when both file and database entry exist
#>

[CmdletBinding()]
param (
    [Parameter(Mandatory=$false, HelpMessage="Actually delete backups (default is dry-run)")]
    [switch]$Force,
    
    [Parameter(Mandatory=$false, HelpMessage="Delete backups older than specified days")]
    [int]$OlderThan,
    
    [Parameter(Mandatory=$false, HelpMessage="Explicitly enable dry-run mode")]
    [switch]$DryRun,
    
    [Parameter(Mandatory=$false, HelpMessage="Sets the logging level")]
    [ValidateSet("INFO", "DEBUG", "WARNING", "ERROR")]
    [string]$LogLevel = "INFO",
    
    [Parameter(Mandatory=$false, HelpMessage="Path to the backup configuration file")]
    [ValidateScript({Test-Path $_ -PathType 'Leaf'})]
    [string]$ConfigFile = "config\bkp_cfg.json"
)

# Import required modules
. "$PSScriptRoot\BackupUtilities.ps1"

# Load SQLite assembly
Add-Type -Path "db\System.Data.SQLite.dll"

# Global variables
$script:DeletedCount = 0
$script:DeletedSize = 0
$script:SkippedCount = 0
$script:ErrorCount = 0

#region Configuration and Initialization

function Initialize-CleanupLogging {
    param ([string]$LogLevel)
    
    $logPath = "log\delete.log"
    $logFolder = Split-Path $logPath -Parent
    if (-not (Test-Path $logFolder)) {
        New-Item -ItemType Directory -Path $logFolder -Force | Out-Null
    }
    
    Initialize-Logging -LogLevel $LogLevel -LogFilePath $logPath
    Write-Log "=== Backup Cleanup Started ===" -Level "INFO"
}

function Get-RetentionLimits {
    return @{
        "Games" = 10
        "Default" = 5
    }
}

#endregion

#region Database Operations

function Get-AllBackups {
    $databasePath = Resolve-Path ".\db\backup_history.db"
    
    if (-not (Test-Path $databasePath)) {
        Write-Log "Database file not found at $databasePath" -Level "ERROR"
        return @()
    }

    try {
        $connectionString = "Data Source=$databasePath;Version=3;"
        $connection = New-Object System.Data.SQLite.SQLiteConnection($connectionString)
        $connection.Open()

        $command = $connection.CreateCommand()
        $command.CommandText = @"
            SELECT id, backup_set_name, backup_type, destination_type, destination_path, 
                   timestamp, size_bytes 
            FROM backups 
            ORDER BY backup_type, timestamp DESC
"@
        $reader = $command.ExecuteReader()

        $backups = @()
        while ($reader.Read()) {
            # Handle different timestamp formats robustly
            $timestampString = $reader["timestamp"].ToString()
            try {
                # Try multiple parsing methods in order of specificity
                if ($timestampString -match '^\d{4}-\d{2}-\d{2}') {
                    # Format: yyyy-MM-dd HH:mm:ss
                    $timestamp = [DateTime]::ParseExact($timestampString, "yyyy-MM-dd HH:mm:ss", $null)
                } elseif ($timestampString -match '^\d{1,2}/\d{1,2}/\d{4}') {
                    # For dd/MM/yyyy vs MM/dd/yyyy, check if day > 12 to determine format
                    $dateParts = $timestampString -split '[/ :]'
                    $firstNumber = [int]$dateParts[0]
                    $secondNumber = [int]$dateParts[1]
                    
                    if ($firstNumber -gt 12) {
                        # Must be dd/MM/yyyy format (European)
                        $timestamp = [DateTime]::ParseExact($timestampString, "dd/MM/yyyy HH:mm:ss", $null)
                    } elseif ($secondNumber -gt 12) {
                        # Must be MM/dd/yyyy format (US)
                        $timestamp = [DateTime]::ParseExact($timestampString, "MM/dd/yyyy HH:mm:ss", $null)
                    } else {
                        # Ambiguous - try European format first (common in your system)
                        try {
                            $timestamp = [DateTime]::ParseExact($timestampString, "dd/MM/yyyy HH:mm:ss", $null)
                        } catch {
                            $timestamp = [DateTime]::ParseExact($timestampString, "MM/dd/yyyy HH:mm:ss", $null)
                        }
                    }
                } else {
                    # Fallback to culture-specific parsing
                    $timestamp = [DateTime]::Parse($timestampString)
                }
            } catch {
                Write-Log "Warning: Could not parse timestamp '$timestampString', using current date" -Level "WARNING"
                $timestamp = Get-Date
            }
            
            $backups += [PSCustomObject]@{
                Id = $reader["id"]
                BackupSetName = $reader["backup_set_name"]
                BackupType = $reader["backup_type"]
                DestinationType = $reader["destination_type"]
                DestinationPath = $reader["destination_path"]
                Timestamp = $timestamp
                SizeBytes = [long]$reader["size_bytes"]
                SizeGB = [math]::Round([long]$reader["size_bytes"] / 1GB, 2)
            }
        }
        return $backups
    }
    catch {
        Write-Log "Error accessing the database: $_" -Level "ERROR"
        return @()
    }
    finally {
        if ($connection -and $connection.State -eq 'Open') {
            $connection.Close()
        }
    }
}

function Remove-BackupFromDatabase {
    param ([int]$BackupId)
    
    $databasePath = Resolve-Path ".\db\backup_history.db"
    
    try {
        $connection = New-Object System.Data.SQLite.SQLiteConnection("Data Source=$databasePath;Version=3;")
        $connection.Open()
        
        $deleteCommand = $connection.CreateCommand()
        $deleteCommand.CommandText = "DELETE FROM backups WHERE id = @Id"
        $deleteCommand.Parameters.AddWithValue("@Id", $BackupId)
        $rowsAffected = $deleteCommand.ExecuteNonQuery()
        
        if ($rowsAffected -gt 0) {
            Write-Log "Removed backup ID $BackupId from database" -Level "INFO"
            return $true
        } else {
            Write-Log "No backup found in database with ID $BackupId" -Level "WARNING"
            return $false
        }
    }
    catch {
        Write-Log "Error deleting from database: $_" -Level "ERROR"
        return $false
    }
    finally {
        if ($connection -and $connection.State -eq 'Open') {
            $connection.Close()
        }
    }
}

#endregion

#region File Operations

function Test-BackupFileExists {
    param ([PSCustomObject]$Backup)
    
    $backupPath = $Backup.DestinationPath
    
    # Handle SSH destinations (can't easily test remote files)
    if ($Backup.DestinationType -eq "SSH") {
        Write-Log "Assuming SSH backup exists (cannot verify remote): $backupPath" -Level "DEBUG"
        return $true
    }
    
    # Handle local and network paths
    if (Test-Path $backupPath) {
        return $true
    } else {
        Write-Log "Backup file not found: $backupPath" -Level "WARNING"
        return $false
    }
}

function Remove-BackupFile {
    param ([PSCustomObject]$Backup, [switch]$WhatIf)
    
    $backupPath = $Backup.DestinationPath
    
    if ($WhatIf) {
        Write-Log "WOULD DELETE: $backupPath ($($Backup.SizeGB) GB)" -Level "INFO"
        return $true
    }
    
    try {
        # Handle SSH destinations
        if ($Backup.DestinationType -eq "SSH") {
            Write-Log "Cannot delete SSH backups automatically: $backupPath" -Level "WARNING"
            Write-Log "Please delete manually: $backupPath" -Level "WARNING"
            $script:SkippedCount++
            return $false
        }
        
        # Handle compressed files
        if ($backupPath.EndsWith('.zip') -or $backupPath.EndsWith('.7z')) {
            if (Test-Path $backupPath) {
                Remove-Item -Path $backupPath -Force -ErrorAction Stop
                Write-Log "Deleted backup file: $backupPath" -Level "INFO"
                
                # Try to delete empty parent directory
                $parentDir = Split-Path $backupPath -Parent
                if (Test-Path $parentDir) {
                    $remainingFiles = Get-ChildItem $parentDir -Force -ErrorAction SilentlyContinue
                    if ($remainingFiles.Count -eq 0) {
                        Remove-Item -Path $parentDir -Force -ErrorAction SilentlyContinue
                        Write-Log "Deleted empty parent directory: $parentDir" -Level "INFO"
                    }
                }
                return $true
            }
        }
        # Handle directory-based backups
        else {
            if (Test-Path $backupPath) {
                Remove-Item -Path $backupPath -Recurse -Force -ErrorAction Stop
                Write-Log "Deleted backup directory: $backupPath" -Level "INFO"
                return $true
            }
        }
        
        Write-Log "Backup file not found: $backupPath" -Level "WARNING"
        return $false
    }
    catch {
        Write-Log "Error deleting backup file $backupPath : $_" -Level "ERROR"
        $script:ErrorCount++
        return $false
    }
}

#endregion

#region Cleanup Logic

function Get-BackupsToDelete {
    param (
        [PSCustomObject[]]$AllBackups,
        [int]$OlderThanDays,
        [hashtable]$RetentionLimits
    )
    
    $backupsToDelete = @()
    $cutoffDate = if ($OlderThanDays -gt 0) { (Get-Date).AddDays(-$OlderThanDays) } else { $null }
    
    # Group backups by type
    $backupGroups = $AllBackups | Group-Object BackupType
    
    foreach ($group in $backupGroups) {
        $backupType = $group.Name
        $backups = $group.Group | Sort-Object Timestamp -Descending
        
        Write-Log "Processing backup type: $backupType ($($backups.Count) backups)" -Level "INFO"
        
        if ($cutoffDate) {
            # Delete by age - OlderThan takes priority
            $oldBackups = $backups | Where-Object { $_.Timestamp -lt $cutoffDate }
            if ($oldBackups) {
                Write-Log "Found $($oldBackups.Count) backups older than $OlderThanDays days for type: $backupType" -Level "INFO"
                $backupsToDelete += $oldBackups
            }
        } else {
            # Delete by count - keep only the specified number
            $limit = if ($RetentionLimits.ContainsKey($backupType)) { $RetentionLimits[$backupType] } else { $RetentionLimits["Default"] }
            
            if ($backups.Count -gt $limit) {
                $excessBackups = $backups | Select-Object -Skip $limit
                Write-Log "Found $($excessBackups.Count) excess backups for type: $backupType (keeping $limit)" -Level "INFO"
                $backupsToDelete += $excessBackups
            } else {
                Write-Log "No cleanup needed for type: $backupType ($($backups.Count)/$limit backups)" -Level "INFO"
            }
        }
    }
    
    return $backupsToDelete
}

function Invoke-BackupCleanup {
    param (
        [PSCustomObject[]]$BackupsToDelete,
        [switch]$WhatIf
    )
    
    if ($BackupsToDelete.Count -eq 0) {
        Write-Log "No backups to delete" -Level "INFO"
        return
    }
    
    $action = if ($WhatIf) { "WOULD DELETE" } else { "DELETING" }
    Write-Log "$action $($BackupsToDelete.Count) backups:" -Level "INFO"
    
    foreach ($backup in $BackupsToDelete) {
        $ageInDays = [math]::Round(((Get-Date) - $backup.Timestamp).TotalDays)
        Write-Log "$action $($backup.BackupSetName) ($($backup.SizeGB) GB, $ageInDays days old)" -Level "INFO"
        
        if (-not $WhatIf) {
            # Only process if both file and DB entry exist
            if (Test-BackupFileExists -Backup $backup) {
                $fileDeleted = Remove-BackupFile -Backup $backup
                
                if ($fileDeleted) {
                    $dbDeleted = Remove-BackupFromDatabase -BackupId $backup.Id
                    
                    if ($dbDeleted) {
                        $script:DeletedCount++
                        $script:DeletedSize += $backup.SizeBytes
                    }
                }
            } else {
                Write-Log "Skipping backup ID $($backup.Id) - file not found: $($backup.DestinationPath)" -Level "WARNING"
                $script:SkippedCount++
            }
        }
    }
}

#endregion

#region Main Execution

function Show-CleanupSummary {
    param ([switch]$WhatIf)
    
    $deletedSizeGB = [math]::Round($script:DeletedSize / 1GB, 2)
    
    if ($WhatIf) {
        Write-Log "=== DRY RUN SUMMARY ===" -Level "INFO"
        Write-Host "`nDry Run Summary:" -ForegroundColor Yellow
        Write-Host "=================" -ForegroundColor Yellow
        Write-Host "Would delete: $script:DeletedCount backups" -ForegroundColor Cyan
        Write-Host "Total size: $deletedSizeGB GB" -ForegroundColor Cyan
        Write-Host "Skipped: $script:SkippedCount backups" -ForegroundColor Yellow
        Write-Host "`nTo actually delete these backups, run with -Force parameter" -ForegroundColor Green
    } else {
        Write-Log "=== CLEANUP SUMMARY ===" -Level "INFO"
        Write-Host "`nCleanup Summary:" -ForegroundColor Green
        Write-Host "================" -ForegroundColor Green
        Write-Host "Deleted: $script:DeletedCount backups" -ForegroundColor Cyan
        Write-Host "Freed space: $deletedSizeGB GB" -ForegroundColor Cyan
        Write-Host "Skipped: $script:SkippedCount backups" -ForegroundColor Yellow
        Write-Host "Errors: $script:ErrorCount" -ForegroundColor Red
    }
    
    Write-Log "Cleanup completed - Deleted: $script:DeletedCount, Skipped: $script:SkippedCount, Errors: $script:ErrorCount, Freed: $deletedSizeGB GB" -Level "INFO"
}

function Start-BackupCleanup {
    # Determine run mode
    $isWhatIf = (-not $Force) -or $DryRun
    $mode = if ($isWhatIf) { "DRY RUN" } else { "LIVE" }
    
    Write-Log "Starting backup cleanup in $mode mode" -Level "INFO"
    
    if ($OlderThan -gt 0) {
        Write-Log "Cleanup mode: Delete backups older than $OlderThan days" -Level "INFO"
    } else {
        Write-Log "Cleanup mode: Keep max backups per type (Games: 10, Others: 5)" -Level "INFO"
    }
    
    # Get all backups
    $allBackups = Get-AllBackups
    if ($allBackups.Count -eq 0) {
        Write-Log "No backups found in database" -Level "WARNING"
        return
    }
    
    Write-Log "Found $($allBackups.Count) total backups in database" -Level "INFO"
    
    # Determine what to delete
    $retentionLimits = Get-RetentionLimits
    $backupsToDelete = Get-BackupsToDelete -AllBackups $allBackups -OlderThanDays $OlderThan -RetentionLimits $retentionLimits
    
    # Perform cleanup
    Invoke-BackupCleanup -BackupsToDelete $backupsToDelete -WhatIf:$isWhatIf
    
    # Show summary
    Show-CleanupSummary -WhatIf:$isWhatIf
    gotify-cli.exe push Backup Deletion Complete -t Backup
    Write-Log "=== Backup Cleanup Finished ===" -Level "INFO"
}

#endregion

#region Script Entry Point

# Initialize
try {
    # Parse and validate config
    $config = Parse-ConfigFile -ConfigFilePath $ConfigFile
    Initialize-CleanupLogging -LogLevel $LogLevel
    
    # Run cleanup
    Start-BackupCleanup
}
catch {
    Write-Log "Fatal error during cleanup: $_" -Level "ERROR"
    Write-Host "Error: $_" -ForegroundColor Red
    exit 1
}

#endregion