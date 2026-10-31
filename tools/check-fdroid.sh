#!/usr/bin/env bash
# check-fdroid.sh – checks a built APK for proprietary Google components that F-Droid
# does not accept (Play Services, Firebase, Play Core, Google ads/analytics).
#
#   tools/check-fdroid.sh path/to/app-release.apk
set -euo pipefail
APK="${1:?usage: $0 app.apk}"
FORBIDDEN='com/google/android/gms|com/google/firebase|com/google/android/play/core|com/google/android/play/integrity|com/google/android/datatransport|com/google/ads|com/android/billingclient'

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
unzip -q -o "$APK" 'classes*.dex' 'AndroidManifest.xml' -d "$tmp"
hits=$(for d in "$tmp"/classes*.dex; do strings -n 8 "$d"; done | grep -oE "L($FORBIDDEN)[^;]*" | sort -u || true)
if [ -n "$hits" ]; then
    echo "✖ Proprietary Google classes in $APK:"
    echo "$hits" | head -20 | sed 's/^/    /'
    exit 1
fi
if unzip -l "$APK" | grep -q 'META-INF/version-control-info.textproto\|DEPENDENCIES'; then
    echo "! note: dependency metadata found in APK"
fi
echo "✔ no Play Services, Firebase, Play Core or Google ads/analytics classes in $APK"
