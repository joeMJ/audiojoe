#!/usr/bin/env bash
# gives-up-test-linux.sh – proposal A: Linux app under Xvfb with an audio output that does not exist.
# Run as the build user in clients/app.
#
#   tools/dev/gives-up-test-linux.sh SERVER_URL CREDENTIALS_JSON
set -euo pipefail
SERVER="$1"
CRED="$2"
export PATH=/opt/flutter/bin:$PATH
val() { python3 -c "import json,sys; print(json.load(open(sys.argv[1]))[sys.argv[2]])" "$CRED" "$1"; }
rm -rf "$HOME/.local/share/io.github.joemj.audiojoe"
xvfb-run -a -s "-screen 0 1280x800x24" flutter test integration_test/gives_up_test.dart -d linux \
    --dart-define=SERVER="$SERVER" \
    --dart-define=AUDIOJOE_AO=no-such-output \
    --dart-define=USER="$(val username)" \
    --dart-define=PASS="$(val password)" \
    --dart-define=TOTP_SECRET="$(val totp_secret)"
