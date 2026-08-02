# APCAM - refresh.ps1
#
# Unattended refresh: collect the latest usage, then rebuild the page.
# Registered as a scheduled task by install-task.ps1. Appends to refresh.log.
#
# KEEP THIS FILE PURE ASCII - PowerShell 5.1 reads .ps1 as ANSI without a BOM.
param(
    [string]$Root     = $PSScriptRoot,
    [string]$LogFile  = "$PSScriptRoot\refresh.log",
    [int]   $MaxLogKB = 512,
    [switch]$SkipPublish   # rebuild the local page only, leave the artifact alone
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
    # Deploy the built page to the tunnel-only portal vhost on swamplink:
    # http://127.0.0.1:8103/apcam/ (over the standing tunnel). This URL is what
    # the portal links to; the Claude artifact below is a secondary snapshot.
    # Same privacy gate as publishing - never ship a non-anonymised dataset.
    $page = Join-Path $Root 'dashboard.html'
    $d = $null
    try { $d = Get-Content (Join-Path $Root 'dataset.json') -Raw | ConvertFrom-Json } catch { }
    if ($d -and $d.anonymised -eq $false) {
        Write-Log "  [deploy] dataset is NOT anonymised - refusing to deploy"
        $failed = $true
    } else {
        # build.ps1 emits a fragment for the artifact wrapper; served raw it
        # would render in quirks mode, so prepend a proper prologue for Caddy.
        $tmp = Join-Path $env:TEMP 'apcam-deploy.html'
        $html = Get-Content $page -Raw -Encoding UTF8
        $prologue = "<!doctype html>`n<html lang=`"en`"><head><meta charset=`"utf-8`">`n" +
            "<meta name=`"viewport`" content=`"width=device-width, initial-scale=1`">`n" +
            "<meta name=`"robots`" content=`"noindex, nofollow`">`n"
        [System.IO.File]::WriteAllText($tmp, $prologue + $html,
            (New-Object System.Text.UTF8Encoding($false)))
        ssh -o BatchMode=yes swamplink "mkdir -p /var/www/swamplink/portal/apcam" 2>&1 | Out-Null
        scp -q $tmp "swamplink:/var/www/swamplink/portal/apcam/index.html"
        if ($LASTEXITCODE -ne 0) {
            Write-Log "  [deploy] scp to swamplink failed with exit $LASTEXITCODE"
            $failed = $true
        } else {
            Write-Log "  [deploy] pushed to swamplink portal/apcam/"
        }
        Remove-Item $tmp -ErrorAction SilentlyContinue
    }
}

if (-not $failed -and -not $SkipPublish) {
    # Republish the artifact. Rebuilding dashboard.html locally used to be the whole job,
    # which meant the published page only moved when someone happened to be in a session.
    $page   = Join-Path $Root 'dashboard.html'
    $prompt = Join-Path $Root 'publish-prompt.txt'
    $d      = $null
    try { $d = Get-Content (Join-Path $Root 'dataset.json') -Raw | ConvertFrom-Json } catch { }

    if ($d -and $d.anonymised -eq $false) {
        # collect.ps1 -KeepRawClients leaves real client addresses in the dataset. Never
        # push that to a hosted page, even a private one.
        Write-Log "  [publish] dataset is NOT anonymised - refusing to publish"
        $failed = $true
    } elseif (-not (Test-Path $prompt)) {
        Write-Log "  [publish] MISSING $prompt"
        $failed = $true
    } else {
        # See PairingLog\refresh.ps1 for why the entrypoint line is load-bearing: the
        # Artifact tool is gated on it, and claude exits 0 whether or not it published.
        #
        # The prompt is NOT piped in. Under the scheduled task's console the emoji
        # favicon did not survive piping even with $OutputEncoding set (2026-07-31,
        # ENCODING_LOST), so the pipe carries only this ASCII bootstrap and claude
        # reads the real prompt from the UTF-8 file itself, which cannot be mangled.
        $env:CLAUDE_CODE_ENTRYPOINT = 'claude-desktop'
        $boot = 'Read the file {0} and follow its instructions exactly.' -f $prompt

        Push-Location $Root
        $out = $boot | & claude -p --allowedTools 'Artifact,Read'
        $rc  = $LASTEXITCODE
        Pop-Location
        foreach ($l in $out) { Write-Log "  [publish] $l" }

        if ($rc -ne 0 -or ($out -join "`n") -notmatch 'PUBLISHED_OK') {
            Write-Log "  [publish] claude exit $rc, no PUBLISHED_OK in reply - treating as failure"
            $failed = $true
        }
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
