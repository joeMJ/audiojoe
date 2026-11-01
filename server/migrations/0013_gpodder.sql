-- gpodder-compatible sync for other podcast apps (AntennaPod, Kasts …). Those clients know
-- only user name and password, no TOTP: each user may set a separate app password that is
-- valid for the gpodder endpoints alone (Argon2id hash; NULL = switched off).
ALTER TABLE user ADD COLUMN gpodder_hash TEXT;

-- The client's devices (gpodder "device id", e.g. "antennapod-phone").
CREATE TABLE gpodder_device (
    user_id INTEGER NOT NULL REFERENCES user(id) ON DELETE CASCADE,
    id      TEXT    NOT NULL,
    caption TEXT    NOT NULL DEFAULT '',
    type    TEXT    NOT NULL DEFAULT 'other',
    PRIMARY KEY (user_id, id)
);

-- Subscription changes, so a client can ask "what changed since my last sync".
CREATE TABLE gpodder_sub_change (
    user_id INTEGER NOT NULL REFERENCES user(id) ON DELETE CASCADE,
    url     TEXT    NOT NULL,
    added   INTEGER NOT NULL,               -- 1 subscribed, 0 unsubscribed
    at      INTEGER NOT NULL                -- unix seconds
);
CREATE INDEX gpodder_sub_change_at ON gpodder_sub_change (user_id, at);

-- Episode actions uploaded by clients other than "play" (download, delete, new); play
-- positions go into playback and come back from there.
CREATE TABLE gpodder_action (
    id        INTEGER PRIMARY KEY,
    user_id   INTEGER NOT NULL REFERENCES user(id) ON DELETE CASCADE,
    podcast   TEXT    NOT NULL,
    episode   TEXT    NOT NULL,
    device    TEXT    NOT NULL DEFAULT '',
    action    TEXT    NOT NULL,
    timestamp TEXT    NOT NULL,             -- as sent by the client (ISO 8601)
    at        INTEGER NOT NULL              -- unix seconds, when received
);
CREATE INDEX gpodder_action_at ON gpodder_action (user_id, at);
