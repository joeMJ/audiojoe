// Screens of the web app. Plain DOM; each view renders itself into <main>.

import { api, online, qualityBadge, qualityText, type Item, type Playback } from "./api";
import { addOffline, offlineEntry, offlineList, removeFromOffline, retryFailed, type OfflineEntry } from "./downloads";
import { ago, bytes, clock, t } from "./i18n";
import { idbAll } from "./idb";
import * as player from "./player";
import { pendingCount } from "./sync";

type View = "np" | "cont" | "pod" | "lib" | "off";
let view: View = "np";
let main!: HTMLElement;
let top!: HTMLElement;
let onLogout: () => void = () => {};

// ---------------------------------------------------------------- helpers

type Child = Node | string | null | undefined | false;
function h<K extends keyof HTMLElementTagNameMap>(tag: K, props: Record<string, unknown> = {}, ...kids: Child[]) {
  const e = document.createElement(tag);
  for (const [k, v] of Object.entries(props)) {
    if (k.startsWith("on")) e.addEventListener(k.slice(2), v as EventListener);
    else if (k === "style") e.setAttribute("style", String(v));
    else (e as unknown as Record<string, unknown>)[k] = v;
  }
  for (const c of kids) if (c) e.append(c);
  return e;
}

const icon = (path: string) => {
  const d = document.createElement("div");
  d.innerHTML = `<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.2" stroke-linecap="round">${path}</svg>`;
  return d.firstElementChild!;
};
const ICONS: Record<View, string> = {
  np: '<path d="M8 5v14l11-7z" fill="currentColor" stroke="none"/>',
  cont: '<path d="M12 7v5l3 2"/><circle cx="12" cy="12" r="9"/>',
  pod: '<circle cx="12" cy="11" r="3"/><path d="M12 14v7M6.3 16.5a8 8 0 1 1 11.4 0"/>',
  lib: '<path d="M9 18V5l11-2v13"/><circle cx="6" cy="18" r="3"/><circle cx="17" cy="16" r="3"/>',
  off: '<path d="M12 4v11m0 0-4-4m4 4 4-4M5 20h14"/>',
};
const LABELS: Record<View, string> = { np: "Now playing", cont: "Continue", pod: "Podcasts", lib: "Music", off: "Offline" };

function initials(s: string) {
  return s.split(/\s+/).filter(Boolean).slice(0, 3).map((w) => w[0]).join("").toUpperCase() || "♫";
}

function thumb(it: { image?: string | null; title: string }) {
  const d = h("div", { className: "ic" }, it.image ? "" : initials(it.title));
  if (it.image) d.style.backgroundImage = `url("${it.image}")`;
  return d;
}

function failure(e: unknown) {
  return h("div", { className: "empty" }, online ? `${t("Error")}: ${(e as Error).message}` : t("Server not reachable."));
}

async function start(items: Item[], index = 0) {
  const meta = await player.itemMeta(items[index].key);
  const queue = items.slice();
  if (meta) queue[index] = { ...items[index], ...meta };
  await player.play(queue, index);
  show("np");
}

// ---------------------------------------------------------------- shell

export function mountShell(root: HTMLElement, logout: () => void) {
  onLogout = logout;
  top = h("header", { className: "top" });
  const nav = h("nav");
  for (const v of Object.keys(LABELS) as View[]) {
    nav.append(h("button", { onclick: () => show(v), className: v === view ? "active" : "" }, icon(ICONS[v]), t(LABELS[v])));
    (nav.lastElementChild as HTMLElement).dataset.v = v;
  }
  main = h("main");
  root.replaceChildren(h("div", { className: "shell" }, top, nav, main));
  renderTop();
  show(view);
}

