[CmdletBinding()]
param (
    [Parameter(Mandatory=$true, HelpMessage="Specifies the type of backup to perform.")]
    [string]$BackupType,

    [Parameter(Mandatory=$true, HelpMessage="Specifies the destination for the backup.")]
    [string]$Destination,

    [Parameter(Mandatory=$false, HelpMessage="Sets the logging level.")]
    [ValidateSet("INFO", "DEBUG", "WARNING", "ERROR")]
    [string]$LogLevel = "WARNING",

    [Parameter(Mandatory=$false, HelpMessage="Specifies the path to the config file.")]
    [ValidateScript({Test-Path $_ -PathType 'Leaf'})]
    [string]$ConfigFile = "config\bkp_cfg.json",

    [Parameter(Mandatory=$false, HelpMessage="Performs a dry run without actually backing up files.")]
    [switch]$DryRun,

    [Parameter(Mandatory=$false, HelpMessage="Displays the help message.")]
    [switch]$Help,

    [Parameter(Mandatory=$false, HelpMessage="Sets the compression level (0-9).")]
    [ValidateRange(0,9)]
    [int]$CompressionLevel = 5,

    [Parameter(Mandatory=$false, HelpMessage="Backup strategy: Full (all files) or Differential (only changed files since last full backup).")]
    [ValidateSet("Full", "Differential")]
    [string]$BackupStrategy = "Full"
)

# Import shared utilities with performance enhancements
. "$PSScriptRoot\BackupUtilities.ps1"
. "$PSScriptRoot\WinBackup.ps1"
. "$PSScriptRoot\ManifestUtilities.ps1"

# Global variable for temporary backup folder
$script:tempBackupFolder = $null

#region Helper Functions for Perform-Backup

function Invoke-PreflightChecks {
    <#
    .SYNOPSIS
    Validates parameters and checks write permissions before backup starts.
    #>
    param (
        $Config,
        [string]$BackupType,
        [string]$Destination
    )

    # Validate and sanitize input parameters (Issue #28 - Phase 3 Security)
    $validated = Validate-BackupParameters -Config $Config -BackupType $BackupType -Destination $Destination

    # Pre-flight checks: Test write permissions (Issue #40 - Phase 3 Security)
    Write-Log "Performing pre-flight permission checks..." -Level "INFO"

    # Test temp path write permission
    if (-not (Test-DestinationWritable -DestinationPath $Config.TempPath)) {
        throw "Cannot write to temp path: $($Config.TempPath). Check permissions and disk space."
    }

    # Test destination path write permission (skip for SSH as it's checked during transfer)
    if ($Destination -ne "SSH") {
        $destinationConfig = $Config.Destinations.$Destination
        $destinationBasePath = if ($Destination -eq "HomeNet") { $destinationConfig.Path } else { $destinationConfig }

        if (-not (Test-DestinationWritable -DestinationPath $destinationBasePath)) {
            throw "Cannot write to destination: $destinationBasePath. Check permissions and disk space."
        }
    }

    Write-Log "Pre-flight checks passed: All destinations are writable" -Level "INFO"

    return $validated
}

function Initialize-BackupEnvironment {
    <#
    .SYNOPSIS
    Sets up backup environment: checks disk space, creates folders, generates backup name.
    #>
    param (
        $Config,
        [string]$BackupType,
        [string]$Destination,
        [array]$BackupItems
    )

    # Check disk space and estimate backup size
    $spaceCheck = Check-DiskSpaceAndEstimateSize -Config $Config -BackupType $BackupType -Destination $Destination

    $estimatedSizeGB = [math]::Round($spaceCheck.EstimatedSize / 1GB, 2)
    $freeSpaceGB = [math]::Round($spaceCheck.FreeSpace / 1GB, 2)

    Write-Log "Estimated backup size: $estimatedSizeGB GB" -Level "INFO"
    Write-Log "Available free space: $freeSpaceGB GB" -Level "INFO"

    foreach ($item in $spaceCheck.ItemizedEstimates) {
        $itemSizeMB = [math]::Round($item.Size / 1MB, 2)
        Write-Log "Estimated size for $($item.Item): $itemSizeMB MB" -Level "INFO"
    }

    if (-not $spaceCheck.SufficientSpace) {
        $spaceNeededGB = [math]::Round(($spaceCheck.EstimatedSize - $spaceCheck.FreeSpace) / 1GB, 2)
        throw "Insufficient disk space. Need additional $spaceNeededGB GB."
    }

    $timestamp = Get-Date -Format "yyyyMMdd-HHmmss"
    $backupName = "${BackupType}_${timestamp}"
    $tempBackupFolder = Join-Path $Config.TempPath $backupName

    # Ensure temp directory exists
    if (-not (Test-Path $Config.TempPath)) {
        New-Item -ItemType Directory -Path $Config.TempPath -Force | Out-Null
        Write-Log "Created temp directory: $($Config.TempPath)" -Level "INFO"
    }

    # Initialize backup directory structure
    if (-not (Test-Path $tempBackupFolder)) {
        New-Item -ItemType Directory -Path $tempBackupFolder -Force | Out-Null
    }

    # Initialize backup manifest
    Initialize-BackupManifest -BackupType $BackupType -BackupName $backupName -Timestamp $timestamp
    Write-Log "Initialized backup manifest" -Level "INFO"

    return @{
        BackupName = $backupName
        TempBackupFolder = $tempBackupFolder
        Timestamp = $timestamp
    }
}

