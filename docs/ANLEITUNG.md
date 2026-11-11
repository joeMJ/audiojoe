# Anleitung

*Diese Seite beschreibt das aktuelle Release. Für eine ältere Version gilt dieselbe Seite unter dem
Schild dieser Version auf GitHub (`https://github.com/joeMJ/audiojoe/tree/vX.Y.Z/docs`). Die im
Server eingebauten Hilfeseiten unter `/docs/` passen immer zur installierten Version.*

audiojoe hat fünf Bereiche: **Weiterhören**, **Podcasts**, **Hörbücher**, **Musik** und
**Radio**. Die App zeigt sie unten (am Telefon) bzw. links (Desktop, Web-Player). Oben stehen der
Zustand der Verbindung und der Hörstände, der Knopf für die Offline-Titel, Hell/Dunkel und die
Einstellungen.

## Zustand oben

- **● Server** grün: der Server ist erreichbar. **Offline · Cache** gelb: keine Verbindung; die
  App spielt, was offline gespeichert ist, und merkt sich die Positionen. Reißt die Verbindung
  während der Wiedergabe ab, spielt die App an derselben Stelle aus der gespeicherten Kopie weiter;
  ohne Kopie wartet sie an der Stelle und spielt von selbst weiter, sobald der Server wieder
  antwortet (Pause beendet das Warten). Ab 0.1.9. Liefert der Server, aber das Gerät kann nicht
  abspielen (zum Beispiel ohne Audiogerät), hört die App nach drei Versuchen in Folge (etwa 15
  Sekunden) auf, bleibt an der Stelle stehen und meldet „Wiedergabe auf diesem Gerät nicht möglich“
  mit dem Grund; der Eintrag steht auch im Fehlerprotokoll (Einstellungen → Wartung). ▶ versucht es
  erneut. Ab 0.3.2.
- **✓ Position** grün: alle Hörstände sind beim Server. Rot mit **✕** erst, wenn eine Position
  länger als 30 Sekunden nicht gespeichert werden konnte; sie wird nachgereicht, sobald der Server
  wieder erreichbar ist.

## Weiterhören

Angefangene Folgen und Hörbücher kommen von selbst nach oben, mit **Next** (Symbol mit Liste und
Plus) hängst du Folgen, Hörbücher oder ganze Alben ans Ende an. Am Ende eines Titels spielt der
nächste Eintrag derselben Liste. Die Reihenfolge lässt sich durch Ziehen ändern; der
Papierkorb nimmt einen Eintrag heraus (bei Folgen und Hörbüchern: **Als gehört markieren**).

**Likes:** Musiktitel, die du im Player mit dem Herz (**Gefällt mir**) markierst. Ein zweiter Tipp
auf das Herz nimmt den Titel wieder heraus. Ein Like bleibt nach dem Hören in der Liste; am Ende
eines Titels spielt der nächste Like. Ab 0.2.6.

## Podcasts

**Neu** zeigt die neuesten Folgen aller Abonnements, **Abonniert** die Podcasts selbst. Je Folge:
abspielen, **Next**, offline speichern. Shownotes und Kapitel stehen im Player unter **Details**
und **Kapitel**.

<p align="center">
  <img src="screenshots/podcasts.webp" alt="Podcasts: abonnierte Podcasts" width="270">
  &nbsp;
  <img src="screenshots/kapitel.webp" alt="Kapitel einer Folge mit Zeitmarken" width="270">
  <br>
  <em>Abonnierte Podcasts · Kapitel einer Folge</em>
</p>

## Radio

Sender suchen, mit dem Stern als Favorit merken, die Favoriten durch Ziehen ordnen. Radio läuft
live; es lässt sich nicht offline speichern.

<p align="center">
  <img src="screenshots/radio.webp" alt="Radio: Favoriten mit Logos und Qualität" width="270">
  <br>
  <em>Radio-Favoriten (Senderverzeichnis: Radio Browser)</em>
</p>

## Hörbücher und Musik

