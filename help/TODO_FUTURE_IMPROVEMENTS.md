# Future Backup System Improvements

**Date Created:** 2025-10-21
**Last Updated:** 2025-10-22
**Status:** Phase 1 Complete - Ready for Phase 2
**Implementation Strategy:** Phased approach to minimize conflicts and maximize code reuse

---

## Implementation Order - 6 Phases

This document organizes improvements by implementation phases. Items in each phase share code/modules and should be implemented together to avoid conflicts and maximize efficiency.

---

# PHASE 1: Logging & Monitoring Foundation

**Rationale:** Just standardized error handling. Now enhance entire logging infrastructure while fresh. All future features benefit from better logging/metrics.

**Shared Code:** `Write-Log()`, database schema, logging system

---

## #37 - Structured JSON Logging

**Problem:** Current logs are pipe-delimited text, hard to parse/analyze.

**Solution:** Output logs in JSON format for easier parsing and integration with log analysis tools.

**Implementation:**
```powershell
function Write-Log-Structured {
    param($Level, $Message, $Context = @{})

    $logEntry = @{
        timestamp = (Get-Date).ToString("o")
        level = $Level
        message = $Message
        context = $Context
        process_id = $PID
        user = $env:USERNAME
    } | ConvertTo-Json -Compress

    Add-Content -Path $LogFilePath -Value $logEntry
}

# Query logs with PowerShell
Get-Content log\backup.log | ForEach-Object { ConvertFrom-Json $_ } | Where-Object { $_.level -eq "ERROR" }
```

**Alternative: Hybrid Approach** (Keep text for human readability, add JSON option)
```powershell
function Write-Log {
    param($Message, $Level = "INFO", [switch]$AsJson)

    if ($AsJson -or $script:LogFormat -eq "JSON") {
        # JSON format
    } else {
        # Existing pipe-delimited format
    }
}
```

**Config Addition:**
```json
"Logging": {
    "LogFilePath": "log\\backup.log",
    "Format": "JSON",  // "Text" or "JSON"
    "IncludeContext": true
}
```

**Files to Modify:**
- `BackupUtilities.ps1` - Update Write-Log() function
- `config\bkp_cfg.json` - Add Format option

**Benefit:** Easy parsing, integration with log analysis tools, better debugging

---

## #35 - Success/Failure Metrics

**Problem:** No statistics tracked over time.

**Solution:** Track backup statistics in database and config.

**Config Addition:**
```json
"Statistics": {
    "TotalBackups": 0,
    "SuccessfulBackups": 0,
    "FailedBackups": 0,
    "AverageSize_MB": 0,
    "AverageDuration_Seconds": 0,
    "LastBackupDate": null,
    "LastFullBackupDate": null
}
```

**Implementation:**
```powershell
function Update-BackupStatistics {
    param($Success, $SizeMB, $DurationSeconds)

    $stats = Get-ConfigSection "Statistics"
    $stats.TotalBackups++

    if ($Success) {
        $stats.SuccessfulBackups++
    } else {
        $stats.FailedBackups++
    }

    # Update running averages
    $stats.AverageSize_MB = (($stats.AverageSize_MB * ($stats.TotalBackups - 1)) + $SizeMB) / $stats.TotalBackups
    $stats.AverageDuration_Seconds = (($stats.AverageDuration_Seconds * ($stats.TotalBackups - 1)) + $DurationSeconds) / $stats.TotalBackups

    Save-ConfigSection "Statistics" $stats
}
```

**Database Enhancement:**
```sql
-- Add to existing backups table
ALTER TABLE backups ADD COLUMN duration_seconds INTEGER;
ALTER TABLE backups ADD COLUMN size_mb REAL;
ALTER TABLE backups ADD COLUMN file_count INTEGER;
```

**Files to Modify:**
- `config\bkp_cfg.json` - Add Statistics section
- `BackupUtilities.ps1` - Add Update-BackupStatistics(), modify Update-BackupDatabase()
- `main.ps1` - Call statistics tracking after backup completes

**Display:**
```powershell
Write-Log "Total Backups: $($stats.TotalBackups) (Success: $($stats.SuccessfulBackups), Failed: $($stats.FailedBackups))" -Level "INFO"
Write-Log "Average: $($stats.AverageSize_MB) MB in $($stats.AverageDuration_Seconds)s" -Level "INFO"
```

---

## #39 - Audit Trail

**Problem:** No audit log of backup operations.

**Solution:** Separate audit log tracking all backup operations with user, action, result.

**Implementation:**
```powershell
function Write-AuditLog {
    param($Action, $User, $Target, $Result)

    $auditEntry = "{0}|{1}|{2}|{3}|{4}" -f (Get-Date), $Action, $User, $Target, $Result
    Add-Content -Path "log\audit.log" -Value $auditEntry
}

# Usage
Write-AuditLog -Action "BACKUP_START" -User $env:USERNAME -Target "Full-HomeNet" -Result "STARTED"
Write-AuditLog -Action "BACKUP_COMPLETE" -User $env:USERNAME -Target "Full-HomeNet" -Result "SUCCESS"
Write-AuditLog -Action "RESTORE_START" -User $env:USERNAME -Target "Full_20251022-123456" -Result "STARTED"
```

**Audit Events to Track:**
- BACKUP_START
- BACKUP_COMPLETE (SUCCESS/FAILED)
- RESTORE_START
- RESTORE_COMPLETE
- CONFIG_CHANGE
- CREDENTIAL_ACCESS
- COMPRESSION_START
- TRANSFER_START (SSH/Network)

**Files to Modify:**
- `BackupUtilities.ps1` - Add Write-AuditLog()
- `main.ps1` - Add audit logging at key points
- `RestoreBackup.ps1` - Add audit logging
- `config_manager.ps1` - Log config changes

**Retention:** Keep audit logs separate from regular logs, longer retention (90+ days)

---

## #36 - Health Check Script

**Problem:** No way to monitor backup system health.

**Solution:** Create standalone health check script that queries database and config.

**NEW File:** `health-check.ps1`
```powershell
# health-check.ps1
function Test-BackupHealth {
    $lastBackup = Get-LastBackupFromDatabase

    if (-not $lastBackup) {
        return @{ Status = "ERROR"; Message = "No backups found in database" }
    }

    $hoursSinceBackup = ((Get-Date) - $lastBackup.Timestamp).TotalHours

    if ($hoursSinceBackup -gt 48) {
        return @{ Status = "WARNING"; Message = "No backup in 48 hours (last: $($lastBackup.Timestamp))" }
    }

    if ($lastBackup.Success -eq $false) {
        return @{ Status = "WARNING"; Message = "Last backup failed" }
    }

    # Check disk space
    $config = Get-Content "config\bkp_cfg.json" | ConvertFrom-Json
    $tempDrive = (Get-Item $config.TempPath).PSDrive.Name
    $freeSpaceGB = (Get-PSDrive $tempDrive).Free / 1GB

    if ($freeSpaceGB -lt 10) {
        return @{ Status = "WARNING"; Message = "Low disk space: $([math]::Round($freeSpaceGB, 2)) GB remaining" }
    }

    return @{ Status = "OK"; Message = "System healthy. Last backup: $($lastBackup.Timestamp)" }
}

# Run and send to monitoring
$health = Test-BackupHealth
Write-Host "[$($health.Status)] $($health.Message)"

if ($health.Status -ne "OK") {
    # Optional: Send notification
    if ($config.Notifications.Gotify.Enabled) {
        Send-GotifyNotification -Title "Backup Health Alert" -Message $health.Message -Priority 8 -Config $config
    }
}

# Exit code for monitoring systems
exit $(if ($health.Status -eq "OK") { 0 } elseif ($health.Status -eq "WARNING") { 1 } else { 2 })
```

