# APCAM - build.ps1
#
# Injects dataset.json into the dashboard template and writes a standalone page.
# Pure string substitution; run collect.ps1 first to refresh the data.
#
# One -Dataset path embeds that dataset exactly as before. Several paths - an
# array, comma-separated, or both - embed a multi-machine wrapper
# {"schema":1,"multi":true,"machines":[...]} that the page renders with a
# machine picker and a combined totals strip. Each element is one machine's
# full dataset, injected verbatim (never re-serialized).
#
# KEEP THIS FILE PURE ASCII - PowerShell 5.1 reads .ps1 as ANSI without a BOM.
param(
    [string]$Template  = (Join-Path $PSScriptRoot 'dashboard.template.html'),
    [string[]]$Dataset = @(Join-Path $PSScriptRoot 'dataset.json'),
    [string]$OutFile   = (Join-Path $PSScriptRoot 'dashboard.html'),
    [switch]$Open     # open the finished page in the default browser
)
$ErrorActionPreference = 'Stop'

# Accept -Dataset a.json,b.json (array binding) and -Dataset "a.json,b.json"
# (one string) alike. Consequence: a literal comma inside a dataset path needs
# the array form with the comma-free part quoted separately - not worth more
# machinery for a character that is pathological in a filename anyway.
$paths = @($Dataset | ForEach-Object { "$_" -split ',' } |
           ForEach-Object { $_.Trim() } | Where-Object { $_ })
if (-not $paths.Count) { throw 'no dataset path given' }

foreach ($f in (@($Template) + $paths)) {
    if (-not (Test-Path $f)) {
        throw "missing required input: $f$(if ($f -ne $Template) { ' - run .\collect.ps1 first' })"
    }
}

$html = [System.IO.File]::ReadAllText($Template)

# fail loudly rather than publish a page built on unreadable data
$jsons  = @()
$probes = @()
foreach ($f in $paths) {
    $j = ([System.IO.File]::ReadAllText($f)).Trim()
    try { $probes += , ($j | ConvertFrom-Json) } catch { throw "$f is not valid JSON: $_" }
    $jsons += , $j
}

$multi = $paths.Count -gt 1
$json  = if ($multi) { '{"schema":1,"multi":true,"machines":[' + ($jsons -join ',') + ']}' }
         else        { $jsons[0] }

$startTag = '/*BEGIN_DATA*/'
$endTag   = '/*END_DATA*/'
$i = $html.IndexOf($startTag)
$j = $html.IndexOf($endTag)
if ($i -lt 0 -or $j -lt 0 -or $j -lt $i) { throw "injection markers not found in $Template" }

$out = $html.Substring(0, $i + $startTag.Length) + $json + $html.Substring($j)
[System.IO.File]::WriteAllText($OutFile, $out, [System.Text.UTF8Encoding]::new($false))

Write-Output "wrote $OutFile"
if (-not $multi) {
    $probe = $probes[0]
    $ev  = if ($probe.events) { $probe.events.Count } else { 0 }
    $rt  = if ($probe.rates)  { $probe.rates.Count }  else { 0 }
    $sec = if ($ev) { ($probe.events | Measure-Object -Property dur -Sum).Sum } else { 0 }

    Write-Output ("embedded {0} events, {1} rate samples, {2:N0}s active, captured {3}" -f `
        $ev, $rt, $sec, $probe.generatedAt)
    if (-not $ev) {
        Write-Warning "dataset has no events - the page will render its empty state."
    }
    if ($probe.anonymised -eq $false) {
        Write-Warning "this dataset holds RAW client addresses (-KeepRawClients was used). Do not share the page."
    }
} else {
    $totEv = 0; $totRt = 0; $totSec = 0.0
    for ($k = 0; $k -lt $paths.Count; $k++) {
        $probe = $probes[$k]
        $ev  = if ($probe.events) { $probe.events.Count } else { 0 }
        $rt  = if ($probe.rates)  { $probe.rates.Count }  else { 0 }
        $sec = if ($ev) { ($probe.events | Measure-Object -Property dur -Sum).Sum } else { 0 }
        $totEv += $ev; $totRt += $rt; $totSec += $sec
        Write-Output ("  {0}: {1} events, {2} rate samples, {3:N0}s active, captured {4}" -f `
            $paths[$k], $ev, $rt, $sec, $probe.generatedAt)
        if (-not $ev) {
            Write-Warning "$($paths[$k]) has no events - its page will render the empty state."
        }
        if ($probe.anonymised -eq $false) {
            Write-Warning "$($paths[$k]) holds RAW client addresses (-KeepRawClients was used). Do not share the page."
        }
    }
    Write-Output ("embedded {0} machines: {1} events, {2} rate samples, {3:N0}s active in total" -f `
        $paths.Count, $totEv, $totRt, $totSec)
}

Write-Output "open it:  .\build.ps1 -Open      or just double-click $OutFile"
if ($Open) { Start-Process $OutFile }
