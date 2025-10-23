# Load SQLite assembly
Add-Type -Path "db\System.Data.SQLite.dll"

function Test-DatabaseAccess {
    $databasePath = Resolve-Path ".\db\backup_history.db"
    Write-Host "Testing database access: $databasePath"
    
    if (Test-Path $databasePath) {
        try {
            $content = Get-Content $databasePath -TotalCount 1 -ErrorAction Stop
            Write-Host "Successfully read from database file."
			#cls
        }
        catch {
            Write-Host "Error reading database file: $_"
        }
    }
    else {
        Write-Host "Database file not found."
    }
}

# Call this function at the start of your script
Test-DatabaseAccess

function Show-MainMenu {
    gum choose --height=13 --header "Main Menu" "Perform Backup" "Restore Backup" "Delete Backups" "Edit config" "Manage backup config" "Quit"
}

function Invoke-BackupOperation {
    # Load config to get available backup types dynamically
    try {
        $config = Get-Content "config\bkp_cfg.json" -Raw | ConvertFrom-Json
        $availableTypes = $config.BackupTypes.PSObject.Properties.Name | Sort-Object
        
        if ($availableTypes.Count -eq 0) {
            gum style --foreground 196 "No backup types found in configuration!"
            Read-Host "Press Enter to continue"
            return
        }
        
        # Separate file backups from Windows settings backups for better organization
        $fileBackups = $availableTypes | Where-Object { -not $_.StartsWith("WinSettings-") } | Sort-Object
        $winSettingsBackups = $availableTypes | Where-Object { $_.StartsWith("WinSettings-") } | Sort-Object
        
        # Build the menu options
        $menuOptions = @()
        
        if ($fileBackups.Count -gt 0) {
            $menuOptions += "═══ File Backups ═══"
            $menuOptions += $fileBackups
        }
        
        if ($winSettingsBackups.Count -gt 0) {
            $menuOptions += "═══ Windows Settings ═══"
            $menuOptions += $winSettingsBackups
        }
        
        $menuOptions += "Go back"
        
        # Calculate height based on number of options (with some padding)
        $menuHeight = [Math]::Min(15, $menuOptions.Count + 2)
        
        # Show backup type menu with dynamically loaded options
        $backupType = gum choose --height=$menuHeight --header "Select Backup Type" $menuOptions
    }
    catch {
        Write-Host "Error loading backup configuration: $_" -ForegroundColor Red
        gum style --foreground 196 "Could not load backup types from config file!"
        Read-Host "Press Enter to continue"
        return
    }
    
    # Handle menu separators and special options
    if ($backupType -eq "Go back" -or $backupType.StartsWith("═══")) { 
        return 
    }
    
    # Load destinations dynamically from config
    try {
        $config = Get-Content "config\bkp_cfg.json" -Raw | ConvertFrom-Json
        $availableDestinations = $config.Destinations.PSObject.Properties.Name | Sort-Object
        $menuOptions = $availableDestinations + @("Go back")
        $menuHeight = [Math]::Min(15, $menuOptions.Count + 2)
        $destination = gum choose --height=$menuHeight --header "Select Destination" $menuOptions
    } catch {
        Write-Host "Error loading destinations from config: $_" -ForegroundColor Red
        gum style --foreground 196 "Could not load destinations from config file!"
        Read-Host "Press Enter to continue"
        return
    }
    if ($destination -eq "Go back") { return }

    $logLevel = gum choose --height=12 --header "Select Log Level" "INFO" "DEBUG" "WARNING" "ERROR" "Go back"
    if ($logLevel -eq "Go back") { return }

    # Compression level selection with presets
    Write-Host "`nCompression Level:" -ForegroundColor Yellow
    Write-Host "0 = Store (no compression, fastest)" -ForegroundColor Gray
    Write-Host "1 = Fastest (minimal compression)" -ForegroundColor Gray
    Write-Host "3 = Fast (light compression)" -ForegroundColor Gray
    Write-Host "5 = Normal (balanced - recommended)" -ForegroundColor Green
    Write-Host "7 = Maximum (high compression)" -ForegroundColor Gray
    Write-Host "9 = Ultra (best compression, slowest)" -ForegroundColor Gray
    Write-Host ""

    $compressionChoice = gum choose --height=10 --header "Select Compression Level" "5 - Normal (Default)" "1 - Fastest" "3 - Fast" "7 - Maximum" "9 - Ultra" "0 - Store (No Compression)" "Go back"
    if ($compressionChoice -eq "Go back") { return }

    # Extract number from choice
    $compressionLevel = [int]($compressionChoice.Split(' ')[0])

    # Show backup description based on type
    $backupDescription = Get-BackupDescription -BackupType $backupType
    Write-Host "`nBackup Details:" -ForegroundColor Cyan
    Write-Host $backupDescription -ForegroundColor Yellow

    # Show performance mode (always enabled)
    Write-Host "`n🚀 Performance Mode (Default):" -ForegroundColor Green
    Write-Host "• Multi-threaded 7zip compression (Level $compressionLevel)" -ForegroundColor Green
    Write-Host "• Optimized file operations" -ForegroundColor Green
    Write-Host "• Enhanced registry exports with timeout handling" -ForegroundColor Green

    gum confirm "Proceed with this backup?"
    if ($LASTEXITCODE -ne 0) {
        Write-Host "Backup cancelled by user." -ForegroundColor Yellow
        return
    }

    # Build command (always uses main.ps1 with performance mode built-in)
    $command = ".\Main.ps1 -BackupType $backupType -Destination $destination -LogLevel $logLevel -CompressionLevel $compressionLevel"
    Write-Host "Executing: $command" -ForegroundColor Green

    try {
        $output = Invoke-Expression $command

        # Display backup summary with performance indicators
        gum style --border normal --padding "1 2" --border-foreground 46 "🚀 Performance Backup Summary"

        if ($backupType.StartsWith("WinSettings-")) {
            # Windows settings backup summary
            $output | Where-Object { $_ -match '^\d{4}-\d{2}-\d{2}' -or $_ -match 'Successfully processed' -or $_ -match 'completed successfully' -or $_ -match 'PERFORMANCE:' } |
                      Select-Object -Last 20 |
                      ForEach-Object {
                          if ($_ -match 'PERFORMANCE:') {
                              Write-Host $_ -ForegroundColor Green
                          } else {
                              $_ -replace '^\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}\|[A-Z]+\|', ''
                          }
                      } |
                      gum format
        } else {
            # File backup summary with performance metrics
            $performanceLines = $output | Where-Object { $_ -match 'PERFORMANCE:' }
            $regularLines = $output | Where-Object { $_ -match '^\d{4}-\d{2}-\d{2}' -and $_ -notmatch 'PERFORMANCE:' }

            # Show performance metrics first if available
            if ($performanceLines) {
                Write-Host "`nPerformance Metrics:" -ForegroundColor Green
                $performanceLines | ForEach-Object {
                    Write-Host $_ -ForegroundColor Green
                }
                Write-Host ""
            }

            # Then show regular backup summary
            $regularLines | Select-Object -Last 10 |
                           ForEach-Object {
                               $_ -replace '^\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}\|', ''
                           } |
                           gum format
        }

        Write-Host "`n🚀 Performance backup completed successfully!" -ForegroundColor Green
    }
    catch {
        Write-Host "`nBackup failed with error: $_" -ForegroundColor Red
        gum style --foreground 196 "Backup operation failed. Check the logs for details."
    }

    gum confirm "Return to main menu?" 
    if (-not $?) { exit }
}

