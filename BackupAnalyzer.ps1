#Requires -Version 5.1

<#
.SYNOPSIS
    Backup analysis and statistics module

.DESCRIPTION
    Provides comprehensive analysis of backup history including:
    - Largest files and folders across backups
    - Backup size trends over time
    - File type distribution
    - Category breakdown
    - Most frequently backed up paths

.NOTES
    Version: 1.0
    Part of Phase 6 - User Experience improvements
    Requires: SQLite database and backup manifests
#>

#region Database Functions

function Get-DatabaseConnection {
    param (
        [string]$DatabasePath = "$PSScriptRoot\db\backup_history.db"
    )

    if (-not (Test-Path $DatabasePath)) {
        Write-Error "Database not found at: $DatabasePath"
        return $null
    }

    try {
        Add-Type -Path "$PSScriptRoot\db\System.Data.SQLite.dll"
        $connection = New-Object System.Data.SQLite.SQLiteConnection("Data Source=$DatabasePath;Version=3;")
        $connection.Open()
        return $connection
    }
    catch {
        Write-Error "Failed to connect to database: $_"
        return $null
    }
}

function Close-DatabaseConnection {
    param (
        [System.Data.SQLite.SQLiteConnection]$Connection
    )

    if ($Connection -and $Connection.State -eq 'Open') {
        $Connection.Close()
        $Connection.Dispose()
    }
}

function Get-AllBackups {
    param (
        [int]$Limit = 0
    )

    $conn = Get-DatabaseConnection
    if (-not $conn) { return @() }

    try {
        $cmd = $conn.CreateCommand()
        $limitClause = if ($Limit -gt 0) { "LIMIT $Limit" } else { "" }
        $cmd.CommandText = "SELECT * FROM backups ORDER BY timestamp DESC $limitClause"

        $reader = $cmd.ExecuteReader()
        $backups = @()

        while ($reader.Read()) {
            $backups += [PSCustomObject]@{
                Id = $reader['id']
                Name = $reader['backup_set_name']
                Type = $reader['backup_type']
                DestinationType = $reader['destination_type']
                DestinationPath = $reader['destination_path']
                Timestamp = $reader['timestamp']
                SizeBytes = [long]$reader['size_bytes']
                SizeMB = [double]$reader['size_mb']
                FileCount = [int]$reader['file_count']
                DurationSeconds = [int]$reader['duration_seconds']
                CompressionMethod = $reader['compression_method']
                EncryptionMethod = $reader['encryption_method']
                BackupStrategy = if ($reader['backup_strategy']) { $reader['backup_strategy'] } else { 'Full' }
                ParentBackupId = if ($reader['parent_backup_id']) { $reader['parent_backup_id'] } else { $null }
            }
        }

        return $backups
    }
    finally {
        Close-DatabaseConnection $conn
    }
}

#endregion

#region Manifest Functions

