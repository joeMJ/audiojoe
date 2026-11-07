// Headless test: connection loss while playing (user 2026-11-07).
//  A  stream without a copy: offline → the player waits at the position and shows as playing;
//     online again → it continues by itself at that position.
//  B  a copy finished while the episode streams: the player takes it over without stopping, and
//     keeps playing when the connection is gone.
//  C  a book of several files that is only partly saved: its saved first part plays from the copy.
//
//   AUDIOJOE_URL=https://audio.example.org CRED=/path/credentials.json node tests/connection.test.mjs

import { createHmac } from "node:crypto";
import { readFileSync } from "node:fs";
import puppeteer from "puppeteer-core";

const base = process.env.AUDIOJOE_URL;
const cred = JSON.parse(readFileSync(process.env.CRED, "utf8"));
const FEED = "https://feeds.lagedernation.org/feeds/ldn-mp3.xml";
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
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
let failed = 0;
const check = (name, cond, detail = "") => {
  console.log(`${cond ? "✔" : "✖"} ${name}${detail ? ` – ${detail}` : ""}`);
  if (!cond) failed++;
};

const browser = await puppeteer.launch({ executablePath: "/usr/bin/chromium", headless: true,
  args: ["--no-sandbox", "--autoplay-policy=no-user-gesture-required", "--lang=de-DE"] });
const page = await browser.newPage();
await page.setViewport({ width: 773, height: 601 });
await page.evaluateOnNewDocument(() => Object.defineProperty(navigator, "language", { get: () => "de-DE" }));
const waitText = (s, timeout = 30000) => page.waitForFunction((x) => document.body.innerText.replace(/­/g, "").includes(x), { timeout, polling: 250 }, s);
const nav = (l) => page.evaluate((l) => [...document.querySelectorAll("nav button")].find((b) => b.innerText.replace(/­/g, "").includes(l)).click(), l);
const call = (method, path, body) => page.evaluate(async (m, p, b) => {
  const r = await fetch(`/api/v1${p}`, { method: m, headers: b ? { "content-type": "application/json" } : {}, body: b ? JSON.stringify(b) : undefined });
  return { status: r.status, body: r.headers.get("content-type")?.includes("json") ? await r.json() : null };
}, method, path, body);
/** Position shown in the player, in seconds. */
const at = () => page.evaluate(() => {
  const t = document.querySelector(".times span")?.innerText ?? "";
  return t.split(":").reduce((a, n) => a * 60 + Number(n), 0);
});
const playing = () => page.evaluate(() => document.querySelector(".ctrl .play")?.innerText === "❚❚");
/** Clicks the progress bar at a fraction (seeks). */
async function seekFraction(f) {
  const r = await page.evaluate(() => { const b = document.querySelector(".dockbar .bar").getBoundingClientRect(); return { x: b.left, y: b.top, w: b.width, h: b.height }; });
  await page.mouse.click(r.x + r.w * f, r.y + r.h / 2);
}
/** Media requests of the page (stream from the server or copy from the cache). */
const media = [];
page.on("request", (r) => {
  const u = new URL(r.url());
  if (u.pathname.startsWith("/api/v1/stream/") || u.pathname.startsWith("/offline/")) media.push(decodeURIComponent(u.pathname));
});
/** Clicks a button of the list row showing `title` (first 30 characters); explains a miss. */
async function rowButton(title, labels) {
  const r = await page.evaluate((t, labels) => {
    const clean = (x) => x.replace(/\u00ad/g, "").replace(/\s+/g, " ");
    const rows = [...document.querySelectorAll("main .item")];
    const row = rows.find((r) => clean(r.innerText).includes(clean(t)));
    if (!row) return `no row with "${t}" (${rows.length} rows: ${rows.slice(0, 4).map((r) => clean(r.innerText).slice(0, 40)).join(" | ")})`;
    const b = [...row.querySelectorAll("button")].find((b) => labels.includes(b.innerText));
    if (!b) return `row without ${labels.join("/")}: ${[...row.querySelectorAll("button")].map((b) => b.innerText).join(", ")}`;
    b.click();
    return "";
  }, title.slice(0, 30), labels);
  if (r) throw new Error(r);
}
async function playEpisode(title) {
  await nav("Podcasts");
  await sleep(1500);
  // The page remembers the podcast opened last (then it shows "← Back" instead of the tabs).
  const inside = await page.evaluate(() => [...document.querySelectorAll("main button.chip")].some((b) => b.innerText.includes("Zurück")));
  if (!inside) {
    await page.evaluate(() => [...document.querySelectorAll("main button")].find((b) => b.innerText.includes("Abonniert"))?.click());
    await waitText("Lage der Nation");
    await page.evaluate(() => document.querySelector("main .item.tap")?.click());
  }
  await waitText(title.slice(0, 20));
  await rowButton(title, ["Abspielen", "Weiter"]);
  await page.waitForFunction(() => document.querySelector(".ctrl .play")?.innerText === "❚❚", { timeout: 60000 });
}

