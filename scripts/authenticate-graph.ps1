# One-time authentication using auth code + PKCE (opens browser, catches localhost callback).
# Run in pwsh (PowerShell 7).
#
# Least privilege: the default scopes cover the core task/calendar scripts only.
# Add scopes for the optional scripts you actually use, e.g.:
#   send-work-brief.ps1 needs Mail.Send:
#     pwsh -File authenticate-graph.ps1 -Scopes "Tasks.ReadWrite Calendars.ReadWrite Mail.Send offline_access"
# Re-running this script replaces the stored token and its consented scopes.

param(
    [string]$Scopes = "Tasks.ReadWrite Calendars.ReadWrite offline_access"
)

$config = Get-Content -Path "$PSScriptRoot\..\config\graph-config.json" | ConvertFrom-Json
$tokenDir = "$env:LOCALAPPDATA\ClaudeGraph"
if (-not (Test-Path $tokenDir)) { New-Item -ItemType Directory -Path $tokenDir | Out-Null }
$tokenPath = "$tokenDir\refresh-token.bin"
$redirectUri = "http://localhost:8085"

Add-Type -AssemblyName System.Security
Add-Type -AssemblyName System.Web

# Generate PKCE code verifier + challenge
$codeVerifier = -join ((65..90 + 97..122 + 48..57) | Get-Random -Count 64 | ForEach-Object { [char]$_ })
$sha256 = [System.Security.Cryptography.SHA256]::Create()
$hashBytes = $sha256.ComputeHash([System.Text.Encoding]::ASCII.GetBytes($codeVerifier))
$codeChallenge = [Convert]::ToBase64String($hashBytes).TrimEnd('=').Replace('+', '-').Replace('/', '_')

# Build auth URL
$scope = [System.Uri]::EscapeDataString($Scopes)
$encodedRedirect = [System.Uri]::EscapeDataString($redirectUri)
$authUrl = "https://login.microsoftonline.com/$($config.TenantId)/oauth2/v2.0/authorize" +
    "?client_id=$($config.ClientId)" +
    "&response_type=code" +
    "&redirect_uri=$encodedRedirect" +
    "&scope=$scope" +
    "&code_challenge=$codeChallenge" +
    "&code_challenge_method=S256"

# Start localhost listener
$listener = [System.Net.HttpListener]::new()
$listener.Prefixes.Add("$redirectUri/")
$listener.Start()

Write-Host "Opening browser for sign-in..." -ForegroundColor Cyan
Start-Process $authUrl

# Wait up to 2 minutes for callback
$task = $listener.GetContextAsync()
if (-not $task.Wait(120000)) {
    $listener.Stop()
    Write-Error "Timed out waiting for sign-in."
    exit 1
}
$context = $task.Result

# Extract auth code
$code = [System.Web.HttpUtility]::ParseQueryString($context.Request.Url.Query)["code"]

# Return success page to browser
$html = [System.Text.Encoding]::UTF8.GetBytes("<html><body><h2>Signed in successfully. You can close this window.</h2></body></html>")
$context.Response.ContentLength64 = $html.Length
$context.Response.OutputStream.Write($html, 0, $html.Length)
$context.Response.OutputStream.Close()
$listener.Stop()

if (-not $code) {
    Write-Error "No auth code received."
    exit 1
}

# Exchange code for tokens
$tokenResponse = Invoke-RestMethod -Method POST `
    -Uri "https://login.microsoftonline.com/$($config.TenantId)/oauth2/v2.0/token" `
    -ContentType "application/x-www-form-urlencoded" `
    -Body @{
        grant_type    = "authorization_code"
        client_id     = $config.ClientId
        code          = $code
        redirect_uri  = $redirectUri
        code_verifier = $codeVerifier
    }

# Encrypt and save refresh token via Windows DPAPI
$bytes = [System.Text.Encoding]::UTF8.GetBytes($tokenResponse.refresh_token)
$encrypted = [System.Security.Cryptography.ProtectedData]::Protect(
    $bytes, $null, [System.Security.Cryptography.DataProtectionScope]::CurrentUser
)
[System.IO.File]::WriteAllBytes($tokenPath, $encrypted)

# Record the consented scopes (not secret) so get-graph-token.ps1 refreshes with the same set
Set-Content -Path "$tokenDir\scopes.txt" -Value $Scopes -NoNewline

Write-Host "Done! Token saved — scripts will now run silently." -ForegroundColor Green
Write-Host "Consented scopes: $Scopes" -ForegroundColor DarkCyan
