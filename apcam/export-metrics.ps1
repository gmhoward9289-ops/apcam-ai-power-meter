# APCAM - export-metrics.ps1
#
# Reads dataset.json (and optionally history.json) and writes a Prometheus
# textfile-collector .prom file, so node_exporter / windows_exporter can ship
# APCAM's numbers to Grafana or Home Assistant. Point the exporter's
# --collector.textfile.directory at the output folder and schedule this script
# to run after collect.ps1.
#
#   .\export-metrics.ps1 -OutFile C:\textfile_collector\apcam.prom
#   .\export-metrics.ps1 -Dataset .\dataset.json -History .\history.json `
#                        -OutFile .\apcam.prom -SystemWatts 90 -Validate
#
# Counters are cumulative because dataset.json already carries the full merged
# history of events (collect.ps1 appends, never truncates); passing -History
# additionally unions history.json's events in case the dataset was rebuilt
# from partial logs. apcam_prompt_tokens_total is the one exception: Ollama's
# logs only support a per-scan figure, so it can reset - Prometheus's rate()
# and increase() handle counter resets by design.
#
# The write is atomic (temp file in the same directory, then rename) because
# textfile collectors read the directory on their own schedule and must never
# see a half-written file.
#
# -Validate re-reads the emitted file and checks Prometheus exposition-format
# shape line by line, dependency-free - no promtool assumed.
#
# KEEP THIS FILE PURE ASCII - PowerShell 5.1 reads .ps1 as ANSI without a BOM.
param(
    [string]$Dataset = (Join-Path $PSScriptRoot 'dataset.json'),
    [string]$History = '',
    [string]$OutFile = '',
    [double]$SystemWatts = -1,   # negative = use the dataset's machine.systemWatts
    [switch]$Validate
)
$ErrorActionPreference = 'Stop'
$inv = [System.Globalization.CultureInfo]::InvariantCulture

if (-not $OutFile) {
    throw '-OutFile is required, e.g.  .\export-metrics.ps1 -OutFile C:\textfile_collector\apcam.prom'
}
if (-not (Test-Path -LiteralPath $Dataset)) { throw "missing dataset: $Dataset - run .\collect.ps1 first" }
try { $ds = (Get-Content -LiteralPath $Dataset -Raw) | ConvertFrom-Json }
catch { throw "$Dataset is not valid JSON: $_" }

