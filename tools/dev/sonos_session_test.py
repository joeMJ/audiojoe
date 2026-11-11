#!/usr/bin/env python3
"""Sonos sessions against a speaker that answers badly (tools/dev/fake_sonos.py on 127.0.0.1:1400).

A speaker on a weak network misses poll rounds while it plays on; that must not end the session.
A speaker that answers "stopped" ends it after 20 s, one that gives no answer at all after 120 s.

  BASE=http://127.0.0.1:8095 CRED=credentials.json DB=/path/audiojoe.db LOG=/path/server.log \
    python3 tools/dev/sonos_session_test.py [--old]

--old: counter-check with a server before the fix – only the "slow" case, which must end the session there.
Needs a test server of its own (its database gets the fake speaker): never the one other devices use.
"""

import base64
import hashlib
import hmac
import json
import os
import sqlite3
import struct
import sys
import time
import urllib.error
import urllib.request

BASE, DB, LOG = os.environ["BASE"], os.environ["DB"], os.environ["LOG"]
CRED = json.load(open(os.environ["CRED"]))
OLD = "--old" in sys.argv
FAKE = "http://127.0.0.1:1400/ctl"
failed = 0


def check(name, ok, detail=""):
    global failed
    print(f"{'✔' if ok else '✖'} {name}{' – ' + detail if detail else ''}", flush=True)
    failed += not ok


def totp(secret):
    k = base64.b32decode(secret.upper() + "=" * (-len(secret) % 8))
    m = hmac.new(k, struct.pack(">Q", int(time.time() // 30)), hashlib.sha1).digest()
    o = m[-1] & 15
    return "%06d" % ((struct.unpack(">I", m[o:o + 4])[0] & 0x7FFFFFFF) % 1000000)


token = None


def call(method, path, body=None):
    h = {"content-type": "application/json"}
    if token:
        h["authorization"] = "Bearer " + token
    r = urllib.request.Request(BASE + path, data=json.dumps(body).encode() if body is not None else None, method=method, headers=h)
    try:
        with urllib.request.urlopen(r, timeout=30) as x:
            c = x.read()
            return x.status, (json.loads(c) if c else None)
    except urllib.error.HTTPError as e:
        return e.code, e.read()[:200]


def mode(m):
    urllib.request.urlopen(f"{FAKE}?mode={m}", timeout=5).read()


def state(room):
    c = sqlite3.connect(f"file:{DB}?mode=ro", uri=True)
    try:
        r = c.execute("SELECT state FROM sonos_session WHERE room_id = ?", (room,)).fetchone()
        return r[0] if r else None
    finally:
        c.close()


def last_end():
    lines = [l for l in open(LOG, errors="replace") if "session ended" in l]
    return lines[-1].split("session ended", 1)[1].strip() if lines else ""


def play(room, key):
    mode("ok")
    s, b = call("POST", f"/api/v1/sonos/{room}/play", {"key": key, "position_ms": 0})
    t0 = time.time()
    while time.time() - t0 < 20 and state(room) != "playing":
        time.sleep(1)
    return s, state(room)


def hold(room, m, secs):
    """Speaker in mode m for secs seconds; returns after how many seconds the session ended (or None)."""
    mode(m)
    t0 = time.time()
    while time.time() - t0 < secs:
        if state(room) == "ended":
            return round(time.time() - t0)
        time.sleep(2)
    return None


s, b = call("POST", "/api/v1/auth/login", {"username": CRED["username"], "password": CRED["password"],
                                           "totp": totp(CRED["totp_secret"]), "device": "sonos-session-test"})
token = b["token"]
mode("ok")
s, b = call("POST", "/api/v1/sonos", {"ip": "127.0.0.1"})
check("fake speaker added", s == 200, str(b))
s, lst = call("GET", "/api/v1/sonos")
room = next(x["id"] for x in lst if x["ip"] == "127.0.0.1")
s, pb = call("GET", "/api/v1/playback?limit=20")
key = next(p["key"] for p in pb if not p["key"].startswith("radio:"))
s, st = play(room, key)
check("playback starts, session playing", s == 200 and st == "playing", f"{s} {st} {key}")

if OLD:
    end = hold(room, "slow", 60)
    check("old server: slow speaker ends the session (bug reproduced)", end is not None, f"after {end} s, {last_end()}")
else:
    end = hold(room, "flaky", 60)
    check("flaky speaker (every third round answers) for 60 s: session stays", end is None, f"ended after {end} s" if end else state(room))
    end = hold(room, "slow", 60)
    check("slow speaker (no full answer) for 60 s: session stays", end is None, f"ended after {end} s" if end else state(room))
    hold(room, "ok", 10)
    check("answers again: session playing", state(room) == "playing", state(room))
    end = hold(room, "stopped", 40)
    check("speaker answers as stopped: session ends after ~20 s", end is not None and 15 <= end <= 35 and "(stopped)" in last_end(),
          f"after {end} s, {last_end()}")
    s, st = play(room, key)
    check("playback starts again", s == 200 and st == "playing", f"{s} {st}")
    end = hold(room, "down", 160)
    check("speaker gone (no answer at all): session ends after ~120 s", end is not None and 115 <= end <= 145 and "(unreachable)" in last_end(),
          f"after {end} s, {last_end()}")

mode("ok")
call("POST", f"/api/v1/sonos/{room}/command", {"action": "stop"})
s, _ = call("DELETE", f"/api/v1/sonos/{room}")
check("fake speaker removed", s == 200, str(s))
call("POST", "/api/v1/auth/logout")
print(f"\n{failed} check(s) failed" if failed else "\nall checks passed")
sys.exit(1 if failed else 0)
