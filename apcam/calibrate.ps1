# APCAM - calibrate.ps1
#
# Measures this machine's actual GPU power envelope by running one real inference
# while sampling the GPU vendor's own telemetry, then writes machine.json for
# collect.ps1 to consume.
#
# This is the step that makes the energy figures real rather than guessed. Run it
# once per machine, and again if you change GPU, power limit, or driver.
#
# Vendors (-GpuVendor): nvidia is the reference path (nvidia-smi, any OS). amd is
# best-effort via amd-smi/rocm-smi (realistically Linux only). apple reads the GPU
# rail with powermetrics, which only talks to root - run under sudo or this
# degrades to manual entry. none skips telemetry and leaves the power fields for
# you to fill in. Default: apple on macOS, nvidia everywhere else.
#
# When no telemetry is available, this script tries one more thing before
# giving up: detect the GPU model by name alone and, if it is in
# data/gpu-tdp.ps1's curated table, derive a rough envelope from its rated
# TDP. That is the worst rung of APCAM's accuracy ladder - a thermal ceiling
# is not a measured draw - so it is written with powerSource = "spec-estimate"
# and machine.measured stays false; collect.ps1 and the dashboard carry that
# distinction through. Pass -NoSpecEstimate to skip this and keep the old
# fill-in-by-hand behavior.
#
# KEEP THIS FILE PURE ASCII - PowerShell 5.1 reads .ps1 as ANSI without a BOM,
# so any non-ASCII literal is silently corrupted at parse time.
param(
    [string]$OutFile  = (Join-Path $PSScriptRoot 'machine.json'),
    [string]$Endpoint = 'http://localhost:11434',
    [string]$Model    = '',          # default: smallest installed model
    [int]   $Predict  = 400,         # tokens to generate
    [int]   $GpuIndex = 0,           # which GPU to calibrate on a multi-GPU box
    [ValidateSet('auto','nvidia','amd','apple','none')]
    [string]$GpuVendor = 'auto',     # auto = apple on macOS, nvidia elsewhere
    [string]$PlugUrl  = '',          # smart plug local API, e.g. http://192.168.1.60
    [ValidateSet('auto','tasmota','shelly')]
    [string]$PlugType = 'auto',      # auto probes tasmota, then shelly gen2, then gen1
    [int]   $IdleSamples = 8,
    [int]   $SampleMs = 700,
    [double]$SustainedFrac = 0.80,   # "sustained" = samples >= this * peak
    [switch]$NoSpecEstimate          # skip the TDP-based fallback; leave power fields null
)
$ErrorActionPreference = 'Continue'
. (Join-Path $PSScriptRoot 'data/gpu-tdp.ps1')

# ---------------- platform ----------------
# $IsWindows/$IsLinux/$IsMacOS do not exist in Windows PowerShell 5.1 (they read
# as $null there), so test the edition first and only trust them under Core.
$onWindows = ($PSVersionTable.PSEdition -ne 'Core') -or ($IsWindows -eq $true)
$onLinux   = ($IsLinux -eq $true)
$onMacOS   = ($IsMacOS -eq $true)

if ($GpuVendor -eq 'auto') { $GpuVendor = if ($onMacOS) { 'apple' } else { 'nvidia' } }

function Test-Command([string]$name) {
    return [bool](Get-Command $name -ErrorAction SilentlyContinue)
}

