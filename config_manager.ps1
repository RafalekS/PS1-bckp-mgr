#Requires -Version 5.1

<#
.SYNOPSIS
    Backup Configuration Manager
    
.DESCRIPTION
    Comprehensive tool for managing backup configurations, backup items, backup types,
    and folder categorization. Automatically modifies main.ps1 when needed.
    
.NOTES
    Version: 1.0
    Requires: gum.exe, backup_config.json, main.ps1
#>

param(
    [Parameter(Mandatory=$false)]
    [string]$ConfigPath = "config\bkp_cfg.json",
    
    [Parameter(Mandatory=$false)]
    [string]$MainScriptPath = "main.ps1"
)

# Global variables
$script:Config = $null
$script:ConfigBackupDir = "backup\config"
$script:OriginalTitle = $Host.UI.RawUI.WindowTitle

function Initialize-ConfigManager {
    # Set window title
    $Host.UI.RawUI.WindowTitle = "Backup Configuration Manager"
    
    # Clear screen
    Clear-Host
    
    # Ensure backup directory exists
    if (-not (Test-Path $script:ConfigBackupDir)) {
        New-Item -ItemType Directory -Path $script:ConfigBackupDir -Force | Out-Null
    }
    
    # Load configuration
    if (-not (Test-Path $ConfigPath)) {
        Write-Host "Configuration file not found: $ConfigPath" -ForegroundColor Red
        Read-Host "Press Enter to exit"
        exit 1
    }
    
    try {
        $script:Config = Get-Content $ConfigPath -Raw | ConvertFrom-Json
        Show-Banner
    }
    catch {
        Write-Host "Error loading configuration: $_" -ForegroundColor Red
        Read-Host "Press Enter to exit"
        exit 1
    }
}

function Show-Banner {
    Clear-Host
    Write-Host @"

╔══════════════════════════════════════════════════════════════╗
║               🔧 BACKUP CONFIGURATION MANAGER 🔧             ║
║                                                              ║
║  Manage backup items, types, and folder categorization       ║
║  Auto-updates main.ps1 when folder assignments change       ║
╚══════════════════════════════════════════════════════════════╝

"@ -ForegroundColor Cyan
}

function Show-MainMenu {
    $options = @(
        "View Current Configuration",
        "Manage Backup Items",
        "Manage Backup Types", 
        "Manage Folder Categorization",
        "Special Handling",
        "Configuration Tools",
        "Exit"
    )
    
    gum choose --height=15 --header "Configuration Manager - Main Menu" $options
}

function Show-BackupItemsMenu {
    $options = @(
        "Add New Item Category",
        "Edit Existing Item", 
        "Delete Item Category",
        "Add Paths to Existing Item",
        "View All Items",
        "Go Back"
    )
    
    gum choose --height=15 --header "Manage Backup Items" $options
}

function Show-BackupTypesMenu {
    $options = @(
        "Create New Backup Type",
        "Edit Existing Backup Type",
        "Delete Backup Type",
        "View All Backup Types", 
        "Go Back"
    )
    
    gum choose --height=10 --header "Manage Backup Types" $options
}

function Show-FolderCategorizationMenu {
    $options = @(
        "View Current Folder Mapping",
        "Move Items Between Folders",
        "Rename Folder Category",
        "Create New Folder Category",
        "View main.ps1 Categorization Code",
        "Go Back"
    )
    
    gum choose --height=15 --header "Manage Folder Categorization" $options
}

function Show-SpecialHandlingMenu {
    $options = @(
        "View Current Special Items",
        "Generate Code for New Special Item",
        "Go Back"
    )
    
    gum choose --height=10 --header "Special Handling" $options
}

function Show-ConfigToolsMenu {
    $options = @(
        "Validate Configuration", 
        "Backup Current Config",
        "Restore Config Backup",
        "View Config Backups",
        "Go Back"
    )
    
    gum choose --height=10 --header "Configuration Tools" $options
}

#region Configuration Backup/Restore

function Backup-Configuration {
    $timestamp = Get-Date -Format "yyyyMMdd-HHmmss"
    $backupName = "bkp_cfg_$timestamp.json"
    $backupPath = Join-Path $script:ConfigBackupDir $backupName
    
    try {
        Copy-Item $ConfigPath $backupPath -Force
        Write-Host "Configuration backed up to: $backupPath" -ForegroundColor Green
        return $backupPath
    }
    catch {
        Write-Host "Error backing up configuration: $_" -ForegroundColor Red
        return $null
    }
}

function Restore-Configuration {
    $backupFiles = Get-ChildItem -Path $script:ConfigBackupDir -Filter "bkp_cfg_*.json" | Sort-Object LastWriteTime -Descending
    
    if ($backupFiles.Count -eq 0) {
        gum style --foreground 196 "No configuration backups found."
        Read-Host "Press Enter to continue"
        return
    }
    
    $formattedBackups = $backupFiles | ForEach-Object { 
        "$($_.Name) - $($_.LastWriteTime.ToString('yyyy-MM-dd HH:mm:ss'))"
    }
    $formattedBackups = @("Cancel") + $formattedBackups
    
    $selected = gum choose --height=15 --header "Select Configuration Backup to Restore" $formattedBackups
    
    if ($selected -eq "Cancel") { return }
    
    $backupFileName = ($selected -split " - ")[0]
    $backupPath = Join-Path $script:ConfigBackupDir $backupFileName
    
    gum confirm "Are you sure you want to restore this backup? Current config will be overwritten."
    if ($LASTEXITCODE -ne 0) { return }
    
    try {
        # Backup current config first
        Backup-Configuration | Out-Null
        
        # Restore selected backup
        Copy-Item $backupPath $ConfigPath -Force
        $script:Config = Get-Content $ConfigPath -Raw | ConvertFrom-Json
        
        Write-Host "Configuration restored successfully from: $backupFileName" -ForegroundColor Green
        Read-Host "Press Enter to continue"
    }
    catch {
        Write-Host "Error restoring configuration: $_" -ForegroundColor Red
        Read-Host "Press Enter to continue"
    }
}

function View-ConfigBackups {
    $backupFiles = Get-ChildItem -Path $script:ConfigBackupDir -Filter "bkp_cfg_*.json" | Sort-Object LastWriteTime -Descending
    
    if ($backupFiles.Count -eq 0) {
        gum style --foreground 196 "No configuration backups found."
    }
    else {
        Write-Host "`nConfiguration Backup History:" -ForegroundColor Yellow
        Write-Host "==============================" -ForegroundColor Yellow
        
        foreach ($backup in $backupFiles) {
            $size = [math]::Round($backup.Length / 1KB, 2)
            Write-Host "$($backup.Name)" -ForegroundColor Cyan
            Write-Host "  Created: $($backup.LastWriteTime.ToString('yyyy-MM-dd HH:mm:ss'))" -ForegroundColor Gray
            Write-Host "  Size: $size KB" -ForegroundColor Gray
            Write-Host ""
        }
    }
    
    Read-Host "Press Enter to continue"
}

#endregion

#region View Configuration

function View-CurrentConfiguration {
    Clear-Host
    Write-Host "Current Backup Configuration" -ForegroundColor Yellow
    Write-Host "============================" -ForegroundColor Yellow
    
    Write-Host "`nBackup Items:" -ForegroundColor Cyan
    $backupItems = $script:Config.BackupItems.PSObject.Properties | Sort-Object Name
    foreach ($item in $backupItems) {
        if ($item.Name -notlike "_comment*") {
            Write-Host "  $($item.Name):" -ForegroundColor White
            if ($item.Value -is [Array]) {
                foreach ($path in $item.Value) {
                    $exists = Test-Path $path
                    $status = if ($exists) { "✓" } else { "✗" }
                    $color = if ($exists) { "Green" } else { "Red" }
                    Write-Host "    $status $path" -ForegroundColor $color
                }
            }
            elseif ($item.Value.type -eq "windows_settings") {
                Write-Host "    [Windows Settings Category]" -ForegroundColor Magenta
                Write-Host "    Items: $($item.Value.items.Count)" -ForegroundColor Gray
            }
            else {
                Write-Host "    $($item.Value)" -ForegroundColor Gray
            }
            Write-Host ""
        }
    }
    
    Write-Host "Backup Types:" -ForegroundColor Cyan
    $backupTypes = $script:Config.BackupTypes.PSObject.Properties | Sort-Object Name
    foreach ($type in $backupTypes) {
        Write-Host "  $($type.Name): " -NoNewline -ForegroundColor White
        Write-Host ($type.Value -join ", ") -ForegroundColor Gray
    }
    
    Read-Host "`nPress Enter to continue"
}

