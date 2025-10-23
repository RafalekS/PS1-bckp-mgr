# PowerShell Backup System

**Version:** 4.0
**Last Updated:** 2025-01-21
**Performance Mode:** Always Enabled (Default)

---

## 📋 Table of Contents

- [Overview](#overview)
- [Features](#features)
- [System Requirements](#system-requirements)
- [Quick Start](#quick-start)
- [Module Reference](#module-reference)
- [Configuration](#configuration)
- [Backup Types](#backup-types)
- [Destinations](#destinations)
- [Usage Examples](#usage-examples)
- [Scheduled Tasks](#scheduled-tasks)
- [Restoration](#restoration)
- [Performance Features](#performance-features)
- [Troubleshooting](#troubleshooting)
- [File Structure](#file-structure)

---

## Overview

Enterprise-grade PowerShell backup solution for Windows with comprehensive file and system settings backup capabilities. Features multi-threaded compression, SQLite database tracking, manifest-based restoration, and support for multiple backup destinations including local, network (SMB), and SSH/SCP.

**Key Highlights:**
- 🚀 Performance optimizations enabled by default (1.5-3x faster compression)
- 📁 File backups with intelligent categorization
- 🪟 Complete Windows settings backup (registry, configs, package lists)
- 💾 SQLite database for backup history tracking
- 🔄 Manifest-based granular restoration
- 🎯 Interactive GUI via `gum` terminal UI
- 📊 Real-time progress indicators
- 🔔 Gotify notifications (optional)
- 🧹 Automated cleanup with retention policies

---

## Features

### File Backup
- ✅ Scripts, applications, documents, game saves
- ✅ Browser profiles and bookmarks (Chrome, Edge, Firefox, Brave)
- ✅ PowerShell profiles (both PS5 and PS7)
- ✅ Development tools configurations
- ✅ SSH keys and user configs
- ✅ Smart file naming with automatic prefixes
- ✅ Organized archive structure (Applications, PowerShell, Games, etc.)

### Windows Settings Backup
- ✅ Registry exports (display, power, keyboard, mouse, regional settings)
- ✅ Taskbar and Start menu configuration
- ✅ File Explorer preferences and Quick Access
- ✅ Context menus and file associations
- ✅ Environment variables
- ✅ Package manager exports (winget, chocolatey, pip, cargo)
- ✅ WSL configuration
- ✅ Group Policy settings

### Performance Features (Always Enabled)
- 🚀 Multi-threaded 7-Zip compression
- 🚀 Parallel file operations for large datasets
- 🚀 Optimized registry exports with timeout handling
- 🚀 Performance metrics logging
- 🚀 Intelligent path validation

### Restoration
- ✅ Interactive mode with step-by-step guidance
- ✅ Selective restoration (choose specific files/categories)
- ✅ Restore to original locations or custom destination
- ✅ Registry import confirmation prompts
- ✅ Manifest-based file mapping

---

## System Requirements

### Required
- **OS:** Windows 10/11 (PowerShell 5.1+)
- **7-Zip:** Compression utility
- **gum:** Terminal UI framework ([Charm Bracelet](https://github.com/charmbracelet/gum))
- **SQLite:** System.Data.SQLite.dll (included in `db/` folder)

### Optional
- **gsudo:** For backing up privileged paths (C:\Windows, Program Files)
- **OpenSSH:** For SSH/SCP transfers
- **Gotify:** For push notifications
- **CredentialManager:** PowerShell module for credential backup

### Installation
```powershell
# Install gum (via winget, chocolatey, or scoop)
winget install charmbracelet.gum

# Install gsudo (optional but recommended)
winget install gsudo

# Install 7-Zip
winget install 7zip.7zip
```

---

## Quick Start

### GUI Mode (Recommended)
```powershell
cd C:\Scripts\Backup
.\backup_mgr.ps1
```

### Command Line
```powershell
# File backup
.\main.ps1 -BackupType Full -Destination Local

# Windows settings backup
.\main.ps1 -BackupType WinSettings-Essential -Destination HomeNet -LogLevel INFO

# Custom compression level
.\main.ps1 -BackupType Games -Destination USB -CompressionLevel 9

# Dry run (preview only)
.\main.ps1 -BackupType Dev -Destination Tests -DryRun
```

### Restore Backup
```powershell
# Interactive restoration
.\RestoreBackup.ps1 -RestoreMode Interactive -LogLevel INFO

# Quick restore specific backup
.\RestoreBackup.ps1 -BackupId 15 -RestoreMode Interactive
```

---

## Module Reference

### Core Modules

#### **backup_mgr.ps1** (30KB)
Main GUI launcher using `gum` for interactive backup operations.

**Features:**
- Dynamic backup type and destination selection
- Real-time backup descriptions
- Progress indicators
- Performance metrics display
- Integrated restore functionality
- Database-driven backup deletion

**Usage:**
```powershell
.\backup_mgr.ps1
```

---

#### **main.ps1** (670 lines)
Core backup engine with performance optimizations built-in.

**Parameters:**
- `-BackupType` (Required) - Type of backup to perform
- `-Destination` (Required) - Where to store the backup
- `-LogLevel` (Optional) - INFO, DEBUG, WARNING, ERROR (default: WARNING)
- `-ConfigFile` (Optional) - Path to config file (default: config\bkp_cfg.json)
- `-CompressionLevel` (Optional) - 0-9 (default: 5)
- `-DryRun` (Optional) - Preview mode without actual backup
- `-Help` (Optional) - Display help message

**Usage:**
```powershell
.\main.ps1 -BackupType Full -Destination HomeNet -LogLevel INFO
```

**Key Functions:**
- `Perform-Backup` - Main backup orchestration
- `Process-BackupItems` - Iterates through backup items
- `Invoke-WindowsSettingsCategory-Enhanced` - Windows settings processing
- `Invoke-WindowsSettingsItem-Enhanced` - Individual setting export

---

#### **BackupUtilities.ps1** (2,200 lines)
Shared utility library with performance-enhanced functions.

**Core Functions:**
- `Initialize-Logging` - Set up logging system
- `Write-Log` - Multi-level logging
- `Parse-ConfigFile` - Load and validate configuration
- `Validate-BackupParameters` - Input validation
- `Check-Dependencies` - Verify required tools
- `Update-BackupDatabase` - SQLite database operations
- `Send-GotifyNotification` - Push notifications

**Performance Functions:**
- `Get-SmartBackupFileName` - Intelligent file naming with prefixes
- `Backup-Files-Optimized` - Pre-validated path copying
- `Compress-Backup-Optimized` - Multi-threaded 7-Zip compression
- `Measure-BackupPerformance` - Performance metrics tracking
- `Export-RegistryKey-Optimized` - Registry export with timeout handling

**Compression Functions:**
- `Compress-Backup` - Standard 7-Zip compression
- `Verify-Backup` - SHA256 hash verification
- `Manage-BackupVersions` - Retention policy enforcement

**Destination Functions:**
- `Backup-ToSSH` - SCP transfer with hash verification
- `Backup-ToLocal` - Local filesystem backup
- `Backup-ToNetwork` - SMB network share backup

---

#### **WinBackup.ps1** (47KB)
Windows Settings Backup Module with registry and config export capabilities.

**Key Functions:**
- `Invoke-WindowsSettingsBackup` - Main Windows settings orchestration
- `Initialize-WindowsBackupDirectory` - Directory structure creation
- `Invoke-WindowsSettingsCategory` - Category-level processing
- `Invoke-WindowsSettingsItem` - Individual item export
- `Copy-WindowsSettingsFile` - File-based settings backup
- `Copy-WindowsSettingsFolder` - Folder-based settings backup
- `Invoke-ExportCommand` - Custom export command execution

**Supported Categories:**
- Display & UI (WinInterface)
- Input & Regional (WinInput)
- Network & Connectivity
- Privacy & Security
- System Configuration
- Developer Settings

---

#### **RestoreBackup.ps1** (46KB)
Comprehensive restoration system with manifest support.

**Modes:**
1. **Interactive** - Step-by-step guided restoration
2. **Selective** - Choose specific files/categories to restore

**Parameters:**
- `-BackupId` (Optional) - Specific backup ID to restore
- `-RestoreMode` (Optional) - Interactive or Selective (default: Interactive)
- `-RestoreDestination` (Optional) - Custom restore location
- `-LogLevel` (Optional) - Logging level
- `-DryRun` (Optional) - Preview restoration without executing

**Features:**
- ✅ Manifest-based file mapping
- ✅ Original or custom destination support
- ✅ Registry import confirmation dialogs
- ✅ Granular file selection
- ✅ Progress tracking
- ✅ Error handling and rollback

**Usage:**
```powershell
# Interactive restoration
.\RestoreBackup.ps1 -RestoreMode Interactive

# Restore specific backup to custom location
.\RestoreBackup.ps1 -BackupId 23 -RestoreDestination "C:\Temp\Restore"

# Preview restoration
.\RestoreBackup.ps1 -BackupId 23 -DryRun
```

---

#### **ManifestUtilities.ps1** (12KB)
Manifest generation for backup restoration tracking.

**Key Functions:**
- `Initialize-BackupManifest` - Create new manifest
- `Add-FileToManifest` - Track file backup location
- `Add-RegistryToManifest` - Track registry export
- `Add-WindowsSettingsToManifest` - Track Windows settings
- `Add-SpecialItemToManifest` - Track special items (certs, credentials)
- `Finalize-BackupManifest` - Write manifest.json to backup

**Manifest Structure:**
```json
{
  "backup_info": {
    "backup_type": "Full",
    "backup_name": "Full_20250121-143022",
    "created_timestamp": "20250121-143022",
    "creation_date": "2025-01-21 14:30:22",
    "manifest_version": "1.0",
    "total_files": 245,
    "total_folders": 38,
    "backup_items": ["Scripts", "PowerShell", "Games"]
  },
  "backup_manifest": {
    "Files/PowerShell/PS7_Microsoft.PowerShell_profile.ps1": {
      "original_path": "C:\\Users\\r_sta\\Documents\\PowerShell\\Microsoft.PowerShell_profile.ps1",
      "backup_item": "PowerShell",
      "file_type": "file",
      "archive_relative_path": "Files/PowerShell/PS7_Microsoft.PowerShell_profile.ps1",
      "size_bytes": 8432,
      "last_modified": "2025-01-15 10:23:45"
    }
  }
}
```

---

#### **config_manager.ps1** (67KB)
Interactive configuration management tool.

**Features:**
- ✅ Add/edit/delete backup items
- ✅ Create/modify backup types
- ✅ Manage folder categorization
- ✅ Configuration validation
- ✅ Automatic backups of config changes
- ✅ View current configuration

**Usage:**
```powershell
.\config_manager.ps1
```

**Menus:**
1. View Current Configuration
2. Manage Backup Items
3. Manage Backup Types
4. Manage Folder Categorization
5. Special Handling
6. Configuration Tools

---

#### **cleanup_backups.ps1** (17KB)
Automated backup cleanup with retention policies.

**Parameters:**
- `-Force` (Optional) - Actually delete backups (default is dry-run)
- `-OlderThan` (Optional) - Delete backups older than N days
- `-DryRun` (Optional) - Preview deletions
- `-LogLevel` (Optional) - Logging level
- `-ConfigFile` (Optional) - Config file path

**Retention Policy:**
- Games: Keep 10 backups
- All other types: Keep 5 backups
- OlderThan overrides count limits

**Usage:**
```powershell
# Preview what would be deleted
.\cleanup_backups.ps1

# Actually delete old backups
.\cleanup_backups.ps1 -Force

# Delete backups older than 30 days
.\cleanup_backups.ps1 -OlderThan 30 -Force
```

---

## Configuration

### Configuration File: `config\bkp_cfg.json`

**Structure:**
```json
{
  "ConfigVersion": {
    "version": "4.0",
    "lastModified": "2025-01-21",
    "description": "Simplified backup configuration"
  },
  "TempPath": "C:\\Temp\\Backup",
  "BackupVersions": 5,
  "Tools": {
    "7Zip": "C:\\Program Files\\7-Zip\\7z.exe",
    "SCP": "c:\\windows\\System32\\OpenSSH\\scp.exe"
  },
  "Destinations": { ... },
  "Notifications": { ... },
  "Logging": { ... },
  "BackupItems": { ... },
  "BackupTypes": { ... }
}
```

### Key Configuration Sections

#### **Destinations**
```json
"Destinations": {
  "Gdrive": "g:\\My Drive\\Devices\\P16",
  "USB": "D:\\Backup\\Devices\\P16",
  "Tests": "c:\\Temp\\Tests",
  "HomeNet": {
    "Path": "W:\\Devices\\P16"
  },
  "SSH": {
    "RemoteHost": "pi@raspi5-nvme",
    "RemotePath": "/media/pi/Media/Backup/Devices/P16/",
    "SSHKeyPath": "C:\\Users\\R_sta\\.ssh\\keys\\open_ssh.key"
  }
}
```

#### **Backup Types**
```json
"BackupTypes": {
  "Full": [
    "Scripts", "PowerShell", "Applications", "Documents",
    "UserConfigs", "Browsers", "PowerToys", "Games",
    "WinSettings-Full"
  ],
  "Games": ["Games"],
  "Dev": ["Scripts", "PowerShell", "UserConfigs"],
  "WinSettings-Minimal": ["WinInterface", "WinInput"],
  "WinSettings-Essential": [
    "WinInterface", "WinInput", "WinExplorer", "WinTaskbar"
  ],
  "WinSettings-Full": [
    "All Windows settings categories..."
  ]
}
```

#### **Backup Items**
```json
"BackupItems": {
  "Scripts": ["C:\\Scripts"],
  "PowerShell": [
    "C:\\Program Files\\WindowsPowerShell\\Scripts",
    "C:\\Users\\r_sta\\.config\\powershell",
    "C:\\Users\\r_sta\\Documents\\PowerShell\\Microsoft.PowerShell_profile.ps1"
  ],
  "Games": [
    "C:\\Games\\Adult\\confined-with-goddesses\\game\\saves",
    "C:\\Users\\r_sta\\AppData\\LocalLow\\Lord Goblin\\Lord Goblin"
  ],
  "WinInterface": {
    "type": "windows_settings",
    "category": "Display and User Interface",
    "items": [
      {
        "id": 6,
        "name": "Display scaling and resolution preferences",
        "registry_keys": [
          "HKEY_CURRENT_USER\\Control Panel\\Desktop",
          "HKEY_LOCAL_MACHINE\\SYSTEM\\CurrentControlSet\\Control\\GraphicsDrivers\\Configuration"
        ]
      }
    ]
  }
}
```

---

## Backup Types

### File Backups

#### **Full**
Complete system backup including all files and Windows settings.

**Includes:**
- Scripts, Applications, Documents
- PowerShell profiles, PowerToys, Windows Terminal
- User configurations, SSH keys, game saves
- Browser bookmarks and settings
- Complete Windows settings backup

**Estimated Time:** 10-20 minutes
**Typical Size:** 1-5 GB (depending on data)

---

#### **Games**
Game save files from various locations.

**Includes:**
- Adult game saves (C:\Games\Adult\*)
- AppData game saves (LocalLow\*)
- Steam/Epic game data (if configured)

**Estimated Time:** 1-3 minutes
**Typical Size:** 10-500 MB

---

#### **Dev**
Development environment essentials.

**Includes:**
- Scripts folder
- PowerShell profiles and scripts
- User configurations (.ssh, .config, etc.)
- Development tool settings

**Estimated Time:** 2-5 minutes
**Typical Size:** 100-500 MB

---

### Windows Settings Backups

#### **WinSettings-Minimal**
Essential system settings only.

**Includes:**
- Display scaling and resolution
- Power management settings
- Mouse, keyboard, regional settings
- Network profiles
- Environment variables

**Estimated Time:** 2-3 minutes
**Typical Size:** ~50 MB

---

#### **WinSettings-Essential**
Common user preferences.

**Includes:**
- All Minimal settings plus:
- Taskbar and Start menu configuration
- File Explorer preferences and Quick Access
- Context menus and file associations
- Privacy and security settings
- Terminal and PowerShell profiles

**Estimated Time:** 3-5 minutes
**Typical Size:** ~100 MB

---

#### **WinSettings-Full**
Complete system configuration.

**Includes:**
- All Essential settings plus:
- Advanced system settings and Group Policy
- Windows features and service configurations
- Developer settings and WSL configuration
- Application settings (browsers, Office)
- Package manager exports (winget, chocolatey, pip, cargo)
- Event logs and system diagnostics

**Estimated Time:** 5-10 minutes
**Typical Size:** ~200 MB

---

## Destinations

### Local
Direct backup to local drives.

**Configuration:**
```json
"Gdrive": "g:\\My Drive\\Devices\\P16",
"USB": "D:\\Backup\\Devices\\P16"
```

**Use Cases:**
- Quick backups to external drives
- Google Drive sync folder
- Local NAS mounts

---

### Network (SMB)
Backup to network shares.

**Configuration:**
```json
"HomeNet": {
  "Path": "W:\\Devices\\P16"
}
```

**Use Cases:**
- NAS/Server backups
- Shared network storage
- Corporate file servers

---

### SSH/SCP
Secure remote transfers.

**Configuration:**
```json
"SSH": {
  "RemoteHost": "pi@raspi5-nvme",
  "RemotePath": "/media/pi/Media/Backup/Devices/P16/",
  "SSHKeyPath": "C:\\Users\\R_sta\\.ssh\\keys\\open_ssh.key"
}
```

**Features:**
- ✅ Automatic remote directory creation
- ✅ SHA256 hash verification
- ✅ Transfer speed monitoring
- ✅ SSH key authentication

**Use Cases:**
- Remote server backups
- Raspberry Pi/Linux server storage
- Off-site backup replication

---

## Usage Examples

### Command Line Examples

#### Basic File Backup
```powershell
# Backup scripts to local destination
.\main.ps1 -BackupType Scripts -Destination Tests

# Backup games to USB drive
.\main.ps1 -BackupType Games -Destination USB

# Full backup to network share
.\main.ps1 -BackupType Full -Destination HomeNet
```

#### Windows Settings Backup
```powershell
# Minimal Windows settings
.\main.ps1 -BackupType WinSettings-Minimal -Destination Gdrive

# Essential settings with debug logging
.\main.ps1 -BackupType WinSettings-Essential -Destination HomeNet -LogLevel DEBUG

# Full settings to SSH server
.\main.ps1 -BackupType WinSettings-Full -Destination SSH -LogLevel INFO
```

#### Advanced Options
```powershell
# Maximum compression (slower but smaller)
.\main.ps1 -BackupType Full -Destination USB -CompressionLevel 9

# Fast compression (faster but larger)
.\main.ps1 -BackupType Games -Destination Tests -CompressionLevel 1

# Dry run (preview only)
.\main.ps1 -BackupType Dev -Destination Tests -DryRun

# Custom config file
.\main.ps1 -BackupType Full -Destination HomeNet -ConfigFile ".\config\custom_config.json"
```

---

### GUI Examples

#### Launch Backup Manager
```powershell
.\backup_mgr.ps1
```

**Workflow:**
1. Select "Perform Backup"
2. Choose backup type (Full, Games, Dev, WinSettings-*)
3. Select destination (Local, HomeNet, SSH, etc.)
4. Choose log level (INFO, DEBUG, WARNING, ERROR)
5. Review backup details and performance features
6. Confirm and execute

#### Restore Backup
```powershell
.\backup_mgr.ps1
```

**Workflow:**
1. Select "Restore Backup"
2. Choose restoration mode:
   - **Interactive** - Guided step-by-step
   - **Quick** - Select backup and restore completely
3. Select backup from list
4. Choose destination (original or custom)
5. Confirm and execute

#### Delete Old Backups
```powershell
.\backup_mgr.ps1
```

**Workflow:**
1. Select "Delete Backups"
2. View list of available backups with details
3. Select backup to delete
4. Confirm deletion (deletes both file and database entry)

---

## Scheduled Tasks

### Task 1: Full Backup to HomeNet (Weekly)
```powershell
# PowerShell Arguments
-ExecutionPolicy Bypass -WindowStyle Hidden -NoProfile -NonInteractive -NoLogo -File "c:\Scripts\Backup\main.ps1" -BackupType FULL -Destination Homenet -LogLevel WARNING
```

**Trigger:** Weekly, Sunday 2:00 AM
**User:** SYSTEM (or your user account)
**Run whether user is logged on or not:** Yes

---

### Task 2: Full Backup to Google Drive (Daily)
```powershell
# PowerShell Arguments
-ExecutionPolicy Bypass -WindowStyle Hidden -NoProfile -NonInteractive -NoLogo -File "c:\Scripts\Backup\main.ps1" -BackupType FULL -Destination Gdrive -LogLevel WARNING
```

**Trigger:** Daily, 1:00 AM
**User:** Your user account (for Google Drive access)
**Run whether user is logged on or not:** Yes

---

### Task 3: Cleanup Old Backups (Monthly)
```powershell
# PowerShell Arguments
-ExecutionPolicy Bypass -WindowStyle Hidden -File "c:\Scripts\Backup\cleanup_backups.ps1" -Force
```

**Trigger:** Monthly, 1st of month, 3:00 AM
**User:** SYSTEM or your user account

---

### Creating Scheduled Tasks

**Option 1: Task Scheduler GUI**
1. Open Task Scheduler (taskschd.msc)
2. Create Basic Task
3. Set trigger (daily, weekly, monthly)
4. Action: Start a program
   - Program: `pwsh.exe` (or `powershell.exe`)
   - Arguments: (see above)
5. Configure conditions and settings

**Option 2: PowerShell**
```powershell
# Example: Create weekly backup task
$action = New-ScheduledTaskAction -Execute "pwsh.exe" -Argument '-ExecutionPolicy Bypass -WindowStyle Hidden -NoProfile -NonInteractive -NoLogo -File "c:\Scripts\Backup\main.ps1" -BackupType FULL -Destination Homenet -LogLevel WARNING'

$trigger = New-ScheduledTaskTrigger -Weekly -DaysOfWeek Sunday -At 2am

Register-ScheduledTask -TaskName "WeeklyBackup-HomeNet" -Action $action -Trigger $trigger -User "SYSTEM" -RunLevel Highest
```

---

## Restoration

### Interactive Restoration Mode

**Features:**
- Step-by-step guided process
- Choose complete or selective restoration
- Registry import confirmation prompts
- Original or custom destination support

**Usage:**
```powershell
.\RestoreBackup.ps1 -RestoreMode Interactive -LogLevel INFO
```

**Workflow:**
1. Lists all available backups from database
2. Select backup to restore
3. Choose restoration scope:
   - **Complete** - Restore everything
   - **Selective** - Choose specific files/categories
4. Select destination:
   - **Original Locations** - Restore to original paths
   - **Custom Location** - Restore to specified directory
5. Review manifest and file list
6. Confirm restoration
7. Execute with progress tracking
8. Registry imports prompt for confirmation

---

### Quick Restoration Mode

**Features:**
- Fast complete restoration
- Minimal prompts
- Entire backup restored at once

**Usage:**
```powershell
# Restore specific backup ID
.\RestoreBackup.ps1 -BackupId 23 -RestoreMode Interactive -LogLevel INFO

# Restore to custom location
.\RestoreBackup.ps1 -BackupId 23 -RestoreDestination "C:\Temp\Restore"
```

---

### Selective Restoration

**Process:**
1. Extract backup to temp directory
2. Load manifest.json
3. Display categorized file list
4. User selects files/folders/categories
5. Restore selected items only
6. Clean up temp directory

**Example:**
```powershell
# Launch selective restoration
.\RestoreBackup.ps1 -RestoreMode Selective -LogLevel DEBUG

# Select from available options:
# - Restore entire categories (Scripts, PowerShell, Games)
# - Restore individual files
# - Restore specific registry keys
# - Restore Windows settings
```

---

### Registry Restoration

**Automatic Handling:**
- Registry files (.reg) detected automatically
- Confirmation prompt before each import
- Option to skip individual registry files
- Logs all registry import operations

**Manual Registry Import:**
```powershell
# If you prefer manual import
regedit.exe /s "path\to\exported\registry.reg"
```

---

## Performance Features

### Always Enabled Optimizations

#### Multi-Threaded Compression
**7-Zip Arguments:**
```
-mmt=on          # Enable multi-threading
-md=64m          # 64MB dictionary size (for .7z)
-mfb=64          # Fast bytes optimization
-mem=AES256      # AES256 encryption (for .zip)
```

**Benefits:**
- 1.5-3x faster compression
- Better CPU utilization
- Reduced backup time

---

#### Optimized File Operations
**Path Validation:**
- Pre-validates all paths before processing
- Batch processing (10 paths per batch)
- Efficient environment variable expansion
- Progress tracking for large path lists

**Smart File Naming:**
- Auto-prefixes: PS5_, PS7_, Chrome_, Edge_, Brave_, Firefox_
- Game save naming: Game_[GameName]_
- Handles special characters and length limits

---

#### Enhanced Registry Exports
**Timeout Handling:**
- 60-second timeout per registry key
- Automatic process termination on timeout
- Skips known problematic large keys
- Better error handling

**Problematic Keys Skipped:**
- HKEY_CLASSES_ROOT (massive)
- HKEY_LOCAL_MACHINE\SOFTWARE\Classes (huge)
- Context menu handlers (slow)

---

#### Performance Monitoring
**Metrics Tracked:**
- Total operation time
- Memory usage per operation
- Compression speed (MB/s)
- File transfer rates (for SSH)

**Output Example:**
```
PERFORMANCE: File operations (Performance Mode) completed in 42.35s (Memory: +12.5 MB)
PERFORMANCE: Compression (Performance Mode) completed in 68.22s
PERFORMANCE: Total Backup Operation completed in 115.89s (Memory: +18.3 MB)
```

---

## Troubleshooting

### Common Issues

#### Issue: "7-Zip not found"
**Solution:**
```powershell
# Check 7-Zip installation
Test-Path "C:\Program Files\7-Zip\7z.exe"

# Update config file if installed elsewhere
# Edit config\bkp_cfg.json -> Tools.7Zip
```

---

#### Issue: "gum command not found"
**Solution:**
```powershell
# Install gum
winget install charmbracelet.gum

# OR via Chocolatey
choco install gum

# OR via Scoop
scoop install gum
```

---

#### Issue: "SQLite assembly not loaded"
**Solution:**
```powershell
# Verify SQLite DLL exists
Test-Path ".\db\System.Data.SQLite.dll"

# If missing, download from:
# https://system.data.sqlite.org/downloads/
```

---

#### Issue: "Insufficient disk space"
**Solution:**
- Check estimated backup size in logs
- Free up space on destination
- Use higher compression level to reduce size
- Clean up old backups: `.\cleanup_backups.ps1 -Force`

---

#### Issue: "Registry export timeout"
**Solution:**
- Timeouts are logged and skipped automatically
- Check logs for problematic keys
- Known large keys are skipped by default
- Registry key may be too large (>100MB)

---

#### Issue: "SSH transfer failed"
**Solution:**
```powershell
# Test SSH connection manually
ssh -i "C:\Users\R_sta\.ssh\keys\open_ssh.key" pi@raspi5-nvme

# Check remote path exists
ssh -i "C:\Users\R_sta\.ssh\keys\open_ssh.key" pi@raspi5-nvme "ls -la /media/pi/Media/Backup/"

# Verify SSH key permissions (should be 600/read-only)
```

---

#### Issue: "Backup verification failed"
**Solution:**
- Indicates hash mismatch after compression
- Check disk integrity
- Try lower compression level
- Check for antivirus interference

---

### Logs

**Log Location:**
```
log\backup.log      # Main backup operations
log\delete.log      # Cleanup operations
```

**Log Format:**
```
2025-01-21 14:30:22|INFO|Starting file backup: Type=Full, Destination=HomeNet
2025-01-21 14:30:23|INFO|Estimated backup size: 2.34 GB
2025-01-21 14:30:25|DEBUG|Copying with Copy-Item: C:\Scripts
2025-01-21 14:32:15|INFO|PERFORMANCE: File operations completed in 110.52s
```

**Debugging:**
```powershell
# Enable debug logging
.\main.ps1 -BackupType Full -Destination Tests -LogLevel DEBUG

# View recent logs
Get-Content .\log\backup.log -Tail 50
```

---

### Database

**Database Location:**
```
db\backup_history.db
```

**Schema:**
```sql
CREATE TABLE backups (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    backup_set_name TEXT NOT NULL,
    backup_type TEXT NOT NULL,
    destination_type TEXT,
    destination_path TEXT,
    timestamp DATETIME DEFAULT CURRENT_TIMESTAMP,
    size_bytes INTEGER,
    compression_method TEXT,
    encryption_method TEXT,
    source_paths TEXT,
    additional_metadata TEXT
);
```

**Query Backups:**
```powershell
# Via PowerShell
Add-Type -Path "db\System.Data.SQLite.dll"
$connection = New-Object System.Data.SQLite.SQLiteConnection("Data Source=.\db\backup_history.db")
$connection.Open()
$command = $connection.CreateCommand()
$command.CommandText = "SELECT * FROM backups ORDER BY timestamp DESC LIMIT 10"
$reader = $command.ExecuteReader()
while ($reader.Read()) {
    "{0} - {1} - {2} GB" -f $reader["timestamp"], $reader["backup_type"], ([math]::Round($reader["size_bytes"] / 1GB, 2))
}
$connection.Close()
```

---

## File Structure

```
C:\Scripts\Backup\
│
├── backup_mgr.ps1                 # Main GUI launcher (30KB)
├── main.ps1                       # Core backup engine (670 lines)
├── BackupUtilities.ps1            # Utility library (2,200 lines)
├── WinBackup.ps1                  # Windows settings backup (47KB)
├── RestoreBackup.ps1              # Restoration system (46KB)
├── ManifestUtilities.ps1          # Manifest generation (12KB)
├── config_manager.ps1             # Configuration manager (67KB)
├── cleanup_backups.ps1            # Automated cleanup (17KB)
│
├── config\
│   └── bkp_cfg.json               # Main configuration file
│
├── db\
│   ├── backup_history.db          # SQLite database
│   └── System.Data.SQLite.dll     # SQLite assembly
│
├── log\
│   ├── backup.log                 # Main operation logs
│   └── delete.log                 # Cleanup operation logs
│
└── archive_old_versions\          # Archived legacy files
    ├── main.ps1                   # Original standard mode
    ├── BackupUtilities.ps1        # Original utilities
    ├── Main_Performance.ps1       # Legacy performance script
    └── BackupUtilities_Performance.ps1  # Legacy performance utilities
```

---

## Backup Archive Structure

### File Backups
```
Full_20250121-143022.zip
│
├── Files\
│   ├── Applications\
│   │   ├── AdminTray\
│   │   ├── Terminator\
│   │   └── WindowsTerminal\
│   │
│   ├── PowerShell\
│   │   ├── PS7_Microsoft.PowerShell_profile.ps1
│   │   ├── PS5_Microsoft.PowerShell_profile.ps1
│   │   └── Scripts\
│   │
│   ├── Games\
│   │   ├── Game_confined-with_saves\
│   │   └── Game_Lord_Goblin_Lord Goblin\
│   │
│   ├── Browsers\
│   │   ├── Chrome_Bookmarks
│   │   ├── Brave_Bookmarks
│   │   └── Firefox_Profiles\
│   │
│   ├── UserConfigs\
│   │   ├── Certificates\
│   │   ├── DoskeyMacros\
│   │   ├── WindowsCredentials\
│   │   └── .ssh\
│   │
│   └── Scripts\
│
└── manifest.json                  # File mapping for restoration
```

### Windows Settings Backups
```
WinSettings-Full_20250121-143022.zip
│
├── Registry\
│   ├── 6-HKEY_CURRENT_USER_Control Panel_Desktop.reg
│   ├── 9-HKEY_CURRENT_USER_SOFTWARE_Microsoft_Windows_CurrentVersion_Explorer_Advanced.reg
│   └── ...
│
├── Files\
│   ├── LayoutModification.xml
│   ├── AutoHotkey\
│   └── SendTo\
│
├── Exports\
│   ├── winget_list.json
│   ├── choco_list.txt
│   ├── pip_list.txt
│   └── cargo_list.txt
│
└── manifest.json                  # Settings mapping
```

---

## Version History

### Version 4.0 (2025-01-21)
**Major Changes:**
- ✅ Consolidated Main_Performance.ps1 into main.ps1
- ✅ Performance mode now always enabled (no longer optional)
- ✅ Merged BackupUtilities_Performance.ps1 into BackupUtilities.ps1
- ✅ Simplified backup_mgr.ps1 (removed performance mode selection)
- ✅ Improved documentation

**Performance Enhancements:**
- Multi-threaded 7-Zip compression (1.5-3x faster)
- Optimized file operations with path pre-validation
- Enhanced registry exports with timeout handling
- Performance metrics logging

**Breaking Changes:**
- `-PerformanceMode` parameter removed from main.ps1
- Main_Performance.ps1 deprecated (use main.ps1)
- BackupUtilities_Performance.ps1 deprecated (merged into BackupUtilities.ps1)

---

### Version 3.x (2024-2025)
- Dual-mode operation (Standard + Performance)
- Manifest-based restoration system
- Windows Settings backup categories
- SQLite database tracking
- Gotify notifications
- SSH/SCP support

---

### Version 2.x (2024)
- Windows Settings backup added
- Configuration manager
- Automated cleanup
- Multiple destinations

---

### Version 1.x (2023-2024)
- Initial release
- File backups only
- Local destinations
- Basic compression

---

## Support & Feedback

**Issues:** Report issues via GitHub or local documentation
**Configuration:** Use `config_manager.ps1` for interactive config editing
**Logs:** Check `log\backup.log` for detailed operation logs
**Database:** Query `db\backup_history.db` for backup history

---

## License

**Personal/Internal Use**
This backup system is designed for personal and internal organizational use.

---

## Credits

**Dependencies:**
- [7-Zip](https://www.7-zip.org/) - File compression
- [gum](https://github.com/charmbracelet/gum) - Terminal UI framework
- [SQLite](https://www.sqlite.org/) - Database engine
- [gsudo](https://github.com/gerardog/gsudo) - Windows sudo implementation

**PowerShell Modules:**
- CredentialManager - Windows Credential Manager integration

---

**END OF DOCUMENTATION**
