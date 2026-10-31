// Screens of the web app. Plain DOM; each view renders itself into <main>.

import { api, online, qualityBadge, qualityChips, qualityText, type Item, type Playback } from "./api";
import { addOffline, offlineEntry, offlineList, removeFromOffline, retryFailed, type OfflineEntry } from "./downloads";
import { ago, bytes, clock, t } from "./i18n";
import { idbAll } from "./idb";
import * as player from "./player";
import { pendingCount } from "./sync";
import { isDark, onAppearance, toggleDark } from "./theme";

type View = "np" | "cont" | "pod" | "books" | "lib" | "off";
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
  books: '<path d="M5 4h11a3 3 0 0 1 3 3v13H8a3 3 0 0 1-3-3z"/><path d="M5 17a3 3 0 0 1 3-3h11"/>',
  lib: '<path d="M9 18V5l11-2v13"/><circle cx="6" cy="18" r="3"/><circle cx="17" cy="16" r="3"/>',
  off: '<path d="M12 4v11m0 0-4-4m4 4 4-4M5 20h14"/>',
};
const RADIO_ICON = '<rect x="3" y="8" width="18" height="12" rx="2"/><path d="M7 8l10-5"/><circle cx="8" cy="14" r="2"/><path d="M14 13h4M14 16h4"/>';
const LABELS: Record<View, string> = { np: "Now playing", cont: "Continue", pod: "Podcasts", books: "Audiobooks", lib: "Music", off: "Offline" };

function initials(s: string) {
  return s.split(/\s+/).filter(Boolean).slice(0, 3).map((w) => w[0]).join("").toUpperCase() || "♫";
}

/** Cover over the initials; a missing cover (404, offline) leaves the initials. */
function thumb(it: { image?: string | null; title: string }) {
  const d = h("div", { className: "ic" }, initials(it.title));
  if (it.image) {
    const img = h("img", { src: it.image, alt: "" });
    img.addEventListener("error", () => img.remove());
    d.append(img);
  }
  return d;
}

function failure(e: unknown) {
  return h("div", { className: "empty" }, online ? `${t("Error")}: ${(e as Error).message}` : t("Server not reachable."));
}

/** Click handler of a button inside a tappable row: the row must not react as well. */
const own = (f: (ev: Event) => void) => (ev: Event) => { ev.stopPropagation(); f(ev); };

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
  root.replaceChildren(h("div", { className: "shell" }, top, nav, main, themeButton()));
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
  top.replaceChildren(h("div", { className: "logo" }, h("img", { src: "/icon-192.png", alt: "" }), "audiojoe"), net, sync);
  void offlineUsage().then((u) => u && top.append(h("div", { className: "pill" }, `${t("Offline")} ${u}`)));
}

/** Moon button below the top bar, top right over the content: dark mode on (filled, accent)
 *  or off (outline). */
function themeButton() {
  const b = h("button", { className: "theme", onclick: () => toggleDark() });
  const paint = () => {
    const on = isDark();
    b.classList.toggle("on", on);
    b.ariaLabel = b.title = on ? t("Dark mode: on") : t("Dark mode: off");
    b.replaceChildren(icon(on
      ? '<path d="M20 14.5A8.5 8.5 0 0 1 9.5 4a8.5 8.5 0 1 0 10.5 10.5z" fill="currentColor"/>'
      : '<path d="M20 14.5A8.5 8.5 0 0 1 9.5 4a8.5 8.5 0 1 0 10.5 10.5z"/>'));
  };
  paint();
  onAppearance(paint);
  return b;
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
  ({ np: renderNowPlaying, cont: renderContinue, pod: renderPodcasts, books: renderBooks, lib: renderMusic, off: renderOffline })[v]();
}

/** Re-render the current view when its data changed (except lists the user scrolls in). */
export function refresh(kind: "player" | "data" | "offline") {
  if (kind === "player" && view === "np") updateNowPlaying();
  else if (kind === "data" && view === "cont") show("cont");
  else if (kind === "offline" && view === "off") show("off");
  else if (kind === "offline" && view === "np" && npRefs) void fillOffTool(npRefs.off);
}

// ---------------------------------------------------------------- now playing

