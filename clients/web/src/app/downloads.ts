// Offline titles: download queue, status, re-download when the browser cleared the cache.

import { download } from "../downloader";
import { OFFLINE_CACHE, offlineUrl, removeOffline, storeOffline } from "../offline";
import { api, online, onConnection, type Item, type Playback, type Quality } from "./api";
import { idbAll, idbDel, idbGet, idbPut } from "./idb";

export interface OfflineEntry {
  key: string;
  title: string;
  subtitle: string;
  status: "queued" | "loading" | "done" | "error" | "missing";
  progress: number;
  bytes?: number;
  source?: Quality | null;
  delivered?: Quality | null;
  transcoded?: boolean;
  error?: string;
  added: string;
}

const listeners = new Set<() => void>();
export const onOfflineChange = (l: () => void) => listeners.add(l);
const notify = () => listeners.forEach((l) => l());

/** Cache key of one part of a multi-file item. */
export const partKey = (key: string, part: number) => `${key}#${part}`;

// The running download counts up in memory only; the stored entry keeps 0 % until it is done.
let live: OfflineEntry | null = null;
const withLive = (e?: OfflineEntry) => (e && live?.key === e.key && e.status === "loading" ? { ...e, progress: live.progress, bytes: live.bytes } : e);

export const offlineList = async () => (await idbAll<OfflineEntry>("offline")).map((e) => withLive(e)!);
export const offlineEntry = async (key: string) => withLive(await idbGet<OfflineEntry>("offline", key));

export async function isOffline(key: string): Promise<boolean> {
  return (await offlineEntry(key))?.status === "done";
}

export async function addOffline(items: Item[]) {
  for (const it0 of items.filter((i) => ["track", "episode", "book"].includes(i.kind))) {
    if (await offlineEntry(it0.key)) continue;
    // Books need their parts; list entries do not carry them.
    let it = it0;
    if (it.kind === "book" && !it.parts) {
      try {
        it = await api<Item>("GET", `/items/${encodeURIComponent(it.key)}`);
      } catch {
        continue;
      }
    }
    await idbPut("items", it.key, it);
    await idbPut("offline", it.key, {
      key: it.key, title: it.title, subtitle: it.subtitle ?? it.podcast ?? "", status: "queued", progress: 0,
      source: it.quality ?? null, added: new Date().toISOString(),
    } satisfies OfflineEntry);
  }
  notify();
  void process();
}

// Played media leave the cache when the switch is on (per device); the current item stays.
const DROP = "aj_drop_played";
let current = "";
export const keepCurrent = (key: string) => void (current = key);
export function dropPlayedOn(): boolean {
  try {
    return localStorage.getItem(DROP) === "1";
  } catch {
    return false;
  }
}
export function setDropPlayed(on: boolean) {
  try {
    localStorage.setItem(DROP, on ? "1" : "0");
  } catch {
    /* private window: not kept */
  }
  void dropPlayed();
  notify();
}
let dropping = false;
export async function dropPlayed() {
  if (!dropPlayedOn() || dropping) return;
  dropping = true;
  try {
    for (const e of await offlineList()) {
      if (e.key === current) continue;
      let p = await idbGet<Playback>("positions", e.key);
      if (online) {
        try {
          p = await api<Playback>("GET", `/playback/${encodeURIComponent(e.key)}`);
        } catch {
          /* not on the server (never played) or offline: local state */
        }
      }
      if (p?.finished) await removeFromOffline(e.key);
    }
  } finally {
    dropping = false;
  }
}

export async function removeFromOffline(key: string) {
  await removeOffline(key);
  const it = await idbGet<Item>("items", key);
  for (const p of it?.parts ?? []) await removeOffline(partKey(key, p.index));
  await idbDel("offline", key);
  notify();
}
/** "Clear cache": every offline entry with its files, also running and waiting downloads. A running
 * download notices that its entry is gone and keeps nothing. The settings stay. */
export async function clearOffline() {
  for (const e of await idbAll<OfflineEntry>("offline")) {
    await idbDel("offline", e.key);
    await idbDel("items", e.key);
  }
  await caches.delete(OFFLINE_CACHE); // also parts left over from earlier removals
  notify();
}

let running = false;
async function process() {
  if (running) return;
  running = true;
  try {
    for (;;) {
      if (!online) break;
      const next = (await offlineList()).find((e) => e.status === "queued" || e.status === "missing");
      if (!next) break;
      await fetchOne(next);
    }
  } finally {
    running = false;
  }
}

async function fetchOne(e: OfflineEntry) {
  e.status = "loading";
  e.progress = 0;
  await idbPut("offline", e.key, e);
  live = e;
  notify();
  try {
    await fetchParts(e);
  } finally {
    live = null;
  }
}

async function fetchParts(e: OfflineEntry) {
  const it = await idbGet<Item>("items", e.key);
  const parts = it?.parts && it.parts.length > 1 ? it.parts : null;
  const total = parts ? parts.reduce((s, p) => s + p.duration_ms, 0) : 1;
  let done = 0, bytes = 0, last = 0;
  let q: { delivered?: Quality; transcoded?: boolean } | null = null;
  // One file, or each part of a book. The server converts hi-res FLAC to 48 kHz for the
  // car (cached 24/96 does not play there).
  for (const [i, p] of (parts ?? [null]).entries()) {
    const url = `/api/v1/stream/${encodeURIComponent(e.key)}?profile=tesla-offline${p ? `&part=${i}` : ""}`;
    const share = p ? p.duration_ms / total : 1;
    const { blob, report } = await download(url, {
      onProgress: (b, t) => {
        e.progress = done + (t ? (b / t) * share : 0);
        e.bytes = bytes + b;
        if (Date.now() - last > 500) {
          last = Date.now();
          notify();
        }
      },
    });
    if (!(await offlineEntry(e.key))) return; // removed meanwhile
    if (!blob || !report.ok) {
      Object.assign(e, { status: "error", error: report.error ?? "download failed" });
      await idbPut("offline", e.key, e);
      return notify();
    }
    await storeOffline(p ? partKey(e.key, i) : e.key, blob);
    q ??= report.quality ? JSON.parse(report.quality) : null;
    bytes += blob.size;
    done += share;
  }
  Object.assign(e, { status: "done", progress: 1, bytes, delivered: q?.delivered ?? e.source, transcoded: !!q?.transcoded });
  await idbPut("offline", e.key, e);
  notify();
}

/// After start: titles the browser removed from the cache are marked and fetched again.
export async function checkOffline() {
  const cache = await caches.open(OFFLINE_CACHE);
  for (const e of await offlineList()) {
    if (e.status === "loading") e.status = "queued";
    const it = await idbGet<Item>("items", e.key);
    const keys = it?.parts && it.parts.length > 1 ? it.parts.map((p) => partKey(e.key, p.index)) : [e.key];
    if (e.status === "done") {
      for (const k of keys) if (!(await cache.match(offlineUrl(k)))) e.status = "missing";
    }
    await idbPut("offline", e.key, e);
  }
  notify();
  onConnection(() => online && void process());
  void process();
}

export async function retryFailed() {
  for (const e of await offlineList()) {
    if (e.status === "error") await idbPut("offline", e.key, { ...e, status: "queued" });
  }
  void process();
}
