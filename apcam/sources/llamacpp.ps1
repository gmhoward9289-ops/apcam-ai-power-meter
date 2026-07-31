# APCAM - sources/llamacpp.ps1
#
# Adapter for a standalone llama.cpp `llama-server`. Dot-sourced from
# collect.ps1 when -Source llamacpp is selected; collect.ps1's preamble
# ($machine, $LogDir, Get-ClientLabel, Read-SharedLines, ...) is in scope.
#
# What the logs actually offer (derived from llama.cpp's own source, both the
# pre-Nov-2025 single-file server and the current split server):
#
#   * request lines, INFO level in builds from ~Oct 2024 (b39xx) to Nov 2025:
#       srv  log_server_r: request: POST /v1/chat/completions 127.0.0.1 200
#     method, path, client address and status - but NO duration and NO
#     timestamp. In Nov 2025 upstream demoted this line to trace and currently
#     does not register the logger at all, so on newer builds there are no
#     per-request lines and only the timing/rate lines below are available.
#   * per-task timing block on completion (INFO in both eras; older builds
#     print it as one call with bare continuation lines, current builds prefix
#     every row with "slot print_timing: id N | task M |"):
#       prompt eval time = ... ms / N tokens (... ms per token, ... tokens per second)
#              eval time = ... ms / N tokens (... ms per token, ... tokens per second)
#             total time = ... ms / N tokens
#   * periodic progress (current builds, every ~3s once 100 tokens decoded):
#       slot print_timing: id  0 | task 12 | n_decoded = 250, tg = 51.90 t/s, tg_3s = ...
#   * "new prompt" line: n_prompt_tokens = N in older builds, task.n_tokens = N
#     in newer ones; trace-only on current builds so often absent.
#   * srv  load_model: loading model '<path or name>' and the same
#     llama_context: n_ctx lines the ollama path reads.
#
# llama-server writes all of this to stderr and never timestamps it with wall
# time (--log-timestamps prints time SINCE START). Absolute times therefore
# only exist if a wrapper stamped the lines: journald (journalctl -o short-iso),
# docker logs -t, or piping through ts. This adapter reads an ISO-8601 prefix
# when present; without one, events and rates still parse but carry no
# timestamp and are NOT merged into the persistent history (no stable identity
# across runs), and the dataset is a snapshot of the scanned logs only.
#
# Attribution is simpler than ollama's: llama-server serves one model per
# process, so everything after a load line belongs to that model - stamped in
# scan order, no wall clock needed.
#
# Honest-numbers notes, mirrored in the README:
#   * events have dur = 0 (0, not null, so dataset consumers can keep treating
#     dur as a number). The request line has no duration; pairing tasks to
#     requests by order would be the confidently-wrong zip the ollama path
#     refuses, so this adapter refuses it too. Busy time comes from the tasks:
#     busySeconds = sum of "total time" rows.
#   * promptTokens counts EVALUATED prefill tokens (prompt eval rows; cache
#     hits excluded), falling back to the new-prompt count for tasks that
#     never printed one. Ollama's figure is the full task.n_tokens.
#   * generationTokens sums final eval rows, so it covers completed tasks only.
#
# KEEP THIS FILE PURE ASCII - see the note at the top of collect.ps1.

. (Join-Path $PSScriptRoot 'common.ps1')

if (-not $LogDirGiven) {
    Write-Error ("-Source llamacpp needs -LogDir: llama-server logs to stderr and has no " +
        "default log directory. Capture it first, e.g. 'llama-server ... 2>>llama.log', " +
        "'journalctl -u <unit> -o short-iso > llama.log', or 'docker logs -t <ctr> 2>llama.log', " +
        "then pass the directory (scans *.log) or the file itself.")
    return
}