#endregion

#region Backup Items Management

function Add-NewItemCategory {
    Clear-Host
    Write-Host "Add New Backup Item Category" -ForegroundColor Yellow
    Write-Host "============================" -ForegroundColor Yellow
    
    Write-Host @"

Instructions:
• Enter a unique name for your backup item category
• Use PascalCase (e.g., MyDocuments, GameSaves, etc.)
• Avoid spaces and special characters
• This will be used in backup types and folder categorization

"@ -ForegroundColor Gray
    
    $categoryName = gum input --placeholder "Enter category name (e.g., Import, Databases, etc.)"
    if ([string]::IsNullOrWhiteSpace($categoryName)) { return }
    
    # Check if category already exists
    if ($script:Config.BackupItems.PSObject.Properties.Name -contains $categoryName) {
        gum style --foreground 196 "Category '$categoryName' already exists!"
        Read-Host "Press Enter to continue"
        return
    }
    
    Clear-Host
    Write-Host "Add Paths to '$categoryName'" -ForegroundColor Yellow
    Write-Host "============================" -ForegroundColor Yellow
    
    Write-Host @"

Instructions:
• Enter one or more file/folder paths for this category
• Enter each path on a separate line
• Use full paths (e.g., C:\MyFolder\file.txt)
• Environment variables are supported (e.g., %USERPROFILE%\Documents)
• Press Ctrl+D when finished entering paths

Examples:
C:\MyApp\config.xml
C:\Users\%USERNAME%\AppData\Local\MyApp
D:\Databases\mydb.sqlite

"@ -ForegroundColor Gray
    
    $pathsInput = gum write --placeholder "Enter paths (one per line)..."
    if ([string]::IsNullOrWhiteSpace($pathsInput)) { return }
    
    $paths = $pathsInput.Split("`n") | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne "" }
    
    if ($paths.Count -eq 0) {
        gum style --foreground 196 "No valid paths entered!"
        Read-Host "Press Enter to continue"
        return
    }
    
    # Validate paths
    Clear-Host
    Write-Host "Path Validation Results:" -ForegroundColor Yellow
    Write-Host "=======================" -ForegroundColor Yellow
    
    $validPaths = @()
    $warnings = @()
    
    foreach ($path in $paths) {
        $expandedPath = [System.Environment]::ExpandEnvironmentVariables($path)
        $exists = Test-Path $expandedPath
        $status = if ($exists) { "✓ EXISTS" } else { "✗ NOT FOUND" }
        $color = if ($exists) { "Green" } else { "Yellow" }
        
        Write-Host "$status $path" -ForegroundColor $color
        $validPaths += $path
        
        if (-not $exists) {
            $warnings += $path
        }
    }
    
    if ($warnings.Count -gt 0) {
        Write-Host "`nWarning: $($warnings.Count) path(s) do not currently exist." -ForegroundColor Yellow
        Write-Host "You can still save them - they may be created later." -ForegroundColor Gray
    }
    
    Write-Host "`nProposed Addition:" -ForegroundColor Cyan
    Write-Host "`"$categoryName`": [" -ForegroundColor White
    foreach ($path in $validPaths) {
        Write-Host "  `"$path`"," -ForegroundColor Gray
    }
    Write-Host "]" -ForegroundColor White
    
    gum confirm "Add this backup item category?"
    if ($LASTEXITCODE -ne 0) { return }
    
    # Backup configuration first
    $backupPath = Backup-Configuration
    if (-not $backupPath) { return }
    
    try {
        # Add new category
        $script:Config.BackupItems | Add-Member -NotePropertyName $categoryName -NotePropertyValue $validPaths
        
        # Save configuration
        $script:Config | ConvertTo-Json -Depth 10 | Set-Content $ConfigPath -Encoding UTF8
        
        Write-Host "`nBackup item category '$categoryName' added successfully!" -ForegroundColor Green
        Write-Host "Configuration backed up to: $(Split-Path $backupPath -Leaf)" -ForegroundColor Gray
        
        # Ask about folder categorization
        gum confirm "Would you like to set up folder categorization for this item now?"
        if ($LASTEXITCODE -eq 0) {
            Set-FolderCategorization -ItemName $categoryName
        }
    }
    catch {
        Write-Host "Error adding backup item: $_" -ForegroundColor Red
    }
    
    Read-Host "Press Enter to continue"
}

function Edit-ExistingItem {
    $items = $script:Config.BackupItems.PSObject.Properties | Where-Object { $_.Name -notlike "_comment*" } | Sort-Object Name
    
    if ($items.Count -eq 0) {
        gum style --foreground 196 "No backup items found to edit."
        Read-Host "Press Enter to continue"
        return
    }
    
    $itemNames = @("Cancel") + ($items | ForEach-Object { $_.Name })
    $selected = gum choose --height=15 --header "Select Backup Item to Edit" $itemNames
    
    if ($selected -eq "Cancel") { return }
    
    $selectedItem = $items | Where-Object { $_.Name -eq $selected }
    
    # Handle Windows Settings items differently
    if ($selectedItem.Value.type -eq "windows_settings") {
        gum style --foreground 196 "Windows Settings items cannot be edited through this interface."
        gum style --foreground 212 "Please edit the JSON configuration directly for Windows Settings categories."
        Read-Host "Press Enter to continue"
        return
    }
    
    Clear-Host
    Write-Host "Edit Backup Item: $selected" -ForegroundColor Yellow
    Write-Host "=========================" -ForegroundColor Yellow
    
    Write-Host "`nCurrent paths:" -ForegroundColor Cyan
    $currentPaths = $selectedItem.Value
    for ($i = 0; $i -lt $currentPaths.Count; $i++) {
        $exists = Test-Path ([System.Environment]::ExpandEnvironmentVariables($currentPaths[$i]))
        $status = if ($exists) { "✓" } else { "✗" }
        $color = if ($exists) { "Green" } else { "Red" }
        Write-Host "  $($i + 1). $status $($currentPaths[$i])" -ForegroundColor $color
    }
    
    Write-Host @"

Instructions:
• Enter the new complete list of paths for this category
• Enter each path on a separate line  
• This will REPLACE the current paths entirely
• Press Ctrl+D when finished

"@ -ForegroundColor Gray
    
    $newPathsInput = gum write --placeholder "Enter new paths (one per line)..." --value ($currentPaths -join "`n")
    if ([string]::IsNullOrWhiteSpace($newPathsInput)) { return }
    
    $newPaths = $newPathsInput.Split("`n") | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne "" }
    
    if ($newPaths.Count -eq 0) {
        gum style --foreground 196 "No valid paths entered!"
        Read-Host "Press Enter to continue"
        return
    }
    
    # Validate and show changes
    Clear-Host
    Write-Host "Changes Preview:" -ForegroundColor Yellow
    Write-Host "================" -ForegroundColor Yellow
    
    Write-Host "`nNew paths:" -ForegroundColor Cyan
    foreach ($path in $newPaths) {
        $expandedPath = [System.Environment]::ExpandEnvironmentVariables($path)
        $exists = Test-Path $expandedPath
        $status = if ($exists) { "✓" } else { "✗" }
        $color = if ($exists) { "Green" } else { "Yellow" }
        Write-Host "  $status $path" -ForegroundColor $color
    }
    
    gum confirm "Save these changes?"
    if ($LASTEXITCODE -ne 0) { return }
    
    # Backup and save
    $backupPath = Backup-Configuration
    if (-not $backupPath) { return }
    
    try {
        $script:Config.BackupItems.$selected = $newPaths
        $script:Config | ConvertTo-Json -Depth 10 | Set-Content $ConfigPath -Encoding UTF8
        
        Write-Host "`nBackup item '$selected' updated successfully!" -ForegroundColor Green
        Write-Host "Configuration backed up to: $(Split-Path $backupPath -Leaf)" -ForegroundColor Gray
    }
    catch {
        Write-Host "Error updating backup item: $_" -ForegroundColor Red
    }
    
    Read-Host "Press Enter to continue"
}

