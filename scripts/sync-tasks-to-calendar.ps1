# sync-tasks-to-calendar.ps1
# Ensures a timed calendar event exists on the target date for every incomplete task
# due on or before that date. Rolls events forward from previous days.
#
# Slot rules:
#   HIGH   → 60-min blocks from 17:30
#   normal → 30-min blocks, continuing after HIGH
#
# Pre-meeting tasks: tasks matching a fragment in -PreMeetingTasks get a 5-min slot
# ending at the specified meeting time instead of a normal cursor-based slot.
#
# All events are created with normal (public) sensitivity.
# Events are tagged "PlanDay" so they can be found and rolled forward each day.
#
# Same-day replan behaviour (when -Date is today):
#   - Existing PlanDay slots for incomplete tasks are PRESERVED (not recreated).
#   - Slots for tasks that were completed since the last sync are removed.
#   - New slots for tasks that don't yet have one are placed after the current time,
#     skipping over any existing slots.
# Future-date behaviour: same as a same-day replan — existing slots are preserved.
#   - Tasks whose due date was moved to the next day keep their slot on the target date.
#   - Slots for completed tasks are removed. New tasks get a new slot from 09:00.
#
# Usage: .\sync-tasks-to-calendar.ps1 [-Date "2026-05-06"] [-BlockedSlots "09:00-09:15"] [-PreMeetingTasks "Rory:11:00,Peter:16:00"]
# -BlockedSlots:     comma-separated "HH:mm-HH:mm" ranges in local time
# -PreMeetingTasks:  comma-separated "title_fragment:HH:mm" pairs — matching tasks get a 5-min slot ending at HH:mm
# Requires Calendars.ReadWrite — run authenticate-graph.ps1 once if this fails.

param(
    [string]$Date             = (Get-Date).ToString("yyyy-MM-dd"),
    [string]$BlockedSlots     = "",
    [string]$PreMeetingTasks  = "",
    [string]$FillGaps         = ""   # title fragment — matching task fills ALL free work-hour gaps after normal sync
)

$accessToken = & "$PSScriptRoot\get-graph-token.ps1"
if (-not $accessToken) { Write-Error "Token refresh failed — run authenticate-graph.ps1 to re-authenticate."; exit 1 }