// Large touch targets throughout: this is used while driving.
let npTab: "play" | "details" | "chapters" = "play";
let npKey = "";
let npRefs: { bar: HTMLElement; fill: HTMLElement; knob: HTMLElement; pos: HTMLElement; rest: HTMLElement; play: HTMLElement;
              from: HTMLElement; rate: HTMLElement; here: HTMLElement; sub: HTMLElement; next: HTMLButtonElement; off: HTMLElement } | null = null;

/** Offline field of the player toolbar: save button, then live progress, then "in cache". */
async function fillOffTool(box: HTMLElement) {
  const it = player.state.item;
  if (!it || player.isLive()) return box.replaceChildren();
  const off = await offlineEntry(it.key);
  const key = off ? `${off.status}:${Math.round((off.progress ?? 0) * 100)}` : "none";
  if (box.dataset.v === key) return;
  box.dataset.v = key;
  box.replaceChildren(offBadge(off) ?? h("button", { className: "big sec", onclick: (ev: Event) => {
    (ev.target as HTMLButtonElement).disabled = true;
    void addOffline([it]);
  } }, t("Save offline")));
}

const skipIcon = (n: number, back: boolean) => icon(
  (back ? '<path d="M4.5 12a7.5 7.5 0 1 0 2.2-5.3"/><path d="M5 3.5v4h4"/>' : '<path d="M19.5 12a7.5 7.5 0 1 1-2.2-5.3"/><path d="M19 3.5v4h-4"/>') +
  `<text x="12" y="15.2" font-size="8" font-weight="800" text-anchor="middle" fill="currentColor" stroke="none">${n}</text>`);

function chipRow(label: string, chips: string[], note = "") {
  return h("div", { className: "row" }, h("span", { className: "lbl" }, label),
    h("span", { className: "fchips" }, ...chips.map((c) => h("span", { className: "fchip" }, c)), note ? h("span", { className: "fnote" }, note) : null));
}

function renderNowPlaying() {
  const s = player.state;
  npRefs = null;
  if (!s.item) {
    main.append(h("div", { className: "empty" }, t("Nothing is playing.")));
    return;
  }
  const it = s.item;
  npKey = it.key;
  if (npTab === "chapters" && !it.chapters?.length) npTab = "play";
  const tab = (v: typeof npTab, label: string) =>
    h("button", { className: npTab === v ? "chip on" : "chip", onclick: () => ((npTab = v), show("np")) }, label);
  main.append(h("div", { className: "chips" }, tab("play", t("Playback")), tab("details", t("Details")),
    it.chapters?.length ? tab("chapters", t("Chapters")) : null));
  if (npTab === "details") return renderDetails(it);
  if (npTab === "chapters") return renderChapters(it);

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
  const rate = h("button", { className: "big sec", onclick: () => player.nextRate() });
  // In the car: offline state left, speed, next item of the queue right (no sleep timer).
  const next = h("button", { className: "big sec next", onclick: () => void player.skip(1) }, t("Next item"),
    icon('<path d="M18 5v14M6 6l9 6-9 6z" fill="currentColor"/>')) as HTMLButtonElement;
  const here = h("div");
  const from = h("div", { className: "from" });
  const kind = it.kind === "episode" ? `Podcast · ${it.subtitle ?? ""}` : it.subtitle ?? "";
  const sub = h("div", { className: "sub" }, it.kind === "episode" ? it.published?.slice(0, 10) ?? "" : it.kind === "book" ? "" : it.subtitle ?? "");
  const off = h("div", { className: "offtool" });
  const tools = h("div", { className: "tools" }, off, rate, next);
  void fillOffTool(off);
  main.append(
    h("div", { className: "np" }, cover, h("div", {},
      h("div", { className: "kind" }, kind),
      h("div", { className: "title" }, it.title),
      sub,
      h("div", { className: "fmt" }, chipRow(t("Source"), qualityChips(it.quality)), here),
      bar, h("div", { className: "times" }, pos, rest),
      h("div", { className: "ctrl" },
        s.queue.length > 1 ? h("button", { onclick: () => void player.skip(-1), ariaLabel: t("Previous") }, icon('<path d="M6 5v14M18 6l-9 6 9 6z" fill="currentColor"/>')) : null,
        player.isLive() ? null : h("button", { className: "skip", onclick: () => player.seekBy(-15000), ariaLabel: t("Back {n} s", { n: 15 }) }, skipIcon(15, true)),
        play,
        player.isLive() ? null : h("button", { className: "skip", onclick: () => player.seekBy(30000), ariaLabel: t("Forward {n} s", { n: 30 }) }, skipIcon(30, false)),
        s.queue.length > 1 ? h("button", { onclick: () => void player.skip(1), ariaLabel: t("Next") }, icon('<path d="M18 5v14M6 6l9 6-9 6z" fill="currentColor"/>')) : null),
      player.isLive() ? null : tools,
      from)),
  );
  npRefs = { bar, fill, knob, pos, rest, play, from, rate, here, sub, next, off };
  updateNowPlaying();
}

