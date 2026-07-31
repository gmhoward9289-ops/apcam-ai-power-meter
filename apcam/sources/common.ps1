# APCAM - sources/common.ps1
#
# Plumbing shared by the non-ollama source adapters. Dot-sourced by
# sources/<name>.ps1, which is itself dot-sourced from collect.ps1, so
# everything from collect.ps1's preamble ($machine, $OutFile, $HistoryFile,
# Get-ClientLabel, Read-SharedLines, ...) is in scope here.
#
# Two of these deliberately mirror blocks in collect.ps1's ollama path
# (Format-HistTs and the gpuNow snapshot). They are duplicated rather than
# factored out so the ollama path stays provably untouched; if you change one
# side, change the other.
#
# KEEP THIS FILE PURE ASCII - see the note at the top of collect.ps1.

# pwsh 7's ConvertFrom-Json revives ISO date strings as [datetime] (5.1 keeps
# them as strings). Pin them back to the ISO string form so dedupe keys match
# across runtimes; on 5.1 this is a no-op. Mirrors collect.ps1.
function Format-HistTs($v) {
    if ($v -is [datetime]) { return $v.ToString('yyyy-MM-ddTHH:mm:ss') }
    return "$v"
}

# Live GPU snapshot. Mirrors the gpuNow block in collect.ps1's ollama path:
# nvidia-smi only, honoring machine.json's gpuIndex/gpuVendor, null elsewhere.
function Get-ApcamGpuNow {
    $gpuNow = $null
    $gpuIdx = 0
    if ($machine.PSObject.Properties.Name -contains 'gpuIndex' -and $null -ne $machine.gpuIndex) {
        $gpuIdx = [int]$machine.gpuIndex
    }
    $gpuVendorNow = ''
    if ($machine.PSObject.Properties.Name -contains 'gpuVendor' -and $machine.gpuVendor) {
        $gpuVendorNow = "$($machine.gpuVendor)"
    }
    if ($gpuVendorNow -in @('', 'nvidia', 'unknown')) {
        try {
            $raw = & nvidia-smi -i $gpuIdx --query-gpu=power.draw,utilization.gpu,memory.used,memory.total,temperature.gpu `
                                --format=csv,noheader,nounits 2>$null
            if ($raw) {
                if ($raw -is [array]) { $raw = $raw[0] }
                $p = ($raw -split ',').Trim()
                $gpuNow = [pscustomobject]@{ w=[double]$p[0]; util=[double]$p[1]
                                             vramUsed=[double]$p[2]; vramTotal=[double]$p[3]; temp=[double]$p[4] }
            }
        } catch { }
    }
    return $gpuNow
}

# Compact UTF-8-no-BOM JSON writer, same encoding collect.ps1 uses everywhere.
function Write-ApcamJson([string]$path, $obj, [int]$depth) {
    [System.IO.File]::WriteAllText($path,
        ($obj | ConvertTo-Json -Depth $depth -Compress),
        [System.Text.UTF8Encoding]::new($false))
}
