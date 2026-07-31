# APCAM - sources/vllm.ps1
#
# Adapter for vLLM. No logs are parsed: vLLM exposes a Prometheus endpoint at
# /metrics, which is scraped and mapped into the dataset schema. Dot-sourced
# from collect.ps1 when -Source vllm is selected.
#
# What the metrics honestly give (metric names from vllm's own definitions,
# both the v1 engine and the legacy v0 names where they differ):
#
#   * EXACT cumulative token counters per served model:
#       vllm:prompt_tokens_total / vllm:generation_tokens_total
#     (plus vllm:prompt_tokens_cached_total on v1). These are counts, not the
#     ~50-token progress floor the log-parsing sources live with.
#   * request counts: vllm:request_success_total, by finished_reason.
#   * latency histograms - only their _sum/_count are read, which yield exact
#     totals and true averages: vllm:e2e_request_latency_seconds,
#     vllm:request_inference_time_seconds (v1), vllm:request_queue_time_seconds,
#     vllm:time_to_first_token_seconds, and per-token decode time from
#     vllm:inter_token_latency_seconds (v1) or
#     vllm:time_per_output_token_seconds (v0).
#   * gauges: vllm:num_requests_running / _waiting, and KV-cache usage from
#     vllm:kv_cache_usage_perc (v1) or vllm:gpu_cache_usage_perc (v0).
#
# What they do NOT give: a per-request timeline. There is no start time, no
# client address, no per-request duration - so events and rates stay EMPTY
# rather than being fabricated, and the real information lands in a top-level
# "aggregates" block. Counters are cumulative since server start and reset on
# restart; each run also appends a snapshot to the history file, so deltas
# between runs are exact interval usage (when a counter goes backwards, the
# server restarted in between).
#
# Busy time for the energy math: per-request inference seconds (RUNNING phase)
# where available, else end-to-end seconds (which include queue time). Either
# way requests overlap under continuous batching, so summed request-seconds
# can exceed wall-clock busy time - treat energy from it as an upper bound.
#
# -MetricsFile parses a saved scrape (curl .../metrics > snap.txt) instead of
# HTTP - useful for offline analysis and for the hermetic tests. serverUp is
# only ever true for a live scrape.
#
# KEEP THIS FILE PURE ASCII - see the note at the top of collect.ps1.

. (Join-Path $PSScriptRoot 'common.ps1')

# ---------------- acquire metrics text ----------------
$serverUp = $false
$metricsText = ''
if ($MetricsFile) {
    if (-not (Test-Path $MetricsFile)) {
        Write-Error "metrics file not found: $MetricsFile"
        return
    }
    $metricsText = Get-Content $MetricsFile -Raw
} else {
    try {
        $resp = Invoke-WebRequest -Uri "$Endpoint/metrics" -UseBasicParsing -TimeoutSec 10
        $metricsText = "$($resp.Content)"
        $serverUp = $true
    } catch {
        Write-Warning "could not scrape $Endpoint/metrics : $($_.Exception.Message)"
    }
}

# ---------------- parse the Prometheus text exposition ----------------
# One pass into {name, labels, value} triples. Histogram _bucket series and
# prometheus_client's _created bookkeeping series are dropped here; everything
# else is summed by callers below.
$series = New-Object System.Collections.ArrayList
$vmLineRe  = '^([a-zA-Z_:][a-zA-Z0-9_:]*)(?:\{(.*)\})?\s+(\S+)'
$vmLabelRe = '([a-zA-Z_][a-zA-Z0-9_]*)="((?:[^"\\]|\\.)*)"'
$inv = [System.Globalization.CultureInfo]::InvariantCulture
foreach ($rawLine in ($metricsText -split "`n")) {
    $line = $rawLine.TrimEnd("`r")
    if (-not $line -or $line.StartsWith('#')) { continue }
    if ($line -notmatch $vmLineRe) { continue }
    $name = $Matches[1]
    if ($name.EndsWith('_bucket') -or $name.EndsWith('_created')) { continue }
    $val = 0.0
    if (-not [double]::TryParse($Matches[3], [System.Globalization.NumberStyles]::Float, $inv, [ref]$val)) { continue }
    if ([double]::IsNaN($val) -or [double]::IsInfinity($val)) { continue }
    $labels = @{}
    if ($Matches[2]) {
        foreach ($lm in [regex]::Matches($Matches[2], $vmLabelRe)) {
            $labels[$lm.Groups[1].Value] = ($lm.Groups[2].Value -replace '\\(["\\])', '$1')
        }
    }
    [void]$series.Add([pscustomobject]@{ name = $name; labels = $labels; value = $val })
}

