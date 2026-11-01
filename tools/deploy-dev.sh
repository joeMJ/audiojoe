#!/usr/bin/env bash
# deploy-dev.sh – builds and installs the current working tree in the development container.
#
#   tools/deploy-dev.sh [root@host]      default: $AUDIOJOE_DEV_HOST
#
# Copies the sources (without private/, target/, node_modules/), builds server, attrappe
# and web app there, installs the server package (tools/build-server-deb.sh) and restarts.
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"
HOST="${1:-${AUDIOJOE_DEV_HOST:?set AUDIOJOE_DEV_HOST or pass root@host}}"

ssh "$HOST" mkdir -p /opt/audiojoe/src
rsync -a --delete --exclude target --exclude private --exclude node_modules --exclude .git ./ "$HOST:/opt/audiojoe/src/"
ssh "$HOST" bash -s <<'EOF'
set -euo pipefail
. ~/.cargo/env
cd /opt/audiojoe/src
cargo build --release --quiet
(cd clients/web && npm install --no-audit --no-fund --silent && npm run --silent build >/dev/null)

# The server as package (as on a real installation); the test source of the attrappe by hand.
DEB=$(tools/build-server-deb.sh)
rm -f /usr/local/bin/audiojoe-server /etc/systemd/system/audiojoe-server.service
DEBIAN_FRONTEND=noninteractive apt-get install -y -qq --reinstall --allow-downgrades -o Dpkg::Options::=--force-confold "./$DEB" >/dev/null
install -m 755 target/release/attrappe /usr/local/bin/
install -m 644 packaging/lxc/audiojoe-attrappe.service /etc/systemd/system/
if [ -f /etc/audiojoe/config.toml ]; then chown root:audiojoe /etc/audiojoe/config.toml; chmod 640 /etc/audiojoe/config.toml; fi
systemctl daemon-reload
systemctl enable --now --quiet audiojoe-attrappe audiojoe-server
systemctl restart audiojoe-attrappe audiojoe-server
sleep 2
systemctl is-active audiojoe-attrappe audiojoe-server
EOF
