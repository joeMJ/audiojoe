//! gpodder.net-compatible API for other podcast apps (AntennaPod, Kasts, gPodder …):
//! subscriptions and episode actions (play positions) are shared with audiojoe's own lists.
//!
//! Endpoints (gpodder.net API 2 as the clients use it):
//! - `POST /api/2/auth/{user}/login.json` (HTTP Basic) → cookie `sessionid`; `…/logout.json`
//! - `GET /api/2/devices/{user}.json`, `POST /api/2/devices/{user}/{device}.json`
//! - `GET|PUT /subscriptions/{user}/{device}.json` (whole list)
//! - `GET /api/2/subscriptions/{user}/{device}.json?since=` → `{add, remove, timestamp}`,
//!   `POST` with `{add, remove}` → `{timestamp, update_urls}`
//! - `POST /api/2/episodes/{user}.json` (actions), `GET …?since=&podcast=&device=`
//!
//! Those clients know only user name and password, no TOTP, so each user may create a
//! separate app password (`POST /api/v1/gpodder/password`, shown once, stored as Argon2id
//! hash). It is valid for these endpoints only; nothing else accepts it. Timestamps are unix
//! seconds, as gpodder defines them.

use std::time::{SystemTime, UNIX_EPOCH};

use axum::{
    extract::{FromRequestParts, Path, Query, State},
    http::{header, request::Parts, HeaderValue, StatusCode},
    response::{IntoResponse, Response},
    routing::{get, post},
    Json, Router,
};
use base64::Engine;
use chrono::{DateTime, NaiveDateTime, Utc};
use rusqlite::OptionalExtension;
use serde::Deserialize;
use serde_json::{json, Value};

use crate::{
    auth::{self, CurrentUser},
    error::{with_db, ApiError, ApiResult},
    playback, podcasts, AppState,
};

const COOKIE: &str = "sessionid";

fn now() -> i64 {
    SystemTime::now().duration_since(UNIX_EPOCH).map(|d| d.as_secs() as i64).unwrap_or(0)
}

/// gpodder timestamps are seconds; audiojoe stores RFC 3339.
fn unix_of(rfc3339: &str) -> i64 {
    DateTime::parse_from_rfc3339(rfc3339).map(|d| d.timestamp()).unwrap_or(0)
}

/// Client timestamps come as "2009-12-12T09:00:00" (UTC, no zone) or with a zone.
fn parse_client_time(s: &str) -> DateTime<Utc> {
    DateTime::parse_from_rfc3339(s)
        .map(|d| d.with_timezone(&Utc))
        .or_else(|_| NaiveDateTime::parse_from_str(s, "%Y-%m-%dT%H:%M:%S").map(|n| n.and_utc()))
        .or_else(|_| NaiveDateTime::parse_from_str(s, "%Y-%m-%dT%H:%M:%S%.f").map(|n| n.and_utc()))
        .unwrap_or_else(|_| Utc::now())
}

fn valid_device(id: &str) -> bool {
    !id.is_empty() && id.len() <= 64 && id.chars().all(|c| c.is_ascii_alphanumeric() || "-_.".contains(c))
}

fn valid_url(u: &str) -> bool {
    (u.starts_with("https://") || u.starts_with("http://")) && u.len() <= 2048
}

// ---------------------------------------------------------------- app password (audiojoe API)

/// `GET /api/v1/gpodder`: switched on? and the clients' devices.
pub async fn info(State(state): State<AppState>, user: CurrentUser) -> ApiResult<Json<Value>> {
    with_db(&state.db, move |c| {
        let on: bool = c.query_row("SELECT gpodder_hash IS NOT NULL FROM user WHERE id = ?1", [user.id], |r| r.get(0))?;
        let mut st = c.prepare("SELECT id, caption, type FROM gpodder_device WHERE user_id = ?1 ORDER BY id")?;
        let devices: Vec<Value> = st
            .query_map([user.id], |r| Ok(json!({ "id": r.get::<_, String>(0)?, "caption": r.get::<_, String>(1)?, "type": r.get::<_, String>(2)? })))?
            .collect::<Result<_, _>>()?;
        Ok(Json(json!({ "enabled": on, "username": user.name, "devices": devices })))
    })
    .await
}

