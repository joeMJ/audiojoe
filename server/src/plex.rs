//! Plex Media Server as a source: music sections, albums, tracks, quality, stream and
//! cover URLs. The token stays on the server.
//!
//! Item keys: `plex:<source>:<ratingKey>`; music sections are browsed as `s<sectionKey>`.
//! Untested against a real server so far (no test instance yet).

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

    async fn get(&self, http: &reqwest::Client, path: &str, query: &[(&str, String)]) -> ApiResult<Value> {
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
        "track": m["index"].as_i64(),
        "duration_ms": m["duration"].as_i64(),
        "image": m["thumb"].as_str().map(|_| format!("/api/v1/image/plex:{src}:{id}")),
        "quality": if kind == "track" { quality(m) } else { Value::Null },
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
