#!/usr/bin/env bash
# nosound-test-linux.sh – runs integration_test/nosound_test.dart under Xvfb, once without any
# audio output (PulseAudio stopped, no ALSA device in the container) and once with a silent
# PulseAudio sink as the counter-check. Run as the build user in clients/app.
#
#   tools/dev/nosound-test-linux.sh SERVER CREDENTIALS_JSON FIRST_KEY NEXT_KEY LOG
set -euo pipefail
SERVER="$1"; CRED="$2"; FIRST="$3"; NEXT="$4"; LOG="$5"
export PATH=/opt/flutter/bin:$PATH
val() { python3 -c "import json,sys; print(json.load(open(sys.argv[1]))[sys.argv[2]])" "$CRED" "$1"; }

run() {
    rm -rf "$HOME/.local/share/io.github.joemj.audiojoe"
    xvfb-run -a -s "-screen 0 1280x800x24" flutter test integration_test/nosound_test.dart -d linux \
        --dart-define=SERVER="$SERVER" \
        --dart-define=USER="$(val username)" \
        --dart-define=PASS="$(val password)" \
        --dart-define=TOTP_SECRET="$(val totp_secret)" \
        --dart-define=FIRST="$FIRST" --dart-define=NEXT="$NEXT" \
        --dart-define=SOUND="$1" 2>&1 | tee -a "$LOG"
}

: > "$LOG"
echo "== without an audio output" | tee -a "$LOG"
pulseaudio --kill 2>/dev/null || true
PULSE_SERVER=none run none
echo "== with a silent output" | tee -a "$LOG"
pulseaudio --start --exit-idle-time=-1 --daemonize=yes --load="module-null-sink sink_name=silent" 2>/dev/null
pactl set-default-sink silent 2>/dev/null || true
run silent
