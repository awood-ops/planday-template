# Fetches all incomplete Microsoft To Do tasks and writes a daily markdown plan.
# Requires authenticate-graph.ps1 to have been run at least once.
# Usage: .\get-todo.ps1 [-Date "2026-05-08"]  (defaults to today)

param([string]$Date)

$accessToken = & "$PSScriptRoot\get-graph-token.ps1"
if (-not $accessToken) { Write-Error "Token refresh failed — run authenticate-graph.ps1 to re-authenticate."; exit 1 }
$headers = @{ Authorization = "Bearer $accessToken" }

# Fetch all lists and incomplete tasks
$lists = (Invoke-RestMethod -Uri "https://graph.microsoft.com/v1.0/me/todo/lists" -Headers $headers).value

$allTasks = foreach ($list in $lists) {
    (Invoke-RestMethod `
        -Uri "https://graph.microsoft.com/v1.0/me/todo/lists/$($list.id)/tasks?`$filter=status ne 'completed'" `
        -Headers $headers).value |
        ForEach-Object {
            [ordered]@{
                Title      = $_.title
                Status     = $_.status
                Importance = $_.importance
                DueDate    = if ($_.dueDateTime.dateTime) { [System.DateTime]::SpecifyKind([datetime]$_.dueDateTime.dateTime, [System.DateTimeKind]::Utc).ToLocalTime() } else { $null }
                Reminder   = if ($_.isReminderOn -and $_.reminderDateTime.dateTime) { [System.DateTime]::SpecifyKind([datetime]$_.reminderDateTime.dateTime, [System.DateTimeKind]::Utc).ToLocalTime() } else { $null }
                Body       = $_.body.content
                List       = $list.displayName
            }
        }
}

# Bucket tasks relative to target date (today by default)
$targetDate = if ($Date) { (Get-Date $Date).Date } else { (Get-Date).Date }
$overdue   = $allTasks | Where-Object { $_.DueDate -and $_.DueDate.Date -lt $targetDate } | Sort-Object DueDate
$dueToday  = $allTasks | Where-Object { $_.DueDate -and $_.DueDate.Date -eq $targetDate }
$thisWeek  = $allTasks | Where-Object { $_.DueDate -and $_.DueDate.Date -gt $targetDate -and $_.DueDate.Date -le $targetDate.AddDays(7) } | Sort-Object DueDate
$upcoming  = $allTasks | Where-Object { (-not $_.DueDate) -or $_.DueDate.Date -gt $targetDate.AddDays(7) } | Sort-Object DueDate

function Format-Task($task) {
    $suffix = ""
    if ($task.DueDate)   { $suffix += " *(due $($task.DueDate.ToString('d MMM')))*" }
    if ($task.Reminder)  { $suffix += " ⏰ $($task.Reminder.ToString('HH:mm'))" }
    if ($task.Importance -eq "high") { $suffix += " **[HIGH]**" }
    "- [ ] $($task.Title)$suffix"
}

$dateHeading = $targetDate.ToString("dddd d MMMM yyyy")
$lines = @("# $dateHeading", "")

if ($overdue)  { $lines += "## Overdue";    $lines += $overdue   | ForEach-Object { Format-Task $_ }; $lines += "" }
if ($dueToday) { $lines += "## Today";      $lines += $dueToday  | ForEach-Object { Format-Task $_ }; $lines += "" }
if ($thisWeek) { $lines += "## This Week";  $lines += $thisWeek  | ForEach-Object { Format-Task $_ }; $lines += "" }
if ($upcoming) { $lines += "## Upcoming";   $lines += $upcoming  | ForEach-Object { Format-Task $_ }; $lines += "" }

# Write daily markdown file
$todoDir = "$PSScriptRoot\..\todo"
if (-not (Test-Path $todoDir)) { New-Item -ItemType Directory -Path $todoDir | Out-Null }
$filePath = "$todoDir\$($targetDate.ToString('yyyy-MM-dd')).md"
$lines | Set-Content -Path $filePath -Encoding UTF8

Write-Host "Written: $filePath"

# Also output JSON for Claude to parse
$allTasks | ConvertTo-Json -Depth 4