function renderDetails(it: Item) {
  const facts = [it.published?.slice(0, 10), it.year, player.duration() && !player.isLive() ? clock(player.duration()) : "",
    it.chapters?.length ? t("{n} chapters", { n: it.chapters.length }) : ""].filter(Boolean) as string[];
  main.append(h("div", { className: "details" },
    h("div", { className: "head" }, thumb({ title: it.subtitle || it.title, image: it.image }),
      h("div", {}, h("div", { className: "title" }, it.title), h("div", { className: "sub" }, it.subtitle ?? ""),
        h("div", { className: "facts" }, ...facts.map((f) => h("span", { className: "badge" }, String(f)))))),
    it.notes ? notesView(it.notes) : h("div", { className: "desc" }, it.description || t("No description.")),
    it.quality?.codec ? h("div", { className: "note" }, `${t("Format")}: ${qualityText(it.quality)}`) : null));
}

/** Shownotes rebuilt from an allow-list of elements. Links stay plain text: in the car a
 *  link would leave the app. */
function notesView(html: string) {
  const block: Record<string, string> = { P: "p", UL: "ul", OL: "ol", LI: "li", BLOCKQUOTE: "blockquote",
    H1: "h4", H2: "h4", H3: "h4", H4: "h4", H5: "h4", H6: "h4" };
  const inline: Record<string, string> = { B: "b", STRONG: "b", I: "i", EM: "i", A: "span" };
  const copy = (from: Node, to: HTMLElement) => {
    for (const n of Array.from(from.childNodes)) {
      if (n.nodeType === Node.TEXT_NODE) to.append(n.textContent ?? "");
      else if (n instanceof Element) {
        if (n.tagName === "BR") { to.append(document.createElement("br")); continue; }
        const tag = block[n.tagName] ?? inline[n.tagName];
        if (!tag) { copy(n, to); continue; }
        const el = document.createElement(tag);
        if (n.tagName === "A") el.className = "link";
        copy(n, el);
        to.append(el);
      }
    }
  };
  const box = h("div", { className: "notes" });
  copy(new DOMParser().parseFromString(html, "text/html").body, box);
  return box;
}

// ---------------------------------------------------------------- details page

/** Details of an episode, book or title in place of the list; nothing plays until a button
 *  is pressed. "Back" re-renders the list. */
