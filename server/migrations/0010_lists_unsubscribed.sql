-- Episodes of podcasts the user no longer subscribes to cannot be played: out of the lists.
DELETE FROM list_entry WHERE item_key LIKE 'episode:%' AND NOT EXISTS (
    SELECT 1 FROM episode e JOIN subscription s ON s.podcast_id = e.podcast_id
    WHERE e.id = CAST(substr(list_entry.item_key, 9) AS INTEGER) AND s.user_id = list_entry.user_id);
