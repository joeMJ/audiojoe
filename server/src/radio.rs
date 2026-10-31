//! Internet radio via the Radio Browser directory (radio-browser.info).
//!
//! The server list is fetched from the directory itself (no fixed server), one is picked
//! at random, failing ones are skipped. Stations from searches are cached locally, so
//! playing a favourite needs no directory request. Logos are relayed by the server, so
//! clients never contact third-party sites. Item key: `radio:<stationuuid>`.

use std::{sync::Mutex, time::Duration};

use axum::{
    extract::{Path, Query, State},
    http::header,
    response::Response,
    Json,
};
use rand::seq::SliceRandom;
use serde::Deserialize;
use serde_json::{json, Value};

use crate::{
    auth::CurrentUser,
    error::{with_db, ApiError, ApiResult},
    AppState,
};

const DIRECTORY: &str = "https://all.api.radio-browser.info";

/// Cached list of directory servers.
pub static SERVERS: Mutex<Vec<String>> = Mutex::new(Vec::new());

pub fn valid_uuid(u: &str) -> bool {
    !u.is_empty() && u.len() <= 64 && u.chars().all(|c| c.is_ascii_hexdigit() || c == '-')
}

async fn servers(http: &reqwest::Client) -> Vec<String> {
    {
        let s = SERVERS.lock().unwrap();
        if !s.is_empty() {
            return s.clone();
        }
    }
    let list: Vec<String> = match http.get(format!("{DIRECTORY}/json/servers")).timeout(Duration::from_secs(10)).send().await {
        Ok(r) => r
            .json::<Vec<Value>>()
            .await
            .unwrap_or_default()
            .iter()
            .filter_map(|s| s["name"].as_str().map(|n| format!("https://{n}")))
            .collect(),
        Err(_) => Vec::new(),
    };
    let mut list = if list.is_empty() { vec![DIRECTORY.to_string()] } else { list };
    list.sort();
    list.dedup();
    *SERVERS.lock().unwrap() = list.clone();
    list
}

/// GET on a random directory server, trying the others on failure.
async fn directory(http: &reqwest::Client, path: &str, query: &[(&str, String)]) -> ApiResult<Value> {
    let mut list = servers(http).await;
    list.shuffle(&mut rand::thread_rng());
    let mut last = String::new();
    for base in list.iter().take(3) {
        match http.get(format!("{base}{path}")).query(query).timeout(Duration::from_secs(10)).send().await {
            Ok(r) if r.status().is_success() => {
                return r.json().await.map_err(|e| ApiError::BadGateway(format!("radio directory: {e}")));
            }
            Ok(r) => last = format!("{}", r.status()),
            Err(e) => last = e.without_url().to_string(),
        }
    }
    SERVERS.lock().unwrap().clear();
    Err(ApiError::BadGateway(format!("radio directory unreachable: {last}")))
}

fn station_json(r: &rusqlite::Row) -> rusqlite::Result<Value> {
    let uuid: String = r.get("uuid")?;
    let favicon: String = r.get("favicon")?;
    let country: String = r.get("country")?;
    let tags: String = r.get("tags")?;
    let tags = tags.split(',').map(str::trim).filter(|t| !t.is_empty()).take(3).collect::<Vec<_>>().join(", ");
    let subtitle = [country.as_str(), tags.as_str()].iter().filter(|s| !s.is_empty()).cloned().collect::<Vec<_>>().join(" · ");
    Ok(json!({
        "key": format!("radio:{uuid}"),
        "kind": "radio",
        "title": r.get::<_, String>("name")?,
        "subtitle": subtitle,
        "image": if favicon.is_empty() { Value::Null } else { json!(format!("/api/v1/image/radio:{uuid}")) },
        "quality": { "codec": r.get::<_, String>("codec")?.to_lowercase(), "bitrate": r.get::<_, Option<i64>>("bitrate")?.map(|b| b * 1000),
                     "sample_rate": null, "bit_depth": null, "channels": null },
        "favorite": r.get::<_, Option<bool>>("favorite")?.unwrap_or(false),
    }))
}

fn store(c: &rusqlite::Connection, s: &Value) -> rusqlite::Result<Option<String>> {
    let uuid = s["stationuuid"].as_str().unwrap_or_default();
    let url = s["url_resolved"].as_str().filter(|u| u.starts_with("http")).or_else(|| s["url"].as_str()).unwrap_or_default();
    if !valid_uuid(uuid) || !url.starts_with("http") {
        return Ok(None);
    }
    c.execute(
        "INSERT INTO radio_station (uuid, name, url, codec, bitrate, favicon, country, tags) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8)
         ON CONFLICT (uuid) DO UPDATE SET name = excluded.name, url = excluded.url, codec = excluded.codec, bitrate = excluded.bitrate,
           favicon = excluded.favicon, country = excluded.country, tags = excluded.tags, updated_at = strftime('%Y-%m-%dT%H:%M:%SZ', 'now')",
        (uuid, s["name"].as_str().unwrap_or("").trim(), url, s["codec"].as_str().unwrap_or(""), s["bitrate"].as_i64().filter(|b| *b > 0),
         s["favicon"].as_str().filter(|f| f.starts_with("http")).unwrap_or(""), s["country"].as_str().unwrap_or(""), s["tags"].as_str().unwrap_or("")),
    )?;
    Ok(Some(uuid.to_string()))
}

const STATION_SELECT: &str = "SELECT s.*, f.uuid IS NOT NULL AS favorite FROM radio_station s
     LEFT JOIN radio_favorite f ON f.uuid = s.uuid AND f.user_id = ?1";

