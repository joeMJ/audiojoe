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
  await waitText("Server erreichbar");
  check("signed in, server reachable", true);
  const cookie = (await page.cookies()).find((c) => c.name === "aj_session");
  check("session cookie HttpOnly + Secure", cookie?.httpOnly && cookie?.secure);

  // Appearance: moon button cycles automatic → light → dark, survives a reload, back to automatic.
  await page.emulateMediaFeatures([{ name: "prefers-color-scheme", value: "light" }]);
  const look = () => page.evaluate(() => ({ label: document.querySelector(".top .theme")?.ariaLabel,
    bg: getComputedStyle(document.documentElement).getPropertyValue("--bg").trim() }));
  const auto = await look();
  await page.click(".top .theme"); const light = await look();
  await page.click(".top .theme"); const dark = await look();
  await page.reload({ waitUntil: "domcontentloaded" }); await page.waitForSelector(".top .theme"); await sleep(1000);
  const kept = await look();
  await shot("00-dunkel");
  await page.click(".top .theme"); const back = await look();
  check("moon button: automatic → light → dark, kept after reload",
    /automatisch/.test(auto.label) && /hell/.test(light.label) && /dunkel/.test(dark.label) && light.bg !== dark.bg
      && kept.bg === dark.bg && /automatisch/.test(back.label) && back.bg === light.bg,
    `${auto.bg} → ${light.bg} → ${dark.bg}, reload ${kept.bg}, back ${back.bg}`);

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
  check("plays from cache, format chips shown", /MP3/.test(here ?? "") && /aus dem Cache/.test(here ?? ""), here);
  const sizes = await page.evaluate(() => [...document.querySelectorAll(".ctrl button, .tools button, .tools .badge")].map((b) => Math.min(b.offsetWidth, b.offsetHeight)));
  check("controls large enough for driving (≥ 64 px)", sizes.length >= 4 && Math.min(...sizes) >= 64, sizes.join(", "));
  const fits = await page.evaluate(() => document.querySelector("main").scrollHeight <= document.querySelector("main").clientHeight + 2);
  check("player fits the car screen without scrolling", fits);
  await clickText("☾ Schlaf-Timer");
  check("sleep timer set", /15 min/.test(await page.evaluate(() => document.querySelector(".tools .big")?.innerText)));
  await clickText("☾ 15 min"); await clickText("☾ 30 min"); await clickText("☾ 60 min"); await clickText("☾ Ende des Titels");
  check("sleep timer cycles back to off", /Schlaf-Timer/.test(await page.evaluate(() => document.querySelector(".tools .big")?.innerText)));
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
  await waitText("Übernommen von Telefon (Test)", 10000).then(() => check("phone's position arrives live in the car", true),
    () => check("phone's position arrives live in the car", false));
  const t = await page.evaluate(() => document.querySelector(".times span")?.innerText);
  check("player jumped to 10:00", t === "10:00", t);
  await shot("05-uebernommen");
  await clickText("Weiterhören");
  await waitText("Zuletzt auf Telefon (Test)");
  await shot("06-weiterhoeren");

  // The car plays on its own speakers only: no output selection (Sonos is in the apps).
  await clickText("Jetzt läuft");
  const outputChip = await page.evaluate(() => [...document.querySelectorAll("main .chip")].some((b) => b.innerText.includes("Dieses Gerät")));
  check("no output selection in the web app", !outputChip);

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
      await waitText(book.title.slice(0, 15));
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
  await waitText("1 warten auf Abgleich", 5000).then(() => check("position buffered while offline", true, offlinePos),
    () => check("position buffered while offline", false));
  await shot("07-offline-gepuffert");

  // ------------------------------------------------------------ server back: sync
  execSync("systemctl start audiojoe-server");
  await waitText("Stände aktuell", 40000).then(() => check("server back: buffered position synced", true),
    () => check("server back: buffered position synced", false));
  const after = await fetch(`${base}/api/v1/playback/${encodeURIComponent(ep.key)}`, { headers: { authorization: `Bearer ${phone}` } }).then((r) => r.json());
  check("server has the offline position from the car", after.device === "Tesla (Test)" && after.position_ms > 600000, `${Math.round(after.position_ms / 1000)} s from ${after.device}`);
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
