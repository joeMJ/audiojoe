//! Plex Media Server as a source: music sections, albums, tracks, quality, stream and
//! cover URLs. The token stays on the server.
//!
//! Item keys: `plex:<source>:<ratingKey>`; music sections are browsed as `s<sectionKey>`.
//! Audiobooks: Plex has no audiobook type; a music section counts as audiobooks when it uses
//! the Audnexus agent or its name says so (see `is_book_section`). Album = book
//! (`pbook:<source>:<ratingKey>`), album artist = author; no series, no narrator.
//! Tested against Plex Media Server 1.43 (tools/dev/e2e.py, PLEX_URL).

use std::time::Duration;

use axum::response::Response;
use serde_json::{json, Value};

use crate::{
    error::{with_db, ApiError, ApiResult},
    sources::Browse,
    AppState,
};

#[derive(Clone)]
pub struct Plex {
    pub source_id: i64,
    pub base: String,
    token: String,
}

pub fn valid_id(id: &str) -> bool {
    !id.is_empty() && id.len() <= 32 && id.chars().all(|c| c.is_ascii_alphanumeric())
}

impl Plex {
    pub fn auth(&self) -> (axum::http::HeaderName, String) {
        (axum::http::HeaderName::from_static("x-plex-token"), self.token.clone())
    }

    pub(crate) async fn get(&self, http: &reqwest::Client, path: &str, query: &[(&str, String)]) -> ApiResult<Value> {
        let res = http
            .get(format!("{}{path}", self.base))
            .query(query)
            .header("x-plex-token", &self.token)
            .header("accept", "application/json")
            .header("x-plex-product", "audiojoe")
            .header("x-plex-client-identifier", "audiojoe-server")
            .timeout(Duration::from_secs(20))
            .send()
            .await
            .map_err(|e| ApiError::BadGateway(format!("plex unreachable: {}", e.without_url())))?;
        match res.status() {
            s if s == reqwest::StatusCode::NOT_FOUND => Err(ApiError::NotFound),
            s if !s.is_success() => Err(ApiError::BadGateway(format!("plex answered {s}"))),
            _ => res.json().await.map_err(|e| ApiError::BadGateway(format!("plex: invalid response: {e}"))),
        }
    }

    /// Track metadata incl. the stream URL of its first file.
    pub async fn track(&self, state: &AppState, id: &str) -> ApiResult<(Value, String)> {
        if !valid_id(id) {
            return Err(ApiError::NotFound);
        }
        let v = self.get(&state.http, &format!("/library/metadata/{id}"), &[]).await?;
        let m = &v["MediaContainer"]["Metadata"][0];
        let part = &m["Media"][0]["Part"][0];
        let url = part["key"].as_str().map(|k| format!("{}{k}", self.base)).ok_or(ApiError::NotFound)?;
        Ok((normalize(self.source_id, m), url))
    }
}

pub async fn source(state: &AppState, id: i64) -> ApiResult<Plex> {
    with_db(&state.db, move |c| {
        Ok(c.query_row(
            "SELECT url, secret FROM source WHERE id = ?1 AND kind = 'plex'",
            [id],
            |r| Ok(Plex { source_id: id, base: r.get(0)?, token: r.get(1)? }),
        )?)
    })
    .await
}

pub async fn check(state: &AppState, url: &str, token: &str) -> ApiResult<Value> {
    let p = Plex { source_id: 0, base: url.to_string(), token: token.to_string() };
    let v = p.get(&state.http, "/", &[]).await?;
    let mc = &v["MediaContainer"];
    Ok(json!({ "server": mc["friendlyName"], "version": mc["version"] }))
}

fn quality(m: &Value) -> Value {
    let media = &m["Media"][0];
    let stream = m["Media"][0]["Part"][0]["Stream"]
        .as_array()
        .and_then(|a| a.iter().find(|s| s["streamType"] == 2))
        .cloned()
        .unwrap_or(Value::Null);
    if media.is_null() {
        return Value::Null;
    }
    json!({
        "codec": stream["codec"].as_str().or(media["audioCodec"].as_str()).unwrap_or("").to_lowercase(),
        "sample_rate": stream["samplingRate"].as_i64(),
        "bit_depth": stream["bitDepth"].as_i64(),
        "bitrate": stream["bitrate"].as_i64().or(media["bitrate"].as_i64()).map(|b| b * 1000),
        "channels": stream["channels"].as_i64().or(media["audioChannels"].as_i64()),
        "container": media["container"].as_str(),
        "size": media["Part"][0]["size"].as_i64(),
    })
}

