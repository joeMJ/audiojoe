-- The queue (e.g. an album) each device last played, so another device that takes over
-- the current title continues the whole queue. `current_key` is the queue's current item.
CREATE TABLE queue (
    user_id     INTEGER NOT NULL REFERENCES user(id) ON DELETE CASCADE,
    device      TEXT    NOT NULL,
    current_key TEXT    NOT NULL,
    data        TEXT    NOT NULL,   -- JSON {items, index, entry}
    updated_at  TEXT    NOT NULL,
    PRIMARY KEY (user_id, device)
);
CREATE INDEX queue_current ON queue (user_id, current_key, updated_at DESC);
