#!/usr/bin/env bash
# audiojoe-lxc.sh – creates an unprivileged Debian 13 container on a Proxmox VE host and installs
# the audiojoe server in it (package from the newest release), with nightly server updates,
# daily Debian updates and the first user with TOTP. Run on the Proxmox host as root:
#
#   bash -c "$(curl -fsSL https://raw.githubusercontent.com/joeMJ/audiojoe/main/packaging/proxmox/audiojoe-lxc.sh)"
#
# With a terminal and whiptail it asks in dialogs (like the Proxmox helper scripts): resources
# (minimum or optimal), container ID, host name, storage, bridge, IP, gateway, DNS, proxy, Sonos,
# first user; then a summary to confirm. Without whiptail it asks on the console.
#
#   CTID=120 IP=10.0.0.20/24 GW=10.0.0.1 ADMIN=anna bash audiojoe-lxc.sh --yes
#   DRY_RUN=1 bash audiojoe-lxc.sh        only shows what would be done
#
# Values (environment): PRESET (optimal: 2 cores, 2048 MB, 16 GB; minimal: 1 core, 1024 MB, 8 GB),
# CTID, HOSTNAME_CT (audiojoe), STORAGE (local-lvm), TEMPLATE_STORAGE (local), BRIDGE (vmbr0),
# IP (dhcp or address/prefix), GW, DNS (empty: like the host), CORES, RAM (MB), DISK (GB) – these
# three override the preset –, PROXY (address of the reverse proxy, optional), ADMIN (first user),
# SONOS (yes: stream port 8081).
# RELEASE_API: release source (default: the GitHub repository), RELEASE_TOKEN_FILE: file with an
# access token for a private repository (tests only).
set -Eeuo pipefail

DEFAULT_API="https://api.github.com/repos/joeMJ/audiojoe"
RELEASE_API="${RELEASE_API:-$DEFAULT_API}"
YES=no; [ "${1:-}" = --yes ] && YES=yes
DRY="${DRY_RUN:-0}"
TITLE="audiojoe – Proxmox container"

say() { printf '\033[1;36m== %s\033[0m\n' "$*"; }
die() { printf '\033[1;31m✖ %s\033[0m\n' "$*" >&2; exit 1; }
run() { if [ "$DRY" = 1 ]; then printf '   %s\n' "$*"; else "$@"; fi; }
BOX='box() { # colour line… – double frame around important lines (long lines wrapped at spaces, 74 columns)
  local c="$1" w=0 l bar; shift
  local -a out=()
  for l in "$@"; do
    if [ -z "$l" ]; then out+=(""); else while IFS= read -r part; do out+=("$part"); done < <(printf "%s\n" "$l" | fold -s -w 74 | sed "s/ *$//"); fi
  done
  for l in "${out[@]}"; do [ "${#l}" -gt "$w" ] && w=${#l}; done
  bar="$(printf "%*s" $((w + 2)) "" | sed "s/ /═/g")"
  printf "\n   \033[%sm╔%s╗\033[0m\n" "$c" "$bar"
  for l in "${out[@]}"; do printf "   \033[%sm║\033[0m %-*s \033[%sm║\033[0m\n" "$c" "$w" "$l" "$c"; done
  printf "   \033[%sm╚%s╝\033[0m\n\n" "$c" "$bar"
}'
eval "$BOX"

# Dialogs only when someone sits at a terminal; otherwise environment values and proposals.
ASKING=no; [ "$YES" = no ] && [ -t 0 ] && [ -t 1 ] && ASKING=yes
UI=console; [ "$ASKING" = yes ] && command -v whiptail >/dev/null && UI=whiptail
wt() { whiptail --title "$TITLE" "$@" 3>&1 1>&2 2>&3; }

