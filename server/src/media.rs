//! Items across sources: metadata with audio quality and the stream endpoint.
//!
//! Item keys: `episode:<id>` (podcast episode) and `jellyfin:<source>:<item>`.
//! `GET /api/v1/stream/{key}?profile=…` relays the original (Range passed through) or, if
//! the profile requires it, converts on the fly with ffmpeg – nothing is stored.
//! Profiles: `original` (default) and `tesla-offline` (hi-res FLAC → FLAC 48 kHz, because
//! the in-car browser cannot play cached 24/96 FLAC).
//! The response header `x-audiojoe-quality` describes source and delivered format.

use axum::{
    body::Body,
    extract::{Path, Query, State},
    http::{header, HeaderMap, HeaderValue, StatusCode},
    response::{IntoResponse, Response},
    Json,
};
use futures_util::StreamExt;
use serde::Deserialize;
use serde_json::{json, Value};

use crate::{
    auth::CurrentUser,
    error::{with_db, ApiError, ApiResult},
    audiobookshelf, jellyfin, plex, podcasts, radio, AppState,
};

enum Key {
    Episode(i64),
    Jellyfin(i64, String),
    Abs(i64, String),
    Radio(String),
    Plex(i64, String),
}

fn parse_key(key: &str) -> ApiResult<Key> {
    let mut p = key.splitn(3, ':');
    match (p.next(), p.next(), p.next()) {
        (Some("episode"), Some(id), None) => id.parse().map(Key::Episode).map_err(|_| ApiError::NotFound),
        (Some("jellyfin" | "emby"), Some(src), Some(item)) if jellyfin::valid_id(item) => {
            Ok(Key::Jellyfin(src.parse().map_err(|_| ApiError::NotFound)?, item.to_string()))
        }
        (Some("radio"), Some(uuid), None) if radio::valid_uuid(uuid) => Ok(Key::Radio(uuid.to_string())),
        (Some("plex"), Some(src), Some(item)) if plex::valid_id(item) => {
            Ok(Key::Plex(src.parse().map_err(|_| ApiError::NotFound)?, item.to_string()))
        }
        (Some("abs"), Some(src), Some(item)) if audiobookshelf::valid_id(item) => {
            Ok(Key::Abs(src.parse().map_err(|_| ApiError::NotFound)?, item.to_string()))
        }
        _ => Err(ApiError::NotFound),
    }
}

fn codec_from_mime(mime: &str) -> &'static str {
    match mime.split(';').next().unwrap_or("").trim() {
        "audio/mpeg" | "audio/mp3" => "mp3",
        "audio/mp4" | "audio/x-m4a" | "audio/aac" | "audio/m4a" => "aac",
        "audio/ogg" | "audio/opus" => "opus",
        "audio/flac" | "audio/x-flac" => "flac",
        _ => "",
    }
}

struct Resolved {
    url: String,
    /// Header with the source's credentials for the upstream request.
    auth: Option<(header::HeaderName, String)>,
    meta: Value,
}

