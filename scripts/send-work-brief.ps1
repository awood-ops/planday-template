# send-work-brief.ps1 — Sends a structured work day plan to the work email address
# Claude at work can parse this and add task slots to the work calendar.
#
# Usage:
#   pwsh -File send-work-brief.ps1 -Subject "Work Plan — Fri 8 May" -Body "..."
#   pwsh -File send-work-brief.ps1 -Subject "..." -BodyFile "path\to\body.txt"

param(
    [Parameter(Mandatory)]
    [string]$Subject,
    [string]$Body,
    [string]$BodyFile,
    [Parameter(Mandatory)][string]$To
)

if ($BodyFile) { $Body = Get-Content $BodyFile -Raw }
if (-not $Body) { Write-Error "Provide -Body or -BodyFile."; exit 1 }

$accessToken = & "$PSScriptRoot\get-graph-token.ps1"
if (-not $accessToken) { Write-Error "Token refresh failed — run authenticate-graph.ps1 to re-authenticate."; exit 1 }
$h = @{ Authorization = "Bearer $accessToken"; "Content-Type" = "application/json" }

$payload = @{
    message = @{
        subject = $Subject
        body    = @{ contentType = "Text"; content = $Body }
        toRecipients = @(@{ emailAddress = @{ address = $To } })
    }
    saveToSentItems = $false
} | ConvertTo-Json -Depth 6

Invoke-RestMethod -Method POST `
    -Uri "https://graph.microsoft.com/v1.0/me/sendMail" `
    -Headers $h -Body $payload | Out-Null

Write-Host "Sent: '$Subject' → $To"