try {
  await page.goto(base, { waitUntil: "networkidle0" });
  await sleep((30 - (Date.now() / 1000) % 30 + 1) * 1000);
  const inputs = await page.$$("form input");
  await inputs[0].type(cred.username);
  await inputs[1].type(cred.password);
  await inputs[2].type(totp(cred.totp_secret));
  await page.click("form button");
  await waitText("Server");
  const sub = await call("POST", "/podcasts", { feed_url: FEED });
  const eps = (await call("GET", `/podcasts/${sub.body.id}/episodes?limit=200`)).body.filter((e) => e.size && e.title);
  const bySize = [...eps].sort((a, b) => a.size - b.size);
  const epB = bySize[0], epA = bySize.find((e) => e.key !== epB.key && (e.duration_ms ?? 0) > 1800000) ?? bySize[1];
  console.log(`  A: ${epA.title} · B: ${epB.title} (${Math.round(epB.size / 2 ** 20)} MB)`);

  // ------------------------------------------------------------ A: stream without a copy
  await playEpisode(epA.title);
  await nav("Jetzt läuft");
  await page.waitForSelector(".dockbar .bar", { timeout: 15000 });
  await sleep(6000);
  await page.setOfflineMode(true);
  // Seeking needs new data from the server: the break shows at once.
  await seekFraction(0.5);
  await sleep(25000);
  const waitPos = await at();
  check("A: offline – shows as playing while waiting", await playing(), `button ${await page.evaluate(() => document.querySelector(".ctrl .play")?.innerText)}`);
  check("A: offline – position kept (about half)", waitPos > 600, `${waitPos} s`);
  const fillA = await page.evaluate(() => document.querySelector(".dockbar .bar i")?.style.width ?? "");
  check("A: offline – bar keeps the held position", parseFloat(fillA) > 30, `fill ${fillA}`);
  const before = media.length;
  await page.setOfflineMode(false);
  await sleep(15000);
  const resumed = await at();
  check("A: online again – continues by itself at the position", (await playing()) && resumed >= waitPos && resumed < waitPos + 60 && media.length > before,
    `${waitPos} s → ${resumed} s, ${media.length - before} new requests`);

  // ------------------------------------------------------------ B: copy finished while streaming
  await playEpisode(epB.title);
  await sleep(3000);
  media.length = 0;
  // As the user does: the save button in the player's toolbar.
  const saved = await page.evaluate(() => {
    const b = [...document.querySelectorAll("button")].find((b) => b.innerText === "Offline" && b.className.includes("sec"));
    b?.click();
    return !!b;
  });
  if (!saved) throw new Error("no save button in the player");
  await page.waitForFunction(async (k) => !!(await (await caches.open("audiojoe-offline-v1")).match(`/offline/${encodeURIComponent(k)}`)),
    { timeout: 300000, polling: 1000 }, epB.key);
  await sleep(3000);
  await nav("Jetzt läuft");
  await page.waitForSelector(".dockbar .bar", { timeout: 15000 });
  const tookCopy = media.some((p) => p.startsWith(`/offline/${epB.key}`));
  check("B: copy finished while playing – taken over", tookCopy && (await playing()), media.slice(-3).join(", "));
  await page.setOfflineMode(true);
  const b1 = await at();
  await sleep(10000);
  const b2 = await at();
  check("B: offline – keeps playing from the copy", (await playing()) && b2 >= b1 + 7, `${b1} s → ${b2} s`);
  const coverB = await page.evaluate(async (k) => {
    const r = await fetch(`/api/v1/image/${encodeURIComponent(k)}`).catch((e) => ({ status: String(e) }));
    return `${r.status} ${r.headers?.get("content-type") ?? ""}`;
  }, epB.key);
  check("B: offline – cover saved with the copy", coverB.startsWith("200 image/"), coverB);
  await page.setOfflineMode(false);

  // ------------------------------------------------------------ C: book partly saved
  const libs = ((await call("GET", "/books/libraries")).body ?? []).filter((l) => l.lib);
  let book = null;
  for (const l of libs) {
    const res = (await call("GET", `/sources/${l.source}/books?parent=${encodeURIComponent(l.lib)}`)).body;
    for (const b of (res?.books ?? []).slice(0, 60)) {
      const it = (await call("GET", `/items/${encodeURIComponent(b.key)}`)).body;
      // The first file small enough to be saved during the test.
      if ((it?.parts?.length ?? 0) > 1 && it.parts[0].duration_ms < 1800000) { book = it; break; }
    }
    if (book) break;
  }
  if (!book) {
    console.log("  C: no book of several files on this server – skipped");
  } else {
    console.log(`  C: ${book.title} (${book.parts.length} files)`);
    // Plays the book from the stream, then saves it from the player's toolbar: its first file
    // is taken over from the copy while the others are still loading.
    await nav("Hörbücher");
    await page.waitForSelector("main input.search", { timeout: 60000 });
    await page.type("main input.search", book.title.slice(0, 25));
    await sleep(1500);
    await page.evaluate((title) => {
      const row = [...document.querySelectorAll("main .item")].find((r) => r.innerText.replace(/\u00ad/g, "").includes(title));
      [...row.querySelectorAll("button")].find((b) => ["Abspielen", "Weiter"].includes(b.innerText)).click();
    }, book.title);
    await page.waitForFunction(() => document.querySelector(".ctrl .play")?.innerText === "❚❚", { timeout: 60000 });
    await nav("Jetzt läuft");
    await sleep(2000);
    media.length = 0;
    await page.evaluate(() => [...document.querySelectorAll("button")].find((b) => b.innerText === "Offline" && b.className.includes("sec"))?.click());
    const first = `${book.key}#0`;
    await page.waitForFunction(async (k) => !!(await (await caches.open("audiojoe-offline-v1")).match(`/offline/${encodeURIComponent(k)}`)),
      { timeout: 300000, polling: 1000 }, first);
    await sleep(3000);
    const all = await page.evaluate(async (k) => !!(await (await caches.open("audiojoe-offline-v1")).match(`/offline/${encodeURIComponent(k)}`)), `${book.key}#${book.parts.length - 1}`);
    check("C: first file saved, book not yet complete", !all);
    check("C: saved first file plays from the copy", media.some((p) => p === `/offline/${first}`) && (await playing()), media.slice(-3).join(", "));
  }
} catch (e) {
  console.log("✖ aborted:", e.message);
  await page.screenshot({ path: process.env.SHOT ?? "/tmp/connection-fail.png" }).catch(() => {});
  console.log("  page:", (await page.evaluate(() => document.querySelector("main")?.innerText.replace(/\s+/g, " ").slice(0, 300)).catch(() => "")));
  failed++;
} finally {
  await browser.close();
}
console.log(failed ? `${failed} checks failed` : "all checks passed");
process.exit(failed ? 1 : 0);
