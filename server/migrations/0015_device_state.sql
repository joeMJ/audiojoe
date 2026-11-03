-- What each of the user's devices plays or played last, for controlling one device from
-- another. One row per device name; the newest report wins.
CREATE TABLE device_state (
    user_id     INTEGER NOT NULL REFERENCES user(id) ON DELETE CASCADE,
    device      TEXT    NOT NULL,
    kind        TEXT    NOT NULL DEFAULT '',   -- linux | windows | android | web | sonos
    state       TEXT    NOT NULL DEFAULT 'stopped',   -- playing | paused | stopped
    item_key    TEXT    NOT NULL DEFAULT '',
    title       TEXT    NOT NULL DEFAULT '',
    subtitle    TEXT    NOT NULL DEFAULT '',
    position_ms INTEGER NOT NULL DEFAULT 0,
    duration_ms INTEGER,
    queue_index INTEGER,
    updated_at  TEXT    NOT NULL,
    PRIMARY KEY (user_id, device)
);
