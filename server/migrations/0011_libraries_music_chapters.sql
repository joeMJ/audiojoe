-- Libraries a user has hidden (per source), on all of their devices.
CREATE TABLE hidden_library (
    user_id   INTEGER NOT NULL REFERENCES user(id) ON DELETE CASCADE,
    source_id INTEGER NOT NULL REFERENCES source(id) ON DELETE CASCADE,
    library   TEXT    NOT NULL,
    PRIMARY KEY (user_id, source_id, library)
);

-- The server's own album directory per music library (the sources cannot sort by these
-- fields). Labels come from the files' tags, Plex's studio or – when switched on – MusicBrainz.
CREATE TABLE music_album (
    source_id   INTEGER NOT NULL REFERENCES source(id) ON DELETE CASCADE,
    library     TEXT    NOT NULL,
    album_id    TEXT    NOT NULL,
    title       TEXT    NOT NULL,
    artist      TEXT    NOT NULL DEFAULT '',
    year        INTEGER,
    genres      TEXT    NOT NULL DEFAULT '[]',   -- JSON array
    added_at    TEXT,                            -- RFC 3339
    image       TEXT,
    tracks      INTEGER,
    duration_ms INTEGER,
    mbid        TEXT,                            -- MusicBrainz release id
    label       TEXT,
    label_tags  INTEGER NOT NULL DEFAULT 0,      -- 1 = file tags read
    label_mb    INTEGER NOT NULL DEFAULT 0,      -- 1 = MusicBrainz asked
    PRIMARY KEY (source_id, album_id)
);
CREATE INDEX music_album_library ON music_album (source_id, library);

CREATE TABLE music_index (
    source_id  INTEGER NOT NULL REFERENCES source(id) ON DELETE CASCADE,
    library    TEXT    NOT NULL,
    built_at   TEXT    NOT NULL,
    checked_at TEXT    NOT NULL,
    newest     TEXT    NOT NULL DEFAULT '',      -- id of the newest album when built
    total      INTEGER NOT NULL DEFAULT 0,
    PRIMARY KEY (source_id, library)
);

-- Episode chapters: the feed's chapter file (Podcasting 2.0) and the parsed chapters as JSON
-- ([] = none, NULL = not looked up yet). Fetch every feed in full once for Podlove chapters.
ALTER TABLE episode ADD COLUMN chapters_url TEXT NOT NULL DEFAULT '';
ALTER TABLE episode ADD COLUMN chapters TEXT;
UPDATE podcast SET etag = NULL, last_modified = NULL;
