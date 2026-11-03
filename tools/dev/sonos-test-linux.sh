#!/usr/bin/env bash
# sonos-test-linux.sh – runs integration_test/sonos_test.dart (plays quietly on a real Sonos
# speaker) under Xvfb with a silent PulseAudio sink. Run as the build user in clients/app.
# Start tools/dev/cut-events.sh as root on the server host with the same log file beforehand.
#
#   tools/dev/sonos-test-linux.sh SERVER CREDENTIALS_JSON ROOM_ID FIRST_KEY NEXT_KEY LOG [SCREENSHOT_DIR]
set -euo pipefail
SERVER="$1"; CRED="$2"; ROOM="$3"; FIRST="$4"; NEXT="$5"; LOG="$6"; SHOTS="${7:-}"
[[ -z "$SHOTS" ]] || mkdir -p "$SHOTS"
export PATH=/opt/flutter/bin:$PATH
val() { python3 -c "import json,sys; print(json.load(open(sys.argv[1]))[sys.argv[2]])" "$CRED" "$1"; }

pulseaudio --check 2>/dev/null || pulseaudio --start --exit-idle-time=-1 --daemonize=yes \
    --load="module-null-sink sink_name=silent" 2>/dev/null
pactl set-default-sink silent 2>/dev/null || true
rm -rf "$HOME/.local/share/io.github.joemj.audiojoe"

xvfb-run -a -s "-screen 0 1280x800x24" flutter test integration_test/sonos_test.dart -d linux \
    --dart-define=SERVER="$SERVER" \
    --dart-define=USER="$(val username)" \
    --dart-define=PASS="$(val password)" \
    --dart-define=TOTP_SECRET="$(val totp_secret)" \
    --dart-define=ROOM="$ROOM" --dart-define=FIRST="$FIRST" --dart-define=NEXT="$NEXT" \
    --dart-define=SHOTS="$SHOTS" 2>&1 | tee "$LOG"
