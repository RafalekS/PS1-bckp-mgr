# PowerShell Backup System

A comprehensive, feature-rich backup solution for Windows built entirely in PowerShell. Designed for developers and power users who need reliable, automated backups with advanced features like differential backups, SSH transfers, and performance monitoring.

**Version:** 4.4
**Last Updated:** 30/10/2025
**Status:** Active Development (10 of 17 planned features complete)

## Table of Contents
- [Features](#features)
- [Requirements](#requirements)
- [Installation](#installation)
- [Usage](#usage)
- [Configuration](#configuration)
- [Backup Types](#backup-types)
- [Destination Types](#destination-types)
- [Performance](#performance)
- [Security](#security)
- [Troubleshooting](#troubleshooting)

## Features

### Core Functionality
- **Multiple Backup Destinations:** Local drives, network shares (SMB), and SSH/SCP remote servers
- **Compression:** 7-Zip integration with configurable compression levels (0-9) and presets
- **Backup Verification:** SHA-256 hash verification after compression
- **Backup Versioning:** Automatic rotation with configurable retention (keep last N backups)
- **Backup Manifest:** JSON manifest for each backup with full file inventory and metadata
- **Windows Settings Backup:** Registry exports, installed packages, system configuration, certificates

### Advanced Features (Phases 1-5 Complete)

#### Phase 1: Logging & Monitoring
- **Dual-format Logging:** JSON or text (pipe-delimited) with configurable format
- **Statistics Tracking:** Success/failure rates, average size, duration, backup counts
- **Audit Trail:** Complete log of all backup operations (start, complete, compression, transfers)
- **Health Check Script:** Standalone monitoring with Gotify notifications
  - Checks last backup time, disk space, database integrity
  - Configurable thresholds and alerts
  - Exit codes for integration with monitoring systems

#### Phase 2: Performance Optimization
- **Real-time Speed Statistics:** Live MB/s monitoring during backup
- **Enhanced Progress Display:**
  - Visual progress bar with percentage
  - Current file being processed (truncated to 80 chars)
  - Accurate ETA calculation
  - Speed statistics every 10 files
- **Optimized Operations:**
  - Multi-threaded 7-Zip compression
  - Parallel file operations (3+ paths)
  - Efficient logging with proper flushing

#### Phase 3: Security Hardening
- **DPAPI Secrets Management:**
  - Windows DPAPI encryption for Gotify tokens
  - User-specific encryption (machine-bound)
  - No plaintext credentials in configs or logs
- **Input Sanitization:**
  - Path traversal prevention
  - Dangerous character removal
  - Control sequence filtering
  - Length validation
- **Pre-flight Validation:**
  - Write permission testing before backup
  - Fail-fast approach saves time
  - Clear error messages

#### Phase 4: Advanced Backup Strategies (Partial)
- **Differential Backups:** Changes since last full backup
  - Database schema: backup_strategy, parent_backup_id
  - Auto-fallback to full if no parent found
  - ⚠️ **Current Limitation:** Category-level (not file-level)
    - Backs up entire directories when one file changes
    - See TODO.md for planned file-level implementation
- **Backup Manifest System:**
  - JSON manifest for every backup
  - Complete file inventory with metadata
  - SHA-256 hashes for verification
  - Original paths preserved for restoration

#### Phase 5: Code Quality & Maintainability
- **Function Refactoring:**
  - Perform-Backup: 295 → 115 lines (6 helper functions)
  - Process-BackupItems: 207 → 72 lines (5 helper functions)
  - Compress-Backup-Optimized: 177 → 138 lines
- **Benefits:**
  - 78-88% token reduction for AI debugging
  - Easier to test individual functions
  - Better code reusability
  - Clearer separation of concerns

### Core Features

#### Backup Management
- **Multiple Destinations:** Local, network share, SSH/SCP
- **Compression:** 7-Zip with 10 levels (0-9) + named presets
- **Verification:** SHA-256 hash validation post-compression
- **Versioning:** Automatic rotation (keep last N backups)
- **Global Exclusions:** Skip common unnecessary files/folders
- **Dry Run Mode:** Test without executing backup

#### Windows Settings Backup
- **Registry Exports:** Full or selective registry key exports
- **Installed Packages:** Chocolatey, Scoop, winget package lists
- **Certificates:** User certificate inventory
- **SSH Keys:** SSH configuration and keys
- **PowerShell:** Profiles, modules, history
- **Doskey Macros:** Command aliases

#### Restoration Features
- **Interactive TUI:** gum-powered selection menus
- **Selective Restore:** Choose specific categories to restore
- **Destination Options:** Original location or custom path
- **Registry Import:** Bulk or manual registry import
- **Conflict Resolution:** Skip, overwrite, or rename existing files
- **Manifest-based:** Fast extraction of selected items only

### Notifications
- Gotify push notifications (start, completion, errors)
- Asynchronous notification delivery (non-blocking)

## Requirements

- **PowerShell:** 5.1 or PowerShell Core 7+
- **7-Zip:** For compression (download from [7-zip.org](https://www.7-zip.org/))
- **gum** (optional): For interactive menus in backup manager
- **SQLite:** For backup history database (included via .NET assembly)
- **SSH client:** For SSH/SCP transfers (Windows 10+ includes OpenSSH)

## Installation

1. Clone this repository:
   ```powershell
   git clone https://github.com/YOUR_USERNAME/powershell-backup-system.git
   cd powershell-backup-system
   ```

2. Copy the example configuration:
   ```powershell
   Copy-Item config\bkp_cfg.example.json config\bkp_cfg.json
   ```

3. Edit `config\bkp_cfg.json` to customize:
   - Backup destinations (local paths, network shares, SSH servers)
   - Backup types and items
   - Notification settings
   - Tool paths (7-Zip location)

4. (Optional) Set up encrypted Gotify token:
   ```powershell
   .\Setup-BackupCredentials.ps1 -GotifyToken "YOUR_TOKEN_HERE"
   ```

5. Initialize the database:
   ```powershell
   # Database is automatically created on first backup
   # Or manually run migrations:
   .\db\migrate-add-differential-support.ps1
   ```

## Backup Types

The system supports multiple predefined backup types, each targeting specific sets of files:

### Standard Backup Types
- **Full** - Complete system backup including all configured items
- **Dev** - Development files (code, scripts, configs)
- **Games** - Game saves and configuration
- **AI** - AI tool configurations (Claude, Cursor, Fabric, etc.)
- **Scripts** - PowerShell, Python, and other scripts

### Windows Settings Backups
- **WinSettings-Full** - Complete Windows configuration
- **WinSettings-PowerShell** - PowerShell profiles and modules
- **WinSettings-Registry** - Registry exports
- **WinSettings-Packages** - Installed packages (Chocolatey, Scoop, etc.)
- **WinSettings-SSH** - SSH keys and configuration
- **WinSettings-Certificates** - User certificates

Each backup type is fully configurable in `config\bkp_cfg.json`.

## Destination Types

### Local Destinations
Simple folder path for local or network-mapped drives:
```json
"Destinations": {
  "Local": "D:\\Backup",
  "USB": "E:\\Backup\\Devices\\Laptop"
}
```

### Network Share Destinations
Network paths with automatic connection handling:
```json
"HomeNet": {
  "Path": "\\\\NAS\\Backup\\Devices\\Laptop"
}
```

### SSH/SCP Destinations
Remote backup via SSH with bandwidth limiting:
```json
"SSH": {
  "RemoteHost": "user@server",
  "RemotePath": "/backup/path",
  "SSHKeyPath": "$env:USERPROFILE\\.ssh\\id_rsa",
  "BandwidthLimit": 8000
}
```

## Usage

### Basic Backup
```powershell
# Full backup to local destination
.\main.ps1 -BackupType Full -Destination Local

# Development files backup to network share
.\main.ps1 -BackupType Dev -Destination HomeNet

# Backup with custom compression level (0=store, 9=ultra)
.\main.ps1 -BackupType Full -Destination Local -CompressionLevel 9

# Differential backup (only changed files since last full)
# WARNING: Current differential implementation is category-level (backs up entire directories)
.\main.ps1 -BackupType Dev -Destination Local -BackupStrategy Differential
```

### Advanced Options
```powershell
# Dry run (validate paths without backing up)
.\main.ps1 -BackupType Full -Destination Local -DryRun

# Custom log level
.\main.ps1 -BackupType Full -Destination Local -LogLevel DEBUG

# SSH backup with bandwidth limiting
.\main.ps1 -BackupType Full -Destination SSH
```

### Restore Backups
```powershell
# Interactive restoration
.\RestoreBackup.ps1

# Restore specific backup
.\RestoreBackup.ps1 -BackupPath "D:\Backup\Full_20251023-120000"

# Selective restoration (choose specific items)
.\RestoreBackup.ps1 -BackupPath "..." -SelectiveRestore
```

### Health Check
```powershell
# Check backup system health
.\health-check.ps1
# Returns exit code: 0=OK, 1=WARNING, 2=ERROR
```

### Backup Management
```powershell
# Interactive backup manager (requires gum)
.\backup_mgr.ps1
```

### Configuration Management
```powershell
# Interactive config editor
.\config_manager.ps1
```

## Configuration

The system uses a JSON configuration file (`config\bkp_cfg.json`) with multiple sections:

### Core Configuration Sections

#### 1. Destinations
Define where backups are stored:
```json
"Destinations": {
  "Local": "D:\\Backup",
  "HomeNet": {
    "Path": "\\\\NAS\\Backup"
  },
  "SSH": {
    "RemoteHost": "user@server",
    "RemotePath": "/backup/path",
    "SSHKeyPath": "$env:USERPROFILE\\.ssh\\id_rsa",
    "BandwidthLimit": 8000
  }
}
```

#### 2. Backup Types
Define groups of items to backup together:
```json
"BackupTypes": {
  "Full": ["PowerShell", "Scripts", "UserConfigs", "Documents"],
  "Dev": ["PowerShell", "Scripts", "UserConfigs"],
  "Games": ["GameSaves"]
}
```

#### 3. Backup Items
Define what files/folders to include:
```json
"BackupItems": {
  "PowerShell": [
    "$env:USERPROFILE\\Documents\\PowerShell",
    "$env:USERPROFILE\\Documents\\WindowsPowerShell"
  ],
  "Scripts": [
    "C:\\Scripts"
  ],
  "UserConfigs": [
    "$env:USERPROFILE\\.gitconfig",
    "$env:USERPROFILE\\.ssh\\config"
  ]
}
```

#### 4. Global Exclusions
Paths and patterns to exclude from ALL backups:
```json
"GlobalExclusions": {
  "Folders": [
    "*\\node_modules",
    "*\\.git",
    "*\\__pycache__"
  ],
  "Files": [
    "*.tmp",
    "*.log",
    "Thumbs.db"
  ]
}
```

#### 5. Compression Presets
Predefined compression levels:
```json
"CompressionPresets": {
  "Store": 0,
  "Fastest": 1,
  "Fast": 3,
  "Normal": 5,
  "Maximum": 7,
  "Ultra": 9
}
```

#### 6. Statistics Tracking
Automatically tracked metrics:
```json
"Statistics": {
  "TotalBackups": 64,
  "SuccessfulBackups": 62,
  "FailedBackups": 2,
  "AverageSize_MB": 1119.54,
  "AverageDuration_Seconds": 633.0,
  "LastBackupDate": "2025-10-30 12:37:50"
}
```

#### 7. Notifications
Push notifications via Gotify:
```json
"Notifications": {
  "Gotify": {
    "Enabled": true,
    "Url": "http://server:port/message",
    "TokenEncrypted": "..."
  }
}
```

See `config\bkp_cfg.example.json` for a complete configuration template.

## Project Structure

```
powershell-backup-system/
├── main.ps1                       # Main backup script
├── RestoreBackup.ps1              # Backup restoration
├── BackupUtilities.ps1            # Core utility functions
├── WinBackup.ps1                  # Windows-specific backups
├── ManifestUtilities.ps1          # Manifest generation/parsing
├── health-check.ps1               # System health monitoring
├── Setup-BackupCredentials.ps1    # DPAPI credential encryption
├── backup_mgr.ps1                 # Interactive backup manager
├── config_manager.ps1             # Interactive config editor
├── cleanup_backups.ps1            # Manual backup cleanup
├── config/
│   ├── bkp_cfg.json               # Main configuration (gitignored)
│   └── bkp_cfg.example.json       # Configuration template
├── db/
│   ├── backup_history.db          # SQLite database (gitignored)
│   ├── schema.sql                 # Database schema
│   └── migrate-*.ps1              # Database migrations
├── log/
│   ├── backup.log                 # Backup logs (gitignored)
│   └── audit.log                  # Audit trail (gitignored)
└── help/
    └── TODO_FUTURE_IMPROVEMENTS.md # Roadmap and future enhancements
```

## Development Status

### Completed Phases (10 of 17 features) ✅

- **Phase 1: Logging & Monitoring Foundation** (Complete)
  - JSON/text logging with configurable format
  - Statistics tracking (64 backups tracked, 90.44 MB average)
  - Audit trail with separate log
  - Health check script with exit codes

- **Phase 2: Backup Loop Enhancements** (Complete)
  - Real-time speed statistics
  - Enhanced progress with current file display
  - Optimized logging with flushing

- **Phase 3: Security Hardening** (Complete)
  - DPAPI encryption for secrets
  - Input sanitization and validation
  - Pre-flight permission checks

- **Phase 4: Advanced Backup Features** (Partial - 50%)
  - ✅ Differential backup infrastructure (database, tracking)
  - ⚠️ Current implementation: category-level (needs file-level rework)
  - ✅ Complete manifest system with SHA-256 hashes

- **Phase 5: Performance & Code Quality** (Complete)
  - Major function refactoring (295→115 lines)
  - 78-88% token reduction for AI maintenance
  - Improved code organization

### Pending Features (Phase 6) 🔄

See `help\TODO.md` and `help\TODO_FUTURE_IMPROVEMENTS.md` for details:

1. **Interactive Restore Preview** - Show backup contents before restoration
2. **Backup Comparison Tool** - Diff two backups (added/removed/modified)
3. **Backup Schedule Suggestions** - Data-driven schedule recommendations

### Future Work (Deferred) 📋

- **File-Level Differential Backups:** Rework Phase 4 to backup only changed files
- **Backup Deduplication:** Hash-based duplicate detection across backups
- **Tar-like Archive Structure:** Standard backup format (breaking change)

### Recent Fixes (30/10/2025)

1. Fixed missing paths display - shows ALL missing paths
2. Fixed AI folder mapping - correct destination (Files/AI/)
3. Fixed duplicate logging - size estimates logged once
4. Fixed GlobalExclusions in size calculation
5. Fixed critical `-or` operator bug in size calculations

## Testing

```powershell
# Test full backup
.\main.ps1 -BackupType Dev -Destination Tests

# Test differential backup
.\main.ps1 -BackupType Dev -Destination Tests -BackupStrategy Differential

# Test health check
.\health-check.ps1

# Test restoration
.\RestoreBackup.ps1 -BackupPath "C:\Temp\Tests\Dev_YYYYMMDD-HHMMSS"
```

## Performance

### Speed and Efficiency
- **Backup Speed:** 50-100 MB/s (depending on disk speed and compression level)
- **Compression Ratio:** 40-60% size reduction (level 5), up to 70% (level 9)
- **Real-time Monitoring:** Live speed statistics (MB/s) during backup
- **ETA Calculation:** Accurate time remaining estimates
- **Progress Tracking:** Visual progress bar with current file display

### Optimization Features
- **Multi-threading:** 7-Zip compression uses multiple CPU cores
- **Parallel Operations:** Automatic parallel processing for backup items with 3+ paths
- **Smart Path Validation:** Batch validation reduces startup time
- **Efficient File Operations:** Optimized copy operations with proper error handling
- **Global Exclusions:** Skip unnecessary files (node_modules, .git, etc.) to save time and space

### Typical Performance
- Small backup (1 GB): 30-60 seconds
- Medium backup (10 GB): 3-5 minutes
- Large backup (50 GB): 15-25 minutes

Performance varies based on:
- Compression level (0=fastest, 9=slowest but best compression)
- Source drive speed (SSD vs HDD)
- Destination type (Local > Network > SSH)
- File count and types (many small files slower than few large files)

## Security

### Implemented Security Features (Phase 3)

#### 1. DPAPI Secrets Management
- Gotify tokens encrypted using Windows DPAPI (Data Protection API)
- User-specific encryption (tokens only decryptable by the same Windows account)
- No plaintext secrets in configuration files or process lists
- Automatic encryption setup via `Setup-BackupCredentials.ps1`

#### 2. Input Sanitization
- All user inputs validated and sanitized before use
- Protection against path traversal attacks (..\ sequences removed)
- Removal of dangerous characters and control sequences
- Limited string lengths to prevent buffer overflows

#### 3. Pre-flight Permission Validation
- Write permissions tested before backup starts
- Fail-fast approach prevents wasted time on inaccessible destinations
- Clear error messages for permission issues

#### 4. Secure File Operations
- SHA-256 hash verification for compressed backups
- Manifest tracking for file integrity validation
- Proper error handling to prevent partial backups

#### 5. Audit Trail
- Complete audit log of all backup operations
- Tracks: start/complete, compression, transfers, config changes
- Separate audit log with longer retention (90+ days recommended)

### Best Practices
- Use DPAPI encryption for all sensitive credentials
- Review audit logs regularly for suspicious activity
- Limit backup service account permissions to minimum required
- Use SSH keys (not passwords) for remote backups
- Enable bandwidth limiting for SSH to avoid network saturation
- Test restore operations regularly to ensure backup integrity

## Troubleshooting

### Common Issues

**"Cannot write to destination"**
- Check permissions on destination folder
- Ensure destination path exists
- For network shares, verify network connectivity

**"Compression failed"**
- Verify 7-Zip path in config is correct
- Check disk space on temp and destination drives
- Review compression level (9 = maximum, slowest)

**"SSH backup failed"**
- Test SSH connection manually: `ssh user@host`
- Verify SSH key path and permissions
- Check remote path exists and is writable

**"Differential backup backs up entire directory"**
- Known limitation: current differential works at category-level
- See Phase 4 notes in TODO for planned file-level implementation

### Debug Mode

```powershell
.\main.ps1 -BackupType Full -Destination Local -LogLevel DEBUG
# Check log\backup.log for detailed output
```

## License

This project is personal software. Feel free to use and modify for your own purposes.

## Contributing

This is a personal project, but suggestions and bug reports are welcome via GitHub issues.

### Reporting Issues
Please include:
- PowerShell version (`$PSVersionTable.PSVersion`)
- Error messages from `log\backup.log`
- Relevant config sections (sanitize sensitive data)
- Steps to reproduce

## Author

**Rafal Staska** (RafalekS)
- GitHub: [@RafalekS](https://github.com/RafalekS)
- Email: r.staska@gmail.com / rafaleks@gmail.com

## Acknowledgments

- Built with **Claude Code** for AI-assisted development
- Optimized for AI-assisted maintenance (Phase 5 refactoring achieved 78-88% token reduction)
- Community-inspired features from backup best practices
- Thanks to:
  - **7-Zip** for excellent compression
  - **Charm Bracelet** for gum TUI tools
  - **Gotify** for push notifications

## License

Personal software - free to use and modify for your own purposes. No warranty provided.

---

**Status:** Active Development | **Version:** 4.4 | **Last Updated:** 30/10/2025
**Completion:** 10 of 17 planned features (59%) | Phases 1-3 & 5 complete, Phase 4 partial, Phase 6 pending