# sum a metric's series for one model; $null when the metric is absent
# (absent and zero are different answers and the fallbacks below rely on that)
function Get-VmSum([string]$metric, [string]$model) {
    $hit = $false; $sum = 0.0
    foreach ($s in $series) {
        if ($s.name -ne $metric) { continue }
        if ($s.labels['model_name'] -cne $model) { continue }
        $sum += $s.value; $hit = $true
    }
    if ($hit) { return $sum }
    return $null
}
function Get-VmAvg([string]$metric, [string]$model) {
    $n = 0; $sum = 0.0
    foreach ($s in $series) {
        if ($s.name -ne $metric) { continue }
        if ($s.labels['model_name'] -cne $model) { continue }
        $sum += $s.value; $n++
    }
    if ($n) { return ($sum / $n) }
    return $null
}

$modelNames = @($series | Where-Object { $_.name.StartsWith('vllm:') -and $_.labels.ContainsKey('model_name') } |
                ForEach-Object { $_.labels['model_name'] } | Sort-Object -Unique)
if ($metricsText -and -not $modelNames.Count) {
    Write-Warning "no vllm: series with a model_name label found - is this actually a vLLM /metrics scrape?"
}

# ---------------- per-model aggregates ----------------
$aggModels    = New-Object System.Collections.ArrayList
$promptTotal  = [long]0
$genTotal     = [long]0
$busyTotal    = 0.0
$busySources  = @()
foreach ($m in $modelNames) {
    $prompt  = Get-VmSum 'vllm:prompt_tokens_total' $m
    $cached  = Get-VmSum 'vllm:prompt_tokens_cached_total' $m
    $gen     = Get-VmSum 'vllm:generation_tokens_total' $m
    $success = Get-VmSum 'vllm:request_success_total' $m
    $running = Get-VmSum 'vllm:num_requests_running' $m
    $waiting = Get-VmSum 'vllm:num_requests_waiting' $m
    $e2eSum   = Get-VmSum 'vllm:e2e_request_latency_seconds_sum'   $m
    $e2eCount = Get-VmSum 'vllm:e2e_request_latency_seconds_count' $m
    $infSum   = Get-VmSum 'vllm:request_inference_time_seconds_sum'   $m
    $infCount = Get-VmSum 'vllm:request_inference_time_seconds_count' $m
    $queueSum = Get-VmSum 'vllm:request_queue_time_seconds_sum' $m
    $ttftSum   = Get-VmSum 'vllm:time_to_first_token_seconds_sum'   $m
    $ttftCount = Get-VmSum 'vllm:time_to_first_token_seconds_count' $m
    # per-token decode time: v1 name first, v0 name as fallback
    $tpotSum   = Get-VmSum 'vllm:inter_token_latency_seconds_sum'   $m
    $tpotCount = Get-VmSum 'vllm:inter_token_latency_seconds_count' $m
    if ($null -eq $tpotSum) {
        $tpotSum   = Get-VmSum 'vllm:time_per_output_token_seconds_sum'   $m
        $tpotCount = Get-VmSum 'vllm:time_per_output_token_seconds_count' $m
    }
    $kv = Get-VmAvg 'vllm:kv_cache_usage_perc' $m
    if ($null -eq $kv) { $kv = Get-VmAvg 'vllm:gpu_cache_usage_perc' $m }

    $byReason = @{}
    foreach ($s in $series) {
        if ($s.name -ne 'vllm:request_success_total') { continue }
        if ($s.labels['model_name'] -cne $m) { continue }
        $reason = $s.labels['finished_reason']
        if (-not $reason) { $reason = 'unknown' }
        if ($byReason.ContainsKey($reason)) { $byReason[$reason] += $s.value }
        else                                { $byReason[$reason]  = $s.value }
    }
    $byReasonOut = [pscustomobject]@{}
    foreach ($k in ($byReason.Keys | Sort-Object)) {
        $byReasonOut | Add-Member -NotePropertyName $k -NotePropertyValue ([long][math]::Round($byReason[$k]))
    }

    # busy seconds: RUNNING-phase time when the deployment exposes it,
    # end-to-end (includes queueing) otherwise
    $busy = $null; $busySource = $null
    if ($null -ne $infSum)        { $busy = $infSum; $busySource = 'inference' }
    elseif ($null -ne $e2eSum)    { $busy = $e2eSum; $busySource = 'e2e' }

    $avgE2e  = $null
    if ($null -ne $e2eSum -and $e2eCount -gt 0) { $avgE2e = [math]::Round($e2eSum / $e2eCount, 3) }
    $avgTtft = $null
    if ($null -ne $ttftSum -and $ttftCount -gt 0) { $avgTtft = [math]::Round($ttftSum / $ttftCount, 4) }
    $avgTpot = $null; $decodeTps = $null
    if ($null -ne $tpotSum -and $tpotCount -gt 0) {
        $avgTpot = $tpotSum / $tpotCount
        if ($avgTpot -gt 0) { $decodeTps = [math]::Round(1.0 / $avgTpot, 2) }
        $avgTpot = [math]::Round($avgTpot, 5)
    }

    $entry = [pscustomobject]@{
        model            = $m
        promptTokens     = $(if ($null -ne $prompt) { [long][math]::Round($prompt) } else { $null })
        promptTokensCached = $(if ($null -ne $cached) { [long][math]::Round($cached) } else { $null })
        generationTokens = $(if ($null -ne $gen) { [long][math]::Round($gen) } else { $null })
        requests         = $(if ($null -ne $success) { [long][math]::Round($success) } else { $null })
        requestsByReason = $byReasonOut
        requestsRunning  = $(if ($null -ne $running) { [int]$running } else { $null })
        requestsWaiting  = $(if ($null -ne $waiting) { [int]$waiting } else { $null })
        busySeconds      = $(if ($null -ne $busy) { [math]::Round($busy, 3) } else { $null })
        busySource       = $busySource
        e2eSeconds       = $(if ($null -ne $e2eSum) { [math]::Round($e2eSum, 3) } else { $null })
        queueSeconds     = $(if ($null -ne $queueSum) { [math]::Round($queueSum, 3) } else { $null })
        avgE2eSeconds    = $avgE2e
        avgTtftSeconds   = $avgTtft
        avgTpotSeconds   = $avgTpot
        decodeTokPerSec  = $decodeTps
        kvCacheUsage     = $(if ($null -ne $kv) { [math]::Round($kv, 4) } else { $null })
    }
    [void]$aggModels.Add($entry)
    if ($null -ne $prompt) { $promptTotal += [long][math]::Round($prompt) }
    if ($null -ne $gen)    { $genTotal    += [long][math]::Round($gen) }
    if ($null -ne $busy)   { $busyTotal   += $busy; $busySources += $busySource }
}
$busyTotal = [math]::Round($busyTotal, 3)
$busySourceOut = $null
if ($busySources.Count) {
    $u = @($busySources | Sort-Object -Unique)
    if ($u.Count -eq 1) { $busySourceOut = $u[0] } else { $busySourceOut = 'mixed' }
}

