# APCAM - collect.ps1
#
# Parses Ollama's server logs into (a) inference requests and (b) observed
# generation-rate samples, attributing each to a model via the runner's load-event
# timeline. Joins the model inventory and the measured power envelope from
# machine.json, and emits dataset.json for the dashboard.
#
# Client addresses are classified and hashed on the way in, never stored raw.
#
# Two things this deliberately does NOT do, because the logs cannot support them:
#   * pair a generation rate to a specific HTTP request. llama-server task ids are
#     non-contiguous and do not map 1:1 onto Ollama requests, so rates are reported
#     per model, not per request. An ordered zip of the two is wrong.
#   * distinguish tags that share a weights blob (e.g. a model and a long-context
#     variant of it). They are indistinguishable in the logs and shown as one entity.
#
# The persistent store matters: Ollama rotates server*.log on every app restart and
# keeps only a handful, so anything not captured here is lost permanently.
#
# KEEP THIS FILE PURE ASCII - PowerShell 5.1 reads .ps1 as ANSI without a BOM, so
# any non-ASCII literal is silently corrupted at parse time. That already broke a
# microsecond regex once; it now uses a \u escape.
param(
    [string]$OutFile     = (Join-Path $PSScriptRoot 'dataset.json'),
    [string]$HistoryFile = (Join-Path $PSScriptRoot 'history.json'),
    [string]$MachineFile = (Join-Path $PSScriptRoot 'machine.json'),
    [string]$LogDir      = '',
    [string]$ModelDir    = '',
    [string]$Endpoint    = 'http://localhost:11434',
    [switch]$KeepRawClients   # opt out of anonymisation for local-only debugging
)
$ErrorActionPreference = 'Continue'

function Confirm-ParentDir([string]$path) {
    $d = Split-Path -Parent $path
    if ($d -and -not (Test-Path $d)) { New-Item -ItemType Directory -Force -Path $d | Out-Null }
}
Confirm-ParentDir $OutFile
Confirm-ParentDir $HistoryFile

# ---------------- platform defaults ----------------
# $IsWindows/$IsLinux/$IsMacOS do not exist in Windows PowerShell 5.1 (they read
# as $null there), so test the edition first and only trust them under Core.
$onWindows = ($PSVersionTable.PSEdition -ne 'Core') -or ($IsWindows -eq $true)
$onLinux   = ($IsLinux -eq $true)

$LogDirGiven = [bool]$LogDir
if (-not $LogDir) {
    if ($onWindows) {
        # Windows desktop app.
        $LogDir = Join-Path $env:LOCALAPPDATA 'Ollama'
    } else {
        # The macOS app and manual `ollama serve 2>...` runs log here. The Linux
        # systemd service logs to journald instead - handled after the file scan.
        $LogDir = Join-Path $HOME '.ollama/logs'
    }
}
if (-not $ModelDir) {
    $ModelDir = if ($env:OLLAMA_MODELS) { $env:OLLAMA_MODELS }
                elseif ($onWindows)     { Join-Path $env:USERPROFILE '.ollama\models' }
                else                    { Join-Path $HOME '.ollama/models' }
}

# ---------------- machine envelope ----------------
if (-not (Test-Path $MachineFile)) {
    Write-Error "missing $MachineFile - run .\calibrate.ps1 first (it measures this machine's power envelope)."
    return
}
$machine = Get-Content $MachineFile -Raw | ConvertFrom-Json
if ($null -eq $machine.gpuActiveW -or $null -eq $machine.gpuIdleW) {
    Write-Error "$MachineFile has no power figures. Re-run calibrate.ps1, or fill in gpuIdleW and gpuActiveW by hand."
    return
}

function Parse-GoDuration([string]$s) {
    $s = $s.Trim()
    if ($s -eq '0s' -or $s -eq '') { return 0.0 }
    if ($s -match '^(?:(\d+)h)?(?:(\d+)m)?(?:([\d.]+)s)$') {
        $t = 0.0
        if ($Matches[1]) { $t += [double]$Matches[1] * 3600 }
        if ($Matches[2]) { $t += [double]$Matches[2] * 60 }
        if ($Matches[3]) { $t += [double]$Matches[3] }
        return $t
    }
    if ($s -match '^([\d.]+)ms$')             { return [double]$Matches[1] / 1e3 }
    if ($s -match '^([\d.]+)(?:\u00B5s|us)$') { return [double]$Matches[1] / 1e6 }
    if ($s -match '^([\d.]+)ns$')             { return [double]$Matches[1] / 1e9 }
    if ($s -match '^([\d.]+)s$')              { return [double]$Matches[1] }
    return 0.0
}

