use std::{
    path::Path,
    sync::{Arc, Mutex},
};

use anyhow::{Context, Result};
use rusqlite::Connection;

/// Schema migrations, applied in order. The index + 1 is stored in `PRAGMA user_version`.
const MIGRATIONS: &[&str] = &[
    include_str!("../migrations/0001_init.sql"),
    include_str!("../migrations/0002_core.sql"),
    include_str!("../migrations/0003_source_owner.sql"),
    include_str!("../migrations/0004_radio_sonos.sql"),
    include_str!("../migrations/0005_settings.sql"),
    include_str!("../migrations/0006_descriptions.sql"),
];

pub type Db = Arc<Mutex<Connection>>;

pub fn open(path: &Path) -> Result<Db> {
    if let Some(dir) = path.parent() {
        std::fs::create_dir_all(dir)
            .with_context(|| format!("cannot create {}", dir.display()))?;
    }
    let mut conn =
        Connection::open(path).with_context(|| format!("cannot open {}", path.display()))?;
    conn.pragma_update(None, "journal_mode", "WAL")?;
    conn.pragma_update(None, "foreign_keys", "ON")?;
    migrate(&mut conn)?;
    Ok(Arc::new(Mutex::new(conn)))
}

fn migrate(conn: &mut Connection) -> Result<()> {
    let current: usize = conn.pragma_query_value(None, "user_version", |r| r.get(0))?;
    for (i, sql) in MIGRATIONS.iter().enumerate().skip(current) {
        let tx = conn.transaction()?;
        tx.execute_batch(sql)
            .with_context(|| format!("migration {} failed", i + 1))?;
        tx.pragma_update(None, "user_version", i + 1)?;
        tx.commit()?;
        tracing::info!("applied migration {}", i + 1);
    }
    Ok(())
}