$lcLogFiles = @()
if (Test-Path $LogDir -PathType Leaf) {
    $lcLogFiles = @(Get-Item $LogDir)
} elseif (Test-Path $LogDir) {
    $lcLogFiles = @(Get-ChildItem -Path $LogDir -Filter '*.log' -File -EA SilentlyContinue |
                    Sort-Object LastWriteTime, Name)
}
if (-not $lcLogFiles.Count) {
    Write-Warning "no *.log files at $LogDir - nothing to parse."
}

# request paths that count as inference (llama-server's endpoint set)
$lcInferencePaths = @('/completion','/completions','/v1/completions',
                      '/chat/completions','/v1/chat/completions','/infill',
                      '/embedding','/embeddings','/v1/embeddings',
                      '/rerank','/reranking','/v1/rerank')

# strip a model file path down to an entity name
function Get-LcModelName([string]$p) {
    $n = ($p -split '[\\/]')[-1]
    $n = $n -replace '\.gguf$', ''
    $n = $n -replace '-\d{5}-of-\d{5}$', ''   # multi-part gguf shards
    return $n
}

$lcEvents  = New-Object System.Collections.ArrayList   # request lines
$lcSamples = New-Object System.Collections.ArrayList   # generation-rate samples
$lcLoads   = New-Object System.Collections.ArrayList   # model load lines
$taskSeen   = @{}   # file|task -> rate sample (max n_decoded wins, first ts kept)
$promptEval = @{}   # file|task -> evaluated prefill tokens (prompt eval row)
$newPrompt  = @{}   # file|task -> announced prompt size (new prompt line)
$genEval    = @{}   # file|task -> final generated tokens (eval row)
$totalMs    = @{}   # file|task -> total task ms (total time row)
$sawTs   = $false
$curModel = $null
$curCtx   = $null

# wrapper timestamp: journald short-iso, docker logs -t, or ts(1). llama-server
# itself never prints wall time, so this is the only absolute-time source.
$lcTsRe = '^(\d{4}-\d{2}-\d{2})[T ](\d{2}:\d{2}:\d{2})(?:[.,]\d+)?(?:Z|[+-]\d{2}:?\d{2})?\s+(.+)$'