**Usage:**
```powershell
# Manual check
.\health-check.ps1

# Scheduled task (daily)
schtasks /create /tn "Backup Health Check" /tr "pwsh -File C:\Scripts\Backup\health-check.ps1" /sc daily /st 09:00
```

**Files to Create:**
- `health-check.ps1` - NEW standalone script

**Dependencies:**
- Requires #35 (Statistics) for meaningful health data

---

# PHASE 2: Backup Loop Enhancements

**Rationale:** All modify the same backup loop code. Do together to avoid merge conflicts. Enhances core backup functionality.

**Shared Code:** `Backup-Files-Sequential-Optimized()`, `Copy-ItemWithExclusions()`, `Show-Progress()`, backup loop in main.ps1

---

## #15 - Smart Retry Logic for Failed Items

**Problem:** If one file fails to backup (e.g., locked by another process like Snipping Tool settings), the entire backup fails.

**Solution:** Implement retry mechanism with configurable attempts and delays.

**Implementation:**
```powershell
function Backup-ItemWithRetry {
    param($Item, $MaxRetries = 3, $RetryDelay = 5, $Config = $null)

    for ($i = 1; $i -le $MaxRetries; $i++) {
        try {
            # Use existing copy function
            Copy-ItemWithExclusions -Source $Item.Source -Destination $Item.Destination -Config $Config
            Write-Log "Successfully backed up: $($Item.Source)" -Level "INFO"
            return $true
        }
        catch {
            if ($i -lt $MaxRetries) {
                Write-Log "Retry $i/$MaxRetries for $($Item.Source) after $RetryDelay seconds (Error: $_)" -Level "WARNING"
                Start-Sleep -Seconds $RetryDelay
            } else {
                Write-Log "Failed after $MaxRetries attempts: $($Item.Source) - $_" -Level "ERROR"

                if ($Config.RetryPolicy.ContinueOnFailure) {
                    Write-Log "Continuing backup despite failure (ContinueOnFailure=true)" -Level "WARNING"
                    return $false
                } else {
                    throw $_
                }
            }
        }
    }
}
```

**Config Addition:**
```json
"RetryPolicy": {
    "Enabled": true,
    "MaxAttempts": 3,
    "DelaySeconds": 5,
    "ContinueOnFailure": true
}
```

**Files to Modify:**
- `BackupUtilities.ps1` - Add Backup-ItemWithRetry function
- `Backup-Files-Sequential-Optimized()` - Wrap copy operations in retry logic
- `config\bkp_cfg.json` - Add RetryPolicy section

**Expected Behavior:**
- Locked files (Snipping Tool settings) → retry 3x → if still fails, log error and continue
- No more full backup failures due to single locked file
- Log shows: `[WARNING] Retry 1/3 for SnippingTool settings.dat after 5 seconds (Error: Access denied)`

---

## #17 - Backup Speed Statistics

**Problem:** No visibility into actual transfer speed during backup.

**Solution:** Track bytes processed over time, display speed in MB/s.

**Implementation:**
```powershell
# Add to script-level variables in BackupUtilities.ps1
$script:BackupSpeedStats = @{
    StartTime = $null
    BytesProcessed = 0
    FileCount = 0
}

function Measure-BackupSpeed {
    param($StartTime, $BytesProcessed)

    $elapsed = (Get-Date) - $StartTime
    $mbProcessed = [math]::Round($BytesProcessed / 1MB, 2)
    $speed = [math]::Round($mbProcessed / $elapsed.TotalSeconds, 2)

    Write-Log "Backup speed: $speed MB/s ($mbProcessed MB in $([math]::Round($elapsed.TotalSeconds, 1))s)" -Level "INFO"

    return @{
        Speed_MBps = $speed
        TotalMB = $mbProcessed
        Duration = $elapsed
    }
}

# Integration in backup loop (Backup-Files-Sequential-Optimized)
function Backup-Files-Sequential-Optimized {
    param($ValidatedPaths, $DestinationPath, $Config = $null)

    $script:BackupSpeedStats.StartTime = Get-Date
    $script:BackupSpeedStats.BytesProcessed = 0
    $script:BackupSpeedStats.FileCount = 0

    foreach ($pathInfo in $ValidatedPaths) {
        try {
            # Existing copy logic...
            Copy-ItemWithExclusions -Source $pathInfo.ExpandedPath -Destination $destPath -Config $Config

            # Track bytes
            if (Test-Path $pathInfo.ExpandedPath -PathType Leaf) {
                $script:BackupSpeedStats.BytesProcessed += (Get-Item $pathInfo.ExpandedPath).Length
            } else {
                $folderSize = (Get-ChildItem $pathInfo.ExpandedPath -Recurse -File | Measure-Object -Property Length -Sum).Sum
                $script:BackupSpeedStats.BytesProcessed += $folderSize
            }
            $script:BackupSpeedStats.FileCount++

            # Update speed every 10 files
            if ($script:BackupSpeedStats.FileCount % 10 -eq 0) {
                $stats = Measure-BackupSpeed -StartTime $script:BackupSpeedStats.StartTime -BytesProcessed $script:BackupSpeedStats.BytesProcessed
                Show-Progress -PercentComplete $percentComplete -Status "Processing $item ($($stats.Speed_MBps) MB/s)"
            }

        } catch {
            Write-Log "Failed to backup: $_" -Level "ERROR"
        }
    }

    # Final speed report
    $finalStats = Measure-BackupSpeed -StartTime $script:BackupSpeedStats.StartTime -BytesProcessed $script:BackupSpeedStats.BytesProcessed
    Write-Log "Backup completed: $($script:BackupSpeedStats.FileCount) files, $($finalStats.TotalMB) MB, $($finalStats.Speed_MBps) MB/s" -Level "INFO"
}
```

**Enhanced Progress Display:**
```
[INFO] Backup speed: 45.2 MB/s (1234.5 MB in 27.3s)
Progress: [===============>    ] 75% Processing UserConfigs (45.2 MB/s, ETA: 2m 15s)
```