ask() { # name proposal question – a value from the environment is kept, Enter keeps the proposal
  local v="${!1:-}"
  if [ -z "$v" ] && [ "$ASKING" = yes ]; then
    if [ "$UI" = whiptail ]; then v="$(wt --inputbox "$3" 10 72 "$2")" || die "cancelled"
    else read -r -p "$3 [$2]: " v; fi
  fi
  printf -v "$1" '%s' "${v:-$2}"
}
ask_yes() { # name question – yes/no, proposal yes
  local v="${!1:-}"
  if [ -z "$v" ] && [ "$ASKING" = yes ]; then
    if [ "$UI" = whiptail ]; then
      if wt --yesno "$2" 10 72; then v=yes; else [ $? = 1 ] && v=no || die "cancelled"; fi
    else read -r -p "$2 (yes/no) [yes]: " v; fi
  fi
  printf -v "$1" '%s' "${v:-yes}"
}

[ "$(id -u)" = 0 ] || die "run as root on the Proxmox host"
command -v pct >/dev/null && command -v pveam >/dev/null || die "pct/pveam missing – this is not a Proxmox VE host"

say "Settings"
if [ -z "${PRESET:-}" ] && [ "$ASKING" = yes ]; then
  if [ "$UI" = whiptail ]; then
    PRESET="$(wt --menu "Resources for the container" 12 72 2 \
      optimal "2 cores, 2048 MB RAM, 16 GB disk (recommended)" \
      minimal "1 core, 1024 MB RAM, 8 GB disk (minimum)")" || die "cancelled"
  else
    read -r -p "Resources: optimal (2 cores, 2048 MB, 16 GB) or minimal (1 core, 1024 MB, 8 GB) [optimal]: " PRESET
  fi
fi
PRESET="${PRESET:-optimal}"
case "$PRESET" in
  optimal) CORES="${CORES:-2}" RAM="${RAM:-2048}" DISK="${DISK:-16}" ;;
  minimal) CORES="${CORES:-1}" RAM="${RAM:-1024}" DISK="${DISK:-8}" ;;
  *) die "PRESET must be optimal or minimal" ;;
esac

ask CTID "$(pvesh get /cluster/nextid)" "Container ID"
ask HOSTNAME_CT audiojoe "Host name"
ask STORAGE local-lvm "Storage for the disk"
ask TEMPLATE_STORAGE local "Storage for the template"
ask BRIDGE vmbr0 "Network bridge"
ask IP dhcp "IPv4 address with prefix (e.g. 10.0.0.20/24) or dhcp"
[ "$IP" = dhcp ] || ask GW "" "Gateway"
ask DNS "" "DNS server (empty: like the host)"
ask PROXY "" "Address of the reverse proxy (empty: none yet)"
ask_yes SONOS "Sonos speakers in the home network? (opens stream port 8081)"
ask ADMIN "" "Name of the first user (empty: later by hand)"

pct status "$CTID" >/dev/null 2>&1 && die "container $CTID exists already"
[[ "$CTID" =~ ^[0-9]+$ ]] || die "container ID must be a number"
[[ "$IP" = dhcp || "$IP" =~ ^[0-9.]+/[0-9]+$ ]] || die "IP must be dhcp or address/prefix"
[ -z "${GW:-}" ] || [[ "$GW" =~ ^[0-9.]+$ ]] || die "gateway must be an IPv4 address"
[ -z "${DNS:-}" ] || [[ "$DNS" =~ ^[0-9.]+$ ]] || die "DNS server must be an IPv4 address"
[[ "$SONOS" =~ ^(yes|no)$ ]] || die "SONOS must be yes or no"
[ -z "${ADMIN:-}" ] || [[ "$ADMIN" =~ ^[a-z][a-z0-9_-]{0,31}$ ]] || die "user name: lower-case letters, digits, - and _"

SUMMARY="Container $CTID \"$HOSTNAME_CT\", unprivileged Debian 13
Resources: $PRESET – CPU cores $CORES, RAM $RAM MB, disk $DISK GB on $STORAGE
Network: $BRIDGE, ${IP}${GW:+ via $GW}, DNS ${DNS:-like the host}
Reverse proxy: ${PROXY:-none}; Sonos: $SONOS; first user: ${ADMIN:-none}
Server package from: $RELEASE_API"
printf '%s\n' "$SUMMARY" | sed 's/^/   /'
if [ "$ASKING" = yes ] && [ "$DRY" != 1 ]; then
  if [ "$UI" = whiptail ]; then wt --yesno "$SUMMARY

