// Car test (/testcar/): a short guided check of an in-car browser – screen, formats, cache,
// where the car shows the music, which media buttons reach the page, background playback.
// Nothing is sent to the server; the result ends up in a QR code that opens a mail on a phone.
// With ?auto=1 the page exposes window.__testcar for the headless tests.

import qrcode from "qrcode-generator";
import { t } from "../app/i18n";

const AUTO = new URLSearchParams(location.search).get("auto") === "1";
const T0 = performance.now();
const now = () => Math.round(performance.now() - T0);
const app = document.getElementById("app")!;
const status = document.getElementById("st")!;
document.getElementById("title")!.textContent = t("Car test");
document.title = `audiojoe · ${t("Car test")}`;

// ---------------------------------------------------------------- helpers

type Kid = Node | string | null | undefined | false;
function h<K extends keyof HTMLElementTagNameMap>(tag: K, props: Partial<HTMLElementTagNameMap[K]> = {}, ...kids: Kid[]) {
  const e = Object.assign(document.createElement(tag), props);
  e.append(...kids.filter((k): k is Node | string => !!k));
  return e;
}
const ICONS = {
  prev: "M6 5h2v14H6zM20 5v14L9 12z",
  next: "M16 5h2v14h-2zM4 5v14l11-7z",
  pause: "M6 5h4v14H6zM14 5h4v14h-4z",
  stop: "M6 6h12v12H6z",
};
function icon(name: keyof typeof ICONS) {
  const s = document.createElementNS("http://www.w3.org/2000/svg", "svg");
  s.setAttribute("viewBox", "0 0 24 24");
  s.setAttribute("class", "i");
  s.innerHTML = `<path d="${ICONS[name]}" fill="currentColor"/>`;
  return s;
}
/** Text with {prev}/{next}/{pause}/{stop} replaced by drawn icons (the glyphs are missing in some car fonts). */
function withIcons(text: string) {
  const span = h("span");
  for (const part of text.split(/(\{(?:prev|next|pause|stop)\})/)) {
    const m = part.match(/^\{(\w+)\}$/);
    span.append(m ? icon(m[1] as keyof typeof ICONS) : part);
  }
  return span;
}
const store = {
  get: (k: string) => { try { return localStorage.getItem(k); } catch { return null; } },
  set: (k: string, v: string) => { try { localStorage.setItem(k, v); } catch { /* private window */ } },
};

// ---------------------------------------------------------------- result

const result = {
  vehicle: { make: "", model: "", year: "" },
  env: {} as Record<string, string>,
  formats: [] as string[],
  cache: "",
  shown: [] as string[],
  steps: [] as [string, string][],
  bg: "",
  unsupported: [] as string[],
  server: "",
};
type Ev = { a: string; t: number; step: string };
const log: Ev[] = [];
let step = "";
let onAction: ((a: string) => void) | null = null;
function record(a: string) {
  log.push({ a, t: now(), step });
  if (!a.startsWith("el:") && !a.startsWith("vis:")) onAction?.(a);
}

// ---------------------------------------------------------------- environment

const tesla = /Tesla/i.test(navigator.userAgent);

function browserName(): string {
  const ua = navigator.userAgent;
  for (const [name, re] of [["Tesla", /Tesla\/([\w.-]+)/], ["Edge", /Edg\/(\d+)/], ["Firefox", /Firefox\/(\d+)/],
    ["Chrome", /Chrome\/(\d+)/], ["Safari", /Version\/(\d+).*Safari/]] as [string, RegExp][]) {
    const m = ua.match(re);
    if (m) return `${name} ${m[1]}`;
  }
  return "Browser";
}

async function earlierVisit(): Promise<string> {
  const first = store.get("audiojoe-testcar-first");
  let cached = false;
  try { cached = !!(await (await caches.open("audiojoe-testcar")).match("/testcar/marker")); } catch { /* no cache storage */ }
  const today = new Date().toISOString().slice(0, 10);
  if (!first) store.set("audiojoe-testcar-first", today);
  try { await (await caches.open("audiojoe-testcar")).put("/testcar/marker", new Response(today)); } catch { /* reported in features */ }
  return first ? `${first} (ls+ cache${cached ? "+" : "-"})` : "first";
}

