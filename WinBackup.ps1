#Requires -Version 5.1

<#
.SYNOPSIS
    Windows Settings Backup Module
    
.DESCRIPTION
    Handles Windows registry settings, configuration files, and system settings backup.
    Integrates with the main backup system for compression and destinations.
    Now includes manifest generation for comprehensive restoration support.
    
.NOTES
    Version: 2.0
    Used by: Main.ps1 via Backup_MGR.ps1
    Requires: BackupUtilities.ps1, ManifestUtilities.ps1
#>

# Import shared utilities
. "$PSScriptRoot\BackupUtilities.ps1"
. "$PSScriptRoot\ManifestUtilities.ps1"

#region Main Windows Settings Backup Function

function Invoke-WindowsSettingsBackup {
    param (
        $Config,
        [string]$BackupType,
        [string]$Destination,
        [int]$CompressionLevel = 5
    )
    
    Write-Log "Starting Windows Settings Backup: Type=$BackupType, Destination=$Destination" -Level "INFO"
    
    # Validate backup type is Windows settings
    if (-not $BackupType.StartsWith("WinSettings-")) {
        throw "Invalid Windows Settings backup type: $BackupType"
    }
    
    # Get backup items for this type
    $backupItems = $Config.BackupTypes.$BackupType
    if (-not $backupItems) {
        throw "No backup items found for type: $BackupType"
    }
    
    # Create temporary backup directory
    $timestamp = Get-Date -Format "yyyyMMdd-HHmmss"
    $backupName = "${BackupType}_${timestamp}"
    $tempBackupFolder = Join-Path $Config.TempPath $backupName
    
    # Ensure temp directory exists
    if (-not (Test-Path $Config.TempPath)) {
        New-Item -ItemType Directory -Path $Config.TempPath -Force | Out-Null
        Write-Log "Created temp directory: $($Config.TempPath)" -Level "INFO"
    }
    
    try {
        # Initialize Windows backup directory structure
        Initialize-WindowsBackupDirectory -Path $tempBackupFolder
        
        # Initialize backup manifest for Windows Settings
        Initialize-BackupManifest -BackupType $BackupType -BackupName $backupName -Timestamp $timestamp
        Write-Log "Initialized Windows Settings backup manifest" -Level "INFO"
        
        Write-Log "Processing $($backupItems.Count) Windows settings categories" -Level "INFO"
        
        $totalItems = $backupItems.Count
        $currentItem = 0
        $successCount = 0
        
        # Process each backup category
        foreach ($categoryName in $backupItems) {
            $currentItem++
            $percentComplete = [math]::Round(($currentItem / $totalItems) * 100)
            Show-Progress -PercentComplete $percentComplete -Status "Processing $categoryName"
            
            Write-Log "Processing Windows settings category: $categoryName" -Level "INFO"
            
            try {
                $category = $Config.BackupItems.$categoryName
                if ($category) {
                    $result = Invoke-WindowsSettingsCategory -Category $category -CategoryName $categoryName -BackupPath $tempBackupFolder
                    if ($result) {
                        $successCount++
                    }
                } else {
                    Write-Log "Category not found in config: $categoryName" -Level "WARNING"
                }
            }
            catch {
                Write-Log "Error processing category $categoryName : $_" -Level "ERROR"
            }
        }
        
        Write-Host "`n" # New line after progress
        Write-Log "Windows settings backup completed: $successCount/$totalItems categories processed" -Level "INFO"
        
        # Finalize manifest before compression
        $manifestPath = Finalize-BackupManifest -BackupPath $tempBackupFolder -BackupItems $backupItems
        if ($manifestPath) {
            Write-Log "Windows Settings backup manifest created successfully" -Level "INFO"
        } else {
            Write-Log "Failed to create Windows Settings backup manifest - restore functionality may be limited" -Level "WARNING"
        }
        
        # Get destination configuration
        $destinationConfig = $Config.Destinations.$Destination
        
        # Compress backup
        if ($Destination -eq "SSH") {
            # For SSH, use the SSH backup function
            $sshConfig = $Config.Destinations.SSH
            $sourcePaths = @((Resolve-Path $tempBackupFolder).Path)
            $success = Backup-ToSSH -SourcePaths $sourcePaths `
                                   -RemoteHost $sshConfig.RemoteHost `
                                   -RemotePath $sshConfig.RemotePath `
                                   -SSHKeyPath $sshConfig.SSHKeyPath `
                                   -BackupName $backupName `
                                   -SevenZipPath $Config.Tools.'7Zip' `
                                   -TempPath $Config.TempPath
            
            if (-not $success) {
                throw "SSH backup failed"
            }
            
            $finalBackupPath = "$($sshConfig.RemoteHost):$($sshConfig.RemotePath)/$backupName"
            $backupSize = 0 # Can't easily get remote file size
        }
        else {
            # For local and network destinations
            if ($Destination -eq "HomeNet") {
                $destinationPath = Join-Path $destinationConfig.Path $backupName
            } else {
                $destinationPath = Join-Path $destinationConfig $backupName
            }
            
            # Ensure destination directory exists
            if (-not (Test-Path $destinationPath)) {
                New-Item -ItemType Directory -Path $destinationPath -Force | Out-Null
            }
            
            # Compress the backup
            $sourcePaths = @((Resolve-Path $tempBackupFolder).Path)
            $compressedBackup = Compress-Backup -SourcePaths $sourcePaths `
                                               -DestinationPath $destinationPath `
                                               -ArchiveName $backupName `
                                               -SevenZipPath $Config.Tools.'7Zip' `
                                               -CompressionLevel $CompressionLevel `
                                               -TempPath $Config.TempPath
            
            if (-not $compressedBackup) {
                throw "Compression failed"
            }
            
            $finalBackupPath = $compressedBackup
            $backupSize = (Get-Item $compressedBackup).Length
            
            # Verify backup
            $backupHash = Verify-Backup -BackupFile $compressedBackup
            if ($backupHash) {
                Write-Log "Windows settings backup verified. Hash: $backupHash" -Level "INFO"
            } else {
                Write-Log "Backup verification failed" -Level "WARNING"
            }
            
            # Manage backup versions
            Manage-BackupVersions -BackupDirectory (Split-Path $compressedBackup -Parent) -VersionsToKeep $Config.BackupVersions
        }
        
        # Update backup database
        $destinationType = if ($Destination -eq "SSH") { "SSH" } elseif ($Destination -eq "HomeNet") { "NetworkShare" } else { "Local" }
        
        Update-BackupDatabase -BackupSetName $backupName `
                             -BackupType $BackupType `
                             -DestinationType $destinationType `
                             -DestinationPath $finalBackupPath `
                             -SizeBytes $backupSize `
                             -CompressionMethod "7zip" `
                             -EncryptionMethod "" `
                             -SourcePaths $backupItems `
                             -AdditionalMetadata "Windows Settings Backup with Manifest"
        
        Write-Log "Windows settings backup completed successfully: $finalBackupPath" -Level "INFO"
        return $finalBackupPath
    }
    catch {
        Write-Log "Windows settings backup failed: $_" -Level "ERROR"
        throw $_
    }
    finally {
        # Clean up temporary folder
        if (Test-Path $tempBackupFolder) {
            Remove-Item -Path $tempBackupFolder -Recurse -Force -ErrorAction SilentlyContinue
            Write-Log "Cleaned up temporary backup folder" -Level "INFO"
        }
    }
}

#endregion

#region Category Processing Functions

function Invoke-WindowsSettingsCategory {
    param (
        $Category,
        [string]$CategoryName,
        [string]$BackupPath
    )
    
    if (-not $Category.items) {
        Write-Log "No items found in category: $CategoryName" -Level "WARNING"
        return $false
    }
    
    $successCount = 0
    $totalItems = $Category.items.Count
    
    Write-Log "Processing $totalItems items in category: $CategoryName" -Level "INFO"
    
    foreach ($item in $Category.items) {
        try {
            $result = Invoke-WindowsSettingsItem -Item $item -BackupPath $BackupPath -CategoryName $CategoryName
            if ($result) {
                $successCount++
            }
        }
        catch {
            Write-Log "Error processing item $($item.name): $_" -Level "ERROR"
        }
    }
    
    Write-Log "Category $CategoryName completed: $successCount/$totalItems items processed" -Level "INFO"
    return ($successCount -gt 0)
}

function Invoke-WindowsSettingsItem {
    param (
        $Item,
        [string]$BackupPath,
        [string]$CategoryName
    )
    
    $itemName = $Item.name
    $itemId = $Item.id
    Write-Log "Processing item $itemId : $itemName" -Level "DEBUG"
    
    $hasSuccess = $false
    
    # Handle registry keys
    if ($Item.registry_keys) {
        foreach ($regKey in $Item.registry_keys) {
            $fileName = "$itemId-$($regKey.Replace('\','_').Replace(':',''))"
            $result = Export-RegistryKey -KeyPath $regKey -FileName $fileName -BackupDir $BackupPath
            if ($result) { 
                $hasSuccess = $true
                
                # Add to manifest
                $archivePath = "Registry/$fileName.reg"
                Add-RegistryToManifest -RegistryKey $regKey -ArchivePath $archivePath -BackupItem $CategoryName -ItemName $itemName
            }
        }
    }
    
    # Handle files
    if ($Item.files) {
        foreach ($filePath in $Item.files) {
            $fileName = Split-Path $filePath -Leaf
            $destPath = Join-Path $BackupPath "Files\$fileName"
            $result = Copy-WindowsSettingsFile -SourcePath $filePath -DestinationPath $destPath -Description $itemName
            if ($result) { 
                $hasSuccess = $true
                
                # Add to manifest
                $archivePath = "Files/$fileName"
                Add-WindowsSettingsToManifest -ItemId $itemId -ItemName $itemName -Category $CategoryName -ArchivePath $archivePath -ExportType "file" -OriginalLocation $filePath
            }
        }
    }
    
    # Handle folders
    if ($Item.folders) {
        foreach ($folderPath in $Item.folders) {
            $folderName = if ($folderPath -eq "SendTo") { "SendTo" } else { Split-Path $folderPath -Leaf }
            $destPath = Join-Path $BackupPath "Files\$folderName"
            $result = Copy-WindowsSettingsFolder -SourcePath $folderPath -DestinationPath $destPath -Description $itemName
            if ($result) { 
                $hasSuccess = $true
                
                # Add to manifest
                $archivePath = "Files/$folderName"
                Add-WindowsSettingsToManifest -ItemId $itemId -ItemName $itemName -Category $CategoryName -ArchivePath $archivePath -ExportType "folder" -OriginalLocation $folderPath
            }
        }
    }
    
    # Handle export commands
    if ($Item.export_command) {
        $result = Invoke-ExportCommand -Command $Item.export_command -ItemId $itemId -ItemName $itemName -BackupPath $BackupPath -CategoryName $CategoryName
        if ($result) { 
            $hasSuccess = $true 
        }
    }
    
    if ($hasSuccess) {
        Write-Log "Successfully processed: $itemName" -Level "INFO"
    } else {
        Write-Log "No data exported for: $itemName" -Level "WARNING"
    }
    
    return $hasSuccess
}

#endregion

#region Export Command Handlers

function Invoke-ExportCommand {
    param (
        [string]$Command,
        [int]$ItemId,
        [string]$ItemName,
        [string]$BackupPath,
        [string]$CategoryName
    )
    
    try {
        switch ($Command) {
            "powercfg" {
                $result = Export-PowerSettings -BackupPath $BackupPath
                if ($result) {
                    # Add to manifest
                    Add-WindowsSettingsToManifest -ItemId $ItemId -ItemName $ItemName -Category $CategoryName -ArchivePath "Lists/PowerSchemes.txt" -ExportType "command_export" -AdditionalInfo @{
                        command = "powercfg"
                        output_files = @("Lists/PowerSchemes.txt", "Lists/CurrentPowerScheme.txt")
                    }
                }
                return $result
            }
            "Get-ScheduledTask" {
                $result = Export-ScheduledTasks -BackupPath $BackupPath
                if ($result) {
                    # Add to manifest
                    Add-WindowsSettingsToManifest -ItemId $ItemId -ItemName $ItemName -Category $CategoryName -ArchivePath "Lists/ScheduledTasks.csv" -ExportType "command_export" -AdditionalInfo @{
                        command = "Get-ScheduledTask"
                        output_files = @("Lists/ScheduledTasks.csv", "Files/Tasks/*.xml")
                    }
                }
                return $result
            }
            "Get-EnvironmentVariables-User" {
                $result = Export-UserEnvironmentVariables -BackupPath $BackupPath
                if ($result) {
                    # Add to manifest
                    Add-WindowsSettingsToManifest -ItemId $ItemId -ItemName $ItemName -Category $CategoryName -ArchivePath "Lists/UserEnvironmentVariables.json" -ExportType "command_export" -AdditionalInfo @{
                        command = "Get-EnvironmentVariables-User"
                        output_files = @("Lists/UserEnvironmentVariables.json")
                    }
                }
                return $result
            }
            "Get-EnvironmentVariables-Machine" {
                $result = Export-SystemEnvironmentVariables -BackupPath $BackupPath
                if ($result) {
                    # Add to manifest
                    Add-WindowsSettingsToManifest -ItemId $ItemId -ItemName $ItemName -Category $CategoryName -ArchivePath "Lists/SystemEnvironmentVariables.json" -ExportType "command_export" -AdditionalInfo @{
                        command = "Get-EnvironmentVariables-Machine"
                        output_files = @("Lists/SystemEnvironmentVariables.json")
                    }
                }
                return $result
            }
            "Get-WindowsOptionalFeature" {
                $result = Export-WindowsFeatures -BackupPath $BackupPath
                if ($result) {
                    # Add to manifest
                    Add-WindowsSettingsToManifest -ItemId $ItemId -ItemName $ItemName -Category $CategoryName -ArchivePath "Lists/WindowsFeatures.csv" -ExportType "command_export" -AdditionalInfo @{
                        command = "Get-WindowsOptionalFeature"
                        output_files = @("Lists/WindowsFeatures.csv", "Lists/WindowsCapabilities.csv")
                    }
                }
                return $result
            }
            "Get-Service" {
                $result = Export-ServiceSettings -BackupPath $BackupPath
                if ($result) {
                    # Add to manifest
                    Add-WindowsSettingsToManifest -ItemId $ItemId -ItemName $ItemName -Category $CategoryName -ArchivePath "Lists/CustomServiceStartupTypes.csv" -ExportType "command_export" -AdditionalInfo @{
                        command = "Get-Service"
                        output_files = @("Lists/CustomServiceStartupTypes.csv")
                    }
                }
                return $result
            }
            "Get-MpPreference" {
                $result = Export-DefenderSettings -BackupPath $BackupPath
                if ($result) {
                    # Add to manifest
                    Add-WindowsSettingsToManifest -ItemId $ItemId -ItemName $ItemName -Category $CategoryName -ArchivePath "Lists/WindowsDefenderExclusions.json" -ExportType "command_export" -AdditionalInfo @{
                        command = "Get-MpPreference"
                        output_files = @("Lists/WindowsDefenderExclusions.json")
                    }
                }
                return $result
            }
			"cmdkey /list" {
				$result = Export-CredentialManager -OutputPath (Join-Path $BackupPath "Lists\CredentialManagerList.txt")
                if ($result) {
                    # Add to manifest
                    Add-WindowsSettingsToManifest -ItemId $ItemId -ItemName $ItemName -Category $CategoryName -ArchivePath "Lists/CredentialManagerList.txt" -ExportType "command_export" -AdditionalInfo @{
                        command = "cmdkey /list"
                        output_files = @("Lists/CredentialManagerList.txt")
                        security_note = "Passwords not included for security"
                    }
                }
                return $result
            }
            "Get-ChildItem Cert:\CurrentUser\My" {
                $result = Export-PersonalCertificates -BackupPath $BackupPath
                if ($result) {
                    # Add to manifest
                    Add-WindowsSettingsToManifest -ItemId $ItemId -ItemName $ItemName -Category $CategoryName -ArchivePath "Lists/PersonalCertificates.csv" -ExportType "command_export" -AdditionalInfo @{
                        command = "Get-ChildItem Cert:\CurrentUser\My"
                        output_files = @("Lists/PersonalCertificates.csv")
                    }
                }
                return $result
            }
            "Get-WmiObject Win32_MappedLogicalDisk" {
                $result = Export-NetworkDrives -BackupPath $BackupPath
                if ($result) {
                    # Add to manifest
                    Add-WindowsSettingsToManifest -ItemId $ItemId -ItemName $ItemName -Category $CategoryName -ArchivePath "Lists/MappedNetworkDrives.csv" -ExportType "command_export" -AdditionalInfo @{
                        command = "Get-WmiObject Win32_MappedLogicalDisk"
                        output_files = @("Lists/MappedNetworkDrives.csv", "Scripts/map_drives.cmd")
                        restoration_script = "Scripts/map_drives.cmd"
                    }
                }
                return $result
            }
            "Get-WinEvent" {
                $result = Export-EventLogs -BackupPath $BackupPath
                if ($result) {
                    # Add to manifest
                    Add-WindowsSettingsToManifest -ItemId $ItemId -ItemName $ItemName -Category $CategoryName -ArchivePath "Lists/EventLog_System.csv" -ExportType "command_export" -AdditionalInfo @{
                        command = "Get-WinEvent"
                        output_files = @("Lists/EventLog_System.csv", "Lists/EventLog_Application.csv", "Files/EventViewer/*")
                    }
                }
                return $result
            }
            "wsl_export" {
                $result = Export-WSLConfiguration -BackupPath $BackupPath
                if ($result) {
                    # Add to manifest
                    Add-WindowsSettingsToManifest -ItemId $ItemId -ItemName $ItemName -Category $CategoryName -ArchivePath "Lists/WSLDistributions.txt" -ExportType "command_export" -AdditionalInfo @{
                        command = "wsl --list --verbose"
                        output_files = @("Lists/WSLDistributions.txt", "Files/wslconfig")
                    }
                }
                return $result
            }
            "winget_export" {
                $result = Export-WingetPackages -BackupPath $BackupPath
                if ($result) {
                    # Add to manifest
                    Add-WindowsSettingsToManifest -ItemId $ItemId -ItemName $ItemName -Category $CategoryName -ArchivePath "Lists/WingetSoftware.json" -ExportType "command_export" -AdditionalInfo @{
                        command = "winget export"
                        output_files = @("Lists/WingetSoftware.json")
                        restoration_command = "winget import Lists/WingetSoftware.json"
                    }
                }
                return $result
            }
            "Export-PythonPackages" {
                $result = Export-PythonPackages -BackupPath $BackupPath
                if ($result) {
                    # Add to manifest
                    Add-WindowsSettingsToManifest -ItemId $ItemId -ItemName $ItemName -Category $CategoryName -ArchivePath "Lists/PythonRequirements.txt" -ExportType "command_export" -AdditionalInfo @{
                        command = "pip freeze"
                        output_files = @("Lists/PythonRequirements.txt")
                        restoration_command = "pip install -r Lists/PythonRequirements.txt"
                    }
                }
                return $result
            }
            "choco list --localonly" {
                $result = Export-ChocolateyPackages -BackupPath $BackupPath
                if ($result) {
                    # Add to manifest
                    Add-WindowsSettingsToManifest -ItemId $ItemId -ItemName $ItemName -Category $CategoryName -ArchivePath "Lists/ChocolateyPackages.config" -ExportType "command_export" -AdditionalInfo @{
                        command = "choco list --localonly"
                        output_files = @("Lists/ChocolateyPackages.config", "Scripts/InstallChocolateyPackages.ps1")
                        restoration_script = "Scripts/InstallChocolateyPackages.ps1"
                    }
                }
                return $result
            }
            "cargo install --list" {
                $result = Export-CargoPackages -BackupPath $BackupPath
                if ($result) {
                    # Add to manifest
                    Add-WindowsSettingsToManifest -ItemId $ItemId -ItemName $ItemName -Category $CategoryName -ArchivePath "Lists/CargoPackages.txt" -ExportType "command_export" -AdditionalInfo @{
                        command = "cargo install --list"
                        output_files = @("Lists/CargoPackages.txt", "Scripts/InstallCargoPackages.ps1")
                        restoration_script = "Scripts/InstallCargoPackages.ps1"
                    }
                }
                return $result
            }
            "dism /online /Export-DefaultAppAssociations" {
                $result = Export-DefaultAppAssociations -BackupPath $BackupPath
                if ($result) {
                    # Add to manifest
                    Add-WindowsSettingsToManifest -ItemId $ItemId -ItemName $ItemName -Category $CategoryName -ArchivePath "Lists/DefaultAppAssociations.xml" -ExportType "command_export" -AdditionalInfo @{
                        command = "dism /online /Export-DefaultAppAssociations"
                        output_files = @("Lists/DefaultAppAssociations.xml")
                        restoration_command = "dism /online /Import-DefaultAppAssociations:Lists/DefaultAppAssociations.xml"
                    }
                }
                return $result
            }
            default {
                Write-Log "Unknown export command: $Command" -Level "WARNING"
                return $false
            }
        }
    }
    catch {
        Write-Log "Error executing export command '$Command': $_" -Level "ERROR"
        return $false
    }
}

#endregion

#region Specific Export Functions

function Export-PowerSettings {
    param ([string]$BackupPath)
    
    try {
        # FIXED: Ensure Lists directory exists
        $listsPath = Join-Path $BackupPath "Lists"
        if (-not (Test-Path $listsPath)) {
            New-Item -ItemType Directory -Path $listsPath -Force | Out-Null
        }
        
        # Export power schemes list
        $powerOutput = powercfg /list 2>&1 | Out-String
        $powerOutput | Out-File "$BackupPath\Lists\PowerSchemes.txt" -Encoding UTF8
        
        # Export current power scheme details
        $currentScheme = (powercfg /getactivescheme).Split()[3]
        powercfg /query $currentScheme | Out-File "$BackupPath\Lists\CurrentPowerScheme.txt" -Encoding UTF8
        
        Write-Log "Exported power management settings" -Level "INFO"
        return $true
    }
    catch {
        Write-Log "Failed to export power settings: $_" -Level "ERROR"
        return $false
    }
}

function Export-ScheduledTasks {
    param ([string]$BackupPath)
    
    try {
        # FIXED: Ensure Lists and Files/Tasks directories exist
        $listsPath = Join-Path $BackupPath "Lists"
        if (-not (Test-Path $listsPath)) {
            New-Item -ItemType Directory -Path $listsPath -Force | Out-Null
        }
        
        $tasks = Get-ScheduledTask | Where-Object { $_.TaskPath -notlike "\Microsoft\*" -and $_.Author -ne "Microsoft Corporation" }
        $taskList = @()
        
        $tasksPath = Join-Path $BackupPath "Files\Tasks"
        if (-not (Test-Path $tasksPath)) {
            New-Item -ItemType Directory -Path $tasksPath -Force | Out-Null
        }
        
        foreach ($task in $tasks) {
            $taskInfo = [PSCustomObject]@{
                Name = $task.TaskName
                Path = $task.TaskPath
                Author = $task.Author
                Description = $task.Description
                State = $task.State
            }
            $taskList += $taskInfo
            
            # Export individual task XML
            try {
                $xml = Export-ScheduledTask -TaskName $task.TaskName -TaskPath $task.TaskPath
                $safeTaskName = $task.TaskName -replace '[\\/:*?"<>|]', '_'
                $xml | Out-File "$tasksPath\$safeTaskName.xml" -Encoding UTF8
            }
            catch {
                Write-Log "Failed to export task: $($task.TaskName)" -Level "WARNING"
            }
        }
        
        $taskList | Export-Csv "$BackupPath\Lists\ScheduledTasks.csv" -NoTypeInformation
        Write-Log "Exported $($taskList.Count) custom scheduled tasks" -Level "INFO"
        return $true
    }
    catch {
        Write-Log "Failed to export scheduled tasks: $_" -Level "ERROR"
        return $false
    }
}

function Export-UserEnvironmentVariables {
    param ([string]$BackupPath)
    
    try {
        # FIXED: Ensure Lists directory exists
        $listsPath = Join-Path $BackupPath "Lists"
        if (-not (Test-Path $listsPath)) {
            New-Item -ItemType Directory -Path $listsPath -Force | Out-Null
        }
        
        $userVars = [Environment]::GetEnvironmentVariables("User")
        $userVars | ConvertTo-Json -Depth 3 | Out-File "$BackupPath\Lists\UserEnvironmentVariables.json" -Encoding UTF8
        Write-Log "Exported user environment variables" -Level "INFO"
        return $true
    }
    catch {
        Write-Log "Failed to export user environment variables: $_" -Level "ERROR"
        return $false
    }
}

function Export-SystemEnvironmentVariables {
    param ([string]$BackupPath)
    
    try {
        # FIXED: Ensure Lists directory exists
        $listsPath = Join-Path $BackupPath "Lists"
        if (-not (Test-Path $listsPath)) {
            New-Item -ItemType Directory -Path $listsPath -Force | Out-Null
        }
        
        $systemVars = [Environment]::GetEnvironmentVariables("Machine")
        $systemVars | ConvertTo-Json -Depth 3 | Out-File "$BackupPath\Lists\SystemEnvironmentVariables.json" -Encoding UTF8
        Write-Log "Exported system environment variables" -Level "INFO"
        return $true
    }
    catch {
        Write-Log "Failed to export system environment variables: $_" -Level "ERROR"
        return $false
    }
}

function Export-WindowsFeatures {
    param ([string]$BackupPath)
    
    try {
        # FIXED: Ensure Lists directory exists
        $listsPath = Join-Path $BackupPath "Lists"
        if (-not (Test-Path $listsPath)) {
            New-Item -ItemType Directory -Path $listsPath -Force | Out-Null
        }
        
        # Windows Features
        $features = Get-WindowsOptionalFeature -Online | Select-Object FeatureName, State
        $features | Export-Csv "$BackupPath\Lists\WindowsFeatures.csv" -NoTypeInformation
        
        # Windows Capabilities (Optional Features)
        $capabilities = Get-WindowsCapability -Online | Select-Object Name, State
        $capabilities | Export-Csv "$BackupPath\Lists\WindowsCapabilities.csv" -NoTypeInformation
        
        Write-Log "Exported Windows features and capabilities" -Level "INFO"
        return $true
    }
    catch {
        Write-Log "Failed to export Windows features: $_" -Level "ERROR"
        return $false
    }
}

function Export-ServiceSettings {
    param ([string]$BackupPath)
    
    try {
        # FIXED: Ensure Lists directory exists
        $listsPath = Join-Path $BackupPath "Lists"
        if (-not (Test-Path $listsPath)) {
            New-Item -ItemType Directory -Path $listsPath -Force | Out-Null
        }
        
        # Get services with modified startup types
        $services = Get-Service -ErrorAction SilentlyContinue | Where-Object { 
            $_.StartType -notin @('Manual', 'Automatic', 'Disabled') 
        }
        $customServices = @()
        
        foreach ($service in $services) {
            try {
                $customServices += [PSCustomObject]@{
                    Name = $service.Name
                    DisplayName = $service.DisplayName
                    StartType = $service.StartType
                    Status = $service.Status
                }
            }
            catch {
                continue
            }
        }
        
        $customServices | Export-Csv "$BackupPath\Lists\CustomServiceStartupTypes.csv" -NoTypeInformation
        Write-Log "Exported custom service startup types" -Level "INFO"
        return $true
    }
    catch {
        Write-Log "Failed to export service settings: $_" -Level "ERROR"
        return $false
    }
}

function Export-DefenderSettings {
    param ([string]$BackupPath)
    
    try {
        # Ensure Lists directory exists
        $listsPath = Join-Path $BackupPath "Lists"
        Ensure-Directory $listsPath
        
        $exclusions = @{
            PathExclusions = Get-MpPreference | Select-Object -ExpandProperty ExclusionPath -ErrorAction SilentlyContinue
            ExtensionExclusions = Get-MpPreference | Select-Object -ExpandProperty ExclusionExtension -ErrorAction SilentlyContinue
            ProcessExclusions = Get-MpPreference | Select-Object -ExpandProperty ExclusionProcess -ErrorAction SilentlyContinue
        }
        $exclusions | ConvertTo-Json -Depth 3 | Out-File "$BackupPath\Lists\WindowsDefenderExclusions.json" -Encoding UTF8
        Write-Log "Exported Windows Defender exclusions" -Level "INFO"
        return $true
    }
    catch {
        Write-Log "Failed to export Defender settings: $_" -Level "ERROR"
        return $false
    }
}

function Export-CredentialManager {
    param ([string]$BackupPath)
    
    try {
        # Ensure Lists directory exists
        $listsPath = Join-Path $BackupPath "Lists"
        Ensure-Directory $listsPath
        
        $creds = cmdkey /list 2>$null | Out-String
        $creds | Out-File "$BackupPath\Lists\CredentialManagerList.txt" -Encoding UTF8
        Write-Log "Exported Credential Manager list (passwords not included for security)" -Level "INFO"
        return $true
    }
    catch {
        Write-Log "Failed to export credential manager list: $_" -Level "ERROR"
        return $false
    }
}

function Export-PersonalCertificates {
    param ([string]$BackupPath)
    
    try {
        # Ensure Lists directory exists
        $listsPath = Join-Path $BackupPath "Lists"
        Ensure-Directory $listsPath
        
        $certs = Get-ChildItem -Path Cert:\CurrentUser\My | Select-Object Subject, Issuer, Thumbprint, NotAfter
        $certs | Export-Csv "$BackupPath\Lists\PersonalCertificates.csv" -NoTypeInformation
        Write-Log "Exported personal certificates list" -Level "INFO"
        return $true
    }
    catch {
        Write-Log "Failed to export personal certificates: $_" -Level "ERROR"
        return $false
    }
}

function Export-NetworkDrives {
    param ([string]$BackupPath)
    
    try {
        # Ensure Lists and Scripts directories exist
        $listsPath = Join-Path $BackupPath "Lists"
        $scriptsPath = Join-Path $BackupPath "Scripts"
        Ensure-Directory $listsPath
        Ensure-Directory $scriptsPath
        
        # Get all mapped network drives
        $mappedDrives = @()
        Get-WmiObject -Class Win32_MappedLogicalDisk | ForEach-Object {
            $mappedDrives += [PSCustomObject]@{
                DriveLetter = $_.DeviceID
                NetworkPath = $_.ProviderName
                Label = $_.VolumeName
            }
        }
        
        if ($mappedDrives.Count -eq 0) {
            Write-Log "No mapped network drives found" -Level "INFO"
            return $true
        }
        
        # Export to CSV (existing functionality)
        $mappedDrives | Export-Csv "$BackupPath\Lists\MappedNetworkDrives.csv" -NoTypeInformation
        Write-Log "Exported mapped network drives to CSV" -Level "INFO"
        
        # NEW: Create restoration batch file
        $cmdFile = "$BackupPath\Scripts\map_drives.cmd"
        
        # Get stored credentials for enhanced batch file
        $storedCredentials = Get-StoredNetworkCredentials
        
        # Create the batch file content
        $batchContent = @()
        $batchContent += "@echo off"
        $batchContent += "REM Mapped Network Drives Restoration Script"
        $batchContent += "REM Generated on: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
        $batchContent += "REM Part of Windows Settings Backup"
        $batchContent += "REM"
        $batchContent += "REM Instructions:"
        $batchContent += "REM 1. Review and edit credentials below as needed"
        $batchContent += "REM 2. Run this script as Administrator"
        $batchContent += "REM 3. Drives will be mapped with persistent connections"
        $batchContent += ""
        $batchContent += "echo Restoring network drive mappings..."
        $batchContent += ""
        
        $driveCount = 0
        
        foreach ($drive in $mappedDrives) {
            $driveCount++
            $driveLetter = $drive.DriveLetter
            $networkPath = $drive.NetworkPath
            $volumeName = $drive.Label
            
            # Try to find credentials for this path
            $username = Find-NetworkCredentialForPath -NetworkPath $networkPath -StoredCredentials $storedCredentials
            
            $batchContent += "REM Drive ${driveCount}: $driveLetter"
            if ($volumeName) {
                $batchContent += "REM Volume: $volumeName"
            }
            $batchContent += "REM Path: $networkPath"
            
            if ($username) {
                $batchContent += "REM Found stored username: $username"
                $batchContent += "echo Mapping $driveLetter to $networkPath (user: $username)"
                $batchContent += "net use $driveLetter `"$networkPath`" /user:$username * /persistent:yes"
                $batchContent += "if errorlevel 1 echo ERROR: Failed to map $driveLetter"
            } else {
                $batchContent += "REM No stored credentials found - please enter manually"
                $batchContent += "echo Mapping $driveLetter to $networkPath (enter credentials when prompted)"
                $batchContent += "net use $driveLetter `"$networkPath`" /persistent:yes"
                $batchContent += "if errorlevel 1 echo ERROR: Failed to map $driveLetter"
            }
            
            $batchContent += ""
        }
        
        $batchContent += "echo."
        $batchContent += "echo Drive mapping restoration completed!"
        $batchContent += "echo Check above for any errors."
        $batchContent += "echo."
        $batchContent += "pause"
        
        # Write the batch file
        $batchContent | Out-File -FilePath $cmdFile -Encoding ASCII
        
        Write-Log "Created network drive restoration script: $cmdFile" -Level "INFO"
        Write-Log "Exported $($mappedDrives.Count) mapped network drives" -Level "INFO"
        return $true
    }
    catch {
        Write-Log "Failed to export network drives: $_" -Level "ERROR"
        return $false
    }
}

function Get-StoredNetworkCredentials {
    <#
    .SYNOPSIS
    Helper function to get stored network credentials from Windows Credential Manager
    #>
    
    $credentials = @{}
    
    try {
        # Get stored credentials using cmdkey
        $cmdkeyOutput = cmdkey /list 2>$null
        
        if ($cmdkeyOutput) {
            $currentTarget = ""
            $currentUser = ""
            
            foreach ($line in $cmdkeyOutput) {
                if ($line -match "Target:\s*(.+)") {
                    $currentTarget = $matches[1].Trim()
                }
                elseif ($line -match "User:\s*(.+)") {
                    $currentUser = $matches[1].Trim()
                    if ($currentTarget -and $currentUser) {
                        $credentials[$currentTarget] = $currentUser
                    }
                }
            }
        }
        
        Write-Log "Found $($credentials.Count) stored network credentials" -Level "DEBUG"
        return $credentials
    }
    catch {
        Write-Log "Could not access stored credentials: $_" -Level "WARNING"
        return @{}
    }
}

function Find-NetworkCredentialForPath {
    param(
        [string]$NetworkPath,
        [hashtable]$StoredCredentials
    )
    
    # Try exact match first
    if ($StoredCredentials.ContainsKey($NetworkPath)) {
        return $StoredCredentials[$NetworkPath]
    }
    
    # Try to find by server name
    if ($NetworkPath -match "\\\\([^\\]+)") {
        $serverName = $matches[1]
        
        # Look for credentials that match the server
        foreach ($target in $StoredCredentials.Keys) {
            if ($target -like "*$serverName*") {
                return $StoredCredentials[$target]
            }
        }
    }
    
    return $null
}

function Export-EventLogs {
    param ([string]$BackupPath)
    
    try {
        $logTypes = @("System", "Application")
        $eventLevels = @(1, 2, 3) # Critical, Error, Warning
        
        foreach ($logType in $logTypes) {
            $events = Get-WinEvent -FilterHashtable @{LogName=$logType; Level=$eventLevels} -MaxEvents 1000 -ErrorAction SilentlyContinue
            if ($events) {
                $events | Select-Object TimeCreated, Id, LevelDisplayName, LogName, ProviderName, Message | 
                    Export-Csv "$BackupPath\Lists\EventLog_$logType.csv" -NoTypeInformation
            }
        }
        
        # Also backup custom Event Viewer views if they exist
        $eventViewerPath = "$env:PROGRAMDATA\Microsoft\Event Viewer\Views"
        if (Test-Path $eventViewerPath) {
            $destEventPath = Join-Path $BackupPath "Files\EventViewer"
            Copy-WindowsSettingsFolder -SourcePath $eventViewerPath -DestinationPath $destEventPath
        }
        
        Write-Log "Exported event logs and custom views" -Level "INFO"
        return $true
    }
    catch {
        Write-Log "Failed to export event logs: $_" -Level "ERROR"
        return $false
    }
}

function Export-WSLConfiguration {
    param ([string]$BackupPath)
    
    try {
        # Export WSL distributions list
        $wslList = wsl --list --verbose 2>$null | Out-String
        $wslList | Out-File "$BackupPath\Lists\WSLDistributions.txt" -Encoding UTF8
        
        # Export WSL configuration file if it exists
        $wslConfigPath = $ExecutionContext.InvokeCommand.ExpandString('$env:USERPROFILE\.wslconfig')
        if (Test-Path $wslConfigPath) {
            Copy-Item $wslConfigPath "$BackupPath\Files\wslconfig" -Force
        }
        
        Write-Log "Exported WSL configuration" -Level "INFO"
        return $true
    }
    catch {
        Write-Log "Failed to export WSL configuration: $_" -Level "WARNING"
        return $false
    }
}

function Export-WingetPackages {
    param ([string]$BackupPath)
    
    try {
        # Ensure Lists directory exists
        $listsPath = Join-Path $BackupPath "Lists"
        if (-not (Test-Path $listsPath)) {
            New-Item -ItemType Directory -Path $listsPath -Force | Out-Null
        }
        
        $outputPath = Join-Path $listsPath "WingetSoftware.json"
        
        if (Get-Command winget -ErrorAction SilentlyContinue) {
            Write-Log "Attempting winget export to: $outputPath" -Level "DEBUG"
            
            # Use winget export command with proper error handling
            $process = Start-Process -FilePath "winget" -ArgumentList "export", "--output", "`"$outputPath`"" -Wait -PassThru -NoNewWindow -RedirectStandardError "$env:TEMP\winget_error.log" -RedirectStandardOutput "$env:TEMP\winget_output.log"
            
            if ($process.ExitCode -eq 0 -and (Test-Path $outputPath)) {
                Write-Log "Exported Winget software list to: $outputPath" -Level "INFO"
                
                # Clean up temp files
                Remove-Item "$env:TEMP\winget_error.log" -ErrorAction SilentlyContinue
                Remove-Item "$env:TEMP\winget_output.log" -ErrorAction SilentlyContinue
                
                return $true
            } else {
                # Read error output if available
                $errorOutput = ""
                if (Test-Path "$env:TEMP\winget_error.log") {
                    $errorOutput = Get-Content "$env:TEMP\winget_error.log" -Raw
                    Remove-Item "$env:TEMP\winget_error.log" -ErrorAction SilentlyContinue
                }
                if (Test-Path "$env:TEMP\winget_output.log") {
                    Remove-Item "$env:TEMP\winget_output.log" -ErrorAction SilentlyContinue
                }
                
                Write-Log "Winget export failed with exit code: $($process.ExitCode). Error: $errorOutput" -Level "WARNING"
                return $false
            }
        } else {
            Write-Log "Winget not available on this system" -Level "WARNING"
            return $false
        }
    }
    catch {
        Write-Log "Failed to export Winget packages: $_" -Level "ERROR"
        return $false
    }
}





