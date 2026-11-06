-- Settings of one account, the same on all its devices (e.g. continue 10 s earlier).
CREATE TABLE user_setting (
    user_id INTEGER NOT NULL REFERENCES user(id) ON DELETE CASCADE,
    name    TEXT    NOT NULL,
    value   TEXT    NOT NULL,
    PRIMARY KEY (user_id, name)
);
