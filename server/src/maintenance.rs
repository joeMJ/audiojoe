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

use std::path::PathBuf;

use axum::{extract::State, Json};
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

pub async fn status(State(state): State<AppState>, _user: CurrentUser) -> Json<Value> {
    let d = dir(&state);
    let status = std::fs::read_to_string(d.join("update-status.json"))
        .ok()
        .and_then(|s| serde_json::from_str::<Value>(&s).ok());
    Json(json!({
        "version": VERSION,
        "mode": mode(&state),
        // Without the script (development, other installation) there is no status.
        "managed": status.is_some(),
        "status": status,
        "requested": d.join("update-request").exists(),
    }))
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
