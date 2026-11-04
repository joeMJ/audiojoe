# Backup and restore

*This page describes the current release. For an older version, see the same page under that
version's tag on GitHub (`https://github.com/joeMJ/audiojoe/tree/vX.Y.Z/docs`). The help pages
built into your server under `/docs/` always match the installed version.*

All data of audiojoe is on the **server**. The apps and the web player only keep a copy
(positions not yet sent, offline titles) and get everything else from the server again. Media and
images are not stored by the server; they stay with your sources.

## What to back up

| Path | Content |
|---|---|
| `/var/lib/audiojoe/audiojoe.db` | everything: users (password as Argon2id hash, TOTP secret), sign-ins per device, positions, queues, sources with their access keys, podcasts, radio favourites, Sonos speakers and the key that signs the Sonos stream addresses |
| `/var/lib/audiojoe/update-mode` | "Update at 04:00" or "Only report" (only there once it was changed) |
| `/etc/audiojoe/` | `config.toml` (listen address, proxy, Sonos) and `update.conf` (update source) |

Not needed: `/var/lib/audiojoe/update-status.json` (written again), `/var/cache/audiojoe/`
(packages). The automatic backups before each update in `/var/backups/audiojoe/` (the last 5) are
on the same server and do not replace a backup elsewhere.

**A backup contains secrets.** With the TOTP secrets and the access keys of your sources anyone
holding the file can create sign-in codes and read your sources. Keep it like a password: on an
encrypted disk or a protected place, not in a shared folder.

## Backup with a stopped server

The database is SQLite in WAL mode: changes are first written to `audiojoe.db-wal` and later moved
into `audiojoe.db`. A copy of the files **while the server is running** can therefore be
incomplete. When the server stops cleanly, it moves everything into `audiojoe.db` and the files
`-wal` and `-shm` are gone; a copy is then complete. `audiojoe-update` makes its backup before each
update the same way. Background at the SQLite project:
[backup or restore while a transaction is active](https://www.sqlite.org/howtocorrupt.html#_backup_or_restore_while_a_transaction_is_active),
[write-ahead log](https://www.sqlite.org/wal.html).

```bash
sudo systemctl stop audiojoe-server
sudo tar -C / -czf /root/audiojoe-backup-$(date +%Y%m%d-%H%M%S).tar.gz var/lib/audiojoe etc/audiojoe
sudo systemctl start audiojoe-server
```

The server is gone for a few seconds; the apps connect again by themselves. Then copy the file to
another computer, for example `scp root@<server>:/root/audiojoe-backup-*.tar.gz .`

**Regularly** – a small script that also reports a failed start and keeps the newest 7 backups,
`/usr/local/sbin/audiojoe-backup` (`chmod 755`):

```sh
#!/bin/sh
# Consistent backup of the audiojoe server: stop for a moment, pack, start. Keeps the newest 7.
set -u
dir=/root/audiojoe-backups
mkdir -p -m 700 "$dir"
systemctl stop audiojoe-server
tar -C / -czf "$dir/audiojoe-$(date +%Y%m%d-%H%M%S).tar.gz" var/lib/audiojoe etc/audiojoe
rc=$?
systemctl start audiojoe-server || rc=1
ls -1t "$dir"/audiojoe-*.tar.gz | tail -n +8 | xargs -r rm --
exit $rc
```

and in `crontab -e` of root, for example every night at 03:30 (before the update at 04:00):

```
30 3 * * * /usr/local/sbin/audiojoe-backup
```

`/root/audiojoe-backups/` is still on the server: fetch the files from another computer
(e.g. `rsync` or `scp`) or put `dir` onto a mounted network drive.

## Backup of the whole container (Proxmox)

If audiojoe runs in a Proxmox container (e.g. set up with the Proxmox script), Proxmox can back up
the whole container while it runs:

```bash
vzdump <CTID> --mode snapshot --storage <storage> --compress zstd
```

or as a scheduled job under **Datacenter → Backup**. The copy is like the state after a sudden power
cut; SQLite brings the database back to the last completed change with the write-ahead log (WAL)
when the server starts. It contains the whole container, so the secrets as well. Details:
[Proxmox Backup and Restore](https://pve.proxmox.com/wiki/Backup_and_Restore).

## Restore on the same server

```bash
sudo systemctl stop audiojoe-server
sudo rm -f /var/lib/audiojoe/audiojoe.db-wal /var/lib/audiojoe/audiojoe.db-shm
sudo tar -C / -xzpf audiojoe-backup-<time>.tar.gz
sudo systemctl start audiojoe-server
curl -s http://<listen address>/api/v1/health
```

Remove `-wal` and `-shm` before unpacking: left over from the current database, they do not belong
to the restored one. One of the automatic backups from `/var/backups/audiojoe/` is restored the
same way, with
`sudo install -o audiojoe -g audiojoe -m 600 /var/backups/audiojoe/audiojoe-<version>-<time>.db /var/lib/audiojoe/audiojoe.db`
instead of `tar`.

What changed after the backup is lost on the server: positions, new podcasts and sign-ins. Devices
that signed in **before** the backup stay signed in; devices that signed in **after** it have to
sign in again.

## After losing the whole server

1. **Proxmox backup:** `pct restore <CTID> <vzdump file> --storage <storage> --unprivileged 1`,
   start the container – done.
2. **File backup:** set up a new server as on [Install the server](install-server.en.md), ideally
   with the same IP address. The first user the script asks for is replaced in the next step.
3. Restore as in [Restore on the same server](#restore-on-the-same-server). The backup also puts
   back `config.toml`; if the new server has another address, change `listen` (and `[sonos]
   listen`) and restart the server.
4. With another address: change the forward target in the reverse proxy.

Users, passwords and authenticator codes stay as they were – nobody has to scan a new QR code.
Devices signed in before the backup keep working.

Both ways – Proxmox backup and file backup on a newly installed container – were tried out: users
and sign-ins from before the backup worked, sign-ins made after the backup were refused.
