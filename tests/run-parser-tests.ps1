# APCAM parser regression tests.
#
# Runs apcam/collect.ps1 against the synthetic fixtures in tests/fixtures/ and
# asserts, field by field, on the dataset.json it emits. The point (issue #3):
# collect.ps1 parses llama-server internals that are not a stable interface, so
# an Ollama format change should fail HERE, not go quietly dark on a user's box.
#
# Hermetic by construction:
#   * fixture logs + fixture manifests tree + a stub machine file
#   * -Endpoint points at a port that refuses connections, so the handled
#     "Ollama unreachable" path is exercised (ollamaUp=false, empty inventory)
#   * output goes to a fresh temp dir; nothing in the repo is touched
# No Pester, no network, no GPU. Works under pwsh on Linux/macOS and under
# Windows PowerShell 5.1.
#
# Usage:  pwsh tests/run-parser-tests.ps1
# Exit:   0 = all assertions pass; 1 = failures (one expected-vs-got block each)
#
# The fixtures are synthetic. Clients are loopback/RFC1918/CGNAT only, the user
# name in log paths is 'ci', and digests are a 12-hex prefix padded with zeros.
# If you change a fixture, re-derive the expected values below by hand - they
# are deliberately hard-coded, not recomputed, so a parser regression cannot
# recompute itself into a pass.
#
# KEEP THIS FILE PURE ASCII - see the note at the top of apcam/collect.ps1.

$ErrorActionPreference = 'Stop'

$testsDir = $PSScriptRoot
$repoRoot = Split-Path -Parent $testsDir
$collect  = Join-Path $repoRoot (Join-Path 'apcam' 'collect.ps1')
$fixtures = Join-Path $testsDir 'fixtures'