async function environment() {
  const e = result.env;
  const mm = (q: string) => matchMedia(q).matches;
  e.ua = navigator.userAgent;
  e.screen = `${screen.width}x${screen.height} win ${innerWidth}x${innerHeight} dpr ${Math.round(devicePixelRatio * 100) / 100}`;
  e.input = [innerWidth >= innerHeight ? "landscape" : "portrait", mm("(pointer: coarse)") ? "touch" : "mouse",
    `tp${navigator.maxTouchPoints}`, mm("(prefers-color-scheme: dark)") ? "dark" : "light",
    innerWidth <= 600 ? "layout=narrow" : "layout=wide", navigator.language].join(" ");
  let quota = "?";
  try { const est = await navigator.storage.estimate(); quota = `${((est.quota ?? 0) / 2 ** 30).toFixed(1)}GB`; } catch { /* old browser */ }
  let persisted = "?";
  try { persisted = (await navigator.storage.persisted()) ? "+" : "-"; } catch { /* old browser */ }
  e.features = [`sw${"serviceWorker" in navigator ? "+" : "-"}`, `cache${"caches" in self ? "+" : "-"}`,
    `idb${"indexedDB" in self ? "+" : "-"}`, `ms${"mediaSession" in navigator ? "+" : "-"}`,
    `secure${isSecureContext ? "+" : "-"}`, `persist${persisted}`, `quota ${quota}`].join(" ");
  e.earlier = await earlierVisit();
  e.audio = audioOutput();
  try { result.server = (await (await fetch("/api/v1/health")).json()).version ?? ""; } catch { /* page opened from elsewhere */ }
}

// ---------------------------------------------------------------- audio output
//
// Sample rate of the browser's audio output (user 2026-11-07: "ob das Ding 24 Bit 48 kHz kann").
// AudioContext.sampleRate is the rate the browser mixes at for the output device (the device's
// rate as the system set it); the bit depth of the output is not visible to a web page – the
// stages below show which files the car decodes. A stage above that rate plays only because the
// browser converts it down: it counts as "resampled", not as the highest stage (user 2026-11-09).

let audioRate = 0;
function audioOutput(): string {
  try {
    const ctx = new AudioContext();
    audioRate = ctx.sampleRate;
    const base = Math.round((ctx.baseLatency ?? 0) * 1000);
    void ctx.close();
    return `${audioRate}Hz base ${base}ms`;
  } catch (e) {
    return `-${(e as Error).name}`;
  }
}

/** After a tap: the running context also knows the latency to the speakers. */
async function audioRunning(): Promise<string> {
  try {
    const ctx = new AudioContext();
    await Promise.race([ctx.resume(), new Promise((r) => setTimeout(r, 1000))]);
    await new Promise((r) => setTimeout(r, 300));
    const out = Math.round(((ctx as AudioContext & { outputLatency?: number }).outputLatency ?? 0) * 1000);
    const state = ctx.state;
    await ctx.close();
    return `out ${out}ms ${state}`;
  } catch (e) {
    return `-${(e as Error).name}`;
  }
}

// ---------------------------------------------------------------- formats and cache

// PCM stages step by step (bit depth / kHz); the ids of 0.1.x (flac16, flac24) stay.
const STAGES: [string, string, string][] = [
  ["FLAC 16/44", "flac16", "tone16.flac"],
  ["FLAC 16/48", "flac16-48", "tone16-48.flac"],
  ["FLAC 24/44", "flac24-44", "tone24-44.flac"],
  ["FLAC 24/48", "flac24-48", "tone24-48.flac"],
  ["FLAC 24/96", "flac24", "tone24.flac"],
  ["FLAC 24/192", "flac24-192", "tone24-192.flac"],
  ["WAV 24/48", "wav24-48", "tone24-48.wav"],
];
const FORMATS: [string, string, string][] = [
  ["MP3", "mp3", "tone.mp3"],
  ["AAC", "aac", "tone.m4a"],
  ["Opus", "opus", "tone.opus"],
  ...STAGES,
];

/** Audio output for the mail, without spaces (each costs three characters in the QR code). */
function mailAudio(): string {
  const a = result.env.audio ?? "";
  const m = a.match(/^(\d+)Hz base (\d+)ms(?: out (\d+)ms (\w+))?/);
  if (!m) return a.replace(/ /g, ",");
  return `${m[1]}Hz,out=${m[3] ?? "?"}ms${m[4] && m[4] !== "running" ? `,${m[4]}` : ""}`;
}

/** The measured result of one format ("+<ms>" or "-<reason>"), "" when not measured. Exact: the id
 * "flac24" must not take the result of "flac24-44" (0.2.4 mailed "24/96-44+687" as failed). */
