# clear-planday-events.ps1
# Deletes ALL PlanDay events for a given date — tracked IDs first, then repeated calendarView sweeps.
# Usage: .\clear-planday-events.ps1 [-Date "2026-05-07"]

param([string]$Date = (Get-Date).ToString("yyyy-MM-dd"))

$accessToken = & "$PSScriptRoot\get-graph-token.ps1"
if (-not $accessToken) { Write-Error "Token refresh failed — run authenticate-graph.ps1 to re-authenticate."; exit 1 }
$h = @{ Authorization = "Bearer $accessToken"; "Content-Type" = "application/json" }

# Delete tracked IDs from last sync run
$trackingFile = "$PSScriptRoot\..\todo\planday-event-ids.json"
$trackingData = if (Test-Path $trackingFile) {
    try { Get-Content $trackingFile -Raw | ConvertFrom-Json } catch { [PSCustomObject]@{} }
} else { [PSCustomObject]@{} }
$prevIds = if ($null -ne $trackingData.$Date) { @($trackingData.$Date) } else { @() }
Write-Host "Tracked IDs for $Date`: $($prevIds.Count)" -ForegroundColor Cyan
foreach ($id in $prevIds) {
    try {
        Invoke-RestMethod -Method DELETE "https://graph.microsoft.com/v1.0/me/events/$id" -Headers $h | Out-Null
        Write-Host "  Deleted tracked: $id" -ForegroundColor DarkYellow
    } catch {
        Write-Host "  Already gone: $id" -ForegroundColor DarkGray
    }
}

# Loop calendarView sweeps until no PlanDay events remain
$targetDate = [datetime]::ParseExact($Date, "yyyy-MM-dd", $null)
$dayStartUtc = $targetDate.Date.ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
$dayEndUtc   = $targetDate.Date.AddDays(1).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")

$round = 0
do {
    $round++
    if ($round -gt 1) { Start-Sleep -Seconds 4 }
    Write-Host "Sweep $round..." -ForegroundColor Cyan
    $found = 0
    $page = Invoke-RestMethod ("https://graph.microsoft.com/v1.0/me/calendarView" +
        "?startDateTime=$dayStartUtc&endDateTime=$dayEndUtc&`$select=id,subject,categories") -Headers $h
    do {
        foreach ($evt in ($page.value | Where-Object { $_.categories -contains "PlanDay" })) {
            try {
                Invoke-RestMethod -Method DELETE "https://graph.microsoft.com/v1.0/me/events/$($evt.id)" -Headers $h | Out-Null
                Write-Host "  Deleted: $($evt.subject)" -ForegroundColor Yellow
            } catch {
                Write-Host "  Delete failed: $($evt.subject)" -ForegroundColor Red
            }
            $found++
        }
        $page = if ($page.'@odata.nextLink') { Invoke-RestMethod $page.'@odata.nextLink' -Headers $h } else { $null }
    } while ($page)
    Write-Host "  $found PlanDay event(s) found this sweep." -ForegroundColor Cyan
} while ($found -gt 0 -and $round -lt 6)

# Clear the tracking entry so next sync starts clean
$trackingData | Add-Member -NotePropertyName $Date -NotePropertyValue @() -Force
$trackingData | ConvertTo-Json | Set-Content $trackingFile

Write-Host "Done. $Date is clear of PlanDay events." -ForegroundColor Green
