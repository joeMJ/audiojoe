//! Settings of one account, the same on all its devices: `GET/PUT /api/v1/settings/playback`.
//! Changes reach the other devices at once (event `settings`).

use axum::{extract::State, Json};
use rusqlite::Connection;
use serde::Deserialize;
use serde_json::{json, Value};

use crate::{
    auth::CurrentUser,
    error::{with_db, ApiResult},
    AppState,
};

/// Playback settings with their defaults: podcasts and books continue 10 s earlier after another
/// device or after a pause of 5 minutes (user 2026-11-06: both on, switchable apart).
const PLAYBACK: &[(&str, bool)] = &[("rewind_podcasts", true), ("rewind_books", true)];

fn read(c: &Connection, user: i64) -> rusqlite::Result<Value> {
    let mut st = c.prepare("SELECT name, value FROM user_setting WHERE user_id = ?1")?;
    let rows: Vec<(String, String)> = st.query_map([user], |r| Ok((r.get(0)?, r.get(1)?)))?.collect::<Result<_, _>>()?;
    let mut out = serde_json::Map::new();
    for (name, default) in PLAYBACK {
        let v = rows.iter().find(|(n, _)| n == name).map(|(_, v)| v == "on").unwrap_or(*default);
        out.insert((*name).into(), json!(v));
    }
    Ok(Value::Object(out))
}

fn write(c: &Connection, user: i64, set: &[(&str, bool)]) -> rusqlite::Result<()> {
    for (name, on) in set {
        c.execute(
            "INSERT INTO user_setting (user_id, name, value) VALUES (?1, ?2, ?3)
             ON CONFLICT (user_id, name) DO UPDATE SET value = excluded.value",
            rusqlite::params![user, name, if *on { "on" } else { "off" }],
        )?;
    }
    Ok(())
}

pub async fn get_playback(State(state): State<AppState>, user: CurrentUser) -> ApiResult<Json<Value>> {
    let uid = user.id;
    Ok(Json(with_db(&state.db, move |c| Ok(read(c, uid)?)).await?))
}

#[derive(Deserialize)]
pub struct Playback {
    rewind_podcasts: Option<bool>,
    rewind_books: Option<bool>,
}

pub async fn put_playback(State(state): State<AppState>, user: CurrentUser, Json(req): Json<Playback>) -> ApiResult<Json<Value>> {
    let set: Vec<(&'static str, bool)> = [("rewind_podcasts", req.rewind_podcasts), ("rewind_books", req.rewind_books)]
        .into_iter()
        .filter_map(|(n, v)| v.map(|v| (n, v)))
        .collect();
    let uid = user.id;
    let now = with_db(&state.db, move |c| {
        write(c, uid, &set)?;
        Ok(read(c, uid)?)
    })
    .await?;
    let _ = state.events.send((uid, json!({ "type": "settings", "playback": now })));
    Ok(Json(now))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn defaults_on_changes_per_user() {
        let c = crate::db::open_memory().unwrap();
        c.execute("INSERT INTO user (id, name, password_hash, totp_secret) VALUES (1, 'a', 'x', 'y'), (2, 'b', 'x', 'y')", []).unwrap();
        assert_eq!(read(&c, 1).unwrap(), json!({ "rewind_podcasts": true, "rewind_books": true }));
        write(&c, 1, &[("rewind_podcasts", false)]).unwrap();
        assert_eq!(read(&c, 1).unwrap(), json!({ "rewind_podcasts": false, "rewind_books": true }));
        write(&c, 1, &[("rewind_podcasts", true), ("rewind_books", false)]).unwrap();
        assert_eq!(read(&c, 1).unwrap(), json!({ "rewind_podcasts": true, "rewind_books": false }));
        // Another account keeps its own settings.
        assert_eq!(read(&c, 2).unwrap(), json!({ "rewind_podcasts": true, "rewind_books": true }));
    }
}
