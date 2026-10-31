-- Shownotes: the long, formatted episode text (filtered HTML); fetch every feed in full once
-- so it gets filled.
ALTER TABLE episode ADD COLUMN notes TEXT NOT NULL DEFAULT '';
UPDATE podcast SET etag = NULL, last_modified = NULL;
