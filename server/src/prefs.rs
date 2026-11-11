//! Settings of one account, the same on all its devices: `GET/PUT /api/v1/settings/playback` and
//! `GET/PUT /api/v1/settings/sonos`. Changes reach the other devices at once (event `settings`).

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

/// Sonos settings with their defaults (0.3.1, user 2026-11-11 „204 ja“, „205 ja“): playback that starts on a
/// speaker sets it to `start_volume` (8); switched-off speakers are hidden in the output overlay.
pub const SONOS_START_VOLUME: i64 = 8;

pub fn read_sonos(c: &Connection, user: i64) -> rusqlite::Result<Value> {
    let get = |name: &str| -> rusqlite::Result<Option<String>> {
        c.query_row("SELECT value FROM user_setting WHERE user_id = ?1 AND name = ?2", rusqlite::params![user, name], |r| r.get(0))
            .map(Some)
            .or_else(|e| if matches!(e, rusqlite::Error::QueryReturnedNoRows) { Ok(None) } else { Err(e) })
    };
    let start = get("sonos_start_volume")?.and_then(|v| v.parse::<i64>().ok()).unwrap_or(SONOS_START_VOLUME).clamp(0, 100);
    let hide = get("sonos_hide_off")?.map(|v| v == "on").unwrap_or(true);
    Ok(json!({ "start_volume": start, "hide_off": hide }))
}

pub async fn get_sonos(State(state): State<AppState>, user: CurrentUser) -> ApiResult<Json<Value>> {
    let uid = user.id;
    Ok(Json(with_db(&state.db, move |c| Ok(read_sonos(c, uid)?)).await?))
}

#[derive(Deserialize)]
pub struct Sonos {
    start_volume: Option<i64>,
    hide_off: Option<bool>,
}

pub async fn put_sonos(State(state): State<AppState>, user: CurrentUser, Json(req): Json<Sonos>) -> ApiResult<Json<Value>> {
    if req.start_volume.is_some_and(|v| !(0..=100).contains(&v)) {
        return Err(crate::error::ApiError::BadRequest("start_volume: 0–100".into()));
    }
    let uid = user.id;
    let now = with_db(&state.db, move |c| {
        let put = |name: &str, value: String| {
            c.execute(
                "INSERT INTO user_setting (user_id, name, value) VALUES (?1, ?2, ?3)
                 ON CONFLICT (user_id, name) DO UPDATE SET value = excluded.value",
                rusqlite::params![uid, name, value],
            )
        };
        if let Some(v) = req.start_volume {
            put("sonos_start_volume", v.to_string())?;
        }
        if let Some(h) = req.hide_off {
            put("sonos_hide_off", if h { "on" } else { "off" }.into())?;
        }
        Ok(read_sonos(c, uid)?)
    })
    .await?;
    let _ = state.events.send((uid, json!({ "type": "settings", "sonos": now })));
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

    #[test]
    fn sonos_defaults_and_changes() {
        let c = crate::db::open_memory().unwrap();
        c.execute("INSERT INTO user (id, name, password_hash, totp_secret) VALUES (1, 'a', 'x', 'y')", []).unwrap();
        assert_eq!(read_sonos(&c, 1).unwrap(), json!({ "start_volume": 8, "hide_off": true }));
        c.execute("INSERT INTO user_setting (user_id, name, value) VALUES (1, 'sonos_start_volume', '12'), (1, 'sonos_hide_off', 'off')", []).unwrap();
        assert_eq!(read_sonos(&c, 1).unwrap(), json!({ "start_volume": 12, "hide_off": false }));
        // The playback settings are not touched by the Sonos ones.
        assert_eq!(read(&c, 1).unwrap(), json!({ "rewind_podcasts": true, "rewind_books": true }));
    }
}
