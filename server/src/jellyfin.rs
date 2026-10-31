//! Jellyfin as a source: library browsing, item metadata incl. audio quality, stream and
//! image URLs. The API key stays on the server; clients only see audiojoe URLs.

use std::time::Duration;

use axum::{
    body::Body,
    extract::{Path, Query, State},
    http::{header, HeaderMap, StatusCode},
    response::{IntoResponse, Response},
    Json,
};
use serde::Deserialize;
use serde_json::{json, Value};

use crate::{
    auth::CurrentUser,
    error::{with_db, ApiError, ApiResult},
    AppState,
};

#[derive(Clone)]
pub struct Jellyfin {
    pub source_id: i64,
    pub base: String,
    key: String,
}

impl Jellyfin {
    pub fn auth_header(&self) -> String {
        format!(
            "MediaBrowser Client=\"audiojoe\", Device=\"audiojoe-server\", DeviceId=\"audiojoe-server\", Version=\"{}\", Token=\"{}\"",
            env!("CARGO_PKG_VERSION"),
            self.key
        )
    }

    async fn get(&self, http: &reqwest::Client, path: &str, query: &[(&str, String)]) -> ApiResult<Value> {
        let res = http
            .get(format!("{}{path}", self.base))
            .query(query)
            .header(header::AUTHORIZATION, self.auth_header())
            .timeout(Duration::from_secs(20))
            .send()
            .await
            .map_err(|e| ApiError::BadGateway(format!("jellyfin unreachable: {e}")))?;
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
            .get(&state.http, &format!("/Users/{uid}/Items/{item}"), &[("Fields", "MediaSources,MediaStreams".into())])
            .await?;
        Ok(normalize(self.source_id, &v))
    }
}

