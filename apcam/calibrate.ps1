# APCAM - calibrate.ps1
#
# Measures this machine's actual GPU power envelope by running one real inference
# while sampling nvidia-smi, then writes machine.json for collect.ps1 to consume.
#
# This is the step that makes the energy figures real rather than guessed. Run it
# once per machine, and again if you change GPU, power limit, or driver.
#
# KEEP THIS FILE PURE ASCII - PowerShell 5.1 reads .ps1 as ANSI without a BOM,
# so any non-ASCII literal is silently corrupted at parse time.
param(
    [string]$OutFile  = "$PSScriptRoot\machine.json",
    [string]$Endpoint = 'http://localhost:11434',
    [string]$Model    = '',          # default: smallest installed model
    [int]   $Predict  = 400,         # tokens to generate
    [int]   $IdleSamples = 8,
    [int]   $SampleMs = 700,
    [double]$SustainedFrac = 0.80    # "sustained" = samples >= this * peak
)
$ErrorActionPreference = 'Continue'

function Get-GpuSample {
    $raw = & nvidia-smi --query-gpu=power.draw,utilization.gpu,memory.used,temperature.gpu `
                        --format=csv,noheader,nounits 2>$null
    if (-not $raw) { return $null }
    $p = ($raw -split ',').Trim()
    [pscustomobject]@{ w=[double]$p[0]; util=[double]$p[1]; vram=[double]$p[2]; temp=[double]$p[3] }
}

function Get-GpuStatic {
    $raw = & nvidia-smi --query-gpu=name,power.limit,memory.total --format=csv,noheader,nounits 2>$null
    if (-not $raw) { return $null }
    $p = ($raw -split ',').Trim()
    [pscustomobject]@{ name=$p[0]; limitW=[double]$p[1]; vramMiB=[double]$p[2] }
}

# ---------------- host facts ----------------
$cpu = $null
try { $cpu = Get-CimInstance Win32_Processor | Select-Object -First 1 } catch { }
$ramGiB = $null
try { $ramGiB = [math]::Round((Get-CimInstance Win32_ComputerSystem).TotalPhysicalMemory / 1GB, 0) } catch { }

$gpuStatic = Get-GpuStatic
$hasNvidia = $null -ne $gpuStatic

$machine = [ordered]@{
    schema        = 1
    calibratedAt  = (Get-Date).ToString('yyyy-MM-ddTHH:mm:ss')
    gpuVendor     = if ($hasNvidia) { 'nvidia' } else { 'unknown' }
    gpuName       = if ($hasNvidia) { $gpuStatic.name } else { $null }
    gpuVramMiB    = if ($hasNvidia) { $gpuStatic.vramMiB } else { $null }
    gpuLimitW     = if ($hasNvidia) { $gpuStatic.limitW } else { $null }
    cpuName       = if ($cpu) { ($cpu.Name -replace '\s+', ' ').Trim() } else { $null }
    cpuCores      = if ($cpu) { [int]$cpu.NumberOfCores } else { $null }
    cpuThreads    = if ($cpu) { [int]$cpu.NumberOfLogicalProcessors } else { $null }
    ramGiB        = $ramGiB
    # measured below
    gpuIdleW      = $null
    gpuActiveW    = $null
    gpuMaxW       = $null
    vramActiveMiB = $null
    tempIdleC     = $null
    tempLoadC     = $null
    refTokensPerSec = $null
    refModel      = $null
    calibSamples  = 0
    # user-supplied estimate; only the GPU can be metered from software
    systemWatts   = 70
    measured      = $false
    note          = ''
}

if (-not $hasNvidia) {
    $machine.note = 'nvidia-smi not found. No GPU power telemetry is available on this ' +
        'machine, so gpuIdleW/gpuActiveW must be filled in by hand (a plug meter is the ' +
        'best source). Everything else still works.'
    $machine | ConvertTo-Json -Depth 4 | Set-Content -Path $OutFile -Encoding utf8
    Write-Warning "nvidia-smi not found - wrote $OutFile with power fields left null."
    Write-Output "Fill in gpuIdleW and gpuActiveW manually, then run collect.ps1."
    return
}

Write-Output ("GPU: {0}  limit {1} W  VRAM {2} MiB" -f $gpuStatic.name, $gpuStatic.limitW, $gpuStatic.vramMiB)

# ---------------- pick a model ----------------
if (-not $Model) {
    try {
        $tags = Invoke-RestMethod -Uri "$Endpoint/api/tags" -TimeoutSec 5
        # smallest generative model loads fastest; skip embedding-only tags
        $cand = $tags.models |
            Where-Object { $_.capabilities -contains 'completion' -or -not $_.capabilities } |
            Sort-Object size | Select-Object -First 1
        if ($cand) { $Model = $cand.name }
    } catch {
        Write-Error "cannot reach Ollama at $Endpoint - is it running?"; return
    }
}
if (-not $Model) { Write-Error "no generative model installed to calibrate against."; return }
Write-Output "calibrating against: $Model"

# ---------------- idle baseline ----------------
Write-Output "sampling idle..."
$idle = @()
for ($i = 0; $i -lt $IdleSamples; $i++) {
    $s = Get-GpuSample; if ($s) { $idle += $s }
    Start-Sleep -Milliseconds 400
}
if (-not $idle.Count) { Write-Error "no GPU samples captured."; return }
$idleW = ($idle | Measure-Object -Property w -Average).Average
$idleT = ($idle | Measure-Object -Property temp -Average).Average
Write-Output ("  idle {0:N2} W at {1:N0} C" -f $idleW, $idleT)

# ---------------- load ----------------
$body = @{
    model  = $Model
    prompt = 'Explain how a B-tree index works, then implement one in Python with insert and search.'
    stream = $false
    options = @{ num_predict = $Predict }
} | ConvertTo-Json -Compress

Write-Output "running inference and sampling under load..."
$job = Start-Job -ScriptBlock {
    param($u, $b)
    try { Invoke-RestMethod -Uri $u -Method Post -Body $b -ContentType 'application/json' -TimeoutSec 600 |
           ConvertTo-Json -Depth 5 -Compress }
    catch { "ERR: $_" }
} -ArgumentList "$Endpoint/api/generate", $body

$load = @()
$t0 = Get-Date
while ($job.State -eq 'Running' -and ((Get-Date) - $t0).TotalSeconds -lt 600) {
    $s = Get-GpuSample; if ($s) { $load += $s }
    Start-Sleep -Milliseconds $SampleMs
}
$res = Receive-Job $job -Wait -AutoRemoveJob

if (-not $load.Count) { Write-Error "no samples captured under load."; return }

$peak = ($load | Measure-Object -Property w -Maximum).Maximum
# Sustained draw is what matters for energy. A whole-run mean is misleading because
# the first seconds are spent loading weights at a fraction of full draw.
$sustained = $load | Where-Object { $_.w -ge $peak * $SustainedFrac }
if (-not $sustained.Count) { $sustained = $load }
$activeW = ($sustained | Measure-Object -Property w -Average).Average
$loadT   = ($load | Measure-Object -Property temp -Maximum).Maximum
$loadV   = ($load | Measure-Object -Property vram -Maximum).Maximum

Write-Output ("  peak {0:N2} W   sustained {1:N2} W over {2} of {3} samples" -f `
    $peak, $activeW, $sustained.Count, $load.Count)

