#!/usr/bin/env bash
# build-deb.sh – packages the built Linux app (flutter build linux --release) as .deb for
# Ubuntu 24.04 / 26.04. Run in clients/app after the Flutter build.
#
#   tools/build-deb.sh [output-dir]
set -euo pipefail
APP="$(pwd)"
OUT="${1:-$APP/build/deb}"
BUNDLE="$APP/build/linux/x64/release/bundle"
[ -x "$BUNDLE/audiojoe" ] || { echo "no Linux build in $BUNDLE – run: flutter build linux --release" >&2; exit 1; }
VERSION=$(sed -n 's/^version: *\([0-9.]*\).*/\1/p' "$APP/pubspec.yaml")

ROOT=$(mktemp -d)
trap 'rm -rf "$ROOT"' EXIT
mkdir -p "$ROOT/DEBIAN" "$ROOT/opt/audiojoe" "$ROOT/usr/bin" "$ROOT/usr/share/applications" \
         "$ROOT/usr/share/icons/hicolor/256x256/apps"
cp -a "$BUNDLE/." "$ROOT/opt/audiojoe/"
ln -s /opt/audiojoe/audiojoe "$ROOT/usr/bin/audiojoe"
ICON="$APP/assets/icon.png"
[ -f "$ICON" ] && cp "$ICON" "$ROOT/usr/share/icons/hicolor/256x256/apps/audiojoe.png"
cat > "$ROOT/usr/share/applications/io.github.joemj.audiojoe.desktop" <<EOF
[Desktop Entry]
Type=Application
Name=audiojoe
Comment=All your audio, one source of truth
Comment[de]=Alle Audioquellen, ein Stand
Exec=audiojoe
Icon=audiojoe
Categories=AudioVideo;Audio;Player;
StartupWMClass=audiojoe
EOF
cat > "$ROOT/DEBIAN/control" <<EOF
Package: audiojoe
Version: $VERSION
Section: sound
Priority: optional
Architecture: amd64
Depends: libgtk-3-0t64 | libgtk-3-0, libmpv2, libsecret-1-0
Maintainer: joeMJ <1265358+joeMJ@users.noreply.github.com>
Homepage: https://github.com/joeMJ/audiojoe
Description: audiojoe client – all your audio, one source of truth
 Podcasts, audiobooks and music from Jellyfin, Audiobookshelf and RSS with
 playback positions synced across devices via an audiojoe server.
EOF
mkdir -p "$OUT"
DEB="$OUT/audiojoe_${VERSION}_amd64.deb"
dpkg-deb --root-owner-group --build "$ROOT" "$DEB" >/dev/null
echo "$DEB"