export function renderTop() {
  if (!top) return;
  const net = online
    ? h("div", { className: "pill ok", id: "net" }, h("span", { className: "dot" }), t("Server reachable"))
    : h("div", { className: "pill warn", id: "net" }, h("span", { className: "dot" }), t("Offline · cache"));
  const sync = pendingCount
    ? h("div", { className: "pill warn", id: "sync" }, t("{n} waiting to sync", { n: pendingCount }))
    : h("div", { className: "pill", id: "sync" }, t("Positions synced"));
  top.replaceChildren(h("div", { className: "logo" }, "audiojoe"), net, sync);
  void offlineUsage().then((u) => u && top.append(h("div", { className: "pill" }, `${t("Offline")} ${u}`)));
}

async function offlineUsage() {
  const done = (await offlineList()).filter((e) => e.status === "done");
  return done.length ? bytes(done.reduce((s, e) => s + (e.bytes ?? 0), 0)) : "";
}

export function show(v: View) {
  view = v;
  document.querySelectorAll<HTMLElement>("nav button").forEach((b) => b.classList.toggle("active", b.dataset.v === v));
  main.replaceChildren();
  main.scrollTop = 0;
  ({ np: renderNowPlaying, cont: renderContinue, pod: renderPodcasts, lib: renderMusic, off: renderOffline })[v]();
}

/** Re-render the current view when its data changed (except lists the user scrolls in). */
export function refresh(kind: "player" | "data" | "offline") {
  if (kind === "player" && view === "np") updateNowPlaying();
  else if (kind === "data" && view === "cont") show("cont");
  else if (kind === "offline" && view === "off") show("off");
}

// ---------------------------------------------------------------- now playing

let npRefs: { bar: HTMLElement; fill: HTMLElement; knob: HTMLElement; pos: HTMLElement; rest: HTMLElement;
              play: HTMLElement; from: HTMLElement; rate: HTMLElement; here: HTMLElement } | null = null;

function renderNowPlaying() {
  const s = player.state;
  npRefs = null;
  if (!s.item) {
    main.append(h("div", { className: "empty" }, t("Nothing is playing.")));
    return;
  }
  const it = s.item;
  const cover = h("div", { className: "cover" }, it.image ? "" : it.subtitle || it.title);
  if (it.image) cover.style.backgroundImage = `url("${it.image}")`;
  const fill = h("i"), knob = h("b");
  const bar = h("div", { className: "bar" }, fill, knob);
  const seek = (e: PointerEvent) => {
    const r = bar.getBoundingClientRect();
    player.seekTo(Math.min(1, Math.max(0, (e.clientX - r.left) / r.width)));
  };
  bar.addEventListener("pointerdown", seek);
  const pos = h("span"), rest = h("span");
  const play = h("button", { className: "play", onclick: () => player.toggle() });
  const rate = h("button", { className: "rate", onclick: () => player.nextRate() });
  const here = h("span", { className: "val" });
  const from = h("div", { className: "from" });
  const kind = it.kind === "episode" ? `Podcast · ${it.subtitle ?? ""}` : it.subtitle ?? "";
  main.append(
    h("div", { className: "np" }, cover, h("div", {},
      h("div", { className: "kind" }, kind),
      h("div", { className: "title" }, it.title),
      h("div", { className: "sub" }, it.kind === "episode" ? it.published?.slice(0, 10) ?? "" : it.subtitle ?? ""),
      h("div", { className: "quality" },
        h("div", { className: "row" }, h("span", { className: "lbl" }, t("Source")), h("span", { className: "val" }, qualityText(it.quality))),
        h("div", { className: "row" }, h("span", { className: "lbl" }, t("Here")), here)),
      bar, h("div", { className: "times" }, pos, rest),
      h("div", { className: "ctrl" },
        s.queue.length > 1 ? h("button", { onclick: () => void player.skip(-1), ariaLabel: "previous" }, icon('<path d="M6 5v14M18 6l-9 6 9 6z" fill="currentColor"/>')) : null,
        h("button", { onclick: () => player.seekBy(-30000) }, "−30"), play,
        h("button", { onclick: () => player.seekBy(30000) }, "+30"),
        s.queue.length > 1 ? h("button", { onclick: () => void player.skip(1), ariaLabel: "next" }, icon('<path d="M18 5v14M6 6l9 6-9 6z" fill="currentColor"/>')) : rate),
      from)),
  );
  npRefs = { bar, fill, knob, pos, rest, play, from, rate, here };
  updateNowPlaying();
}