# ---------------- vendor telemetry: amd ----------------
# amd-smi and rocm-smi rename and re-nest their JSON fields between ROCm
# releases, so hard-coding one layout would rot. These walk the object and take
# the first property whose name matches - best-effort by design; any failure
# falls back to the manual-entry path.
function Find-JsonValue($node, [string]$nameRe, [int]$depth = 0) {
    if ($null -eq $node -or $depth -gt 4) { return $null }
    if ($node -is [System.Collections.IEnumerable] -and $node -isnot [string]) {
        foreach ($el in $node) {
            $v = Find-JsonValue $el $nameRe ($depth + 1)
            if ($null -ne $v) { return $v }
        }
        return $null
    }
    if ($node -isnot [System.Management.Automation.PSCustomObject]) { return $null }
    foreach ($p in $node.PSObject.Properties) {
        if ($p.Name -match $nameRe) {
            $v = $p.Value
            # amd-smi wraps numbers as { "value": 41, "unit": "W" }
            if ($v -is [System.Management.Automation.PSCustomObject] -and
                ($v.PSObject.Properties.Name -contains 'value')) { $v = $v.value }
            if ($null -ne $v -and "$v" -ne '' -and "$v" -notmatch '^(N/A|null)$') { return $v }
        }
    }
    foreach ($p in $node.PSObject.Properties) {
        $v = Find-JsonValue $p.Value $nameRe ($depth + 1)
        if ($null -ne $v) { return $v }
    }
    return $null
}

function Find-JsonNumber($node, [string]$nameRe) {
    $v = Find-JsonValue $node $nameRe
    if ($null -eq $v) { return $null }
    if ("$v" -match '(-?\d+(\.\d+)?)') { return [double]$Matches[1] }
    return $null
}

function Get-AmdStatic {
    if (Test-Command 'amd-smi') {
        try {
            $j = (& amd-smi static -g $GpuIndex --json 2>$null) -join "`n" | ConvertFrom-Json
            if ($j) {
                $name = Find-JsonValue  $j '(?i)market_name|product_name|device_name'
                $lim  = Find-JsonNumber $j '(?i)max_power|power_cap'
                $vram = Find-JsonNumber $j '(?i)vram.*size|size.*vram'
                if ($name -or ($null -ne $lim)) {
                    return [pscustomobject]@{ name = "$name"; limitW = $lim; vramMiB = $vram }
                }
            }
        } catch { }
    }
    if (Test-Command 'rocm-smi') {
        try {
            $j = (& rocm-smi -d $GpuIndex --showproductname --showmaxpower --showmeminfo vram --json 2>$null) -join "`n" | ConvertFrom-Json
            if ($j) {
                $name  = Find-JsonValue  $j '(?i)card series|card model|card sku'
                $lim   = Find-JsonNumber $j '(?i)max graphics package power'
                $vramB = Find-JsonNumber $j '(?i)vram total memory'
                $vram  = if ($null -ne $vramB) { [math]::Round($vramB / 1MB, 0) } else { $null }
                if ($name -or ($null -ne $lim)) {
                    return [pscustomobject]@{ name = "$name"; limitW = $lim; vramMiB = $vram }
                }
            }
        } catch { }
    }
    return $null
}

function Get-AmdSample {
    if (Test-Command 'amd-smi') {
        try {
            $j = (& amd-smi metric -g $GpuIndex --json 2>$null) -join "`n" | ConvertFrom-Json
            $w = Find-JsonNumber $j '(?i)socket_power|average_socket_power'
            if ($null -ne $w) {
                return [pscustomobject]@{
                    w    = $w
                    util = Find-JsonNumber $j '(?i)gfx_activity|gfx busy'
                    vram = Find-JsonNumber $j '(?i)used_vram|vram_used'
                    temp = Find-JsonNumber $j '(?i)edge|junction|hotspot'
                }
            }
        } catch { }
    }
    if (Test-Command 'rocm-smi') {
        try {
            $j = (& rocm-smi -d $GpuIndex --showpower --showuse --showtemp --showmeminfo vram --json 2>$null) -join "`n" | ConvertFrom-Json
            $w = Find-JsonNumber $j '(?i)package power \(w\)'
            if ($null -ne $w) {
                $vramB = Find-JsonNumber $j '(?i)vram total used'
                return [pscustomobject]@{
                    w    = $w
                    util = Find-JsonNumber $j '(?i)gpu use'
                    vram = if ($null -ne $vramB) { [math]::Round($vramB / 1MB, 0) } else { $null }
                    temp = Find-JsonNumber $j '(?i)temperature.*edge'
                }
            }
        } catch { }
    }
    return $null
}

