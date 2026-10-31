// The single audio element: plays from the offline cache when available, otherwise as a
// stream from the server; saves positions; Media Session for the car's mini player.

import { offlineUrl } from "../offline";
import { api, online, type Item, type Playback, type Quality } from "./api";
import { isOffline, offlineEntry } from "./downloads";
import { idbGet, idbPut } from "./idb";
import { localPosition, onRemote, savePosition } from "./sync";

export interface PlayerState {
  item?: Item;
  queue: Item[];
  index: number;
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
export const state: PlayerState = { queue: [], index: 0, playing: false, fromCache: false, transcoded: false, rate: 1 };
let myDevice = "";
const listeners = new Set<() => void>();
export const onPlayer = (l: () => void) => listeners.add(l);
const notify = () => listeners.forEach((l) => l());

export const position = () => audio.currentTime * 1000;
export const duration = () => (Number.isFinite(audio.duration) ? audio.duration * 1000 : state.item?.duration_ms ?? 0);

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

async function load(it: Item, autoplay: boolean) {
  state.item = it;
  const cached = await isOffline(it.key);
  state.fromCache = cached;
  const off = cached ? await offlineEntry(it.key) : undefined;
  state.delivered = cached ? off?.delivered ?? it.quality : it.quality;
  state.transcoded = cached ? !!off?.transcoded : false;
  const start = await startPosition(it);
  state.takenOver = start.from ? { device: start.from.device, at: start.from.updated_at } : undefined;
  audio.src = cached ? offlineUrl(it.key) : `/api/v1/stream/${encodeURIComponent(it.key)}`;
  audio.playbackRate = state.rate;
  const startSec = start.ms / 1000;
  audio.addEventListener("loadedmetadata", () => startSec && (audio.currentTime = startSec), { once: true });
  mediaSession(it);
  notify();
  if (autoplay) await audio.play().catch(() => notify());
}

export function toggle() {
  if (!state.item) return;
  if (audio.paused) void audio.play();
  else audio.pause();
}

export function seekBy(ms: number) {
  audio.currentTime = Math.max(0, Math.min(duration() / 1000, audio.currentTime + ms / 1000));
  void persist();
}

export function seekTo(fraction: number) {
  audio.currentTime = (duration() / 1000) * fraction;
  void persist();
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
  if (!it || !audio.src || (!finished && audio.currentTime < 1)) return;
  await savePosition({
    key: it.key,
    position_ms: Math.round(audio.currentTime * 1000),
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
  ms.setActionHandler("play", () => void audio.play());
  ms.setActionHandler("pause", () => audio.pause());
  ms.setActionHandler("seekbackward", () => seekBy(-30000));
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
  void persist();
  notify();
});
audio.addEventListener("ended", async () => {
  await persist(true);
  if (state.index + 1 < state.queue.length) await skip(1);
});
audio.addEventListener("timeupdate", notify);
audio.addEventListener("error", () => notify());
document.addEventListener("visibilitychange", () => document.hidden && void persist());

// Another device moved on: follow it while this device is not playing the item.
onRemote((p) => {
  if (!p.key || !state.item || p.key !== state.item.key || state.playing || p.device === myDevice) return;
  audio.currentTime = p.position_ms / 1000;
  state.takenOver = { device: p.device, at: p.updated_at };
  notify();
});

export const audioError = () => audio.error;
