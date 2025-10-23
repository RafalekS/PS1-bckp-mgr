# Migration script to add success column to backups table
# Run this once to upgrade existing database schema

Add-Type -Path "C:\Program Files\Microsoft Visual Studio\2022\Community\Common7\IDE\PrivateAssemblies\System.Data.SQLite.dll"

$databasePath = Join-Path $PSScriptRoot "backup_history.db"

if (-not (Test-Path $databasePath)) {
    Write-Host "Database not found at: $databasePath" -ForegroundColor Yellow
    Write-Host "No migration needed - column will be created when database is first initialized" -ForegroundColor Green
    exit 0
}

# SQL command to add success column
$migration = "ALTER TABLE backups ADD COLUMN success INTEGER DEFAULT 1"

try {
    $connection = New-Object System.Data.SQLite.SQLiteConnection("Data Source=$databasePath;Version=3;")
    $connection.Open()

    try {
        $command = $connection.CreateCommand()
        $command.CommandText = $migration
        $command.ExecuteNonQuery()
        Write-Host "✓ Added success column to backups table" -ForegroundColor Green
    }
    catch {
        if ($_.Exception.Message -like "*duplicate column name*") {
            Write-Host "○ Success column already exists (skipping)" -ForegroundColor Gray
        }
        else {
            throw $_
        }
    }

    Write-Host "`nDatabase migration completed successfully!" -ForegroundColor Green
}
catch {
    Write-Error "Migration failed: $_"
}
finally {
    if ($connection) {
        $connection.Close()
    }
}