/// Loads a Jellyfin source.
pub async fn source(state: &AppState, id: i64) -> ApiResult<Jellyfin> {
    with_db(&state.db, move |c| {
        Ok(c.query_row(
            "SELECT url, secret FROM source WHERE id = ?1 AND kind = 'jellyfin'",
            [id],
            |r| Ok(Jellyfin { source_id: id, base: r.get(0)?, key: r.get(1)? }),
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

fn normalize(source: i64, v: &Value) -> Value {
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
        "key": format!("jellyfin:{source}:{id}"),
        "kind": kind,
        "title": v["Name"].as_str().unwrap_or(""),
        "subtitle": subtitle,
        "year": v["ProductionYear"].as_i64(),
        "track": v["IndexNumber"].as_i64(),
        "disc": v["ParentIndexNumber"].as_i64(),
        "duration_ms": v["RunTimeTicks"].as_i64().map(|t| t / 10_000),
        "image": v["ImageTags"]["Primary"].as_str().map(|_| format!("/api/v1/image/jellyfin:{source}:{id}")),
        "quality": if kind == "track" { quality(v) } else { Value::Null },
    })
}

// ---------------------------------------------------------------- handlers

#[derive(Deserialize)]
pub struct Browse {
    parent: Option<String>,
    search: Option<String>,
    start: Option<u32>,
    limit: Option<u32>,
}

fn valid_id(id: &str) -> bool {
    !id.is_empty() && id.len() <= 64 && id.chars().all(|c| c.is_ascii_alphanumeric() || c == '-')
}

pub async fn browse(
    State(state): State<AppState>,
    _user: CurrentUser,
    Path(source_id): Path<i64>,
    Query(q): Query<Browse>,
) -> ApiResult<Json<Value>> {
    let jf = source(&state, source_id).await?;
    let uid = jf.user_id(&state).await?;
    let start = q.start.unwrap_or(0).to_string();
    let limit = q.limit.unwrap_or(100).clamp(1, 500).to_string();
    let fields = ("Fields", "MediaSources,MediaStreams".to_string());

    let items: Value = if let Some(term) = q.search.filter(|s| !s.trim().is_empty()) {
        jf.get(&state.http, &format!("/Users/{uid}/Items"), &[
            ("SearchTerm", term),
            ("IncludeItemTypes", "MusicAlbum,Audio,MusicArtist".into()),
            ("Recursive", "true".into()),
            ("StartIndex", start),
            ("Limit", limit),
            fields,
        ])
        .await?
    } else if let Some(parent) = q.parent {
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

    let list: Vec<Value> = items["Items"].as_array().map(|a| a.iter().map(|v| normalize(source_id, v)).collect()).unwrap_or_default();
    Ok(Json(json!({ "items": list, "total": items["TotalRecordCount"] })))
}

/// Cover images, relayed so the API key never reaches the client.
pub async fn image(State(state): State<AppState>, _user: CurrentUser, Path(key): Path<String>) -> ApiResult<Response> {
    let mut parts = key.splitn(3, ':');
    let (Some("jellyfin"), Some(src), Some(item)) = (parts.next(), parts.next(), parts.next()) else {
        return Err(ApiError::NotFound);
    };
    let src: i64 = src.parse().map_err(|_| ApiError::NotFound)?;
    if !valid_id(item) {
        return Err(ApiError::NotFound);
    }
    let jf = source(&state, src).await?;
    let res = state
        .http
        .get(format!("{}/Items/{item}/Images/Primary", jf.base))
        .query(&[("maxHeight", "400"), ("quality", "85")])
        .header(header::AUTHORIZATION, jf.auth_header())
        .send()
        .await
        .map_err(|e| ApiError::BadGateway(e.to_string()))?;
    if !res.status().is_success() {
        return Err(ApiError::NotFound);
    }
    let ct = res.headers().get(header::CONTENT_TYPE).cloned();
    let mut headers = HeaderMap::new();
    if let Some(ct) = ct {
        headers.insert(header::CONTENT_TYPE, ct);
    }
    headers.insert(header::CACHE_CONTROL, "private, max-age=86400".parse().unwrap());
    let body = res.bytes().await.map_err(|e| ApiError::BadGateway(e.to_string()))?;
    Ok((StatusCode::OK, headers, Body::from(body)).into_response())
}

// ---------------------------------------------------------------- source management

pub async fn list_sources(State(state): State<AppState>, _user: CurrentUser) -> ApiResult<Json<Value>> {
    with_db(&state.db, |c| {
        let mut stmt = c.prepare("SELECT id, kind, name, url, created_at FROM source ORDER BY name")?;
        let rows = stmt
            .query_map([], |r| {
                Ok(json!({ "id": r.get::<_, i64>(0)?, "kind": r.get::<_, String>(1)?, "name": r.get::<_, String>(2)?,
                           "url": r.get::<_, String>(3)?, "created_at": r.get::<_, String>(4)? }))
            })?
            .collect::<Result<Vec<_>, _>>()?;
        Ok(Json(Value::Array(rows)))
    })
    .await
}

#[derive(Deserialize)]
pub struct NewSource {
    kind: String,
    name: String,
    url: String,
    api_key: String,
}

pub async fn add_source(State(state): State<AppState>, _user: CurrentUser, Json(req): Json<NewSource>) -> ApiResult<Json<Value>> {
    if req.kind != "jellyfin" {
        return Err(ApiError::BadRequest("supported kinds: jellyfin".into()));
    }
    let mut url = req.url.trim().trim_end_matches('/').to_string();
    // A bare host name means HTTPS.
    if !url.contains("://") {
        url = format!("https://{url}");
    }
    if !(url.starts_with("https://") || url.starts_with("http://")) {
        return Err(ApiError::BadRequest("url must be http(s)".into()));
    }
    let name = req.name.trim().to_string();
    if name.is_empty() || name.len() > 80 {
        return Err(ApiError::BadRequest("name required (max. 80)".into()));
    }
    // Check the connection and the key before storing anything.
    let probe = Jellyfin { source_id: 0, base: url.clone(), key: req.api_key.trim().to_string() };
    let info = probe.get(&state.http, "/System/Info", &[]).await?;
    let key = probe.key.clone();
    let id = with_db(&state.db, move |c| {
        c.execute("INSERT INTO source (kind, name, url, secret) VALUES ('jellyfin', ?1, ?2, ?3)", (&name, &url, &key))?;
        Ok(c.last_insert_rowid())
    })
    .await?;
    Ok(Json(json!({ "id": id, "server": info["ServerName"], "version": info["Version"] })))
}

pub async fn delete_source(State(state): State<AppState>, _user: CurrentUser, Path(id): Path<i64>) -> ApiResult<Json<Value>> {
    with_db(&state.db, move |c| {
        if c.execute("DELETE FROM source WHERE id = ?1", [id])? == 0 {
            return Err(ApiError::NotFound);
        }
        Ok(())
    })
    .await?;
    state.jellyfin_users.lock().unwrap().remove(&id);
    Ok(Json(json!({ "ok": true })))
}