function Get-Prop($obj, [string]$name, $default) {
    if ($null -ne $obj -and $obj.PSObject.Properties.Name -contains $name -and $null -ne $obj.$name) {
        return $obj.$name
    }
    return $default
}
# pwsh 7's ConvertFrom-Json revives ISO date strings as [datetime]; 5.1 keeps
# strings. Pin to the ISO form so dedupe keys match across editions.
function Format-IsoTs($v) {
    if ($v -is [datetime]) { return $v.ToString('yyyy-MM-ddTHH:mm:ss') }
    return "$v"
}
# Prometheus label values escape backslash, double quote and newline.
function Format-LabelValue([string]$s) {
    if ($null -eq $s) { $s = '' }
    return $s.Replace('\', '\\').Replace('"', '\"').Replace("`r`n", '\n').Replace("`n", '\n').Replace("`r", '\n')
}
function Format-MetricValue($v) {
    if ($v -is [double] -or $v -is [single] -or $v -is [decimal]) {
        return ([double]$v).ToString('0.######', $inv)
    }
    return "$v"
}

# ---------------- events: dataset, optionally unioned with history ----------------
$events = @(Get-Prop $ds 'events' @())
$source = Split-Path -Leaf $Dataset
if ($History) {
    if (-not (Test-Path -LiteralPath $History)) { throw "missing history file: $History" }
    try { $hist = (Get-Content -LiteralPath $History -Raw) | ConvertFrom-Json }
    catch { throw "$History is not valid JSON: $_" }
    $seen  = @{}
    $union = New-Object System.Collections.ArrayList
    foreach ($e in ($events + @(Get-Prop $hist 'events' @()))) {
        if ($null -eq $e) { continue }
        $e.start = Format-IsoTs $e.start
        # same dedupe key collect.ps1 uses for its history merge
        $k = "$($e.start)|$($e.path)|$($e.client)|$($e.dur)"
        if (-not $seen.ContainsKey($k)) { $seen[$k] = $true; [void]$union.Add($e) }
    }
    $events = @($union)
    $source = $source + '+' + (Split-Path -Leaf $History)
}

# ---------------- aggregate ----------------
$mach = Get-Prop $ds 'machine' $null
$gpuActiveW = [double](Get-Prop $mach 'gpuActiveW' 0)
if ($gpuActiveW -le 0) {
    Write-Warning "machine.gpuActiveW is missing or zero - energy figures will be system-draw only."
}
$sysW = if ($SystemWatts -ge 0) { $SystemWatts } else { [double](Get-Prop $mach 'systemWatts' 70) }
$activeW = $gpuActiveW + $sysW

$US = [string][char]31   # composite-key separator; cannot occur in a label value
$reqBy = @{}
$secBy = @{}
foreach ($e in $events) {
    $m = "$(Get-Prop $e 'model' '')"
    if ($m -eq '') { $m = 'unattributed' }
    $cls = '{0}xx' -f [math]::Floor([int](Get-Prop $e 'status' 0) / 100)
    $cli = "$(Get-Prop $e 'client' 'unknown')"
    $k = $m + $US + $cls + $US + $cli
    if (-not $reqBy.ContainsKey($k)) { $reqBy[$k] = 0 }
    $reqBy[$k] = $reqBy[$k] + 1
    if (-not $secBy.ContainsKey($m)) { $secBy[$m] = 0.0 }
    $secBy[$m] = $secBy[$m] + [double](Get-Prop $e 'dur' 0)
}
$totSec = 0.0
foreach ($v in $secBy.Values) { $totSec += $v }
$totWh = $totSec * $activeW / 3600

# ---------------- emit ----------------
$L = New-Object System.Collections.ArrayList
function Add-Line([string]$s) { [void]$script:L.Add($s) }

$gpuName = "$(Get-Prop $mach 'gpuName' 'unknown')"
Add-Line '# HELP apcam_info Static labels for this APCAM export: GPU and data source.'
Add-Line '# TYPE apcam_info gauge'
Add-Line ('apcam_info{gpu="' + (Format-LabelValue $gpuName) + '",source="' + (Format-LabelValue $source) + '"} 1')

Add-Line '# HELP apcam_requests_total Completed inference requests parsed from Ollama server logs.'
Add-Line '# TYPE apcam_requests_total counter'
foreach ($k in ($reqBy.Keys | Sort-Object)) {
    $p = $k.Split([char]31)
    Add-Line ('apcam_requests_total{model="' + (Format-LabelValue $p[0]) +
              '",status_class="' + (Format-LabelValue $p[1]) +
              '",client="' + (Format-LabelValue $p[2]) + '"} ' + (Format-MetricValue $reqBy[$k]))
}

Add-Line '# HELP apcam_active_seconds_total GPU-active seconds summed over requests, by model.'
Add-Line '# TYPE apcam_active_seconds_total counter'
foreach ($m in ($secBy.Keys | Sort-Object)) {
    Add-Line ('apcam_active_seconds_total{model="' + (Format-LabelValue $m) + '"} ' +
              (Format-MetricValue ([double]$secBy[$m])))
}

Add-Line ('# HELP apcam_energy_wh_total Energy in watt-hours by model, at the measured ' +
          'gpuActiveW plus the system draw (' + (Format-MetricValue $activeW) + ' W total for this export).')
Add-Line '# TYPE apcam_energy_wh_total counter'
foreach ($m in ($secBy.Keys | Sort-Object)) {
    Add-Line ('apcam_energy_wh_total{model="' + (Format-LabelValue $m) + '"} ' +
              (Format-MetricValue ([double]$secBy[$m] * $activeW / 3600)))
}

Add-Line '# HELP apcam_prompt_tokens_total Prompt tokens seen in the last collect run. May reset between runs.'
Add-Line '# TYPE apcam_prompt_tokens_total counter'
Add-Line ('apcam_prompt_tokens_total ' + (Format-MetricValue ([long](Get-Prop $ds 'promptTokens' 0))))

Add-Line ('# HELP apcam_disk_bytes Model storage: scope="store" is the deduplicated blob store; ' +
          'scope="tag" is each tag''s reported size (shared blobs double-count).')
Add-Line '# TYPE apcam_disk_bytes gauge'
Add-Line ('apcam_disk_bytes{scope="store"} ' + (Format-MetricValue ([long](Get-Prop $ds 'diskBytes' 0))))
foreach ($mo in (@(Get-Prop $ds 'models' @()) | Sort-Object -Property name)) {
    Add-Line ('apcam_disk_bytes{scope="tag",model="' + (Format-LabelValue "$($mo.name)") + '"} ' +
              (Format-MetricValue ([long](Get-Prop $mo 'sizeBytes' 0))))
}

$gpuNow = Get-Prop $ds 'gpuNow' $null
if ($null -ne $gpuNow -and $null -ne (Get-Prop $gpuNow 'w' $null)) {
    Add-Line '# HELP apcam_gpu_watts GPU power draw at dataset capture time.'
    Add-Line '# TYPE apcam_gpu_watts gauge'
    Add-Line ('apcam_gpu_watts ' + (Format-MetricValue ([double]$gpuNow.w)))
}

$text = ($L -join "`n") + "`n"

# ---------------- atomic write: temp in the same directory, then rename ----------------
if (-not [System.IO.Path]::IsPathRooted($OutFile)) {
    $OutFile = Join-Path (Get-Location).Path $OutFile
}
$outDir = Split-Path -Parent $OutFile
if ($outDir -and -not (Test-Path -LiteralPath $outDir)) {
    New-Item -ItemType Directory -Force -Path $outDir | Out-Null
}
$tmp = $OutFile + '.tmp' + $PID
[System.IO.File]::WriteAllText($tmp, $text, [System.Text.UTF8Encoding]::new($false))
try {
    if (Test-Path -LiteralPath $OutFile) {
        try { [System.IO.File]::Replace($tmp, $OutFile, $null) }
        catch { Move-Item -LiteralPath $tmp -Destination $OutFile -Force }  # non-NTFS fallback
    } else {
        Move-Item -LiteralPath $tmp -Destination $OutFile -Force
    }
} finally {
    if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp -Force -EA SilentlyContinue }
}

