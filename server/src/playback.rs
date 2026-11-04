//! Playback positions per user and item, synced across devices.
//!
//! Each update carries the client's time of the change (`updated_at`). The server keeps
//! the newest one, so positions recorded offline and sent later never overwrite a newer
//! position from another device. Timestamps in the future are clamped to the server time.
//! Changes are pushed to the user's other devices via Server-Sent Events.

use std::{convert::Infallible, time::Duration};

use axum::{
    extract::{Path, Query, State},
    http::{header::HeaderName, HeaderValue},
    response::{
        sse::{Event, KeepAlive, Sse},
        IntoResponse,
    },
    Json,
};
use chrono::{DateTime, Utc};
use serde::Deserialize;
use serde_json::{json, Value};
use tokio::sync::broadcast;

use crate::{
    auth::CurrentUser,
    devices,
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
    /// The reporting device's state (playing | paused | stopped) and kind; older clients send neither.
    #[serde(default)]
    state: Option<String>,
    #[serde(default)]
    kind: Option<String>,
    #[serde(default)]
    queue_index: Option<i64>,
}

fn ts(t: DateTime<Utc>) -> String {
    t.format("%Y-%m-%dT%H:%M:%S%.3fZ").to_string()
}

pub fn now() -> String {
    ts(Utc::now())
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

/// Stores the device state that came with an update; returns whether it changed.
fn report_device(c: &rusqlite::Connection, user: i64, device: &str, key: &str, u: &Update) -> ApiResult<bool> {
    let Some(state) = u.state.as_deref() else { return Ok(false) };
    let kind = u.kind.as_deref().filter(|k| devices::valid_kind(k) && *k != "sonos");
    if !devices::valid_state(state) {
        return Err(ApiError::BadRequest("invalid state".into()));
    }
    let when = ts(u.updated_at.min(Utc::now()));
    let r = devices::Report { kind, state, key, title: &u.title, subtitle: &u.subtitle, position_ms: u.position_ms,
                              duration_ms: u.duration_ms, queue_index: u.queue_index, updated_at: &when };
    Ok(devices::report(c, user, device, &r)?)
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
                     updated_at: e.updated_at, title: e.title, subtitle: e.subtitle, state: None, kind: None,
                     queue_index: None };
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
    let (applied, row, reported) = with_db(&state.db, move |c| {
        let (a, r) = apply(c, uid, &dev, &k, &u)?;
        Ok((a, r, report_device(c, uid, &dev, &k, &u)?))
    })
    .await?;
    if applied {
        let _ = state.events.send((user.id, json!({ "type": "playback", "state": row.clone() })));
        crate::audiobookshelf::push_later(&state, user.id, &key);
    }
    if reported {
        devices::notify(&state, user.id, &user.device).await;
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
        let (mut out, mut reported) = (Vec::new(), false);
        for u in &list {
            let key = u.key.clone().ok_or_else(|| ApiError::BadRequest("key missing".into()))?;
            out.push(apply(&tx, uid, &dev, &key, u)?);
            reported |= report_device(&tx, uid, &dev, &key, u)?;
        }
        tx.commit()?;
        Ok((out, reported))
    })
    .await?;
    let (results, reported) = results;
    if reported {
        devices::notify(&state, user.id, &user.device).await;
    }
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

#[derive(Deserialize)]
pub struct EventsQuery {
    /// The connecting device's kind (linux | windows | android | web).
    #[serde(default)]
    kind: Option<String>,
}

/// Server-Sent Events with the user's playback changes from all devices. An open stream
/// marks its device as online.
pub async fn events(
    State(state): State<AppState>,
    user: CurrentUser,
    Query(q): Query<EventsQuery>,
) -> impl IntoResponse {
    if let Some(kind) = q.kind.filter(|k| devices::valid_kind(k) && k != "sonos") {
        let (uid, dev) = (user.id, user.device.clone());
        let _ = with_db(&state.db, move |c| Ok(devices::set_kind(c, uid, &dev, &kind)?)).await;
    }
    let guard = devices::connect(&state, user.id, &user.device);
    let rx = state.events.subscribe();
    let stream = futures_util::stream::unfold((rx, user.id, guard), |(mut rx, uid, guard)| async move {
        loop {
            match rx.recv().await {
                Ok((u, v)) if u == uid => {
                    let name = v["type"].as_str().unwrap_or("playback").to_string();
                    return Some((Ok::<_, Infallible>(Event::default().event(name).data(v.to_string())), (rx, uid, guard)));
                }
                Ok(_) => continue,
                // Missed events: tell the client to reload instead of silently dropping them.
                Err(broadcast::error::RecvError::Lagged(_)) => {
                    return Some((Ok::<_, Infallible>(Event::default().event("resync").data("{}")), (rx, uid, guard)))
                }
                Err(broadcast::error::RecvError::Closed) => return None,
            }
        }
    });
    // The keep-alive is a named event, not a comment: a browser's EventSource does not pass
    // comments on, and the clients watch for a sign of life to notice a stream that died quietly.
    let sse = Sse::new(stream).keep_alive(KeepAlive::new().interval(Duration::from_secs(15)).event(Event::default().event("ping").data("{}")));
    // nginx (and Nginx Proxy Manager) pass each event on at once instead of buffering this one
    // response; other proxies ignore the header.
    ([(HeaderName::from_static("x-accel-buffering"), HeaderValue::from_static("no"))], sse)
}

#[derive(Deserialize)]
pub struct Queue {
    items: Vec<Value>,
    index: usize,
    #[serde(default)]
    entry: Option<Value>,
}

/// Stores this device's queue; a queue of one title removes it.
pub async fn put_queue(State(state): State<AppState>, user: CurrentUser, Json(q): Json<Queue>) -> ApiResult<Json<Value>> {
    let current = q.items.get(q.index).and_then(|i| i["key"].as_str()).unwrap_or("").to_string();
    if q.items.len() > 1000 || !valid_key(&current) {
        return Err(ApiError::BadRequest("invalid queue".into()));
    }
    let data = json!({ "items": q.items, "index": q.index, "entry": q.entry }).to_string();
    if data.len() > 2_000_000 {
        return Err(ApiError::BadRequest("queue too large".into()));
    }
    let (uid, dev, single) = (user.id, user.device.clone(), q.items.len() < 2);
    with_db(&state.db, move |c| {
        if single {
            c.execute("DELETE FROM queue WHERE user_id = ?1 AND device = ?2", (uid, &dev))?;
        } else {
            c.execute(
                "INSERT INTO queue (user_id, device, current_key, data, updated_at) VALUES (?1, ?2, ?3, ?4, ?5)
                 ON CONFLICT (user_id, device) DO UPDATE SET current_key = excluded.current_key,
                   data = excluded.data, updated_at = excluded.updated_at",
                (uid, &dev, &current, &data, ts(Utc::now())),
            )?;
        }
        Ok(Json(json!({ "ok": true })))
    })
    .await
}

/// The newest queue of any of the user's devices whose current item is `key`.
pub async fn get_queue(State(state): State<AppState>, user: CurrentUser, Path(key): Path<String>) -> ApiResult<Json<Value>> {
    with_db(&state.db, move |c| {
        let data: String = c.query_row(
            "SELECT data FROM queue WHERE user_id = ?1 AND current_key = ?2 ORDER BY updated_at DESC LIMIT 1",
            (user.id, key),
            |r| r.get(0),
        )?;
        Ok(Json(serde_json::from_str(&data).map_err(|e| ApiError::Internal(e.into()))?))
    })
    .await
}
