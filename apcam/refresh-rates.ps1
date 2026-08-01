# APCAM - refresh-rates.ps1
#
# Refreshes the location rate table embedded in dashboard.template.html from
# the EIA open API, so the rate slider's location picker offers current
# figures without the page ever needing network access at view time.
#
#   .\refresh-rates.ps1 -ApiKey $env:EIA_API_KEY
#   .\refresh-rates.ps1 -ApiKey KEY -WhatIf        # show the diff, write nothing
#
# Get a free key at https://www.eia.gov/opendata/register.php
#
# WHAT THESE NUMBERS ARE, AND ARE NOT.
# EIA series ELEC.PRICE / retail-sales, sector RES, is the average revenue per
# kilowatthour across every residential customer in a state - utilities, rate
# plans, and seasons blended together. It is an ESTIMATE offered to seed the
# slider, never a measurement of any particular bill, and the page labels it
# that way. This script must not be extended to present it as anything else.
#
# The page keeps working if this is never run: the table already in the
# template is used as-is, carrying whatever vintage it was last refreshed to.
#
# KEEP THIS FILE PURE ASCII - PowerShell 5.1 reads .ps1 as ANSI without a BOM.
param(
    [Parameter(Mandatory = $true)][string]$ApiKey,
    [string]$Template = (Join-Path $PSScriptRoot 'dashboard.template.html'),
    [switch]$WhatIf   # report what would change, write nothing
)
$ErrorActionPreference = 'Stop'

if (-not (Test-Path $Template)) { throw "missing template: $Template" }

# The 50 states plus DC and the national roll-up, in the order the picker
# shows them: US first, then alphabetical by name (which is also by code here,
# with DC slotted where "District of Columbia" sorts).
$NAMES = [ordered]@{
    US = 'United States average'
    AL = 'Alabama';        AK = 'Alaska';         AZ = 'Arizona'
    AR = 'Arkansas';       CA = 'California';     CO = 'Colorado'
    CT = 'Connecticut';    DE = 'Delaware';       DC = 'District of Columbia'
    FL = 'Florida';        GA = 'Georgia';        HI = 'Hawaii'
    ID = 'Idaho';          IL = 'Illinois';       IN = 'Indiana'
    IA = 'Iowa';           KS = 'Kansas';         KY = 'Kentucky'
    LA = 'Louisiana';      ME = 'Maine';          MD = 'Maryland'
    MA = 'Massachusetts';  MI = 'Michigan';       MN = 'Minnesota'
    MS = 'Mississippi';    MO = 'Missouri';       MT = 'Montana'
    NE = 'Nebraska';       NV = 'Nevada';         NH = 'New Hampshire'
    NJ = 'New Jersey';     NM = 'New Mexico';     NY = 'New York'
    NC = 'North Carolina'; ND = 'North Dakota';   OH = 'Ohio'
    OK = 'Oklahoma';       OR = 'Oregon';         PA = 'Pennsylvania'
    RI = 'Rhode Island';   SC = 'South Carolina'; SD = 'South Dakota'
    TN = 'Tennessee';      TX = 'Texas';          UT = 'Utah'
    VT = 'Vermont';        VA = 'Virginia';       WA = 'Washington'
    WV = 'West Virginia';  WI = 'Wisconsin';      WY = 'Wyoming'
}

# One request for every state's latest monthly residential price. sort=period
# descending with a generous length gets the newest month for all of them;
# states publish on slightly different schedules, so take each one's own
# newest rather than assuming a single common month.
$uri = 'https://api.eia.gov/v2/electricity/retail-sales/data/' +
       '?frequency=monthly&data[0]=price&facets[sectorid][]=RES' +
       '&sort[0][column]=period&sort[0][direction]=desc&offset=0&length=500'

Write-Output 'requesting EIA retail-sales (residential, monthly)...'
try {
    $resp = Invoke-RestMethod -Uri "$uri&api_key=$ApiKey" -Method Get -TimeoutSec 60
} catch {
    throw "EIA request failed: $_"
}

$rows = $resp.response.data
if (-not $rows) { throw 'EIA returned no rows - check the API key and route' }

