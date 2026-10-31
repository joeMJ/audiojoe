-- Stage 1: users, sessions, sources, podcasts, playback state.

CREATE TABLE user (
    id            INTEGER PRIMARY KEY,
    name          TEXT    NOT NULL UNIQUE,
    password_hash TEXT    NOT NULL,           -- Argon2id, PHC string
    totp_secret   TEXT    NOT NULL,           -- base32
    created_at    TEXT    NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now'))
);

-- One row per logged-in device. Only the SHA-256 of the token is stored.
CREATE TABLE session (
    id          INTEGER PRIMARY KEY,
    user_id     INTEGER NOT NULL REFERENCES user(id) ON DELETE CASCADE,
    token_hash  TEXT    NOT NULL UNIQUE,
    device      TEXT    NOT NULL,
    created_at  TEXT    NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now')),
    last_seen   TEXT    NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now')),
    expires_at  TEXT    NOT NULL
);

-- Media servers (Jellyfin, later Plex, Emby, ...). Podcasts are not sources but subscriptions.
CREATE TABLE source (
    id         INTEGER PRIMARY KEY,
    kind       TEXT    NOT NULL,              -- 'jellyfin'
    name       TEXT    NOT NULL,
    url        TEXT    NOT NULL,
    secret     TEXT    NOT NULL,              -- API key / token for the source
    created_at TEXT    NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now'))
);

CREATE TABLE podcast (
    id            INTEGER PRIMARY KEY,
    feed_url      TEXT    NOT NULL UNIQUE,
    title         TEXT    NOT NULL DEFAULT '',
    author        TEXT    NOT NULL DEFAULT '',
    image_url     TEXT    NOT NULL DEFAULT '',
    etag          TEXT,
    last_modified TEXT,
    last_fetch    TEXT,
    last_error    TEXT
);

CREATE TABLE subscription (
    user_id    INTEGER NOT NULL REFERENCES user(id) ON DELETE CASCADE,
    podcast_id INTEGER NOT NULL REFERENCES podcast(id) ON DELETE CASCADE,
    PRIMARY KEY (user_id, podcast_id)
);

CREATE TABLE episode (
    id           INTEGER PRIMARY KEY,
    podcast_id   INTEGER NOT NULL REFERENCES podcast(id) ON DELETE CASCADE,
    guid         TEXT    NOT NULL,
    title        TEXT    NOT NULL,
    published    TEXT,                        -- RFC 3339
    duration_s   INTEGER,
    url          TEXT    NOT NULL,
    mime         TEXT    NOT NULL DEFAULT '',
    size         INTEGER,
    UNIQUE (podcast_id, guid)
);
CREATE INDEX episode_published ON episode (podcast_id, published DESC);

-- Playback position per user and item. item_key: 'episode:<id>' or 'jellyfin:<source>:<item>'.
-- updated_at is the client's time of the change, so positions recorded offline do not
-- overwrite newer ones when they are synced later.
CREATE TABLE playback (
    user_id     INTEGER NOT NULL REFERENCES user(id) ON DELETE CASCADE,
    item_key    TEXT    NOT NULL,
    position_ms INTEGER NOT NULL,
    duration_ms INTEGER,
    finished    INTEGER NOT NULL DEFAULT 0,
    title       TEXT    NOT NULL DEFAULT '',
    subtitle    TEXT    NOT NULL DEFAULT '',
    device      TEXT    NOT NULL DEFAULT '',
    updated_at  TEXT    NOT NULL,
    PRIMARY KEY (user_id, item_key)
);
CREATE INDEX playback_recent ON playback (user_id, updated_at DESC);