function updateNowPlaying() {
  if (!npRefs) return renderNowPlaying();
  const s = player.state;
  const p = player.position(), d = player.duration();
  const f = d ? Math.min(1, p / d) : 0;
  npRefs.fill.style.width = `${f * 100}%`;
  npRefs.knob.style.left = `${f * 100}%`;
  npRefs.pos.textContent = clock(p);
  npRefs.rest.textContent = d ? `−${clock(d - p)}` : "";
  npRefs.play.textContent = s.playing ? "❚❚" : "▶";
  npRefs.rate.textContent = `${s.rate.toLocaleString()}×`;
  const suffix = s.transcoded ? t("converted") : s.fromCache ? t("from cache") : t("unchanged");
  npRefs.here.textContent = `${qualityText(s.delivered)} · ${suffix}`;
  npRefs.from.textContent = s.takenOver ? t("Taken over from {device} · {ago}", { device: s.takenOver.device, ago: ago(s.takenOver.at) }) : "";
}

// ---------------------------------------------------------------- continue

async function renderContinue() {
  main.append(h("h2", {}, t("Continue")));
  let list: Playback[];
  try {
    list = online ? await api<Playback[]>("GET", "/playback?unfinished=true&limit=30") : [];
  } catch {
    list = [];
  }
  if (!online || !list.length) {
    // Offline: what this device knows.
    const local = await idbAll<Playback>("positions");
    if (!list.length) list = local.filter((p) => !p.finished && p.position_ms > 0).sort((a, b) => b.updated_at.localeCompare(a.updated_at));
  }
  if (!list.length) return void main.append(h("div", { className: "empty" }, t("Nothing to continue.")));
  const box = h("div", { className: "list" });
  for (const p of list) {
    const off = await offlineEntry(p.key);
    const f = p.duration_ms ? p.position_ms / p.duration_ms : 0;
    const item: Item = { key: p.key, kind: p.key.startsWith("episode:") ? "episode" : "track", title: p.title, subtitle: p.subtitle };
    box.append(h("div", { className: "item" }, thumb({ title: p.subtitle || p.title }),
      h("div", { className: "tx" }, h("div", { className: "t1" }, p.title || p.key),
        h("div", { className: "t2" }, `${clock(p.position_ms)}${p.duration_ms ? " / " + clock(p.duration_ms) : ""} · ${p.device ? t("Last on {device} · {ago}", { device: p.device, ago: ago(p.updated_at) }) : ago(p.updated_at)}`),
        h("div", { className: "prog" }, h("i", { style: `width:${f * 100}%` }))),
      h("span", { className: off?.status === "done" ? "badge ok" : "badge warn" }, off?.status === "done" ? t("in cache") : t("online only")),
      h("button", { className: "big", onclick: () => void start([item]) }, t("Resume"))));
  }
  main.append(box);
}

// ---------------------------------------------------------------- podcasts

let podTab: "new" | "subs" | number = "new";

interface Episode extends Item { podcast_id: number }

