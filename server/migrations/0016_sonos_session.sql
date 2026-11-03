-- What this server plays on a Sonos room: started by "Play there", kept across restarts,
-- ended by stop, takeover or when the speaker plays something else.
CREATE TABLE sonos_session (
    room_id     INTEGER PRIMARY KEY REFERENCES sonos_speaker(id) ON DELETE CASCADE,
    coordinator TEXT    NOT NULL,
    user_id     INTEGER NOT NULL REFERENCES user(id) ON DELETE CASCADE,
    item_key    TEXT    NOT NULL,
    queue       TEXT    NOT NULL DEFAULT '[]',   -- JSON list of item keys
    idx         INTEGER NOT NULL DEFAULT 0,
    state       TEXT    NOT NULL DEFAULT 'playing',   -- playing | paused | ended
    position_ms INTEGER NOT NULL DEFAULT 0,
    started_by  TEXT    NOT NULL,
    started_at  TEXT    NOT NULL,
    updated_at  TEXT    NOT NULL
);
