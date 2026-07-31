# Contributing

This is one person's tool, validated on one machine (Windows, NVIDIA, Ollama 0.32.5).
That shapes what is useful to send and how long it takes to land. Read this before
opening a PR; it is short.

---

## What is wanted

In rough order of value:

1. **A Linux or macOS entry point.** The README's [Platform support](README.md#platform-support)
   table is the roadmap. The log *parsing* in `collect.ps1` is portable — the request,
   load-event and generation-rate regexes work on the same `llama-server` output
   everywhere. What is not portable is (a) log discovery, since the Linux service goes to
   journald and macOS to `~/.ollama/logs/`, and (b) power, since there is no
   `nvidia-smi`-equivalent readout, and none at all per-GPU on Apple Silicon. A port that
   reads logs correctly and asks the user for a hand-measured envelope is a real
   contribution; do not invent a power number to fill the gap.
2. **Calibration data points from other hardware.** One card is not a sample. Open an
   issue with the measured fields from your `machine.json` — `gpuName`, `gpuLimitW`,
   `gpuIdleW`, `gpuActiveW`, `gpuMaxW`, `refModel`, `refTokensPerSec` — plus how you
   measured, if not `calibrate.ps1`. Idle-floor figures from non-reference cards are the
   single most useful thing anyone can send.
3. **Platform-support fixes.** Non-NVIDIA Windows paths, log layouts a different install
   produces, breakage from an Ollama version bump. See the standing caveat in the README:
   `llama-server` internals are not a stable interface.

**Not wanted without discussing it first:** new dashboard panels, metrics, or chart types.
Open an issue. The page is deliberately one self-contained file with a fixed scope, and a
feature that arrives as a finished PR is harder to say no to than it should be.

---

## The one non-negotiable

The value of this tool is entirely in the
[measured / estimated / not measured](README.md#what-is-measured-what-is-estimated)
distinction. Everything else is a rendering detail.

A change will be rejected — regardless of how good it otherwise is — if it:

- presents an estimate, an interpolation, or a default as a measurement;
- widens a measured field to cover values that were derived instead;
- attributes data more precisely than the logs support (task ids do not map onto HTTP
  requests; tags sharing a weights blob are one entity);
- drops or softens a caveat in the UI or the README to make output look cleaner.

If you add a number, say in the PR which bucket it lands in and why. If it is estimated,
label it estimated in the page, not only in the commit message. A confidently wrong figure
is worse than no figure, and an earlier version of this tool shipped one — that is why the
rule exists.

---

## Checking a change locally

From `apcam/`:

```powershell
.\build.ps1 -Dataset ..\sample\dataset.sample.json -OutFile demo.html
node verify.js demo.html
```

`sample/dataset.sample.json` is synthetic, so the dashboard can be exercised end to end
without capturing anything real. `verify.js` runs the built page's JS against a DOM stub:
it boots the script, fires the slider, hover and toggle handlers, and fails on a missing
element id or a runtime error. It exits non-zero on failure, prints the rendered hero
figure, and needs no browser.

Two things to know: it checks the **built** page, not `dashboard.template.html`, so
rebuild before verifying; and it proves the page does not crash, not that a number is
correct. Numbers are still on you.

There is no CI. Say in the PR what you ran and on what — OS, GPU, Ollama version.

---

## How review actually goes

Everything here has been confirmed on exactly one rig. A platform port cannot be merged on
a read-through, because reading Linux log-parsing code proves nothing about whether Linux
logs parse. So a port PR may sit until someone with that hardware runs it and reports
back, and that wait can be long.

That is not neglect. It is the same standard the README applies to its own numbers, turned
on the contribution process: nothing gets claimed as working until something measured says
it works. A PR that stalls waiting for a second machine is being held to the bar, not
ignored — and a comment saying "ran this on X, here is the output" from anyone unblocks it.

Bug fixes with a clear reproduction and doc corrections move much faster.

---

By contributing you agree your changes ship under the [MIT license](LICENSE).
