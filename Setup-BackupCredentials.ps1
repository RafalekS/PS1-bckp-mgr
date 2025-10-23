<#
.SYNOPSIS
    Setup script for Backup System credentials and environment variables

.DESCRIPTION
    Configures Gotify token using DPAPI encryption (recommended) or environment variable (legacy).
    DPAPI encryption is more secure as tokens are encrypted at rest and not visible in config.
    Part of Phase 3 Security Hardening (Issue #38).

.PARAMETER GotifyToken
    The Gotify API token to configure

.PARAMETER UseEnvironmentVariable
    Use legacy environment variable method instead of DPAPI encryption

.NOTES
    Version: 2.0
    Last Modified: 2025-10-22
    Supports both DPAPI encryption (recommended) and environment variable (legacy)
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory=$false)]
    [string]$GotifyToken = "A7QEDoNZucEO8UD",

    [Parameter(Mandatory=$false)]
    [switch]$UseEnvironmentVariable
)

Write-Host "========================================" -ForegroundColor Cyan
Write-Host " Backup System Credentials Setup" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
Write-Host ""

# Load utilities for DPAPI functions
$scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
. "$scriptRoot\BackupUtilities.ps1"

# Initialize minimal logging for setup script
Initialize-Logging -LogLevel "INFO" -LogFilePath "$scriptRoot\log\setup.log" -LogFormat "Text"

# Function to set environment variable
function Set-EnvironmentVariable {
    param(
        [string]$Name,
        [string]$Value,
        [string]$Target = "User"
    )

    try {
        [System.Environment]::SetEnvironmentVariable($Name, $Value, $Target)
        Write-Host "[SUCCESS] Set $Name environment variable for $Target scope" -ForegroundColor Green
        return $true
    }
    catch {
        Write-Host "[ERROR] Failed to set ${Name}: $_" -ForegroundColor Red
        return $false
    }
}

# 1. Set Gotify Token
if ($UseEnvironmentVariable) {
    Write-Host "[1/3] Setting Gotify Token (Environment Variable - Legacy Method)..." -ForegroundColor Yellow
    Write-Host "      Token: $GotifyToken"
    Write-Host "      NOTE: Consider using DPAPI encryption instead (run without -UseEnvironmentVariable)" -ForegroundColor Yellow
    $gotifySet = Set-EnvironmentVariable -Name "GOTIFY_TOKEN" -Value $GotifyToken -Target "User"

    if ($gotifySet) {
        # Set for current session as well
        $env:GOTIFY_TOKEN = $GotifyToken
        Write-Host "      Token is now available in current session" -ForegroundColor Green
    }
}
else {
    Write-Host "[1/3] Encrypting Gotify Token with DPAPI..." -ForegroundColor Yellow
    Write-Host "      Plain token: $GotifyToken"

    try {
        $encryptedToken = Protect-BackupSecret -Secret $GotifyToken
        Write-Host "      [SUCCESS] Token encrypted successfully" -ForegroundColor Green
        Write-Host "      Encrypted token (first 50 chars): $($encryptedToken.Substring(0, [Math]::Min(50, $encryptedToken.Length)))..." -ForegroundColor Gray

        # Update config file
        $configPath = Join-Path $scriptRoot "config\bkp_cfg.json"
        Write-Host ""
        Write-Host "      Updating config file: $configPath" -ForegroundColor Cyan

        $config = Get-Content $configPath | ConvertFrom-Json

        # Add or update TokenEncrypted field
        if ($config.Notifications.Gotify.PSObject.Properties.Name -contains "TokenEncrypted") {
            $config.Notifications.Gotify.TokenEncrypted = $encryptedToken
            Write-Host "      [INFO] Updated existing TokenEncrypted field" -ForegroundColor Cyan
        }
        else {
            $config.Notifications.Gotify | Add-Member -MemberType NoteProperty -Name "TokenEncrypted" -Value $encryptedToken -Force
            Write-Host "      [INFO] Added new TokenEncrypted field" -ForegroundColor Cyan
        }

        # Remove old Token field if it exists (for security)
        if ($config.Notifications.Gotify.PSObject.Properties.Name -contains "Token") {
            Write-Host "      [INFO] Removing old Token field for security" -ForegroundColor Yellow
            $config.Notifications.Gotify.PSObject.Properties.Remove("Token")
        }

        # Save config
        $config | ConvertTo-Json -Depth 10 | Set-Content $configPath
        Write-Host "      [SUCCESS] Config file updated with encrypted token" -ForegroundColor Green
        $gotifySet = $true
    }
    catch {
        Write-Host "      [ERROR] Failed to encrypt token: $_" -ForegroundColor Red
        $gotifySet = $false
    }
}

