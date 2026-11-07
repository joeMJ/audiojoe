#!/usr/bin/env bash
# connection-test-linux.sh – connection loss while playing, Linux app under Xvfb: the app talks
# to the server through tools/dev/cutproxy.py, the test hangs and refuses the connection.
# Run as the build user in clients/app.
#
#   tools/dev/connection-test-linux.sh SERVER_HOST:PORT CREDENTIALS_JSON
set -euo pipefail
TARGET="$1"
CRED="$2"
export PATH=/opt/flutter/bin:$PATH
val() { python3 -c "import json,sys; print(json.load(open(sys.argv[1]))[sys.argv[2]])" "$CRED" "$1"; }
HERE="$(cd "$(dirname "$0")" && pwd)"

pulseaudio --check 2>/dev/null || pulseaudio --start --exit-idle-time=-1 --daemonize=yes \
    --load="module-null-sink sink_name=silent" 2>/dev/null
pactl set-default-sink silent 2>/dev/null || true
rm -rf "$HOME/.local/share/io.github.joemj.audiojoe"

python3 "$HERE/cutproxy.py" 8099 "$TARGET" 8097 &
PROXY=$!
trap 'kill $PROXY 2>/dev/null || true' EXIT
sleep 1

xvfb-run -a -s "-screen 0 1280x800x24" flutter test integration_test/connection_test.dart -d linux \
    --dart-define=SERVER=http://127.0.0.1:8099 \
    --dart-define=CONTROL=http://127.0.0.1:8097 \
    --dart-define=USER="$(val username)" \
    --dart-define=PASS="$(val password)" \
    --dart-define=TOTP_SECRET="$(val totp_secret)"
