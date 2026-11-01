#!/usr/bin/env bash
# audiojoe-ubuntu.sh – installs the audiojoe server on Ubuntu Server 24.04 or 26.04 (the minimal
# edition too) in an existing VM: package from the newest release, configuration, nightly server
# updates, daily Ubuntu updates and the first user with TOTP. Run in the VM as root:
#
#   sudo bash -c "$(curl -fsSL https://raw.githubusercontent.com/joeMJ/audiojoe/main/packaging/ubuntu/audiojoe-ubuntu.sh)"
#
# With a terminal and whiptail it asks in dialogs (like the Proxmox script): the address audiojoe
# listens on, the reverse proxy, Sonos, the first user; then a summary to confirm. Without
# whiptail it asks on the console. A reverse proxy in the VM itself is not set up (yet).
#
#   sudo ADDR=10.0.0.21 PROXY=10.0.0.10 ADMIN=anna bash audiojoe-ubuntu.sh --yes
#   sudo DRY_RUN=1 bash audiojoe-ubuntu.sh     only shows what would be done
#
# Values (environment): ADDR (address in the home network, default: the VM's address towards the
# default gateway), PROXY (IP address of the reverse proxy that publishes audiojoe, e.g. NPM - not
# a download proxy; optional), SONOS (yes: stream port 8081), ADMIN (first user).
# RELEASE_API: release source (default: the GitHub repository), RELEASE_TOKEN_FILE: file with an
# access token for a private repository (tests only).
set -Eeuo pipefail

DEFAULT_API="https://api.github.com/repos/joeMJ/audiojoe"
RELEASE_API="${RELEASE_API:-$DEFAULT_API}"
YES=no; [ "${1:-}" = --yes ] && YES=yes
DRY="${DRY_RUN:-0}"
TITLE="audiojoe – Ubuntu server"
LOG=/var/log/audiojoe-install.log
export DEBIAN_FRONTEND=noninteractive

say() { printf '\033[1;36m== %s\033[0m\n' "$*"; }
die() { printf '\033[1;31m✖ %s\033[0m\n' "$*" >&2; exit 1; }
box() { # colour line… – double frame around important lines (long lines wrapped at spaces, 74 columns)
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
}

# Dialogs only when someone sits at a terminal; otherwise environment values and proposals.
ASKING=no; [ "$YES" = no ] && [ -t 0 ] && [ -t 1 ] && ASKING=yes
# Input fields in black on the blue field (the default light text is hard to read in many themes).
export NEWT_COLORS="${NEWT_COLORS:-entry=black,blue}"
wt() { whiptail --title "$TITLE" "$@" 3>&1 1>&2 2>&3; }