function Add-PathsToExistingItem {
    $items = $script:Config.BackupItems.PSObject.Properties | Where-Object { $_.Name -notlike "_comment*" -and $_.Value.type -ne "windows_settings" } | Sort-Object Name
    
    if ($items.Count -eq 0) {
        gum style --foreground 196 "No editable backup items found."
        Read-Host "Press Enter to continue"
        return
    }
    
    $itemNames = @("Cancel") + ($items | ForEach-Object { $_.Name })
    $selected = gum choose --height=15 --header "Select Backup Item to Add Paths To" $itemNames
    
    if ($selected -eq "Cancel") { return }
    
    $selectedItem = $items | Where-Object { $_.Name -eq $selected }
    
    Clear-Host
    Write-Host "Add Paths to: $selected" -ForegroundColor Yellow
    Write-Host "=====================" -ForegroundColor Yellow
    
    Write-Host "`nCurrent paths:" -ForegroundColor Cyan
    $currentPaths = $selectedItem.Value
    foreach ($path in $currentPaths) {
        $exists = Test-Path ([System.Environment]::ExpandEnvironmentVariables($path))
        $status = if ($exists) { "✓" } else { "✗" }
        $color = if ($exists) { "Green" } else { "Red" }
        Write-Host "  $status $path" -ForegroundColor $color
    }
    
    Write-Host @"

Instructions:
• Enter additional paths to add to this category
• Enter each path on a separate line
• These will be ADDED to the existing paths
• Press Ctrl+D when finished

"@ -ForegroundColor Gray
    
    $additionalPathsInput = gum write --placeholder "Enter additional paths (one per line)..."
    if ([string]::IsNullOrWhiteSpace($additionalPathsInput)) { return }
    
    $additionalPaths = $additionalPathsInput.Split("`n") | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne "" }
    
    if ($additionalPaths.Count -eq 0) {
        gum style --foreground 196 "No valid paths entered!"
        Read-Host "Press Enter to continue"
        return
    }
    
    # Validate new paths
    Clear-Host
    Write-Host "New Paths to Add:" -ForegroundColor Yellow
    Write-Host "=================" -ForegroundColor Yellow
    
    foreach ($path in $additionalPaths) {
        $expandedPath = [System.Environment]::ExpandEnvironmentVariables($path)
        $exists = Test-Path $expandedPath
        $status = if ($exists) { "✓" } else { "✗" }
        $color = if ($exists) { "Green" } else { "Yellow" }
        Write-Host "  $status $path" -ForegroundColor $color
    }
    
    gum confirm "Add these paths?"
    if ($LASTEXITCODE -ne 0) { return }
    
    # Backup and save
    $backupPath = Backup-Configuration
    if (-not $backupPath) { return }
    
    try {
        $combinedPaths = @($currentPaths) + @($additionalPaths)
        $script:Config.BackupItems.$selected = $combinedPaths
        $script:Config | ConvertTo-Json -Depth 10 | Set-Content $ConfigPath -Encoding UTF8
        
        Write-Host "`nPaths added to '$selected' successfully!" -ForegroundColor Green
        Write-Host "Configuration backed up to: $(Split-Path $backupPath -Leaf)" -ForegroundColor Gray
    }
    catch {
        Write-Host "Error adding paths: $_" -ForegroundColor Red
    }
    
    Read-Host "Press Enter to continue"
}

function Remove-ItemCategory {
    $items = $script:Config.BackupItems.PSObject.Properties | Where-Object { $_.Name -notlike "_comment*" } | Sort-Object Name
    
    if ($items.Count -eq 0) {
        gum style --foreground 196 "No backup items found to delete."
        Read-Host "Press Enter to continue"
        return
    }
    
    $itemNames = @("Cancel") + ($items | ForEach-Object { $_.Name })
    $selected = gum choose --height=15 --header "Select Backup Item to Delete" $itemNames
    
    if ($selected -eq "Cancel") { return }
    
    # Check if item is used in backup types
    $usedInTypes = @()
    foreach ($type in $script:Config.BackupTypes.PSObject.Properties) {
        if ($type.Value -contains $selected) {
            $usedInTypes += $type.Name
        }
    }
    
    Clear-Host
    Write-Host "Delete Backup Item: $selected" -ForegroundColor Yellow
    Write-Host "==========================" -ForegroundColor Yellow
    
    if ($usedInTypes.Count -gt 0) {
        Write-Host "`nWarning: This item is used in the following backup types:" -ForegroundColor Red
        foreach ($type in $usedInTypes) {
            Write-Host "  • $type" -ForegroundColor Yellow
        }
        Write-Host "`nDeleting this item will remove it from those backup types as well." -ForegroundColor Red
    }
    
    $selectedItem = $items | Where-Object { $_.Name -eq $selected }
    Write-Host "`nCurrent paths in this item:" -ForegroundColor Cyan
    if ($selectedItem.Value -is [Array]) {
        foreach ($path in $selectedItem.Value) {
            Write-Host "  • $path" -ForegroundColor Gray
        }
    }
    else {
        Write-Host "  [Windows Settings Category]" -ForegroundColor Magenta
    }
    
    gum confirm "Are you sure you want to delete this backup item?"
    if ($LASTEXITCODE -ne 0) { return }
    
    # Backup and save
    $backupPath = Backup-Configuration
    if (-not $backupPath) { return }
    
    try {
        # Remove from BackupItems
        $script:Config.BackupItems.PSObject.Properties.Remove($selected)
        
        # Remove from BackupTypes
        foreach ($type in $script:Config.BackupTypes.PSObject.Properties) {
            if ($type.Value -contains $selected) {
                $newValue = $type.Value | Where-Object { $_ -ne $selected }
                $script:Config.BackupTypes.$($type.Name) = $newValue
            }
        }
        
        $script:Config | ConvertTo-Json -Depth 10 | Set-Content $ConfigPath -Encoding UTF8
        
        Write-Host "`nBackup item '$selected' deleted successfully!" -ForegroundColor Green
        Write-Host "Configuration backed up to: $(Split-Path $backupPath -Leaf)" -ForegroundColor Gray
        
        if ($usedInTypes.Count -gt 0) {
            Write-Host "Item removed from backup types: $($usedInTypes -join ', ')" -ForegroundColor Yellow
        }
    }
    catch {
        Write-Host "Error deleting backup item: $_" -ForegroundColor Red
    }
    
    Read-Host "Press Enter to continue"
}

#endregion

#region Backup Types Management

function Add-NewBackupType {
    Clear-Host
    Write-Host "Create New Backup Type" -ForegroundColor Yellow
    Write-Host "======================" -ForegroundColor Yellow
    
    Write-Host @"

Instructions:
• Enter a unique name for your backup type
• Use PascalCase or kebab-case (e.g., MyBackup, Custom-Backup)
• This name will be used with -BackupType parameter

Examples: Import, Databases, WebDev, etc.

"@ -ForegroundColor Gray
    
    $typeName = gum input --placeholder "Enter backup type name"
    if ([string]::IsNullOrWhiteSpace($typeName)) { return }
    
    # Check if type already exists
    if ($script:Config.BackupTypes.PSObject.Properties.Name -contains $typeName) {
        gum style --foreground 196 "Backup type '$typeName' already exists!"
        Read-Host "Press Enter to continue"
        return
    }
    
    # Get available backup items
    $availableItems = $script:Config.BackupItems.PSObject.Properties | Where-Object { $_.Name -notlike "_comment*" } | Sort-Object Name
    
    if ($availableItems.Count -eq 0) {
        gum style --foreground 196 "No backup items available. Create backup items first."
        Read-Host "Press Enter to continue"
        return
    }
    
    Clear-Host
    Write-Host "Select Items for '$typeName'" -ForegroundColor Yellow
    Write-Host "=============================" -ForegroundColor Yellow
    
    Write-Host @"

Instructions:
• Select one or more backup items to include in this backup type
• Use Space or Ctrl+Space to select multiple items
• Press Enter when finished selecting

Available items:
"@ -ForegroundColor Gray
    
    foreach ($item in $availableItems) {
        if ($item.Value.type -eq "windows_settings") {
            Write-Host "  • $($item.Name) [Windows Settings]" -ForegroundColor Magenta
        }
        else {
            $pathCount = if ($item.Value -is [Array]) { $item.Value.Count } else { 1 }
            Write-Host "  • $($item.Name) ($pathCount paths)" -ForegroundColor Cyan
        }
    }
    
    Write-Host ""
    $itemNames = $availableItems | ForEach-Object { $_.Name }
    $selectedItems = gum choose --no-limit --header "Select backup items (use Space to select, Enter to confirm)" $itemNames
    
    if (-not $selectedItems -or $selectedItems.Count -eq 0) {
        gum style --foreground 196 "No items selected!"
        Read-Host "Press Enter to continue"
        return
    }
    
    # Convert to array if single item selected
    if ($selectedItems -is [string]) {
        $selectedItems = @($selectedItems)
    }
    
    Clear-Host
    Write-Host "New Backup Type Preview:" -ForegroundColor Yellow
    Write-Host "========================" -ForegroundColor Yellow
    
    Write-Host "`n`"$typeName`": [" -ForegroundColor White
    foreach ($item in $selectedItems) {
        Write-Host "  `"$item`"," -ForegroundColor Gray
    }
    Write-Host "]" -ForegroundColor White
    
    Write-Host "`nThis backup type will include:" -ForegroundColor Cyan
    foreach ($item in $selectedItems) {
        $itemData = $availableItems | Where-Object { $_.Name -eq $item }
        if ($itemData.Value.type -eq "windows_settings") {
            Write-Host "  • $item [Windows Settings - $($itemData.Value.items.Count) items]" -ForegroundColor Magenta
        }
        else {
            $pathCount = if ($itemData.Value -is [Array]) { $itemData.Value.Count } else { 1 }
            Write-Host "  • $item ($pathCount paths)" -ForegroundColor Gray
        }
    }
    
    gum confirm "Create this backup type?"
    if ($LASTEXITCODE -ne 0) { return }
    
    # Backup and save
    $backupPath = Backup-Configuration
    if (-not $backupPath) { return }
    
    try {
        $script:Config.BackupTypes | Add-Member -NotePropertyName $typeName -NotePropertyValue $selectedItems
        $script:Config | ConvertTo-Json -Depth 10 | Set-Content $ConfigPath -Encoding UTF8
        
        Write-Host "`nBackup type '$typeName' created successfully!" -ForegroundColor Green
        Write-Host "Configuration backed up to: $(Split-Path $backupPath -Leaf)" -ForegroundColor Gray
        Write-Host "`nYou can now use: .\Main.ps1 -BackupType $typeName -Destination Local" -ForegroundColor Cyan
    }
    catch {
        Write-Host "Error creating backup type: $_" -ForegroundColor Red
    }
    
    Read-Host "Press Enter to continue"
}

