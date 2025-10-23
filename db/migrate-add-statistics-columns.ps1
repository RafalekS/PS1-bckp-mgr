# Migration script to add statistics columns to backups table
# Run this once to upgrade existing database schema

Add-Type -Path "C:\Program Files\Microsoft Visual Studio\2022\Community\Common7\IDE\PrivateAssemblies\System.Data.SQLite.dll"

$databasePath = Join-Path $PSScriptRoot "backup_history.db"

if (-not (Test-Path $databasePath)) {
    Write-Host "Database not found at: $databasePath" -ForegroundColor Yellow
    Write-Host "No migration needed - columns will be created when database is first initialized" -ForegroundColor Green
    exit 0
}

# SQL commands to add new columns (safe - won't fail if columns already exist)
$migrations = @(
    "ALTER TABLE backups ADD COLUMN duration_seconds INTEGER DEFAULT 0",
    "ALTER TABLE backups ADD COLUMN size_mb REAL DEFAULT 0.0",
    "ALTER TABLE backups ADD COLUMN file_count INTEGER DEFAULT 0"
)

try {
    $connection = New-Object System.Data.SQLite.SQLiteConnection("Data Source=$databasePath;Version=3;")
    $connection.Open()

    foreach ($sql in $migrations) {
        try {
            $command = $connection.CreateCommand()
            $command.CommandText = $sql
            $command.ExecuteNonQuery()
            Write-Host "✓ Executed: $sql" -ForegroundColor Green
        }
        catch {
            if ($_.Exception.Message -like "*duplicate column name*") {
                Write-Host "○ Column already exists (skipping): $sql" -ForegroundColor Gray
            }
            else {
                throw $_
            }
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