/// `POST /api/v1/gpodder/password`: a new app password, shown once; replaces an old one.
pub async fn new_password(State(state): State<AppState>, user: CurrentUser) -> ApiResult<Json<Value>> {
    // 20 characters from the token alphabet: easy to type, 100+ bits.
    let password: String = auth::random_token().chars().take(20).collect();
    let hash = tokio::task::spawn_blocking({
        let p = password.clone();
        move || auth::hash_password(&p)
    })
    .await
    .map_err(|e| ApiError::Internal(e.into()))?
    .map_err(ApiError::Internal)?;
    with_db(&state.db, move |c| {
        c.execute("UPDATE user SET gpodder_hash = ?1 WHERE id = ?2", (hash, user.id))?;
        Ok(())
    })
    .await?;
    Ok(Json(json!({ "username": user.name, "password": password })))
}

/// `DELETE /api/v1/gpodder/password`: switches the sync off; the clients' sessions end too.
pub async fn drop_password(State(state): State<AppState>, user: CurrentUser) -> ApiResult<Json<Value>> {
    with_db(&state.db, move |c| {
        c.execute("UPDATE user SET gpodder_hash = NULL WHERE id = ?1", [user.id])?;
        c.execute("DELETE FROM session WHERE user_id = ?1 AND device LIKE 'gpodder%'", [user.id])?;
        Ok(Json(json!({ "enabled": false })))
    })
    .await
}

// ---------------------------------------------------------------- authentication

/// The user of a gpodder request: HTTP Basic with the app password, or the session cookie
/// from `login.json`. The user name in the path must be the same.
pub struct GpodderUser {
    pub id: i64,
    pub name: String,
}

fn basic_credentials(parts: &Parts) -> Option<(String, String)> {
    let v = parts.headers.get(header::AUTHORIZATION)?.to_str().ok()?;
    let b64 = v.strip_prefix("Basic ")?.trim();
    let raw = base64::engine::general_purpose::STANDARD.decode(b64).ok()?;
    let s = String::from_utf8(raw).ok()?;
    let (u, p) = s.split_once(':')?;
    Some((u.to_string(), p.to_string()))
}

fn cookie_token(parts: &Parts) -> Option<String> {
    parts
        .headers
        .get_all(header::COOKIE)
        .iter()
        .filter_map(|v| v.to_str().ok())
        .flat_map(|v| v.split(';'))
        .filter_map(|kv| kv.trim().split_once('='))
        .find(|(k, _)| *k == COOKIE)
        .map(|(_, v)| v.to_string())
}

impl FromRequestParts<AppState> for GpodderUser {
    type Rejection = Response;

