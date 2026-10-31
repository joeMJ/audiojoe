// Output to Sonos speakers: the server starts playback on the speaker, which fetches the
// stream itself; this device then only controls it. Rooms with several speakers
// (stereo pairs, surround) are shown once.

import { api } from "./api";
import * as player from "./player";

export interface Room {
  id: number;
  name: string;
  model: string;
  s2: boolean;
  reachable: boolean;
  state?: string | null;
  volume?: number | null;
  item_key?: string | null;
  position_ms?: number | null;
}

export let output: Room | null = null;
const listeners = new Set<() => void>();
export const onSonos = (l: () => void) => listeners.add(l);
const notify = () => listeners.forEach((l) => l());

export async function rooms(): Promise<Room[]> {
  const all = await api<Room[]>("GET", "/sonos");
  const byName = new Map<string, Room>();
  for (const r of all) {
    const cur = byName.get(r.name);
    if (!cur || (!cur.reachable && r.reachable)) byName.set(r.name, r);
  }
  return [...byName.values()].sort((a, b) => a.name.localeCompare(b.name));
}

let timer: number | undefined;

export async function playOn(room: Room) {
  const it = player.state.item;
  if (!it) return;
  const pos = Math.round(player.position());
  if (player.state.playing) player.toggle();
  await api("POST", `/sonos/${room.id}/play`, { key: it.key, position_ms: it.kind === "radio" ? 0 : pos });
  output = { ...room, state: "PLAYING" };
  clearInterval(timer);
  timer = window.setInterval(refresh, 5000);
  notify();
}

async function refresh() {
  if (!output) return;
  try {
    const r = (await api<Room[]>("GET", "/sonos")).find((x) => x.id === output!.id);
    if (r && output) output = r;
  } catch {
    /* keep last state */
  }
  notify();
}

export const playing = () => output?.state === "PLAYING" || output?.state === "TRANSITIONING";

export async function toggle() {
  if (!output) return;
  await api("POST", `/sonos/${output.id}/command`, { action: playing() ? "pause" : "resume" });
  output.state = playing() ? "PAUSED_PLAYBACK" : "PLAYING";
  notify();
}

export async function volume(delta: number) {
  if (!output) return;
  const v = Math.max(0, Math.min(100, (output.volume ?? 15) + delta));
  await api("POST", `/sonos/${output.id}/command`, { action: "volume", volume: v });
  output.volume = v;
  notify();
}

/** Back to this device: the speaker pauses; its last position arrives via the server. */
export async function backToDevice() {
  if (output) {
    try {
      await api("POST", `/sonos/${output.id}/command`, { action: "pause" });
    } catch {
      /* speaker gone */
    }
  }
  output = null;
  clearInterval(timer);
  notify();
}
