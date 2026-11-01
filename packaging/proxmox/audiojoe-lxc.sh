#!/usr/bin/env bash
# audiojoe-lxc.sh – creates an unprivileged Debian 13 container on a Proxmox VE host and installs
# the audiojoe server in it (package from the newest release), with nightly server updates,
# daily Debian updates and the first user with TOTP. Run on the Proxmox host as root:
#
#   bash audiojoe-lxc.sh                  asks for the values (Enter keeps the proposal)
#   CTID=120 IP=10.0.0.20/24 GW=10.0.0.1 ADMIN=anna bash audiojoe-lxc.sh --yes
#   DRY_RUN=1 bash audiojoe-lxc.sh        only shows what would be done
#
# Values (environment): CTID, HOSTNAME_CT (audiojoe), STORAGE (local-lvm), TEMPLATE_STORAGE
# (local), BRIDGE (vmbr0), IP (dhcp or address/prefix), GW, CORES (2), RAM (2048 MB), DISK (8 GB),
# PROXY (address of the reverse proxy, optional), ADMIN (first user), SONOS (yes: stream port 8081).
# RELEASE_API: release source (default: the GitHub repository), RELEASE_TOKEN_FILE: file with an
# access token for a private repository (tests only).
set -Eeuo pipefail

RELEASE_API="${RELEASE_API:-https://api.github.com/repos/joeMJ/audiojoe}"
YES=no; [ "${1:-}" = --yes ] && YES=yes
DRY="${DRY_RUN:-0}"

say() { printf '\033[1;36m== %s\033[0m\n' "$*"; }
die() { printf '\033[1;31m✖ %s\033[0m\n' "$*" >&2; exit 1; }
run() { if [ "$DRY" = 1 ]; then printf '   %s\n' "$*"; else "$@"; fi; }
ask() { # name proposal question
  local v="${!1:-}"
  if [ -z "$v" ] && [ "$YES" = no ] && [ -t 0 ]; then read -r -p "$3 [$2]: " v; fi
  printf -v "$1" '%s' "${v:-$2}"
}

[ "$(id -u)" = 0 ] || die "run as root on the Proxmox host"
command -v pct >/dev/null && command -v pveam >/dev/null || die "pct/pveam missing – this is not a Proxmox VE host"

say "Settings"
ask CTID "$(pvesh get /cluster/nextid)" "Container ID"
ask HOSTNAME_CT audiojoe "Host name"
ask STORAGE local-lvm "Storage for the disk"
ask TEMPLATE_STORAGE local "Storage for the template"
ask BRIDGE vmbr0 "Network bridge"
ask IP dhcp "IPv4 address with prefix (e.g. 10.0.0.20/24) or dhcp"
[ "$IP" = dhcp ] || ask GW "" "Gateway"
ask CORES 2 "CPU cores"
ask RAM 2048 "RAM in MB"
ask DISK 8 "Disk in GB"
ask PROXY "" "Address of the reverse proxy (empty: none yet)"
ask SONOS yes "Sonos stream port 8081 (yes/no)"
ask ADMIN "" "Name of the first user (empty: later by hand)"

pct status "$CTID" >/dev/null 2>&1 && die "container $CTID exists already"
[[ "$CTID" =~ ^[0-9]+$ ]] || die "container ID must be a number"
[[ "$IP" = dhcp || "$IP" =~ ^[0-9.]+/[0-9]+$ ]] || die "IP must be dhcp or address/prefix"
[ -z "${ADMIN:-}" ] || [[ "$ADMIN" =~ ^[a-z][a-z0-9_-]{0,31}$ ]] || die "user name: lower-case letters, digits, - and _"

cat <<EOF
   container $CTID "$HOSTNAME_CT", unprivileged Debian 13, $CORES cores, $RAM MB, $DISK GB on $STORAGE
   network $BRIDGE, ${IP}${GW:+ via $GW}; reverse proxy: ${PROXY:-none}; Sonos: $SONOS; first user: ${ADMIN:-none}
   server package from: $RELEASE_API
EOF
if [ "$YES" = no ] && [ "$DRY" != 1 ] && [ -t 0 ]; then
  read -r -p "Create? [y/N]: " ok; [[ "$ok" =~ ^[yYjJ]$ ]] || die "cancelled"
fi

say "Template"
run pveam update >/dev/null
TEMPLATE="$(pveam available --section system | awk '/debian-13-standard_.*_amd64/ {print $2}' | sort -V | tail -n1)"
[ -n "$TEMPLATE" ] || die "no Debian 13 template offered by pveam"
pveam list "$TEMPLATE_STORAGE" | grep -q "$TEMPLATE" || run pveam download "$TEMPLATE_STORAGE" "$TEMPLATE"

say "Container"
NET="name=eth0,bridge=$BRIDGE,ip=$IP${GW:+,gw=$GW}"
run pct create "$CTID" "$TEMPLATE_STORAGE:vztmpl/$TEMPLATE" --hostname "$HOSTNAME_CT" --unprivileged 1 \
  --features nesting=1 --cores "$CORES" --memory "$RAM" --swap 512 --rootfs "$STORAGE:$DISK" \
  --net0 "$NET" --onboot 1 --timezone host --tags audiojoe --description "audiojoe server"
run pct start "$CTID"

