# daily-sync.ps1
# End-to-end wrapper for the plan-day pipeline. Designed to be called by
# Windows Task Scheduler every morning, BEFORE Cowork's plan-day briefing,
# so that Cowork only needs to read state and produce the report.
#
# Steps:
#   1. sync-birthdays.ps1                 (creates 1-week-ahead birthday tasks)
#   2. get-todo.ps1                       (writes today's daily markdown)
#   3. Compute BlockedSlots + PreMeetingTasks from Outlook work calendar
#   4. sync-tasks-to-calendar.ps1         (slots tasks around meetings)
#
# All output is captured to <repo>\logs\daily-sync-yyyy-MM-dd.log so the
# Cowork run (or you) can inspect what happened.
#
# Usage:
#   pwsh -File daily-sync.ps1                  # today
#   pwsh -File daily-sync.ps1 -Date 2026-05-07 # specific date
#   pwsh -File daily-sync.ps1 -WorkCalendar "My Work Calendar"

param(
    [string]$Date          = (Get-Date).ToString("yyyy-MM-dd"),
    [string]$WorkCalendar  = "",   # your work calendar name, if you have one
    [datetime]$WorkDayEnd  = (Get-Date "17:30")   # cut-off for "blocking" meetings
)

$ErrorActionPreference = 'Continue'
$scriptRoot = $PSScriptRoot
$logDir     = Join-Path $scriptRoot "..\logs"
if (-not (Test-Path $logDir)) { New-Item -ItemType Directory -Path $logDir -Force | Out-Null }
$logPath    = Join-Path $logDir "daily-sync-$Date.log"

function Write-Log {
    param([string]$msg, [string]$colour = "Gray")
    $line = "{0} {1}" -f (Get-Date).ToString("HH:mm:ss"), $msg
    $line | Out-File -FilePath $logPath -Append -Encoding utf8
    Write-Host $line -ForegroundColor $colour
}

Write-Log "=== daily-sync starting for $Date ===" "Cyan"

# ------------------------------------------------------------------
# Step 1: sync-birthdays
# ------------------------------------------------------------------
Write-Log "Step 1: sync-birthdays.ps1" "Cyan"
try {
    & "$scriptRoot\sync-birthdays.ps1" *>&1 | Tee-Object -FilePath $logPath -Append
} catch {
    Write-Log "  sync-birthdays FAILED: $($_.Exception.Message)" "Red"
}

# ------------------------------------------------------------------
# Step 2: get-todo
# ------------------------------------------------------------------
Write-Log "Step 2: get-todo.ps1 -Date $Date" "Cyan"
try {
    & "$scriptRoot\get-todo.ps1" -Date $Date *>&1 | Tee-Object -FilePath $logPath -Append
} catch {
    Write-Log "  get-todo FAILED: $($_.Exception.Message)" "Red"
}

# ------------------------------------------------------------------
# Step 3: compute BlockedSlots + PreMeetingTasks from Graph
# ------------------------------------------------------------------
Write-Log "Step 3: computing BlockedSlots from '$WorkCalendar'" "Cyan"

$blockedSlotsArg    = ""
$preMeetingTasksArg = ""