function resultOf(id: string): string {
  const ids = FORMATS.map(([, i]) => i);
  const f = result.formats.find((x) => x.startsWith(id) && /^[+-]/.test(x.slice(id.length))
    && !ids.some((o) => o.length > id.length && x.startsWith(o) && /^[+-]/.test(x.slice(o.length))));
  return f ? f.slice(id.length) : "";
}

/** kHz of a stage label: "FLAC 24/96" → 96 (44 stands for 44.1). */
const stageKhz = (label: string) => Number(label.split(" ")[1].split("/")[1]);
const stageHz = (label: string) => (stageKhz(label) === 44 ? 44100 : stageKhz(label) * 1000);

/** A stage above the browser's output rate plays only because the browser converts it down (user
 * 2026-11-09: "Er kann nur 48kHz … Der Browser spielt alle Files trotzdem ab, weil er dann downsamplet"). */
const resampled = (label: string) => audioRate > 0 && stageHz(label) > audioRate;

/** PCM stages for the mail: how many played, the highest at most at the output rate
 * (AudioContext.sampleRate), the rates the browser converted down, and each one that failed with
 * its reason – e.g. "7/7,max=24/48,resampled=96,192" or "5/7,max=24/48,24/192-err4,wav24/48-timeout". */
function mailStages(): string {
  const failed = STAGES.flatMap(([label, id]) => {
    const r = resultOf(id) || "-";
    if (r.startsWith("+")) return [];
    return [`${label.startsWith("WAV") ? "wav" : ""}${label.split(" ")[1]}${r}`];
  });
  const down = [...new Set(STAGES.filter(([label, id]) => resultOf(id).startsWith("+") && resampled(label)).map(([label]) => stageKhz(label)))];
  return [`${STAGES.length - failed.length}/${STAGES.length}`, `max=${highestStage() || "-"}`,
    ...(down.length ? [`resampled=${down.join(",")}`] : []), ...failed].join(",");
}

/** The highest PCM stage that played at most at the output rate, e.g. "24/48"; "" when none. */
function highestStage(): string {
  const played = STAGES.filter(([label, id]) => resultOf(id).startsWith("+") && !resampled(label))
    .map(([label]) => label.split(" ")[1].split("/").map(Number) as [number, number]);
  played.sort((a, b) => a[0] - b[0] || a[1] - b[1]);
  const top = played.at(-1);
  return top ? `${top[0]}/${top[1]}` : "";
}

/** Plays a source until 0.3 s have passed; "+<ms to start>" or "-<reason>". */
function playShort(src: string): Promise<string> {
  return new Promise((resolve) => {
    const a = new Audio(src);
    a.volume = 0.5;
    const t0 = performance.now();
    let done = false;
    const finish = (r: string) => {
      if (done) return;
      done = true;
      a.pause();
      a.removeAttribute("src");
      resolve(r);
    };
    a.addEventListener("timeupdate", () => a.currentTime >= 0.3 && finish(`+${Math.round(performance.now() - t0)}`));
    a.addEventListener("error", () => finish(`-err${a.error?.code ?? ""}`));
    setTimeout(() => finish("-timeout"), 4000);
    a.play().catch((e: Error) => finish(`-${e.name}`));
  });
}

async function cacheTest(): Promise<string> {
  try {
    const c = await caches.open("audiojoe-testcar");
    await c.add("/testcar/tone.mp3");
    const r = await c.match("/testcar/tone.mp3");
    if (!r) return "-nomatch";
    const url = URL.createObjectURL(await r.blob());
    const res = await playShort(url);
    URL.revokeObjectURL(url);
    return res;
  } catch (e) {
    return `-${(e as Error).name}`;
  }
}

// ---------------------------------------------------------------- media session

const loop = new Audio("/testcar/loop.mp3");
loop.loop = true;
loop.volume = 0.6;
const ACTIONS: MediaSessionAction[] = ["play", "pause", "stop", "previoustrack", "nexttrack", "seekbackward", "seekforward", "seekto"];
const handlers: Record<string, () => void> = {};
let hiddenPlayed = 0;
let lastTime = 0;
loop.addEventListener("timeupdate", () => {
  const d = loop.currentTime - lastTime;
  lastTime = loop.currentTime;
  if (document.hidden && d > 0 && d < 5) hiddenPlayed += d;
});
loop.addEventListener("pause", () => record("el:pause"));
loop.addEventListener("play", () => record("el:play"));
document.addEventListener("visibilitychange", () => record(document.hidden ? "vis:hidden" : "vis:visible"));
addEventListener("keydown", (e: KeyboardEvent) => { if (/^(Media|AudioVolume)/.test(e.key)) record(`key:${e.key}`); });