function openDetails(base: Item) {
  const back = view;
  main.replaceChildren(h("div", { className: "chips" }, h("button", { className: "chip", onclick: () => show(back) }, `← ${t("Back")}`)));
  main.scrollTop = 0;
  const page = h("div", { className: "details page" });
  main.append(page);
  void (async () => {
    let it = base;
    try {
      it = { ...base, ...(await api<Item>("GET", `/items/${encodeURIComponent(base.key)}`)) };
    } catch { /* offline: what the list knew */ }
    const pos = it.playback?.position_ms ?? it.position_ms ?? 0;
    const finished = it.playback?.finished ?? it.finished ?? false;
    const dur = it.duration_ms ?? 0;
    const facts = [it.published?.slice(0, 10) || (it.year ? String(it.year) : ""), dur ? clock(dur) : "", ...(it.genres ?? []),
      it.chapters?.length ? t("{n} chapters", { n: it.chapters.length }) : "", qualityBadge(it.quality)].filter(Boolean) as string[];
    const off = await offlineEntry(it.key);
    const parts: (HTMLElement | null)[] = [
      h("div", { className: "head" }, h("div", { className: "art" }, thumb({ title: it.subtitle || it.title, image: it.image ?? base.image })),
        h("div", {}, h("div", { className: "title" }, it.title), h("div", { className: "sub" }, it.subtitle ?? ""),
          it.series ? h("div", { className: "sub" }, it.series) : null,
          h("div", { className: "facts" }, ...facts.map((f) => h("span", { className: "badge" }, f))),
          pos > 0 && !finished && dur ? h("div", { className: "prog" }, h("i", { style: `width:${(pos / dur) * 100}%` })) : null,
          pos > 0 && !finished && dur ? h("div", { className: "sub" }, `${clock(pos)} / ${clock(dur)}`) : null,
          h("div", { className: "chips", style: "margin-top:12px" },
            h("button", { className: "big", onclick: () => void start([it]) }, pos > 0 && !finished ? t("Resume") : t("Play")),
            offBadge(off) ?? h("button", { className: "big sec", onclick: (ev: Event) => { (ev.target as HTMLButtonElement).disabled = true; void addOffline([it]); } }, t("Save offline"))))),
      it.notes ? notesView(it.notes) : h("div", { className: "desc" }, it.description || t("No description.")),
      it.chapters?.length ? h("h3", {}, t("Chapters")) : null,
      it.chapters?.length ? h("div", { className: "list" }, ...it.chapters.map((c) =>
        h("div", { className: "item" }, h("div", { className: "tx" }, h("div", { className: "t1" }, c.title)), h("span", { className: "badge" }, clock(c.start_ms))))) : null,
      it.quality?.codec ? h("div", { className: "note" }, `${t("Format")}: ${qualityText(it.quality)}`) : null];
    page.append(...parts.filter((x): x is HTMLElement => x !== null));
  })();
}

/** Head of an opened album: cover, artist, year, genres, length, format, description. */
function albumHead(album: Item, tracks: Item[], buttons: HTMLElement[]) {
  const total = tracks.reduce((n, x) => n + (x.duration_ms ?? 0), 0);
  const q = tracks.map((x) => qualityBadge(x.quality)).find(Boolean) ?? "";
  const facts = h("div", { className: "facts" });
  const desc = h("div", {});
  const fill = (a: Item) => facts.replaceChildren(...[a.year ? String(a.year) : "", ...(a.genres ?? []), t("{n} titles", { n: tracks.length }),
    total ? clock(total) : "", q].filter(Boolean).map((f) => h("span", { className: "badge" }, f)));
  fill(album);
  void api<Item>("GET", `/items/${encodeURIComponent(album.key)}`).then((a) => {
    fill({ ...album, ...a });
    if (a.notes) desc.replaceChildren(notesView(a.notes));
  }).catch(() => undefined);
  return h("div", { className: "details album" },
    h("div", { className: "head" }, h("div", { className: "art" }, thumb(album)),
      h("div", {}, h("div", { className: "title" }, album.title), h("div", { className: "sub" }, album.subtitle ?? ""), facts,
        h("div", { className: "chips", style: "margin-top:12px" }, ...buttons))),
    desc);
}

function renderChapters(it: Item) {
  const now = player.position();
  main.append(h("div", { className: "list" }, ...(it.chapters ?? []).map((c) =>
    h("div", { className: now >= c.start_ms && now < c.end_ms ? "item tap on" : "item tap", onclick: () => {
      player.seekTo(c.start_ms / (player.duration() || 1));
      npTab = "play";
      show("np");
    } }, h("div", { className: "tx" }, h("div", { className: "t1" }, c.title)), h("span", { className: "badge" }, clock(c.start_ms))))));
}

