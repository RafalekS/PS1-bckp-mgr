# Migration script to add differential backup support columns
# Phase 4 - Advanced Backup Features (Issue #20)
# Run this once to upgrade existing database schema

Add-Type -Path "C:\Program Files\Microsoft Visual Studio\2022\Community\Common7\IDE\PrivateAssemblies\System.Data.SQLite.dll"

$databasePath = Join-Path $PSScriptRoot "backup_history.db"

if (-not (Test-Path $databasePath)) {
    Write-Host "Database not found at: $databasePath" -ForegroundColor Yellow
    Write-Host "No migration needed - columns will be created when database is first initialized" -ForegroundColor Green
    exit 0
}

Write-Host "========================================" -ForegroundColor Cyan
Write-Host " Phase 4 Database Migration" -ForegroundColor Cyan
Write-Host " Adding Differential Backup Support" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
Write-Host ""

# SQL commands to add new columns
$migrations = @(
    @{
        Name = "backup_strategy"
        SQL = "ALTER TABLE backups ADD COLUMN backup_strategy TEXT DEFAULT 'Full'"
        Description = "Backup type: Full, Differential, or Incremental"
    },
    @{
        Name = "parent_backup_id"
        SQL = "ALTER TABLE backups ADD COLUMN parent_backup_id INTEGER"
        Description = "References the parent full backup for differential/incremental"
    }
)

try {
    $connection = New-Object System.Data.SQLite.SQLiteConnection("Data Source=$databasePath;Version=3;")
    $connection.Open()

    $changesApplied = 0
    $changesSkipped = 0

    foreach ($migration in $migrations) {
        try {
            Write-Host "Adding column: $($migration.Name)..." -NoNewline
            $command = $connection.CreateCommand()
            $command.CommandText = $migration.SQL
            $command.ExecuteNonQuery()
            Write-Host " ✓" -ForegroundColor Green
            Write-Host "  - $($migration.Description)" -ForegroundColor Gray
            $changesApplied++
        }
        catch {
            if ($_.Exception.Message -like "*duplicate column name*") {
                Write-Host " ○ (already exists)" -ForegroundColor Gray
                $changesSkipped++
            }
            else {
                Write-Host " ✗" -ForegroundColor Red
                throw $_
            }
        }
    }

    Write-Host ""
    Write-Host "Migration Summary:" -ForegroundColor Cyan
    Write-Host "  - Changes applied: $changesApplied" -ForegroundColor Green
    Write-Host "  - Changes skipped: $changesSkipped" -ForegroundColor Gray
    Write-Host ""

    if ($changesApplied -gt 0) {
        # Update existing backups to have 'Full' strategy
        Write-Host "Updating existing backups to 'Full' strategy..." -NoNewline
        $updateCommand = $connection.CreateCommand()
        $updateCommand.CommandText = "UPDATE backups SET backup_strategy = 'Full' WHERE backup_strategy IS NULL"
        $updated = $updateCommand.ExecuteNonQuery()
        Write-Host " ✓ ($updated records)" -ForegroundColor Green
    }

    Write-Host ""
    Write-Host "Database migration completed successfully!" -ForegroundColor Green
}
catch {
    Write-Host ""
    Write-Error "Migration failed: $_"
    exit 1
}
finally {
    if ($connection) {
        $connection.Close()
    }
}

Write-Host ""
Write-Host "Next steps:" -ForegroundColor Cyan
Write-Host "  1. Differential backups are now supported" -ForegroundColor White
Write-Host "  2. Configure Differential backup type in config\bkp_cfg.json" -ForegroundColor White
Write-Host "  3. Run differential backup: .\main.ps1 -BackupType Differential -Destination <dest>" -ForegroundColor White
Write-Host ""
