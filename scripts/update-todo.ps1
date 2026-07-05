# Update a Microsoft To Do task by partial title match.
# Usage examples:
#   .\update-todo.ps1 -Task "firewall" -Due "Thursday"
#   .\update-todo.ps1 -Task "firewall" -Due "Thursday" -Reminder "9am"
#   .\update-todo.ps1 -Task "on call" -Due "tomorrow" -Reminder "08:30"
#   .\update-todo.ps1 -Task "Ben's ALZ" -Done
#   .\update-todo.ps1 -Task "audit" -Due "7 May" -Importance high -Reminder "9am"
#   .\update-todo.ps1 -Task "Packt" -NewTitle "[PERSONAL] Sign Packt Publishing document"

param(
    [Parameter(Mandatory)][string]$Task,
    [string]$NewTitle,
    [string]$Due,
    [switch]$ClearDue,
    [string]$Reminder,
    [switch]$Done,
    [ValidateSet("high","normal","low")][string]$Importance
)

if (-not $NewTitle -and -not $Due -and -not $ClearDue -and -not $Done -and -not $Importance -and -not $Reminder) {
    Write-Error "Specify at least one of -NewTitle, -Due, -ClearDue, -Done, -Importance, or -Reminder."
    exit 1
}

# Get token
$accessToken = & "$PSScriptRoot\get-graph-token.ps1"
if (-not $accessToken) { Write-Error "Token refresh failed — run authenticate-graph.ps1 to re-authenticate."; exit 1 }
$headers = @{ Authorization = "Bearer $accessToken" }

# Search all lists for a matching task
$lists = (Invoke-RestMethod "https://graph.microsoft.com/v1.0/me/todo/lists" -Headers $headers).value
$match = $null
$matchListId = $null

foreach ($list in $lists) {
    $tasks = (Invoke-RestMethod "https://graph.microsoft.com/v1.0/me/todo/lists/$($list.id)/tasks?`$top=200" -Headers $headers).value
    $found = $tasks | Where-Object { $_.title.IndexOf($Task, [System.StringComparison]::OrdinalIgnoreCase) -ge 0 -and $_.status -ne "completed" }
    if ($found.Count -gt 1) {
        Write-Error "Multiple tasks match '$Task':`n$($found.title -join "`n")`nBe more specific."
        exit 1
    }
    if ($found) { $match = $found; $matchListId = $list.id; break }
}

if (-not $match) {
    Write-Error "No incomplete task found matching '$Task'."
    exit 1
}

# Build patch body
$patch = @{}
$tz = [System.TimeZoneInfo]::Local.Id

if ($NewTitle)   { $patch.title = $NewTitle }
if ($Done)       { $patch.status = "completed" }
if ($Importance) { $patch.importance = $Importance }

$dueDate = $null
if ($Due) {
    $dueDate = Get-Date $Due -ErrorAction Stop
    $patch.dueDateTime = @{ dateTime = $dueDate.ToString("yyyy-MM-ddT00:00:00"); timeZone = $tz }
} elseif ($ClearDue) {
    $patch.dueDateTime = $null
}

if ($Reminder) {
    $reminderBase = if ($dueDate) {
        $dueDate
    } elseif ($match.dueDateTime.dateTime) {
        [System.DateTime]::SpecifyKind([datetime]$match.dueDateTime.dateTime, [System.DateTimeKind]::Utc).ToLocalTime()
    } else {
        Get-Date
    }
    $reminderTime = Get-Date $Reminder -ErrorAction Stop
    $reminderDateTime = $reminderBase.Date + $reminderTime.TimeOfDay
    $patch.isReminderOn     = $true
    $patch.reminderDateTime = @{ dateTime = $reminderDateTime.ToString("yyyy-MM-ddTHH:mm:ss"); timeZone = $tz }
}

Invoke-RestMethod -Method PATCH `
    -Uri "https://graph.microsoft.com/v1.0/me/todo/lists/$matchListId/tasks/$($match.id)" `
    -Headers ($headers + @{ "Content-Type" = "application/json" }) `
    -Body ($patch | ConvertTo-Json -Depth 3) | Out-Null

# Confirm
$changes = @()
if ($NewTitle)   { $changes += "title → '$NewTitle'" }
if ($Due)        { $changes += "due → $($dueDate.ToString('dddd d MMM'))" }
if ($ClearDue)   { $changes += "due date cleared" }
if ($Reminder)   { $changes += "reminder → $($reminderDateTime.ToString('dddd d MMM HH:mm'))" }
if ($Done)       { $changes += "marked complete" }
if ($Importance) { $changes += "importance → $Importance" }
Write-Host "Updated '$($match.title)': $($changes -join ', ')" -ForegroundColor Green
