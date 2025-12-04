# Analyze backup configuration
$configPath = "C:\Scripts\Backup\config\bkp_cfg.json"
$config = Get-Content $configPath | ConvertFrom-Json

Write-Host "`n=== DUPLICATE PATH ANALYSIS ===" -ForegroundColor Cyan

# Check for duplicates
$allPaths = @{}
$duplicates = @()

foreach($cat in $config.BackupItems.PSObject.Properties) {
    if($cat.Value -is [array]) {
        foreach($path in $cat.Value) {
            if($allPaths.ContainsKey($path)) {
                $duplicates += [PSCustomObject]@{
                    Path = $path
                    Category1 = $allPaths[$path]
                    Category2 = $cat.Name
                }
            } else {
                $allPaths[$path] = $cat.Name
            }
        }
    }
}

if($duplicates.Count -gt 0) {
    Write-Host "Found $($duplicates.Count) duplicate(s):" -ForegroundColor Yellow
    $duplicates | Format-Table -AutoSize
} else {
    Write-Host "No duplicates found!" -ForegroundColor Green
}

Write-Host "`n=== CATEGORY COVERAGE ANALYSIS ===" -ForegroundColor Cyan

# Get all backup item categories
$allCategories = $config.BackupItems.PSObject.Properties.Name | Where-Object { $_ -notlike "_*" }
Write-Host "Total backup item categories: $($allCategories.Count)"

# Get all categories used in backup types
$usedCategories = @()
foreach($type in $config.BackupTypes.PSObject.Properties) {
    $usedCategories += $type.Value
}
$usedCategories = $usedCategories | Select-Object -Unique

# Find categories not in any backup type
$unusedCategories = $allCategories | Where-Object { $_ -notin $usedCategories }

if($unusedCategories) {
    Write-Host "`nCategories NOT in any backup type:" -ForegroundColor Yellow
    $unusedCategories | ForEach-Object { Write-Host "  - $_" -ForegroundColor Yellow }
} else {
    Write-Host "All categories are assigned to at least one backup type!" -ForegroundColor Green
}

Write-Host "`n=== BACKUP TYPE ANALYSIS ===" -ForegroundColor Cyan

# Check if ALL type exists
$hasAllType = $config.BackupTypes.PSObject.Properties.Name -contains "All"
if($hasAllType) {
    $allTypeCategories = $config.BackupTypes.All
    $missingFromAll = $allCategories | Where-Object { $_ -notin $allTypeCategories }
    if($missingFromAll) {
        Write-Host "ALL type exists but missing categories:" -ForegroundColor Yellow
        $missingFromAll | ForEach-Object { Write-Host "  - $_" -ForegroundColor Yellow }
    } else {
        Write-Host "ALL type exists and contains all categories!" -ForegroundColor Green
    }
} else {
    Write-Host "ALL backup type does NOT exist" -ForegroundColor Red
}

# List all backup types
Write-Host "`nAvailable backup types:"
$config.BackupTypes.PSObject.Properties | ForEach-Object {
    Write-Host "  $($_.Name): $($_.Value.Count) categories"
}
