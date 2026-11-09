// Headless test of the web app in the car's viewport (773 × 601), German UI.
//
//   AUDIOJOE_URL=https://audio.example.org CRED=/path/credentials.json \
//   SHOTS=/tmp/shots node tests/app.test.mjs
//
// Runs on the server host (it stops and starts audiojoe-server to test offline mode).
// Flow: sign in → subscribe a podcast → save the shortest episode offline → play →
// position on the server → change from another device arrives live → server down:
// app starts from cache, plays offline, buffers the position → server up: synced.

import { execSync } from "node:child_process";
import { createHmac } from "node:crypto";
import { mkdirSync, readFileSync } from "node:fs";
import puppeteer from "puppeteer-core";

const base = process.env.AUDIOJOE_URL;
const cred = JSON.parse(readFileSync(process.env.CRED, "utf8"));
const shots = process.env.SHOTS ?? "/tmp/audiojoe-shots";
const FEED = "https://feeds.lagedernation.org/feeds/ldn-mp3.xml";
mkdirSync(shots, { recursive: true });

function totp(secret, t = Date.now() / 1000) {
  const alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZ234567";
  let bits = "";
  for (const c of secret.replace(/=+$/, "")) bits += alphabet.indexOf(c).toString(2).padStart(5, "0");
  const key = Buffer.from(bits.match(/.{8}/g).map((b) => parseInt(b, 2)));
  const msg = Buffer.alloc(8);
  msg.writeBigUInt64BE(BigInt(Math.floor(t / 30)));
  const h = createHmac("sha1", key).update(msg).digest();
  const o = h[h.length - 1] & 15;
  return String((h.readUInt32BE(o) & 0x7fffffff) % 1e6).padStart(6, "0");
}
const nextStep = () => new Promise((r) => setTimeout(r, (30 - (Date.now() / 1000) % 30 + 1) * 1000));
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

let failed = 0;
const check = (name, cond, detail = "") => {
  console.log(`${cond ? "✔" : "✖"} ${name}${detail ? ` – ${detail}` : ""}`);
  if (!cond) failed++;
};

const browser = await puppeteer.launch({
  executablePath: "/usr/bin/chromium",
  headless: true,
  args: ["--no-sandbox", "--autoplay-policy=no-user-gesture-required", "--lang=de-DE"],
});
const page = await browser.newPage();
await page.setViewport({ width: 773, height: 601, deviceScaleFactor: 1.53 });
page.on("pageerror", (e) => console.log("  pageerror:", e.message));
await page.evaluateOnNewDocument(() => {
  Object.defineProperty(navigator, "language", { get: () => "de-DE" });
  Object.defineProperty(navigator, "languages", { get: () => ["de-DE", "de"] });
});
const shot = (name) => page.screenshot({ path: `${shots}/${name}.png` });
// Soft hyphens (German labels) are ignored when matching texts.
const text = () => page.evaluate(() => document.body.innerText.replace(/\u00ad/g, ""));
const call = (method, path, body) => page.evaluate(async (m, p, b) => {
  const r = await fetch(`/api/v1${p}`, { method: m, headers: b ? { "content-type": "application/json" } : {}, body: b ? JSON.stringify(b) : undefined });
  return { status: r.status, body: r.headers.get("content-type")?.includes("json") ? await r.json() : null };
}, method, path, body);
const clickText = async (label, scope = "main") => {
  // The offline page opens from the indicator at the top, not from the navigation.
  if (label === "Offline") return page.evaluate(() => document.getElementById("offsize").click());
  const ok = await page.evaluate((l, s) => {
    const all = [...document.querySelectorAll(`${s} button, nav button`)];
    const txt = (x) => x.innerText.replace(/\u00ad/g, "").trim();
    const b = all.find((x) => txt(x) === l) ?? all.find((x) => txt(x).includes(l));
    b?.click();
    return !!b;
  }, label, scope);
  if (!ok) throw new Error(`button "${label}" not found`);
};
const waitText = (s, timeout = 30000) => page.waitForFunction((x) => document.body.innerText.replace(/\u00ad/g, "").includes(x), { timeout, polling: 250 }, s);