/// `part`: index of the audio file for items consisting of several files (books).
async fn resolve(state: &AppState, user: &CurrentUser, key: &str, part: usize) -> ApiResult<Resolved> {
    match parse_key(key)? {
        Key::Episode(id) => {
            let uid = user.id;
            let (url, mime, size, duration, title, podcast) =
                with_db(&state.db, move |c| podcasts::episode_source(c, uid, id)).await?;
            let bitrate = match (size, duration) {
                (Some(s), Some(d)) if d > 0 => Some(s * 8 / d),
                _ => None,
            };
            Ok(Resolved {
                url,
                auth: None,
                meta: json!({
                    "key": key, "kind": "episode", "title": title, "subtitle": podcast,
                    "duration_ms": duration.map(|d| d * 1000),
                    "quality": { "codec": codec_from_mime(&mime), "bitrate": bitrate, "size": size,
                                 "sample_rate": null, "bit_depth": null, "channels": null },
                }),
            })
        }
        Key::Jellyfin(src, item) => {
            let jf = jellyfin::source(state, src).await?;
            let meta = jf.item(state, &item).await?;
            Ok(Resolved { url: jf.stream_url(&item), auth: Some(jf.auth()), meta })
        }
        Key::Plex(src, item) => {
            let p = plex::source(state, src).await?;
            let (meta, url) = p.track(state, &item).await?;
            Ok(Resolved { url, auth: Some(p.auth()), meta })
        }
        Key::Radio(uuid) => {
            let (url, meta) = radio::resolve(state, user.id, &uuid).await?;
            Ok(Resolved { url, auth: None, meta })
        }
        Key::Abs(src, item) => {
            let abs = audiobookshelf::source(state, src).await?;
            let (meta, parts) = audiobookshelf::item(state, &abs, &item).await?;
            let url = parts.get(part).map(|p| p.url.clone()).ok_or(ApiError::NotFound)?;
            Ok(Resolved { url, auth: Some((header::AUTHORIZATION, abs.auth_header())), meta })
        }
    }
}

pub async fn item(State(state): State<AppState>, user: CurrentUser, Path(key): Path<String>) -> ApiResult<Json<Value>> {
    let mut meta = resolve(&state, &user, &key, 0).await?.meta;
    // Fresh listening progress from Audiobookshelf before answering.
    if let Ok(Key::Abs(src, item)) = parse_key(&key) {
        if let Ok(abs) = audiobookshelf::source(&state, src).await {
            audiobookshelf::sync_item(&state, &abs, &item).await;
        }
    }
    let (uid, k) = (user.id, key.clone());
    meta["playback"] = with_db(&state.db, move |c| {
        Ok(c.query_row(
            "SELECT position_ms, finished, device, updated_at FROM playback WHERE user_id = ?1 AND item_key = ?2",
            (uid, k),
            |r| Ok(json!({ "position_ms": r.get::<_, i64>(0)?, "finished": r.get::<_, bool>(1)?,
                            "device": r.get::<_, String>(2)?, "updated_at": r.get::<_, String>(3)? })),
        )
        .unwrap_or(Value::Null))
    })
    .await?;
    Ok(Json(meta))
}

#[derive(Deserialize)]
pub struct StreamQuery {
    profile: Option<String>,
    part: Option<usize>,
}

pub async fn stream(
    State(state): State<AppState>,
    user: CurrentUser,
    Path(key): Path<String>,
    Query(q): Query<StreamQuery>,
    headers: HeaderMap,
) -> ApiResult<Response> {
    stream_for(&state, &user, &key, q.part.unwrap_or(0), q.profile.as_deref().unwrap_or("original"), 0, &headers).await
}

/// Metadata of an item (used by Sonos).
pub async fn meta_for(state: &AppState, user: &CurrentUser, key: &str) -> ApiResult<Value> {
    Ok(resolve(state, user, key, 0).await?.meta)
}

/// Stream of an item for a client profile: `original`, `tesla-offline` (hi-res FLAC → 48 kHz),
/// `sonos-s2` (≤ 48 kHz) or `sonos-s1` (≤ 16 bit / 48 kHz). `start_ms` only applies to a
/// conversion (a converted stream cannot be seeked; the original keeps Range requests).
pub async fn stream_for(state: &AppState, user: &CurrentUser, key: &str, part: usize, profile: &str, start_ms: i64, headers: &HeaderMap) -> ApiResult<Response> {
    let r = resolve(state, user, key, part).await?;
    let src = r.meta["quality"].clone();

    // Live radio cannot be saved offline.
    if profile == "tesla-offline" && key.starts_with("radio:") {
        return Err(ApiError::BadRequest("live streams cannot be saved offline".into()));
    }
    if let Some((rate, depth)) = conversion(&src, profile)? {
        return transcode_flac(&r, src, rate, depth, start_ms);
    }
    let extra: Vec<(header::HeaderName, String)> = r.auth.iter().cloned().collect();
    let mut res = crate::stream::relay(&state.http, &r.url, headers, &extra).await;
    set_quality(&mut res, json!({ "source": src, "delivered": src, "transcoded": false }));
    Ok(res)
}

