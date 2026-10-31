#!/usr/bin/env python3
"""End-to-end test of the audiojoe API (stage 1), standard library only.

    tools/dev/e2e.py BASE_URL CREDENTIALS_JSON

CREDENTIALS_JSON: {"username": ..., "password": ..., "totp_secret": ...} of a test user.
Optional environment: JELLYFIN_URL, JELLYFIN_API_KEY (adds and tests a Jellyfin source),
EMBY_TEST_FILE (JSON with url and api_key), PLEX_URL and PLEX_TOKEN (adds and tests these
sources; a test server should hold at least one hi-res FLAC), E2E_FEED (podcast feed URL,
default: Lage der Nation).
The rate-limit check runs last because it blocks logins from this address for 15 minutes.
"""

import base64, hashlib, hmac, json, os, struct, sys, threading, time
import urllib.error, urllib.request
from datetime import datetime, timedelta, timezone

BASE = sys.argv[1].rstrip("/")
CRED = json.load(open(sys.argv[2]))
FEED = os.environ.get("E2E_FEED", "https://feeds.lagedernation.org/feeds/ldn-mp3.xml")
failed = 0


def check(name, cond, detail=""):
    global failed
    print(("✔ " if cond else "✖ ") + name + (f" – {detail}" if detail else ""), flush=True)
    if not cond:
        failed += 1


