#!/usr/bin/env bash
# build-server-deb.sh – packages the built server and web app as audiojoe-server_<version>_amd64.deb
# (Debian 13, Ubuntu 24.04/26.04). Run in the repository after
#   cargo build --release -p audiojoe-server   and   (cd clients/web && npm run build)
#
#   tools/build-server-deb.sh [output-dir]      default: target/deb
#
# Contents: /usr/bin/audiojoe-server, /usr/sbin/audiojoe-update, the web app, the systemd units
# (server, nightly update, update on request) and the example configuration.
set -euo pipefail
cd "$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
OUT="${1:-target/deb}"
BIN=target/release/audiojoe-server
WEB=clients/web/dist
[ -x "$BIN" ] || { echo "no $BIN – run: cargo build --release -p audiojoe-server" >&2; exit 1; }
[ -f "$WEB/index.html" ] || { echo "no $WEB – run: (cd clients/web && npm run build)" >&2; exit 1; }
VERSION=$(sed -n '/^\[workspace.package\]/,/^\[/s/^version *= *"\(.*\)"/\1/p' Cargo.toml)
[ -n "$VERSION" ] || { echo "no version in Cargo.toml" >&2; exit 1; }

ROOT=$(mktemp -d)
trap 'rm -rf "$ROOT"' EXIT
install -D -m 755 "$BIN" "$ROOT/usr/bin/audiojoe-server"
install -D -m 755 packaging/deb/audiojoe-update "$ROOT/usr/sbin/audiojoe-update"
mkdir -p "$ROOT/usr/share/audiojoe" && cp -r "$WEB" "$ROOT/usr/share/audiojoe/web"
for u in audiojoe-server.service audiojoe-update.service audiojoe-update-now.service audiojoe-update.timer audiojoe-update.path; do
  install -D -m 644 "packaging/deb/$u" "$ROOT/usr/lib/systemd/system/$u"
done
install -D -m 644 packaging/lxc/journald-audiojoe.conf "$ROOT/usr/lib/systemd/journald.conf.d/audiojoe.conf"
install -D -m 644 packaging/lxc/config.example.toml "$ROOT/usr/share/audiojoe/config.example.toml"
install -D -m 644 packaging/deb/52audiojoe-upgrades "$ROOT/usr/share/audiojoe/52audiojoe-upgrades"
install -D -m 644 packaging/deb/update.conf "$ROOT/etc/audiojoe/update.conf"
install -D -m 644 LICENSE "$ROOT/usr/share/doc/audiojoe-server/copyright"
install -m 644 THIRD_PARTY.md THIRD_PARTY_LICENSES.txt "$ROOT/usr/share/doc/audiojoe-server/"

mkdir -p "$ROOT/DEBIAN"
echo /etc/audiojoe/update.conf > "$ROOT/DEBIAN/conffiles"
cat > "$ROOT/DEBIAN/control" <<EOF
Package: audiojoe-server
Version: $VERSION
Section: sound
Priority: optional
Architecture: amd64
Depends: libc6, systemd, passwd, curl, jq, ca-certificates, ffmpeg
Recommends: unattended-upgrades
Installed-Size: $(du -sk "$ROOT" | cut -f1)
Maintainer: joeMJ <1265358+joeMJ@users.noreply.github.com>
Homepage: https://github.com/joeMJ/audiojoe
Description: audiojoe server – all your audio, one source of truth
 Podcasts, audiobooks, music and radio from Jellyfin, Emby, Plex, Audiobookshelf
 and RSS, with playback positions synced across the audiojoe apps and the web
 player. Updates itself nightly (database backup, way back on failure).
EOF

cat > "$ROOT/DEBIAN/postinst" <<'EOF'
#!/bin/sh
set -e
[ "$1" = configure ] || exit 0
id audiojoe >/dev/null 2>&1 || useradd --system --home-dir /var/lib/audiojoe --shell /usr/sbin/nologin audiojoe
install -d -m 755 -o audiojoe -g audiojoe /var/lib/audiojoe
install -d -m 755 /etc/audiojoe /var/cache/audiojoe
if [ ! -f /etc/audiojoe/config.toml ]; then
  # Only reachable on this machine until the address is set (see docs/INSTALLATION.md).
  sed -e 's/^listen = .*/listen = "127.0.0.1:8080"/' -e 's/^trusted_proxies = .*/trusted_proxies = []/' \
      /usr/share/audiojoe/config.example.toml > /etc/audiojoe/config.toml
  echo "audiojoe: /etc/audiojoe/config.toml created (listens on 127.0.0.1:8080 – set the LAN address there)"
fi
chown root:audiojoe /etc/audiojoe/config.toml
chmod 640 /etc/audiojoe/config.toml
if [ -d /run/systemd/system ]; then
  systemctl daemon-reload
  systemctl try-restart systemd-journald || true
  systemctl enable --quiet audiojoe-server.service audiojoe-update.timer audiojoe-update.path
  systemctl start --quiet audiojoe-update.timer audiojoe-update.path || true
  # During a self-update audiojoe-update restarts the server and checks it.
  systemctl restart audiojoe-server.service || true
fi
EOF
cat > "$ROOT/DEBIAN/prerm" <<'EOF'
#!/bin/sh
set -e
if [ "$1" = remove ] && [ -d /run/systemd/system ]; then
  systemctl disable --now --quiet audiojoe-update.timer audiojoe-update.path audiojoe-server.service || true
fi
EOF
cat > "$ROOT/DEBIAN/postrm" <<'EOF'
#!/bin/sh
set -e
[ -d /run/systemd/system ] && systemctl daemon-reload || true
# Data (/var/lib/audiojoe), backups and configuration stay; remove them by hand if wanted.
EOF
chmod 755 "$ROOT/DEBIAN/postinst" "$ROOT/DEBIAN/prerm" "$ROOT/DEBIAN/postrm"

mkdir -p "$OUT"
DEB="$OUT/audiojoe-server_${VERSION}_amd64.deb"
dpkg-deb --root-owner-group -Zxz --build "$ROOT" "$DEB" >/dev/null
echo "$DEB"
