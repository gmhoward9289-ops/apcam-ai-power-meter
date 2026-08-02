/* Pre-publish check: runs dashboard.html's script against a minimal DOM stub and
   reports runtime errors, so a broken page is caught before it is published.
   Also re-derives the dataset-conditional features (idle-policy advisor, hosted
   reference, hardware amortization) from the injected data and fails if the
   page disagrees.
   A multi-machine build (injected data has multi:true) is checked differently:
   the machine picker must exist, every machine's page must render when its
   picker handler fires, and the combined strip must equal the sum of
   per-machine totals re-derived from the injected JSON.
   Usage:  node verify.js [dashboard.html] */
const fs = require("fs");
const path = require("path");
const target = process.argv[2] || path.join(__dirname, "dashboard.html");
const html = fs.readFileSync(target, "utf8");

const realIds = new Set([...html.matchAll(/\bid="([^"]+)"/g)].map(m => m[1]));
/* Rebound, not reassigned casually: the reload check below boots the page a
   second time against a fresh element map and listener list, which is what a
   browser reload actually does. makeEl and document read these dynamically. */
let listeners = [];

function makeEl(tag = "div", id = null) {
  const e = {
    tagName: tag, id, _attrs: {}, _children: [], dataset: {},
    style: new Proxy({}, { set: () => true, get: () => "" }),
    classList: { add() {}, remove() {}, contains: () => false },
    setAttribute(k, v) { this._attrs[k] = v; },
    getAttribute(k) { return this._attrs[k] ?? null; },
    appendChild(c) { this._children.push(c); return c; },
    addEventListener(ev, fn) { listeners.push([this, ev, fn]); },
    click() {},
    getBoundingClientRect: () => ({ left: 0, top: 0, width: 760, height: 230 }),
    querySelector: sel => makeEl(sel === "svg" ? "svg" : "div"),
    querySelectorAll: () => [],
    clientWidth: 760, clientHeight: 230, value: "17",
  };
  Object.defineProperty(e, "innerHTML",   { set(v){this._html=String(v);}, get(){return this._html||"";} });
  Object.defineProperty(e, "textContent", { set(v){this._text=String(v);}, get(){return this._text||"";} });
  Object.defineProperty(e, "hidden",      { set(v){this._hidden=v;},      get(){return this._hidden;} });
  return e;
}

let els = new Map();
const missing = [];
const document = {
  createElementNS: (ns, tag) => makeEl(tag),
  createElement: tag => makeEl(tag),
  getElementById(id) {
    if (!realIds.has(id)) { missing.push(id); }
    if (!els.has(id)) els.set(id, makeEl("div", id));
    return els.get(id);
  },
  querySelectorAll(sel) {
    if (sel === "[data-toggle]") {
      return [...html.matchAll(/data-toggle="([^"]+)"/g)].map(m => {
        const b = makeEl("button"); b.dataset.toggle = m[1]; return b;
      });
    }
    return [];
  },
};
const window = { addEventListener: (ev, fn) => listeners.push([window, ev, fn]) };

/* Slider settings persist through localStorage. The stub records writes so the
   persistence check can inspect what the page saved, and `seed` lets a second
   boot start from a previous run's storage - which is what a reload is. */
function makeStorage(seed = null) {
  let v = seed;
  return {
    getItem: () => v,
    setItem: (k, val) => { v = String(val); },
    removeItem: () => { v = null; },
    dump: () => v,
  };
}
let localStorage = makeStorage();

const script = html.slice(html.indexOf("<script>") + 8, html.lastIndexOf("</scr" + "ipt>"));
let fail = 0;

const boot = (doc, win, store) =>
  new Function("document", "window", "localStorage", script)(doc, win, store);

try {
  boot(document, window, localStorage);
  console.log("boot .......... OK");
} catch (e) {
  console.error("boot .......... FAILED:", e.message);
  console.error(e.stack.split("\n").slice(0, 3).join("\n"));
  process.exit(1);
}

const fire = (pred, label) => {
  let n = 0, err = 0, firstMsg = "";
  for (const [t, ev, cb] of listeners) {
    if (!pred(t, ev)) continue;
    try { cb({ clientX: 400, clientY: 100 }); n++; }
    catch (e) { if (!err++) firstMsg = e.message; }
  }
  if (err) { console.error(`${label} FAILED: ${err} error(s), first: ${firstMsg}`); fail++; }
  else console.log(`${label} OK (${n} handler${n === 1 ? "" : "s"})`);
};

