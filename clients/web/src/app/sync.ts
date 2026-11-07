// Playback positions: stored locally first, sent to the server when it is reachable,
// changes from other devices arrive via Server-Sent Events.

import { api, onConnection, online, setOnline, type Playback } from "./api";
import { idbAll, idbDel, idbGet, idbPut } from "./idb";

export interface PositionUpdate {
  key: string;
  position_ms: number;
  duration_ms?: number | null;
  finished: boolean;
  updated_at: string;
  title: string;
  subtitle: string;
  /** This device's state, so other devices can take over (the web player takes no commands). */
  state?: "playing" | "paused" | "stopped";
  kind?: "web";
}

type Listener = (p: Playback) => void;
const remoteListeners = new Set<Listener>();
const stateListeners = new Set<() => void>();
export let pendingCount = 0;
/** True once a position has waited more than 30 s for the server; saves that go through in
 *  time never show. Back to false as soon as nothing waits. */
export let stale = false;
let staleTimer: number | undefined;

export const onRemote = (l: Listener) => remoteListeners.add(l);

/** The account's devices as far as "Playing on …" needs them (GET /devices, then event `device`). */
export interface DeviceState { device: string; state: string; key: string; label?: string | null }
const devices = new Map<string, DeviceState>();
const deviceListeners = new Set<() => void>();
export const onDevices = (l: () => void) => deviceListeners.add(l);
export const deviceState = (name: string) => devices.get(name);
/** The name a device is shown with (Settings → Devices → Rename), else its device name. */
export const shownName = (name: string) => devices.get(name)?.label || name;
async function loadDevices() {
  try {
    const list = await api<DeviceState[]>("GET", "/devices");
    devices.clear();
    for (const d of list) devices.set(d.device, d);
    deviceListeners.forEach((l) => l());
  } catch {
    // Unknown until the next event: "Played on …".
  }
}
export const onSyncState = (l: () => void) => stateListeners.add(l);
/** The account's settings changed on some device (event `settings`). */
const settingsListeners = new Set<(e: Record<string, unknown>) => void>();
export const onSettings = (l: (e: Record<string, unknown>) => void) => settingsListeners.add(l);
const notify = () => stateListeners.forEach((l) => l());

export async function localPosition(key: string): Promise<Playback | undefined> {
  return idbGet<Playback>("positions", key);
}

export async function savePosition(u: PositionUpdate) {
  await idbPut("positions", u.key, { ...u, device: "", subtitle: u.subtitle });
  await idbPut("pending", u.key, u);
  await refreshCount();
  void flush();
}

async function refreshCount() {
  pendingCount = (await idbAll("pending")).length;
  if (!pendingCount) {
    clearTimeout(staleTimer);
    staleTimer = undefined;
    stale = false;
  } else if (staleTimer === undefined && !stale) {
    staleTimer = window.setTimeout(() => {
      staleTimer = undefined;
      stale = pendingCount > 0;
      notify();
    }, 30_000);
  }
  notify();
}

let flushing = false;
export async function flush() {
  if (flushing || !online) return;
  flushing = true;
  try {
    const list = await idbAll<PositionUpdate>("pending");
    if (list.length) {
      await api("POST", "/playback", list);
      for (const u of list) {
        // Only remove what was sent; a newer local update keeps waiting.
        const cur = await idbGet<PositionUpdate>("pending", u.key);
        if (cur && cur.updated_at === u.updated_at) await idbDel("pending", u.key);
      }
    }
  } catch {
    /* stays pending */
  } finally {
    flushing = false;
    await refreshCount();
  }
}

let es: EventSource | null = null;
let healthTimer: number | undefined;
let watchTimer: number | undefined;
/** When the stream last delivered anything (an event, or the server's "ping" every 15 s). */
let lastData = 0;
/** A stream without a sign of life for `silenceMs` is dead: a connection the router or a proxy
 *  dropped without notice delivers nothing and never ends. Checked every `everyMs`. */
export const watchdog = { everyMs: 20_000, silenceMs: 45_000 };

export function startSync() {
  void refreshCount();
  connect();
  onConnection(() => {
    notify();
    if (online) void flush();
  });
  addEventListener("online", () => void probe());
  addEventListener("offline", () => setOnline(false));
  // While offline, check every 20 s whether the server is back.
  healthTimer = window.setInterval(() => {
    if (!online) void probe();
  }, 20000);
  // No sign of life for three pings: open a new stream (the old one is closed).
  watchTimer = window.setInterval(() => {
    if (es?.readyState === EventSource.OPEN && Date.now() - lastData > watchdog.silenceMs) connect();
  }, watchdog.everyMs);
}

async function probe() {
  try {
    const r = await fetch("/api/v1/health", { cache: "no-store", credentials: "same-origin" });
    setOnline(r.ok);
    if (r.ok && (!es || es.readyState === EventSource.CLOSED)) connect();
  } catch {
    setOnline(false);
  }
}

function connect() {
  es?.close();
  es = new EventSource("/api/v1/events?kind=web");
  lastData = Date.now();
  const alive = () => (lastData = Date.now());
  es.onopen = () => {
    alive();
    setOnline(true);
    void loadDevices();
  };
  es.onerror = () => {
    if (es?.readyState === EventSource.CLOSED) setOnline(false);
  };
  es.addEventListener("ping", alive);
  es.addEventListener("playback", (e) => {
    alive();
    const p = JSON.parse((e as MessageEvent).data).state as Playback;
    void idbPut("positions", p.key, p);
    remoteListeners.forEach((l) => l(p));
  });
  es.addEventListener("device", (e) => {
    alive();
    const d = JSON.parse((e as MessageEvent).data).device as DeviceState;
    devices.set(d.device, d);
    deviceListeners.forEach((l) => l());
  });
  es.addEventListener("resync", () => {
    alive();
    remoteListeners.forEach((l) => l({ key: "" } as Playback));
  });
  es.addEventListener("settings", (e) => {
    alive();
    const v = JSON.parse((e as MessageEvent).data) as Record<string, unknown>;
    settingsListeners.forEach((l) => l(v));
  });
  // A continue list changed on some device: views reload like after a resync.
  es.addEventListener("lists", () => {
    alive();
    remoteListeners.forEach((l) => l({ key: "" } as Playback));
  });
}

export function stopSync() {
  es?.close();
  clearInterval(healthTimer);
  clearInterval(watchTimer);
}
