//! Audiobookshelf as a source: libraries, books (one or more audio files = parts),
//! chapters, streams, covers – and the listening progress, synced in both directions
//! with the user who added the source: Audiobookshelf's apps stay usable.
//!
//! Item key: `abs:<source>:<library item id>`; the position is the position in the whole
//! book. Sync: on every change here (push), on opening an item (pull) and every 5 minutes
//! (both directions). The newer state wins; equal content is never written back, so the
//! two sides do not ping-pong.

use std::time::Duration;

use axum::{http::header, response::Response};
use chrono::{DateTime, TimeZone, Utc};
use rusqlite::OptionalExtension;
use serde_json::{json, Value};

use crate::{
    error::{with_db, ApiError, ApiResult},
    playback,
    sources::Browse,
    AppState,
};

const SYNC_EVERY: Duration = Duration::from_secs(5 * 60);
pub const DEVICE: &str = "Audiobookshelf";

#[derive(Clone)]
pub struct Abs {
    pub source_id: i64,
    pub base: String,
    key: String,
    pub owner: Option<i64>,
}

pub fn valid_id(id: &str) -> bool {
    !id.is_empty() && id.len() <= 64 && id.chars().all(|c| c.is_ascii_alphanumeric() || c == '-' || c == '_')
}

impl Abs {
    pub fn auth_header(&self) -> String {
        format!("Bearer {}", self.key)
    }

    async fn get(&self, http: &reqwest::Client, path: &str, query: &[(&str, String)]) -> ApiResult<Value> {
        let res = http
            .get(format!("{}{path}", self.base))
            .query(query)
            .header(header::AUTHORIZATION, self.auth_header())
            .timeout(Duration::from_secs(20))
            .send()
            .await
            .map_err(|e| ApiError::BadGateway(format!("audiobookshelf unreachable: {}", e.without_url())))?;
        match res.status() {
            s if s == reqwest::StatusCode::NOT_FOUND => Err(ApiError::NotFound),
            s if s == reqwest::StatusCode::UNAUTHORIZED || s == reqwest::StatusCode::FORBIDDEN => {
                Err(ApiError::BadRequest(format!("audiobookshelf rejected the API key ({s})")))
            }
            s if !s.is_success() => Err(ApiError::BadGateway(format!("audiobookshelf answered {s}"))),
            _ => res.json().await.map_err(|e| ApiError::BadGateway(format!("audiobookshelf: invalid response: {e}"))),
        }
    }

    async fn patch_progress(&self, http: &reqwest::Client, item: &str, body: Value) -> ApiResult<()> {
        let res = http
            .patch(format!("{}/api/me/progress/{item}", self.base))
            .header(header::AUTHORIZATION, self.auth_header())
            .json(&body)
            .timeout(Duration::from_secs(20))
            .send()
            .await
            .map_err(|e| ApiError::BadGateway(format!("audiobookshelf unreachable: {}", e.without_url())))?;
        if !res.status().is_success() {
            return Err(ApiError::BadGateway(format!("audiobookshelf answered {}", res.status())));
        }
        Ok(())
    }
}

pub async fn source(state: &AppState, id: i64) -> ApiResult<Abs> {
    with_db(&state.db, move |c| {
        Ok(c.query_row(
            "SELECT url, secret, owner_user_id FROM source WHERE id = ?1 AND kind = 'audiobookshelf'",
            [id],
            |r| Ok(Abs { source_id: id, base: r.get(0)?, key: r.get(1)?, owner: r.get(2)? }),
        )?)
    })
    .await
}

/// Checks URL and key; returns the Audiobookshelf user and version.
pub async fn check(state: &AppState, url: &str, key: &str) -> ApiResult<Value> {
    let abs = Abs { source_id: 0, base: url.to_string(), key: key.to_string(), owner: None };
    let me = abs.get(&state.http, "/api/me", &[]).await?;
    let status = abs.get(&state.http, "/status", &[]).await.unwrap_or(Value::Null);
    Ok(json!({ "server": format!("Audiobookshelf ({})", me["username"].as_str().unwrap_or("?")), "version": status["serverVersion"] }))
}

