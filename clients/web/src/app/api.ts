// Server API (same origin, session cookie). Tracks whether the server is reachable.

export interface Quality {
  codec: string;
  sample_rate?: number | null;
  bit_depth?: number | null;
  bitrate?: number | null;
  channels?: number | null;
}

export interface Item {
  key: string;
  kind: string;
  title: string;
  subtitle: string;
  duration_ms?: number | null;
  image?: string | null;
  quality?: Quality | null;
  podcast?: string;
  published?: string | null;
  description?: string | null;
  favorite?: boolean;
  track?: number | null;
  year?: number | null;
  /** Audio files of a book; positions are positions in the whole item. */
  parts?: { index: number; start_ms: number; duration_ms: number; title: string }[];
  chapters?: { title: string; start_ms: number; end_ms: number }[];
  position_ms?: number | null;
  finished?: boolean;
  playback?: Playback | null;
}

export interface Playback {
  key: string;
  position_ms: number;
  duration_ms?: number | null;
  finished: boolean;
  title: string;
  subtitle: string;
  device: string;
  updated_at: string;
}

export class ApiError extends Error {
  constructor(public status: number, message: string) {
    super(message);
  }
}

type Listener = () => void;
const listeners = new Set<Listener>();
export let online = navigator.onLine;

export function onConnection(l: Listener) {
  listeners.add(l);
}

export function setOnline(v: boolean) {
  if (v === online) return;
  online = v;
  listeners.forEach((l) => l());
}

export async function api<T>(method: string, path: string, body?: unknown): Promise<T> {
  let res: Response;
  try {
    res = await fetch(`/api/v1${path}`, {
      method,
      credentials: "same-origin",
      headers: body === undefined ? {} : { "content-type": "application/json" },
      body: body === undefined ? undefined : JSON.stringify(body),
      cache: "no-store",
    });
  } catch (e) {
    setOnline(false);
    throw new ApiError(0, String(e));
  }
  // Behind the reverse proxy a stopped server shows up as 502/503/504: that is "offline".
  // A 502 with our own JSON error comes from the server itself (a source failed).
  if (res.status >= 502 && res.status <= 504 && !res.headers.get("content-type")?.includes("json")) {
    setOnline(false);
    throw new ApiError(0, `server unavailable (${res.status})`);
  }
  setOnline(true);
  const data = res.headers.get("content-type")?.includes("json") ? await res.json() : null;
  if (!res.ok) throw new ApiError(res.status, data?.error ?? res.statusText);
  return data as T;
}

/// Format line for a quality, e.g. "FLAC · 24 bit · 96 kHz · 3450 kbit/s".
export function qualityText(q?: Quality | null): string {
  if (!q || !q.codec) return "–";
  const parts = [q.codec.replace(/^pcm_.*/, "PCM").toUpperCase()];
  if (q.bit_depth) parts.push(`${q.bit_depth} bit`);
  if (q.sample_rate) parts.push(`${(q.sample_rate / 1000).toLocaleString(undefined, { maximumFractionDigits: 1 })} kHz`);
  if (q.bitrate) parts.push(`${Math.round(q.bitrate / 1000)} kbit/s`);
  return parts.join(" · ");
}

/// Separate facts for chips: ["FLAC", "24 bit", "96 kHz", "Stereo"].
export function qualityChips(q?: Quality | null): string[] {
  if (!q || !q.codec) return [];
  const lossless = /^(flac|alac|pcm_)/.test(q.codec);
  const out = [q.codec.replace(/^pcm_.*/, "PCM").toUpperCase()];
  if (q.bit_depth) out.push(`${q.bit_depth} bit`);
  if (q.sample_rate) out.push(`${(q.sample_rate / 1000).toLocaleString(undefined, { maximumFractionDigits: 1 })} kHz`);
  if (q.bitrate && !lossless) out.push(`${Math.round(q.bitrate / 1000)} kbit/s`);
  if (q.channels === 1) out.push("Mono");
  else if (q.channels === 2) out.push("Stereo");
  else if (q.channels) out.push(`${q.channels} ch`);
  return out;
}

/// Short badge, e.g. "FLAC 24/96".
export function qualityBadge(q?: Quality | null): string {
  if (!q || !q.codec) return "";
  const c = q.codec.replace(/^pcm_.*/, "PCM").toUpperCase();
  if (q.bit_depth && q.sample_rate) return `${c} ${q.bit_depth}/${Math.round(q.sample_rate / 1000)}`;
  if (q.bitrate) return `${c} ${Math.round(q.bitrate / 1000)}k`;
  return c;
}
