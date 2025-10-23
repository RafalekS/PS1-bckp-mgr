#Requires -Version 5.1

<#
.SYNOPSIS
    Manifest generation utilities for backup restoration
    
.DESCRIPTION
    Functions to generate and manage backup manifests that track original file locations
    for comprehensive restoration capabilities
    
.NOTES
    Version: 1.0
    Used by: Main.ps1, WinBackup.ps1, RestoreBackup.ps1
#>

#region Manifest Generation Functions

# Global variable to track manifest entries during backup
$script:BackupManifest = @{
    backup_manifest = @{}
    backup_info = @{}
}

function Initialize-BackupManifest {
    param (
        [string]$BackupType,
        [string]$BackupName,
        [string]$Timestamp
    )
    
    $script:BackupManifest = @{
        backup_manifest = @{}
        backup_info = @{
            backup_type = $BackupType
            backup_name = $BackupName
            created_timestamp = $Timestamp
            creation_date = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
            manifest_version = "1.0"
            total_files = 0
            total_folders = 0
            backup_items = @()
        }
    }
    
    # Use Write-Host if Write-Log is not available
    if (Get-Command Write-Log -ErrorAction SilentlyContinue) {
        Write-Log "Initialized backup manifest for $BackupName" -Level "DEBUG"
    } else {
        Write-Host "Initialized backup manifest for $BackupName"
    }
}

function Add-FileToManifest {
    param (
        [string]$OriginalPath,
        [string]$ArchivePath,
        [string]$BackupItem,
        [string]$FileType = "file",
        [hashtable]$AdditionalMetadata = @{}
    )
    
    # Normalize paths for consistency
    $normalizedArchivePath = $ArchivePath -replace '\\', '/' -replace '/+', '/'
    $normalizedOriginalPath = $OriginalPath -replace '/', '\'
    
    $manifestEntry = @{
        original_path = $normalizedOriginalPath
        backup_item = $BackupItem
        file_type = $FileType
        archive_relative_path = $normalizedArchivePath
        size_bytes = 0
        last_modified = ""
        checksum = ""
    }
    
    # Add file size and modification date if it's a file
    if ($FileType -eq "file" -and (Test-Path $OriginalPath -PathType Leaf)) {
        try {
            $fileInfo = Get-Item $OriginalPath -Force -ErrorAction SilentlyContinue
            if ($fileInfo) {
                $manifestEntry.size_bytes = $fileInfo.Length
                $manifestEntry.last_modified = $fileInfo.LastWriteTime.ToString("yyyy-MM-dd HH:mm:ss")
            }
        }
        catch {
            if (Get-Command Write-Log -ErrorAction SilentlyContinue) {
                Write-Log "Could not get file info for manifest: $OriginalPath" -Level "WARNING"
            } else {
                Write-Warning "Could not get file info for manifest: $OriginalPath"
            }
        }
    }
    
    # Add any additional metadata
    foreach ($key in $AdditionalMetadata.Keys) {
        $manifestEntry[$key] = $AdditionalMetadata[$key]
    }
    
    # Store in manifest using archive path as key
    $script:BackupManifest.backup_manifest[$normalizedArchivePath] = $manifestEntry
    
    # Update counters
    if ($FileType -eq "file") {
        $script:BackupManifest.backup_info.total_files++
    } elseif ($FileType -eq "folder") {
        $script:BackupManifest.backup_info.total_folders++
    }
    
    if (Get-Command Write-Log -ErrorAction SilentlyContinue) {
        Write-Log "Added to manifest: $normalizedArchivePath -> $normalizedOriginalPath" -Level "DEBUG"
    }
}

