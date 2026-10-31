// The single audio element: plays from the offline cache when available, otherwise as a
// stream from the server; saves positions; Media Session for the car's mini player.
// Books may consist of several audio files ("parts"); positions are always positions in
// the whole item, the player switches parts as needed.

import { offlineUrl } from "../offline";
import { api, online, type Item, type Playback, type Quality } from "./api";
import { dropPlayed, isOffline, keepCurrent, offlineEntry, partKey } from "./downloads";
import { idbAll, idbGet, idbPut } from "./idb";
import { localPosition, onRemote, savePosition } from "./sync";

export interface PlayerState {
  item?: Item;
  queue: Item[];
  index: number;
  /** Current part of a multi-file item. */
  part: number;
  playing: boolean;
  fromCache: boolean;
  delivered?: Quality | null;
  transcoded: boolean;
  /** Set when the start position came from another device. */
  takenOver?: { device: string; at: string };
  rate: number;
}

const audio = new Audio();
audio.preload = "auto";
export const state: PlayerState = { queue: [], index: 0, part: 0, playing: false, fromCache: false, transcoded: false, rate: 1 };
let myDevice = "";
const listeners = new Set<() => void>();
export const onPlayer = (l: () => void) => listeners.add(l);
const notify = () => listeners.forEach((l) => l());

const parts = () => state.item?.parts ?? [];
const partStart = () => parts()[state.part]?.start_ms ?? 0;

/** Position of an item that is ready but not loaded yet (after a restart). */
let cuedMs = 0;
export const position = () => (audio.src ? partStart() + audio.currentTime * 1000 : cuedMs);
export const isLive = () => state.item?.kind === "radio";
export const duration = () =>
  parts().length ? state.item?.duration_ms ?? 0 : Number.isFinite(audio.duration) ? audio.duration * 1000 : state.item?.duration_ms ?? 0;

export function chapter(): string {
  const ms = position();
  return state.item?.chapters?.find((c) => ms >= c.start_ms && ms < c.end_ms)?.title ?? "";
}

export function setDevice(name: string) {
  myDevice = name;
}

/** Metadata for an item: from the server, else from the local copy (offline). */
export async function itemMeta(key: string): Promise<Item | undefined> {
  if (online) {
    try {
      const it = await api<Item>("GET", `/items/${encodeURIComponent(key)}`);
      await idbPut("items", key, it);
      return it;
    } catch {
      /* fall back to local */
    }
  }
  return idbGet<Item>("items", key);
}

async function startPosition(it: Item): Promise<{ ms: number; from?: Playback }> {
  const local = await localPosition(it.key);
  const remote = it.playback ?? undefined;
  const best = [local, remote].filter((p): p is Playback => !!p).sort((a, b) => b.updated_at.localeCompare(a.updated_at))[0];
  if (!best || best.finished) return { ms: 0 };
  return { ms: best.position_ms, from: best.device && best.device !== myDevice ? best : undefined };
}

export async function play(queue: Item[], index = 0) {
  await persist();
  state.queue = queue;
  state.index = index;
  await load(queue[index], true);
}

function partFor(ms: number): number {
  const p = parts();
  const i = p.findIndex((x) => ms >= x.start_ms && ms < x.start_ms + x.duration_ms);
  return i < 0 ? Math.max(0, p.length - 1) : i;
}

/** Points the audio element at the right file for a position in the whole item. */
async function seekGlobal(ms: number, autoplay: boolean) {
  const it = state.item!;
  const p = parts();
  const part = p.length ? partFor(ms) : 0;
  const local = (ms - (p[part]?.start_ms ?? 0)) / 1000;
  if (!audio.src || part !== state.part || !audio.src.includes(srcFor(it, part))) {
    state.part = part;
    audio.src = srcFor(it, part);
    audio.playbackRate = state.rate;
    audio.addEventListener("loadedmetadata", () => local > 0 && (audio.currentTime = local), { once: true });
    if (autoplay) await audio.play().catch(() => notify());
  } else {
    audio.currentTime = local;
  }
  notify();
}

function srcFor(it: Item, part: number): string {
  const multi = (it.parts?.length ?? 0) > 1;
  if (state.fromCache) return offlineUrl(multi ? partKey(it.key, part) : it.key);
  return `/api/v1/stream/${encodeURIComponent(it.key)}${multi ? `?part=${part}` : ""}`;
}

async function load(it: Item, autoplay: boolean, cue = false) {
  state.item = it;
  keepCurrent(it.key);
  state.part = 0;
  audio.removeAttribute("src");
  const cached = await isOffline(it.key);
  state.fromCache = cached;
  const off = cached ? await offlineEntry(it.key) : undefined;
  state.delivered = cached ? off?.delivered ?? it.quality : it.quality;
  state.transcoded = cached ? !!off?.transcoded : false;
  const start = it.kind === "radio" ? { ms: 0 } : await startPosition(it);
  state.takenOver = start.from ? { device: start.from.device, at: start.from.updated_at } : undefined;
  mediaSession(it);
  void dropPlayed();
  if (cue) {
    // Ready, paused, nothing loaded until play is pressed (a live stream would keep loading).
    cuedMs = start.ms;
    return notify();
  }
  // Radio has no position; one entry still marks it as the last thing played on any device.
  if (it.kind === "radio") {
    void savePosition({ key: it.key, position_ms: 0, duration_ms: null, finished: false, updated_at: new Date().toISOString(),
      title: it.title, subtitle: it.subtitle ?? "" });
  }
  await seekGlobal(start.ms, autoplay);
}