# ---------------- vendor telemetry: apple ----------------
function Get-AppleStatic {
    # Apple Silicon: the GPU is on-package and shares unified memory, so there
    # is no discrete VRAM figure and no board power limit to read.
    $name = $null
    try { $name = "$(& sysctl -n machdep.cpu.brand_string 2>$null | Select-Object -First 1)".Trim() } catch { }
    if (-not $name) { return $null }
    return [pscustomobject]@{ name = "$name (unified memory)"; limitW = $null; vramMiB = $null }
}

# powermetrics only talks to root. Returns the command prefix to run it with,
# or $null when neither root nor passwordless sudo is available.
function Get-ApplePowerCmd {
    if (-not (Test-Command 'powermetrics')) { return $null }
    $uid = ''
    try { $uid = "$(& id -u 2>$null)".Trim() } catch { }
    if ($uid -eq '0') { return @('powermetrics') }
    try {
        & sudo -n true 2>$null
        if ($LASTEXITCODE -eq 0) { return @('sudo', '-n', 'powermetrics') }
    } catch { }
    return $null
}

# powermetrics --samplers gpu_power prints one "GPU Power: N mW" line per sample.
function ConvertFrom-PowermetricsGpu([string[]]$Lines) {
    $watts = @()
    foreach ($l in $Lines) {
        if ($l -match '^\s*GPU Power:\s*(\d+(\.\d+)?)\s*mW') {
            $watts += [double]$Matches[1] / 1000.0
        }
    }
    return ,$watts
}

function Get-AppleGpuWatts([string[]]$Cmd, [int]$Count, [int]$IntervalMs) {
    $exe    = $Cmd[0]
    $pmArgs = @($Cmd | Select-Object -Skip 1) + @('--samplers', 'gpu_power', '-i', "$IntervalMs", '-n', "$Count")
    $out = @()
    try { $out = @(& $exe @pmArgs 2>$null) } catch { }
    return ConvertFrom-PowermetricsGpu $out
}

# ---------------- wall power via smart plug (optional) ----------------
# Local HTTP only, nothing leaves the LAN: Tasmota (/cm?cmnd=Status 8), Shelly
# Gen2+ (/rpc/Switch.GetStatus) and Gen1 (/status). Returns watts or $null.
function Get-PlugWatts {
    if (-not $PlugUrl) { return $null }
    $u = $PlugUrl.TrimEnd('/')
    if ($PlugType -eq 'auto' -or $PlugType -eq 'tasmota') {
        try {
            $r = Invoke-RestMethod -Uri ($u + '/cm?cmnd=Status%208') -TimeoutSec 3
            $p = $r.StatusSNS.ENERGY.Power
            if ($null -ne $p) { return [double]$p }
        } catch { }
    }
    if ($PlugType -eq 'auto' -or $PlugType -eq 'shelly') {
        try {
            $r = Invoke-RestMethod -Uri ($u + '/rpc/Switch.GetStatus?id=0') -TimeoutSec 3
            if ($null -ne $r.apower) { return [double]$r.apower }
        } catch { }
        try {
            $r = Invoke-RestMethod -Uri ($u + '/status') -TimeoutSec 3
            if ($r.meters -and $null -ne $r.meters[0].power) { return [double]$r.meters[0].power }
        } catch { }
    }
    return $null
}

