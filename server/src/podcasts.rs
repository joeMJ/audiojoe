//! Podcast subscriptions: RSS feeds are fetched by the server (conditional requests),
//! episodes are stored as metadata only; the audio is relayed on demand.

use std::time::Duration;

use axum::{
    extract::{Path, Query, State},
    Json,
};
use futures_util::StreamExt;
use reqwest::header;
use rusqlite::OptionalExtension;
use serde::Deserialize;
use serde_json::{json, Value};

use crate::{
    auth::CurrentUser,
    error::{with_db, ApiError, ApiResult},
    AppState,
};

const MAX_FEED_BYTES: usize = 64 * 1024 * 1024;
const REFRESH_EVERY: Duration = Duration::from_secs(60 * 60);

struct Episode {
    guid: String,
    title: String,
    published: Option<String>,
    duration_s: Option<i64>,
    url: String,
    mime: String,
    size: Option<i64>,
}

struct Feed {
    title: String,
    author: String,
    image_url: String,
    episodes: Vec<Episode>,
}

/// `HH:MM:SS`, `MM:SS` or plain seconds.
fn parse_duration(s: &str) -> Option<i64> {
    let parts: Vec<&str> = s.trim().split(':').collect();
    let nums: Option<Vec<i64>> = parts.iter().map(|p| p.trim().parse::<f64>().ok().map(|f| f as i64)).collect();
    let nums = nums?;
    Some(nums.iter().fold(0, |acc, n| acc * 60 + n)).filter(|&d| d > 0)
}

fn parse_feed(bytes: &[u8]) -> anyhow::Result<Feed> {
    let ch = rss::Channel::read_from(bytes)?;
    let itunes = ch.itunes_ext();
    let episodes = ch
        .items()
        .iter()
        .filter_map(|it| {
            let enc = it.enclosure()?;
            let url = enc.url().trim().to_string();
            if !(url.starts_with("https://") || url.starts_with("http://")) {
                return None;
            }
            Some(Episode {
                guid: it.guid().map(|g| g.value().to_string()).unwrap_or_else(|| url.clone()),
                title: it.title().unwrap_or("").trim().to_string(),
                published: it
                    .pub_date()
                    .and_then(|d| chrono::DateTime::parse_from_rfc2822(d.trim()).ok())
                    .map(|d| d.with_timezone(&chrono::Utc).format("%Y-%m-%dT%H:%M:%SZ").to_string()),
                duration_s: it.itunes_ext().and_then(|i| i.duration()).and_then(parse_duration),
                mime: enc.mime_type().to_string(),
                size: enc.length().parse().ok().filter(|&n: &i64| n > 0),
                url,
            })
        })
        .collect();
    Ok(Feed {
        title: ch.title().trim().to_string(),
        author: itunes.and_then(|i| i.author()).unwrap_or("").to_string(),
        image_url: itunes
            .and_then(|i| i.image())
            .map(str::to_string)
            .or_else(|| ch.image().map(|i| i.url().to_string()))
            .unwrap_or_default(),
        episodes,
    })
}

/// Fetches a feed. Returns None when unchanged (304).
async fn fetch(
    http: &reqwest::Client,
    url: &str,
    etag: Option<&str>,
    last_modified: Option<&str>,
) -> anyhow::Result<Option<(Feed, Option<String>, Option<String>)>> {
    let mut req = http.get(url).timeout(Duration::from_secs(60));
    if let Some(e) = etag {
        req = req.header(header::IF_NONE_MATCH, e);
    }
    if let Some(l) = last_modified {
        req = req.header(header::IF_MODIFIED_SINCE, l);
    }
    let res = req.send().await?;
    if res.status() == reqwest::StatusCode::NOT_MODIFIED {
        return Ok(None);
    }
    let res = res.error_for_status()?;
    let h = |n| res.headers().get(n).and_then(|v: &header::HeaderValue| v.to_str().ok()).map(str::to_string);
    let (etag, lm) = (h(header::ETAG), h(header::LAST_MODIFIED));
    let mut body = Vec::new();
    let mut stream = res.bytes_stream();
    while let Some(chunk) = stream.next().await {
        body.extend_from_slice(&chunk?);
        anyhow::ensure!(body.len() <= MAX_FEED_BYTES, "feed larger than {MAX_FEED_BYTES} bytes");
    }
    let feed = tokio::task::spawn_blocking(move || parse_feed(&body)).await??;
    Ok(Some((feed, etag, lm)))
}