# ---------------- snapshot history ----------------
# Counters are cumulative since server start, so history keeps one snapshot
# per observed counter state; deltas between snapshots are exact interval
# usage. A snapshot identical to the last one is not re-appended.
$snapshots = @()
if (Test-Path $HistoryFile) {
    try {
        $prevHist = Get-Content $HistoryFile -Raw | ConvertFrom-Json
        if ($prevHist.PSObject.Properties.Name -contains 'snapshots') {
            $snapshots = @($prevHist.snapshots)
        } elseif ($prevHist.PSObject.Properties.Name -contains 'events') {
            Write-Error ("$HistoryFile holds an events/rates history (another source's file?). " +
                "Refusing to overwrite it - pass a vllm-specific -HistoryFile.")
            return
        }
    } catch { Write-Warning "could not read history, starting fresh: $_" }
}
function Get-VmSnapshotSig($models) {
    return (@($models | ForEach-Object {
        "$($_.model)|$($_.promptTokens)|$($_.generationTokens)|$($_.requests)"
    }) | Sort-Object) -join ';'
}
if ($aggModels.Count) {
    $snapModels = @($aggModels | ForEach-Object {
        [pscustomobject]@{ model = $_.model; promptTokens = $_.promptTokens
                           generationTokens = $_.generationTokens; requests = $_.requests }
    })
    $newSig  = Get-VmSnapshotSig $snapModels
    $lastSig = ''
    if ($snapshots.Count) { $lastSig = Get-VmSnapshotSig @($snapshots[-1].models) }
    if ($newSig -cne $lastSig) {
        $snapshots = @($snapshots) + @([pscustomobject]@{
            ts = (Get-Date).ToString('yyyy-MM-ddTHH:mm:ss'); models = $snapModels })
    }
    Write-ApcamJson $HistoryFile ([pscustomobject]@{ snapshots = $snapshots }) 6
}