function startLoop() {
  if ("mediaSession" in navigator) {
    navigator.mediaSession.metadata = new MediaMetadata({
      title: "audiojoe Test", artist: "audiojoe", album: t("Car test"),
      artwork: [{ src: "/icon-512.png", sizes: "512x512", type: "image/png" }],
    });
    for (const a of ACTIONS) {
      const fn = () => {
        record(a);
        if (a === "pause" || a === "stop") loop.pause();
        if (a === "play") void loop.play();
        navigator.mediaSession.playbackState = loop.paused ? "paused" : "playing";
      };
      handlers[a] = fn;
      try {
        navigator.mediaSession.setActionHandler(a, fn);
      } catch {
        result.unsupported.push(a);
      }
    }
  }
  return resume();
}
async function resume() {
  if (loop.paused) await loop.play().catch(() => undefined);
  if ("mediaSession" in navigator) navigator.mediaSession.playbackState = "playing";
}

// ---------------------------------------------------------------- screens

function setStatus(s: string) {
  status.textContent = s;
}

async function startScreen() {
  setStatus(t("About 1 minute · only when parked"));
  const saved = JSON.parse(store.get("audiojoe-testcar-vehicle") ?? "{}");
  const field = (label: string, key: "make" | "model" | "year", ph: string, numeric = false) => {
    const input = document.createElement("input");
    input.value = saved[key] ?? (key === "make" && tesla ? "Tesla" : "");
    input.placeholder = ph;
    input.name = key;
    if (numeric) { input.inputMode = "numeric"; input.maxLength = 4; }
    input.addEventListener("input", check);
    return { wrap: h("div", {}, h("label", {}, label), input), input };
  };
  const make = field(t("Make"), "make", t("e.g. Tesla"));
  const model = field(t("Model"), "model", t("e.g. Model 3 Highland"));
  const year = field(t("Year"), "year", t("e.g. 2024"), true);
  const start = h("button", { textContent: `▶ ${t("Start test")}`, disabled: true, id: "start" });
  function check() {
    start.disabled = !(make.input.value.trim() && model.input.value.trim() && /^(19|20)\d\d$/.test(year.input.value.trim()));
  }
  check();
  const measured = h("div", { className: "kv" });
  app.replaceChildren(
    h("p", { className: "lead" }, t("Checks whether audiojoe plays in this car and can be controlled from the car's music display and the steering wheel. At the end the page shows a QR code – take a photo of it and a mail with the results opens.")),
    h("div", { className: "grp" }, h("h3", {}, t("Your vehicle")),
      h("div", { className: "fields" }, make.wrap, model.wrap, year.wrap),
      h("div", { className: "small gap" }, t("All three fields are needed so the result can be assigned."))),
    h("div", { className: "grp" }, h("h3", {}, t("Measured already")), measured),
    h("div", { className: "actions" }, start, h("span", { className: "small" }, t("Keep the volume low, the sound is a beep."))),
  );
  await environment();
  const e = result.env;
  measured.append(
    h("span", {}, t("Screen / window")), h("span", {}, e.screen),
    h("span", {}, t("Operation")), h("span", {}, e.input),
    h("span", {}, t("Features")), h("span", {}, e.features),
    h("span", {}, t("Audio output")), h("span", {}, audioRate ? `${audioRate} Hz` : "?"),
    h("span", {}, t("Earlier visit")), h("span", {}, e.earlier === "first" ? t("first visit") : e.earlier),
  );
  await new Promise<void>((r) => (start.onclick = () => r()));
  result.vehicle = { make: make.input.value.trim(), model: model.input.value.trim(), year: year.input.value.trim() };
  store.set("audiojoe-testcar-vehicle", JSON.stringify(result.vehicle));
}

async function formatsScreen() {
  setStatus(t("Step {n} of {m}", { n: 1, m: 4 }));
  const chips = h("div", { className: "chips" });
  app.replaceChildren(h("div", { className: "ask" }, h("div", {}, h("div", { className: "big" }, t("Testing formats…")),
    h("div", { className: "small" }, t("{n} short beeps, then one from the cache.", { n: FORMATS.length })))), chips);
  result.env.audio += ` ${await audioRunning()}`;
  for (const [label, id, file] of FORMATS) {
    step = `fmt-${id}`;
    const r = await playShort(`/testcar/${file}`);
    result.formats.push(`${id}${r}`);
    // Above the output rate: plays, but converted down by the browser.
    const down = r.startsWith("+") && STAGES.some(([l, i]) => i === id && resampled(l));
    chips.append(h("span", { className: down ? "chip warn" : r.startsWith("+") ? "chip ok" : "chip bad" },
      `${label} ${down ? t("resampled") : r.startsWith("+") ? "✓" : "✗"}`));
  }
  step = "cache";
  result.cache = await cacheTest();
  chips.append(h("span", { className: result.cache.startsWith("+") ? "chip ok" : "chip bad" }, `${t("Cache")} ${result.cache.startsWith("+") ? "✓" : "✗"}`));
  await startLoop();
  return chips;
}

