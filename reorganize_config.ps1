# Reorganize and sort backup configuration
$configPath = "C:\Scripts\Backup\config\bkp_cfg.json"
$config = Get-Content $configPath | ConvertFrom-Json

Write-Host "Reorganizing backup configuration..." -ForegroundColor Cyan

# Lists of duplicates to remove from UserConfigs
$aiDuplicates = @(
    "C:\Users\r_sta\.claude",
    "C:\Users\r_sta\.codex",
    "C:\Users\r_sta\.cursor",
    "C:\Users\r_sta\.gemini",
    "c:\Users\r_sta\.mcp-scan",
    "C:\Users\r_sta\.claude-mcp-configs",
    "C:\Users\r_sta\mcp_scripts",
    "C:\utils\AI\MCP-Steam",
    "c:\Users\r_sta\.lmstudio\config-presets",
    "c:\Users\r_sta\.lmstudio\credentials",
    "c:\Users\r_sta\.lmstudio\extensions\plugins\mcp",
    "c:\Users\r_sta\.lmstudio\mcp.json",
    "C:\Users\r_sta\AppData\Roaming\Claude\claude_desktop_config.json",
    "C:\Users\r_sta\AppData\Roaming\Claude\Preferences",
    "C:\Users\r_sta\AppData\Roaming\Claude\config.json",
    "C:\Users\r_sta\AppData\Roaming\Claude\Claude Extensions Settings",
    "C:\Users\r_sta\AppData\Roaming\Claude\Claude Extensions",
    "C:\Users\r_sta\.tweakcc",
    "C:\Users\r_sta\.claude-server-commander",
    "C:\Users\r_sta\AppData\Roaming\Claude\developer_settings.json"
)

$gamesDuplicate = @("C:\Users\r_sta\AppData\Local\@shift-code")

# Remove duplicates from UserConfigs
$cleanedUserConfigs = $config.BackupItems.UserConfigs | Where-Object {
    $_ -notin ($aiDuplicates + $gamesDuplicate)
}

# Sort all category paths alphabetically
Write-Host "Sorting paths within categories..." -ForegroundColor Yellow

$sortedBackupItems = [ordered]@{}
foreach($cat in $config.BackupItems.PSObject.Properties | Sort-Object Name) {
    if($cat.Value -is [array]) {
        if($cat.Name -eq "UserConfigs") {
            $sortedBackupItems[$cat.Name] = $cleanedUserConfigs | Sort-Object
        } else {
            $sortedBackupItems[$cat.Name] = $cat.Value | Sort-Object
        }
    } else {
        # Windows Settings categories (objects, not arrays)
        $sortedBackupItems[$cat.Name] = $cat.Value
    }
}

# Get all category names for ALL backup type
$allCategories = $config.BackupItems.PSObject.Properties.Name |
    Where-Object { $_ -notlike "_*" } |
    Sort-Object

# Create new organized config
$newConfig = [ordered]@{
    ConfigVersion = $config.ConfigVersion
    Statistics = $config.Statistics
    TempPath = $config.TempPath
    BackupVersions = $config.BackupVersions
    CompressionPresets = $config.CompressionPresets
    Constants = $config.Constants
    GlobalExclusions = $config.GlobalExclusions
    Tools = $config.Tools
    Destinations = $config.Destinations
    Notifications = $config.Notifications
    Logging = $config.Logging
    BackupItems = $sortedBackupItems
    BackupTypes = [ordered]@{
        AI = @("AI", "Scripts") | Sort-Object
        All = $allCategories
        Dev = @("PowerShell", "Scripts", "UserConfigs", "WindowsTerminal", "BrowserBookmarks") | Sort-Object
        Full = @("Games", "Applications", "BrowserBookmarks", "BrowserPasswords", "BrowserSettings",
                 "Certificates", "Documents", "DoskeyMacros", "Import", "Logs", "Notepad++",
                 "PowerShell", "PowerToys", "Scripts", "SystemFiles", "TotalCommander", "UserConfigs",
                 "WinApps", "WinInput", "WinInterface", "WinSecurity", "WinSystem",
                 "WindowsCredentials", "WindowsTerminal") | Sort-Object
        Games = @("Games")
        Scripts = @("Scripts", "WindowsTerminal") | Sort-Object
        "WinSettings-Essential" = @("SystemFiles", "WinApps", "WinInput", "WinInterface", "WinSecurity", "WinSystem") | Sort-Object
        "WinSettings-Full" = @("SystemFiles", "WinApps", "WinInput", "WinInterface", "WinSecurity", "WinSystem") | Sort-Object
        "WinSettings-Minimal" = @("SystemFiles", "WinInput", "WinInterface", "WinSecurity", "WinSystem") | Sort-Object
    }
    WindowsSettings = $config.WindowsSettings
}

# Save reorganized config
$newConfig | ConvertTo-Json -Depth 20 | Set-Content $configPath -Encoding UTF8

Write-Host "`nConfiguration reorganized successfully!" -ForegroundColor Green
Write-Host "  - Removed $($aiDuplicates.Count + $gamesDuplicate.Count) duplicates from UserConfigs" -ForegroundColor Green
Write-Host "  - Created 'All' backup type with $($allCategories.Count) categories" -ForegroundColor Green
Write-Host "  - Sorted all paths alphabetically within categories" -ForegroundColor Green
Write-Host "  - Reorganized config sections in proper order" -ForegroundColor Green