Create the container?" 16 76 || die "cancelled"
  else read -r -p "Create? [y/N]: " ok; [[ "$ok" =~ ^[yYjJ]$ ]] || die "cancelled"; fi
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
  --net0 "$NET" ${DNS:+--nameserver "$DNS"} --onboot 1 --timezone host --tags audiojoe --description "audiojoe server"
run pct start "$CTID"

if [ "$DRY" != 1 ]; then
  printf '   \033[1;33m…\033[0m waiting for the network in the container'
  for _ in $(seq 1 30); do pct exec "$CTID" -- getent hosts deb.debian.org >/dev/null 2>&1 && break; sleep 2; done
  pct exec "$CTID" -- getent hosts deb.debian.org >/dev/null || { echo; die "container $CTID has no network/DNS"; }
  printf '\r   \033[1;32m✔\033[0m network in the container is up        \n'
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
# The host's locale (LANG) comes along with pct exec but is not installed in the container.
export LC_ALL=C.UTF-8 LANG=C.UTF-8
ADDR="$1" PROXY="$2" SONOS="$3" API="$4" ADMIN="$5" DEFAULT_API="$6"
read -r TOKEN || true
eval "$7"   # box()
export DEBIAN_FRONTEND=noninteractive
LOG=/var/log/audiojoe-install.log; : > "$LOG"

# One line per step: a spinner while it runs, then a check mark; on failure the end of the log.
step() { # text command…
  local text="$1" pid i=0 spin='|/-\'; shift
  "$@" </dev/null >>"$LOG" 2>&1 & pid=$!
  while kill -0 "$pid" 2>/dev/null; do
    printf '\r   \033[1;33m%s\033[0m %s ' "${spin:$((i++ % 4)):1}" "$text"; sleep 0.2
  done
  if wait "$pid"; then printf '\r   \033[1;32m✔\033[0m %s \n' "$text"
  else printf '\r   \033[1;31m✖\033[0m %s – failed, last lines of %s:\n' "$text" "$LOG"; tail -n 15 "$LOG"; exit 1; fi
}
hdr() { [ -n "$TOKEN" ] && printf 'Authorization: token %s\n' "$TOKEN" || true; }
url() { jq -r --arg n "$1" '.assets[] | select(.name == $n) | .browser_download_url' <<<"$rel"; }
upgrade() { apt-get update; apt-get -y -o Dpkg::Options::=--force-confold full-upgrade; }
tools() { apt-get -y install curl ca-certificates jq unattended-upgrades; }
fetch() {
  hdr | curl -fsSL -H @- -H 'Accept: application/octet-stream' -o "$deb" "$(url "$deb")"
  hdr | curl -fsSL -H @- -H 'Accept: application/octet-stream' -o SHA256SUMS "$(url SHA256SUMS)"
  grep -E "  \*?$deb\$" SHA256SUMS | sha256sum -c
  rm -f SHA256SUMS
}
package() { apt-get -y -o Dpkg::Options::=--force-confold install "./$deb"; }
selfcare() { # Debian keeps itself up to date: all updates daily, unused packages removed.
  install -m 644 /usr/share/audiojoe/52audiojoe-upgrades /etc/apt/apt.conf.d/52audiojoe-upgrades
  systemctl enable --now apt-daily.timer apt-daily-upgrade.timer
  audiojoe-update --check || true
}
health() { for _ in $(seq 1 30); do curl -fsS "http://$ADDR:8080/api/v1/health" && return 0; sleep 1; done; return 1; }

step "Updating Debian in the container" upgrade
step "Installing curl, jq and unattended-upgrades" tools
rel="$(hdr | curl -fsSL -H @- -H 'Accept: application/json' "$API/releases/latest")"
ver="$(jq -r '.tag_name' <<<"$rel")"; ver="${ver#v}"
deb="audiojoe-server_${ver}_amd64.deb"
mkdir -p /var/cache/audiojoe && cd /var/cache/audiojoe
step "Downloading audiojoe $ver and checking the checksum" fetch

