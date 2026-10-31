// Offline titles: download queue, status, re-download when the browser cleared the cache.

import { download } from "../downloader";
import { OFFLINE_CACHE, offlineUrl, removeOffline, storeOffline } from "../offline";
import { online, onConnection, type Item, type Quality } from "./api";
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

export const offlineList = () => idbAll<OfflineEntry>("offline");
export const offlineEntry = (key: string) => idbGet<OfflineEntry>("offline", key);

export async function isOffline(key: string): Promise<boolean> {
  return (await offlineEntry(key))?.status === "done";
}

export async function addOffline(items: Item[]) {
  for (const it of items.filter((i) => i.kind === "track" || i.kind === "episode")) {
    if (await offlineEntry(it.key)) continue;
    await idbPut("items", it.key, it);
    await idbPut("offline", it.key, {
      key: it.key, title: it.title, subtitle: it.subtitle ?? it.podcast ?? "", status: "queued", progress: 0,
      source: it.quality ?? null, added: new Date().toISOString(),
    } satisfies OfflineEntry);
  }
  notify();
  void process();
}

export async function removeFromOffline(key: string) {
  await removeOffline(key);
  await idbDel("offline", key);
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
  notify();
  let last = 0;
  // The server converts hi-res FLAC to 48 kHz for the car (cached 24/96 does not play there).
  const { blob, report } = await download(`/api/v1/stream/${encodeURIComponent(e.key)}?profile=tesla-offline`, {
    onProgress: (b, total) => {
      e.progress = total ? b / total : 0;
      e.bytes = b;
      if (Date.now() - last > 500) {
        last = Date.now();
        notify();
      }
    },
  });
  if (!(await offlineEntry(e.key))) return; // removed meanwhile
  if (blob && report.ok) {
    await storeOffline(e.key, blob);
    const q = report.quality ? JSON.parse(report.quality) : null;
    Object.assign(e, { status: "done", progress: 1, bytes: blob.size, delivered: q?.delivered ?? e.source, transcoded: !!q?.transcoded });
  } else {
    Object.assign(e, { status: "error", error: report.error ?? "download failed" });
  }
  await idbPut("offline", e.key, e);
  notify();
}

/// After start: titles the browser removed from the cache are marked and fetched again.
export async function checkOffline() {
  const cache = await caches.open(OFFLINE_CACHE);
  for (const e of await offlineList()) {
    if (e.status === "loading") e.status = "queued";
    if (e.status === "done" && !(await cache.match(offlineUrl(e.key)))) e.status = "missing";
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
