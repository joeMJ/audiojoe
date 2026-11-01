// Headless test of src/downloader.ts against a small local server that misbehaves on purpose:
// a dropped connection with a server that honours Range (resume), one that ignores Range after
// the drop (restart from the beginning – a converted stream cannot be seeked), a wrong
// Content-Length (416 on the retry) and a checksum. Runs in Node (fetch, crypto.subtle).
//   node tests/downloader.test.mjs
import { createServer } from "node:http";
import { createHash } from "node:crypto";
import { mkdtempSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { build } from "esbuild";

let failed = 0;
const check = (name, ok, detail = "") => {
  console.log(`${ok ? "✔" : "✖"} ${name}${detail ? " – " + detail : ""}`);
  if (!ok) failed++;
};

// The TypeScript module, bundled for Node.
const dir = mkdtempSync(join(tmpdir(), "aj-dl-"));
const out = join(dir, "downloader.mjs");
await build({ entryPoints: [new URL("../src/downloader.ts", import.meta.url).pathname], bundle: true, format: "esm", platform: "node", outfile: out, logLevel: "silent" });
const { download } = await import(out);

const SIZE = 300_000;
const body = Buffer.alloc(SIZE);
for (let i = 0; i < SIZE; i++) body[i] = (i * 7) & 0xff;
const sha = createHash("sha256").update(body).digest("hex");

// Behaviour per path; `hits` counts requests, the first request of each path drops after 100 kB.
const hits = {};
const server = createServer((req, res) => {
  const n = (hits[req.url] = (hits[req.url] ?? 0) + 1);
  const range = /^bytes=(\d+)-/.exec(req.headers.range ?? "");
  const from = range ? Number(range[1]) : 0;
  const drop = () => {
    res.writeHead(200, { "content-type": "audio/flac", "content-length": SIZE, "x-content-sha256": sha, "accept-ranges": "bytes" });
    res.write(body.subarray(0, 100_000));
    setTimeout(() => res.destroy(), 50);
  };
  switch (req.url) {
    case "/resume": // honours Range: 206 from the requested byte
      if (n === 1) return drop();
      res.writeHead(206, { "content-type": "audio/flac", "content-range": `bytes ${from}-${SIZE - 1}/${SIZE}`, "content-length": SIZE - from, "x-content-sha256": sha });
      return res.end(body.subarray(from));
    case "/ignores-range": // converted stream: no Range, always 200 from the start, no length
      if (n === 1) return drop();
      res.writeHead(200, { "content-type": "audio/flac", "x-audiojoe-quality": '{"transcoded":true}', "x-content-sha256": sha });
      return res.end(body);
    case "/too-long": // announces more than it sends; the retry is answered with 416
      if (n === 1) {
        res.writeHead(200, { "content-type": "audio/flac", "content-length": SIZE + 5000, "x-content-sha256": sha });
        return res.end(body);
      }
      res.writeHead(416, { "content-range": `bytes */${SIZE}` });
      return res.end();
    case "/bad-sum":
      res.writeHead(200, { "content-type": "audio/flac", "content-length": SIZE, "x-content-sha256": "0".repeat(64) });
      return res.end(body);
    default:
      res.writeHead(404);
      res.end();
  }
});
await new Promise((r) => server.listen(0, "127.0.0.1", r));
const base = `http://127.0.0.1:${server.address().port}`;
const opts = { stallMs: 2000, backoffMs: 10 };

let { blob, report: r } = await download(`${base}/resume`, opts);
check("dropped connection, server honours Range: resumed, no restart, checksum ok",
  r.ok && r.restarts === 0 && r.attempts === 2 && blob?.size === SIZE && r.verified === true && hits["/resume"] === 2,
  `attempts ${r.attempts}, restarts ${r.restarts}, ${blob?.size} B, verified ${r.verified}`);

({ blob, report: r } = await download(`${base}/ignores-range`, opts));
check("dropped connection, server ignores Range (converted stream): starts over once, complete",
  r.ok && r.restarts === 1 && r.attempts === 2 && blob?.size === SIZE && r.verified === true && r.quality?.includes("transcoded"),
  `attempts ${r.attempts}, restarts ${r.restarts}, ${blob?.size} B, verified ${r.verified}`);
const same = Buffer.from(await blob.arrayBuffer()).equals(body);
check("restarted download has the whole file, not the first bytes twice", same, `${blob.size} B`);

({ blob, report: r } = await download(`${base}/too-long`, opts));
check("wrong Content-Length: 416 on the retry ends the download complete", r.ok && blob?.size === SIZE && r.verified === true, `attempts ${r.attempts}, ${blob?.size} B`);

({ blob, report: r } = await download(`${base}/bad-sum`, opts));
check("checksum mismatch is reported, not stored", !r.ok && r.error === "checksum mismatch" && r.verified === false, r.error);

server.close();
writeFileSync(join(dir, "done"), "");
console.log(failed ? `\n${failed} check(s) failed` : "\nall checks passed");
process.exit(failed ? 1 : 0);