$tz = [System.TimeZoneInfo]::Local.Id
$h  = @{
    Authorization  = "Bearer $accessToken"
    "Content-Type" = "application/json"
    Prefer         = "outlook.timezone=`"$tz`""
}

$targetDate = [datetime]::ParseExact($Date, "yyyy-MM-dd", $null)

# --- Parse pre-meeting task overrides (5-min slot ending at specified time) ---
$preMeetingMap = @{}
if ($PreMeetingTasks -and $PreMeetingTasks.Trim()) {
    $PreMeetingTasks -split ',' | Where-Object { $_.Trim() } | ForEach-Object {
        $entry    = $_.Trim()
        $colonIdx = $entry.IndexOf(':')
        if ($colonIdx -gt 0) {
            $fragment = $entry.Substring(0, $colonIdx).Trim()
            $timeStr  = $entry.Substring($colonIdx + 1).Trim()
            try { $preMeetingMap[$fragment] = $targetDate.Date.Add([TimeSpan]::Parse($timeStr)) } catch {}
        }
    }
    if ($preMeetingMap.Count -gt 0) {
        Write-Host "Pre-meeting tasks: $($preMeetingMap.Keys -join ', ')" -ForegroundColor DarkCyan
    }
}

# --- Parse blocked time windows (work calendar meetings to avoid) ---
$blockedWindows = @()
if ($BlockedSlots -and $BlockedSlots.Trim()) {
    $blockedWindows = @($BlockedSlots -split ',' | Where-Object { $_.Trim() } | ForEach-Object {
        $parts = $_.Trim() -split '-'
        if ($parts.Count -eq 2) {
            try {
                [PSCustomObject]@{
                    Start = $targetDate.Date.Add([TimeSpan]::Parse($parts[0]))
                    End   = $targetDate.Date.Add([TimeSpan]::Parse($parts[1]))
                }
            } catch { $null }
        }
    } | Where-Object { $_ -ne $null })
    if ($blockedWindows.Count -gt 0) {
        Write-Host "Blocked slots: $($blockedWindows | ForEach-Object { "$($_.Start.ToString('HH:mm'))-$($_.End.ToString('HH:mm'))" } | Join-String -Separator ', ')" -ForegroundColor DarkCyan
    }
}

function Get-NextFreeSlot {
    param([datetime]$Start, [int]$DurationMins, [array]$Blocked)
    $cursor = $Start
    $guard  = 0
    do {
        $slotEnd = $cursor.AddMinutes($DurationMins)
        $overlap = $Blocked | Where-Object { $cursor -lt $_.End -and $slotEnd -gt $_.Start }
        if ($overlap) {
            $cursor = ($overlap | Sort-Object End | Select-Object -Last 1).End
        } else {
            return $cursor
        }
        $guard++
    } while ($guard -lt 20)
    return $cursor
}

# --- Collect incomplete tasks due on or before target date ---
$lists              = (Invoke-RestMethod "https://graph.microsoft.com/v1.0/me/todo/lists" -Headers $h).value
$tasksToSync        = [System.Collections.Generic.List[object]]::new()
$allIncompleteTasks = [System.Collections.Generic.List[object]]::new()

foreach ($list in $lists) {
    $tasksUrl = "https://graph.microsoft.com/v1.0/me/todo/lists/$($list.id)/tasks?`$filter=status ne 'completed'&`$top=200"
    do {
        $page = Invoke-RestMethod $tasksUrl -Headers $h
        foreach ($t in ($page.value | Where-Object { $_.dueDateTime })) {
            $allIncompleteTasks.Add($t)
            if ([datetime]$t.dueDateTime.dateTime -le $targetDate.Date.AddDays(1).AddSeconds(-1)) {
                $tasksToSync.Add($t)
            }
        }
        $tasksUrl = $page.'@odata.nextLink'
    } while ($tasksUrl)
}

# --- Email/check tasks never get calendar slots — the To Do reminder is enough ---
$noSlotPattern = 'Check email|Check school email|Reply to|Review email|Review uncategorised email'
$skipped = @($tasksToSync | Where-Object { $_.title -match $noSlotPattern })
if ($skipped.Count -gt 0) {
    $skipped | ForEach-Object { Write-Host "Skipped (reminder-only): '$($_.title)'" -ForegroundColor DarkGray }
    $tasksToSync = [System.Collections.Generic.List[object]]@($tasksToSync | Where-Object { $_.title -notmatch $noSlotPattern })
}

if ($tasksToSync.Count -eq 0) {
    Write-Host "No tasks to sync." -ForegroundColor Gray
    exit 0
}

# --- Sort: WORK HIGH → WORK normal → other HIGH → other normal ---
$sorted = $tasksToSync | Sort-Object {
    $isPersonal = [int]($_.title -notmatch '^\[WORK\]')
    $isNormal   = [int]($_.importance -ne "high")
    $isPersonal * 2 + $isNormal
}

# --- Fetch existing PlanDay events in a 60-day window centred on target date ---
$sinceUtc = $targetDate.AddDays(-30).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
$untilUtc = $targetDate.AddDays(30).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
$viewUrl  = "https://graph.microsoft.com/v1.0/me/calendarView" +
            "?startDateTime=$sinceUtc&endDateTime=$untilUtc" +
            "&`$select=id,subject,start,end,categories"

$planEvents = [System.Collections.Generic.List[object]]::new()
$page = Invoke-RestMethod $viewUrl -Headers $h
foreach ($e in ($page.value | Where-Object { $_.categories -contains "PlanDay" })) { $planEvents.Add($e) }
while ($page.'@odata.nextLink') {
    $page = Invoke-RestMethod $page.'@odata.nextLink' -Headers $h
    foreach ($e in ($page.value | Where-Object { $_.categories -contains "PlanDay" })) { $planEvents.Add($e) }
}

$today   = (Get-Date).Date
$isToday = ($targetDate.Date -eq $today)

# --- Load tracked event IDs from previous run ---
$trackingFile = "$PSScriptRoot\..\todo\planday-event-ids.json"
$trackingData = if (Test-Path $trackingFile) {
    try { Get-Content $trackingFile -Raw | ConvertFrom-Json } catch { [PSCustomObject]@{} }
} else { [PSCustomObject]@{} }
$prevIds = if ($null -ne $trackingData.$Date) { @($trackingData.$Date) } else { @() }

$existingToday = @{}   # populated only during a same-day replan

# Preserve existing PlanDay slots for all dates (same-day replan and future alike).
# A task's slot is kept if the task is still incomplete (even if its due date was moved
# to the next day). Only completed tasks have their slots removed.

# Build $existingToday from the calendarView window
foreach ($evt in ($planEvents | Where-Object { ([datetime]$_.start.dateTime).Date -eq $targetDate.Date })) {
    $stillActive = $allIncompleteTasks | Where-Object { $_.title -eq $evt.subject }
    if ($stillActive) {
        $existingToday[$evt.subject] = $evt
    } else {
        # Task was completed — clean up its stale event
        try {
            Invoke-RestMethod -Method DELETE "https://graph.microsoft.com/v1.0/me/events/$($evt.id)" -Headers $h | Out-Null
            Write-Host "Removed:  '$($evt.subject)'  (task completed)" -ForegroundColor DarkGray
        } catch {}
    }
}

# Also GET tracked IDs by ID to catch events not yet indexed in calendarView
foreach ($id in $prevIds) {
    try {
        $evt = Invoke-RestMethod "https://graph.microsoft.com/v1.0/me/events/$id`?`$select=id,subject,start,end" -Headers $h -ErrorAction Stop
        if (-not $existingToday.ContainsKey($evt.subject)) {
            $stillActive = $allIncompleteTasks | Where-Object { $_.title -eq $evt.subject }
            if ($stillActive) { $existingToday[$evt.subject] = $evt }
        }
    } catch {}
}

if ($existingToday.Count -gt 0) {
    Write-Host "Preserving $($existingToday.Count) existing slot(s): $($existingToday.Keys -join ', ')" -ForegroundColor DarkGray
}

# Clean up stale PlanDay events: past events (before today) and future duplicates beyond the target
# date. Events on intermediate days (today through target-1) are left alone — they represent tasks
# already planned for today and should not be rolled forward until that day has passed.
$cleaned = 0
foreach ($evt in ($planEvents | Where-Object { ([datetime]$_.start.dateTime).Date -ne $targetDate.Date })) {
    $evtDate     = ([datetime]$evt.start.dateTime).Date
    $stillActive = $sorted | Where-Object { $_.title -eq $evt.subject }
    if ($stillActive -and ($evtDate -lt $today -or $evtDate -gt $targetDate.Date)) {
        Invoke-RestMethod -Method DELETE "https://graph.microsoft.com/v1.0/me/events/$($evt.id)" -Headers $h | Out-Null
        $arrow = if ($evtDate -lt $targetDate.Date) { "rolled forward" } else { "future duplicate removed" }
        Write-Host "Cleaned:  '$($evt.subject)'  ($($evtDate.ToString('dd MMM')) → $Date) [$arrow]" -ForegroundColor Yellow
        $cleaned++
    }
}

# Tasks already slotted on an intermediate day (today through target-1) are skipped —
# they will roll forward naturally once that day has passed.
$intermediateScheduled = @{}
foreach ($evt in ($planEvents | Where-Object {
    $d = ([datetime]$_.start.dateTime).Date
    $d -ge $today -and $d -lt $targetDate.Date
})) {
    $intermediateScheduled[$evt.subject] = $true
}
if ($intermediateScheduled.Count -gt 0) {
    Write-Host "Already scheduled today (skipping): $($intermediateScheduled.Keys -join ', ')" -ForegroundColor DarkGray
}

# --- Assign time slots and create events ---
$personalCursor = $targetDate.Date.AddHours(17).AddMinutes(30)

# Treat ALL preserved PlanDay slots as blocked windows so new tasks slot around them
foreach ($existEvt in $existingToday.Values) {
    $blockedWindows += [PSCustomObject]@{
        Start = [datetime]$existEvt.start.dateTime
        End   = [datetime]$existEvt.end.dateTime
    }
}

# Work task scan start: today → current time (rounded up), future → 09:00
$workScanStart = $targetDate.Date.AddHours(9)
if ($isToday) {
    $now = Get-Date
    if ($now -gt $workScanStart) {
        $mins          = $now.Hour * 60 + $now.Minute
        $rounded       = [Math]::Ceiling($mins / 5.0) * 5
        $workScanStart = $targetDate.Date.AddMinutes($rounded)
    }
}

$created = 0
$createdIds = [System.Collections.Generic.List[string]]::new()
foreach ($task in $sorted) {
    $title       = $task.title

    # Skip tasks already slotted on an intermediate day
    if ($intermediateScheduled.ContainsKey($title)) { continue }
    # Skip tasks that already have a slot (preserved from previous sync)
    if ($existingToday.ContainsKey($title)) { continue }
    $isHigh      = $task.importance -eq "high"
    $sensitivity = "normal"

    # Check for pre-meeting override (5-min slot ending at meeting time)
    $preMeetingTarget = $null
    foreach ($fragment in $preMeetingMap.Keys) {
        if ($title -like "*$fragment*") { $preMeetingTarget = $preMeetingMap[$fragment]; break }
    }

    if ($preMeetingTarget) {
        $duration = 5
        $start    = $preMeetingTarget.AddMinutes(-5)
        $end      = $preMeetingTarget
    } else {
        $duration       = if ($isHigh) { 60 } else { 30 }
        $start          = Get-NextFreeSlot -Start $personalCursor -DurationMins $duration -Blocked $blockedWindows
        $personalCursor = $start.AddMinutes($duration)
        $end            = $start.AddMinutes($duration)
    }

    $body = @{
        subject     = $title
        start       = @{ dateTime = $start.ToString("yyyy-MM-ddTHH:mm:ss"); timeZone = $tz }
        end         = @{ dateTime = $end.ToString("yyyy-MM-ddTHH:mm:ss");   timeZone = $tz }
        sensitivity = $sensitivity
        showAs      = "busy"
        categories  = @("PlanDay")
    }
    $created_evt = Invoke-RestMethod -Method POST "https://graph.microsoft.com/v1.0/me/events" `
        -Headers $h -Body ($body | ConvertTo-Json -Depth 3)
    if ($created_evt.id) { $createdIds.Add($created_evt.id) }

    $label = if ($isHigh) { "HIGH " } else { "      " }
    Write-Host "Created:  $label'$title'  $($start.ToString('HH:mm'))-$($end.ToString('HH:mm'))" -ForegroundColor Green
    $created++
}

# --- Fill remaining free work-hour gaps with a specified task ---
if ($FillGaps -and $FillGaps.Trim()) {
    $fillTask = $sorted | Where-Object { $_.title -like "*$FillGaps*" } | Select-Object -First 1
    if ($fillTask) {
        $workEnd      = $targetDate.Date.AddHours(17).AddMinutes(30)
        $sortedBlocks = @($blockedWindows | Sort-Object Start) + [PSCustomObject]@{ Start = $workEnd; End = $workEnd }
        $cursor       = $workScanStart

        foreach ($block in $sortedBlocks) {
            if ($cursor -ge $workEnd) { break }
            $gapEnd  = if ($block.Start -le $workEnd) { $block.Start } else { $workEnd }
            $gapMins = ($gapEnd - $cursor).TotalMinutes

            if ($gapMins -ge 20) {
                $body = @{
                    subject     = $fillTask.title
                    start       = @{ dateTime = $cursor.ToString("yyyy-MM-ddTHH:mm:ss"); timeZone = $tz }
                    end         = @{ dateTime = $gapEnd.ToString("yyyy-MM-ddTHH:mm:ss"); timeZone = $tz }
                    sensitivity = "normal"
                    showAs      = "busy"
                    categories  = @("PlanDay")
                }
                $fill_evt = Invoke-RestMethod -Method POST "https://graph.microsoft.com/v1.0/me/events" `
                    -Headers $h -Body ($body | ConvertTo-Json -Depth 3)
                if ($fill_evt.id) { $createdIds.Add($fill_evt.id) }
                Write-Host "Fill gap: '$($fillTask.title)'  $($cursor.ToString('HH:mm'))-$($gapEnd.ToString('HH:mm'))" -ForegroundColor Green
                $created++
            }
            if ($block.End -gt $cursor) { $cursor = $block.End }
        }
    }
}

# Save event IDs: merge preserved existing IDs with newly created ones
$preservedIds = @($existingToday.Values | ForEach-Object { $_.id })
$allIds = $preservedIds + $createdIds.ToArray()
$trackingData | Add-Member -NotePropertyName $Date -NotePropertyValue $allIds -Force
$trackingData | ConvertTo-Json | Set-Content $trackingFile

Write-Host "Done — $created created, $cleaned cleaned up." -ForegroundColor Cyan