function Get-BackupDescription {
    param([string]$BackupType)
    
    # First check for hardcoded descriptions for known types
    switch ($BackupType) {
        "Full" {
            return @"
File Backup + Windows Settings - COMPLETE SYSTEM BACKUP
• Documents, Applications, Scripts
• TotalCommander, PowerToys, Notepad++
• PowerShell profiles, Windows Terminal
• User configurations and game saves
• ALL Windows Settings - Complete registry, configurations, and system preferences
• Package lists (winget, chocolatey, pip, cargo)
• Estimated time: 10-20 minutes depending on data size
"@
        }
        "Scripts" {
            return @"
Scripts Folder
• Estimated time: 1-3 minutes
"@
        }
        "Dev" {
            return @"
File Backup - Development Environment
• Scripts and PowerShell profiles
• User configurations and SSH keys
• Development tools settings
• Estimated time: 2-5 minutes
"@
        }
        "WinSettings-Minimal" {
            return @"
Windows Settings - Essential System Settings
• Display scaling and resolution
• Power management settings
• Mouse, keyboard, and regional settings
• Network profiles and basic system configuration
• Environment variables
• ~50MB, estimated time: 2-3 minutes
"@
        }
        "WinSettings-Essential" {
            return @"
Windows Settings - Common User Preferences
• All Minimal settings plus:
• Taskbar and Start menu configuration
• File Explorer preferences and Quick Access
• Context menus and file associations
• Privacy and security settings
• Terminal and PowerShell profiles
• ~100MB, estimated time: 3-5 minutes
"@
        }
        "WinSettings-Full" {
            return @"
Windows Settings - Complete System Configuration
• All Essential settings plus:
• Advanced system settings and Group Policy
• Windows features and service configurations
• Developer settings and WSL configuration
• Application settings (browsers, Office if installed)
• Package manager exports (winget, chocolatey, pip, cargo)
• Event logs and system diagnostics
• ~200MB, estimated time: 5-10 minutes
"@
        }
        default {
            # For dynamic/custom backup types, generate description from config
            try {
                $config = Get-Content "config\bkp_cfg.json" -Raw | ConvertFrom-Json
                $backupItems = $config.BackupTypes.$BackupType
                
                if (-not $backupItems) {
                    return "Unknown backup type: $BackupType"
                }
                
                # Determine if it's Windows Settings or File backup
                $isWindowsSettings = $BackupType.StartsWith("WinSettings-") -or 
                                   ($backupItems | Where-Object { $_ -like "Win*" }).Count -gt 0
                
                if ($isWindowsSettings) {
                    $description = "Windows Settings - Custom Configuration`n"
                    $description += "• Registry exports and system configurations`n"
                    $description += "• Configuration files and user preferences`n"
                    $description += "• System inventories and package lists`n"
                }
                else {
                    $description = "File Backup - Custom Backup Type`n"
                }
                
                $description += "• Backup items included:`n"
                foreach ($item in $backupItems) {
                    # Get item details from config
                    $itemPaths = $config.BackupItems.$item
                    if ($itemPaths) {
                        if ($itemPaths.type -eq "windows_settings") {
                            $description += "  - $item [Windows Settings - $($itemPaths.items.Count) items]`n"
                        }
                        elseif ($itemPaths -is [Array]) {
                            $pathCount = $itemPaths.Count
                            $description += "  - $item ($pathCount paths)`n"
                        }
                        else {
                            $description += "  - $item`n"
                        }
                    }
                    else {
                        $description += "  - $item [Configuration not found]`n"
                    }
                }
                
                $description += "• Custom backup type created via Configuration Manager"
                
                return $description
            }
            catch {
                return @"
Custom Backup Type: $BackupType
• Configuration could not be loaded
• Check bkp_cfg.json for details
• This backup type was created via Configuration Manager
"@
            }
        }
    }
}

