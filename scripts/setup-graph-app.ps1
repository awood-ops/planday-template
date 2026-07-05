# One-time setup: registers an Azure AD app for Microsoft To Do access via Azure CLI
# Run this in pwsh (PowerShell 7)

param([Parameter(Mandatory)][string]$TenantId)

Write-Host "Logging in to Azure (your tenant)..." -ForegroundColor Cyan
az login --use-device-code --tenant $TenantId --allow-no-subscriptions | Out-Null
az account set --subscription (az account list --query "[?tenantId=='$TenantId'].id" --output tsv 2>$null) 2>$null

# Get Tasks.ReadWrite permission GUID from Graph service principal
Write-Host "Looking up Tasks.ReadWrite permission..." -ForegroundColor Cyan
$tasksPermId = az ad sp show `
    --id 00000003-0000-0000-c000-000000000000 `
    --query "oauth2PermissionScopes[?value=='Tasks.ReadWrite'].id" `
    --output tsv

if (-not $tasksPermId) {
    Write-Error "Could not find Tasks.ReadWrite permission."
    exit 1
}

# Create the app registration
Write-Host "Creating app registration..." -ForegroundColor Cyan
$appJson = az ad app create `
    --display-name "Claude Code" `
    --sign-in-audience "AzureADMyOrg" `
    --output json | ConvertFrom-Json

$appId = $appJson.appId
$objectId = $appJson.id

# Add Tasks.ReadWrite delegated permission
Write-Host "Adding Tasks.ReadWrite permission..." -ForegroundColor Cyan
az ad app permission add `
    --id $objectId `
    --api 00000003-0000-0000-c000-000000000000 `
    --api-permissions "$($tasksPermId)=Scope" | Out-Null

# Enable public client flow with a loopback redirect (matches authenticate-graph.ps1)
Write-Host "Enabling public client flow..." -ForegroundColor Cyan
az ad app update `
    --id $objectId `
    --public-client-redirect-uris "http://localhost:8085" | Out-Null

# Save config
$config = [ordered]@{
    ClientId = $appId
    TenantId = $TenantId
}
$configPath = "$PSScriptRoot\..\config\graph-config.json"
$config | ConvertTo-Json | Set-Content -Path $configPath -Encoding UTF8

Write-Host "`nDone!" -ForegroundColor Green
Write-Host "  Client ID : $appId"
Write-Host "  Tenant ID : $TenantId"
Write-Host "  Config    : $configPath"