foreach ($lf in $lcLogFiles) {
    $bareTasks      = 0
    $lastTimingKey  = $null

    foreach ($raw in (Read-SharedLines $lf.FullName)) {
        $t = $raw -replace '\x1b\[[0-9;]*m', ''    # ANSI colors, if captured
        $lineTs = $null

        if ($t -match $lcTsRe) {
            try {
                $lineTs = [datetime]::ParseExact(($Matches[1] + ' ' + $Matches[2]),
                                                 'yyyy-MM-dd HH:mm:ss', $null)
                $sawTs = $true
            } catch { }
            $t = $Matches[3]
            # journald short-iso carries "host ident[pid]: " after the stamp
            if ($t -match '^\S+\s+[^\s:\[\]]+\[\d+\]:\s+(.+)$') { $t = $Matches[1] }
        }
        # llama.cpp's own --log-timestamps/--log-prefix decorations: uptime
        # (minutes.seconds.ms.us - relative, so not usable as a clock) and a
        # level letter. Strip both so payload matching below is uniform.
        if ($t -match '^\d+\.\d{2}\.\d{3}\.\d{3}\s+(.+)$') { $t = $Matches[1] }
        if ($t -match '^[IWED]\s(.+)$')                    { $t = $Matches[1] }

        # ---- request lines (INFO until Nov 2025; "done request:" at trace after) ----
        if ($t -match 'srv\s+log_server_r: (?:done )?request: (\S+) (\S+) (\S+) (\d+)$') {
            $path = $Matches[2]
            if ($lcInferencePaths -notcontains $path) { continue }
            $startStr = ''            # empty, not null: consumers sort/format these
            if ($lineTs) { $startStr = $lineTs.ToString('yyyy-MM-ddTHH:mm:ss') }
            [void]$lcEvents.Add([pscustomobject]@{
                start  = $startStr        # completion moment; the line has no duration
                dur    = 0                # llama-server logs none - busySeconds holds real busy time
                status = [int]$Matches[4]
                client = Get-ClientLabel $Matches[3]
                path   = $path
                model  = $curModel
                ctx    = $curCtx
            })
            continue
        }

        # ---- model load / context size ----
        if ($t -match "load_model: loading model '([^']+)'") {
            $curModel = Get-LcModelName $Matches[1]
            $curCtx   = $null
            [void]$lcLoads.Add([pscustomobject]@{ ts = $lineTs; model = $curModel })
            continue
        }
        if ($t -match 'llama_context: n_ctx\s+=\s+(\d+)') {
            $curCtx = [int]$Matches[1]
            continue
        }

        # ---- new prompt (older: n_prompt_tokens, newer: task.n_tokens) ----
        if ($t -match 'task (\d+) \| new prompt,.*?(?:task\.n_tokens|n_prompt_tokens)\s*=\s*(\d+)') {
            $newPrompt["$($lf.Name)|$($Matches[1])"] = [int]$Matches[2]
            continue
        }

        # ---- timing rows. Current builds prefix every row with the slot/task;
        # older builds print one header row and bare continuation lines. ----
        $payload = $null
        $key     = $null
        if ($t -match 'slot\s+print_timing: id\s*\d+ \| task (\d+) \|\s?(.*)$') {
            $key     = "$($lf.Name)|$($Matches[1])"
            $payload = $Matches[2]
            $lastTimingKey = $key
            if (-not $payload.Trim()) { continue }   # header row of the older block form
        } elseif ($t -match '^\s*(prompt eval time|eval time|total time)\s*=') {
            $payload = $t                             # bare continuation line
            if ($lastTimingKey) { $key = $lastTimingKey }
            else { $bareTasks++; $key = "$($lf.Name)|bare$bareTasks" }
        }
        if ($null -ne $payload) {
            if ($payload -match 'n_decoded\s*=\s*(\d+), tg\s*=\s*([\d.]+) t/s') {
                # periodic progress: dedupe per task, larger n_decoded wins,
                # first timestamp kept - same pin as the ollama path
                $gen = [int]$Matches[1]; $tps = [double]$Matches[2]
                if ($taskSeen.ContainsKey($key)) {
                    if ($gen -gt $taskSeen[$key].gen) { $taskSeen[$key].gen = $gen; $taskSeen[$key].tps = $tps }
                } else {
                    $rec = [pscustomobject]@{ ts = $lineTs; gen = $gen; tps = $tps
                                              model = $curModel; ctx = $curCtx }
                    $taskSeen[$key] = $rec; [void]$lcSamples.Add($rec)
                }
            } elseif ($payload -match 'prompt eval time\s*=\s*[\d.]+ ms\s*/\s*(\d+) tokens') {
                $promptEval[$key] = [int]$Matches[1]
            } elseif ($payload -match '^\s*eval time\s*=\s*[\d.]+ ms\s*/\s*(\d+) tokens \(\s*[\d.]+ ms per token,\s*([\d.]+) tokens per second\)') {
                # final per-task figures: fold into the same sample slot, where
                # the final count naturally beats any interim progress line
                $gen = [int]$Matches[1]; $tps = [double]$Matches[2]
                $genEval[$key] = $gen
                if ($taskSeen.ContainsKey($key)) {
                    if ($gen -ge $taskSeen[$key].gen) { $taskSeen[$key].gen = $gen; $taskSeen[$key].tps = $tps }
                } else {
                    $rec = [pscustomobject]@{ ts = $lineTs; gen = $gen; tps = $tps
                                              model = $curModel; ctx = $curCtx }
                    $taskSeen[$key] = $rec; [void]$lcSamples.Add($rec)
                }
            } elseif ($payload -match 'total time\s*=\s*([\d.]+) ms') {
                $totalMs[$key] = [double]$Matches[1]
            }
            continue
        }
    }
}

