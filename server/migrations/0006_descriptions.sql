-- Descriptions and episode images from the feeds; clear the cache validators so every
-- feed is fetched in full once and the new fields get filled.
ALTER TABLE podcast ADD COLUMN description TEXT NOT NULL DEFAULT '';
ALTER TABLE episode ADD COLUMN description TEXT NOT NULL DEFAULT '';
ALTER TABLE episode ADD COLUMN image_url TEXT NOT NULL DEFAULT '';
UPDATE podcast SET etag = NULL, last_modified = NULL;