function Edit-ExistingBackupType {
    $backupTypes = $script:Config.BackupTypes.PSObject.Properties | Sort-Object Name
    
    if ($backupTypes.Count -eq 0) {
        gum style --foreground 196 "No backup types found to edit."
        Read-Host "Press Enter to continue"
        return
    }
    
    $typeNames = @("Cancel") + ($backupTypes | ForEach-Object { $_.Name })
    $selected = gum choose --height=15 --header "Select Backup Type to Edit" $typeNames
    
    if ($selected -eq "Cancel") { return }
    
    $selectedType = $backupTypes | Where-Object { $_.Name -eq $selected }
    $availableItems = $script:Config.BackupItems.PSObject.Properties | Where-Object { $_.Name -notlike "_comment*" } | Sort-Object Name
    
    Clear-Host
    Write-Host "Edit Backup Type: $selected" -ForegroundColor Yellow
    Write-Host "=========================" -ForegroundColor Yellow
    
    Write-Host "`nCurrently includes:" -ForegroundColor Cyan
    foreach ($item in $selectedType.Value) {
        Write-Host "  ✓ $item" -ForegroundColor Green
    }
    
    Write-Host "`nAvailable items:" -ForegroundColor Gray
    foreach ($item in $availableItems) {
        if ($selectedType.Value -notcontains $item.Name) {
            Write-Host "  ○ $($item.Name)" -ForegroundColor Gray
        }
    }
    
    Write-Host @"

Instructions:
• Select the complete new list of items for this backup type
• This will REPLACE the current items entirely
• Use Space to select/deselect, Enter to confirm

"@ -ForegroundColor Yellow
    
    $itemNames = $availableItems | ForEach-Object { $_.Name }
    $newSelectedItems = gum choose --height=25 --no-limit --header "Select backup items for $selected" $itemNames
    
    if (-not $newSelectedItems -or $newSelectedItems.Count -eq 0) {
        gum style --foreground 196 "No items selected!"
        Read-Host "Press Enter to continue"
        return
    }
    
    # Convert to array if single item
    if ($newSelectedItems -is [string]) {
        $newSelectedItems = @($newSelectedItems)
    }
    
    Clear-Host
    Write-Host "Changes Preview:" -ForegroundColor Yellow
    Write-Host "================" -ForegroundColor Yellow
    
    Write-Host "`nNew items for '$selected':" -ForegroundColor Cyan
    foreach ($item in $newSelectedItems) {
        Write-Host "  ✓ $item" -ForegroundColor Green
    }
    
    gum confirm "Save these changes?"
    if ($LASTEXITCODE -ne 0) { return }
    
    # Backup and save
    $backupPath = Backup-Configuration
    if (-not $backupPath) { return }
    
    try {
        $script:Config.BackupTypes.$selected = $newSelectedItems
        $script:Config | ConvertTo-Json -Depth 10 | Set-Content $ConfigPath -Encoding UTF8
        
        Write-Host "`nBackup type '$selected' updated successfully!" -ForegroundColor Green
        Write-Host "Configuration backed up to: $(Split-Path $backupPath -Leaf)" -ForegroundColor Gray
    }
    catch {
        Write-Host "Error updating backup type: $_" -ForegroundColor Red
    }
    
    Read-Host "Press Enter to continue"
}

function Remove-BackupType {
    $backupTypes = $script:Config.BackupTypes.PSObject.Properties | Sort-Object Name
    
    if ($backupTypes.Count -eq 0) {
        gum style --foreground 196 "No backup types found to delete."
        Read-Host "Press Enter to continue"
        return
    }
    
    $typeNames = @("Cancel") + ($backupTypes | ForEach-Object { $_.Name })
    $selected = gum choose --height=15 --header "Select Backup Type to Delete" $typeNames
    
    if ($selected -eq "Cancel") { return }
    
    $selectedType = $backupTypes | Where-Object { $_.Name -eq $selected }
    
    Clear-Host
    Write-Host "Delete Backup Type: $selected" -ForegroundColor Yellow
    Write-Host "===========================" -ForegroundColor Yellow
    
    Write-Host "`nThis backup type includes:" -ForegroundColor Cyan
    foreach ($item in $selectedType.Value) {
        Write-Host "  • $item" -ForegroundColor Gray
    }
    
    Write-Host "`nWarning: This will permanently delete the backup type definition." -ForegroundColor Red
    Write-Host "The backup items themselves will not be deleted." -ForegroundColor Gray
    
    gum confirm "Are you sure you want to delete this backup type?"
    if ($LASTEXITCODE -ne 0) { return }
    
    # Backup and save
    $backupPath = Backup-Configuration
    if (-not $backupPath) { return }
    
    try {
        $script:Config.BackupTypes.PSObject.Properties.Remove($selected)
        $script:Config | ConvertTo-Json -Depth 10 | Set-Content $ConfigPath -Encoding UTF8
        
        Write-Host "`nBackup type '$selected' deleted successfully!" -ForegroundColor Green
        Write-Host "Configuration backed up to: $(Split-Path $backupPath -Leaf)" -ForegroundColor Gray
    }
    catch {
        Write-Host "Error deleting backup type: $_" -ForegroundColor Red
    }
    
    Read-Host "Press Enter to continue"
}

function View-AllBackupTypes {
    Clear-Host
    Write-Host "All Backup Types" -ForegroundColor Yellow
    Write-Host "================" -ForegroundColor Yellow
    
    $backupTypes = $script:Config.BackupTypes.PSObject.Properties | Sort-Object Name
    
    if ($backupTypes.Count -eq 0) {
        Write-Host "No backup types configured." -ForegroundColor Gray
    }
    else {
        foreach ($type in $backupTypes) {
            Write-Host "`n$($type.Name):" -ForegroundColor Cyan
            foreach ($item in $type.Value) {
                Write-Host "  • $item" -ForegroundColor Gray
            }
        }
    }
    
    Read-Host "`nPress Enter to continue"
}

#endregion

#region Folder Categorization