# ---------------- throughput from the response ----------------
$tps = $null
try {
    $j = $res | ConvertFrom-Json
    if ($j.eval_count -and $j.eval_duration) {
        $tps = [math]::Round($j.eval_count / ($j.eval_duration / 1e9), 2)
        Write-Output ("  {0} tokens in {1:N2}s = {2} tok/s" -f $j.eval_count, ($j.eval_duration/1e9), $tps)
    }
} catch { Write-Warning "could not parse inference response for throughput" }

$machine.gpuIdleW        = [math]::Round($idleW, 2)
$machine.gpuActiveW      = [math]::Round($activeW, 2)
$machine.gpuMaxW         = [math]::Round($peak, 2)
$machine.vramActiveMiB   = [int]$loadV
$machine.tempIdleC       = [int][math]::Round($idleT)
$machine.tempLoadC       = [int]$loadT
$machine.refTokensPerSec = $tps
$machine.refModel        = $Model
$machine.calibSamples    = $load.Count
$machine.measured        = $true
$machine.note            = 'gpuIdleW/gpuActiveW measured with nvidia-smi. systemWatts is an ' +
                           'estimate for everything that is not the GPU - adjust it, or use a ' +
                           'plug meter to measure wall draw properly.'

$machine | ConvertTo-Json -Depth 4 | Set-Content -Path $OutFile -Encoding utf8
Write-Output ""
Write-Output "wrote $OutFile"
Write-Output ("envelope: {0} W idle -> {1} W sustained (limit {2} W)" -f `
    $machine.gpuIdleW, $machine.gpuActiveW, $machine.gpuLimitW)
Write-Output "next: .\collect.ps1"
