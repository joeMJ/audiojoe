# Installation

audiojoe consists of the **server** (one program with an SQLite database, meant for a Linux
container in the home network) and the **apps**: Android, Linux and Windows, plus the web player
the server serves itself.

> [!NOTE]
> Ready-made packages, an installation script for Proxmox and automatic updates come with the first
> release (`v0.1.0`). Until then the server is built from source as described below.

## Server

### Requirements

- Debian 13, e.g. as an unprivileged LXC container on Proxmox. Building needs considerably more
  memory and time than running.
- `ffmpeg` to convert hi-res FLAC (offline in the car, Sonos).
- To build: Rust (via [rustup](https://rustup.rs)), Node.js with npm, `build-essential`.
- A reverse proxy with HTTPS in front of it (e.g. Nginx Proxy Manager, Caddy, Nginx). The server
  itself only speaks HTTP and should only listen in the home network.

### Building and setting up

```bash
apt install ffmpeg build-essential nodejs npm git
git clone https://github.com/joeMJ/audiojoe.git && cd audiojoe
cargo build --release
(cd clients/web && npm install && npm run build)

useradd --system --home-dir /var/lib/audiojoe --shell /usr/sbin/nologin audiojoe
install -m 755 target/release/audiojoe-server /usr/local/bin/
mkdir -p /usr/share/audiojoe && cp -r clients/web/dist /usr/share/audiojoe/web
install -d -m 750 -g audiojoe /etc/audiojoe
install -m 640 -g audiojoe packaging/lxc/config.example.toml /etc/audiojoe/config.toml
install -m 644 packaging/lxc/audiojoe-server.service /etc/systemd/system/
install -D -m 644 packaging/lxc/journald-audiojoe.conf /etc/systemd/journald.conf.d/audiojoe.conf
```

In `/etc/audiojoe/config.toml` enter your own address in the home network (`listen`) and the
proxy's address (`trusted_proxies`), then start the server and add the first user
([Getting started](ERSTE-SCHRITTE.en.md#adding-users)):

```bash
systemctl daemon-reload && systemctl enable --now audiojoe-server
runuser -u audiojoe -- audiojoe-server user add anna
```

The systemd unit runs as a user of its own with hardened rights; the database is in
`/var/lib/audiojoe/`, the log in the journal (14 days, see
[Privacy](DATENSCHUTZ.en.md#what-the-server-stores)).

### HTTPS through the proxy

The proxy forwards `https://audio.example.org` to `http://<listen address>`. Important:

- **Streaming:** do not buffer responses; the live connection `/api/v1/events` (server-sent
  events) stays open for a long time.
- **Reachability:** if you make the server reachable from the internet, limit access to known
  networks. Without signing in, only the web player's pages, the documentation under `/docs/`,
  `/api/v1/health` and `/api/v1/auth/login` are reachable; everything else needs a sign-in with
  password and TOTP code.

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

- **Android:** signed APK. Until the first release it is built from source:
  `cd clients/app && flutter build apk --release`.
- **Linux (Ubuntu 24.04 / 26.04):** in the folder `clients/app` run `flutter build linux --release`,
  then `../../tools/build-deb.sh` – this makes a `.deb`. Playback needs `libmpv2` from the system.
- **Windows 10/11:** `flutter build windows --release`; an installer follows with the first
  release.
- **Web player:** nothing to install – open the server address in the browser, in the car e.g. in
  the Tesla's browser. It can be put on the home screen as an app.