    async fn from_request_parts(parts: &mut Parts, state: &AppState) -> Result<Self, Self::Rejection> {
        let unauthorized = || {
            (StatusCode::UNAUTHORIZED, [(header::WWW_AUTHENTICATE, "Basic realm=\"audiojoe gpodder\"")], "unauthorized").into_response()
        };
        if let Some(token) = cookie_token(parts) {
            let th = auth::token_hash(&token);
            let found = with_db(&state.db, move |c| {
                Ok(c.query_row(
                    "SELECT u.id, u.name FROM session s JOIN user u ON u.id = s.user_id
                     WHERE s.token_hash = ?1 AND s.device LIKE 'gpodder%' AND u.gpodder_hash IS NOT NULL
                       AND s.expires_at > strftime('%Y-%m-%dT%H:%M:%SZ', 'now')",
                    [&th],
                    |r| Ok(GpodderUser { id: r.get(0)?, name: r.get(1)? }),
                )
                .optional()?)
            })
            .await
            .map_err(|e| e.into_response())?;
            if let Some(u) = found {
                return Ok(u);
            }
        }
        let Some((name, password)) = basic_credentials(parts) else { return Err(unauthorized()) };
        let key = format!("gpodder:{}", name.to_lowercase());
        if state.guard.blocked(&key) {
            return Err(ApiError::TooManyRequests.into_response());
        }
        let n = name.clone();
        let row = with_db(&state.db, move |c| {
            Ok(c.query_row("SELECT id, gpodder_hash FROM user WHERE name = ?1", [&n], |r| Ok((r.get::<_, i64>(0)?, r.get::<_, Option<String>>(1)?)))
                .optional()?)
        })
        .await
        .map_err(|e| e.into_response())?;
        let hash = row.as_ref().and_then(|r| r.1.clone()).unwrap_or_else(|| state.dummy_hash.to_string());
        let ok = tokio::task::spawn_blocking(move || auth::verify_password(&hash, &password)).await.unwrap_or(false);
        match row {
            Some((id, Some(_))) if ok => {
                state.guard.clear(&key);
                Ok(GpodderUser { id, name })
            }
            _ => {
                state.guard.fail(&key);
                tracing::warn!(target: "access", "gpodder login failed for {name:?}");
                Err(unauthorized())
            }
        }
    }
}

fn same_user(u: &GpodderUser, name: &str) -> ApiResult<()> {
    if u.name == name { Ok(()) } else { Err(ApiError::Unauthorized) }
}

/// `POST /api/2/auth/{user}/login.json`: Basic → session cookie (a device in the device list).
pub async fn login(State(state): State<AppState>, u: GpodderUser, Path(name): Path<String>) -> ApiResult<Response> {
    same_user(&u, &name)?;
    let token = auth::random_token();
    let th = auth::token_hash(&token);
    with_db(&state.db, move |c| {
        c.execute(
            "INSERT INTO session (user_id, token_hash, device, expires_at)
             VALUES (?1, ?2, 'gpodder', strftime('%Y-%m-%dT%H:%M:%SZ', 'now', ?3))",
            (u.id, th, format!("+{} days", auth::SESSION_DAYS)),
        )?;
        Ok(())
    })
    .await?;
    let cookie = format!("{COOKIE}={token}; HttpOnly; Secure; SameSite=Lax; Path=/; Max-Age={}", auth::SESSION_DAYS * 86400);
    let mut res = StatusCode::OK.into_response();
    res.headers_mut().insert(header::SET_COOKIE, HeaderValue::from_str(&cookie).unwrap());
    Ok(res)
}

/// `POST /api/2/auth/{user}/logout.json`.
pub async fn logout(State(state): State<AppState>, u: GpodderUser, Path(name): Path<String>, parts_cookie: axum::http::HeaderMap) -> ApiResult<StatusCode> {
    same_user(&u, &name)?;
    let token = parts_cookie
        .get_all(header::COOKIE)
        .iter()
        .filter_map(|v| v.to_str().ok())
        .flat_map(|v| v.split(';'))
        .filter_map(|kv| kv.trim().split_once('='))
        .find(|(k, _)| *k == COOKIE)
        .map(|(_, v)| v.to_string());
    if let Some(t) = token {
        let th = auth::token_hash(&t);
        with_db(&state.db, move |c| {
            c.execute("DELETE FROM session WHERE token_hash = ?1", [th])?;
            Ok(())
        })
        .await?;
    }
    Ok(StatusCode::OK)
}

// ---------------------------------------------------------------- devices

