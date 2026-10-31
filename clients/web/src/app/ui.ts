// Screens of the web app. Plain DOM; each view renders itself into <main>.

import { api, online, qualityBadge, qualityChips, qualityText, type Item, type Playback, type Quality } from "./api";
import { addOffline, dropPlayedOn, offlineEntry, offlineList, removeFromOffline, retryFailed, setDropPlayed, type OfflineEntry } from "./downloads";
import { ago, bytes, clock, t } from "./i18n";
import { idbAll } from "./idb";
import * as player from "./player";
import { pendingCount, savePosition, stale } from "./sync";
import { isDark, onAppearance, toggleDark } from "./theme";

type View = "np" | "cont" | "pod" | "books" | "lib" | "radio" | "off";
// Offline is reached from the indicator at the top, not from the navigation.
const NAV: View[] = ["np", "cont", "pod", "books", "lib", "radio"];
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
  radio: '<rect x="3" y="8" width="18" height="12" rx="2"/><path d="M7 8l10-5"/><circle cx="8" cy="14" r="2"/><path d="M14 13h4M14 16h4"/>',
  off: '<path d="M12 4v11m0 0-4-4m4 4 4-4M5 20h14"/>',
};
const LABELS: Record<View, string> = { np: "Now playing", cont: "Continue", pod: "Podcasts", books: "Audiobooks", lib: "Music", radio: "Radio", off: "Offline" };

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

async function start(items: Item[], index = 0, entry?: player.Entry) {
  const meta = await player.itemMeta(items[index].key);
  const queue = items.slice();
  if (meta) queue[index] = { ...items[index], ...meta };
  await player.play(queue, index, entry);
  show("np");
}

// ---------------------------------------------------------------- continue lists, "Next"

type ListName = player.Entry["list"];
interface ListEntry { key: string; title: string; subtitle: string; position_ms: number; duration_ms: number | null; device: string; updated_at: string | null }

const listOf = (it: Item): ListName => (it.kind === "episode" ? "podcasts" : it.kind === "book" ? "books" : "music");

/** "Next": appends the item (an album as one entry) at the end of its continue list. */
function nextButton(it: Item) {
  const b = h("button", { className: "big sec", title: t("Added to Next") }, t("Add to Next")) as HTMLButtonElement;
  b.onclick = own(async () => {
    b.disabled = true;
    try {
      await api("POST", `/lists/${listOf(it)}`, { key: it.key, title: it.title, subtitle: it.subtitle ?? it.podcast ?? "" });
      b.textContent = `✓ ${t("Add to Next")}`;
    } catch {
      b.disabled = false;
    }
  });
  return b;
}

/** Tracks of an album entry ("jellyfin:2:abc" → browse parent abc of source 2). */
async function albumTracks(key: string): Promise<Item[]> {
  const [, src, id] = key.split(":");
  const res = await api<{ items: Item[] }>("GET", `/sources/${src}/browse?parent=${encodeURIComponent(id)}&limit=500`);
  return res.items.filter((i) => i.kind === "track");
}

async function playEntry(list: ListName, e: ListEntry) {
  const entry = { list, key: e.key };
  if (list === "music") {
    const tracks = await albumTracks(e.key);
    if (tracks.length) await start(tracks, 0, entry);
    return;
  }
  await start([{ key: e.key, kind: list === "podcasts" ? "episode" : "book", title: e.title, subtitle: e.subtitle }], 0, entry);
}

// At the end of an item: the next entry of the same list plays.
player.setNextAfter(async (entry) => {
  let list: ListEntry[];
  try {
    list = await api<ListEntry[]>("GET", `/lists/${entry.list}`);
  } catch {
    return null;
  }
  const i = list.findIndex((x) => x.key === entry.key);
  if (i < 0) return null;
  if (entry.list === "music") void api("DELETE", `/lists/music/${encodeURIComponent(entry.key)}`).catch(() => undefined);
  const next = list[i + 1];
  return next ? () => playEntry(entry.list, next) : null;
});

/** A short note at the bottom with an undo button. */
function undoBar(text: string, undo: () => Promise<void>) {
  document.querySelector(".toast")?.remove();
  const bar = h("div", { className: "toast" }, h("span", {}, text));
  const b = h("button", { className: "big sec" }, t("Undo")) as HTMLButtonElement;
  b.onclick = async () => {
    b.disabled = true;
    bar.remove();
    await undo().catch(() => undefined);
    show(view);
  };
  bar.append(b);
  document.body.append(bar);
  setTimeout(() => bar.remove(), 7000);
}

// ---------------------------------------------------------------- shell

