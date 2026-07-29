# APCAM - refresh.ps1
#
# Unattended refresh: collect the latest usage, then rebuild the page.
# Registered as a scheduled task by install-task.ps1. Appends to refresh.log.
#
# KEEP THIS FILE PURE ASCII - PowerShell 5.1 reads .ps1 as ANSI without a BOM.
param(
    [string]$Root     = $PSScriptRoot,
    [string]$LogFile  = "$PSScriptRoot\refresh.log",
    [int]   $MaxLogKB = 512
)
$ErrorActionPreference = 'Continue'

if ((Test-Path $LogFile) -and ((Get-Item $LogFile).Length -gt $MaxLogKB * 1KB)) {
    Move-Item $LogFile "$LogFile.old" -Force
}

function Write-Log([string]$msg) {
    $line = "{0}  {1}" -f (Get-Date).ToString('yyyy-MM-dd HH:mm:ss'), $msg
    Add-Content -Path $LogFile -Value $line -Encoding utf8
    Write-Output $line
}

Write-Log "=== refresh start ==="
$failed = $false

foreach ($step in @('collect','build')) {
    $script = Join-Path $Root "$step.ps1"
    if (-not (Test-Path $script)) { Write-Log "MISSING $script"; $failed = $true; break }
    try {
        $out = & $script 2>&1
        foreach ($l in $out) { Write-Log ("  [{0}] {1}" -f $step, $l) }
    } catch {
        Write-Log "  [$step] THREW: $($_.Exception.Message)"; $failed = $true; break
    }
}

if (-not $failed) {
    try {
        $ds = Join-Path $Root 'dataset.json'
        $d  = Get-Content $ds -Raw | ConvertFrom-Json
        if ($d.events) {
            $sec = ($d.events | Measure-Object -Property dur -Sum).Sum
            $w   = $d.machine.gpuActiveW + $d.machine.systemWatts
            Write-Log ("  summary: {0} events, {1:N0}s active, {2:N1} Wh at {3:N0} W" -f `
                $d.events.Count, $sec, ($sec * $w / 3600), $w)
        } else {
            Write-Log "  summary: no events recorded yet"
        }
    } catch { Write-Log "  summary unavailable: $($_.Exception.Message)" }
}

Write-Log ("=== refresh {0} ===" -f $(if ($failed) { "FAILED" } else { "ok" }))
if ($failed) { exit 1 }
