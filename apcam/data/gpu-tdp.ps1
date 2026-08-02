# APCAM - data/gpu-tdp.ps1
#
# A small, curated table of GPU model -> rated TDP (thermal design power, in
# watts), used by calibrate.ps1's spec-based estimation fallback when no real
# power telemetry is available on this machine (no nvidia-smi/amd-smi/
# rocm-smi/powermetrics, and no smart plug).
#
# WHAT THIS TABLE IS, AND IS NOT.
# TDP is a thermal ceiling the vendor guarantees the cooler can dissipate, not
# a measured or even typical draw during inference. It is the worst rung of
# APCAM's accuracy ladder - below both nvidia-smi sampling and a wall-plug
# meter - and calibrate.ps1 labels every figure derived from it as
# "spec-estimate", never as measured. See the "Spec-estimated" bullet in
# dashboard.template.html's footer legend for how this shows up on the page.
#
# Every entry MUST cite where its number came from (source + sourceDate). Do
# not add an entry you cannot cite. Do not widen `pattern` to catch a model
# family you have not actually looked up - an unmatched GPU falls through to
# the existing manual-entry path (calibrate.ps1 already handles that), which
# is more honest than a guess across model families.
#
# Provenance of this initial table: NVIDIA/AMD TGP/TDP figures are the
# vendor's own published spec-sheet numbers (these are stable once a SKU
# ships - they do not change after launch), compiled from general knowledge
# and spot-checked against NVIDIA/AMD/TechPowerUp listings for the RTX 2060
# SUPER, RTX 4090 and RX 7900 XTX entries on 2026-08-01. The remaining
# entries were not individually re-verified via a live source in that pass -
# if you find one wrong, a corrected citation is a welcome one-line PR. The
# Apple entries are explicitly the weakest tier here (see note below) and
# should be treated with the most skepticism.
#
# This is one person's tool (see CONTRIBUTING.md) and this table reflects
# that: it covers common consumer/prosumer cards, not an exhaustive catalog.
# Sending a calibration data point per CONTRIBUTING.md item 2 is more useful
# than a TDP entry; sending a TDP entry with a citation is still welcome.
#
# KEEP THIS FILE PURE ASCII - PowerShell 5.1 reads .ps1 as ANSI without a BOM,
# so any non-ASCII literal is silently corrupted at parse time.