/** After a restart: the last unfinished item of any device, paused at its position. */
export async function cueLast() {
  if (state.item) return;
  let list: Playback[] = [];
  if (online) {
    try {
      list = await api<Playback[]>("GET", "/playback?limit=10");
    } catch {
      /* offline: local positions */
    }
  }
  if (!list.length) list = (await idbAll<Playback>("positions")).sort((a, b) => b.updated_at.localeCompare(a.updated_at));
  let it: Item | undefined;
  for (const p of list.filter((x) => !x.finished)) {
    if (online) {
      // Only what the server can still play (a removed source is skipped).
      try {
        it = await api<Item>("GET", `/items/${encodeURIComponent(p.key)}`);
        await idbPut("items", p.key, it);
      } catch {
        continue;
      }
    } else it = await idbGet<Item>("items", p.key);
    if (it) break;
  }
  if (!it || state.item) return;
  state.queue = [it];
  state.index = 0;
  await load(it, false, true);
}

export function toggle() {
  if (!state.item) return;
  if (!audio.src) {
    if (state.item.kind === "radio") void load(state.item, true);
    else void seekGlobal(cuedMs, true);
  } else if (audio.paused) void audio.play();
  else audio.pause();
}

export function seekBy(ms: number) {
  void seekGlobal(Math.max(0, Math.min(duration(), position() + ms)), state.playing).then(() => persist());
}

export function seekTo(fraction: number) {
  void seekGlobal(duration() * fraction, state.playing).then(() => persist());
}

const RATES = [1, 1.2, 1.5, 2];
export function nextRate() {
  state.rate = RATES[(RATES.indexOf(state.rate) + 1) % RATES.length];
  audio.playbackRate = state.rate;
  notify();
}

export async function skip(d: 1 | -1) {
  const i = state.index + d;
  if (i < 0 || i >= state.queue.length) return;
  await persist();
  state.index = i;
  await load(state.queue[i], true);
}

async function persist(finished = false) {
  const it = state.item;
  // Live radio has no position to continue from.
  if (!it || it.kind === "radio" || !audio.src || (!finished && position() < 1000)) return;
  await savePosition({
    key: it.key,
    position_ms: Math.round(position()),
    duration_ms: Math.round(duration()) || null,
    finished,
    updated_at: new Date().toISOString(),
    title: it.title,
    subtitle: it.subtitle ?? it.podcast ?? "",
  });
}

function mediaSession(it: Item) {
  if (!("mediaSession" in navigator)) return;
  navigator.mediaSession.metadata = new MediaMetadata({
    title: it.title,
    artist: it.subtitle ?? it.podcast ?? "",
    album: "audiojoe",
    artwork: it.image ? [{ src: it.image, sizes: "400x400" }] : [],
  });
  const ms = navigator.mediaSession;
  ms.setActionHandler("play", () => (audio.src ? void audio.play() : toggle()));
  ms.setActionHandler("pause", () => audio.pause());
  ms.setActionHandler("seekbackward", () => seekBy(-15000));
  ms.setActionHandler("seekforward", () => seekBy(30000));
  ms.setActionHandler("previoustrack", state.queue.length > 1 ? () => void skip(-1) : null);
  ms.setActionHandler("nexttrack", state.queue.length > 1 ? () => void skip(1) : null);
}

let saveTimer: number | undefined;
audio.addEventListener("play", () => {
  state.playing = true;
  clearInterval(saveTimer);
  saveTimer = window.setInterval(() => void persist(), 10000);
  notify();
});
audio.addEventListener("pause", () => {
  state.playing = false;
  clearInterval(saveTimer);
  if (!audio.ended) void persist();
  notify();
});
audio.addEventListener("ended", async () => {
  // Next part of the same book, else the item is finished.
  if (state.part + 1 < parts().length) {
    await seekGlobal(parts()[state.part + 1].start_ms, true);
    return;
  }
  await persist(true);
  void dropPlayed();
  if (state.index + 1 < state.queue.length) await skip(1);
});
audio.addEventListener("timeupdate", () => notify());
audio.addEventListener("error", () => notify());
document.addEventListener("visibilitychange", () => document.hidden && void persist());

// Another device moved on: follow it while this device is not playing the item.
onRemote((p) => {
  if (!p.key || !state.item || p.key !== state.item.key || state.playing || p.device === myDevice) return;
  state.takenOver = { device: p.device, at: p.updated_at };
  if (!audio.src) {
    cuedMs = p.position_ms;
    notify();
  } else void seekGlobal(p.position_ms, false);
});

export const audioError = () => audio.error;