try {
    # Fresh access token (covers Mail / Calendars / Tasks scopes)
    $accessToken = & "$scriptRoot\get-graph-token.ps1"
    $tz = [System.TimeZoneInfo]::Local.Id
    $h  = @{
        Authorization  = "Bearer $accessToken"
        "Content-Type" = "application/json"
        Prefer         = "outlook.timezone=`"$tz`""
    }

    # Resolve the named work calendar
    $cals    = (Invoke-RestMethod "https://graph.microsoft.com/v1.0/me/calendars" -Headers $h).value
    $workCal = $cals | Where-Object { $_.name -eq $WorkCalendar } | Select-Object -First 1
    if (-not $workCal) {
        Write-Log "  WARN: calendar '$WorkCalendar' not found — proceeding with empty BlockedSlots" "Yellow"
    } else {
        $targetDate = [datetime]::ParseExact($Date, "yyyy-MM-dd", $null)
        $start = $targetDate.Date.ToString("yyyy-MM-ddTHH:mm:ss")
        $end   = $targetDate.Date.AddDays(1).AddSeconds(-1).ToString("yyyy-MM-ddTHH:mm:ss")
        $url   = "https://graph.microsoft.com/v1.0/me/calendars/$($workCal.id)/calendarView?startDateTime=$start&endDateTime=$end&`$top=200&`$orderby=start/dateTime"
        $events = (Invoke-RestMethod $url -Headers $h).value

        $cutoff = $targetDate.Date.Add($WorkDayEnd.TimeOfDay)
        $busy = $events | Where-Object {
            -not $_.isAllDay -and
            ($_.showAs -eq "busy" -or $_.showAs -eq "tentative") -and
            ([datetime]$_.start.dateTime) -lt $cutoff
        } | Sort-Object { [datetime]$_.start.dateTime }

        $slots = $busy | ForEach-Object {
            $s = [datetime]$_.start.dateTime
            $e = [datetime]$_.end.dateTime
            "{0:HH:mm}-{1:HH:mm}" -f $s, $e
        }
        $blockedSlotsArg = ($slots -join ",")
        Write-Log "  BlockedSlots: $blockedSlotsArg" "Green"

        # ----------------------------------------------------------------
        # PreMeetingTasks: tasks containing "in one-to-one" matched to a
        # weekly catchup in today's work calendar by name initials.
        # ----------------------------------------------------------------
        $lists = (Invoke-RestMethod "https://graph.microsoft.com/v1.0/me/todo/lists" -Headers $h).value
        $oneToOneTasks = foreach ($list in $lists) {
            $tasks = (Invoke-RestMethod "https://graph.microsoft.com/v1.0/me/todo/lists/$($list.id)/tasks" -Headers $h).value
            $tasks | Where-Object {
                $_.status -ne "completed" -and
                $_.dueDateTime -and
                [datetime]$_.dueDateTime.dateTime -le $targetDate.Date.AddDays(1).AddSeconds(-1) -and
                $_.title -match "in one-to-one"
            }
        }

        $pmEntries = foreach ($t in $oneToOneTasks) {
            # Take the first capitalised name in the title, e.g. "Talk to Buchi in one-to-one ..." -> "Buchi"
            $nameMatch = [regex]::Match($t.title, '\b([A-Z][a-z]+)\b')
            if (-not $nameMatch.Success) { continue }
            $name = $nameMatch.Groups[1].Value

            $catchup = $busy | Where-Object {
                $_.subject -match $name -or
                $_.subject -match (($name.Substring(0,1)) + ".*Catchup")
            } | Select-Object -First 1
            if ($catchup) {
                $hhmm     = ([datetime]$catchup.start.dateTime).ToString("HH:mm")
                # Use a distinctive fragment (skip first word "Talk") to avoid colliding with other tasks
                $fragment = ($t.title -split '\s+', 4)[2..3] -join ' '
                if (-not $fragment) { $fragment = $name }
                "{0}:{1}" -f $fragment, $hhmm
            }
        }
        if ($pmEntries) {
            $preMeetingTasksArg = ($pmEntries -join ",")
            Write-Log "  PreMeetingTasks: $preMeetingTasksArg" "Green"
        }
    }
} catch {
    Write-Log "  BlockedSlots compute FAILED: $($_.Exception.Message) — proceeding with empty values" "Red"
}

# ------------------------------------------------------------------
# Step 4: sync-tasks-to-calendar
# ------------------------------------------------------------------
Write-Log "Step 4: sync-tasks-to-calendar.ps1" "Cyan"
$syncArgs = @("-File", "$scriptRoot\sync-tasks-to-calendar.ps1", "-Date", $Date)
if ($blockedSlotsArg)    { $syncArgs += @("-BlockedSlots", $blockedSlotsArg) }
if ($preMeetingTasksArg) { $syncArgs += @("-PreMeetingTasks", $preMeetingTasksArg) }
try {
    & pwsh @syncArgs *>&1 | Tee-Object -FilePath $logPath -Append
} catch {
    Write-Log "  sync-tasks-to-calendar FAILED: $($_.Exception.Message)" "Red"
}

Write-Log "=== daily-sync finished for $Date ===" "Cyan"
