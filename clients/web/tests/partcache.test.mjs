// Headless test: an album that is only partly saved offline plays title after title – none skipped

//
//   AUDIOJOE_URL=https://audio.example.org CRED=/path/credentials.json node tests/queue.test.mjs

import { createHmac } from "node:crypto";
import { readFileSync } from "node:fs";
import puppeteer from "puppeteer-core";

const base = process.env.AUDIOJOE_URL;
const cred = JSON.parse(readFileSync(process.env.CRED, "utf8"));
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
const QUEUE = "aj_queue";
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
const text = () => page.evaluate(() => document.body.innerText.replace(/­/g, ""));
const waitText = (s, timeout = 30000) => page.waitForFunction((x) => document.body.innerText.replace(/­/g, "").includes(x), { timeout, polling: 250 }, s);
const nav = (l) => page.evaluate((l) => [...document.querySelectorAll("nav button")].find((b) => b.innerText.replace(/­/g, "").includes(l)).click(), l);
const openOffline = () => page.evaluate(() => [...document.querySelectorAll("header button, .top button, button")].find((b) => /^Offline/.test(b.innerText.trim())).click());
const index = () => page.evaluate(() => JSON.parse(localStorage.getItem("aj_queue"))?.index);
const toEnd = async () => {
  const box = await (await page.$(".bar")).boundingBox();
  await page.mouse.click(box.x + box.width - 1, box.y + box.height / 2);
};
try {
  await page.goto(base, { waitUntil: "networkidle0" });
  await sleep((30 - (Date.now() / 1000) % 30 + 1) * 1000);
  const inputs = await page.$$("form input");
  await inputs[0].type(cred.username);
  await inputs[1].type(cred.password);
  await inputs[2].type(totp(cred.totp_secret));
  await page.click("form button");
  await waitText("Server");
  await nav("Musik");
  await page.waitForSelector("main .list .item.tap", { timeout: 60000 });
  // An album with at least 6 titles; titles 1, 2 and 5 offline, the others not.
  const total = await page.evaluate(() => {
    const row = [...document.querySelectorAll("main .list .item.tap")].find((r) => /(\d+) Titel/.exec(r.innerText)?.[1] >= 6);
    row.click();
    return Number(/(\d+) Titel/.exec(row.innerText)[1]);
  });
  await waitText("Album abspielen");
  await page.waitForSelector("main .list .item .t1");
  const order = await page.evaluate(() => [...document.querySelectorAll("main .list .item .t1")].map((e) => e.innerText));
  await page.evaluate(() => [...document.querySelectorAll("main button")].find((b) => b.innerText === "Offline").click());
  await page.waitForFunction(async (n) => {
    const db = await new Promise((r) => { const q = indexedDB.open("audiojoe"); q.onsuccess = () => r(q.result); });
    const c = await new Promise((r) => { const q = db.transaction("offline").objectStore("offline").count(); q.onsuccess = () => r(q.result); });
    return c >= n;
  }, { timeout: 30000, polling: 300 }, total);
  // Wait until titles 1, 2, 5 are done, removing the others from the download queue.
  const album = await page.evaluate(async () => {
    const db = await new Promise((r) => { const q = indexedDB.open("audiojoe"); q.onsuccess = () => r(q.result); });
    const all = await new Promise((r) => { const q = db.transaction("offline").objectStore("offline").getAll(); q.onsuccess = () => r(q.result); });
    return all.map((e) => ({ key: e.key, title: e.title }));
  }).then((all) => order.map((t) => all.find((e) => e.title === t)).filter(Boolean));
  console.log(`  album: ${album.length} titles queued for offline`);
  const want = new Set([0, 1, 4].map((i) => album[i]?.key));
  await openOffline();
  await waitText("Offline");
  for (let round = 0; round < 120; round++) {
    const st = await page.evaluate(async (want) => {
      const db = await new Promise((r) => { const q = indexedDB.open("audiojoe"); q.onsuccess = () => r(q.result); });
      const all = await new Promise((r) => { const q = db.transaction("offline").objectStore("offline").getAll(); q.onsuccess = () => r(q.result); });
      return all.map((e) => ({ key: e.key, status: e.status, want: want.includes(e.key) }));
    }, [...want]);
    // Remove unwanted entries via their buttons on the Offline page.
    const extra = st.filter((e) => !e.want).map((e) => e.key);
    if (extra.length) {
      await page.evaluate((titles) => {
        for (const row of document.querySelectorAll("main .list .item")) {
          if (titles.some((t) => row.querySelector(".t1")?.innerText === t)) [...row.querySelectorAll("button")].find((b) => b.innerText === "Entfernen")?.click();
        }
      }, album.filter((a) => extra.includes(a.key)).map((a) => a.title));
      await sleep(500);
      await openOffline();
    }
    if (st.filter((e) => e.want && e.status === "done").length === 3 && !extra.length) break;
    await sleep(2000);
  }
  const cached = await page.evaluate(async () => {
    const db = await new Promise((r) => { const q = indexedDB.open("audiojoe"); q.onsuccess = () => r(q.result); });
    const all = await new Promise((r) => { const q = db.transaction("offline").objectStore("offline").getAll(); q.onsuccess = () => r(q.result); });
    return all.filter((e) => e.status === "done").map((e) => e.title);
  });
  check("titles 1, 2 and 5 offline, the others not", cached.length === 3, cached.join(" | "));

  // Play the album and let every title run to its end: 1 (cache) → 2 (cache) → 3 (server) → 4 (server) → 5 (cache) → 6 (server).
  await nav("Musik");
  await waitText("Album abspielen");   // Music opens on the album shown last
  await page.evaluate(() => [...document.querySelectorAll("main button")].find((b) => b.innerText === "Album abspielen").click());
  await page.waitForFunction(() => document.querySelector(".ctrl .play")?.innerText === "❚❚", { timeout: 30000 });
  const seen = [await index()];
  for (let n = 0; n < 5; n++) {
    await sleep(3000);
    const from = await index();
    await toEnd();
    await page.waitForFunction((i) => JSON.parse(localStorage.getItem("aj_queue"))?.index !== i, { timeout: 30000, polling: 200 }, from);
    await sleep(2500);
    seen.push(await index());
  }
  const cacheChips = await page.evaluate(() => document.querySelector(".fmt")?.innerText.replace(/\s+/g, " "));
  check("each end goes to the next title, none skipped", seen.every((v, i) => v === i), `indices ${seen.join(" → ")} (last: ${cacheChips})`);
  await page.evaluate(() => document.querySelector(".ctrl .play")?.innerText === "❚❚" && document.querySelector(".ctrl .play").click());
} catch (e) {
  check(`aborted: ${e.message}`, false);
}
await browser.close();
console.log(failed ? `\n${failed} check(s) failed` : "\nall checks passed");
process.exit(failed ? 1 : 0);