fn normalize(src: i64, m: &Value) -> Value {
    let id = m["ratingKey"].as_str().unwrap_or_default();
    let kind = match m["type"].as_str() {
        Some("track") => "track",
        Some("album") => "album",
        Some("artist") => "artist",
        _ => "folder",
    };
    let subtitle = match kind {
        "track" => [m["grandparentTitle"].as_str().unwrap_or(""), m["parentTitle"].as_str().unwrap_or("")]
            .iter().filter(|s| !s.is_empty()).cloned().collect::<Vec<_>>().join(" · "),
        _ => m["parentTitle"].as_str().unwrap_or("").to_string(),
    };
    json!({
        "key": format!("plex:{src}:{id}"),
        "kind": kind,
        "title": m["title"].as_str().unwrap_or(""),
        "subtitle": subtitle,
        "year": m["year"].as_i64(),
        "genres": m["Genre"].as_array().map(|g| g.iter().filter_map(|x| x["tag"].as_str()).take(4).collect::<Vec<_>>()).unwrap_or_default(),
        "track": m["index"].as_i64(),
        "duration_ms": m["duration"].as_i64(),
        "image": m["thumb"].as_str().map(|_| format!("/api/v1/image/plex:{src}:{id}")),
        "description": m["summary"].as_str().filter(|s| !s.is_empty()).map(crate::podcasts::plain_text),
        "notes": m["summary"].as_str().map(crate::notes::html).filter(|s| !s.is_empty()),
        "quality": if kind == "track" { quality(m) } else { Value::Null },
        // The album of a title: the apps' cache pill saves the whole album.
        "album": if kind == "track" { m["parentRatingKey"].as_str().map(|a| format!("plex:{src}:{a}")) } else { None },
    })
}

pub async fn browse(state: &AppState, src: i64, q: &Browse) -> ApiResult<Value> {
    let p = source(state, src).await?;
    let start = q.start.unwrap_or(0).to_string();
    let size = q.limit.unwrap_or(100).clamp(1, 500).to_string();
    let paging = [("X-Plex-Container-Start", start), ("X-Plex-Container-Size", size)];
    let list: Vec<Value> = match q.parent.as_deref() {
        None => {
            // Music sections.
            let v = p.get(&state.http, "/library/sections", &[]).await?;
            v["MediaContainer"]["Directory"]
                .as_array()
                .map(|a| a.iter().filter(|d| d["type"] == "artist")
                    .map(|d| json!({ "key": format!("plex:{src}:s{}", d["key"].as_str().unwrap_or("")), "kind": "folder",
                                     "title": d["title"], "subtitle": "", "image": null, "quality": null }))
                    .collect())
                .unwrap_or_default()
        }
        Some(parent) => {
            let (path, query): (String, Vec<(&str, String)>) = match parent.strip_prefix('s') {
                // Section: all albums.
                Some(sec) if valid_id(sec) => (format!("/library/sections/{sec}/all"), vec![("type", "9".into())]),
                _ if valid_id(parent) => (format!("/library/metadata/{parent}/children"), vec![]),
                _ => return Err(ApiError::BadRequest("invalid parent".into())),
            };
            let query: Vec<(&str, String)> = query.into_iter().chain(paging.iter().cloned()).collect();
            let v = p.get(&state.http, &path, &query).await?;
            v["MediaContainer"]["Metadata"].as_array().map(|a| a.iter().map(|m| normalize(src, m)).collect()).unwrap_or_default()
        }
    };
    Ok(json!({ "items": list, "total": list.len() }))
}

// ---------------------------------------------------------------- audiobooks

/// A music section holding audiobooks: Audnexus agent, or a name like „Hörbücher“/"Audiobooks".
pub fn is_book_section(d: &Value) -> bool {
    if d["type"] != "artist" {
        return false;
    }
    let agent = d["agent"].as_str().unwrap_or("").to_lowercase();
    let title = d["title"].as_str().unwrap_or("").to_lowercase();
    agent.contains("audnexus") || ["hörbuch", "hörbücher", "hoerbuch", "hoerbuecher", "audiobook", "audio book"].iter().any(|w| title.contains(w))
}