fn book_json(src: i64, v: &Value) -> Value {
    let id = v["id"].as_str().unwrap_or_default();
    let meta = &v["media"]["metadata"];
    json!({
        "key": format!("abs:{src}:{id}"),
        "kind": "book",
        "title": meta["title"].as_str().unwrap_or(""),
        "subtitle": meta["authorName"].as_str().unwrap_or(""),
        "year": meta["publishedYear"].as_str().and_then(|y| y.parse::<i64>().ok()),
        "duration_ms": v["media"]["duration"].as_f64().map(|d| (d * 1000.0) as i64),
        "image": format!("/api/v1/image/abs:{src}:{id}"),
        "quality": Value::Null,
    })
}

pub async fn browse(state: &AppState, src: i64, q: &Browse) -> ApiResult<Value> {
    let abs = source(state, src).await?;
    let Some(lib) = q.parent.clone() else {
        // Top level: the book libraries.
        let libs = abs.get(&state.http, "/api/libraries", &[]).await?;
        let items: Vec<Value> = libs["libraries"]
            .as_array()
            .map(|a| {
                a.iter()
                    .filter(|l| l["mediaType"] == "book")
                    .map(|l| json!({ "key": format!("abs:{src}:{}", l["id"].as_str().unwrap_or("")), "kind": "folder",
                                     "title": l["name"], "subtitle": "", "image": null, "quality": null }))
                    .collect()
            })
            .unwrap_or_default();
        return Ok(json!({ "items": items, "total": items.len() }));
    };
    if !valid_id(&lib) {
        return Err(ApiError::BadRequest("invalid parent".into()));
    }
    let limit = q.limit.unwrap_or(100).clamp(1, 500);
    let page = q.start.unwrap_or(0) / limit;
    let mut query = vec![
        ("limit", limit.to_string()),
        ("page", page.to_string()),
        ("sort", "media.metadata.title".to_string()),
        ("minified", "1".to_string()),
    ];
    if let Some(term) = q.search.clone().filter(|s| !s.trim().is_empty()) {
        // Server-side filter on title/author would need the search endpoint; the list is
        // filtered here instead (libraries of a household are small).
        query.retain(|(k, _)| *k != "limit" && *k != "page");
        let res = abs.get(&state.http, &format!("/api/libraries/{lib}/items"), &query).await?;
        let t = term.to_lowercase();
        let items: Vec<Value> = res["results"]
            .as_array()
            .map(|a| a.iter().map(|v| book_json(src, v)).filter(|b| {
                b["title"].as_str().unwrap_or("").to_lowercase().contains(&t) || b["subtitle"].as_str().unwrap_or("").to_lowercase().contains(&t)
            }).collect())
            .unwrap_or_default();
        return Ok(json!({ "items": items, "total": items.len() }));
    }
    let res = abs.get(&state.http, &format!("/api/libraries/{lib}/items"), &query).await?;
    let items: Vec<Value> = res["results"].as_array().map(|a| a.iter().map(|v| book_json(src, v)).collect()).unwrap_or_default();
    Ok(json!({ "items": items, "total": res["total"] }))
}

pub async fn image(state: &AppState, src: i64, item: &str) -> ApiResult<Response> {
    if !valid_id(item) {
        return Err(ApiError::NotFound);
    }
    let abs = source(state, src).await?;
    let req = state
        .http
        .get(format!("{}/api/items/{item}/cover", abs.base))
        .query(&[("width", "400")])
        .header(header::AUTHORIZATION, abs.auth_header());
    crate::sources::relay_image(req).await
}

/// One audio file of a book.
pub struct Part {
    pub url: String,
}

