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
