-- Stage 0: measurements reported by the browser capability probe.
CREATE TABLE probe_result (
    id          INTEGER PRIMARY KEY,
    received_at TEXT    NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now')),
    user_agent  TEXT    NOT NULL,
    report      TEXT    NOT NULL  -- JSON as sent by the probe page
);