export function mountShell(root: HTMLElement, logout: () => void) {
  onLogout = logout;
  top = h("header", { className: "top" });
  const nav = h("nav");
  for (const v of NAV) {
    nav.append(h("button", { onclick: () => show(v), className: v === view ? "active" : "" }, icon(ICONS[v]), t(LABELS[v])));
    (nav.lastElementChild as HTMLElement).dataset.v = v;
  }
  main = h("main");
  const moon = themeButton();
  // The moon belongs to the first line: it scrolls away with the content and is cut off at
  // the top bar instead of floating over the list.
  const follow = () => {
    const y = main.scrollTop, gap = main.getBoundingClientRect().top - moon.offsetParent!.getBoundingClientRect().top;
    moon.style.transform = y ? `translateY(${-y}px)` : "";
    moon.style.clipPath = y ? `inset(${Math.max(0, gap - (moon.offsetTop - y))}px 0 0 0)` : "";
    moon.style.visibility = y > moon.offsetTop - gap + moon.offsetHeight ? "hidden" : "";
  };
  main.addEventListener("scroll", follow, { passive: true });
  root.replaceChildren(h("div", { className: "shell" }, top, nav, main, moon));
  renderTop();
  show(view);
}

let usage = "";
export function renderTop() {
  if (!top) return;
  // As wide as its own text: "Server" is short, offline is a real change of state.
  const net = h("div", { className: online ? "pill ok" : "pill warn", id: "net", title: online ? t("Server reachable") : t("Offline · cache") },
    h("span", { className: "dot" }), online ? t("Server") : t("Offline · cache"));
  // "Position" with a tick; a cross in red once a position has waited more than 30 s for the server.
  const sync = h("div", { className: stale ? "pill bad" : "pill ok", id: "sync",
    title: !stale ? t("Positions synced") : pendingCount === 1 ? t("1 position waiting for the server") : t("{n} positions waiting for the server", { n: pendingCount }) },
    h("span", { className: "mark", ariaHidden: "true" }, stale ? "✕" : "✓"), t("Position"));
  // The offline size keeps its last value until the new one is known (no gap, no jump).
  // Opens the offline page (it has no place in the navigation).
  const off = h("button", { className: view === "off" ? "pill num tap on" : "pill num tap", id: "offsize", onclick: () => show("off") },
    usage ? `${t("Offline")} ${usage}` : t("Offline"));
  top.replaceChildren(h("div", { className: "logo" }, h("img", { src: "/icon-192.png", alt: "" }), "audiojoe"), net, sync, off);
  void offlineUsage().then((u) => {
    usage = u || "";
    off.textContent = usage ? `${t("Offline")} ${usage}` : t("Offline");
  });
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
  ({ np: renderNowPlaying, cont: renderContinue, pod: renderPodcasts, books: renderBooks, lib: renderMusic, radio: renderRadio, off: renderOffline })[v]();
  renderTop();
}

/** Re-render the current view when its data changed (except lists the user scrolls in). */
export function refresh(kind: "player" | "data" | "offline") {
  if (kind === "player" && view === "np") updateNowPlaying();
  else if (kind === "data" && view === "cont" && !document.querySelector(".toast")) show("cont");
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

/// One line: what is played, "Cache" first when it comes from there; the source in brackets
/// only when it differs.
function qualityRow(played: Quality | null | undefined, cached: boolean, source?: Quality | null) {
  const chips = qualityChips(played);
  if (!chips.length) return h("div");
  return h("div", { className: "row" }, h("span", { className: "fchips" },
    cached ? h("span", { className: "fchip cache" }, t("Cache")) : null,
    ...chips.map((c) => h("span", { className: "fchip" }, c)),
    source ? h("span", { className: "fnote" }, t("(Source: {q})", { q: qualityChips(source).join(" ") })) : null));
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
  // In the car: offline state left, speed, next chapter (else next item of the queue) right (no sleep timer).
  const byChapter = player.hasChapters();
  const next = h("button", { className: "big sec next", onclick: () => void (byChapter ? player.nextChapter() : player.skip(1)) }, byChapter ? t("Next chapter") : t("Next item"),
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
      h("div", { className: "fmt" }, here),
      bar, h("div", { className: "times" }, pos, rest),
      h("div", { className: "ctrl" },
        player.canStep() ? h("button", { onclick: () => void player.stepBack(), ariaLabel: byChapter ? t("Previous chapter") : t("Previous") }, icon('<path d="M6 5v14M18 6l-9 6 9 6z" fill="currentColor"/>')) : null,
        player.isLive() ? null : h("button", { className: "skip", onclick: () => player.seekBy(-15000), ariaLabel: t("Back {n} s", { n: 15 }) }, skipIcon(15, true)),
        play,
        player.isLive() ? null : h("button", { className: "skip", onclick: () => player.seekBy(30000), ariaLabel: t("Forward {n} s", { n: 30 }) }, skipIcon(30, false)),
        player.canStep() ? h("button", { onclick: () => void player.stepForward(), ariaLabel: byChapter ? t("Next chapter") : t("Next") }, icon('<path d="M18 5v14M6 6l9 6-9 6z" fill="currentColor"/>')) : null),
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
            offBadge(off) ?? h("button", { className: "big sec", onclick: (ev: Event) => { (ev.target as HTMLButtonElement).disabled = true; void addOffline([it]); } }, t("Save offline")),
            it.kind === "episode" || it.kind === "book" ? nextButton(it) : null))),
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
  const now = player.chapterIndex();
  main.append(h("div", { className: "list" }, ...(it.chapters ?? []).map((c, i) =>
    h("div", { className: i === now ? "item tap on" : "item tap", onclick: () => {
      player.seekTo(c.start_ms / (player.duration() || 1));
      npTab = "play";
      show("np");
    } }, h("div", { className: "tx" }, h("div", { className: "t1" }, c.title)), h("span", { className: "badge" }, clock(c.start_ms))))));
}