function updateNowPlaying() {
  const s = player.state;
  if (s.item?.key !== npKey) return renderNowPlaying();
  if (npTab !== "play") return;
  if (!npRefs) return renderNowPlaying();
  const p = player.position(), d = player.duration();
  const f = d ? Math.min(1, p / d) : 0;
  npRefs.fill.style.width = `${f * 100}%`;
  npRefs.knob.style.left = `${f * 100}%`;
  npRefs.pos.textContent = player.isLive() ? t("Live") : clock(p);
  npRefs.rest.textContent = player.isLive() ? "" : d ? `−${clock(d - p)}` : "";
  npRefs.bar.style.visibility = player.isLive() ? "hidden" : "";
  npRefs.play.textContent = s.playing ? "❚❚" : "▶";
  npRefs.rate.textContent = `${t("Speed")} ${s.rate.toLocaleString()}×`;
  npRefs.next.disabled = s.index + 1 >= s.queue.length;
  const suffix = s.transcoded ? t("converted") : s.fromCache ? t("from cache") : t("unchanged");
  const here = JSON.stringify([s.delivered, suffix]);
  if (npRefs.here.dataset.v !== here) {
    npRefs.here.dataset.v = here;
    npRefs.here.replaceChildren(chipRow(t("Here"), qualityChips(s.delivered), suffix));
  }
  if (s.item?.chapters?.length) {
    const c = player.chapter();
    if (npRefs.sub.textContent !== c) npRefs.sub.textContent = c;
  }
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
    const kind = p.key.startsWith("episode:") ? "episode" : p.key.startsWith("abs:") ? "book" : "track";
    const item: Item = { key: p.key, kind, title: p.title, subtitle: p.subtitle };
    const base: Item = { ...item, image: `/api/v1/image/${encodeURIComponent(p.key)}`, duration_ms: p.duration_ms, position_ms: p.position_ms };
    box.append(h("div", { className: "item tap", onclick: () => openDetails(base) }, thumb({ title: p.subtitle || p.title, image: base.image }),
      h("div", { className: "tx" }, h("div", { className: "t1" }, p.title || p.key),
        h("div", { className: "t2" }, `${clock(p.position_ms)}${p.duration_ms ? " / " + clock(p.duration_ms) : ""} · ${p.device ? t("Last on {device} · {ago}", { device: p.device, ago: ago(p.updated_at) }) : ago(p.updated_at)}`),
        h("div", { className: "prog" }, h("i", { style: `width:${f * 100}%` }))),
      h("span", { className: off?.status === "done" ? "badge ok" : "badge warn" }, off?.status === "done" ? t("in cache") : t("online only")),
      h("button", { className: "big", onclick: own(() => void start([item])) }, t("Resume"))));
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
      const pods = await api<{ id: number; title: string; author: string; image: string | null; episodes: number }[]>("GET", "/podcasts");
      if (!pods.length) return void main.append(h("div", { className: "empty" }, t("No podcasts subscribed. Add them in the desktop or phone app.")));
      main.append(h("div", { className: "list" }, ...pods.map((p) =>
        h("div", { className: "item tap", onclick: () => ((podTab = p.id), show("pod")) }, thumb({ title: p.title, image: p.image }),
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
      box.append(h("div", { className: "item tap", onclick: () => openDetails(items[i]) }, thumb({ title: e.subtitle, image: e.image }),
        h("div", { className: "tx" }, h("div", { className: "t1" }, e.title),
          h("div", { className: "t2" }, [e.subtitle, e.published?.slice(0, 10), e.duration_ms ? clock(e.duration_ms) : ""].filter(Boolean).join(" · ")),
          f ? h("div", { className: "prog" }, h("i", { style: `width:${f * 100}%` })) : null),
        offBadge(off) ?? h("button", { className: "big sec", onclick: own((ev) => { (ev.target as HTMLButtonElement).disabled = true; void addOffline([e]); }) }, t("Save offline")),
        h("button", { className: "big", onclick: own(() => void start([items[i]])) }, f ? t("Resume") : t("Play"))));
    }
    main.append(box);
  } catch (e) {
    main.append(failure(e));
  }
}

/** Offline state in place of the "Save offline" button, with the same size. */
function offBadge(off?: OfflineEntry) {
  if (!off) return null;
  if (off.status === "done") return h("span", { className: "badge slot ok" }, t("in cache"));
  if (off.status === "error") return h("span", { className: "badge slot bad" }, t("failed"));
  return h("span", { className: "badge slot warn" }, off.status === "loading" ? t("loading {p}", { p: `${Math.round(off.progress * 100)} %` }) : t("waiting"));
}

// ---------------------------------------------------------------- music

let libStack: { source: number; parent?: string; title: string; album?: Item }[] = [];

async function renderMusic() {
  try {
    if (!libStack.length) {
      const sources = (await api<{ id: number; name: string; kind: string }[]>("GET", "/sources")).filter((x) => ["jellyfin", "emby", "plex"].includes(x.kind));
      main.append(h("h2", {}, t("Music")));
      main.append(h("div", { className: "list" },
        h("div", { className: "item tap", onclick: () => ((libStack = [{ source: RADIO, title: t("Internet radio") }]), show("lib")) },
          h("div", { className: "ic" }, icon(RADIO_ICON)), h("div", { className: "tx" }, h("div", { className: "t1" }, t("Internet radio")), h("div", { className: "t2" }, t("Favourites and search")))),
        ...sources.map((s) =>
        h("div", { className: "item tap", onclick: () => ((libStack = [{ source: s.id, title: s.name }]), show("lib")) },
          thumb({ title: s.name }), h("div", { className: "tx" }, h("div", { className: "t1" }, s.name), h("div", { className: "t2" }, s.kind))))));
      return;
    }
    const cur = libStack[libStack.length - 1];
    if (cur.source === RADIO) return renderRadio();
    const head = h("div", { className: "chips" });
    head.append(h("button", { className: "chip", onclick: () => (libStack.pop(), show("lib")) }, `← ${t("Back")}`));
    if (!cur.album) head.append(h("h2", { style: "margin:0;overflow:hidden;white-space:nowrap;text-overflow:ellipsis" }, cur.title));
    main.append(head);
    const q = cur.parent ? `?parent=${encodeURIComponent(cur.parent)}&limit=300` : "";
    const res = await api<{ items: Item[] }>("GET", `/sources/${cur.source}/browse${q}`);
    const tracks = res.items.filter((i) => i.kind === "track");
    const buttons = tracks.length ? [h("button", { className: "big", onclick: () => void start(tracks, 0) }, cur.album ? t("Play album") : t("Play all")),
      h("button", { className: "big sec", onclick: (ev: Event) => { (ev.target as HTMLButtonElement).disabled = true; void addOffline(tracks); } }, t("Save offline"))] : [];
    if (cur.album) main.append(albumHead(cur.album, tracks, buttons));
    else head.append(...buttons);
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
        box.append(h("div", { className: "item tap", onclick: () => (libStack.push({ source: cur.source, parent: id, title: it.title, album: it.kind === "album" ? it : undefined }), show("lib")) },
          thumb(it), h("div", { className: "tx" }, h("div", { className: "t1" }, it.title),
            h("div", { className: "t2" }, [it.subtitle, it.year].filter(Boolean).join(" · ")))));
      }
    }
    main.append(box);
  } catch (e) {
    main.append(failure(e));
  }
}

