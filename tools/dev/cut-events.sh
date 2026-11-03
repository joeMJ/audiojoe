#!/bin/bash
# cut-events.sh – for integration_test/sonos_test.dart: run as root on the server host with the
# test log as argument. Waits for "CUT" in the log, then kills the server side of the app's event
# stream while dropping the reset to the app (nftables), so the app sees a stream that died without
# notice and must reconnect by itself.
#
#   tools/dev/cut-events.sh /tmp/sonos-test.log
LOG=$1
until grep -q " CUT" "$LOG" 2>/dev/null; do sleep 1; done
date +%T
ss -tnpi state established "( dport = :8080 )" > /root/cut-ss.txt
cat /root/cut-ss.txt
# the client socket that sent longest ago (the event stream only receives)
P=$(python3 -I - <<"PY"
import re
t = open("/root/cut-ss.txt").read().split("\n")
best = None
for i, l in enumerate(t):
    m = re.search(r":(\d+)\s+\S+:8080\s+users:\(\(\"([^\"]+)\"", l)
    if not m or m.group(2).startswith("audiojoe-serv") or m.group(2) == "python3": continue
    info = t[i + 1] if i + 1 < len(t) else ""
    s = re.search(r"lastsnd:(\d+)", info); r = re.search(r"lastrcv:(\d+)", info)
    if s and r and int(r.group(1)) < 20000 and (best is None or int(s.group(1)) > best[1]): best = (m.group(1), int(s.group(1)))
print(best[0] if best else "")
PY
)
echo "port=$P"
[ -n "$P" ] || exit 1
nft add table inet audiojoe_cut
nft add chain inet audiojoe_cut out "{ type filter hook output priority -10; }"
nft add rule inet audiojoe_cut out tcp sport 8080 tcp dport $P drop
nft add rule inet audiojoe_cut out tcp sport $P tcp dport 8080 drop
ss -K state established "( sport = :8080 and dport = :$P )" | tail -n +2
sleep 5
nft delete table inet audiojoe_cut
echo "cut done $(date +%T)"; ss -tn "( sport = :$P or dport = :$P )"
