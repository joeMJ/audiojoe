#!/usr/bin/env bash
# fastseek-test-linux.sh – Linux app: how long is it silent when an MP3 without a seek index is played
# from a late position? Runs integration_test/fastseek_test.dart under Xvfb with a silent PulseAudio
# sink, records that sink and reports the time from play() to the first sound. Run as the build user
# in clients/app.
#
#   tools/dev/fastseek-test-linux.sh [START_SECONDS] [MAX_SILENCE_SECONDS] [URL]
#   NO_FASTSEEK=1 tools/dev/fastseek-test-linux.sh …   counter-test without the fix
# Also prints libmpv's "playback restart" time, the measurement used where nothing can be recorded
# (Windows VM without a sound card); both should agree.
set -uo pipefail
START="${1:-3600}"
MAX="${2:-8}"
URL="${3:-https://dts.podtrac.com/redirect.mp3/files.lagedernation.org/lagedernation/LdN501.mp3}"
export PATH=/opt/flutter/bin:$PATH
export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/tmp/xdg-$(id -u)}"
[[ -O "$XDG_RUNTIME_DIR" ]] || export XDG_RUNTIME_DIR="/tmp/xdg-$(id -u)"
mkdir -p -m 700 "$XDG_RUNTIME_DIR"
work=$(mktemp -d)
trap 'kill $rec 2>/dev/null; rm -rf "$work"' EXIT

pulseaudio --check 2>/dev/null || pulseaudio --start --exit-idle-time=-1 --daemonize=yes \
    --load="module-null-sink sink_name=silent" 2>/dev/null
pactl set-default-sink silent 2>/dev/null || true

# Record what the app plays: 8 kHz mono, 16 bit; the start time lets the samples be matched to play().
date +%s%3N > "$work/rec-start"
parec -d silent.monitor --format=s16le --rate=8000 --channels=1 > "$work/rec.raw" &
rec=$!

xvfb-run -a -s "-screen 0 1280x800x24" flutter test integration_test/fastseek_test.dart -d linux \
    --dart-define=START="$START" --dart-define=URL="$URL" \
    ${NO_FASTSEEK:+--dart-define=AUDIOJOE_NO_FASTSEEK=true} > "$work/test.log" 2>&1
kill $rec 2>/dev/null

python3 -I - "$work" "$MAX" <<'EOF'
import re, struct, sys
work, limit = sys.argv[1], float(sys.argv[2])
log = open(f"{work}/test.log", encoding="utf-8", errors="replace").read()
m = re.search(r"FASTSEEK play at (\d+)", log)
pos = re.search(r"FASTSEEK position (\S+)", log)
for line in re.findall(r"FASTSEEK (?:mpv restart|restart).*", log):
    print(line)
if not m:
    print(log[-2000:]); print("NICHT FERTIG: der Test hat nicht abgespielt"); sys.exit(1)
start = int(open(f"{work}/rec-start").read())
raw = open(f"{work}/rec.raw", "rb").read()
samples = struct.unpack(f"<{len(raw)//2}h", raw[: len(raw) // 2 * 2])
skip = max(0, (int(m.group(1)) - start) * 8)  # samples before play()
first = next((i for i in range(skip, len(samples)) if abs(samples[i]) > 300), None)
if first is None:
    print(f"kein Ton nach play() (Position am Ende {pos.group(1) if pos else '?'})")
    print("FEHLGESCHLAGEN"); sys.exit(1)
silence = (first - skip) / 8000
print(f"Stille nach play(): {silence:.1f} s (Grenze {limit:.0f} s), Position am Ende {pos.group(1) if pos else '?'}")
print("BESTANDEN" if silence <= limit else "FEHLGESCHLAGEN"); sys.exit(0 if silence <= limit else 1)
EOF
