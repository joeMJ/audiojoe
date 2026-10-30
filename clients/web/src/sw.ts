/// <reference lib="webworker" />
// Service worker: serves offline media from Cache Storage, including Range requests,
// so <audio> can seek in cached files without network.

const sw = self as unknown as ServiceWorkerGlobalScope;

// Same value as in offline.ts. Not imported, so the worker stays a single classic script
// without shared chunks.
const OFFLINE_CACHE = "audiojoe-offline-v1";

sw.addEventListener("install", () => void sw.skipWaiting());
sw.addEventListener("activate", (e) => e.waitUntil(sw.clients.claim()));

sw.addEventListener("fetch", (e) => {
  const url = new URL(e.request.url);
  if (url.origin === sw.location.origin && url.pathname.startsWith("/offline/")) {
    e.respondWith(fromCache(e.request, url.pathname));
  }
});

async function fromCache(req: Request, path: string): Promise<Response> {
  const cached = await (await caches.open(OFFLINE_CACHE)).match(path);
  if (!cached) return new Response("not cached", { status: 404 });
  const blob = await cached.blob();
  const type = cached.headers.get("content-type") ?? "application/octet-stream";
  const base = { "content-type": type, "accept-ranges": "bytes", "x-from-cache": "1" };

  const m = /^bytes=(\d*)-(\d*)$/.exec(req.headers.get("range") ?? "");
  if (!m) {
    return new Response(blob, { headers: { ...base, "content-length": String(blob.size) } });
  }
  let start: number;
  let end: number;
  if (m[1] === "") {
    start = Math.max(0, blob.size - Number(m[2]));
    end = blob.size - 1;
  } else {
    start = Number(m[1]);
    end = m[2] === "" ? blob.size - 1 : Math.min(Number(m[2]), blob.size - 1);
  }
  if (start >= blob.size || start > end) {
    return new Response(null, { status: 416, headers: { ...base, "content-range": `bytes */${blob.size}` } });
  }
  return new Response(blob.slice(start, end + 1), {
    status: 206,
    headers: {
      ...base,
      "content-length": String(end - start + 1),
      "content-range": `bytes ${start}-${end}/${blob.size}`,
    },
  });
}
