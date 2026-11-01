# Install the server

audiojoe consists of the **server** (one program with an SQLite database, meant for a Linux
container or a VM in the home network) and the **apps** for Ubuntu, Debian, Windows and Android
(own pages, see [Apps](#apps)), plus the web player the server serves itself.

> [!NOTE]
> The packages and the Proxmox script fetch the server from the GitHub releases; those exist from
> the first release (`v0.1.0`). Until then the server is built from source (below).

## Server

Four ways, from the simplest:

1. **Proxmox:** a script creates a ready container (recommended).
2. **Ubuntu Server 24.04 / 26.04:** a script sets up audiojoe in an existing VM.
3. **Debian package** on an existing Debian 13 or Ubuntu 24.04/26.04.
4. **From source.**

A reverse proxy with HTTPS goes in front (e.g. Nginx Proxy Manager, Caddy, Nginx); the server
itself speaks plain HTTP and should listen in the home network only.

### Proxmox (container by script)

On the Proxmox host as `root`:

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/joeMJ/audiojoe/main/packaging/proxmox/audiojoe-lxc.sh)"
```

**Read first, then run** (recommended): the one-liner above runs the script without showing it
to you first. If you do not want that, download it, read it and then start it:

```bash
curl -fsSL -o audiojoe-lxc.sh https://raw.githubusercontent.com/joeMJ/audiojoe/main/packaging/proxmox/audiojoe-lxc.sh
less audiojoe-lxc.sh
bash audiojoe-lxc.sh
```

The script asks in dialogs (similar to the Proxmox helper scripts), first for the resources –
**optimal** (2 cores, 2 GB RAM, 16 GB disk, recommended) or **minimum** (1 core, 1 GB RAM, 8 GB
disk) –, then for the CPU cores (more than the preset, never fewer), the disk (proposal from the
preset, at least 8 GB), the container ID, name, storage, bridge, network (fixed address or DHCP),
gateway, DNS server (empty: like the host), the IP address of the **reverse proxy** that publishes
audiojoe (e.g. Nginx Proxy Manager; not a proxy for downloads), Sonos and the name of the
first user; Enter keeps the proposal. A summary shows everything before the container is created.
Then it:

- creates an **unprivileged Debian 13 container** (starts with the host),
- installs the server package from the newest release (checksum from `SHA256SUMS`),
- writes `/etc/audiojoe/config.toml` with the container's address (port 8080, Sonos 8081),
- sets up the **self-maintenance** (see [Updates and maintenance](#updates-and-maintenance)),
- creates the **first user** and shows password and TOTP secret once.

Without questions, e.g. to repeat it (`PRESET=minimal` for the small resources):
`CTID=120 IP=10.0.0.20/24 GW=10.0.0.1 DNS=10.0.0.1 PROXY=10.0.0.10 ADMIN=anna bash audiojoe-lxc.sh --yes`.
`DRY_RUN=1` only shows what would be done.

### Ubuntu Server 24.04 / 26.04 (VM by script)

In an Ubuntu Server VM (24.04 or 26.04, the minimal edition too) with a fixed address in the
home network, as a user with `sudo`:

```bash
sudo bash -c "$(curl -fsSL https://raw.githubusercontent.com/joeMJ/audiojoe/main/packaging/ubuntu/audiojoe-ubuntu.sh)"
```

**Read first, then run** (recommended): the one-liner above runs the script without showing it
to you first. If you do not want that, download it, read it and then start it:

```bash
curl -fsSL -o audiojoe-ubuntu.sh https://raw.githubusercontent.com/joeMJ/audiojoe/main/packaging/ubuntu/audiojoe-ubuntu.sh
less audiojoe-ubuntu.sh
sudo bash audiojoe-ubuntu.sh
```

The script asks in the same dialogs as the Proxmox script for the address audiojoe listens on in
the home network (proposal: the VM's address), the IP address of the **reverse proxy** that
publishes audiojoe (not a proxy for downloads), Sonos and the name of the first user. If `whiptail`
is missing (minimal edition), it installs the Ubuntu package for it first. A summary shows
everything before it sets up. Then it:

- updates Ubuntu and installs the server package from the newest release (checksum from
  `SHA256SUMS`),
- writes `/etc/audiojoe/config.toml` (port 8080, Sonos 8081),
- sets up the **self-maintenance**, for Ubuntu with the Ubuntu package sources (see
  [Updates and maintenance](#updates-and-maintenance)),
- creates the **first user** and shows password and TOTP secret once,
- shows the fields for Nginx Proxy Manager at the end.

The script does not set up a reverse proxy in the VM yet; until then an existing proxy points to
the VM. Without questions: `sudo ADDR=10.0.0.21 PROXY=10.0.0.10 ADMIN=anna bash
audiojoe-ubuntu.sh --yes`; `DRY_RUN=1` only shows what would be done.

### Debian package

On Debian 13 or Ubuntu 24.04/26.04 download `audiojoe-server_<version>_amd64.deb` and
`SHA256SUMS` from the [newest release](https://github.com/joeMJ/audiojoe/releases/latest), check
and install:

```bash
sha256sum -c --ignore-missing SHA256SUMS
sudo mkdir -p /var/cache/audiojoe && sudo cp audiojoe-server_*_amd64.deb /var/cache/audiojoe/
sudo apt install /var/cache/audiojoe/audiojoe-server_*_amd64.deb
```

The package brings `ffmpeg`, `curl` and `jq`, creates the user `audiojoe` and writes a
configuration that listens on `127.0.0.1:8080` only. Put the own home-network address (`listen`)
and the proxy's address (`trusted_proxies`) into `/etc/audiojoe/config.toml`, restart and add the
first user ([Getting started](ERSTE-SCHRITTE.en.md#adding-users)):

```bash
sudo systemctl restart audiojoe-server
sudo runuser -u audiojoe -- audiojoe-server user add anna
```

The package in `/var/cache/audiojoe/` is the way back for the first automatic update; without it
`audiojoe-update` fetches the installed version from the release again.

### From source

Requirements: Rust (via [rustup](https://rustup.rs)), Node.js with npm, `build-essential`,
`ffmpeg`. Building needs much more memory and time than running.

```bash
apt install ffmpeg build-essential nodejs npm git curl jq
git clone https://github.com/joeMJ/audiojoe.git && cd audiojoe
cargo build --release -p audiojoe-server
(cd clients/web && npm install && npm run build)
tools/build-server-deb.sh        # → target/deb/audiojoe-server_<version>_amd64.deb
apt install ./target/deb/audiojoe-server_*_amd64.deb
```

Continue as with the [Debian package](#debian-package). The systemd unit runs as its own user
with hardened rights; the database is in `/var/lib/audiojoe/`, the log in the journal (14 days,
see [Privacy](DATENSCHUTZ.en.md#what-the-server-stores)).

### Updates and maintenance

With the package the server keeps itself up to date; **Settings → Maintenance** in the app shows
the state.

- **Server:** every night at 04:00 `audiojoe-update` (timer `audiojoe-update.timer`) asks for the
  newest release. If it is newer, the **database is backed up** first (`/var/backups/audiojoe/`,
  the last 5 are kept), then the new package is installed after checking its checksum. If the
  server does not answer with the new version within 60 seconds, **the previous package and the
  backup are put back**; that version is not tried again at night.
- **Only report:** in the app "Update at 04:00" can be switched to "Only report"; the app then
  shows the new version and **Update now** installs it.
- **Ubuntu** (set up by the Ubuntu script): like Debian, with the Ubuntu package sources
  (`/etc/apt/apt.conf.d/52audiojoe-upgrades`, written by the script).
- **Debian** (set up by the Proxmox script): `unattended-upgrades` installs all Debian updates
  daily, not only security updates, and removes packages no longer needed
  (`/etc/apt/apt.conf.d/52audiojoe-upgrades`). On an own Debian the same works with
  `apt install unattended-upgrades` and `cp /usr/share/audiojoe/52audiojoe-upgrades /etc/apt/apt.conf.d/`.
- **By hand:** `audiojoe-update --check` only checks, `audiojoe-update --now` updates at once.
  Switch off completely: `systemctl disable --now audiojoe-update.timer audiojoe-update.path`.
- **Source:** `/etc/audiojoe/update.conf` (`SOURCE`, default the GitHub repository).

### HTTPS through the proxy

The proxy forwards `https://audio.example.org` to `http://<listen address>`. Important:

- **Streaming:** do not buffer responses; the live connection `/api/v1/events` (server-sent
  events) stays open for a long time.
- **Reachability:** if you make the server reachable from the internet, limit access to known
  networks. Without signing in, only the web player's pages, the documentation under `/docs/`,
  `/api/v1/health` and `/api/v1/auth/login` are reachable; everything else needs a sign-in with
  password and TOTP code. The paths `/api/2/…` and `/subscriptions/…` (sync with other podcast
  apps) need user name and app password; without an app password they answer "unauthorized" only.

### Sonos

Sonos speakers fetch the audio through a port of its own without a sign-in (with signed addresses
valid for 24 hours). This port must be reachable **only in the home network**:

```toml
[sonos]
listen = "10.0.0.20:8081"          # address in the home network, reachable by the speakers
scan = "10.0.0.230-10.0.0.240"     # optional: range to search for speakers
```

Adding speakers: [Getting started](ERSTE-SCHRITTE.en.md#sonos).

## Apps

Every app has its own page with installation, updates and notes:

- **Ubuntu 24.04 / 26.04:** [Install audiojoe on Ubuntu](install-ubuntu.en.md)
- **Debian 13:** [Install audiojoe on Debian](install-debian.en.md)
- **Windows 10/11:** [Install audiojoe on Windows](install-windows.en.md)
- **Android (7.0 and later):** [Install audiojoe on Android](install-android.en.md)
- **Web player:** nothing to install – open the server address in the browser, in the car e.g. in
  the Tesla's browser. It can be put on the home screen as an app.
