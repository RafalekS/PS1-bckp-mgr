# How to Modify or Add Backup Categories

## Method 1: Add New Category (Like Import Example)

### Step 1: Add to backup_config.json
```json
{
  "BackupItems": {
    "YourNewCategory": [
      "C:\\Path\\To\\Your\\Files",
      "C:\\Another\\Path"
    ]
  },
  
  "BackupTypes": {
    "YourBackupType": [
      "YourNewCategory"
    ]
  }
}
```

### Step 2: Modify main.ps1 (Two Changes Required)

**Change A:** Add folder to structure (around line 350)
```powershell
$folderStructure = @(
    "Files\Applications",
    "Files\Documents", 
    "Files\Scripts",
    "Files\Games",
    "Files\UserConfigs",
    "Files\Tools",
    "Files\System",
    "Files\YourNewFolder",    # <-- ADD THIS
    "Files\Other"
)
```

**Change B:** Add to categorization logic (around line 400)
```powershell
$destinationFolder = switch ($item) {
    { $_ -in @("Documents") } { "Files\Documents" }
    { $_ -in @("Applications", "TotalCommander", "PowerToys", "Notepad++", "WindowsTerminal") } { "Files\Applications" }
    { $_ -in @("Scripts", "PowerShell") } { "Files\Scripts" }
    { $_ -in @("Adult", "Other") } { "Files\Games" }
    { $_ -in @("UserConfigs") } { "Files\UserConfigs" }
    { $_ -in @("SystemFiles") } { "Files\System" }
    { $_ -in @("YourNewCategory") } { "Files\YourNewFolder" }    # <-- ADD THIS
    default { "Files\Other" }
}
```

## Method 2: Move Existing Item to Different Folder

### Example: Move "PowerToys" from Applications to Tools

**Change the categorization logic in main.ps1:**
```powershell
# BEFORE:
{ $_ -in @("Applications", "TotalCommander", "PowerToys", "Notepad++", "WindowsTerminal") } { "Files\Applications" }

# AFTER:
{ $_ -in @("Applications", "TotalCommander", "Notepad++", "WindowsTerminal") } { "Files\Applications" }
{ $_ -in @("PowerToys") } { "Files\Tools" }
```

## Method 3: Add Items to Existing Category

### Example: Add Chrome settings to Applications

**Only modify backup_config.json:**
```json
{
  "BackupItems": {
    "Applications": [
      "C:\\Utils\\Windows\\AdminTray",
      "C:\\Utils\\Windows\\Terminator", 
      "C:\\Utils\\Windows\\WinSettings",
      "C:\\Utils\\Windows\\ms-settings",
      "C:\\Users\\R_sta\\clink",
      "C:\\Utils\\Tools",
      "C:\\Users\\R_sta\\AppData\\Local\\Google\\Chrome\\User Data"  // <-- ADD THIS
    ]
  }
}
```

## Method 4: Create Special Handling (Like Certificates)

### For items that need custom processing, add to main.ps1:

```powershell
# Add this in the switch statement around line 380
"YourSpecialItem" {
  $specialBackupFolder = Join-Path $tempBackupFolder "Files\Special\YourSpecialItem"
  if (-not (Test-Path $specialBackupFolder)) { 
      New-Item -ItemType Directory -Path $specialBackupFolder -Force | Out-Null 
  }
  # Your custom processing logic here
  Your-Custom-Function -DestinationPath $specialBackupFolder
  if (Test-Path $specialBackupFolder) {
      Write-Log "Exported YourSpecialItem to $specialBackupFolder" -Level "INFO"
  }
}
```

## Examples of Common Modifications

### Add Database Backups
```json
// Config:
"Databases": [
  "C:\\Databases\\MyApp.mdb",
  "C:\\SQLite\\data.db"
]

// main.ps1 changes:
"Files\Databases"  // Add to $folderStructure
{ $_ -in @("Databases") } { "Files\Databases" }  // Add to switch
```

### Add Web Browser Data
```json
// Config:
"Browsers": [
  "C:\\Users\\R_sta\\AppData\\Local\\Google\\Chrome\\User Data\\Default\\Bookmarks",
  "C:\\Users\\R_sta\\AppData\\Roaming\\Mozilla\\Firefox\\Profiles"
]

// main.ps1 changes:
"Files\Browsers"  // Add to $folderStructure  
{ $_ -in @("Browsers") } { "Files\Browsers" }  // Add to switch
```

### Move Adult Games to separate backup type
```json
// Create new backup type:
"GamesOnly": [
  "Adult"
]
```

## Testing Your Changes

1. **Test with dry run first:**
   ```powershell
   .\Main.ps1 -BackupType YourNewType -Destination Local -DryRun
   ```

2. **Check the log output** to see if folders are created correctly

3. **Verify paths** in the temp folder structure before compression

4. **Test actual backup:**
   ```powershell
   .\Main.ps1 -BackupType YourNewType -Destination Local -LogLevel DEBUG
   ```

## Pro Tips

- **Use DEBUG logging** to see exactly what's happening
- **Always backup your config** before making changes  
- **Test with small data sets** first
- **Check temp folder** (`C:\Temp\Backup\{BackupName}`) to verify structure
- **Items not in any category** automatically go to `Files\Other`