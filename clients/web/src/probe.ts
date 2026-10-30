// Browser capability probe (stage 0).
// Guided test for the Tesla in-car browser: environment, playback of the test formats,
// offline cache, persistence across visits, background playback and Media Session.
// Every step sends its result to the server. With ?auto=1 the page runs unattended
// (headless tests against the fake source) and exposes the report as window.__probe.

import { download, type DownloadReport } from "./downloader";
import { offlineUrl, removeOffline, storeOffline } from "./offline";

const params = new URLSearchParams(location.search);
const TOKEN = params.get("t") ?? "";
const AUTO = params.get("auto") === "1";
const STREAM = "/api/v1/probe/stream/";
const FORMATS = ["mp3.mp3", "aac.m4a", "flac16_44.flac", "flac24_96.flac"] as const;
const MIME: Record<string, string> = {
  "mp3.mp3": "audio/mpeg",
  "aac.m4a": 'audio/mp4; codecs="mp4a.40.2"',
  "flac16_44.flac": "audio/flac",
  "flac24_96.flac": "audio/flac",
};

// ---------------------------------------------------------------- texts (en base, de)

const de = navigator.language.toLowerCase().startsWith("de");
const T = {
  title: ["audiojoe – browser probe", "audiojoe – Browser-Messung"],
  lead: [
    "Run the steps from top to bottom. Results are sent to the server automatically.",
    "Schritte von oben nach unten ausführen. Die Ergebnisse gehen automatisch an den Server.",
  ],
  context: ["Situation:", "Situation:"],
  parked: ["Parked", "Im Stand"],
  driving: ["Driving", "Während der Fahrt"],
  s1: ["1 · Environment", "1 · Umgebung"],
  s1p: ["Measured automatically when the page opens.", "Wird beim Öffnen automatisch gemessen."],
  s2: ["2 · Playback", "2 · Wiedergabe"],
  s2p: ["Plays four short test tones (about 4 s each, quiet).", "Spielt vier kurze Testtöne (je etwa 4 s, leise)."],
  s3: ["3 · Offline cache", "3 · Offline-Cache"],
  s3p: [
    "Downloads two files into the browser cache, one of them over a deliberately interrupted connection, then plays from the cache.",
    "Lädt zwei Dateien in den Browser-Cache, eine davon über eine absichtlich abreißende Verbindung, und spielt sie aus dem Cache.",
  ],
  s4: ["4 · Background", "4 · Hintergrund"],
  s4p: [
    "Press start, then minimise the browser for about 20 seconds and open it again.",
    "Start drücken, dann den Browser etwa 20 Sekunden minimieren und wieder öffnen.",
  ],
  s5: ["5 · Mini player", "5 · Miniplayer"],
  s5p: [
    'While step 4 plays: does the car\'s media mini player show "audiojoe probe"?',
    "Während Schritt 4 spielt: Zeigt der Miniplayer des Autos „audiojoe probe“?",
  ],
  s6: ["6 · After sleep or restart", "6 · Nach Schlaf oder Neustart"],
  s6p: [
    "Open this page again later (next day, after the car slept or after an update). Step 1 then shows whether the cache survived.",
    "Diese Seite später erneut öffnen (am nächsten Tag, nach dem Schlafen des Autos oder nach einem Update). Schritt 1 zeigt dann, ob der Cache überlebt hat.",
  ],
  start: ["Start", "Starten"],
  stop: ["Stop", "Stoppen"],
  yes: ["Yes", "Ja"],
  no: ["No", "Nein"],
  sent: ["Sent to server", "An den Server gesendet"],
  sendFail: ["Sending failed – will retry with the next step", "Senden fehlgeschlagen – wird mit dem nächsten Schritt wiederholt"],
  noToken: ["No token in the URL – results cannot be sent.", "Kein Token in der Adresse – Ergebnisse können nicht gesendet werden."],
  running: ["Running…", "Läuft…"],
};
const t = (k: keyof typeof T) => T[k][de ? 1 : 0];

// ---------------------------------------------------------------- report

type Json = Record<string, unknown>;
const report: Json = { version: 1, started: new Date().toISOString(), context: "parked", steps: {} };
const steps = report.steps as Json;
const pending: Json[] = [];