try {
  // ------------------------------------------------------------ sign in
  await page.goto(base, { waitUntil: "networkidle0" });
  check("sign-in form shown", (await text()).includes("Anmelden"));
  await shot("01-anmeldung");
  await nextStep();
  const inputs = await page.$$("form input");
  await inputs[0].type(cred.username);
  await inputs[1].type(cred.password);
  await inputs[2].type(totp(cred.totp_secret));
  await inputs[3].click({ clickCount: 3 });
  await inputs[3].type("Tesla (Test)");
  await page.click("form button");
  await waitText("Server");
  await page.waitForSelector("#net.ok");
  check("signed in, server reachable", true);
  const syncPill = () => page.evaluate(() => { const p = document.getElementById("sync"); return `${p?.className}|${p?.innerText.trim()}`; });
  check("short pills: Server with dot, Position with tick", (await syncPill()) === "pill ok|✓\nPosition" || (await syncPill()) === "pill ok|✓Position",
    await syncPill());
  const pillW = () => page.evaluate(() => ["sync"].map((id) => document.getElementById(id)?.getBoundingClientRect().width ?? 0).join("/"));
  const pillsOnline = await pillW();
  const cookie = (await page.cookies()).find((c) => c.name === "aj_session");
  check("session cookie HttpOnly + Secure", cookie?.httpOnly && cookie?.secure);

  // Moon below the top bar: dark mode on/off, kept after a reload; without a choice the system applies.
  await page.emulateMediaFeatures([{ name: "prefers-color-scheme", value: "light" }]);
  const look = () => page.evaluate(() => {
    const m = document.querySelector(".shell > .theme"), r = m?.getBoundingClientRect();
    return { label: m?.ariaLabel, on: m?.classList.contains("on"), bg: getComputedStyle(document.documentElement).getPropertyValue("--bg").trim(),
             inBar: !!document.querySelector(".top .theme"), bar: document.querySelector(".top").offsetHeight, top: r?.top, right: innerWidth - r?.right };
  });
  const off = await look();
  await page.click(".shell > .theme"); const on = await look();
  await page.reload({ waitUntil: "domcontentloaded" }); await page.waitForSelector(".shell > .theme"); await sleep(1000);
  const kept = await look();
  await shot("00-dunkel");
  await page.click(".shell > .theme"); const back = await look();
  check("moon: dark on/off, kept after reload", /aus/.test(off.label) && !off.on && /an/.test(on.label) && on.on && on.bg !== off.bg
      && kept.on && kept.bg === on.bg && !back.on && back.bg === off.bg,
    `${off.bg} → ${on.bg}, reload ${kept.bg}, back ${back.bg}`);
  check("moon below the top bar, top right", !off.inBar && off.bar === 52 && off.top >= 52 && off.right < 60, `bar ${off.bar}, top ${off.top}, right ${off.right}`);
  // Radio search: magnifier as large as the moon, right-aligned just left of it, no overlap.
  const navs = await page.evaluate(() => [...document.querySelectorAll("nav button")].map((b) => b.innerText.replace(/\u00ad/g, "").trim()));
  check("navigation: Radio of its own, Offline at the top", navs.includes("Radio") && !navs.includes("Offline") && (await page.$("#offsize")) !== null, navs.join(", "));
  await clickText("Radio", "nav"); await sleep(1500);
  await page.waitForSelector(".lens", { timeout: 15000 });
  const rs = await page.evaluate(() => {
    const l = document.querySelector(".lens").getBoundingClientRect(), m = document.querySelector(".shell > .theme").getBoundingClientRect();
    return { lw: l.width, lh: l.height, mw: m.width, mh: m.height, gap: m.left - l.right, dy: Math.abs(l.top - m.top), overlap: l.right > m.left && l.bottom > m.top && l.top < m.bottom,
             text: document.querySelector(".lens").innerText.trim() };
  });
  await shot("00b-radiosuche");
  check("radio search: magnifier like the moon, left of it", rs.lw === rs.mw && rs.lh === rs.mh && !rs.overlap && rs.gap >= 4 && rs.gap <= 24 && rs.dy < 1 && rs.text === "",
    `lens ${rs.lw}×${rs.lh}, moon ${rs.mw}×${rs.mh}, gap ${rs.gap}, height offset ${rs.dy}`);
  // The moon on one line with the first row of every view.
  const rows = [];
  for (const v of ["Jetzt läuft", "Weiterhören", "Podcasts", "Hörbücher", "Musik", "Offline"]) {
    await clickText(v, "nav"); await sleep(1500);
    rows.push(await page.evaluate((name) => {
      const m = document.querySelector(".shell > .theme").getBoundingClientRect();
      const f = document.querySelector("main").firstElementChild;
      const r = (f.matches(".chips") ? f.firstElementChild : f).getBoundingClientRect();
      return `${name} ${Math.round(r.top - m.top)}`;
    }, v.replace(/\u00ad/g, "")));
  }
  check("moon on one line with the first row in every view", rows.every((x) => Math.abs(+x.split(" ").pop()) < 1), rows.join(", "));
  // Scrolling a long list: the moon goes up with the first row, it does not float over the list.
  await clickText("Podcasts", "nav"); await sleep(2000);
  const sc = await page.evaluate(async () => {
    const m = document.querySelector("main"), moon = document.querySelector(".shell > .theme");
    const row = () => (m.firstElementChild.matches(".chips") ? m.firstElementChild.firstElementChild : m.firstElementChild).getBoundingClientRect().top;
    m.scrollTop = 30; await new Promise((r) => setTimeout(r, 200));
    const d30 = Math.round(moon.getBoundingClientRect().top - row());
    m.scrollTop = 400; await new Promise((r) => setTimeout(r, 200));
    const hidden = getComputedStyle(moon).visibility === "hidden" || m.scrollHeight - m.clientHeight < 400;
    m.scrollTop = 0; await new Promise((r) => setTimeout(r, 200));
    return { d30, hidden, back: Math.round(moon.getBoundingClientRect().top - row()) };
  });
  check("moon scrolls with the first row, gone further down", sc.d30 === 0 && sc.hidden && sc.back === 0, JSON.stringify(sc));
  await clickText("Jetzt läuft", "nav"); await sleep(500);

  // ------------------------------------------------------------ podcast + offline
  const sub = await call("POST", "/podcasts", { feed_url: FEED });
  check("podcast subscribed", sub.status === 200, `${sub.body?.episodes} Folgen`);
  const eps = (await call("GET", `/podcasts/${sub.body.id}/episodes?limit=200`)).body;
  const ep = eps.filter((e) => e.size).sort((a, b) => a.size - b.size)[0];
  console.log(`  shortest episode: ${ep.title} (${Math.round(ep.size / 2 ** 20)} MB)`);
  await clickText("Podcasts");
  await waitText("Lage der Nation");
  await shot("02-podcasts-neu");
  await clickText("Abonniert");
  await waitText("Lage der Nation");
  await page.evaluate(() => document.querySelector("main .item.tap")?.click());
  await waitText(ep.title.slice(0, 20));
  // Offline button of the shortest episode
  await page.evaluate((title) => {
    const row = [...document.querySelectorAll("main .item")].find((r) => r.innerText.includes(title));
    [...row.querySelectorAll("button")].find((b) => b.innerText === "Offline").click();
  }, ep.title);
  await clickText("Offline");
  await waitText("fertig", 300000);
  check("episode saved offline", true);
  await shot("03-offline");

  // ------------------------------------------------------------ continue lists: Next, order, bin, undo
  const listKeys = async () => (await call("GET", "/lists/podcasts")).body.map((e) => e.key);
  await clickText("Podcasts", "nav");
  await clickText("Abonniert");
  await waitText("Lage der Nation");
  await page.evaluate(() => document.querySelector("main .item.tap")?.click());
  await waitText(ep.title.slice(0, 20));
  const other = eps.find((e) => e.key !== ep.key && e.title);
  // Leftovers of an earlier run (playing adds an episode to the list) would keep their place.
  for (const e of [ep, other]) await call("DELETE", `/lists/podcasts/${encodeURIComponent(e.key)}`);
  for (const e of [other, ep]) {
    await page.evaluate((title) => {
      const row = [...document.querySelectorAll("main .item")].find((r) => r.innerText.includes(title));
      [...row.querySelectorAll("button")].find((b) => b.innerText === "Next").click();
    }, e.title);
    // Wait until the server has it, so the order is the order of the taps.
    await page.waitForFunction((title) => [...document.querySelectorAll("main .item")].find((r) => r.innerText.includes(title))?.innerText.includes("✓"),
      { timeout: 15000, polling: 200 }, e.title);
  }
  let lk = await listKeys();
  check("Next appends at the end of the podcast list", lk.at(-1) === ep.key && lk.at(-2) === other.key, `${lk.length} entries, last ${lk.at(-1)}`);
  await clickText("Weiterhören", "nav");
  await page.waitForFunction(() => [...document.querySelectorAll("main .chips.seg .chip.on")].some((b) => b.innerText === "Podcasts"), { timeout: 15000 });
  await waitText(ep.title.slice(0, 20));
  await shot("04a-weiterhoeren-podcasts");
  const rowBtn = (title, label) => page.evaluate((t, l) => {
    const row = [...document.querySelectorAll("main .list .item")].find((r) => r.innerText.includes(t));
    [...row.querySelectorAll("button")].find((b) => b.getAttribute("aria-label") === l).click();
  }, title, label);
  await rowBtn(ep.title, "Nach oben");
  await sleep(1500);
  lk = await listKeys();
  check("arrow moves an entry up", lk.at(-1) === other.key && lk.at(-2) === ep.key, `last two ${lk.slice(-2).join(", ")}`);
  const before = lk;
  await page.waitForFunction((t) => [...document.querySelectorAll("main .list .item")].some((r) => r.innerText.includes(t)), {}, ep.title.slice(0, 20));
  await rowBtn(ep.title, "Als gehört markieren");
  await waitText("Als gehört markiert", 5000);
  await sleep(2500);
  const heard = (await call("GET", `/playback/${encodeURIComponent(ep.key)}`)).body;
  lk = await listKeys();
  check("bin marks as heard, the entry leaves the list", heard?.finished === true && !lk.includes(ep.key), `finished ${heard?.finished}, in list ${lk.includes(ep.key)}`);
  await shot("04b-rueckgaengig");
  await clickText("Rückgängig", "body");
  await sleep(2500);
  lk = await listKeys();
  const back2 = (await call("GET", `/playback/${encodeURIComponent(ep.key)}`)).body;
  check("undo brings it back at its place, unheard", JSON.stringify(lk) === JSON.stringify(before) && back2?.finished === false, `same order ${JSON.stringify(lk) === JSON.stringify(before)}, finished ${back2?.finished}`);
  for (const e of [ep, other]) await call("DELETE", `/lists/podcasts/${encodeURIComponent(e.key)}`);

  // ------------------------------------------------------------ play, position on the server
  await clickText("Podcasts");
  await waitText(ep.title.slice(0, 20));
  const rowSizes = await page.evaluate(() => [...document.querySelectorAll("main .item .big, main .item .badge.slot")].map((e) => e.offsetHeight));
  check("list buttons and offline state equally tall", rowSizes.length > 1 && new Set(rowSizes).size === 1, [...new Set(rowSizes)].join(", "));
  // Tapping the row (not a button) opens the details; nothing plays.
  await page.evaluate((title) => [...document.querySelectorAll("main .item")].find((r) => r.innerText.includes(title)).querySelector(".tx").click(), ep.title);
  await page.waitForSelector(".details.page .title", { timeout: 15000 });
  await sleep(1500);
  const det = await page.evaluate(() => ({ title: document.querySelector(".details.page .title")?.innerText,
    notes: document.querySelector(".details.page .notes, .details.page .desc")?.innerText.length ?? 0,
    buttons: [...document.querySelectorAll(".details.page .big")].map((b) => b.innerText),
    playing: [...document.querySelectorAll("audio")].some((a) => !a.paused) }));
  await shot("03b-details-folge");
  const cover = await page.evaluate(() => { const c = document.querySelector(".details.page .art .ic");
    return [c?.offsetWidth, c?.offsetHeight, getComputedStyle(c.parentElement).backgroundImage]; });
  check("details cover square, not squeezed, no frame", cover[0] === 200 && cover[1] === 200 && cover[2] === "none", cover.join(" × "));
  const logo = await page.evaluate(() => { const i = document.querySelector(".top .logo img"); return i && i.complete && i.naturalWidth > 0 ? i.offsetWidth : 0; });
  check("app icon before the name", logo >= 30, `${logo} px`);
  check("row tap opens details without playing", det.title?.length > 3 && det.notes > 40 && det.buttons.some((b) => /Abspielen|Weiter/.test(b)) && !det.playing,
    `${det.notes} chars, buttons ${det.buttons.join("/")}, playing ${det.playing}`);
  await clickText(`← Zurück`);
  await waitText(ep.title.slice(0, 20));
  await page.evaluate((title) => {
    const row = [...document.querySelectorAll("main .item")].find((r) => r.innerText.includes(title));
    [...row.querySelectorAll("button")].find((b) => ["Abspielen", "Weiter"].includes(b.innerText)).click();
  }, ep.title);
  await waitText("Jetzt läuft");
  await page.waitForFunction(() => document.querySelector(".ctrl .play")?.innerText === "❚❚", { timeout: 15000 });
  await sleep(6000);
  await page.evaluate(() => document.querySelectorAll(".ctrl .skip")[1].click()); // +30
  await sleep(1000);
  await shot("04-jetzt-laeuft");
  const here = await page.evaluate(() => document.querySelector(".fmt .row:last-child")?.innerText.replace(/\s+/g, " "));
  check("plays from cache: one quality line, Cache pill, no Quelle/Hier", /^Cache MP3 \d+ kbit\/s/.test(here ?? "") && !/Quelle|Hier/.test(here ?? ""), here);
  // "Als Nächstes: …" small below the quality line (user 2026-11-09): the next episode of the continue list.
  const un = await page.evaluate(async (key) => {
    const list = await (await fetch("/api/v1/lists/podcasts")).json();
    const i = list.findIndex((e) => e.key === key);
    const el = document.querySelector(".fmt .upnext"), q = document.querySelector(".fmt .row");
    return { want: (i < 0 ? list[0] : list[i + 1])?.title ?? "", text: el?.innerText ?? null, size: el ? getComputedStyle(el).fontSize : "",
             below: !!(el && q && el.getBoundingClientRect().top >= q.getBoundingClientRect().bottom - 1) };
  }, ep.key);
  check("„Als Nächstes“ below the quality line, small", un.want ? un.text === `Als Nächstes: ${un.want}` && un.below && un.size === "13px" : !un.text,
    JSON.stringify(un));
  const sizes = await page.evaluate(() => [...document.querySelectorAll(".ctrl button, .tools button, .tools .badge")].map((b) => Math.min(b.offsetWidth, b.offsetHeight)));
  check("controls large enough for driving (≥ 64 px)", sizes.length >= 4 && Math.min(...sizes) >= 64, sizes.join(", "));
  const fits = await page.evaluate(() => document.querySelector("main").scrollHeight <= document.querySelector("main").clientHeight + 2);
  check("player fits the car screen without scrolling", fits);
  const dock = await page.evaluate(() => {
    const m = document.querySelector("main").getBoundingClientRect(), d = document.querySelector(".dockbar").getBoundingClientRect(), tb = document.querySelector("main > .tools").getBoundingClientRect();
    return Math.round(m.bottom - Math.max(d.bottom, tb.bottom));
  });
  check("progress, controls and toolbar docked at the bottom", dock >= 0 && dock <= 30, `${dock} px above the bottom`);
  const coverBox = await page.evaluate(() => {
    const m = document.querySelector("main").getBoundingClientRect(), c = document.querySelector("main > .cover").getBoundingClientRect();
    return { whole: c.top >= m.top && c.bottom <= m.bottom && c.height >= 190, h: Math.round(c.height), below: Math.round(m.bottom - c.bottom) };
  });
  check("cover fully visible next to the controls", coverBox.whole, JSON.stringify(coverBox));
  const tbRow = await page.evaluate(() => {
    const m = document.querySelector("main"), d = document.querySelector(".dockbar").getBoundingClientRect(), tb = document.querySelector("main > .tools").getBoundingClientRect();
    return { last: m.lastElementChild?.className, below: tb.top >= d.bottom - 1 };
  });
  check("toolbar is the last row below the controls, „Taken over from …“ not below it", tbRow.last === "tools" && tbRow.below, JSON.stringify(tbRow));
  const cut = await page.evaluate(() => [...document.querySelectorAll(".tools button")].filter((b) => b.scrollWidth > b.clientWidth + 1).map((b) => b.innerText));
  check("toolbar labels not cut off", !cut.length, cut.join(", "));
  // With chapters the right button goes to the next chapter.
  const hasChapters = await page.evaluate(() => /\(\d+ von \d+\)$/.test(document.querySelector(".np .sub .txt")?.innerText ?? ""));
  if (hasChapters) console.log("  episode has chapters: " + await page.evaluate(() => document.querySelector(".np .sub .txt")?.innerText));
  const tb = await page.evaluate(() => [...document.querySelector(".tools").children].map((c) => ({ t: c.innerText.trim(), w: c.offsetWidth, h: c.offsetHeight,
    inner: c.firstElementChild ? c.firstElementChild.offsetWidth : c.offsetWidth })));
  check("car toolbar: offline left, speed, next right; no sleep timer",
    tb.length === 3 && /Cache|Offline|lädt|wartet/.test(tb[0].t) && /Tempo/.test(tb[1].t) && /Nächster Podcast/.test(tb[2].t) && !tb.some((x) => /Schlaf/.test(x.t)),
    tb.map((x) => x.t).join(" | "));
  check("offline state fills its field", tb[0].inner >= tb[0].w - 2 && Math.abs(tb[0].w - tb[1].w) <= 2, `${tb[0].inner}/${tb[0].w} vs ${tb[1].w}`);
  // Narrow screen (other cars): under 420 px right of the cover the three buttons stack under the
  // cover in the left column, the cover stays at the top; 800 × 480 still uses the wide layout.
  const layout = () => page.evaluate(() => {
    const r = (q) => document.querySelector(q).getBoundingClientRect();
    const m = r("main"), chips = r("main > .chips"), c = r("main > .cover"), d = r(".dockbar"), tb = r("main > .tools");
    const btn = [...document.querySelectorAll("main > .tools > *")].map((b) => b.getBoundingClientRect());
    const stacked = btn.every((b, i) => !i || b.top >= btn[i - 1].bottom - 1);
    const cut = [...document.querySelectorAll(".tools button")].filter((b) => b.scrollWidth > b.clientWidth + 1).map((b) => b.innerText);
    const main = document.querySelector("main");
    const cs = getComputedStyle(document.querySelector("main > .tools")), ms = getComputedStyle(main);
    return { area: cs.gridArea, dir: cs.flexDirection, mainAreas: ms.gridTemplateAreas, cols: ms.gridTemplateColumns, tb: [Math.round(tb.left), Math.round(tb.top), Math.round(tb.width)], cover: [Math.round(c.left), Math.round(c.bottom)], n: document.querySelectorAll("main > .tools, main > .cover").length, coverTop: Math.round(c.top - chips.bottom), coverH: Math.round(c.height), underCover: tb.top >= c.bottom - 1 && Math.abs(tb.left - c.left) <= 1 && tb.width <= c.width + 1,
      belowDock: tb.top >= d.bottom - 1, stacked, cut, fits: main.scrollHeight <= main.clientHeight + 2, dock: Math.round(m.bottom - Math.max(d.bottom, tb.bottom)), minBtn: Math.min(...btn.map((b) => Math.min(b.width, b.height))) };
  });
  await page.setViewport({ width: 700, height: 480, deviceScaleFactor: 1 });
  await sleep(500);
  await shot("04c-eng-700x480");
  let L = await layout();
  check("700 × 480: cover at the top, buttons stacked under the cover", L.coverTop <= 12 && L.underCover && L.stacked, JSON.stringify(L));
  check("700 × 480: buttons ≥ 64 px, labels not cut, fits without scrolling, controls docked", L.minBtn >= 64 && !L.cut.length && L.fits && L.dock <= 30, JSON.stringify(L));
  await page.setViewport({ width: 800, height: 480, deviceScaleFactor: 1 });
  await sleep(500);
  await shot("04d-800x480");
  L = await layout();
  check("800 × 480: wide layout (toolbar below the controls), cover whole, fits without scrolling", L.belowDock && !L.underCover && L.coverH >= 190 && L.fits && !L.cut.length, JSON.stringify(L));
  await page.setViewport({ width: 773, height: 601, deviceScaleFactor: 1.53 });
  await sleep(500);
  await clickText("Details");
  const notes = await page.evaluate(() => {
    const n = document.querySelector(".notes");
    return { text: (n ?? document.querySelector(".desc"))?.innerText ?? "", blocks: n?.querySelectorAll("p, li").length ?? 0,
             links: n?.querySelectorAll("a").length ?? 0, foreign: n?.querySelectorAll("img, script, iframe, [style], [onclick]").length ?? 0 };
  });
  check("details tab shows shownotes in paragraphs", notes.text.length > 40 && notes.blocks >= 1, `${notes.text.length} chars, ${notes.blocks} blocks`);
  check("shownotes: no clickable links, images or scripts in the car", notes.links === 0 && notes.foreign === 0, `links ${notes.links}, foreign ${notes.foreign}`);
  await shot("04b-details");
  await clickText("Wiedergabe");
  await page.evaluate(() => document.querySelector(".ctrl .play").click()); // pause → saves position
  await sleep(1500);
  const pb = (await call("GET", `/playback/${encodeURIComponent(ep.key)}`)).body;
  check("position saved on the server", pb?.position_ms >= 30000 && pb.device === "Tesla (Test)", `${Math.round(pb?.position_ms / 1000)} s from ${pb?.device}`);

  // ------------------------------------------------------------ change from another device, live
  await nextStep();
  const login = await fetch(`${base}/api/v1/auth/login`, {
    method: "POST", headers: { "content-type": "application/json" },
    body: JSON.stringify({ username: cred.username, password: cred.password, totp: totp(cred.totp_secret), device: "Telefon (Test)" }),
  });
  const phone = (await login.json()).token;
  await fetch(`${base}/api/v1/playback/${encodeURIComponent(ep.key)}`, {
    method: "PUT", headers: { "content-type": "application/json", authorization: `Bearer ${phone}` },
    body: JSON.stringify({ position_ms: 600000, updated_at: new Date().toISOString(), title: ep.title, subtitle: ep.podcast }),
  });
  await clickText("Jetzt läuft");
  // The position follows the phone; the web player shows no origin line (user 2026-11-08).
  await page.waitForFunction(() => document.querySelector(".times span")?.innerText === "9:50", { timeout: 10000 })
    .then(() => check("phone's position arrives live in the car", true), () => check("phone's position arrives live in the car", false));
  const t = await page.evaluate(() => document.querySelector(".times span")?.innerText);
  check("player jumped to 9:50 (10 s before the phone)", t === "9:50", t);
  const line = await page.evaluate(() => /Übernommen von|Spielt auf|Spielte auf/.test(document.querySelector("main").innerText));
  check("no origin line („Übernommen von“, „Spielt/Spielte auf“)", !line);
  await shot("05-mitgelaufen");
  await clickText("Weiterhören");
  await waitText("Zuletzt auf Telefon (Test)");
  await shot("06-weiterhoeren");

  // The car plays on its own speakers only: no output selection (Sonos is in the apps).
  await clickText("Jetzt läuft");
  const outputChip = await page.evaluate(() => [...document.querySelectorAll("main .chip")].some((b) => b.innerText.includes("Dieses Gerät")));
  check("no output selection in the web app", !outputChip);

  // ------------------------------------------------------------ audiobooks from Emby/Jellyfin (optional)
  // EMBY_TEST_FILE: {url, api_key} of an Emby with an "Audiobooks" library (one folder per book).
  if (process.env.EMBY_TEST_FILE) {
    const ec = JSON.parse(readFileSync(process.env.EMBY_TEST_FILE, "utf8"));
    let emby = (await call("GET", "/sources")).body.find((s) => s.kind === "emby" && s.url === ec.url);
    if (!emby) emby = (await call("POST", "/sources", { kind: "emby", name: "Emby (Test)", url: ec.url, api_key: ec.api_key })).body;
    const libs = (await call("GET", "/books/libraries")).body;
    const elib = libs.find((l) => l.source === emby.id && l.lib);
    check("books: Emby audiobook library listed next to the others", !!elib && libs.every((l) => !l.error), libs.map((l) => `${l.kind}:${l.title ?? l.error}`).join(", "));
    if (elib) {
      const shelf = (await call("GET", `/sources/${emby.id}/books?parent=${elib.lib}`)).body;
      const authors = shelf.authors.map((a) => `${a.name} (${a.books})`).join(", ");
      check("books: Emby shelf has books grouped by folder, authors from the album artist, no series",
        shelf.books.length >= 2 && shelf.books.every((b) => b.key.startsWith("jbook:") && b.kind === "book" && b.author) && shelf.series.length === 0 && shelf.authors.length >= 1, `${shelf.books.length} books; ${authors}`);
      const b0 = shelf.books[0];
      const m = (await call("GET", `/items/${encodeURIComponent(b0.key)}`)).body;
      const sum = (m.parts ?? []).reduce((a, p) => a + p.duration_ms, 0);
      check("books: Emby book has one part per file, chapters alike, total duration", m.kind === "book" && m.parts?.length >= 2 && m.chapters?.length === m.parts.length && sum === m.duration_ms, `${m.title}: ${m.parts?.length} parts, ${m.duration_ms} ms`);
      const st = await call("PUT", `/playback/${encodeURIComponent(b0.key)}`, { position_ms: 25000, duration_ms: m.duration_ms, finished: false, title: m.title, subtitle: m.subtitle, updated_at: new Date().toISOString() });
      const list = (await call("GET", "/lists/books")).body;
      const again = (await call("GET", `/sources/${emby.id}/books?parent=${elib.lib}`)).body.books.find((b) => b.key === b0.key);
      check("books: a started Emby book joins the continue list and shows its position on the shelf",
        st.status === 200 && list.some((e) => e.key === b0.key) && again?.position_ms === 25000, `list: ${list.map((e) => e.key).join(" ")}; shelf ${again?.position_ms}`);
      await call("PUT", `/playback/${encodeURIComponent(b0.key)}`, { position_ms: 0, duration_ms: m.duration_ms, finished: true, title: m.title, subtitle: m.subtitle, updated_at: new Date(Date.now() + 1000).toISOString() });
      await call("DELETE", `/lists/books/${encodeURIComponent(b0.key)}`);
      // Hi-res FLAC for the car: the offline profile converts to 48 kHz (24/96 from the cache
      // does not play in the Tesla); the original keeps its rate and Range requests.
      const hires = (await call("GET", `/sources/${emby.id}/browse?search=Sinus%2024`)).body.items.find((x) => x.kind === "track" && x.quality?.sample_rate > 48000);
      if (hires) {
        const q = await page.evaluate(async (k) => {
          const out = {};
          for (const prof of ["original", "tesla-offline"]) {
            const r = await fetch(`/api/v1/stream/${encodeURIComponent(k)}?profile=${prof}`, { headers: { range: "bytes=0-99" } });
            const buf = new Uint8Array(await r.arrayBuffer());
            // FLAC STREAMINFO: sample rate in the 20 bits at byte 18 of the file
            const rate = buf[0] === 0x66 ? (buf[18] << 12) | (buf[19] << 4) | (buf[20] >> 4) : null;
            out[prof] = { status: r.status, rate, q: JSON.parse(r.headers.get("x-audiojoe-quality") ?? "null") };
          }
          return out;
        }, hires.key);
        check("hi-res FLAC: original streams 24/96 with Range, offline profile delivers 48 kHz FLAC (converted)",
          q.original.status === 206 && q.original.rate === hires.quality.sample_rate && q["tesla-offline"].status === 200 && q["tesla-offline"].rate === 48000 && q["tesla-offline"].q?.transcoded === true,
          `original ${q.original.status} ${q.original.rate} Hz; offline ${q["tesla-offline"].status} ${q["tesla-offline"].rate} Hz`);
      } else {
        check("hi-res FLAC test track present in Emby", false, "no track above 48 kHz found");
      }
      if (libs.length > 1) {
        await clickText("Hörbücher");
        await waitText("Autoren");
        const chips = await page.evaluate(() => [...document.querySelectorAll("main .chips.wrap .chip")].map((b) => b.innerText));
        check("books: library chips offer the Emby library", chips.includes(elib.title), chips.join(", "));
        await page.evaluate((name) => [...document.querySelectorAll("main .chips.wrap .chip")].find((b) => b.innerText === name).click(), elib.title);
        await page.waitForFunction((n) => document.querySelectorAll("main .list .item").length === n, { timeout: 15000 }, shelf.authors.length);
        await shot("09d-emby-hoerbuecher");
        check("books: Emby library shows its authors", true, authors);
      }
    }
  }

  // ------------------------------------------------------------ audiobooks (optional)
  if (process.env.ABS_TEST_FILE) {
    const absc = JSON.parse(readFileSync(process.env.ABS_TEST_FILE, "utf8"));
    const src = await call("POST", "/sources", { kind: "audiobookshelf", name: "Hörbücher (Test)", url: absc.url, api_key: absc.api_key });
    check("audiobookshelf source added", src.status === 200, src.body?.server);
    const libs = (await call("GET", `/sources/${src.body.id}/browse`)).body.items;
    const books = (await call("GET", `/sources/${src.body.id}/browse?parent=${libs[0].key.split(":")[2]}&limit=200`)).body.items;
    let book = null;
    for (const b of books.slice().sort((a, b) => (a.duration_ms ?? 0) - (b.duration_ms ?? 0))) {
      const m = (await call("GET", `/items/${encodeURIComponent(b.key)}`)).body;
      if (m?.parts?.length > 1) { book = m; break; }
    }
    check("multi-part book found", !!book, book ? `${book.title}: ${book.parts.length} parts, ${Math.round(book.duration_ms / 60000)} min` : "");
    if (book) {
      await clickText("Hörbücher");
      await waitText("Autoren");
      const shelf = (await call("GET", `/sources/${src.body.id}/books?parent=${libs[0].key.split(":")[2]}`)).body;
      const views = await page.evaluate(() => [...document.querySelectorAll("main .chip")].map((b) => b.innerText));
      const authorsShown = await page.evaluate(() => document.querySelectorAll("main .list .item").length);
      check("books: views authors/series/titles/new, start in authors",
        ["Autoren", "Serien", "Titel", "Neu hinzugefügt"].every((v) => views.includes(v)) && authorsShown === shelf.authors.length,
        `${views.join(", ")}; ${authorsShown} authors`);
      await shot("09a-autoren");
      // An author with a series: series headings with "x von y", volumes in order.
      const ser = shelf.series.find((x) => x.total > 1 && x.author);
      if (ser) {
        await page.evaluate((a) => [...document.querySelectorAll("main .item")].find((r) => r.querySelector(".t1").innerText === a).click(), ser.author);
        await page.waitForSelector("main .section");
        const got = await page.evaluate((name) => {
          const hs = [...document.querySelectorAll("main .section")];
          const h = hs.find((x) => x.innerText.startsWith(name + " · "));
          const out = []; let n = h?.nextElementSibling;
          while (n && n.matches(".item")) { out.push(n.querySelector(".t1").innerText); n = n.nextElementSibling; }
          return { head: h?.innerText ?? "", titles: out };
        }, ser.name);
        const want = ser.books.map((k) => shelf.books.find((b) => b.key === k)).filter((b) => b.author === ser.author).map((b) => b.title);
        check("books: author shows series in volume order", got.head.includes(" von ") && JSON.stringify(got.titles) === JSON.stringify(want),
          `${ser.author}: ${got.head}, ${got.titles.length} volumes`);
        await shot("09b-autor");
        await page.evaluate(() => [...document.querySelectorAll("main .chip")].find((b) => b.innerText.includes("Zurück")).click());
        await waitText("Neu hinzugefügt");
      }
      await page.evaluate(() => [...document.querySelectorAll("main .chip")].find((b) => b.innerText === "Serien").click());
      await sleep(500);
      const serRows = await page.evaluate(() => [...document.querySelectorAll("main .list .item .t2")].slice(0, 3).map((x) => x.innerText));
      check("books: series rows read \"author · x von y\"", serRows.length > 0 && serRows.every((x) => / von \d+$/.test(x)), serRows.join(" | "));
      await page.goto(base, { waitUntil: "domcontentloaded" });
      await page.waitForSelector("nav");
      await clickText("Hörbücher", "nav");
      await page.waitForFunction(() => [...document.querySelectorAll("main .chip.on")].some((b) => b.innerText === "Serien"), { timeout: 15000 });
      check("books: last view kept on this device", true);
      await shot("09c-serien");
      // Search over title, author, series, narrator.
      await page.evaluate((q) => { const i = document.querySelector("main input.search"); i.value = q; i.dispatchEvent(new Event("input")); }, book.title);
      await waitText(book.title.slice(0, 15));
      const hit = await page.evaluate(() => document.querySelectorAll("main .list .item").length);
      check("books: search finds the title", hit >= 1, `${hit} hits`);
      await shot("09-hoerbuecher");
      await page.evaluate((title) => {
        const row = [...document.querySelectorAll("main .item")].find((r) => r.innerText.includes(title));
        [...row.querySelectorAll("button")].find((b) => ["Abspielen", "Weiter"].includes(b.innerText)).click();
      }, book.title);
      await waitText("Jetzt läuft");
      await page.waitForFunction(() => document.querySelector(".ctrl .play")?.innerText === "❚❚", { timeout: 20000 });
      // Jump just past the start of the second file.
      const target = book.parts[1].start_ms + 15000;
      await page.evaluate((f) => {
        const bar = document.querySelector(".bar").getBoundingClientRect();
        const ev = (type) => new PointerEvent(type, { clientX: bar.left + bar.width * f, clientY: bar.top + 5, bubbles: true });
        document.querySelector(".bar").dispatchEvent(ev("pointerdown"));
      }, target / book.duration_ms);
      await sleep(6000);
      await shot("10-hoerbuch-teil2");
      await page.evaluate(() => document.querySelector(".ctrl .play").click());
      await sleep(2500);
      const pbk = (await call("GET", `/playback/${encodeURIComponent(book.key)}`)).body;
      check("book: position across file boundary saved", Math.abs(pbk.position_ms - target) < 15000, `${Math.round(pbk.position_ms / 1000)} s (target ${Math.round(target / 1000)} s)`);
      const absProg = await fetch(`${absc.url}/api/me/progress/${book.key.split(":")[2]}`, { headers: { authorization: `Bearer ${absc.api_key}` } }).then((r) => r.json());
      check("book: position arrived in Audiobookshelf", Math.abs(absProg.currentTime * 1000 - pbk.position_ms) < 3000, `${Math.round(absProg.currentTime)} s`);
      if (book.duration_ms < 3 * 3600 * 1000) {
        await clickText("Hörbücher");
        await waitText(book.title.slice(0, 15));
        await page.evaluate((title) => {
          const row = [...document.querySelectorAll("main .item")].find((r) => r.innerText.includes(title));
          [...row.querySelectorAll("button")].find((b) => b.innerText === "Offline").click();
        }, book.title);
        await clickText("Offline");
        await page.waitForFunction((t) => [...document.querySelectorAll("main .item")].some((r) => r.innerText.includes(t) && r.innerText.includes("fertig")),
          { timeout: 600000, polling: 1000 }, book.title.slice(0, 15));
        check("book with all parts saved offline", true);
        // Restart: the last unfinished item (any device) stands paused in "Jetzt läuft".
        const lastU = (await call("GET", "/playback?limit=10")).body.find((p) => !p.finished);
        await page.goto(base, { waitUntil: "domcontentloaded" });
        await page.waitForSelector("nav");
        await clickText("Jetzt läuft", "nav");
        await page.waitForFunction((x) => document.querySelector(".np .title .txt")?.innerText.trim() === x, { timeout: 15000 }, lastU.title);
        await sleep(1500);
        const np = await page.evaluate(() => ({ play: document.querySelector(".ctrl .play").innerText, times: document.querySelector(".times").innerText }));
        const shown = np.times.split(/\s/)[0].split(":").reduce((n, x) => n * 60 + +x, 0);
        check("restart: last unfinished item paused in now playing", np.play !== "❚❚" && Math.abs(shown - lastU.position_ms / 1000) <= 1.5,
          `${lastU.title} from ${lastU.device}, ${np.times.replace(/\n/g, " ")}`);
        await shot("11-neustart-pausiert");
        // Switch on: a finished item leaves the cache, but not while it is the current one.
        await clickText("Offline", "nav");
        await page.waitForSelector(".switch input");
        await page.evaluate(() => document.querySelector(".switch input").click());
        await call("PUT", `/playback/${encodeURIComponent(book.key)}`, { position_ms: book.duration_ms, duration_ms: book.duration_ms, finished: true, updated_at: new Date().toISOString() });
        await sleep(3000);
        const kept = await page.evaluate((x) => [...document.querySelectorAll("main .item")].some((r) => r.innerText.includes(x)), book.title.slice(0, 15));
        await page.goto(base, { waitUntil: "domcontentloaded" });
        await page.waitForSelector("nav");
        await clickText("Offline", "nav");
        const gone = await page.waitForFunction((x) => !!document.querySelector(".switch") && ![...document.querySelectorAll("main .item")].some((r) => r.innerText.includes(x)),
          { timeout: 30000, polling: 500 }, book.title.slice(0, 15)).then(() => true, () => false);
        await shot("12-cache-gehoert");
        check("played media leave the cache when switched on, the current item stays",
          gone && (kept || lastU.key !== book.key), `kept while current ${kept}, removed after restart ${gone}`);
        await page.evaluate(() => document.querySelector(".switch input").click());
      } else {
        console.log("  (book longer than 3 h – offline download skipped)");
      }
      await fetch(`${absc.url}/api/me/progress/${book.key.split(":")[2]}`, { method: "DELETE", headers: { authorization: `Bearer ${absc.api_key}` } });
    }
    await call("DELETE", `/sources/${src.body.id}`);
  }

  // ------------------------------------------------------------ server down: offline
  execSync("systemctl stop audiojoe-server");
  await page.reload({ waitUntil: "domcontentloaded" });
  await waitText("Offline · Cache", 20000).then(() => check("server down: app starts from cache, shows offline", true),
    () => check("server down: app starts from cache, shows offline", false));
  await clickText("Weiterhören");
  await waitText(ep.title.slice(0, 20));
  await page.evaluate((title) => {
    const row = [...document.querySelectorAll("main .item")].find((r) => r.innerText.includes(title));
    [...row.querySelectorAll("button")].find((b) => b.innerText === "Weiter").click();
  }, ep.title.slice(0, 20));
  await waitText("Jetzt läuft");
  await page.waitForFunction(() => document.querySelector(".ctrl .play")?.innerText === "❚❚", { timeout: 15000 });
  await sleep(5000);
  await page.evaluate(() => document.querySelector(".ctrl .play").click());
  await sleep(1000);
  const offlinePos = await page.evaluate(() => document.querySelector(".times span")?.innerText);
  const buffered = await page.evaluate(async () => (await new Promise((res) => {
    const r = indexedDB.open("audiojoe");
    r.onsuccess = () => { const q = r.result.transaction("pending").objectStore("pending").count(); q.onsuccess = () => res(q.result); };
  })));
  check("position buffered while offline", buffered === 1, `${offlinePos}, ${buffered} waiting`);
  check("Position stays green while the wait is short", (await syncPill()).startsWith("pill ok"), await syncPill());
  await page.waitForSelector("#sync.bad", { timeout: 40000 }).then(async () => check("after 30 s waiting: Position red with a cross", (await syncPill()).includes("✕"), await syncPill()),
    () => check("after 30 s waiting: Position red with a cross", false));
  const pillsOffline = await pillW();
  check("Position pill keeps its width (no jumping)", pillsOnline === pillsOffline, `online ${pillsOnline}, offline + waiting ${pillsOffline}`);
  await shot("07-offline-gepuffert");

  // ------------------------------------------------------------ server back: sync
  execSync("systemctl start audiojoe-server");
  await page.waitForSelector("#sync.ok", { timeout: 40000 }).then(() => check("server back: buffered position synced", true),
    () => check("server back: buffered position synced", false));
  const after = await fetch(`${base}/api/v1/playback/${encodeURIComponent(ep.key)}`, { headers: { authorization: `Bearer ${phone}` } }).then((r) => r.json());
  check("server has the offline position from the car", after.device === "Tesla (Test)" && after.position_ms > 590000, `${Math.round(after.position_ms / 1000)} s from ${after.device}`);
  await shot("08-wieder-online");

  // ------------------------------------------------------------ cleanup
  await call("DELETE", `/podcasts/${sub.body.id}`);
  await fetch(`${base}/api/v1/auth/logout`, { method: "POST", headers: { authorization: `Bearer ${phone}` } });
} catch (e) {
  failed++;
  console.log("✖ aborted:", e.message);
  await shot("99-abbruch").catch(() => {});
  execSync("systemctl start audiojoe-server");
} finally {
  await browser.close();
}
console.log(failed ? `\n${failed} check(s) failed` : "\nall checks passed");
process.exit(failed ? 1 : 0);
