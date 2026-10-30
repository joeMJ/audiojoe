//! Stage 0: browser capability probe for the Tesla in-car browser.
//! The probe page streams test media through the server and reports its measurements.

use axum::{
    extract::{Path, Query, State},
    http::{header, HeaderMap, StatusCode},
    response::{IntoResponse, Response},
    Json,
};
use serde::Deserialize;
use sha2::{Digest, Sha256};

use crate::AppState;

/// Fault parameters understood by the test source; only these are passed upstream.
const FAULT_PARAMS: &[&str] = &["abort_after", "stall_at", "stall_ms", "rate", "lie_length", "no_range", "fail_first"];

#[derive(Deserialize)]
pub struct TokenQuery {
    t: Option<String>,
}

fn token_ok(state: &AppState, t: &Option<String>) -> bool {
    let (Some(cfg), Some(t)) = (&state.config.probe, t) else { return false };
    // Compare digests so the comparison time does not depend on the token content.
    Sha256::digest(cfg.token.as_bytes()) == Sha256::digest(t.as_bytes())
}

/// Keeps the table small: submitting needs no token (so nothing has to be typed in the
/// car), therefore only the newest rows are kept. Reading the results needs the token.
const MAX_ROWS: i64 = 500;

pub async fn submit(
    State(state): State<AppState>,
    headers: HeaderMap,
    Json(report): Json<serde_json::Value>,
) -> StatusCode {
    if state.config.probe.is_none() {
        return StatusCode::NOT_FOUND;
    }
    let ua = headers
        .get(header::USER_AGENT)
        .and_then(|v| v.to_str().ok())
        .unwrap_or("")
        .chars()
        .take(512)
        .collect::<String>();
    let db = state.db.clone();
    let res = tokio::task::spawn_blocking(move || {
        let conn = db.lock().unwrap();
        conn.execute(
            "INSERT INTO probe_result (user_agent, report) VALUES (?1, ?2)",
            (ua, report.to_string()),
        )?;
        conn.execute(
            "DELETE FROM probe_result WHERE id <= (SELECT MAX(id) FROM probe_result) - ?1",
            [MAX_ROWS],
        )
    })
    .await;
    match res {
        Ok(Ok(_)) => StatusCode::NO_CONTENT,
        _ => StatusCode::INTERNAL_SERVER_ERROR,
    }
}

pub async fn list(State(state): State<AppState>, Query(q): Query<TokenQuery>) -> Response {
    if !token_ok(&state, &q.t) {
        return StatusCode::FORBIDDEN.into_response();
    }
    let db = state.db.clone();
    let rows = tokio::task::spawn_blocking(move || -> rusqlite::Result<Vec<serde_json::Value>> {
        let conn = db.lock().unwrap();
        let mut stmt = conn.prepare(
            "SELECT id, received_at, user_agent, report FROM probe_result ORDER BY id DESC LIMIT 50",
        )?;
        let rows = stmt.query_map([], |r| {
            let report: String = r.get(3)?;
            Ok(serde_json::json!({
                "id": r.get::<_, i64>(0)?,
                "received_at": r.get::<_, String>(1)?,
                "user_agent": r.get::<_, String>(2)?,
                "report": serde_json::from_str::<serde_json::Value>(&report).unwrap_or_default(),
            }))
        })?;
        rows.collect()
    })
    .await;
    match rows {
        Ok(Ok(rows)) => Json(rows).into_response(),
        _ => StatusCode::INTERNAL_SERVER_ERROR.into_response(),
    }
}

/// Relays a test file from the configured test source. File names are restricted so the
/// endpoint cannot be used to reach anything else on the upstream host.
pub async fn stream(
    State(state): State<AppState>,
    Path(file): Path<String>,
    Query(params): Query<Vec<(String, String)>>,
    headers: HeaderMap,
) -> Response {
    let Some(cfg) = &state.config.probe else { return StatusCode::NOT_FOUND.into_response() };
    let valid = !file.is_empty()
        && file.len() <= 64
        && file.chars().all(|c| c.is_ascii_alphanumeric() || c == '_' || c == '.')
        && !file.starts_with('.');
    if !valid {
        return StatusCode::NOT_FOUND.into_response();
    }
    let query: Vec<String> = params
        .iter()
        .filter(|(k, v)| FAULT_PARAMS.contains(&k.as_str()) && v.chars().all(|c| c.is_ascii_digit()))
        .map(|(k, v)| format!("{k}={v}"))
        .collect();
    let mut url = format!("{}/media/{file}", cfg.upstream.trim_end_matches('/'));
    if !query.is_empty() {
        url.push('?');
        url.push_str(&query.join("&"));
    }
    crate::stream::relay(&state.http, &url, &headers).await
}
