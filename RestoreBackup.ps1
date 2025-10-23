#Requires -Version 5.1

<#
.SYNOPSIS
    Comprehensive Backup Restoration Module
    
.DESCRIPTION
    Provides comprehensive backup restoration capabilities with granular selection,
    original or custom destination support, and registry import handling.
    
.PARAMETERS
    -BackupId         : Specific backup ID to restore (optional)
    -RestoreMode      : "Interactive" or "Selective" (default: Interactive)
    -RestoreDestination: Custom restore location (optional, uses original paths if not specified)
    -LogLevel         : Logging level (INFO, DEBUG, WARNING, ERROR)
    -DryRun           : Preview what would be restored without actually restoring
    
.EXAMPLES
    .\RestoreBackup.ps1
    .\RestoreBackup.ps1 -BackupId 15 -RestoreDestination "C:\Temp\Restore"
    .\RestoreBackup.ps1 -RestoreMode Selective -DryRun
    
.NOTES
    Version: 1.4
    Depends on: BackupUtilities.ps1, ManifestUtilities.ps1, gum.exe, 7-Zip

    DIFFERENTIAL BACKUP RESTORE (Phase 4 - Issue #20):
    - For differential backups, you must restore the parent full backup FIRST
    - Then restore the differential backup on top (files will overwrite)
    - Check database for parent_backup_id to find the full backup to restore
    - Future enhancement: Auto-detect and restore full+differential chain
    Fixed: Simplified extraction paths, fixed manifest detection logic
#>

[CmdletBinding()]
param (
    [Parameter(Mandatory=$false, HelpMessage="Specific backup ID to restore")]
    [int]$BackupId,
    
    [Parameter(Mandatory=$false, HelpMessage="Restore mode: Interactive or Selective")]
    [ValidateSet("Interactive", "Selective")]
    [string]$RestoreMode = "Interactive",
    
    [Parameter(Mandatory=$false, HelpMessage="Custom restore destination")]
    [string]$RestoreDestination,
    
    [Parameter(Mandatory=$false, HelpMessage="Logging level")]
    [ValidateSet("INFO", "DEBUG", "WARNING", "ERROR")]
    [string]$LogLevel = "INFO",
    
    [Parameter(Mandatory=$false, HelpMessage="Preview mode - show what would be restored")]
    [switch]$DryRun,
    
    [Parameter(Mandatory=$false, HelpMessage="Configuration file path")]
    [string]$ConfigFile = "config\bkp_cfg.json"
)

#region Dependency Loading and Validation

# Load SQLite assembly
try {
    Add-Type -Path "db\System.Data.SQLite.dll"
    Write-Verbose "SQLite assembly loaded successfully"
}
catch {
    Write-Error "Failed to load SQLite assembly. Ensure System.Data.SQLite.dll exists in db\ folder: $_"
    exit 1
}

# Check for gum.exe availability
function Test-GumAvailability {
    try {
        $null = & gum --version 2>$null
        return $true
    }
    catch {
        return $false
    }
}

if (-not (Test-GumAvailability)) {
    Write-Error @"
gum.exe is required for interactive restoration but was not found.
Please install gum from: https://github.com/charmbracelet/gum
Or ensure gum.exe is in your PATH.
"@
    exit 1
}

# Import required modules with better error handling
$requiredModules = @(
    @{ Path = "$PSScriptRoot\BackupUtilities.ps1"; Name = "BackupUtilities" },
    @{ Path = "$PSScriptRoot\ManifestUtilities.ps1"; Name = "ManifestUtilities" }
)

foreach ($module in $requiredModules) {
    if (-not (Test-Path $module.Path)) {
        Write-Error "Required module not found: $($module.Path)"
        exit 1
    }
    
    try {
        . $module.Path
        Write-Verbose "Successfully loaded $($module.Name)"
    }
    catch {
        Write-Error "Failed to load $($module.Name): $_"
        exit 1
    }
}

# Verify critical functions are available
$criticalFunctions = @("Write-Log", "Parse-ConfigFile", "Initialize-Logging", "Check-Dependencies", "Show-Progress")
$missingFunctions = @()

foreach ($func in $criticalFunctions) {
    if (-not (Get-Command $func -ErrorAction SilentlyContinue)) {
        $missingFunctions += $func
    }
}

if ($missingFunctions.Count -gt 0) {
    Write-Error "Critical functions not available after loading dependencies: $($missingFunctions -join ', ')"
    Write-Error "This indicates a problem with BackupUtilities.ps1 or ManifestUtilities.ps1"
    exit 1
}

#endregion

#region Global Variables

$script:Config = $null
$script:SelectedBackup = $null
$script:BackupManifest = $null
$script:TempRestoreDir = $null
$script:BackupBaseDir = $null  # FIXED: Track the actual directory containing backup files
$script:RestoredItems = @()
$script:FailedItems = @()

#endregion

#region Utility Functions

function Get-SimpleRestoreDirectory {
    param ([string]$BackupName)
    
    # FIXED: Use simple, consistent temp path from config
    $baseTempPath = $script:Config.TempPath
    
    # Ensure base temp directory exists
    if (-not (Test-Path $baseTempPath)) {
        New-Item -ItemType Directory -Path $baseTempPath -Force | Out-Null
        Write-Log "Created base temp directory: $baseTempPath" -Level "INFO"
    }
    
    # SIMPLIFIED: Use simple directory name
    $restoreDirName = "Restore_$BackupName"
    $fullRestorePath = Join-Path $baseTempPath $restoreDirName
    
    # Clean up existing restore directory if it exists
    if (Test-Path $fullRestorePath) {
        Write-Log "Cleaning up existing restore directory: $fullRestorePath" -Level "INFO"
        Remove-Item -Path $fullRestorePath -Recurse -Force -ErrorAction SilentlyContinue
    }
    
    Write-Log "Using simple restore directory: $fullRestorePath" -Level "INFO"
    return $fullRestorePath
}

#endregion

#region Database Query Functions

function Get-AvailableBackups {
    param ([string]$BackupType = $null)
    
    $databasePath = Join-Path $PSScriptRoot "db\backup_history.db"
    
    if (-not (Test-Path $databasePath)) {
        Write-Log "Database file not found: $databasePath" -Level "ERROR"
        return @()
    }
    
    try {
        $connection = New-Object System.Data.SQLite.SQLiteConnection("Data Source=$databasePath;Version=3;")
        $connection.Open()
        
        $query = if ($BackupType) {
            "SELECT * FROM backups WHERE backup_type = @BackupType ORDER BY timestamp DESC"
        } else {
            "SELECT * FROM backups ORDER BY timestamp DESC"
        }
        
        $command = $connection.CreateCommand()
        $command.CommandText = $query
        
        if ($BackupType) {
            $command.Parameters.AddWithValue("@BackupType", $BackupType)
        }
        
        $reader = $command.ExecuteReader()
        $backups = @()
        
        while ($reader.Read()) {
            $sizeGB = [math]::Round([long]$reader["size_bytes"] / 1GB, 2)
            $backups += [PSCustomObject]@{
                Id = $reader["id"]
                BackupSetName = $reader["backup_set_name"]
                BackupType = $reader["backup_type"]
                DestinationType = $reader["destination_type"]
                DestinationPath = $reader["destination_path"]
                Timestamp = $reader["timestamp"]
                SizeGB = $sizeGB
                SizeBytes = [long]$reader["size_bytes"]
                CompressionMethod = $reader["compression_method"]
                SourcePaths = $reader["source_paths"]
                AdditionalMetadata = $reader["additional_metadata"]
            }
        }
        
        Write-Log "Found $($backups.Count) available backups" -Level "INFO"
        return $backups
    }
    catch {
        Write-Log "Error querying backup database: $_" -Level "ERROR"
        return @()
    }
    finally {
        if ($connection -and $connection.State -eq 'Open') {
            $connection.Close()
        }
    }
}

function Get-BackupById {
    param ([int]$Id)
    
    $allBackups = Get-AvailableBackups
    return $allBackups | Where-Object { $_.Id -eq $Id }
}

#endregion

#region Archive Handling Functions

function Extract-BackupArchive {
    param (
        [PSCustomObject]$Backup,
        [string]$TempDirectory
    )
    
    $archivePath = $Backup.DestinationPath
    
    # Handle SSH backups (not implemented in this version)
    if ($Backup.DestinationType -eq "SSH") {
        Write-Log "SSH backup restoration not yet implemented" -Level "ERROR"
        return $false
    }
    
    # Verify archive exists
    if (-not (Test-Path $archivePath)) {
        Write-Log "Backup archive not found: $archivePath" -Level "ERROR"
        return $false
    }
    
    # Create temp directory
    if (-not (Test-Path $TempDirectory)) {
        New-Item -ItemType Directory -Path $TempDirectory -Force | Out-Null
    }
    
    # Extract archive using 7-Zip
    try {
        Write-Log "Extracting backup archive: $archivePath" -Level "INFO"
        $sevenZipPath = $script:Config.Tools.'7Zip'
        
        # Verify 7-Zip exists
        if (-not (Test-Path $sevenZipPath)) {
            Write-Log "7-Zip not found at: $sevenZipPath" -Level "ERROR"
            return $false
        }
        
        $extractArgs = @("x", $archivePath, "-o$TempDirectory", "-y")
        $result = & $sevenZipPath $extractArgs
        
        if ($LASTEXITCODE -ne 0) {
            Write-Log "7-Zip extraction failed with exit code: $LASTEXITCODE" -Level "ERROR"
            return $false
        }
        
        Write-Log "Backup archive extracted successfully to: $TempDirectory" -Level "INFO"
        return $true
    }
    catch {
        Write-Log "Error extracting backup archive: $_" -Level "ERROR"
        return $false
    }
}

function Find-ManifestInExtraction {
    param ([string]$ExtractedPath)
    
    Write-Log "Searching for manifest.json in extracted backup..." -Level "DEBUG"
    Write-Log "Base extraction path: $ExtractedPath" -Level "DEBUG"
    
    # FIXED: Better manifest search that understands backup structure
    # When 7-Zip extracts C:\Temp\Backup\Full_20250629-163636, it creates C_\temp\Backup\Full_20250629-163636\
    
    try {
        # Get all manifest.json files recursively
        $manifestFiles = Get-ChildItem -Path $ExtractedPath -Filter "manifest.json" -Recurse -ErrorAction SilentlyContinue
        
        if ($manifestFiles) {
            Write-Log "Found $($manifestFiles.Count) manifest.json file(s)" -Level "DEBUG"
            
            foreach ($manifestFile in $manifestFiles) {
                Write-Log "Checking manifest: $($manifestFile.FullName)" -Level "DEBUG"
                
                try {
                    # Test if it's a valid backup manifest
                    $testContent = Get-Content $manifestFile.FullName -Raw | ConvertFrom-Json
                    
                    if ($testContent.backup_manifest -and $testContent.backup_info) {
                        Write-Log "Valid backup manifest found: $($manifestFile.FullName)" -Level "INFO"
                        Write-Log "Manifest contains $($testContent.backup_info.total_entries) entries" -Level "INFO"
                        
                        # FIXED: Store the directory containing the manifest as the base directory for files
                        $script:BackupBaseDir = Split-Path $manifestFile.FullName -Parent
                        Write-Log "Backup base directory set to: $script:BackupBaseDir" -Level "DEBUG"
                        
                        return $manifestFile.FullName
                    } else {
                        Write-Log "File is JSON but not a backup manifest: $($manifestFile.FullName)" -Level "DEBUG"
                    }
                }
                catch {
                    Write-Log "Failed to parse manifest file $($manifestFile.FullName): $_" -Level "DEBUG"
                }
            }
        }
        
        # If no valid manifest found, show directory structure for debugging
        Write-Log "No valid manifest found. Showing directory structure for debugging:" -Level "DEBUG"
        $dirStructure = Get-ChildItem -Path $ExtractedPath -Recurse -Directory | Select-Object -First 10 | ForEach-Object { $_.FullName.Replace($ExtractedPath, "").TrimStart('\') }
        if ($dirStructure) {
            Write-Log "Directory structure: $($dirStructure -join ', ')" -Level "DEBUG"
        }
        
        $allFiles = Get-ChildItem -Path $ExtractedPath -Recurse -File | Select-Object -First 20 | ForEach-Object { $_.FullName.Replace($ExtractedPath, "").TrimStart('\') }
        if ($allFiles) {
            Write-Log "Sample files: $($allFiles -join ', ')" -Level "DEBUG"
        }
        
    }
    catch {
        Write-Log "Error during manifest search: $_" -Level "ERROR"
    }
    
    Write-Log "No valid manifest.json found - this backup may not support selective restoration" -Level "WARNING"
    return $null
}

#endregion

#region TUI Selection Functions

function Show-BackupSelectionMenu {
    param ([PSCustomObject[]]$Backups)
    
    if ($Backups.Count -eq 0) {
        Write-Host "No backups available for restoration." -ForegroundColor Red
        return $null
    }
    
    Write-Host "`nAvailable Backups for Restoration:" -ForegroundColor Yellow
    Write-Host "===================================" -ForegroundColor Yellow
    
    # Format backup list for gum
    $formattedBackups = @()
    
    foreach ($backup in $Backups) {
        $typeIndicator = if ($backup.BackupType.StartsWith("WinSettings-")) { "[WIN]" } else { "[FILE]" }
        $ageInDays = [math]::Round(((Get-Date) - [DateTime]$backup.Timestamp).TotalDays)
        $formattedBackups += "{0,3}: {1} {2} | {3} | {4:N2} GB | {5} days ago" -f $backup.Id, $typeIndicator, $backup.BackupSetName, $backup.Timestamp, $backup.SizeGB, $ageInDays
    }
    
    $formattedBackups = @("Cancel Restoration") + $formattedBackups
    
    # Use gum for selection with error handling
    try {
        $selection = & gum choose --height=15 --header="Select Backup to Restore ([WIN]=Windows Settings, [FILE]=File Backup)" $formattedBackups
        
        if ($selection -eq "Cancel Restoration" -or -not $selection) {
            return $null
        }
        
        # Extract backup ID from selection
        $backupId = [int]($selection -split ":")[0].Trim()
        return $Backups | Where-Object { $_.Id -eq $backupId }
    }
    catch {
        Write-Log "Error with gum selection: $_" -Level "ERROR"
        return $null
    }
}

function Show-RestoreModeMenu {
    Write-Host "`nRestore Mode Selection:" -ForegroundColor Yellow
    Write-Host "======================" -ForegroundColor Yellow
    Write-Host "• Complete Restoration: Restore entire backup"
    Write-Host "• Selective Restoration: Choose specific items to restore"
    Write-Host ""
    
    $modes = @(
        "Complete Restoration",
        "Selective Restoration", 
        "Cancel"
    )
    
    try {
        $selection = & gum choose --height=8 --header="Choose Restoration Mode" $modes
        
        switch ($selection) {
            "Complete Restoration" { return "Complete" }
            "Selective Restoration" { return "Selective" }
            default { return $null }
        }
    }
    catch {
        Write-Log "Error with gum selection: $_" -Level "ERROR"
        return $null
    }
}

function Show-DestinationMenu {
    Write-Host "`nRestore Destination:" -ForegroundColor Yellow
    Write-Host "====================" -ForegroundColor Yellow
    Write-Host "• Original Locations: Restore files to their original paths"
    Write-Host "• Custom Location: Restore to a different location with preserved structure"
    Write-Host ""
    
    $destinations = @(
        "Original Locations",
        "Custom Location",
        "Cancel"
    )
    
    try {
        $selection = & gum choose --height=8 --header="Select Restore Destination" $destinations
        
        switch ($selection) {
            "Original Locations" { return "Original" }
            "Custom Location" { 
                try {
                    $customPath = & gum input --placeholder="Enter custom restore path (e.g., C:\Temp\Restore)"
                    if ([string]::IsNullOrWhiteSpace($customPath)) {
                        return $null
                    }
                    return $customPath
                }
                catch {
                    Write-Log "Error getting custom path input: $_" -Level "ERROR"
                    return $null
                }
            }
            default { return $null }
        }
    }
    catch {
        Write-Log "Error with gum selection: $_" -Level "ERROR"
        return $null
    }
}

function Show-RegistryBulkActionMenu {
    param ([int]$RegistryCount)
    
    Write-Host "`nRegistry Import Options:" -ForegroundColor Yellow
    Write-Host "======================" -ForegroundColor Yellow
    Write-Host "Found $RegistryCount registry entries to be restored." -ForegroundColor Cyan
    Write-Host "Choose how to handle registry imports:" -ForegroundColor Gray
    Write-Host ""
    Write-Host "• Import All: Automatically import all registry entries to Windows Registry" -ForegroundColor Gray
    Write-Host "• Extract Only: Save all registry files to disk but don't import them" -ForegroundColor Gray  
    Write-Host "• Manual Choice: Ask for each registry entry individually (current behavior)" -ForegroundColor Gray
    Write-Host ""
    
    $choices = @(
        "Import All Registry Entries",
        "Extract Only (Do Not Import)",
        "Manual Choice for Each Entry",
        "Cancel Restoration"
    )
    
    try {
        $selection = & gum choose --height=10 --header="Registry Import Bulk Action ($RegistryCount entries found)" $choices
        
        switch ($selection) {
            "Import All Registry Entries" { 
                Write-Host "Will automatically import all registry entries" -ForegroundColor Green
                return "ImportAll" 
            }
            "Extract Only (Do Not Import)" { 
                Write-Host "Will extract registry files but not import them" -ForegroundColor Yellow
                return "ExtractOnly" 
            }
            "Manual Choice for Each Entry" { 
                Write-Host "Will ask for each registry entry individually" -ForegroundColor Cyan
                return "Manual" 
            }
            default { 
                return $null 
            }
        }
    }
    catch {
        Write-Log "Error with registry bulk action selection: $_" -Level "ERROR"
        return $null
    }
}

function Show-SelectiveRestorationMenu {
    param (
        [PSCustomObject]$Manifest,
        [string]$ExtractedPath
    )
    
    Write-Host "`nSelective Restoration:" -ForegroundColor Yellow
    Write-Host "=====================" -ForegroundColor Yellow
    
    # Group manifest entries by backup item
    $manifestSummary = Get-ManifestSummary -Manifest $Manifest
    $backupItems = $manifestSummary.BackupItems
    
    if ($backupItems.Count -eq 0) {
        Write-Host "No restorable items found in backup manifest." -ForegroundColor Red
        return @()
    }
    
    Write-Host "Available Backup Items:"
    foreach ($item in $backupItems.Keys) {
        $count = $backupItems[$item].count
        Write-Host "  • $item ($count files/items)" -ForegroundColor Cyan
    }
    Write-Host ""
    
    # Let user select backup items first
    $itemChoices = @("Select All Items") + ($backupItems.Keys | Sort-Object) + @("Cancel")
    
    try {
        $selectedItems = & gum choose --height=15 --no-limit --header="Select Backup Items to Restore (Space to select, Enter to confirm)" $itemChoices
        
        if (-not $selectedItems -or $selectedItems -contains "Cancel") {
            return @()
        }
        
        if ($selectedItems -contains "Select All Items") {
            $selectedItems = $backupItems.Keys
        }
    }
    catch {
        Write-Log "Error with item selection: $_" -Level "ERROR"
        return @()
    }
    
    # Now show granular selection for each selected item
    $itemsToRestore = @()
    
    foreach ($itemName in $selectedItems) {
        if ($itemName -eq "Select All Items") { continue }
        
        $itemFiles = $backupItems[$itemName].files
        
        Write-Host "`nFiles in '$itemName':" -ForegroundColor Green
        
        # Format files for selection
        $fileChoices = @()
        foreach ($file in $itemFiles) {
            $archivePath = $file.archive_relative_path
            $originalPath = $file.original_path
            $fileType = $file.file_type
            
            if ($fileType -eq "windows_settings") {
                $itemDisplayName = $file.windows_settings.item_name
                $exportType = $file.windows_settings.export_type
                $fileChoices += "[$exportType] $itemDisplayName -> $archivePath"
            } else {
                $fileChoices += "[$fileType] $originalPath -> $archivePath"
            }
        }
        
        if ($fileChoices.Count -gt 0) {
            $fileChoices = @("Select All from $itemName") + $fileChoices + @("Skip $itemName")
            
            try {
                $selectedFiles = & gum choose --height=20 --no-limit --header="Select files from '$itemName' to restore" $fileChoices
                
                if ($selectedFiles -and -not ($selectedFiles -contains "Skip $itemName")) {
                    if ($selectedFiles -contains "Select All from $itemName") {
                        $itemsToRestore += $itemFiles
                    } else {
                        # Map selected display strings back to manifest entries
                        foreach ($selectedFile in $selectedFiles) {
                            if ($selectedFile.StartsWith("[") -and $selectedFile -match "-> (.+)$") {
                                $archivePath = $matches[1]
                                $matchingFile = $itemFiles | Where-Object { $_.archive_relative_path -eq $archivePath }
                                if ($matchingFile) {
                                    $itemsToRestore += $matchingFile
                                }
                            }
                        }
                    }
                }
            }
            catch {
                Write-Log "Error with file selection for $itemName : $_" -Level "ERROR"
                continue
            }
        }
    }
    
    Write-Host "`nSelected $($itemsToRestore.Count) items for restoration." -ForegroundColor Green
    return $itemsToRestore
}

#endregion

#region Restoration Functions

function Restore-SelectedItems {
    param (
        [array]$ItemsToRestore,
        [string]$ExtractedPath,
        [string]$RestoreDestination,
        [bool]$IsOriginalLocation,
        [switch]$DryRun
    )
    
    if ($ItemsToRestore.Count -eq 0) {
        Write-Log "No items selected for restoration" -Level "WARNING"
        return
    }
    
    Write-Log "Starting restoration of $($ItemsToRestore.Count) items" -Level "INFO"
    
    # Check if there are registry items to be restored and get bulk action preference
    $registryItems = $ItemsToRestore | Where-Object { $_.file_type -eq "windows_settings" -and $_.windows_settings.export_type -eq "registry" }
    $script:RegistryBulkAction = "Manual" # Default to manual (current behavior)
    
    if ($registryItems.Count -gt 0) {
        $script:RegistryBulkAction = Show-RegistryBulkActionMenu -RegistryCount $registryItems.Count
        if (-not $script:RegistryBulkAction) {
            Write-Log "Registry bulk action cancelled by user" -Level "WARNING"
            return
        }
    }
    
    $totalItems = $ItemsToRestore.Count
    $currentItem = 0
    $restoredCount = 0
    $skippedCount = 0
    $failedCount = 0
    
    foreach ($item in $ItemsToRestore) {
        $currentItem++
        $percentComplete = [math]::Round(($currentItem / $totalItems) * 100)
        Show-Progress -PercentComplete $percentComplete -Status "Restoring item $currentItem of $totalItems"
        
        try {
            $result = Restore-SingleItem -Item $item -ExtractedPath $ExtractedPath -RestoreDestination $RestoreDestination -IsOriginalLocation $IsOriginalLocation -DryRun:$DryRun
            
            switch ($result) {
                "Success" { 
                    $restoredCount++
                    $script:RestoredItems += $item
                }
                "Skipped" { 
                    $skippedCount++
                }
                "Failed" { 
                    $failedCount++
                    $script:FailedItems += $item
                }
            }
        }
        catch {
            Write-Log "Error restoring item: $_" -Level "ERROR"
            $failedCount++
            $script:FailedItems += $item
        }
    }
    
    Write-Host "`n" # New line after progress
    
    # Show restoration summary
    Write-Host "`nRestoration Summary:" -ForegroundColor Yellow
    Write-Host "===================" -ForegroundColor Yellow
    Write-Host "Successfully restored: $restoredCount" -ForegroundColor Green
    Write-Host "Skipped: $skippedCount" -ForegroundColor Yellow
    Write-Host "Failed: $failedCount" -ForegroundColor Red
    Write-Host "Total processed: $totalItems" -ForegroundColor Cyan
}

function Restore-SingleItem {
    param (
        [PSCustomObject]$Item,
        [string]$ExtractedPath,
        [string]$RestoreDestination,
        [bool]$IsOriginalLocation,
        [switch]$DryRun
    )
    
    $archivePath = $Item.archive_relative_path
    $originalPath = $Item.original_path
    $fileType = $Item.file_type
    
    # FIXED: Find the actual file using the correct base directory
    $baseDir = if ($script:BackupBaseDir) { $script:BackupBaseDir } else { $ExtractedPath }
    $sourceFile = Join-Path $baseDir $archivePath
    $sourceFile = $sourceFile -replace '/', '\'
    
    if (-not (Test-Path $sourceFile)) {
        Write-Log "Source file not found at: $sourceFile" -Level "WARNING"
        Write-Log "Base directory: $baseDir, Archive path: $archivePath" -Level "DEBUG"
        
        # DEBUGGING: Try to find the file with alternate approaches
        $alternateSearch = Get-ChildItem -Path $baseDir -Filter (Split-Path $archivePath -Leaf) -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($alternateSearch) {
            Write-Log "Found file via search: $($alternateSearch.FullName)" -Level "DEBUG"
            $sourceFile = $alternateSearch.FullName
        } else {
            return "Failed"
        }
    }
    
    # Determine destination path
    if ($IsOriginalLocation) {
        $destinationPath = $originalPath
    } else {
        # Custom location - preserve directory structure
        $relativePath = $originalPath
        if ($relativePath.Length -gt 3 -and $relativePath[1] -eq ':') {
            # Remove drive letter (C:\ becomes \)
            $relativePath = $relativePath.Substring(2)
        }
        $destinationPath = Join-Path $RestoreDestination $relativePath
    }
    
    # Handle different file types
    switch ($fileType) {
        "file" {
            return Restore-RegularFile -SourceFile $sourceFile -DestinationPath $destinationPath -DryRun:$DryRun
        }
        "folder" {
            return Restore-Folder -SourceFolder $sourceFile -DestinationPath $destinationPath -DryRun:$DryRun
        }
        "windows_settings" {
            return Restore-WindowsSettingsItem -Item $Item -SourceFile $sourceFile -DestinationPath $destinationPath -IsOriginalLocation $IsOriginalLocation -DryRun:$DryRun
        }
        "special" {
            return Restore-SpecialItem -Item $Item -SourceFile $sourceFile -DestinationPath $destinationPath -DryRun:$DryRun
        }
        default {
            Write-Log "Unknown file type: $fileType" -Level "WARNING"
            return "Skipped"
        }
    }
}

function Restore-RegularFile {
    param (
        [string]$SourceFile,
        [string]$DestinationPath,
        [switch]$DryRun
    )
    
    if ($DryRun) {
        Write-Log "DRY RUN: Would restore file $SourceFile -> $DestinationPath" -Level "INFO"
        return "Success"
    }
    
    # FIXED: Check if this is a placeholder file (0-1 bytes) for regular files too
    if (Test-Path $SourceFile) {
        $fileInfo = Get-Item $SourceFile
        if ($fileInfo.Length -le 1) {
            Write-Log "Detected placeholder file (size: $($fileInfo.Length) bytes) - skipping: $SourceFile" -Level "INFO"
            Write-Host "Skipping placeholder file: $(Split-Path $SourceFile -Leaf)" -ForegroundColor Yellow
            return "Skipped"
        }
    }
    
    try {
        # Create destination directory if needed
        $destinationDir = Split-Path $DestinationPath -Parent
        if (-not (Test-Path $destinationDir)) {
            New-Item -ItemType Directory -Path $destinationDir -Force | Out-Null
        }
        
        # Handle file conflicts
        if (Test-Path $DestinationPath) {
            $conflict = Show-FileConflictDialog -ExistingFile $DestinationPath -NewFile $SourceFile
            switch ($conflict) {
                "Skip" { 
                    Write-Log "Skipped due to user choice: $DestinationPath" -Level "INFO"
                    return "Skipped" 
                }
                "Rename" {
                    $timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
                    $directory = Split-Path $DestinationPath -Parent
                    $filename = Split-Path $DestinationPath -LeafBase
                    $extension = Split-Path $DestinationPath -Extension
                    $DestinationPath = Join-Path $directory "${filename}_restored_${timestamp}${extension}"
                }
                # "Overwrite" - continue with original path
            }
        }
        
        # Copy the file
        Copy-Item -Path $SourceFile -Destination $DestinationPath -Force
        Write-Log "Restored file: $DestinationPath" -Level "INFO"
        return "Success"
    }
    catch {
        Write-Log "Failed to restore file $SourceFile to $DestinationPath : $_" -Level "ERROR"
        return "Failed"
    }
}

function Restore-Folder {
    param (
        [string]$SourceFolder,
        [string]$DestinationPath,
        [switch]$DryRun
    )
    
    if ($DryRun) {
        Write-Log "DRY RUN: Would restore folder $SourceFolder -> $DestinationPath" -Level "INFO"
        return "Success"
    }
    
    try {
        if (-not (Test-Path $DestinationPath)) {
            New-Item -ItemType Directory -Path $DestinationPath -Force | Out-Null
        }
        
        Copy-Item -Path "$SourceFolder\*" -Destination $DestinationPath -Recurse -Force
        Write-Log "Restored folder: $DestinationPath" -Level "INFO"
        return "Success"
    }
    catch {
        Write-Log "Failed to restore folder $SourceFolder to $DestinationPath : $_" -Level "ERROR"
        return "Failed"
    }
}

function Restore-WindowsSettingsItem {
    param (
        [PSCustomObject]$Item,
        [string]$SourceFile,
        [string]$DestinationPath,
        [bool]$IsOriginalLocation,
        [switch]$DryRun
    )
    
    $exportType = $Item.windows_settings.export_type
    $itemName = $Item.windows_settings.item_name
    
    switch ($exportType) {
        "registry" {
            # For registry files, use the original filename from archive, not the registry key path
            $originalFileName = Split-Path $Item.archive_relative_path -Leaf
            
            if ($IsOriginalLocation) {
                # For "original location" registry files, put them in a Registry folder in user's Downloads
                $registryRestoreDir = Join-Path ([Environment]::GetFolderPath("UserProfile")) "Downloads\Restored_Registry"
                $finalDestinationPath = Join-Path $registryRestoreDir $originalFileName
            } else {
                # For custom location, put them in a Registry subfolder
                $registryRestoreDir = Join-Path $DestinationPath "Registry"
                $finalDestinationPath = Join-Path $registryRestoreDir $originalFileName
            }
            
            return Restore-RegistryFile -RegistryFile $SourceFile -ItemName $itemName -DestinationPath $finalDestinationPath -DryRun:$DryRun
        }
        default {
            # Handle as regular file for other Windows Settings items
            return Restore-RegularFile -SourceFile $SourceFile -DestinationPath $DestinationPath -DryRun:$DryRun
        }
    }
}

function Restore-RegistryFile {
    param (
        [string]$RegistryFile,
        [string]$ItemName,
        [string]$DestinationPath,
        [switch]$DryRun
    )
    
    if ($DryRun) {
        Write-Log "DRY RUN: Would extract registry file $RegistryFile to $DestinationPath" -Level "INFO"
        return "Success"
    }
    
    # FIXED: Always extract the registry file to destination first
    try {
        # Create destination directory if needed
        $destinationDir = Split-Path $DestinationPath -Parent
        if (-not (Test-Path $destinationDir)) {
            New-Item -ItemType Directory -Path $destinationDir -Force | Out-Null
        }
        
        # Copy the registry file to the restore destination
        Copy-Item -Path $RegistryFile -Destination $DestinationPath -Force
        Write-Log "Registry file extracted to: $DestinationPath" -Level "INFO"
    }
    catch {
        Write-Log "Failed to extract registry file: $_" -Level "ERROR"
        return "Failed"
    }
    
    # Handle registry import based on bulk action choice
    $importDecision = $null
    
    # Check if we have a bulk action preference
    if ((Get-Variable -Name "RegistryBulkAction" -Scope Script -ErrorAction SilentlyContinue) -and $script:RegistryBulkAction) {
        switch ($script:RegistryBulkAction) {
            "ImportAll" {
                Write-Host "Auto-importing registry file: $ItemName" -ForegroundColor Green
                $importDecision = "Import"
            }
            "ExtractOnly" {
                Write-Host "Skipping import for registry file: $ItemName (extract only mode)" -ForegroundColor Yellow
                $importDecision = "Skip"
            }
            "Manual" {
                # Fall through to manual dialog below
                $importDecision = $null
            }
        }
    }
    
    # If no bulk decision, show individual dialog (Manual mode or no bulk choice set)
    if (-not $importDecision) {
        # Show registry file details
        Write-Host "`nRegistry File Extracted:" -ForegroundColor Yellow
        Write-Host "========================" -ForegroundColor Yellow
        Write-Host "Item: $ItemName" -ForegroundColor Cyan
        Write-Host "Extracted to: $DestinationPath" -ForegroundColor Green
        Write-Host "Original file: $RegistryFile" -ForegroundColor Cyan
        
        # Show first few lines of the registry file
        if (Test-Path $RegistryFile) {
            Write-Host "`nRegistry File Preview:" -ForegroundColor Gray
            $content = Get-Content $RegistryFile -TotalCount 10
            foreach ($line in $content) {
                Write-Host "  $line" -ForegroundColor Gray
            }
            if ((Get-Content $RegistryFile).Count -gt 10) {
                Write-Host "  ... (file continues)" -ForegroundColor Gray
            }
        }
        
        # Get user decision about registry import
        $choices = @(
            "Import to Registry Now",
            "Skip Registry Import (file already extracted)"
        )
        
        try {
            $decision = & gum choose --height=6 --header="Registry File: $ItemName (already extracted)" $choices
            
            switch ($decision) {
                "Import to Registry Now" {
                    $importDecision = "Import"
                }
                default {
                    $importDecision = "Skip"
                }
            }
        }
        catch {
            Write-Log "Error with registry file dialog: $_" -Level "ERROR"
            $importDecision = "Skip"  # Default to skip on error
        }
    }
    
    # Execute the import decision
    if ($importDecision -eq "Import") {
        try {
            & regedit.exe /s $RegistryFile
            if ($LASTEXITCODE -eq 0) {
                Write-Log "Successfully imported registry file: $RegistryFile" -Level "INFO"
                return "Success"
            } else {
                Write-Log "Registry import failed with exit code: $LASTEXITCODE" -Level "ERROR"
                Write-Log "Registry file still available at: $DestinationPath" -Level "INFO"
                return "Success"  # File was extracted successfully even if import failed
            }
        }
        catch {
            Write-Log "Error importing registry file: $_" -Level "ERROR"
            Write-Log "Registry file still available at: $DestinationPath" -Level "INFO"
            return "Success"  # File was extracted successfully even if import failed
        }
    } else {
        Write-Log "Registry import skipped. File available at: $DestinationPath" -Level "INFO"
        return "Success"  # File was extracted successfully
    }
}

function Restore-SpecialItem {
    param (
        [PSCustomObject]$Item,
        [string]$SourceFile,
        [string]$DestinationPath,
        [switch]$DryRun
    )
    
    $itemType = $Item.special_handling.item_type
    
    Write-Log "Restoring special item: $itemType" -Level "INFO"
    
    # FIXED: Check if this is a placeholder file (0-1 bytes)
    if (Test-Path $SourceFile) {
        $fileInfo = Get-Item $SourceFile
        if ($fileInfo.Length -le 1) {
            Write-Log "Detected placeholder file for $itemType (size: $($fileInfo.Length) bytes) - skipping restoration" -Level "INFO"
            Write-Host "Skipping $itemType - was empty/non-existent during backup" -ForegroundColor Yellow
            return "Skipped"
        }
    }
    
    # Handle special items properly based on their type
    switch ($itemType) {
        "DoskeyMacros" {
            # DoskeyMacros should be extracted as regular file
            return Restore-RegularFile -SourceFile $SourceFile -DestinationPath $DestinationPath -DryRun:$DryRun
        }
        "Certificates" {
            # Certificates should be extracted as regular file
            return Restore-RegularFile -SourceFile $SourceFile -DestinationPath $DestinationPath -DryRun:$DryRun
        }
        "WindowsCredentials" {
            # WindowsCredentials should be extracted as regular file
            return Restore-RegularFile -SourceFile $SourceFile -DestinationPath $DestinationPath -DryRun:$DryRun
        }
        default {
            # For any other special items, treat as regular files
            return Restore-RegularFile -SourceFile $SourceFile -DestinationPath $DestinationPath -DryRun:$DryRun
        }
    }
}

function Show-FileConflictDialog {
    param (
        [string]$ExistingFile,
        [string]$NewFile
    )
    
    Write-Host "`nFile Conflict:" -ForegroundColor Yellow
    Write-Host "==============" -ForegroundColor Yellow
    Write-Host "A file already exists at the destination:" -ForegroundColor Yellow
    Write-Host "  $ExistingFile" -ForegroundColor Cyan
    
    # Show file details
    if (Test-Path $ExistingFile) {
        $existingInfo = Get-Item $ExistingFile
        Write-Host "`nExisting file:" -ForegroundColor Gray
        Write-Host "  Size: $($existingInfo.Length) bytes" -ForegroundColor Gray
        Write-Host "  Modified: $($existingInfo.LastWriteTime)" -ForegroundColor Gray
    }
    
    if (Test-Path $NewFile) {
        $newInfo = Get-Item $NewFile
        Write-Host "`nNew file from backup:" -ForegroundColor Gray
        Write-Host "  Size: $($newInfo.Length) bytes" -ForegroundColor Gray
        Write-Host "  Modified: $($newInfo.LastWriteTime)" -ForegroundColor Gray
    }
    
    $choices = @(
        "Overwrite existing file",
        "Skip this file",
        "Rename restored file"
    )
    
    try {
        $decision = & gum choose --height=8 --header="File Conflict Resolution" $choices
        
        switch ($decision) {
            "Overwrite existing file" { return "Overwrite" }
            "Skip this file" { return "Skip" }
            "Rename restored file" { return "Rename" }
            default { return "Skip" }
        }
    }
    catch {
        Write-Log "Error with file conflict dialog: $_" -Level "ERROR"
        return "Skip"
    }
}

#endregion

#region Main Restoration Workflow

function Start-RestoreWorkflow {
    param (
        [int]$SpecificBackupId = 0
    )
    
    Write-Host "Starting Backup Restoration Workflow..." -ForegroundColor Green
    
    # Clear previous state
    $script:BackupBaseDir = $null
    $script:RestoredItems = @()
    $script:FailedItems = @()
    
    # Step 1: Select backup
    if ($SpecificBackupId -gt 0) {
        $script:SelectedBackup = Get-BackupById -Id $SpecificBackupId
        if (-not $script:SelectedBackup) {
            Write-Host "Backup with ID $SpecificBackupId not found." -ForegroundColor Red
            return
        }
    } else {
        $availableBackups = Get-AvailableBackups
        $script:SelectedBackup = Show-BackupSelectionMenu -Backups $availableBackups
        if (-not $script:SelectedBackup) {
            Write-Host "No backup selected. Restoration cancelled." -ForegroundColor Yellow
            return
        }
    }
    
    Write-Host "`nSelected backup: $($script:SelectedBackup.BackupSetName)" -ForegroundColor Green
    
    # Step 2: Extract backup and read manifest - FIXED: Use simple, consistent temp path
    $script:TempRestoreDir = Get-SimpleRestoreDirectory -BackupName $script:SelectedBackup.BackupSetName
    
    if (-not (Extract-BackupArchive -Backup $script:SelectedBackup -TempDirectory $script:TempRestoreDir)) {
        Write-Host "Failed to extract backup archive." -ForegroundColor Red
        return
    }
    
    $manifestPath = Find-ManifestInExtraction -ExtractedPath $script:TempRestoreDir
    if ($manifestPath) {
        $script:BackupManifest = Read-BackupManifest -ManifestPath $manifestPath
        if (-not $script:BackupManifest) {
            Write-Host "Failed to read backup manifest." -ForegroundColor Red
            return
        } else {
            Write-Log "Successfully loaded manifest with $($script:BackupManifest.backup_info.total_entries) entries" -Level "INFO"
        }
    } else {
        Write-Host "This backup doesn't have a manifest file." -ForegroundColor Yellow
        Write-Host "Only complete restoration is available." -ForegroundColor Yellow
        # For backups without manifest, we can still do basic restoration
    }
    
    # Step 3: Choose restoration mode
    $restoreMode = if ($RestoreMode -eq "Selective" -and $script:BackupManifest) {
        "Selective"
    } elseif ($RestoreMode -eq "Interactive") {
        Show-RestoreModeMenu
    } else {
        "Complete"
    }
    
    if (-not $restoreMode) {
        Write-Host "Restoration cancelled." -ForegroundColor Yellow
        return
    }
    
    # Step 4: Choose destination
    $destination = if ($RestoreDestination) {
        $RestoreDestination
    } else {
        Show-DestinationMenu
    }
    
    if (-not $destination) {
        Write-Host "Restoration cancelled." -ForegroundColor Yellow
        return
    }
    
    $isOriginalLocation = ($destination -eq "Original")
    
    # Step 5: Select items (if selective mode)
    $itemsToRestore = @()
    
    if ($restoreMode -eq "Selective" -and $script:BackupManifest) {
        $itemsToRestore = Show-SelectiveRestorationMenu -Manifest $script:BackupManifest -ExtractedPath $script:TempRestoreDir
        if ($itemsToRestore.Count -eq 0) {
            Write-Host "No items selected for restoration." -ForegroundColor Yellow
            return
        }
    } else {
        # Complete restoration - restore everything
        if ($script:BackupManifest) {
            $itemsToRestore = $script:BackupManifest.backup_manifest.PSObject.Properties | ForEach-Object { $_.Value }
        } else {
            # Fallback for backups without manifest
            Write-Host "Performing complete restoration without manifest..." -ForegroundColor Yellow
            # This would need different logic to handle legacy backups
        }
    }
    
    # Step 6: Perform restoration
    if ($itemsToRestore.Count -gt 0) {
        Restore-SelectedItems -ItemsToRestore $itemsToRestore -ExtractedPath $script:TempRestoreDir -RestoreDestination $destination -IsOriginalLocation $isOriginalLocation -DryRun:$DryRun
    }
    
    # Step 7: Show final summary
    Show-FinalSummary
}

function Show-FinalSummary {
    Write-Host "`n" + ("="*60) -ForegroundColor Green
    Write-Host "RESTORATION COMPLETED" -ForegroundColor Green
    Write-Host ("="*60) -ForegroundColor Green
    
    Write-Host "`nBackup: $($script:SelectedBackup.BackupSetName)" -ForegroundColor Cyan
    Write-Host "Type: $($script:SelectedBackup.BackupType)" -ForegroundColor Cyan
    Write-Host "Created: $($script:SelectedBackup.Timestamp)" -ForegroundColor Cyan
    
    if ($script:RestoredItems.Count -gt 0) {
        Write-Host "`nSuccessfully Restored Items:" -ForegroundColor Green
        foreach ($item in $script:RestoredItems | Select-Object -First 10) {
            $displayPath = if ($item.original_path) { $item.original_path } else { $item.archive_relative_path }
            Write-Host "  ✓ $displayPath" -ForegroundColor Green
        }
        if ($script:RestoredItems.Count -gt 10) {
            Write-Host "  ... and $($script:RestoredItems.Count - 10) more items" -ForegroundColor Green
        }
    }
    
    if ($script:FailedItems.Count -gt 0) {
        Write-Host "`nFailed Items:" -ForegroundColor Red
        foreach ($item in $script:FailedItems) {
            $displayPath = if ($item.original_path) { $item.original_path } else { $item.archive_relative_path }
            Write-Host "  ✗ $displayPath" -ForegroundColor Red
        }
    }
    
    Write-Host "`nRestore operation completed!" -ForegroundColor Green
}

#endregion

#region Cleanup

function Cleanup-TempFiles {
    if ($script:TempRestoreDir -and (Test-Path $script:TempRestoreDir)) {
        try {
            Remove-Item -Path $script:TempRestoreDir -Recurse -Force
            Write-Log "Cleaned up temporary files: $script:TempRestoreDir" -Level "INFO"
        }
        catch {
            Write-Log "Failed to clean up temporary files: $_" -Level "WARNING"
        }
    }
}

#endregion

#region Main Script Execution

# Initialize
try {
    # Load configuration
    if (Test-Path $ConfigFile) {
        $script:Config = Parse-ConfigFile -ConfigFilePath $ConfigFile
    } else {
        Write-Host "Configuration file not found: $ConfigFile" -ForegroundColor Red
        exit 1
    }
    
    # Initialize logging
    Initialize-Logging -LogLevel $LogLevel -LogFilePath $script:Config.Logging.LogFilePath
    
    Write-Log "=== Starting Backup Restoration ===" -Level "INFO"
    
    # Check dependencies
    Check-Dependencies -Config $script:Config
    
    # Start restoration workflow
    Start-RestoreWorkflow -SpecificBackupId $BackupId
}
catch {
    Write-Host "Error during restoration: $_" -ForegroundColor Red
    Write-Log "Restoration failed: $_" -Level "ERROR"
    exit 1
}
finally {
    Cleanup-TempFiles
    Write-Log "=== Backup Restoration Finished ===" -Level "INFO"
}

#endregion