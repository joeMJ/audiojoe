// Robust download of a complete media file for offline use.
// Survives dropped connections, stalls, servers that ignore Range, wrong Content-Length
// and temporary 5xx errors: it resumes with Range requests from the last received byte
// and verifies the result against the checksum announced by the server, if any.

export interface DownloadOptions {
  /** Abort and resume when no data arrives for this long. */
  stallMs?: number;
  maxAttempts?: number;
  /** First retry delay; doubles per attempt up to 15 s. */
  backoffMs?: number;
  onProgress?: (bytes: number, total: number | undefined) => void;
}

export interface DownloadReport {
  ok: boolean;
  bytes: number;
  total?: number;
  attempts: number;
  /** Times the download had to start over because the server ignored Range. */
  restarts: number;
  stalls: number;
  /** true/false when the server announced a checksum, null otherwise. */
  verified: boolean | null;
  contentType?: string;
  /** Value of the server's x-audiojoe-quality header, if sent. */
  quality?: string;
  ms: number;
  error?: string;
}

const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));

export async function download(
  url: string,
  opts: DownloadOptions = {},
): Promise<{ blob?: Blob; report: DownloadReport }> {
  const stallMs = opts.stallMs ?? 15000;
  const maxAttempts = opts.maxAttempts ?? 8;
  const backoffMs = opts.backoffMs ?? 1000;
  const started = performance.now();
  const r: DownloadReport = { ok: false, bytes: 0, attempts: 0, restarts: 0, stalls: 0, verified: null, ms: 0 };
  let chunks: Uint8Array[] = [];
  let offset = 0;
  let expectedSha: string | null = null;
  let lastError = "";

  while (r.attempts < maxAttempts) {
    r.attempts++;
    const ctrl = new AbortController();
    let timer = setTimeout(() => ctrl.abort("stall"), stallMs);
    const resetTimer = () => {
      clearTimeout(timer);
      timer = setTimeout(() => ctrl.abort("stall"), stallMs);
    };
    try {
      const headers: HeadersInit = offset > 0 ? { Range: `bytes=${offset}-` } : {};
      const res = await fetch(url, { headers, signal: ctrl.signal, cache: "no-store" });
      expectedSha = res.headers.get("x-content-sha256") ?? expectedSha;
      r.contentType = res.headers.get("content-type") ?? r.contentType;
      r.quality = res.headers.get("x-audiojoe-quality") ?? r.quality;

      if (res.status === 416) {
        // We already have everything; happens after a too large Content-Length.
        const m = /\/(\d+)$/.exec(res.headers.get("content-range") ?? "");
        if (m && Number(m[1]) === offset) {
          r.total = offset;
          break;
        }
        throw new Error("range not satisfiable");
      }
      if (!res.ok || !res.body) throw new Error(`HTTP ${res.status}`);
      if (res.status === 200 && offset > 0) {
        chunks = [];
        offset = 0;
        r.restarts++;
      }
      if (res.status === 206) {
        const m = /\/(\d+)$/.exec(res.headers.get("content-range") ?? "");
        if (m) r.total = Number(m[1]);
      } else {
        const len = res.headers.get("content-length");
        if (len) r.total = Number(len);
      }

      const reader = res.body.getReader();
      for (;;) {
        const { done, value } = await reader.read();
        if (done) break;
        resetTimer();
        chunks.push(value);
        offset += value.byteLength;
        opts.onProgress?.(offset, r.total);
      }
      clearTimeout(timer);
      if (r.total !== undefined && offset < r.total) throw new Error(`short body ${offset}/${r.total}`);
      r.total = offset;
      break;
    } catch (e) {
      clearTimeout(timer);
      if (ctrl.signal.aborted) r.stalls++;
      lastError = ctrl.signal.aborted ? "stall" : String((e as Error)?.message ?? e);
      if (r.attempts >= maxAttempts) {
        r.error = lastError;
        r.bytes = offset;
        r.ms = Math.round(performance.now() - started);
        return { report: r };
      }
      await sleep(Math.min(backoffMs * 2 ** (r.attempts - 1), 15000));
    }
  }

  const blob = new Blob(chunks as BlobPart[], { type: r.contentType ?? "application/octet-stream" });
  r.bytes = blob.size;
  if (expectedSha) {
    const digest = await crypto.subtle.digest("SHA-256", await blob.arrayBuffer());
    const hex = [...new Uint8Array(digest)].map((b) => b.toString(16).padStart(2, "0")).join("");
    r.verified = hex === expectedSha;
  }
  r.ok = r.verified !== false;
  if (!r.ok) r.error = "checksum mismatch";
  r.ms = Math.round(performance.now() - started);
  return { blob, report: r };
}