async function renderPodcasts() {
  const chips = h("div", { className: "chips" },
    h("button", { className: podTab === "new" ? "chip on" : "chip", onclick: () => ((podTab = "new"), show("pod")) }, t("New")),
    h("button", { className: podTab === "subs" ? "chip on" : "chip", onclick: () => ((podTab = "subs"), show("pod")) }, t("Subscribed")));
  main.append(chips);
  try {
    if (podTab === "subs") {
      const pods = await api<{ id: number; title: string; author: string; image_url: string; episodes: number }[]>("GET", "/podcasts");
      if (!pods.length) return void main.append(h("div", { className: "empty" }, t("No podcasts subscribed. Add them in the desktop or phone app.")));
      main.append(h("div", { className: "list" }, ...pods.map((p) =>
        h("div", { className: "item tap", onclick: () => ((podTab = p.id), show("pod")) }, thumb({ title: p.title, image: p.image_url }),
          h("div", { className: "tx" }, h("div", { className: "t1" }, p.title), h("div", { className: "t2" }, `${p.author} · ${p.episodes}`))))));
      return;
    }
    let eps: Episode[];
    if (typeof podTab === "number") {
      chips.append(h("button", { className: "chip", onclick: () => ((podTab = "subs"), show("pod")) }, `← ${t("Back")}`));
      eps = await api<Episode[]>("GET", `/podcasts/${podTab}/episodes?limit=60`);
    } else {
      eps = await api<Episode[]>("GET", "/episodes/latest?limit=40");
    }
    const items: Item[] = eps.map((e) => ({ ...e, kind: "episode", subtitle: e.podcast ?? "" }));
    const box = h("div", { className: "list" });
    for (const [i, e] of items.entries()) {
      const off = await offlineEntry(e.key);
      const f = e.position_ms && e.duration_ms ? e.position_ms / e.duration_ms : 0;
      box.append(h("div", { className: "item" }, thumb({ title: e.subtitle }),
        h("div", { className: "tx" }, h("div", { className: "t1" }, e.title),
          h("div", { className: "t2" }, [e.subtitle, e.published?.slice(0, 10), e.duration_ms ? clock(e.duration_ms) : ""].filter(Boolean).join(" · ")),
          f ? h("div", { className: "prog" }, h("i", { style: `width:${f * 100}%` })) : null),
        offBadge(off) ?? h("button", { className: "big sec", onclick: (ev: Event) => { (ev.target as HTMLButtonElement).disabled = true; void addOffline([e]); } }, t("Save offline")),
        h("button", { className: "big", onclick: () => void start([items[i]]) }, f ? t("Resume") : t("Play"))));
    }
    main.append(box);
  } catch (e) {
    main.append(failure(e));
  }
}

function offBadge(off?: OfflineEntry) {
  if (!off) return null;
  if (off.status === "done") return h("span", { className: "badge ok" }, t("in cache"));
  if (off.status === "error") return h("span", { className: "badge bad" }, t("failed"));
  return h("span", { className: "badge warn" }, off.status === "loading" ? t("loading {p}", { p: `${Math.round(off.progress * 100)} %` }) : t("waiting"));
}

// ---------------------------------------------------------------- music

let libStack: { source: number; parent?: string; title: string }[] = [];