function Add-WindowsSettingsToManifest {
    param (
        [string]$ItemId,
        [string]$ItemName,
        [string]$Category,
        [string]$ArchivePath,
        [string]$ExportType,
        [string]$OriginalLocation = "",
        [hashtable]$AdditionalInfo = @{}
    )
    
    $normalizedArchivePath = $ArchivePath -replace '\\', '/' -replace '/+', '/'
    
    $manifestEntry = @{
        original_path = $OriginalLocation
        backup_item = $Category
        file_type = "windows_settings"
        archive_relative_path = $normalizedArchivePath
        windows_settings = @{
            item_id = $ItemId
            item_name = $ItemName
            category = $Category
            export_type = $ExportType
        }
    }
    
    # Add additional info
    foreach ($key in $AdditionalInfo.Keys) {
        $manifestEntry.windows_settings[$key] = $AdditionalInfo[$key]
    }
    
    $script:BackupManifest.backup_manifest[$normalizedArchivePath] = $manifestEntry
    
    if (Get-Command Write-Log -ErrorAction SilentlyContinue) {
        Write-Log "Added Windows Settings to manifest: $ItemName ($ExportType)" -Level "DEBUG"
    }
}

function Add-RegistryToManifest {
    param (
        [string]$RegistryKey,
        [string]$ArchivePath,
        [string]$BackupItem,
        [string]$ItemName = ""
    )
    
    Add-WindowsSettingsToManifest -ItemId "registry" -ItemName $ItemName -Category $BackupItem -ArchivePath $ArchivePath -ExportType "registry" -OriginalLocation $RegistryKey -AdditionalInfo @{
        registry_key = $RegistryKey
        export_method = "regedit"
    }
}

function Add-SpecialItemToManifest {
    param (
        [string]$ItemType,
        [string]$ArchivePath,
        [string]$BackupItem,
        [hashtable]$SpecialInfo = @{}
    )
    
    $manifestEntry = @{
        original_path = ""
        backup_item = $BackupItem
        file_type = "special"
        archive_relative_path = $ArchivePath -replace '\\', '/' -replace '/+', '/'
        special_handling = @{
            item_type = $ItemType
        }
    }
    
    # Add special info
    foreach ($key in $SpecialInfo.Keys) {
        $manifestEntry.special_handling[$key] = $SpecialInfo[$key]
    }
    
    $script:BackupManifest.backup_manifest[$ArchivePath] = $manifestEntry
    
    if (Get-Command Write-Log -ErrorAction SilentlyContinue) {
        Write-Log "Added special item to manifest: $ItemType" -Level "DEBUG"
    }
}

function Finalize-BackupManifest {
    param (
        [string]$BackupPath,
        [string[]]$BackupItems
    )
    
    # Set final backup items list
    $script:BackupManifest.backup_info.backup_items = $BackupItems
    
    # Set total counts
    $script:BackupManifest.backup_info.total_entries = $script:BackupManifest.backup_manifest.Count
    
    # Create manifest file
    $manifestPath = Join-Path $BackupPath "manifest.json"
    
    try {
        $manifestJson = $script:BackupManifest | ConvertTo-Json -Depth 10
        $manifestJson | Out-File -FilePath $manifestPath -Encoding UTF8
        
        if (Get-Command Write-Log -ErrorAction SilentlyContinue) {
            Write-Log "Backup manifest created: $manifestPath" -Level "INFO"
            Write-Log "Manifest contains $($script:BackupManifest.backup_info.total_entries) entries" -Level "INFO"
        } else {
            Write-Host "Backup manifest created: $manifestPath" -ForegroundColor Green
            Write-Host "Manifest contains $($script:BackupManifest.backup_info.total_entries) entries" -ForegroundColor Green
        }
        
        return $manifestPath
    }
    catch {
        if (Get-Command Write-Log -ErrorAction SilentlyContinue) {
            Write-Log "Failed to create backup manifest: $_" -Level "ERROR"
        } else {
            Write-Error "Failed to create backup manifest: $_"
        }
        return $null
    }
}

#endregion

#region Manifest Reading Functions

