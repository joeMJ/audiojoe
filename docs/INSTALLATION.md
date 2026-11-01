# Installation

audiojoe besteht aus dem **Server** (ein Programm mit SQLite-Datenbank, gedacht für einen
Linux-Container im Heimnetz) und den **Apps**: Android, Linux und Windows sowie dem Web-Player, den
der Server selbst ausliefert.

> [!NOTE]
> Fertige Pakete, ein Installationsskript für Proxmox und automatische Updates kommen mit dem
> ersten Release (`v0.1.0`). Bis dahin wird der Server aus dem Quelltext gebaut, wie unten
> beschrieben.

## Server

### Voraussetzungen

- Debian 13, z. B. als unprivilegierter LXC-Container unter Proxmox. Das Bauen braucht deutlich
  mehr Speicher und Zeit als der Betrieb.
- `ffmpeg` für die Umrechnung von Hi-Res-FLAC (Offline im Auto, Sonos).
- Zum Bauen: Rust (über [rustup](https://rustup.rs)), Node.js mit npm, `build-essential`.
- Ein Reverse Proxy mit HTTPS davor (z. B. Nginx Proxy Manager, Caddy, Nginx). Der Server spricht
  selbst nur HTTP und soll nur im Heimnetz lauschen.

### Bauen und einrichten

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

In `/etc/audiojoe/config.toml` die eigene Adresse im Heimnetz (`listen`) und die Adresse des
Proxys (`trusted_proxies`) eintragen, dann starten und den ersten Benutzer anlegen
([Erste Schritte](ERSTE-SCHRITTE.md#benutzer-anlegen)):

```bash
systemctl daemon-reload && systemctl enable --now audiojoe-server
runuser -u audiojoe -- audiojoe-server user add anna
```

Die systemd-Einheit läuft als eigener Benutzer mit gehärteten Rechten; die Datenbank liegt in
`/var/lib/audiojoe/`, das Protokoll im Journal (14 Tage, siehe
[Datenschutz](DATENSCHUTZ.md#was-der-server-speichert)).

### HTTPS über den Proxy

Der Proxy leitet `https://audio.example.org` an `http://<listen-Adresse>` weiter. Wichtig:

- **Streaming:** Antworten nicht puffern; die Live-Verbindung `/api/v1/events` (Server-Sent
  Events) bleibt lange offen.
- **Erreichbarkeit:** Wer den Server aus dem Internet erreichbar macht, sollte den Zugang auf
  bekannte Netze beschränken. Ohne Anmeldung erreichbar sind nur die Seiten des Web-Players, die
  Dokumentation unter `/docs/`, `/api/v1/health` und `/api/v1/auth/login`; alles andere verlangt
  eine Anmeldung mit Passwort und TOTP-Code.

### Sonos

Sonos-Lautsprecher holen den Ton über einen eigenen Port ohne Anmeldung (mit signierten,
24 Stunden gültigen Adressen). Dieser Port darf **nur im Heimnetz** erreichbar sein:

```toml
[sonos]
listen = "10.0.0.20:8081"          # Adresse im Heimnetz, von den Lautsprechern erreichbar
scan = "10.0.0.230-10.0.0.240"     # optional: Bereich für die Suche nach Lautsprechern
```

Lautsprecher eintragen: [Erste Schritte](ERSTE-SCHRITTE.md#sonos).

## Apps

- **Android:** signierte APK. Bis zum ersten Release wird sie aus dem Quelltext
  gebaut: `cd clients/app && flutter build apk --release`.
- **Linux (Ubuntu 24.04 / 26.04):** im Ordner `clients/app` `flutter build linux --release`, dann
  `../../tools/build-deb.sh` – das erzeugt ein `.deb`. Die Wiedergabe braucht
  `libmpv2` vom System.
- **Windows 10/11:** `flutter build windows --release`; ein Installationsprogramm folgt mit dem
  ersten Release.
- **Web-Player:** keine Installation – die Server-Adresse im Browser öffnen, im Auto z. B. im
  Browser des Tesla. Er lässt sich als App auf dem Startbildschirm ablegen.