/// Metadata of a book (parts, chapters, quality) and the URLs of its audio files.
pub async fn item(state: &AppState, abs: &Abs, id: &str) -> ApiResult<(Value, Vec<Part>)> {
    if !valid_id(id) {
        return Err(ApiError::NotFound);
    }
    let v = abs.get(&state.http, &format!("/api/items/{id}"), &[("expanded", "1".into())]).await?;
    let media = &v["media"];
    let mut files: Vec<&Value> = media["audioFiles"].as_array().map(|a| a.iter().filter(|f| f["exclude"] != true).collect()).unwrap_or_default();
    files.sort_by_key(|f| f["index"].as_i64().unwrap_or(0));
    let mut parts = Vec::new();
    let mut part_json = Vec::new();
    let mut offset = 0.0;
    for (i, f) in files.iter().enumerate() {
        let ino = f["ino"].as_str().unwrap_or_default();
        let dur = f["duration"].as_f64().unwrap_or(0.0);
        parts.push(Part { url: format!("{}/api/items/{id}/file/{ino}", abs.base) });
        part_json.push(json!({ "index": i, "start_ms": (offset * 1000.0) as i64, "duration_ms": (dur * 1000.0) as i64,
                               "title": f["metadata"]["filename"].as_str().unwrap_or("") }));
        offset += dur;
    }
    let first = files.first().copied().cloned().unwrap_or(Value::Null);
    let chapters: Vec<Value> = media["chapters"]
        .as_array()
        .map(|a| a.iter().map(|c| json!({
            "title": c["title"].as_str().unwrap_or(""),
            "start_ms": (c["start"].as_f64().unwrap_or(0.0) * 1000.0) as i64,
            "end_ms": (c["end"].as_f64().unwrap_or(0.0) * 1000.0) as i64,
        })).collect())
        .unwrap_or_default();
    let meta = &media["metadata"];
    let narrator = meta["narratorName"].as_str().filter(|s| !s.is_empty());
    let author = meta["authorName"].as_str().unwrap_or("");
    let out = json!({
        "key": format!("abs:{}:{id}", abs.source_id),
        "kind": "book",
        "title": meta["title"].as_str().unwrap_or(""),
        "subtitle": match narrator { Some(n) => format!("{author} · {n}"), None => author.to_string() },
        "duration_ms": (media["duration"].as_f64().unwrap_or(offset) * 1000.0) as i64,
        "image": format!("/api/v1/image/abs:{}:{id}", abs.source_id),
        "description": crate::podcasts::plain_text(meta["description"].as_str().unwrap_or("")),
        "notes": crate::notes::html(meta["description"].as_str().unwrap_or("")),
        "published": meta["publishedYear"].as_str(),
        "genres": meta["genres"].as_array().map(|g| g.iter().filter_map(|x| x.as_str()).take(4).collect::<Vec<_>>()).unwrap_or_default(),
        "series": meta["seriesName"].as_str().filter(|s| !s.is_empty()),
        "quality": {
            "codec": first["codec"].as_str().unwrap_or("").to_lowercase(),
            "bitrate": first["bitRate"].as_i64(),
            "channels": first["channels"].as_i64(),
            "sample_rate": null, "bit_depth": null,
        },
        "parts": part_json,
        "chapters": chapters,
    });
    Ok((out, parts))
}

// ---------------------------------------------------------------- progress sync

fn ts(ms: i64) -> DateTime<Utc> {
    Utc.timestamp_millis_opt(ms).single().unwrap_or_else(Utc::now)
}

/// Applies Audiobookshelf's progress for one item to the owner's playback position when
/// it is newer and differs; pushes ours to Audiobookshelf when ours is newer and differs.
async fn reconcile(state: &AppState, abs: &Abs, owner: i64, item: &str, theirs: Option<&Value>) -> ApiResult<()> {
    let key = format!("abs:{}:{item}", abs.source_id);
    let k = key.clone();
    let ours: Option<(i64, Option<i64>, bool, String, String)> = with_db(&state.db, move |c| {
        Ok(c.query_row(
            "SELECT position_ms, duration_ms, finished, updated_at, title FROM playback WHERE user_id = ?1 AND item_key = ?2",
            (owner, &k),
            |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?, r.get(3)?, r.get(4)?)),
        )
        .optional()?)
    })
    .await?;

    let their_pos = theirs.map(|p| (p["currentTime"].as_f64().unwrap_or(0.0) * 1000.0) as i64);
    let their_fin = theirs.map(|p| p["isFinished"].as_bool().unwrap_or(false));
    let their_ts = theirs.and_then(|p| p["lastUpdate"].as_i64()).map(ts);
    let same = |pos: i64, fin: bool| their_pos.is_some_and(|tp| (tp - pos).abs() <= 2000) && their_fin == Some(fin);

    if let (Some((pos, _, fin, _, _)), Some(_)) = (&ours, their_ts) {
        if same(*pos, *fin) {
            return Ok(());
        }
    }
    let theirs_newer = match (&ours, their_ts) {
        (_, None) => false,
        (None, Some(_)) => true,
        (Some(o), Some(tt)) => o.3 < tt.format("%Y-%m-%dT%H:%M:%S%.3fZ").to_string(),
    };
    if theirs_newer {
        // Take theirs over.
        let (title, subtitle) = match &ours {
            Some((.., title)) if !title.is_empty() => (title.clone(), String::new()),
            _ => match abs.get(&state.http, &format!("/api/items/{item}"), &[]).await {
                Ok(v) => (
                    v["media"]["metadata"]["title"].as_str().unwrap_or("").to_string(),
                    v["media"]["metadata"]["authorName"].as_str().unwrap_or("").to_string(),
                ),
                Err(_) => (String::new(), String::new()),
            },
        };
        let p = theirs.unwrap_or(&Value::Null);
        let ext = playback::External {
            position_ms: their_pos.unwrap_or(0),
            duration_ms: p["duration"].as_f64().map(|d| (d * 1000.0) as i64),
            finished: their_fin.unwrap_or(false),
            updated_at: their_ts.unwrap_or_else(Utc::now),
            title,
            subtitle,
        };
        return playback::apply_external(state, owner, DEVICE, &key, ext).await;
    }
    match &ours {
        // Ours is newer: push it.
        Some((pos, dur, fin, _, _)) => {
            let body = json!({ "currentTime": *pos as f64 / 1000.0, "isFinished": fin,
                               "duration": dur.map(|d| d as f64 / 1000.0) });
            abs.patch_progress(&state.http, item, body).await
        }
        None => Ok(()),
    }
}