/// Target sample rate and bit depth when the profile requires converting the source.
pub fn conversion(src: &Value, profile: &str) -> ApiResult<Option<(i64, i64)>> {
    let codec = src["codec"].as_str().unwrap_or("");
    let lossless = matches!(codec, "flac" | "alac") || codec.starts_with("pcm_");
    let rate = src["sample_rate"].as_i64().unwrap_or(0);
    let depth = src["bit_depth"].as_i64().unwrap_or(16);
    Ok(match profile {
        "tesla-offline" | "sonos-s2" if codec == "flac" && rate > 48_000 => Some((48_000, depth.min(24))),
        "sonos-s1" if lossless && (rate > 48_000 || depth > 16) => Some((rate.clamp(1, 48_000), 16)),
        "original" | "tesla-offline" | "sonos-s2" | "sonos-s1" => None,
        _ => return Err(ApiError::BadRequest("profile: original | tesla-offline | sonos-s2 | sonos-s1".into())),
    })
}

fn set_quality(res: &mut Response, q: Value) {
    if let Ok(v) = HeaderValue::from_str(&q.to_string()) {
        res.headers_mut().insert("x-audiojoe-quality", v);
    }
}

/// Lossless source → FLAC with the given sample rate and bit depth, converted while streaming.
fn transcode_flac(r: &Resolved, src: Value, rate: i64, depth: i64, start_ms: i64) -> ApiResult<Response> {
    let mut cmd = tokio::process::Command::new("ffmpeg");
    cmd.args(["-nostdin", "-hide_banner", "-loglevel", "error"]);
    if let Some((name, value)) = &r.auth {
        cmd.arg("-headers").arg(format!("{name}: {value}\r\n"));
    }
    if start_ms > 0 {
        cmd.arg("-ss").arg(format!("{}.{:03}", start_ms / 1000, start_ms % 1000));
    }
    cmd.arg("-i").arg(&r.url);
    cmd.args(["-map", "0:a:0", "-map_metadata", "-1", "-c:a", "flac", "-ar", &rate.to_string()]);
    cmd.args(["-sample_fmt", if depth > 16 { "s32" } else { "s16" }]);
    if depth > 16 {
        cmd.args(["-bits_per_raw_sample", "24"]);
    }
    cmd.args(["-f", "flac", "pipe:1"]);
    cmd.stdout(std::process::Stdio::piped()).stderr(std::process::Stdio::null()).kill_on_drop(true);
    let mut child = cmd.spawn().map_err(|e| ApiError::Internal(anyhow::anyhow!("cannot start ffmpeg: {e}")))?;
    let stdout = child.stdout.take().ok_or_else(|| ApiError::Internal(anyhow::anyhow!("no ffmpeg stdout")))?;
    // The stream owns the child: when the client goes away, ffmpeg is killed.
    let body = tokio_util::io::ReaderStream::new(stdout).map(move |chunk| {
        let _keep = &child;
        chunk
    });
    let mut delivered = src.clone();
    delivered["codec"] = json!("flac");
    delivered["sample_rate"] = json!(rate);
    delivered["bit_depth"] = json!(depth);
    delivered["bitrate"] = Value::Null;
    delivered["size"] = Value::Null;
    let mut res = Response::builder()
        .status(StatusCode::OK)
        .header(header::CONTENT_TYPE, "audio/flac")
        .header(header::CACHE_CONTROL, "no-store")
        .body(Body::from_stream(body))
        .map_err(|e| ApiError::Internal(e.into()))?;
    set_quality(&mut res, json!({ "source": src, "delivered": delivered, "transcoded": true }));
    Ok(res.into_response())
}