function Read-BackupManifest {
    param (
        [string]$ManifestPath
    )
    
    if (-not (Test-Path $ManifestPath)) {
        if (Get-Command Write-Log -ErrorAction SilentlyContinue) {
            Write-Log "Manifest file not found: $ManifestPath" -Level "ERROR"
        } else {
            Write-Error "Manifest file not found: $ManifestPath"
        }
        return $null
    }
    
    try {
        $manifestContent = Get-Content $ManifestPath -Raw | ConvertFrom-Json
        if (Get-Command Write-Log -ErrorAction SilentlyContinue) {
            Write-Log "Successfully loaded manifest from $ManifestPath" -Level "INFO"
        } else {
            Write-Host "Successfully loaded manifest from $ManifestPath" -ForegroundColor Green
        }
        return $manifestContent
    }
    catch {
        if (Get-Command Write-Log -ErrorAction SilentlyContinue) {
            Write-Log "Failed to read manifest file: $_" -Level "ERROR"
        } else {
            Write-Error "Failed to read manifest file: $_"
        }
        return $null
    }
}

function Get-ManifestSummary {
    param (
        [PSCustomObject]$Manifest
    )
    
    if (-not $Manifest) {
        return $null
    }
    
    $summary = @{
        BackupInfo = $Manifest.backup_info
        FileTypes = @{}
        BackupItems = @{}
        Categories = @{}
    }
    
    # Analyze manifest entries
    foreach ($entry in $Manifest.backup_manifest.PSObject.Properties) {
        $manifestEntry = $entry.Value
        $fileType = $manifestEntry.file_type
        $backupItem = $manifestEntry.backup_item
        
        # Count by file type
        if (-not $summary.FileTypes.ContainsKey($fileType)) {
            $summary.FileTypes[$fileType] = 0
        }
        $summary.FileTypes[$fileType]++
        
        # Count by backup item
        if (-not $summary.BackupItems.ContainsKey($backupItem)) {
            $summary.BackupItems[$backupItem] = @{
                count = 0
                files = @()
            }
        }
        $summary.BackupItems[$backupItem].count++
        $summary.BackupItems[$backupItem].files += $manifestEntry
        
        # Windows Settings categories
        if ($fileType -eq "windows_settings" -and $manifestEntry.windows_settings) {
            $category = $manifestEntry.windows_settings.category
            if (-not $summary.Categories.ContainsKey($category)) {
                $summary.Categories[$category] = 0
            }
            $summary.Categories[$category]++
        }
    }
    
    return $summary
}

#endregion

#region Helper Functions

function Get-RelativeArchivePath {
    param (
        [string]$OriginalPath,
        [string]$TempBackupFolder,
        [string]$BackupItem
    )
    
    # This function helps determine the archive path within the backup structure
    # Based on the backup categorization logic from main.ps1
    
    $fileName = Split-Path $OriginalPath -Leaf
    
    # Use smart file naming if function is available, otherwise use simple naming
    if (Get-Command Get-SmartBackupFileName -ErrorAction SilentlyContinue) {
        $smartFileName = Get-SmartBackupFileName -SourcePath $OriginalPath
    } else {
        $smartFileName = $fileName
    }
    
    # Determine folder based on backup item
    $destinationFolder = switch ($BackupItem) {
        { $_ -in @("Logs") } { "Files" }
        { $_ -in @("Applications", "Notepad++", "WindowsTerminal") } { "Files/Applications" }
        { $_ -in @("TotalCommander") } { "Files" }
        { $_ -in @("Scripts") } { "Files" }
        { $_ -in @("PowerToys") } { "Files/PowerToys" }
        { $_ -in @("PowerShell") } { "Files/PowerShell" }
        { $_ -in @("Games") } { "Files/Games" }
        { $_ -in @("UserConfigs") } { "Files/UserConfigs" }
        { $_ -in @("Browsers") } { "Files/Browsers" }
        { $_ -in @("SystemFiles") } { "Files/System" }
        { $_ -in @("Import") } { "Files/Import" }
        default { "Files/Other" }
    }
    
    return "$destinationFolder/$smartFileName"
}

#endregion

# Functions are available through dot-sourcing