pub async fn devices(State(state): State<AppState>, u: GpodderUser, Path(name): Path<String>) -> ApiResult<Json<Value>> {
    same_user(&u, &user_of(&name)?)?;
    with_db(&state.db, move |c| {
        let n: i64 = c.query_row("SELECT COUNT(*) FROM subscription WHERE user_id = ?1", [u.id], |r| r.get(0))?;
        let mut st = c.prepare("SELECT id, caption, type FROM gpodder_device WHERE user_id = ?1 ORDER BY id")?;
        let list: Vec<Value> = st
            .query_map([u.id], |r| Ok(json!({ "id": r.get::<_, String>(0)?, "caption": r.get::<_, String>(1)?, "type": r.get::<_, String>(2)?, "subscriptions": n })))?
            .collect::<Result<_, _>>()?;
        Ok(Json(Value::Array(list)))
    })
    .await
}

#[derive(Deserialize, Default)]
pub struct DeviceUpdate {
    #[serde(default)]
    caption: Option<String>,
    #[serde(default, rename = "type")]
    kind: Option<String>,
}

pub async fn update_device(
    State(state): State<AppState>,
    u: GpodderUser,
    Path((name, device)): Path<(String, String)>,
    Json(d): Json<DeviceUpdate>,
) -> ApiResult<StatusCode> {
    same_user(&u, &name)?;
    let device = device_of(&device)?;
    with_db(&state.db, move |c| {
        ensure_device(c, u.id, &device)?;
        if let Some(cap) = d.caption {
            c.execute("UPDATE gpodder_device SET caption = ?1 WHERE user_id = ?2 AND id = ?3", (cap.chars().take(80).collect::<String>(), u.id, &device))?;
        }
        if let Some(k) = d.kind {
            c.execute("UPDATE gpodder_device SET type = ?1 WHERE user_id = ?2 AND id = ?3", (k.chars().take(20).collect::<String>(), u.id, &device))?;
        }
        Ok(StatusCode::OK)
    })
    .await
}

fn ensure_device(c: &rusqlite::Connection, user: i64, device: &str) -> rusqlite::Result<()> {
    c.execute("INSERT OR IGNORE INTO gpodder_device (user_id, id) VALUES (?1, ?2)", (user, device))?;
    Ok(())
}

// ---------------------------------------------------------------- subscriptions

fn subscribed_urls(c: &rusqlite::Connection, user: i64) -> rusqlite::Result<Vec<String>> {
    let mut st = c.prepare("SELECT p.feed_url FROM subscription s JOIN podcast p ON p.id = s.podcast_id WHERE s.user_id = ?1 ORDER BY p.feed_url")?;
    let urls = st.query_map([user], |r| r.get(0))?.collect();
    urls
}

/// Subscribes and unsubscribes a list of feed URLs; a feed that cannot be fetched is skipped
/// (the client keeps it; nothing to rewrite, so `update_urls` stays empty).
async fn apply_changes(state: &AppState, user: i64, add: &[String], remove: &[String]) -> ApiResult<()> {
    for url in add.iter().filter(|u| valid_url(u)) {
        if let Err(e) = podcasts::subscribe_url(state, user, url).await {
            tracing::warn!("gpodder: cannot subscribe {url}: {e:?}");
        }
    }
    let remove: Vec<String> = remove.iter().filter(|u| valid_url(u)).cloned().collect();
    with_db(&state.db, move |c| {
        for url in remove {
            if let Some(id) = c.query_row("SELECT id FROM podcast WHERE feed_url = ?1", [&url], |r| r.get::<_, i64>(0)).optional()? {
                podcasts::unsubscribe_in(c, user, id)?;
            }
        }
        Ok(())
    })
    .await
}

#[derive(Deserialize, Default)]
pub struct Since {
    #[serde(default)]
    since: i64,
    #[serde(default)]
    podcast: Option<String>,
    #[serde(default)]
    device: Option<String>,
}

/// axum allows one parameter per path segment, so `{user}.json` is matched as `{user}` and the
/// suffix is checked here. Only `.json` is offered (`.opml`/`.txt` are not).
fn user_of(path: &str) -> ApiResult<String> {
    path.strip_suffix(".json").map(str::to_string).ok_or(ApiError::NotFound)
}

