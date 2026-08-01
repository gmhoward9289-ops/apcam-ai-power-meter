# Changelog

All notable changes to APCAM (`shunt`) are documented here.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

### Added

- **Slider settings persist across reloads**
  ([#15](https://github.com/gmhoward9289-ops/shunt-ai-power/pull/15)) — rate,
  system draw and CO2 sliders are stored in `localStorage`, keyed per machine.
  Every access is fenced, so a `file://` page without storage falls back to the
  previous reset-on-reload behaviour rather than erroring.
- **Location picker for the electricity rate** — seeds the rate slider from the
  EIA average residential price (Apr 2026 vintage, embedded so the page stays
  offline). Labelled as a location-wide average rather than a bill; the slider
  stays free to override.

## [1.1.0] - 2026-07-31

Cross-platform support and two new backend adapters, on top of dashboard/UX and
correctness fixes.

### Added

- **Linux and macOS support** — GPU vendor dispatch and wall-power import.
  Previously Windows + NVIDIA only.
- **Runtime adapters for llama.cpp server and vLLM**, alongside the existing
  Ollama collector, selected with `-Source`
  ([#11](https://github.com/gmhoward9289-ops/shunt-ai-power/pull/11)).
- **Multi-machine merge and Prometheus metrics export** — aggregate telemetry
  from more than one host.
- **Idle-policy advisor, hosted-API cost reference, and hardware amortization**
  — analysis surfaces layered on the measured-power model.
- **CGNAT client class, multi-GPU calibrate, CO2 slider, and CSV export.**
- **Parser regression fixtures and CI**
  ([#7](https://github.com/gmhoward9289-ops/shunt-ai-power/pull/7)).
- `CONTRIBUTING.md`.

### Fixed

- **pwsh 7 dedupe** affecting run-2 raw counts, with regression fixtures.
- **Wall-power wording** now reflects `-PlugUrl`, and `build.ps1` defaults
  resolve correctly on Unix.
- Dashboard colour-scheme pass over the page chrome.

### Security

- CI hardened: `pii_scan` now refuses to run against a shallow clone (exit 2)
  rather than passing vacuously on a truncated history
  ([#13](https://github.com/gmhoward9289-ops/shunt-ai-power/pull/13)).

## [1.0.0] - 2026-07-31

Initial release. APCAM (AI Power Calculation And Monitoring) works out what a
local LLM habit actually costs in electricity, from *measured* GPU wattage
rather than a spec-sheet estimate, and renders it as a single self-contained
HTML dashboard.

### Added

- **Measured, not guessed** — `calibrate.ps1` samples `nvidia-smi` through one
  real inference to capture the GPU's idle → sustained power envelope.
- **Ollama log parsing** (`collect.ps1`) for request timing, generation rate and
  per-model attribution, handling non-contiguous task IDs and shared-weights
  model tags rather than naively zipping them in order.
- **Privacy-conscious capture** — client addresses are reduced at capture time
  into localhost / LAN / external buckets, never raw IPs. All captured telemetry
  (`dataset.json`, `history.json`, `machine.json`, `dashboard.html`) is
  gitignored; only a synthetic sample dataset ships in the repo.
- **Optional twice-daily scheduled refresh** via `install-task.ps1`, running as
  the invoking user with an interactive token — no stored password, no
  elevation.

### Platform support at 1.0.0

Built and tested on Windows + NVIDIA (Ollama 0.32.5). Partial support for
non-NVIDIA Windows GPUs via manual power entry in `machine.json`. Linux and
macOS were not supported until 1.1.0 — the log parsing was portable, but the
entry point and power readout were not.

[Unreleased]: https://github.com/gmhoward9289-ops/shunt-ai-power/compare/v1.1.0...HEAD
[1.1.0]: https://github.com/gmhoward9289-ops/shunt-ai-power/compare/v1.0.0...v1.1.0
[1.0.0]: https://github.com/gmhoward9289-ops/shunt-ai-power/releases/tag/v1.0.0