# Ollama holds the current server.log open, so read with a permissive share mode.
function Read-SharedLines([string]$path) {
    $lines = New-Object System.Collections.ArrayList
    try {
        $fs = New-Object System.IO.FileStream($path, [System.IO.FileMode]::Open,
                  [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
        $sr = New-Object System.IO.StreamReader($fs)
        while ($null -ne ($l = $sr.ReadLine())) { [void]$lines.Add($l) }
        $sr.Close(); $fs.Close()
    } catch { Write-Warning "could not read $path : $($_.Exception.Message)" }
    return $lines
}

# ---------------- client anonymisation ----------------
# The dashboard only needs to distinguish "me", "another box on my network" and
# "something off-network". The raw address adds nothing and is worth not storing.
$sha = [System.Security.Cryptography.SHA256]::Create()
function Get-ClientLabel([string]$addr) {
    if ($KeepRawClients) { return $addr }
    $a = $addr.Trim().ToLowerInvariant()
    if ($a -in @('::1','127.0.0.1','localhost') -or $a.StartsWith('127.')) { return 'localhost' }
    $isPrivate =
        $a -match '^10\.' -or
        $a -match '^192\.168\.' -or
        $a -match '^172\.(1[6-9]|2\d|3[01])\.' -or
        $a -match '^169\.254\.' -or
        $a -match '^100\.(6[4-9]|[7-9]\d|1[01]\d|12[0-7])\.' -or
        $a.StartsWith('fe80:') -or $a.StartsWith('fc') -or $a.StartsWith('fd')
    $h = [BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($a))).Replace('-','').ToLower()
    return ($(if ($isPrivate) { 'lan-' } else { 'external-' }) + $h.Substring(0,4))
}

# ---------------- digest -> entity name, from the manifests ----------------
$digestEntity = @{}
$digestTags   = @{}
$manifestRoot = Join-Path $ModelDir 'manifests'
if (Test-Path $manifestRoot) {
    foreach ($f in (Get-ChildItem -Path $manifestRoot -Recurse -File)) {
        try {
            $m    = Get-Content $f.FullName -Raw | ConvertFrom-Json
            $rel  = $f.FullName.Substring($manifestRoot.Length).TrimStart('\','/')
            $segs = $rel -split '[\\/]'
            $full = "$($segs[-2]):$($segs[-1])"
            foreach ($layer in $m.layers) {
                if ($layer.mediaType -like '*image.model*') {
                    $h = ($layer.digest -replace '^sha256:', '').Substring(0,12)
                    if (-not $digestTags.ContainsKey($h)) { $digestTags[$h] = @() }
                    $digestTags[$h] += $full
                }
            }
        } catch { }
    }
} else {
    Write-Warning "no manifests at $manifestRoot - models will show as unresolved digests"
}
foreach ($h in $digestTags.Keys) {
    $tags = @($digestTags[$h] | Sort-Object -Unique)
    $digestEntity[$h] = if ($tags.Count -eq 1) { $tags[0] }
                        else { ($tags[0] -split ':')[0] + " (shared: " + ($tags -join ', ') + ")" }
}

# Which tags actually share a weights file. This has to come from the manifests:
# reported tag sizes include the params/template layers, so two variants of one
# model differ by a few bytes and never compare equal.
$sharedBlobs = @()
$tagDigest   = @{}
foreach ($h in $digestTags.Keys) {
    $tags = @($digestTags[$h] | Sort-Object -Unique)
    foreach ($t in $tags) { $tagDigest[$t] = $h }
    if ($tags.Count -gt 1) {
        $sharedBlobs += [pscustomobject]@{ digest = $h; tags = $tags; tagCount = $tags.Count }
    }
}

# ---------------- scan server logs ----------------
$ginRe = '^\[GIN\]\s+(\d{4}/\d{2}/\d{2})\s+-\s+(\d{2}:\d{2}:\d{2})\s+\|\s*(\d+)\s*\|\s*([^|]+?)\s*\|\s*([^|]+?)\s*\|\s*(\w+)\s+"([^"]+)"'
$inferencePaths = @('/api/chat','/api/generate','/api/embed','/api/embeddings',
                    '/v1/chat/completions','/v1/completions','/v1/messages','/v1/embeddings')

$loads   = New-Object System.Collections.ArrayList
$reqs    = New-Object System.Collections.ArrayList
$samples = New-Object System.Collections.ArrayList
$logFiles = @(Get-ChildItem -Path $LogDir -Filter 'server*.log' -File -EA SilentlyContinue | Sort-Object LastWriteTime)

# The Linux service install logs to journald, not files. If default discovery
# found nothing, dump the ollama unit (system first, then user) to a temp file
# shaped like a rotated log, parse that, and delete it after the scan.
$journalDump = $null
if (-not $logFiles.Count -and $onLinux -and -not $LogDirGiven -and
    (Get-Command journalctl -ErrorAction SilentlyContinue)) {
    $jLines = @(& journalctl -u ollama --no-pager -o cat 2>$null | Where-Object { $_ })
    if (-not $jLines.Count) {
        $jLines = @(& journalctl --user-unit ollama --no-pager -o cat 2>$null | Where-Object { $_ })
    }
    if ($jLines.Count) {
        $journalDump = Join-Path ([System.IO.Path]::GetTempPath()) ('apcam-journal-' + [System.Guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Force -Path $journalDump | Out-Null
        [System.IO.File]::WriteAllLines((Join-Path $journalDump 'server-journald.log'), [string[]]$jLines)
        $logFiles = @(Get-ChildItem -Path $journalDump -Filter 'server*.log' -File)
        Write-Output "no server*.log in $LogDir - parsing the ollama journald unit instead ($($jLines.Count) lines)"
    }
}

if (-not $logFiles.Count) {
    Write-Warning "no server*.log found in $LogDir - pass -LogDir if Ollama logs elsewhere."
}

try {
foreach ($lf in $logFiles) {
    $lineTs   = $null
    $lastLoad = $null
    $taskSeen = @{}

    foreach ($line in (Read-SharedLines $lf.FullName)) {

        if ($line -match '^time=(\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2})') {
            try { $lineTs = [datetime]::ParseExact($Matches[1], 'yyyy-MM-ddTHH:mm:ss', $null) } catch { }
        }

        foreach ($mm in [regex]::Matches($line, "load_model: loading model '.*?sha256-([0-9a-f]{12})")) {
            $rec = [pscustomobject]@{ ts = $lineTs; digest = $mm.Groups[1].Value; ctx = $null }
            [void]$loads.Add($rec); $lastLoad = $rec
        }
        foreach ($mm in [regex]::Matches($line, 'llama_context: n_ctx\s+=\s+(\d+)')) {
            if ($lastLoad -and -not $lastLoad.ctx) { $lastLoad.ctx = [int]$mm.Groups[1].Value }
        }

        foreach ($mm in [regex]::Matches($line, 'task (\d+) \| n_decoded\s*=\s*(\d+), tg\s*=\s*([\d.]+) t/s')) {
            $tid = $mm.Groups[1].Value
            $gen = [int]$mm.Groups[2].Value
            $tps = [double]$mm.Groups[3].Value
            $key = "$($lf.Name)|$tid"
            if ($taskSeen.ContainsKey($key)) {
                if ($gen -gt $taskSeen[$key].gen) { $taskSeen[$key].gen = $gen; $taskSeen[$key].tps = $tps }
            } else {
                $rec = [pscustomobject]@{ ts = $lineTs; tid = [int]$tid; gen = $gen; tps = $tps }
                $taskSeen[$key] = $rec; [void]$samples.Add($rec)
            }
        }
        foreach ($mm in [regex]::Matches($line, 'task \d+ \| new prompt,[^|]*?task\.n_tokens\s*=\s*(\d+)')) {
            [void]$samples.Add([pscustomobject]@{ ts = $lineTs; tid = -1; gen = 0; tps = 0.0
                                                 prompt = [int]$mm.Groups[1].Value })
        }

        if ($line.StartsWith('[GIN]') -and $line -match $ginRe) {
            $path = $Matches[7]
            if ($inferencePaths -notcontains $path) { continue }
            $dur = Parse-GoDuration $Matches[4]
            try {
                $endTs = [datetime]::ParseExact(($Matches[1] + ' ' + $Matches[2]),
                                               'yyyy/MM/dd HH:mm:ss', $null)
            } catch { continue }
            [void]$reqs.Add([pscustomobject]@{
                endTs  = $endTs
                start  = $endTs.AddSeconds(-$dur)
                dur    = [math]::Round($dur,3)
                status = [int]$Matches[3]
                client = Get-ClientLabel $Matches[5]
                path   = $path
            })
        }
    }
}
} finally {
    if ($journalDump) { Remove-Item -Path $journalDump -Recurse -Force -EA SilentlyContinue }
}

# ---------------- attribute by load timeline ----------------
$sortedLoads = @($loads | Where-Object { $_.ts } | Sort-Object ts)
function Resolve-Model([datetime]$at) {
    $hit = $null
    foreach ($l in $sortedLoads) { if ($l.ts -le $at) { $hit = $l } else { break } }
    if (-not $hit) { return @{ name = $null; ctx = $null } }
    $name = if ($digestEntity.ContainsKey($hit.digest)) { $digestEntity[$hit.digest] }
            else { "removed:$($hit.digest)" }
    return @{ name = $name; ctx = $hit.ctx }
}

$events = New-Object System.Collections.ArrayList
foreach ($r in ($reqs | Sort-Object endTs)) {
    # a load triggered *by* this request still precedes its completion
    $m = Resolve-Model $r.endTs
    [void]$events.Add([pscustomobject]@{
        start = $r.start.ToString('yyyy-MM-ddTHH:mm:ss'); dur = $r.dur; status = $r.status
        client = $r.client; path = $r.path; model = $m.name; ctx = $m.ctx
    })
}

$rates = New-Object System.Collections.ArrayList
foreach ($s in ($samples | Where-Object { $_.tps -gt 0 -and $_.ts } | Sort-Object ts)) {
    $m = Resolve-Model $s.ts
    [void]$rates.Add([pscustomobject]@{
        ts = $s.ts.ToString('yyyy-MM-ddTHH:mm:ss'); tps = [math]::Round($s.tps,2)
        gen = $s.gen; model = $m.name; ctx = $m.ctx
    })
}
$promptTotal = (($samples | Where-Object { $_.PSObject.Properties.Name -contains 'prompt' }) |
                Measure-Object -Property prompt -Sum).Sum
if (-not $promptTotal) { $promptTotal = 0 }

# ---------------- merge into persistent history ----------------
# pwsh 7's ConvertFrom-Json revives ISO date strings as [datetime] (5.1 keeps
# them as strings). Left alone, a revived start/ts stringifies culture-style, so
# its dedupe key never matches the freshly parsed entry and every run appends a
# full duplicate. Pin them back to the ISO string form; on 5.1 this is a no-op.
function Format-HistTs($v) {
    if ($v -is [datetime]) { return $v.ToString('yyyy-MM-ddTHH:mm:ss') }
    return "$v"
}
$hist = @{ events = @{}; rates = @{} }
if (Test-Path $HistoryFile) {
    try {
        $prev = Get-Content $HistoryFile -Raw | ConvertFrom-Json
        foreach ($e in $prev.events) {
            $e.start = Format-HistTs $e.start
            $hist.events["$($e.start)|$($e.path)|$($e.client)|$($e.dur)"] = $e
        }
        foreach ($r in $prev.rates) {
            $r.ts = Format-HistTs $r.ts
            $hist.rates["$($r.ts)|$($r.tps)|$($r.gen)"] = $r
        }
    } catch { Write-Warning "could not read history, starting fresh: $_" }
}
$beforeE = $hist.events.Count; $beforeR = $hist.rates.Count
foreach ($e in $events) { $hist.events["$($e.start)|$($e.path)|$($e.client)|$($e.dur)"] = $e }
foreach ($r in $rates)  { $hist.rates["$($r.ts)|$($r.tps)|$($r.gen)"] = $r }

$allEvents = @($hist.events.Values | Sort-Object { [datetime]$_.start })
$allRates  = @($hist.rates.Values  | Sort-Object { [datetime]$_.ts })
[System.IO.File]::WriteAllText($HistoryFile,
    ([pscustomobject]@{ events = $allEvents; rates = $allRates } | ConvertTo-Json -Depth 6 -Compress),
    [System.Text.UTF8Encoding]::new($false))

# ---------------- model inventory ----------------
$models = @(); $ollamaUp = $false; $loaded = @()
try {
    $tags = Invoke-RestMethod -Uri "$Endpoint/api/tags" -TimeoutSec 5
    $ollamaUp = $true
    $models = @($tags.models | ForEach-Object {
        [pscustomobject]@{
            name=$_.name; sizeBytes=$_.size; params=$_.details.parameter_size
            quant=$_.details.quantization_level; family=$_.details.family; caps=@($_.capabilities)
        }
    })
} catch { }
try {
    $ps = Invoke-RestMethod -Uri "$Endpoint/api/ps" -TimeoutSec 5
    $loaded = @($ps.models | ForEach-Object { [pscustomobject]@{ name=$_.name; vram=$_.size_vram } })
} catch { }

$diskBytes = 0
$blobDir = Join-Path $ModelDir 'blobs'
if (Test-Path $blobDir) {
    $diskBytes = [long](((Get-ChildItem $blobDir -File -Recurse -EA SilentlyContinue) |
                         Measure-Object -Property Length -Sum).Sum)
}

$gpuNow = $null
$gpuIdx = 0
if ($machine.PSObject.Properties.Name -contains 'gpuIndex' -and $null -ne $machine.gpuIndex) {
    $gpuIdx = [int]$machine.gpuIndex
}
# Live snapshot exists only for the nvidia path ('unknown' covers machine.json
# files from before gpuVendor and degrades to null exactly as it always did).
$gpuVendorNow = ''
if ($machine.PSObject.Properties.Name -contains 'gpuVendor' -and $machine.gpuVendor) {
    $gpuVendorNow = "$($machine.gpuVendor)"
}
if ($gpuVendorNow -in @('', 'nvidia', 'unknown')) {
try {
    $raw = & nvidia-smi -i $gpuIdx --query-gpu=power.draw,utilization.gpu,memory.used,memory.total,temperature.gpu `
                        --format=csv,noheader,nounits 2>$null
    if ($raw) {
        if ($raw -is [array]) { $raw = $raw[0] }
        $p = ($raw -split ',').Trim()
        $gpuNow = [pscustomobject]@{ w=[double]$p[0]; util=[double]$p[1]
                                     vramUsed=[double]$p[2]; vramTotal=[double]$p[3]; temp=[double]$p[4] }
    }
} catch { }
}

$out = [pscustomobject]@{
    schema      = 1
    generatedAt = (Get-Date).ToString('yyyy-MM-ddTHH:mm:ss')
    anonymised  = (-not $KeepRawClients)
    ollamaUp    = $ollamaUp
    machine     = $machine
    models      = $models
    loadedNow   = $loaded
    diskBytes   = $diskBytes
    sharedBlobs = $sharedBlobs
    tagDigest   = $tagDigest
    promptTokens= [int]$promptTotal
    gpuNow      = $gpuNow
    events      = $allEvents
    rates       = $allRates
}
[System.IO.File]::WriteAllText($OutFile,
    ($out | ConvertTo-Json -Depth 8 -Compress), [System.Text.UTF8Encoding]::new($false))

# ---------------- summary ----------------
Write-Output "wrote $OutFile"
Write-Output "events: $($allEvents.Count) (+$($allEvents.Count - $beforeE))   rate samples: $($allRates.Count) (+$($allRates.Count - $beforeR))"
Write-Output "logs scanned: $($logFiles.Count)   loads seen: $($sortedLoads.Count)   tags: $($models.Count)   disk: $([math]::Round($diskBytes/1GB,2)) GB"

if (-not $allEvents.Count) {
    Write-Warning "no inference requests found. Either none have run yet, or Ollama's log format changed - check $LogDir\server.log for [GIN] lines."
    Write-Output "next: .\build.ps1"
    return
}

$d = $allEvents | Measure-Object -Property dur -Sum -Average -Maximum
$w = $machine.gpuActiveW + $machine.systemWatts
Write-Output ("active: {0:N1}s  avg {1:N1}s  max {2:N1}s   prompt tokens: {3:N0}" -f $d.Sum,$d.Average,$d.Maximum,$promptTotal)
Write-Output ("energy at {0:N0} W: {1:N1} Wh" -f $w, ($d.Sum * $w / 3600))
Write-Output "--- energy by model ---"
$allEvents | Group-Object model | Sort-Object { ($_.Group | Measure-Object dur -Sum).Sum } -Descending | ForEach-Object {
    $s = ($_.Group | Measure-Object -Property dur -Sum).Sum
    Write-Output ("  {0,-46} n={1,-3} {2,8:N1}s  {3,4:N0}%" -f $_.Name,$_.Count,$s,($s/$d.Sum*100))
}
if ($allRates.Count) {
    Write-Output "--- observed generation rate by model ---"
    $allRates | Group-Object model | ForEach-Object {
        $t = $_.Group | Measure-Object -Property tps -Average -Minimum -Maximum
        Write-Output ("  {0,-46} n={1,-3} avg {2,6:N1}  range {3:N1}-{4:N1} tok/s" -f `
            $_.Name,$_.Count,$t.Average,$t.Minimum,$t.Maximum)
    }
}
Write-Output "--- by client ---"
$allEvents | Group-Object client | Sort-Object Count -Descending | ForEach-Object {
    Write-Output ("  {0,-16} n={1}" -f $_.Name,$_.Count) }
Write-Output ""
Write-Output "next: .\build.ps1"
