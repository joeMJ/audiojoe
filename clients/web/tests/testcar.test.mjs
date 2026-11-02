// Headless test of the car test page (/testcar/) in several screen sizes: required vehicle
// fields, formats and cache, display question, media buttons (fired through the page's own
// handlers), background, and the QR code – read back with zbarimg and compared with the mail.
//
//   AUDIOJOE_URL=http://127.0.0.1:18080 SHOTS=/tmp/testcar node tests/testcar.test.mjs

import { execFileSync } from "node:child_process";
import { mkdirSync } from "node:fs";
import puppeteer from "puppeteer-core";

const base = process.env.AUDIOJOE_URL;
const shots = process.env.SHOTS;
if (shots) mkdirSync(shots, { recursive: true });
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
let failed = 0;
const check = (name, cond, detail = "") => {
  console.log(`${cond ? "✔" : "✖"} ${name}${detail ? ` – ${detail}` : ""}`);
  if (!cond) failed++;
};
const TESLA_UA = "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/136.0.0.0 Safari/537.36 Tesla/2025.32.3";

// size, language, user agent, what is ticked, how the buttons are answered
const CASES = [
  { name: "tesla-split", w: 1083, h: 1104, lang: "de-DE", ua: TESLA_UA, shown: ["bar"], presses: "all" },
  { name: "tesla-full", w: 1920, h: 1104, lang: "de-DE", ua: TESLA_UA, shown: ["cluster"], presses: "all" },
  { name: "wide-720", w: 1280, h: 720, lang: "en-GB", shown: ["bar", "hud"], presses: "timeout" },
  { name: "small-800", w: 800, h: 480, lang: "de-DE", shown: ["none"], presses: "nowheel" },
  { name: "portrait", w: 1080, h: 1920, lang: "en-GB", shown: ["cluster"], presses: "all" },
  { name: "phone", w: 412, h: 860, dpr: 2.6, lang: "de-DE", shown: ["bar"], presses: "all" },
];
const PRESS = { "bar-next": "nexttrack", "bar-prev": "previoustrack", "bar-pause": "pause", "wheel-next": "nexttrack", "wheel-pause": "pause" };

const browser = await puppeteer.launch({ executablePath: "/usr/bin/chromium", headless: true,
  args: ["--no-sandbox", "--autoplay-policy=no-user-gesture-required"] });