function Get-DifferentialBackupInfo {
    <#
    .SYNOPSIS
    Determines if differential backup is possible and returns parent backup info.
    #>
    param (
        [string]$BackupType,
        [string]$BackupStrategy
    )

    $parentBackupId = 0
    $lastFullBackupDate = [DateTime]::MinValue
    $actualStrategy = $BackupStrategy

    Write-Log "=== BACKUP STRATEGY: $BackupStrategy ===" -Level "WARNING"

    if ($BackupStrategy -eq "Differential") {
        Write-Log "Differential backup requested - looking for last full backup" -Level "WARNING"

        $lastFullBackup = Get-LastFullBackupDate -BackupType $BackupType

        if ($null -eq $lastFullBackup) {
            Write-Log "No previous full backup found - performing Full backup instead" -Level "WARNING"
            $actualStrategy = "Full"
        }
        else {
            $parentBackupId = $lastFullBackup.Id
            $lastFullBackupDate = $lastFullBackup.Timestamp
            Write-Log "DIFFERENTIAL MODE: Only backing up files modified after $($lastFullBackupDate.ToString('yyyy-MM-dd HH:mm:ss'))" -Level "WARNING"
            Write-Log "Parent full backup ID: $parentBackupId" -Level "WARNING"
        }
    }
    else {
        Write-Log "FULL BACKUP: All files will be backed up" -Level "WARNING"
    }

    return @{
        Strategy = $actualStrategy
        ParentBackupId = $parentBackupId
        LastFullBackupDate = $lastFullBackupDate
    }
}

