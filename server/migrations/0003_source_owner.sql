-- The user who added a source. Sources with their own per-user state (Audiobookshelf
-- listening progress) are synced with this user's playback positions.
ALTER TABLE source ADD COLUMN owner_user_id INTEGER REFERENCES user(id) ON DELETE SET NULL;
