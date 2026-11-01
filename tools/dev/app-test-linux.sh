#!/usr/bin/env bash
# app-test-linux.sh – runs the Flutter integration test of the Linux app under Xvfb with a
# silent PulseAudio sink. Run as the build user in clients/app.
#
#   tools/dev/app-test-linux.sh SERVER CREDENTIALS_JSON [SCREENSHOT_DIR]
set -euo pipefail
SERVER="$1"
CRED="$2"
SHOTS="${3:-}"
[[ -z "$SHOTS" ]] || mkdir -p "$SHOTS"
export PATH=/opt/flutter/bin:$PATH
val() { python3 -c "import json,sys; print(json.load(open(sys.argv[1]))[sys.argv[2]])" "$CRED" "$1"; }

# Audio output without hardware: PulseAudio with a null sink.
pulseaudio --check 2>/dev/null || pulseaudio --start --exit-idle-time=-1 --daemonize=yes \
    --load="module-null-sink sink_name=silent" 2>/dev/null
pactl set-default-sink silent 2>/dev/null || true

# Fresh app data, so the test starts at the sign-in screen.
rm -rf "$HOME/.local/share/io.github.joemj.audiojoe"

xvfb-run -a -s "-screen 0 1280x800x24" flutter test integration_test -d linux \
    --dart-define=SERVER="$SERVER" \
    --dart-define=USER="$(val username)" \
    --dart-define=PASS="$(val password)" \
    --dart-define=TOTP_SECRET="$(val totp_secret)" \
    --dart-define=SHOTS="$SHOTS"