function updateNowPlaying() {
  const s = player.state;
  // A new item (next title) replaces the view instead of being appended below it.
  if (s.item?.key !== npKey) return show("np");
  if (npTab !== "play") return;
  if (!npRefs) return show("np");
  const p = player.position(), d = player.duration();
  const f = d ? Math.min(1, p / d) : 0;
  npRefs.fill.style.width = `${f * 100}%`;
  npRefs.knob.style.left = `${f * 100}%`;
  npRefs.pos.textContent = player.isLive() ? t("Live") : clock(p);
  npRefs.rest.textContent = player.isLive() ? "" : d ? `−${clock(d - p)}` : "";
  npRefs.bar.style.visibility = player.isLive() ? "hidden" : "";
  npRefs.play.textContent = s.playing ? "❚❚" : "▶";
  npRefs.rate.textContent = `${t("Speed")} ${s.rate.toLocaleString()}×`;
  npRefs.next.disabled = player.hasChapters() ? player.chapterIndex() + 1 >= (s.item?.chapters?.length ?? 0) && s.index + 1 >= s.queue.length : s.index + 1 >= s.queue.length;
  const here = JSON.stringify([s.delivered, s.fromCache, s.transcoded]);
  if (npRefs.here.dataset.v !== here) {
    npRefs.here.dataset.v = here;
    npRefs.here.replaceChildren(qualityRow(s.delivered ?? s.item?.quality, s.fromCache, s.transcoded ? s.item?.quality : null));
  }
  if (s.item?.chapters?.length) {
    const c = t("Chapter {c}", { c: player.chapterLine() });
    if (npRefs.sub.textContent !== c) npRefs.sub.textContent = c;
  }
  npRefs.from.textContent = s.takenOver ? t("Taken over from {device} · {ago}", { device: s.takenOver.device, ago: ago(s.takenOver.at) }) : "";
}

// ---------------------------------------------------------------- continue

const CONT = "aj_continue_list";
let contList: ListName = (() => {
  try {
    return (localStorage.getItem(CONT) as ListName | null) ?? "podcasts";
  } catch {
    return "podcasts";
  }
})();