install -d -m 755 /etc/audiojoe
{
  echo "# audiojoe server configuration (written by audiojoe-lxc.sh)"
  echo "listen = \"$ADDR:8080\""
  echo 'database = "/var/lib/audiojoe/audiojoe.db"'
  echo 'web_root = "/usr/share/audiojoe/web"'
  if [ -n "$PROXY" ]; then echo "trusted_proxies = [\"$PROXY\"]"; else echo "trusted_proxies = []"; fi
  if [ "$SONOS" = yes ]; then printf '\n[sonos]\nlisten = "%s:8081"\n' "$ADDR"; fi
} > /etc/audiojoe/config.toml
step "Installing the audiojoe server package" package

# Another release source than the default (and its token) goes into the package's update.conf.
if [ -n "$TOKEN" ]; then
  install -m 600 /dev/null /etc/audiojoe/update-token; printf '%s\n' "$TOKEN" > /etc/audiojoe/update-token
fi
if [ "$API" != "$DEFAULT_API" ] || [ -n "$TOKEN" ]; then
  { echo "# release source (written by audiojoe-lxc.sh)"; echo "SOURCE=$API"
    [ -z "$TOKEN" ] || echo "TOKEN_FILE=/etc/audiojoe/update-token"; } > /etc/audiojoe/update.conf
fi
step "Switching on the nightly updates" selfcare
step "Waiting for the server to answer" health

if [ -n "$ADMIN" ]; then
  out="$(runuser -u audiojoe -- audiojoe-server --config /etc/audiojoe/config.toml user add "$ADMIN")"
  mapfile -t user <<<"$out"
  box "1;33" "FIRST USER - shown only once, write it down now" "" "${user[@]}" "" \
    "Put the totp secret into your authenticator app (or open the totp uri" \
    "on the phone). Sign in with user name, password and the 6-digit code."
fi
EOS
)
if [ "$DRY" = 1 ]; then
  printf '   pct exec %s -- bash -s %q %q %q %q %q %q   (install, see INSIDE in this script)\n' "$CTID" "$ADDR" "${PROXY:-}" "$SONOS" "$RELEASE_API" "${ADMIN:-}" "$DEFAULT_API"
  printf '     steps: update Debian, install tools, download and check audiojoe, install it, nightly updates, wait for the server, first user\n'
else
  printf '%s\n' "$TOKEN" | pct exec "$CTID" -- bash -c "$INSIDE" inside "$ADDR" "${PROXY:-}" "$SONOS" "$RELEASE_API" "${ADMIN:-}" "$DEFAULT_API" "$BOX"
fi

say "Done"
cat <<EOF
   audiojoe runs in container $CTID at http://$ADDR:8080 (home network only).
   Updates: server nightly at 04:00 (app: Settings → Maintenance), Debian daily.
   Install log in the container: /var/log/audiojoe-install.log
   More users: pct exec $CTID -- runuser -u audiojoe -- audiojoe-server user add NAME
EOF
NPM_NOTE="Proxy address: $PROXY (already in /etc/audiojoe/config.toml)"
[ -n "${PROXY:-}" ] || NPM_NOTE="No proxy address given: put the NPM address into trusted_proxies in /etc/audiojoe/config.toml (container $CTID), then: systemctl restart audiojoe-server"
box "1;36" "NEXT: REVERSE PROXY WITH HTTPS (Nginx Proxy Manager)" "" \
  "Hosts > Proxy Hosts > Add Proxy Host" \
  "  Details  Domain Names           your domain, e.g. audiojoe.example.org" \
  "           Scheme                 http" \
  "           Forward Hostname / IP  $ADDR" \
  "           Forward Port           8080" \
  "           Websockets Support     not needed" \
  "  SSL      SSL Certificate        Request a new Certificate" \
  "           Force SSL              on" \
  "           HTTP/2 Support         on" \
  "" "$NPM_NOTE" "" \
  "Then sign in with the app at https://<your domain>."