/// Strips `.json` (the only format offered; `.opml`/`.txt` are not).
fn device_of(path: &str) -> ApiResult<String> {
    let d = path.strip_suffix(".json").ok_or(ApiError::NotFound)?;
    if !valid_device(d) {
        return Err(ApiError::BadRequest("invalid device id".into()));
    }
    Ok(d.to_string())
}

/// `GET /subscriptions/{user}/{device}.json`: all feed URLs.
pub async fn simple_get(State(state): State<AppState>, u: GpodderUser, Path((name, device)): Path<(String, String)>) -> ApiResult<Json<Value>> {
    same_user(&u, &name)?;
    let device = device_of(&device)?;
    with_db(&state.db, move |c| {
        ensure_device(c, u.id, &device)?;
        Ok(Json(json!(subscribed_urls(c, u.id)?)))
    })
    .await
}

/// `PUT /subscriptions/{user}/{device}.json` with a list of URLs: becomes the whole list.
pub async fn simple_put(State(state): State<AppState>, u: GpodderUser, Path((name, device)): Path<(String, String)>, Json(urls): Json<Vec<String>>) -> ApiResult<StatusCode> {
    same_user(&u, &name)?;
    let device = device_of(&device)?;
    let have = with_db(&state.db, move |c| {
        ensure_device(c, u.id, &device)?;
        Ok(subscribed_urls(c, u.id)?)
    })
    .await?;
    let add: Vec<String> = urls.iter().filter(|x| !have.contains(x)).cloned().collect();
    let remove: Vec<String> = have.iter().filter(|x| !urls.contains(x)).cloned().collect();
    apply_changes(&state, u.id, &add, &remove).await?;
    Ok(StatusCode::OK)
}

/// `GET /api/2/subscriptions/{user}/{device}.json?since=`: changes since then.
pub async fn changes(State(state): State<AppState>, u: GpodderUser, Path((name, device)): Path<(String, String)>, Query(q): Query<Since>) -> ApiResult<Json<Value>> {
    same_user(&u, &name)?;
    let device = device_of(&device)?;
    let since = q.since;
    with_db(&state.db, move |c| {
        ensure_device(c, u.id, &device)?;
        let ts = now();
        if since <= 0 {
            return Ok(Json(json!({ "add": subscribed_urls(c, u.id)?, "remove": [], "timestamp": ts })));
        }
        // The last change per URL since then decides.
        let mut st = c.prepare("SELECT url, added FROM gpodder_sub_change WHERE user_id = ?1 AND at > ?2 ORDER BY at")?;
        let mut last: std::collections::BTreeMap<String, bool> = Default::default();
        for row in st.query_map((u.id, since), |r| Ok((r.get::<_, String>(0)?, r.get::<_, bool>(1)?)))? {
            let (url, added) = row?;
            last.insert(url, added);
        }
        let add: Vec<&String> = last.iter().filter(|(_, a)| **a).map(|(u, _)| u).collect();
        let remove: Vec<&String> = last.iter().filter(|(_, a)| !**a).map(|(u, _)| u).collect();
        Ok(Json(json!({ "add": add, "remove": remove, "timestamp": ts })))
    })
    .await
}

#[derive(Deserialize, Default)]
pub struct Changes {
    #[serde(default)]
    add: Vec<String>,
    #[serde(default)]
    remove: Vec<String>,
}

/// `POST /api/2/subscriptions/{user}/{device}.json` `{add, remove}`.
pub async fn upload_changes(State(state): State<AppState>, u: GpodderUser, Path((name, device)): Path<(String, String)>, Json(ch): Json<Changes>) -> ApiResult<Json<Value>> {
    same_user(&u, &name)?;
    let device = device_of(&device)?;
    with_db(&state.db, move |c| Ok(ensure_device(c, u.id, &device)?)).await?;
    apply_changes(&state, u.id, &ch.add, &ch.remove).await?;
    Ok(Json(json!({ "timestamp": now(), "update_urls": [] })))
}

