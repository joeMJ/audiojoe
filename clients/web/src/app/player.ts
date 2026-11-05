// The single audio element: plays from the offline cache when available, otherwise as a
// stream from the server; saves positions; Media Session for the car's mini player.
// Books may consist of several audio files ("parts"); positions are always positions in
// the whole item, the player switches parts as needed.

import { offlineUrl } from "../offline";
import { api, online, type Item, type Playback, type Quality } from "./api";
import { dropPlayed, isOffline, keepCurrent, offlineEntry, partKey } from "./downloads";
import { idbAll, idbGet, idbPut } from "./idb";
import { localPosition, onRemote, savePosition } from "./sync";

/** The continue-list entry being played (an album for music): its successor plays next. */
export interface Entry { list: "podcasts" | "books" | "music"; key: string }

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
  entry?: Entry;
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

const chapters = () => state.item?.chapters ?? [];
export const hasChapters = () => chapters().length > 0;

/** Index of the chapter at the position, -1 without chapters. */
export function chapterIndex(): number {
  const ms = position(), l = chapters();
  for (let i = l.length - 1; i >= 0; i--) if (ms >= l[i].start_ms) return i;
  return l.length ? 0 : -1;
}

export function chapter(): string {
  const i = chapterIndex();
  return i < 0 ? "" : chapters()[i].title;
}

/** "3/11 · Name"; empty without chapters. */
export function chapterLine(): string {
  const i = chapterIndex();
  return i < 0 ? "" : `${i + 1}/${chapters().length} · ${chapter()}`;
}

/** Next chapter; after the last one the next item, if any. */
export async function nextChapter() {
  const i = chapterIndex(), l = chapters();
  if (i >= 0 && i + 1 < l.length) return void (await seekGlobal(l[i + 1].start_ms, state.playing).then(() => persist()));
  await skip(1);
}

/** Start of the chapter; within its first 3 seconds the previous chapter. */
export async function previousChapter() {
  const i = chapterIndex(), l = chapters();
  if (i < 0) return void (await skip(-1));
  const to = position() - l[i].start_ms < 3000 && i > 0 ? l[i - 1].start_ms : l[i].start_ms;
  await seekGlobal(to, state.playing).then(() => persist());
}

/** ⏮ ⏭: by chapter when there are chapters, else by item. */
export const stepForward = () => (hasChapters() ? nextChapter() : skip(1));
export const stepBack = () => (hasChapters() ? previousChapter() : skip(-1));
export const canStep = () => hasChapters() || state.queue.length > 1;

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

// Podcasts and books continue 10 s earlier after another device or after a pause of 5 minutes.
const REWIND_MS = 10000;
const LONG_PAUSE_MS = 5 * 60 * 1000;
let pausedAt: number | undefined;
const rewinds = (it: Item) => it.kind === "episode" || it.kind === "book";
const back = (it: Item, ms: number) => (rewinds(it) ? Math.max(0, ms - REWIND_MS) : ms);
const longAgo = (at: string) => Date.now() - Date.parse(at) >= LONG_PAUSE_MS;

async function startPosition(it: Item): Promise<{ ms: number; from?: Playback }> {
  const local = await localPosition(it.key);
  const remote = it.playback ?? undefined;
  const best = [local, remote].filter((p): p is Playback => !!p).sort((a, b) => b.updated_at.localeCompare(a.updated_at))[0];
  // A position in the last seconds counts as heard (else the title ends at once and the next follows).
  const length = best?.duration_ms ?? it.duration_ms ?? 0;
  if (!best || best.finished || (length > 0 && best.position_ms >= length - 5000)) return { ms: 0 };
  const other = !!best.device && best.device !== myDevice;
  return { ms: other || longAgo(best.updated_at) ? back(it, best.position_ms) : best.position_ms, from: other ? best : undefined };
}

let nextAfter: ((e: Entry) => Promise<(() => Promise<void>) | null>) | null = null;
export const setNextAfter = (f: typeof nextAfter) => void (nextAfter = f);

/** The queue (e.g. an album) on this device, so a reload continues it instead of one title.
 *  The server keeps it too, so another device taking over the title continues the queue. */
const QUEUE = "aj_queue";
type Saved = { queue: Item[]; index: number; entry?: Entry };
function saveQueue() {
  try {
    localStorage.setItem(QUEUE, JSON.stringify({ queue: state.queue, index: state.index, entry: state.entry ?? null }));
  } catch { /* private window or full: a reload then continues the title alone */ }
  if (online) void api("PUT", "/queue", { items: state.queue, index: state.index, entry: state.entry ?? null }).catch(() => undefined);
}
function savedQueue(key: string): Saved | null {
  try {
    const q = JSON.parse(localStorage.getItem(QUEUE) ?? "null") as { queue: Item[]; index: number; entry: Entry | null } | null;
    if (!q || q.queue?.[q.index]?.key !== key) return null;
    return { queue: q.queue, index: q.index, entry: q.entry ?? undefined };
  } catch {
    return null;
  }
}
/** The queue another device left with `key` as its current title. */
async function serverQueue(key: string): Promise<Saved | null> {
  if (!online) return null;
  try {
    const q = await api<{ items: Item[]; index: number; entry: Entry | null }>("GET", `/queue/${encodeURIComponent(key)}`);
    if (q.items?.[q.index]?.key !== key) return null;
    return { queue: q.items, index: q.index, entry: q.entry ?? undefined };
  } catch {
    return null;
  }
}