// sliders: re-run the whole render at a different rate/wattage/carbon factor
const rate = els.get("rate"), sysw = els.get("sysw"), co2 = els.get("co2");
if (rate) rate.value = "42.5";
if (sysw) sysw.value = "125";
if (co2) co2.value = "500";
fire((t, ev) => (t === rate || t === sysw || t === co2) && ev === "input", "sliders ....... ");
fire((t, ev) => ["mouseenter", "mousemove", "mouseleave"].includes(ev), "hover ......... ");
fire((t, ev) => ev === "click", "toggles ....... ");

if (missing.length) {
  console.error("missing ids ... FAILED:", [...new Set(missing)].join(", "));
  fail++;
} else console.log("element ids ... OK");

const findings = (els.get("findings")?._html.match(/class="finding[ "]/g) || []).length;
console.log(`findings ...... ${findings} rendered`);
const hero = (els.get("hero-cost")?._text || "") + (els.get("hero-unit")?._text || "");
console.log(`hero .......... ${hero} (at 42.5c/kWh + 125W + 500g/kWh)`);

/* Dataset-conditional features: expectations are re-derived from the injected
   JSON, so these checks adapt to whatever page was built. */
let DS = {};
try {
  DS = JSON.parse(html.slice(html.indexOf("/*BEGIN_DATA*/") + "/*BEGIN_DATA*/".length,
                             html.indexOf("/*END_DATA*/")));
} catch { /* unparsable data would already have failed boot */ }
if (DS.multi === true && Array.isArray(DS.machines)) {

/* =========== multi-machine build: picker, per-machine render, combined =========== */
const machines = DS.machines;
const mp = els.get("mpick");
const btns = (mp ? mp._children : []).filter(c => c && c.tagName === "button");
if (mp && mp._hidden === false && btns.length === machines.length && btns.every(b => b._text))
  console.log(`picker ........ OK (${btns.length} machines: ${btns.map(b => b._text).join(", ")})`);
else {
  console.error(`picker ........ FAILED: ${btns.length} button(s) for ${machines.length} machines` +
    (mp && mp._hidden === false ? "" : " (or #mpick still hidden)"));
  fail++;
}

/* The generic slider block above fired while machine 0 was current, so its
   page carries 42.5c / 125 W / 500 g; every other machine keeps its own
   defaults (17c, its dataset's systemWatts, 370 g). Re-derive each page's
   expected hero from that model, then click through the picker. */
const ctl = machines.map((m, i) => i === 0
  ? { rate: 42.5, sysw: 125, co2: 500 }
  : { rate: 17, sysw: (m.machine || {}).systemWatts ?? 70, co2: 370 });
const fmtMoney = usd => usd < 1 ? (usd * 100).toFixed(usd < 0.01 ? 3 : 2) + "¢" : "$" + usd.toFixed(2);
const numFmt = (n, d) => n.toLocaleString("en-US", { minimumFractionDigits: d, maximumFractionDigits: d });
const durFmt = s => { if (s < 60) return s.toFixed(1) + "s";
  const m = Math.floor(s / 60), r = Math.round(s % 60);
  if (m < 60) return `${m}m ${String(r).padStart(2, "0")}s`;
  return `${Math.floor(m / 60)}h ${String(m % 60).padStart(2, "0")}m`; };
const machSec = m => (m.events || []).reduce((a, e) => a + e.dur, 0);
const machW = (m, c) => (((m.machine || {}).gpuActiveW ?? 0) + c.sysw);
const machUsd = (m, c) => machSec(m) * machW(m, c) / 3600 / 1000 * (c.rate / 100);
const clickBtn = b => { let n = 0;
  for (const [t, ev, cb] of [...listeners]) if (t === b && ev === "click") { cb({}); n++; }
  return n; };

let switchFail = 0;
machines.forEach((m, i) => {
  if (!clickBtn(btns[i])) {
    console.error(`machine ${i} ..... FAILED: picker button has no click handler`);
    switchFail++; return;
  }
  const nEv = (m.events || []).length;
  const want = fmtMoney(machUsd(m, ctl[i]));
  const got = (els.get("hero-cost")?._text || "") + (els.get("hero-unit")?._text || "");
  const sub = els.get("sub")?._html || "";
  const heroOk = nEv ? got === want : true;           // no events -> empty state, no hero
  const subOk = nEv ? sub.includes(`${nEv} inference requests`) : true;
  if (heroOk && subOk)
    console.log(`machine ${i} ..... OK (hero ${got} at ${ctl[i].rate}c + ${ctl[i].sysw}W)`);
  else {
    console.error(`machine ${i} ..... FAILED: hero "${got}" want "${want}"` +
      (subOk ? "" : `; sub wrong: "${sub}"`));
    switchFail++;
  }
});
if (switchFail) fail++;

/* combined strip: totals must equal the sum of per-machine recomputations */
let req = 0, sec = 0, wh = 0, usd = 0;
machines.forEach((m, i) => {
  req += (m.events || []).length; sec += machSec(m);
  wh += machSec(m) * machW(m, ctl[i]) / 3600;
  usd += machUsd(m, ctl[i]);
});
const ch = els.get("combined")?._html || "";
const cell = k => { const mm = ch.match(new RegExp(`data-comb="${k}"[^>]*>([^<]*)`)); return mm ? mm[1] : null; };
const wantC = { machines: String(machines.length), requests: String(req),
  active: durFmt(sec), energy: numFmt(wh, 1), cost: fmtMoney(usd) };
const badC = Object.keys(wantC).filter(k => cell(k) !== wantC[k]);
if (!badC.length && els.get("combined")?._hidden === false)
  console.log(`combined ...... OK (${req} req, ${numFmt(wh, 1)} Wh, ${fmtMoney(usd)} across ${machines.length} machines)`);
else {
  console.error("combined ...... FAILED: " + (els.get("combined")?._hidden === false
    ? badC.map(k => `${k}="${cell(k)}" want "${wantC[k]}"`).join("; ")
    : "#combined still hidden"));
  fail++;
}

} else {

const dsEv = (DS.events || []).slice().sort((a, b) => a.start.localeCompare(b.start));
const perHtml = els.get("t-per")?._html || "";

if ((DS.rates || []).length) {
  if (/data-ref="hosted"/.test(perHtml)) console.log("hosted refs ... OK");
  else { console.error("hosted refs ... FAILED: reference table missing from #t-per"); fail++; }

  const wantHw = typeof (DS.machine || {}).gpuCostUSD === "number" && DS.machine.gpuCostUSD > 0;
  const haveHw = /Incl\. hardware/.test(perHtml);
  if (wantHw === haveHw)
    console.log(`amortization .. OK (${wantHw ? "column shown" : "no gpuCostUSD, column absent"})`);
  else {
    console.error(`amortization .. FAILED: gpuCostUSD ${wantHw
      ? "present but column missing" : "absent but column rendered"}`);
    fail++;
  }
}

// idle-policy advisor: recompute the qualifying gaps (15 min = 900 s, matching
// SLEEP_AFTER_MIN in the page) and check the finding shows exactly when due
let gapSec = 0, end = null;
dsEv.forEach(e => {
  const s = new Date(e.start).getTime() / 1000;
  if (end != null && s - end > 900) gapSec += s - end - 900;
  end = end == null ? s + e.dur : Math.max(end, s + e.dur);
});
const winSec = dsEv.length
  ? (Math.max(...dsEv.map(e => new Date(e.start).getTime() + e.dur * 1000))
     - new Date(dsEv[0].start).getTime()) / 1000
  : 0;
const wantAdv = winSec >= 2 * 3600 && gapSec > 0;
const haveAdv = /data-finding="idle-policy"/.test(els.get("findings")?._html || "");
if (wantAdv === haveAdv)
  console.log(`advisor ....... OK (${haveAdv ? "shown" : "conditions unmet, hidden"})`);
else {
  console.error(`advisor ....... FAILED: expected ${wantAdv ? "shown" : "hidden"}, got the opposite`);
  fail++;
}

/* Power-source honesty: whatever powerSource this build's machine.json
   carries, the page must describe it correctly and must never let a
   spec-estimate or absent reading read as "measured". This is the
   CONTRIBUTING.md non-negotiable, checked against whatever dataset was
   actually built rather than a fixed fixture. */
{
  const src = (DS.machine || {}).powerSource ||
    ((DS.machine || {}).measured ? "measured" : "none");
  const heroHtml = els.get("hero-cap")?._html || "";
  const findHtml = els.get("findings")?._html || "";
  const tilesHtml = els.get("tiles")?._html || "";
  const methodHtml = els.get("method-lead")?._html || "";
  // A positive "this reading is measured" claim, distinct from an honest
  // "this was NOT measured" disclosure - both contain the word "measured",
  // so only the affirmative phrasing counts as a false claim here.
  const claimsMeasured = s => /\bW measured GPU\b/.test(s) || />Measured power envelope</.test(s) ||
    /power was measured with/.test(s);
  const noMeasuredClaim = !claimsMeasured(heroHtml) && !claimsMeasured(tilesHtml) &&
    !claimsMeasured(methodHtml);
  if (src === "measured") {
    if (claimsMeasured(heroHtml) && claimsMeasured(tilesHtml))
      console.log("power source .. OK (measured)");
    else { console.error("power source .. FAILED: measured build does not say so"); fail++; }
  } else if (src === "spec-estimate") {
    const tdpSrc = (DS.machine || {}).gpuTdpSource || "";
    const saysEstimated = /spec-estimated|estimated|modeled/i.test(heroHtml + tilesHtml + methodHtml);
    const citesTdp = !tdpSrc || tilesHtml.includes(tdpSrc) || methodHtml.includes(tdpSrc) ||
      findHtml.includes(tdpSrc);
    if (noMeasuredClaim && saysEstimated && citesTdp)
      console.log("power source .. OK (spec-estimate, never claims measured)");
    else {
      console.error(`power source .. FAILED: spec-estimate build ${noMeasuredClaim ? "" : "says 'measured'; "}` +
        `${saysEstimated ? "" : "missing estimated/modeled wording; "}${citesTdp ? "" : "missing TDP source citation"}`);
      fail++;
    }
  } else {
    if (noMeasuredClaim)
      console.log("power source .. OK (none, no measured claim)");
    else { console.error("power source .. FAILED: unmeasured build claims 'measured'"); fail++; }
  }
}

}

