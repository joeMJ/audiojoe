# Components reachable over HTTPS

*This page describes the current release. For an older version, see the same page under that
version's tag on GitHub (`https://github.com/joeMJ/audiojoe/tree/vX.Y.Z/docs`). The help pages
built into your server under `/docs/` always match the installed version.*

Which libraries handle requests that reach the audiojoe server through your HTTPS address (port
443), and which of them already do so **before** sign-in. Use it to judge a published
vulnerability: if it concerns a library in the first table, the part of audiojoe that anyone who
can reach your address can use is affected – update soon. A library that only works after sign-in
can only be reached with a valid sign-in.

Versions are not listed here; the exact ones are in `Cargo.lock` (server) and
`clients/web/package-lock.json` (web player) of the release you run.

## How a request arrives

```
device ── HTTPS 443 ──► your reverse proxy (TLS) ── HTTP ──► audiojoe-server (listen address)
```

- **TLS** is done by your reverse proxy, not by audiojoe. Vulnerabilities in TLS libraries
  (OpenSSL and the like) concern the proxy and must be fixed there.
- audiojoe-server itself only speaks HTTP and should only be reachable by the proxy.

## Before sign-in

Every request, also one without a valid sign-in, passes these libraries:

| Library | What it does there |
|---|---|
| `tokio` | network connections, runtime |
| `hyper` (inside `axum`) | reads the HTTP request (headers, body) |
| `axum` | routing, reading paths, query strings and JSON, body limit (64 KB) |
| `tower-http` | serves the static pages (web player, car test page), security headers |
| `serde`, `serde_json` | reads the JSON of the sign-in request |
| `sha2` | checksum of the access key sent along, to look it up |
| `rusqlite` (with SQLite built in) | looks up the sign-in in the database |

All paths that answer without sign-in, and what works there in addition:

| Path | Library | What it does there |
|---|---|---|
| `/`, `/testcar/` (static pages) | `tower-http` | delivers files of the web player and the car test page |
| `/api/v1/health` | `serde_json` | answers status and version |
| `/api/v1/auth/login` | `argon2` | checks the password |
| | `totp-rs` | checks the authenticator code |
| | `rand` | creates the access key after a successful sign-in |
| `/api/2/…`, `/subscriptions/…` (gpodder.net API) | `base64`, `argon2` | reads and checks the app password (HTTP Basic); without an app password these paths only answer "unauthorized" |
| `/docs/…` | `pulldown-cmark` | turns the built-in help pages into HTML; it only processes text built into the server, nothing from the request |

Also delivered without sign-in, but run in the **visitor's browser**, not on the server:

| Library | Where |
|---|---|
| `qrcode-generator` | car test page (`/testcar/`) |

The web player itself contains no third-party libraries.

## Only after sign-in

These libraries only work for requests with a valid sign-in, or in the server's own background
jobs (feed refresh, sync with Audiobookshelf). Their input mostly comes from the servers you
entered (sources, podcast feeds), not from the request:

| Library | What it does there |
|---|---|
| `reqwest` (with `rustls`) | all connections from the server to the outside: sources, feeds, Radio Browser, fyyd, MusicBrainz |
| `quick-xml`, `rss` | reads podcast feeds and imported OPML files |
| `ammonia` | cleans show notes before they are shown |
| `chrono` | dates of feeds and positions |
| `tokio-util` | relays audio streams and downloads |
| `ffmpeg` (separate program) | converts hi-res FLAC, only when a target cannot play it |

## Not over HTTPS

- **Sonos stream port** (only with the `[sonos]` section): a port of its own that should only be
  reachable in the home network. The speakers fetch the audio there with a signed address valid
  for 24 hours (`hmac`, `sha2`); this port must not be forwarded by the proxy.
- **Updates** (`audiojoe-update`): the server asks GitHub with `curl`; nothing comes in over 443.

## What follows from this

- A vulnerability in a library of the first section: update soon, even if only you use the server.
- A vulnerability in a library of the second section: only a signed-in user, or a source or feed
  you entered, can reach it.
- To keep the reachable part small, let the proxy forward only your audiojoe address, and let only
  the proxy reach the listen address of the server.
