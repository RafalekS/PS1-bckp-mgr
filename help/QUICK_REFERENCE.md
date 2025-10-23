# PowerShell Backup System - Quick Reference

**Version:** 4.0 | **Performance Mode:** Always Enabled

---

## 🚀 Quick Start

```powershell
# GUI Mode (Recommended)
.\backup_mgr.ps1

# Command Line
.\main.ps1 -BackupType Full -Destination Local
```

---

## 📁 Common Commands

### Backup Operations

```powershell
# Full backup to network share
.\main.ps1 -BackupType Full -Destination HomeNet

# Games backup to USB
.\main.ps1 -BackupType Games -Destination USB

# Windows settings backup
.\main.ps1 -BackupType WinSettings-Essential -Destination Gdrive

# Development environment backup
.\main.ps1 -BackupType Dev -Destination Tests

# With verbose logging
.\main.ps1 -BackupType Full -Destination HomeNet -LogLevel INFO

# Maximum compression
.\main.ps1 -BackupType Full -Destination USB -CompressionLevel 9

# Dry run (preview only)
.\main.ps1 -BackupType Games -Destination Tests -DryRun
```

### Restore Operations

```powershell
# Interactive restoration
.\RestoreBackup.ps1 -RestoreMode Interactive

# Restore specific backup
.\RestoreBackup.ps1 -BackupId 23 -RestoreMode Interactive

# Restore to custom location
.\RestoreBackup.ps1 -BackupId 23 -RestoreDestination "C:\Temp\Restore"

# Preview restoration
.\RestoreBackup.ps1 -BackupId 23 -DryRun
```

### Cleanup Operations

```powershell
# Preview cleanup (dry run)
.\cleanup_backups.ps1

# Actually delete old backups
.\cleanup_backups.ps1 -Force

# Delete backups older than 30 days
.\cleanup_backups.ps1 -OlderThan 30 -Force
```

---

## 📋 Backup Types

| Type | Description | Time | Size |
|------|-------------|------|------|
| **Full** | Complete system (files + Windows settings) | 10-20 min | 1-5 GB |
| **Games** | Game save files | 1-3 min | 10-500 MB |
| **Dev** | Development environment | 2-5 min | 100-500 MB |
| **Scripts** | Scripts folder only | 1-3 min | 50-200 MB |
| **WinSettings-Minimal** | Essential system settings | 2-3 min | ~50 MB |
| **WinSettings-Essential** | Common user preferences | 3-5 min | ~100 MB |
| **WinSettings-Full** | Complete system configuration | 5-10 min | ~200 MB |

---

## 🎯 Destinations

| Name | Type | Path/Details |
|------|------|--------------|
| **Gdrive** | Local | `g:\My Drive\Devices\P16` |
| **USB** | Local | `D:\Backup\Devices\P16` |
| **HomeNet** | Network | `W:\Devices\P16` |
| **SSH** | Remote | `pi@raspi5-nvme:/media/pi/Media/Backup/` |
| **Tests** | Local | `c:\Temp\Tests` |

---

## 🔧 Main Parameters

| Parameter | Values | Default | Description |
|-----------|--------|---------|-------------|
| `-BackupType` | Full, Games, Dev, Scripts, WinSettings-* | *Required* | Type of backup |
| `-Destination` | Local, HomeNet, SSH, USB, Gdrive | *Required* | Where to store backup |
| `-LogLevel` | INFO, DEBUG, WARNING, ERROR | WARNING | Logging verbosity |
| `-CompressionLevel` | 0-9 | 5 | 0=None, 5=Normal, 9=Ultra |
| `-DryRun` | Switch | Off | Preview without backing up |
| `-Help` | Switch | Off | Show help message |

---

## 🚀 Performance Features (Always Enabled)

✅ Multi-threaded 7-Zip compression (1.5-3x faster)
✅ Optimized file operations with path validation
✅ Enhanced registry exports with timeout handling
✅ Performance metrics logging
✅ Smart file naming with auto-prefixes