/* =========== location lookup and slider persistence ===========
   Runs last on purpose: picking a location moves the rate slider, which would
   invalidate the hero and per-machine expectations derived above. Everything
   here is checked against the page's own embedded table and its own saved
   state, so refreshing the published figures does not invalidate the test. */

const locSel = els.get("loc");
const locOpts = [...(locSel?._html || "").matchAll(/<option value="([A-Z]{2})">([^<]*)/g)];
if (locOpts.length >= 51) console.log(`locations ..... OK (${locOpts.length} entries)`);
else { console.error(`locations ..... FAILED: ${locOpts.length} option(s), expected 51+`); fail++; }

/* Picking a location must move the rate slider onto that location's published
   figure, snapped to the slider's 0.5c step, and reveal the caveat note. The
   note matters as much as the number: an average presented without its
   caveat is exactly the estimate-as-measurement the project forbids. */
if (locOpts.length) {
  const pick = locOpts.find(o => /Hawaii/.test(o[2])) || locOpts[1];
  const published = parseFloat(/([0-9.]+)&cent;/.exec(pick[2])?.[1] ?? "NaN");
  const snapped = Number.isFinite(published)
    ? Math.min(80, Math.max(2, Math.round(published * 2) / 2)) : null;
  locSel.value = pick[1];
  const before = parseFloat(els.get("rate").value);
  fire((t, ev) => t === locSel && ev === "change", "location pick . ");
  const after = parseFloat(els.get("rate").value);
  const note = els.get("loc-note");
  const rateOk = snapped == null ? after !== before : after === snapped;
  const noteOk = note._hidden === false && /average/i.test(note._html || "");
  if (rateOk && noteOk)
    console.log(`location rate . OK (${pick[1]} -> ${after}c/kWh, caveat shown)`);
  else {
    console.error(`location rate . FAILED: rate ${after}` +
      (snapped == null ? "" : ` want ${snapped}`) +
      (noteOk ? "" : "; caveat note missing or hidden"));
    fail++;
  }
}