- **Hörbücher** (Audiobookshelf, Jellyfin, Emby, Plex): nach Autor, Serie („x von y gehört“,
  nächster Band), Titel oder zuletzt hinzugefügt; Suche nach Titel, Autor, Serie und Sprecher.
  Bei Jellyfin („Bücher“-Bibliothek), Emby („Hörbücher“) und Plex (Musikbibliothek mit dem
  Audnexus-Agenten oder mit „Hörbücher“/„Audiobooks“ im Namen) ist ein Ordner ein Buch, der
  Albuminterpret der Autor; Serien und Sprecher kennen diese Quellen nicht.
- **Musik** (Jellyfin, Emby, Plex): Alben, Künstler, Sampler, Genres, Jahre, Neu hinzugefügt und
  Labels; Suche nach Titel, Künstler, Genre und Label. **Album abspielen** spielt das ganze Album;
  ⏮ ⏭ springen zwischen den Titeln.

## Player

<p align="center">
  <img src="screenshots/player.webp" alt="Player mit Kapitel, Qualität, Bedienung und Lautstärke" width="270">
  <br>
  <em>Player einer Podcast-Folge mit Kapiteln</em>
</p>

- **Titel und Stelle:** In einem Album steht hinter dem Titel „(3 von 14)“, bei Folgen und
  Hörbüchern mit Kapiteln hinter dem Kapitel „(1 von 21)“. Ist der Titel zu lang, läuft er durch.
- **Qualität:** Codec, Bitrate, Bittiefe und Abtastrate. Verlustfreie Formate (FLAC, ALAC, PCM)
  sind gelb bei 16 Bit und rot ab 24 Bit. Wird umgerechnet oder aus dem Cache gespielt, steht das
  dabei.
- **Als Nächstes:** klein unter der Qualität – im Album der nächste Titel, im Hörbuch das nächste
  Kapitel, bei Podcasts die nächste Folge aus **Weiterhören**. Bei Radio und beim letzten Eintrag
  steht nichts. Auch im Web-Player. Ab 0.2.5.
- **Bedienung:** 15 Sekunden zurück, 30 Sekunden vor. ⏮ ⏭ springen bei Kapiteln zum vorigen bzw.
  nächsten Kapitel (⏮ in den ersten 3 Sekunden eines Kapitels zum vorigen, sonst an den Anfang),
  sonst zum vorigen bzw. nächsten Titel. Sperrbildschirm und Benachrichtigung machen dasselbe.
- **Unten:** **Schlaf-Timer** (5 bis 60 Minuten, Ende des Kapitels, Ende des Titels), **Tempo**
  (bei Folgen und Hörbüchern; bei Musik steht dort das Herz **Gefällt mir**, Musik spielt immer mit
  1,0×), **Ausgabe** (dieses Gerät oder ein Sonos-Raum) und **Offline**.
- **Lautstärke:** die des Geräts, bei Sonos die des Raums bzw. der Gruppe, mit − und + in Schritten von 1;
  Räume lassen sich zur Gruppe hinzufügen oder herausnehmen. Beginnt die Wiedergabe auf einem Sonos-Raum,
  stellt audiojoe ihn – bei einer Gruppe jeden Raum – auf die **Startlautstärke** (Einstellungen → Sonos,
  ab Werk 8). Ab 0.3.1.
- **Schlummern** (Sonos, im Ausgabe-Fenster neben Hierher, Stoppen und Gruppe, und bei Sonos-Ausgabe über
  **Schlaf-Timer** unten im Player): stellt den Schlaf-Timer des Lautsprechers bzw. der Gruppe auf 5 bis 60
  Minuten; der Knopf zeigt die Restzeit. Der Lautsprecher hört von selbst auf, auch wenn App oder Server aus
  sind; ein Ende des Titels oder Kapitels kennt er nicht. Ab 0.1.9, über Schlaf-Timer ab 0.3.1.

## Auf anderen Geräten weiterhören

Jede Position geht sofort an den Server; die anderen Geräte folgen, solange sie selbst nicht
spielen. Beim nächsten Start setzt ein Gerät dort fort, wo zuletzt gehört wurde – auch wenn das
auf einem anderen Gerät war – und zeigt kurz „Übernommen von …“. Lief dort ein Album, kommt das
ganze Album mit, samt ⏮ ⏭ und dem nächsten Titel.