function Export-PythonPackages {
    param ([string]$BackupPath)
    
    try {
        # Ensure Lists directory exists
        $listsPath = Join-Path $BackupPath "Lists"
        Ensure-Directory $listsPath
        
        $pipOutput = pip freeze 2>&1 | Out-String
        if ($pipOutput -and $pipOutput.Trim()) {
            $pipOutput | Out-File "$BackupPath\Lists\PythonRequirements.txt" -Encoding UTF8
            Write-Log "Exported Python requirements" -Level "INFO"
            return $true
        } else {
            Write-Log "No Python packages found" -Level "WARNING"
            return $false
        }
    }
    catch {
        Write-Log "Python/pip not available: $_" -Level "WARNING"
        return $false
    }
}

function Export-ChocolateyPackages {
    param ([string]$BackupPath)
    
    try {
        # Ensure Lists and Scripts directories exist
        $listsPath = Join-Path $BackupPath "Lists"
        $scriptsPath = Join-Path $BackupPath "Scripts"
        Ensure-Directory $listsPath
        Ensure-Directory $scriptsPath
        
        # Try modern choco export first
        $chocoExportResult = choco export "$BackupPath\Lists\ChocolateyPackages.config" 2>&1
        if (Test-Path "$BackupPath\Lists\ChocolateyPackages.config") {
            Write-Log "Exported Chocolatey packages (packages.config)" -Level "INFO"
            return $true
        } else {
            # Fallback to list command for older versions
            $chocoList = choco list --localonly --idonly 2>&1
            if ($chocoList -and $chocoList -notlike "*Invalid argument*") {
                $chocoList | Out-File "$BackupPath\Lists\ChocolateyPackages.txt" -Encoding UTF8
                
                # Create install script
                $installScript = "# Chocolatey packages install script`n# Run as Administrator`n`n"
                $chocoList.Split("`n") | Where-Object { $_ -and $_ -notlike "*packages installed*" -and $_ -notlike "Chocolatey v*" } | ForEach-Object {
                    $packageName = $_.Trim()
                    if ($packageName) {
                        $installScript += "choco install $packageName -y`n"
                    }
                }
                $installScript | Out-File "$BackupPath\Scripts\InstallChocolateyPackages.ps1" -Encoding UTF8
                Write-Log "Exported Chocolatey packages list and install script" -Level "INFO"
                return $true
            } else {
                Write-Log "No Chocolatey packages found or version too old" -Level "WARNING"
                return $false
            }
        }
    }
    catch {
        Write-Log "Chocolatey not available: $_" -Level "WARNING"
        return $false
    }
}