/// Full sync of one source with its owner.
pub async fn sync_source(state: &AppState, src: i64) {
    let Ok(abs) = source(state, src).await else { return };
    let Some(owner) = abs.owner else { return };
    let me = match abs.get(&state.http, "/api/me", &[]).await {
        Ok(me) => me,
        Err(e) => return tracing::warn!("audiobookshelf source {src}: {e:?}"),
    };
    let theirs: Vec<Value> = me["mediaProgress"]
        .as_array()
        .map(|a| a.iter().filter(|p| p["episodeId"].is_null() && p["libraryItemId"].is_string()).cloned().collect())
        .unwrap_or_default();
    let mut seen = std::collections::HashSet::new();
    for p in &theirs {
        let item = p["libraryItemId"].as_str().unwrap_or_default().to_string();
        seen.insert(item.clone());
        if let Err(e) = reconcile(state, &abs, owner, &item, Some(p)).await {
            tracing::warn!("audiobookshelf sync {item}: {e:?}");
        }
    }
    // Positions that exist only here.
    let prefix = format!("abs:{src}:");
    let ours: Vec<String> = with_db(&state.db, move |c| {
        let mut stmt = c.prepare("SELECT item_key FROM playback WHERE user_id = ?1 AND item_key LIKE ?2 || '%'")?;
        let rows = stmt.query_map((owner, &prefix), |r| r.get::<_, String>(0))?.collect::<Result<Vec<_>, _>>()?;
        Ok(rows)
    })
    .await
    .unwrap_or_default();
    for key in ours {
        let item = key.rsplit(':').next().unwrap_or_default().to_string();
        if !seen.contains(&item) {
            let _ = reconcile(state, &abs, owner, &item, None).await;
        }
    }
}

/// Pull for one item (when it is opened).
pub async fn sync_item(state: &AppState, abs: &Abs, item: &str) {
    let Some(owner) = abs.owner else { return };
    let theirs = abs.get(&state.http, &format!("/api/me/progress/{item}"), &[]).await.ok();
    let _ = reconcile(state, abs, owner, item, theirs.as_ref()).await;
}

/// Push after a change here (called for applied updates of `abs:` keys).
pub fn push_later(state: &AppState, user: i64, key: &str) {
    let mut p = key.splitn(3, ':');
    let (Some("abs"), Some(src), Some(item)) = (p.next(), p.next(), p.next()) else { return };
    let (Ok(src), item, state) = (src.parse::<i64>(), item.to_string(), state.clone()) else { return };
    tokio::spawn(async move {
        let Ok(abs) = source(&state, src).await else { return };
        if abs.owner == Some(user) {
            let theirs = abs.get(&state.http, &format!("/api/me/progress/{item}"), &[]).await.ok();
            if let Err(e) = reconcile(&state, &abs, user, &item, theirs.as_ref()).await {
                tracing::warn!("audiobookshelf push {item}: {e:?}");
            }
        }
    });
}

pub async fn sync_loop(state: AppState) {
    loop {
        tokio::time::sleep(SYNC_EVERY).await;
        let ids = with_db(&state.db, |c| {
            let mut stmt = c.prepare("SELECT id FROM source WHERE kind = 'audiobookshelf'")?;
            let ids = stmt.query_map([], |r| r.get::<_, i64>(0))?.collect::<Result<Vec<_>, _>>()?;
            Ok(ids)
        })
        .await
        .unwrap_or_default();
        for id in ids {
            sync_source(&state, id).await;
        }
    }
}
