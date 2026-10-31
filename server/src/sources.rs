//! Media sources (Jellyfin, Audiobookshelf): management, browsing and cover images.
//! The source's credentials stay on the server.

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
    audiobookshelf,
    auth::CurrentUser,
    error::{with_db, ApiError, ApiResult},
    jellyfin, AppState,
};

const KINDS: &[&str] = &["jellyfin", "audiobookshelf"];

#[derive(Deserialize, Default)]
pub struct Browse {
    pub parent: Option<String>,
    pub search: Option<String>,
    pub start: Option<u32>,
    pub limit: Option<u32>,
}

pub async fn kind(state: &AppState, id: i64) -> ApiResult<String> {
    with_db(&state.db, move |c| Ok(c.query_row("SELECT kind FROM source WHERE id = ?1", [id], |r| r.get(0))?)).await
}

pub async fn browse(
    State(state): State<AppState>,
    _user: CurrentUser,
    Path(id): Path<i64>,
    Query(q): Query<Browse>,
) -> ApiResult<Json<Value>> {
    match kind(&state, id).await?.as_str() {
        "jellyfin" => jellyfin::browse(&state, id, &q).await.map(Json),
        "audiobookshelf" => audiobookshelf::browse(&state, id, &q).await.map(Json),
        _ => Err(ApiError::NotFound),
    }
}

/// `/api/v1/image/{key}` for `jellyfin:<src>:<item>` and `abs:<src>:<item>`.
pub async fn image(State(state): State<AppState>, _user: CurrentUser, Path(key): Path<String>) -> ApiResult<Response> {
    let mut parts = key.splitn(3, ':');
    let (Some(k), Some(src), Some(item)) = (parts.next(), parts.next(), parts.next()) else {
        return Err(ApiError::NotFound);
    };
    let src: i64 = src.parse().map_err(|_| ApiError::NotFound)?;
    match k {
        "jellyfin" => jellyfin::image(&state, src, item).await,
        "abs" => audiobookshelf::image(&state, src, item).await,
        _ => Err(ApiError::NotFound),
    }
}

pub async fn relay_image(req: reqwest::RequestBuilder) -> ApiResult<Response> {
    let res = req.send().await.map_err(|e| ApiError::BadGateway(e.without_url().to_string()))?;
    if !res.status().is_success() {
        return Err(ApiError::NotFound);
    }
    let mut headers = HeaderMap::new();
    if let Some(ct) = res.headers().get(header::CONTENT_TYPE).cloned() {
        headers.insert(header::CONTENT_TYPE, ct);
    }
    headers.insert(header::CACHE_CONTROL, "private, max-age=86400".parse().unwrap());
    let body = res.bytes().await.map_err(|e| ApiError::BadGateway(e.without_url().to_string()))?;
    Ok((StatusCode::OK, headers, Body::from(body)).into_response())
}

// ---------------------------------------------------------------- management

pub async fn list(State(state): State<AppState>, _user: CurrentUser) -> ApiResult<Json<Value>> {
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

pub async fn add(State(state): State<AppState>, user: CurrentUser, Json(req): Json<NewSource>) -> ApiResult<Json<Value>> {
    if !KINDS.contains(&req.kind.as_str()) {
        return Err(ApiError::BadRequest(format!("supported kinds: {}", KINDS.join(", "))));
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
    let key = req.api_key.trim().to_string();
    // Check the connection and the key before storing anything.
    let info = match req.kind.as_str() {
        "jellyfin" => jellyfin::check(&state, &url, &key).await?,
        _ => audiobookshelf::check(&state, &url, &key).await?,
    };
    let kind = req.kind.clone();
    let id = with_db(&state.db, move |c| {
        c.execute(
            "INSERT INTO source (kind, name, url, secret, owner_user_id) VALUES (?1, ?2, ?3, ?4, ?5)",
            (&kind, &name, &url, &key, user.id),
        )?;
        Ok(c.last_insert_rowid())
    })
    .await?;
    if req.kind == "audiobookshelf" {
        // Take over the existing listening progress right away.
        let st = state.clone();
        tokio::spawn(async move { audiobookshelf::sync_source(&st, id).await });
    }
    let mut out = info;
    out["id"] = json!(id);
    Ok(Json(out))
}

pub async fn delete(State(state): State<AppState>, _user: CurrentUser, Path(id): Path<i64>) -> ApiResult<Json<Value>> {
    with_db(&state.db, move |c| {
        let kind: String = c.query_row("SELECT kind FROM source WHERE id = ?1", [id], |r| r.get(0))?;
        c.execute("DELETE FROM source WHERE id = ?1", [id])?;
        // Positions of its items can no longer be played.
        let prefix = format!("{}:{id}:", if kind == "audiobookshelf" { "abs" } else { kind.as_str() });
        c.execute("DELETE FROM playback WHERE item_key LIKE ?1 || '%'", [prefix])?;
        Ok(())
    })
    .await?;
    state.jellyfin_users.lock().unwrap().remove(&id);
    Ok(Json(json!({ "ok": true })))
}
