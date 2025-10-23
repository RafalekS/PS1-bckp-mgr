# PowerShell Backup System

A comprehensive, feature-rich backup solution for Windows built entirely in PowerShell. Designed for developers and power users who need reliable, automated backups with advanced features like differential backups, SSH transfers, and performance monitoring.

## Features

### Core Functionality
- **Multiple Backup Destinations:** Local drives, network shares (SMB), and SSH/SCP remote servers
- **Compression:** 7-Zip integration with configurable compression levels (0-9)
- **Backup Verification:** SHA-256 hash verification after compression
- **Backup Versioning:** Automatic rotation with configurable retention (keep last N backups)
- **Backup Manifest:** JSON manifest for each backup with full file inventory and metadata
- **Windows Settings Backup:** Registry exports, installed packages, system configuration

### Advanced Features (Phases 1-5 Complete)

#### Phase 1: Logging & Monitoring
- JSON or text logging with configurable log levels
- Backup statistics tracking (success/failure rates, average size/duration)
- Audit trail for all backup operations
- Health check script with Gotify notifications

#### Phase 2: Performance Optimization
- Real-time backup speed statistics (MB/s)
- Enhanced progress display with current file being processed
- Multi-threaded compression
- Parallel file operations
- ETA calculation with visual progress bars

#### Phase 3: Security Hardening
- Pre-flight permission validation (fail-fast on write errors)
- DPAPI encryption for secrets (Gotify tokens)
- Input sanitization to prevent injection attacks
- Path traversal prevention

#### Phase 4: Advanced Backup Strategies
- **Differential Backups:** Only backup files modified since last full backup
  - ⚠️ Note: Current implementation works at category-level (not file-level). See TODO for future improvements.
- Database schema supports backup strategies and parent/child relationships

#### Phase 5: Code Quality & Maintainability
- Refactored large functions (295→115 lines) for better AI-assisted maintenance
- 78-88% token reduction when debugging specific functionality
- Comprehensive helper functions for focused troubleshooting

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

## Usage

### Basic Backup
```powershell
# Full backup to local destination
.\main.ps1 -BackupType Full -Destination Local

# Development files backup to network share
.\main.ps1 -BackupType Dev -Destination Network

# Backup with custom compression level
.\main.ps1 -BackupType Full -Destination Local -CompressionLevel 9

# Differential backup (only changed files since last full)
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

See `config/bkp_cfg.example.json` for a complete configuration example.

### Key Configuration Sections

**Destinations:**
```json
"Destinations": {
  "Local": "D:\\Backup",
  "SSH": {
    "RemoteHost": "user@server",
    "RemotePath": "/backup/path",
    "SSHKeyPath": "$env:USERPROFILE\\.ssh\\id_rsa",
    "BandwidthLimit": 8000
  }
}
```

**Backup Types:**
```json
"BackupTypes": {
  "Full": ["Documents", "Scripts", "Config"],
  "Dev": ["Code", "Config"]
}
```

**Backup Items:**
```json
"BackupItems": {
  "Documents": [
    "$env:USERPROFILE\\Documents\\*.docx"
  ],
  "Scripts": [
    "C:\\Scripts"
  ]
}
```

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

## Development

### Completed Phases (10 of 17 features)

- ✅ **Phase 1:** Logging & Monitoring Foundation
  - JSON logging, statistics tracking, audit trail, health checks

- ✅ **Phase 2:** Backup Loop Enhancements
  - Speed statistics, enhanced progress display, logging improvements

- ✅ **Phase 3:** Security Hardening
  - Permissions validation, DPAPI secrets, input sanitization

- ⚠️ **Phase 4:** Advanced Backup Features (Partial)
  - Differential backups (category-level only - needs file-level rework)

- ✅ **Phase 5:** Performance & Code Quality
  - Function refactoring for better maintainability (78-88% token reduction)

### Planned Features (Phase 6)

See `help/TODO_FUTURE_IMPROVEMENTS.md` for detailed roadmap:

- **Interactive Restore Preview:** See what will be restored before committing
- **Backup Comparison Tool:** Compare two backups and show differences
- **Backup Schedule Suggestions:** AI-based schedule recommendations from backup history
- **File-Level Differential Backups:** True differential (only changed files, not entire directories)
- **Backup Deduplication:** Hash-based duplicate detection across backups

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

- **Backup Speed:** 50-100 MB/s (depending on disk speed and compression level)
- **Compression Ratio:** ~40-60% size reduction (level 5)
- **Multi-threading:** Enabled by default for compression
- **Parallel Operations:** Automatic for backup items with 3+ paths

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

## Author

Rafal Staska (RafalekS)
- GitHub: [@RafalekS](https://github.com/RafalekS)
- Email: r.staska@gmail.com

## Acknowledgments

- Built with Claude Code for AI-assisted development
- Optimized for AI-assisted maintenance (Phase 5 refactoring)
- Community-inspired features from backup best practices

---

**Status:** Active Development | **Version:** 4.4 | **Last Updated:** 2025-10-23