function Config-Edit {
    notepad++.exe ".\config\bkp_cfg.json"
}

function Start-ConfigManager {
    Write-Host "Starting Configuration Manager..." -ForegroundColor Cyan
    
    # Check if config manager exists
    if (-not (Test-Path ".\config_manager.ps1")) {
        gum style --foreground 196 "config_manager.ps1 not found!"
        gum style --foreground 212 "Please ensure config_manager.ps1 is in the same directory."
        Read-Host "Press Enter to continue"
        return
    }
    
    try {
        # Start config manager using Windows Terminal profile
        wt -p "Backup_Config_Manager"
        
        # Give user option to continue or wait
        $choice = gum choose --height=5 --header "Configuration Manager opened in new window" "Continue with Backup Manager" "Exit Backup Manager"
        
        if ($choice -eq "Exit Backup Manager") {
            Write-Host "Thank you for using Backup Manager!" -ForegroundColor Green
            exit
        }
    }
    catch {
        gum style --foreground 196 "Error starting Configuration Manager: $_"
        gum style --foreground 212 "Make sure Windows Terminal profile 'Backup_Config_Manager' exists"
        Read-Host "Press Enter to continue"
    }
}

function Get-Backups {
    $databasePath = Resolve-Path ".\db\backup_history.db"
    Write-Host "Attempting to connect to database: $databasePath"
    
    if (-not (Test-Path $databasePath)) {
        Write-Host "Database file not found at $databasePath"
        return @()
    }

    try {
        $connectionString = "Data Source=$databasePath;Version=3;"
        Write-Host "Connection string: $connectionString"
        $connection = New-Object System.Data.SQLite.SQLiteConnection($connectionString)
        $connection.Open()

        $command = $connection.CreateCommand()
        $command.CommandText = "SELECT * FROM backups ORDER BY id DESC"
        $reader = $command.ExecuteReader()

        $backups = @()
        while ($reader.Read()) {
            $sizeBytes = [long]$reader["size_bytes"]
            $sizeGB = [math]::Round($sizeBytes / 1GB, 2)
            $backups += [PSCustomObject]@{
                Id = $reader["id"]
                BackupSetName = $reader["backup_set_name"]
                BackupType = $reader["backup_type"]
                Destination = $reader["destination_type"]
                DestinationPath = $reader["destination_path"]
                Timestamp = $reader["timestamp"]
                SizeGB = $sizeGB
            }
        }
        return $backups
    }
    catch {
        Write-Host "Error accessing the database: $_"
        Write-Host "Exception details: $($_.Exception.GetType().FullName)"
        Write-Host "Stack trace: $($_.ScriptStackTrace)"
        return @()
    }
    finally {
        if ($connection -and $connection.State -eq 'Open') {
            $connection.Close()
        }
    }
}

