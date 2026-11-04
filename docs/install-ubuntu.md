# audiojoe unter Ubuntu installieren

*Diese Seite beschreibt das aktuelle Release. Für eine ältere Version gilt dieselbe Seite unter dem
Schild dieser Version auf GitHub (`https://github.com/joeMJ/audiojoe/tree/vX.Y.Z/docs`). Die im
Server eingebauten Hilfeseiten unter `/docs/` passen immer zur installierten Version.*

Für Ubuntu 24.04 und 26.04 (amd64) gibt es ein Paket (`.deb`); dasselbe Paket passt auch für
[Debian 13](install-debian.md). Die App braucht einen audiojoe-Server
([Server installieren](install-server.md)). Am einfachsten installiert das Skript das Paket aus
dem neuesten Release:

```bash
curl -fsSL https://raw.githubusercontent.com/joeMJ/audiojoe/main/install.sh | bash
```

Das Skript prüft Ubuntu-Version und Architektur, lädt das Paket und die Datei `SHA256SUMS`,
prüft die Prüfsumme und installiert mit `sudo apt-get install`. Derselbe Befehl aktualisiert eine
vorhandene Installation.

**Erst lesen, dann ausführen** (empfohlen): Der Einzeiler oben führt das Skript aus, ohne dass du
es vorher siehst. Wer das nicht will, lädt es zuerst, liest es und startet es dann:

```bash
curl -fsSL -o install-audiojoe.sh https://raw.githubusercontent.com/joeMJ/audiojoe/main/install.sh
less install-audiojoe.sh
bash install-audiojoe.sh
```

Von Hand: Auf der [Release-Seite](https://github.com/joeMJ/audiojoe/releases/latest) das Paket
`audiojoe_<Version>_amd64.deb` laden (nicht `audiojoe-server_…`, das ist der Server), die
Prüfsumme mit `SHA256SUMS` vergleichen und installieren:

```bash
sha256sum -c --ignore-missing SHA256SUMS
sudo apt install ./audiojoe_<Version>_amd64.deb
```

audiojoe erscheint danach im Anwendungsmenü; im Terminal startet es mit `audiojoe`. Die
Wiedergabe nutzt `libmpv2` vom System, die Anmeldung liegt im Schlüsselbund (`libsecret`); apt
installiert beides mit.

Entfernen:

```bash
sudo apt remove audiojoe
```

Positionen, Offline-Titel und Einstellungen bleiben dabei in
`~/.local/share/io.github.joemj.audiojoe/`, die Anmeldung im Schlüsselbund.

## Updates

Ist der Server aus dem Paket installiert, zeigt die App eine neue Version unter
**Einstellungen → Pflege** in der Zeile **App** an. **Version … herunterladen** lädt das Paket über den
eigenen Server und prüft es gegen `SHA256SUMS` desselben Releases; stimmt die Prüfsumme nicht,
wird nichts installiert. Danach zeigt die App den Befehl `pkexec apt-get install -y …`, installiert
nach **Installieren** (das System fragt nach dem Kennwort) und bietet **Neu starten** an. Die App fragt dafür nie GitHub, siehe [Datenschutz](DATENSCHUTZ.md#updates-nur-mit-dem-server-paket).
Ebenso aktualisiert der Installationsbefehl oben.

## Aus dem Quelltext

Im Ordner `clients/app` `flutter build linux --release`, dann `../../tools/build-deb.sh` – das
erzeugt ein `.deb`.
