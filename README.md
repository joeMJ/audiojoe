# audiojoe

One source of truth for all your audio: podcasts, audiobooks, music and internet radio
from Jellyfin, Plex, Emby and RSS — with playback positions synced across phone,
desktop, car and Sonos.

The server stores **no audio**. It knows sources, media and playback state and relays
the audio stream over HTTP. Caching happens on the client devices only.

**Status:** early development, not usable yet.

## Layout

| Path | Content |
|---|---|
| `server/` | Rust server (single binary, SQLite) |
| `clients/web/` | Web app / PWA for the Tesla in-car browser (TypeScript) |
| `clients/app/` | Flutter app for Android, Linux, Windows (later iOS) |
| `design/` | Shared design tokens |
| `po/` | Translations (base language English) |
| `tests/attrappe/` | Fake media source with injectable stream faults for testing |
| `packaging/lxc/` | systemd unit and example configuration |

## License

Apache-2.0, see [LICENSE](LICENSE).
