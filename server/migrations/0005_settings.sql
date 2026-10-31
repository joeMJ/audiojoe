-- Server-wide settings, e.g. the key that signs stream URLs for Sonos speakers.
CREATE TABLE setting (
    name  TEXT PRIMARY KEY,
    value TEXT NOT NULL
);
