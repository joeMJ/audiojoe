#!/usr/bin/env python3
"""cutproxy.py – TCP forwarder for connection-loss tests (only the standard library).

    tools/dev/cutproxy.py LISTEN_PORT TARGET_HOST:PORT CONTROL_PORT

Forwards LISTEN_PORT (127.0.0.1) to the target. On the control port (127.0.0.1):
  GET /hang     open connections stop moving data, new ones are accepted but get nothing
                (as with a dropped DSL line: no answer, no error)
  GET /refuse   open connections are closed, new ones are closed at once
  GET /restore  forwards again (connections that hung stay dead, as after a real outage)
  GET /state    the current mode
"""
import asyncio
import sys

mode = "open"
conns: set = set()


async def pipe(r: asyncio.StreamReader, w: asyncio.StreamWriter, tag: dict):
    try:
        while True:
            data = await r.read(65536)
            if not data:
                break
            # A hung connection never moves data again.
            while tag["hung"] or mode == "hang":
                tag["hung"] = True
                await asyncio.sleep(3600)
            w.write(data)
            await w.drain()
    except (ConnectionError, asyncio.CancelledError):
        pass
    finally:
        try:
            w.close()
        except Exception:
            pass


async def client(r: asyncio.StreamReader, w: asyncio.StreamWriter, target):
    if mode == "refuse":
        w.close()
        return
    tag = {"hung": mode == "hang"}
    if tag["hung"]:
        conns.add((w, None, tag))
        await asyncio.sleep(3600)
        return
    try:
        tr, tw = await asyncio.open_connection(*target)
    except OSError:
        w.close()
        return
    entry = (w, tw, tag)
    conns.add(entry)
    try:
        await asyncio.gather(pipe(r, tw, tag), pipe(tr, w, tag))
    finally:
        conns.discard(entry)


async def control(r: asyncio.StreamReader, w: asyncio.StreamWriter):
    global mode
    line = (await r.readline()).decode(errors="replace")
    path = line.split(" ")[1] if " " in line else "/"
    if path == "/hang":
        mode = "hang"
    elif path == "/refuse":
        mode = "refuse"
        for cw, tw, _ in list(conns):
            for x in (cw, tw):
                if x:
                    x.close()
        conns.clear()
    elif path == "/restore":
        mode = "open"
    body = mode.encode()
    w.write(b"HTTP/1.0 200 OK\r\nContent-Type: text/plain\r\nContent-Length: %d\r\n\r\n%s" % (len(body), body))
    await w.drain()
    w.close()


async def main():
    port, target, cport = int(sys.argv[1]), sys.argv[2].rsplit(":", 1), int(sys.argv[3])
    target = (target[0], int(target[1]))
    s1 = await asyncio.start_server(lambda r, w: client(r, w, target), "127.0.0.1", port)
    s2 = await asyncio.start_server(control, "127.0.0.1", cport)
    print(f"cutproxy 127.0.0.1:{port} → {target[0]}:{target[1]}, control 127.0.0.1:{cport}", flush=True)
    async with s1, s2:
        await asyncio.gather(s1.serve_forever(), s2.serve_forever())


asyncio.run(main())