# ---------------- spec-based estimation fallback ----------------
# Gets a GPU model name with no telemetry query at all - just an OS-level
# device listing. This is deliberately separate from Get-GpuStatic: it exists
# for the case where that returns $null (no nvidia-smi/amd-smi/rocm-smi, or a
# vendor probe that failed), so calibrate.ps1 still knows what card this is.
function Get-GenericGpuName {
    if ($onWindows) {
        try {
            $names = Get-CimInstance Win32_VideoController -ErrorAction Stop |
                Where-Object { $_.Name -and $_.Name -notmatch '(?i)Basic Display|Remote Display|Virtual' } |
                Select-Object -ExpandProperty Name
            if ($names) { return ($names | Select-Object -First 1) }
        } catch { }
    } elseif ($onLinux) {
        if (Test-Command 'lspci') {
            try {
                $lines = & lspci -mm 2>$null | Where-Object { $_ -match '"(VGA compatible controller|3D controller)"' }
                if ($lines) {
                    # lspci -mm quotes each field; the device name is the 4th quoted field.
                    $m = [regex]::Matches(($lines | Select-Object -First 1), '"([^"]*)"')
                    if ($m.Count -ge 4) { return $m[3].Value.Trim('"') }
                }
            } catch { }
        }
    } elseif ($onMacOS) {
        if (Test-Command 'system_profiler') {
            try {
                $out = & system_profiler SPDisplaysDataType 2>$null
                $line = $out | Where-Object { $_ -match 'Chipset Model:\s*(.+)$' } | Select-Object -First 1
                if ($line -match 'Chipset Model:\s*(.+)$') { return $Matches[1].Trim() }
            } catch { }
        }
    }
    return $null
}

# Looks up $gpuName in the curated TDP table and derives a rough idle/active
# wattage envelope from the match. These fractions are this feature's own
# uncalibrated constants (not from any vendor source) - GPU-bound LLM decode
# tends to sit near a card's power limit, with some headroom for boost
# clocks; idle is a small fraction of TDP, with wide slack either side
# because idle behavior varies a lot by driver and board. Returns $null if
# the name does not match any table entry.
function Get-SpecEstimate([string]$gpuName) {
    $row = Find-GpuTdp $gpuName
    if (-not $row) { return $null }
    $ACTIVE_FRAC_LO = 0.75; $ACTIVE_FRAC_MODE = 0.90; $ACTIVE_FRAC_HI = 1.05
    $IDLE_FRAC_LO   = 0.02; $IDLE_FRAC_MODE   = 0.05; $IDLE_FRAC_HI   = 0.10
    return [pscustomobject]@{
        label       = $row.label
        tdpW        = $row.tdpW
        source      = $row.source
        sourceDate  = $row.sourceDate
        idleW       = [math]::Round($row.tdpW * $IDLE_FRAC_MODE, 1)
        idleLoW     = [math]::Round($row.tdpW * $IDLE_FRAC_LO, 1)
        idleHiW     = [math]::Round($row.tdpW * $IDLE_FRAC_HI, 1)
        activeW     = [math]::Round($row.tdpW * $ACTIVE_FRAC_MODE, 1)
        activeLoW   = [math]::Round($row.tdpW * $ACTIVE_FRAC_LO, 1)
        activeHiW   = [math]::Round($row.tdpW * $ACTIVE_FRAC_HI, 1)
    }
}

# ---------------- vendor dispatch ----------------
function Get-GpuStatic {
    switch ($GpuVendor) {
        'nvidia' {
            if (-not (Test-Command 'nvidia-smi')) { return $null }
            $raw = & nvidia-smi -i $GpuIndex --query-gpu=name,power.limit,memory.total --format=csv,noheader,nounits 2>$null
            if (-not $raw) { return $null }
            if ($raw -is [array]) { $raw = $raw[0] }
            $p = ($raw -split ',').Trim()
            return [pscustomobject]@{ name=$p[0]; limitW=[double]$p[1]; vramMiB=[double]$p[2] }
        }
        'amd'   { return Get-AmdStatic }
        'apple' { return Get-AppleStatic }
        default { return $null }
    }
}