def totp(secret, t=None):
    key = base64.b32decode(secret + "=" * (-len(secret) % 8))
    counter = int((t or time.time()) // 30)
    h = hmac.new(key, struct.pack(">Q", counter), hashlib.sha1).digest()
    o = h[-1] & 15
    return "%06d" % ((struct.unpack(">I", h[o:o + 4])[0] & 0x7FFFFFFF) % 1000000)


def call(method, path, body=None, token=None, headers=None, raw=False):
    h = {"accept": "application/json", **(headers or {})}
    data = None
    if body is not None:
        data = json.dumps(body).encode()
        h["content-type"] = "application/json"
    if token:
        h["authorization"] = "Bearer " + token
    req = urllib.request.Request(BASE + path, data=data, method=method, headers=h)
    try:
        with urllib.request.urlopen(req, timeout=60) as r:
            content = r.read() if raw else r.read()
            return r.status, (content if raw else (json.loads(content) if content else None)), dict(r.headers)
    except urllib.error.HTTPError as e:
        content = e.read()
        try:
            content = json.loads(content)
        except Exception:
            pass
        return e.code, content, dict(e.headers)


def wait_next_step():
    time.sleep(30 - time.time() % 30 + 1)


def login(device, code=None):
    return call("POST", "/api/v1/auth/login", {
        "username": CRED["username"], "password": CRED["password"],
        "totp": code or totp(CRED["totp_secret"]), "device": device})


# ------------------------------------------------------------------ authentication
s, b, _ = call("GET", "/api/v1/me")
check("without login: 401", s == 401, str(s))
s, _, _ = call("POST", "/api/v1/auth/login", {"username": CRED["username"], "password": "wrong-password",
                                                  "totp": totp(CRED["totp_secret"]), "device": "e2e"})
check("wrong password: 401", s == 401, str(s))
s, _, _ = call("POST", "/api/v1/auth/login", {"username": CRED["username"], "password": CRED["password"],
                                                  "totp": "000000", "device": "e2e"})
check("wrong TOTP: 401", s == 401, str(s))

wait_next_step()
code = totp(CRED["totp_secret"])
s, b, h = login("e2e-phone", code)
check("login device A", s == 200 and b.get("token"), str(s))
A = b["token"]
check("session cookie is HttpOnly, Secure, SameSite=Strict",
      all(x in h.get("set-cookie", h.get("Set-Cookie", "")) for x in ("HttpOnly", "Secure", "SameSite=Strict")))
s, _, _ = login("e2e-replay", code)
check("same TOTP code twice: 401 (replay)", s == 401, str(s))
s, b, _ = call("GET", "/api/v1/me", token=A)
check("/me", s == 200 and b["user"] == CRED["username"] and b["device"] == "e2e-phone", json.dumps(b))

wait_next_step()
s, b, _ = login("e2e-tesla")
check("login device B", s == 200, str(s))
B = b["token"]

s, b, _ = call("GET", "/api/v1/sessions", token=A)
check("device list with current session", s == 200 and any(x["current"] and x["device"] == "e2e-phone" for x in b), f"{len(b)} sessions")
sid_b = next(x["id"] for x in b if x["device"] == "e2e-tesla")

# ------------------------------------------------------------------ podcasts
s, b, _ = call("GET", "/api/v1/podcasts/search?q=lage%20der%20nation", token=A)
check("podcast search", s == 200 and any("lagedernation" in x["feed_url"] for x in b), f"{len(b)} results")
s, b, _ = call("POST", "/api/v1/podcasts", {"feed_url": FEED}, token=A)
check("subscribe podcast", s == 200 and b["episodes"] > 0, f"{b.get('title') if isinstance(b, dict) else b}, {b.get('episodes') if isinstance(b, dict) else ''} episodes")
pid = b["id"]
s, _, _ = call("POST", f"/api/v1/podcasts/{pid}/refresh", token=A)
check("refresh feed", s == 200, str(s))
s, b, _ = call("POST", "/api/v1/podcasts", {"feed_url": "https://example.invalid/feed.xml"}, token=A)
check("invalid feed rejected", s == 502, str(s))
s, eps, _ = call("GET", f"/api/v1/podcasts/{pid}/episodes?limit=5", token=A)
check("episodes", s == 200 and len(eps) == 5 and eps[0]["published"], eps[0]["title"] if eps else "")
s, latest, _ = call("GET", "/api/v1/episodes/latest?limit=3", token=B)
check("latest episodes (device B)", s == 200 and len(latest) == 3)
ep = eps[0]
s, item, _ = call("GET", f"/api/v1/items/{ep['key']}", token=A)
check("episode item with quality", s == 200 and item["quality"]["codec"] == "mp3", json.dumps(item["quality"]))
check("episode description and cover", item.get("description") and item.get("image"),
      f"{len(item.get('description') or '')} chars, {item.get('image')}")
if item.get("image"):
    s, img, h = call("GET", item["image"], token=A, raw=True)
    check("episode cover relayed as image", s == 200 and h.get("content-type", h.get("Content-Type", "")).startswith("image/"), str(s))
s, pods, _ = call("GET", "/api/v1/podcasts", token=A)
pod = next((x for x in pods if x["id"] == pid), {}) if s == 200 else {}
check("podcast description and cover", pod.get("description") and pod.get("image"), pod.get("image") or "")
s, _, _ = call("GET", "/api/v1/image/podcast:999999", token=A, raw=True)
check("cover of unsubscribed podcast: 404", s == 404, str(s))


def post_text(path, text, token):
    req = urllib.request.Request(BASE + path, data=text.encode(), method="POST",
                                 headers={"content-type": "text/x-opml", "authorization": "Bearer " + token})
    try:
        with urllib.request.urlopen(req, timeout=120) as r:
            return r.status, json.loads(r.read())
    except urllib.error.HTTPError as e:
        return e.code, e.read()


s, opml, h = call("GET", "/api/v1/podcasts/opml", token=A, raw=True)
check("OPML export", s == 200 and FEED.encode() in opml and b"<opml" in opml, f"{len(opml)} B")
s, b = post_text("/api/v1/podcasts/opml", opml.decode().replace(
    "</body>", '<outline type="rss" text="kaputt" xmlUrl="https://example.invalid/feed.xml"/></body>'), A)
check("OPML import: known feed kept, broken feed listed",
      s == 200 and b["added"] == 0 and b["existing"] >= 1 and [f["feed_url"] for f in b["failed"]] == ["https://example.invalid/feed.xml"],
      json.dumps(b)[:200])
s, _ = post_text("/api/v1/podcasts/opml", "kein xml <", A)
check("OPML import of garbage: 400", s == 400, str(s))
s, data, h = call("GET", f"/api/v1/stream/{ep['key']}", token=A, headers={"range": "bytes=0-9999"}, raw=True)
q = json.loads(h.get("x-audiojoe-quality", h.get("X-Audiojoe-Quality", "null")))
check("episode stream with Range: 206", s == 206 and len(data) == 10000, f"{s}, {len(data)} B")
check("quality header", q and q["transcoded"] is False and q["delivered"]["codec"] == "mp3")
s, _, _ = call("GET", f"/api/v1/stream/{ep['key']}")
check("stream without login: 401", s == 401, str(s))

# ------------------------------------------------------------------ playback sync + events
events = []


def listen():
    req = urllib.request.Request(BASE + "/api/v1/events", headers={"authorization": "Bearer " + B})
    try:
        with urllib.request.urlopen(req, timeout=20) as r:
            for line in r:
                line = line.decode().strip()
                if line.startswith("data:"):
                    events.append((time.time(), json.loads(line[5:])))
    except Exception:
        pass


threading.Thread(target=listen, daemon=True).start()
time.sleep(1.5)
now = datetime.now(timezone.utc)
iso = lambda t: t.isoformat().replace("+00:00", "Z")
t0 = time.time()
s, b, _ = call("PUT", f"/api/v1/playback/{ep['key']}", {
    "position_ms": 842000, "duration_ms": ep["duration_ms"], "updated_at": iso(now),
    "title": ep["title"], "subtitle": ep["podcast"]}, token=A)
check("device A saves position 14:02", s == 200 and b["applied"], json.dumps(b.get("state", b))[:120])
time.sleep(1.5)
ev = [e for e in events if e[1]["state"]["key"] == ep["key"]]
check("device B receives the change live (SSE)", bool(ev) and ev[0][1]["state"]["position_ms"] == 842000,
      f"after {ev[0][0] - t0:.2f} s, from {ev[0][1]['state']['device']}" if ev else "no event")
s, b, _ = call("GET", f"/api/v1/playback/{ep['key']}", token=B)
check("device B reads position", s == 200 and b["position_ms"] == 842000 and b["device"] == "e2e-phone")
s, b, _ = call("PUT", f"/api/v1/playback/{ep['key']}", {"position_ms": 100000, "updated_at": iso(now - timedelta(minutes=5))}, token=B)
check("older offline position does not overwrite", s == 200 and not b["applied"] and b["state"]["position_ms"] == 842000)
s, b, _ = call("PUT", f"/api/v1/playback/{ep['key']}", {"position_ms": 900000, "updated_at": iso(now + timedelta(days=1))}, token=B)
check("future timestamp is clamped", s == 200 and b["applied"] and b["state"]["updated_at"] < iso(now + timedelta(minutes=1)))
s, b, _ = call("POST", "/api/v1/playback", [
    {"key": eps[1]["key"], "position_ms": 1000, "updated_at": iso(now), "title": eps[1]["title"]},
    {"key": eps[2]["key"], "position_ms": 2000, "updated_at": iso(now), "finished": True}], token=B)
check("bulk sync of buffered positions", s == 200 and all(x["applied"] for x in b))
s, b, _ = call("GET", "/api/v1/playback?unfinished=true", token=A)
keys = [x["key"] for x in b] if s == 200 else []
check("continue listening: unfinished only", eps[1]["key"] in keys and ep["key"] in keys and eps[2]["key"] not in keys, str(keys[:3]))
s, b, _ = call("GET", f"/api/v1/podcasts/{pid}/episodes?limit=3", token=A)
check("episode list shows position", s == 200 and b[0]["position_ms"] == 900000)

# ------------------------------------------------------------------ internet radio
s, st, _ = call("GET", "/api/v1/radio/search?q=deutschlandfunk", token=A)
if not isinstance(st, list):  # directory unreachable: report, do not crash
    st = []
check("radio search", s == 200 and len(st) > 0, f"{s}, {len(st)} stations, first: {st[0]['title'] if st else ''}")
if st:
    r0 = st[0]
    s, _, _ = call("PUT", f"/api/v1/radio/favorites/{r0['key'][6:]}", token=A)
    s2, fav, _ = call("GET", "/api/v1/radio/favorites", token=B)
    check("radio favourite", s == 200 and any(f["key"] == r0["key"] and f["favorite"] for f in fav))
    s, meta, _ = call("GET", f"/api/v1/items/{r0['key']}", token=A)
    check("radio item with quality", s == 200 and meta["kind"] == "radio", json.dumps(meta.get("quality")))
    req = urllib.request.Request(BASE + f"/api/v1/stream/{r0['key']}", headers={"authorization": "Bearer " + A})
    try:
        with urllib.request.urlopen(req, timeout=20) as r:
            chunk = r.read(32768)
            check("live radio stream relayed", r.status == 200 and len(chunk) == 32768, f"{r.headers.get('content-type')}, {len(chunk)} B")
    except Exception as e:
        check("live radio stream relayed", False, str(e))
    s, _, _ = call("GET", f"/api/v1/stream/{r0['key']}?profile=tesla-offline", token=A)
    check("radio cannot be saved offline", s == 400, str(s))
    s, _, _ = call("GET", f"/api/v1/image/{r0['key']}", token=A, raw=True)
    check("station logo relayed (or none)", s in (200, 404), str(s))
    call("DELETE", f"/api/v1/radio/favorites/{r0['key'][6:]}", token=A)

# ------------------------------------------------------------------ sonos (silent: nothing is played)
if os.environ.get("SONOS_DB"):
    import sqlite3
    s, found, _ = call("POST", "/api/v1/sonos/scan", token=A)
    check("sonos scan (configured range, unicast)", s == 200, ", ".join(f"{x['name']} {x['ip']} {'S2' if x['s2'] else 'S1'}" for x in found) if s == 200 else str(found))
    s, sps, _ = call("GET", "/api/v1/sonos", token=A)
    check("sonos status read", s == 200 and any(x["reachable"] for x in sps),
          "; ".join(f"{x['name']}: {x.get('state')} vol {x.get('volume')}" for x in sps if x["reachable"]))
    # Signed LAN stream URL, as a speaker would fetch it.
    secret = sqlite3.connect(os.environ["SONOS_DB"]).execute("SELECT value FROM setting WHERE name='sonos_secret'").fetchone()[0].encode()
    b64 = lambda b: base64.urlsafe_b64encode(b).rstrip(b"=").decode()
    claim = {"user": 1, "key": ep["key"], "part": None, "offset_ms": 0, "profile": "sonos-s2", "exp": int(time.time()) + 60, "room": "Test"}
    me = call("GET", "/api/v1/me", token=A)[1]
    uid = sqlite3.connect(os.environ["SONOS_DB"]).execute("SELECT id FROM user WHERE name=?", (me["user"],)).fetchone()[0]
    claim["user"] = uid
    payload = b64(json.dumps(claim).encode())
    token = payload + "." + b64(hmac.new(secret, payload.encode(), hashlib.sha256).digest())
    lan = os.environ.get("SONOS_LAN", "http://127.0.0.1:8081")
    req = urllib.request.Request(f"{lan}/sonos/{token}", headers={"range": "bytes=0-4095"})
    try:
        with urllib.request.urlopen(req, timeout=20) as r:
            check("LAN stream with signed URL (Range)", r.status == 206 and len(r.read()) == 4096, str(r.status))
    except Exception as e:
        check("LAN stream with signed URL (Range)", False, str(e))
    try:
        urllib.request.urlopen(f"{lan}/sonos/{payload}.{b64(b'x' * 32)}", timeout=10)
        check("LAN stream rejects a forged signature", False)
    except urllib.error.HTTPError as e:
        check("LAN stream rejects a forged signature", e.code == 403, str(e.code))
    try:
        urllib.request.urlopen(f"{lan}/api/v1/health", timeout=10)
        check("LAN port serves no API", False)
    except urllib.error.HTTPError as e:
        check("LAN port serves no API", e.code == 404, str(e.code))

# ------------------------------------------------------------------ jellyfin
if os.environ.get("JELLYFIN_URL"):
    s, b, _ = call("POST", "/api/v1/sources", {"kind": "jellyfin", "name": "Jellyfin (e2e)",
                                               "url": os.environ["JELLYFIN_URL"], "api_key": "wrong"}, token=A)
    check("jellyfin with wrong key rejected", s == 502, str(s))
    s, b, _ = call("POST", "/api/v1/sources", {"kind": "jellyfin", "name": "Jellyfin (e2e)",
                                               "url": os.environ["JELLYFIN_URL"], "api_key": os.environ["JELLYFIN_API_KEY"]}, token=A)
    check("add jellyfin source", s == 200, f"version {b.get('version')}" if s == 200 else str(b))
    sid = b["id"]
    s, srcs, _ = call("GET", "/api/v1/sources", token=A)
    check("source list contains no secret", s == 200 and all("secret" not in x and "api_key" not in x for x in srcs))
    s, root, _ = call("GET", f"/api/v1/sources/{sid}/browse", token=A)
    views = root.get("items", []) if s == 200 else []
    check("jellyfin libraries", s == 200 and views, ", ".join(v["title"] for v in views))
    tracks, hires = [], None
    for view in views:
        s, albums, _ = call("GET", f"/api/v1/sources/{sid}/browse?parent={view['key'].split(':')[2]}&limit=40", token=A)
        for album in [a for a in albums.get("items", []) if a["kind"] in ("album", "folder")][:40]:
            s, t, _ = call("GET", f"/api/v1/sources/{sid}/browse?parent={album['key'].split(':')[2]}&limit=5", token=A)
            for tr in [x for x in t.get("items", []) if x["kind"] == "track"]:
                tracks.append(tr)
                qq = tr.get("quality") or {}
                if not hires and qq.get("codec") == "flac" and (qq.get("sample_rate") or 0) > 48000:
                    hires = tr
            if hires and len(tracks) > 3:
                break
        if hires:
            break
    check("jellyfin tracks found", bool(tracks), f"{len(tracks)} tracks")
    if tracks:
        tr = tracks[0]
        s, item, _ = call("GET", f"/api/v1/items/{tr['key']}", token=A)
        check("track item with quality", s == 200 and item["quality"] and item["quality"]["codec"], json.dumps(item.get("quality")))
        s, data, h = call("GET", f"/api/v1/stream/{tr['key']}", token=A, headers={"range": "bytes=0-65535"}, raw=True)
        check("jellyfin stream with Range: 206", s == 206 and len(data) == 65536, f"{s}, {len(data)} B")
        s, _, _ = call("GET", f"/api/v1/image/{tr['key']}", token=A, raw=True)
        check("cover image relayed (or none)", s in (200, 404), str(s))
    if hires:
        q = hires["quality"]
        req = urllib.request.Request(BASE + f"/api/v1/stream/{hires['key']}?profile=tesla-offline",
                                     headers={"authorization": "Bearer " + A})
        with urllib.request.urlopen(req, timeout=60) as r:
            head = r.read(65536)
            qh = json.loads(r.headers.get("x-audiojoe-quality"))
        check("hi-res FLAC → 48 kHz for Tesla offline", head[:4] == b"fLaC" and qh["transcoded"] and qh["delivered"]["sample_rate"] == 48000,
              f"source {q['bit_depth']}/{q['sample_rate']} → {qh['delivered']['bit_depth']}/{qh['delivered']['sample_rate']}")
    else:
        print("  (no hi-res FLAC found in the first albums – conversion not tested against Jellyfin)")
    s, _, _ = call("DELETE", f"/api/v1/sources/{sid}", token=A)
    check("remove jellyfin source", s == 200)
else:
    print("  (JELLYFIN_URL not set – Jellyfin not tested)")

# ------------------------------------------------------------------ emby, plex
def media_server(kind, url, key):
    s, b, _ = call("POST", "/api/v1/sources", {"kind": kind, "name": f"{kind} (e2e)", "url": url, "api_key": key}, token=A)
    check(f"add {kind} source", s == 200, f"version {b.get('version')}" if s == 200 else str(b))
    if s != 200:
        return
    sid = b["id"]
    tracks, todo = [], [None]
    while todo and len(tracks) < 20:
        parent = todo.pop(0)
        s, b, _ = call("GET", f"/api/v1/sources/{sid}/browse" + (f"?parent={parent}" if parent else ""), token=A)
        for it in b.get("items", []) if s == 200 else []:
            (tracks.append(it) if it["kind"] == "track" else todo.append(it["key"].split(":", 2)[2]))
    check(f"{kind} tracks found", bool(tracks), f"{len(tracks)} tracks")
    hires = None
    for tr in tracks:
        s, item, _ = call("GET", f"/api/v1/items/{tr['key']}", token=A)
        q = item.get("quality") or {} if s == 200 else {}
        if q.get("codec") == "flac" and (q.get("sample_rate") or 0) > 48000:
            hires = tr
    if tracks:
        s, data, _ = call("GET", f"/api/v1/stream/{tracks[0]['key']}", token=A, headers={"range": "bytes=1000-1999"}, raw=True)
        check(f"{kind} stream with Range: 206", s == 206 and len(data) == 1000, f"{s}, {len(data)} B")
    if hires:
        req = urllib.request.Request(BASE + f"/api/v1/stream/{hires['key']}?profile=tesla-offline", headers={"authorization": "Bearer " + A})
        with urllib.request.urlopen(req, timeout=60) as r:
            head = r.read(65536)
            qh = json.loads(r.headers.get("x-audiojoe-quality"))
        check(f"{kind} hi-res FLAC → 48 kHz", head[:4] == b"fLaC" and qh["delivered"]["sample_rate"] == 48000)
    s, _, _ = call("DELETE", f"/api/v1/sources/{sid}", token=A)
    check(f"remove {kind} source", s == 200)


if os.environ.get("EMBY_TEST_FILE"):
    em = json.load(open(os.environ["EMBY_TEST_FILE"]))
    media_server("emby", em["url"], em["api_key"])
else:
    print("  (EMBY_TEST_FILE not set – Emby not tested)")
if os.environ.get("PLEX_URL"):
    media_server("plex", os.environ["PLEX_URL"], os.environ.get("PLEX_TOKEN", "unclaimed"))
else:
    print("  (PLEX_URL not set – Plex not tested)")

# ------------------------------------------------------------------ audiobookshelf
if os.environ.get("ABS_TEST_FILE"):
    absc = json.load(open(os.environ["ABS_TEST_FILE"]))

    def abs_call(method, path, body=None):
        req = urllib.request.Request(absc["url"] + path, method=method,
                                     data=json.dumps(body).encode() if body is not None else None,
                                     headers={"authorization": "Bearer " + absc["api_key"], "content-type": "application/json"})
        try:
            with urllib.request.urlopen(req, timeout=30) as r:
                c = r.read()
                return r.status, (json.loads(c) if c and c[:1] in b"{[" else None)
        except urllib.error.HTTPError as e:
            return e.code, None

    s, b, _ = call("POST", "/api/v1/sources", {"kind": "audiobookshelf", "name": "falsch",
                                               "url": absc["url"], "api_key": "kein-gueltiger-schluessel"}, token=A)
    check("audiobookshelf with wrong key: 400 with reason", s == 400 and "API key" in str(b.get("error")), str(b))
    s, b, _ = call("POST", "/api/v1/sources", {"kind": "audiobookshelf", "name": "Audiobookshelf (e2e)",
                                               "url": absc["url"], "api_key": absc["api_key"]}, token=A)
    check("add audiobookshelf source", s == 200, f"{b.get('server')} {b.get('version')}" if s == 200 else str(b))
    aid = b["id"]
    s, libs, _ = call("GET", f"/api/v1/sources/{aid}/browse", token=A)
    check("audiobookshelf libraries", s == 200 and libs["items"], ", ".join(l["title"] for l in libs.get("items", [])))
    lib = libs["items"][0]["key"].split(":")[2]
    s, books, _ = call("GET", f"/api/v1/sources/{aid}/browse?parent={lib}&limit=20", token=A)
    check("books listed", s == 200 and books["items"], f"{len(books.get('items', []))} books")
    multi = None
    for bk in books["items"]:
        s, meta, _ = call("GET", f"/api/v1/items/{bk['key']}", token=A)
        if s == 200 and multi is None and len(meta.get("parts", [])) > 1:
            multi = meta
        if s == 200 and len(meta.get("parts", [])) >= 1 and meta.get("chapters"):
            book = meta
            break
    else:
        book = meta
    check("book with parts, chapters, quality", book.get("parts") and book.get("quality", {}).get("codec"),
          f"{book['title']}: {len(book['parts'])} part(s), {len(book.get('chapters', []))} chapters, {book['quality']['codec']}")
    s, data, h = call("GET", f"/api/v1/stream/{book['key']}?part=0", token=A, headers={"range": "bytes=0-32767"}, raw=True)
    check("book stream part 0 with Range: 206", s == 206 and len(data) == 32768, f"{s}, {len(data)} B")
    s, _, _ = call("GET", f"/api/v1/image/{book['key']}", token=A, raw=True)
    check("book cover relayed", s == 200, str(s))
    check("book description", "description" in book, f"{len(book.get('description') or '')} chars")
    item_id = book["key"].split(":")[2]

    # audiojoe -> Audiobookshelf
    s, b, _ = call("PUT", f"/api/v1/playback/{book['key']}", {"position_ms": 123000, "duration_ms": book["duration_ms"],
                    "updated_at": iso(datetime.now(timezone.utc)), "title": book["title"], "subtitle": book["subtitle"]}, token=A)
    time.sleep(3)
    s, prog = abs_call("GET", f"/api/me/progress/{item_id}")
    check("position pushed to Audiobookshelf", s == 200 and abs(prog["currentTime"] - 123) < 1.5, f"{prog and prog['currentTime']} s")

    # Audiobookshelf -> audiojoe (pull when the item is opened)
    time.sleep(1.2)
    abs_call("PATCH", f"/api/me/progress/{item_id}", {"currentTime": 456.0, "duration": book["duration_ms"] / 1000, "isFinished": False})
    s, meta, _ = call("GET", f"/api/v1/items/{book['key']}", token=A)
    s, pb, _ = call("GET", f"/api/v1/playback/{book['key']}", token=A)
    check("position from Audiobookshelf taken over", s == 200 and pb["position_ms"] == 456000 and pb["device"] == "Audiobookshelf",
          f"{pb.get('position_ms')} ms from {pb.get('device')}")

    # no ping-pong: an unchanged state is not written back
    s, before = abs_call("GET", f"/api/me/progress/{item_id}")
    call("GET", f"/api/v1/items/{book['key']}", token=A)
    time.sleep(1)
    s, after = abs_call("GET", f"/api/me/progress/{item_id}")
    check("unchanged state not written back", before["lastUpdate"] == after["lastUpdate"])

    abs_call("DELETE", f"/api/me/progress/{item_id}")
    call("DELETE", f"/api/v1/sources/{aid}", token=A)
    s, b, _ = call("GET", "/api/v1/playback", token=A)
    check("removing a source removes its positions", s == 200 and not any(x["key"].startswith(f"abs:{aid}:") for x in b))
else:
    print("  (ABS_TEST_FILE not set – Audiobookshelf not tested)")

# ------------------------------------------------------------------ cleanup, logout
s, _, _ = call("DELETE", f"/api/v1/sessions/{sid_b}", token=A)
s2, _, _ = call("GET", "/api/v1/me", token=B)
check("sign out another device", s == 200 and s2 == 401, f"{s}/{s2}")
call("DELETE", f"/api/v1/podcasts/{pid}", token=A)
s, b, _ = call("GET", "/api/v1/playback", token=A)
check("unsubscribe removes its positions", s == 200 and not any(x["key"] in {e["key"] for e in eps} for x in b), str(len(b)))
s, _, _ = call("POST", "/api/v1/auth/logout", token=A)
s2, _, _ = call("GET", "/api/v1/me", token=A)
check("logout ends the session", s == 200 and s2 == 401, f"{s}/{s2}")


# ------------------------------------------------------------------ throttling (last)
codes = [call("POST", "/api/v1/auth/login", {"username": "ghost-e2e", "password": "x" * 12, "totp": "123456", "device": "e2e"})[0]
         for _ in range(6)]
check("6th failed login: 429", codes[:5] == [401] * 5 and codes[5] == 429, str(codes))

print(f"\n{failed} check(s) failed" if failed else "\nall checks passed")
sys.exit(1 if failed else 0)