// ---------------------------------------------------------------- episode actions

#[derive(Deserialize)]
pub struct Action {
    podcast: String,
    episode: String,
    #[serde(default)]
    device: Option<String>,
    action: String,
    #[serde(default)]
    timestamp: Option<String>,
    #[serde(default)]
    started: Option<i64>,
    #[serde(default)]
    position: Option<i64>,
    #[serde(default)]
    total: Option<i64>,
}

/// `POST /api/2/episodes/{user}.json`: play positions go into audiojoe's playback (and so into
/// "Continue" on every device), the other actions are kept for the other clients.
pub async fn upload_actions(State(state): State<AppState>, u: GpodderUser, Path(name): Path<String>, Json(actions): Json<Vec<Action>>) -> ApiResult<Json<Value>> {
    same_user(&u, &user_of(&name)?)?;
    if actions.len() > 5000 {
        return Err(ApiError::BadRequest("max. 5000 actions".into()));
    }
    for a in &actions {
        if !valid_url(&a.podcast) || !valid_url(&a.episode) {
            continue;
        }
        let device = a.device.clone().filter(|d| valid_device(d)).unwrap_or_default();
        let when = a.timestamp.as_deref().map(parse_client_time).unwrap_or_else(Utc::now);
        if a.action == "play" {
            let Some(pos) = a.position else { continue };
            let (podcast, episode) = (a.podcast.clone(), a.episode.clone());
            let found = with_db(&state.db, move |c| {
                Ok(c.query_row(
                    "SELECT e.id, e.title, p.title, e.duration_s FROM episode e JOIN podcast p ON p.id = e.podcast_id
                     JOIN subscription s ON s.podcast_id = p.id AND s.user_id = ?1 WHERE p.feed_url = ?2 AND e.url = ?3",
                    (u.id, &podcast, &episode),
                    |r| Ok((r.get::<_, i64>(0)?, r.get::<_, String>(1)?, r.get::<_, String>(2)?, r.get::<_, Option<i64>>(3)?)),
                )
                .optional()?)
            })
            .await?;
            let Some((id, title, podcast_title, duration_s)) = found else { continue };
            let total = a.total.filter(|t| *t > 0).or(duration_s);
            // gpodder has no "played" flag: at the end (last 10 s) the episode counts as heard.
            let finished = total.is_some_and(|t| pos >= t - 10);
            playback::apply_external(&state, u.id, &format!("gpodder {device}").trim().to_string(), &format!("episode:{id}"), playback::External {
                position_ms: if finished { 0 } else { pos * 1000 },
                duration_ms: total.map(|t| t * 1000),
                finished,
                updated_at: when,
                title,
                subtitle: podcast_title,
            })
            .await?;
        } else if matches!(a.action.as_str(), "download" | "delete" | "new" | "flattr") {
            let (podcast, episode, action) = (a.podcast.clone(), a.episode.clone(), a.action.clone());
            let ts = when.format("%Y-%m-%dT%H:%M:%S").to_string();
            with_db(&state.db, move |c| {
                c.execute(
                    "INSERT INTO gpodder_action (user_id, podcast, episode, device, action, timestamp, at) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7)",
                    (u.id, podcast, episode, device, action, ts, now()),
                )?;
                Ok(())
            })
            .await?;
        }
    }
    Ok(Json(json!({ "timestamp": now(), "update_urls": [] })))
}

/// `GET /api/2/episodes/{user}.json?since=&podcast=&device=`: play positions from audiojoe's
/// playback (whoever set them) plus the stored actions.
pub async fn actions(State(state): State<AppState>, u: GpodderUser, Path(name): Path<String>, Query(q): Query<Since>) -> ApiResult<Json<Value>> {
    same_user(&u, &user_of(&name)?)?;
    with_db(&state.db, move |c| Ok(Json(actions_since(c, u.id, q.since, q.podcast.as_deref(), q.device.as_deref())?))).await
}

