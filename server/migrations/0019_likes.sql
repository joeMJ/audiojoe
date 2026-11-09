-- Likes (0.2.6, user 2026-11-09): the continue lists get "likes", music titles marked with the heart.
-- SQLite cannot change a CHECK constraint, so the table is built anew with the same rows.
CREATE TABLE list_entry_new (
    user_id  INTEGER NOT NULL REFERENCES user(id) ON DELETE CASCADE,
    list     TEXT    NOT NULL CHECK (list IN ('podcasts', 'books', 'music', 'likes')),
    item_key TEXT    NOT NULL,
    position REAL    NOT NULL,
    title    TEXT    NOT NULL DEFAULT '',
    subtitle TEXT    NOT NULL DEFAULT '',
    added_at TEXT    NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now')),
    PRIMARY KEY (user_id, list, item_key)
);
INSERT INTO list_entry_new (user_id, list, item_key, position, title, subtitle, added_at)
SELECT user_id, list, item_key, position, title, subtitle, added_at FROM list_entry;
DROP TABLE list_entry;
ALTER TABLE list_entry_new RENAME TO list_entry;
