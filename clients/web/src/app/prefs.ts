// Settings of the account, the same on all its devices (GET/PUT /api/v1/settings/playback); a copy
// in this browser keeps them while offline.
import { api } from "./api";
import { onSettings } from "./sync";

export type PlaybackPrefs = { rewind_podcasts: boolean; rewind_books: boolean };
const KEY = "aj_playback_prefs";
const listeners = new Set<() => void>();
export const onPrefs = (l: () => void) => listeners.add(l);

const norm = (v: Partial<PlaybackPrefs> | null | undefined): PlaybackPrefs =>
  ({ rewind_podcasts: v?.rewind_podcasts !== false, rewind_books: v?.rewind_books !== false });

function stored(): PlaybackPrefs {
  try {
    return norm(JSON.parse(localStorage.getItem(KEY) ?? "null"));
  } catch {
    return norm(null);
  }
}

/** Continue podcasts / books 10 s earlier after another device or a pause of 5 minutes. */
export let playbackPrefs: PlaybackPrefs = stored();

function apply(v: Partial<PlaybackPrefs>) {
  playbackPrefs = norm(v);
  try {
    localStorage.setItem(KEY, JSON.stringify(playbackPrefs));
  } catch { /* private window: the server keeps them */ }
  listeners.forEach((l) => l());
}

export async function refreshPrefs() {
  try {
    apply(await api<PlaybackPrefs>("GET", "/settings/playback"));
  } catch { /* offline: the stored copy stays */ }
}

export async function setPrefs(p: Partial<PlaybackPrefs>) {
  apply(await api<PlaybackPrefs>("PUT", "/settings/playback", p));
}

onSettings((e) => e.playback && apply(e.playback as Partial<PlaybackPrefs>));