# `pattern` matches against the raw GPU name string as returned by
# nvidia-smi --query-gpu=name, Win32_VideoController, lspci, or
# system_profiler SPDisplaysDataType - whichever produced a name. First match
# wins, so more specific patterns (e.g. "RTX 4090" before "RTX 40") are listed
# first within a vendor block.
$GpuTdpTable = @(
    # ---------------- NVIDIA GeForce RTX 40-series ----------------
    # Source: NVIDIA GeForce RTX 40-series spec pages (nvidia.com/en-us/geforce/graphics-cards/),
    # "Graphics Card Power" field; compiled 2026-08, spot-checked for RTX 4090
    # only (see provenance note above).
    [pscustomobject]@{ pattern = 'RTX\s*4090';      label = 'GeForce RTX 4090';      tdpW = 450; source = 'NVIDIA RTX 4090 spec page'; sourceDate = '2026-08' }
    [pscustomobject]@{ pattern = 'RTX\s*4080\s*S';  label = 'GeForce RTX 4080 SUPER'; tdpW = 320; source = 'NVIDIA RTX 4080 SUPER spec page'; sourceDate = '2026-08' }
    [pscustomobject]@{ pattern = 'RTX\s*4080';      label = 'GeForce RTX 4080';      tdpW = 320; source = 'NVIDIA RTX 4080 spec page'; sourceDate = '2026-08' }
    [pscustomobject]@{ pattern = 'RTX\s*4070\s*Ti\s*S'; label = 'GeForce RTX 4070 Ti SUPER'; tdpW = 285; source = 'NVIDIA RTX 4070 Ti SUPER spec page'; sourceDate = '2026-08' }
    [pscustomobject]@{ pattern = 'RTX\s*4070\s*Ti'; label = 'GeForce RTX 4070 Ti';   tdpW = 285; source = 'NVIDIA RTX 4070 Ti spec page'; sourceDate = '2026-08' }
    [pscustomobject]@{ pattern = 'RTX\s*4070\s*S';  label = 'GeForce RTX 4070 SUPER'; tdpW = 220; source = 'NVIDIA RTX 4070 SUPER spec page'; sourceDate = '2026-08' }
    [pscustomobject]@{ pattern = 'RTX\s*4070';      label = 'GeForce RTX 4070';      tdpW = 200; source = 'NVIDIA RTX 4070 spec page'; sourceDate = '2026-08' }
    [pscustomobject]@{ pattern = 'RTX\s*4060\s*Ti'; label = 'GeForce RTX 4060 Ti';   tdpW = 160; source = 'NVIDIA RTX 4060 Ti spec page'; sourceDate = '2026-08' }
    [pscustomobject]@{ pattern = 'RTX\s*4060';      label = 'GeForce RTX 4060';      tdpW = 115; source = 'NVIDIA RTX 4060 spec page'; sourceDate = '2026-08' }

    # ---------------- NVIDIA GeForce RTX 30-series ----------------
    # Source: NVIDIA GeForce RTX 30-series spec pages; compiled 2026-08, not
    # individually re-verified (see provenance note above).
    [pscustomobject]@{ pattern = 'RTX\s*3090\s*Ti'; label = 'GeForce RTX 3090 Ti';   tdpW = 450; source = 'NVIDIA RTX 3090 Ti spec page'; sourceDate = '2026-08' }
    [pscustomobject]@{ pattern = 'RTX\s*3090';      label = 'GeForce RTX 3090';      tdpW = 350; source = 'NVIDIA RTX 3090 spec page'; sourceDate = '2026-08' }
    [pscustomobject]@{ pattern = 'RTX\s*3080\s*Ti'; label = 'GeForce RTX 3080 Ti';   tdpW = 350; source = 'NVIDIA RTX 3080 Ti spec page'; sourceDate = '2026-08' }
    [pscustomobject]@{ pattern = 'RTX\s*3080';      label = 'GeForce RTX 3080';      tdpW = 320; source = 'NVIDIA RTX 3080 spec page'; sourceDate = '2026-08' }
    [pscustomobject]@{ pattern = 'RTX\s*3070\s*Ti'; label = 'GeForce RTX 3070 Ti';   tdpW = 290; source = 'NVIDIA RTX 3070 Ti spec page'; sourceDate = '2026-08' }
    [pscustomobject]@{ pattern = 'RTX\s*3070';      label = 'GeForce RTX 3070';      tdpW = 220; source = 'NVIDIA RTX 3070 spec page'; sourceDate = '2026-08' }
    [pscustomobject]@{ pattern = 'RTX\s*3060\s*Ti'; label = 'GeForce RTX 3060 Ti';   tdpW = 200; source = 'NVIDIA RTX 3060 Ti spec page'; sourceDate = '2026-08' }
    [pscustomobject]@{ pattern = 'RTX\s*3060';      label = 'GeForce RTX 3060';      tdpW = 170; source = 'NVIDIA RTX 3060 spec page'; sourceDate = '2026-08' }

    # ---------------- NVIDIA GeForce RTX 20-series / SUPER ----------------
    # Source: NVIDIA GeForce RTX 20-series spec pages; compiled 2026-08,
    # spot-checked for RTX 2060 SUPER only (see provenance note above).
    [pscustomobject]@{ pattern = 'RTX\s*2080\s*Ti'; label = 'GeForce RTX 2080 Ti';   tdpW = 250; source = 'NVIDIA RTX 2080 Ti spec page'; sourceDate = '2026-08' }
    [pscustomobject]@{ pattern = 'RTX\s*2080\s*S';  label = 'GeForce RTX 2080 SUPER'; tdpW = 250; source = 'NVIDIA RTX 2080 SUPER spec page'; sourceDate = '2026-08' }
    [pscustomobject]@{ pattern = 'RTX\s*2080';      label = 'GeForce RTX 2080';      tdpW = 215; source = 'NVIDIA RTX 2080 spec page'; sourceDate = '2026-08' }
    [pscustomobject]@{ pattern = 'RTX\s*2070\s*S';  label = 'GeForce RTX 2070 SUPER'; tdpW = 215; source = 'NVIDIA RTX 2070 SUPER spec page'; sourceDate = '2026-08' }
    [pscustomobject]@{ pattern = 'RTX\s*2070';      label = 'GeForce RTX 2070';      tdpW = 175; source = 'NVIDIA RTX 2070 spec page'; sourceDate = '2026-08' }
    [pscustomobject]@{ pattern = 'RTX\s*2060\s*S';  label = 'GeForce RTX 2060 SUPER'; tdpW = 175; source = 'NVIDIA RTX 2060 SUPER spec page'; sourceDate = '2026-08' }
    [pscustomobject]@{ pattern = 'RTX\s*2060';      label = 'GeForce RTX 2060';      tdpW = 160; source = 'NVIDIA RTX 2060 spec page'; sourceDate = '2026-08' }

    # ---------------- AMD Radeon RX 7000-series ----------------
    # Source: AMD Radeon RX 7000-series product pages (amd.com/en/products/graphics/radeon-rx),
    # "Typical Board Power" field; compiled 2026-08, spot-checked for RX 7900
    # XTX only (see provenance note above).
    [pscustomobject]@{ pattern = 'RX\s*7900\s*XTX'; label = 'Radeon RX 7900 XTX';    tdpW = 355; source = 'AMD RX 7900 XTX product page'; sourceDate = '2026-08' }
    [pscustomobject]@{ pattern = 'RX\s*7900\s*XT\b'; label = 'Radeon RX 7900 XT';    tdpW = 315; source = 'AMD RX 7900 XT product page'; sourceDate = '2026-08' }
    [pscustomobject]@{ pattern = 'RX\s*7800\s*XT';  label = 'Radeon RX 7800 XT';     tdpW = 263; source = 'AMD RX 7800 XT product page'; sourceDate = '2026-08' }
    [pscustomobject]@{ pattern = 'RX\s*7700\s*XT';  label = 'Radeon RX 7700 XT';     tdpW = 245; source = 'AMD RX 7700 XT product page'; sourceDate = '2026-08' }
    [pscustomobject]@{ pattern = 'RX\s*7600';       label = 'Radeon RX 7600';        tdpW = 165; source = 'AMD RX 7600 product page'; sourceDate = '2026-08' }

    # ---------------- AMD Radeon RX 6000-series ----------------
    # Source: AMD Radeon RX 6000-series product pages; compiled 2026-08, not
    # individually re-verified (see provenance note above).
    [pscustomobject]@{ pattern = 'RX\s*6950\s*XT';  label = 'Radeon RX 6950 XT';     tdpW = 335; source = 'AMD RX 6950 XT product page'; sourceDate = '2026-08' }
    [pscustomobject]@{ pattern = 'RX\s*6900\s*XT';  label = 'Radeon RX 6900 XT';     tdpW = 300; source = 'AMD RX 6900 XT product page'; sourceDate = '2026-08' }
    [pscustomobject]@{ pattern = 'RX\s*6800\s*XT';  label = 'Radeon RX 6800 XT';     tdpW = 300; source = 'AMD RX 6800 XT product page'; sourceDate = '2026-08' }
    [pscustomobject]@{ pattern = 'RX\s*6800';       label = 'Radeon RX 6800';        tdpW = 250; source = 'AMD RX 6800 product page'; sourceDate = '2026-08' }
    [pscustomobject]@{ pattern = 'RX\s*6700\s*XT';  label = 'Radeon RX 6700 XT';     tdpW = 230; source = 'AMD RX 6700 XT product page'; sourceDate = '2026-08' }
    [pscustomobject]@{ pattern = 'RX\s*6600';       label = 'Radeon RX 6600';        tdpW = 132; source = 'AMD RX 6600 product page'; sourceDate = '2026-08' }

    # ---------------- Apple Silicon ----------------
    # Apple does not publish a board TDP for its SoCs (no discrete card, no
    # power connector) - these are third-party sustained package-power
    # measurements under GPU load, the closest available proxy for a "ceiling"
    # figure. Treat these as the least certain entries in this table.
    # Source: Apple M-series independent teardown/review power measurements
    # (Anandtech/Notebookcheck-class sustained GPU load testing); compiled
    # 2026-08, not individually re-verified.
    [pscustomobject]@{ pattern = 'M3\s*Max';        label = 'Apple M3 Max';          tdpW = 78;  source = 'third-party M3 Max sustained GPU-load power measurements'; sourceDate = '2026-08' }
    [pscustomobject]@{ pattern = 'M3\s*Pro';        label = 'Apple M3 Pro';          tdpW = 45;  source = 'third-party M3 Pro sustained GPU-load power measurements'; sourceDate = '2026-08' }
    [pscustomobject]@{ pattern = 'M2\s*Ultra';      label = 'Apple M2 Ultra';        tdpW = 120; source = 'third-party M2 Ultra sustained GPU-load power measurements'; sourceDate = '2026-08' }
    [pscustomobject]@{ pattern = 'M2\s*Max';        label = 'Apple M2 Max';          tdpW = 65;  source = 'third-party M2 Max sustained GPU-load power measurements'; sourceDate = '2026-08' }
    [pscustomobject]@{ pattern = 'M2\s*Pro';        label = 'Apple M2 Pro';          tdpW = 40;  source = 'third-party M2 Pro sustained GPU-load power measurements'; sourceDate = '2026-08' }
    [pscustomobject]@{ pattern = 'M1\s*Max';        label = 'Apple M1 Max';          tdpW = 60;  source = 'third-party M1 Max sustained GPU-load power measurements'; sourceDate = '2026-08' }
    [pscustomobject]@{ pattern = 'M1\s*Pro';        label = 'Apple M1 Pro';          tdpW = 35;  source = 'third-party M1 Pro sustained GPU-load power measurements'; sourceDate = '2026-08' }
)

# Returns the first matching table entry for a raw GPU name string, or $null.
function Find-GpuTdp([string]$GpuName) {
    if (-not $GpuName) { return $null }
    foreach ($row in $GpuTdpTable) {
        if ($GpuName -match $row.pattern) { return $row }
    }
    return $null
}
