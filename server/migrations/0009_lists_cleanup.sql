-- Entries whose episode or source is gone (left from before removal cleaned the lists too).
DELETE FROM list_entry WHERE item_key LIKE 'episode:%'
  AND CAST(substr(item_key, 9) AS INTEGER) NOT IN (SELECT id FROM episode);
DELETE FROM list_entry WHERE item_key LIKE 'abs:%'
  AND CAST(substr(item_key, 5, instr(substr(item_key, 5), ':') - 1) AS INTEGER) NOT IN (SELECT id FROM source);
