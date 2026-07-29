# shunt

**APCAM — AI Power Calculation And Monitoring.** Works out what your local LLM habit
actually costs in electricity, from *measured* GPU wattage rather than a spec-sheet
guess, and renders it as a single self-contained HTML page.

A shunt is the resistor you drop into a circuit specifically to measure current. Same idea.

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
is that against a rate you set with a slider.

### The finding that motivated this

On the reference machine, **sitting idle cost 3.3x more than every inference combined**
over the same window. The idle floor, not the workload, was the bill. Whether that holds
for you depends on your hardware and how much you actually generate — which is the point
of measuring rather than assuming.

It also surfaces things that are easy to miss: which model ate your GPU-hours, how much
cost-per-token varies between models, and how much disk your model tags *appear* to use
versus what they really occupy.

---

## Quickstart

```powershell
git clone <your-remote> shunt
cd shunt\apcam

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
| **Not measured** | Wall power. Only the GPU is instrumented; a plug meter is the sole way to close the gap between the GPU figure and what the outlet delivers. |

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
| **Windows + NVIDIA** | Supported. This is what it was built and tested against (Ollama 0.32.5). |
| **Windows, non-NVIDIA** | Partial. `calibrate.ps1` writes a `machine.json` with null power fields and tells you so; fill in `gpuIdleW` / `gpuActiveW` by hand (a plug meter is the best source) and everything else works. |
| **Linux / macOS** | Not yet. The log *parsing* is portable, but the entry point is not: the Linux service logs to journald and macOS to `~/.ollama/logs/`, and neither exposes power the way `nvidia-smi` does — Apple Silicon has no comparable per-GPU readout at all. PRs welcome. |

`collect.ps1 -LogDir <path>` overrides log discovery if your install differs.

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

## License

MIT — see [LICENSE](LICENSE). Use it, change it, ship it; just keep the notice.