async function renderMusic() {
  try {
    if (!libStack.length) {
      const sources = await api<{ id: number; name: string; kind: string }[]>("GET", "/sources");
      main.append(h("h2", {}, t("Music")));
      if (!sources.length) return void main.append(h("div", { className: "empty" }, t("No sources. Add them in the desktop or phone app.")));
      if (sources.length === 1) {
        libStack = [{ source: sources[0].id, title: sources[0].name }];
        return show("lib");
      }
      main.append(h("div", { className: "list" }, ...sources.map((s) =>
        h("div", { className: "item tap", onclick: () => ((libStack = [{ source: s.id, title: s.name }]), show("lib")) },
          thumb({ title: s.name }), h("div", { className: "tx" }, h("div", { className: "t1" }, s.name), h("div", { className: "t2" }, s.kind))))));
      return;
    }
    const cur = libStack[libStack.length - 1];
    const head = h("div", { className: "chips" });
    if (libStack.length > 1) head.append(h("button", { className: "chip", onclick: () => (libStack.pop(), show("lib")) }, `← ${t("Back")}`));
    head.append(h("h2", { style: "margin:0;overflow:hidden;white-space:nowrap;text-overflow:ellipsis" }, cur.title));
    main.append(head);
    const q = cur.parent ? `?parent=${encodeURIComponent(cur.parent)}&limit=300` : "";
    const res = await api<{ items: Item[] }>("GET", `/sources/${cur.source}/browse${q}`);
    const tracks = res.items.filter((i) => i.kind === "track");
    if (tracks.length) {
      head.append(h("button", { className: "big", onclick: () => void start(tracks, 0) }, t("Play all")),
        h("button", { className: "big sec", onclick: (ev: Event) => { (ev.target as HTMLButtonElement).disabled = true; void addOffline(tracks); } }, t("Save offline")));
    }
    const box = h("div", { className: "list" });
    for (const it of res.items) {
      if (it.kind === "track") {
        const off = await offlineEntry(it.key);
        box.append(h("div", { className: "item tap", onclick: () => void start(tracks, tracks.indexOf(it)) },
          h("div", { className: "ic" }, String(it.track ?? "♫")),
          h("div", { className: "tx" }, h("div", { className: "t1" }, it.title),
            h("div", { className: "t2" }, [it.subtitle, it.duration_ms ? clock(it.duration_ms) : ""].filter(Boolean).join(" · "))),
          offBadge(off), h("span", { className: "badge" }, qualityBadge(it.quality))));
      } else {
        const id = it.key.split(":")[2];
        box.append(h("div", { className: "item tap", onclick: () => (libStack.push({ source: cur.source, parent: id, title: it.title }), show("lib")) },
          thumb(it), h("div", { className: "tx" }, h("div", { className: "t1" }, it.title),
            h("div", { className: "t2" }, [it.subtitle, it.year].filter(Boolean).join(" · ")))));
      }
    }
    main.append(box);
  } catch (e) {
    main.append(failure(e));
  }
}

// ---------------------------------------------------------------- offline

async function renderOffline() {
  main.append(h("h2", {}, t("Offline")));
  try {
    const est = await navigator.storage.estimate();
    main.append(h("div", { className: "storage" },
      t("Used {used} of about {quota}", { used: bytes(est.usage ?? 0), quota: bytes(est.quota ?? 0) }),
      h("div", { className: "note" }, t("The browser may clear this storage when space runs low; missing titles are downloaded again automatically."))));
  } catch {
    /* no storage manager */
  }
  const list = (await offlineList()).sort((a, b) => b.added.localeCompare(a.added));
  if (!list.length) main.append(h("div", { className: "empty" }, t("Nothing saved offline yet.")));
  const box = h("div", { className: "list" });
  for (const e of list) {
    const status = { queued: t("waiting"), loading: t("loading {p}", { p: `${Math.round(e.progress * 100)} %` }), done: t("ready"),
                     error: t("failed"), missing: t("missing – will reload") }[e.status];
    const q = e.delivered ?? e.source;
    box.append(h("div", { className: "item" },
      h("div", { className: "tx" }, h("div", { className: "t1" }, e.title),
        h("div", { className: "t2" }, [e.subtitle, e.bytes ? bytes(e.bytes) : "", qualityBadge(q) + (e.transcoded ? ` (${t("converted")})` : "")].filter(Boolean).join(" · ")),
        e.status === "loading" ? h("div", { className: "prog" }, h("i", { style: `width:${e.progress * 100}%` })) : null),
      h("span", { className: e.status === "done" ? "badge ok" : e.status === "error" ? "badge bad" : "badge warn" }, status),
      e.status === "error" ? h("button", { className: "big sec", onclick: () => void retryFailed() }, "↻") : null,
      h("button", { className: "big sec", onclick: () => void removeFromOffline(e.key) }, t("Remove"))));
  }
  main.append(box);
  main.append(h("div", { style: "margin-top:24px" }, h("button", { className: "big sec", onclick: () => onLogout() }, t("Sign out this device"))));
}