async function send(step: string, data: Json) {
  steps[step] = data;
  pending.push({ step, context: report.context, at: new Date().toISOString(), data });
  if (AUTO) return;
  if (!TOKEN) return setStatus(t("noToken"), "bad");
  try {
    const res = await fetch(`/api/v1/probe/results?t=${encodeURIComponent(TOKEN)}`, {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ items: pending }),
    });
    if (!res.ok) throw new Error(String(res.status));
    pending.length = 0;
    setStatus(`${t("sent")} · ${new Date().toLocaleTimeString()}`, "ok");
  } catch {
    setStatus(t("sendFail"), "warn");
  }
}

// ---------------------------------------------------------------- UI helpers

const app = document.getElementById("app")!;
function setStatus(text: string, cls = "") {
  const s = document.getElementById("status")!;
  s.textContent = text;
  s.className = cls;
}
function el<K extends keyof HTMLElementTagNameMap>(tag: K, props: Partial<HTMLElementTagNameMap[K]> = {}, ...kids: (Node | string)[]) {
  const e = Object.assign(document.createElement(tag), props);
  e.append(...kids);
  return e;
}
function stepBox(title: string, text: string) {
  const out = el("div", { className: "out" });
  const row = el("div", { className: "row" });
  app.append(el("section", { className: "step" }, el("h2", {}, title), el("p", {}, text), row, out));
  return { row, out };
}
function show(out: HTMLElement, data: Json) {
  out.replaceChildren();
  for (const [k, v] of Object.entries(data)) {
    const val = typeof v === "object" ? JSON.stringify(v) : String(v);
    const cls = v === true ? "ok" : v === false ? "bad" : "";
    out.append(el("span", { className: "k" }, k), el("span", { className: cls }, val));
  }
}

// ---------------------------------------------------------------- step 1: environment

const MARKER_DB = "audiojoe-probe";
const MARKER_CACHE = "audiojoe-probe-marker";

function idb<T>(fn: (store: IDBObjectStore) => IDBRequest<T>): Promise<T> {
  return new Promise((resolve, reject) => {
    const open = indexedDB.open(MARKER_DB, 1);
    open.onupgradeneeded = () => open.result.createObjectStore("kv");
    open.onerror = () => reject(open.error);
    open.onsuccess = () => {
      const req = fn(open.result.transaction("kv", "readwrite").objectStore("kv"));
      req.onsuccess = () => resolve(req.result);
      req.onerror = () => reject(req.error);
    };
  });
}

async function environment(): Promise<Json> {
  const d: Json = {
    userAgent: navigator.userAgent,
    viewport: `${innerWidth}×${innerHeight}`,
    screen: `${screen.width}×${screen.height}`,
    devicePixelRatio: devicePixelRatio,
    language: navigator.language,
    secureContext: isSecureContext,
    serviceWorker: "serviceWorker" in navigator,
    cacheStorage: "caches" in self,
    indexedDB: "indexedDB" in self,
    mediaSession: "mediaSession" in navigator,
    storageManager: !!navigator.storage?.estimate,
  };
  const a = document.createElement("audio");
  d.canPlay = Object.fromEntries(FORMATS.map((f) => [f, a.canPlayType(MIME[f]) || "no"]));
  try {
    const e = await navigator.storage.estimate();
    d.quotaMB = Math.round((e.quota ?? 0) / 2 ** 20);
    d.usageMB = Math.round((e.usage ?? 0) / 2 ** 20);
    d.persisted = await navigator.storage.persisted();
    d.persistGranted = await navigator.storage.persist();
  } catch (e) {
    d.storageError = String(e);
  }
  // Marker from an earlier visit: shows whether storage survives sleep, restart, update.
  try {
    d.markerIndexedDB = (await idb((s) => s.get("visit"))) ?? "none";
    await idb((s) => s.put(new Date().toISOString(), "visit"));
  } catch (e) {
    d.markerIndexedDB = `error: ${e}`;
  }
  try {
    const c = await caches.open(MARKER_CACHE);
    const old = await c.match("/marker");
    d.markerCache = old ? await old.text() : "none";
    await c.put("/marker", new Response(new Date().toISOString()));
    const offline = await (await caches.open("audiojoe-offline-v1")).keys();
    d.offlineFilesFromEarlier = offline.length;
  } catch (e) {
    d.markerCache = `error: ${e}`;
  }
  return d;
}

// ---------------------------------------------------------------- playback