Beginnt ein anderes Gerät oder ein Sonos-Raum zu spielen, während in der App nichts spielt, zeigt
sie das sofort und steuert es – wie beim Start, auch nach einer Unterbrechung der Verbindung. Im
Ausgabe-Fenster steht bei einem Sonos-Raum, den ein anderes Gerät gestartet hat, was dort läuft und
„gestartet von …“, mit **Steuern** und **Hier**. Ab 0.2.5.

## Offline

Folgen, Hörbücher und Alben lassen sich mit dem Pfeil nach unten speichern. In den Apps zeigt
**Downloads** (über **Ablage** oben bzw. **Einstellungen → Ablage → Downloads öffnen**), was lädt,
wartet, teilweise oder ganz geladen ist, mit einem Filter nach Podcasts, Hörbüchern und Musik.
Höchstens zwei Downloads laufen gleichzeitig. Ein Album und ein Hörbuch sind je ein Eintrag und
werden ganz gelöscht; bei einem angefangenen Album lädt **Rest laden** die übrigen Titel.

Unter **Einstellungen → Ablage**:
- **Mindestens frei lassen** (ab 5 GB): darunter beginnt kein Download, wartende laden weiter,
  sobald wieder Platz ist.
- **Nach dem Hören löschen** für Podcasts (ab Werk an) und Hörbücher (ab Werk aus): eine
  beendete Folge bzw. ein beendetes Hörbuch wird gelöscht, sobald es nicht mehr spielt. Musik
  bleibt, bis man sie löscht.
- Linux und Windows: der **Ablageordner** (ab Werk `audiojoe` im persönlichen Ordner) mit den
  Unterordnern `podcasts`, `audiobooks` und `music`. **Ändern …** legt Neues künftig im anderen
  Ordner ab, Gespeichertes bleibt, wo es ist. **Verschieben nach …** nimmt alles mit: auf
  demselben Laufwerk wird umbenannt, sonst kopiert, die Größe geprüft und erst dann das
  Original gelöscht; ein Abbruch hält nach der laufenden Datei an. Solange Downloads laufen oder
  warten, ist Verschieben gesperrt. Android speichert im App-Speicher.

Der **Offline**-Knopf des Web-Players zeigt, was gespeichert ist und wie viel Platz es belegt.
Hi-Res-FLAC speichert der Web-Player als 48 kHz, damit es im Auto läuft. Im Web-Player räumt
**Gespielte Medien aus dem Cache entfernen** nach dem Hören auf.

## Im Auto (Web-Player)

Der Web-Player ist für den Browser im Auto gebaut (große Knöpfe, Bedienung unten angedockt). Statt
des Schlaf-Timers gibt es **Nächster Podcast** bzw. **Nächstes Album**: Die laufende Folge gilt als
gehört (das Album verlässt die Liste), und der nächste Eintrag aus **Weiterhören** startet. Bei
Hörbüchern fehlt der Knopf. Auf schmaleren Bildschirmen als dem des Tesla (weniger als 420 px
rechts vom Cover) stehen die drei Knöpfe untereinander unter dem Cover, die Bedienknöpfe bleiben
rechts unten. Links in den Shownotes stehen nur als Text.

Der Browser im Tesla gibt die Tasten am Lenkrad sowie ⏭ und ⏮ der Musikleiste nicht an Webseiten
weiter; aus der Musikleiste kommt nur Pause/Wiedergabe an. Bedient wird der Web-Player deshalb auf
dem Bildschirm.

<p align="center">
  <img src="screenshots/web-player.webp" alt="Web-Player im Format des Auto-Bildschirms" width="580">
  <br>
  <em>Web-Player im Format des Tesla-Bildschirms: Folge mit Kapiteln, eben vom Telefon übernommen (der Hinweis steht nur kurz da)</em>
  <br><br>
  <img src="screenshots/web-radio.webp" alt="Web-Player: Radio-Favoriten" width="580">
  <br>
  <em>Radio-Favoriten im Web-Player</em>