fn actions_since(c: &rusqlite::Connection, user: i64, since: i64, podcast: Option<&str>, device: Option<&str>) -> rusqlite::Result<Value> {
    let mut out = Vec::new();
    let mut st = c.prepare(
        "SELECT p.feed_url, e.url, pb.position_ms, pb.duration_ms, e.duration_s, pb.finished, pb.updated_at, pb.device
         FROM playback pb JOIN episode e ON pb.item_key = 'episode:' || e.id JOIN podcast p ON p.id = e.podcast_id
         WHERE pb.user_id = ?1 AND CAST(strftime('%s', pb.updated_at) AS INTEGER) > ?2 ORDER BY pb.updated_at",
    )?;
    for row in st.query_map((user, since), |r| {
        Ok((r.get::<_, String>(0)?, r.get::<_, String>(1)?, r.get::<_, i64>(2)?, r.get::<_, Option<i64>>(3)?, r.get::<_, Option<i64>>(4)?,
            r.get::<_, bool>(5)?, r.get::<_, String>(6)?, r.get::<_, String>(7)?))
    })? {
        let (feed, url, pos_ms, dur_ms, dur_s, finished, updated, dev) = row?;
        let total = dur_ms.map(|d| d / 1000).or(dur_s);
        let position = if finished { total.unwrap_or(pos_ms / 1000) } else { pos_ms / 1000 };
        let dev = dev.strip_prefix("gpodder ").map(str::to_string).unwrap_or_else(|| "audiojoe".to_string());
        let dev: String = dev.chars().filter(|c| c.is_ascii_alphanumeric() || "-_.".contains(*c)).take(64).collect();
        if podcast.is_some_and(|p| p != feed) || device.is_some_and(|d| d != dev) {
            continue;
        }
        out.push(json!({ "podcast": feed, "episode": url, "device": dev, "action": "play",
            "timestamp": updated.trim_end_matches('Z').split('.').next().unwrap_or(""),
            "started": 0, "position": position, "total": total }));
    }
    let mut st = c.prepare("SELECT podcast, episode, device, action, timestamp FROM gpodder_action WHERE user_id = ?1 AND at > ?2 ORDER BY at")?;
    for row in st.query_map((user, since), |r| {
        Ok((r.get::<_, String>(0)?, r.get::<_, String>(1)?, r.get::<_, String>(2)?, r.get::<_, String>(3)?, r.get::<_, String>(4)?))
    })? {
        let (feed, url, dev, action, ts) = row?;
        if podcast.is_some_and(|p| p != feed) || device.is_some_and(|d| d != dev) {
            continue;
        }
        out.push(json!({ "podcast": feed, "episode": url, "device": dev, "action": action, "timestamp": ts }));
    }
    Ok(json!({ "actions": out, "timestamp": now() }))
}

/// Logs a subscription change (called from podcasts when a subscription is added or removed).
pub fn log_change(c: &rusqlite::Connection, user: i64, url: &str, added: bool) -> rusqlite::Result<()> {
    c.execute("INSERT INTO gpodder_sub_change (user_id, url, added, at) VALUES (?1, ?2, ?3, ?4)", (user, url, added, now()))?;
    Ok(())
}

