# Creates a new Microsoft To Do task.
# Usage: .\create-todo.ps1 -Title "Task title" [-Due "2026-05-06"] [-Reminder "09:00"] [-Importance "high"]

param(
    [Parameter(Mandatory)][string]$Title,
    [string]$Due,
    [string]$Reminder,
    [ValidateSet("normal","high")][string]$Importance = "normal",
    [ValidateSet("","weekly","monthly")][string]$Recurrence = ""
)

$accessToken = & "$PSScriptRoot\get-graph-token.ps1"
if (-not $accessToken) { Write-Error "Token refresh failed — run authenticate-graph.ps1 to re-authenticate."; exit 1 }
$h = @{ Authorization = "Bearer $accessToken"; "Content-Type" = "application/json" }
$tz = [System.TimeZoneInfo]::Local.Id

$listId = ((Invoke-RestMethod "https://graph.microsoft.com/v1.0/me/todo/lists" -Headers $h).value |
    Where-Object { $_.displayName -eq "Tasks" }).id

$body = [ordered]@{ title = $Title; importance = $Importance }

if ($Due) {
    $dueDate = [datetime]$Due
    $body.dueDateTime = @{ dateTime = $dueDate.ToString("yyyy-MM-ddT00:00:00"); timeZone = $tz }
}

if ($Reminder) {
    $reminderBase = if ($Due) { [datetime]$Due } else { (Get-Date) }
    $reminderTime = [datetime]"$($reminderBase.ToString('yyyy-MM-dd')) $Reminder"
    $body.isReminderOn = $true
    $body.reminderDateTime = @{ dateTime = $reminderTime.ToString("yyyy-MM-ddTHH:mm:ss"); timeZone = $tz }
}

if ($Recurrence -and $Due) {
    $startDate = (Get-Date $Due).ToString("yyyy-MM-dd")
    if ($Recurrence -eq "weekly") {
        $dayOfWeek = (Get-Date $Due).DayOfWeek.ToString().ToLower()
        $body.recurrence = @{
            pattern = @{ type = "weekly"; interval = 1; daysOfWeek = [string[]]@($dayOfWeek) }
            range   = @{ type = "noEnd"; startDate = $startDate }
        }
    } else {
        $body.recurrence = @{
            pattern = @{ type = "absoluteMonthly"; interval = 1; dayOfMonth = (Get-Date $Due).Day }
            range   = @{ type = "noEnd"; startDate = $startDate }
        }
    }
}

$result = Invoke-RestMethod -Method POST `
    -Uri "https://graph.microsoft.com/v1.0/me/todo/lists/$listId/tasks" `
    -Headers $h -Body ($body | ConvertTo-Json -Depth 5)

$detail = "importance: $($result.importance)"
if ($Due)      { $detail += ", due: $Due" }
if ($Reminder) { $detail += ", reminder: $Reminder" }
Write-Host "Created: '$($result.title)' ($detail)"
