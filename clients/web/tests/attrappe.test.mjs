// Headless test of the probe page against the fake source (tests/attrappe).
// Runs the page with ?auto=1 in Chromium and checks downloads under injected faults,
// the offline cache via service worker and playback.
//
//   AUDIOJOE_URL=http://10.0.0.20:8080 npm run test:attrappe
//
// Service workers need a secure context; for a plain-HTTP test server the origin is
// declared secure through a Chromium flag.

import puppeteer from "puppeteer-core";

const base = process.env.AUDIOJOE_URL ?? "http://localhost:8080";
const browser = await puppeteer.launch({
  executablePath: process.env.CHROMIUM ?? "/usr/bin/chromium",
  headless: true,
  args: [
    "--no-sandbox",
    "--autoplay-policy=no-user-gesture-required",
    `--unsafely-treat-insecure-origin-as-secure=${base}`,
  ],
});

let failed = 0;
const check = (name, cond, detail = "") => {
  console.log(`${cond ? "✔" : "✖"} ${name}${detail ? ` – ${detail}` : ""}`);
  if (!cond) failed++;
};

try {
  const page = await browser.newPage();
  page.on("console", (m) => m.type() === "error" && console.log("  console:", m.text()));
  await page.goto(`${base}/probe.html?auto=1`, { waitUntil: "load" });
  await page.waitForFunction(() => window.__probe, { timeout: 240_000, polling: 500 });
  const r = await page.evaluate(() => window.__probe);

  check("secure context", r.environment.secureContext === true);
  check("service worker available", r.environment.serviceWorker === true);
  for (const [name, d] of Object.entries(r.faults)) {
    check(`download: ${name}`, d.ok && d.verified === true,
      `attempts ${d.attempts}, restarts ${d.restarts}, stalls ${d.stalls}, ${d.ms} ms${d.error ? `, ${d.error}` : ""}`);
  }
  for (const [name, d] of Object.entries(r.playback)) {
    check(`playback stream ${name}`, d.ok, d.error ?? `t=${d.currentTime}s`);
  }
  check("service worker controls page", r.offline.serviceWorker.controlling === true);
  for (const key of ["mp3.mp3", "flac24_96.flac"]) {
    const dl = r.offline[`download ${key}`];
    check(`offline download ${key}`, dl?.ok && dl.verified === true, dl ? `attempts ${dl.attempts}` : "missing");
    const c = r.offline[`cache ${key}`];
    check(`offline cache ${key} served by service worker (Range)`, c?.fromServiceWorker && c.status === 206, JSON.stringify(c));
    const p = r.offline[`play from cache ${key}`];
    check(`playback from cache ${key}`, p?.ok, p?.error ?? `t=${p?.currentTime}s`);
  }
} finally {
  await browser.close();
}

console.log(failed ? `\n${failed} check(s) failed` : "\nall checks passed");
process.exit(failed ? 1 : 0);