try {
  for (const c of CASES) {
    console.log(`— ${c.name} ${c.w}×${c.h} ${c.lang}${c.ua ? " Tesla" : ""}`);
    const ctx = await browser.createBrowserContext();
    const page = await ctx.newPage();
    await page.setViewport({ width: c.w, height: c.h, deviceScaleFactor: c.dpr ?? 1 });
    if (c.ua) await page.setUserAgent(c.ua);
    await page.evaluateOnNewDocument((l) => Object.defineProperty(navigator, "language", { get: () => l }), c.lang);
    const de = c.lang.startsWith("de");
    const overflow = () => page.evaluate(() => document.documentElement.scrollWidth - innerWidth);
    const stepIs = (s, timeout = 20000) => page.waitForFunction((s) => window.__testcar?.step() === s, { timeout, polling: 100 }, s);
    const shoot = (n) => shots && page.screenshot({ path: `${shots}/${c.name}-${n}.png` });

    await page.goto(`${base}/testcar/?auto=1`, { waitUntil: "networkidle0" });
    await page.waitForFunction(() => document.querySelector(".kv")?.children.length >= 8, { timeout: 10000 });
    const make = await page.$eval("input[name=make]", (i) => i.value);
    check("Marke vorausgefüllt nur bei Tesla", make === (c.ua ? "Tesla" : ""), JSON.stringify(make));
    check("Start gesperrt ohne Fahrzeug", await page.$eval("#start", (b) => b.disabled));
    if (!make) await page.type("input[name=make]", "Testmarke");
    await page.type("input[name=model]", "Model Test");
    await page.type("input[name=year]", "20");
    check("Start gesperrt bei unvollständigem Baujahr", await page.$eval("#start", (b) => b.disabled));
    await page.type("input[name=year]", "24");
    check("Start frei mit allen Feldern", !(await page.$eval("#start", (b) => b.disabled)));
    check("Texte in der Browsersprache", (await page.$eval("#start", (b) => b.innerText)).includes(de ? "Test starten" : "Start test"));
    check("keine waagrechte Scrollleiste (Start)", (await overflow()) <= 0, `${await overflow()} px`);
    await shoot("1-start");
    const t0 = Date.now();
    await page.click("#start");

    await stepIs("shown");
    const r1 = await page.evaluate(() => window.__testcar.result);
    check("fünf Formate gemessen", r1.formats.length === 5, r1.formats.join(" "));
    check("MP3 spielt", r1.formats[0].startsWith("mp3+"), r1.formats[0]);
    check("Cache: laden und abspielen", r1.cache.startsWith("+"), r1.cache);
    const pre = await page.$$eval(".opt.on", (o) => o.map((e) => e.id));
    check("Musikleiste vorausgewählt nur bei Tesla", JSON.stringify(pre) === JSON.stringify(c.ua ? ["opt-bar"] : []), pre.join(","));
    for (const id of c.shown) if (!(c.ua && id === "bar")) await page.click(`#opt-${id}`);
    if (c.ua && !c.shown.includes("bar")) await page.click("#opt-bar"); // untick the preselection
    check("Weiter nur mit Auswahl", !(await page.$eval("#next", (b) => b.disabled)));
    check("keine waagrechte Scrollleiste (Anzeige)", (await overflow()) <= 0);
    await shoot("2-anzeige");
    await page.click("#next");

    const bar = c.shown.includes("bar");
    const steps = [...(bar ? ["bar-next", "bar-prev", "bar-pause"] : []), "wheel-next", "wheel-pause"];
    for (const s of steps) {
      if (c.presses === "nowheel" && s.startsWith("wheel")) {
        await stepIs(s);
        await page.click("#nowheel");
        break;
      }
      await stepIs(s);
      if (s === "bar-prev") await shoot("3-knopf");
      if (c.presses === "timeout" && s === "wheel-pause") continue; // nothing arrives: 8 s countdown
      await page.evaluate((a) => window.__testcar.fire(a), PRESS[s]);
    }
    await stepIs("bg", 15000);
    check("keine waagrechte Scrollleiste (Hintergrund)", (await overflow()) <= 0);
    await page.evaluate(() => window.__testcar.hide());
    await sleep(1500);
    if (c.presses !== "nowheel") await page.evaluate(() => window.__testcar.fire("nexttrack"));
    await page.evaluate(() => window.__testcar.show());
    const mail = await page.evaluate(() => window.__testcar.done);
    const secs = Math.round((Date.now() - t0) / 1000);
    const r = await page.evaluate(() => window.__testcar.result);
    const res = Object.fromEntries(r.steps);
    check("Tipp-Schritte nur mit Musikleiste", ("bar-next" in res) === bar, Object.keys(res).join(","));
    if (bar) check("Musikleiste: weiter, zurück, Pause angekommen",
      res["bar-next"] === "nexttrack" && res["bar-prev"] === "previoustrack" && res["bar-pause"].startsWith("pause"), JSON.stringify(res));
    if (c.presses === "all") check("Lenkrad angekommen", res["wheel-next"] === "nexttrack" && res["wheel-pause"].startsWith("pause"), JSON.stringify(res));
    if (c.presses === "timeout") check("Lenkrad Pause ohne Druck: nicht angekommen", res["wheel-pause"] === "-", res["wheel-pause"]);
    if (c.presses === "nowheel") check("keine Lenkradtasten", res["wheel-next"] === "none" && res["wheel-pause"] === "none", JSON.stringify(res));
    check("Hintergrund gemessen", /^away \d+s played \d+s (playing|paused) acts /.test(r.bg), r.bg);
    if (c.presses !== "nowheel") check("Lenkrad im Hintergrund angekommen", r.bg.includes("nexttrack"), r.bg);
    check("Anzeige gespeichert", JSON.stringify(r.shown) === JSON.stringify(["bar", "cluster", "hud", "none"].filter((x) => c.shown.includes(x))), r.shown.join(","));

    // QR code: fully on screen after scrolling to it, and it reads back as the same mail.
    await page.$eval("#qr", (q) => q.scrollIntoView({ block: "center" }));
    const box = await page.$eval("#qr", (q) => { const b = q.getBoundingClientRect(); return { w: Math.round(b.width), h: Math.round(b.height), fits: b.height <= innerHeight && b.width <= innerWidth }; });
    check("QR-Code passt ins Fenster", box.fits, `${box.w}×${box.h}`);
    check("keine waagrechte Scrollleiste (Ergebnis)", (await overflow()) <= 0);
    const png = `${shots ?? "/tmp"}/${c.name}-qr.png`;
    await (await page.$("#qr")).screenshot({ path: png });
    let read = "";
    try { read = execFileSync("zbarimg", ["-q", "--raw", png], { encoding: "utf8" }).trim(); } catch (e) { read = `zbarimg: ${e.status}`; }
    check("QR-Code liest sich als die Mail", read === mail.url, `${read.length} Zeichen`);
    const body = decodeURIComponent(mail.url.split("&body=")[1] ?? "");
    check("Mail ohne Wiederholung der Knopf-Ergebnisse im Protokoll", !/log: .*nexttrack@/.test(body.split("\nbg:")[0] + (c.presses === "nowheel" ? body : "")), body.split("\n").pop());
    const subject = decodeURIComponent(mail.url.match(/subject=([^&]*)/)?.[1] ?? "");
    check("mailto ohne Empfänger", mail.url.startsWith("mailto:?subject="));
    check("Betreff audiojoe testcar <Datum> <Browser>", /^audiojoe testcar \S+ \S+/.test(subject) && (!c.ua || subject.includes("Tesla")), subject);
    check("Mail enthält Fahrzeug", body.includes(`car: ${c.ua ? "Tesla" : "Testmarke"} / Model Test / 2024`));
    check("Mail enthält Bildschirm", body.includes(`win ${c.w}x${c.h}`));
    check("Mail enthält Ergebnis der Knöpfe", body.includes("wheel-next: "));
    const modules = await page.$eval("#qr svg", (s) => s.viewBox.baseVal.width / 4); // cellSize 4, margin 0
    const px = ((box.w - 24) / modules) * (c.dpr ?? 1);
    check("QR-Code mindestens 4 Bildpunkte je Modul", px >= 4, `${modules} Module, ${px.toFixed(1)} Bildpunkte`);
    console.log(`  Dauer mit sofortigen Drücken: ${secs} s, QR ${box.w}×${box.h}, Mail ${mail.url.length} Zeichen`);
    await page.$eval("#qr", (q) => q.scrollIntoView({ block: "start" }));
    await shoot("4-ergebnis");
    if (c.name === "tesla-split") console.log(`  Mailtext:\n${subject}\n${body}`);
    await ctx.close();
  }
} finally {
  await browser.close();
}
console.log(failed ? `${failed} Prüfung(en) fehlgeschlagen` : "alle Prüfungen bestanden");
process.exit(failed ? 1 : 0);
