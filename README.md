# apcam-ai-power-meter

**APCAM — AI Power Calculation And Monitoring.** Works out what your local LLM habit
actually costs in electricity, from *measured* GPU wattage rather than a spec-sheet
guess, and renders it as a single self-contained HTML page.

Named for the shunt resistor you drop into a circuit specifically to measure current. Same idea:
measure it, do not guess it.

> Ollama on Windows, NVIDIA GPU. See [Platform support](#platform-support) before you start.

---

## What it actually does

Two independent sources, joined:

1. **Measured power.** `calibrate.ps1` samples `nvidia-smi` while running one real
   inference, and records the idle-to-sustained envelope for *your* card. On the machine
   this was built for that came out at **17.9 W idle → 173.5 W generating**, pegged
   against a 175 W limit. A spec sheet would not have told you that.
2. **Parsed usage.** `collect.ps1` reads Ollama's own server logs for completed
   inference requests — timestamp, duration, endpoint, client, status — plus the
   generation-rate samples the runner prints, and attributes each to a model using the
   runner's load-event timeline.

Energy is then `duration x (measured GPU watts + your system-watts estimate)`, and cost
is that against a rate you set with a slider. Slider settings persist between reloads
(per machine, via `localStorage`, degrading gracefully where `file://` storage is
unavailable), and an optional location picker under the rate slider seeds it from the
EIA average residential price for a U.S. state — labelled with its data vintage, and an
average to start from, not a measurement of your bill.

### The finding that motivated this

On the reference machine, **sitting idle cost 3.3x more than every inference combined**
over the same window. The idle floor, not the workload, was the bill. Whether that holds
for you depends on your hardware and how much you actually generate — which is the point
of measuring rather than assuming.

It also surfaces things that are easy to miss: which model ate your GPU-hours, how much
cost-per-token varies between models, and how much disk your model tags *appear* to use
versus what they really occupy. A CO2 slider (g/kWh) turns the energy figures into
emissions, and the request/rate tables export as CSV straight from the page.

---

## Quickstart

```powershell
git clone https://github.com/gmhoward9289-ops/apcam-ai-power-meter.git
cd apcam-ai-power-meter\apcam

.\calibrate.ps1        # once per machine: measures your GPU's power envelope
.\collect.ps1          # parse Ollama's logs -> dataset.json (+ append to history.json)
.\build.ps1 -Open      # inject data into the page and open it
```

Optionally keep it current without thinking about it:

```powershell
.\install-task.ps1                      # twice daily, 09:00 and 21:00
.\install-task.ps1 -At 07:00,13:00,19:00
.\install-task.ps1 -Uninstall
```

The scheduled task runs as you with an interactive token — no stored password, no
elevation — so it **only fires while you are logged on**. `StartWhenAvailable` picks up a
slot missed because the machine was off.

Before sharing a generated page, sanity-check it:

```powershell
node verify.js         # runs the page's JS against a DOM stub; catches a broken build
```

The location averages behind the rate picker are embedded at build time, so the page
never reaches the network. Refresh them when they drift:

```powershell
.\refresh-rates.ps1 -ApiKey $env:EIA_API_KEY -WhatIf   # show what would change
.\refresh-rates.ps1 -ApiKey $env:EIA_API_KEY           # rewrite the table, then rebuild
```

The parser has regression tests of its own: synthetic `server*.log` fixtures under
`tests/fixtures/` are run through `collect.ps1` and the emitted dataset is asserted
field by field, so a llama-server format change fails in CI rather than going quietly
dark (see [A standing caveat](#a-standing-caveat)). CI runs them on every push;
locally:

```powershell
pwsh tests/run-parser-tests.ps1     # works on Windows PowerShell 5.1 too
```

There is a synthetic dataset in `sample/` if you want to see the page before collecting
anything of your own:

```powershell
.\build.ps1 -Dataset ..\sample\dataset.sample.json -OutFile demo.html -Open
```

---

## What is measured, what is estimated

Being honest about this is the whole point — the numbers are only useful if you know
which ones to trust.

| | |
|---|---|
| **Measured** | GPU watts, VRAM, temperature. Request start, duration, status, endpoint, client class. Generation rates. Model inventory and on-disk size. |
| **Estimated** | Non-GPU system draw (the slider, default 70 W). And the assumption that the GPU holds sustained wattage for a whole request — short requests spend part of their time loading weights at lower draw, so their energy is mildly over-stated. |
| **Spec-estimated** | GPU idle/active wattage, only when `calibrate.ps1` found no power sensor at all. It detects the GPU model and looks it up in `data/gpu-tdp.ps1`'s curated table of vendor-published TDP figures, then derives a wide idle/active band from that rating (`powerSource: "spec-estimate"` in `machine.json`). This is the worst rung of the ladder — a thermal ceiling is not a measured draw — and the page always says so: the hero line, the envelope tile, and the footer all read "estimated"/"modeled", never "measured", and cite the TDP source. Skip it with `calibrate.ps1 -NoSpecEstimate` to keep the old fill-in-by-hand behavior instead. |
| **Not measured** | Wall power, unless you calibrate with a smart plug (`calibrate.ps1 -PlugUrl <addr>`, Tasmota/Shelly), which records `wallIdleW`/`wallActiveW`. Without one, only the GPU is instrumented and the gap to the outlet stays open. |

### Optional: hardware amortization

Add `gpuCostUSD` (and optionally `gpuLifetimeYears`, default 3) to `machine.json` by
hand and the cost-per-million-tokens table gains an **incl. hardware** column — the
card's price spread over its expected lifetime of wall-clock time, on top of
electricity. Caveat: `calibrate.ps1` currently rewrites `machine.json` from scratch,
so re-add the field after any recalibration.

### Two limits worth understanding

These are properties of the log data, not bugs, and the tool will not paper over them:

- **Generation rates are per model, not per request.** The runner's internal task ids
  are non-contiguous (0, 74, 292, 645...) and do not map one-to-one onto HTTP requests.
  Zipping them in order produces confidently wrong attribution — an earlier version of
  this did exactly that. Rates are attributed only to the model that was loaded at the
  time, which the load timeline *does* establish.
- **Tags sharing a weights blob are one entity.** A model and its long-context variant
  differ only in a parameters layer and are indistinguishable in the logs, so they are
  reported together rather than guessed apart.

Also: generated-token counts are deliberately not reported per request. Ollama prints
progress roughly every 50 tokens, so anything shorter reports nothing and the totals
would be floors masquerading as counts.

---

## Sources

`collect.ps1 -Source <name>` selects the runtime adapter. The default is `ollama` and
its behavior is unchanged — a dataset collected without `-Source` is identical to one
collected before adapters existed (and carries no `source` key; adapter datasets add a
top-level `source`). Non-ollama sources write to `dataset.<source>.json` /
`history.<source>.json` by default so streams never mix; every adapter applies the
same client anonymisation, and all of them still need `machine.json` from
`calibrate.ps1` for the power envelope.

| Source | Input | What you get |
|---|---|---|
| `ollama` (default) | Ollama's `server*.log` + manifests + API | Everything described above. |
| `llamacpp` | A captured `llama-server` stderr log (`-LogDir <dir-or-file>`) | Requests (no durations), per-task timings and rates, exact evaluated-prompt and generated-token counts for completed tasks. |
| `vllm` | Prometheus `/metrics` scrape (`-Endpoint`, default `http://localhost:8000`, or `-MetricsFile <saved scrape>`) | Exact aggregate token/request counters and latency sums — no per-request timeline. |
| `lmstudio` | — | Not implemented: LM Studio's server log is a console mirror with no documented stable format, and a missing adapter beats a guessed one. If your install exposes the underlying llama.cpp engine log, `-Source llamacpp` may work on that file. |

### llama.cpp (`-Source llamacpp`)

```powershell
.\collect.ps1 -Source llamacpp -LogDir C:\logs\llama    # scans *.log; a single file works too
```

`llama-server` logs to stderr and has no log directory of its own, so capture it first
(`llama-server ... 2>>llama.log`, `journalctl -u <unit> -o short-iso > llama.log`, or
`docker logs -t`). Honest limits, straight from what the log actually contains:

- **Request lines have no duration and no timestamp.** `srv  log_server_r: request:
  POST /v1/chat/completions <addr> <status>` gives method/path/client/status only, so
  events carry `dur = 0` (a number, so existing consumers keep working — not a
  measurement) — and llama.cpp demoted the line to trace level in Nov 2025, so on
  newer builds there are no request lines at all and only timings and rates remain.
  Busy time comes from the per-task `total time` rows instead (`busySeconds` in the
  dataset), which is also what the energy figure uses.
- **Wall-clock time only exists if a wrapper stamped the lines** (journald
  `-o short-iso`, `docker logs -t`, `ts`). llama.cpp's own `--log-timestamps` prints
  time since start, which is not a clock. Unstamped logs still parse, but events and
  rates carry no time and are not merged into the history file — the dataset is then a
  snapshot of the scanned logs, and the run says so.
- **One model per process:** attribution needs no load-timeline join; everything after
  a `load_model:` line belongs to that model. Inventory is names only (no manifests to
  read — sizes are null, `diskBytes` is null).
- `promptTokens` counts **evaluated** prefill tokens (prompt-cache hits excluded),
  falling back to the announced prompt size for tasks that never printed a timing
  block; ollama's figure is the full prompt size. `generationTokens` sums final eval
  rows, so it covers completed tasks only. Both the pre-Nov-2025 single-block timing
  format and the current per-row format are parsed, as are the periodic
  `n_decoded ... tg = N t/s` progress rows (same dedupe rule as the ollama path:
  one sample per task, final count wins, first timestamp kept).

### vLLM (`-Source vllm`)

```powershell
.\collect.ps1 -Source vllm                       # scrapes http://localhost:8000/metrics
.\collect.ps1 -Source vllm -MetricsFile snap.txt # or parse a saved scrape offline
```

vLLM is scraped, not parsed: `/metrics` exposes exact cumulative counters, which is
both better and worse than logs, and the dataset represents that honestly rather than
faking events:

- **Token counts are exact.** `vllm:prompt_tokens_total` / `vllm:generation_tokens_total`
  are true counters — the ~50-token reporting floor that applies to the log-parsing
  sources does not exist here.
- **There is no per-request timeline** — no start times, durations, or client
  addresses — so `events` and `rates` stay empty and the real data lands in a
  top-level `aggregates` block: per-model token/request totals (with
  `finished_reason` breakdown), latency sums and true averages (e2e, queue, TTFT,
  per-output-token → `decodeTokPerSec`), running/waiting gauges and KV-cache usage.
  Both v1 metric names (`vllm:kv_cache_usage_perc`, `vllm:inter_token_latency_seconds`)
  and their v0 predecessors are understood.
- **Busy time is summed request-seconds** — RUNNING-phase time where the deployment
  exposes it, end-to-end time (queueing included) otherwise; `busySource` says which.
  Requests overlap under continuous batching, so treat energy computed from it as an
  upper bound.
- **Counters reset when the server restarts.** Each run appends a snapshot to the
  history file (unchanged counters are not re-appended), so deltas between snapshots
  are exact interval usage; a counter that went backwards means a restart.

Adapter status: both new adapters are **fixture-verified** — the log and metrics
shapes were derived from llama.cpp's and vLLM's own source across format eras, and
pinned by the regression tests, but they have not been run against live servers here.
The ollama path remains the only one exercised against a real deployment. Adapters run
under PowerShell 7; they are written to Windows PowerShell 5.1's dialect
(parse-checked there), while day-to-day 5.1 use remains tested for the ollama path.

---

## Privacy

The repo is structured so captured telemetry never lands in git:

- `dataset.json`, `history.json`, `machine.json`, `dashboard.html` and `refresh.log` are
  all gitignored. Only the synthetic `sample/` data is tracked.
- **Client addresses are reduced at capture time**, never stored raw. `127.0.0.1` and
  `::1` become `localhost`; RFC1918 addresses become `lan-<4 hex>`; anything else becomes
  `external-<4 hex>`. The dashboard only needs to distinguish *me* / *another box on my
  network* / *off-network*, and the raw address adds nothing to that.
- `-KeepRawClients` opts out for local debugging. `build.ps1` warns loudly if it builds a
  page from such a dataset.

Nothing is transmitted anywhere. The page is a local file.

---

## Platform support

| | |
|---|---|
| **Windows + NVIDIA** | Supported. This is what it was built and tested against (Ollama 0.32.5), on Windows PowerShell 5.1. Multi-GPU boxes: calibrate one card with `.\calibrate.ps1 -GpuIndex N`; collect samples the same card. |
| **Windows, non-NVIDIA** | Partial. With no power sensor, `calibrate.ps1` detects the GPU model via `Win32_VideoController` and, if it is in `data/gpu-tdp.ps1`'s table, writes a spec-based estimate (`powerSource: "spec-estimate"`) instead of giving up. Otherwise — or with `-NoSpecEstimate` — it writes a `machine.json` with null power fields and tells you so; fill in `gpuIdleW` / `gpuActiveW` by hand (a plug meter is the best source) and everything else works. |
| **Linux + NVIDIA** | Supported under [PowerShell 7](https://learn.microsoft.com/powershell/scripting/install/installing-powershell) (`pwsh`). `nvidia-smi` sampling is identical to Windows. Logs: `~/.ollama/logs` is tried first; if no `server*.log` turns up, `collect.ps1` dumps the `ollama` journald unit to a temp file and parses that (system unit first, then `--user-unit`; assumes the stock service install; the dump is deleted after the scan). Schedule with `./install-schedule.sh` — a systemd *user* timer, which fires only while you are logged in unless you `loginctl enable-linger`. |
| **Linux + AMD** | Best-effort. `calibrate.ps1 -GpuVendor amd` probes `amd-smi`, then `rocm-smi`; their JSON layouts drift between ROCm releases, so the probe pattern-matches field names and falls back to the manual-entry path when no power figure comes back. Untested on real AMD hardware — reports welcome. |
| **macOS (Apple Silicon)** | Supported with caveats, under PowerShell 7. GPU power comes from `powermetrics`, which only talks to root: calibrate with `sudo pwsh -NoProfile -File calibrate.ps1` (without root it degrades to the manual-entry path and says so). The figure is the Apple GPU rail only — CPU and ANE draw are excluded — and unified memory means there is no VRAM number. Intel Macs print no `GPU Power` lines and land on the manual path. Logs: `~/.ollama/logs`. Schedule with `./install-schedule.sh` — a launchd agent, missed slots run on wake. |

`collect.ps1 -LogDir <path>` overrides log discovery everywhere if your install differs.
`calibrate.ps1 -GpuVendor nvidia|amd|apple|none` overrides GPU vendor detection
(default: `apple` on macOS, `nvidia` everywhere else). On Linux/macOS run the scripts as
`pwsh ./collect.ps1`; on Windows they still run under stock PowerShell 5.1.

**No power sensor at all.** When telemetry is unavailable on any platform,
`calibrate.ps1` tries one more thing before asking for manual entry: it detects the GPU
model by name (`Win32_VideoController` on Windows, `lspci` on Linux, `system_profiler
SPDisplaysDataType` on macOS) and, if that model is in `data/gpu-tdp.ps1`'s curated TDP
table, derives a wide idle/active band from its rated TDP. See [What is measured, what is
estimated](#what-is-measured-what-is-estimated) for how this is labeled on the page. Pass
`-NoSpecEstimate` to skip it and keep the old null-fields-fill-in-by-hand behavior.

**Wall power from a smart plug.** If the machine is on a Tasmota or Shelly plug,
`calibrate.ps1 -PlugUrl http://<plug-ip>` samples the plug's local HTTP API during the
idle and load phases and records `wallIdleW` / `wallActiveW` in `machine.json` — actual
outlet draw alongside the GPU-only figures. The API flavor is auto-detected
(`-PlugType tasmota|shelly` pins it); an unreachable plug warns and is skipped. Local
HTTP only — nothing leaves your LAN.

### A standing caveat

This parses `llama-server` internals — `load_model:`, `n_decoded`, `task N` — which are
not a stable interface and can change between Ollama releases. If a version bump makes
things go quiet, `collect.ps1` says so rather than silently reporting zero, and
`server.log` is the place to look for `[GIN]` lines.

---

## How it fits together

```
calibrate.ps1  --->  machine.json      (your GPU's measured power envelope)
                          |
Ollama logs    --->  collect.ps1  --->  dataset.json     (current snapshot)
                          |        \->  history.json     (append-only, survives log rotation)
                          v
                     build.ps1    --->  dashboard.html   (self-contained, no network)
```

`history.json` exists because **Ollama rotates `server*.log` on every restart and drops
the oldest** — usage history is being destroyed continuously. During development a test
request vanished from the logs within the hour. That file is the only durable record, so
back it up if the history matters to you.

The dashboard is a snapshot, not a live feed: one static file, no network calls, works
offline, and renders in light or dark to match your system.

---

## Multiple machines on one page

Every dataset already carries its own machine envelope, so merging is a build-time
concern — copy each box's `dataset.json` somewhere and hand `build.ps1` all of them:

```powershell
.\build.ps1 -Dataset C:\fleet\office.json,C:\fleet\garage.json -OutFile fleet.html
```

Comma-separated or an array; one path behaves exactly as it always has. With several,
the page gains a machine picker in the masthead — each machine renders its full
dashboard from its own dataset, with its own sliders — plus a combined strip of the
additive totals: requests, active time, energy, electricity cost and CO2, each machine
at its own measured wattages and its own slider settings. Per-request economics
(tok/s, $/Mtok) are deliberately never averaged across machines, because the wattages
behind them are per-machine measurements and a blended figure would describe no
machine. Tabs are named from a hand-added `label` on the dataset root, falling back
to the machine's GPU name. Try it on the two synthetic samples:

```powershell
.\build.ps1 -Dataset ..\sample\dataset.sample.json,..\sample\dataset.sample2.json -OutFile fleet-demo.html -Open
```

## Prometheus metrics export

For the Grafana / Home Assistant crowd: `export-metrics.ps1` turns a dataset into a
Prometheus textfile-collector `.prom` file. Nothing is served — point node_exporter's
(or windows_exporter's) textfile collector at the folder and schedule the script
after `collect.ps1`:

```powershell
.\export-metrics.ps1 -OutFile C:\textfile_collector\apcam.prom
.\export-metrics.ps1 -Dataset .\dataset.json -History .\history.json -OutFile .\apcam.prom -Validate
```

Emitted: `apcam_requests_total{model,status_class,client}`,
`apcam_active_seconds_total{model}`, `apcam_energy_wh_total{model}` (at the measured
`gpuActiveW` plus `-SystemWatts`, defaulting to the dataset's `machine.systemWatts`),
`apcam_prompt_tokens_total`, `apcam_disk_bytes{scope,...}`, `apcam_gpu_watts`, and an
`apcam_info{gpu,source}` marker. Counters are cumulative because the dataset already
carries the merged event history; `-History` unions `history.json` in as well. The
write is atomic (temp file, then rename) so a collector never reads a half-written
file, and `-Validate` re-reads the emitted file and checks exposition-format shape
line by line — no promtool needed.

---

## License

MIT — see [LICENSE](LICENSE). Use it, change it, ship it; just keep the notice.
