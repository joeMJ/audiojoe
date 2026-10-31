// Minimal IndexedDB key-value stores for the app:
//   pending   – playback updates not yet sent to the server (key: item key)
//   positions – last known position per item (works offline)
//   offline   – metadata and status of offline titles
//   items     – item metadata for offline use (title, quality, …)

const DB = "audiojoe";
const STORES = ["pending", "positions", "offline", "items"] as const;
export type Store = (typeof STORES)[number];

let dbp: Promise<IDBDatabase> | null = null;

function db(): Promise<IDBDatabase> {
  dbp ??= new Promise((resolve, reject) => {
    const req = indexedDB.open(DB, 1);
    req.onupgradeneeded = () => STORES.forEach((s) => req.result.createObjectStore(s));
    req.onsuccess = () => resolve(req.result);
    req.onerror = () => reject(req.error);
  });
  return dbp;
}

function run<T>(store: Store, mode: IDBTransactionMode, fn: (s: IDBObjectStore) => IDBRequest<T>): Promise<T> {
  return db().then(
    (d) =>
      new Promise<T>((resolve, reject) => {
        const req = fn(d.transaction(store, mode).objectStore(store));
        req.onsuccess = () => resolve(req.result);
        req.onerror = () => reject(req.error);
      }),
  );
}

export const idbGet = <T>(store: Store, key: string) => run<T | undefined>(store, "readonly", (s) => s.get(key));
export const idbPut = (store: Store, key: string, value: unknown) => run(store, "readwrite", (s) => s.put(value, key));
export const idbDel = (store: Store, key: string) => run(store, "readwrite", (s) => s.delete(key));
export const idbAll = <T>(store: Store) => run<T[]>(store, "readonly", (s) => s.getAll());
export const idbKeys = (store: Store) => run<IDBValidKey[]>(store, "readonly", (s) => s.getAllKeys());
