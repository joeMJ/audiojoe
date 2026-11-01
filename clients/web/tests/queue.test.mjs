// Headless test: an album keeps its queue across a reload (⏮ ⏭ stay, the next title follows),
// a second device taking over the title gets the whole album, and a long title flows.
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
const ctrl = () => page.evaluate(() => ({ steps: document.querySelectorAll(".ctrl button:not(.skip):not(.play)").length,
  next: !document.querySelector(".tools .next")?.disabled }));
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
  // The first album with at least 3 titles.
  await page.evaluate(() => [...document.querySelectorAll("main .list .item.tap")].find((r) => /(\d+) Titel/.exec(r.innerText)?.[1] >= 3).click());
  await waitText("Album abspielen");
  await page.evaluate(() => [...document.querySelectorAll("main button")].find((b) => b.innerText === "Album abspielen").click());
  await waitText("Wiedergabe");
  await sleep(4000);
  const first = await title();
  check("album plays with ⏮ ⏭", (await ctrl()).steps === 2, `${first}, ${JSON.stringify(await ctrl())}`);
  const facts = await page.evaluate(() => ({ place: document.querySelector(".np .title .count")?.innerText.trim(),
    codec: [...document.querySelectorAll(".fchip")].map((c) => `${c.innerText}:${c.className}`).join(" ") }));
  check("„(1 von n)“ after the title", /^\(1 von \d+\)$/.test(facts.place ?? ""), facts.place);
  check("lossless codec chip coloured by bit depth", /(FLAC|PCM|ALAC):fchip (hi|cd)/.test(facts.codec) || !/FLAC|PCM|ALAC/.test(facts.codec), facts.codec);
  await page.evaluate(() => document.querySelector(".ctrl .play").click()); // pause, position saved
  await sleep(1500);
  await page.reload({ waitUntil: "domcontentloaded" });
  await nav("Jetzt läuft");
  await page.waitForSelector(".np .title", { timeout: 20000 });
  await sleep(1000);
  const c = await ctrl();
  check("after a reload: same title, ⏮ ⏭ and „Nächster“ still there", (await title()) === first && c.steps === 2 && c.next, `${await title()}, ${JSON.stringify(c)}`);
  await page.evaluate(() => document.querySelectorAll(".ctrl button:not(.skip):not(.play)")[1].click());
  await sleep(3000);
  const second = await title();
  check("⏭ after the reload plays the next title of the album", second && second !== first, second);
  await page.evaluate(() => document.querySelector(".ctrl .play")?.innerText === "❚❚" && document.querySelector(".ctrl .play").click());
  await sleep(1500);

  // A long title flows (the count stays visible); the flow restarts on a resize.
  const flows = await page.evaluate(async () => {
    const txt = document.querySelector(".np .title .txt");
    txt.firstChild.textContent = "A very long title that never fits into one line of the player view ".repeat(2);
    dispatchEvent(new Event("resize"));
    await new Promise((r) => setTimeout(r, 300));
    const el = document.querySelector(".np .title");
    return { flowing: el.classList.contains("flowing"), running: el.querySelector(".run").getAnimations().length };
  });
  check("a long title flows in one line", flows.flowing && flows.running === 1, JSON.stringify(flows));

  // A second device (own session) takes over the paused title: the album comes along.
  const other = await browser.createBrowserContext();
  const p2 = await other.newPage();
  await p2.setViewport({ width: 773, height: 601 });
  await p2.evaluateOnNewDocument(() => Object.defineProperty(navigator, "language", { get: () => "de-DE" }));
  await p2.goto(base, { waitUntil: "networkidle0" });
  await sleep((30 - (Date.now() / 1000) % 30 + 1) * 1000);
  const in2 = await p2.$$("form input");
  await in2[0].type(cred.username);
  await in2[1].type(cred.password);
  await in2[2].type(totp(cred.totp_secret));
  await p2.click("form button");
  await p2.waitForFunction(() => document.body.innerText.includes("Server"), { timeout: 30000 });
  await p2.evaluate(() => [...document.querySelectorAll("nav button")].find((b) => b.innerText.replace(/­/g, "").includes("Jetzt läuft")).click());
  await p2.waitForSelector(".np .title .txt", { timeout: 20000 });
  await sleep(1500);
  const taken = await p2.evaluate(() => ({ title: document.querySelector(".np .title .txt")?.innerText,
    steps: document.querySelectorAll(".ctrl button:not(.skip):not(.play)").length }));
  check("another device taking over gets the album with ⏮ ⏭", taken.title === second && taken.steps === 2, JSON.stringify(taken));
  await other.close();
} catch (e) {
  check(`aborted: ${e.message}`, false);
}
await browser.close();
console.log(failed ? `\n${failed} check(s) failed` : "\nall checks passed");
process.exit(failed ? 1 : 0);