Write-Host ""

# 2. Verify SSH key path
Write-Host "[2/3] Verifying SSH key path..." -ForegroundColor Yellow
$sshKeyPath = "$env:USERPROFILE\.ssh\keys\open_ssh.key"
Write-Host "      Expected path: $sshKeyPath"

if (Test-Path $sshKeyPath) {
    Write-Host "      [SUCCESS] SSH key found" -ForegroundColor Green
} else {
    Write-Host "      [WARNING] SSH key not found at expected location" -ForegroundColor Yellow
    Write-Host "      You may need to update the SSH destination config" -ForegroundColor Yellow
}

Write-Host ""
Write-Host "========================================" -ForegroundColor Cyan
Write-Host " Setup Complete" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
Write-Host ""

if ($UseEnvironmentVariable) {
    Write-Host "Credentials Configured (Environment Variable Method):" -ForegroundColor Green
    Write-Host "  - GOTIFY_TOKEN = $GotifyToken" -ForegroundColor White
    Write-Host ""
    Write-Host "IMPORTANT:" -ForegroundColor Yellow
    Write-Host "  1. Close and reopen any PowerShell windows to use the new variables" -ForegroundColor White
    Write-Host "  2. The backup system will now read Gotify token from `$env:GOTIFY_TOKEN" -ForegroundColor White
    Write-Host "  3. SSH key path uses `$env:USERPROFILE environment variable" -ForegroundColor White
}
else {
    Write-Host "Credentials Configured (DPAPI Encryption - Recommended):" -ForegroundColor Green
    Write-Host "  - Gotify token encrypted and stored in config file" -ForegroundColor White
    Write-Host "  - Token can only be decrypted by current Windows user: $env:USERNAME" -ForegroundColor White
    Write-Host ""
    Write-Host "IMPORTANT:" -ForegroundColor Yellow
    Write-Host "  1. Config file updated: config\bkp_cfg.json" -ForegroundColor White
    Write-Host "  2. Token is encrypted at rest using Windows DPAPI" -ForegroundColor White
    Write-Host "  3. Token is NOT visible in config file or process lists" -ForegroundColor White
    Write-Host "  4. To update token, run this script again" -ForegroundColor White
}

Write-Host ""

if ($UseEnvironmentVariable) {
    Write-Host "To verify the setup, run:" -ForegroundColor Cyan
    Write-Host "  `$env:GOTIFY_TOKEN" -ForegroundColor White
}
else {
    Write-Host "To verify the setup:" -ForegroundColor Cyan
    Write-Host "  1. Check config\bkp_cfg.json for 'TokenEncrypted' field" -ForegroundColor White
    Write-Host "  2. Run a test backup with notifications enabled" -ForegroundColor White
}

Write-Host ""

# Test notification (optional)
$testNotification = Read-Host "[3/3] Would you like to test the Gotify notification? (Y/N)"
if ($testNotification -eq "Y" -or $testNotification -eq "y") {
    Write-Host ""
    Write-Host "Testing Gotify notification..." -ForegroundColor Yellow

    try {
        # Get token based on method used
        $testToken = if ($UseEnvironmentVariable) {
            $env:GOTIFY_TOKEN
        } else {
            $GotifyToken
        }

        # Read Gotify URL from config
        $gotifyUrl = $config.Notifications.Gotify.Url
        if (-not $gotifyUrl) {
            $gotifyUrl = "http://localhost:12680/message"  # Default fallback
        }
        $headers = @{
            "X-Gotify-Key" = $testToken
        }

        $methodDesc = if ($UseEnvironmentVariable) { "Environment variable" } else { "DPAPI encryption" }
        $body = @{
            title = "Backup System Test"
            message = "Credential setup successful!`nMethod: $methodDesc`nGotify notifications are working."
            priority = 5
        } | ConvertTo-Json

        $response = Invoke-RestMethod -Uri $gotifyUrl -Method Post -Headers $headers -Body $body -ContentType "application/json"
        Write-Host "[SUCCESS] Test notification sent successfully!" -ForegroundColor Green
        Write-Host "  Check your Gotify server for the test message." -ForegroundColor White
    }
    catch {
        Write-Host "[ERROR] Failed to send test notification: $_" -ForegroundColor Red
        Write-Host "  Please verify:" -ForegroundColor Yellow
        Write-Host "    - Gotify server is accessible at $gotifyUrl" -ForegroundColor White
        Write-Host "    - Token is correct" -ForegroundColor White
    }
}

Write-Host ""
Write-Host "Press any key to exit..." -ForegroundColor Gray
$null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
