-- Internet radio: stations seen in searches (cache of the Radio Browser data) and the
-- users' favourites.
CREATE TABLE radio_station (
    uuid       TEXT PRIMARY KEY,           -- Radio Browser stationuuid
    name       TEXT NOT NULL,
    url        TEXT NOT NULL,              -- url_resolved
    codec      TEXT NOT NULL DEFAULT '',
    bitrate    INTEGER,
    favicon    TEXT NOT NULL DEFAULT '',
    country    TEXT NOT NULL DEFAULT '',
    tags       TEXT NOT NULL DEFAULT '',
    updated_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now'))
);

CREATE TABLE radio_favorite (
    user_id INTEGER NOT NULL REFERENCES user(id) ON DELETE CASCADE,
    uuid    TEXT    NOT NULL REFERENCES radio_station(uuid) ON DELETE CASCADE,
    added_at TEXT   NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now')),
    PRIMARY KEY (user_id, uuid)
);

-- Sonos speakers, addressed by fixed IP (no multicast discovery).
CREATE TABLE sonos_speaker (
    id         INTEGER PRIMARY KEY,
    ip         TEXT    NOT NULL UNIQUE,
    name       TEXT    NOT NULL DEFAULT '',
    uuid       TEXT    NOT NULL DEFAULT '',  -- RINCON_…
    model      TEXT    NOT NULL DEFAULT '',
    s2         INTEGER NOT NULL DEFAULT 1,   -- S2 plays up to 24 bit/48 kHz, S1 up to 16 bit
    added_at   TEXT    NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now'))
);