const SHOWN: [string, string, string][] = [
  ["bar", t("Music bar on the centre screen"), t("e.g. mini player in a Tesla, media card in a Polestar, Volvo, Zeekr")],
  ["cluster", t("Instrument cluster behind the steering wheel"), t("display in front of the driver")],
  ["hud", t("Head-up display"), t("shown in the windscreen")],
  ["none", t("Nowhere"), t("only here in the browser")],
];

async function shownScreen(chips: HTMLElement) {
  setStatus(t("Step {n} of {m}", { n: 2, m: 4 }));
  step = "shown";
  const sel = new Set<string>(tesla ? ["bar"] : []);
  const next = h("button", { textContent: t("Next step"), id: "next" });
  const opts = h("div", { className: "opts" });
  const draw = () => {
    opts.replaceChildren(...SHOWN.map(([id, title, sub]) => h("button", {
      className: sel.has(id) ? "opt on" : "opt", id: `opt-${id}`,
      onclick: () => {
        if (sel.has(id)) sel.delete(id);
        else if (id === "none") { sel.clear(); sel.add(id); }
        else { sel.delete("none"); sel.add(id); }
        draw();
      },
    }, h("span", { className: "bx" }, sel.has(id) ? "✓" : ""), h("span", {}, title, h("small", {}, sub)))));
    next.disabled = sel.size === 0;
  };
  draw();
  app.replaceChildren(chips,
    h("div", { className: "ask" }, h("div", {}, h("div", { className: "big" }, t("Where do you see “audiojoe Test” now?")),
      h("div", {}, t("Tap everything that applies – outside this browser")))),
    opts,
    h("div", { className: "actions" }, next, tesla ? h("span", { className: "small" }, t("“Music bar” is preselected in a Tesla.")) : null));
  await new Promise<void>((r) => (next.onclick = () => r()));
  result.shown = SHOWN.map(([id]) => id).filter((id) => sel.has(id));
}

type Prompt = { id: string; label: string; big: string; sub: string; wheel: boolean };
const PROMPTS: Prompt[] = [
  { id: "bar-next", label: t("Music bar {next}"), big: t("Tap {next} in the music bar"), sub: t("on the centre screen, where “audiojoe Test” is shown – not here in the browser"), wheel: false },
  { id: "bar-prev", label: t("Music bar {prev}"), big: t("Tap {prev} in the music bar"), sub: t("on the centre screen, where “audiojoe Test” is shown – not here in the browser"), wheel: false },
  { id: "bar-pause", label: t("Music bar {pause} / {stop}"), big: t("Tap {pause} or {stop} in the music bar"), sub: t("on the centre screen, where “audiojoe Test” is shown – not here in the browser"), wheel: false },
  { id: "wheel-next", label: t("Steering wheel: next"), big: t("Press “next” on the steering wheel"), sub: t("the button for the next track"), wheel: true },
  { id: "wheel-pause", label: t("Steering wheel: pause"), big: t("Press pause on the steering wheel"), sub: t("or play/pause; in some cars pressing the volume roller"), wheel: true },
];
const WAIT_S = 8;
let noWheel = false;