if [ "$DRY" != 1 ]; then
  for _ in $(seq 1 30); do pct exec "$CTID" -- getent hosts deb.debian.org >/dev/null 2>&1 && break; sleep 2; done
  pct exec "$CTID" -- getent hosts deb.debian.org >/dev/null || die "container $CTID has no network/DNS"
  ADDR="$(pct exec "$CTID" -- sh -c "ip -4 -o addr show eth0 | awk '{print \$4}' | cut -d/ -f1 | head -n1")"
else
  ADDR="${IP%/*}"; [ "$IP" = dhcp ] && ADDR="<address>"
fi

TOKEN=""
[ -n "${RELEASE_TOKEN_FILE:-}" ] && { [ -r "$RELEASE_TOKEN_FILE" ] || die "cannot read $RELEASE_TOKEN_FILE"; TOKEN="$(tr -d '[:space:]' < "$RELEASE_TOKEN_FILE")"; }

say "Server in the container"
# Runs inside the container; the values come as arguments, the token on standard input.
INSIDE=$(cat <<'EOS'
set -Eeuo pipefail
ADDR="$1" PROXY="$2" SONOS="$3" API="$4" ADMIN="$5"
read -r TOKEN || true
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get -y -qq -o Dpkg::Options::=--force-confold full-upgrade >/dev/null
apt-get -y -qq install curl ca-certificates jq unattended-upgrades >/dev/null
hdr() { [ -n "$TOKEN" ] && printf 'Authorization: token %s\n' "$TOKEN" || true; }
rel="$(hdr | curl -fsSL -H @- -H 'Accept: application/json' "$API/releases/latest")"
ver="$(jq -r '.tag_name' <<<"$rel")"; ver="${ver#v}"
deb="audiojoe-server_${ver}_amd64.deb"
url() { jq -r --arg n "$1" '.assets[] | select(.name == $n) | .browser_download_url' <<<"$rel"; }
mkdir -p /var/cache/audiojoe && cd /var/cache/audiojoe
hdr | curl -fsSL -H @- -H 'Accept: application/octet-stream' -o "$deb" "$(url "$deb")"
hdr | curl -fsSL -H @- -H 'Accept: application/octet-stream' -o SHA256SUMS "$(url SHA256SUMS)"
grep -E "  \*?$deb\$" SHA256SUMS | sha256sum -c --quiet
rm -f SHA256SUMS

install -d -m 755 /etc/audiojoe
{
  echo "# audiojoe server configuration (written by audiojoe-lxc.sh)"
  echo "listen = \"$ADDR:8080\""
  echo 'database = "/var/lib/audiojoe/audiojoe.db"'
  echo 'web_root = "/usr/share/audiojoe/web"'
  if [ -n "$PROXY" ]; then echo "trusted_proxies = [\"$PROXY\"]"; else echo "trusted_proxies = []"; fi
  if [ "$SONOS" = yes ]; then printf '\n[sonos]\nlisten = "%s:8081"\n' "$ADDR"; fi
} > /etc/audiojoe/config.toml
if [ -n "$TOKEN" ]; then
  printf '%s\n' "$TOKEN" > /etc/audiojoe/update-token; chmod 600 /etc/audiojoe/update-token
  printf 'SOURCE=%s\nTOKEN_FILE=/etc/audiojoe/update-token\n' "$API" > /etc/audiojoe/update.conf
fi
apt-get -y -qq -o Dpkg::Options::=--force-confold install "./$deb" >/dev/null

# Debian keeps itself up to date: all updates daily, unused packages removed.
install -m 644 /usr/share/audiojoe/52audiojoe-upgrades /etc/apt/apt.conf.d/52audiojoe-upgrades
systemctl enable --now --quiet apt-daily.timer apt-daily-upgrade.timer
audiojoe-update --check >/dev/null || true

for _ in $(seq 1 20); do curl -fsS "http://$ADDR:8080/api/v1/health" >/dev/null 2>&1 && break; sleep 1; done
curl -fsS "http://$ADDR:8080/api/v1/health"; echo
if [ -n "$ADMIN" ]; then
  echo; echo "First user (shown once – put the secret into the authenticator app):"
  runuser -u audiojoe -- audiojoe-server --config /etc/audiojoe/config.toml user add "$ADMIN"
fi
EOS
)
if [ "$DRY" = 1 ]; then
  printf '   pct exec %s -- bash -s %q %q %q %q %q   (install, see INSIDE in this script)\n' "$CTID" "$ADDR" "${PROXY:-}" "$SONOS" "$RELEASE_API" "${ADMIN:-}"
else
  printf '%s\n' "$TOKEN" | pct exec "$CTID" -- bash -c "$INSIDE" inside "$ADDR" "${PROXY:-}" "$SONOS" "$RELEASE_API" "${ADMIN:-}"
fi

say "Done"
cat <<EOF
   audiojoe runs in container $CTID at http://$ADDR:8080 (only in the home network).
   Next: reverse proxy with HTTPS to this address (docs/INSTALLATION.md), then sign in in the app.
   Updates: server nightly at 04:00 (switch "only report" in the app under Settings → Maintenance),
   Debian daily. More users: pct exec $CTID -- runuser -u audiojoe -- audiojoe-server user add NAME
EOF
