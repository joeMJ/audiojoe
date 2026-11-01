# Server installieren

audiojoe besteht aus dem **Server** (ein Programm mit SQLite-Datenbank, gedacht für einen
Linux-Container oder eine VM im Heimnetz) und den **Apps** für Ubuntu, Debian, Windows und Android
(eigene Seiten, siehe [Apps](#apps)) sowie dem Web-Player, den der Server selbst ausliefert.

> [!NOTE]
> Die Pakete und das Proxmox-Skript holen den Server aus den GitHub-Releases; die gibt es ab dem
> ersten Release (`v0.1.0`). Bis dahin wird der Server aus dem Quelltext gebaut (unten).

## Server

Vier Wege, vom einfachsten zum aufwendigsten:

1. **Proxmox:** ein Skript legt einen fertigen Container an (empfohlen).
2. **Ubuntu Server 24.04 / 26.04:** ein Skript richtet audiojoe in einer vorhandenen VM ein.
3. **Debian-Paket** auf einem vorhandenen Debian 13 oder Ubuntu 24.04/26.04.
4. **Aus dem Quelltext** bauen.

Davor gehört ein Reverse Proxy mit HTTPS (z. B. Nginx Proxy Manager, Caddy, Nginx); der Server
spricht selbst nur HTTP und soll nur im Heimnetz lauschen.

### Proxmox (Container per Skript)

Auf dem Proxmox-Host als `root`:

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/joeMJ/audiojoe/main/packaging/proxmox/audiojoe-lxc.sh)"
```

**Erst lesen, dann ausführen** (empfohlen): Der Einzeiler oben führt das Skript aus, ohne dass du
es vorher siehst. Wer das nicht will, lädt es zuerst, liest es und startet es dann:

```bash
curl -fsSL -o audiojoe-lxc.sh https://raw.githubusercontent.com/joeMJ/audiojoe/main/packaging/proxmox/audiojoe-lxc.sh
less audiojoe-lxc.sh
bash audiojoe-lxc.sh
```

Das Skript fragt in Dialogen (ähnlich den Proxmox Helper Scripts) zuerst nach den Ressourcen –
**optimal** (2 Kerne, 2 GB RAM, 16 GB Platte, empfohlen) oder **Minimum** (1 Kern, 1 GB RAM,
8 GB Platte) –, dann nach Kernen (mehr als die Stufe, nie weniger), Platte (Vorschlag der Stufe,
mindestens 8 GB), Container-Nummer, Name, Speicher, Bridge, Netz (feste Adresse oder
DHCP), Gateway, DNS-Server (leer: wie der Host), der IP-Adresse des **Reverse Proxys**, über den
audiojoe veröffentlicht wird (z. B. Nginx Proxy Manager; kein Proxy für Downloads), Sonos und dem Namen des
ersten Benutzers; Enter übernimmt den Vorschlag. Eine Zusammenfassung zeigt alles vor dem
Anlegen. Dann:

- legt es einen **unprivilegierten Debian-13-Container** an (Start mit dem Host),
- installiert das Server-Paket aus dem neuesten Release (Prüfsumme aus `SHA256SUMS`),
- schreibt `/etc/audiojoe/config.toml` mit der Adresse des Containers (Port 8080, Sonos 8081),
- richtet die **Selbstpflege** ein (siehe [Updates und Pflege](#updates-und-pflege)),
- legt den **ersten Benutzer** an und zeigt Passwort und TOTP-Schlüssel einmal an.

Ohne Rückfragen, z. B. für Wiederholungen (`PRESET=minimal` für die kleinen Ressourcen):
`CTID=120 IP=10.0.0.20/24 GW=10.0.0.1 DNS=10.0.0.1 PROXY=10.0.0.10 ADMIN=anna bash audiojoe-lxc.sh --yes`.
`DRY_RUN=1` zeigt nur, was geschehen würde.

### Ubuntu Server 24.04 / 26.04 (VM per Skript)

In einer Ubuntu-Server-VM (24.04 oder 26.04, auch die Minimal-Fassung) mit fester Adresse im
Heimnetz, als Benutzer mit `sudo`:

```bash
sudo bash -c "$(curl -fsSL https://raw.githubusercontent.com/joeMJ/audiojoe/main/packaging/ubuntu/audiojoe-ubuntu.sh)"
```

**Erst lesen, dann ausführen** (empfohlen): Der Einzeiler oben führt das Skript aus, ohne dass du
es vorher siehst. Wer das nicht will, lädt es zuerst, liest es und startet es dann:

```bash
curl -fsSL -o audiojoe-ubuntu.sh https://raw.githubusercontent.com/joeMJ/audiojoe/main/packaging/ubuntu/audiojoe-ubuntu.sh
less audiojoe-ubuntu.sh
sudo bash audiojoe-ubuntu.sh
```

Das Skript fragt in denselben Dialogen wie das Proxmox-Skript nach der Adresse, unter der
audiojoe im Heimnetz lauscht (Vorschlag: die Adresse der VM), der IP-Adresse des **Reverse
Proxys**, über den audiojoe veröffentlicht wird (kein Proxy für Downloads), Sonos und dem Namen
des ersten Benutzers. Fehlt `whiptail` (Minimal-Ausgabe), installiert es das Ubuntu-Paket dafür
zuerst. Eine Zusammenfassung zeigt alles vor dem Einrichten. Dann:

- aktualisiert es Ubuntu und installiert das Server-Paket aus dem neuesten Release (Prüfsumme aus
  `SHA256SUMS`),
- schreibt `/etc/audiojoe/config.toml` (Port 8080, Sonos 8081),
- richtet die **Selbstpflege** ein, für Ubuntu mit den Ubuntu-Paketquellen (siehe
  [Updates und Pflege](#updates-und-pflege)),
- legt den **ersten Benutzer** an und zeigt Passwort und TOTP-Schlüssel einmal an,
- zeigt am Ende die Felder für den Nginx Proxy Manager.

Einen Reverse Proxy in der VM richtet das Skript noch nicht ein; bis dahin zeigt ein vorhandener
Proxy auf die VM. Ohne Rückfragen: `sudo ADDR=10.0.0.21 PROXY=10.0.0.10 ADMIN=anna bash
audiojoe-ubuntu.sh --yes`; `DRY_RUN=1` zeigt nur, was geschehen würde.

### Debian-Paket

Auf Debian 13 oder Ubuntu 24.04/26.04 das Paket `audiojoe-server_<Version>_amd64.deb` und
`SHA256SUMS` aus dem [neuesten Release](https://github.com/joeMJ/audiojoe/releases/latest) laden,
prüfen und installieren:

```bash
sha256sum -c --ignore-missing SHA256SUMS
sudo mkdir -p /var/cache/audiojoe && sudo cp audiojoe-server_*_amd64.deb /var/cache/audiojoe/
sudo apt install /var/cache/audiojoe/audiojoe-server_*_amd64.deb
```

Das Paket bringt `ffmpeg`, `curl` und `jq` mit, legt den Benutzer `audiojoe` an und schreibt eine
Konfiguration, die nur auf `127.0.0.1:8080` lauscht. In `/etc/audiojoe/config.toml` die eigene
Adresse im Heimnetz (`listen`) und die Adresse des Proxys (`trusted_proxies`) eintragen, dann
neu starten und den ersten Benutzer anlegen ([Erste Schritte](ERSTE-SCHRITTE.md#benutzer-anlegen)):

```bash
sudo systemctl restart audiojoe-server
sudo runuser -u audiojoe -- audiojoe-server user add anna
```

Das Paket in `/var/cache/audiojoe/` ist der Rückweg für das erste automatische Update; ohne es
holt `audiojoe-update` die installierte Version noch einmal aus dem Release.

### Aus dem Quelltext

Voraussetzungen: Rust (über [rustup](https://rustup.rs)), Node.js mit npm, `build-essential`,
`ffmpeg`. Das Bauen braucht deutlich mehr Speicher und Zeit als der Betrieb.

```bash
apt install ffmpeg build-essential nodejs npm git curl jq
git clone https://github.com/joeMJ/audiojoe.git && cd audiojoe
cargo build --release -p audiojoe-server
(cd clients/web && npm install && npm run build)
tools/build-server-deb.sh        # → target/deb/audiojoe-server_<Version>_amd64.deb
apt install ./target/deb/audiojoe-server_*_amd64.deb
```

Weiter wie beim [Debian-Paket](#debian-paket). Die systemd-Einheit läuft als eigener Benutzer mit
gehärteten Rechten; die Datenbank liegt in `/var/lib/audiojoe/`, das Protokoll im Journal
(14 Tage, siehe [Datenschutz](DATENSCHUTZ.md#was-der-server-speichert)).

### Updates und Pflege

Mit dem Paket hält sich der Server selbst aktuell; **Einstellungen → Pflege** in der App zeigt den
Stand.

- **Server:** Jede Nacht um 04:00 fragt `audiojoe-update` (Timer `audiojoe-update.timer`) nach
  dem neuesten Release. Ist es neuer, wird zuerst die **Datenbank gesichert**
  (`/var/backups/audiojoe/`, die letzten 5 bleiben), dann das neue Paket nach Prüfung der
  Prüfsumme installiert. Antwortet der Server nicht innerhalb von 60 Sekunden mit der neuen
  Version, kommen **das vorige Paket und die Sicherung zurück**; diese Version wird nachts nicht
  noch einmal versucht.
- **Nur melden:** In der App lässt sich „Um 04:00 aktualisieren“ auf „Nur melden“ umstellen; dann
  zeigt die App die neue Version und **Jetzt aktualisieren** spielt sie ein.
- **Ubuntu** (vom Ubuntu-Skript eingerichtet): wie Debian, mit den Ubuntu-Paketquellen
  (`/etc/apt/apt.conf.d/52audiojoe-upgrades`, vom Skript geschrieben).
- **Debian** (vom Proxmox-Skript eingerichtet): `unattended-upgrades` spielt täglich alle
  Debian-Updates ein, nicht nur Sicherheitsupdates, und entfernt nicht mehr benötigte Pakete
  (`/etc/apt/apt.conf.d/52audiojoe-upgrades`). Auf einem eigenen Debian lässt sich das genauso
  einrichten: `apt install unattended-upgrades` und
  `cp /usr/share/audiojoe/52audiojoe-upgrades /etc/apt/apt.conf.d/`.
- **Von Hand:** `audiojoe-update --check` prüft nur, `audiojoe-update --now` aktualisiert sofort.
  Ganz abschalten: `systemctl disable --now audiojoe-update.timer audiojoe-update.path`.
- **Quelle:** `/etc/audiojoe/update.conf` (`SOURCE`, Vorgabe das GitHub-Repository).

### HTTPS über den Proxy

Der Proxy leitet `https://audio.example.org` an `http://<listen-Adresse>` weiter. Wichtig:

- **Streaming:** Antworten nicht puffern; die Live-Verbindung `/api/v1/events` (Server-Sent
  Events) bleibt lange offen.
- **Erreichbarkeit:** Wer den Server aus dem Internet erreichbar macht, sollte den Zugang auf
  bekannte Netze beschränken. Ohne Anmeldung erreichbar sind nur die Seiten des Web-Players, die
  Dokumentation unter `/docs/`, `/api/v1/health` und `/api/v1/auth/login`; alles andere verlangt
  eine Anmeldung mit Passwort und TOTP-Code. Die Pfade `/api/2/…` und `/subscriptions/…` (Abgleich
  mit anderen Podcast-Apps) verlangen Benutzername und App-Passwort; ohne App-Passwort antworten
  sie nur mit „nicht angemeldet“.

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

Jede App hat eine eigene Seite mit Installation, Updates und Hinweisen:

- **Ubuntu 24.04 / 26.04:** [audiojoe auf Ubuntu installieren](install-ubuntu.md)
- **Debian 13:** [audiojoe auf Debian installieren](install-debian.md)
- **Windows 10/11:** [audiojoe auf Windows installieren](install-windows.md)
- **Android (ab 7.0):** [audiojoe auf Android installieren](install-android.md)
- **Web-Player:** keine Installation – die Server-Adresse im Browser öffnen, im Auto z. B. im
  Browser des Tesla. Er lässt sich als App auf dem Startbildschirm ablegen.
