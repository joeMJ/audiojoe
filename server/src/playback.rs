//! Playback positions per user and item, synced across devices.
//!
//! Each update carries the client's time of the change (`updated_at`). The server keeps
//! the newest one, so positions recorded offline and sent later never overwrite a newer
//! position from another device. Timestamps in the future are clamped to the server time.
//! Changes are pushed to the user's other devices via Server-Sent Events.

use std::{convert::Infallible, time::Duration};

use axum::{
    extract::{Path, Query, State},
    response::sse::{Event, KeepAlive, Sse},
    Json,
};
use chrono::{DateTime, Utc};
use futures_util::Stream;
use serde::Deserialize;
use serde_json::{json, Value};
use tokio::sync::broadcast;

use crate::{
    auth::CurrentUser,
    error::{with_db, ApiError, ApiResult},
    AppState,
};

/// (user id, event payload)
pub type Events = broadcast::Sender<(i64, Value)>;

#[derive(Deserialize, Clone)]
pub struct Update {
    #[serde(default)]
    key: Option<String>,
    position_ms: i64,
    duration_ms: Option<i64>,
    #[serde(default)]
    finished: bool,
    updated_at: DateTime<Utc>,
    #[serde(default)]
    title: String,
    #[serde(default)]
    subtitle: String,
}

fn ts(t: DateTime<Utc>) -> String {
    t.format("%Y-%m-%dT%H:%M:%S%.3fZ").to_string()
}

fn row_json(r: &rusqlite::Row) -> rusqlite::Result<Value> {
    Ok(json!({
        "key": r.get::<_, String>("item_key")?,
        "position_ms": r.get::<_, i64>("position_ms")?,
        "duration_ms": r.get::<_, Option<i64>>("duration_ms")?,
        "finished": r.get::<_, bool>("finished")?,
        "title": r.get::<_, String>("title")?,
        "subtitle": r.get::<_, String>("subtitle")?,
        "device": r.get::<_, String>("device")?,
        "updated_at": r.get::<_, String>("updated_at")?,
    }))
}

fn valid_key(k: &str) -> bool {
    !k.is_empty() && k.len() <= 160 && k.chars().all(|c| c.is_ascii_alphanumeric() || ":-_".contains(c))
}

/// Applies one update; returns (applied, stored state).
fn apply(c: &rusqlite::Connection, user: i64, device: &str, key: &str, u: &Update) -> ApiResult<(bool, Value)> {
    if !valid_key(key) || u.position_ms < 0 {
        return Err(ApiError::BadRequest("invalid key or position".into()));
    }
    let when = ts(u.updated_at.min(Utc::now()));
    let n = c.execute(
        "INSERT INTO playback (user_id, item_key, position_ms, duration_ms, finished, title, subtitle, device, updated_at)
         VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9)
         ON CONFLICT (user_id, item_key) DO UPDATE SET
           position_ms = excluded.position_ms, duration_ms = COALESCE(excluded.duration_ms, duration_ms),
           finished = excluded.finished,
           title = CASE WHEN excluded.title <> '' THEN excluded.title ELSE title END,
           subtitle = CASE WHEN excluded.subtitle <> '' THEN excluded.subtitle ELSE subtitle END,
           device = excluded.device, updated_at = excluded.updated_at
         WHERE excluded.updated_at > playback.updated_at",
        (user, key, u.position_ms, u.duration_ms, u.finished, u.title.chars().take(300).collect::<String>(),
         u.subtitle.chars().take(300).collect::<String>(), device, when),
    )?;
    if n > 0 {
        crate::lists::follow(c, user, key, u.finished, u.position_ms, &u.title, &u.subtitle)?;
    }
    let row = c.query_row("SELECT * FROM playback WHERE user_id = ?1 AND item_key = ?2", (user, key), row_json)?;
    Ok((n > 0, row))
}

/// A position from another system (e.g. Audiobookshelf).
pub struct External {
    pub position_ms: i64,
    pub duration_ms: Option<i64>,
    pub finished: bool,
    pub updated_at: DateTime<Utc>,
    pub title: String,
    pub subtitle: String,
}

pub async fn apply_external(state: &AppState, user: i64, device: &str, key: &str, e: External) -> ApiResult<()> {
    let u = Update { key: None, position_ms: e.position_ms, duration_ms: e.duration_ms, finished: e.finished,
                     updated_at: e.updated_at, title: e.title, subtitle: e.subtitle };
    let (dev, k) = (device.to_string(), key.to_string());
    let (applied, row) = with_db(&state.db, move |c| apply(c, user, &dev, &k, &u)).await?;
    if applied {
        let _ = state.events.send((user, json!({ "type": "playback", "state": row })));
    }
    Ok(())
}

