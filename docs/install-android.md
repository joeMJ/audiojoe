# audiojoe unter Android installieren

*Diese Seite beschreibt das aktuelle Release. Für eine ältere Version gilt dieselbe Seite unter dem
Schild dieser Version auf GitHub (`https://github.com/joeMJ/audiojoe/tree/vX.Y.Z/docs`). Die im
Server eingebauten Hilfeseiten unter `/docs/` passen immer zur installierten Version.*

**Voraussetzungen:** Android 7.0 oder neuer. Die App braucht einen audiojoe-Server
([Server installieren](install-server.md)). audiojoe steht nicht im Play Store; installiert wird
die signierte APK aus dem Release.

**Installieren:**

1. Auf dem Telefon die [Release-Seite](https://github.com/joeMJ/audiojoe/releases/latest) öffnen
   und `audiojoe-<Version>.apk` laden.
2. Die Datei öffnen (Benachrichtigung des Browsers oder Dateien-App).
3. Android fragt beim ersten Mal, ob diese App (Browser bzw. Dateien) **unbekannte Apps
   installieren** darf: in den Einstellungen dafür erlauben, zurück, **Installieren**. Unter
   Android 7 heißt die Einstellung **Unbekannte Herkunft** (Einstellungen → Sicherheit).
4. Danach die Erlaubnis für Browser bzw. Dateien wieder ausschalten, wenn sie nicht gebraucht
   wird.

**Echtheit prüfen** (empfohlen, am Rechner): APK und `SHA256SUMS` aus dem Release in einen Ordner
laden und die Prüfsumme vergleichen; die Signatur zeigt `apksigner` aus den Android-Build-Tools:

```bash
sha256sum -c --ignore-missing SHA256SUMS
apksigner verify --print-certs audiojoe-<Version>.apk
```

Erwartet: `CN=audiojoe, O=joeMJ` und als SHA-256 des Zertifikats
`60f91d92d6ff259a5c9f811cd47df8388016c7aeace642af89acd74c73fedc12`. Android nimmt spätere
Versionen nur mit derselben Signatur als Update an.

> [!NOTE]
> Google Play Protect kann bei Apps außerhalb des Play Stores warnen. Erst die Echtheit prüfen
> (oben), dann entscheiden.

**Aktualisieren:** Ist der Server aus dem Paket installiert, zeigt die App eine neue Version unter
**Einstellungen → Wartung** in der Zeile **App** an. **Version … installieren** lädt die APK über den
eigenen Server und öffnet die Paketinstallation; Android fragt beim ersten Mal, ob audiojoe Apps
installieren darf, und vor jeder Installation. Die App fragt dafür nie GitHub, siehe
[Datenschutz](DATENSCHUTZ.md#updates-nur-mit-dem-server-paket). Von Hand: die neue APK wie oben
installieren.

**Deinstallieren:** Einstellungen → Apps → **audiojoe** → **Deinstallieren**. Android entfernt
dabei auch Anmeldung, Positionen auf dem Gerät und Offline-Titel; die Positionen auf dem Server
bleiben.

## Aus dem Quelltext

```bash
cd clients/app && flutter build apk --release --flavor github
```

Diese Fassung prüft wie die APK im Release über den eigenen Server auf neue Versionen. Für
F-Droid gibt es eine Fassung ohne Updateprüfung:

```bash
flutter build apk --release --flavor fdroid --dart-define=AUDIOJOE_DIST=fdroid
```
