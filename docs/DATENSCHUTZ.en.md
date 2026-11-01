# Privacy and network access

audiojoe sends no usage data and has no telemetry, no update check and no crash reports. All
access to the outside is made by the **server**; the apps and the web player only connect to your
own audiojoe server. As with any network access, every request to another server carries the
audiojoe server's IP address, plus the identifier `audiojoe/<version>`. The server does not pass on
the devices' IP addresses or browser identifiers. When providers redirect to other addresses (e.g.
feeds to a CDN), the server follows the redirect.

## Always, once set up

- **Podcast feeds:** every subscribed feed is fetched once an hour (first 60 seconds after the
  start), and when subscribing, refreshing by hand and importing OPML. The server asks for changes
  only, with `If-None-Match`/`If-Modified-Since`.
- **Episodes, images and chapters:** when an episode is played or downloaded, the server fetches
  the audio file from the provider (feed server or CDN) and relays it to the device; it does not
  store it. Images are fetched when a device shows them. Chapters are fetched when an episode is
  opened for the first time and then stored: the chapter file from the feed (Podcasting 2.0) or,
  for an MP3 without one, the first 2 MB of the episode to read its chapter marks (ID3).
- **Your sources** (Jellyfin, Emby, Plex, Audiobookshelf): only the server you entered –
  libraries, browsing, search (with the search term), covers and playback.
  - **Jellyfin, Emby, Plex** are only read; audiojoe reports neither progress nor "played" to them.
  - **Audiobookshelf:** listening progress is synced both ways – every 5 minutes, when a book is
    opened and after every change – and only for the audiojoe user who added the source.
  - **Album index (music):** once a music library has been opened, the server checks every day
    (adjustable: weekly, by hand only) whether it changed. After a rebuild it reads the first
    256 KB of each album's first track on Jellyfin and Emby to get the label from the tags (one
    request every 250 ms).
  - The access keys are kept in the server's database and only go to their source; the apps never
    see them.

## Only when used

- **Radio Browser** ([radio-browser.info](https://www.radio-browser.info)): the station search
  goes with the search term to a server picked at random from the list of
  `all.api.radio-browser.info`. When a station is played, audiojoe reports a click with the
  station's identifier, as the directory asks. The server fetches stream and logo straight from
  the station (addresses from the directory).
- **Podcast search:** the search term goes to [fyyd](https://fyyd.de) (`api.fyyd.de`), without an
  account.
- **Links in show notes:** the app opens a link in the browser only when you tap it. The web
  player shows links as text only.

## Only when switched on

- **Labels from MusicBrainz** (off by default; **Settings → Music**): for albums whose files name
  no label and for which Jellyfin or Emby knows a MusicBrainz identifier, the server asks
  `musicbrainz.org` for the label. Only the release identifier is sent, with the contact address
  MusicBrainz asks for in the program identifier; at most one request per second, each album only
  once. Labels are part of the MusicBrainz core data and are under
  [CC0](https://musicbrainz.org/doc/About/Data_License).
- **Sonos** (only with the `[sonos]` section in the configuration): only in the home network, port
  1400 of the speakers. Every 10 seconds the server asks the speakers you entered for their group
  and playback state, so that the position of a title played there is saved. The speaker gets
  title, subtitle and a signed stream address valid for 24 hours; it fetches the audio through a
  port of its own that should only be reachable in the home network. "Scan" only probes the
  address range you configured (at most 64 addresses), without multicast.
- **Conversion:** for hi-res FLAC a target cannot play (offline storage in the car, Sonos), the
  server starts `ffmpeg`; it fetches the file from the source itself.

## What the server stores

In the database (`/var/lib/audiojoe/audiojoe.db`):

- **Users:** name, password as an Argon2id hash, TOTP secret.
- **Sign-ins per device:** device name (free to choose), time of sign-in and last use; of the
  access key only a checksum. The server deletes expired sign-ins at the next sign-in.
- **Listening state per user and title:** position, duration, "heard", title and the device that
  played last – so also what played when on which device. Also the continue lists, the queue per
  device, radio favourites and hidden libraries.
- **Sources:** kind, name, address, access key. Sources, Sonos speakers and the music settings
  apply to all users of the server.
- **Cache:** podcasts and episodes with descriptions and chapters, station data from Radio
  Browser, the album index.

The server stores no media and no images.

**Log:** per request the device's IP address (behind a configured proxy the forwarded one),
method, path, status and duration. The path contains the identifier of what was played; query
parameters and Sonos addresses are not logged. Also sign-ins (user name, device name; for failures
the IP address) and errors of sources. In the container journald keeps the log for 14 days.

**Deleting:** unsubscribing deletes your positions of the podcast, removing a source all positions
from it, deleting a user (`audiojoe-server user delete NAME`) everything belonging to them.

## What the devices store

- **App:** the sign-in (server address, access key, device name) in the system's secure storage;
  positions, positions not yet sent, title data, appearance and queue in the app's data folder;
  offline titles under `offline/`. On the desktop the app suggests "system · host name" as device
  name – the name goes to the server and can be changed when signing in.
- **Web player:** the sign-in as a cookie (`HttpOnly`, `Secure`, `SameSite=Strict`); positions,
  title data and offline titles in the browser's storage (IndexedDB, cache); appearance, views and
  queue in `localStorage`.
- **Signing out** only deletes the sign-in. Offline titles stay until you remove them (app:
  **Offline**, web player: **Offline → Remove**).

## Sign-in

- Password and a code from an authenticator app (TOTP, required); each code works only once.
- After 5 failed attempts per device or user name within 15 minutes the server blocks further
  attempts for 15 minutes.
- A sign-in is valid for 180 days. **Settings → Devices** lists all sign-ins; each can be signed out
  on its own.
- The server itself only speaks HTTP; HTTPS is done by the proxy in front of it
  ([Installation](INSTALLATION.en.md)).