function Get-GpuSample {
    switch ($GpuVendor) {
        'nvidia' {
            if (-not (Test-Command 'nvidia-smi')) { return $null }
            $raw = & nvidia-smi -i $GpuIndex --query-gpu=power.draw,utilization.gpu,memory.used,temperature.gpu `
                                --format=csv,noheader,nounits 2>$null
            if (-not $raw) { return $null }
            if ($raw -is [array]) { $raw = $raw[0] }
            $p = ($raw -split ',').Trim()
            return [pscustomobject]@{ w=[double]$p[0]; util=[double]$p[1]; vram=[double]$p[2]; temp=[double]$p[3] }
        }
        'amd'   { return Get-AmdSample }
        default { return $null }   # apple is sampled in batches by Get-AppleGpuWatts
    }
}

# ---------------- host facts ----------------
$cpuName = $null; $cpuCores = $null; $cpuThreads = $null; $ramGiB = $null
if ($onWindows) {
    try {
        $cpu = Get-CimInstance Win32_Processor | Select-Object -First 1
        if ($cpu) {
            $cpuName    = ($cpu.Name -replace '\s+', ' ').Trim()
            $cpuCores   = [int]$cpu.NumberOfCores
            $cpuThreads = [int]$cpu.NumberOfLogicalProcessors
        }
    } catch { }
    try { $ramGiB = [math]::Round((Get-CimInstance Win32_ComputerSystem).TotalPhysicalMemory / 1GB, 0) } catch { }
} elseif ($onLinux) {
    try {
        $physId = ''; $coreIds = @{}; $logical = 0
        foreach ($ln in (Get-Content '/proc/cpuinfo' -ErrorAction Stop)) {
            if     ($ln -match '^processor\s*:')           { $logical++ }
            elseif ($ln -match '^model name\s*:\s*(.+)$')  { if (-not $cpuName) { $cpuName = ($Matches[1] -replace '\s+', ' ').Trim() } }
            elseif ($ln -match '^physical id\s*:\s*(\d+)') { $physId = $Matches[1] }
            elseif ($ln -match '^core id\s*:\s*(\d+)')     { $coreIds["$physId/$($Matches[1])"] = $true }
        }
        if ($logical)      { $cpuThreads = $logical }
        if ($coreIds.Count) { $cpuCores = $coreIds.Count } elseif ($logical) { $cpuCores = $logical }
    } catch { }
    try {
        foreach ($ln in (Get-Content '/proc/meminfo' -ErrorAction Stop)) {
            # MemTotal is in kB; kB / 1MB = GiB
            if ($ln -match '^MemTotal:\s*(\d+)\s*kB') { $ramGiB = [math]::Round([double]$Matches[1] / 1MB, 0); break }
        }
    } catch { }
} elseif ($onMacOS) {
    try { $cpuName = "$(& sysctl -n machdep.cpu.brand_string 2>$null | Select-Object -First 1)".Trim() } catch { }
    try { $cpuCores   = [int]"$(& sysctl -n hw.physicalcpu 2>$null | Select-Object -First 1)" } catch { }
    try { $cpuThreads = [int]"$(& sysctl -n hw.logicalcpu 2>$null | Select-Object -First 1)" } catch { }
    try { $ramGiB = [math]::Round([double]"$(& sysctl -n hw.memsize 2>$null | Select-Object -First 1)" / 1GB, 0) } catch { }
}
if (-not $cpuName) { $cpuName = $null }

# ---------------- probe the chosen vendor ----------------
$gpuStatic  = Get-GpuStatic
$applePower = $null
if ($GpuVendor -eq 'apple' -and $gpuStatic) {
    $applePower = Get-ApplePowerCmd
    if ($applePower) {
        # prove privilege and output format with one sample before committing
        if (-not (Get-AppleGpuWatts $applePower 1 500).Count) { $applePower = $null }
    }
}

$ready = $false
switch ($GpuVendor) {
    'nvidia' { $ready = ($null -ne $gpuStatic) }
    'amd'    { $ready = ($null -ne $gpuStatic) -and ($null -ne (Get-GpuSample)) }
    'apple'  { $ready = ($null -ne $gpuStatic) -and ($null -ne $applePower) }
}

$machine = [ordered]@{
    schema        = 1
    calibratedAt  = (Get-Date).ToString('yyyy-MM-ddTHH:mm:ss')
    gpuVendor     = if ($ready) { $GpuVendor } elseif ($GpuVendor -eq 'nvidia') { 'unknown' } else { $GpuVendor }
    gpuIndex      = $GpuIndex
    gpuName       = if ($gpuStatic) { $gpuStatic.name } else { $null }
    gpuVramMiB    = if ($gpuStatic) { $gpuStatic.vramMiB } else { $null }
    gpuLimitW     = if ($gpuStatic) { $gpuStatic.limitW } else { $null }
    cpuName       = $cpuName
    cpuCores      = $cpuCores
    cpuThreads    = $cpuThreads
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
    # wall power from a smart plug (-PlugUrl), when one was reachable
    wallIdleW     = $null
    wallActiveW   = $null
    # user-supplied estimate; only the GPU can be metered from software
    systemWatts   = 70
    measured      = $false
    # "measured" | "spec-estimate" | "none" - see data/gpu-tdp.ps1 and the
    # dashboard's "Spec-estimated" footer bullet for what each means.
    powerSource   = 'none'
    # populated only when powerSource = "spec-estimate"
    gpuTdpW         = $null
    gpuTdpSource    = $null
    gpuTdpSourceDate = $null
    gpuActiveLoW  = $null
    gpuActiveHiW  = $null
    gpuIdleLoW    = $null
    gpuIdleHiW    = $null
    note          = ''
}

if (-not $ready) {
    $fillIn = 'gpuIdleW/gpuActiveW must be filled in by hand (a plug meter is the best source). Everything else still works.'
    $why = ''
    switch ($GpuVendor) {
        'nvidia' {
            $machine.note = 'nvidia-smi not found. No GPU power telemetry is available on this machine, so ' + $fillIn
            $why = 'nvidia-smi not found'
        }
        'amd' {
            $machine.note = 'amd-smi/rocm-smi not found or returned no power figure. No AMD GPU power ' +
                            'telemetry is available on this machine, so ' + $fillIn
            $why = 'no usable amd-smi/rocm-smi'
        }
        'apple' {
            $machine.note = 'powermetrics needs root, and this run had neither root nor passwordless sudo ' +
                            '(or no "GPU Power" lines came back - Intel Macs do not report them). ' +
                            'Re-run as: sudo pwsh -NoProfile -File calibrate.ps1 - until then ' + $fillIn
            $why = 'powermetrics needs root (re-run under sudo)'
        }
        default {
            $machine.note = '-GpuVendor none: GPU telemetry skipped on request, so ' + $fillIn
            $why = 'GPU telemetry skipped (-GpuVendor none)'
        }
    }

    # No real telemetry - try the TDP-based fallback before giving up and
    # asking for manual entry. This never claims to be a measurement: the
    # dashboard reads powerSource, not gpuIdleW/gpuActiveW alone, to decide
    # what to call these numbers.
    $specEstimated = $false
    if (-not $NoSpecEstimate) {
        $genericName = if ($machine.gpuName) { $machine.gpuName } else { Get-GenericGpuName }
        $spec = if ($genericName) { Get-SpecEstimate $genericName } else { $null }
        if ($spec) {
            if (-not $machine.gpuName) { $machine.gpuName = $genericName }
            $machine.gpuIdleW        = $spec.idleW
            $machine.gpuActiveW      = $spec.activeW
            $machine.gpuIdleLoW      = $spec.idleLoW
            $machine.gpuIdleHiW      = $spec.idleHiW
            $machine.gpuActiveLoW    = $spec.activeLoW
            $machine.gpuActiveHiW    = $spec.activeHiW
            $machine.gpuTdpW         = $spec.tdpW
            $machine.gpuTdpSource    = $spec.source
            $machine.gpuTdpSourceDate = $spec.sourceDate
            $machine.powerSource     = 'spec-estimate'
            $machine.measured        = $false
            $machine.note = "$why. Modeled from $($spec.label)'s rated TDP " +
                "($($spec.tdpW) W, $($spec.source)): idle $($spec.idleLoW)-$($spec.idleHiW) W, " +
                "active $($spec.activeLoW)-$($spec.activeHiW) W. This is not a measurement - it is the " +
                "worst rung of APCAM's accuracy ladder. Run calibrate.ps1 with real GPU telemetry, or a " +
                "plug meter, for a real number. Pass -NoSpecEstimate to skip this and fill in by hand instead."
            $specEstimated = $true
        }
    }

    if (-not $specEstimated) { $machine.powerSource = 'none' }
    $machine | ConvertTo-Json -Depth 4 | Set-Content -Path $OutFile -Encoding utf8
    if ($specEstimated) {
        Write-Warning "$why - modeled gpuIdleW/gpuActiveW from rated TDP instead (powerSource: spec-estimate)."
        Write-Output ("envelope (spec-estimate): {0} W idle -> {1} W active, modeled from {2} ({3} W TDP)" -f `
            $machine.gpuIdleW, $machine.gpuActiveW, $machine.gpuName, $machine.gpuTdpW)
        if ($onWindows) { Write-Output "next: .\collect.ps1" } else { Write-Output "next: pwsh ./collect.ps1" }
    } else {
        Write-Warning "$why - wrote $OutFile with power fields left null."
        Write-Output "Fill in gpuIdleW and gpuActiveW manually, then run collect.ps1."
    }
    return
}