# ---------------- token totals / busy time ----------------
$promptTotal = [long]0
$allTaskKeys = @($promptEval.Keys) + @($newPrompt.Keys) | Sort-Object -Unique
foreach ($k in $allTaskKeys) {
    if ($promptEval.ContainsKey($k)) { $promptTotal += $promptEval[$k] }
    else                             { $promptTotal += $newPrompt[$k] }
}
$genTotal = [long]0
foreach ($v in $genEval.Values) { $genTotal += $v }
$busySeconds = 0.0
foreach ($v in $totalMs.Values) { $busySeconds += $v }
$busySeconds = [math]::Round($busySeconds / 1000, 3)

# ---------------- shape events / rates ----------------
$events = New-Object System.Collections.ArrayList
foreach ($e in $lcEvents) { [void]$events.Add($e) }
$rates = New-Object System.Collections.ArrayList
foreach ($s in ($lcSamples | Where-Object { $_.tps -gt 0 })) {
    $tsStr = ''                # empty, not null - same reason as event starts
    if ($s.ts) { $tsStr = $s.ts.ToString('yyyy-MM-ddTHH:mm:ss') }
    [void]$rates.Add([pscustomobject]@{
        ts = $tsStr; tps = [math]::Round($s.tps,2)
        gen = $s.gen; model = $s.model; ctx = $s.ctx
    })
}

if (($events.Count -or $rates.Count) -and -not $sawTs) {
    Write-Warning ("these logs carry no wall-clock timestamps, so events and rates have no " +
        "start/ts and are NOT merged into $HistoryFile (no stable identity across runs). " +
        "Wrap the server so lines get stamped: journalctl -o short-iso, docker logs -t, " +
        "or pipe stderr through ts(1) from moreutils.")
}

# ---------------- merge timestamped records into persistent history ----------------
# Same shape as the ollama history. Event keys use status instead of the
# duration (llama-server logs none); rate keys match the ollama form.
$hist = @{ events = @{}; rates = @{} }
if (Test-Path $HistoryFile) {
    try {
        $prev = Get-Content $HistoryFile -Raw | ConvertFrom-Json
        foreach ($e in $prev.events) {
            $e.start = Format-HistTs $e.start
            $hist.events["$($e.start)|$($e.path)|$($e.client)|$($e.status)"] = $e
        }
        foreach ($r in $prev.rates) {
            $r.ts = Format-HistTs $r.ts
            $hist.rates["$($r.ts)|$($r.tps)|$($r.gen)"] = $r
        }
    } catch { Write-Warning "could not read history, starting fresh: $_" }
}
$beforeE = $hist.events.Count; $beforeR = $hist.rates.Count
foreach ($e in ($events | Where-Object { $_.start })) { $hist.events["$($e.start)|$($e.path)|$($e.client)|$($e.status)"] = $e }
foreach ($r in ($rates  | Where-Object { $_.ts }))    { $hist.rates["$($r.ts)|$($r.tps)|$($r.gen)"] = $r }

# Same tie-break as collect.ps1's ollama path: Hashtable.Values enumeration
# order is randomized per process, so a sort key that isn't total leaves same-
# start ties in that random order. Mirror the rest of the dedupe key here too.
$allEvents = @($hist.events.Values | Sort-Object start, path, client, status) + @($events | Where-Object { -not $_.start })
$allRates  = @($hist.rates.Values  | Sort-Object ts, tps, gen)              + @($rates  | Where-Object { -not $_.ts })
if ($sawTs -or (Test-Path $HistoryFile)) {
    Write-ApcamJson $HistoryFile ([pscustomobject]@{
        events = @($hist.events.Values | Sort-Object start, path, client, status)
        rates  = @($hist.rates.Values  | Sort-Object ts, tps, gen) }) 6
}

