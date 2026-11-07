/// <reference lib="webworker" />
// Service worker: serves offline media from Cache Storage, including Range requests,
// so <audio> can seek in cached files without network.

const sw = self as unknown as ServiceWorkerGlobalScope;

// Same value as in offline.ts. Not imported, so the worker stays a single classic script
// without shared chunks.
const OFFLINE_CACHE = "audiojoe-offline-v1";

sw.addEventListener("install", (e) => {
  void sw.skipWaiting();
  e.waitUntil(fetch("/", { cache: "no-store" }).then((r) => (r.ok ? storeShell(r) : undefined)).catch(() => {}));
});
sw.addEventListener("activate", (e) => e.waitUntil(sw.clients.claim()));

// App shell, so the app starts without network: the page network-first (always the
// newest version when online), hashed assets cache-first.
const SHELL_CACHE = "audiojoe-shell-v1";

sw.addEventListener("fetch", (e) => {
  const url = new URL(e.request.url);
  if (url.origin !== sw.location.origin || e.request.method !== "GET") return;
  if (url.pathname.startsWith("/offline/")) {
    e.respondWith(fromCache(e.request, url.pathname));
  } else if (url.pathname.startsWith("/api/v1/image/")) {
    e.respondWith(cover(e.request));
  } else if (e.request.mode === "navigate" && !url.pathname.startsWith("/api/") && !url.pathname.startsWith("/testcar/")) {
    e.respondWith(page(e.request));
  } else if (url.pathname.startsWith("/assets/") || url.pathname === "/manifest.webmanifest") {
    e.respondWith(asset(e.request));
  }
});

async function page(req: Request): Promise<Response> {
  const cache = await caches.open(SHELL_CACHE);
  try {
    const res = await fetch(req);
    if (res.ok) void storeShell(res.clone());
    // Server down behind the proxy: serve the cached app instead of the proxy's error page.
    if (res.status >= 500) return (await cache.match("/")) ?? res;
    return res;
  } catch {
    return (await cache.match("/")) ?? new Response("offline", { status: 503 });
  }
}

/** Stores the page and the assets it references; drops assets of older versions. */
async function storeShell(res: Response) {
  const cache = await caches.open(SHELL_CACHE);
  const html = await res.clone().text();
  await cache.put("/", res);
  const wanted = new Set([...html.matchAll(/(?:src|href)="(\/assets\/[^"]+)"/g)].map((m) => m[1]));
  for (const path of wanted) {
    if (!(await cache.match(path))) await cache.add(path).catch(() => {});
  }
  for (const req of await cache.keys()) {
    const path = new URL(req.url).pathname;
    if (path.startsWith("/assets/") && !wanted.has(path)) await cache.delete(req);
  }
}

async function asset(req: Request): Promise<Response> {
  const cache = await caches.open(SHELL_CACHE);
  const hit = await cache.match(req);
  if (hit) return hit;
  const res = await fetch(req);
  if (res.ok) await cache.put(req, res.clone());
  return res;
}

/** Covers of saved titles come from the offline cache (also without network), others from the server. */
async function cover(req: Request): Promise<Response> {
  const hit = await (await caches.open(OFFLINE_CACHE)).match(new URL(req.url).pathname);
  return hit ?? fetch(req);
}

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