# ---------------- inventory ----------------
$models = @($modelNames | ForEach-Object {
    [pscustomobject]@{ name=$_; sizeBytes=$null; params=$null; quant=$null; family=$null; caps=@() }
})
# vLLM keeps its served model(s) resident for the server's lifetime
$loaded = @()
if ($serverUp) {
    $loaded = @($modelNames | ForEach-Object { [pscustomobject]@{ name=$_; vram=$null } })
}

# ---------------- emit dataset ----------------
$out = [pscustomobject]@{
    schema      = 1
    source      = 'vllm'
    generatedAt = (Get-Date).ToString('yyyy-MM-ddTHH:mm:ss')
    anonymised  = $true                 # no client identifiers exist in this source
    serverUp    = $serverUp
    machine     = $machine
    models      = $models
    loadedNow   = $loaded
    diskBytes   = $null
    sharedBlobs = @()
    tagDigest   = @{}
    promptTokens     = $promptTotal     # exact counter, no 50-token floor
    generationTokens = $genTotal        # exact counter, no 50-token floor
    busySeconds      = $busyTotal       # summed request-seconds; overlaps under batching
    busySource       = $busySourceOut
    gpuNow      = Get-ApcamGpuNow
    events      = @()                   # vLLM exposes no per-request timeline
    rates       = @()
    aggregates  = [pscustomobject]@{
        models      = @($aggModels)
        snapshots   = $snapshots
        counterNote = 'cumulative since vLLM start; a counter going backwards between snapshots means the server restarted'
    }
}
Write-ApcamJson $OutFile $out 8

# ---------------- summary ----------------
Write-Output "wrote $OutFile (source: vllm)"
if ($MetricsFile) { Write-Output "metrics: parsed from file $MetricsFile" }
else              { Write-Output "metrics: $Endpoint/metrics   server up: $serverUp" }
Write-Output "models: $($models.Count)   snapshots in history: $($snapshots.Count)"
Write-Output ("prompt tokens: {0:N0}   generated: {1:N0}   (exact counters - no 50-token floor)" -f $promptTotal, $genTotal)
if (-not $aggModels.Count) {
    Write-Warning "no per-model aggregates - nothing served yet, or the scrape failed."
    Write-Output "next: .\build.ps1 -Dataset $OutFile"
    return
}
if ($busyTotal -gt 0) {
    $w = $machine.gpuActiveW + $machine.systemWatts
    Write-Output ("busy ({0}): {1:N1}s   energy at {2:N0} W: {3:N2} Wh (upper bound - requests overlap)" -f `
        $busySourceOut, $busyTotal, $w, ($busyTotal * $w / 3600))
}
Write-Output "--- per model ---"
foreach ($a in $aggModels) {
    $tp = ''
    if ($null -ne $a.decodeTokPerSec) { $tp = "  decode $($a.decodeTokPerSec) tok/s" }
    Write-Output ("  {0,-46} req={1,-6} prompt={2,-10:N0} gen={3,-10:N0}{4}" -f `
        $a.model, $a.requests, $a.promptTokens, $a.generationTokens, $tp)
}
Write-Output ""
Write-Output "note: no per-request timeline exists in /metrics - events and rates are empty by design."
Write-Output "next: .\build.ps1 -Dataset $OutFile"
