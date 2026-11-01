// Headless test: a title that ran to its end is saved as heard, and a title stored "at its end, not heard"
// (the state the old player left) plays from the start instead of being skipped.
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
const title = () => page.evaluate(() => document.querySelector(".np .title .txt")?.innerText);
const queue = () => page.evaluate(() => JSON.parse(localStorage.getItem("aj_queue")));
const at = () => page.evaluate(() => document.querySelector(".times span")?.innerText);
const playback = (key) => page.evaluate(async (k) => (await fetch(`/api/v1/playback/${encodeURIComponent(k)}`)).json(), key);
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
  await page.evaluate(() => [...document.querySelectorAll("main .list .item.tap")].find((r) => /(\d+) Titel/.exec(r.innerText)?.[1] >= 3).click());
  await waitText("Album abspielen");
  await page.evaluate(() => [...document.querySelectorAll("main button")].find((b) => b.innerText === "Album abspielen").click());
  await page.waitForFunction(() => document.querySelector(".ctrl .play")?.innerText === "❚❚", { timeout: 30000 });
  await sleep(3000);
  const q = await queue();
  const one = q.queue[q.index], two = q.queue[q.index + 1];
  // Title 2 as the old player left it: position at its end, not heard.
  const end = two.duration_ms;
  const set = await page.evaluate(async (t, end) => (await fetch("/api/v1/playback", { method: "POST", headers: { "content-type": "application/json" },
    body: JSON.stringify([{ key: t.key, position_ms: end, duration_ms: end, finished: false, title: t.title, subtitle: t.subtitle ?? "", device: "Tesla (Test)", updated_at: new Date().toISOString() }]) })).status, two, end);
  const before = await playback(two.key);
  console.log(`  title 2 before: ${two.title} – position ${before.position_ms / 1000} s of ${before.duration_ms / 1000} s, heard ${before.finished} (POST ${set})`);
  // Title 1 runs to its end by itself (jump to the last second, then let it play out).
  const box = await (await page.$(".bar")).boundingBox();
  await page.mouse.click(box.x + box.width - 1, box.y + box.height / 2);
  await page.waitForFunction((t) => document.querySelector(".np .title .txt")?.innerText !== t, { timeout: 30000, polling: 200 }, await title());
  await sleep(5000);
  const now = await queue();
  const pos = await at();
  check("after title 1 ends, title 2 plays (not skipped)", now.index === q.index + 1, `index ${q.index} → ${now.index}, ${await title()}`);
  check("title 2 plays from the start, not from its stored end", /^0:0\d$/.test(pos ?? ""), `at ${pos}`);
  const heard = await playback(one.key);
  check("title 1 is saved as heard", heard.finished === true, `${one.title}: position ${heard.position_ms / 1000} s of ${heard.duration_ms / 1000} s, heard ${heard.finished}`);
  await page.evaluate(() => document.querySelector(".ctrl .play")?.innerText === "❚❚" && document.querySelector(".ctrl .play").click());
  await sleep(1500);
  console.log(`  keys: ${one.key} ${two.key}`);
} catch (e) {
  check(`aborted: ${e.message}`, false);
}
await browser.close();
console.log(failed ? `\n${failed} check(s) failed` : "\nall checks passed");
process.exit(failed ? 1 : 0);