function Invoke-BackupCompression {
    <#
    .SYNOPSIS
    Compresses backup folder and verifies integrity.
    #>
    param (
        [string]$TempBackupFolder,
        [string]$DestinationPath,
        [string]$BackupName,
        $Config,
        [int]$CompressionLevel
    )

    # Audit trail: Compression started (Issue #39)
    Write-AuditLog -Action "COMPRESSION_START" -User $env:USERNAME -Target "$BackupName-Level$CompressionLevel" -Result "STARTED" -AuditLogPath "$PSScriptRoot\log\audit.log"

    # Compress the entire temp folder with performance optimizations
    $compressionResult = Measure-BackupPerformance -Operation {
        $sourcePaths = @((Resolve-Path $TempBackupFolder).Path)
        Compress-Backup-Optimized -SourcePaths $sourcePaths `
                                 -DestinationPath $DestinationPath `
                                 -ArchiveName $BackupName `
                                 -SevenZipPath $Config.Tools.'7Zip' `
                                 -CompressionLevel $CompressionLevel `
                                 -TempPath $Config.TempPath `
                                 -UseMultiThreading `
                                 -ArchiveFormat "zip"
    } -OperationName "Compression (Performance Mode)"

    $compressedBackup = $compressionResult
    if (-not $compressedBackup) {
        throw "Compression failed or did not return a valid file path"
    }
    Write-Log "Compressed backup to $compressedBackup" -Level "INFO"

    # Verify backup integrity
    $backupHash = Verify-Backup -BackupFile $compressedBackup
    if ($backupHash) {
        Write-Log "Backup verified successfully. Hash: $backupHash" -Level "INFO"
    } else {
        throw "Backup verification failed"
    }

    return $compressedBackup
}

function Invoke-BackupTransfer {
    <#
    .SYNOPSIS
    Handles backup transfer to destination (local or SSH).
    #>
    param (
        [string]$Destination,
        $Config,
        [string]$TempBackupFolder,
        [string]$BackupName,
        [int]$CompressionLevel,
        [int]$TotalSteps,
        [int]$CurrentStep
    )

    Show-Progress -PercentComplete (($CurrentStep / $TotalSteps) * 100) -Status "Creating Backup"

    if ($Destination -eq "SSH") {
        $sshConfig = $Config.Destinations.SSH
        $sourcePaths = @((Resolve-Path $TempBackupFolder).Path)

        # Audit trail: SSH transfer started (Issue #39)
        Write-AuditLog -Action "TRANSFER_START" -User $env:USERNAME -Target "SSH-$($sshConfig.RemoteHost)" -Result "STARTED" -AuditLogPath "$PSScriptRoot\log\audit.log"

        $success = Backup-ToSSH -SourcePaths $sourcePaths `
                                -RemoteHost $sshConfig.RemoteHost `
                                -RemotePath $sshConfig.RemotePath `
                                -SSHKeyPath $sshConfig.SSHKeyPath `
                                -BackupName $BackupName `
                                -SevenZipPath $Config.Tools.'7Zip' `
                                -TempPath $Config.TempPath
        if (-not $success) {
            throw "SSH backup failed"
        }
        Write-Log "Backup transferred to SSH destination: $($sshConfig.RemoteHost):$($sshConfig.RemotePath)/$BackupName" -Level "INFO"

        return @{
            FinalPath = "$($sshConfig.RemoteHost):$($sshConfig.RemotePath)/$BackupName"
            Size = 0  # Can't easily get remote file size
        }
    }
    else {
        $destinationConfig = $Config.Destinations.$Destination
        if ($Destination -eq "HomeNet") {
            $destinationPath = Join-Path $destinationConfig.Path $BackupName
        }
        else {
            $destinationPath = Join-Path $destinationConfig $BackupName
        }

        $compressedBackup = Invoke-BackupCompression -TempBackupFolder $TempBackupFolder `
                                                      -DestinationPath $destinationPath `
                                                      -BackupName $BackupName `
                                                      -Config $Config `
                                                      -CompressionLevel $CompressionLevel

        # Manage backup versions
        Manage-BackupVersions -BackupDirectory (Split-Path $compressedBackup -Parent) -VersionsToKeep $Config.BackupVersions | Out-Null

        return @{
            FinalPath = $compressedBackup
            Size = (Get-Item $compressedBackup).Length
        }
    }
}

function Complete-BackupProcess {
    <#
    .SYNOPSIS
    Finalizes backup: updates database, sends notifications.
    #>
    param (
        [string]$BackupName,
        [string]$BackupType,
        [string]$Destination,
        [string]$FinalBackupPath,
        [long]$BackupSize,
        [array]$BackupItems,
        [string]$BackupStrategy,
        [int]$ParentBackupId,
        $Config,
        [string]$ScriptPath
    )

    # Update backup database
    $destinationType = if ($Destination -eq "SSH") { "SSH" } elseif ($Destination -eq "HomeNet") { "NetworkShare" } else { "Local" }
    $additionalMetadata = "File Backup with Manifest (Performance Mode)"

    Update-BackupDatabase -BackupSetName $BackupName `
                          -BackupType $BackupType `
                          -DestinationType $destinationType `
                          -DestinationPath $FinalBackupPath `
                          -SizeBytes $BackupSize `
                          -CompressionMethod "zip" `
                          -EncryptionMethod "" `
                          -SourcePaths $BackupItems `
                          -AdditionalMetadata $additionalMetadata `
                          -BackupStrategy $BackupStrategy `
                          -ParentBackupId $ParentBackupId | Out-Null

    # Send completion notification asynchronously
    $backupSizeMB = [math]::Round($BackupSize / 1MB, 2)
    $completionMessage = "Backup Type: $BackupType`nDestination: $Destination`nSize: $backupSizeMB MB`nStatus: ✓ SUCCESS"

    Start-Job -ScriptBlock {
        param($Title, $Message, $ConfigJson, $ScriptRoot)
        $Config = $ConfigJson | ConvertFrom-Json
        . "$ScriptRoot\BackupUtilities.ps1"
        Send-GotifyNotification -Title $Title -Message $Message -Priority 5 -Config $Config
    } -ArgumentList "Backup Completed", $completionMessage, ($Config | ConvertTo-Json -Depth 10), $ScriptPath | Out-Null
}

#endregion

#region Helper Functions for Process-BackupItems

function Process-CertificatesBackup {
    <#
    .SYNOPSIS
    Exports user certificates to backup folder.
    #>
    param (
        [string]$TempBackupFolder,
        [string]$Item
    )

    try {
        $certBackupFolder = Join-Path $TempBackupFolder "Files\UserConfigs\Certificates"
        if (-not (Test-Path $certBackupFolder)) {
            New-Item -ItemType Directory -Path $certBackupFolder -Force | Out-Null
        }
        Export-Certificates -DestinationPath $certBackupFolder
        if (Test-Path $certBackupFolder) {
            Write-Log "Exported Certificates to $certBackupFolder" -Level "INFO"

            # Add to manifest
            Add-SpecialItemToManifest -ItemType "Certificates" -ArchivePath "Files/UserConfigs/Certificates" -BackupItem $Item -SpecialInfo @{
                export_method = "PowerShell_Certificate_Export"
                description = "Certificate store exports (My, Root, CA)"
            }
        }
    }
    catch {
        Write-Log "Skipping Certificates backup - function not available: $_" -Level "WARNING"
    }
}

function Process-DoskeyMacrosBackup {
    <#
    .SYNOPSIS
    Exports Doskey macros to backup folder.
    #>
    param (
        [string]$TempBackupFolder,
        [string]$Item
    )

    try {
        $macroBackupFolder = Join-Path $TempBackupFolder "Files\UserConfigs\DoskeyMacros"
        if (-not (Test-Path $macroBackupFolder)) {
            New-Item -ItemType Directory -Path $macroBackupFolder -Force | Out-Null
        }
        Backup-DoskeyMacros -DestinationPath $macroBackupFolder
        if (Test-Path $macroBackupFolder) {
            Write-Log "Exported DoskeyMacros to $macroBackupFolder" -Level "INFO"

            # Add to manifest
            Add-SpecialItemToManifest -ItemType "DoskeyMacros" -ArchivePath "Files/UserConfigs/DoskeyMacros" -BackupItem $Item -SpecialInfo @{
                export_method = "doskey_command"
                description = "Command-line macros export"
            }
        }
    }
    catch {
        Write-Log "Skipping DoskeyMacros backup - function not available: $_" -Level "WARNING"
    }
}

function Process-WindowsCredentialsBackup {
    <#
    .SYNOPSIS
    Exports Windows Credential Manager credentials to backup folder.
    #>
    param (
        [string]$TempBackupFolder,
        [string]$Item
    )

    $credBackupFolder = Join-Path $TempBackupFolder "Files\UserConfigs\WindowsCredentials"
    if (-not (Test-Path $credBackupFolder)) {
        New-Item -ItemType Directory -Path $credBackupFolder -Force | Out-Null
    }
    Backup-WindowsCredentials -DestinationPath $credBackupFolder
    if (Test-Path $credBackupFolder) {
        Write-Log "Exported WindowsCredentials to $credBackupFolder" -Level "INFO"

        # Add to manifest
        Add-SpecialItemToManifest -ItemType "WindowsCredentials" -ArchivePath "Files/UserConfigs/WindowsCredentials" -BackupItem $Item -SpecialInfo @{
            export_method = "credential_manager_export"
            description = "Windows Credential Manager export (passwords protected)"
        }
    }
}

function Get-BackupDestinationFolder {
    <#
    .SYNOPSIS
    Determines the backup destination folder based on item name.
    #>
    param (
        [string]$ItemName
    )

    switch ($ItemName) {
        { $_ -in @("Logs") } { return "Files" }
        { $_ -in @("Applications", "Notepad++", "WindowsTerminal") } { return "Files\Applications" }
        { $_ -in @("TotalCommander") } { return "Files" }
        { $_ -in @("Scripts") } { return "Files" }
        { $_ -in @("PowerToys") } { return "Files\PowerToys" }
        { $_ -in @("PowerShell") } { return "Files\PowerShell" }
        { $_ -in @("Games") } { return "Files\Games" }
        { $_ -in @("UserConfigs") } { return "Files\UserConfigs" }
        { $_ -in @("Browsers") } { return "Files\Browsers" }
        { $_ -in @("SystemFiles") } { return "Files\System" }
        { $_ -in @("Import") } { return "Files\Import" }
        default { return "Files\Other" }
    }
}

function Process-FileBackupItem {
    <#
    .SYNOPSIS
    Handles file and folder backups with differential support and parallel processing.
    #>
    param (
        [string]$Item,
        [array]$Paths,
        [string]$TempBackupFolder,
        $Config,
        [string]$BackupStrategy = "Full",
        [DateTime]$LastFullBackupDate = [DateTime]::MinValue
    )

    # Phase 4: Differential backup filtering (Issue #20)
    if ($BackupStrategy -eq "Differential" -and $LastFullBackupDate -ne [DateTime]::MinValue) {
        Write-Log "Applying differential filter for $Item (since $($LastFullBackupDate.ToString('yyyy-MM-dd HH:mm:ss')))" -Level "WARNING"

        # Get validated paths first
        $validatedPaths = @()
        foreach ($path in $Paths) {
            $expandedPath = $ExecutionContext.InvokeCommand.ExpandString($path)
            if (Test-Path $expandedPath) {
                $validatedPaths += [PSCustomObject]@{
                    OriginalPath = $path
                    ExpandedPath = $expandedPath
                    IsDirectory = Test-Path $expandedPath -PathType Container
                }
            }
        }

        # Filter to only modified files
        $modifiedPaths = Get-ModifiedFilesSinceLastFull -SourcePaths $validatedPaths -LastFullBackupDate $LastFullBackupDate -Config $Config

        if ($modifiedPaths.Count -eq 0) {
            Write-Log "DIFFERENTIAL: No changes detected for $Item - SKIPPING" -Level "WARNING"
            return
        }

        # Replace paths with only modified ones
        $Paths = $modifiedPaths | ForEach-Object { $_.OriginalPath }
        Write-Log "DIFFERENTIAL: $($modifiedPaths.Count) of $($validatedPaths.Count) items modified for $Item - backing up changed files only" -Level "WARNING"
    }

    # Determine destination folder
    $destinationFolder = Get-BackupDestinationFolder -ItemName $Item
    $categoryPath = Join-Path $TempBackupFolder $destinationFolder
    if (-not (Test-Path $categoryPath)) {
        New-Item -ItemType Directory -Path $categoryPath -Force | Out-Null
    }

    # Use performance-enhanced backup function
    try {
        $useParallel = $Paths.Count -gt 3  # Use parallel for items with many paths
        Backup-Files-Optimized -SourcePaths $Paths -DestinationPath $categoryPath -BackupName $Item -UseParallel:$useParallel -Config $Config

        # Add files to manifest
        foreach ($path in $Paths) {
            $expandedPath = $ExecutionContext.InvokeCommand.ExpandString($path)
            if (Test-Path $expandedPath) {
                $itemName = Get-SmartBackupFileName -SourcePath $expandedPath
                $archivePath = "$($destinationFolder.Replace('\', '/'))/$itemName"
                $fileType = if (Test-Path $expandedPath -PathType Container) { "folder" } else { "file" }
                Add-FileToManifest -OriginalPath $expandedPath -ArchivePath $archivePath -BackupItem $Item -FileType $fileType
            }
        }

        Write-Log "Performance backup completed for: $Item" -Level "INFO"
    }
    catch {
        Write-Log "Performance backup failed for $Item, using fallback: $_" -Level "WARNING"
        # Fallback to standard Copy-Item method
        foreach ($path in $Paths) {
            $expandedPath = $ExecutionContext.InvokeCommand.ExpandString($path)
            if (Test-Path $expandedPath) {
                try {
                    $itemName = Get-SmartBackupFileName -SourcePath $expandedPath
                    $destPath = Join-Path $categoryPath $itemName

                    if ($expandedPath.StartsWith("C:\Windows") -or $expandedPath.StartsWith("C:\Program Files")) {
                        Write-Log "Using gsudo for path: $expandedPath" -Level "DEBUG"
                        gsudo Copy-Item -Path $expandedPath -Destination $destPath -Recurse -Force -ErrorAction Stop
                    } else {
                        Copy-Item -Path $expandedPath -Destination $destPath -Recurse -Force -ErrorAction Stop
                    }
                    Write-Log "Copied $expandedPath to $destinationFolder as $itemName" -Level "INFO"

                    # Add to manifest
                    $archivePath = "$($destinationFolder.Replace('\', '/'))/$itemName"
                    $fileType = if (Test-Path $expandedPath -PathType Container) { "folder" } else { "file" }
                    Add-FileToManifest -OriginalPath $expandedPath -ArchivePath $archivePath -BackupItem $Item -FileType $fileType
                } catch {
                    Handle-Error -ErrorRecord $_ -Operation "Copy-File-$expandedPath"
                }
            } else {
                Write-Log "Path not found (skipping): $path" -Level "DEBUG"
            }
        }
    }
}

#endregion

#region Main Backup Function

function Perform-Backup {
    <#
    .SYNOPSIS
    Main backup orchestration function. Coordinates all backup operations.
    .DESCRIPTION
    Refactored to use helper functions for better maintainability and token efficiency (Phase 5 #25).
    Reduced from 295 lines to ~100 lines by extracting focused sub-functions.
    #>
    param (
        $Config,
        [string]$BackupType,
        [string]$Destination,
        [switch]$DryRun,
        [int]$CompressionLevel,
        [string]$BackupStrategy = "Full"
    )

    # Perform validation and permission checks
    $validated = Invoke-PreflightChecks -Config $Config -BackupType $BackupType -Destination $Destination
    $BackupType = $validated.BackupType
    $Destination = $validated.Destination

    # Reset progress timer for ETA calculation
    Reset-ProgressTimer

    # Handle Windows Settings backup (separate workflow)
    if ($BackupType.StartsWith("WinSettings-")) {
        Write-Log "Detected Windows Settings backup type: $BackupType" -Level "INFO"

        try {
            $result = Invoke-WindowsSettingsBackup -Config $Config -BackupType $BackupType -Destination $Destination -CompressionLevel $CompressionLevel
            Write-Log "Windows Settings backup completed successfully: $result" -Level "INFO"
            return $result
        }
        catch {
            Handle-Error -ErrorRecord $_ -Operation "Windows-Settings-Backup" -SendNotification -Config $Config
            throw $_
        }
    }

    # Handle file-based backups
    $backupItems = $Config.BackupTypes.$BackupType

    # Validate that backup paths exist (warns but doesn't fail)
    Test-BackupItemsExist -BackupItems $backupItems -Config $Config

    # Send start notification asynchronously
    $scriptPath = $PSScriptRoot
    $startMessage = "Backup Type: $BackupType`nDestination: $Destination`nCompression: Level $CompressionLevel`nItems: $($backupItems.Count)"
    Start-Job -ScriptBlock {
        param($Title, $Message, $ConfigJson, $ScriptRoot)
        $Config = $ConfigJson | ConvertFrom-Json
        . "$ScriptRoot\BackupUtilities.ps1"
        Send-GotifyNotification -Title $Title -Message $Message -Config $Config
    } -ArgumentList "Backup Started", $startMessage, ($Config | ConvertTo-Json -Depth 10), $scriptPath | Out-Null

    Write-Log "Starting file backup: Type=$BackupType, Destination=$Destination (Performance Mode)" -Level "INFO"

    # Initialize backup environment (disk space, temp folders, manifest)
    $backupEnv = Initialize-BackupEnvironment -Config $Config -BackupType $BackupType -Destination $Destination -BackupItems $backupItems
    $backupName = $backupEnv.BackupName
    $tempBackupFolder = $backupEnv.TempBackupFolder
    $script:tempBackupFolder = $tempBackupFolder

    $totalSteps = $backupItems.Count + 3  # +3 for Compression, Verification, and Version Management
    $currentStep = 0

    try {
        # Determine backup strategy (Full or Differential)
        $strategyInfo = Get-DifferentialBackupInfo -BackupType $BackupType -BackupStrategy $BackupStrategy
        $BackupStrategy = $strategyInfo.Strategy
        $parentBackupId = $strategyInfo.ParentBackupId
        $lastFullBackupDate = $strategyInfo.LastFullBackupDate

        # Process backup items (file copying)
        $fileOperationResult = Measure-BackupPerformance -Operation {
            Process-BackupItems -BackupItems $backupItems `
                                -TempBackupFolder $tempBackupFolder `
                                -Config $Config `
                                -TotalSteps $totalSteps `
                                -CurrentStep ([ref]$currentStep) `
                                -BackupStrategy $BackupStrategy `
                                -ParentBackupId $parentBackupId `
                                -LastFullBackupDate $lastFullBackupDate
        } -OperationName "File operations (Performance Mode)"

        # Finalize manifest before compression
        $manifestPath = Finalize-BackupManifest -BackupPath $tempBackupFolder -BackupItems $backupItems
        if ($manifestPath) {
            Write-Log "Backup manifest created successfully" -Level "INFO"
        } else {
            Write-Log "Failed to create backup manifest - restore functionality may be limited" -Level "WARNING"
        }

        # Transfer backup to destination (compress locally or transfer via SSH)
        $currentStep++
        $transferResult = Invoke-BackupTransfer -Destination $Destination `
                                                 -Config $Config `
                                                 -TempBackupFolder $tempBackupFolder `
                                                 -BackupName $backupName `
                                                 -CompressionLevel $CompressionLevel `
                                                 -TotalSteps $totalSteps `
                                                 -CurrentStep $currentStep

        Show-Progress -PercentComplete 100 -Status "Backup Completed"
        Write-Log "File backup completed successfully" -Level "INFO"

        # Finalize backup (database update, notifications)
        Complete-BackupProcess -BackupName $backupName `
                                -BackupType $BackupType `
                                -Destination $Destination `
                                -FinalBackupPath $transferResult.FinalPath `
                                -BackupSize $transferResult.Size `
                                -BackupItems $backupItems `
                                -BackupStrategy $BackupStrategy `
                                -ParentBackupId $parentBackupId `
                                -Config $Config `
                                -ScriptPath $scriptPath

        return $transferResult.FinalPath
    }
    catch {
        Handle-Error -ErrorRecord $_ -Operation "File-Backup-Process" -SendNotification -Config $Config
        throw $_
    }
    finally {
        # Clean up temp folder if it exists
        if ($script:tempBackupFolder -and (Test-Path $script:tempBackupFolder)) {
            Remove-Item -Path $script:tempBackupFolder -Recurse -Force -ErrorAction SilentlyContinue
            Write-Log "Cleaned up temporary backup folder" -Level "INFO"
        }
    }
}

function Process-BackupItems {
    <#
    .SYNOPSIS
    Orchestrates backup processing for all items in the backup set.
    .DESCRIPTION
    Refactored to use helper functions for better maintainability and token efficiency (Phase 5 #25).
    Reduced from 207 lines to ~50 lines by extracting item-specific processing functions.
    #>
    param (
        [string[]]$BackupItems,
        [string]$TempBackupFolder,
        $Config,
        [int]$TotalSteps,
        [ref]$CurrentStep,
        [string]$BackupStrategy = "Full",
        [int]$ParentBackupId = 0,
        [DateTime]$LastFullBackupDate = [DateTime]::MinValue
    )

    Write-Log "Processing backup items with performance enhancements (Strategy: $BackupStrategy)" -Level "INFO"

    foreach ($item in $BackupItems) {
        $CurrentStep.Value++
        Show-Progress -PercentComplete (($CurrentStep.Value / $TotalSteps) * 100) -Status "Processing $item"

        switch ($item) {
            "Certificates" {
                Process-CertificatesBackup -TempBackupFolder $TempBackupFolder -Item $item
            }
            "DoskeyMacros" {
                Process-DoskeyMacrosBackup -TempBackupFolder $TempBackupFolder -Item $item
            }
            "WindowsCredentials" {
                Process-WindowsCredentialsBackup -TempBackupFolder $TempBackupFolder -Item $item
            }
            default {
                # Check if this is a Windows settings category
                if ($Config.BackupItems.PSObject.Properties.Name -contains $item -and
                    $Config.BackupItems.$item.type -eq "windows_settings") {

                    Write-Log "Processing Windows settings category: $item" -Level "INFO"
                    try {
                        # Process Windows settings in WindowsSettings folder with enhanced registry export
                        $winSettingsPath = Join-Path $TempBackupFolder "WindowsSettings"
                        $category = $Config.BackupItems.$item
                        $result = Invoke-WindowsSettingsCategory-Enhanced -Category $category -CategoryName $item -BackupPath $winSettingsPath

                        if ($result) {
                            Write-Log "Successfully processed Windows settings category: $item" -Level "INFO"
                        }
                    }
                    catch {
                        Handle-Error -ErrorRecord $_ -Operation "Process-WindowsSettings-$item"
                    }
                }
                elseif ($Config.BackupItems.PSObject.Properties.Name -contains $item) {
                    # Handle file/folder backups
                    $paths = $Config.BackupItems.$item
                    Process-FileBackupItem -Item $item `
                                            -Paths $paths `
                                            -TempBackupFolder $TempBackupFolder `
                                            -Config $Config `
                                            -BackupStrategy $BackupStrategy `
                                            -LastFullBackupDate $LastFullBackupDate
                }
                else {
                    Write-Log "BackupItem not found in config: $item" -Level "WARNING"
                }
            }
        }
    }
}

function Invoke-WindowsSettingsCategory-Enhanced {
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

    Write-Log "Processing $totalItems items in category: $CategoryName (Performance Mode)" -Level "INFO"

    foreach ($item in $Category.items) {
        try {
            $result = Invoke-WindowsSettingsItem-Enhanced -Item $item -BackupPath $BackupPath -CategoryName $CategoryName
            if ($result) {
                $successCount++
            }
        }
        catch {
            Handle-Error -ErrorRecord $_ -Operation "Process-Item-$($item.name)"
        }
    }

    Write-Log "Category $CategoryName completed: $successCount/$totalItems items processed" -Level "INFO"
    return ($successCount -gt 0)
}

function Invoke-WindowsSettingsItem-Enhanced {
    param (
        $Item,
        [string]$BackupPath,
        [string]$CategoryName
    )

    $itemName = $Item.name
    $itemId = $Item.id
    Write-Log "Processing item $itemId : $itemName (Performance Mode)" -Level "DEBUG"

    $hasSuccess = $false

    # Handle registry keys with enhanced export
    if ($Item.registry_keys) {
        foreach ($regKey in $Item.registry_keys) {
            $fileName = "$itemId-$($regKey.Replace('\','_').Replace(':',''))"
            $result = Export-RegistryKey-Optimized -KeyPath $regKey -FileName $fileName -BackupDir $BackupPath -TimeoutSeconds 60
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

#region Help Function

function Show-Help {
    $helpText = @"
Backup Script Help (Performance Mode - Default)
------------------------------------------------

Usage: .\Main.ps1 [options]

Options:
  -BackupType <type>       Specifies the type of backup to perform. (Mandatory unless -Help is used)
                           Valid types are defined in the config file.
                           File backups: Full, Games, Dev
                           Windows settings: WinSettings-Minimal, WinSettings-Essential, WinSettings-Full

  -Destination <dest>      Specifies the destination for the backup. (Mandatory unless -Help is used)
                           Valid destinations are defined in the config file.

  -LogLevel <level>        Sets the logging level. (Optional)
                           Valid levels: INFO (default), DEBUG, ERROR, WARNING

  -ConfigFile <path>       Specifies the path to the config file. (Optional)
                           Default: config\bkp_cfg.json

  -CompressionLevel <0-9>    Sets the compression level. (Optional)
                               0 = No compression (Store)
                               1 = Fastest
                               3 = Fast
                               5 = Normal (default)
                               7 = Maximum
                               9 = Ultra

    -DryRun                    Performs a dry run without actually backing up files.
                               Shows what would be backed up, estimated sizes, and actions taken.

  -Help                    Displays this help message.

Examples:
  .\Main.ps1 -BackupType Full -Destination Local
  .\Main.ps1 -BackupType Full -Destination HomeNet
  .\Main.ps1 -BackupType WinSettings-Essential -Destination SSH -LogLevel DEBUG
  .\Main.ps1 -BackupType Games -Destination USB -DryRun
  .\Main.ps1 -Help

Performance Features (Always Enabled):
• Multi-threaded 7zip compression (1.5-3x faster)
• Parallel file copying for large directory sets
• Optimized registry exports with timeout handling
• Detailed performance metrics in logs

For more detailed information, please refer to the script documentation.
"@

    Write-Host $helpText
}

#endregion

#region Main Script Execution

# Main script execution
if ($Help) {
    Show-Help
    exit 0
}

if (-not $BackupType -or -not $Destination) {
    Write-Host "Error: BackupType and Destination are required parameters."
    Write-Host "Use -Help for more information."
    exit 1
}

# Sanitize parameters early (Issue #28 - Phase 3 Security)
# Note: Full validation happens later in Validate-BackupParameters after config is loaded
try {
    # Sanitize BackupType (allow alphanumeric, underscore, dash)
    $BackupType = $BackupType -replace '[^a-zA-Z0-9_\-]', ''
    if ([string]::IsNullOrWhiteSpace($BackupType)) {
        Write-Host "Error: Invalid BackupType after sanitization." -ForegroundColor Red
        exit 1
    }

    # Sanitize Destination (allow alphanumeric, underscore, dash)
    $Destination = $Destination -replace '[^a-zA-Z0-9_\-]', ''
    if ([string]::IsNullOrWhiteSpace($Destination)) {
        Write-Host "Error: Invalid Destination after sanitization." -ForegroundColor Red
        exit 1
    }

    # Sanitize LogLevel (must be one of the valid levels)
    if ($LogLevel -notmatch '^(DEBUG|INFO|WARNING|ERROR)$') {
        Write-Host "Warning: Invalid LogLevel '$LogLevel'. Defaulting to WARNING." -ForegroundColor Yellow
        $LogLevel = "WARNING"
    }

    # CompressionLevel is already validated by [ValidateRange(0,9)] attribute
}
catch {
    Write-Host "Error: Failed to sanitize input parameters: $_" -ForegroundColor Red
    exit 1
}

# Parse config file
try {
    $config = Parse-ConfigFile -ConfigFilePath $ConfigFile
}
catch {
    # Logging not initialized yet, use Write-Host
    Write-Host "ERROR: Failed to parse config file: $_" -ForegroundColor Red
    exit 1
}

# Initialize logging
$logFormat = if ($config.Logging.Format) { $config.Logging.Format } else { "Text" }
Initialize-Logging -LogLevel $LogLevel -LogFilePath $config.Logging.LogFilePath -LogFormat $logFormat

# Log performance mode status
Write-Log "🚀 PERFORMANCE MODE - Using optimized backup functions (Default)" -Level "INFO"
Write-Log "Performance enhancements: Multi-threaded compression, Parallel operations" -Level "INFO"

# Validate input parameters
try {
    Validate-BackupParameters -Config $config -BackupType $BackupType -Destination $Destination
}
catch {
    Handle-Error -ErrorRecord $_ -Operation "Parameter-Validation" -SendNotification -Config $config
    exit 1
}

try {
    Check-Dependencies -Config $config

    # Track backup start time for statistics
    $backupStartTime = Get-Date

    # Audit trail: Backup operation started (Issue #39)
    Write-AuditLog -Action "BACKUP_START" -User $env:USERNAME -Target "$BackupType-$Destination" -Result "STARTED" -AuditLogPath "$PSScriptRoot\log\audit.log"

    # Use performance-enhanced backup function with timing
    $allResults = @(Measure-BackupPerformance -Operation {
        Perform-Backup -Config $config -BackupType $BackupType -Destination $Destination -DryRun:$DryRun -CompressionLevel $CompressionLevel -BackupStrategy $BackupStrategy
    } -OperationName "Total Backup Operation")

    # Only take the last output (the actual return value)
    $totalBackupResult = $allResults[-1]

    Write-Log "✓ BACKUP COMPLETED SUCCESSFULLY" -Level "WARNING"
    Write-Log "Backup operation completed successfully: $totalBackupResult" -Level "INFO"

    # Update backup statistics (Issue #35)
    $backupDuration = [int]((Get-Date) - $backupStartTime).TotalSeconds

    # Check if result is a valid file path
    if ($totalBackupResult -and $totalBackupResult -is [string] -and (Test-Path $totalBackupResult -ErrorAction SilentlyContinue)) {
        $backupSize = (Get-Item $totalBackupResult).Length / 1MB

        Update-BackupStatistics -Success $true -SizeMB $backupSize -DurationSeconds $backupDuration -Config $config -ConfigPath "$PSScriptRoot\config\bkp_cfg.json"

        Write-Log "Statistics updated: Size=$([math]::Round($backupSize, 2)) MB, Duration=$backupDuration sec, Total backups: $($config.Statistics.TotalBackups)" -Level "INFO"

        # Audit trail: Backup completed successfully (Issue #39)
        Write-AuditLog -Action "BACKUP_COMPLETE" -User $env:USERNAME -Target "$BackupType-$Destination" -Result "SUCCESS" -AuditLogPath "$PSScriptRoot\log\audit.log"
    }
    else {
        # If we can't get file size, still track the backup with 0 size
        Update-BackupStatistics -Success $true -SizeMB 0 -DurationSeconds $backupDuration -Config $config -ConfigPath "$PSScriptRoot\config\bkp_cfg.json"
        Write-Log "Backup completed but statistics tracking incomplete (backup path: $totalBackupResult)" -Level "WARNING"

        # Audit trail: Backup completed successfully (Issue #39)
        Write-AuditLog -Action "BACKUP_COMPLETE" -User $env:USERNAME -Target "$BackupType-$Destination" -Result "SUCCESS" -AuditLogPath "$PSScriptRoot\log\audit.log"
    }
}
catch {
    # Track failed backup statistics (Issue #35)
    if ($backupStartTime) {
        $backupDuration = [int]((Get-Date) - $backupStartTime).TotalSeconds
        Update-BackupStatistics -Success $false -SizeMB 0 -DurationSeconds $backupDuration -Config $config -ConfigPath "$PSScriptRoot\config\bkp_cfg.json"
        Write-Log "Statistics updated for failed backup: Duration=$backupDuration sec, Total failures: $($config.Statistics.FailedBackups)" -Level "INFO"

        # Audit trail: Backup failed (Issue #39)
        Write-AuditLog -Action "BACKUP_COMPLETE" -User $env:USERNAME -Target "$BackupType-$Destination" -Result "FAILED" -AuditLogPath "$PSScriptRoot\log\audit.log"
    }

    Handle-Error -ErrorRecord $_ -Operation "Main-Script-Execution" -SendNotification -Config $config
    exit 1
}
finally {
    # Cleanup operations
    if ($script:tempBackupFolder -and (Test-Path $script:tempBackupFolder)) {
        Remove-Item -Path $script:tempBackupFolder -Recurse -Force -ErrorAction SilentlyContinue
        Write-Log "Final cleanup completed" -Level "INFO"
    }

    # Close database connection pool
    Close-DatabaseConnection

    Write-Log "=== Backup process finished ===" -Level "WARNING"

    # Flush log to ensure all entries are written to disk
    Flush-Log
}

#endregion
