# Creates To-Do tasks with a 07:00 reminder for upcoming bin collections.
# Idempotent — skips days that already have a matching bin task.
# Usage: pwsh -File sync-bins-to-calendar.ps1 [-DaysAhead 14]

param([int]$DaysAhead = 14)

$accessToken = pwsh -File "$PSScriptRoot\get-graph-token.ps1"
$h = @{ Authorization = "Bearer $accessToken"; "Content-Type" = "application/json" }

# Get upcoming collections
$bins = pwsh -File "$PSScriptRoot\get-bin-schedule.ps1" -DaysAhead $DaysAhead 2>&1 | Out-String
if (-not $bins.Trim()) { Write-Host "No collections in window."; exit 0 }

try   { $collections = $bins | ConvertFrom-Json }
catch { Write-Host "Bin script error — skipping."; exit 0 }

# Fetch existing tasks to check for duplicates
$taskListId = (Invoke-RestMethod "https://graph.microsoft.com/v1.0/me/todo/lists" -Headers $h).value |
    Where-Object { $_.displayName -eq "Tasks" } | Select-Object -First 1 -ExpandProperty id

$existingTasks = (Invoke-RestMethod "https://graph.microsoft.com/v1.0/me/todo/lists/$taskListId/tasks?`$top=100" -Headers $h).value

# Group by date
$byDate = $collections | Group-Object date

foreach ($group in $byDate) {
    $date     = $group.Name   # yyyy-MM-dd
    $services = $group.Group | ForEach-Object {
        switch ($_.service) {
            "REFUSE"    { "Grey bin" }
            "RECYCLING" { "Recycling box" }
            "GARDEN"    { "Garden bin" }
            default     { $_.service }
        }
    }
    $label   = $services -join " + "
    $title   = "Bins out — $label"

    # Skip if a task with this title already exists
    $dupe = $existingTasks | Where-Object {
        $_.title.IndexOf("Bins out", [System.StringComparison]::OrdinalIgnoreCase) -ge 0 -and
        $_.reminderDateTime -and $_.reminderDateTime.dateTime.ToString("yyyy-MM-dd") -eq $date
    }
    if ($dupe) {
        Write-Host "Exists:  $title ($date)"
        continue
    }

    $body = @{
        title       = $title
        importance  = "normal"
        dueDateTime      = @{ dateTime = "${date}T07:00:00.000000"; timeZone = "Europe/London" }
        reminderDateTime = @{ dateTime = "${date}T07:00:00.000000"; timeZone = "Europe/London" }
        isReminderOn = $true
    } | ConvertTo-Json -Depth 3

    Invoke-RestMethod -Method POST `
        "https://graph.microsoft.com/v1.0/me/todo/lists/$taskListId/tasks" `
        -Headers $h -Body $body | Out-Null
    Write-Host "Created: $title ($date) ⏰ 07:00"
}