# ---------------- inventory (no manifests, no registry - names only) ----------------
$serverUp = $false
try {
    $props = Invoke-RestMethod -Uri "$Endpoint/props" -TimeoutSec 5
    $serverUp = $true
    if ($props.PSObject.Properties.Name -contains 'model_path' -and $props.model_path) {
        $n = Get-LcModelName "$($props.model_path)"
        if (-not $curModel) { $curModel = $n }
        [void]$lcLoads.Add([pscustomobject]@{ ts = $null; model = $n })
    }
} catch { }

$models = @($lcLoads | ForEach-Object { $_.model } | Sort-Object -Unique | ForEach-Object {
    [pscustomobject]@{ name=$_; sizeBytes=$null; params=$null; quant=$null; family=$null; caps=@() }
})
$loaded = @()
if ($serverUp -and $curModel) { $loaded = @([pscustomobject]@{ name=$curModel; vram=$null }) }

# ---------------- emit dataset ----------------
$out = [pscustomobject]@{
    schema      = 1
    source      = 'llamacpp'
    generatedAt = (Get-Date).ToString('yyyy-MM-ddTHH:mm:ss')
    anonymised  = (-not $KeepRawClients)
    serverUp    = $serverUp
    machine     = $machine
    models      = $models
    loadedNow   = $loaded
    diskBytes   = $null                 # no blob store to measure
    sharedBlobs = @()
    tagDigest   = @{}
    promptTokens     = $promptTotal
    generationTokens = $genTotal        # completed tasks only - exact, not a floor
    busySeconds      = $busySeconds     # sum of per-task "total time" rows
    busySource       = 'task-total-time'
    gpuNow      = Get-ApcamGpuNow
    events      = $allEvents
    rates       = $allRates
}
Write-ApcamJson $OutFile $out 8

# ---------------- summary ----------------
Write-Output "wrote $OutFile (source: llamacpp)"
Write-Output "events: $($allEvents.Count) (+$($allEvents.Count - $beforeE))   rate samples: $($allRates.Count) (+$($allRates.Count - $beforeR))"
Write-Output "logs scanned: $($lcLogFiles.Count)   loads seen: $($lcLoads.Count)   models: $($models.Count)   server up: $serverUp"
Write-Output ("prompt tokens (evaluated): {0:N0}   generated (completed tasks): {1:N0}" -f $promptTotal, $genTotal)

if (-not $allEvents.Count -and -not $allRates.Count) {
    Write-Warning ("nothing parsed. Request lines only exist at INFO on llama.cpp builds from " +
        "~Oct 2024 to Nov 2025; newer builds log no per-request lines at default verbosity, " +
        "and timing lines need completed generations. Check the log for 'srv' / 'slot' lines.")
    Write-Output "next: .\build.ps1 -Dataset $OutFile"
    return
}

if ($busySeconds -gt 0) {
    $w = $machine.gpuActiveW + $machine.systemWatts
    Write-Output ("busy (task total time): {0:N1}s   energy at {1:N0} W: {2:N2} Wh" -f `
        $busySeconds, $w, ($busySeconds * $w / 3600))
}
Write-Output "note: llama-server logs no per-request durations - event dur is null; busy time is per-task."
if ($allRates.Count) {
    Write-Output "--- observed generation rate by model ---"
    $allRates | Group-Object model | ForEach-Object {
        $t = $_.Group | Measure-Object -Property tps -Average -Minimum -Maximum
        Write-Output ("  {0,-46} n={1,-3} avg {2,6:N1}  range {3:N1}-{4:N1} tok/s" -f `
            $_.Name,$_.Count,$t.Average,$t.Minimum,$t.Maximum)
    }
}
if ($allEvents.Count) {
    Write-Output "--- by client ---"
    $allEvents | Group-Object client | Sort-Object Count -Descending | ForEach-Object {
        Write-Output ("  {0,-16} n={1}" -f $_.Name,$_.Count) }
}
Write-Output ""
Write-Output "next: .\build.ps1 -Dataset $OutFile"
