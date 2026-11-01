# Datenschutz und Netzzugriffe

audiojoe sendet keine Nutzungsdaten und hat keine Telemetrie und keine Absturzberichte. Die
einzige Prüfung auf neue Versionen macht der Server, wenn er aus dem Paket installiert ist
([Updates](#updates-nur-mit-dem-server-paket)). Alle Zugriffe nach außen macht der **Server**; die Apps und der Web-Player
verbinden sich nur mit dem eigenen audiojoe-Server. Bei jedem Zugriff auf einen fremden Server
wird, wie bei jedem Netzzugriff, die IP-Adresse des audiojoe-Servers übermittelt, dazu die
Kennung `audiojoe/<Version>`. Die IP-Adresse und die Browserkennung der Geräte gibt der Server
nicht weiter. Leiten Anbieter auf andere Adressen weiter (z. B. Feeds auf ein CDN), folgt der
Server der Weiterleitung.

## Immer, sobald eingerichtet

- **Podcast-Feeds:** Jeder abonnierte Feed wird stündlich abgerufen (erstmals 60 Sekunden nach
  dem Start), dazu beim Abonnieren, beim Aktualisieren von Hand und beim OPML-Import. Der Server
  fragt mit `If-None-Match`/`If-Modified-Since` nur nach Änderungen.
- **Folgen, Bilder und Kapitel:** Beim Abspielen oder Herunterladen holt der Server die
  Audiodatei beim Anbieter (Feed-Server oder CDN) und reicht sie an das Gerät durch; er speichert
  sie nicht. Bilder holt er, wenn ein Gerät sie anzeigt. Kapitel holt er beim ersten Öffnen einer
  Folge und speichert sie: die Kapiteldatei aus dem Feed (Podcasting 2.0) oder, bei MP3 ohne
  Kapiteldatei, die ersten 2 MB der Folge, um die Kapitelmarken (ID3) zu lesen.
- **Eingetragene Quellen** (Jellyfin, Emby, Plex, Audiobookshelf): nur der eingetragene Server –
  Bibliotheken, Stöbern, Suche (mit dem Suchbegriff), Cover und Wiedergabe.
  - **Jellyfin, Emby, Plex** werden nur gelesen; audiojoe meldet dorthin weder Fortschritt noch
    „gehört“.
  - **Audiobookshelf:** Der Hörfortschritt wird in beide Richtungen abgeglichen – alle
    5 Minuten, beim Öffnen eines Hörbuchs und nach jeder Änderung –, und zwar nur für den
    audiojoe-Benutzer, der die Quelle angelegt hat.
  - **Albenverzeichnis (Musik):** Sobald eine Musikbibliothek einmal geöffnet wurde, fragt der
    Server täglich (einstellbar: wöchentlich, nur von Hand), ob sich die Bibliothek geändert hat.
    Nach einem Neuaufbau liest er bei Jellyfin und Emby je Album die ersten 256 KB des ersten
    Titels, um das Label aus den Tags zu lesen (eine Anfrage alle 250 ms).
  - Die Zugangsschlüssel liegen in der Datenbank des Servers und gehen nur an die jeweilige
    Quelle; die Apps bekommen sie nie zu sehen.

## Nur bei Nutzung

- **Radio Browser** ([radio-browser.info](https://www.radio-browser.info)): Die Sendersuche geht
  mit dem Suchbegriff an einen zufällig gewählten Server aus der Liste von
  `all.api.radio-browser.info`. Beim Abspielen eines Senders meldet audiojoe dem Verzeichnis einen
  Klick mit der Kennung des Senders, wie es das Verzeichnis erbittet. Stream und Logo holt der
  Server direkt beim Sender (Adressen aus dem Verzeichnis).
- **Podcast-Suche:** Der Suchbegriff geht an [fyyd](https://fyyd.de) (`api.fyyd.de`), ohne Konto.
- **Links in Shownotes:** Die App öffnet einen Link erst, wenn du darauf tippst, im Browser. Der
  Web-Player zeigt Links nur als Text.

## Nur wenn eingeschaltet

- **Labels von MusicBrainz** (standardmäßig aus; **Einstellungen → Musik**): Für Alben, deren
  Dateien kein Label nennen und für die Jellyfin oder Emby eine MusicBrainz-Kennung kennt, fragt
  der Server `musicbrainz.org` nach dem Label. Gesendet wird nur die Kennung der
  Veröffentlichung, dazu in der Kennung des Programms die Kontaktadresse, die MusicBrainz
  verlangt; höchstens eine Anfrage pro Sekunde, jedes Album nur einmal. Die Labels gehören zu den
  Kerndaten von MusicBrainz und stehen unter
  [CC0](https://musicbrainz.org/doc/About/Data_License).
- **Sonos** (nur mit dem Abschnitt `[sonos]` in der Konfiguration): nur im Heimnetz, Port 1400
  der Lautsprecher. Der Server fragt alle 10 Sekunden die eingetragenen Lautsprecher nach ihrer
  Gruppe und dem Wiedergabestand, damit die Position eines dort gespielten Titels gespeichert
  wird. An den Lautsprecher gehen Titel, Untertitel und eine signierte
  Stream-Adresse, die 24 Stunden gilt; der Lautsprecher holt den Strom über einen eigenen Port,
  der nur im Heimnetz erreichbar sein soll. „Suchen“ fragt nur den eingetragenen Adressbereich
  ab (höchstens 64 Adressen), ohne Multicast.
- **Umrechnung:** Für Hi-Res-FLAC, das ein Ziel nicht abspielen kann (Offline-Speicher im Auto,
  Sonos), startet der Server `ffmpeg`; es holt die Datei selbst bei der Quelle.

## Updates (nur mit dem Server-Paket)

- **Server:** Jede Nacht um 04:00 fragt `audiojoe-update` mit `curl` die Release-Liste des
  Repositorys ab (`api.github.com`, Adresse in `/etc/audiojoe/update.conf`). Gesendet werden
  nur die IP-Adresse des Servers und die Kennung von `curl`, keine Version und keine Kennung der
  Installation. Ist ein neueres Release da, lädt der Server Paket und Prüfsummen bei GitHub. Auch
  „Nur melden“ fragt nachts ab; ganz abschalten:
  `systemctl disable --now audiojoe-update.timer audiojoe-update.path`.
- **Debian** (nur vom Proxmox-Skript eingerichtet): `unattended-upgrades` fragt täglich die
  Debian-Paketquellen (`deb.debian.org`, `security.debian.org`) und lädt Updates von dort.
- **Pflege-Übersicht:** Was die App unter **Einstellungen → Pflege** zeigt (Versionen, letzte
  Debian-Updates, Sicherungen), liegt nur auf dem Server
  (`/var/lib/audiojoe/update-status.json`); Sicherungen der Datenbank in
  `/var/backups/audiojoe/` (die letzten 5).
- **Apps:** Die Apps fragen nie GitHub. Beim Start fragt die App ihren eigenen audiojoe-Server,
  welche Version das zuletzt vom Server gesehene Release hat, und zeigt eine neuere einmal an
  („Später“ schweigt bis zur nächsten Version). Erst auf Tippen lädt die App das
  Installationsprogramm – über den Server, der es vom Release-Host holt und durchreicht –
  und übergibt es dem System: Android fragt vor der Installation, Linux und Windows öffnen die
  gespeicherte Datei (Ordner „Downloads“). Die F-Droid-Fassung prüft nicht; der Web-Player
  kommt immer vom Server.

## Was der Server speichert

In der Datenbank (`/var/lib/audiojoe/audiojoe.db`):

- **Benutzer:** Name, Passwort als Argon2id-Hash, TOTP-Schlüssel.
- **Anmeldungen je Gerät:** Gerätename (frei wählbar), Zeitpunkt der Anmeldung und der letzten
  Nutzung; vom Zugangsschlüssel nur eine Prüfsumme. Abgelaufene Anmeldungen löscht der Server bei
  der nächsten Anmeldung.
- **Hörstand je Benutzer und Titel:** Position, Dauer, „gehört“, Titel und das Gerät, das zuletzt
  gespielt hat – also auch, was wann auf welchem Gerät lief. Dazu die Weiterhören-Listen, die
  Warteschlange je Gerät, Radio-Favoriten und ausgeblendete Bibliotheken.
- **Quellen:** Art, Name, Adresse, Zugangsschlüssel. Quellen, Sonos-Lautsprecher und die
  Musik-Einstellungen gelten für alle Benutzer des Servers.
- **Zwischenspeicher:** Podcasts und Folgen samt Beschreibungen und Kapiteln, Senderdaten aus
  Radio Browser, das Albenverzeichnis.

Medien und Bilder speichert der Server nicht.

**Protokoll:** je Anfrage IP-Adresse des Geräts (hinter einem eingetragenen Proxy die
weitergereichte), Methode, Pfad, Status und Dauer. Der Pfad enthält die Kennung dessen, was
abgespielt wurde; Abfrageparameter und Sonos-Adressen werden nicht protokolliert. Dazu
Anmeldungen (Benutzername, Gerätename; bei Fehlschlägen die IP-Adresse) und Fehler der Quellen.
Im Container hält journald das Protokoll 14 Tage.

**Löschen:** Abbestellen löscht die eigenen Hörstände des Podcasts, das Entfernen einer Quelle
alle Hörstände aus ihr, das Löschen eines Benutzers (`audiojoe-server user delete NAME`) alles,
was zu ihm gehört.

## Was die Geräte speichern

- **App:** die Anmeldung (Server-Adresse, Zugangsschlüssel, Gerätename) im sicheren Speicher des
  Systems; Hörstände, noch nicht gesendete Positionen, Titeldaten, Darstellung und Warteschlange
  im Datenordner der App; Offline-Titel unter `offline/`. Auf dem Desktop schlägt die App als
  Gerätenamen „System · Rechnername“ vor – der Name geht an den Server und lässt sich bei der
  Anmeldung ändern.
- **Web-Player:** die Anmeldung als Cookie (`HttpOnly`, `Secure`, `SameSite=Strict`);
  Hörstände, Titeldaten und Offline-Titel im Speicher des Browsers (IndexedDB, Cache);
  Darstellung, Ansichten und Warteschlange im `localStorage`.
- **Abmelden** löscht nur die Anmeldung. Offline-Titel bleiben, bis du sie entfernst (App:
  **Offline**, Web-Player: **Offline → Entfernen**).

## Anmeldung

- Passwort und Code aus einer Authenticator-App (TOTP, Pflicht); jeder Code gilt nur einmal.
- Nach 5 Fehlversuchen je Gerät oder Benutzername innerhalb von 15 Minuten sperrt der Server
  weitere Versuche für 15 Minuten.
- Eine Anmeldung gilt 180 Tage. Unter **Einstellungen → Geräte** siehst du alle Anmeldungen und
  kannst jede einzeln abmelden.
- Der Server spricht selbst nur HTTP; HTTPS übernimmt der vorgeschaltete Proxy
  ([Installation](INSTALLATION.md)).
