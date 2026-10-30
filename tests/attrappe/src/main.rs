//! attrappe – fake media source for tests.
//!
//! Generates test tones with ffmpeg at start-up and serves them at `/media/{file}` with
//! Range support. Faults are selected per request through query parameters:
//!
//! | Parameter       | Effect                                                        |
//! |-----------------|---------------------------------------------------------------|
//! | `abort_after=N` | drop the connection after N body bytes                        |
//! | `stall_at=N`    | pause after N body bytes for `stall_ms` milliseconds          |
//! | `rate=B`        | throttle to B bytes per second                                |
//! | `lie_length=1`  | announce 4096 more bytes than are sent, then end the body     |
//! | `no_range=1`    | ignore Range headers and always send the whole file (200)     |
//! | `fail_first=N`  | answer the first N requests of this URL with 503              |
//!
//! Every response carries `x-content-sha256` with the checksum of the complete file.
//!
//!   attrappe [--listen 127.0.0.1:8090] [--dir /var/lib/attrappe]

use std::{
    collections::HashMap,
    path::PathBuf,
    process::Command,
    sync::{Arc, Mutex},
    time::Duration,
};

use anyhow::{ensure, Context, Result};
use axum::{
    body::Body,
    extract::{Path, Query, State},
    http::{header, HeaderMap, StatusCode},
    response::{IntoResponse, Response},
    routing::get,
    Json, Router,
};
use bytes::Bytes;
use serde::Deserialize;
use sha2::{Digest, Sha256};

/// (file name, content type, ffmpeg output arguments)
const FILES: &[(&str, &str, &[&str])] = &[
    ("flac16_44.flac", "audio/flac", &["-ar", "44100", "-sample_fmt", "s16", "-c:a", "flac"]),
    ("flac24_96.flac", "audio/flac", &["-ar", "96000", "-sample_fmt", "s32", "-bits_per_raw_sample", "24", "-c:a", "flac"]),
    ("aac.m4a", "audio/mp4", &["-ar", "44100", "-c:a", "aac", "-b:a", "256k"]),
    ("mp3.mp3", "audio/mpeg", &["-ar", "44100", "-c:a", "libmp3lame", "-b:a", "128k"]),
];
const SECONDS: &str = "30";
const CHUNK: usize = 16 * 1024;

struct Media {
    data: Bytes,
    content_type: &'static str,
    sha256: String,
}

#[derive(Clone)]
struct AppState {
    media: Arc<HashMap<&'static str, Media>>,
    /// Request counter per URL for `fail_first`.
    hits: Arc<Mutex<HashMap<String, u32>>>,
}

#[derive(Deserialize, Default)]
struct Faults {
    abort_after: Option<usize>,
    stall_at: Option<usize>,
    stall_ms: Option<u64>,
    rate: Option<usize>,
    lie_length: Option<u8>,
    no_range: Option<u8>,
    fail_first: Option<u32>,
}

#[tokio::main]
async fn main() -> Result<()> {
    let args: Vec<String> = std::env::args().collect();
    let arg = |name: &str, default: &str| {
        args.iter()
            .position(|a| a == name)
            .and_then(|i| args.get(i + 1).cloned())
            .unwrap_or_else(|| default.to_string())
    };
    let listen = arg("--listen", "127.0.0.1:8090");
    let dir = PathBuf::from(arg("--dir", "/var/lib/attrappe"));
    std::fs::create_dir_all(&dir).with_context(|| format!("cannot create {}", dir.display()))?;

    let mut media = HashMap::new();
    for (name, content_type, codec) in FILES {
        let path = dir.join(name);
        if !path.exists() {
            // Stereo test tone: 440 Hz left, 660 Hz right, so channel swaps are audible.
            let status = Command::new("ffmpeg")
                .args(["-hide_banner", "-loglevel", "error", "-y", "-f", "lavfi", "-i"])
                .arg(format!("sine=frequency=440:duration={SECONDS}"))
                .args(["-f", "lavfi", "-i"])
                .arg(format!("sine=frequency=660:duration={SECONDS}"))
                .args(["-filter_complex", "[0:a][1:a]amerge=inputs=2[a]", "-map", "[a]"])
                .args(*codec)
                .arg(&path)
                .status()
                .context("cannot run ffmpeg")?;
            ensure!(status.success(), "ffmpeg failed for {name}");
        }
        let data = Bytes::from(std::fs::read(&path)?);
        let sha256 = format!("{:x}", Sha256::digest(&data));
        media.insert(*name, Media { data, content_type, sha256 });
    }

    let state = AppState { media: Arc::new(media), hits: Default::default() };
    let app = Router::new()
        .route("/media", get(index))
        .route("/media/{file}", get(serve))
        .with_state(state);
    let listener = tokio::net::TcpListener::bind(&listen).await?;
    eprintln!("attrappe listening on {listen}, media in {}", dir.display());
    axum::serve(listener, app).await?;
    Ok(())
}