async function buttonsScreen() {
  setStatus(t("Step {n} of {m}", { n: 3, m: 4 }));
  const prompts = PROMPTS.filter((p) => p.wheel || result.shown.includes("bar"));
  const res = new Map<string, string>();
  const list = h("ul", { className: "chk" });
  const ask = h("div", { className: "ask" });
  const skip = h("button", { className: "sec", textContent: t("Continue without press"), id: "skip" });
  const none = h("button", { className: "sec", textContent: t("No music buttons on the steering wheel"), id: "nowheel" });
  const drawList = (cur: string) => list.replaceChildren(...prompts.map((p) => {
    const r = res.get(p.id);
    const mark = p.id === cur ? h("span", { className: "m warn" }, "▶")
      : r === undefined ? h("span", { className: "m" }, "·")
        : r.startsWith("-") || r === "none" ? h("span", { className: "m bad" }, "✗") : h("span", { className: "m ok" }, "✓");
    const note = r === undefined ? "" : r === "none" ? ` – ${t("no buttons")}` : r.startsWith("-") ? ` – ${t("not arrived")}` : ` – ${t("arrived as “{a}”", { a: r })}`;
    const li = h("li", {}, mark, withIcons(p.label), note);
    if (p.id === cur) li.style.fontWeight = "700";
    return li;
  }));
  app.replaceChildren(ask, h("div", { className: "grp" }, list),
    h("div", { className: "small" }, t("If nothing arrives, the test moves on after {n} s. Every press is logged with its time.", { n: WAIT_S })),
    h("div", { className: "actions" }, skip, none));
  for (const p of prompts) {
    if (p.wheel && noWheel) { res.set(p.id, "none"); continue; }
    step = p.id;
    await resume();
    drawList(p.id);
    const cnt = h("div", { className: "cnt" }, String(WAIT_S));
    ask.replaceChildren(h("div", {}, h("div", { className: "big" }, withIcons(p.big)), h("div", {}, p.sub)), cnt);
    const got: string[] = [];
    const r = await new Promise<string>((resolve) => {
      let left = WAIT_S;
      const timer = setInterval(() => {
        left--;
        cnt.textContent = String(left);
        if (left <= 0) end(got.length ? got.join(",") : "-");
      }, 1000);
      let settle: ReturnType<typeof setTimeout> | undefined;
      function end(v: string) {
        clearInterval(timer);
        clearTimeout(settle);
        onAction = null;
        resolve(v);
      }
      // Collect everything a single press triggers (e.g. pause plus stop), then move on.
      onAction = (a) => { got.push(a); clearTimeout(settle); settle = setTimeout(() => end(got.join(",")), 700); };
      skip.onclick = () => end(got.length ? got.join(",") : "-skip");
      none.onclick = () => { noWheel = true; end(p.wheel ? "none" : got.length ? got.join(",") : "-skip"); };
    });
    res.set(p.id, r);
  }
  drawList("");
  result.steps = prompts.map((p) => [p.id, res.get(p.id) ?? "-"]);
}

async function backgroundScreen() {
  setStatus(t("Step {n} of {m}", { n: 4, m: 4 }));
  step = "bg";
  await resume();
  const skip = h("button", { className: "sec", textContent: t("Skip"), id: "skipbg" });
  const later = h("button", { textContent: t("Next step"), id: "bgnext", hidden: true });
  app.replaceChildren(
    h("div", { className: "ask" }, h("div", {}, h("div", { className: "big" }, t("Minimise the browser")),
      h("div", {}, noWheel ? t("then open the browser again after about 10 seconds")
        : t("then press “next” on the steering wheel once and open the browser again")))),
    h("div", { className: "small" }, t("The page notices minimising and coming back by itself.")),
    h("div", { className: "actions" }, skip, later));
  const later20 = setTimeout(() => (later.hidden = false), 20000);
  const from = log.length;
  let hiddenAt = 0;
  const r = await new Promise<string>((resolve) => {
    const onVis = () => {
      if (document.hidden) { hiddenAt = performance.now(); hiddenPlayed = 0; lastTime = loop.currentTime; return; }
      if (!hiddenAt) return;
      document.removeEventListener("visibilitychange", onVis);
      const away = Math.round((performance.now() - hiddenAt) / 1000);
      const acts = log.slice(from).filter((e) => !e.a.startsWith("vis:")).map((e) => e.a);
      resolve(`away ${away}s played ${Math.round(hiddenPlayed)}s ${loop.paused ? "paused" : "playing"} acts ${acts.join(",") || "-"}`);
    };
    document.addEventListener("visibilitychange", onVis);
    skip.onclick = later.onclick = () => { document.removeEventListener("visibilitychange", onVis); resolve("-skip"); };
  });
  clearTimeout(later20);
  result.bg = r;
  loop.pause();
  if ("mediaSession" in navigator) navigator.mediaSession.playbackState = "none";
}

// ---------------------------------------------------------------- mail and QR

