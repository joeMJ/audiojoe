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
    include_str!("../migrations/0007_notes.sql"),
    include_str!("../migrations/0008_lists.sql"),
    include_str!("../migrations/0009_lists_cleanup.sql"),
    include_str!("../migrations/0010_lists_unsubscribed.sql"),
    include_str!("../migrations/0011_libraries_music_chapters.sql"),
    include_str!("../migrations/0012_queue.sql"),
    include_str!("../migrations/0013_gpodder.sql"),
    include_str!("../migrations/0014_drop_probe.sql"),
    include_str!("../migrations/0015_device_state.sql"),
    include_str!("../migrations/0016_sonos_session.sql"),
    include_str!("../migrations/0017_user_setting.sql"),
    include_str!("../migrations/0018_device_label.sql"),
    include_str!("../migrations/0019_likes.sql"),
];

pub type Db = Arc<Mutex<Connection>>;

pub fn open(path: &Path) -> Result<Db> {
    if let Some(dir) = path.parent() {
        std::fs::create_dir_all(dir)
            .with_context(|| format!("cannot create {}", dir.display()))?;
    }
    let mut conn =
        Connection::open(path).with_context(|| format!("cannot open {}", path.display()))?;
    check(&conn, path)?;
    conn.pragma_update(None, "journal_mode", "WAL")?;
    conn.pragma_update(None, "foreign_keys", "ON")?;
    migrate(&mut conn)?;
    Ok(Arc::new(Mutex::new(conn)))
}

/// `PRAGMA quick_check` before anything else touches the file (user 2026-11-04 „17 ja“, 2026-11-06 for 0.1.8):
/// a damaged database is neither migrated nor used, the server stops with a clear message.
fn check(conn: &Connection, path: &Path) -> Result<()> {
    let finding = match conn.query_row("PRAGMA quick_check(1)", [], |r| r.get::<_, String>(0)) {
        Ok(r) if r == "ok" => return Ok(()),
        Ok(r) => r,
        Err(e) => e.to_string(),
    };
    // One line in the journal: SQLite puts "*** in database main ***" on a line of its own.
    let finding = finding.split_whitespace().collect::<Vec<_>>().join(" ");
    anyhow::bail!(
        "Database check failed: {} is damaged ({finding}). audiojoe will not start, so the damage does not spread. Restore the latest backup, see BACKUP.md.",
        path.display()
    )
}

/// An empty database with all migrations, for tests.
#[cfg(test)]
pub fn open_memory() -> Result<Connection> {
    let mut conn = Connection::open_in_memory()?;
    conn.pragma_update(None, "foreign_keys", "ON")?;
    migrate(&mut conn)?;
    Ok(conn)
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

#[cfg(test)]
mod tests {
    use super::*;

    fn temp(name: &str) -> std::path::PathBuf {
        let dir = std::env::temp_dir().join(format!("audiojoe-db-test-{}-{name}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        dir.join("audiojoe.db")
    }

    #[test]
    fn healthy_and_new_databases_open() {
        let path = temp("ok");
        drop(open(&path).unwrap());
        // Second start on the existing file.
        drop(open(&path).unwrap());
        let _ = std::fs::remove_dir_all(path.parent().unwrap());
    }

    #[test]
    fn damaged_database_stops_with_message() {
        let path = temp("damaged");
        {
            let c = Connection::open(&path).unwrap();
            c.execute_batch("CREATE TABLE t (a TEXT); CREATE INDEX t_a ON t (a);").unwrap();
            for i in 0..2000 {
                c.execute("INSERT INTO t (a) VALUES (?1)", [format!("row {i} {}", "x".repeat(50))]).unwrap();
            }
        }
        // Overwrite part of the second page and beyond with garbage, as a disk error would.
        let mut bytes = std::fs::read(&path).unwrap();
        for b in bytes.iter_mut().skip(4096 + 100).take(8192) {
            *b = 0x5a;
        }
        std::fs::write(&path, bytes).unwrap();
        let err = open(&path).err().expect("damaged database must not open").to_string();
        assert!(err.starts_with("Database check failed: "), "{err}");
        assert!(err.contains("is damaged ("), "{err}");
        assert!(err.ends_with("audiojoe will not start, so the damage does not spread. Restore the latest backup, see BACKUP.md."), "{err}");
        let _ = std::fs::remove_dir_all(path.parent().unwrap());
    }

    #[test]
    fn not_a_database_stops_with_message() {
        let path = temp("garbage");
        std::fs::write(&path, vec![0x5a; 8192]).unwrap();
        let err = open(&path).err().expect("garbage must not open").to_string();
        assert!(err.starts_with("Database check failed: "), "{err}");
        let _ = std::fs::remove_dir_all(path.parent().unwrap());
    }
}
