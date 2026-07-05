# Fetches all incomplete tasks for a 7-day window and writes a weekly markdown plan.
# Usage: .\get-week-tasks.ps1 [-WeekStart "2026-05-18"]  (defaults to today)

param([string]$WeekStart)

$accessToken = & "$PSScriptRoot\get-graph-token.ps1"
if (-not $accessToken) { Write-Error "Token refresh failed — run authenticate-graph.ps1 to re-authenticate."; exit 1 }
$headers = @{ Authorization = "Bearer $accessToken" }

$lists    = (Invoke-RestMethod -Uri "https://graph.microsoft.com/v1.0/me/todo/lists" -Headers $headers).value
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

$startDate = if ($WeekStart) { (Get-Date $WeekStart).Date } else { (Get-Date).Date }
$endDate   = $startDate.AddDays(6)

$overdue = $allTasks | Where-Object { $_.DueDate -and $_.DueDate.Date -lt $startDate } | Sort-Object DueDate
$byDay   = 0..6 | ForEach-Object {
    $day   = $startDate.AddDays($_)
    $tasks = @($allTasks | Where-Object { $_.DueDate -and $_.DueDate.Date -eq $day })
    [ordered]@{
        Date      = $day.ToString("yyyy-MM-dd")
        DayLabel  = $day.ToString("dddd d MMMM")
        Tasks     = $tasks
        HighCount = @($tasks | Where-Object { $_.Importance -eq "high" }).Count
    }
}
$beyond = $allTasks | Where-Object { (-not $_.DueDate) -or $_.DueDate.Date -gt $endDate } | Sort-Object DueDate

function Format-Task($task) {
    $suffix = ""
    if ($task.DueDate)  { $suffix += " *(due $($task.DueDate.ToString('d MMM')))*" }
    if ($task.Reminder) { $suffix += " ⏰ $($task.Reminder.ToString('HH:mm'))" }
    if ($task.Importance -eq "high") { $suffix += " **[HIGH]**" }
    "- [ ] $($task.Title)$suffix"
}

$heading = "Week of $($startDate.ToString('d MMM'))–$($endDate.ToString('d MMM yyyy'))"
$lines   = @("# $heading", "")

if ($overdue) {
    $lines += "## Overdue"
    $lines += $overdue | ForEach-Object { Format-Task $_ }
    $lines += ""
}

foreach ($bucket in $byDay) {
    $tag    = if ($bucket.HighCount -gt 0) { " ($($bucket.HighCount) HIGH)" } else { "" }
    $lines += "## $($bucket.DayLabel)$tag"
    if ($bucket.Tasks.Count -gt 0) {
        $lines += $bucket.Tasks | ForEach-Object { Format-Task $_ }
    } else {
        $lines += "*(no tasks due)*"
    }
    $lines += ""
}

if ($beyond) {
    $lines += "## Beyond this week"
    $lines += $beyond | ForEach-Object { Format-Task $_ }
    $lines += ""
}

$todoDir = "$PSScriptRoot\..\todo"
if (-not (Test-Path $todoDir)) { New-Item -ItemType Directory -Path $todoDir | Out-Null }
$filePath = "$todoDir\week-$($startDate.ToString('yyyy-MM-dd')).md"
$lines | Set-Content -Path $filePath -Encoding UTF8

[Console]::Error.WriteLine("Written: $filePath")

$allTasks | ConvertTo-Json -Depth 4
