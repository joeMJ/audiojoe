// Headless test: the "Cache" pill left of "Server" shows the saved share of what plays next,
// keeps its width, saves the rest on a tap, and the offline page counts the download up.
//
//   AUDIOJOE_URL=https://audio.example.org CRED=/path/credentials.json node tests/cache.test.mjs

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
const pill = () => page.evaluate(() => {
  const p = document.querySelector("#cache"), n = document.querySelector("#net");
  return p && { text: p.innerText, cls: p.className, width: p.getBoundingClientRect().width, fits: p.scrollWidth <= p.clientWidth,
    leftOfServer: !!n && p.getBoundingClientRect().right <= n.getBoundingClientRect().left };
});
try {
  await page.goto(base, { waitUntil: "networkidle0" });
  await sleep((30 - (Date.now() / 1000) % 30 + 1) * 1000);
  const inputs = await page.$$("form input");
  await inputs[0].type(cred.username);
  await inputs[1].type(cred.password);
  await inputs[2].type(totp(cred.totp_secret));
  await page.click("form button");
  await waitText("Server");
  const first = await pill();
  check("pill „Cache“ left of „Server“", first?.leftOfServer === true, JSON.stringify(first));

  // The album with the fewest titles (at least 3): little to download, and an order to check.
  await nav("Musik");
  await page.waitForSelector("main .list .item.tap", { timeout: 60000 });
  await page.evaluate(() => {
    const rows = [...document.querySelectorAll("main .list .item.tap")].map((r) => [r, Number(/(\d+) Titel/.exec(r.innerText)?.[1] ?? 0)]);
    rows.filter(([, n]) => n >= 3).sort((a, b) => a[1] - b[1])[0][0].click();
  });
  await waitText("Album abspielen");
  await page.evaluate(() => [...document.querySelectorAll("main button")].find((b) => b.innerText === "Album abspielen").click());
  await waitText("Wiedergabe");
  await page.evaluate(() => document.querySelector(".ctrl .play")?.innerText === "❚❚" && document.querySelector(".ctrl .play").click());
  // 0.3.3 (user „260“): on to title 2; the tap has to save 2, 3, … and title 1 last.
  await sleep(1500);
  await page.evaluate(() => document.querySelectorAll(".ctrl button:not(.skip):not(.play)")[1].click());
  await sleep(3000);
  await page.evaluate(() => document.querySelector(".ctrl .play")?.innerText === "❚❚" && document.querySelector(".ctrl .play").click());
  const fetched = [];
  page.on("request", (r) => {
    const u = r.url();
    if (u.includes("profile=tesla-offline")) {
      const k = decodeURIComponent(u.split("/api/v1/stream/")[1].split("?")[0]);
      if (!fetched.includes(k)) fetched.push(k);
    }
  });
  await page.waitForFunction(() => /^Cache \d+ %$/.test(document.querySelector("#cache")?.innerText ?? ""), { timeout: 20000, polling: 250 });
  const before = await pill();
  check("album not saved: „Cache 0 %“ in yellow", before.text === "Cache 0 %" && before.cls.includes("warn"), JSON.stringify(before));

  // A tap saves the album; the pill and the offline page count up on the way.
  await page.evaluate(() => document.querySelector("#cache").click());
  const seen = new Set(), counted = new Set();
  const until = Date.now() + 240000;
  await page.evaluate(() => document.querySelector("#offsize").click());
  while (Date.now() < until) {
    const p = await pill();
    seen.add(p.text);
    for (const m of await page.evaluate(() => [...document.querySelectorAll("main .list .item")].map((r) => /lädt (\d+) %/.exec(r.innerText)?.[1]).filter(Boolean))) counted.add(Number(m));
    if (p.text === "Cache 100 %") break;
    await sleep(200);
  }
  const after = await pill();
  check("after the tap: „Cache 100 %“ in green", after.text === "Cache 100 %" && after.cls.includes("ok"), JSON.stringify(after));
  check("pill counts up in between", [...seen].some((s) => /^Cache ([1-9]\d?) %$/.test(s)), [...seen].join(", "));
  check("offline page counts „lädt x %“ up", [...counted].some((n) => n > 0 && n < 100), [...counted].sort((a, b) => a - b).join(", "));
  const q = await page.evaluate(() => JSON.parse(localStorage.getItem("aj_queue")));
  const want = [...q.queue.slice(q.index), ...q.queue.slice(0, q.index)].map((x) => x.key);
  check("downloads from the title playing to the end, then from the start (2, 3, …, 1)",
    q.index === 1 && JSON.stringify(fetched) === JSON.stringify(want),
    `index ${q.index}; ${fetched.map((k) => want.indexOf(k) + 1).join(", ")} of ${want.length}`);
  check("pill keeps its width", before.width === after.width && after.fits, `${before.width} / ${after.width}, fits ${after.fits}`);
} catch (e) {
  check(`aborted: ${e.message}`, false);
}
await browser.close();
console.log(failed ? `\n${failed} check(s) failed` : "\nall checks passed");
process.exit(failed ? 1 : 0);