/// Audiobook sections of a source: (section key, name).
pub async fn book_sections(state: &AppState, src: i64) -> ApiResult<Vec<(String, String)>> {
    let p = source(state, src).await?;
    let v = p.get(&state.http, "/library/sections", &[]).await?;
    Ok(v["MediaContainer"]["Directory"]
        .as_array()
        .map(|a| {
            a.iter()
                .filter(|d| is_book_section(d))
                .filter_map(|d| Some((format!("s{}", d["key"].as_str()?), d["title"].as_str().unwrap_or("").to_string())))
                .collect()
        })
        .unwrap_or_default())
}

/// All albums of a section, page by page.
async fn all_albums(p: &Plex, state: &AppState, sec: &str) -> ApiResult<Vec<Value>> {
    let mut out: Vec<Value> = Vec::new();
    loop {
        let v = p
            .get(&state.http, &format!("/library/sections/{sec}/all"), &[
                ("type", "9".to_string()),
                ("X-Plex-Container-Start", out.len().to_string()),
                ("X-Plex-Container-Size", "500".to_string()),
            ])
            .await?;
        let page = v["MediaContainer"]["Metadata"].as_array().cloned().unwrap_or_default();
        let n = page.len();
        out.extend(page);
        let total = v["MediaContainer"]["totalSize"].as_u64().unwrap_or(0) as usize;
        if n < 500 || out.len() >= total || out.len() >= 20_000 {
            return Ok(out);
        }
    }
}

fn book_json(src: i64, m: &Value, progress: &std::collections::HashMap<String, (i64, bool)>) -> Value {
    let id = m["ratingKey"].as_str().unwrap_or_default();
    let key = format!("pbook:{src}:{id}");
    let author = m["parentTitle"].as_str().unwrap_or("").trim().to_string();
    let (pos, fin) = progress.get(&key).copied().unwrap_or((0, false));
    json!({
        "key": key, "kind": "book", "title": m["title"].as_str().unwrap_or(""), "subtitle": author,
        "year": m["year"].as_i64(), "duration_ms": m["duration"].as_i64(),
        "image": m["thumb"].as_str().map(|_| format!("/api/v1/image/pbook:{src}:{id}")), "quality": null,
        "author": author, "narrator": "", "series": null, "sequence": null, "volume": null,
        "added": m["addedAt"].as_i64().map(|s| s * 1000), "position_ms": pos, "finished": fin,
    })
}

/// `/api/v1/sources/{id}/books?parent=s<section>` for Plex.
pub async fn library(state: &AppState, user: i64, src: i64, lib: &str) -> ApiResult<Value> {
    let Some(sec) = lib.strip_prefix('s').filter(|s| valid_id(s)) else {
        return Err(ApiError::BadRequest("invalid library".into()));
    };
    let p = source(state, src).await?;
    let albums = all_albums(&p, state, sec).await?;
    let prefix = format!("pbook:{src}:");
    let progress: std::collections::HashMap<String, (i64, bool)> = with_db(&state.db, move |c| {
        let mut st = c.prepare("SELECT item_key, position_ms, finished FROM playback WHERE user_id = ?1 AND item_key LIKE ?2 || '%'")?;
        let rows = st.query_map((user, &prefix), |r| Ok((r.get::<_, String>(0)?, (r.get::<_, i64>(1)?, r.get::<_, bool>(2)?))))?;
        Ok(rows.collect::<Result<_, _>>()?)
    })
    .await?;
    let mut books: Vec<Value> = albums.iter().map(|m| book_json(src, m, &progress)).collect();
    books.sort_by(|a, b| crate::audiobookshelf::natural_cmp(a["title"].as_str().unwrap_or(""), b["title"].as_str().unwrap_or("")));
    let mut authors: std::collections::BTreeMap<String, (String, usize)> = Default::default();
    for b in books.iter().filter(|b| !b["author"].as_str().unwrap_or("").is_empty()) {
        let name = b["author"].as_str().unwrap_or("");
        authors.entry(name.to_lowercase()).or_insert_with(|| (name.to_string(), 0)).1 += 1;
    }
    let authors: Vec<Value> = authors.into_values().map(|(name, n)| json!({ "name": name, "books": n })).collect();
    Ok(json!({ "books": books, "authors": authors, "series": [] }))
}

