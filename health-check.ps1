<#
.SYNOPSIS
    Health check script for backup system

.DESCRIPTION
    Monitors backup system health by checking:
    - Last backup date and status
    - Disk space on temp drive
    - Database connectivity
    - Sends notifications for issues

.PARAMETER SendNotification
    Send Gotify notification if issues are found

.EXAMPLE
    .\health-check.ps1
    .\health-check.ps1 -SendNotification

.NOTES
    Exit codes:
    0 = OK (all checks passed)
    1 = WARNING (minor issues detected)
    2 = ERROR (critical issues detected)
#>

param(
    [switch]$SendNotification
)

# Script setup
$ErrorActionPreference = "Stop"
$ScriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path

# Load utilities and config
. "$ScriptRoot\BackupUtilities.ps1"
$configPath = Join-Path $ScriptRoot "config\bkp_cfg.json"
$config = Get-Content $configPath | ConvertFrom-Json

# Initialize logging
$logFilePath = Join-Path $ScriptRoot $config.Logging.LogFilePath
$logFormat = if ($config.Logging.Format) { $config.Logging.Format } else { "Text" }
Initialize-Logging -LogLevel "INFO" -LogFilePath $logFilePath -LogFormat $logFormat

Write-Log "=== Backup System Health Check ===" -Level "INFO"
Write-Log "Starting health check at $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')" -Level "INFO"

$healthIssues = @()
$healthStatus = "OK"

#region Database Check
try {
    Write-Log "Checking database connectivity..." -Level "INFO"

    $dbPath = Join-Path $ScriptRoot "db\backup_history.db"
    if (-not (Test-Path $dbPath)) {
        $healthIssues += "Database file not found: $dbPath"
        $healthStatus = "ERROR"
    }
    else {
        # Try to connect and query
        $query = "SELECT COUNT(*) as count FROM backups"
        $result = Invoke-SqliteQuery -Query $query -DataSource $dbPath
        Write-Log "Database check passed: $($result.count) backups in database" -Level "INFO"
    }
}
catch {
    $healthIssues += "Database connectivity failed: $_"
    $healthStatus = "ERROR"
}
#endregion

#region Last Backup Check
try {
    Write-Log "Checking last backup status..." -Level "INFO"

    $query = "SELECT backup_type, timestamp, success FROM backups ORDER BY timestamp DESC LIMIT 1"
    $lastBackup = Invoke-SqliteQuery -Query $query -DataSource $dbPath

    if (-not $lastBackup) {
        $healthIssues += "No backups found in database"
        $healthStatus = if ($healthStatus -eq "ERROR") { "ERROR" } else { "WARNING" }
    }
    else {
        # Parse timestamp - try multiple formats
        $lastBackupTime = $null
        try {
            $lastBackupTime = [DateTime]::ParseExact($lastBackup.timestamp, "yyyy-MM-dd HH:mm:ss", $null)
        }
        catch {
            try {
                $lastBackupTime = [DateTime]::ParseExact($lastBackup.timestamp, "MM/dd/yyyy HH:mm:ss", $null)
            }
            catch {
                $lastBackupTime = [DateTime]::Parse($lastBackup.timestamp)
            }
        }

        $hoursSinceBackup = ((Get-Date) - $lastBackupTime).TotalHours

        Write-Log "Last backup: $($lastBackup.backup_type) at $($lastBackup.timestamp)" -Level "INFO"

        # Check if backup is too old
        if ($hoursSinceBackup -gt 48) {
            $healthIssues += "No backup in 48 hours (last backup: $([math]::Round($hoursSinceBackup, 1)) hours ago)"
            $healthStatus = if ($healthStatus -eq "ERROR") { "ERROR" } else { "WARNING" }
        }

        # Check if last backup failed (requires success column - run migrate-add-success-column.ps1 first)
        if ($lastBackup.PSObject.Properties.Name -contains "success") {
            if ($lastBackup.success -eq 0 -or $lastBackup.success -eq "False") {
                $healthIssues += "Last backup failed: $($lastBackup.backup_type) at $($lastBackup.timestamp)"
                $healthStatus = if ($healthStatus -eq "ERROR") { "ERROR" } else { "WARNING" }
            }
        }
    }
}
catch {
    $healthIssues += "Failed to check last backup: $_"
    $healthStatus = "ERROR"
}
#endregion

