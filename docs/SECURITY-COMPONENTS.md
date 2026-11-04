# Über HTTPS erreichbare Bestandteile

*Diese Seite beschreibt das aktuelle Release. Für eine ältere Version gilt dieselbe Seite unter dem
Schild dieser Version auf GitHub (`https://github.com/joeMJ/audiojoe/tree/vX.Y.Z/docs`). Die im
Server eingebauten Hilfeseiten unter `/docs/` passen immer zur installierten Version.*

Welche Bibliotheken Anfragen verarbeiten, die über deine HTTPS-Adresse (Port 443) beim
audiojoe-Server ankommen, und welche davon das schon **vor** der Anmeldung tun. Damit lässt sich
eine veröffentlichte Schwachstelle einordnen: Betrifft sie eine Bibliothek aus der ersten Tabelle,
ist der Teil von audiojoe betroffen, den jeder nutzen kann, der deine Adresse erreicht – bald
aktualisieren. Eine Bibliothek, die erst nach der Anmeldung arbeitet, ist nur mit gültiger
Anmeldung erreichbar.

Versionen stehen hier nicht; die genauen stehen in `Cargo.lock` (Server) und
`clients/web/package-lock.json` (Web-Player) des Releases, das du betreibst.

## Wie eine Anfrage ankommt

```
Gerät ── HTTPS 443 ──► dein Reverse Proxy (TLS) ── HTTP ──► audiojoe-server (Listen-Adresse)
```

- **TLS** macht dein Reverse Proxy, nicht audiojoe. Schwachstellen in TLS-Bibliotheken (OpenSSL
  und ähnliche) betreffen den Proxy und werden dort behoben.
- audiojoe-server selbst spricht nur HTTP und sollte nur für den Proxy erreichbar sein.

## Vor der Anmeldung

Jede Anfrage, auch eine ohne gültige Anmeldung, durchläuft diese Bibliotheken:

| Bibliothek | Was sie dort tut |
|---|---|
| `tokio` | Netzverbindungen, Laufzeit |
| `hyper` (in `axum`) | liest die HTTP-Anfrage (Kopfzeilen, Inhalt) |
| `axum` | Weiterleitung, liest Pfade, Query-Strings und JSON, Größengrenze (64 KB) |
| `tower-http` | liefert die statischen Seiten (Web-Player, Auto-Testseite), Sicherheits-Kopfzeilen |
| `serde`, `serde_json` | liest das JSON der Anmeldung |
| `sha2` | Prüfsumme des mitgeschickten Zugangsschlüssels, um ihn nachzuschlagen |
| `rusqlite` (mit eingebautem SQLite) | schlägt die Anmeldung in der Datenbank nach |

Alle Pfade, die ohne Anmeldung antworten, und was dort zusätzlich arbeitet:

| Pfad | Bibliothek | Was sie dort tut |
|---|---|---|
| `/`, `/testcar/` (statische Seiten) | `tower-http` | liefert die Dateien des Web-Players und der Auto-Testseite |
| `/api/v1/health` | `serde_json` | antwortet mit Status und Version |
| `/api/v1/auth/login` | `argon2` | prüft das Kennwort |
| | `totp-rs` | prüft den Code der Authenticator-App |
| | `rand` | erzeugt nach erfolgreicher Anmeldung den Zugangsschlüssel |
| `/api/2/…`, `/subscriptions/…` (gpodder.net-Schnittstelle) | `base64`, `argon2` | liest und prüft das App-Kennwort (HTTP Basic); ohne App-Kennwort antworten diese Pfade nur „unauthorized“ |
| `/docs/…` | `pulldown-cmark` | macht aus den eingebauten Hilfeseiten HTML; verarbeitet nur Text, der im Server steckt, nichts aus der Anfrage |

Ebenfalls ohne Anmeldung ausgeliefert, aber im **Browser des Besuchers** ausgeführt, nicht auf dem
Server:

| Bibliothek | Wo |
|---|---|
| `qrcode-generator` | Auto-Testseite (`/testcar/`) |

Der Web-Player selbst enthält keine Fremdbibliotheken.

## Erst nach der Anmeldung

Diese Bibliotheken arbeiten nur für Anfragen mit gültiger Anmeldung oder in den eigenen
Hintergrundaufgaben des Servers (Feeds abrufen, Abgleich mit Audiobookshelf). Ihre Eingaben kommen
meist von den Servern, die du eingetragen hast (Quellen, Podcast-Feeds), nicht aus der Anfrage:

| Bibliothek | Was sie dort tut |
|---|---|
| `reqwest` (mit `rustls`) | alle Verbindungen des Servers nach außen: Quellen, Feeds, Radio Browser, fyyd, MusicBrainz |
| `quick-xml`, `rss` | liest Podcast-Feeds und importierte OPML-Dateien |
| `ammonia` | bereinigt Shownotes, bevor sie angezeigt werden |
| `chrono` | Datumsangaben von Feeds und Hörständen |
| `tokio-util` | reicht Audioströme und Downloads durch |
| `ffmpeg` (eigenes Programm) | wandelt Hi-Res-FLAC um, nur wenn ein Ziel es nicht abspielen kann |

## Nicht über HTTPS

- **Sonos-Stromport** (nur mit dem Abschnitt `[sonos]`): ein eigener Port, der nur im Heimnetz
  erreichbar sein soll. Die Lautsprecher holen dort den Ton mit einer signierten Adresse, die
  24 Stunden gilt (`hmac`, `sha2`); diesen Port darf der Proxy nicht weiterleiten.
- **Updates** (`audiojoe-update`): Der Server fragt GitHub mit `curl`; über 443 kommt dabei nichts
  herein.

## Was daraus folgt

- Schwachstelle in einer Bibliothek des ersten Abschnitts: bald aktualisieren, auch wenn nur du den
  Server nutzt.
- Schwachstelle in einer Bibliothek des zweiten Abschnitts: erreichbar nur für angemeldete Nutzer
  oder über eine Quelle bzw. einen Feed, den du eingetragen hast.
- Damit der erreichbare Teil klein bleibt: Den Proxy nur deine audiojoe-Adresse weiterleiten lassen,
  und die Listen-Adresse des Servers nur für den Proxy erreichbar machen.
