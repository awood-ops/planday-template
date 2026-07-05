# register-daily-sync.ps1
# Registers (or updates) a Windows Scheduled Task that runs daily-sync.ps1
# every morning at 07:55 local time, before Cowork's 08:00 plan-day.
#
# Run this ONCE: right-click → Run with PowerShell, or:
#     pwsh -File register-daily-sync.ps1
#
# Re-running it is safe — it will overwrite the existing task definition.
# To remove: Unregister-ScheduledTask -TaskName 'PlanDay - Daily Sync' -Confirm:$false

param(
    [string]$TaskName = "PlanDay - Daily Sync",
    [string]$RunTime  = "07:55"
)

$scriptRoot  = $PSScriptRoot
$dailySync   = Join-Path $scriptRoot "daily-sync.ps1"

if (-not (Test-Path $dailySync)) {
    Write-Error "daily-sync.ps1 not found at $dailySync"
    exit 1
}

# Use pwsh (PowerShell 7) if installed; fall back to Windows PowerShell.
$pwshPath = (Get-Command pwsh -ErrorAction SilentlyContinue).Source
if (-not $pwshPath) {
    $pwshPath = (Get-Command powershell -ErrorAction SilentlyContinue).Source
}
if (-not $pwshPath) {
    Write-Error "Neither pwsh nor powershell.exe found on PATH."
    exit 1
}

$action = New-ScheduledTaskAction `
    -Execute $pwshPath `
    -Argument "-NoProfile -ExecutionPolicy Bypass -File `"$dailySync`""

$trigger = New-ScheduledTaskTrigger -Daily -At $RunTime

# Run as the current user, even when not logged in (uses stored credentials).
# We use S4U so no password is required, but the task only fires when this
# user account is logged in / unlocked. That's fine — tasks need the user's
# DPAPI-protected refresh token anyway.
$principal = New-ScheduledTaskPrincipal `
    -UserId  ([System.Security.Principal.WindowsIdentity]::GetCurrent().Name) `
    -LogonType Interactive `
    -RunLevel Limited

$settings = New-ScheduledTaskSettingsSet `
    -AllowStartIfOnBatteries `
    -DontStopIfGoingOnBatteries `
    -StartWhenAvailable `
    -ExecutionTimeLimit (New-TimeSpan -Minutes 15)

# Replace existing registration if present.
if (Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue) {
    Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
}

Register-ScheduledTask `
    -TaskName  $TaskName `
    -Action    $action `
    -Trigger   $trigger `
    -Principal $principal `
    -Settings  $settings `
    -Description "Runs the plan-day PowerShell pipeline (sync-birthdays, get-todo, sync-tasks-to-calendar) so Cowork's 08:00 briefing has fresh state to read."

Write-Host ""
Write-Host "Registered '$TaskName' to run daily at $RunTime." -ForegroundColor Green
Write-Host "Logs: $((Resolve-Path "$scriptRoot\..").Path)\logs\daily-sync-yyyy-MM-dd.log"
Write-Host ""
Write-Host "To trigger it now (test):"
Write-Host "    Start-ScheduledTask -TaskName '$TaskName'"