async fn index(State(state): State<AppState>) -> Json<serde_json::Value> {
    let list: Vec<_> = FILES
        .iter()
        .map(|(name, ..)| {
            let m = &state.media[name];
            serde_json::json!({ "name": name, "type": m.content_type, "size": m.data.len(), "sha256": m.sha256 })
        })
        .collect();
    Json(serde_json::Value::Array(list))
}

async fn serve(
    State(state): State<AppState>,
    Path(file): Path<String>,
    Query(f): Query<Faults>,
    headers: HeaderMap,
    uri: axum::http::Uri,
) -> Response {
    let Some(m) = state.media.get(file.as_str()) else {
        return StatusCode::NOT_FOUND.into_response();
    };
    if let Some(n) = f.fail_first {
        let mut hits = state.hits.lock().unwrap();
        let count = hits.entry(uri.to_string()).or_default();
        *count += 1;
        if *count <= n {
            return StatusCode::SERVICE_UNAVAILABLE.into_response();
        }
    }

    let total = m.data.len();
    let range = if f.no_range == Some(1) { None } else { parse_range(&headers, total) };
    let (status, start, end) = match range {
        Some(Ok((s, e))) => (StatusCode::PARTIAL_CONTENT, s, e),
        Some(Err(())) => {
            return Response::builder()
                .status(StatusCode::RANGE_NOT_SATISFIABLE)
                .header(header::CONTENT_RANGE, format!("bytes */{total}"))
                .body(Body::empty())
                .unwrap();
        }
        None => (StatusCode::OK, 0, total - 1),
    };
    let body = m.data.slice(start..=end);
    let announced = body.len() + if f.lie_length == Some(1) { 4096 } else { 0 };

    let mut b = Response::builder()
        .status(status)
        .header(header::CONTENT_TYPE, m.content_type)
        .header(header::CONTENT_LENGTH, announced)
        .header(header::ETAG, format!("\"{}\"", &m.sha256[..16]))
        .header("x-content-sha256", &m.sha256);
    if f.no_range != Some(1) {
        b = b.header(header::ACCEPT_RANGES, "bytes");
    }
    if status == StatusCode::PARTIAL_CONTENT {
        b = b.header(header::CONTENT_RANGE, format!("bytes {start}-{end}/{total}"));
    }
    b.body(Body::from_stream(faulty_stream(body, f))).unwrap()
}

/// Parses a single `bytes=a-b`, `bytes=a-` or `bytes=-n` range.
fn parse_range(headers: &HeaderMap, total: usize) -> Option<Result<(usize, usize), ()>> {
    let v = headers.get(header::RANGE)?.to_str().ok()?;
    let spec = v.strip_prefix("bytes=")?;
    let (a, b) = spec.split_once('-')?;
    let r = match (a.trim(), b.trim()) {
        ("", n) => n.parse::<usize>().ok().filter(|&n| n > 0).map(|n| (total.saturating_sub(n), total - 1)),
        (s, "") => s.parse::<usize>().ok().map(|s| (s, total - 1)),
        (s, e) => match (s.parse::<usize>(), e.parse::<usize>()) {
            (Ok(s), Ok(e)) if s <= e => Some((s, e.min(total - 1))),
            _ => None,
        },
    };
    Some(r.filter(|&(s, _)| s < total).ok_or(()))
}

fn faulty_stream(
    body: Bytes,
    f: Faults,
) -> impl futures_util::Stream<Item = Result<Bytes, std::io::Error>> {
    let rate = f.rate.filter(|&r| r > 0);
    futures_util::stream::unfold((0usize, false), move |(sent, stalled)| {
        let body = body.clone();
        async move {
            if sent >= body.len() {
                if f.lie_length == Some(1) && sent != usize::MAX {
                    // The announced length is larger: after the real bytes are flushed the
                    // connection ends early, as with a real server that miscounted.
                    tokio::time::sleep(Duration::from_millis(300)).await;
                    return Some((Err(std::io::Error::other("attrappe: lie_length")), (usize::MAX, stalled)));
                }
                return None;
            }
            if let Some(limit) = f.abort_after {
                if sent >= limit {
                    // Give hyper time to flush the bytes already produced; otherwise the
                    // abort discards them together with the buffer.
                    tokio::time::sleep(Duration::from_millis(300)).await;
                    return Some((Err(std::io::Error::other("attrappe: abort_after")), (usize::MAX, stalled)));
                }
            }
            let mut stalled = stalled;
            if let (Some(at), false) = (f.stall_at, stalled) {
                if sent >= at {
                    tokio::time::sleep(Duration::from_millis(f.stall_ms.unwrap_or(5000))).await;
                    stalled = true;
                }
            }
            let mut n = CHUNK.min(body.len() - sent);
            if let Some(limit) = f.abort_after {
                n = n.min(limit - sent);
            }
            if let Some(at) = f.stall_at.filter(|&at| !stalled && at > sent) {
                n = n.min(at - sent);
            }
            if let Some(r) = rate {
                tokio::time::sleep(Duration::from_secs_f64(n as f64 / r as f64)).await;
            }
            Some((Ok(body.slice(sent..sent + n)), (sent + n, stalled)))
        }
    })
}