fn store(c: &mut rusqlite::Connection, podcast_id: i64, feed: &Feed, etag: Option<String>, lm: Option<String>) -> rusqlite::Result<usize> {
    let tx = c.transaction()?;
    tx.execute(
        "UPDATE podcast SET title = ?2, author = ?3, image_url = ?4, etag = ?5, last_modified = ?6,
         last_fetch = strftime('%Y-%m-%dT%H:%M:%SZ', 'now'), last_error = NULL WHERE id = ?1",
        (podcast_id, &feed.title, &feed.author, &feed.image_url, etag, lm),
    )?;
    let mut n = 0;
    {
        let mut stmt = tx.prepare(
            "INSERT INTO episode (podcast_id, guid, title, published, duration_s, url, mime, size)
             VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8)
             ON CONFLICT (podcast_id, guid) DO UPDATE SET title = excluded.title, published = excluded.published,
               duration_s = excluded.duration_s, url = excluded.url, mime = excluded.mime, size = excluded.size",
        )?;
        for e in &feed.episodes {
            n += stmt.execute((podcast_id, &e.guid, &e.title, &e.published, e.duration_s, &e.url, &e.mime, e.size))?;
        }
    }
    tx.commit()?;
    Ok(n)
}

/// Fetches one podcast and stores the result (or the error).
pub async fn refresh_one(state: &AppState, podcast_id: i64) -> ApiResult<()> {
    let (url, etag, lm) = with_db(&state.db, move |c| {
        Ok(c.query_row(
            "SELECT feed_url, etag, last_modified FROM podcast WHERE id = ?1",
            [podcast_id],
            |r| Ok((r.get::<_, String>(0)?, r.get::<_, Option<String>>(1)?, r.get::<_, Option<String>>(2)?)),
        )?)
    })
    .await?;
    match fetch(&state.http, &url, etag.as_deref(), lm.as_deref()).await {
        Ok(Some((feed, etag, lm))) => {
            with_db(&state.db, move |c| Ok(store(c, podcast_id, &feed, etag, lm)?)).await?;
            Ok(())
        }
        Ok(None) => {
            with_db(&state.db, move |c| {
                c.execute("UPDATE podcast SET last_fetch = strftime('%Y-%m-%dT%H:%M:%SZ', 'now'), last_error = NULL WHERE id = ?1", [podcast_id])?;
                Ok(())
            })
            .await
        }
        Err(e) => {
            let msg = format!("{e:#}");
            tracing::warn!("feed {url}: {msg}");
            let m = msg.clone();
            with_db(&state.db, move |c| {
                c.execute("UPDATE podcast SET last_error = ?2 WHERE id = ?1", (podcast_id, m))?;
                Ok(())
            })
            .await?;
            Err(ApiError::BadGateway(msg))
        }
    }
}

/// Background task: refreshes all subscribed podcasts every hour.
pub async fn refresh_loop(state: AppState) {
    loop {
        tokio::time::sleep(REFRESH_EVERY).await;
        let ids = with_db(&state.db, |c| {
            let mut stmt = c.prepare("SELECT DISTINCT podcast_id FROM subscription")?;
            let ids = stmt.query_map([], |r| r.get::<_, i64>(0))?.collect::<Result<Vec<_>, _>>()?;
            Ok(ids)
        })
        .await
        .unwrap_or_default();
        for id in ids {
            let _ = refresh_one(&state, id).await;
        }
    }
}

// ---------------------------------------------------------------- handlers

fn podcast_json(r: &rusqlite::Row) -> rusqlite::Result<Value> {
    Ok(json!({
        "id": r.get::<_, i64>("id")?,
        "feed_url": r.get::<_, String>("feed_url")?,
        "title": r.get::<_, String>("title")?,
        "author": r.get::<_, String>("author")?,
        "image_url": r.get::<_, String>("image_url")?,
        "last_fetch": r.get::<_, Option<String>>("last_fetch")?,
        "last_error": r.get::<_, Option<String>>("last_error")?,
        "episodes": r.get::<_, i64>("episodes")?,
    }))
}

const PODCAST_SELECT: &str = "SELECT p.*, (SELECT COUNT(*) FROM episode e WHERE e.podcast_id = p.id) AS episodes
     FROM podcast p JOIN subscription s ON s.podcast_id = p.id";

pub async fn list(State(state): State<AppState>, user: CurrentUser) -> ApiResult<Json<Value>> {
    with_db(&state.db, move |c| {
        let mut stmt = c.prepare(&format!("{PODCAST_SELECT} WHERE s.user_id = ?1 ORDER BY p.title COLLATE NOCASE"))?;
        let rows = stmt.query_map([user.id], podcast_json)?.collect::<Result<Vec<_>, _>>()?;
        Ok(Json(Value::Array(rows)))
    })
    .await
}

