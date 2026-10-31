//! Jellyfin as a source: library browsing, item metadata incl. audio quality, stream and
//! image URLs. The API key stays on the server; clients only see audiojoe URLs.

use std::time::Duration;

use axum::{http::header, response::Response};
use serde_json::{json, Value};

use crate::{
    error::{with_db, ApiError, ApiResult},
    sources::Browse,
    AppState,
};

/// Jellyfin and Emby (Jellyfin is a fork of Emby; the API is largely the same).
/// Emby: tested against Emby Server 4.10 (tools/dev/e2e.py, EMBY_TEST_FILE).
#[derive(Clone)]
pub struct Jellyfin {
    pub source_id: i64,
    pub base: String,
    key: String,
    /// "jellyfin" or "emby" – also the prefix of item keys.
    pub kind: String,
}

impl Jellyfin {
    /// Request header carrying the API key.
    pub fn auth(&self) -> (header::HeaderName, String) {
        if self.kind == "emby" {
            return (header::HeaderName::from_static("x-emby-token"), self.key.clone());
        }
        (
            header::AUTHORIZATION,
            format!(
                "MediaBrowser Client=\"audiojoe\", Device=\"audiojoe-server\", DeviceId=\"audiojoe-server\", Version=\"{}\", Token=\"{}\"",
                env!("CARGO_PKG_VERSION"),
                self.key
            ),
        )
    }

    async fn get(&self, http: &reqwest::Client, path: &str, query: &[(&str, String)]) -> ApiResult<Value> {
        let res = http
            .get(format!("{}{path}", self.base))
            .query(query)
            .header(self.auth().0, self.auth().1)
            .timeout(Duration::from_secs(20))
            .send()
            .await
            .map_err(|e| ApiError::BadGateway(format!("{} unreachable: {}", self.kind, e.without_url())))?;
        if res.status() == reqwest::StatusCode::NOT_FOUND {
            return Err(ApiError::NotFound);
        }
        if !res.status().is_success() {
            return Err(ApiError::BadGateway(format!("jellyfin answered {}", res.status())));
        }
        res.json().await.map_err(|e| ApiError::BadGateway(format!("jellyfin: invalid response: {e}")))
    }

    /// The Jellyfin user whose library is browsed: the first administrator.
    async fn user_id(&self, state: &AppState) -> ApiResult<String> {
        if let Some(id) = state.jellyfin_users.lock().unwrap().get(&self.source_id) {
            return Ok(id.clone());
        }
        let users = self.get(&state.http, "/Users", &[]).await?;
        let users = users.as_array().cloned().unwrap_or_default();
        let user = users
            .iter()
            .find(|u| u["Policy"]["IsAdministrator"].as_bool() == Some(true))
            .or_else(|| users.first())
            .and_then(|u| u["Id"].as_str())
            .ok_or_else(|| ApiError::BadGateway("jellyfin has no users".into()))?
            .to_string();
        state.jellyfin_users.lock().unwrap().insert(self.source_id, user.clone());
        Ok(user)
    }

    pub fn stream_url(&self, item: &str) -> String {
        format!("{}/Audio/{}/stream?static=true", self.base, item)
    }

    pub async fn item(&self, state: &AppState, item: &str) -> ApiResult<Value> {
        let uid = self.user_id(state).await?;
        let v = self
            .get(&state.http, &format!("/Users/{uid}/Items/{item}"), &[("Fields", "MediaSources,MediaStreams,Overview".into())])
            .await?;
        Ok(normalize(&self.kind, self.source_id, &v))
    }
}

/// Loads a Jellyfin or Emby source.
pub async fn source(state: &AppState, id: i64) -> ApiResult<Jellyfin> {
    with_db(&state.db, move |c| {
        Ok(c.query_row(
            "SELECT url, secret, kind FROM source WHERE id = ?1 AND kind IN ('jellyfin', 'emby')",
            [id],
            |r| Ok(Jellyfin { source_id: id, base: r.get(0)?, key: r.get(1)?, kind: r.get(2)? }),
        )?)
    })
    .await
}

/// Audio quality of the first audio stream of a Jellyfin item.
fn quality(v: &Value) -> Value {
    let src = &v["MediaSources"][0];
    let streams = src["MediaStreams"].as_array().or_else(|| v["MediaStreams"].as_array());
    let audio = streams.and_then(|s| s.iter().find(|m| m["Type"] == "Audio"));
    match audio {
        Some(a) => json!({
            "codec": a["Codec"].as_str().unwrap_or("").to_lowercase(),
            "sample_rate": a["SampleRate"].as_i64(),
            "bit_depth": a["BitDepth"].as_i64(),
            "bitrate": a["BitRate"].as_i64().or_else(|| src["Bitrate"].as_i64()),
            "channels": a["Channels"].as_i64(),
            "container": src["Container"].as_str(),
            "size": src["Size"].as_i64(),
        }),
        None => Value::Null,
    }
}