function View-FolderMapping {
    Clear-Host
    Write-Host "Current Folder Categorization Mapping" -ForegroundColor Yellow
    Write-Host "=====================================" -ForegroundColor Yellow
    
    Write-Log "Reading categorization from main.ps1..." -Level "DEBUG"
    
    # Read current categorization from main.ps1
    $categorization = Get-MainScriptCategorization
    
    if (-not $categorization) {
        Write-Host "Could not read categorization from main.ps1" -ForegroundColor Red
        Write-Log "Check that main.ps1 exists and contains the switch statement" -Level "DEBUG"
        Read-Host "Press Enter to continue"
        return
    }
    
    Write-Log "Successfully parsed categorization data" -Level "DEBUG"
    Write-Log "Found $($categorization.Keys.Count) folder categories" -Level "DEBUG"
    
    Write-Host "`nBackup Items → Archive Folders:" -ForegroundColor Cyan
    Write-Host "===============================" -ForegroundColor Cyan
    
    if ($categorization.Keys.Count -eq 0) {
        Write-Host "No folder mappings found." -ForegroundColor Gray
        Write-Log "This might indicate a parsing issue with the switch statement" -Level "DEBUG"
    }
    else {
        foreach ($mapping in $categorization.GetEnumerator() | Sort-Object Key) {
            Write-Host "`n$($mapping.Key):" -ForegroundColor White
            if ($mapping.Value.Count -gt 0) {
                foreach ($item in $mapping.Value) {
                    Write-Host "  • $item" -ForegroundColor Gray
                }
            }
            else {
                Write-Host "  (no items)" -ForegroundColor Gray
            }
        }
    }
    
    Write-Host "`nSpecial Handling Items:" -ForegroundColor Magenta
    Write-Host "=======================" -ForegroundColor Magenta
    Write-Host "• Certificates → Files\Certificates" -ForegroundColor Gray
    Write-Host "• DoskeyMacros → Files\Tools\DoskeyMacros" -ForegroundColor Gray  
    Write-Host "• WindowsCredentials → Files\Tools\WindowsCredentials" -ForegroundColor Gray
    Write-Host "• Windows Settings (Win*) → WindowsSettings\*" -ForegroundColor Gray
    
    Read-Host "`nPress Enter to continue"
}

function Move-ItemsBetweenFolders {
    # Get current categorization
    $categorization = Get-MainScriptCategorization
    if (-not $categorization) {
        gum style --foreground 196 "Could not read folder categorization from main.ps1"
        Read-Host "Press Enter to continue"
        return
    }
    
    # Get all items that can be moved (not special handling items)
    $allItems = $script:Config.BackupItems.PSObject.Properties | Where-Object { 
        $_.Name -notlike "_comment*" -and 
        $_.Value.type -ne "windows_settings" -and
        $_.Name -notin @("Certificates", "DoskeyMacros", "WindowsCredentials")
    } | Sort-Object Name
    
    if ($allItems.Count -eq 0) {
        gum style --foreground 196 "No moveable items found."
        Read-Host "Press Enter to continue"
        return
    }
    
    Clear-Host
    Write-Host "Move Items Between Folders" -ForegroundColor Yellow
    Write-Host "==========================" -ForegroundColor Yellow
    
    Write-Host "`nCurrent folder assignments:" -ForegroundColor Cyan
    foreach ($item in $allItems) {
        $currentFolder = Get-CurrentItemMapping -ItemName $item.Name
        if (-not $currentFolder) { $currentFolder = "Files\Other (default)" }
        Write-Host "  • $($item.Name) → $currentFolder" -ForegroundColor Gray
    }
    
    # Select item to move
    $itemNames = @("Cancel") + ($allItems | ForEach-Object { $_.Name })
    $selectedItem = gum choose --height=15 --header "Select Item to Move" $itemNames
    
    if ($selectedItem -eq "Cancel") { return }
    
    # Show available folders
    $availableFolders = @(
        "Files\Documents",
        "Files\Applications", 
        "Files\Scripts",
        "Files\Games",
        "Files\UserConfigs",
        "Files\Browsers",
        "Files\System",
        "Files\Tools",
        "Files\Other",
        "Create New Folder",
        "Cancel"
    )
    
    $currentFolder = Get-CurrentItemMapping -ItemName $selectedItem
    if (-not $currentFolder) { $currentFolder = "Files\Other" }
    
    Clear-Host
    Write-Host "Move '$selectedItem'" -ForegroundColor Yellow
    Write-Host "===================" -ForegroundColor Yellow
    Write-Host "`nCurrent folder: $currentFolder" -ForegroundColor Cyan
    Write-Host "`nSelect new folder:" -ForegroundColor Gray
    
    $newFolder = gum choose --height=15 --header "Select Target Folder" $availableFolders
    
    if ($newFolder -eq "Cancel") { return }
    
    if ($newFolder -eq "Create New Folder") {
        $customFolder = gum input --placeholder "Enter new folder name (without Files\ prefix)"
        if ([string]::IsNullOrWhiteSpace($customFolder)) { return }
        $newFolder = "Files\$customFolder"
    }
    
    if ($newFolder -eq $currentFolder) {
        gum style --foreground 196 "Item is already in that folder!"
        Read-Host "Press Enter to continue"
        return
    }
    
    # Confirm the move
    Clear-Host
    Write-Host "Confirm Move" -ForegroundColor Yellow
    Write-Host "============" -ForegroundColor Yellow
    Write-Host "`nItem: $selectedItem" -ForegroundColor Cyan
    Write-Host "From: $currentFolder" -ForegroundColor Red
    Write-Host "To:   $newFolder" -ForegroundColor Green
    
    gum confirm "Move this item?"
    if ($LASTEXITCODE -ne 0) { return }
    
    # Backup and update
    $configBackup = Backup-Configuration
    $mainBackup = Backup-MainScript
    
    if (-not $configBackup -or -not $mainBackup) { return }
    
    try {
        $result = Update-MainScriptCategorization -ItemName $selectedItem -TargetFolder $newFolder
        
        if ($result) {
            Write-Host "`nItem moved successfully!" -ForegroundColor Green
            Write-Host "Configuration backed up to: $(Split-Path $configBackup -Leaf)" -ForegroundColor Gray
            Write-Host "main.ps1 backed up to: $(Split-Path $mainBackup -Leaf)" -ForegroundColor Gray
        }
        else {
            Write-Host "`nFailed to move item." -ForegroundColor Red
        }
    }
    catch {
        Write-Host "Error moving item: $_" -ForegroundColor Red
    }
    
    Read-Host "Press Enter to continue"
}