#[derive(Deserialize)]
pub struct Subscribe {
    feed_url: String,
}

pub async fn subscribe(State(state): State<AppState>, user: CurrentUser, Json(req): Json<Subscribe>) -> ApiResult<Json<Value>> {
    let url = req.feed_url.trim().to_string();
    if !(url.starts_with("https://") || url.starts_with("http://")) || url.len() > 2048 {
        return Err(ApiError::BadRequest("feed_url must be an http(s) URL".into()));
    }
    let u = url.clone();
    let (id, new) = with_db(&state.db, move |c| {
        if let Some(id) = c.query_row("SELECT id FROM podcast WHERE feed_url = ?1", [&u], |r| r.get::<_, i64>(0)).optional()? {
            return Ok((id, false));
        }
        c.execute("INSERT INTO podcast (feed_url) VALUES (?1)", [&u])?;
        Ok((c.last_insert_rowid(), true))
    })
    .await?;
    if new {
        if let Err(e) = refresh_one(&state, id).await {
            // Not a usable feed: do not keep it.
            with_db(&state.db, move |c| {
                c.execute("DELETE FROM podcast WHERE id = ?1", [id])?;
                Ok(())
            })
            .await?;
            return Err(e);
        }
    }
    with_db(&state.db, move |c| {
        c.execute("INSERT OR IGNORE INTO subscription (user_id, podcast_id) VALUES (?1, ?2)", (user.id, id))?;
        let p = c.query_row(&format!("{PODCAST_SELECT} WHERE s.user_id = ?1 AND p.id = ?2"), (user.id, id), podcast_json)?;
        Ok(Json(p))
    })
    .await
}

pub async fn unsubscribe(State(state): State<AppState>, user: CurrentUser, Path(id): Path<i64>) -> ApiResult<Json<Value>> {
    with_db(&state.db, move |c| {
        let n = c.execute("DELETE FROM subscription WHERE user_id = ?1 AND podcast_id = ?2", (user.id, id))?;
        if n == 0 {
            return Err(ApiError::NotFound);
        }
        // Its episodes can no longer be played by this user: drop them from "continue".
        c.execute(
            "DELETE FROM playback WHERE user_id = ?1 AND item_key IN (SELECT 'episode:' || id FROM episode WHERE podcast_id = ?2)",
            (user.id, id),
        )?;
        // Drop podcasts nobody subscribes to any more (episodes cascade).
        c.execute("DELETE FROM podcast WHERE id = ?1 AND NOT EXISTS (SELECT 1 FROM subscription WHERE podcast_id = ?1)", [id])?;
        Ok(Json(json!({ "ok": true })))
    })
    .await
}

pub async fn refresh(State(state): State<AppState>, user: CurrentUser, Path(id): Path<i64>) -> ApiResult<Json<Value>> {
    ensure_subscribed(&state, user.id, id).await?;
    refresh_one(&state, id).await?;
    Ok(Json(json!({ "ok": true })))
}

async fn ensure_subscribed(state: &AppState, user: i64, podcast: i64) -> ApiResult<()> {
    with_db(&state.db, move |c| {
        c.query_row("SELECT 1 FROM subscription WHERE user_id = ?1 AND podcast_id = ?2", (user, podcast), |_| Ok(()))?;
        Ok(())
    })
    .await
}

#[derive(Deserialize)]
pub struct Page {
    limit: Option<i64>,
    offset: Option<i64>,
}

fn episode_json(r: &rusqlite::Row) -> rusqlite::Result<Value> {
    let id: i64 = r.get("id")?;
    Ok(json!({
        "key": format!("episode:{id}"),
        "podcast_id": r.get::<_, i64>("podcast_id")?,
        "podcast": r.get::<_, String>("podcast_title")?,
        "title": r.get::<_, String>("title")?,
        "published": r.get::<_, Option<String>>("published")?,
        "duration_ms": r.get::<_, Option<i64>>("duration_s")?.map(|s| s * 1000),
        "mime": r.get::<_, String>("mime")?,
        "size": r.get::<_, Option<i64>>("size")?,
        "position_ms": r.get::<_, Option<i64>>("position_ms")?,
        "finished": r.get::<_, Option<bool>>("finished")?.unwrap_or(false),
    }))
}

const EPISODE_SELECT: &str = "SELECT e.*, p.title AS podcast_title, pb.position_ms, pb.finished
     FROM episode e JOIN podcast p ON p.id = e.podcast_id
     JOIN subscription s ON s.podcast_id = p.id AND s.user_id = ?1
     LEFT JOIN playback pb ON pb.user_id = ?1 AND pb.item_key = 'episode:' || e.id";

