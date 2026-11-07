// Offline storage for downloaded media. Files live in Cache Storage under /offline/<key>;
// the service worker answers requests (including Range) for these URLs from the cache.

export const OFFLINE_CACHE = "audiojoe-offline-v1";

export const offlineUrl = (key: string) => `/offline/${encodeURIComponent(key)}`;

export async function storeOffline(key: string, blob: Blob): Promise<void> {
  const cache = await caches.open(OFFLINE_CACHE);
  await cache.put(
    offlineUrl(key),
    new Response(blob, {
      headers: { "content-type": blob.type, "content-length": String(blob.size) },
    }),
  );
}

export async function removeOffline(key: string): Promise<boolean> {
  return (await caches.open(OFFLINE_CACHE)).delete(offlineUrl(key));
}

/** Covers of saved titles: under their own server path (/api/v1/image/…) in the same cache; the
 *  service worker answers image requests from there first, so they show offline. */
export async function storeCover(path: string, res: Response): Promise<void> {
  await (await caches.open(OFFLINE_CACHE)).put(path, res);
}

export async function removeCover(path: string): Promise<boolean> {
  return (await caches.open(OFFLINE_CACHE)).delete(path);
}

export async function hasCover(path: string): Promise<boolean> {
  return !!(await (await caches.open(OFFLINE_CACHE)).match(path));
}