function Export-CargoPackages {
    param ([string]$BackupPath)
    
    try {
        # Ensure Lists and Scripts directories exist
        $listsPath = Join-Path $BackupPath "Lists"
        $scriptsPath = Join-Path $BackupPath "Scripts"
        Ensure-Directory $listsPath
        Ensure-Directory $scriptsPath
        
        $cargoList = cargo install --list 2>&1 | Out-String
        if ($cargoList -and $cargoList.Trim()) {
            $cargoList | Out-File "$BackupPath\Lists\CargoPackages.txt" -Encoding UTF8
            
            # Extract package names and create install script
            $installScript = "# Cargo packages install script`n`n"
            $cargoList.Split("`n") | Where-Object { $_ -match "^[a-zA-Z0-9_-]+ v" } | ForEach-Object {
                $packageName = ($_ -split " ")[0]
                $installScript += "cargo install $packageName`n"
            }
            $installScript | Out-File "$BackupPath\Scripts\InstallCargoPackages.ps1" -Encoding UTF8
            
            Write-Log "Exported Cargo packages list and install script" -Level "INFO"
            return $true
        } else {
            Write-Log "No Cargo packages found" -Level "WARNING"
            return $false
        }
    }
    catch {
        Write-Log "Rust/Cargo not available (skipped)" -Level "DEBUG"
        return $false
    }
}

function Export-DefaultAppAssociations {
    param ([string]$BackupPath)
    
    try {
        $associations = dism /online /Export-DefaultAppAssociations:"$BackupPath\Lists\DefaultAppAssociations.xml"
        Write-Log "Exported default app associations" -Level "INFO"
        return $true
    }
    catch {
        Write-Log "Failed to export default app associations: $_" -Level "ERROR"
        return $false
    }
}

#endregion

# Functions are available through dot-sourcing