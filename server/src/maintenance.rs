//! Maintenance overview: server updates and Debian updates of the machine.
//!
//! The work is done by `audiojoe-update` (root, packaging/deb), started nightly by a timer and
//! on request by a path unit. It talks to the server only through three files in the state
//! directory (next to the database):
//!
//! - `update-status.json` – written by the script: last check, installed and newest version,
//!   result of the last update, Debian updates, database backups. Shown as it is.
//! - `update-mode` – written here: `auto` (install at night) or `notify` (only report).
//! - `update-request` – written here: "install now"; the path unit starts the script.
//!
//! App updates: the script keeps the newest release (tag, page, files) in the status; from
//! that `apps` names the installer of each platform, and `GET /maintenance/app/{platform}`
//! relays its download – the apps never talk to GitHub themselves.

use std::path::PathBuf;

use axum::{
    body::Body,
    extract::{Path, State},
    http::{header, HeaderValue, StatusCode},
    response::{IntoResponse, Response},
    Json,
};
use serde::Deserialize;
use serde_json::{json, Value};

use crate::{
    auth::CurrentUser,
    error::{ApiError, ApiResult},
    AppState, VERSION,
};

fn dir(state: &AppState) -> PathBuf {
    state.config.database.parent().map(|p| p.to_path_buf()).unwrap_or_else(|| PathBuf::from("."))
}

fn mode(state: &AppState) -> &'static str {
    match std::fs::read_to_string(dir(state).join("update-mode")).as_deref().map(str::trim) {
        Ok("notify") => "notify",
        _ => "auto",
    }
}

fn read_status(state: &AppState) -> Option<Value> {
    std::fs::read_to_string(dir(state).join("update-status.json")).ok().and_then(|s| serde_json::from_str::<Value>(&s).ok())
}

/// The platform an installer file in a release belongs to, by its name
/// (`audiojoe-<v>.apk`, `audiojoe-<v>-windows-x86_64.msi`, `audiojoe_<v>_amd64.deb`; the
/// server's own package is `audiojoe-server_…`).
fn platform_of(name: &str) -> Option<&'static str> {
    if name.ends_with(".apk") {
        Some("android")
    } else if name.ends_with(".msi") {
        Some("windows")
    } else if name.starts_with("audiojoe_") && name.ends_with(".deb") {
        Some("linux")
    } else {
        None
    }
}

/// `{latest, page, android: {name}, windows: {name}, linux: {name}}` from the status; null without it.
fn apps_of(status: Option<&Value>) -> Value {
    let Some(st) = status else { return Value::Null };
    let Some(assets) = st["release"]["assets"].as_array() else { return Value::Null };
    let mut out = json!({ "latest": st["latest"], "page": st["release"]["page"] });
    for a in assets {
        if let (Some(name), Some(p)) = (a["name"].as_str(), a["name"].as_str().and_then(platform_of)) {
            if out[p].is_null() {
                out[p] = json!({ "name": name });
            }
        }
    }
    out
}

fn asset_url(status: Option<&Value>, platform: &str) -> Option<(String, String)> {
    status?["release"]["assets"]
        .as_array()?
        .iter()
        .find(|a| a["name"].as_str().and_then(platform_of) == Some(platform))
        .and_then(|a| Some((a["name"].as_str()?.to_string(), a["url"].as_str()?.to_string())))
}

pub async fn status(State(state): State<AppState>, _user: CurrentUser) -> Json<Value> {
    let d = dir(&state);
    let status = read_status(&state);
    Json(json!({
        "version": VERSION,
        "mode": mode(&state),
        // Without the script (development, other installation) there is no status.
        "managed": status.is_some(),
        "apps": apps_of(status.as_ref()),
        "status": status,
        "requested": d.join("update-request").exists(),
    }))
}

/// `GET /api/v1/maintenance/app/{android|windows|linux}`: the newest installer, relayed from
/// the release so the app itself never contacts the release host.
pub async fn app_download(State(state): State<AppState>, _user: CurrentUser, Path(platform): Path<String>) -> ApiResult<Response> {
    let status = read_status(&state);
    let (name, url) = asset_url(status.as_ref(), &platform).ok_or(ApiError::NotFound)?;
    let res = state
        .http
        .get(&url)
        .header(header::ACCEPT, "application/octet-stream")
        .timeout(std::time::Duration::from_secs(600))
        .send()
        .await
        .map_err(|e| ApiError::BadGateway(format!("release download: {}", e.without_url())))?;
    if !res.status().is_success() {
        return Err(ApiError::BadGateway(format!("release download answered {}", res.status())));
    }
    let mut headers = axum::http::HeaderMap::new();
    let ct = if name.ends_with(".apk") { "application/vnd.android.package-archive" } else { "application/octet-stream" };
    headers.insert(header::CONTENT_TYPE, HeaderValue::from_static(ct));
    if let Some(n) = res.content_length() {
        headers.insert(header::CONTENT_LENGTH, HeaderValue::from(n));
    }
    if let Ok(v) = HeaderValue::from_str(&format!("attachment; filename=\"{name}\"")) {
        headers.insert(header::CONTENT_DISPOSITION, v);
    }
    Ok((StatusCode::OK, headers, Body::from_stream(res.bytes_stream())).into_response())
}

#[derive(Deserialize)]
pub struct SetMode {
    mode: String,
}

pub async fn set_mode(State(state): State<AppState>, _user: CurrentUser, Json(b): Json<SetMode>) -> ApiResult<Json<Value>> {
    if b.mode != "auto" && b.mode != "notify" {
        return Err(ApiError::BadRequest("mode must be auto or notify".into()));
    }
    std::fs::write(dir(&state).join("update-mode"), format!("{}\n", b.mode)).map_err(|e| ApiError::Internal(e.into()))?;
    Ok(Json(json!({ "mode": b.mode })))
}

/// Asks the update script to install the newest version now (also in mode `notify`).
pub async fn request_update(State(state): State<AppState>, _user: CurrentUser) -> ApiResult<Json<Value>> {
    std::fs::write(dir(&state).join("update-request"), b"now\n").map_err(|e| ApiError::Internal(e.into()))?;
    Ok(Json(json!({ "requested": true })))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn apps_from_release_files() {
        let st = json!({ "latest": "0.1.0", "release": { "tag": "v0.1.0", "page": "https://example.org/r/v0.1.0", "assets": [
            { "name": "audiojoe-server_0.1.0_amd64.deb", "url": "u1" }, { "name": "SHA256SUMS", "url": "u2" },
            { "name": "audiojoe-0.1.0.apk", "url": "u3" }, { "name": "audiojoe-0.1.0-windows-x86_64.msi", "url": "u4" },
            { "name": "audiojoe_0.1.0_amd64.deb", "url": "u5" } ] } });
        let apps = apps_of(Some(&st));
        assert_eq!(apps["latest"], "0.1.0");
        assert_eq!(apps["android"]["name"], "audiojoe-0.1.0.apk");
        assert_eq!(apps["windows"]["name"], "audiojoe-0.1.0-windows-x86_64.msi");
        assert_eq!(apps["linux"]["name"], "audiojoe_0.1.0_amd64.deb");
        assert_eq!(asset_url(Some(&st), "android"), Some(("audiojoe-0.1.0.apk".into(), "u3".into())));
        assert_eq!(asset_url(Some(&st), "linux").unwrap().1, "u5");
        assert!(apps_of(Some(&json!({ "latest": "0.1.0" }))).is_null());
        assert!(apps_of(None).is_null());
    }
}