function playFor(src: string, seconds: number): Promise<Json> {
  return new Promise((resolve) => {
    const a = new Audio();
    a.volume = 0.25;
    const started = performance.now();
    let playingAt = 0;
    const finish = (d: Json) => {
      a.pause();
      a.removeAttribute("src");
      a.load();
      resolve({ ...d, startMs: playingAt ? Math.round(playingAt - started) : null });
    };
    const timeout = setTimeout(() => finish({ ok: false, error: "timeout", currentTime: a.currentTime }), (seconds + 10) * 1000);
    a.onplaying = () => {
      if (playingAt) return;
      playingAt = performance.now();
      setTimeout(() => {
        clearTimeout(timeout);
        finish({ ok: a.currentTime >= seconds * 0.6, currentTime: Math.round(a.currentTime * 10) / 10 });
      }, seconds * 1000);
    };
    a.onerror = () => {
      clearTimeout(timeout);
      finish({ ok: false, error: `media error ${a.error?.code}: ${a.error?.message ?? ""}` });
    };
    a.src = src;
    a.play().catch((e) => {
      clearTimeout(timeout);
      finish({ ok: false, error: `play(): ${e?.name ?? e}` });
    });
  });
}

async function playback(): Promise<Json> {
  const d: Json = {};
  for (const f of FORMATS) d[f] = await playFor(STREAM + f, 4);
  return d;
}

// ---------------------------------------------------------------- offline cache

async function ensureServiceWorker(): Promise<Json> {
  if (!("serviceWorker" in navigator)) return { registered: false };
  try {
    await navigator.serviceWorker.register("/sw.js");
    await navigator.serviceWorker.ready;
    if (!navigator.serviceWorker.controller) {
      await new Promise<void>((r) => {
        navigator.serviceWorker.addEventListener("controllerchange", () => r(), { once: true });
        setTimeout(r, 5000);
      });
    }
    return { registered: true, controlling: !!navigator.serviceWorker.controller };
  } catch (e) {
    return { registered: false, error: String(e) };
  }
}

const brief = (r: DownloadReport) => ({
  ok: r.ok, bytes: r.bytes, attempts: r.attempts, restarts: r.restarts, stalls: r.stalls, verified: r.verified, ms: r.ms, error: r.error,
});

async function offlineCache(onProgress: (s: string) => void): Promise<Json> {
  const d: Json = { serviceWorker: await ensureServiceWorker() };
  const jobs: [string, string][] = [
    ["mp3.mp3", STREAM + "mp3.mp3"],
    // Connection drops after every 1.5 MB: the download has to resume several times.
    ["flac24_96.flac", STREAM + "flac24_96.flac?abort_after=1500000"],
  ];
  for (const [key, url] of jobs) {
    const { blob, report: r } = await download(url, {
      onProgress: (b, total) => onProgress(`${key}: ${(b / 2 ** 20).toFixed(1)} / ${total ? (total / 2 ** 20).toFixed(1) : "?"} MB`),
    });
    d[`download ${key}`] = brief(r);
    if (!blob || !r.ok) continue;
    try {
      await removeOffline(key);
      await storeOffline(key, blob);
      const probe = await fetch(offlineUrl(key), { headers: { Range: "bytes=0-99" } });
      d[`cache ${key}`] = { stored: true, status: probe.status, fromServiceWorker: probe.headers.get("x-from-cache") === "1" };
      d[`play from cache ${key}`] = await playFor(offlineUrl(key), 4);
    } catch (e) {
      d[`cache ${key}`] = { stored: false, error: String(e) };
    }
  }
  try {
    const e = await navigator.storage.estimate();
    d.usageAfterMB = Math.round((e.usage ?? 0) / 2 ** 20);
  } catch { /* reported in step 1 */ }
  return d;
}

// ---------------------------------------------------------------- automatic fault tests

const FAULTS: [string, string, number][] = [
  ["clean", "flac24_96.flac", 15000],
  ["abort_after=1000000", "flac24_96.flac?abort_after=1000000", 15000],
  ["stall 4 s (stall timeout 1.5 s)", "flac16_44.flac?stall_at=200000&stall_ms=4000", 1500],
  ["server ignores Range", "flac24_96.flac?no_range=1", 15000],
  ["Content-Length too large", "aac.m4a?lie_length=1", 15000],
  ["first 2 requests 503", "mp3.mp3?fail_first=2", 15000],
  ["throttled 400 kB/s", "mp3.mp3?rate=400000", 15000],
  ["abort + throttle", "flac16_44.flac?abort_after=250000&rate=500000", 15000],
];

