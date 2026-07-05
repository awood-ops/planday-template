# Returns a valid Graph access token on stdout. Single auth path for all scripts.
# Caches the access token (DPAPI-encrypted) and only refreshes when it has less
# than 5 minutes left — avoids refresh-token rotation races when scripts run in
# parallel. Usage: $token = & "...\get-graph-token.ps1"   [-ForceRefresh]

param([switch]$ForceRefresh)

Add-Type -AssemblyName System.Security
$config  = Get-Content "$PSScriptRoot\..\config\graph-config.json" | ConvertFrom-Json
$tokenDir = "$env:LOCALAPPDATA\ClaudeGraph"
$rtPath  = "$tokenDir\refresh-token.bin"
$atPath  = "$tokenDir\access-token.bin"

function Protect-String([string]$s) {
    [System.Security.Cryptography.ProtectedData]::Protect(
        [System.Text.Encoding]::UTF8.GetBytes($s), $null,
        [System.Security.Cryptography.DataProtectionScope]::CurrentUser)
}
function Unprotect-Bytes([byte[]]$b) {
    [System.Text.Encoding]::UTF8.GetString(
        [System.Security.Cryptography.ProtectedData]::Unprotect(
            $b, $null, [System.Security.Cryptography.DataProtectionScope]::CurrentUser))
}

# Serve from cache while it still has 5+ minutes of life
if (-not $ForceRefresh -and (Test-Path $atPath)) {
    try {
        $cached = Unprotect-Bytes ([System.IO.File]::ReadAllBytes($atPath)) | ConvertFrom-Json
        if ([datetime]$cached.expires -gt (Get-Date).AddMinutes(5)) {
            Write-Output $cached.token
            exit 0
        }
    } catch { }  # unreadable cache — fall through and refresh
}

$refreshToken = Unprotect-Bytes ([System.IO.File]::ReadAllBytes($rtPath))
$resp = Invoke-RestMethod -Method POST `
    -Uri "https://login.microsoftonline.com/$($config.TenantId)/oauth2/v2.0/token" `
    -ContentType "application/x-www-form-urlencoded" `
    -Body @{
        grant_type    = "refresh_token"
        client_id     = $config.ClientId
        refresh_token = $refreshToken
        scope         = "Tasks.ReadWrite Calendars.ReadWrite Mail.ReadWrite Mail.Send MailboxSettings.ReadWrite offline_access"
    }

[System.IO.File]::WriteAllBytes($rtPath, (Protect-String $resp.refresh_token))
$cacheJson = @{ token = $resp.access_token; expires = (Get-Date).AddSeconds($resp.expires_in).ToString("o") } | ConvertTo-Json -Compress
[System.IO.File]::WriteAllBytes($atPath, (Protect-String $cacheJson))
Write-Output $resp.access_token