function Rename-FolderCategory {
    # Get current categorization
    $categorization = Get-MainScriptCategorization
    if (-not $categorization) {
        gum style --foreground 196 "Could not read folder categorization from main.ps1"
        Read-Host "Press Enter to continue"
        return
    }
    
    # Get existing folders (exclude default)
    $existingFolders = $categorization.Keys | Where-Object { $_ -ne "Files\Other" } | Sort-Object
    
    if ($existingFolders.Count -eq 0) {
        gum style --foreground 196 "No renameable folders found."
        Read-Host "Press Enter to continue"
        return
    }
    
    Clear-Host
    Write-Host "Rename Folder Category" -ForegroundColor Yellow
    Write-Host "======================" -ForegroundColor Yellow
    
    Write-Host "`nCurrent folders:" -ForegroundColor Cyan
    foreach ($folder in $existingFolders) {
        $itemCount = $categorization[$folder].Count
        Write-Host "  • $folder ($itemCount items)" -ForegroundColor Gray
    }
    
    # Select folder to rename
    $folderOptions = @("Cancel") + $existingFolders
    $selectedFolder = gum choose --height=15 --header "Select Folder to Rename" $folderOptions
    
    if ($selectedFolder -eq "Cancel") { return }
    
    # Get new name
    $currentName = $selectedFolder.Replace("Files\", "")
    $newName = gum input --placeholder "Enter new folder name" --value $currentName
    
    if ([string]::IsNullOrWhiteSpace($newName)) { return }
    
    $newFolderPath = "Files\$newName"
    
    if ($newFolderPath -eq $selectedFolder) {
        gum style --foreground 196 "New name is the same as current name!"
        Read-Host "Press Enter to continue"
        return
    }
    
    # Check if new name conflicts
    if ($categorization.Keys -contains $newFolderPath) {
        gum style --foreground 196 "A folder with that name already exists!"
        Read-Host "Press Enter to continue"
        return
    }
    
    # Show items that will be affected
    Clear-Host
    Write-Host "Confirm Folder Rename" -ForegroundColor Yellow
    Write-Host "=====================" -ForegroundColor Yellow
    Write-Host "`nRename: $selectedFolder" -ForegroundColor Red
    Write-Host "To:     $newFolderPath" -ForegroundColor Green
    
    Write-Host "`nItems in this folder:" -ForegroundColor Cyan
    foreach ($item in $categorization[$selectedFolder]) {
        Write-Host "  • $item" -ForegroundColor Gray
    }
    
    gum confirm "Rename this folder and update all affected items?"
    if ($LASTEXITCODE -ne 0) { return }
    
    # Backup and update
    $configBackup = Backup-Configuration
    $mainBackup = Backup-MainScript
    
    if (-not $configBackup -or -not $mainBackup) { return }
    
    try {
        # Update each item in the folder to the new folder name
        $affectedItems = $categorization[$selectedFolder]
        $successCount = 0
        
        foreach ($item in $affectedItems) {
            $result = Update-MainScriptCategorization -ItemName $item -TargetFolder $newFolderPath
            if ($result) { $successCount++ }
        }
        
        if ($successCount -eq $affectedItems.Count) {
            Write-Host "`nFolder renamed successfully!" -ForegroundColor Green
            Write-Host "Updated $successCount items" -ForegroundColor Green
            Write-Host "Configuration backed up to: $(Split-Path $configBackup -Leaf)" -ForegroundColor Gray
            Write-Host "main.ps1 backed up to: $(Split-Path $mainBackup -Leaf)" -ForegroundColor Gray
        }
        else {
            Write-Host "`nPartial success: $successCount/$($affectedItems.Count) items updated" -ForegroundColor Yellow
        }
    }
    catch {
        Write-Host "Error renaming folder: $_" -ForegroundColor Red
    }
    
    Read-Host "Press Enter to continue"
}

function Set-FolderCategorization {
    param([string]$ItemName = $null)
    
    if (-not $ItemName) {
        # Let user select item to categorize
        $items = $script:Config.BackupItems.PSObject.Properties | Where-Object { $_.Name -notlike "_comment*" -and $_.Value.type -ne "windows_settings" } | Sort-Object Name
        
        if ($items.Count -eq 0) {
            gum style --foreground 196 "No items available for folder categorization."
            Read-Host "Press Enter to continue"
            return
        }
        
        $itemNames = @("Cancel") + ($items | ForEach-Object { $_.Name })
        $selected = gum choose --height=15 --header "Select Item to Set Folder Category" $itemNames
        
        if ($selected -eq "Cancel") { return }
        $ItemName = $selected
    }
    
    Clear-Host
    Write-Host "Set Folder Category for: $ItemName" -ForegroundColor Yellow
    Write-Host "==================================" -ForegroundColor Yellow
    
    # Get current mapping
    $currentMapping = Get-CurrentItemMapping -ItemName $ItemName
    
    if ($currentMapping) {
        Write-Host "`nCurrent folder: $currentMapping" -ForegroundColor Cyan
    }
    else {
        Write-Host "`nCurrent folder: Files\Other (default)" -ForegroundColor Gray
    }
    
    Write-Host @"

Available folder categories:
• Files\Documents - Document files and user data
• Files\Applications - Application configs and tools  
• Files\Scripts - Scripts and PowerShell profiles
• Files\Games - Game saves and related data
• Files\UserConfigs - User configuration files
• Files\System - System files and drivers
• Files\Tools - Utility tools and macros
• Files\Other - Miscellaneous items (default)
• Create New Folder - Define a custom folder

"@ -ForegroundColor Gray
    
    $folderOptions = @(
        "Files\Documents",
        "Files\Applications", 
        "Files\Scripts",
        "Files\Games",
        "Files\UserConfigs",
        "Files\System",
        "Files\Tools", 
        "Files\Other",
        "Create New Folder",
        "Cancel"
    )
    
    $selectedFolder = gum choose --height=15 --header "Select Target Folder" $folderOptions
    
    if ($selectedFolder -eq "Cancel") { return }
    
    if ($selectedFolder -eq "Create New Folder") {
        $customFolder = gum input --placeholder "Enter custom folder name (e.g., MyCustomFolder)"
        if ([string]::IsNullOrWhiteSpace($customFolder)) { return }
        $selectedFolder = "Files\$customFolder"
    }
    
    # Show the change that will be made
    Clear-Host
    Write-Host "Folder Categorization Change" -ForegroundColor Yellow
    Write-Host "============================" -ForegroundColor Yellow
    
    Write-Host "`nItem: $ItemName" -ForegroundColor Cyan
    Write-Host "Will go to folder: $selectedFolder" -ForegroundColor Green
    
    Write-Host "`nThis will modify main.ps1 to add/update the categorization rule." -ForegroundColor Yellow
    
    gum confirm "Apply this folder categorization change?"
    if ($LASTEXITCODE -ne 0) { return }
    
    # Backup configuration and main.ps1
    $configBackup = Backup-Configuration
    $mainBackup = Backup-MainScript
    
    if (-not $configBackup -or -not $mainBackup) { return }
    
    try {
        $result = Update-MainScriptCategorization -ItemName $ItemName -TargetFolder $selectedFolder
        
        if ($result) {
            Write-Host "`nFolder categorization updated successfully!" -ForegroundColor Green
            Write-Host "Configuration backed up to: $(Split-Path $configBackup -Leaf)" -ForegroundColor Gray
            Write-Host "main.ps1 backed up to: $(Split-Path $mainBackup -Leaf)" -ForegroundColor Gray
            Write-Host "`n'$ItemName' will now go to '$selectedFolder' in backups." -ForegroundColor Cyan
        }
        else {
            Write-Host "`nFailed to update folder categorization." -ForegroundColor Red
        }
    }
    catch {
        Write-Host "Error updating folder categorization: $_" -ForegroundColor Red
    }
    
    Read-Host "Press Enter to continue"
}

function Get-MainScriptCategorization {
    if (-not (Test-Path $MainScriptPath)) {
        Write-Log "main.ps1 not found at: $MainScriptPath" -Level "DEBUG"
        return $null
    }
    
    try {
        $content = Get-Content $MainScriptPath -Raw
        Write-Log "Successfully read main.ps1 ($($content.Length) characters)" -Level "DEBUG"
        
        # Find the switch statement - improved pattern to handle whitespace and formatting
        $pattern = '\$destinationFolder\s*=\s*switch\s*\(\$item\)\s*\{(.*?)\s*\}'
        $match = [regex]::Match($content, $pattern, [System.Text.RegularExpressions.RegexOptions]::Singleline)
        
        if (-not $match.Success) {
            Write-Log "Switch statement pattern not found" -Level "DEBUG"
            Write-Log "Looking for pattern: `$destinationFolder = switch (`$item) { ... }" -Level "DEBUG"
            
            # Try to find just the switch line for debugging
            $lines = $content -split "`n"
            $switchLine = $lines | Where-Object { $_ -like "*destinationFolder*switch*item*" }
            if ($switchLine) {
                Write-Log "Found potential switch line: $($switchLine.Trim())" -Level "DEBUG"
            }
            else {
                Write-Log "No switch line found at all" -Level "DEBUG"
            }
            return $null
        }
        
        Write-Log "Found switch statement" -Level "DEBUG"
        $switchContent = $match.Groups[1].Value
        Write-Log "Switch content length: $($switchContent.Length)" -Level "DEBUG"
        
        # Parse the switch cases - improved pattern to handle tabs, spaces, and formatting variations
        $categorization = @{}
        $casePattern = '\{\s*\$_\s+-in\s+@\((.*?)\)\s*\}\s*\{\s*"([^"]+)"\s*\}'
        $matches = [regex]::Matches($switchContent, $casePattern, [System.Text.RegularExpressions.RegexOptions]::Singleline)
        
        Write-Log "Found $($matches.Count) switch cases" -Level "DEBUG"
        
        foreach ($match in $matches) {
            $itemsString = $match.Groups[1].Value
            $folder = $match.Groups[2].Value
            
            Write-Log "Processing case - Folder: '$folder', Items string: '$itemsString'" -Level "DEBUG"
            
            # Parse items from the comma-separated string, handling quotes and whitespace
            $items = $itemsString -split ',' | ForEach-Object { 
                $_.Trim().Trim('"').Trim("'").Trim() 
            } | Where-Object { $_ -ne "" }
            
            Write-Log "Parsed items: $($items -join ', ')" -Level "DEBUG"
            
            if (-not $categorization[$folder]) {
                $categorization[$folder] = @()
            }
            $categorization[$folder] += $items
        }
        
        Write-Log "Final categorization has $($categorization.Keys.Count) folders" -Level "DEBUG"
        foreach ($cat in $categorization.GetEnumerator()) {
            Write-Log "$($cat.Key) -> $($cat.Value.Count) items: $($cat.Value -join ', ')" -Level "DEBUG"
        }
        
        return $categorization
    }
    catch {
        Write-Log "Exception in Get-MainScriptCategorization: $_" -Level "DEBUG"
        Write-Log "Exception type: $($_.Exception.GetType().Name)" -Level "DEBUG"
        return $null
    }
}

function Get-CurrentItemMapping {
    param([string]$ItemName)
    
    $categorization = Get-MainScriptCategorization
    if (-not $categorization) { return $null }
    
    foreach ($mapping in $categorization.GetEnumerator()) {
        if ($mapping.Value -contains $ItemName) {
            return $mapping.Key
        }
    }
    
    return $null
}

function Update-MainScriptCategorization {
    param(
        [string]$ItemName,
        [string]$TargetFolder
    )
    
    try {
        $content = Get-Content $MainScriptPath -Raw
        
        # Find the current categorization section
        $pattern = '(\$destinationFolder\s*=\s*switch\s*\(\$item\)\s*\{.*?\})'
        $match = [regex]::Match($content, $pattern, [System.Text.RegularExpressions.RegexOptions]::Singleline)
        
        if (-not $match.Success) {
            Write-Host "Could not find categorization section in main.ps1" -ForegroundColor Red
            return $false
        }
        
        $currentCategorization = Get-MainScriptCategorization
        
        # Remove item from current categories
        foreach ($category in $currentCategorization.GetEnumerator()) {
            if ($category.Value -contains $ItemName) {
                $currentCategorization[$category.Key] = $currentCategorization[$category.Key] | Where-Object { $_ -ne $ItemName }
            }
        }
        
        # Add item to target category
        if (-not $currentCategorization[$TargetFolder]) {
            $currentCategorization[$TargetFolder] = @()
        }
        $currentCategorization[$TargetFolder] += $ItemName
        
        # Rebuild the switch statement
        $newSwitch = "`$destinationFolder = switch (`$item) {`n"
        
        foreach ($category in $currentCategorization.GetEnumerator() | Sort-Object Key) {
            if ($category.Value.Count -gt 0) {
                $itemsList = ($category.Value | ForEach-Object { "`"$_`"" }) -join ", "
                $newSwitch += "                            { `$_ -in @($itemsList) } { `"$($category.Key)`" }`n"
            }
        }
        
        $newSwitch += "                            default { `"Files\Other`" }`n                        }"
        
        # Replace the switch statement
        $content = $content.Replace($match.Groups[1].Value, $newSwitch)
        
        # Save the updated main.ps1
        Set-Content $MainScriptPath $content -Encoding UTF8
        
        return $true
    }
    catch {
        Write-Host "Error updating main.ps1: $_" -ForegroundColor Red
        return $false
    }
}

function Backup-MainScript {
    $timestamp = Get-Date -Format "yyyyMMdd-HHmmss"
    $backupName = "main_$timestamp.ps1"
    $backupPath = Join-Path $script:ConfigBackupDir $backupName
    
    try {
        Copy-Item $MainScriptPath $backupPath -Force
        return $backupPath
    }
    catch {
        Write-Host "Error backing up main.ps1: $_" -ForegroundColor Red
        return $null
    }
}

function Show-MainScriptCode {
    Clear-Host
    Write-Host "Current main.ps1 Categorization Code" -ForegroundColor Yellow
    Write-Host "====================================" -ForegroundColor Yellow
    
    try {
        $content = Get-Content $MainScriptPath -Raw
        
        # Extract categorization switch
        $switchPattern = '(\$destinationFolder\s*=\s*switch\s*\(\$item\)\s*\{.*?\})'
        $switchMatch = [regex]::Match($content, $switchPattern, [System.Text.RegularExpressions.RegexOptions]::Singleline)
        
        if ($switchMatch.Success) {
            Write-Host "`nCategorization Switch:" -ForegroundColor Cyan
            # Format the output nicely
            $switchCode = $switchMatch.Groups[1].Value
            $lines = $switchCode -split "`n"
            foreach ($line in $lines) {
                Write-Host $line -ForegroundColor Gray
            }
        }
        else {
            Write-Host "Categorization switch not found in main.ps1" -ForegroundColor Red
        }
    }
    catch {
        Write-Host "Error reading main.ps1: $_" -ForegroundColor Red
    }
    
    Read-Host "`nPress Enter to continue"
}

#endregion

#region Special Handling

function View-SpecialItems {
    Clear-Host
    Write-Host "Current Special Handling Items" -ForegroundColor Yellow
    Write-Host "==============================" -ForegroundColor Yellow
    
    Write-Host @"

Special items are processed with custom logic instead of simple file copying:

• Certificates
  → Custom export of certificate stores
  → Location: Files\Certificates\
  → Exports .cer and .pfx files from My, Root, CA stores

• DoskeyMacros  
  → Exports command-line macros
  → Location: Files\Tools\DoskeyMacros\
  → Creates macros.doskey file

• WindowsCredentials
  → Exports Windows Credential Manager entries
  → Location: Files\Tools\WindowsCredentials\
  → Creates Win_credentials.txt (passwords protected)

• Windows Settings (Win* items)
  → Complex registry and configuration exports
  → Location: WindowsSettings\Registry\, Files\, Lists\, Scripts\
  → Handles registry exports, file copies, and command exports

To add new special handling:
1. Use 'Generate Code for New Special Item' option
2. Implement the custom logic in main.ps1
3. Add the item to your backup configuration

"@ -ForegroundColor Gray
    
    Read-Host "Press Enter to continue"
}

function Generate-SpecialItemCode {
    Clear-Host
    Write-Host "Generate Special Handling Code" -ForegroundColor Yellow
    Write-Host "==============================" -ForegroundColor Yellow
    
    Write-Host @"

This will generate template code for adding special handling to a backup item.
Special handling allows custom processing instead of simple file copying.

Examples of special handling:
• Export databases with custom tools
• Process configuration files before backup
• Create custom archive formats
• Generate reports or inventories

"@ -ForegroundColor Gray
    
    $itemName = gum input --placeholder "Enter backup item name for special handling"
    if ([string]::IsNullOrWhiteSpace($itemName)) { return }
    
    $description = gum input --placeholder "Brief description of what this item does"
    if ([string]::IsNullOrWhiteSpace($description)) { $description = "Custom processing for $itemName" }
    
    Clear-Host
    Write-Host "Generated Special Handling Code" -ForegroundColor Yellow
    Write-Host "===============================" -ForegroundColor Yellow
    
    Write-Host "`nAdd this code to main.ps1 in the switch statement around line 380:" -ForegroundColor Cyan
    
    $code = @"

"$itemName" {
    `$${itemName}BackupFolder = Join-Path `$tempBackupFolder "Files\Special\$itemName"
    if (-not (Test-Path `$${itemName}BackupFolder)) { 
        New-Item -ItemType Directory -Path `$${itemName}BackupFolder -Force | Out-Null 
    }
    
    # TODO: Implement custom processing logic here
    # Example: Export-$itemName -DestinationPath `$${itemName}BackupFolder
    
    Write-Log "$description" -Level "INFO"
    
    if (Test-Path `$${itemName}BackupFolder) {
        Write-Log "Successfully processed $itemName to `$${itemName}BackupFolder" -Level "INFO"
    }
}
"@
    
    Write-Host $code -ForegroundColor Gray
    
    Write-Host "`nAlso create a custom function like this:" -ForegroundColor Cyan
    
    $functionCode = @"

function Export-$itemName {
    param (
        [string]`$DestinationPath
    )
    
    Write-Log "Starting $itemName export" -Level "INFO"
    
    try {
        # TODO: Implement your custom export logic here
        # Examples:
        # - Export database: mysqldump.exe -u user -p database > `$DestinationPath\database.sql
        # - Process config files: Get-Content config.xml | ConvertTo-Json | Out-File `$DestinationPath\config.json
        # - Create custom archives: 7z.exe a `$DestinationPath\archive.7z C:\MyData\*
        
        Write-Log "Successfully exported $itemName" -Level "INFO"
        return `$true
    }
    catch {
        Write-Log "Error exporting $itemName`: `$_" -Level "ERROR"
        return `$false
    }
}
"@
    
    Write-Host $functionCode -ForegroundColor Gray
    
    Write-Host "`nConfiguration addition:" -ForegroundColor Cyan
    Write-Host @"
Add to bkp_cfg.json BackupItems:

"$itemName": [
    "Path\To\Your\Source\Data"
]
"@ -ForegroundColor Gray
    
    Read-Host "`nPress Enter to continue"
}

#endregion

#region Configuration Tools

function Test-Configuration {
    Clear-Host
    Write-Host "Configuration Validation" -ForegroundColor Yellow
    Write-Host "========================" -ForegroundColor Yellow
    
    $issues = @()
    $warnings = @()
    
    Write-Host "`nValidating backup items..." -ForegroundColor Cyan
    
    # Define special handling items that don't have file paths
    $specialItems = @("Certificates", "DoskeyMacros", "WindowsCredentials")
    
    # Validate backup items
    $backupItems = $script:Config.BackupItems.PSObject.Properties | Where-Object { $_.Name -notlike "_comment*" }
    foreach ($item in $backupItems) {
        if ($item.Value.type -eq "windows_settings") {
            Write-Host "  ✓ $($item.Name) [Windows Settings]" -ForegroundColor Green
        }
        elseif ($specialItems -contains $item.Name) {
            Write-Host "  ⚙ $($item.Name) [Special Handling]" -ForegroundColor Magenta
        }
        elseif ($item.Value -is [Array]) {
            $validPaths = 0
            $totalPaths = $item.Value.Count
            
            foreach ($path in $item.Value) {
                # Handle both PowerShell $env: syntax and Windows %VAR% syntax
                $expandedPath = $path
                
                # First expand Windows-style environment variables
                $expandedPath = [System.Environment]::ExpandEnvironmentVariables($expandedPath)
                
                # Then expand PowerShell $env: variables using PowerShell's expansion
                if ($expandedPath -match '\$env:') {
                    $expandedPath = $ExecutionContext.InvokeCommand.ExpandString($expandedPath)
                }
                
                if (Test-Path $expandedPath) {
                    $validPaths++
                }
                else {
                    $warnings += "Path not found: $path → $expandedPath (in $($item.Name))"
                }
            }
            
            if ($validPaths -eq $totalPaths) {
                Write-Host "  ✓ $($item.Name) ($totalPaths/$totalPaths paths exist)" -ForegroundColor Green
            }
            elseif ($validPaths -gt 0) {
                Write-Host "  ⚠ $($item.Name) ($validPaths/$totalPaths paths exist)" -ForegroundColor Yellow
            }
            else {
                Write-Host "  ✗ $($item.Name) (0/$totalPaths paths exist)" -ForegroundColor Red
                $issues += "No valid paths found in backup item: $($item.Name)"
            }
        }
        else {
            Write-Host "  ? $($item.Name) [Unknown format]" -ForegroundColor Magenta
            $warnings += "Backup item has unknown format: $($item.Name)"
        }
    }
    
    Write-Host "`nValidating backup types..." -ForegroundColor Cyan
    
    # Validate backup types
    $backupTypes = $script:Config.BackupTypes.PSObject.Properties
    foreach ($type in $backupTypes) {
        $validItems = 0
        $totalItems = $type.Value.Count
        
        foreach ($itemName in $type.Value) {
            if ($script:Config.BackupItems.PSObject.Properties.Name -contains $itemName) {
                $validItems++
            }
            else {
                $issues += "Backup type '$($type.Name)' references non-existent item: $itemName"
            }
        }
        
        if ($validItems -eq $totalItems) {
            Write-Host "  ✓ $($type.Name) ($totalItems items)" -ForegroundColor Green
        }
        else {
            Write-Host "  ✗ $($type.Name) ($validItems/$totalItems valid items)" -ForegroundColor Red
        }
    }
    
    Write-Host "`nValidating required files..." -ForegroundColor Cyan
    
    # Check required files
    $requiredFiles = @{
        "main.ps1" = $MainScriptPath
        "BackupUtilities.ps1" = "BackupUtilities.ps1"
        "WinBackup.ps1" = "WinBackup.ps1"
        "7-Zip" = $script:Config.Tools.'7Zip'
    }
    
    foreach ($file in $requiredFiles.GetEnumerator()) {
        if (Test-Path $file.Value) {
            Write-Host "  ✓ $($file.Key)" -ForegroundColor Green
        }
        else {
            Write-Host "  ✗ $($file.Key) - $($file.Value)" -ForegroundColor Red
            $issues += "Required file not found: $($file.Value)"
        }
    }
    
    # Summary
    Write-Host "`nValidation Summary:" -ForegroundColor Yellow
    Write-Host "==================" -ForegroundColor Yellow
    
    if ($issues.Count -eq 0) {
        Write-Host "✓ Configuration is valid!" -ForegroundColor Green
    }
    else {
        Write-Host "✗ Found $($issues.Count) error(s):" -ForegroundColor Red
        foreach ($issue in $issues) {
            Write-Host "  • $issue" -ForegroundColor Red
        }
    }
    
    if ($warnings.Count -gt 0) {
        Write-Host "`n⚠ Found $($warnings.Count) warning(s):" -ForegroundColor Yellow
        foreach ($warning in $warnings) {
            Write-Host "  • $warning" -ForegroundColor Yellow
        }
    }
    
    Write-Host "`nLegend:" -ForegroundColor Gray
    Write-Host "  ✓ Valid file/folder paths" -ForegroundColor Green
    Write-Host "  ⚙ Special handling (no paths needed)" -ForegroundColor Magenta  
    Write-Host "  ⚠ Some paths missing" -ForegroundColor Yellow
    Write-Host "  ✗ All paths missing or invalid" -ForegroundColor Red
    
    Read-Host "`nPress Enter to continue"
}

#endregion

#region Main Application Logic

function Start-ConfigManager {
    Initialize-ConfigManager
    
    while ($true) {
        Show-Banner
        $choice = Show-MainMenu
        
        switch ($choice) {
            "View Current Configuration" { View-CurrentConfiguration }
            "Manage Backup Items" { 
                $exitSubmenu = $false
                while (-not $exitSubmenu) {
                    Show-Banner
                    $subChoice = Show-BackupItemsMenu
                    switch ($subChoice) {
                        "Add New Item Category" { Add-NewItemCategory }
                        "Edit Existing Item" { Edit-ExistingItem }
                        "Delete Item Category" { Remove-ItemCategory }
                        "Add Paths to Existing Item" { Add-PathsToExistingItem }
                        "View All Items" { View-CurrentConfiguration }
                        "Go Back" { $exitSubmenu = $true }
                    }
                }
            }
            "Manage Backup Types" {
                $exitSubmenu = $false
                while (-not $exitSubmenu) {
                    Show-Banner
                    $subChoice = Show-BackupTypesMenu
                    switch ($subChoice) {
                        "Create New Backup Type" { Add-NewBackupType }
                        "Edit Existing Backup Type" { Edit-ExistingBackupType }
                        "Delete Backup Type" { Remove-BackupType }
                        "View All Backup Types" { View-AllBackupTypes }
                        "Go Back" { $exitSubmenu = $true }
                    }
                }
            }
            "Manage Folder Categorization" {
                $exitSubmenu = $false
                while (-not $exitSubmenu) {
                    Show-Banner
                    $subChoice = Show-FolderCategorizationMenu
                    switch ($subChoice) {
                        "View Current Folder Mapping" { View-FolderMapping }
                        "Move Items Between Folders" { Move-ItemsBetweenFolders }
                        "Rename Folder Category" { Rename-FolderCategory }
                        "Create New Folder Category" { Set-FolderCategorization }
                        "View main.ps1 Categorization Code" { Show-MainScriptCode }
                        "Go Back" { $exitSubmenu = $true }
                    }
                }
            }
            "Special Handling" {
                $exitSubmenu = $false
                while (-not $exitSubmenu) {
                    Show-Banner
                    $subChoice = Show-SpecialHandlingMenu
                    switch ($subChoice) {
                        "View Current Special Items" { View-SpecialItems }
                        "Generate Code for New Special Item" { Generate-SpecialItemCode }
                        "Go Back" { $exitSubmenu = $true }
                    }
                }
            }
            "Configuration Tools" {
                $exitSubmenu = $false
                while (-not $exitSubmenu) {
                    Show-Banner
                    $subChoice = Show-ConfigToolsMenu
                    switch ($subChoice) {
                        "Validate Configuration" { Test-Configuration }
                        "Backup Current Config" { 
                            $backup = Backup-Configuration
                            if ($backup) {
                                Write-Host "Configuration backed up successfully!" -ForegroundColor Green
                                Read-Host "Press Enter to continue"
                            }
                        }
                        "Restore Config Backup" { Restore-Configuration }
                        "View Config Backups" { View-ConfigBackups }
                        "Go Back" { $exitSubmenu = $true }
                    }
                }
            }
            "Exit" { 
                $Host.UI.RawUI.WindowTitle = $script:OriginalTitle
                exit 0 
            }
        }
    }
}

#endregion

# Start the configuration manager
Start-ConfigManager