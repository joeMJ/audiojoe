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
    jellyfin, podcasts, AppState,
};

enum Key {
    Episode(i64),
    Jellyfin(i64, String),
}

fn parse_key(key: &str) -> ApiResult<Key> {
    let mut p = key.splitn(3, ':');
    match (p.next(), p.next(), p.next()) {
        (Some("episode"), Some(id), None) => id.parse().map(Key::Episode).map_err(|_| ApiError::NotFound),
        (Some("jellyfin"), Some(src), Some(item))
            if item.len() <= 64 && item.chars().all(|c| c.is_ascii_alphanumeric() || c == '-') =>
        {
            Ok(Key::Jellyfin(src.parse().map_err(|_| ApiError::NotFound)?, item.to_string()))
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
    auth: Option<String>,
    meta: Value,
}

async fn resolve(state: &AppState, user: &CurrentUser, key: &str) -> ApiResult<Resolved> {
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
            Ok(Resolved { url: jf.stream_url(&item), auth: Some(jf.auth_header()), meta })
        }
    }
}

pub async fn item(State(state): State<AppState>, user: CurrentUser, Path(key): Path<String>) -> ApiResult<Json<Value>> {
    let mut meta = resolve(&state, &user, &key).await?.meta;
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
}

pub async fn stream(
    State(state): State<AppState>,
    user: CurrentUser,
    Path(key): Path<String>,
    Query(q): Query<StreamQuery>,
    headers: HeaderMap,
) -> ApiResult<Response> {
    let r = resolve(&state, &user, &key).await?;
    let src = r.meta["quality"].clone();
    let profile = q.profile.as_deref().unwrap_or("original");
    let hires_flac = src["codec"] == "flac" && src["sample_rate"].as_i64().unwrap_or(0) > 48_000;

    match profile {
        "original" => {}
        "tesla-offline" if hires_flac => return transcode_flac48(&r, src),
        "tesla-offline" => {}
        _ => return Err(ApiError::BadRequest("profile: original | tesla-offline".into())),
    }
    let extra: Vec<(header::HeaderName, String)> = r.auth.iter().map(|a| (header::AUTHORIZATION, a.clone())).collect();
    let mut res = crate::stream::relay(&state.http, &r.url, &headers, &extra).await;
    set_quality(&mut res, json!({ "source": src, "delivered": src, "transcoded": false }));
    Ok(res)
}

fn set_quality(res: &mut Response, q: Value) {
    if let Ok(v) = HeaderValue::from_str(&q.to_string()) {
        res.headers_mut().insert("x-audiojoe-quality", v);
    }
}

/// Hi-res FLAC → FLAC 48 kHz with the original bit depth, converted while streaming.
fn transcode_flac48(r: &Resolved, src: Value) -> ApiResult<Response> {
    let depth = src["bit_depth"].as_i64().unwrap_or(24);
    let mut cmd = tokio::process::Command::new("ffmpeg");
    cmd.args(["-nostdin", "-hide_banner", "-loglevel", "error"]);
    if let Some(a) = &r.auth {
        cmd.arg("-headers").arg(format!("Authorization: {a}\r\n"));
    }
    cmd.arg("-i").arg(&r.url);
    cmd.args(["-map", "0:a:0", "-map_metadata", "-1", "-c:a", "flac", "-ar", "48000"]);
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
    delivered["sample_rate"] = json!(48_000);
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