async function faultTests(): Promise<Json> {
  const d: Json = {};
  const run = Date.now();
  for (const [name, path, stallMs] of FAULTS) {
    // Unique query per run so fail_first counts from zero.
    const sep = path.includes("?") ? "&" : "?";
    const { report: r } = await download(`${STREAM}${path}${sep}run=${run}`, { stallMs, backoffMs: 200, maxAttempts: 12 });
    d[name] = brief(r);
  }
  return d;
}

// ---------------------------------------------------------------- background + media session

let bg: { audio: HTMLAudioElement; log: Json[]; hiddenAt?: number; hiddenTime?: number } | null = null;

function startBackground() {
  const audio = new Audio(STREAM + "mp3.mp3");
  audio.loop = true;
  audio.volume = 0.25;
  bg = { audio, log: [] };
  if ("mediaSession" in navigator) {
    navigator.mediaSession.metadata = new MediaMetadata({ title: "audiojoe probe", artist: "audiojoe", album: "Test" });
  }
  void audio.play();
}

document.addEventListener("visibilitychange", () => {
  if (!bg) return;
  const now = performance.now();
  if (document.hidden) {
    bg.hiddenAt = now;
    bg.hiddenTime = bg.audio.currentTime;
  } else if (bg.hiddenAt !== undefined) {
    const away = (now - bg.hiddenAt) / 1000;
    // With loop the position wraps every 30 s; only short absences are comparable.
    const advanced = (bg.audio.currentTime - (bg.hiddenTime ?? 0) + 30) % 30;
    bg.log.push({ awaySeconds: Math.round(away), positionAdvanced: Math.round(advanced), playing: !bg.audio.paused });
  }
});

// ---------------------------------------------------------------- page

async function main() {
  document.title = t("title");
  app.append(el("h1", {}, t("title")), el("p", { className: "lead" }, t("lead")));

  const ctx = el("div", { className: "ctx" }, el("span", {}, t("context")));
  const parked = el("button", { className: "on" }, t("parked"));
  const driving = el("button", { className: "sec" }, t("driving"));
  const pick = (c: "parked" | "driving") => {
    report.context = c;
    parked.className = c === "parked" ? "on" : "sec";
    driving.className = c === "driving" ? "on" : "sec";
  };
  parked.onclick = () => pick("parked");
  driving.onclick = () => pick("driving");
  ctx.append(parked, driving);
  app.append(ctx);

  const s1 = stepBox(t("s1"), t("s1p"));
  const env = await environment();
  show(s1.out, env);
  void send("environment", env);

  if (AUTO) {
    const w = window as unknown as { __probe?: Json };
    const play = await playback();
    const faults = await faultTests();
    const cache = await offlineCache(() => {});
    w.__probe = { environment: env, playback: play, faults, offline: cache };
    return;
  }

  const s2 = stepBox(t("s2"), t("s2p"));
  const b2 = el("button", {}, t("start"));
  b2.onclick = async () => {
    b2.disabled = true;
    setStatus(t("running"));
    const d = await playback();
    show(s2.out, d);
    await send("playback", d);
    b2.disabled = false;
  };
  s2.row.append(b2);

  const s3 = stepBox(t("s3"), t("s3p"));
  const b3 = el("button", {}, t("start"));
  b3.onclick = async () => {
    b3.disabled = true;
    const d = await offlineCache((s) => setStatus(s));
    show(s3.out, d);
    await send("offline", d);
    b3.disabled = false;
  };
  s3.row.append(b3);

  const s4 = stepBox(t("s4"), t("s4p"));
  const b4 = el("button", {}, t("start"));
  const b4s = el("button", { className: "sec" }, t("stop"));
  b4.onclick = () => startBackground();
  b4s.onclick = async () => {
    if (!bg) return;
    bg.audio.pause();
    const d = { mediaSession: "mediaSession" in navigator, returns: bg.log };
    bg = null;
    show(s4.out, d);
    await send("background", d);
  };
  s4.row.append(b4, b4s);

  const s5 = stepBox(t("s5"), t("s5p"));
  const answer = (v: boolean) => async () => {
    const d = { miniPlayerShowsTitle: v };
    show(s5.out, d);
    await send("miniplayer", d);
  };
  const y = el("button", {}, t("yes"));
  const n = el("button", { className: "sec" }, t("no"));
  y.onclick = answer(true);
  n.onclick = answer(false);
  s5.row.append(y, n);

  stepBox(t("s6"), t("s6p"));
}

void main();