function Get-ZipFileList {
    <#
    .SYNOPSIS
        Get ALL files from a ZIP archive with their sizes
    .DESCRIPTION
        Reads actual ZIP contents using .NET ZipArchive - NOT the manifest
    #>
    param (
        [Parameter(Mandatory=$true)]
        [string]$BackupPath
    )

    # Handle both directory paths and .zip file paths
    if ($BackupPath -like "*.zip") {
        $zipPath = $BackupPath
    }
    else {
        $backupName = Split-Path $BackupPath -Leaf
        $zipPath = Join-Path $BackupPath "$backupName.zip"
    }

    if (-not (Test-Path $zipPath)) {
        Write-Warning "Backup ZIP not found: $zipPath"
        return @()
    }

    try {
        Write-Verbose "Reading ZIP contents from: $zipPath"
        Add-Type -AssemblyName System.IO.Compression.FileSystem

        $zip = [System.IO.Compression.ZipFile]::OpenRead($zipPath)
        $files = @()

        foreach ($entry in $zip.Entries) {
            # Skip directories (they have Length 0 and end with /)
            if ($entry.FullName.EndsWith('/') -or $entry.Length -eq 0) {
                continue
            }

            # Extract file info from path
            # Path format: C:/temp/Backup/BACKUP_NAME/Files/Category/filename
            $fullPath = $entry.FullName
            $parts = $fullPath -split '/'

            # Try to determine category from path
            # Path format: C:/temp/Backup/BACKUP_NAME/Files/Category/...
            $category = "Unknown"
            $filesIndex = [array]::IndexOf($parts, 'Files')
            if ($filesIndex -ge 0 -and $filesIndex + 1 -lt $parts.Length) {
                $category = $parts[$filesIndex + 1]
            } elseif ($parts -contains 'WindowsSettings') {
                $category = "WindowsSettings"
            }

            $fileName = $parts[-1]
            $extension = [System.IO.Path]::GetExtension($fileName).ToLower()
            $directory = ($parts[0..($parts.Length-2)] -join '\').Replace('/', '\')

            $files += [PSCustomObject]@{
                FileName = $fileName
                FileExtension = $extension
                FullPath = $fullPath
                Directory = $directory
                SizeBytes = [long]$entry.Length
                CompressedSize = [long]$entry.CompressedLength
                LastModified = $entry.LastWriteTime
                Category = $category
            }
        }

        $zip.Dispose()
        Write-Verbose "Read $($files.Count) files from ZIP"
        return $files
    }
    catch {
        Write-Error "Failed to read ZIP contents: $_"
        return @()
    }
}

function Get-BackupManifest {
    param (
        [Parameter(Mandatory=$true)]
        [string]$BackupPath
    )

    # Handle both directory paths and .zip file paths
    if ($BackupPath -like "*.zip") {
        $zipPath = $BackupPath
    }
    else {
        # Find the .zip file in the directory
        $backupName = Split-Path $BackupPath -Leaf
        $zipPath = Join-Path $BackupPath "$backupName.zip"
    }

    if (-not (Test-Path $zipPath)) {
        Write-Warning "Backup ZIP not found: $zipPath"
        return $null
    }

    try {
        # Extract manifest.json from the backup directory structure
        # The manifest is at: C:/temp/Backup/BACKUP_NAME/manifest.json inside the ZIP
        $backupName = [System.IO.Path]::GetFileNameWithoutExtension($zipPath)

        # Use .NET ZipArchive for reliable extraction
        Add-Type -AssemblyName System.IO.Compression.FileSystem

        $zip = [System.IO.Compression.ZipFile]::OpenRead($zipPath)

        # Look for manifest.json in the backup root directory
        # Pattern: C:/temp/Backup/BACKUP_NAME/manifest.json
        $manifestEntry = $zip.Entries | Where-Object {
            $_.FullName -match "^C:/temp/Backup/[^/]+/manifest\.json$"
        } | Select-Object -First 1

        if ($manifestEntry) {
            $stream = $manifestEntry.Open()
            $reader = New-Object System.IO.StreamReader($stream)
            $manifestJson = $reader.ReadToEnd()
            $reader.Close()
            $stream.Close()
            $zip.Dispose()

            $manifest = $manifestJson | ConvertFrom-Json
            Write-Verbose "Successfully read manifest from $zipPath ($(($manifest.backup_manifest.PSObject.Properties | Measure-Object).Count) entries)"
            return $manifest
        }

        $zip.Dispose()
        Write-Warning "manifest.json not found in backup: $zipPath"
        Write-Verbose "Expected path pattern: C:/temp/Backup/$backupName/manifest.json"
        return $null
    }
    catch {
        Write-Error "Failed to read manifest from $zipPath : $_"
        Write-Error "Error details: $($_.Exception.Message)"
        return $null
    }
}

function Get-ManifestFileData {
    param (
        [Parameter(Mandatory=$true)]
        [PSCustomObject]$Manifest
    )

    $files = @()

    foreach ($entry in $Manifest.backup_manifest.PSObject.Properties) {
        $manifestEntry = $entry.Value

        if ($manifestEntry.file_type -eq "file") {
            $files += [PSCustomObject]@{
                OriginalPath = $manifestEntry.original_path
                ArchivePath = $manifestEntry.archive_relative_path
                BackupItem = $manifestEntry.backup_item
                SizeBytes = [long]$manifestEntry.size_bytes
                LastModified = $manifestEntry.last_modified
                FileExtension = [System.IO.Path]::GetExtension($manifestEntry.original_path).ToLower()
                FileName = [System.IO.Path]::GetFileName($manifestEntry.original_path)
                Directory = [System.IO.Path]::GetDirectoryName($manifestEntry.original_path)
            }
        }
    }

    return $files
}

#endregion

#region Analysis Functions

function Get-BackupStatistics {
    <#
    .SYNOPSIS
        Get overall statistics across all backups
    #>
    param (
        [int]$RecentCount = 10
    )

    Write-Host "`n=== BACKUP STATISTICS ===" -ForegroundColor Cyan
    Write-Host ""

    $backups = Get-AllBackups

    if ($backups.Count -eq 0) {
        Write-Host "No backups found in database." -ForegroundColor Yellow
        return
    }

    $totalBackups = $backups.Count
    $totalSizeGB = ($backups | Measure-Object -Property SizeMB -Sum).Sum / 1024
    $totalFiles = ($backups | Measure-Object -Property FileCount -Sum).Sum
    $avgSizeGB = $totalSizeGB / $totalBackups
    $avgDuration = ($backups | Measure-Object -Property DurationSeconds -Average).Average

    $recentBackups = $backups | Select-Object -First $RecentCount
    $oldestDate = ($backups | Measure-Object -Property Timestamp -Minimum).Minimum
    $newestDate = ($backups | Measure-Object -Property Timestamp -Maximum).Maximum

    Write-Host "Total Backups: " -NoNewline
    Write-Host $totalBackups -ForegroundColor Green

    Write-Host "Total Storage: " -NoNewline
    Write-Host ("{0:N2} GB" -f $totalSizeGB) -ForegroundColor Green

    Write-Host "Total Files: " -NoNewline
    Write-Host ("{0:N0}" -f $totalFiles) -ForegroundColor Green

    Write-Host "Average Backup Size: " -NoNewline
    Write-Host ("{0:N2} GB" -f $avgSizeGB) -ForegroundColor Yellow

    Write-Host "Average Duration: " -NoNewline
    Write-Host ("{0:N0} seconds ({1:N1} minutes)" -f $avgDuration, ($avgDuration / 60)) -ForegroundColor Yellow

    Write-Host "Date Range: " -NoNewline
    Write-Host "$oldestDate to $newestDate" -ForegroundColor Gray

    Write-Host "`n--- Recent Backups (Last $RecentCount) ---" -ForegroundColor Cyan
    $recentBackups | Format-Table @{L='ID';E={$_.Id}},
                                   @{L='Name';E={$_.Name}},
                                   @{L='Type';E={$_.Type}},
                                   @{L='Size (GB)';E={"{0:N2}" -f ($_.SizeMB/1024)}},
                                   @{L='Files';E={"{0:N0}" -f $_.FileCount}},
                                   @{L='Duration (min)';E={"{0:N1}" -f ($_.DurationSeconds/60)}},
                                   @{L='Date';E={$_.Timestamp}} -AutoSize
}

function Get-LargestFiles {
    <#
    .SYNOPSIS
        Find the largest files in a backup or across backups
    #>
    param (
        [int]$Top = 20,
        [int]$BackupId = 0
    )

    Write-Host "`n=== LARGEST FILES ===" -ForegroundColor Cyan
    Write-Host ""

    $backups = if ($BackupId -gt 0) {
        $backup = Get-AllBackups | Where-Object { $_.Id -eq $BackupId }
        if ($backup) {
            @($backup)  # Ensure it's an array
        } else {
            @()
        }
    } else {
        Get-AllBackups | Select-Object -First 5  # Analyze recent 5 backups by default
    }

    if ($backups.Count -eq 0) {
        Write-Host "No backups found." -ForegroundColor Yellow
        return
    }

    if ($BackupId -gt 0) {
        Write-Host "Analyzing backup: $($backups[0].Name)" -ForegroundColor Cyan
        Write-Host "Location: $($backups[0].DestinationPath)" -ForegroundColor Gray
    } else {
        Write-Host "Analyzing $($backups.Count) recent backups..." -ForegroundColor Gray
    }
    Write-Host ""

    $allFiles = @()

    foreach ($backup in $backups) {
        Write-Host "  Reading ZIP contents from: $($backup.Name)..." -ForegroundColor Gray

        $files = Get-ZipFileList -BackupPath $backup.DestinationPath
        if ($files.Count -gt 0) {
            foreach ($file in $files) {
                $file | Add-Member -NotePropertyName BackupName -NotePropertyValue $backup.Name -Force
                $file | Add-Member -NotePropertyName BackupId -NotePropertyValue $backup.Id -Force
                # Rename Category to BackupItem for consistency
                $file | Add-Member -NotePropertyName BackupItem -NotePropertyValue $file.Category -Force

                # Strip the common prefix from directory path (normalize backslashes first)
                $normalizedDir = $file.Directory -replace '\\', '/'
                $backupPrefix = "C:/temp/Backup/$($backup.Name)"
                $relativePath = $normalizedDir -replace [regex]::Escape($backupPrefix), ''
                # Convert back to backslashes for display
                $relativePath = $relativePath -replace '/', '\'
                $file | Add-Member -NotePropertyName RelativePath -NotePropertyValue $relativePath -Force
            }
            $allFiles += $files
            Write-Host "    Found $($files.Count) files" -ForegroundColor Gray
        }
    }

    if ($allFiles.Count -eq 0) {
        Write-Host "No files found in ZIP archive(s)." -ForegroundColor Yellow
        return
    }

    $largestFiles = $allFiles | Sort-Object -Property SizeBytes -Descending | Select-Object -First $Top

    Write-Host "`nTop $Top Largest Files:" -ForegroundColor Cyan
    $largestFiles | Format-Table @{L='Size (MB)';E={"{0:N2}" -f ($_.SizeBytes/1MB)}},
                                  @{L='File Name';E={$_.FileName}},
                                  @{L='Extension';E={$_.FileExtension}},
                                  @{L='Category';E={$_.BackupItem}},
                                  @{L='Path';E={$_.RelativePath}} -AutoSize -Wrap

    $totalSize = ($largestFiles | Measure-Object -Property SizeBytes -Sum).Sum
    Write-Host "`nTotal: $($largestFiles.Count) files, " -NoNewline -ForegroundColor Gray
    Write-Host ("{0:N2} GB" -f ($totalSize / 1GB)) -ForegroundColor Green
}

function Get-LargestFolders {
    <#
    .SYNOPSIS
        Find the largest folders/directories in a backup
    #>
    param (
        [int]$Top = 20,
        [int]$BackupId = 0
    )

    Write-Host "`n=== LARGEST FOLDERS ===" -ForegroundColor Cyan
    Write-Host ""

    $backups = if ($BackupId -gt 0) {
        $backup = Get-AllBackups | Where-Object { $_.Id -eq $BackupId }
        if ($backup) { @($backup) } else { @() }
    } else {
        Get-AllBackups | Select-Object -First 5
    }

    if ($backups.Count -eq 0) {
        Write-Host "No backups found." -ForegroundColor Yellow
        return
    }

    if ($BackupId -gt 0) {
        Write-Host "Analyzing backup: $($backups[0].Name)" -ForegroundColor Cyan
    } else {
        Write-Host "Analyzing $($backups.Count) recent backups..." -ForegroundColor Gray
    }
    Write-Host ""

    $folderStats = @{}

    foreach ($backup in $backups) {
        Write-Host "  Reading ZIP contents from: $($backup.Name)..." -ForegroundColor Gray

        $files = Get-ZipFileList -BackupPath $backup.DestinationPath
        if ($files.Count -gt 0) {
            Write-Host "    Found $($files.Count) files" -ForegroundColor Gray

            foreach ($file in $files) {
                $folder = $file.Directory

                if (-not $folderStats.ContainsKey($folder)) {
                    $folderStats[$folder] = @{
                        TotalSize = 0
                        FileCount = 0
                        Categories = @{}
                    }
                }

                $folderStats[$folder].TotalSize += $file.SizeBytes
                $folderStats[$folder].FileCount++

                if (-not $folderStats[$folder].Categories.ContainsKey($file.Category)) {
                    $folderStats[$folder].Categories[$file.Category] = 0
                }
                $folderStats[$folder].Categories[$file.Category]++
            }
        }
    }

    if ($folderStats.Count -eq 0) {
        Write-Host "No folder data found." -ForegroundColor Yellow
        return
    }

    $largestFolders = $folderStats.GetEnumerator() |
                      Sort-Object { $_.Value.TotalSize } -Descending |
                      Select-Object -First $Top

    Write-Host "`nTop $Top Largest Folders:" -ForegroundColor Cyan

    $results = $largestFolders | ForEach-Object {
        $categories = ($_.Value.Categories.Keys | Sort-Object) -join ', '
        [PSCustomObject]@{
            'Size (GB)' = "{0:N2}" -f ($_.Value.TotalSize / 1GB)
            'Size (MB)' = "{0:N2}" -f ($_.Value.TotalSize / 1MB)
            'File Count' = "{0:N0}" -f $_.Value.FileCount
            'Folder Path' = $_.Key -replace '^(.{60}).*(.{30})$', '$1...$2'
            'Categories' = $categories
        }
    }

    $results | Format-Table -AutoSize -Wrap

    $totalSize = ($largestFolders | ForEach-Object { $_.Value.TotalSize } | Measure-Object -Sum).Sum
    Write-Host "`nTotal size of top $Top folders: " -NoNewline
    Write-Host ("{0:N2} GB" -f ($totalSize / 1GB)) -ForegroundColor Green
}

function Get-FolderFileCount {
    <#
    .SYNOPSIS
        Find folders with the most files
    #>
    param (
        [int]$Top = 20,
        [int]$BackupId = 0
    )

    Write-Host "`n=== FOLDERS WITH MOST FILES ===" -ForegroundColor Cyan
    Write-Host ""

    $backups = if ($BackupId -gt 0) {
        $backup = Get-AllBackups | Where-Object { $_.Id -eq $BackupId }
        if ($backup) { @($backup) } else { @() }
    } else {
        Get-AllBackups | Select-Object -First 5
    }

    if ($backups.Count -eq 0) {
        Write-Host "No backups found." -ForegroundColor Yellow
        return
    }

    if ($BackupId -gt 0) {
        Write-Host "Analyzing backup: $($backups[0].Name)" -ForegroundColor Cyan
    } else {
        Write-Host "Analyzing $($backups.Count) recent backups..." -ForegroundColor Gray
    }
    Write-Host ""

    $folderStats = @{}

    foreach ($backup in $backups) {
        Write-Host "  Reading ZIP contents from: $($backup.Name)..." -ForegroundColor Gray

        $files = Get-ZipFileList -BackupPath $backup.DestinationPath
        if ($files.Count -gt 0) {
            Write-Host "    Found $($files.Count) files" -ForegroundColor Gray

            foreach ($file in $files) {
                $folder = $file.Directory

                if (-not $folderStats.ContainsKey($folder)) {
                    $folderStats[$folder] = @{
                        TotalSize = 0
                        FileCount = 0
                    }
                }

                $folderStats[$folder].TotalSize += $file.SizeBytes
                $folderStats[$folder].FileCount++
            }
        }
    }

    if ($folderStats.Count -eq 0) {
        Write-Host "No folder data found." -ForegroundColor Yellow
        return
    }

    $topFolders = $folderStats.GetEnumerator() |
                  Sort-Object { $_.Value.FileCount } -Descending |
                  Select-Object -First $Top

    Write-Host "`nTop $Top Folders by File Count:" -ForegroundColor Cyan

    $results = $topFolders | ForEach-Object {
        [PSCustomObject]@{
            'File Count' = "{0:N0}" -f $_.Value.FileCount
            'Total Size (MB)' = "{0:N2}" -f ($_.Value.TotalSize / 1MB)
            'Avg File Size (KB)' = "{0:N2}" -f (($_.Value.TotalSize / $_.Value.FileCount) / 1KB)
            'Folder Path' = $_.Key -replace '^(.{60}).*(.{30})$', '$1...$2'
        }
    }

    $results | Format-Table -AutoSize -Wrap
}

function Get-CategoryBreakdown {
    <#
    .SYNOPSIS
        Show storage usage breakdown by backup category
    #>
    param (
        [int]$BackupId = 0
    )

    Write-Host "`n=== CATEGORY BREAKDOWN ===" -ForegroundColor Cyan
    Write-Host ""

    $backups = if ($BackupId -gt 0) {
        $backup = Get-AllBackups | Where-Object { $_.Id -eq $BackupId }
        if ($backup) { @($backup) } else { @() }
    } else {
        Get-AllBackups | Select-Object -First 5
    }

    if ($backups.Count -eq 0) {
        Write-Host "No backups found." -ForegroundColor Yellow
        return
    }

    if ($BackupId -gt 0) {
        Write-Host "Analyzing backup: $($backups[0].Name)" -ForegroundColor Cyan
    } else {
        Write-Host "Analyzing $($backups.Count) recent backups..." -ForegroundColor Gray
    }
    Write-Host ""

    $categoryStats = @{}

    foreach ($backup in $backups) {
        Write-Host "  Reading ZIP contents from: $($backup.Name)..." -ForegroundColor Gray

        $files = Get-ZipFileList -BackupPath $backup.DestinationPath
        if ($files.Count -gt 0) {
            Write-Host "    Found $($files.Count) files" -ForegroundColor Gray

            foreach ($file in $files) {
                $category = $file.Category

                if (-not $categoryStats.ContainsKey($category)) {
                    $categoryStats[$category] = @{
                        TotalSize = 0
                        FileCount = 0
                    }
                }

                $categoryStats[$category].TotalSize += $file.SizeBytes
                $categoryStats[$category].FileCount++
            }
        }
    }

    if ($categoryStats.Count -eq 0) {
        Write-Host "No category data found." -ForegroundColor Yellow
        return
    }

    $totalSize = ($categoryStats.Values | ForEach-Object { $_.TotalSize } | Measure-Object -Sum).Sum

    $sortedCategories = $categoryStats.GetEnumerator() | Sort-Object { $_.Value.TotalSize } -Descending

    Write-Host "`nStorage by Category:" -ForegroundColor Cyan

    $results = $sortedCategories | ForEach-Object {
        $percentage = ($_.Value.TotalSize / $totalSize) * 100
        [PSCustomObject]@{
            'Category' = $_.Key
            'Size (GB)' = "{0:N2}" -f ($_.Value.TotalSize / 1GB)
            'Size (MB)' = "{0:N2}" -f ($_.Value.TotalSize / 1MB)
            'File Count' = "{0:N0}" -f $_.Value.FileCount
            'Percentage' = "{0:N1}%" -f $percentage
        }
    }

    $results | Format-Table -AutoSize

    Write-Host "`nTotal analyzed: " -NoNewline
    Write-Host ("{0:N2} GB" -f ($totalSize / 1GB)) -ForegroundColor Green
}

function Get-FileTypeDistribution {
    <#
    .SYNOPSIS
        Analyze file type distribution in a backup
    #>
    param (
        [int]$Top = 20,
        [int]$BackupId = 0
    )

    Write-Host "`n=== FILE TYPE DISTRIBUTION ===" -ForegroundColor Cyan
    Write-Host ""

    $backups = if ($BackupId -gt 0) {
        $backup = Get-AllBackups | Where-Object { $_.Id -eq $BackupId }
        if ($backup) { @($backup) } else { @() }
    } else {
        Get-AllBackups | Select-Object -First 5
    }

    if ($backups.Count -eq 0) {
        Write-Host "No backups found." -ForegroundColor Yellow
        return
    }

    if ($BackupId -gt 0) {
        Write-Host "Analyzing backup: $($backups[0].Name)" -ForegroundColor Cyan
    } else {
        Write-Host "Analyzing $($backups.Count) recent backups..." -ForegroundColor Gray
    }
    Write-Host ""

    $extensionStats = @{}

    foreach ($backup in $backups) {
        Write-Host "  Reading ZIP contents from: $($backup.Name)..." -ForegroundColor Gray

        $files = Get-ZipFileList -BackupPath $backup.DestinationPath
        if ($files.Count -gt 0) {
            Write-Host "    Found $($files.Count) files" -ForegroundColor Gray

            foreach ($file in $files) {
                $ext = if ($file.FileExtension) { $file.FileExtension } else { "(no extension)" }

                if (-not $extensionStats.ContainsKey($ext)) {
                    $extensionStats[$ext] = @{
                        TotalSize = 0
                        FileCount = 0
                    }
                }

                $extensionStats[$ext].TotalSize += $file.SizeBytes
                $extensionStats[$ext].FileCount++
            }
        }
    }

    if ($extensionStats.Count -eq 0) {
        Write-Host "No file type data found." -ForegroundColor Yellow
        return
    }

    $totalSize = ($extensionStats.Values | ForEach-Object { $_.TotalSize } | Measure-Object -Sum).Sum
    $totalFiles = ($extensionStats.Values | ForEach-Object { $_.FileCount } | Measure-Object -Sum).Sum

    $topExtensions = $extensionStats.GetEnumerator() |
                     Sort-Object { $_.Value.TotalSize } -Descending |
                     Select-Object -First $Top

    Write-Host "`nTop $Top File Types by Size:" -ForegroundColor Cyan

    $results = $topExtensions | ForEach-Object {
        $sizePercentage = ($_.Value.TotalSize / $totalSize) * 100
        $countPercentage = ($_.Value.FileCount / $totalFiles) * 100
        [PSCustomObject]@{
            'Extension' = $_.Key
            'Size (MB)' = "{0:N2}" -f ($_.Value.TotalSize / 1MB)
            'File Count' = "{0:N0}" -f $_.Value.FileCount
            'Size %' = "{0:N1}%" -f $sizePercentage
            'Count %' = "{0:N1}%" -f $countPercentage
            'Avg Size (KB)' = "{0:N2}" -f (($_.Value.TotalSize / $_.Value.FileCount) / 1KB)
        }
    }

    $results | Format-Table -AutoSize

    Write-Host "`nTotal file types: " -NoNewline
    Write-Host $extensionStats.Count -ForegroundColor Green
}

function Get-BackupTrends {
    <#
    .SYNOPSIS
        Show backup size and duration trends over time
    #>
    param (
        [int]$RecentCount = 30
    )

    Write-Host "`n=== BACKUP TRENDS ===" -ForegroundColor Cyan
    Write-Host ""

    $backups = Get-AllBackups -Limit $RecentCount

    if ($backups.Count -eq 0) {
        Write-Host "No backups found." -ForegroundColor Yellow
        return
    }

    Write-Host "Showing trends for last $($backups.Count) backups:" -ForegroundColor Gray
    Write-Host ""

    $backups | Format-Table @{L='ID';E={$_.Id}},
                            @{L='Date';E={$_.Timestamp}},
                            @{L='Name';E={$_.Name}},
                            @{L='Type';E={$_.Type}},
                            @{L='Strategy';E={$_.BackupStrategy}},
                            @{L='Size (GB)';E={"{0:N2}" -f ($_.SizeMB/1024)}},
                            @{L='Files';E={"{0:N0}" -f $_.FileCount}},
                            @{L='Duration (min)';E={"{0:N1}" -f ($_.DurationSeconds/60)}} -AutoSize

    # Calculate trend statistics
    if ($backups.Count -ge 2) {
        $recentAvg = ($backups | Select-Object -First 10 | Measure-Object -Property SizeMB -Average).Average / 1024
        $olderAvg = ($backups | Select-Object -Last 10 | Measure-Object -Property SizeMB -Average).Average / 1024

        $trend = $recentAvg - $olderAvg
        $trendPercent = if ($olderAvg -ne 0) { ($trend / $olderAvg) * 100 } else { 0 }

        Write-Host "`nSize Trend Analysis:" -ForegroundColor Cyan
        Write-Host "  Recent 10 avg: " -NoNewline
        Write-Host ("{0:N2} GB" -f $recentAvg) -ForegroundColor Yellow
        Write-Host "  Older 10 avg: " -NoNewline
        Write-Host ("{0:N2} GB" -f $olderAvg) -ForegroundColor Yellow
        Write-Host "  Trend: " -NoNewline

        if ($trend -gt 0) {
            Write-Host ("+{0:N2} GB ({1:N1}% increase)" -f $trend, $trendPercent) -ForegroundColor Red
        }
        elseif ($trend -lt 0) {
            Write-Host ("{0:N2} GB ({1:N1}% decrease)" -f $trend, $trendPercent) -ForegroundColor Green
        }
        else {
            Write-Host "No change" -ForegroundColor Gray
        }
    }
}

function Show-BackupAnalysisReport {
    <#
    .SYNOPSIS
        Generate a comprehensive backup analysis report
    #>
    param (
        [int]$BackupId = 0,
        [switch]$IncludeDetailed
    )

    Write-Host "`n╔════════════════════════════════════════════════════════════╗" -ForegroundColor Cyan
    Write-Host "║         COMPREHENSIVE BACKUP ANALYSIS REPORT              ║" -ForegroundColor Cyan
    Write-Host "╚════════════════════════════════════════════════════════════╝" -ForegroundColor Cyan
    Write-Host ""

    if ($BackupId -gt 0) {
        # Individual backup analysis - show ACTUAL file info
        $backup = Get-AllBackups | Where-Object { $_.Id -eq $BackupId }

        if (-not $backup) {
            Write-Host "Backup ID $BackupId not found!" -ForegroundColor Red
            return
        }

        Write-Host "=== BACKUP INFORMATION ===" -ForegroundColor Cyan
        Write-Host "ID:          $($backup.Id)" -ForegroundColor White
        Write-Host "Name:        $($backup.Name)" -ForegroundColor White
        Write-Host "Type:        $($backup.Type)" -ForegroundColor White
        Write-Host "Date:        $($backup.Timestamp)" -ForegroundColor White
        Write-Host "Location:    $($backup.DestinationPath)" -ForegroundColor White

        # Get ACTUAL archive file size
        if (Test-Path $backup.DestinationPath) {
            $fileInfo = Get-Item $backup.DestinationPath
            $sizeGB = [math]::Round($fileInfo.Length / 1GB, 2)
            $sizeMB = [math]::Round($fileInfo.Length / 1MB, 2)
            Write-Host "Archive Size: " -NoNewline -ForegroundColor White
            Write-Host "$sizeGB GB ($sizeMB MB)" -ForegroundColor Green
        } else {
            Write-Host "Archive Size: File not found!" -ForegroundColor Red
        }
        Write-Host ""

        # Get ACTUAL file stats from ZIP
        Write-Host "Reading actual ZIP contents..." -ForegroundColor Gray
        $files = Get-ZipFileList -BackupPath $backup.DestinationPath

        if ($files.Count -gt 0) {
            $totalFiles = $files.Count
            $totalSize = ($files | Measure-Object -Property SizeBytes -Sum).Sum
            $totalSizeGB = [math]::Round($totalSize / 1GB, 2)
            $totalSizeMB = [math]::Round($totalSize / 1MB, 2)

            Write-Host "Total Files:  " -NoNewline -ForegroundColor White
            Write-Host "$totalFiles files" -ForegroundColor Green
            Write-Host "Total Size:   " -NoNewline -ForegroundColor White
            Write-Host "$totalSizeGB GB ($totalSizeMB MB uncompressed)" -ForegroundColor Green

            # Calculate categories
            $categories = $files | Group-Object Category | Measure-Object
            Write-Host "Categories:   " -NoNewline -ForegroundColor White
            Write-Host "$($categories.Count) categories" -ForegroundColor Green
        }
        Write-Host ""

        # Category breakdown for THIS backup
        Get-CategoryBreakdown -BackupId $BackupId

        if ($IncludeDetailed) {
            # File type distribution
            Get-FileTypeDistribution -Top 15 -BackupId $BackupId

            # Largest files
            Get-LargestFiles -Top 15 -BackupId $BackupId

            # Largest folders
            Get-LargestFolders -Top 15 -BackupId $BackupId

            # Folders with most files
            Get-FolderFileCount -Top 15 -BackupId $BackupId
        }
    } else {
        # Aggregate analysis across multiple backups
        Get-BackupStatistics -RecentCount 10
        Get-BackupTrends -RecentCount 20
        Get-CategoryBreakdown -BackupId 0

        if ($IncludeDetailed) {
            Get-FileTypeDistribution -Top 15 -BackupId 0
            Get-LargestFiles -Top 15 -BackupId 0
            Get-LargestFolders -Top 15 -BackupId 0
            Get-FolderFileCount -Top 15 -BackupId 0
        }
    }

    Write-Host "`n╔════════════════════════════════════════════════════════════╗" -ForegroundColor Cyan
    Write-Host "║                    END OF REPORT                           ║" -ForegroundColor Cyan
    Write-Host "╚════════════════════════════════════════════════════════════╝" -ForegroundColor Cyan
    Write-Host ""
}

#endregion

#region Export Functions

function Export-AnalysisToJson {
    <#
    .SYNOPSIS
        Export analysis data to JSON file
    #>
    param (
        [string]$OutputPath = "backup_analysis.json",
        [int]$BackupId = 0
    )

    Write-Host "`nGenerating analysis data..." -ForegroundColor Cyan

    # This would collect all analysis data and export to JSON
    # Implementation left for future enhancement

    Write-Host "Export complete: $OutputPath" -ForegroundColor Green
}

#endregion

# Functions are available when dot-sourced or imported
# Export-ModuleMember only works in .psm1 modules
