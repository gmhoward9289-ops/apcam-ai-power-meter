# APCAM - build.ps1
#
# Injects dataset.json into the dashboard template and writes a standalone page.
# Pure string substitution; run collect.ps1 first to refresh the data.
#
# KEEP THIS FILE PURE ASCII - PowerShell 5.1 reads .ps1 as ANSI without a BOM.
param(
    [string]$Template = (Join-Path $PSScriptRoot 'dashboard.template.html'),
    [string]$Dataset  = (Join-Path $PSScriptRoot 'dataset.json'),
    [string]$OutFile  = (Join-Path $PSScriptRoot 'dashboard.html'),
    [switch]$Open     # open the finished page in the default browser
)
$ErrorActionPreference = 'Stop'

foreach ($f in @($Template, $Dataset)) {
    if (-not (Test-Path $f)) {
        throw "missing required input: $f$(if ($f -eq $Dataset) { ' - run .\collect.ps1 first' })"
    }
}

$html = [System.IO.File]::ReadAllText($Template)
$json = ([System.IO.File]::ReadAllText($Dataset)).Trim()

# fail loudly rather than publish a page built on unreadable data
try { $probe = $json | ConvertFrom-Json } catch { throw "dataset.json is not valid JSON: $_" }

$startTag = '/*BEGIN_DATA*/'
$endTag   = '/*END_DATA*/'
$i = $html.IndexOf($startTag)
$j = $html.IndexOf($endTag)
if ($i -lt 0 -or $j -lt 0 -or $j -lt $i) { throw "injection markers not found in $Template" }

$out = $html.Substring(0, $i + $startTag.Length) + $json + $html.Substring($j)
[System.IO.File]::WriteAllText($OutFile, $out, [System.Text.UTF8Encoding]::new($false))

$ev  = if ($probe.events) { $probe.events.Count } else { 0 }
$rt  = if ($probe.rates)  { $probe.rates.Count }  else { 0 }
$sec = if ($ev) { ($probe.events | Measure-Object -Property dur -Sum).Sum } else { 0 }

Write-Output "wrote $OutFile"
Write-Output ("embedded {0} events, {1} rate samples, {2:N0}s active, captured {3}" -f `
    $ev, $rt, $sec, $probe.generatedAt)
if (-not $ev) {
    Write-Warning "dataset has no events - the page will render its empty state."
}
if ($probe.anonymised -eq $false) {
    Write-Warning "this dataset holds RAW client addresses (-KeepRawClients was used). Do not share the page."
}

Write-Output "open it:  .\build.ps1 -Open      or just double-click $OutFile"
if ($Open) { Start-Process $OutFile }