/* Dragging a slider must itself persist - checked in isolation, because the
   location picker also writes and would otherwise mask a missing save on the
   slider path. */
{
  const store = makeStorage();
  const prevEls = els, prevListeners = listeners;
  els = new Map(); listeners = [];
  let msg = "";
  try {
    boot(document, window, store);
    els.get("rate").value = "23.5";
    for (const [t, ev, cb] of listeners)
      if (t === els.get("rate") && ev === "input") cb({});
  } catch (e) { msg = e.message; }
  const wrote = store.dump();
  els = prevEls; listeners = prevListeners;
  if (!msg && wrote && /"rate":\s*"23\.5"/.test(wrote))
    console.log("slider saves .. OK");
  else {
    console.error("slider saves .. FAILED: " + (msg ||
      (wrote ? "stored record does not carry the new rate: " + wrote.slice(0, 120)
             : "slider input wrote nothing")));
    fail++;
  }
}

/* Persistence: the page must write its settings, and a second boot seeded
   with that storage must come back on them. Expectations come from the saved
   record for the page that renders first, not from whatever page the checks
   above happened to leave current. */
const savedRaw = localStorage.dump();
let savedObj = null;
try { savedObj = JSON.parse(savedRaw); } catch { /* handled below */ }
if (!savedObj || !Object.keys(savedObj).length) {
  console.error("persist write . FAILED: nothing usable written to localStorage");
  fail++;
} else {
  console.log(`persist write . OK (${Object.keys(savedObj).length} machine record(s))`);

  // mirror the page's own key derivation so multi builds check the right record
  const firstDs = DS.multi === true && Array.isArray(DS.machines) ? DS.machines[0] : DS;
  const mach = firstDs.machine || {};
  const key = mach.host || firstDs.label || mach.gpuName || "Machine 1";
  const want = savedObj[key];

  const prevEls = els, prevListeners = listeners;
  els = new Map(); listeners = [];
  let reloadErr = "";
  try { boot(document, window, makeStorage(savedRaw)); }
  catch (e) { reloadErr = e.message; }
  const back = { rate: els.get("rate")?.value, sysw: els.get("sysw")?.value,
                 co2: els.get("co2")?.value, loc: els.get("loc")?.value || "" };
  els = prevEls; listeners = prevListeners;

  if (!want) {
    console.error(`persist reload  FAILED: no saved record under "${key}" ` +
      `(have: ${Object.keys(savedObj).join(", ")})`);
    fail++;
  } else if (reloadErr) {
    console.error("persist reload  FAILED: second boot threw: " + reloadErr);
    fail++;
  } else {
    const same = ["rate", "sysw", "co2"]
      .every(k => parseFloat(back[k]) === parseFloat(want[k]));
    if (same && back.loc === (want.loc || ""))
      console.log(`persist reload  OK (${back.rate}c, ${back.sysw}W, ${back.co2}g` +
        (back.loc ? `, ${back.loc}` : "") + " restored)");
    else {
      console.error(`persist reload  FAILED: got ${JSON.stringify(back)} ` +
        `want ${JSON.stringify(want)}`);
      fail++;
    }
  }
}

/* Storage is unavailable or throws on some file:// origins, which is where
   this page usually runs. It must degrade to reset-on-reload, not fail. */
{
  const denied = { getItem() { throw new Error("SecurityError"); },
                   setItem() { throw new Error("SecurityError"); } };
  const prevEls = els, prevListeners = listeners;
  els = new Map(); listeners = [];
  let ok = true, msg = "";
  try {
    boot(document, window, denied);
    els.get("rate").value = "30";        // a slider nudge is what triggers a write
    for (const [t, ev, cb] of listeners)
      if (t === els.get("rate") && ev === "input") cb({});
  } catch (e) { ok = false; msg = e.message; }
  els = prevEls; listeners = prevListeners;
  if (ok) console.log("storage denied  OK (boots and repaints without storage)");
  else { console.error("storage denied  FAILED: " + msg); fail++; }
}

console.log(fail ? "\nRESULT: FAILED - do not publish" : "\nRESULT: PASS - safe to publish");
process.exit(fail ? 1 : 0);