/// A book (album) for playing: metadata with parts (one per track) and the tracks' URLs.
pub async fn book(state: &AppState, p: &Plex, id: &str) -> ApiResult<(Value, Vec<String>)> {
    if !valid_id(id) {
        return Err(ApiError::NotFound);
    }
    let album = p.get(&state.http, &format!("/library/metadata/{id}"), &[]).await?;
    let m = &album["MediaContainer"]["Metadata"][0];
    let v = p.get(&state.http, &format!("/library/metadata/{id}/children"), &[]).await?;
    let tracks = v["MediaContainer"]["Metadata"].as_array().cloned().unwrap_or_default();
    if m.is_null() || tracks.is_empty() {
        return Err(ApiError::NotFound);
    }
    let mut parts = Vec::new();
    let mut urls = Vec::new();
    let mut offset = 0i64;
    for (i, t) in tracks.iter().enumerate() {
        let Some(k) = t["Media"][0]["Part"][0]["key"].as_str() else { continue };
        let dur = t["duration"].as_i64().unwrap_or(0);
        parts.push(json!({ "index": i, "start_ms": offset, "duration_ms": dur, "title": t["title"].as_str().unwrap_or("") }));
        urls.push(format!("{}{k}", p.base));
        offset += dur;
    }
    let chapters: Vec<Value> = parts.iter().map(|c| json!({ "title": c["title"], "start_ms": c["start_ms"],
        "end_ms": c["start_ms"].as_i64().unwrap_or(0) + c["duration_ms"].as_i64().unwrap_or(0) })).collect();
    let mut meta = book_json(p.source_id, m, &Default::default());
    meta["duration_ms"] = json!(offset);
    meta["description"] = json!(m["summary"].as_str().filter(|s| !s.is_empty()).map(crate::podcasts::plain_text));
    meta["notes"] = json!(m["summary"].as_str().map(crate::notes::html).filter(|s| !s.is_empty()));
    meta["quality"] = quality(&tracks[0]);
    meta["parts"] = json!(parts);
    meta["chapters"] = json!(chapters);
    Ok((meta, urls))
}

pub async fn image(state: &AppState, src: i64, item: &str) -> ApiResult<Response> {
    if !valid_id(item) {
        return Err(ApiError::NotFound);
    }
    let p = source(state, src).await?;
    let v = p.get(&state.http, &format!("/library/metadata/{item}"), &[]).await?;
    let thumb = v["MediaContainer"]["Metadata"][0]["thumb"].as_str().ok_or(ApiError::NotFound)?.to_string();
    let req = state.http.get(format!("{}/photo/:/transcode", p.base))
        .query(&[("width", "400"), ("height", "400"), ("url", thumb.as_str())])
        .header("x-plex-token", &p.token);
    crate::sources::relay_image(req).await
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn book_sections_by_agent_or_name() {
        assert!(is_book_section(&json!({ "type": "artist", "agent": "com.plexapp.agents.audnexus", "title": "Books" })));
        assert!(is_book_section(&json!({ "type": "artist", "agent": "tv.plex.agents.music", "title": "Hörbücher" })));
        assert!(!is_book_section(&json!({ "type": "artist", "agent": "tv.plex.agents.music", "title": "Musik" })));
        assert!(!is_book_section(&json!({ "type": "movie", "agent": "x", "title": "Audiobooks" })));
    }

    #[test]
    fn track_names_its_album() {
        let t = normalize(3, &json!({ "ratingKey": "123", "type": "track", "title": "So What", "parentRatingKey": "77" }));
        assert_eq!(t["album"], "plex:3:77");
        assert!(normalize(3, &json!({ "ratingKey": "77", "type": "album", "title": "Kind of Blue" }))["album"].is_null());
    }

    #[test]
    fn track_from_plex_json() {
        let m = json!({
            "ratingKey": "123", "type": "track", "title": "So What", "grandparentTitle": "Miles Davis",
            "parentTitle": "Kind of Blue", "index": 1, "duration": 562000, "thumb": "/library/metadata/120/thumb/1",
            "Media": [{ "container": "flac", "audioCodec": "flac", "bitrate": 3450, "audioChannels": 2,
                        "Part": [{ "key": "/library/parts/9/1/file.flac", "size": 1000,
                                   "Stream": [{ "streamType": 2, "codec": "flac", "samplingRate": 96000, "bitDepth": 24, "channels": 2 }] }] }]
        });
        let n = normalize(4, &m);
        assert_eq!(n["key"], "plex:4:123");
        assert_eq!(n["subtitle"], "Miles Davis · Kind of Blue");
        assert_eq!(n["quality"]["sample_rate"], 96000);
        assert_eq!(n["quality"]["bit_depth"], 24);
        assert_eq!(n["quality"]["bitrate"], 3_450_000);
    }
}
