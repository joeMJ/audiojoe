# Troubleshooting

*This page describes the current release. For an older version, see the same page under that
version's tag on GitHub (`https://github.com/joeMJ/audiojoe/tree/vX.Y.Z/docs`).*

This page is on GitHub only, so it can be read while your own server is unreachable. Most answers
start in the log of the server:

```bash
systemctl status audiojoe-server
journalctl -u audiojoe-server -n 50 --no-pager
```

Every request is logged as one line `access: <IP> <method> <path> <status> <duration>`; warnings
and errors stand between them. The messages below are quoted exactly as the server writes them.

## The server does not start

`systemctl status audiojoe-server` shows `failed`; the cause is in the lines before
`Failed to start audiojoe-server.service`:

| Message | Cause and remedy |
|---|---|
| `invalid config /etc/audiojoe/config.toml` with `TOML parse error at line …, column …` | a typing error in `config.toml` at that place, e.g. a value without quotes – correct it |
| `Cannot assign requested address (os error 99)` | `listen` (or `[sonos] listen`) names an address this server does not have – e.g. after the IP address changed; see `ip -br address` |
| `Address already in use (os error 98)` | another program uses the port – find it with `ss -tlnp \| grep 8080` |
| `cannot open /var/lib/audiojoe/audiojoe.db` with `Unable to open the database file` | the database does not belong to the user `audiojoe` – `chown audiojoe:audiojoe /var/lib/audiojoe/audiojoe.db*` |
| `Database check failed: … is damaged (…)` | the database file is damaged – restore the latest backup as described in [Backup and restore](BACKUP.en.md#restore-on-the-same-server); more under [Damaged database or configuration](#damaged-database-or-configuration) |
| `Start request repeated too quickly` or `start of the service was attempted too often` | systemd stopped trying after several failed starts – after the fix: `systemctl reset-failed audiojoe-server && systemctl start audiojoe-server` |

The server is running when the log ends with `audiojoe-server <version> listening on <address>`
and `curl -s http://<listen address>/api/v1/health` answers `{"status":"ok","version":"…"}`.

## The reverse proxy reports an error

First ask the server directly, from the computer the proxy runs on:

```bash
curl -sS -m 5 http://<listen address>/api/v1/health
```

- **Answer `{"status":"ok",…}`:** the server is fine; check the proxy's forward target (scheme
  `http`, address and port exactly as `listen`).
- **`Could not connect to server`** (curl error 7): the server is not running ([above](#the-server-does-not-start)) or
  listens on another address. The Debian package listens on `127.0.0.1:8080` only until you set
  `listen` in `/etc/audiojoe/config.toml`.
- **`Connection timed out after 5002 milliseconds`** (curl error 28): a firewall in between – the server's port must be open for the proxy
  ([Running audiojoe securely](BETRIEB.en.md#firewall-in-the-container-nftables)).
- **All requests in the log come from the proxy's address:** put the proxy into
  `trusted_proxies` in `config.toml` and restart the server; otherwise also the limit of failed
  sign-ins counts the proxy instead of the device.
- **`429` on sign-in** (the server answers "too many attempts, try again later"): 5 failed sign-ins within
  15 minutes from the same address or for the same user name; wait 15 minutes.

## Audio does not play

Look for the line of the stream request in the log (`journalctl -u audiojoe-server -f` while you
start the title): `access: … GET /api/v1/stream/… <status>`.

- **`502` with the warning `upstream unreachable`:** the server cannot reach the source, the feed
  or the station. Test from the server: `curl -sI <address of the source>`. Radio stations are
  sometimes offline – try another one.
- **`401` or `403` passed on from the source:** the source no longer accepts audiojoe's access key –
  enter the source again under **Settings → Sources**.
- **`401` for all requests of the device:** its sign-in was ended – sign in again.
- **No stream line at all:** the device does not reach the server – see
  [The reverse proxy reports an error](#the-reverse-proxy-reports-an-error).

## Sonos cannot reach the server

- At start the log must say `Sonos stream port on <address>:8081 (LAN only)`. Without that line the
  `[sonos]` section in `config.toml` is missing.
- From a computer in the home network:
  `curl -s -o /dev/null -w "%{http_code}\n" http://<[sonos] listen>/` – `404` means reachable (the
  port only answers signed addresses). No answer: wrong address or a firewall; the speakers must
  reach this port directly, not through the proxy.
- `[sonos] listen` must be an address in the home network, not `127.0.0.1`.
- Speakers not found: set `scan` in `[sonos]` to the address range of the speakers
  ([Install the server](install-server.en.md#sonos)).

## Positions or lists are not synchronised

- **Between devices:** changes come through an event stream that stays open
  (`/api/v1/events`; the server sends a `ping` every 15 seconds). If they only arrive after a
  reload, the proxy buffers the responses – switch buffering off for audiojoe (in nginx and Nginx
  Proxy Manager: `proxy_buffering off;`) and allow long-running responses.
- **Device offline:** the app shows "1 position waiting for the server" and sends it as soon as the
  server is reachable again.
- **Audiobookshelf:** warnings `audiobookshelf sync <item>: …` in the log – the user of the source
  needs the right to save the listening progress.
- **Podcast apps (gpodder):** they need the **app password**, not the sign-in password
  ([Manual](ANLEITUNG.en.md)).
- **A podcast does not get new episodes:** warning `feed <address>: <message>` in the log – the feed
  is unreachable or invalid.

## Updates fail

**Settings → Maintenance** shows the state; the details are in
`/var/lib/audiojoe/update-status.json` and `journalctl -u audiojoe-update`. Check by hand with
`sudo audiojoe-update --check`.

| Message | Meaning |
|---|---|
| `release list not reachable: <source>` | GitHub (or the `SOURCE` in `/etc/audiojoe/update.conf`) cannot be reached – network, DNS, firewall for outgoing HTTPS |
| `package <version> could not be downloaded or its checksum is wrong` | download broken or package changed – nothing was installed; tried again the next night |
| `<version> did not start; going back to <version>` | the new version did not answer within 60 seconds; the previous package and the database backup were put back |
| `<version> failed before; not tried again (audiojoe-update --now tries it)` | after such a way back the version is skipped at night |
| `package of the installed version <version> not available, so no way back – update not started` | without the package for the way back the update does not start |

## Damaged database or configuration

- **Configuration:** the messages are in [The server does not start](#the-server-does-not-start).
  A minimal `config.toml`:

  ```toml
  listen = "10.0.0.20:8080"
  database = "/var/lib/audiojoe/audiojoe.db"
  web_root = "/usr/share/audiojoe/web"
  trusted_proxies = ["10.0.0.5"]
  ```

- **Database:** the server checks the file at every start (`PRAGMA quick_check`, since 0.1.8). If it
  is damaged, the server does not start and writes `Database check failed: … is damaged (…)`. Later
  in the log `database disk image is malformed` can appear when a damage happens during operation. Check (needs the
  package `sqlite3`):

  ```bash
  sudo apt install sqlite3
  sudo sqlite3 -readonly /var/lib/audiojoe/audiojoe.db "PRAGMA integrity_check"
  ```

  Anything but `ok` means: restore a backup – your own or the newest from `/var/backups/audiojoe/`
  ([Backup and restore](BACKUP.en.md#restore-on-the-same-server)).
