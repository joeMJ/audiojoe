-- Name a device is shown with, given in the settings ("Rename"). The device name stays the key
-- everywhere else (session, device_state, queue, ...); no row there is rewritten.
CREATE TABLE device_label (
    user_id INTEGER NOT NULL REFERENCES user(id) ON DELETE CASCADE,
    device  TEXT    NOT NULL,
    label   TEXT    NOT NULL,
    PRIMARY KEY (user_id, device)
);