**Files to Modify:**
- `BackupUtilities.ps1` - Add Measure-BackupSpeed(), update Backup-Files-Sequential-Optimized()
- `Show-Progress()` - Display speed alongside ETA

**Benefits:**
- Identify slow backups (network vs disk bottleneck)
- Performance monitoring over time
- User feedback during long operations

---

## #43 - Enhanced Progress Display (Show Current File)

**Problem:** Progress shows percentage and ETA, but not current file being processed.

**Solution:** Add current file name to progress display.

**Implementation:**
```powershell
function Show-Progress {
    param (
        [int]$PercentComplete,
        [string]$Status,
        [string]$CurrentFile = ""  # NEW parameter
    )

    # Existing progress bar logic...
    $progressBar = "[$('#' * $filledLength)$(' ' * $emptyLength)]"

    # Calculate ETA (existing code)
    $etaString = ""
    if ($PercentComplete -gt 5 -and $PercentComplete -lt 100) {
        # ETA calculation...
    }

    # Display progress
    Write-Host "`e[2A`e[2K`e[B`e[2K`e[A" -NoNewline
    Write-Host "`r$progressBar" -ForegroundColor Cyan -NoNewline
    Write-Host ""

    # Show current file being processed (NEW)
    if ($CurrentFile) {
        $truncated = if ($CurrentFile.Length -gt 60) {
            "..." + $CurrentFile.Substring($CurrentFile.Length - 57)
        } else {
            $CurrentFile.PadRight(60)
        }
        Write-Host "`r$PercentComplete% $Status$etaString"
        Write-Host "  File: $truncated" -ForegroundColor DarkGray
    } else {
        Write-Host "`r$PercentComplete% $Status$etaString"
    }
}

# Usage in backup loop
foreach ($pathInfo in $ValidatedPaths) {
    Show-Progress -PercentComplete $percent -Status "Processing $item" -CurrentFile $pathInfo.OriginalPath
    # ... copy file ...
}
```

**Files to Modify:**
- `BackupUtilities.ps1` - Update Show-Progress() function
- `Backup-Files-Sequential-Optimized()` - Pass CurrentFile parameter

**Display Example:**
```
[===================>     ] 78% Processing UserConfigs (ETA: 1m 23s)
  File: C:\Users\r_sta\.gitconfig
```

**Benefit:** Know exactly what file is being processed (useful when retry logic kicks in from #15)

---

# PHASE 3: Security Hardening

**Rationale:** With audit trail in place (from Phase 1), now harden security. All validation/security logic done together.

**Shared Code:** Configuration loading, validation functions, security checks

---

## #40 - Backup Permissions Validation

**Problem:** Backup starts, then fails midway due to permissions.

**Solution:** Test write permissions before backup starts.

**Implementation:**
```powershell
function Test-DestinationWritable {
    param($DestinationPath)

    $testFile = Join-Path $DestinationPath ".writetest_$(Get-Random)"
    try {
        "test" | Out-File $testFile -ErrorAction Stop
        Remove-Item $testFile -ErrorAction SilentlyContinue
        Write-Log "Destination is writable: $DestinationPath" -Level "DEBUG"
        return $true
    }
    catch {
        Write-Log "No write permission to $DestinationPath : $_" -Level "ERROR"
        return $false
    }
}

# Call before backup starts (in main.ps1)
function Perform-Backup {
    # ... existing code ...

    # Pre-flight checks
    if (-not (Test-DestinationWritable $destinationBasePath)) {
        throw "Cannot write to destination: $destinationBasePath"
    }

    # Continue with backup...
}
```

**Files to Modify:**
- `BackupUtilities.ps1` - Add Test-DestinationWritable()
- `main.ps1` - Call validation before starting backup

**Benefit:** Fail fast with clear error instead of failing midway through backup

---

## #38 - DPAPI Secrets Management

**Problem:** Environment variables can leak in process lists.

**Solution:** Use Windows DPAPI to encrypt secrets in config file.

**Implementation:**
```powershell
function Protect-BackupSecret {
    param([string]$Secret)

    $secureString = ConvertTo-SecureString $Secret -AsPlainText -Force
    $encrypted = ConvertFrom-SecureString $secureString
    return $encrypted
}

function Unprotect-BackupSecret {
    param([string]$EncryptedSecret)

    $secureString = ConvertTo-SecureString $EncryptedSecret
    $bstr = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($secureString)
    $plaintext = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto($bstr)
    [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
    return $plaintext
}

# Encrypt current token (one-time setup)
$token = $env:GOTIFY_TOKEN
$encrypted = Protect-BackupSecret -Secret $token
# Store in config: "01000000d08c9ddf0115d1118c7a00c04fc297eb..."
```

**Config Update:**
```json
"Gotify": {
    "Enabled": true,
    "Url": "http://192.168.0.166:12680/message",
    "TokenEncrypted": "01000000d08c9ddf0115d1118c7a00c04fc297eb..."  // Instead of $env:GOTIFY_TOKEN
}
```

**Files to Modify:**
- `BackupUtilities.ps1` - Add Protect/Unprotect functions, update Send-GotifyNotification()
- `config\bkp_cfg.json` - Change to TokenEncrypted
- `Setup-BackupCredentials.ps1` - Update to encrypt token

**Note:** DPAPI encryption is user-specific. Token can only be decrypted by same Windows user account.

**Benefit:** Secrets encrypted at rest, not visible in process lists or config file

---

## #28 - Input Sanitization

**Problem:** User input passed directly to commands without validation.

**Solution:** Sanitize all user inputs before use.

**Implementation:**
```powershell
function ConvertTo-SafePath {
    param([string]$Path)

    # Remove dangerous characters
    $Path = $Path -replace '[<>:"|?*]', ''
    # Prevent path traversal
    $Path = $Path -replace '\.\.[\\/]', ''
    # Remove leading/trailing whitespace
    $Path = $Path.Trim()

    return $Path
}

function ConvertTo-SafeString {
    param([string]$Input, [int]$MaxLength = 255)

    # Trim to max length
    if ($Input.Length -gt $MaxLength) {
        $Input = $Input.Substring(0, $MaxLength)
    }

    # Remove control characters
    $Input = $Input -replace '[\x00-\x1F\x7F]', ''

    return $Input
}

# Apply to user inputs
function Validate-BackupParameters {
    param($Config, $BackupType, $Destination)

    # Sanitize backup type
    $BackupType = ConvertTo-SafeString -Input $BackupType -MaxLength 50

    # Sanitize destination
    $Destination = ConvertTo-SafeString -Input $Destination -MaxLength 50

    # Existing validation...
}
```

**Files to Modify:**
- `BackupUtilities.ps1` - Add sanitization functions
- `main.ps1` - Sanitize all parameters
- `backup_mgr.ps1` - Sanitize GUI inputs

**Inputs to Sanitize:**
- Backup type name
- Destination name
- Log level
- Compression level
- File paths from config
- Custom backup names

**Benefit:** Prevent injection attacks, path traversal, invalid characters

---

# PHASE 4: Advanced Backup Features

**Rationale:** Both require database schema changes. Complex features that modify core backup logic. Test together to ensure differential + dedup work together.

**Shared Code:** Database schema, backup file selection, core backup loop

---

## #20 - Differential Backups

**Problem:** Only have Full backups. Need middle ground between Full and Incremental.

**Solution:** Differential backup = all changes since LAST FULL backup.

**Comparison:**
- **Full Backup:** Everything (1000 files)
- **Incremental Backup:** Changes since last backup (10 files since yesterday)
- **Differential Backup:** Changes since last FULL backup (50 files since last week)

**Implementation:**
```powershell
function Get-ModifiedFilesSinceLastFull {
    param($SourcePaths, $LastFullBackupDate)

    $modifiedFiles = @()

    foreach ($path in $SourcePaths) {
        Get-ChildItem $path -Recurse -File -ErrorAction SilentlyContinue |
            Where-Object { $_.LastWriteTime -gt $LastFullBackupDate } |
            ForEach-Object { $modifiedFiles += $_ }
    }

    Write-Log "Found $($modifiedFiles.Count) files modified since last full backup ($LastFullBackupDate)" -Level "INFO"
    return $modifiedFiles
}

function Get-LastFullBackupDate {
    param($BackupType)

    $query = "SELECT timestamp FROM backups WHERE backup_type = '$BackupType' AND backup_strategy = 'Full' ORDER BY timestamp DESC LIMIT 1"
    $result = Invoke-SqliteQuery -Query $query -DataSource $script:DbPath

    if ($result) {
        return [DateTime]::Parse($result.timestamp)
    }
    return $null
}
```

**Backup Strategy:**
```
Sunday:     Full Backup (1000 files)
Monday:     Differential (10 files changed since Sunday)
Tuesday:    Differential (25 files changed since Sunday)
Wednesday:  Differential (40 files changed since Sunday)
Thursday:   Differential (60 files changed since Sunday)
Friday:     Differential (80 files changed since Sunday)
Saturday:   Differential (100 files changed since Sunday)
Sunday:     Full Backup (start over)
```

**Config Addition:**
```json
"BackupTypes": {
    "Full": [...],
    "Differential": {
        "BasedOn": "LastFull",
        "OnlyModifiedSince": "LastFullBackup",
        "Items": ["PowerShell", "Scripts", "UserConfigs", "Games"]
    }
}
```

**Database Schema Update:**
```sql
ALTER TABLE backups ADD COLUMN backup_strategy TEXT;  -- "Full", "Differential", "Incremental"
ALTER TABLE backups ADD COLUMN parent_backup_id INTEGER;  -- References full backup
```

**Files to Modify:**
- `BackupUtilities.ps1` - Add Get-ModifiedFilesSinceLastFull(), Get-LastFullBackupDate()
- `main.ps1` - Add Differential backup type handling, filter files by date
- `config\bkp_cfg.json` - Add Differential to BackupTypes
- `db\schema.sql` - Update database schema
- `RestoreBackup.ps1` - Handle differential restore (must restore full + differential)

**Restoration Process:**
1. Find last full backup
2. Restore full backup
3. Find all differential backups since that full
4. Restore differential backups in order (overwrites changed files)

**Benefit:** Faster than full backup, easier to restore than incremental (only need full + latest differential)

---

## #16 - Backup Deduplication

**Problem:** Same files backed up multiple times across different backup sets, wasting space.

**Solution:** Build file hash cache, detect duplicates, skip or hard-link them.

**Implementation Approaches:**

**Approach A: Hash-Based Skip (Simpler)**
```powershell
# Build cache of hashes from previous backups
$script:HashCache = @{}

function Get-FileHash-Cached {
    param($FilePath)

    $hash = (Get-FileHash $FilePath -Algorithm SHA256).Hash

    if ($script:HashCache.ContainsKey($hash)) {
        Write-Log "Duplicate file detected (skipping): $FilePath (matches: $($script:HashCache[$hash]))" -Level "INFO"
        return $null  # Skip this file
    }

    $script:HashCache[$hash] = $FilePath
    return $hash
}

# Load cache from previous backup manifests
function Load-HashCacheFromPreviousBackups {
    param($BackupType)

    $script:HashCache = @{}

    # Find recent backups of same type
    $query = "SELECT backup_path FROM backups WHERE backup_type = '$BackupType' ORDER BY timestamp DESC LIMIT 5"
    $recentBackups = Invoke-SqliteQuery -Query $query -DataSource $script:DbPath

    foreach ($backup in $recentBackups) {
        $manifestPath = Join-Path $backup.backup_path "manifest.json"
        if (Test-Path $manifestPath) {
            $manifest = Get-Content $manifestPath | ConvertFrom-Json
            foreach ($file in $manifest.backup_manifest.PSObject.Properties) {
                if ($file.Value.sha256_hash) {
                    $script:HashCache[$file.Value.sha256_hash] = $file.Value.original_path
                }
            }
        }
    }

    Write-Log "Loaded $($script:HashCache.Count) file hashes from previous backups" -Level "INFO"
}
```

**Approach B: Hard Links (More Complex)**
```powershell
# Create hard link to existing file instead of copying
function New-HardLinkIfDuplicate {
    param($SourceFile, $DestinationFile, $HashCache)

    $hash = (Get-FileHash $SourceFile -Algorithm SHA256).Hash

    if ($HashCache.ContainsKey($hash)) {
        $existingFile = $HashCache[$hash]

        # Verify existing file still exists
        if (Test-Path $existingFile) {
            cmd /c mklink /H "$DestinationFile" "$existingFile"
            Write-Log "Created hard link: $DestinationFile -> $existingFile" -Level "INFO"
            return $true
        }
    }

    # No duplicate, copy normally
    Copy-Item $SourceFile $DestinationFile
    $HashCache[$hash] = $DestinationFile
    return $false
}
```

**Config Addition:**
```json
"Deduplication": {
    "Enabled": false,
    "Method": "Skip",  // "Skip" or "HardLink"
    "CachePath": "C:\\Temp\\Backup\\hash_cache.json",
    "LookbackBackups": 5  // Check last 5 backups for duplicates
}
```

**Pros:**
- Saves significant space for incremental/differential backups
- Faster backups (skip duplicate files)
- Space savings: 30-60% for similar backup sets

**Cons:**
- Adds CPU overhead (hashing every file)
- Hard links can be confusing for users
- Cache management complexity
- Hash cache can grow large

**Files to Modify:**
- `BackupUtilities.ps1` - Add deduplication functions, update Copy-ItemWithExclusions()
- `main.ps1` - Load hash cache before backup, check duplicates during copy
- `config\bkp_cfg.json` - Add Deduplication section
- `ManifestUtilities.ps1` - Store file hashes in manifest (already has sha256_hash field)

**Integration with #20 (Differential):**
- Differential backups work great with dedup
- Only copy changed files (differential) + skip duplicates (dedup) = maximum space savings

**Benefit:** Major space savings, especially for differential backups with many unchanged files

---

# PHASE 5: Performance & Code Quality

**Rationale:** Optimize and refactor after features are stable. Easier to refactor working code. Performance improvements don't break functionality.

**Shared Code:** Configuration loading, code structure

---

## #31 - Lazy Config Loading

**Problem:** Full config loaded even if only need one section.

**Solution:** Load config sections on demand with caching.

**Implementation:**
```powershell
$script:ConfigCache = @{}

function Get-ConfigSection {
    param([string]$Section)

    # Return from cache if already loaded
    if ($script:ConfigCache.ContainsKey($Section)) {
        return $script:ConfigCache[$Section]
    }

    # Load full config (only once)
    if (-not $script:ConfigCache.ContainsKey('_full')) {
        $config = Get-Content "config\bkp_cfg.json" | ConvertFrom-Json
        $script:ConfigCache['_full'] = $config
    }

    # Extract requested section
    $fullConfig = $script:ConfigCache['_full']
    $script:ConfigCache[$Section] = $fullConfig.$Section

    Write-Log "Loaded config section: $Section" -Level "DEBUG"
    return $script:ConfigCache[$Section]
}

# Clear cache (for config reload)
function Clear-ConfigCache {
    $script:ConfigCache = @{}
}

# Usage
$notifications = Get-ConfigSection "Notifications"
$backupItems = Get-ConfigSection "BackupItems"
```

**Files to Modify:**
- `BackupUtilities.ps1` - Add Get-ConfigSection(), Clear-ConfigCache()
- Update functions to use Get-ConfigSection instead of accessing full config

**Benefit:**
- Faster startup for simple operations
- Reduced memory usage
- Config changes can invalidate cache

---

## #25 - Break Down Long Functions

**Problem:** Some functions are too long (Process-BackupItems in main.ps1 is 170+ lines).

**Solution:** Break into smaller, focused functions with single responsibility.

**Example Refactoring:**

**Before:** (main.ps1, lines ~330-500)
```powershell
function Process-BackupItems {
    # 170+ lines of mixed logic
    # - Windows settings processing
    # - File backup processing
    # - Registry exports
    # - Certificate handling
    # - Doskey macros
    # - Manifest updates
}
```

**After:**
```powershell
function Process-BackupItems {
    foreach ($item in $BackupItems) {
        Process-BackupItem -Item $item -Config $Config -DestinationPath $tempBackupFolder
    }
}

function Process-BackupItem {
    param($Item, $Config, $DestinationPath)

    switch ($item) {
        "Certificates" { Process-Certificates -DestinationPath $DestinationPath }
        "DoskeyMacros" { Process-DoskeyMacros -DestinationPath $DestinationPath }
        "RegistrySettings" { Process-RegistrySettings -DestinationPath $DestinationPath -Config $Config }
        default { Process-FileBackupItem -Item $item -Config $Config -DestinationPath $DestinationPath }
    }
}

function Process-Certificates {
    param($DestinationPath)

    $certPath = Join-Path $DestinationPath "Certificates.csv"
    $certs = Get-ChildItem Cert:\CurrentUser\My
    $certs | Export-Csv $certPath -NoTypeInformation
    Add-FileToManifest -OriginalPath "Cert:\CurrentUser\My" -ArchivePath "Certificates.csv"
}

function Process-DoskeyMacros {
    param($DestinationPath)

    $macroFile = Join-Path $DestinationPath "DoskeyMacros.txt"
    doskey /macros | Out-File $macroFile
    Add-FileToManifest -OriginalPath "DOSKEY" -ArchivePath "DoskeyMacros.txt"
}

function Process-FileBackupItem {
    param($Item, $Config, $DestinationPath)

    $paths = $Config.BackupItems.$Item
    $validatedPaths = Get-ValidatedPaths -Paths $paths -Config $Config

    if ($validatedPaths.Count -gt 0) {
        Backup-Files-Optimized -SourcePaths $validatedPaths -DestinationPath $DestinationPath -Config $Config
    }
}
```

**Target:** No function >100 lines

**Functions to Refactor:**
- `Process-BackupItems` in main.ps1 (~170 lines) → Break into 8-10 smaller functions
- `Perform-Backup` in main.ps1 (~250 lines) → Extract manifest creation, compression, transfer
- `Compress-Backup-Optimized` in BackupUtilities.ps1 (~100 lines) → Extract progress monitoring

**Files to Modify:**
- `main.ps1` - Major refactoring of Process-BackupItems, Perform-Backup
- `BackupUtilities.ps1` - Minor refactoring of long functions

**Benefits:**
- Easier to test individual functions
- Better code reusability
- Easier to understand and maintain
- Easier to add new backup item types

**Note:** Do LAST in this phase after all features working (don't refactor moving targets)

---

# PHASE 6: User Experience Enhancements

**Rationale:** New utilities and tools. Not critical to core functionality. Can be added incrementally without affecting existing backups.

**Shared Code:** Manifest reading, database queries, backup comparison logic

---

## #41 - Interactive Restore Preview

**Problem:** Don't know what will be restored before executing.

**Solution:** Show preview with file count, total size, largest files before restoration.

**Implementation:**
```powershell
function Show-RestorePreview {
    param($Manifest)

    $totalSize = 0
    $fileCount = 0
    $largestFiles = @()

    Write-Host "`nRestore Preview:" -ForegroundColor Cyan
    Write-Host "================" -ForegroundColor Cyan

    foreach ($file in $Manifest.backup_manifest.PSObject.Properties) {
        $totalSize += $file.Value.size_bytes
        $fileCount++
        $largestFiles += [PSCustomObject]@{
            Path = $file.Value.original_path
            Size = $file.Value.size_bytes
        }
    }

    $largestFiles = $largestFiles | Sort-Object Size -Descending | Select-Object -First 10

    Write-Host "`nTotal Files: $fileCount" -ForegroundColor White
    Write-Host "Total Size: $([math]::Round($totalSize / 1GB, 2)) GB" -ForegroundColor White
    Write-Host "`nTop 10 Largest Files:" -ForegroundColor Yellow

    foreach ($file in $largestFiles) {
        $sizeMB = [math]::Round($file.Size / 1MB, 2)
        Write-Host "  $sizeMB MB - $($file.Path)" -ForegroundColor Gray
    }

    Write-Host "`nBackup Date: $($Manifest.backup_date)" -ForegroundColor Cyan
    Write-Host "Backup Type: $($Manifest.backup_type)" -ForegroundColor Cyan

    $confirm = Read-Host "`nProceed with restoration? (Y/N)"
    return ($confirm -eq "Y" -or $confirm -eq "y")
}

# Integration in RestoreBackup.ps1
$manifest = Get-Content "$backupPath\manifest.json" | ConvertFrom-Json

if (-not (Show-RestorePreview -Manifest $manifest)) {
    Write-Host "Restoration cancelled by user" -ForegroundColor Yellow
    exit 0
}

# Proceed with restoration...
```

**Files to Modify:**
- `RestoreBackup.ps1` - Add Show-RestorePreview(), call before restoration

**Display Example:**
```
Restore Preview:
================

Total Files: 1,247
Total Size: 3.45 GB

Top 10 Largest Files:
  145.23 MB - C:\Users\r_sta\Documents\Project.zip
  89.12 MB - C:\Users\r_sta\Videos\Recording.mp4
  67.45 MB - C:\Users\r_sta\Downloads\Installer.exe
  ...

Backup Date: 2025-10-22 14:30:15
Backup Type: Full

Proceed with restoration? (Y/N):
```

**Benefit:** User knows exactly what will be restored before committing

---

## #42 - Backup Comparison Tool

**Problem:** Can't easily compare two backups.

**Solution:** Create tool to compare manifests and show differences.

**NEW File:** `Compare-Backups.ps1`
```powershell
# Compare-Backups.ps1
param(
    [Parameter(Mandatory=$true)]
    [string]$Backup1Path,

    [Parameter(Mandatory=$true)]
    [string]$Backup2Path
)

function Compare-Backups {
    param($Backup1Path, $Backup2Path)

    Write-Host "`nLoading backup manifests..." -ForegroundColor Cyan

    $manifest1 = Get-Content "$Backup1Path\manifest.json" | ConvertFrom-Json
    $manifest2 = Get-Content "$Backup2Path\manifest.json" | ConvertFrom-Json

    $files1 = $manifest1.backup_manifest.PSObject.Properties.Name
    $files2 = $manifest2.backup_manifest.PSObject.Properties.Name

    # Find differences
    $added = $files2 | Where-Object { $_ -notin $files1 }
    $removed = $files1 | Where-Object { $_ -notin $files2 }
    $common = $files1 | Where-Object { $_ -in $files2 }

    # Find modified files (same path, different size)
    $modified = @()
    foreach ($file in $common) {
        $size1 = $manifest1.backup_manifest.$file.size_bytes
        $size2 = $manifest2.backup_manifest.$file.size_bytes
        if ($size1 -ne $size2) {
            $modified += [PSCustomObject]@{
                Path = $file
                OldSize = $size1
                NewSize = $size2
                Diff = $size2 - $size1
            }
        }
    }

    # Display results
    Write-Host "`n========================================" -ForegroundColor Cyan
    Write-Host "Backup Comparison" -ForegroundColor Cyan
    Write-Host "========================================" -ForegroundColor Cyan

    Write-Host "`nBackup 1: $($manifest1.backup_date)" -ForegroundColor White
    Write-Host "Backup 2: $($manifest2.backup_date)" -ForegroundColor White

    Write-Host "`nAdded: $($added.Count) files" -ForegroundColor Green
    Write-Host "Removed: $($removed.Count) files" -ForegroundColor Red
    Write-Host "Modified: $($modified.Count) files" -ForegroundColor Yellow
    Write-Host "Unchanged: $($common.Count - $modified.Count) files" -ForegroundColor Gray

    # Show details if requested
    $showDetails = Read-Host "`nShow details? (Y/N)"
    if ($showDetails -eq "Y" -or $showDetails -eq "y") {

        if ($added.Count -gt 0) {
            Write-Host "`n--- Added Files ---" -ForegroundColor Green
            $added | Select-Object -First 20 | ForEach-Object {
                Write-Host "  + $_" -ForegroundColor Green
            }
            if ($added.Count -gt 20) {
                Write-Host "  ... and $($added.Count - 20) more" -ForegroundColor Gray
            }
        }

        if ($removed.Count -gt 0) {
            Write-Host "`n--- Removed Files ---" -ForegroundColor Red
            $removed | Select-Object -First 20 | ForEach-Object {
                Write-Host "  - $_" -ForegroundColor Red
            }
            if ($removed.Count -gt 20) {
                Write-Host "  ... and $($removed.Count - 20) more" -ForegroundColor Gray
            }
        }

        if ($modified.Count -gt 0) {
            Write-Host "`n--- Modified Files ---" -ForegroundColor Yellow
            $modified | Select-Object -First 20 | ForEach-Object {
                $diffMB = [math]::Round($_.Diff / 1MB, 2)
                Write-Host "  ~ $($_.Path) (${diffMB} MB)" -ForegroundColor Yellow
            }
            if ($modified.Count -gt 20) {
                Write-Host "  ... and $($modified.Count - 20) more" -ForegroundColor Gray
            }
        }
    }
}

# Run comparison
Compare-Backups -Backup1Path $Backup1Path -Backup2Path $Backup2Path
```

**Usage:**
```powershell
.\Compare-Backups.ps1 -Backup1Path "E:\Backup\Full_20251020-120000" -Backup2Path "E:\Backup\Full_20251022-120000"
```

**Files to Create:**
- `Compare-Backups.ps1` - NEW standalone script

**Benefit:**
- See what changed between backups
- Verify differential backups
- Track file changes over time

---

## #44 - Backup Schedule Suggestions

**Problem:** Don't know optimal backup schedule.

**Solution:** Analyze backup patterns and suggest optimal schedule.

**NEW File:** `Get-BackupScheduleSuggestion.ps1`
```powershell
# Get-BackupScheduleSuggestion.ps1
. "$PSScriptRoot\BackupUtilities.ps1"

function Get-BackupScheduleSuggestion {
    # Get last 30 backups from database
    $query = "SELECT * FROM backups ORDER BY timestamp DESC LIMIT 30"
    $backups = Invoke-SqliteQuery -Query $query -DataSource "$PSScriptRoot\db\backup_history.db"

    if ($backups.Count -eq 0) {
        Write-Host "No backup history found. Run a few backups first." -ForegroundColor Yellow
        return
    }

    # Analyze patterns
    $avgDuration = ($backups | Measure-Object -Property duration_seconds -Average).Average
    $avgSize = ($backups | Measure-Object -Property size_mb -Average).Average

    # Group by hour to find common backup times
    $hourlyFreq = $backups | Group-Object { ([DateTime]$_.timestamp).Hour } | Sort-Object Count -Descending

    # Calculate file change rate
    $fullBackups = $backups | Where-Object { $_.backup_type -eq "Full" } | Select-Object -First 2
    if ($fullBackups.Count -eq 2) {
        $changeRate = [math]::Abs($fullBackups[0].size_mb - $fullBackups[1].size_mb) / $fullBackups[1].size_mb * 100
    } else {
        $changeRate = 10  # Default 10%
    }

    # Generate suggestion
    $suggestion = @{
        RecommendedFrequency = if ($avgSize -lt 1000) { "Daily" } elseif ($changeRate -gt 20) { "Daily" } else { "Weekly" }
        RecommendedTime = "$($hourlyFreq[0].Name):00"
        EstimatedDuration = "$([math]::Round($avgDuration / 60)) minutes"
        Reasoning = "Based on $($backups.Count) recent backups"
        ChangeRate = "$([math]::Round($changeRate, 1))% change between backups"
        AverageSize = "$([math]::Round($avgSize / 1024, 2)) GB"
    }

    # Display
    Write-Host "`nBackup Schedule Suggestion" -ForegroundColor Cyan
    Write-Host "==========================`n" -ForegroundColor Cyan

    Write-Host "Recommended Frequency: " -NoNewline
    Write-Host $suggestion.RecommendedFrequency -ForegroundColor Green

    Write-Host "Recommended Time: " -NoNewline
    Write-Host $suggestion.RecommendedTime -ForegroundColor Green

    Write-Host "Estimated Duration: " -NoNewline
    Write-Host $suggestion.EstimatedDuration -ForegroundColor Yellow

    Write-Host "`nAnalysis:" -ForegroundColor Cyan
    Write-Host "  - $($suggestion.Reasoning)"
    Write-Host "  - Average backup size: $($suggestion.AverageSize)"
    Write-Host "  - File change rate: $($suggestion.ChangeRate)"

    # Suggest task scheduler command
    Write-Host "`nSuggested Scheduled Task:" -ForegroundColor Cyan
    $taskCmd = "schtasks /create /tn `"Backup Full`" /tr `"pwsh -File C:\Scripts\Backup\main.ps1 -BackupType Full -Destination HomeNet`" "
    $taskCmd += "/sc $(if ($suggestion.RecommendedFrequency -eq 'Daily') { 'daily' } else { 'weekly' }) "
    $taskCmd += "/st $($suggestion.RecommendedTime)"
    Write-Host $taskCmd -ForegroundColor Gray

    return $suggestion
}

Get-BackupScheduleSuggestion
```

**Usage:**
```powershell
.\Get-BackupScheduleSuggestion.ps1
```

**Files to Create:**
- `Get-BackupScheduleSuggestion.ps1` - NEW standalone script

**Dependencies:**
- Requires #35 (Statistics) with duration_seconds and size_mb in database

**Benefit:**
- Data-driven schedule recommendations
- Optimizes backup frequency based on actual usage
- Generates ready-to-use scheduled task command

---

## #NEW - Tar-like Archive Structure

**⚠️ WARNING: BREAKING CHANGE - Do this LAST**

**Problem:** Current archive structure doesn't match tar/standard backup format.

**Current Structure:**
```
Backup_20251021-120000/
├── Files/
│   ├── UserConfigs/
│   ├── Applications/
│   └── Games/
├── WindowsSettings/
└── manifest.json
```

**Proposed Structure (tar-like):**
```
Backup_20251021-120000/
├── data/                          # All backed-up files
│   ├── C/                        # Drive letter
│   │   ├── Users/
│   │   │   └── r_sta/
│   │   │       ├── .gitconfig
│   │   │       ├── Documents/
│   │   │       └── AppData/
│   │   ├── Program Files/
│   │   └── Utils/
│   └── REGISTRY/                 # Registry exports
│       ├── HKCU/
│       └── HKLM/
├── metadata/
│   ├── manifest.json            # File listing
│   ├── backup_info.json         # Backup metadata
│   └── checksums.sha256         # File hashes
└── scripts/
    ├── restore.ps1              # Restoration script
    └── install_packages.ps1     # Package installation
```

**Benefits:**
- Standard tar-like structure (familiar to Unix users)
- Easier to browse backup contents
- Clear separation of data/metadata
- Preserves full path structure
- Self-contained restore scripts
- Can extract individual files without restore script

**Implementation:**
- Modify folder creation in main.ps1
- Update manifest paths (all paths relative to data/)
- Update RestoreBackup.ps1 to handle new structure
- Add migration tool for old backups
- Create embedded restore.ps1 in each backup

**Files to Modify:**
- `main.ps1` - Complete rewrite of folder structure creation
- `ManifestUtilities.ps1` - Update all path references
- `RestoreBackup.ps1` - Handle both old and new structures
- NEW: `Migrate-BackupStructure.ps1` - Convert old backups

**Migration Strategy:**
1. Implement new structure alongside old (detect version from manifest)
2. RestoreBackup.ps1 handles both formats
3. Provide migration tool for existing backups
4. Deprecate old structure after 3-6 months

**⚠️ Important:** This is a breaking change. Must maintain backwards compatibility with old backup format.

---

# Implementation Tracking

## Completed Items
✅ **#23** - Standardize Error Handling (2025-10-22)
✅ **#1** - Hardcoded Debug Output in config_manager.ps1
✅ **#3** - Path Validation Before Backup
✅ **#6** - SSH Bandwidth Throttling
✅ **#7** - Database Connection Pooling
✅ **#9** - Compression Progress Indicator
✅ **#22** - Estimated Time Remaining (ETA)
✅ **Gotify Notifications** - Fixed background jobs

## Phase Status
- **Phase 1** (Logging Foundation): ✅ **COMPLETE & TESTED** (2025-10-22)
  - ✅ #37 - JSON Logging: Write-Log() updated, config updated, main.ps1 wired
  - ✅ #35 - Statistics: Functions created, wired into main.ps1, tracking success/failure/size/duration - TESTED & WORKING (avg size 90.44 MB tracked correctly)
  - ✅ #39 - Audit Trail: Write-AuditLog() implemented, tracking BACKUP_START, BACKUP_COMPLETE, COMPRESSION_START, TRANSFER_START - TESTED & WORKING
  - ✅ #36 - Health Check Script: health-check.ps1 created, checks database, last backup, disk space, sends notifications - TESTED & WORKING
  - ✅ Bug fixes: Database output suppression, datetime parsing, Measure-BackupPerformance output handling
- **Phase 2** (Backup Loop Enhancements): ✅ **COMPLETE & TESTED** (2025-10-22)
  - ⏭️ #15 - Smart Retry Logic: SKIPPED (locked files already handled gracefully - no retry needed)
  - ✅ #17 - Backup Speed Statistics: Measure-BackupSpeed() function added, integrated into Backup-Files-Sequential-Optimized, reports speed every 10 files and at completion - TESTED & WORKING
  - ✅ #43 - Enhanced Progress Display: Show-Progress() updated with CurrentFile parameter, displays current file being processed (truncated to 80 chars), clears 3 lines properly - IMPLEMENTED
  - ✅ Logging improvements: Switched to Out-File -Append for better flushing, added Flush-Log(), added WARNING-level completion markers for visibility
- **Phase 3** (Security Hardening): ✅ **COMPLETE** (2025-10-22)
  - ✅ #40 - Backup Permissions Validation: Test-DestinationWritable() function added to BackupUtilities.ps1, integrated into main.ps1 pre-flight checks - Tests write permissions to temp and destination paths before backup starts
  - ✅ #38 - DPAPI Secrets Management: Protect-BackupSecret() and Unprotect-BackupSecret() functions added, Send-GotifyNotification() updated to support encrypted tokens, Setup-BackupCredentials.ps1 updated to encrypt tokens with DPAPI (user-specific encryption)
  - ✅ #28 - Input Sanitization: ConvertTo-SafePath() and ConvertTo-SafeString() functions added, Validate-BackupParameters() updated to sanitize inputs, main.ps1 sanitizes all user parameters (BackupType, Destination, LogLevel) - Prevents injection attacks and path traversal
  - 📝 Implementation details:
    - Permissions: Fail-fast validation prevents midway failures
    - Secrets: TokenEncrypted field in config (backwards compatible with Token field)
    - Sanitization: Alphanumeric + underscore/dash only for names, control character removal, path traversal prevention
- **Phase 4** (Advanced Backup Features): ⚠️ **NEEDS REWORK** (2025-10-23)
  - ⚠️ #20 - Differential Backups: **IMPLEMENTED BUT IMPRACTICAL - REQUIRES REWORK**
    - Current implementation works at **category/path level** instead of **file level**
    - Problem: When ONE file changes in a directory, the ENTIRE directory gets backed up (e.g., 1 config file change → 2GB Scripts folder backed up)
    - This defeats the purpose of differential backups entirely
    - Status: Technically complete, feature exists and works as designed, but design is flawed
    - **FUTURE WORK NEEDED**: Implement true file-level differential backup
      - Only backup specific files that changed, not entire directories
      - Preserve directory structure for changed files only
      - More complex restore logic (merge directories)
      - Similar to rsync/duplicati behavior
    - Current code location: BackupUtilities.ps1 (Get-LastFullBackupDate, Get-ModifiedFilesSinceLastFull), main.ps1 (-BackupStrategy parameter)
    - Database schema: backup_strategy and parent_backup_id columns (via migrate-add-differential-support.ps1)
  - ⏭️ #16 - Backup Deduplication: DEFERRED to Phase 5 (hash-based duplicate detection can be added later as enhancement)
  - 📝 Current implementation details (category-level):
    - Database migration: migrate-add-differential-support.ps1 adds backup_strategy and parent_backup_id columns
    - Differential logic: Checks if ANY files modified in a category since last full backup → backs up ENTIRE category if yes
    - Auto-fallback: If no full backup found, automatically performs Full backup
    - Restore: Manual process - restore full backup first, then differential (future: auto-chain)
    - Usage: .\main.ps1 -BackupType Dev -Destination Tests -BackupStrategy Differential
    - ⚠️ NOT RECOMMENDED FOR USE in current state
- **Phase 5** (Performance & Code Quality): ✅ **COMPLETE & TESTED** (2025-10-23)
  - ⏭️ #31 - Lazy Config Loading: SKIPPED (config file is only 27KB - pointless optimization, adds complexity for no benefit)
  - ✅ #25 - Break Down Long Functions: COMPLETE & TESTED
    - **Goal:** Reduce token usage for AI-assisted maintenance by breaking large functions into focused units
    - **Threshold:** 100+ lines indicates refactoring needed
    - **Refactored functions:**
      1. ✅ Perform-Backup (main.ps1): 295 lines → 115 lines + 6 helper functions (35-65 lines each)
         - Invoke-PreflightChecks, Initialize-BackupEnvironment, Get-DifferentialBackupInfo, Invoke-BackupCompression, Invoke-BackupTransfer, Complete-BackupProcess
      2. ✅ Process-BackupItems (main.ps1): 207 lines → 72 lines + 5 helper functions (24-100 lines each)
         - Process-CertificatesBackup, Process-DoskeyMacrosBackup, Process-WindowsCredentialsBackup, Get-BackupDestinationFolder, Process-FileBackupItem
      3. ✅ Compress-Backup-Optimized (BackupUtilities.ps1): 177 lines → 138 lines + Build-SevenZipArguments helper (39 lines)
    - **Deferred (not needed):** Invoke-ExportCommand (216 lines), Invoke-WindowsSettingsBackup (173 lines), Check-DiskSpaceAndEstimateSize (146 lines)
    - **Achieved benefit:** 78-88% token reduction when debugging specific functionality
    - **Testing:** Full backup tested successfully - no regressions
- **Phase 6** (User Experience Enhancements): 🔄 **IN PROGRESS** (2025-10-23)
  - Pending: #41 - Interactive Restore Preview
  - Pending: #42 - Backup Comparison Tool
  - Pending: #44 - Backup Schedule Suggestions

---

## Resume Instructions

**To resume implementing these improvements in a future session:**

```
Continue implementing backup system improvements from help\TODO_FUTURE_IMPROVEMENTS.md.

Current system status (2025-10-23):
✅ COMPLETED PHASES:
- **Phase 1** (Logging Foundation): JSON logging, statistics tracking, audit trail, health checks
- **Phase 2** (Backup Loop): Speed statistics, enhanced progress display, logging improvements
- **Phase 3** (Security): Permissions validation, DPAPI secrets, input sanitization

⚠️ PHASE 4 STATUS (Advanced Backup Features):
- #20 - Differential Backups: IMPLEMENTED BUT FLAWED (category-level instead of file-level)
  - Current implementation backs up entire directories when one file changes
  - NOT RECOMMENDED FOR USE - needs complete rework to file-level differential
  - See Phase 4 section for details on required rework
- #16 - Backup Deduplication: DEFERRED

✅ PHASE 5 STATUS (Performance & Code Quality): COMPLETE & TESTED
- #31 - Lazy Config Loading: SKIPPED (27KB config file - no benefit)
- #25 - Break Down Long Functions: COMPLETE & TESTED
  - Refactored Perform-Backup (295→115 lines), Process-BackupItems (207→72 lines), Compress-Backup-Optimized (177→138 lines)
  - Achieved: 78-88% token reduction for AI-assisted debugging
  - Full backup tested successfully - no regressions

🔄 PHASE 6 STATUS (User Experience Enhancements): IN PROGRESS
Choose which feature to implement:
- #41 - Interactive Restore Preview (show what will be restored before executing)
- #42 - Backup Comparison Tool (compare two backups, see differences)
- #44 - Backup Schedule Suggestions (analyze patterns, suggest optimal schedule)

📋 DEFERRED WORK:
- Phase 4 rework: TRUE file-level differential backups (current implementation impractical)

The backup system files are at C:\Scripts\Backup\.
Main files: main.ps1, BackupUtilities.ps1, WinBackup.ps1, config\bkp_cfg.json
```

---

**Last Updated:** 2025-10-23
**Current Status:** Phases 1-3 Complete, Phase 4 Partial (needs rework), Phase 5 Complete, Phase 6 In Progress
**Active Work:** Phase 6 - User Experience Enhancements (choosing feature to implement)
**Total Items:** 17 improvements across 6 phases (10 completed, 2 skipped, 1 needs rework, 4 pending)
