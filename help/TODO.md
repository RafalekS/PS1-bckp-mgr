# Backup System TODO

**Last Updated:** 04/12/2025
**Status:** Active Development - Phases 1-5 Complete, Phase 6 In Progress

---

## Recent Fixes Completed (02/11/2025)

1. **Fixed 'if' is not recognized syntax error** - Changed `return if ($directSize)` to `return (if ($directSize))` in Get-DirectorySizeOptimized:2294
2. **Fixed reserved device name handling** - Added Test-IsReservedDeviceName function to exclude Windows reserved names (NUL, CON, PRN, AUX, COM1-9, LPT1-9) from backups
3. **Fixed backup failures on directories with reserved filenames** - Integrated device name checks into path validation and file enumeration to prevent "Cannot find path" errors

## Previous Fixes (30/10/2025)

1. Fixed missing paths display - now shows ALL missing paths instead of just first 10
2. Fixed AI folder mapping - AI backup items now go to Files/AI/ instead of Files/Other/
3. Fixed duplicate logging - size estimates no longer logged twice
4. Fixed GlobalExclusions in size calculation - all 3 optimization paths now respect exclusions
5. Fixed critical PowerShell `-or` operator bug - size calculations were converting to boolean (always returning 0 or 1) instead of actual byte values

---

## Completed Phases (10 of 17 features)

### Phase 1: Logging & Monitoring Foundation (COMPLETE)
- JSON logging with configurable format
- Statistics tracking (success/failure rates, average size/duration)
- Audit trail for all backup operations
- Health check script with Gotify notifications

### Phase 2: Backup Loop Enhancements (COMPLETE)
- Real-time backup speed statistics (MB/s)
- Enhanced progress display with current file being processed
- Improved logging with better flushing

### Phase 3: Security Hardening (COMPLETE)
- Pre-flight permission validation
- DPAPI encryption for secrets (Gotify tokens)
- Input sanitization to prevent injection attacks

### Phase 4: Advanced Backup Features (PARTIAL - NEEDS REWORK)
- Differential backups implemented but FLAWED (category-level instead of file-level)
- Current implementation backs up entire directories when one file changes
- NOT RECOMMENDED FOR USE - needs complete rework to file-level differential

### Phase 5: Performance & Code Quality (COMPLETE)
- Function refactoring for better maintainability
- 78-88% token reduction for AI-assisted debugging
- Major functions broken down from 295→115 lines

---

## Pending Features (Phase 6 - User Experience)

### #40 - Backup Analysis & Statistics Tool (COMPLETE ✓)
Analyze existing backups from database and display comprehensive statistics:
- ✅ Largest files across all backups
- ✅ Largest folders/directories
- ✅ Folders with most file count
- ✅ Backup size trends over time
- ✅ Storage usage breakdown by category
- ✅ File type distribution analysis
- ✅ Comprehensive analysis reports
- ✅ Individual backup analysis with actual file counts
- ✅ Integrated into backup_mgr.ps1 main menu

**Implementation Notes:**
- Created BackupAnalyzer.ps1 module with 9 analysis functions
- Reads actual ZIP contents using .NET ZipArchive (not just manifest)
- Shows real file counts (60k+ files) instead of broken manifest data (25 files)
- Fixed manifest population to track all files recursively (Add-FolderFilesToManifest)
- See help/BACKUP_ANALYZER.md for complete documentation

### #41 - Interactive Restore Preview
Show preview with file count, total size, largest files before restoration

### #42 - Backup Comparison Tool
Compare two backups and show differences (added/removed/modified files)

### #44 - Backup Schedule Suggestions
Analyze backup patterns and suggest optimal schedule based on history

---

## Future Work (Deferred)

### File-Level Differential Backups
Rework Phase 4 differential backups to work at file-level instead of category-level
- Only backup specific changed files, not entire directories
- Similar to rsync/duplicati behavior
- More complex restore logic required

### Backup Deduplication
Hash-based duplicate detection across backups to save space

---

For detailed implementation plans, see: help\TODO_FUTURE_IMPROVEMENTS.md
