// Headless test: "Clear cache" on the offline page asks on the page, "Cancel" keeps everything,
// "Delete" removes all saved titles (also a running download) and their files.
//
//   AUDIOJOE_URL=https://audio.example.org CRED=/path/credentials.json node tests/clearcache.test.mjs

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
const offline = () => page.evaluate(async () => ({
  rows: document.querySelectorAll("main .list .item").length,
  files: (await (await caches.open("audiojoe-offline-v1")).keys()).length,
}));
const button = (label) => page.evaluate((l) => [...document.querySelectorAll("main button")].find((b) => b.innerText === l)?.click() ?? false, label);
try {
  await page.goto(base, { waitUntil: "networkidle0" });
  await sleep((30 - (Date.now() / 1000) % 30 + 1) * 1000);
  const inputs = await page.$$("form input");
  await inputs[0].type(cred.username);
  await inputs[1].type(cred.password);
  await inputs[2].type(totp(cred.totp_secret));
  await page.click("form button");
  await waitText("Server");

  // An album with few titles: save it, wait for the first title, the rest may still be loading.
  await nav("Musik");
  await page.waitForSelector("main .list .item.tap", { timeout: 60000 });
  await page.evaluate(() => {
    const rows = [...document.querySelectorAll("main .list .item.tap")].map((r) => [r, Number(/(\d+) Titel/.exec(r.innerText)?.[1] ?? 0)]);
    rows.filter(([, n]) => n >= 3).sort((a, b) => a[1] - b[1])[0][0].click();
  });
  await waitText("Album abspielen");
  await page.evaluate(() => [...document.querySelectorAll("main button")].find((b) => b.innerText === "Offline")?.click());
  await page.click("#offsize");
  await waitText("Cache leeren");
  const car = await page.$eval('.about a[href="/testcar/"]', (a) => ({ text: a.innerText, target: a.target })).catch(() => null);
  check("Link Autotest unter „Über audiojoe“, im selben Fenster", car?.text === "Autotest" && !car.target, JSON.stringify(car));
  await page.waitForFunction(async () => (await (await caches.open("audiojoe-offline-v1")).keys()).length > 0, { timeout: 120000, polling: 500 });
  const before = await offline();
  check("saved titles listed and a file in the cache", before.rows >= 3 && before.files >= 1, JSON.stringify(before));

  // The order of the page: storage, then the button, then the switch.
  const order = await page.evaluate(() => {
    const els = [...document.querySelectorAll("main .storage, main button.clear, main label.switch")];
    return els.map((e) => e.className);
  });
  check("button right under the storage line", order[0] === "storage" && order[1].includes("clear"), order.join(" | "));

  await button("Cache leeren");
  await waitText("Alle offline gespeicherten Titel löschen?");
  if (process.env.SHOT) await page.screenshot({ path: process.env.SHOT });
  await sleep(1500); // re-renders while loading must keep the question
  check("question stays while a download counts up", await page.evaluate(() => document.body.innerText.includes("Alle offline gespeicherten Titel löschen?")));
  await button("Abbrechen");
  await sleep(500);
  const kept = await offline();
  check("„Abbrechen“ keeps everything", kept.rows === before.rows && kept.files >= before.files, JSON.stringify(kept));

  await button("Cache leeren");
  await waitText("Alle offline gespeicherten Titel löschen?");
  await button("Löschen");
  await waitText("Noch nichts offline gespeichert.");
  await sleep(8000); // a download that was running must not come back
  const after = await offline();
  check("„Löschen“ removes all titles and files", after.rows === 0 && after.files === 0, JSON.stringify(after));
  check("switch „Gespieltes …“ still there", await page.evaluate(() => !!document.querySelector("main label.switch")));
} catch (e) {
  check(`aborted: ${e.message}`, false);
}
await browser.close();
console.log(failed ? `\n${failed} check(s) failed` : "\nall checks passed");
process.exit(failed ? 1 : 0);