function mailText(): { subject: string; body: string; full: string } {
  const v = result.vehicle;
  const d = new Date();
  const date = d.toLocaleDateString(navigator.language.toLowerCase().startsWith("de") ? "de-DE" : "en-GB");
  const subject = `audiojoe testcar ${date} ${browserName()}`;
  // Only what the result lines do not say already: presses outside a prompt, keys, minimising.
  const prompted = new Set(result.steps.map(([id]) => id));
  const ev = log.filter((e) => !e.a.startsWith("el:") && !prompted.has(e.step))
    .map((e) => `${e.a.replace(/^vis:/, "v:")}@${(e.t / 1000).toFixed(1)}`);
  const lines = (ua: string) => [
    `audiojoe testcar 1${result.server ? ` server ${result.server}` : ""}`,
    `car: ${v.make} / ${v.model} / ${v.year}`,
    `when: ${d.toISOString().slice(0, 16)}Z, ${Math.round(now() / 1000)}s`,
    `ua: ${ua}`,
    `screen: ${result.env.screen}`,
    `input: ${result.env.input}`,
    `feat: ${result.env.features}`,
    `earlier: ${result.env.earlier}`,
    `audio: ${mailAudio()}`,
    `formats: ${result.formats.filter((f) => !STAGES.some(([, id]) => f.startsWith(`${id}+`) || f.startsWith(`${id}-`))).join(" ")}`,
    `pcm: ${mailStages()}`,
    `cache: ${result.cache}`,
    `shown: ${result.shown.join(",")}`,
    ...result.steps.map(([id, r]) => `${id}: ${r}`),
    `bg: ${result.bg}`,
    result.unsupported.length ? `unsupported: ${result.unsupported.join(",")}` : "",
  ].filter(Boolean);
  // The event log is cut so the QR code stays coarse enough to read from a photo: at most
  // QR_MODULES modules, so 800×480 still has 4 pixels per module (user 2026-11-08, "81 ja").
  // The QR code names only browser and car of the user agent (user 2026-11-09, "94 ja").
  let body = lines(shortUa(result.env.ua)).join("\n");
  const rest = ev.slice();
  let logLine = `log: ${rest.join(" ") || "-"}`;
  while (qrModules(mailUrl({ subject, body: body + "\n" + logLine })) > QR_MODULES && rest.length) {
    rest.pop();
    logLine = `log:${rest.length ? ` ${rest.join(" ")}` : ""}(cut)`;
  }
  // "Show mail text" keeps the whole log (user 2026-11-07 "3 ja"); only the QR code is cut.
  const full = `${lines(result.env.ua).join("\n")}\nlog: ${ev.join(" ") || "-"}`;
  body += `\n${logLine}`;
  return { subject, body, full };
}

/** Browser and car of a user agent for the QR code, e.g. "Chrome/136 Tesla/2025.32.3"; the whole one
 *  when none of them is in it. */