export async function play(queue: Item[], index = 0, entry?: Entry) {
  await persist();
  // A single title another device played within an album: continue that album here.
  const other = queue.length === 1 && queue[0].kind === "track" ? await serverQueue(queue[0].key) : null;
  state.queue = queue;
  state.index = index;
  const it = queue[index];
  // Episodes and books are list entries themselves; music only when played as an album entry.
  state.entry = entry ?? (it.kind === "episode" ? { list: "podcasts", key: it.key } : it.kind === "book" ? { list: "books", key: it.key } : undefined);
  if (other) {
    state.queue = other.queue;
    state.queue[other.index] = it;
    state.index = other.index;
    state.entry = other.entry;
  }
  saveQueue();
  await load(state.queue[state.index], true);
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

async function load(it: Item, autoplay: boolean, cue = false, fromStart = false) {
  state.item = it;
  keepCurrent(it.key);
  state.part = 0;
  audio.removeAttribute("src");
  const cached = await isOffline(it.key);
  state.fromCache = cached;
  const off = cached ? await offlineEntry(it.key) : undefined;
  state.delivered = cached ? off?.delivered ?? it.quality : it.quality;
  state.transcoded = cached ? !!off?.transcoded : false;
  const start = it.kind === "radio" || fromStart ? { ms: 0 } : await startPosition(it);
  takeOver(start.from ? { device: start.from.device, at: start.from.updated_at } : undefined);
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
  const saved = savedQueue(it.key) ?? (await serverQueue(it.key));
  if (state.item) return;
  if (saved) {
    state.queue = saved.queue;
    state.queue[saved.index] = it;
    state.index = saved.index;
    state.entry = saved.entry;
  } else {
    state.queue = [it];
    state.index = 0;
    state.entry = it.kind === "episode" ? { list: "podcasts", key: it.key } : it.kind === "book" ? { list: "books", key: it.key } : undefined;
  }
  await load(it, false, true);
}

export function toggle() {
  if (!state.item) return;
  if (!audio.src) {
    if (state.item.kind === "radio") void load(state.item, true);
    else void seekGlobal(cuedMs, true);
  } else if (!audio.paused) audio.pause();
  else if (pausedAt !== undefined && rewinds(state.item) && Date.now() - pausedAt >= LONG_PAUSE_MS) {
    void seekGlobal(back(state.item, position()), false).then(() => audio.play());
  } else void audio.play();
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
  // At the end of a title "ended" has saved it as heard already; saving again would store the
  // end position as not heard.
  if (!audio.ended) await persist();
  state.index = i;
  saveQueue();
  // The next title of a queue starts at its beginning.
  await load(state.queue[i], true, false, true);
}

/** "Next podcast" / "Next album": the item counts as heard (an album leaves its list) and the
 *  next entry of the same continue list plays. */
export async function finishAndNext() {
  const after = state.entry && nextAfter ? await nextAfter(state.entry).catch(() => null) : null;
  if (!after) return;
  await persist(true);
  void dropPlayed();
  await after();
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
    // Other devices see what plays here and can take it over.
    state: finished ? "stopped" : audio.paused ? "paused" : "playing",
    kind: "web",
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
  ms.setActionHandler("play", () => audio.paused && toggle());
  ms.setActionHandler("pause", () => audio.pause());
  ms.setActionHandler("seekbackward", () => seekBy(-15000));
  ms.setActionHandler("seekforward", () => seekBy(30000));
  // Lock screen and steering wheel: by chapter, else by item.
  ms.setActionHandler("previoustrack", canStep() ? () => void stepBack() : null);
  ms.setActionHandler("nexttrack", canStep() ? () => void stepForward() : null);
}

let saveTimer: number | undefined;
audio.addEventListener("play", () => {
  state.playing = true;
  pausedAt = undefined;
  clearInterval(saveTimer);
  saveTimer = window.setInterval(() => void persist(), 10000);
  void persist();
  notify();
});
audio.addEventListener("pause", () => {
  state.playing = false;
  pausedAt = Date.now();
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
  const more = state.index + 1 < state.queue.length;
  // Asked before saving "finished": that takes the item out of its list.
  const after = !more && state.entry && nextAfter ? await nextAfter(state.entry).catch(() => null) : null;
  await persist(true);
  void dropPlayed();
  if (more) await skip(1);
  else if (after) await after();
});
let shownChapter = "";
audio.addEventListener("timeupdate", () => {
  // The car's mini player shows the chapter as the artist line.
  const c = chapterLine();
  if (c !== shownChapter && "mediaSession" in navigator && navigator.mediaSession.metadata) {
    shownChapter = c;
    navigator.mediaSession.metadata.artist = c || (state.item?.subtitle ?? state.item?.podcast ?? "");
  }
  notify();
});
audio.addEventListener("error", () => notify());
document.addEventListener("visibilitychange", () => document.hidden && void persist());

/** "Taken over from …" is shown for a few seconds only (as in the app). */
let takenOverTimer: ReturnType<typeof setTimeout> | undefined;
function takeOver(v: PlayerState["takenOver"]) {
  state.takenOver = v;
  clearTimeout(takenOverTimer);
  if (v) takenOverTimer = setTimeout(() => ((state.takenOver = undefined), notify()), 8000);
}

// Another device moved on: follow it while this device is not playing the item.
onRemote((p) => {
  if (!p.key || !state.item || p.key !== state.item.key || state.playing || p.device === myDevice) return;
  takeOver({ device: p.device, at: p.updated_at });
  const ms = back(state.item, p.position_ms);
  if (!audio.src) {
    cuedMs = ms;
    notify();
  } else void seekGlobal(ms, false);
});

export const audioError = () => audio.error;