---

## 📊 Scheduled Tasks

### Weekly Full Backup (HomeNet)
```powershell
-ExecutionPolicy Bypass -WindowStyle Hidden -NoProfile -NonInteractive -NoLogo -File "c:\Scripts\Backup\main.ps1" -BackupType FULL -Destination Homenet -LogLevel WARNING
```
**Trigger:** Sunday 2:00 AM

### Daily Full Backup (Gdrive)
```powershell
-ExecutionPolicy Bypass -WindowStyle Hidden -NoProfile -NonInteractive -NoLogo -File "c:\Scripts\Backup\main.ps1" -BackupType FULL -Destination Gdrive -LogLevel WARNING
```
**Trigger:** Daily 1:00 AM

### Monthly Cleanup
```powershell
-ExecutionPolicy Bypass -WindowStyle Hidden -File "c:\Scripts\Backup\cleanup_backups.ps1" -Force
```
**Trigger:** 1st of month, 3:00 AM

---

## 🗂️ File Locations

| Item | Path |
|------|------|
| **Main Script** | `C:\Scripts\Backup\main.ps1` |
| **GUI Launcher** | `C:\Scripts\Backup\backup_mgr.ps1` |
| **Configuration** | `C:\Scripts\Backup\config\bkp_cfg.json` |
| **Logs** | `C:\Scripts\Backup\log\backup.log` |
| **Database** | `C:\Scripts\Backup\db\backup_history.db` |
| **Cleanup Log** | `C:\Scripts\Backup\log\delete.log` |

---

## 🛠️ Troubleshooting

### Common Fixes

**7-Zip not found:**
```powershell
winget install 7zip.7zip
# Update config\bkp_cfg.json -> Tools.7Zip if installed elsewhere
```

**gum not found:**
```powershell
winget install charmbracelet.gum
```

**Insufficient disk space:**
```powershell
# Clean up old backups
.\cleanup_backups.ps1 -Force

# Use higher compression
.\main.ps1 -BackupType Full -Destination USB -CompressionLevel 9
```

**SSH transfer failed:**
```powershell
# Test SSH connection
ssh -i "C:\Users\R_sta\.ssh\keys\open_ssh.key" pi@raspi5-nvme
```

**View recent logs:**
```powershell
Get-Content .\log\backup.log -Tail 50
```

**Enable debug logging:**
```powershell
.\main.ps1 -BackupType Full -Destination Tests -LogLevel DEBUG
```

---

## 📖 Full Documentation

For complete documentation, see: `C:\Scripts\Backup\README.md` (1,253 lines)

---

## 🔄 Version 4.0 Changes

**What's New:**
- ✅ Performance mode now always enabled (no more dual-mode)
- ✅ Simplified main.ps1 (removed `-PerformanceMode` parameter)
- ✅ Consolidated BackupUtilities with performance enhancements
- ✅ Updated backup_mgr.ps1 to remove mode selection

**Migration:**
- Change `Main_Performance.ps1` → `main.ps1` in scripts/tasks
- Remove `-PerformanceMode` parameter from all commands
- Old files archived in `archive_old_versions/`

---

## 💡 Tips

**Fastest Backup:**
```powershell
.\main.ps1 -BackupType Scripts -Destination Tests -CompressionLevel 1
```

**Smallest Backup:**
```powershell
.\main.ps1 -BackupType Full -Destination USB -CompressionLevel 9
```

**Best Balance:**
```powershell
.\main.ps1 -BackupType Full -Destination HomeNet
# Uses default compression level 5
```

**Test Configuration:**
```powershell
.\main.ps1 -BackupType Games -Destination Tests -DryRun -LogLevel DEBUG
```

---

**For detailed help:**
```powershell
.\main.ps1 -Help
.\RestoreBackup.ps1 -Help
.\cleanup_backups.ps1 -Help
```
