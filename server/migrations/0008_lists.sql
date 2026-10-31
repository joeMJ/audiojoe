-- Radio favourites in the user's order; "continue" lists per kind (podcasts, books, music).
ALTER TABLE radio_favorite ADD COLUMN position REAL NOT NULL DEFAULT 0;
UPDATE radio_favorite SET position = (
    SELECT COUNT(*) FROM radio_favorite f JOIN radio_station s ON s.uuid = f.uuid
    WHERE f.user_id = radio_favorite.user_id
      AND s.name COLLATE NOCASE < (SELECT name FROM radio_station WHERE uuid = radio_favorite.uuid) COLLATE NOCASE);

CREATE TABLE list_entry (
    user_id  INTEGER NOT NULL REFERENCES user(id) ON DELETE CASCADE,
    list     TEXT    NOT NULL CHECK (list IN ('podcasts', 'books', 'music')),
    item_key TEXT    NOT NULL,
    position REAL    NOT NULL,
    title    TEXT    NOT NULL DEFAULT '',
    subtitle TEXT    NOT NULL DEFAULT '',
    added_at TEXT    NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now')),
    PRIMARY KEY (user_id, list, item_key)
);

-- Started, unfinished episodes and books: newest first.
INSERT INTO list_entry (user_id, list, item_key, position, title, subtitle)
SELECT user_id, CASE WHEN item_key LIKE 'episode:%' THEN 'podcasts' ELSE 'books' END, item_key,
       -(SELECT COUNT(*) FROM playback q WHERE q.user_id = p.user_id AND q.updated_at > p.updated_at),
       title, subtitle
FROM playback p
WHERE finished = 0 AND position_ms > 0 AND (item_key LIKE 'episode:%' OR item_key LIKE 'abs:%');