if ($GpuVendor -eq 'nvidia') {
    $gpuCount = @(& nvidia-smi --list-gpus 2>$null).Count
    if ($gpuCount -gt 1) {
        Write-Warning ("{0} GPUs present - calibrating GPU {1} only (pick another with -GpuIndex). " -f $gpuCount, $GpuIndex)
        Write-Warning "If Ollama spreads a model across GPUs, per-GPU watts under-count that inference."
    }
}

if ($null -ne $gpuStatic.limitW -and $null -ne $gpuStatic.vramMiB) {
    Write-Output ("GPU {0}: {1}  limit {2} W  VRAM {3} MiB" -f $GpuIndex, $gpuStatic.name, $gpuStatic.limitW, $gpuStatic.vramMiB)
} else {
    Write-Output ("GPU: {0}  (power source: {1})" -f $gpuStatic.name, $GpuVendor)
}

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
$plugOk   = [bool]$PlugUrl
$wallIdle = @(); $wallLoad = @()
$idle = @()
if ($GpuVendor -eq 'apple') {
    foreach ($w in (Get-AppleGpuWatts $applePower $IdleSamples 1000)) {
        $idle += [pscustomobject]@{ w = $w; util = $null; vram = $null; temp = $null }
    }
    for ($i = 0; $i -lt 4 -and $plugOk; $i++) {
        $pw = Get-PlugWatts
        if ($null -ne $pw) { $wallIdle += $pw; Start-Sleep -Milliseconds 250 } else { $plugOk = $false }
    }
} else {
    for ($i = 0; $i -lt $IdleSamples; $i++) {
        $s = Get-GpuSample; if ($s) { $idle += $s }
        if ($plugOk) {
            $pw = Get-PlugWatts
            if ($null -ne $pw) { $wallIdle += $pw } else { $plugOk = $false }
        }
        Start-Sleep -Milliseconds 400
    }
}
if (-not $idle.Count) { Write-Error "no GPU samples captured."; return }
$idleW = ($idle | Measure-Object -Property w -Average).Average
$idleTemps = @($idle | Where-Object { $null -ne $_.temp })
$idleT = if ($idleTemps.Count) { ($idleTemps | Measure-Object -Property temp -Average).Average } else { $null }
if ($null -ne $idleT) { Write-Output ("  idle {0:N2} W at {1:N0} C" -f $idleW, $idleT) }
else                  { Write-Output ("  idle {0:N2} W" -f $idleW) }

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
if ($GpuVendor -eq 'apple') {
    # powermetrics blocks for the whole batch, so take small batches and re-check
    # the job between them; trailing idle samples fall out of the sustained set.
    while ($job.State -eq 'Running' -and ((Get-Date) - $t0).TotalSeconds -lt 600) {
        $batch = Get-AppleGpuWatts $applePower 3 $SampleMs
        foreach ($w in $batch) {
            $load += [pscustomobject]@{ w = $w; util = $null; vram = $null; temp = $null }
        }
        if ($plugOk) {
            $pw = Get-PlugWatts
            if ($null -ne $pw) { $wallLoad += $pw } else { $plugOk = $false }
        }
        # an empty batch means powermetrics failed mid-run; do not spin hot on it
        if (-not $batch.Count) { Start-Sleep -Milliseconds $SampleMs }
    }
} else {
    while ($job.State -eq 'Running' -and ((Get-Date) - $t0).TotalSeconds -lt 600) {
        $s = Get-GpuSample; if ($s) { $load += $s }
        if ($plugOk) {
            $pw = Get-PlugWatts
            if ($null -ne $pw) { $wallLoad += $pw } else { $plugOk = $false }
        }
        Start-Sleep -Milliseconds $SampleMs
    }
}
$res = Receive-Job $job -Wait -AutoRemoveJob

