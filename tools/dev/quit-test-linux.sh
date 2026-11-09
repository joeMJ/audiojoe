#!/usr/bin/env bash
# quit-test-linux.sh – runs integration_test/quit_test.dart under Xvfb and strace: the app plays a
# title and closes its window. Passes when the app process ended without a signal (0.2.4: SIGSEGV).
# Run as the build user in clients/app; prints one line "RESULT …".
#
#   tools/dev/quit-test-linux.sh SERVER CREDENTIALS_JSON SEARCH LOG
set -uo pipefail
SERVER="$1"; CRED="$2"; SEARCH="$3"; LOG="$4"
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
TRACE="$LOG.strace"
strace -f -qq -e trace=none -e signal=SIGSEGV,SIGABRT,SIGBUS -o "$TRACE" \
  xvfb-run -a -s "-screen 0 1280x800x24" flutter test integration_test/quit_test.dart -d linux \
    --dart-define=SERVER="$SERVER" \
    --dart-define=USER="$(val username)" \
    --dart-define=PASS="$(val password)" \
    --dart-define=TOTP_SECRET="$(val totp_secret)" \
    --dart-define=SEARCH="$SEARCH" --dart-define=AUDIOJOE_AO="$AO" > "$LOG" 2>&1
grep -E "^[0-9:]{8} " "$LOG"
if ! grep -q CLOSING "$LOG"; then echo "RESULT invalid: did not reach CLOSING"; exit 2; fi
if grep -q "STILL RUNNING" "$LOG"; then echo "RESULT fail: window did not close"; exit 1; fi
if grep -qE "killed by SIG|--- SIG(SEGV|ABRT|BUS)" "$TRACE"; then
  echo "RESULT crash: $(grep -E 'killed by SIG|--- SIG' "$TRACE" | head -3 | tr '\n' ' ')"; exit 1
fi
echo "RESULT ok: no signal"