// ---------------------------------------------------------------- internet radio

const RADIO = -1;
let radioQuery = "";

async function renderRadio() {
  const input = h("input", { className: "search", value: radioQuery, placeholder: t("Search stations"), enterKeyHint: "search" }) as HTMLInputElement;
  const go = () => ((radioQuery = input.value.trim()), show("lib"));
  input.addEventListener("keydown", (e) => (e as KeyboardEvent).key === "Enter" && go());
  main.append(h("div", { className: "chips" },
    h("button", { className: "chip", onclick: () => ((libStack = []), (radioQuery = ""), show("lib")) }, `← ${t("Back")}`),
    input, h("button", { className: "big", onclick: go }, t("Search"))));
  try {
    const list = radioQuery
      ? await api<Item[]>("GET", `/radio/search?q=${encodeURIComponent(radioQuery)}`)
      : await api<Item[]>("GET", "/radio/favorites");
    main.append(h("h2", {}, radioQuery ? t("Results") : t("Favourites")));
    if (!list.length) return void main.append(h("div", { className: "empty" }, radioQuery ? t("No stations found.") : t("No favourites yet. Search for a station.")));
    const box = h("div", { className: "list" });
    for (const st of list) {
      const star = h("button", { className: st.favorite ? "big" : "big sec", style: "min-width:64px", ariaLabel: t("Favourite") }, st.favorite ? "★" : "☆");
      star.onclick = async () => {
        await api(st.favorite ? "DELETE" : "PUT", `/radio/favorites/${st.key.slice(6)}`);
        st.favorite = !st.favorite;
        star.textContent = st.favorite ? "★" : "☆";
        star.className = st.favorite ? "big" : "big sec";
      };
      box.append(h("div", { className: "item" }, thumb(st),
        h("div", { className: "tx" }, h("div", { className: "t1" }, st.title), h("div", { className: "t2" }, st.subtitle)),
        h("span", { className: "badge" }, qualityBadge(st.quality)), star,
        h("button", { className: "big", onclick: () => void start([st]) }, t("Play"))));
    }
    main.append(box);
  } catch (e) {
    main.append(failure(e));
  }
}