fn normalize(prefix: &str, source: i64, v: &Value) -> Value {
    let id = v["Id"].as_str().unwrap_or_default();
    let typ = v["Type"].as_str().unwrap_or_default();
    let kind = match typ {
        "Audio" => "track",
        "MusicAlbum" => "album",
        "MusicArtist" => "artist",
        _ => "folder",
    };
    let artists = v["AlbumArtist"]
        .as_str()
        .map(str::to_string)
        .or_else(|| v["Artists"].as_array().map(|a| a.iter().filter_map(|x| x.as_str()).collect::<Vec<_>>().join(", ")))
        .unwrap_or_default();
    let subtitle = match kind {
        "track" => [artists.as_str(), v["Album"].as_str().unwrap_or("")].iter().filter(|s| !s.is_empty()).cloned().collect::<Vec<_>>().join(" · "),
        _ => artists,
    };
    json!({
        "key": format!("{prefix}:{source}:{id}"),
        "kind": kind,
        "title": v["Name"].as_str().unwrap_or(""),
        "subtitle": subtitle,
        "year": v["ProductionYear"].as_i64(),
        "genres": v["Genres"].as_array().map(|g| g.iter().filter_map(|x| x.as_str()).take(4).collect::<Vec<_>>()).unwrap_or_default(),
        "track": v["IndexNumber"].as_i64(),
        "disc": v["ParentIndexNumber"].as_i64(),
        "duration_ms": v["RunTimeTicks"].as_i64().map(|t| t / 10_000),
        "image": v["ImageTags"]["Primary"].as_str().map(|_| format!("/api/v1/image/{prefix}:{source}:{id}")),
        "description": v["Overview"].as_str().map(crate::podcasts::plain_text),
        "notes": v["Overview"].as_str().map(crate::notes::html).filter(|s| !s.is_empty()),
        "quality": if kind == "track" { quality(v) } else { Value::Null },
    })
}

// ---------------------------------------------------------------- browsing

pub fn valid_id(id: &str) -> bool {
    !id.is_empty() && id.len() <= 64 && id.chars().all(|c| c.is_ascii_alphanumeric() || c == '-')
}

pub async fn browse(state: &AppState, source_id: i64, q: &Browse) -> ApiResult<Value> {
    let jf = source(state, source_id).await?;
    let uid = jf.user_id(state).await?;
    let start = q.start.unwrap_or(0).to_string();
    let limit = q.limit.unwrap_or(100).clamp(1, 500).to_string();
    let fields = ("Fields", "MediaSources,MediaStreams".to_string());

    let items: Value = if let Some(term) = q.search.clone().filter(|s| !s.trim().is_empty()) {
        jf.get(&state.http, &format!("/Users/{uid}/Items"), &[
            ("SearchTerm", term),
            ("IncludeItemTypes", "MusicAlbum,Audio,MusicArtist".into()),
            ("Recursive", "true".into()),
            ("StartIndex", start),
            ("Limit", limit),
            fields,
        ])
        .await?
    } else if let Some(parent) = q.parent.clone() {
        if !valid_id(&parent) {
            return Err(ApiError::BadRequest("invalid parent".into()));
        }
        let p = jf.get(&state.http, &format!("/Users/{uid}/Items/{parent}"), &[]).await?;
        let mut query = vec![("ParentId", parent.clone()), ("StartIndex", start), ("Limit", limit), fields];
        match (p["Type"].as_str(), p["CollectionType"].as_str()) {
            // Music library: all albums, alphabetically.
            (_, Some("music")) => query.extend([
                ("IncludeItemTypes", "MusicAlbum".to_string()),
                ("Recursive", "true".to_string()),
                ("SortBy", "AlbumArtist,SortName".to_string()),
            ]),
            (Some("MusicAlbum"), _) => query.push(("SortBy", "ParentIndexNumber,IndexNumber,SortName".to_string())),
            (Some("MusicArtist"), _) => {
                query.retain(|(k, _)| *k != "ParentId");
                query.extend([
                    ("ArtistIds", parent),
                    ("IncludeItemTypes", "MusicAlbum".to_string()),
                    ("Recursive", "true".to_string()),
                    ("SortBy", "ProductionYear,SortName".to_string()),
                ]);
            }
            _ => query.push(("SortBy", "IsFolder,SortName".to_string())),
        }
        jf.get(&state.http, &format!("/Users/{uid}/Items"), &query).await?
    } else {
        // Top level: the audio libraries.
        let views = jf.get(&state.http, &format!("/Users/{uid}/Views"), &[]).await?;
        let items: Vec<Value> = views["Items"]
            .as_array()
            .map(|a| {
                a.iter()
                    .filter(|v| matches!(v["CollectionType"].as_str(), Some("music" | "audiobooks" | "books") | None))
                    .cloned()
                    .collect()
            })
            .unwrap_or_default();
        json!({ "Items": items, "TotalRecordCount": items.len() })
    };

    let list: Vec<Value> = items["Items"].as_array().map(|a| a.iter().map(|v| normalize(&jf.kind, source_id, v)).collect()).unwrap_or_default();
    Ok(json!({ "items": list, "total": items["TotalRecordCount"] }))
}

/// Cover image of an item, relayed so the API key never reaches the client.
pub async fn image(state: &AppState, src: i64, item: &str) -> ApiResult<Response> {
    if !valid_id(item) {
        return Err(ApiError::NotFound);
    }
    let jf = source(state, src).await?;
    let req = state
        .http
        .get(format!("{}/Items/{item}/Images/Primary", jf.base))
        .query(&[("maxHeight", "400"), ("quality", "85")])
        .header(jf.auth().0, jf.auth().1);
    crate::sources::relay_image(req).await
}

/// Checks URL and key; returns server name and version.
pub async fn check(state: &AppState, kind: &str, url: &str, key: &str) -> ApiResult<Value> {
    let probe = Jellyfin { source_id: 0, base: url.to_string(), key: key.to_string(), kind: kind.to_string() };
    let info = probe.get(&state.http, "/System/Info", &[]).await?;
    Ok(json!({ "server": info["ServerName"], "version": info["Version"] }))
}