#region Disk Space Check
try {
    Write-Log "Checking disk space..." -Level "INFO"

    $tempPath = $config.TempPath
    if (Test-Path $tempPath) {
        $tempDrive = (Get-Item $tempPath).PSDrive.Name
        $freeSpaceGB = (Get-PSDrive $tempDrive).Free / 1GB

        Write-Log "Free space on $tempDrive drive: $([math]::Round($freeSpaceGB, 2)) GB" -Level "INFO"

        if ($freeSpaceGB -lt 10) {
            $healthIssues += "Low disk space on $tempDrive drive: $([math]::Round($freeSpaceGB, 2)) GB remaining"
            $healthStatus = if ($healthStatus -eq "ERROR") { "ERROR" } else { "WARNING" }
        }
    }
    else {
        $healthIssues += "Temp path not found: $tempPath"
        $healthStatus = if ($healthStatus -eq "ERROR") { "ERROR" } else { "WARNING" }
    }
}
catch {
    $healthIssues += "Failed to check disk space: $_"
    $healthStatus = if ($healthStatus -eq "ERROR") { "ERROR" } else { "WARNING" }
}
#endregion

#region Statistics Check
try {
    Write-Log "Checking backup statistics..." -Level "INFO"

    $stats = $config.Statistics
    if ($stats) {
        Write-Log "Total backups: $($stats.TotalBackups) (Success: $($stats.SuccessfulBackups), Failed: $($stats.FailedBackups))" -Level "INFO"

        if ($stats.TotalBackups -gt 0) {
            $failureRate = ($stats.FailedBackups / $stats.TotalBackups) * 100

            if ($failureRate -gt 20) {
                $healthIssues += "High failure rate: $([math]::Round($failureRate, 1))% of backups failed"
                $healthStatus = if ($healthStatus -eq "ERROR") { "ERROR" } else { "WARNING" }
            }
        }
    }
}
catch {
    Write-Log "Failed to check statistics: $_" -Level "WARNING"
}
#endregion

#region Summary
Write-Log "=== Health Check Summary ===" -Level "INFO"

if ($healthStatus -eq "OK") {
    Write-Host "`n[OK] Backup system is healthy" -ForegroundColor Green
    Write-Log "Health check passed: All systems operational" -Level "INFO"
    $exitCode = 0
}
elseif ($healthStatus -eq "WARNING") {
    Write-Host "`n[WARNING] Backup system has warnings" -ForegroundColor Yellow
    Write-Log "Health check warning: $($healthIssues.Count) issue(s) detected" -Level "WARNING"

    foreach ($issue in $healthIssues) {
        Write-Host "  - $issue" -ForegroundColor Yellow
        Write-Log "WARNING: $issue" -Level "WARNING"
    }

    $exitCode = 1
}
else {
    Write-Host "`n[ERROR] Backup system has critical issues" -ForegroundColor Red
    Write-Log "Health check failed: $($healthIssues.Count) critical issue(s) detected" -Level "ERROR"

    foreach ($issue in $healthIssues) {
        Write-Host "  - $issue" -ForegroundColor Red
        Write-Log "ERROR: $issue" -Level "ERROR"
    }

    $exitCode = 2
}
#endregion

#region Notifications
if ($SendNotification -and $healthStatus -ne "OK") {
    try {
        if ($config.Notifications.Gotify.Enabled) {
            $priority = if ($healthStatus -eq "ERROR") { 8 } else { 5 }
            $title = "Backup Health Check: $healthStatus"
            $message = "Issues detected:`n" + ($healthIssues -join "`n")

            Send-GotifyNotification -Title $title -Message $message -Priority $priority -Config $config
            Write-Log "Notification sent via Gotify" -Level "INFO"
        }
    }
    catch {
        Write-Log "Failed to send notification: $_" -Level "WARNING"
    }
}
#endregion

Write-Log "Health check completed with status: $healthStatus (exit code: $exitCode)" -Level "INFO"
exit $exitCode