$sampleCount = 0
foreach ($ln in $L) { if (-not $ln.StartsWith('#')) { $sampleCount++ } }
Write-Output "wrote $OutFile"
Write-Output ("{0} samples, {1} events across {2} models, source {3}" -f `
    $sampleCount, $events.Count, $secBy.Count, $source)
Write-Output ("active {0}s -> {1} Wh at {2} W ({3} W GPU + {4} W system)" -f `
    (Format-MetricValue $totSec), (Format-MetricValue $totWh), (Format-MetricValue $activeW), `
    (Format-MetricValue $gpuActiveW), (Format-MetricValue $sysW))

# ---------------- self-check: exposition-format shape, line by line ----------------
if ($Validate) {
    $nameRe   = '[a-zA-Z_:][a-zA-Z0-9_:]*'
    $lblRe    = '[a-zA-Z_][a-zA-Z0-9_]*="(?:[^"\\]|\\\\|\\"|\\n)*"'
    $numRe    = '(?:[-+]?[0-9]+(?:\.[0-9]+)?(?:[eE][-+]?[0-9]+)?|[-+]?Inf|NaN)'
    $helpRe   = '^# HELP (' + $nameRe + ') \S.*$'
    $typeRe   = '^# TYPE (' + $nameRe + ') (counter|gauge|histogram|summary|untyped)$'
    $sampleRe = '^(' + $nameRe + ')(?:\{(?:' + $lblRe + ')(?:,' + $lblRe + ')*\})?[ ](' + $numRe + ')$'
    $vErr = @(); $typeOf = @{}; $helpSeen = @{}; $samples = 0; $n = 0
    foreach ($line in [System.IO.File]::ReadAllLines($OutFile)) {
        $n++
        if ($line -eq '') { continue }
        if ($line -match $helpRe) {
            if ($helpSeen.ContainsKey($Matches[1])) { $vErr += "line ${n}: duplicate HELP for $($Matches[1])" }
            $helpSeen[$Matches[1]] = $true
            continue
        }
        if ($line -match $typeRe) {
            if ($typeOf.ContainsKey($Matches[1])) { $vErr += "line ${n}: duplicate TYPE for $($Matches[1])" }
            $typeOf[$Matches[1]] = $Matches[2]
            continue
        }
        if ($line.StartsWith('#')) { $vErr += "line ${n}: malformed comment line: $line"; continue }
        if ($line -match $sampleRe) {
            $mn = $Matches[1]; $val = $Matches[2]
            if (-not $typeOf.ContainsKey($mn)) {
                $vErr += "line ${n}: sample for '$mn' with no preceding TYPE line"
            } elseif ($typeOf[$mn] -eq 'counter') {
                if ($mn -notmatch '_total$') { $vErr += "line ${n}: counter '$mn' does not end in _total" }
                $d = 0.0
                if (-not [double]::TryParse($val, [System.Globalization.NumberStyles]::Float, $inv, [ref]$d) -or $d -lt 0) {
                    $vErr += "line ${n}: counter '$mn' value '$val' is not a finite non-negative number"
                }
            }
            $samples++
            continue
        }
        $vErr += "line ${n}: not a valid exposition line: $line"
    }
    foreach ($mn in $typeOf.Keys)   { if (-not $helpSeen.ContainsKey($mn)) { $vErr += "TYPE without HELP: $mn" } }
    foreach ($mn in $helpSeen.Keys) { if (-not $typeOf.ContainsKey($mn))   { $vErr += "HELP without TYPE: $mn" } }
    if ($vErr.Count) {
        foreach ($e in $vErr) { Write-Warning $e }
        throw "validate: $($vErr.Count) problem(s) in $OutFile"
    }
    Write-Output "validate: OK - $samples samples, $($typeOf.Count) metrics, $n lines, exposition shape holds"
}