$tmp = Join-Path ([System.IO.Path]::GetTempPath()) ('apcam-parser-tests-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $tmp | Out-Null

$dataset1 = Join-Path $tmp 'dataset.json'
$dataset2 = Join-Path $tmp 'dataset2.json'
$history  = Join-Path $tmp 'history.json'

$common = @{
    LogDir      = Join-Path $fixtures 'logs'
    ModelDir    = Join-Path $fixtures 'models'
    MachineFile = Join-Path $fixtures 'machine.fixture.json'
    HistoryFile = $history
    # port 9 (discard) is not listening on any sane host, so this refuses fast
    Endpoint    = 'http://127.0.0.1:9'
}

# ---------------- assertion plumbing ----------------
$script:passed = 0
$script:failed = 0

# collect.ps1 writes start/ts as 'yyyy-MM-ddTHH:mm:ss' STRINGS, but pwsh 7's
# ConvertFrom-Json revives ISO-8601-shaped strings as [datetime] (Windows
# PowerShell 5.1 keeps them as strings). Normalise before comparing.
function ConvertTo-IsoSecond($v) {
    if ($v -is [datetime]) { return $v.ToString('yyyy-MM-ddTHH:mm:ss') }
    return "$v"
}

function Assert-Eq([string]$label, $expected, $got) {
    # case-sensitive string compare so e.g. a casing change in client labels fails
    if ("$expected" -cne "$got") {
        Write-Host ("FAIL  {0}" -f $label)
        Write-Host ("      expected: {0}" -f "$expected")
        Write-Host ("      got:      {0}" -f "$got")
        $script:failed++
    } else {
        Write-Host ("ok    {0}" -f $label)
        $script:passed++
    }
}

function Find-One($items, [scriptblock]$pred, [string]$label) {
    $hits = @($items | Where-Object $pred)
    if ($hits.Count -ne 1) {
        Write-Host ("FAIL  {0}" -f $label)
        Write-Host ("      expected: exactly 1 match")
        Write-Host ("      got:      {0} matches" -f $hits.Count)
        $script:failed++
        return $null
    }
    $script:passed++
    Write-Host ("ok    {0}" -f $label)
    return $hits[0]
}

function Invoke-Collect([string]$outFile, [string]$label) {
    Write-Host ""
    Write-Host "--- collect.ps1 $label ---"
    $log = & $collect @common -OutFile $outFile *>&1
    $log | ForEach-Object { Write-Host ("  | {0}" -f $_) }
    if (-not (Test-Path $outFile)) {
        Write-Host "FATAL collect.ps1 wrote no dataset at $outFile"
        exit 1
    }
    try {
        return (Get-Content $outFile -Raw | ConvertFrom-Json)
    } catch {
        Write-Host "FATAL $outFile is not valid JSON: $_"
        exit 1
    }
}

# ---------------- run 1: fresh history ----------------
$data = Invoke-Collect $dataset1 'run 1 (fresh history)'
Write-Host ""

# entity name collect.ps1 builds for two tags sharing one weights digest
$shared = 'stubmodel (shared: stubmodel:8b, stubmodel:8b-ctx32k)'

# ---- envelope / inventory (Ollama intentionally unreachable) ----
Assert-Eq 'schema'                 1        $data.schema
Assert-Eq 'ollamaUp'               'False'  $data.ollamaUp
Assert-Eq 'anonymised'             'True'   $data.anonymised
Assert-Eq 'models count (no live Ollama)'    0 @($data.models).Count
Assert-Eq 'loadedNow count (no live Ollama)' 0 @($data.loadedNow).Count
Assert-Eq 'machine.gpuActiveW passthrough'   '150.25' $data.machine.gpuActiveW
Assert-Eq 'machine.gpuIdleW passthrough'     '20.5'   $data.machine.gpuIdleW
Assert-Eq 'machine.systemWatts passthrough'  70       $data.machine.systemWatts
Assert-Eq 'diskBytes (fixture blobs dir)'    223      $data.diskBytes

# ---- shared-blob resolution from the manifests tree ----
Assert-Eq 'sharedBlobs count'      1 @($data.sharedBlobs).Count
$sb = @($data.sharedBlobs)[0]
Assert-Eq 'sharedBlobs digest'     'a1b2c3d4e5f6' $sb.digest
Assert-Eq 'sharedBlobs tagCount'   2              $sb.tagCount
Assert-Eq 'sharedBlobs tags'       'stubmodel:8b,stubmodel:8b-ctx32k' (@($sb.tags) -join ',')
Assert-Eq 'tagDigest entries'      3 @($data.tagDigest.PSObject.Properties).Count
Assert-Eq 'tagDigest stubmodel:8b'        'a1b2c3d4e5f6' $data.tagDigest.'stubmodel:8b'
Assert-Eq 'tagDigest stubmodel:8b-ctx32k' 'a1b2c3d4e5f6' $data.tagDigest.'stubmodel:8b-ctx32k'
Assert-Eq 'tagDigest tinystub:1b'         'c3d4e5f6a7b8' $data.tagDigest.'tinystub:1b'

# ---- events: [GIN] inference lines only, attributed via the load timeline ----
$ev = @($data.events)
Assert-Eq 'event count (non-inference GIN lines ignored)' 6 $ev.Count
Assert-Eq 'prompt token total (new prompt lines)' 707 $data.promptTokens

# client anonymisation: 127.0.0.1 -> localhost, RFC1918/CGNAT -> lan-<4 hex>
Assert-Eq 'events from localhost' 3 @($ev | Where-Object { $_.client -ceq 'localhost' }).Count
Assert-Eq 'events from lan-0647 (192.168.x RFC1918)' 2 @($ev | Where-Object { $_.client -ceq 'lan-0647' }).Count
Assert-Eq 'events from lan-9e58 (100.64/10 CGNAT)'   1 @($ev | Where-Object { $_.client -ceq 'lan-9e58' }).Count

# E1: CGNAT client, model resolved from the earlier log file's load event
$e = Find-One $ev { $_.path -eq '/api/chat' -and $_.client -ceq 'lan-9e58' } 'E1 lookup (/api/chat from lan-9e58)'
if ($e) {
    Assert-Eq 'E1 start'  '2026-03-14T09:30:02' (ConvertTo-IsoSecond $e.start)
    Assert-Eq 'E1 dur'    '22.816' $e.dur
    Assert-Eq 'E1 status' 200 $e.status
    Assert-Eq 'E1 model'  'tinystub:1b' $e.model
    Assert-Eq 'E1 ctx'    2048 $e.ctx
}

# E2: 5xx kept; completed before this file's first load, so the attribution
# falls through to the previous log file's timeline (cross-file case)
$e = Find-One $ev { $_.path -eq '/api/generate' -and $_.status -eq 500 } 'E2 lookup (/api/generate 500)'
if ($e) {
    Assert-Eq 'E2 start (Go s-duration subtracted)' '2026-03-14T10:14:00' (ConvertTo-IsoSecond $e.start)
    Assert-Eq 'E2 dur'    '1.513' $e.dur
    Assert-Eq 'E2 client' 'localhost' $e.client
    Assert-Eq 'E2 model (cross-file attribution)' 'tinystub:1b' $e.model
    Assert-Eq 'E2 ctx'    2048 $e.ctx
}

# E3: started before the sha256-a1b2... load but completed after it - a load
# triggered by the request itself still precedes its completion, so it must
# attribute to the newly loaded (shared-blob) entity
$e = Find-One $ev { $_.path -eq '/api/chat' -and $_.client -ceq 'localhost' } 'E3 lookup (/api/chat from localhost)'
if ($e) {
    Assert-Eq 'E3 start'  '2026-03-14T10:14:00' (ConvertTo-IsoSecond $e.start)
    Assert-Eq 'E3 dur'    '59.8' $e.dur
    Assert-Eq 'E3 model (resolved at completion time)' $shared $e.model
    Assert-Eq 'E3 ctx'    8192 $e.ctx
}

# E4: m+s Go duration, RFC1918 client, shared-blob model attribution
$e = Find-One $ev { $_.path -eq '/v1/chat/completions' } 'E4 lookup (/v1/chat/completions)'
if ($e) {
    Assert-Eq 'E4 start (1m2.4085119s subtracted)' '2026-03-14T10:15:21' (ConvertTo-IsoSecond $e.start)
    Assert-Eq 'E4 dur'    '62.409' $e.dur
    Assert-Eq 'E4 status' 200 $e.status
    Assert-Eq 'E4 client (RFC1918 -> lan hash)' 'lan-0647' $e.client
    Assert-Eq 'E4 model (shared weights entity)' $shared $e.model
    Assert-Eq 'E4 ctx'    8192 $e.ctx
}

# E5: 4xx kept, ms Go duration
$e = Find-One $ev { $_.path -eq '/api/embed' } 'E5 lookup (/api/embed)'
if ($e) {
    Assert-Eq 'E5 status (4xx retained)' 400 $e.status
    Assert-Eq 'E5 dur (2.1041ms rounded)' '0.002' $e.dur
    Assert-Eq 'E5 start' '2026-03-14T10:20:44' (ConvertTo-IsoSecond $e.start)
    Assert-Eq 'E5 client' 'localhost' $e.client
    Assert-Eq 'E5 model' 'tinystub:1b' $e.model
    Assert-Eq 'E5 ctx (reload with new n_ctx)' 4096 $e.ctx
}

# E6: second model load of the same digest, new ctx
$e = Find-One $ev { $_.path -eq '/api/generate' -and $_.status -eq 200 } 'E6 lookup (/api/generate 200)'
if ($e) {
    Assert-Eq 'E6 start'  '2026-03-14T10:21:03' (ConvertTo-IsoSecond $e.start)
    Assert-Eq 'E6 dur'    '8.913' $e.dur
    Assert-Eq 'E6 client' 'lan-0647' $e.client
    Assert-Eq 'E6 model'  'tinystub:1b' $e.model
    Assert-Eq 'E6 ctx'    4096 $e.ctx
}

# ---- rate samples: per-file task-id dedupe, attributed via load timeline ----
$rt = @($data.rates)
Assert-Eq 'rate sample count (5 raw lines, repeated task id deduped)' 4 $rt.Count

$r = Find-One $rt { $_.ts -eq '2026-03-14T09:30:20' } 'R1 lookup (ts 09:30:20)'
if ($r) {
    Assert-Eq 'R1 tps'   '61.4' $r.tps
    Assert-Eq 'R1 gen'   50 $r.gen
    Assert-Eq 'R1 model' 'tinystub:1b' $r.model
    Assert-Eq 'R1 ctx'   2048 $r.ctx
}

# the dedupe pin: task 0 printed n_decoded=50 then n_decoded=100 in the same
# file -> ONE sample keeping the first timestamp and the larger progress
$r = Find-One $rt { $_.ts -eq '2026-03-14T10:14:32' } 'R2 lookup (deduped task, first ts kept)'
if ($r) {
    Assert-Eq 'R2 tps (from the larger n_decoded line)' '42.35' $r.tps
    Assert-Eq 'R2 gen (max n_decoded wins)' 100 $r.gen
    Assert-Eq 'R2 model' $shared $r.model
    Assert-Eq 'R2 ctx'   8192 $r.ctx
}

$r = Find-One $rt { $_.ts -eq '2026-03-14T10:15:58' } 'R3 lookup (ts 10:15:58)'
if ($r) {
    Assert-Eq 'R3 tps'   '38.2' $r.tps
    Assert-Eq 'R3 gen'   150 $r.gen
    Assert-Eq 'R3 model' $shared $r.model
}

$r = Find-One $rt { $_.ts -eq '2026-03-14T10:20:31' } 'R4 lookup (ts 10:20:31)'
if ($r) {
    Assert-Eq 'R4 tps'   '55.1' $r.tps
    Assert-Eq 'R4 gen'   50 $r.gen
    Assert-Eq 'R4 model' 'tinystub:1b' $r.model
    Assert-Eq 'R4 ctx'   4096 $r.ctx
}

# ---------------- run 2: re-scan against the existing history ----------------
# Asserted as RAW counts on purpose. collect.ps1's history merge pins
# pwsh-7-revived [datetime] start/ts values back to ISO strings
# (Format-HistTs) before building dedupe keys, so a re-run of the same logs
# must add nothing on either runtime. If that fix regresses, every
# event/rate duplicates and these counts double - this is the assertion
# that catches it.
$data2 = Invoke-Collect $dataset2 'run 2 (existing history, re-scan check)'
Write-Host ""
Assert-Eq 'run 2 raw event count (re-scan adds nothing)' 6 @($data2.events).Count
Assert-Eq 'run 2 raw rate count (re-scan adds nothing)'  4 @($data2.rates).Count
Assert-Eq 'run 2 prompt token total' 707 $data2.promptTokens

# ===================== runtime-adapter sections (issue #4) =====================
# Everything below was APPENDED for the -Source adapters; the 82 assertions
# above are the unchanged gate for the default ollama path. These sections use
# the same helpers and stay hermetic: fixture logs and canned /metrics scrapes,
# with the Endpoint still pointing at a refusing port.

function Invoke-CollectSrc([hashtable]$p, [string]$outFile, [string]$label) {
    Write-Host ""
    Write-Host "--- collect.ps1 $label ---"
    $log = & $collect @p -OutFile $outFile *>&1
    $log | ForEach-Object { Write-Host ("  | {0}" -f $_) }
    if (-not (Test-Path $outFile)) {
        Write-Host "FATAL collect.ps1 wrote no dataset at $outFile"
        exit 1
    }
    try { return (Get-Content $outFile -Raw | ConvertFrom-Json) }
    catch { Write-Host "FATAL $outFile is not valid JSON: $_"; exit 1 }
}

# ---------------- the ollama dataset is untouched by adapter work ----------------
# The new adapters emit a top-level "source" key; the default ollama dataset
# must NOT gain one (or anything else) - its output is pinned byte-for-byte
# minus generatedAt against pre-adapter collect.ps1.
Assert-Eq 'ollama dataset run 1 carries no source key' `
    0 @($data.PSObject.Properties | Where-Object { $_.Name -ceq 'source' }).Count
Assert-Eq 'ollama dataset run 2 carries no source key' `
    0 @($data2.PSObject.Properties | Where-Object { $_.Name -ceq 'source' }).Count

# ---------------- llamacpp: timestamped logs ----------------
# Fixture A: pre-Nov-2025 llama-server behind docker-style per-line ISO stamps,
# with INFO request lines and the old one-call timing block (bare continuation
# rows). Fixture B: current llama-server behind journald short-iso (host and
# unit prefix), no request lines, per-row-prefixed timing block plus periodic
# n_decoded progress rows. Same client addresses as the ollama fixtures, so the
# hashed labels must come out identical (shared anonymiser).
$lcHist1  = Join-Path $tmp 'history.llamacpp-iso.json'
$lcCommon = @{
    Source      = 'llamacpp'
    LogDir      = Join-Path $fixtures (Join-Path 'llamacpp' 'logs-iso')
    MachineFile = Join-Path $fixtures 'machine.fixture.json'
    HistoryFile = $lcHist1
    Endpoint    = 'http://127.0.0.1:9'
}
$lc1 = Invoke-CollectSrc $lcCommon (Join-Path $tmp 'dataset.lc1.json') 'llamacpp run 1 (iso logs, fresh history)'
Write-Host ""

Assert-Eq 'lc: schema'      1          $lc1.schema
Assert-Eq 'lc: source'      'llamacpp' $lc1.source
Assert-Eq 'lc: serverUp (refused endpoint)' 'False' $lc1.serverUp
Assert-Eq 'lc: anonymised'  'True'     $lc1.anonymised
Assert-Eq 'lc: diskBytes null (no blob store)' '' "$($lc1.diskBytes)"
Assert-Eq 'lc: sharedBlobs empty' 0 @($lc1.sharedBlobs).Count
Assert-Eq 'lc: tagDigest empty'   0 @($lc1.tagDigest.PSObject.Properties).Count
Assert-Eq 'lc: models (one per load line)' 'stubchat-7b-q4_k_m,stubcoder-1b' `
    ((@($lc1.models) | ForEach-Object { $_.name }) -join ',')
Assert-Eq 'lc: model sizeBytes null (no manifests)' '' "$((@($lc1.models))[0].sizeBytes)"

# health and props requests must be filtered; the two inference lines kept
$lcEv = @($lc1.events)
Assert-Eq 'lc: event count (non-inference paths filtered)' 2 $lcEv.Count
$e = Find-One $lcEv { $_.path -eq '/v1/chat/completions' } 'lc: E1 lookup (/v1/chat/completions)'
if ($e) {
    Assert-Eq 'lc: E1 start (wrapper timestamp, completion moment)' '2026-04-02T08:01:24' (ConvertTo-IsoSecond $e.start)
    Assert-Eq 'lc: E1 dur is 0 (llama-server logs no duration)' 0 $e.dur
    Assert-Eq 'lc: E1 status' 200 $e.status
    Assert-Eq 'lc: E1 client (same RFC1918 addr, same hash as ollama fixture)' 'lan-0647' $e.client
    Assert-Eq 'lc: E1 model (stamped from load line, path stripped)' 'stubchat-7b-q4_k_m' $e.model
    Assert-Eq 'lc: E1 ctx' 4096 $e.ctx
}
$e = Find-One $lcEv { $_.path -eq '/completion' } 'lc: E2 lookup (/completion 500)'
if ($e) {
    Assert-Eq 'lc: E2 start'  '2026-04-02T08:02:31' (ConvertTo-IsoSecond $e.start)
    Assert-Eq 'lc: E2 status (5xx kept)' 500 $e.status
    Assert-Eq 'lc: E2 client' 'localhost' $e.client
}

# rates: fixture A has only the final eval row; fixture B has two progress rows
# then the final block for the same task -> ONE sample, final figures, first ts
$lcRt = @($lc1.rates)
Assert-Eq 'lc: rate sample count' 2 $lcRt.Count
$r = Find-One $lcRt { $_.model -eq 'stubchat-7b-q4_k_m' } 'lc: R1 lookup (classic eval row)'
if ($r) {
    Assert-Eq 'lc: R1 ts'  '2026-04-02T08:01:24' (ConvertTo-IsoSecond $r.ts)
    Assert-Eq 'lc: R1 tps' '44.9' $r.tps
    Assert-Eq 'lc: R1 gen' 110 $r.gen
    Assert-Eq 'lc: R1 ctx' 4096 $r.ctx
}
$r = Find-One $lcRt { $_.model -eq 'stubcoder-1b' } 'lc: R2 lookup (progress rows folded)'
if ($r) {
    Assert-Eq 'lc: R2 ts (first progress row kept)' '2026-04-02T09:11:09' (ConvertTo-IsoSecond $r.ts)
    Assert-Eq 'lc: R2 tps (final eval row wins)' '51.81' $r.tps
    Assert-Eq 'lc: R2 gen (final count, not interim 250)' 272 $r.gen
    Assert-Eq 'lc: R2 ctx' 8192 $r.ctx
}

# token totals: prompt-eval rows (45 + 64) preferred over the new-prompt line
# (52) for the same task; generation sums the final eval rows
Assert-Eq 'lc: promptTokens (evaluated, prompt-eval preferred)' 109 $lc1.promptTokens
Assert-Eq 'lc: generationTokens (completed tasks)' 382 $lc1.generationTokens
Assert-Eq 'lc: busySeconds (sum of total-time rows)' '8.131' $lc1.busySeconds
Assert-Eq 'lc: busySource' 'task-total-time' $lc1.busySource

# re-scan against the existing history must add nothing (raw counts, same
# Format-HistTs pin the ollama run 2 asserts)
$lc2 = Invoke-CollectSrc $lcCommon (Join-Path $tmp 'dataset.lc2.json') 'llamacpp run 2 (re-scan check)'
Write-Host ""
Assert-Eq 'lc: run 2 raw event count (re-scan adds nothing)' 2 @($lc2.events).Count
Assert-Eq 'lc: run 2 raw rate count (re-scan adds nothing)'  2 @($lc2.rates).Count

# ---------------- llamacpp: logs without wall-clock timestamps ----------------
# A plain `llama-server 2>file` capture: everything still parses, but events
# and rates carry no start/ts and nothing is persisted to history (no stable
# identity across runs), so the dataset is a snapshot and re-runs do not grow.
$lcHist2  = Join-Path $tmp 'history.llamacpp-bare.json'
$lcBare = @{
    Source      = 'llamacpp'
    LogDir      = Join-Path $fixtures (Join-Path 'llamacpp' 'logs-bare')
    MachineFile = Join-Path $fixtures 'machine.fixture.json'
    HistoryFile = $lcHist2
    Endpoint    = 'http://127.0.0.1:9'
}
$lc3 = Invoke-CollectSrc $lcBare (Join-Path $tmp 'dataset.lc3.json') 'llamacpp run 3 (bare logs, no timestamps)'
Write-Host ""
Assert-Eq 'lc bare: event count' 2 @($lc3.events).Count
$e = Find-One @($lc3.events) { $_.client -ceq 'lan-9e58' } 'lc bare: E lookup (CGNAT client, hash matches ollama fixture)'
if ($e) {
    Assert-Eq 'lc bare: E start is empty (no wall clock in log)' '' "$($e.start)"
    Assert-Eq 'lc bare: E path'   '/completion' $e.path
    Assert-Eq 'lc bare: E model'  'stubchat-7b-q4_k_m' $e.model
    Assert-Eq 'lc bare: E ctx'    2048 $e.ctx
}
$r = Find-One @($lc3.rates) { $_.gen -eq 60 } 'lc bare: R lookup'
if ($r) {
    Assert-Eq 'lc bare: R ts is empty' '' "$($r.ts)"
    Assert-Eq 'lc bare: R tps' '60' $r.tps
}
Assert-Eq 'lc bare: promptTokens' 10 $lc3.promptTokens
Assert-Eq 'lc bare: generationTokens' 60 $lc3.generationTokens
Assert-Eq 'lc bare: busySeconds' '1.08' $lc3.busySeconds
Assert-Eq 'lc bare: history file NOT written (nothing identifiable to merge)' 'False' (Test-Path $lcHist2)
$lc4 = Invoke-CollectSrc $lcBare (Join-Path $tmp 'dataset.lc4.json') 'llamacpp run 4 (bare re-run, no growth)'
Write-Host ""
Assert-Eq 'lc bare: re-run event count unchanged' 2 @($lc4.events).Count
Assert-Eq 'lc bare: re-run rate count unchanged'  1 @($lc4.rates).Count

# ---------------- vllm: canned /metrics scrapes ----------------
# v1 engine exposition: two engine labels for one served model (sums must
# aggregate), histogram _bucket and prometheus_client _created series to be
# ignored, non-vllm process metrics, and a labels-but-no-model_name info gauge.
$vmHist1  = Join-Path $tmp 'history.vllm.json'
$vmFix    = Join-Path $fixtures 'vllm'
$vmCommon = @{
    Source      = 'vllm'
    MetricsFile = Join-Path $vmFix 'metrics-v1a.prom'
    MachineFile = Join-Path $fixtures 'machine.fixture.json'
    HistoryFile = $vmHist1
}
$vm1 = Invoke-CollectSrc $vmCommon (Join-Path $tmp 'dataset.vm1.json') 'vllm run 1 (v1 metrics, fresh history)'
Write-Host ""

Assert-Eq 'vm: schema'     1      $vm1.schema
Assert-Eq 'vm: source'     'vllm' $vm1.source
Assert-Eq 'vm: serverUp false for a file scrape' 'False' $vm1.serverUp
Assert-Eq 'vm: anonymised (no client data exists)' 'True' $vm1.anonymised
Assert-Eq 'vm: events empty by design'  0 @($vm1.events).Count
Assert-Eq 'vm: rates empty by design'   0 @($vm1.rates).Count
Assert-Eq 'vm: loadedNow empty (server not live)' 0 @($vm1.loadedNow).Count
Assert-Eq 'vm: model inventory from labels' 'stub-org/StubModel-7B-Instruct' `
    ((@($vm1.models) | ForEach-Object { $_.name }) -join ',')
Assert-Eq 'vm: promptTokens exact (150000 + 50432 across engines)' 200432 $vm1.promptTokens
Assert-Eq 'vm: generationTokens exact (61000 + 19345)' 80345 $vm1.generationTokens
Assert-Eq 'vm: busySeconds (inference sums, engines added)' '4000.25' $vm1.busySeconds
Assert-Eq 'vm: busySource prefers RUNNING-phase time' 'inference' $vm1.busySource

$ag = @($vm1.aggregates.models)
Assert-Eq 'vm: one aggregate model entry' 1 $ag.Count
$a = $ag[0]
Assert-Eq 'vm: agg requests (finished_reason series summed)' 525 $a.requests
Assert-Eq 'vm: agg requests by reason: stop'   500 $a.requestsByReason.stop
Assert-Eq 'vm: agg requests by reason: length' 25  $a.requestsByReason.length
Assert-Eq 'vm: agg promptTokensCached' 15000 $a.promptTokensCached
Assert-Eq 'vm: agg running (gauges summed)' 3 $a.requestsRunning
Assert-Eq 'vm: agg waiting' 1 $a.requestsWaiting
Assert-Eq 'vm: agg e2eSeconds'   '4700.5' $a.e2eSeconds
Assert-Eq 'vm: agg queueSeconds' '700.25' $a.queueSeconds
Assert-Eq 'vm: agg avgE2eSeconds' '8.953' $a.avgE2eSeconds
Assert-Eq 'vm: agg avgTtftSeconds' '0.1' $a.avgTtftSeconds
Assert-Eq 'vm: agg avgTpotSeconds (inter_token_latency)' '0.02' $a.avgTpotSeconds
Assert-Eq 'vm: agg decodeTokPerSec (1/tpot)' '50' $a.decodeTokPerSec
Assert-Eq 'vm: agg kvCacheUsage (engine average)' '0.3' $a.kvCacheUsage
Assert-Eq 'vm: snapshot appended' 1 @($vm1.aggregates.snapshots).Count

# identical counters -> no new snapshot; advanced counters -> one more
$vm2 = Invoke-CollectSrc $vmCommon (Join-Path $tmp 'dataset.vm2.json') 'vllm run 2 (same scrape, no new snapshot)'
Write-Host ""
Assert-Eq 'vm: unchanged counters not re-appended' 1 @($vm2.aggregates.snapshots).Count
$vmCommon.MetricsFile = Join-Path $vmFix 'metrics-v1b.prom'
$vm3 = Invoke-CollectSrc $vmCommon (Join-Path $tmp 'dataset.vm3.json') 'vllm run 3 (advanced counters)'
Write-Host ""
Assert-Eq 'vm: advanced counters append a snapshot' 2 @($vm3.aggregates.snapshots).Count
Assert-Eq 'vm: promptTokens after advance' 210432 $vm3.promptTokens
Assert-Eq 'vm: requests after advance' 575 (@($vm3.aggregates.models))[0].requests

# v0-era names: model_name-only labels, gpu_cache_usage_perc,
# time_per_output_token_seconds, no inference-time histogram -> e2e fallback
$vmHist0 = Join-Path $tmp 'history.vllm-v0.json'
$vmV0 = @{
    Source      = 'vllm'
    MetricsFile = Join-Path $vmFix 'metrics-v0.prom'
    MachineFile = Join-Path $fixtures 'machine.fixture.json'
    HistoryFile = $vmHist0
}
$vm0 = Invoke-CollectSrc $vmV0 (Join-Path $tmp 'dataset.vm0.json') 'vllm run 4 (v0-era metric names)'
Write-Host ""
Assert-Eq 'vm v0: model'  'stub-v0-model' ((@($vm0.models) | ForEach-Object { $_.name }) -join ',')
Assert-Eq 'vm v0: promptTokens' 1234 $vm0.promptTokens
Assert-Eq 'vm v0: generationTokens' 567 $vm0.generationTokens
Assert-Eq 'vm v0: busySource falls back to e2e' 'e2e' $vm0.busySource
Assert-Eq 'vm v0: busySeconds' '88.8' $vm0.busySeconds
$a0 = (@($vm0.aggregates.models))[0]
Assert-Eq 'vm v0: requests' 10 $a0.requests
Assert-Eq 'vm v0: avgTpotSeconds (time_per_output_token fallback)' '0.02' $a0.avgTpotSeconds
Assert-Eq 'vm v0: decodeTokPerSec' '50' $a0.decodeTokPerSec
Assert-Eq 'vm v0: avgTtftSeconds' '0.2' $a0.avgTtftSeconds
Assert-Eq 'vm v0: kvCacheUsage (gpu_cache_usage_perc fallback)' '0.15' $a0.kvCacheUsage
Assert-Eq 'vm v0: running' 1 $a0.requestsRunning
Assert-Eq 'vm v0: waiting' 0 $a0.requestsWaiting

# ---------------- vllm: refuses to clobber an events-shaped history ----------------
$vmGuardHist = Join-Path $tmp 'history.vllm-guard.json'
$guardBody   = '{"events":[],"rates":[]}'
[System.IO.File]::WriteAllText($vmGuardHist, $guardBody, [System.Text.UTF8Encoding]::new($false))
$vmGuardOut = Join-Path $tmp 'dataset.vm-guard.json'
Write-Host ""
Write-Host "--- collect.ps1 vllm guard run (events-shaped history) ---"
$guardLog = & $collect -Source vllm -MetricsFile (Join-Path $vmFix 'metrics-v1a.prom') `
    -MachineFile (Join-Path $fixtures 'machine.fixture.json') `
    -HistoryFile $vmGuardHist -OutFile $vmGuardOut *>&1
$guardLog | ForEach-Object { Write-Host ("  | {0}" -f $_) }
Assert-Eq 'vm guard: dataset NOT written over foreign history' 'False' (Test-Path $vmGuardOut)
Assert-Eq 'vm guard: history left untouched' $guardBody ([System.IO.File]::ReadAllText($vmGuardHist))

# ---------------- summary ----------------
Write-Host ""
if ($script:failed -gt 0) {
    Write-Host ("RESULT: FAILED - {0} of {1} assertions (outputs kept in {2})" -f `
        $script:failed, ($script:failed + $script:passed), $tmp)
    exit 1
}
Remove-Item -Recurse -Force $tmp
Write-Host ("RESULT: PASS - {0} assertions" -f $script:passed)
exit 0