pub fn router() -> Router<AppState> {
    Router::new()
        .route("/api/2/auth/{user}/login.json", post(login))
        .route("/api/2/auth/{user}/logout.json", post(logout))
        // `{user}.json` cannot be a route (one parameter per segment): the suffix is checked in
        // the handlers (user_of, device_of).
        .route("/api/2/devices/{user}", get(devices))
        .route("/api/2/devices/{user}/{device}", post(update_device))
        .route("/subscriptions/{user}/{device}", get(simple_get).put(simple_put))
        .route("/api/2/subscriptions/{user}/{device}", get(changes).post(upload_changes))
        .route("/api/2/episodes/{user}", post(upload_actions).get(actions))
        // Clients upload hundreds of actions at once.
        .layer(axum::extract::DefaultBodyLimit::max(4 * 1024 * 1024))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn db() -> rusqlite::Connection {
        let c = crate::db::open_memory().unwrap();
        c.execute("INSERT INTO user (id, name, password_hash, totp_secret) VALUES (1, 'anna', 'x', 'y')", []).unwrap();
        c.execute("INSERT INTO podcast (id, feed_url, title) VALUES (7, 'https://p.example/feed', 'Pod')", []).unwrap();
        c.execute("INSERT INTO subscription (user_id, podcast_id) VALUES (1, 7)", []).unwrap();
        c.execute("INSERT INTO episode (id, podcast_id, guid, title, url, duration_s) VALUES (70, 7, 'g1', 'Ep 1', 'https://p.example/ep1.mp3', 3600)", []).unwrap();
        c
    }

    #[test]
    fn play_positions_become_actions_and_changes_are_logged() {
        let c = db();
        c.execute(
            "INSERT INTO playback (user_id, item_key, position_ms, duration_ms, finished, title, device, updated_at)
             VALUES (1, 'episode:70', 125000, 3600000, 0, 'Ep 1', 'Tesla', '2026-11-01T10:00:00.000Z')",
            [],
        )
        .unwrap();
        let v = actions_since(&c, 1, 0, None, None).unwrap();
        let a = &v["actions"][0];
        assert_eq!(a["action"], "play");
        assert_eq!(a["episode"], "https://p.example/ep1.mp3");
        assert_eq!(a["position"], 125);
        assert_eq!(a["total"], 3600);
        assert_eq!(a["device"], "audiojoe");
        assert_eq!(a["timestamp"], "2026-11-01T10:00:00");
        // since after the change: nothing
        assert!(actions_since(&c, 1, unix_of("2026-11-01T10:00:01Z"), None, None).unwrap()["actions"].as_array().unwrap().is_empty());
        // another podcast filter: nothing
        assert!(actions_since(&c, 1, 0, Some("https://other/feed"), None).unwrap()["actions"].as_array().unwrap().is_empty());
        // finished episodes report the total as position
        c.execute("UPDATE playback SET finished = 1, position_ms = 0 WHERE item_key = 'episode:70'", []).unwrap();
        assert_eq!(actions_since(&c, 1, 0, None, None).unwrap()["actions"][0]["position"], 3600);

        log_change(&c, 1, "https://p.example/feed", true).unwrap();
        log_change(&c, 1, "https://gone.example/feed", false).unwrap();
        let n: i64 = c.query_row("SELECT COUNT(*) FROM gpodder_sub_change WHERE user_id = 1", [], |r| r.get(0)).unwrap();
        assert_eq!(n, 2);
    }

    #[test]
    fn device_ids_lose_their_json_suffix() {
        assert_eq!(device_of("antennapod_on_x86_64.json").unwrap(), "antennapod_on_x86_64");
        assert!(device_of("antennapod_on_x86_64").is_err());
        assert_eq!(user_of("anna.json").unwrap(), "anna");
    }

    #[test]
    fn routes_are_valid() {
        // axum checks route syntax when the router is built (it panicked on `{user}.json` once).
        let _ = router();
    }

    #[test]
    fn client_times_and_ids() {
        assert_eq!(parse_client_time("2009-12-12T09:00:00").timestamp(), 1260608400);
        assert_eq!(parse_client_time("2009-12-12T09:00:00Z").timestamp(), 1260608400);
        assert!(valid_device("antennapod-pixel_7.local"));
        assert!(!valid_device("bad id"));
        assert_eq!(device_of("phone.json").unwrap(), "phone");
        assert!(device_of("phone.opml").is_err());
    }
}
