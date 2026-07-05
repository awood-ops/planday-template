# Scans calendar for birthday events and creates a To Do task 1 week before each one.
# Also creates reminder tasks for Father's Day (3rd Sun Jun) and Mother's Day UK (Easter - 21 days).
# Safe to run repeatedly — skips events that already have a task.
# Add names to config\birthday-exclusions.json to permanently ignore someone.

$exclusionsPath = "$PSScriptRoot\..\config\birthday-exclusions.json"
$exclusions = if (Test-Path $exclusionsPath) { @(Get-Content $exclusionsPath | ConvertFrom-Json) } else { @() }

$accessToken = & "$PSScriptRoot\get-graph-token.ps1"
if (-not $accessToken) { Write-Error "Token refresh failed — run authenticate-graph.ps1 to re-authenticate."; exit 1 }
$h = @{ Authorization = "Bearer $accessToken"; "Content-Type" = "application/json" }

# Fetch calendar birthdays for the next 12 months
$after  = (Get-Date).ToString("yyyy-MM-ddT00:00:00")
$before = (Get-Date).AddMonths(12).ToString("yyyy-MM-ddT23:59:59")
$calUri = "https://graph.microsoft.com/v1.0/me/events?`$filter=contains(subject,'birthday') or contains(subject,'Birthday')&`$select=subject,start,categories&`$top=50"
$birthdays = (Invoke-RestMethod -Uri $calUri -Headers $h).value |
    Where-Object { $_.start.dateTime -ge $after -and $_.start.dateTime -le $before -and $_.categories -notcontains "PlanDay" }

# Fetch existing tasks to avoid duplicates
$listId = ((Invoke-RestMethod "https://graph.microsoft.com/v1.0/me/todo/lists" -Headers $h).value |
    Where-Object { $_.displayName -eq "Tasks" }).id
$existing = (Invoke-RestMethod "https://graph.microsoft.com/v1.0/me/todo/lists/$listId/tasks" -Headers $h).value |
    Where-Object { $_.title -like "*birthday*" -or $_.title -like "*Father's Day*" -or $_.title -like "*Mother's Day*" } |
    Select-Object -ExpandProperty title

$tz = [System.TimeZoneInfo]::Local.Id
$created = 0
$skipped = 0

foreach ($event in $birthdays) {
    $subject = $event.subject.Trim()
    $birthdayDate = [datetime]$event.start.dateTime
    $dueDate = $birthdayDate.AddDays(-7)

    if ($dueDate.Date -lt (Get-Date).Date) { $dueDate = (Get-Date).Date }

    $excluded = $exclusions | Where-Object { $subject -like "*$_*" }
    if ($excluded) { Write-Host "Skipped (excluded): $subject"; $skipped++; continue }

    # Only create the task when the birthday is within 3 weeks (task due date ~1 week before)
    if ($birthdayDate.Date -gt (Get-Date).Date.AddDays(21)) { $skipped++; continue }

    $taskTitle = "Get present and card — $subject ($($birthdayDate.ToString('d MMM')))"
    if ($existing | Where-Object { $_ -like "*$subject*" }) { Write-Host "Skipped (exists): $taskTitle"; $skipped++; continue }

    $body = @{
        title       = $taskTitle
        importance  = "high"
        dueDateTime = @{ dateTime = $dueDate.ToString("yyyy-MM-ddT00:00:00"); timeZone = $tz }
    } | ConvertTo-Json
    Invoke-RestMethod -Method POST -Uri "https://graph.microsoft.com/v1.0/me/todo/lists/$listId/tasks" -Headers $h -Body $body | Out-Null
    Write-Host "Created: $taskTitle (due $($dueDate.ToString('d MMM')))"
    $created++
}

# --- Annual floating events ---

function Get-FathersDay {
    param([int]$Year)
    $june1 = [datetime]"$Year-06-01"
    $dow = [int]$june1.DayOfWeek
    $firstSunday = $june1.AddDays($(if ($dow -eq 0) { 0 } else { 7 - $dow }))
    return $firstSunday.AddDays(14)  # 3rd Sunday in June
}

function Get-EasterSunday {
    param([int]$Year)
    $a = $Year % 19; $b = [Math]::Floor($Year / 100); $c = $Year % 100
    $d = [Math]::Floor($b / 4); $e = $b % 4
    $f = [Math]::Floor(($b + 8) / 25)
    $g = [Math]::Floor(($b - $f + 1) / 3)
    $h = (19 * $a + $b - $d - $g + 15) % 30
    $i = [Math]::Floor($c / 4); $k = $c % 4
    $l = (32 + 2 * $e + 2 * $i - $h - $k) % 7
    $m = [Math]::Floor(($a + 11 * $h + 22 * $l) / 451)
    $month = [Math]::Floor(($h + $l - 7 * $m + 114) / 31)
    $day   = (($h + $l - 7 * $m + 114) % 31) + 1
    return [datetime]"$Year-$month-$day"
}

function Get-MothersDay {
    param([int]$Year)
    return (Get-EasterSunday -Year $Year).AddDays(-21)  # Mothering Sunday (UK) = Easter - 21 days
}

$today = (Get-Date).Date
$annualEvents = @(
    @{ Name = "Father's Day"; ThisYear = Get-FathersDay $today.Year;  NextYear = Get-FathersDay ($today.Year + 1) }
    @{ Name = "Mother's Day"; ThisYear = Get-MothersDay $today.Year;  NextYear = Get-MothersDay ($today.Year + 1) }
)

foreach ($ev in $annualEvents) {
    $nextDate = if ($ev.ThisYear.Date -ge $today) { $ev.ThisYear } else { $ev.NextYear }

    if ($nextDate.Date -gt $today.AddDays(21)) { $skipped++; continue }

    $dueDate = $nextDate.AddDays(-7)
    if ($dueDate.Date -lt $today) { $dueDate = $today }

    $taskTitle = "Plan $($ev.Name) — $($nextDate.ToString('d MMM yyyy'))"
    if ($existing | Where-Object { $_ -like "*$($ev.Name)*" }) {
        Write-Host "Skipped (exists): $taskTitle"; $skipped++; continue
    }

    $body = @{
        title       = $taskTitle
        importance  = "high"
        dueDateTime = @{ dateTime = $dueDate.ToString("yyyy-MM-ddT00:00:00"); timeZone = $tz }
    } | ConvertTo-Json
    Invoke-RestMethod -Method POST -Uri "https://graph.microsoft.com/v1.0/me/todo/lists/$listId/tasks" -Headers $h -Body $body | Out-Null
    Write-Host "Created: $taskTitle (due $($dueDate.ToString('d MMM')))"
    $created++
}

Write-Host "`nDone — $created created, $skipped skipped."
