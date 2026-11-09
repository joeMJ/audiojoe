#!/usr/bin/env bash
# sonos-follow-test-linux.sh – runs integration_test/sonos_follow_test.dart (plays quietly on a real
# Sonos speaker) under Xvfb with a silent output. Run as the build user in clients/app; start
# tools/dev/cut-events.sh as root on the server host with the same log file beforehand.
#
#   tools/dev/sonos-follow-test-linux.sh SERVER CREDENTIALS_JSON ROOM_ID KEY LOG
set -euo pipefail
SERVER="$1"; CRED="$2"; ROOM="$3"; KEY="$4"; LOG="$5"
export PATH=/opt/flutter/bin:$PATH
val() { python3 -c "import json,sys; print(json.load(open(sys.argv[1]))[sys.argv[2]])" "$CRED" "$1"; }
AO=""
if pulseaudio --check 2>/dev/null || pulseaudio --start --exit-idle-time=-1 --daemonize=yes \
    --load="module-null-sink sink_name=silent" 2>/dev/null; then
  pactl set-default-sink silent 2>/dev/null || true
else
  AO=null
fi
rm -rf "$HOME/.local/share/io.github.joemj.audiojoe"
xvfb-run -a -s "-screen 0 1280x800x24" flutter test integration_test/sonos_follow_test.dart -d linux \
    --dart-define=SERVER="$SERVER" \
    --dart-define=USER="$(val username)" \
    --dart-define=PASS="$(val password)" \
    --dart-define=TOTP_SECRET="$(val totp_secret)" \
    --dart-define=ROOM="$ROOM" --dart-define=KEY="$KEY" --dart-define=AUDIOJOE_AO="$AO" 2>&1 | tee "$LOG"