ask() { # name proposal question – a value from the environment is kept, Enter keeps the proposal
  local v="${!1:-}"
  if [ -z "$v" ] && [ "$ASKING" = yes ]; then
    if [ "$UI" = whiptail ]; then v="$(wt --inputbox "$3" $((9 + $(printf '%s\n' "$3" | wc -l))) 76 "$2")" || die "cancelled"
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

[ "$(id -u)" = 0 ] || die "run as root (sudo) in the Ubuntu VM"
# shellcheck disable=SC1091
. /etc/os-release
[ "${ID:-}" = ubuntu ] && [[ "${VERSION_ID:-}" =~ ^(24\.04|26\.04)$ ]] \
  || die "for Ubuntu Server 24.04 or 26.04 only (this is: ${PRETTY_NAME:-unknown})"
[ "$(dpkg --print-architecture)" = amd64 ] || die "the server package is for amd64 only"
if dpkg-query -W -f='${Status}' audiojoe-server 2>/dev/null | grep -q "ok installed"; then
  die "audiojoe-server is installed already – it keeps itself up to date (audiojoe-update)"
fi
# The minimal edition has no whiptail: install the Ubuntu package for the dialogs (not in a dry
# run); if that fails, the questions come on the console.
if [ "$ASKING" = yes ] && ! command -v whiptail >/dev/null && [ "$DRY" != 1 ]; then
  say "Installing whiptail for the dialogs"
  { apt-get -qq update && apt-get -y -qq install whiptail; } >/dev/null 2>&1 || echo "   (not possible - questions on the console)"
fi
UI=console; [ "$ASKING" = yes ] && command -v whiptail >/dev/null && UI=whiptail

say "Settings"
DEF_ADDR="$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for (i = 1; i < NF; i++) if ($i == "src") { print $(i + 1); exit }}')"
ask ADDR "${DEF_ADDR:-}" "Address audiojoe listens on in the home network
(an IPv4 address of this VM; Sonos speakers and the reverse proxy reach it there)"
ask PROXY "" "IP address of the REVERSE PROXY that publishes audiojoe
(e.g. Nginx Proxy Manager, Caddy) - NOT a proxy for downloads.
audiojoe trusts its X-Forwarded-For header: real client addresses
in the log and for the login lock. Empty: no reverse proxy yet."
ask_yes SONOS "Sonos speakers in the home network? (opens stream port 8081)"
ask ADMIN "" "Name of the first user (empty: later by hand)"

[[ "$ADDR" =~ ^[0-9.]+$ ]] || die "address must be an IPv4 address"
ip -4 -o addr show | awk '{print $4}' | cut -d/ -f1 | grep -qx "$ADDR" || die "$ADDR is not an address of this VM"
[ -z "${PROXY:-}" ] || [[ "$PROXY" =~ ^[0-9a-fA-F:.]+$ ]] || die "reverse proxy: an IP address, not a name or URL"
[[ "$SONOS" =~ ^(yes|no)$ ]] || die "SONOS must be yes or no"
[ -z "${ADMIN:-}" ] || [[ "$ADMIN" =~ ^[a-z][a-z0-9_-]{0,31}$ ]] || die "user name: lower-case letters, digits, - and _"
DHCP_NOTE=""
ip -4 -o addr show | grep -E " $ADDR/[0-9]+ " | grep -q dynamic \
  && DHCP_NOTE="
NOTE: $ADDR comes from DHCP and may change - make it fixed (netplan) or reserve it in the router."

SUMMARY="audiojoe server on ${PRETTY_NAME}
Listens on: http://$ADDR:8080
Reverse proxy publishing audiojoe: ${PROXY:-none}; Sonos: $SONOS; first user: ${ADMIN:-none}
Server package from: $RELEASE_API
Ubuntu updates: daily, all updates (unattended-upgrades)$DHCP_NOTE"
printf '%s\n' "$SUMMARY" | sed 's/^/   /'
if [ "$ASKING" = yes ] && [ "$DRY" != 1 ]; then
  if [ "$UI" = whiptail ]; then wt --yesno "$SUMMARY

Install audiojoe now?" 18 78 || die "cancelled"
  else read -r -p "Install? [y/N]: " ok; [[ "$ok" =~ ^[yYjJ]$ ]] || die "cancelled"; fi
fi

say "Installing"
if [ "$DRY" = 1 ]; then
  printf '   steps: update Ubuntu, install tools, download and check audiojoe, write %s,\n' /etc/audiojoe/config.toml
  printf '   install it, nightly and daily updates, wait for the server, first user\n'
  exit 0
fi

TOKEN=""
[ -n "${RELEASE_TOKEN_FILE:-}" ] && { [ -r "$RELEASE_TOKEN_FILE" ] || die "cannot read $RELEASE_TOKEN_FILE"; TOKEN="$(tr -d '[:space:]' < "$RELEASE_TOKEN_FILE")"; }
: > "$LOG"

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
selfcare() { # Ubuntu keeps itself up to date: all updates daily, unused packages removed.
  cat > /etc/apt/apt.conf.d/52audiojoe-upgrades <<'EOF'
// audiojoe: install Ubuntu updates (not only security updates) daily and remove packages that
// are no longer needed. Written by audiojoe-ubuntu.sh; see docs/install-server.md.
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
APT::Periodic::AutocleanInterval "7";
Unattended-Upgrade::Allowed-Origins {
        "${distro_id}:${distro_codename}";
        "${distro_id}:${distro_codename}-updates";
        "${distro_id}:${distro_codename}-security";
};
Unattended-Upgrade::Remove-Unused-Dependencies "true";
Unattended-Upgrade::Remove-New-Unused-Dependencies "true";
Unattended-Upgrade::Remove-Unused-Kernel-Packages "true";
Unattended-Upgrade::Automatic-Reboot "false";
EOF
  chmod 644 /etc/apt/apt.conf.d/52audiojoe-upgrades
  systemctl enable --now apt-daily.timer apt-daily-upgrade.timer
  audiojoe-update --check || true
}
health() { for _ in $(seq 1 30); do curl -fsS "http://$ADDR:8080/api/v1/health" && return 0; sleep 1; done; return 1; }

step "Updating Ubuntu" upgrade
step "Installing curl, jq and unattended-upgrades" tools
rel="$(hdr | curl -fsSL -H @- -H 'Accept: application/json' "$RELEASE_API/releases/latest")"
ver="$(jq -r '.tag_name' <<<"$rel")"; ver="${ver#v}"
deb="audiojoe-server_${ver}_amd64.deb"
mkdir -p /var/cache/audiojoe && cd /var/cache/audiojoe
step "Downloading audiojoe $ver and checking the checksum" fetch

install -d -m 755 /etc/audiojoe
{
  echo "# audiojoe server configuration (written by audiojoe-ubuntu.sh)"
  echo "listen = \"$ADDR:8080\""
  echo 'database = "/var/lib/audiojoe/audiojoe.db"'
  echo 'web_root = "/usr/share/audiojoe/web"'
  if [ -n "${PROXY:-}" ]; then echo "trusted_proxies = [\"$PROXY\"]"; else echo "trusted_proxies = []"; fi
  if [ "$SONOS" = yes ]; then printf '\n[sonos]\nlisten = "%s:8081"\n' "$ADDR"; fi
} > /etc/audiojoe/config.toml
step "Installing the audiojoe server package" package

# Another release source than the default (and its token) goes into the package's update.conf.
if [ -n "$TOKEN" ]; then
  install -m 600 /dev/null /etc/audiojoe/update-token; printf '%s\n' "$TOKEN" > /etc/audiojoe/update-token
fi
if [ "$RELEASE_API" != "$DEFAULT_API" ] || [ -n "$TOKEN" ]; then
  { echo "# release source (written by audiojoe-ubuntu.sh)"; echo "SOURCE=$RELEASE_API"
    [ -z "$TOKEN" ] || echo "TOKEN_FILE=/etc/audiojoe/update-token"; } > /etc/audiojoe/update.conf
fi
step "Switching on the nightly and daily updates" selfcare
step "Waiting for the server to answer" health

if [ -n "${ADMIN:-}" ]; then
  out="$(runuser -u audiojoe -- audiojoe-server --config /etc/audiojoe/config.toml user add "$ADMIN")"
  mapfile -t user <<<"$out"
  box "1;33" "FIRST USER - shown only once, write it down now" "" "${user[@]}" "" \
    "Put the totp secret into your authenticator app (or open the totp uri" \
    "on the phone). Sign in with user name, password and the 6-digit code."
fi

say "Done"
cat <<EOF
   audiojoe runs at http://$ADDR:8080 (home network only).
   Updates: server nightly at 04:00 (app: Settings → Maintenance), Ubuntu daily.
   Install log: $LOG
   More users: sudo runuser -u audiojoe -- audiojoe-server user add NAME
EOF
NPM_NOTE="Proxy address: $PROXY (already in /etc/audiojoe/config.toml)"
[ -n "${PROXY:-}" ] || NPM_NOTE="No proxy address given: put the NPM address into trusted_proxies in /etc/audiojoe/config.toml, then: sudo systemctl restart audiojoe-server"
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
