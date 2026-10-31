//! "Continue" lists per kind – podcasts, books, music – in the user's order, on all devices.
//!
//! Started, unfinished episodes and books join their list at the top by themselves (see
//! `playback::apply`); "Next" appends at the end; finished items leave. Music only holds what
//! was added with "Next" (albums), a track position alone does not add anything.

use axum::{
    extract::{Path, State},
    Json,
};
use serde::Deserialize;
use serde_json::{json, Value};

use crate::{
    auth::CurrentUser,
    error::{with_db, ApiError, ApiResult},
    AppState,
};

const LISTS: [&str; 3] = ["podcasts", "books", "music"];

fn check(list: &str) -> ApiResult<()> {
    if LISTS.contains(&list) { Ok(()) } else { Err(ApiError::NotFound) }
}

/// The list an item joins by itself when it is started; None for music and radio.
pub fn auto_list(key: &str) -> Option<&'static str> {
    if key.starts_with("episode:") {
        Some("podcasts")
    } else if key.starts_with("abs:") {
        Some("books")
    } else {
        None
    }
}

/// Keeps the lists in step with a stored playback state (inside the same transaction).
pub fn follow(c: &rusqlite::Connection, user: i64, key: &str, finished: bool, position_ms: i64, title: &str, subtitle: &str)
    -> rusqlite::Result<bool> {
    if finished {
        return Ok(c.execute("DELETE FROM list_entry WHERE user_id = ?1 AND item_key = ?2", (user, key))? > 0);
    }
    let Some(list) = auto_list(key) else { return Ok(false) };
    if position_ms <= 0 {
        return Ok(false);
    }
    let n = c.execute(
        "INSERT OR IGNORE INTO list_entry (user_id, list, item_key, position, title, subtitle)
         SELECT ?1, ?2, ?3, COALESCE(MIN(position), 0) - 1, ?4, ?5 FROM list_entry WHERE user_id = ?1 AND list = ?2",
        (user, list, key, title, subtitle),
    )?;
    Ok(n > 0)
}

fn changed(state: &AppState, user: i64, list: &str) {
    let _ = state.events.send((user, json!({ "type": "lists", "list": list })));
}

pub async fn get(State(state): State<AppState>, user: CurrentUser, Path(list): Path<String>) -> ApiResult<Json<Value>> {
    check(&list)?;
    with_db(&state.db, move |c| {
        let mut st = c.prepare(
            "SELECT e.item_key, e.title, e.subtitle, e.added_at, p.position_ms, p.duration_ms, p.device, p.updated_at,
                    COALESCE(NULLIF(p.title, ''), e.title) AS t, COALESCE(NULLIF(p.subtitle, ''), e.subtitle) AS s
             FROM list_entry e LEFT JOIN playback p ON p.user_id = e.user_id AND p.item_key = e.item_key
             WHERE e.user_id = ?1 AND e.list = ?2 ORDER BY e.position, e.added_at",
        )?;
        let rows = st
            .query_map((user.id, &list), |r| {
                Ok(json!({
                    "key": r.get::<_, String>(0)?,
                    "title": r.get::<_, String>(8)?,
                    "subtitle": r.get::<_, String>(9)?,
                    "added_at": r.get::<_, String>(3)?,
                    "position_ms": r.get::<_, Option<i64>>(4)?.unwrap_or(0),
                    "duration_ms": r.get::<_, Option<i64>>(5)?,
                    "device": r.get::<_, Option<String>>(6)?.unwrap_or_default(),
                    "updated_at": r.get::<_, Option<String>>(7)?,
                }))
            })?
            .collect::<Result<Vec<_>, _>>()?;
        Ok(Json(Value::Array(rows)))
    })
    .await
}

#[derive(Deserialize)]
pub struct Add {
    key: String,
    #[serde(default)]
    title: String,
    #[serde(default)]
    subtitle: String,
}