// ---------------------------------------------------------------- audiobooks

let bookStack: { source: number; parent?: string; title: string }[] = [];

async function renderBooks() {
  try {
    if (!bookStack.length) {
      const sources = (await api<{ id: number; name: string; kind: string }[]>("GET", "/sources")).filter((x) => x.kind === "audiobookshelf");
      if (!sources.length) {
        main.append(h("h2", {}, t("Audiobooks")), h("div", { className: "empty" }, t("No audiobook sources. Add Audiobookshelf in the desktop or phone app.")));
        return;
      }
      bookStack = [{ source: sources[0].id, title: sources[0].name }];
    }
    const cur = bookStack[bookStack.length - 1];
    const q = cur.parent ? `?parent=${encodeURIComponent(cur.parent)}&limit=500` : "";
    const res = await api<{ items: Item[] }>("GET", `/sources/${cur.source}/browse${q}`);
    // A single library: show its books directly.
    if (!cur.parent && res.items.length === 1 && res.items[0].kind === "folder") {
      bookStack.push({ source: cur.source, parent: res.items[0].key.split(":")[2], title: res.items[0].title });
      return show("books");
    }
    const head = h("div", { className: "chips" });
    if (bookStack.length > 1 && !(bookStack.length === 2 && res.items.every((i) => i.kind === "book"))) {
      head.append(h("button", { className: "chip", onclick: () => (bookStack.pop(), show("books")) }, `← ${t("Back")}`));
    }
    head.append(h("h2", { style: "margin:0" }, t("Audiobooks")));
    main.append(head);
    const positions = new Map<string, Playback>();
    try {
      for (const p of await api<Playback[]>("GET", "/playback?limit=200")) positions.set(p.key, p);
    } catch { /* offline: no positions */ }
    const box = h("div", { className: "list" });
    for (const it of res.items) {
      if (it.kind === "folder") {
        box.append(h("div", { className: "item tap", onclick: () => (bookStack.push({ source: cur.source, parent: it.key.split(":")[2], title: it.title }), show("books")) },
          thumb(it), h("div", { className: "tx" }, h("div", { className: "t1" }, it.title))));
        continue;
      }
      const p = positions.get(it.key);
      const f = p && it.duration_ms && !p.finished ? p.position_ms / it.duration_ms : 0;
      const off = await offlineEntry(it.key);
      box.append(h("div", { className: "item tap", onclick: () => openDetails({ ...it, position_ms: p?.position_ms }) }, thumb(it),
        h("div", { className: "tx" }, h("div", { className: "t1" }, it.title),
          h("div", { className: "t2" }, [it.subtitle, it.duration_ms ? clock(it.duration_ms) : ""].filter(Boolean).join(" · ")),
          f ? h("div", { className: "prog" }, h("i", { style: `width:${f * 100}%` })) : null),
        offBadge(off) ?? h("button", { className: "big sec", onclick: own((ev) => { (ev.target as HTMLButtonElement).disabled = true; void addOffline([it]); }) }, t("Save offline")),
        h("button", { className: "big", onclick: own(() => void start([it])) }, f ? t("Resume") : t("Play"))));
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