</p>

## Abgleich mit anderen Podcast-Apps

audiojoe spricht die gpodder.net-Schnittstelle, die AntennaPod, Kasts, gPodder und andere
Podcast-Apps für den Abgleich kennen: Abonnements und Hörstände sind dann in beiden Welten
dieselben. Diese Apps können keinen Code aus der Authenticator-App eingeben, deshalb bekommen
sie ein eigenes **App-Passwort**: in der audiojoe-App unter **Einstellungen → Abgleich mit
anderen Podcast-Apps** erzeugen (wird einmal gezeigt). In der anderen App unter
gpodder.net-Abgleich den **eigenen Server** wählen, die Adresse des audiojoe-Servers,
Benutzername und App-Passwort eintragen. Das App-Passwort gilt nur für den Abgleich, für nichts
anderes; **Abschalten** meldet alle so verbundenen Apps ab.

## Qualität und bit-perfect

Unter **Einstellungen → Qualität** zeigt audiojoe, was gerade läuft: **Quelle** (Format der Datei), was ans
System geht (**An Android übergeben** bzw. **Ausgabe**) und den **Weg** – **Bit-perfect**, Android-Mixer
oder System-Mixer. **Dieses Gerät** nennt das System und den angesteckten USB-DAC, unter Android und Linux
auch die Formate, die er anbietet.

**Bit-perfect über USB:** Mit diesem Schalter geht Musik unverändert an einen USB-DAC – ohne Umrechnung von
Rate oder Bittiefe und ohne Lautstärke in Software. Podcasts, Hörbücher und Radio bleiben auf dem normalen
Weg. Der Schalter wirkt ab dem nächsten Titel.

- **Android:** ab Android 14, wenn das Gerät für den DAC bit-perfect anbietet. Währenddessen sind
  Systemtöne stumm; ein Benachrichtigungston schaltet die Musik kurz stumm. Vor dem ersten Titel nach dem
  Anstecken stellt audiojoe die Medienlautstärke auf 20 % (abschaltbar). Nach Start oder Sprung wird der
  Anfang 20 ms lang eingeblendet, danach ist die Wiedergabe bit-genau.
- **Linux:** audiojoe spielt direkt auf den DAC, an PipeWire vorbei, und nur bei Raten, die der DAC kann.
  Andere Programme können den DAC so lange nicht nutzen.
- **Windows:** WASAPI im Exklusivmodus. Andere Programme können den DAC so lange nicht nutzen.

**Lautstärke:** USB-DACs haben in der Regel keine Lautstärkebegrenzung, wie sie in der EU vorgeschrieben
ist. Leise beginnen, besonders mit empfindlichen In-Ear-Hörern.

**Akkunutzung (Android):** Steht die Akkunutzung von audiojoe nicht auf „Uneingeschränkt“, kann Android die
Wiedergabe im Hintergrund beenden. audiojoe warnt dann beim Start der Wiedergabe und unter
**Einstellungen → Wiedergabe**; **Ändern** öffnet die Abfrage von Android. Nach einer Aktualisierung kann
die Einstellung zurückgesetzt sein.

## Einstellungen

Quellen und Bibliotheken, Musik (Albenverzeichnis, MusicBrainz), Sonos (Lautsprecher, Startlautstärke,
**Ausgeschaltete Lautsprecher ausblenden** – ab Werk an, blendet nicht erreichbare Lautsprecher im
Ausgabe-Fenster aus), Wartung
(Server- und Debian-Updates, Sicherungen, Stand dieser App; siehe
[Installation](install-server.md#updates-und-wartung)), Podcasts
(OPML), Geräte (angemeldete Geräte, einzeln abmelden), **Dieses Gerät abmelden** und
**Über audiojoe** mit Version, Anleitung, Datenschutz und den Lizenzen Dritter. Im Web-Player
stehen das Abmelden und **Über audiojoe** unten auf der Seite **Offline**. Siehe [Erste Schritte](ERSTE-SCHRITTE.md).