# newest row wins per state; rows arrive newest-first
$latest = @{}
foreach ($r in $rows) {
    $id = [string]$r.stateid
    if (-not $NAMES.Contains($id)) { continue }
    if ($latest.ContainsKey($id)) { continue }
    if ($null -eq $r.price) { continue }
    $latest[$id] = [pscustomobject]@{
        Price  = [double]$r.price
        Period = [string]$r.period
    }
}

$missing = @($NAMES.Keys | Where-Object { -not $latest.ContainsKey($_) })
if ($missing.Count) {
    # Refuse a partial table rather than silently leaving stale entries beside
    # fresh ones - a mixed-vintage table cannot be labelled honestly.
    throw "EIA response is missing: $($missing -join ', '). Table not written."
}

# The label carries the vintage of the bulk of the data. Where a state lags,
# its own period is still what was used; report the spread so a wide one is
# visible rather than hidden behind a single tidy month.
$periods = @($latest.Values | ForEach-Object { $_.Period } | Sort-Object -Unique)
$newest  = $periods[-1]
$asOf    = [datetime]::ParseExact($newest, 'yyyy-MM', $null).ToString('MMM yyyy')
if ($periods.Count -gt 1) {
    Write-Warning ("states span {0} periods ({1} .. {2}); labelling as {3}" -f `
        $periods.Count, $periods[0], $newest, $asOf)
}

# Rebuild the two literals the page reads. Layout mirrors what is already in
# the template: three entries per line, US on its own.
$lines = New-Object System.Collections.Generic.List[string]
$lines.Add('const LOC_RATES = {')
$lines.Add(('  US: ["{0}", {1:0.0}],' -f $NAMES['US'], $latest['US'].Price))
$rest = @($NAMES.Keys | Where-Object { $_ -ne 'US' })
for ($i = 0; $i -lt $rest.Count; $i += 3) {
    $chunk = @()
    for ($k = $i; $k -lt [Math]::Min($i + 3, $rest.Count); $k++) {
        $c = $rest[$k]
        $chunk += ('{0}: ["{1}", {2:0.0}]' -f $c, $NAMES[$c], $latest[$c].Price)
    }
    $sep = if ($i + 3 -ge $rest.Count) { '' } else { ',' }
    $lines.Add('  ' + ($chunk -join ', ') + $sep)
}
$lines.Add('};')
$table = $lines -join "`n"

$html = [System.IO.File]::ReadAllText($Template)

$asOfPattern = '(?m)^const LOC_ASOF = ".*?";$'
$tablePattern = '(?ms)^const LOC_RATES = \{.*?^\};'
if ($html -notmatch $asOfPattern -or $html -notmatch $tablePattern) {
    throw "could not find LOC_ASOF / LOC_RATES in $Template - has the page been restructured?"
}

# Report every figure that moves, so a refresh is never a silent swap.
$oldBlock = [regex]::Match($html, $tablePattern).Value
$changed = 0
foreach ($c in $NAMES.Keys) {
    $m = [regex]::Match($oldBlock, ('(?<![A-Z]){0}: \["[^"]*", ([0-9.]+)\]' -f $c))
    $was = if ($m.Success) { [double]$m.Groups[1].Value } else { $null }
    $now = [math]::Round($latest[$c].Price, 1)
    if ($null -eq $was) { Write-Output ("  + {0}  ->  {1:0.0}" -f $c, $now); $changed++ }
    elseif ([math]::Abs($was - $now) -ge 0.05) {
        Write-Output ("    {0}  {1:0.0}  ->  {2:0.0}" -f $c, $was, $now); $changed++
    }
}
Write-Output ("{0} of {1} figures change; vintage -> {2}" -f $changed, $NAMES.Count, $asOf)

if ($WhatIf) { Write-Output 'WhatIf: template not written.'; return }

$html = [regex]::Replace($html, $asOfPattern, ('const LOC_ASOF = "{0}";' -f $asOf))
$html = [regex]::Replace($html, $tablePattern, { $table })
[System.IO.File]::WriteAllText($Template, $html, [System.Text.UTF8Encoding]::new($false))

Write-Output "updated $Template"
Write-Output 'rebuild the page to pick it up:  .\build.ps1'
