# APCAM - install-task.ps1
#
# Registers (or re-registers) refresh.ps1 as a Windows scheduled task.
#
# Runs as the current user with an interactive token, so no password is stored and
# no elevation is needed. The trade-off is that it only fires while that user is
# logged on; StartWhenAvailable catches a slot missed because the machine was off.
# To run while logged out you must supply credentials yourself in Task Scheduler.
#
# KEEP THIS FILE PURE ASCII - PowerShell 5.1 reads .ps1 as ANSI without a BOM.
param(
    [string]  $TaskName = 'APCAM power metrics refresh',
    [string[]]$At       = @('09:00','21:00'),
    [string]  $Root     = $PSScriptRoot,
    [switch]  $Uninstall
)
$ErrorActionPreference = 'Stop'

if ($Uninstall) {
    if (Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue) {
        Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
        Write-Output "removed '$TaskName'"
    } else { Write-Output "'$TaskName' was not registered" }
    return
}

$script = Join-Path $Root 'refresh.ps1'
if (-not (Test-Path $script)) { throw "missing $script" }

$action = New-ScheduledTaskAction -Execute 'powershell.exe' `
    -Argument ('-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "{0}"' -f $script) `
    -WorkingDirectory $Root

$triggers = foreach ($t in $At) { New-ScheduledTaskTrigger -Daily -At $t }

$settings = New-ScheduledTaskSettingsSet `
    -StartWhenAvailable `
    -AllowStartIfOnBatteries `
    -DontStopIfGoingOnBatteries `
    -ExecutionTimeLimit (New-TimeSpan -Minutes 15) `
    -MultipleInstances IgnoreNew

if (Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue) {
    Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
    Write-Output "replaced existing task"
}

Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $triggers `
    -Settings $settings `
    -Description 'Collects Ollama usage from server logs and rebuilds the APCAM power dashboard.' | Out-Null

Write-Output "registered '$TaskName' at $($At -join ' and ')"
Write-Output "run now:   Start-ScheduledTask -TaskName '$TaskName'"
Write-Output "remove:    .\install-task.ps1 -Uninstall"