/// "Next": appends at the end; an entry already in the list stays where it is.
pub async fn add(State(state): State<AppState>, user: CurrentUser, Path(list): Path<String>, Json(a): Json<Add>) -> ApiResult<Json<Value>> {
    check(&list)?;
    if a.key.is_empty() || a.key.len() > 160 || !a.key.chars().all(|c| c.is_ascii_alphanumeric() || ":-_".contains(c)) {
        return Err(ApiError::BadRequest("invalid key".into()));
    }
    let l = list.clone();
    let added = with_db(&state.db, move |c| {
        Ok(c.execute(
            "INSERT OR IGNORE INTO list_entry (user_id, list, item_key, position, title, subtitle)
             SELECT ?1, ?2, ?3, COALESCE(MAX(position), 0) + 1, ?4, ?5 FROM list_entry WHERE user_id = ?1 AND list = ?2",
            (user.id, &l, &a.key, a.title.chars().take(300).collect::<String>(), a.subtitle.chars().take(300).collect::<String>()),
        )? > 0)
    })
    .await?;
    if added {
        changed(&state, user.id, &list);
    }
    Ok(Json(json!({ "added": added })))
}

/// New order: the keys in the wanted order (keys not named keep their place after them).
pub async fn order(State(state): State<AppState>, user: CurrentUser, Path(list): Path<String>, Json(keys): Json<Vec<String>>) -> ApiResult<Json<Value>> {
    check(&list)?;
    if keys.len() > 2000 {
        return Err(ApiError::BadRequest("too many".into()));
    }
    let l = list.clone();
    with_db(&state.db, move |c| {
        let tx = c.transaction()?;
        tx.execute("UPDATE list_entry SET position = position + 100000 WHERE user_id = ?1 AND list = ?2", (user.id, &l))?;
        for (i, k) in keys.iter().enumerate() {
            tx.execute("UPDATE list_entry SET position = ?4 WHERE user_id = ?1 AND list = ?2 AND item_key = ?3", (user.id, &l, k, i as f64))?;
        }
        tx.commit()?;
        Ok(())
    })
    .await?;
    changed(&state, user.id, &list);
    Ok(Json(json!({ "ok": true })))
}

pub async fn remove(State(state): State<AppState>, user: CurrentUser, Path((list, key)): Path<(String, String)>) -> ApiResult<Json<Value>> {
    check(&list)?;
    let l = list.clone();
    with_db(&state.db, move |c| {
        c.execute("DELETE FROM list_entry WHERE user_id = ?1 AND list = ?2 AND item_key = ?3", (user.id, &l, &key))?;
        Ok(())
    })
    .await?;
    changed(&state, user.id, &list);
    Ok(Json(json!({ "ok": true })))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn db() -> rusqlite::Connection {
        let c = crate::db::open_memory().unwrap();
        c.execute("INSERT INTO user (id, name, password_hash, totp_secret) VALUES (1, 'u', 'x', 'y')", []).unwrap();
        c
    }

    fn keys(c: &rusqlite::Connection, list: &str) -> Vec<String> {
        let mut st = c.prepare("SELECT item_key FROM list_entry WHERE user_id = 1 AND list = ?1 ORDER BY position").unwrap();
        st.query_map([list], |r| r.get(0)).unwrap().map(|r| r.unwrap()).collect()
    }

    #[test]
    fn started_items_go_on_top_finished_leave_music_stays_out() {
        let c = db();
        follow(&c, 1, "episode:1", false, 5000, "A", "").unwrap();
        follow(&c, 1, "episode:2", false, 5000, "B", "").unwrap();
        follow(&c, 1, "episode:1", false, 9000, "A", "").unwrap(); // already in: stays
        follow(&c, 1, "abs:1:x", false, 100, "Book", "").unwrap();
        follow(&c, 1, "jellyfin:1:t", false, 100, "Track", "").unwrap();
        follow(&c, 1, "episode:3", false, 0, "C", "").unwrap(); // not started
        assert_eq!(keys(&c, "podcasts"), ["episode:2", "episode:1"]);
        assert_eq!(keys(&c, "books"), ["abs:1:x"]);
        assert!(keys(&c, "music").is_empty());
        follow(&c, 1, "episode:2", true, 0, "", "").unwrap();
        assert_eq!(keys(&c, "podcasts"), ["episode:1"]);
    }
}
