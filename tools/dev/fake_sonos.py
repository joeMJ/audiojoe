#!/usr/bin/env python3
"""A fake Sonos speaker for tests of the server's Sonos sessions (no sound, no real device).

Answers the UPnP/SOAP calls audiojoe-server makes on port 1400 and can be told to fail:

  GET /ctl?mode=ok        answers everything; plays what it was given
  GET /ctl?mode=stopped   answers, transport STOPPED
  GET /ctl?mode=slow      group topology answers, AVTransport/RenderingControl take 5 s (server timeout: 3 s)
  GET /ctl?mode=down      nothing answers in time
  GET /ctl?mode=flaky     like slow, but every third AVTransport round answers (a speaker on a weak network)
  GET /ctl                current mode and what was asked

  python3 tools/dev/fake_sonos.py [--host 127.0.0.1] [--name Fake]
"""

import argparse
import html
import json
import re
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

ap = argparse.ArgumentParser()
ap.add_argument("--host", default="127.0.0.1")
ap.add_argument("--name", default="Fake")
args = ap.parse_args()

UUID = "RINCON_FAKE0001"
lock = threading.Lock()
st = {"mode": "ok", "uri": "", "meta": "", "transport": "STOPPED", "since": 0.0, "offset": 0, "volume": 15,
      "sleep": "", "calls": {}, "avt_rounds": 0}


def rel_time():
    s = st["offset"] + (time.time() - st["since"] if st["transport"] == "PLAYING" else 0)
    s = int(max(0, s))
    return f"{s // 3600}:{s % 3600 // 60:02}:{s % 60:02}"


def answer(action, service, body=""):
    return (f'<?xml version="1.0"?><s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/">'
            f'<s:Body><u:{action}Response xmlns:u="{service}">{body}</u:{action}Response></s:Body></s:Envelope>')


def arg(xml, name):
    m = re.search(f"<{name}>(.*?)</{name}>", xml, re.S)
    return html.unescape(m.group(1)) if m else ""


class H(BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass

    def send(self, code, text, ctype="text/xml; charset=utf-8"):
        b = text.encode()
        self.send_response(code)
        self.send_header("content-type", ctype)
        self.send_header("content-length", str(len(b)))
        self.end_headers()
        self.wfile.write(b)

    def do_GET(self):
        if self.path.startswith("/ctl"):
            m = re.search(r"mode=(\w+)", self.path)
            with lock:
                if m:
                    st["mode"] = m.group(1)
                    st["avt_rounds"] = 0
                out = {k: v for k, v in st.items() if k != "meta"}
            return self.send(200, json.dumps(out), "application/json")
        if self.path == "/xml/device_description.xml":
            if st["mode"] == "down":
                time.sleep(5)
            return self.send(200, f"<root><device><roomName>{args.name}</roomName><UDN>uuid:{UUID}</UDN>"
                                  f"<modelName>Fake One</modelName><softwareVersion>80.1-0</softwareVersion></device></root>")
        self.send(404, "")

    def do_POST(self):
        body = self.rfile.read(int(self.headers.get("content-length", 0))).decode()
        soapaction = self.headers.get("soapaction", "").strip('"')
        service, _, action = soapaction.partition("#")
        with lock:
            st["calls"][action] = st["calls"].get(action, 0) + 1
            mode = st["mode"]
            if action == "GetPositionInfo":
                st["avt_rounds"] += 1
            rounds = st["avt_rounds"]
        topology = self.path.startswith("/ZoneGroupTopology")
        if mode == "down" or (mode in ("slow", "flaky") and not topology and not (mode == "flaky" and rounds % 3 == 0)):
            time.sleep(5)
            return
        with lock:
            if action == "GetZoneGroupState":
                groups = (f'<ZoneGroups><ZoneGroup Coordinator="{UUID}" ID="{UUID}:1"><ZoneGroupMember UUID="{UUID}" '
                          f'Location="http://{args.host}:1400/xml/device_description.xml" ZoneName="{args.name}"/></ZoneGroup></ZoneGroups>')
                return self.send(200, answer(action, service, f"<ZoneGroupState>{html.escape(groups)}</ZoneGroupState>"))
            if action == "SetAVTransportURI":
                st.update(uri=arg(body, "CurrentURI"), meta=arg(body, "CurrentURIMetaData"), transport="STOPPED", offset=0)
            elif action == "Play":
                st.update(transport="PLAYING", since=time.time())
            elif action == "Pause":
                st["offset"] = int(time.time() - st["since"]) + st["offset"] if st["transport"] == "PLAYING" else st["offset"]
                st["transport"] = "PAUSED_PLAYBACK"
            elif action == "Stop":
                st.update(transport="STOPPED", offset=0)
            elif action == "SetVolume":
                st["volume"] = int(arg(body, "DesiredVolume") or 0)
            elif action == "ConfigureSleepTimer":
                st["sleep"] = arg(body, "NewSleepTimerDuration")
            transport = "STOPPED" if mode == "stopped" else st["transport"]
            replies = {
                "GetTransportInfo": f"<CurrentTransportState>{transport}</CurrentTransportState>"
                                    "<CurrentTransportStatus>OK</CurrentTransportStatus><CurrentSpeed>1</CurrentSpeed>",
                "GetPositionInfo": f"<Track>1</Track><TrackDuration>0:05:00</TrackDuration><TrackMetaData>{html.escape(st['meta'])}</TrackMetaData>"
                                   f"<TrackURI>{html.escape(st['uri'])}</TrackURI><RelTime>{rel_time()}</RelTime>",
                "GetVolume": f"<CurrentVolume>{st['volume']}</CurrentVolume>",
                "GetGroupVolume": f"<CurrentVolume>{st['volume']}</CurrentVolume>",
                "GetRemainingSleepTimerDuration": f"<RemainingSleepTimerDuration>{st['sleep']}</RemainingSleepTimerDuration>"
                                                  "<CurrentSleepTimerGeneration>1</CurrentSleepTimerGeneration>",
            }
        self.send(200, answer(action, service, replies.get(action, "")))


ThreadingHTTPServer((args.host, 1400), H).serve_forever()