export function shortUa(ua: string): string {
  const browser = ua.match(/(Edg|OPR|Firefox|Chrome|Chromium|QtWebEngine)\/(\d+)/) ?? ua.match(/\bVersion\/(\d+)[^ ]* (Safari)\//);
  const name = browser ? (browser[2] === "Safari" ? `Safari/${browser[1]}` : `${browser[1]}/${browser[2]}`) : "";
  const car = ua.match(/\bTesla\/[\w.-]+/)?.[0] ?? "";
  const short = [name, car].filter(Boolean).join(" ");
  return short || ua;
}

/** Percent-encoding for a mailto header value: only what RFC 6068 requires (/ : , ; = @ stay as they are). */
function mailEncode(s: string) {
  return encodeURI(s).replace(/[&#?+]/g, (c) => `%${c.charCodeAt(0).toString(16).toUpperCase()}`);
}

function mailUrl(m: { subject: string; body: string }) {
  return `mailto:?subject=${mailEncode(m.subject)}&body=${mailEncode(m.body)}`;
}

/** QR version 19 (93 modules): the largest that keeps 4 pixels per module at 800×480. */
const QR_MODULES = 93;

/** Modules per side of the code for `data` (level L); Infinity when it does not fit at all. */
function qrModules(data: string): number {
  try {
    const q = qrcode(0, "L");
    q.addData(data);
    q.make();
    return q.getModuleCount();
  } catch {
    return Infinity;
  }
}

function qrSvg(data: string): string {
  // Level L keeps the code coarse; a screen photo has no dirt or folds to repair.
  for (const level of ["L"] as const) {
    try {
      const q = qrcode(0, level);
      q.addData(data);
      q.make();
      return q.createSvgTag({ cellSize: 4, margin: 0, scalable: true });
    } catch { /* too long for this level */ }
  }
  return "";
}

function endScreen() {
  setStatus(t("done · {n} s", { n: Math.round(now() / 1000) }));
  step = "end";
  const m = mailText();
  const url = mailUrl(m);
  const qr = h("div", { className: "qr", id: "qr" });
  qr.innerHTML = qrSvg(url);
  const ok = (r: string) => !r.startsWith("-") && r !== "none";
  const bar = result.steps.filter(([id]) => id.startsWith("bar-"));
  const wheel = result.steps.filter(([id]) => id.startsWith("wheel-"));
  const formatsOk = result.formats.filter((f) => f.includes("+")).length;
  const failed = FORMATS.filter(([, id]) => !result.formats.find((f) => f.startsWith(`${id}+`))).map(([l]) => l);
  const [bits, khz] = highestStage().split("/");
  const downKhz = [...new Set(STAGES.filter(([label, id]) => resultOf(id).startsWith("+") && resampled(label)).map(([label]) => stageKhz(label)))];
  const khzText = khz === "44" ? (navigator.language.toLowerCase().startsWith("de") ? "44,1" : "44.1") : khz;
  const count = (l: [string, string][]) => l.length && l.every(([, r]) => r === "none")
    ? h("span", {}, t("no buttons"))
    : h("span", { className: l.filter(([, r]) => ok(r)).length === l.length ? "ok" : "bad" },
      t("{n} of {m}", { n: l.filter(([, r]) => ok(r)).length, m: l.length }));
  const shownLabel = result.shown.map((id) => SHOWN.find(([s]) => s === id)![1]).join(", ");
  const kv = h("div", { className: "kv" },
    h("span", {}, t("Vehicle")), h("span", {}, `${result.vehicle.make} ${result.vehicle.model}, ${result.vehicle.year}`),
    h("span", {}, t("Formats")), h("span", { className: failed.length ? "bad" : "ok" },
      `${t("{n} of {m}", { n: formatsOk, m: FORMATS.length })}${failed.length ? ` (${failed.join(", ")} ✗)` : ""}`),
    h("span", {}, t("Audio output")), h("span", {}, audioRate ? `${audioRate} Hz` : "?"),
    h("span", {}, t("Highest stage")), h("span", { className: bits ? "" : "bad", id: "stage" },
      bits ? t("{b} bit / {k} kHz", { b: bits, k: khzText }) : "✗"),
    ...(downKhz.length ? [h("span", {}, t("Resampled")), h("span", { className: "warn", id: "resampled" }, `${downKhz.join(", ")} kHz`)] : []),
    h("span", {}, t("Cache")), h("span", { className: result.cache.startsWith("+") ? "ok" : "bad" }, result.cache.startsWith("+") ? "✓" : "✗"),
    h("span", {}, t("Music shown")), h("span", {}, shownLabel),
    ...(bar.length ? [h("span", {}, t("Music bar")), count(bar)] : []),
    h("span", {}, t("Steering wheel")), count(wheel),
    h("span", {}, t("Background")), h("span", { className: result.bg.startsWith("-") ? "" : result.bg.includes("playing") ? "ok" : "bad" },
      result.bg.startsWith("-") ? t("skipped") : result.bg.includes("playing") ? t("sound kept playing") : t("sound stopped")));
  const pre = h("pre", { hidden: true, id: "mailtext" }, `${m.subject}\n\n${m.full}`);
  const show = h("button", { className: "sec", textContent: t("Show mail text"), onclick: () => (pre.hidden = !pre.hidden) });
  const again = h("button", { className: "sec", textContent: t("Repeat test"), onclick: () => location.reload() });
  app.replaceChildren(
    h("div", { className: "end" }, qr, h("div", { className: "endcol" },
      h("div", { className: "endtitle" }, t("Take a photo with your phone")),
      h("div", { className: "small" }, t("The camera opens a mail with the subject “{s}” and all results. Enter the recipient yourself and send it.", { s: m.subject })),
      h("div", { className: "grp" }, kv))),
    pre,
    h("div", { className: "actions" }, show, again));
  return { url, ...m };
}

// ---------------------------------------------------------------- run

async function run() {
  await startScreen();
  const chips = await formatsScreen();
  await shownScreen(chips);
  await buttonsScreen();
  await backgroundScreen();
  return endScreen();
}

const done = run();
if (AUTO) {
  // Test hooks: fire media actions, simulate minimising (headless pages are never hidden).
  let fakeHidden = false;
  Object.defineProperty(document, "hidden", { configurable: true, get: () => fakeHidden });
  (window as unknown as Record<string, unknown>).__testcar = {
    // Like a press in the car: through the registered handler, else as a raw event (keys).
    fire: (a: string) => (handlers[a] ? handlers[a]() : record(a)),
    hide: () => { fakeHidden = true; document.dispatchEvent(new Event("visibilitychange")); },
    show: () => { fakeHidden = false; document.dispatchEvent(new Event("visibilitychange")); },
    step: () => step,
    result,
    log,
    done,
  };
}