async function renderContinue() {
  const mode = (v: ListName, label: string) => h("button", {
    className: contList === v ? "chip on" : "chip",
    onclick: () => { contList = v; try { localStorage.setItem(CONT, v); } catch { /* private window */ } show("cont"); },
  }, label);
  main.append(h("div", { className: "chips seg" }, mode("podcasts", t("Podcasts")), mode("books", t("Audiobooks")), mode("music", t("Music"))));
  const list = contList;
  let entries: ListEntry[] | null = null;
  if (online) {
    try {
      entries = await api<ListEntry[]>("GET", `/lists/${list}`);
    } catch { /* offline below */ }
  }
  if (!entries) {
    // Offline: what this device knows (started, unfinished).
    const prefix = list === "podcasts" ? "episode:" : list === "books" ? "abs:" : "-";
    entries = (await idbAll<Playback>("positions")).filter((p) => p.key.startsWith(prefix) && !p.finished && p.position_ms > 0)
      .sort((a, b) => b.updated_at.localeCompare(a.updated_at)).map((p) => ({ ...p, duration_ms: p.duration_ms ?? null }));
  }
  if (!entries.length) return void main.append(h("div", { className: "empty" }, list === "music" ? t("Nothing here yet. Add albums with Next.") : t("Nothing to continue.")));
  const all = entries;
  const keys = all.map((e) => e.key);
  const move = async (i: number, d: number) => {
    const k = keys.slice();
    [k[i], k[i + d]] = [k[i + d], k[i]];
    await api("PUT", `/lists/${list}`, k).catch(() => undefined);
    show("cont");
  };
  const box = h("div", { className: "list" });
  for (const [i, e] of all.entries()) {
    const kind = list === "podcasts" ? "episode" : list === "books" ? "book" : "album";
    const off = kind === "album" ? undefined : await offlineEntry(e.key);
    const f = e.duration_ms && e.position_ms ? e.position_ms / e.duration_ms : 0;
    const base: Item = { key: e.key, kind, title: e.title, subtitle: e.subtitle, image: `/api/v1/image/${encodeURIComponent(e.key)}`,
      duration_ms: e.duration_ms ?? undefined, position_ms: e.position_ms };
    const info = e.position_ms > 0
      ? `${clock(e.position_ms)}${e.duration_ms ? " / " + clock(e.duration_ms) : ""}${e.updated_at ? " · " + (e.device ? t("Last on {device} · {ago}", { device: e.device, ago: ago(e.updated_at) }) : ago(e.updated_at)) : ""}`
      : e.subtitle;
    const row = h("div", { className: "item tap", onclick: () => (kind === "album" ? void playEntry(list, e) : openDetails(base)) },
      thumb({ title: e.subtitle || e.title, image: base.image }),
      h("div", { className: "tx" }, h("div", { className: "t1" }, e.title || e.key), h("div", { className: "t2" }, info),
        f ? h("div", { className: "prog" }, h("i", { style: `width:${f * 100}%` })) : null),
      kind === "album" ? null : h("span", { className: off?.status === "done" ? "badge ok" : "badge warn" }, off?.status === "done" ? t("in cache") : t("online only")),
      h("button", { className: "big sec arrow", disabled: i === 0, ariaLabel: t("Move up"), onclick: own(() => void move(i, -1)) }, "▲"),
      h("button", { className: "big sec arrow", disabled: i === all.length - 1, ariaLabel: t("Move down"), onclick: own(() => void move(i, 1)) }, "▼"),
      h("button", { className: "big sec arrow", ariaLabel: list === "music" ? t("Remove from the list") : t("Mark as heard"), title: list === "music" ? t("Remove from the list") : t("Mark as heard"),
        onclick: own(() => void trash(e)) }, icon('<path d="M4 7h16M9 7V4h6v3M6 7l1 13h10l1-13M10 11v6M14 11v6"/>')),
      h("button", { className: "big", onclick: own(() => void playEntry(list, e)) }, e.position_ms > 0 ? t("Resume") : t("Play")));
    const trash = async (x: ListEntry) => {
      row.remove();
      const now = () => new Date().toISOString();
      if (list === "music") await api("DELETE", `/lists/music/${encodeURIComponent(x.key)}`).catch(() => undefined);
      else await savePosition({ key: x.key, position_ms: x.position_ms, duration_ms: x.duration_ms, finished: true, updated_at: now(), title: x.title, subtitle: x.subtitle });
      undoBar(list === "music" ? t("Removed from the list") : t("Marked as heard"), async () => {
        if (list !== "music") await savePosition({ key: x.key, position_ms: x.position_ms, duration_ms: x.duration_ms, finished: false, updated_at: now(), title: x.title, subtitle: x.subtitle });
        await api("POST", `/lists/${list}`, { key: x.key, title: x.title, subtitle: x.subtitle });
        await api("PUT", `/lists/${list}`, keys);
      });
    };
    box.append(row);
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
        nextButton(items[i]),
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

// All visible music libraries of all sources together, from the server's album directory:
// albums, artists (without samplers), samplers, genres, years, recently added and – when the
// files name enough of them – labels, with a search over title, artist, genre, label and year.

type Album = Item & { artist: string; sampler: boolean; genres: string[]; added: string | null; tracks: number | null; label: string | null; source: number };
let collection: { at: number; albums: Album[]; labels: boolean } | null = null;
let musicGroup: { title: string; sub: string; albums: Album[] } | null = null;
let musicAlbum: Album | null = null;
let musicQuery = "";
const MUSIC_VIEW = "aj_music_view";
function musicView(): string {
  try { return localStorage.getItem(MUSIC_VIEW) ?? "albums"; } catch { return "albums"; }
}

async function loadCollection() {
  // Kept for a minute, so opening an album and going back does not reload everything.
  if (collection && Date.now() - collection.at < 60_000) return collection;
  const albums: Album[] = [];
  let labels = false;
  let failed: unknown = null;
  for (const src of (await api<{ id: number; kind: string }[]>("GET", "/sources")).filter((x) => ["jellyfin", "emby", "plex"].includes(x.kind))) {
    try {
      for (const l of (await api<{ items: Item[] }>("GET", `/sources/${src.id}/browse`)).items.filter((i) => i.kind === "folder")) {
        const r = await api<{ albums: Album[]; labels: boolean }>("GET", `/sources/${src.id}/music?parent=${encodeURIComponent(l.key.split(":")[2])}`);
        albums.push(...r.albums.map((x) => ({ ...x, source: src.id })));
        labels ||= r.labels;
      }
    } catch (e) {
      failed = e; // a source that is down leaves out only its own albums
    }
  }
  if (!albums.length && failed) throw failed;
  const named = albums.filter((x) => x.label).length;
  collection = { at: Date.now(), albums, labels: labels || (albums.length > 0 && named >= albums.length * 0.1) };
  return collection;
}

const sortName = (s: string) => s.trim().toLowerCase().replace(/^the /, "");
const byTitle = (a: Album, b: Album) => a.title.toLowerCase().localeCompare(b.title.toLowerCase());
const byArtist = (a: Album, b: Album) => sortName(a.artist).localeCompare(sortName(b.artist)) || (a.year ?? 0) - (b.year ?? 0);

async function renderMusic() {
  try {
    if (musicAlbum) return void (await renderAlbum(musicAlbum));
    const col = await loadCollection();
    if (!col.albums.length) {
      main.append(h("h2", {}, t("Music")), h("div", { className: "empty" }, t("No sources yet. Add one in the settings.")));
      return;
    }
    const input = h("input", { className: "search", type: "search", placeholder: t("Search title, artist, genre, label"), value: musicQuery, enterKeyHint: "search" }) as HTMLInputElement;
    const box = h("div", { className: "list" });
    const row = (a: Album) => h("div", { className: "item tap", onclick: () => ((musicAlbum = a), show("lib")) }, thumb(a),
      h("div", { className: "tx" }, h("div", { className: "t1" }, a.title),
        h("div", { className: "t2" }, [a.artist, a.year ? `${a.year}` : "", a.tracks ? t("{n} titles", { n: a.tracks }) : ""].filter(Boolean).join(" · "))),
      nextButton(a));
    const folder = (title: string, albums: Album[], sorted: () => Album[]) => {
      const sub = albums.length === 1 ? t("1 album") : t("{n} albums", { n: albums.length });
      return h("div", { className: "item tap", onclick: () => ((musicGroup = { title, sub, albums: sorted() }), show("lib")) },
        thumb({ title, image: albums.find((x) => x.image)?.image ?? null }),
        h("div", { className: "tx" }, h("div", { className: "t1" }, title), h("div", { className: "t2" }, sub)));
    };
    const groupBy = (l: Album[], keys: (a: Album) => string[]) => {
      const m = new Map<string, Album[]>();
      for (const a of l) for (const k of keys(a).map((x) => x.trim()).filter(Boolean)) m.set(k, [...(m.get(k) ?? []), a]);
      return m;
    };
    const folders = (m: Map<string, Album[]>, order: (a: string, b: string) => number, sort: (a: Album, b: Album) => number) =>
      [...m.keys()].sort(order).map((k) => folder(k, m.get(k)!, () => [...m.get(k)!].sort(sort)));
    const byName = (a: string, b: string) => sortName(a).localeCompare(sortName(b));

    const fill = () => {
      const q = musicQuery.toLowerCase();
      const all = col.albums;
      let out: HTMLElement[] = [];
      if (q) {
        const hits = all.filter((a) => [a.title, a.artist, a.label ?? "", `${a.year ?? ""}`, ...a.genres].some((x) => x.toLowerCase().includes(q))).sort(byArtist);
        out = hits.length ? hits.slice(0, 300).map(row) : [h("div", { className: "empty" }, t("Nothing found."))];
      } else if (musicGroup) {
        const g = musicGroup;
        out = [h("div", { className: "chips" }, h("button", { className: "chip", onclick: () => ((musicGroup = null), show("lib")) }, `← ${t("Back")}`),
          h("h2", { style: "margin:0" }, g.title), h("span", { className: "muted" }, g.sub)), ...g.albums.map(row)];
      } else {
        const v = musicView();
        if (v === "artists") {
          // An artist's albums by year, the oldest first.
          out = folders(groupBy(all.filter((a) => !a.sampler), (a) => [a.artist]), byName, (a, b) => (a.year ?? 9999) - (b.year ?? 9999));
        } else if (v === "samplers") out = all.filter((a) => a.sampler).sort(byTitle).map(row);
        else if (v === "genres") out = folders(groupBy(all, (a) => a.genres), (a, b) => a.toLowerCase().localeCompare(b.toLowerCase()), byArtist);
        else if (v === "years") out = folders(groupBy(all, (a) => (a.year ? [`${a.year}`] : [])), (a, b) => b.localeCompare(a), byArtist);
        else if (v === "labels" && col.labels) out = folders(groupBy(all, (a) => [a.label ?? ""]), byName, byArtist);
        else if (v === "new") out = [...all].sort((a, b) => (b.added ?? "").localeCompare(a.added ?? "")).slice(0, 100).map(row);
        else out = [...all].sort(byTitle).map(row);
      }
      box.replaceChildren(...out);
      tabs.style.display = q ? "none" : "";
    };

    const tab = (v: string, label: string) => h("button", {
      className: !musicGroup && musicView() === v ? "chip on" : "chip",
      onclick: () => { try { localStorage.setItem(MUSIC_VIEW, v); } catch { /* private window */ } musicGroup = null; show("lib"); },
    }, label);
    const tabs = h("div", { className: "chips wrap" }, tab("albums", t("Albums")), tab("artists", t("Artists")), tab("samplers", t("Samplers")),
      tab("genres", t("Genres")), tab("years", t("Years")), tab("new", t("Recently added")), col.labels ? tab("labels", t("Labels")) : null);
    input.addEventListener("input", () => ((musicQuery = input.value.trim()), fill()));
    main.append(h("div", { className: "chips searchrow" }, input, h("span", { className: "lens", ariaHidden: "true" }, icon('<circle cx="10.5" cy="10.5" r="6.5"/><path d="M15.5 15.5 21 21"/>'))));
    main.append(tabs, box);
    fill();
  } catch (e) {
    main.append(failure(e));
  }
}

async function renderAlbum(album: Album) {
  main.append(h("div", { className: "chips" }, h("button", { className: "chip", onclick: () => ((musicAlbum = null), show("lib")) }, `← ${t("Back")}`)));
  const res = await api<{ items: Item[] }>("GET", `/sources/${album.source}/browse?parent=${encodeURIComponent(album.key.split(":")[2])}&limit=500`);
  const tracks = res.items.filter((i) => i.kind === "track");
  const buttons = tracks.length ? [h("button", { className: "big", onclick: () => void start(tracks, 0, { list: "music", key: album.key }) }, t("Play album")),
    nextButton(album),
    h("button", { className: "big sec", onclick: (ev: Event) => { (ev.target as HTMLButtonElement).disabled = true; void addOffline(tracks); } }, t("Save offline"))] : [];
  main.append(albumHead(album, tracks, buttons));
  const box = h("div", { className: "list" });
  for (const it of tracks) {
    const off = await offlineEntry(it.key);
    box.append(h("div", { className: "item tap", onclick: () => void start(tracks, tracks.indexOf(it)) },
      h("div", { className: "ic" }, String(it.track ?? "♫")),
      h("div", { className: "tx" }, h("div", { className: "t1" }, it.title),
        h("div", { className: "t2" }, [it.subtitle, it.duration_ms ? clock(it.duration_ms) : ""].filter(Boolean).join(" · "))),
      offBadge(off), h("span", { className: "badge" }, qualityBadge(it.quality))));
  }
  main.append(box);
}

// ---------------------------------------------------------------- radio

let radioQuery = "";

async function renderRadio() {
  const input = h("input", { className: "search", value: radioQuery, placeholder: t("Search stations"), enterKeyHint: "search" }) as HTMLInputElement;
  const go = () => ((radioQuery = input.value.trim()), show("radio"));
  input.addEventListener("keydown", (e) => (e as KeyboardEvent).key === "Enter" && go());
  // Magnifier as large as the moon, right-aligned just left of it.
  main.append(h("div", { className: "chips searchrow" },
    radioQuery ? h("button", { className: "chip", onclick: () => ((radioQuery = ""), show("radio")) }, `← ${t("Back")}`) : null,
    input, h("button", { className: "lens", onclick: go, ariaLabel: t("Search"), title: t("Search") },
      icon('<circle cx="10.5" cy="10.5" r="6.5"/><path d="M15.5 15.5 21 21"/>'))));
  try {
    const list = radioQuery
      ? await api<Item[]>("GET", `/radio/search?q=${encodeURIComponent(radioQuery)}`)
      : await api<Item[]>("GET", "/radio/favorites");
    main.append(h("h2", {}, radioQuery ? t("Results") : t("Favourites")));
    if (!list.length) return void main.append(h("div", { className: "empty" }, radioQuery ? t("No stations found.") : t("No favourites yet. Search for a station.")));
    const box = h("div", { className: "list" });
    // Favourites in the user's order, moved with large arrows (no dragging while driving).
    const move = async (i: number, d: number) => {
      const ids = list.map((x) => x.key.slice(6));
      [ids[i], ids[i + d]] = [ids[i + d], ids[i]];
      await api("PUT", "/radio/favorites", ids).catch(() => undefined);
      show("radio");
    };
    for (const [i, st] of list.entries()) {
      const star = h("button", { className: st.favorite ? "big" : "big sec", style: "min-width:64px", ariaLabel: t("Favourite") }, st.favorite ? "★" : "☆");
      star.onclick = async () => {
        await api(st.favorite ? "DELETE" : "PUT", `/radio/favorites/${st.key.slice(6)}`);
        st.favorite = !st.favorite;
        star.textContent = st.favorite ? "★" : "☆";
        star.className = st.favorite ? "big" : "big sec";
      };
      box.append(h("div", { className: "item" }, thumb(st),
        h("div", { className: "tx" }, h("div", { className: "t1" }, st.title), h("div", { className: "t2" }, st.subtitle)),
        h("span", { className: "badge" }, qualityBadge(st.quality)),
        radioQuery ? null : h("button", { className: "big sec arrow", disabled: i === 0, ariaLabel: t("Move up"), onclick: () => void move(i, -1) }, "▲"),
        radioQuery ? null : h("button", { className: "big sec arrow", disabled: i === list.length - 1, ariaLabel: t("Move down"), onclick: () => void move(i, 1) }, "▼"),
        star,
        h("button", { className: "big", onclick: () => void start([st]) }, t("Play"))));
    }
    main.append(box);
  } catch (e) {
    main.append(failure(e));
  }
}

// ---------------------------------------------------------------- audiobooks

type Book = Item & { author: string; narrator: string; series: string | null; volume: number | null; added: number | null; finished: boolean };
type Series = { name: string; author: string; total: number; heard: number; next: string | null; books: string[]; image: string | null };
type Shelf = { books: Book[]; authors: { name: string; books: number }[]; series: Series[] };

let bookLibs: { source: number; lib: string; title: string }[] | null = null;
let bookLib = 0;
let bookAuthor: string | null = null;
let bookSeries: string | null = null;
let bookQuery = "";
let shelf: { at: number; lib: string; data: Shelf } | null = null;
const BOOK_VIEW = "aj_books_view";
function bookView(): string {
  try { return localStorage.getItem(BOOK_VIEW) ?? "authors"; } catch { return "authors"; }
}

async function loadShelf(): Promise<Shelf | null> {
  if (!bookLibs) {
    const libs: { source: number; lib: string; title: string }[] = [];
    for (const src of (await api<{ id: number; kind: string }[]>("GET", "/sources")).filter((x) => x.kind === "audiobookshelf")) {
      for (const l of (await api<{ items: Item[] }>("GET", `/sources/${src.id}/browse`)).items) libs.push({ source: src.id, lib: l.key.split(":")[2], title: l.title });
    }
    bookLibs = libs;
  }
  const l = bookLibs[Math.min(bookLib, bookLibs.length - 1)];
  if (!l) return null;
  const id = `${l.source}/${l.lib}`;
  // Kept for a minute, so stepping into an author and back does not reload 400 books.
  if (!shelf || shelf.lib !== id || Date.now() - shelf.at > 60_000) {
    shelf = { at: Date.now(), lib: id, data: await api<Shelf>("GET", `/sources/${l.source}/books?parent=${encodeURIComponent(l.lib)}`) };
  }
  return shelf.data;
}

async function renderBooks() {
  try {
    const data = await loadShelf();
    if (!data) {
      main.append(h("h2", {}, t("Audiobooks")), h("div", { className: "empty" }, t("No audiobook sources. Add Audiobookshelf in the desktop or phone app.")));
      return;
    }
    const byKey = new Map(data.books.map((b) => [b.key, b]));
    const offline = new Map<string, Awaited<ReturnType<typeof offlineEntry>>>();
    for (const b of data.books) offline.set(b.key, await offlineEntry(b.key));
    const input = h("input", { className: "search", type: "search", placeholder: t("Search title, author, series, narrator"), value: bookQuery, enterKeyHint: "search" }) as HTMLInputElement;
    const box = h("div", { className: "list" });

    const row = (b: Book, next = false, withAuthor = true) => {
      const p = b.finished ? 0 : (b.position_ms ?? 0);
      const f = p && b.duration_ms ? p / b.duration_ms : 0;
      return h("div", { className: next ? "item tap next" : "item tap", onclick: () => openDetails({ ...b, position_ms: b.position_ms }) }, thumb(b),
        h("div", { className: "tx" }, h("div", { className: "t1" }, b.title),
          h("div", { className: "t2" }, [withAuthor ? b.author : "", b.series && b.volume ? t("Vol. {n}", { n: b.volume }) : "", b.year ? `${b.year}` : "",
            b.duration_ms ? clock(b.duration_ms) : ""].filter(Boolean).join(" · ")),
          f ? h("div", { className: "prog" }, h("i", { style: `width:${f * 100}%` })) : null),
        next ? h("span", { className: "badge ok" }, t("Up next")) : b.finished ? h("span", { className: "badge" }, t("Heard")) : null,
        offBadge(offline.get(b.key)) ?? h("button", { className: "big sec", onclick: own((ev) => { (ev.target as HTMLButtonElement).disabled = true; void addOffline([b]); }) }, t("Save offline")),
        nextButton(b),
        h("button", { className: "big", onclick: own(() => void start([b])) }, f ? t("Resume") : t("Play")));
    };
    const section = (s: string) => h("h3", { className: "section" }, s);
    const back = (title: string, sub: string, go: () => void) =>
      h("div", { className: "chips" }, h("button", { className: "chip", onclick: go }, `← ${t("Back")}`), h("h2", { style: "margin:0" }, title), h("span", { className: "muted" }, sub));
    const of = (s: Series) => t("{a} of {b}", { a: s.heard, b: s.total });

    const fill = () => {
      const q = bookQuery.toLowerCase();
      const out: (HTMLElement | null)[] = [];
      if (q) {
        const hits = data.books.filter((b) => [b.title, b.author, b.series ?? "", b.narrator].some((x) => x.toLowerCase().includes(q)));
        if (!hits.length) out.push(h("div", { className: "empty" }, t("Nothing found.")));
        for (const b of hits) out.push(row(b));
      } else if (bookSeries) {
        const s = data.series.find((x) => x.name === bookSeries);
        if (s) {
          out.push(back(s.name, [s.author, of(s)].filter(Boolean).join(" · "), () => ((bookSeries = null), show("books"))));
          for (const k of s.books) { const b = byKey.get(k); if (b) out.push(row(b, k === s.next)); }
        }
      } else if (bookAuthor) {
        const mine = data.books.filter((b) => b.author === bookAuthor);
        out.push(back(bookAuthor, t("{n} books", { n: mine.length }), () => ((bookAuthor = null), show("books"))));
        let any = false;
        for (const s of data.series.filter((x) => x.books.some((k) => byKey.get(k)?.author === bookAuthor))) {
          out.push(section(`${s.name} · ${of(s)}`));
          any = true;
          for (const k of s.books) { const b = byKey.get(k); if (b && b.author === bookAuthor) out.push(row(b, k === s.next, false)); }
        }
        const loose = mine.filter((b) => !b.series).sort((a, b) => (a.year ?? 9999) - (b.year ?? 9999));
        if (loose.length && any) out.push(section(t("Without series")));
        for (const b of loose) out.push(row(b, false, false));
      } else {
        const v = bookView();
        if (v === "series") {
          for (const s of data.series) {
            out.push(h("div", { className: "item tap", onclick: () => ((bookSeries = s.name), show("books")) }, thumb({ title: s.name, image: s.image }),
              h("div", { className: "tx" }, h("div", { className: "t1" }, s.name), h("div", { className: "t2" }, [s.author, of(s)].filter(Boolean).join(" · ")),
                h("div", { className: "prog" }, h("i", { style: `width:${(s.heard / Math.max(1, s.total)) * 100}%` })))));
          }
        } else if (v === "titles" || v === "new") {
          const l = v === "new" ? [...data.books].sort((a, b) => (b.added ?? 0) - (a.added ?? 0)).slice(0, 100) : data.books;
          for (const b of l) out.push(row(b));
        } else {
          for (const a of data.authors) {
            out.push(h("div", { className: "item tap", onclick: () => ((bookAuthor = a.name), show("books")) },
              thumb({ title: a.name }),
              h("div", { className: "tx" }, h("div", { className: "t1" }, a.name), h("div", { className: "t2" }, t("{n} books", { n: a.books })))));
          }
        }
      }
      box.replaceChildren(...out.filter((x): x is HTMLElement => x !== null));
      tabs.style.display = q ? "none" : "";
    };

    const tab = (v: string, label: string) => h("button", {
      className: !bookAuthor && !bookSeries && bookView() === v ? "chip on" : "chip",
      onclick: () => { try { localStorage.setItem(BOOK_VIEW, v); } catch { /* private window */ } bookAuthor = bookSeries = null; show("books"); },
    }, label);
    const tabs = h("div", { className: "chips wrap" }, tab("authors", t("Authors")), tab("series", t("Series")), tab("titles", t("Titles")), tab("new", t("Recently added")));
    input.addEventListener("input", () => ((bookQuery = input.value.trim()), fill()));
    const libChips = bookLibs && bookLibs.length > 1
      ? h("div", { className: "chips wrap" }, ...bookLibs.map((l, i) => h("button", { className: i === bookLib ? "chip on" : "chip", onclick: () => ((bookLib = i), (bookAuthor = bookSeries = null), show("books")) }, l.title)))
      : null;
    main.append(h("div", { className: "chips searchrow" }, input, h("span", { className: "lens", ariaHidden: "true" }, icon('<circle cx="10.5" cy="10.5" r="6.5"/><path d="M15.5 15.5 21 21"/>'))));
    if (libChips) main.append(libChips);
    main.append(tabs, box);
    fill();
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
  const drop = h("input", { type: "checkbox", checked: dropPlayedOn() }) as HTMLInputElement;
  drop.onchange = () => setDropPlayed(drop.checked);
  main.append(h("label", { className: "switch" }, drop, h("span", {}, t("Remove played media from the cache"))));
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
