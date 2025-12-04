# Backup Analyzer Module

**Version:** 1.0
**Status:** Production Ready
**Part of:** Phase 6 - User Experience Improvements

## Overview

The BackupAnalyzer module provides comprehensive analysis of backup history, allowing you to gain insights into your backup data without restoring files. It analyzes both the SQLite database (for high-level metrics) and backup manifests (for detailed file-level information).

## Features

- **Overall Statistics**: Total backups, storage usage, file counts, and averages
- **Largest Files**: Find the biggest files across all backups
- **Largest Folders**: Identify folders consuming the most space
- **File Count Analysis**: Find folders with the most files
- **Category Breakdown**: Storage usage by backup category (AI, Scripts, Import, etc.)
- **File Type Distribution**: Analyze storage by file extension
- **Backup Trends**: Track backup sizes and duration over time
- **Comprehensive Reports**: Generate detailed analysis reports

## Quick Start

### Import the Module

```powershell
# Import the analyzer module
. .\BackupAnalyzer.ps1

# Or from anywhere:
. C:\Scripts\Backup\BackupAnalyzer.ps1
```

### Generate a Quick Report

```powershell
# Show comprehensive backup analysis report
Show-BackupAnalysisReport

# Include detailed file/folder analysis
Show-BackupAnalysisReport -IncludeDetailed
```

## Available Functions

### 1. Get-BackupStatistics

Get overall statistics across all backups.

```powershell
# Show statistics for recent 10 backups
Get-BackupStatistics

# Show statistics for recent 20 backups
Get-BackupStatistics -RecentCount 20
```

**Output:**
- Total number of backups
- Total storage used
- Total files backed up
- Average backup size and duration
- Date range of backups

---

### 2. Get-LargestFiles

Find the largest files across backups.

```powershell
# Show top 20 largest files from recent 5 backups
Get-LargestFiles

# Show top 50 largest files
Get-LargestFiles -Top 50

# Analyze a specific backup ID
Get-LargestFiles -BackupId 603 -Top 30
```

**Output:**
- File size in MB
- File name and extension
- Backup category
- Directory path
- Backup name

---

### 3. Get-LargestFolders

Find the largest folders/directories.

```powershell
# Show top 20 largest folders
Get-LargestFolders

# Show top 30 largest folders
Get-LargestFolders -Top 30

# Analyze a specific backup
Get-LargestFolders -BackupId 603
```

**Output:**
- Total folder size in GB/MB
- File count in folder
- Categories included
- Folder path

---

### 4. Get-FolderFileCount

Find folders with the most files.

```powershell
# Show top 20 folders by file count
Get-FolderFileCount

# Show top 30 folders
Get-FolderFileCount -Top 30
```

**Output:**
- File count
- Total folder size
- Average file size
- Folder path

---

### 5. Get-CategoryBreakdown

Show storage usage breakdown by backup category.

```powershell
# Analyze categories from recent backups
Get-CategoryBreakdown

# Analyze a specific backup
Get-CategoryBreakdown -BackupId 603
```

**Output:**
- Category name (AI, Scripts, Import, etc.)
- Size in GB/MB
- File count
- Percentage of total storage

---

### 6. Get-FileTypeDistribution

Analyze file type distribution by extension.

```powershell
# Show top 20 file types
Get-FileTypeDistribution

# Show top 30 file types
Get-FileTypeDistribution -Top 30

# Analyze a specific backup
Get-FileTypeDistribution -BackupId 603 -Top 15
```

**Output:**
- File extension
- Total size and file count
- Percentage of storage and file count
- Average file size

---

### 7. Get-BackupTrends

Show backup size and duration trends over time.

```powershell
# Show trends for last 30 backups
Get-BackupTrends

# Show trends for last 50 backups
Get-BackupTrends -RecentCount 50
```

**Output:**
- Backup history with size, files, duration
- Trend analysis (increasing/decreasing)
- Average comparisons

---

### 8. Show-BackupAnalysisReport

Generate a comprehensive backup analysis report.

