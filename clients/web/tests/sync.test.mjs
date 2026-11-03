// Headless test of the event stream watchdog in src/app/sync.ts against a small local server:
// a stream that stops sending (no "ping", no events, connection left open – the way a dropped
// connection looks from the browser) must be replaced by a new one; a stream that keeps pinging
// stays; events on the new stream still reach the listeners.
//   node tests/sync.test.mjs          (needs /usr/bin/chromium)
import { createServer } from "node:http";
import { mkdtempSync, readFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { build } from "esbuild";
import puppeteer from "puppeteer-core";

let failed = 0;
const check = (name, ok, detail = "") => {
  console.log(`${ok ? "✔" : "✖"} ${name}${detail ? " – " + detail : ""}`);
  if (!ok) failed++;
};
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const t0 = Date.now();
const at = () => `${((Date.now() - t0) / 1000).toFixed(1)} s`;

// The module, bundled for the browser; the page shortens the watchdog times.
const dir = mkdtempSync(join(tmpdir(), "aj-sync-"));
const out = join(dir, "sync.js");
await build({ entryPoints: [new URL("../src/app/sync.ts", import.meta.url).pathname], bundle: true, format: "esm", platform: "browser", outfile: out, logLevel: "silent" });
const page_html = `<!doctype html><title>sync</title><script type="module">
import { startSync, onRemote, watchdog } from "/sync.js";
watchdog.everyMs = 1000; watchdog.silenceMs = 3000;
window.got = []; onRemote((p) => window.got.push(p.key));
startSync();
</script>`;

// Stream 1 pings for 2 s, then falls silent (stays open). Later streams ping on; stream 2 also
// gets a playback event after 1 s.
const streams = [];
const server = createServer((req, res) => {
  if (req.url === "/") return res.end(page_html);
  if (req.url === "/sync.js") { res.setHeader("content-type", "text/javascript"); return res.end(readFileSync(out)); }
  if (req.url === "/api/v1/health") return res.end("{}");
  if (req.url !== "/api/v1/events") { res.statusCode = 404; return res.end(); }
  const n = streams.length + 1;
  const s = { n, opened: Date.now(), closed: 0, pings: 0 };
  streams.push(s);
  res.writeHead(200, { "content-type": "text/event-stream", "cache-control": "no-store" });
  res.write(":\n\n");
  const ping = setInterval(() => {
    if (n === 1 && Date.now() - s.opened > 2000) return; // silent from now on, but open
    s.pings++;
    res.write("event: ping\ndata: {}\n\n");
  }, 500);
  if (n === 2) setTimeout(() => res.write(`event: playback\ndata: ${JSON.stringify({ state: { key: "episode:7", position_ms: 1, finished: false, title: "", subtitle: "", device: "x", updated_at: "" } })}\n\n`), 1000);
  req.on("close", () => { s.closed = Date.now(); clearInterval(ping); });
});
await new Promise((r) => server.listen(0, "127.0.0.1", r));
const base = `http://127.0.0.1:${server.address().port}`;

const browser = await puppeteer.launch({ executablePath: "/usr/bin/chromium", headless: true, args: ["--no-sandbox"] });
try {
  const page = await browser.newPage();
  await page.goto(`${base}/`);
  await sleep(1500);
  check("stream 1 opened and pinged", streams.length === 1 && streams[0].pings >= 2, `${streams.length} streams, ${streams[0]?.pings} pings at ${at()}`);
  // Silence starts at 2 s; the watchdog (3 s silence, checked every 1 s) must replace the stream by ~6–7 s.
  await sleep(6500);
  check("silent stream replaced by a new one", streams.length === 2, `${streams.length} streams at ${at()}`);
  check("silent stream closed by the client", streams[0].closed > 0, streams[0].closed ? `after ${((streams[0].closed - streams[0].opened) / 1000).toFixed(1)} s` : "still open");
  check("replacement came after 3 s of silence, not before", streams[1] && streams[1].opened - streams[0].opened >= 4800, streams[1] ? `${((streams[1].opened - streams[0].opened) / 1000).toFixed(1)} s after stream 1` : "");
  await sleep(2000);
  const got = await page.evaluate(() => window.got);
  check("event on the new stream reaches the listener", got.includes("episode:7"), JSON.stringify(got));
  // A stream that keeps pinging is left alone.
  await sleep(5000);
  check("live stream kept", streams.length === 2 && streams[1].closed === 0, `${streams.length} streams at ${at()}`);
} finally {
  await browser.close();
  server.close();
}
console.log(failed ? `${failed} check(s) failed` : "all checks passed");
process.exit(failed ? 1 : 0);
