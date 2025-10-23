Add-Type -Path "C:\Program Files\Microsoft Visual Studio\2022\Community\Common7\IDE\PrivateAssemblies\System.Data.SQLite.dll"

# Define the path for the new database file
$databasePath = Join-Path $PSScriptRoot "backup_history.db"

# SQL command to create the table
$createTableSQL = @"
CREATE TABLE backups (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    backup_set_name TEXT NOT NULL,
    backup_type TEXT NOT NULL,
    destination_type TEXT NOT NULL,
    destination_path TEXT NOT NULL,
    timestamp DATETIME NOT NULL,
    size_bytes INTEGER NOT NULL,
    compression_method TEXT,
    encryption_method TEXT,
    source_paths TEXT NOT NULL,
    additional_metadata TEXT,
    duration_seconds INTEGER DEFAULT 0,
    size_mb REAL DEFAULT 0.0,
    file_count INTEGER DEFAULT 0
);
"@

# Create the database and table
try {
    # Create the database file (if it doesn't exist) and open a connection
    $connection = New-Object System.Data.SQLite.SQLiteConnection("Data Source=$databasePath;Version=3;New=True;")
    $connection.Open()

    # Create the table
    $command = $connection.CreateCommand()
    $command.CommandText = $createTableSQL
    $command.ExecuteNonQuery()

    Write-Host "Database and table created successfully at $databasePath"
}
catch {
    Write-Error "An error occurred while creating the database: $_"
}
finally {
    if ($connection) {
        $connection.Close()
    }
}
