# Running audiojoe securely

*This page describes the current release. For an older version, see the same page under that
version's tag on GitHub (`https://github.com/joeMJ/audiojoe/tree/vX.Y.Z/docs`). The help pages
built into your server under `/docs/` always match the installed version.*

Recommendations for running audiojoe for longer: which ports must be open, how the container and
the service are restricted, accounts, updates and the way back, and what to bear in mind if
audiojoe is reachable from the internet. Which libraries answer before the sign-in is in
[Components reachable over HTTPS](SECURITY-COMPONENTS.en.md); backups are in
[Backup and restore](BACKUP.en.md).

## What must be reachable

| Port | From where | Purpose |
|---|---|---|
| `listen` (8080 with the scripts) | **only the reverse proxy** | apps and web player, through the proxy with HTTPS |
| `[sonos] listen` (8081) | **only the home network** (the speakers) | Sonos fetches the audio; never forward it in the proxy |
| outgoing HTTPS | to the internet | sources, podcast feeds, Radio Browser, fyyd, MusicBrainz, GitHub (updates), Debian mirrors |

Nothing else needs to come in. TLS is done by the proxy; audiojoe itself only speaks HTTP.

## Firewall in the container (nftables)

Example for `/etc/nftables.conf`; put in the address of your proxy and your home network:

```
#!/usr/sbin/nft -f
# audiojoe: only the proxy reaches the server, only the home network the Sonos port.
flush ruleset

define PROXY = 10.0.0.5          # address of the reverse proxy
define HOME  = 10.0.0.0/24       # home network (Sonos speakers, SSH)

table inet filter {
  chain input {
    type filter hook input priority filter; policy drop;
    iif lo accept
    ct state established,related accept
    ct state invalid drop
    meta l4proto { icmp, ipv6-icmp } accept
    tcp dport 22   ip saddr $HOME  accept   # SSH, only if used
    tcp dport 8080 ip saddr $PROXY accept   # audiojoe-server (listen)
    tcp dport 8081 ip saddr $HOME  accept   # Sonos stream port ([sonos] listen)
  }
  chain forward {
    type filter hook forward priority filter; policy drop;
  }
}
```

```bash
sudo apt install nftables            # already there in the Debian container
sudo nft -c -f /etc/nftables.conf    # check only
sudo systemctl enable --now nftables
sudo systemctl restart nftables      # load the new rules
```

Tried out in an unprivileged Debian 13 container (also after a restart): the proxy reaches the
server, other computers do not; the Sonos port answers in the home network; updates and the
connections to sources keep working. With `IP=dhcp` the replies of the DHCP server have to be
allowed as well (`udp dport 68 accept`; not tried out). Instead of nftables in the container, the
[Proxmox firewall](https://pve.proxmox.com/wiki/Firewall) can filter the container's traffic.

## Container and service

- **Container:** the Proxmox script creates an **unprivileged** container: root in the container is
  not root on the host. Without a root password (the script's default) the container can only be
  entered from the Proxmox console; root login over SSH is off unless you switch it on.
- **Service:** `audiojoe-server` runs as its own user `audiojoe` without any privileges. systemd
  restricts it further (`packaging/deb/audiojoe-server.service`): it can write only to
  `/var/lib/audiojoe`, sees no home directories and devices, has no capabilities, may not create
  executable memory and only uses network and local sockets. `systemd-analyze security
  audiojoe-server` rates it 1.4 ("OK"; the scale goes from 0 to 10, lower is better).
- **Files:** database and its WAL only for `audiojoe` (`600`), `config.toml` only for root and the
  group `audiojoe` (`640`).
- **Updates of the system:** `unattended-upgrades` installs the Debian updates daily
  ([Updates and maintenance](install-server.en.md#updates-and-maintenance)).
- **Proxmox host:** outside of audiojoe. Keep it up to date and make its web interface (port 8006)
  and SSH reachable only from the network you administer from; see the
  [Proxmox VE documentation](https://pve.proxmox.com/pve-docs/pve-admin-guide.html).

## Accounts and access keys

- **One account per person** (`audiojoe-server user add <name>`, see
  [Getting started](ERSTE-SCHRITTE.en.md#adding-users)). Every sign-in needs password **and** the
  code of the authenticator app; there is no way to switch that off.
- **Lost device:** in the app under **Settings → Devices** sign out that device. A new password
  (`audiojoe-server user passwd <name>`) or a new authenticator secret
  (`audiojoe-server user totp-reset <name>`) ends all sign-ins of that user.
- **Podcast apps** (gpodder sync) get an **app password** of their own; it is only valid for the
  sync, not for signing in ([Manual](ANLEITUNG.en.md)).
- **Sources:** give audiojoe a user of its own with only the rights it needs – reading; for
  Audiobookshelf also saving the listening progress. Its access key is stored on the server only.

## Updates and the way back

- **Automatically:** every night at 04:00 with a backup before and an automatic way back if the new
  version does not start ([Updates and maintenance](install-server.en.md#updates-and-maintenance)).
  Who wants to decide first switches to **Only report** in the app.
- **By hand to an older version** – e.g. if a new version runs but does not work as expected:

  ```bash
  V=0.1.6                                   # the version you want
  cd /tmp
  curl -fsSLO https://github.com/joeMJ/audiojoe/releases/download/v$V/audiojoe-server_${V}_amd64.deb
  curl -fsSLO https://github.com/joeMJ/audiojoe/releases/download/v$V/SHA256SUMS
  sha256sum -c --ignore-missing SHA256SUMS  # must say "OK"
  sudo systemctl stop audiojoe-server
  sudo apt-get install --allow-downgrades ./audiojoe-server_${V}_amd64.deb
  ```

  Then put back the database backup made **before** the update to the newer version
  (`/var/backups/audiojoe/audiojoe-<old version>-<time>.db`, see
  [Restore on the same server](BACKUP.en.md#restore-on-the-same-server)): an older server does not
  know the changes a newer version made to the database. Switch to **Only report** or stop the
  timer (`systemctl disable --now audiojoe-update.timer`), otherwise the newer version comes back
  the next night.

## Reachable from the internet

What can be reached without a sign-in is small: the pages of the web player, the help pages,
`/api/v1/health`, the sign-in and the gpodder paths (they answer "unauthorized" without an app
password); details in [Components reachable over HTTPS](SECURITY-COMPONENTS.en.md). Still:

- **Do you need it?** If only you listen from outside, a VPN into your home network is the smaller
  surface; then the proxy need not be reachable from the internet at all.
- **Limit access** in the proxy to networks you know (an access list, e.g. your mobile provider and
  your home connection) and use HTTPS only.
- **Never** forward the Sonos port.
- **Keep it up to date:** leave the nightly update on; a vulnerability in one of the libraries
  reachable before the sign-in calls for an update soon.
- **Watch the log:** `journalctl -u audiojoe-server` shows per request IP address, method, path,
  status and duration (kept 14 days); many `401` on `/api/v1/auth/login` mean somebody is trying. After 5 failed sign-ins
  within 15 minutes – per IP address and per user name – the server answers `429` for the rest of
  that time.
