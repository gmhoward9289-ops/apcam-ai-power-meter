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

# $IsWindows does not exist in Windows PowerShell 5.1 (it reads as $null there),
# so test the edition first and only trust it under Core.
$onWindows = ($PSVersionTable.PSEdition -ne 'Core') -or ($IsWindows -eq $true)
if (-not $onWindows) {
    Write-Warning "install-task.ps1 registers a Windows scheduled task, and this is not Windows."
    Write-Warning "Use the shell twin instead - it installs a systemd user timer (Linux) or a"
    Write-Warning "launchd agent (macOS) with the same defaults:"
    Write-Warning "    ./install-schedule.sh            # 09:00 and 21:00"
    Write-Warning "    ./install-schedule.sh -h         # custom times, uninstall"
    exit 1
}

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
