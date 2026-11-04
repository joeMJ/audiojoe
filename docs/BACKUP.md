# Sicherung und Wiederherstellung

*Diese Seite beschreibt das aktuelle Release. Für eine ältere Version gilt dieselbe Seite unter dem
Schild dieser Version auf GitHub (`https://github.com/joeMJ/audiojoe/tree/vX.Y.Z/docs`). Die im
Server eingebauten Hilfeseiten unter `/docs/` passen immer zur installierten Version.*

Alle Daten von audiojoe liegen auf dem **Server**. Die Apps und der Web-Player halten nur eine
Kopie (noch nicht gesendete Hörstände, Offline-Titel) und holen alles andere wieder vom Server.
Medien und Bilder speichert der Server nicht; sie bleiben bei deinen Quellen.

## Was zu sichern ist

| Pfad | Inhalt |
|---|---|
| `/var/lib/audiojoe/audiojoe.db` | alles: Nutzer (Kennwort als Argon2id-Hash, TOTP-Geheimnis), Anmeldungen je Gerät, Hörstände, Warteschlangen, Quellen mit ihren Zugangsschlüsseln, Podcasts, Radio-Favoriten, Sonos-Lautsprecher und der Schlüssel, der die Sonos-Stromadressen signiert |
| `/var/lib/audiojoe/update-mode` | „Update um 04:00“ oder „Nur melden“ (erst vorhanden, wenn es einmal umgestellt wurde) |
| `/etc/audiojoe/` | `config.toml` (Listen-Adresse, Proxy, Sonos) und `update.conf` (Update-Quelle) |

Nicht nötig: `/var/lib/audiojoe/update-status.json` (wird neu geschrieben), `/var/cache/audiojoe/`
(Pakete). Die automatischen Sicherungen vor jedem Update in `/var/backups/audiojoe/` (die letzten
5) liegen auf demselben Server und ersetzen keine Sicherung anderswo.

**Eine Sicherung enthält Geheimnisse.** Mit den TOTP-Geheimnissen und den Zugangsschlüsseln deiner
Quellen kann jeder, der die Datei hat, Anmeldecodes erzeugen und deine Quellen lesen. Bewahre sie
auf wie ein Kennwort: auf einem verschlüsselten Datenträger oder an einem geschützten Ort, nicht in
einem geteilten Ordner.

## Sicherung bei gestopptem Server

Die Datenbank ist SQLite im WAL-Modus: Änderungen landen zuerst in `audiojoe.db-wal` und werden
später in `audiojoe.db` übernommen. Eine Kopie der Dateien **bei laufendem Server** kann deshalb
unvollständig sein. Beim sauberen Stoppen übernimmt der Server alles in `audiojoe.db`, die Dateien
`-wal` und `-shm` verschwinden; eine Kopie ist dann vollständig. `audiojoe-update` sichert vor
jedem Update auf dieselbe Weise. Hintergrund beim SQLite-Projekt:
[Sichern oder Zurückspielen während einer Transaktion](https://www.sqlite.org/howtocorrupt.html#_backup_or_restore_while_a_transaction_is_active)
(englisch), [Write-Ahead Log](https://www.sqlite.org/wal.html) (englisch).

```bash
sudo systemctl stop audiojoe-server
sudo tar -C / -czf /root/audiojoe-backup-$(date +%Y%m%d-%H%M%S).tar.gz var/lib/audiojoe etc/audiojoe
sudo systemctl start audiojoe-server
```

Der Server ist ein paar Sekunden weg; die Apps verbinden sich von selbst wieder. Danach die Datei
auf einen anderen Rechner kopieren, zum Beispiel `scp root@<server>:/root/audiojoe-backup-*.tar.gz .`

**Regelmäßig** – ein kleines Skript, das auch einen fehlgeschlagenen Start meldet und die neuesten
7 Sicherungen behält, `/usr/local/sbin/audiojoe-backup` (`chmod 755`):

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

und in `crontab -e` von root, zum Beispiel jede Nacht um 03:30 (vor dem Update um 04:00):

```
30 3 * * * /usr/local/sbin/audiojoe-backup
```

`/root/audiojoe-backups/` liegt noch auf dem Server: Die Dateien von einem anderen Rechner abholen
(z. B. `rsync` oder `scp`) oder `dir` auf ein eingehängtes Netzlaufwerk legen.

## Sicherung des ganzen Containers (Proxmox)

Läuft audiojoe in einem Proxmox-Container (z. B. mit dem Proxmox-Skript eingerichtet), kann Proxmox
den ganzen Container im laufenden Betrieb sichern:

```bash
vzdump <CTID> --mode snapshot --storage <storage> --compress zstd
```

oder als geplanter Auftrag unter **Rechenzentrum → Backup**. Die Kopie entspricht dem Stand nach
einem plötzlichen Stromausfall; SQLite stellt die Datenbank beim Start des Servers mit dem
Write-Ahead Log (WAL) auf die letzte abgeschlossene Änderung. Sie enthält den ganzen Container, also
auch die Geheimnisse. Einzelheiten:
[Proxmox Backup and Restore](https://pve.proxmox.com/wiki/Backup_and_Restore) (englisch).

## Zurückspielen auf demselben Server

```bash
sudo systemctl stop audiojoe-server
sudo rm -f /var/lib/audiojoe/audiojoe.db-wal /var/lib/audiojoe/audiojoe.db-shm
sudo tar -C / -xzpf audiojoe-backup-<zeit>.tar.gz
sudo systemctl start audiojoe-server
curl -s http://<listen-adresse>/api/v1/health
```

`-wal` und `-shm` vor dem Auspacken entfernen: Übrig von der aktuellen Datenbank, gehören sie nicht
zur zurückgespielten. Eine der automatischen Sicherungen aus `/var/backups/audiojoe/` wird genauso
zurückgespielt, statt `tar` mit
`sudo install -o audiojoe -g audiojoe -m 600 /var/backups/audiojoe/audiojoe-<version>-<zeit>.db /var/lib/audiojoe/audiojoe.db`.

Was nach der Sicherung geändert wurde, ist auf dem Server verloren: Hörstände, neue Podcasts und
Anmeldungen. Geräte, die sich **vor** der Sicherung angemeldet haben, bleiben angemeldet; Geräte,
die sich **danach** angemeldet haben, müssen sich neu anmelden.

## Nach Verlust des ganzen Servers

1. **Proxmox-Sicherung:** `pct restore <CTID> <vzdump-datei> --storage <storage> --unprivileged 1`,
   Container starten – fertig.
2. **Datei-Sicherung:** einen neuen Server wie unter [Server installieren](install-server.md)
   aufsetzen, am besten mit derselben IP-Adresse. Den ersten Nutzer, nach dem das Skript fragt,
   ersetzt der nächste Schritt.
3. Zurückspielen wie unter [Zurückspielen auf demselben Server](#zurückspielen-auf-demselben-server).
   Die Sicherung bringt auch `config.toml` zurück; hat der neue Server eine andere Adresse,
   `listen` (und `[sonos] listen`) anpassen und den Server neu starten.
4. Bei anderer Adresse: im Reverse Proxy das Weiterleitungsziel ändern.

Nutzer, Kennwörter und Authenticator-Codes bleiben, wie sie waren – niemand muss einen neuen QR-Code
scannen. Geräte, die vor der Sicherung angemeldet waren, arbeiten weiter.

Beide Wege – Proxmox-Sicherung und Datei-Sicherung auf einem neu installierten Container – wurden
ausprobiert: Nutzer und Anmeldungen von vor der Sicherung funktionierten, Anmeldungen von nach der
Sicherung wurden abgewiesen.
