#!/usr/bin/env bash
# album-end-test-linux.sh – runs integration_test/album_end_test.dart under Xvfb with a silent
# PulseAudio sink: the end of an album title must play the next one without a message.
# Run as the build user in clients/app.
#
#   tools/dev/album-end-test-linux.sh SERVER CREDENTIALS_JSON SEARCH LOG [full]
# "full": only title 3 played from its start to its end, without seeking (see the test).
set -euo pipefail
SERVER="$1"; CRED="$2"; SEARCH="$3"; LOG="$4"; FULL=false; [ "${5:-}" = full ] && FULL=true
export PATH=/opt/flutter/bin:$PATH
val() { python3 -c "import json,sys; print(json.load(open(sys.argv[1]))[sys.argv[2]])" "$CRED" "$1"; }
# A silent PulseAudio sink; without PulseAudio (test container) libmpv's null output, also in real time.
AO=""
if pulseaudio --check 2>/dev/null || pulseaudio --start --exit-idle-time=-1 --daemonize=yes \
    --load="module-null-sink sink_name=silent" 2>/dev/null; then
  pactl set-default-sink silent 2>/dev/null || true
else
  AO=null
fi
rm -rf "$HOME/.local/share/io.github.joemj.audiojoe"
xvfb-run -a -s "-screen 0 1280x800x24" flutter test integration_test/album_end_test.dart -d linux \
    --dart-define=SERVER="$SERVER" \
    --dart-define=USER="$(val username)" \
    --dart-define=PASS="$(val password)" \
    --dart-define=TOTP_SECRET="$(val totp_secret)" \
    --dart-define=SEARCH="$SEARCH" --dart-define=FULL="$FULL" --dart-define=AUDIOJOE_AO="$AO" 2>&1 | tee "$LOG"
