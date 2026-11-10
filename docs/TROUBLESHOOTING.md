# Fehlerbehebung

*Diese Seite beschreibt das aktuelle Release. Für eine ältere Version gilt dieselbe Seite unter dem
Schild dieser Version auf GitHub (`https://github.com/joeMJ/audiojoe/tree/vX.Y.Z/docs`).*

Diese Seite steht nur auf GitHub, damit sie lesbar ist, während dein eigener Server nicht erreichbar
ist. Die meisten Antworten beginnen im Protokoll des Servers:

```bash
systemctl status audiojoe-server
journalctl -u audiojoe-server -n 50 --no-pager
```

Jede Anfrage steht als eine Zeile `access: <IP> <Methode> <Pfad> <Status> <Dauer>` darin; Warnungen
und Fehler stehen dazwischen. Die Meldungen unten sind wörtlich so zitiert, wie der Server sie
schreibt (englisch).

## Der Server startet nicht

`systemctl status audiojoe-server` zeigt `failed`; die Ursache steht in den Zeilen vor
`Failed to start audiojoe-server.service`:

| Meldung | Ursache und Abhilfe |
|---|---|
| `invalid config /etc/audiojoe/config.toml` mit `TOML parse error at line …, column …` | ein Tippfehler in `config.toml` an dieser Stelle, z. B. ein Wert ohne Anführungszeichen – berichtigen |
| `Cannot assign requested address (os error 99)` | `listen` (oder `[sonos] listen`) nennt eine Adresse, die dieser Server nicht hat – etwa nachdem sich die IP-Adresse geändert hat; siehe `ip -br address` |
| `Address already in use (os error 98)` | ein anderes Programm belegt den Port – finden mit `ss -tlnp \| grep 8080` |
| `cannot open /var/lib/audiojoe/audiojoe.db` mit `Unable to open the database file` | die Datenbank gehört nicht dem Nutzer `audiojoe` – `chown audiojoe:audiojoe /var/lib/audiojoe/audiojoe.db*` |
| `Database check failed: … is damaged (…)` | die Datenbankdatei ist beschädigt – spiele die letzte Sicherung ein, wie in [Sicherung und Wiederherstellung](BACKUP.md#zurückspielen-auf-demselben-server) beschrieben; mehr unter [Datenbank oder Konfiguration beschädigt](#datenbank-oder-konfiguration-beschädigt) |
| `Start request repeated too quickly` oder `start of the service was attempted too often` | systemd hat nach mehreren Fehlstarts aufgehört – nach der Abhilfe: `systemctl reset-failed audiojoe-server && systemctl start audiojoe-server` |

Der Server läuft, wenn das Protokoll mit `audiojoe-server <version> listening on <adresse>` endet
und `curl -s http://<listen-adresse>/api/v1/health` mit `{"status":"ok","version":"…"}` antwortet.

## Der Reverse Proxy meldet einen Fehler

Zuerst den Server direkt fragen, von dem Rechner, auf dem der Proxy läuft:

```bash
curl -sS -m 5 http://<listen-adresse>/api/v1/health
```

- **Antwort `{"status":"ok",…}`:** Der Server ist in Ordnung; das Weiterleitungsziel im Proxy
  prüfen (Schema `http`, Adresse und Port genau wie `listen`).
- **`Could not connect to server`** (curl-Fehler 7): Der Server läuft nicht
  ([oben](#der-server-startet-nicht)) oder lauscht auf einer anderen Adresse. Das Debian-Paket
  lauscht nur auf `127.0.0.1:8080`, bis du `listen` in `/etc/audiojoe/config.toml` setzt.
- **`Connection timed out after 5002 milliseconds`** (curl-Fehler 28): eine Firewall dazwischen –
  der Port des Servers muss für den Proxy offen sein
  ([audiojoe sicher betreiben](BETRIEB.md#firewall-im-container-nftables)).
- **Alle Anfragen im Protokoll kommen von der Adresse des Proxys:** den Proxy in
  `trusted_proxies` in `config.toml` eintragen und den Server neu starten; sonst zählt auch die
  Grenze für Fehlanmeldungen den Proxy statt des Geräts.
- **`429` bei der Anmeldung** (der Server antwortet „too many attempts, try again later“):
  5 Fehlanmeldungen innerhalb von 15 Minuten von derselben Adresse oder für denselben Nutzernamen;
  15 Minuten warten.

## Der Ton spielt nicht

Im Protokoll die Zeile der Stromanfrage suchen (`journalctl -u audiojoe-server -f`, während du den
Titel startest): `access: … GET /api/v1/stream/… <status>`.

- **`502` mit der Warnung `upstream unreachable`:** Der Server erreicht die Quelle, den Feed oder
  den Sender nicht. Vom Server aus prüfen: `curl -sI <adresse der quelle>`. Radiosender sind
  manchmal offline – einen anderen versuchen.
- **`401` oder `403`, von der Quelle durchgereicht:** Die Quelle nimmt den Zugangsschlüssel von
  audiojoe nicht mehr an – die Quelle unter **Einstellungen → Quellen** neu eintragen.
- **`401` für alle Anfragen des Geräts:** Seine Anmeldung wurde beendet – neu anmelden.
- **Gar keine Stromzeile:** Das Gerät erreicht den Server nicht – siehe
  [Der Reverse Proxy meldet einen Fehler](#der-reverse-proxy-meldet-einen-fehler).

## Die Wiedergabe endet im Hintergrund (Android)

Hört die Wiedergabe wenige Sekunden auf, nachdem audiojoe in den Hintergrund geht, steht die Akkunutzung
der App nicht auf **Uneingeschränkt**. Im Protokoll des Servers fehlen dann ab diesem Moment die Zeilen
`POST /api/v1/playback`, die sonst alle 10 Sekunden kommen. Die Akkunutzung auf **Uneingeschränkt** stellen:
in audiojoe unter **Einstellungen → Wiedergabe** mit **Ändern**, oder in den Einstellungen von Android bei
der App. Nach einer Aktualisierung kann die Einstellung zurückgesetzt sein.

## Sonos erreicht den Server nicht

- Beim Start muss im Protokoll `Sonos stream port on <adresse>:8081 (LAN only)` stehen. Fehlt die
  Zeile, fehlt der Abschnitt `[sonos]` in `config.toml`.
- Von einem Rechner im Heimnetz:
  `curl -s -o /dev/null -w "%{http_code}\n" http://<[sonos] listen>/` – `404` heißt erreichbar (der
  Port beantwortet nur signierte Adressen). Keine Antwort: falsche Adresse oder eine Firewall; die
  Lautsprecher müssen diesen Port direkt erreichen, nicht über den Proxy.
- `[sonos] listen` muss eine Adresse im Heimnetz sein, nicht `127.0.0.1`.
- Lautsprecher werden nicht gefunden: in `[sonos]` mit `scan` den Adressbereich der Lautsprecher
  angeben ([Server installieren](install-server.md#sonos)).

## Hörstände oder Listen gleichen sich nicht ab

- **Zwischen Geräten:** Änderungen kommen über einen offen bleibenden Ereignisstrom
  (`/api/v1/events`; der Server schickt alle 15 Sekunden ein `ping`). Kommen sie erst nach dem
  Neuladen an, puffert der Proxy die Antworten – das Puffern für audiojoe abschalten (in nginx und
  Nginx Proxy Manager: `proxy_buffering off;`) und lang laufende Antworten zulassen.
- **Gerät offline:** Die App zeigt „1 Position wartet auf den Server“ und schickt sie, sobald der
  Server wieder erreichbar ist.
- **Audiobookshelf:** Warnungen `audiobookshelf sync <item>: …` im Protokoll – der Nutzer der
  Quelle braucht das Recht, den Hörstand zu speichern.
- **Podcast-Apps (gpodder):** Sie brauchen das **App-Kennwort**, nicht das Anmeldekennwort
  ([Anleitung](ANLEITUNG.md)).
- **Ein Podcast bekommt keine neuen Folgen:** Warnung `feed <adresse>: <meldung>` im Protokoll – der
  Feed ist nicht erreichbar oder fehlerhaft.

## Updates schlagen fehl

**Einstellungen → Wartung** zeigt den Stand; Einzelheiten stehen in
`/var/lib/audiojoe/update-status.json` und `journalctl -u audiojoe-update`. Von Hand prüfen mit
`sudo audiojoe-update --check`.

| Meldung | Bedeutung |
|---|---|
| `release list not reachable: <quelle>` | GitHub (oder die `SOURCE` in `/etc/audiojoe/update.conf`) ist nicht erreichbar – Netz, DNS, Firewall für ausgehendes HTTPS |
| `package <version> could not be downloaded or its checksum is wrong` | Download kaputt oder Paket verändert – nichts wurde installiert; nächste Nacht neuer Versuch |
| `<version> did not start; going back to <version>` | die neue Version hat nicht innerhalb von 60 Sekunden geantwortet; das vorige Paket und die Datenbank-Sicherung sind zurück |
| `<version> failed before; not tried again (audiojoe-update --now tries it)` | nach einem solchen Weg zurück wird die Version nachts übersprungen |
| `package of the installed version <version> not available, so no way back – update not started` | ohne das Paket für den Weg zurück beginnt das Update nicht |

## Datenbank oder Konfiguration beschädigt

- **Konfiguration:** Die Meldungen stehen unter [Der Server startet nicht](#der-server-startet-nicht).
  Eine minimale `config.toml`:

  ```toml
  listen = "10.0.0.20:8080"
  database = "/var/lib/audiojoe/audiojoe.db"
  web_root = "/usr/share/audiojoe/web"
  trusted_proxies = ["10.0.0.5"]
  ```

- **Datenbank:** Der Server prüft die Datei bei jedem Start (`PRAGMA quick_check`, ab 0.1.8). Ist sie
  beschädigt, startet er nicht und schreibt `Database check failed: … is damaged (…)`. Später im
  Protokoll kann `database disk image is malformed` stehen, wenn ein Schaden während des Betriebs
  entsteht.
  Prüfen (braucht das Paket `sqlite3`):

  ```bash
  sudo apt install sqlite3
  sudo sqlite3 -readonly /var/lib/audiojoe/audiojoe.db "PRAGMA integrity_check"
  ```

  Alles außer `ok` heißt: eine Sicherung zurückspielen – deine eigene oder die neueste aus
  `/var/backups/audiojoe/` ([Sicherung und Wiederherstellung](BACKUP.md#zurückspielen-auf-demselben-server)).