#[derive(Deserialize)]
pub struct SearchQuery {
    q: String,
}

pub async fn search(State(state): State<AppState>, user: CurrentUser, Query(q): Query<SearchQuery>) -> ApiResult<Json<Value>> {
    let term = q.q.trim().to_string();
    if term.is_empty() || term.len() > 100 {
        return Err(ApiError::BadRequest("query required".into()));
    }
    let res = directory(&state.http, "/json/stations/search", &[
        ("name", term),
        ("hidebroken", "true".into()),
        ("order", "clickcount".into()),
        ("reverse", "true".into()),
        ("limit", "40".into()),
    ])
    .await?;
    with_db(&state.db, move |c| {
        let mut uuids = Vec::new();
        for s in res.as_array().cloned().unwrap_or_default() {
            if let Some(u) = store(c, &s)? {
                uuids.push(u);
            }
        }
        let mut out = Vec::new();
        for u in uuids {
            out.push(c.query_row(&format!("{STATION_SELECT} WHERE s.uuid = ?2"), (user.id, &u), station_json)?);
        }
        Ok(Json(Value::Array(out)))
    })
    .await
}

pub async fn favorites(State(state): State<AppState>, user: CurrentUser) -> ApiResult<Json<Value>> {
    with_db(&state.db, move |c| {
        let mut stmt = c.prepare(&format!("{STATION_SELECT} WHERE f.uuid IS NOT NULL ORDER BY f.position, s.name COLLATE NOCASE"))?;
        let rows = stmt.query_map([user.id], station_json)?.collect::<Result<Vec<_>, _>>()?;
        Ok(Json(Value::Array(rows)))
    })
    .await
}

pub async fn add_favorite(State(state): State<AppState>, user: CurrentUser, Path(uuid): Path<String>) -> ApiResult<Json<Value>> {
    if !valid_uuid(&uuid) {
        return Err(ApiError::NotFound);
    }
    with_db(&state.db, move |c| {
        if c.execute("INSERT OR IGNORE INTO radio_favorite (user_id, uuid, position)
             SELECT ?1, uuid, (SELECT COALESCE(MAX(position), 0) + 1 FROM radio_favorite WHERE user_id = ?1) FROM radio_station WHERE uuid = ?2", (user.id, &uuid))? == 0
            && c.query_row("SELECT 1 FROM radio_favorite WHERE user_id = ?1 AND uuid = ?2", (user.id, &uuid), |_| Ok(())).is_err()
        {
            return Err(ApiError::NotFound);
        }
        Ok(Json(json!({ "ok": true })))
    })
    .await
}

pub async fn remove_favorite(State(state): State<AppState>, user: CurrentUser, Path(uuid): Path<String>) -> ApiResult<Json<Value>> {
    with_db(&state.db, move |c| {
        c.execute("DELETE FROM radio_favorite WHERE user_id = ?1 AND uuid = ?2", (user.id, &uuid))?;
        Ok(Json(json!({ "ok": true })))
    })
    .await
}

/// Stream URL and metadata of a station; counts the click in the directory (as asked by
/// Radio Browser) without waiting for it.
pub async fn resolve(state: &AppState, user: i64, uuid: &str) -> ApiResult<(String, Value)> {
    if !valid_uuid(uuid) {
        return Err(ApiError::NotFound);
    }
    let u = uuid.to_string();
    let (url, meta) = with_db(&state.db, move |c| {
        let url: String = c.query_row("SELECT url FROM radio_station WHERE uuid = ?1", [&u], |r| r.get(0))?;
        let meta = c.query_row(&format!("{STATION_SELECT} WHERE s.uuid = ?2"), (user, &u), station_json)?;
        Ok((url, meta))
    })
    .await?;
    let (http, u) = (state.http.clone(), uuid.to_string());
    tokio::spawn(async move {
        let _ = directory(&http, &format!("/json/url/{u}"), &[]).await;
    });
    Ok((url, meta))
}

pub async fn image(state: &AppState, uuid: &str) -> ApiResult<Response> {
    if !valid_uuid(uuid) {
        return Err(ApiError::NotFound);
    }
    let u = uuid.to_string();
    let favicon: String = with_db(&state.db, move |c| Ok(c.query_row("SELECT favicon FROM radio_station WHERE uuid = ?1", [&u], |r| r.get(0))?)).await?;
    if favicon.is_empty() {
        return Err(ApiError::NotFound);
    }
    let res = crate::sources::relay_image(state.http.get(favicon).timeout(Duration::from_secs(10))).await?;
    // Only images; a station's "favicon" may point to anything.
    let ok = res.headers().get(header::CONTENT_TYPE).and_then(|v| v.to_str().ok()).is_some_and(|t| t.starts_with("image/"));
    if ok { Ok(res) } else { Err(ApiError::NotFound) }
}

/// The favourites in the user's order (uuids); applies on all devices.
pub async fn order_favorites(State(state): State<AppState>, user: CurrentUser, Json(uuids): Json<Vec<String>>) -> ApiResult<Json<Value>> {
    if uuids.len() > 1000 {
        return Err(ApiError::BadRequest("too many".into()));
    }
    with_db(&state.db, move |c| {
        let tx = c.transaction()?;
        tx.execute("UPDATE radio_favorite SET position = position + 100000 WHERE user_id = ?1", [user.id])?;
        for (i, u) in uuids.iter().enumerate() {
            tx.execute("UPDATE radio_favorite SET position = ?3 WHERE user_id = ?1 AND uuid = ?2", (user.id, u, i as f64))?;
        }
        tx.commit()?;
        Ok(Json(json!({ "ok": true })))
    })
    .await
}