```powershell
# Quick overview report
Show-BackupAnalysisReport

# Detailed report with file and folder analysis
Show-BackupAnalysisReport -IncludeDetailed

# Analyze a specific backup
Show-BackupAnalysisReport -BackupId 603 -IncludeDetailed
```

**Includes:**
- Overall statistics
- Backup trends
- Category breakdown
- (Optional) File type distribution
- (Optional) Largest files and folders
- (Optional) Folder file counts

---

## Low-Level Functions

### Get-AllBackups

Get raw backup data from the database.

```powershell
# Get all backups
$backups = Get-AllBackups

# Get last 10 backups
$backups = Get-AllBackups -Limit 10

# Access backup properties
$backups | ForEach-Object {
    Write-Host "$($_.Name) - $($_.SizeMB) MB - $($_.Timestamp)"
}
```

### Get-BackupManifest

Read manifest.json from a backup ZIP.

```powershell
# Read manifest from backup path
$manifest = Get-BackupManifest -BackupPath "W:\Devices\P16\FULL_20251204-100203\FULL_20251204-100203.zip"

# Access manifest data
$manifest.backup_info
$manifest.backup_manifest
```

---

## Usage Examples

### Example 1: Quick Health Check

```powershell
. .\BackupAnalyzer.ps1
Get-BackupStatistics -RecentCount 5
Get-BackupTrends -RecentCount 10
```

### Example 2: Find Space Hogs

```powershell
. .\BackupAnalyzer.ps1
Get-LargestFiles -Top 20
Get-LargestFolders -Top 20
Get-CategoryBreakdown
```

### Example 3: Analyze Specific Backup

```powershell
. .\BackupAnalyzer.ps1

# Find backup ID
$backups = Get-AllBackups -Limit 10
$backups | Format-Table Id, Name, Timestamp

# Analyze that backup
$backupId = 603
Show-BackupAnalysisReport -BackupId $backupId -IncludeDetailed
```

### Example 4: File Type Analysis

```powershell
. .\BackupAnalyzer.ps1

Get-FileTypeDistribution -Top 30
# See which file types consume the most space
```

### Example 5: Full Comprehensive Report

```powershell
. .\BackupAnalyzer.ps1

Show-BackupAnalysisReport -IncludeDetailed | Tee-Object -FilePath "backup_report.txt"
```

---

## Performance Notes

- **Database queries** are fast (milliseconds)
- **Manifest reading** from ZIPs takes 2-5 seconds per backup
- **Analyzing 5 backups** typically takes 10-25 seconds
- Use `-BackupId` parameter to analyze specific backups for faster results

---

## Limitations

1. **Database Statistics**: For existing backups, `size_mb` and `file_count` in the database are 0. New backups created after the manifest fix will populate these correctly.
2. **ZIP Reading Performance**: Analyzer reads actual ZIP contents using .NET ZipArchive, which takes 2-5 seconds per backup
3. **Memory Usage**: Analyzing many large backups (60k+ files each) may consume significant memory
4. **Old Manifests**: Backups created before the manifest fix only track top-level paths (25 entries), not all files (60k+ entries)

---

## Troubleshooting

### Manifest Not Found

```
WARNING: manifest.json not found in backup: <path>
```

**Solution:** Ensure the backup ZIP contains a manifest.json file at the expected location:
`C:/temp/Backup/BACKUP_NAME/manifest.json`

### Database Not Found

```
ERROR: Database not found at: C:\Scripts\Backup\db\backup_history.db
```

**Solution:** Ensure you're running the script from the correct directory or the database exists.

### Empty Results

If category breakdown shows "No category data found":
- Check if the backup ZIPs exist at the paths stored in the database
- Verify the ZIP files contain manifest.json
- Try analyzing a specific, known-good backup with `-BackupId`

---

## Future Enhancements

- JSON export functionality
- Compare two backups side-by-side
- Historical trend charts
- Anomaly detection (unusual size increases)
- Backup health scoring
- Recommendation engine

---

## See Also

- [Main README](README.md) - Overall backup system documentation
- [TODO](TODO.md) - Planned features and improvements
- [Database Schema](../db/create-sqlite-database.ps1) - Database structure