function Invoke-RestoreOperation {
    Write-Host "`nComprehensive Backup Restoration" -ForegroundColor Yellow
    Write-Host "=================================" -ForegroundColor Yellow
    Write-Host "• Interactive: Complete guided workflow with choice of complete or selective restoration" -ForegroundColor Gray
    Write-Host "• Quick: Fast complete restoration of entire backup to chosen destination" -ForegroundColor Gray  
    Write-Host "• Individual registry file import confirmation available in both modes" -ForegroundColor Gray
    Write-Host "• Restore to original locations or custom destination" -ForegroundColor Gray
    Write-Host ""
    
    # Check if RestoreBackup.ps1 exists
    if (-not (Test-Path ".\RestoreBackup.ps1")) {
        gum style --foreground 196 "RestoreBackup.ps1 not found!"
        gum style --foreground 212 "Please ensure RestoreBackup.ps1 is in the same directory."
        Read-Host "Press Enter to continue"
        return
    }
    
    # Get available backups
    $backups = Get-Backups
    if ($backups.Count -eq 0) {
        gum style --foreground 196 "No backups found for restoration."
        gum style --foreground 212 "Create some backups first using 'Perform Backup'."
        Read-Host "Press Enter to continue"
        return
    }
    
    Write-Host "Found $($backups.Count) available backups for restoration." -ForegroundColor Green
    
    # Choose restoration mode
    Write-Host "`nRestore Options:" -ForegroundColor Cyan
    $restoreOptions = @(
        "Interactive Restoration (Guided step-by-step)",
        "Quick Restoration (Restore specific backup completely)",
        "Go back to main menu"
    )
    
    $restoreChoice = gum choose --height=8 --header "Select Restoration Mode" $restoreOptions
    
    switch ($restoreChoice) {
        "Interactive Restoration (Guided step-by-step)" {
            try {
                Write-Host "`nStarting Interactive Restoration..." -ForegroundColor Green
                $command = ".\RestoreBackup.ps1 -RestoreMode Interactive -LogLevel INFO"
                Write-Host "Executing: $command" -ForegroundColor Cyan
                
                & ".\RestoreBackup.ps1" -RestoreMode "Interactive" -LogLevel "INFO"
                
                Write-Host "`nRestore operation completed!" -ForegroundColor Green
            }
            catch {
                Write-Host "`nRestore failed with error: $_" -ForegroundColor Red
                gum style --foreground 196 "Restore operation failed. Check the logs for details."
            }
        }
        
        "Quick Restoration (Restore specific backup completely)" {
            # Show backup selection menu
            $formattedBackups = $backups | ForEach-Object { 
                $typeIndicator = if ($_.BackupType.StartsWith("WinSettings-")) { "[WIN]" } else { "[FILE]" }
                $ageInDays = [math]::Round(((Get-Date) - [DateTime]$_.Timestamp).TotalDays)
                "{0,3}: {1} {2} | {3} | {4:N2} GB | {5} days ago" -f $_.Id, $typeIndicator, $_.BackupSetName, $_.Timestamp, $_.SizeGB, $ageInDays
            }
            $formattedBackups = @("Cancel") + $formattedBackups
            
            $selectedBackup = gum choose --height=15 --header "Select Backup for Quick Restoration" $formattedBackups
            
            if ($selectedBackup -eq "Cancel" -or -not $selectedBackup) {
                return
            }
            
            $backupId = [int]($selectedBackup -split ":")[0].Trim()
            
            # Get restore destination
            $destination = gum choose --height=8 --header "Restore Destination" "Original Locations" "Custom Location" "Cancel"
            
            if ($destination -eq "Cancel") { return }
            
            $customPath = ""
            if ($destination -eq "Custom Location") {
                $customPath = gum input --placeholder "Enter custom restore path (e.g., C:\Temp\Restore)"
                if ([string]::IsNullOrWhiteSpace($customPath)) {
                    gum style --foreground 196 "No destination specified. Restoration cancelled."
                    return
                }
            }
            
            try {
                Write-Host "`nStarting Quick Restoration..." -ForegroundColor Green
                
                if ($destination -eq "Original Locations") {
                    $command = ".\RestoreBackup.ps1 -BackupId $backupId -RestoreMode Interactive -LogLevel INFO"
                    Write-Host "Executing: $command" -ForegroundColor Cyan
                    & ".\RestoreBackup.ps1" -BackupId $backupId -RestoreMode "Interactive" -LogLevel "INFO"
                } else {
                    $command = ".\RestoreBackup.ps1 -BackupId $backupId -RestoreDestination `"$customPath`" -RestoreMode Interactive -LogLevel INFO"
                    Write-Host "Executing: $command" -ForegroundColor Cyan
                    & ".\RestoreBackup.ps1" -BackupId $backupId -RestoreDestination $customPath -RestoreMode "Interactive" -LogLevel "INFO"
                }
                
                Write-Host "`nQuick restore operation completed!" -ForegroundColor Green
            }
            catch {
                Write-Host "`nQuick restore failed with error: $_" -ForegroundColor Red
                gum style --foreground 196 "Quick restore operation failed. Check the logs for details."
            }
        }
        
        "Go back to main menu" {
            return
        }
        
        default {
            return
        }
    }
    
    gum confirm "Return to main menu?" 
    if (-not $?) { exit }
}

function Delete-Backups {
    Write-Host "Entering Delete-Backups function"
    $backups = Get-Backups
    Write-Host "Retrieved $(($backups | Measure-Object).Count) backups"

    if ($backups.Count -eq 0) {
        gum style --foreground 196 "No backups found to delete."
        return
    }

    # Format backup list with type indication
    $formattedBackups = $backups | ForEach-Object { 
        $typeIndicator = if ($_.BackupType.StartsWith("WinSettings-")) { "[WIN]" } else { "[FILE]" }
        "{0,2}: {1} {2} ({3}) - {4:N2} GB" -f $_.Id, $typeIndicator, $_.BackupSetName, $_.Timestamp, $_.SizeGB
    }
    $formattedBackups = @("Go back to main menu") + $formattedBackups

    Write-Host "Prompting user to select a backup"
    $selectedBackup = gum choose --height=12 --header "Select Backup to Delete ([WIN]=Windows Settings, [FILE]=File Backup)" --limit 1 $formattedBackups

    Write-Host "User selected: $selectedBackup"
    if ($selectedBackup -eq "Go back to main menu") { 
        Write-Host "User chose to go back to main menu"
        return 
    }

    $deleteId = ($selectedBackup -split ":")[0].Trim()
    Write-Host "Parsed deleteId: $deleteId"

    $backupToDelete = $backups | Where-Object { $_.Id -eq $deleteId }
    Write-Host "Backup to delete: $($backupToDelete | ConvertTo-Json)"
    
    if ($backupToDelete) {
        # Show backup details before deletion
        Write-Host "`nBackup Details:" -ForegroundColor Yellow
        Write-Host "Type: $($backupToDelete.BackupType)" -ForegroundColor Cyan
        Write-Host "Created: $($backupToDelete.Timestamp)" -ForegroundColor Cyan
        Write-Host "Size: $($backupToDelete.SizeGB) GB" -ForegroundColor Cyan
        Write-Host "Location: $($backupToDelete.DestinationPath)" -ForegroundColor Cyan
        
        Write-Host "Prompting user for confirmation"
        $confirmation = gum confirm "Are you sure you want to delete this backup?"
        $confirmationResult = $LASTEXITCODE -eq 0
        Write-Host "Confirmation result: $confirmationResult"
        
        if ($confirmationResult) {
            Write-Host "User confirmed deletion"
            
            # FIXED: Delete the actual backup files
            # The DestinationPath already contains the full path to the backup file
            if ($backupToDelete.DestinationPath.EndsWith('.zip') -or $backupToDelete.DestinationPath.EndsWith('.7z')) {
                # It's a single compressed file
                $backupPath = $backupToDelete.DestinationPath
                Write-Host "Attempting to delete backup file: $backupPath"
                if (Test-Path $backupPath) {
                    try {
                        Remove-Item -Path $backupPath -Force -ErrorAction Stop
                        Write-Host "Deleted backup file: $backupPath"
                        gum style --foreground 212 "Deleted backup file: $backupPath"
                        
                        # Also try to delete the parent directory if it's empty
                        $parentDir = Split-Path $backupPath -Parent
                        if (Test-Path $parentDir) {
                            $remainingFiles = Get-ChildItem $parentDir -Force
                            if ($remainingFiles.Count -eq 0) {
                                Remove-Item -Path $parentDir -Force -ErrorAction SilentlyContinue
                                Write-Host "Deleted empty parent directory: $parentDir"
                                gum style --foreground 212 "Deleted empty parent directory: $parentDir"
                            }
                        }
                    } catch {
                        Write-Host "Error deleting backup file: $_"
                        gum style --foreground 196 "Error deleting backup file: $_"
                    }
                } else {
                    Write-Host "Backup file not found at $backupPath"
                    gum style --foreground 196 "Backup file not found at $backupPath"
                }
            } else {
                # It's a directory-based backup
                $backupPath = $backupToDelete.DestinationPath
                Write-Host "Attempting to delete backup directory: $backupPath"
                if (Test-Path $backupPath) {
                    try {
                        Remove-Item -Path $backupPath -Recurse -Force -ErrorAction Stop
                        Write-Host "Deleted backup directory: $backupPath"
                        gum style --foreground 212 "Deleted backup directory: $backupPath"
                    } catch {
                        Write-Host "Error deleting backup directory: $_"
                        gum style --foreground 196 "Error deleting backup directory: $_"
                    }
                } else {
                    Write-Host "Backup directory not found at $backupPath"
                    gum style --foreground 196 "Backup directory not found at $backupPath"
                }
            }

            # Delete from database
            $databasePath = Resolve-Path ".\db\backup_history.db"
            Write-Host "Attempting to delete backup entry from database: $databasePath"
            try {
                $connection = New-Object System.Data.SQLite.SQLiteConnection("Data Source=$databasePath;Version=3;")
                $connection.Open()
                Write-Host "Database connection opened"
                $deleteCommand = $connection.CreateCommand()
                $deleteCommand.CommandText = "DELETE FROM backups WHERE id = @Id"
                $deleteCommand.Parameters.AddWithValue("@Id", $deleteId)
                $rowsAffected = $deleteCommand.ExecuteNonQuery()
                Write-Host "Database query executed. Rows affected: $rowsAffected"
                if ($rowsAffected -gt 0) {
                    Write-Host "Backup deleted from database"
                    gum style --foreground 212 "Backup with ID $deleteId has been deleted from the database."
                } else {
                    Write-Host "No backup found in database with ID $deleteId"
                    gum style --foreground 196 "No backup found in the database with ID $deleteId."
                }
            }
            catch {
                Write-Host "Error deleting from database: $_"
                gum style --foreground 196 "Error deleting from database: $_"
            }
            finally {
                if ($connection -and $connection.State -eq 'Open') {
                    $connection.Close()
                    Write-Host "Database connection closed"
                }
            }
        } else {
            Write-Host "User cancelled deletion"
            gum style --foreground 196 "Deletion cancelled by user."
        }
    } else {
        Write-Host "Backup with ID $deleteId not found"
        gum style --foreground 196 "Backup with ID $deleteId not found."
    }
    Write-Host "Prompting to return to main menu"
    gum confirm "Return to main menu?" 
    if (-not $?) { 
        Write-Host "User chose to exit"
        exit 
    }
    Write-Host "Returning to main menu"
}

# Display startup banner
function Show-Banner {
    Write-Host @"

╔══════════════════════════════════════════════════════════════╗
║                🔧 BACKUP MANAGER v4.0 🔧                     ║
║                                                              ║
║  File Backups:     Full | Games | Dev                        ║
║  Windows Settings: Minimal | Essential | Full                ║
║  Destinations:     Local | HomeNet | SSH                     ║
║  🆕 Restore:       Complete | Selective | Granular           ║
╚══════════════════════════════════════════════════════════════╝

"@ -ForegroundColor Cyan
}

# Main script logic
Write-Host "Starting Backup Manager..." -ForegroundColor Green
Show-Banner

while ($true) {
    $choice = Show-MainMenu
    switch ($choice) {
        "Perform Backup" { Invoke-BackupOperation }
        "Restore Backup" { Invoke-RestoreOperation }
        "Delete Backups" { Delete-Backups }
        "Edit config"    { Config-Edit }
        "Manage backup config" { Start-ConfigManager }
        "Quit" { 
            Write-Host "Thank you for using Backup Manager!" -ForegroundColor Green
            exit 
        }
    }
}