pub async fn episodes(
    State(state): State<AppState>,
    user: CurrentUser,
    Path(id): Path<i64>,
    Query(p): Query<Page>,
) -> ApiResult<Json<Value>> {
    let (limit, offset) = (p.limit.unwrap_or(50).clamp(1, 500), p.offset.unwrap_or(0).max(0));
    with_db(&state.db, move |c| {
        let mut stmt = c.prepare(&format!("{EPISODE_SELECT} WHERE e.podcast_id = ?2 ORDER BY e.published DESC LIMIT ?3 OFFSET ?4"))?;
        let rows = stmt.query_map((user.id, id, limit, offset), episode_json)?.collect::<Result<Vec<_>, _>>()?;
        Ok(Json(Value::Array(rows)))
    })
    .await
}

/// Newest episodes across all subscriptions.
pub async fn latest(State(state): State<AppState>, user: CurrentUser, Query(p): Query<Page>) -> ApiResult<Json<Value>> {
    let limit = p.limit.unwrap_or(30).clamp(1, 200);
    with_db(&state.db, move |c| {
        let mut stmt = c.prepare(&format!("{EPISODE_SELECT} ORDER BY e.published DESC LIMIT ?2"))?;
        let rows = stmt.query_map((user.id, limit), episode_json)?.collect::<Result<Vec<_>, _>>()?;
        Ok(Json(Value::Array(rows)))
    })
    .await
}

#[derive(Deserialize)]
pub struct Search {
    q: String,
}

/// Podcast search in the fyyd directory (no account needed); returns feed URLs to subscribe.
pub async fn search(State(state): State<AppState>, _user: CurrentUser, Query(s): Query<Search>) -> ApiResult<Json<Value>> {
    let q = s.q.trim();
    if q.is_empty() || q.len() > 200 {
        return Err(ApiError::BadRequest("query required".into()));
    }
    let res = state
        .http
        .get("https://api.fyyd.de/0.2/search/podcast")
        .query(&[("term", q), ("count", "30")])
        .timeout(Duration::from_secs(15))
        .send()
        .await
        .map_err(|e| ApiError::BadGateway(format!("podcast search unreachable: {}", e.without_url())))?;
    let v: Value = res.json().await.map_err(|e| ApiError::BadGateway(format!("podcast search: {e}")))?;
    let list: Vec<Value> = v["data"]
        .as_array()
        .map(|a| {
            a.iter()
                .filter(|p| p["xmlURL"].as_str().is_some_and(|u| u.starts_with("http")))
                .map(|p| json!({ "title": p["title"], "author": p["author"], "feed_url": p["xmlURL"],
                                 "image_url": p["imgURL"], "description": p["subtitle"] }))
                .collect()
        })
        .unwrap_or_default();
    Ok(Json(Value::Array(list)))
}

/// Episode URL and metadata for streaming (used by media.rs).
pub fn episode_source(c: &rusqlite::Connection, user: i64, id: i64) -> ApiResult<(String, String, Option<i64>, Option<i64>, String, String)> {
    Ok(c.query_row(
        "SELECT e.url, e.mime, e.size, e.duration_s, e.title, p.title FROM episode e
         JOIN podcast p ON p.id = e.podcast_id JOIN subscription s ON s.podcast_id = p.id AND s.user_id = ?1
         WHERE e.id = ?2",
        (user, id),
        |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?, r.get(3)?, r.get(4)?, r.get(5)?)),
    )?)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn durations() {
        assert_eq!(parse_duration("1:02:03"), Some(3723));
        assert_eq!(parse_duration("62:03"), Some(3723));
        assert_eq!(parse_duration("3723"), Some(3723));
        assert_eq!(parse_duration(""), None);
        assert_eq!(parse_duration("abc"), None);
    }

    #[test]
    fn feed() {
        let xml = br#"<?xml version="1.0"?><rss version="2.0" xmlns:itunes="http://www.itunes.com/dtds/podcast-1.0.dtd">
          <channel><title>Test</title><itunes:author>A</itunes:author>
          <item><title>E1</title><guid>g1</guid><pubDate>Fri, 30 Oct 2026 10:00:00 +0100</pubDate>
            <itunes:duration>01:00</itunes:duration><enclosure url="https://x/e1.mp3" type="audio/mpeg" length="1000"/></item>
          <item><title>no enclosure</title></item>
          </channel></rss>"#;
        let f = parse_feed(xml).unwrap();
        assert_eq!(f.title, "Test");
        assert_eq!(f.episodes.len(), 1);
        assert_eq!(f.episodes[0].published.as_deref(), Some("2026-10-30T09:00:00Z"));
        assert_eq!(f.episodes[0].duration_s, Some(60));
    }
}