pub async fn put(
    State(state): State<AppState>,
    user: CurrentUser,
    Path(key): Path<String>,
    Json(u): Json<Update>,
) -> ApiResult<Json<Value>> {
    let (uid, dev) = (user.id, user.device.clone());
    let k = key.clone();
    let (applied, row) = with_db(&state.db, move |c| apply(c, uid, &dev, &k, &u)).await?;
    if applied {
        let _ = state.events.send((user.id, json!({ "type": "playback", "state": row.clone() })));
        crate::audiobookshelf::push_later(&state, user.id, &key);
    }
    Ok(Json(json!({ "applied": applied, "state": row })))
}

/// Several updates at once, e.g. positions buffered while offline.
pub async fn sync(State(state): State<AppState>, user: CurrentUser, Json(list): Json<Vec<Update>>) -> ApiResult<Json<Value>> {
    if list.len() > 500 {
        return Err(ApiError::BadRequest("max. 500 updates".into()));
    }
    let (uid, dev) = (user.id, user.device.clone());
    let results = with_db(&state.db, move |c| {
        let tx = c.transaction()?;
        let mut out = Vec::new();
        for u in &list {
            let key = u.key.clone().ok_or_else(|| ApiError::BadRequest("key missing".into()))?;
            out.push(apply(&tx, uid, &dev, &key, u)?);
        }
        tx.commit()?;
        Ok(out)
    })
    .await?;
    for (applied, row) in &results {
        if *applied {
            let _ = state.events.send((user.id, json!({ "type": "playback", "state": row })));
            crate::audiobookshelf::push_later(&state, user.id, row["key"].as_str().unwrap_or(""));
        }
    }
    Ok(Json(Value::Array(results.into_iter().map(|(a, r)| json!({ "applied": a, "state": r })).collect())))
}

pub async fn get(State(state): State<AppState>, user: CurrentUser, Path(key): Path<String>) -> ApiResult<Json<Value>> {
    with_db(&state.db, move |c| {
        Ok(Json(c.query_row("SELECT * FROM playback WHERE user_id = ?1 AND item_key = ?2", (user.id, key), row_json)?))
    })
    .await
}

#[derive(Deserialize)]
pub struct ListQuery {
    limit: Option<i64>,
    /// Only unfinished items ("continue listening").
    #[serde(default)]
    unfinished: bool,
}

pub async fn list(State(state): State<AppState>, user: CurrentUser, Query(q): Query<ListQuery>) -> ApiResult<Json<Value>> {
    let limit = q.limit.unwrap_or(20).clamp(1, 200);
    with_db(&state.db, move |c| {
        let sql = format!(
            "SELECT * FROM playback WHERE user_id = ?1 {} ORDER BY updated_at DESC LIMIT ?2",
            if q.unfinished { "AND finished = 0 AND position_ms > 0" } else { "" }
        );
        let mut stmt = c.prepare(&sql)?;
        let rows = stmt.query_map((user.id, limit), row_json)?.collect::<Result<Vec<_>, _>>()?;
        Ok(Json(Value::Array(rows)))
    })
    .await
}

/// Server-Sent Events with the user's playback changes from all devices.
pub async fn events(State(state): State<AppState>, user: CurrentUser) -> Sse<impl Stream<Item = Result<Event, Infallible>>> {
    let rx = state.events.subscribe();
    let stream = futures_util::stream::unfold((rx, user.id), |(mut rx, uid)| async move {
        loop {
            match rx.recv().await {
                Ok((u, v)) if u == uid => {
                    let name = v["type"].as_str().unwrap_or("playback").to_string();
                    return Some((Ok(Event::default().event(name).data(v.to_string())), (rx, uid)));
                }
                Ok(_) => continue,
                // Missed events: tell the client to reload instead of silently dropping them.
                Err(broadcast::error::RecvError::Lagged(_)) => {
                    return Some((Ok(Event::default().event("resync").data("{}")), (rx, uid)))
                }
                Err(broadcast::error::RecvError::Closed) => return None,
            }
        }
    });
    Sse::new(stream).keep_alive(KeepAlive::new().interval(Duration::from_secs(15)))
}