if (-not $load.Count) { Write-Error "no samples captured under load."; return }

$peak = ($load | Measure-Object -Property w -Maximum).Maximum
# Sustained draw is what matters for energy. A whole-run mean is misleading because
# the first seconds are spent loading weights at a fraction of full draw.
$sustained = $load | Where-Object { $_.w -ge $peak * $SustainedFrac }
if (-not $sustained.Count) { $sustained = $load }
$activeW = ($sustained | Measure-Object -Property w -Average).Average
$loadTemps = @($load | Where-Object { $null -ne $_.temp })
$loadT = if ($loadTemps.Count) { ($loadTemps | Measure-Object -Property temp -Maximum).Maximum } else { $null }
$loadVrams = @($load | Where-Object { $null -ne $_.vram })
$loadV = if ($loadVrams.Count) { ($loadVrams | Measure-Object -Property vram -Maximum).Maximum } else { $null }

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
$machine.vramActiveMiB   = if ($null -ne $loadV) { [int]$loadV } else { $null }
$machine.tempIdleC       = if ($null -ne $idleT) { [int][math]::Round($idleT) } else { $null }
$machine.tempLoadC       = if ($null -ne $loadT) { [int]$loadT } else { $null }
$machine.refTokensPerSec = $tps
$machine.refModel        = $Model
$machine.calibSamples    = $load.Count
if ($wallIdle.Count) { $machine.wallIdleW   = [math]::Round(($wallIdle | Measure-Object -Average).Average, 1) }
if ($wallLoad.Count) { $machine.wallActiveW = [math]::Round(($wallLoad | Measure-Object -Average).Average, 1) }
if ($PlugUrl -and -not $plugOk) {
    Write-Warning "smart plug at $PlugUrl unreachable or reports no power - wall figures skipped."
}
$machine.measured        = $true
$machine.powerSource     = 'measured'
$telemetryMethod = 'nvidia-smi'
if ($GpuVendor -eq 'amd')       { $telemetryMethod = 'amd-smi/rocm-smi' }
elseif ($GpuVendor -eq 'apple') { $telemetryMethod = 'powermetrics (Apple GPU rail; CPU and ANE draw excluded)' }
$machine.note            = "gpuIdleW/gpuActiveW measured with $telemetryMethod. systemWatts is an " +
                           'estimate for everything that is not the GPU - adjust it, or use a ' +
                           'plug meter to measure wall draw properly.'

$machine | ConvertTo-Json -Depth 4 | Set-Content -Path $OutFile -Encoding utf8
Write-Output ""
Write-Output "wrote $OutFile"
if ($null -ne $machine.gpuLimitW) {
    Write-Output ("envelope: {0} W idle -> {1} W sustained (limit {2} W)" -f `
        $machine.gpuIdleW, $machine.gpuActiveW, $machine.gpuLimitW)
} else {
    Write-Output ("envelope: {0} W idle -> {1} W sustained" -f $machine.gpuIdleW, $machine.gpuActiveW)
}
if ($null -ne $machine.wallIdleW -or $null -ne $machine.wallActiveW) {
    Write-Output ("wall:     {0} W idle -> {1} W active (smart plug at {2})" -f `
        $machine.wallIdleW, $machine.wallActiveW, $PlugUrl)
}
if ($onWindows) { Write-Output "next: .\collect.ps1" } else { Write-Output "next: pwsh ./collect.ps1" }
