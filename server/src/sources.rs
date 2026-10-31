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
    jellyfin, plex, AppState,
};

const KINDS: &[&str] = &["jellyfin", "emby", "plex", "audiobookshelf"];

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

async fn browse_source(state: &AppState, id: i64, q: &Browse) -> ApiResult<Value> {
    match kind(state, id).await?.as_str() {
        "jellyfin" | "emby" => jellyfin::browse(state, id, q).await,
        "plex" => plex::browse(state, id, q).await,
        "audiobookshelf" => audiobookshelf::browse(state, id, q).await,
        _ => Err(ApiError::NotFound),
    }
}

/// Library id of a top-level item key (`<kind>:<source>:<library>`).
fn library_of(item: &Value) -> String {
    item["key"].as_str().unwrap_or("").splitn(3, ':').nth(2).unwrap_or("").to_string()
}

pub async fn hidden_libraries(state: &AppState, user: i64, source: i64) -> ApiResult<std::collections::HashSet<String>> {
    with_db(&state.db, move |c| {
        let mut st = c.prepare("SELECT library FROM hidden_library WHERE user_id = ?1 AND source_id = ?2")?;
        let rows = st.query_map((user, source), |r| r.get::<_, String>(0))?;
        Ok(rows.collect::<Result<_, _>>()?)
    })
    .await
}

pub async fn browse(
    State(state): State<AppState>,
    user: CurrentUser,
    Path(id): Path<i64>,
    Query(q): Query<Browse>,
) -> ApiResult<Json<Value>> {
    let mut out = browse_source(&state, id, &q).await?;
    // Top level: the libraries, without the ones this user has hidden.
    if q.parent.is_none() && q.search.as_deref().is_none_or(|s| s.trim().is_empty()) {
        let hidden = hidden_libraries(&state, user.id, id).await?;
        if let Some(items) = out["items"].as_array_mut() {
            items.retain(|i| !hidden.contains(&library_of(i)));
            out["total"] = json!(items.len());
        }
    }
    Ok(Json(out))
}

/// `GET /api/v1/sources/{id}/libraries`: all libraries with the user's switch.
pub async fn libraries(State(state): State<AppState>, user: CurrentUser, Path(id): Path<i64>) -> ApiResult<Json<Value>> {
    let all = browse_source(&state, id, &Browse::default()).await?;
    let hidden = hidden_libraries(&state, user.id, id).await?;
    let list: Vec<Value> = all["items"]
        .as_array()
        .map(|a| a.iter().map(|i| json!({ "id": library_of(i), "title": i["title"], "hidden": hidden.contains(&library_of(i)) })).collect())
        .unwrap_or_default();
    Ok(Json(Value::Array(list)))
}

#[derive(Deserialize)]
pub struct Hide {
    hidden: bool,
}

/// `PUT /api/v1/sources/{id}/libraries/{library}` {hidden}: hides or shows a library for this user.
pub async fn set_library(
    State(state): State<AppState>,
    user: CurrentUser,
    Path((id, lib)): Path<(i64, String)>,
    Json(req): Json<Hide>,
) -> ApiResult<Json<Value>> {
    if lib.is_empty() || lib.len() > 80 {
        return Err(ApiError::BadRequest("invalid library".into()));
    }
    with_db(&state.db, move |c| {
        if req.hidden {
            c.execute("INSERT OR IGNORE INTO hidden_library (user_id, source_id, library) VALUES (?1, ?2, ?3)", (user.id, id, &lib))?;
        } else {
            c.execute("DELETE FROM hidden_library WHERE user_id = ?1 AND source_id = ?2 AND library = ?3", (user.id, id, &lib))?;
        }
        Ok(Json(json!({ "ok": true })))
    })
    .await
}

/// `/api/v1/sources/{id}/books?parent=<library>`: the audiobook library with authors and series.
pub async fn books(
    State(state): State<AppState>,
    user: CurrentUser,
    Path(id): Path<i64>,
    Query(q): Query<Browse>,
) -> ApiResult<Json<Value>> {
    match kind(&state, id).await?.as_str() {
        "audiobookshelf" => {
            let lib = q.parent.ok_or_else(|| ApiError::BadRequest("parent (library) required".into()))?;
            audiobookshelf::library(&state, user.id, id, &lib).await.map(Json)
        }
        _ => Err(ApiError::NotFound),
    }
}

/// `/api/v1/image/{key}` for `jellyfin:<src>:<item>` and `abs:<src>:<item>`.
pub async fn image(State(state): State<AppState>, user: CurrentUser, Path(key): Path<String>) -> ApiResult<Response> {
    if let Some(uuid) = key.strip_prefix("radio:") {
        return crate::radio::image(&state, uuid).await;
    }
    for kind in ["episode", "podcast"] {
        if let Some(id) = key.strip_prefix(kind).and_then(|r| r.strip_prefix(':')) {
            let id: i64 = id.parse().map_err(|_| ApiError::NotFound)?;
            return crate::podcasts::image(&state, user.id, kind, id).await;
        }
    }
    let mut parts = key.splitn(3, ':');
    let (Some(k), Some(src), Some(item)) = (parts.next(), parts.next(), parts.next()) else {
        return Err(ApiError::NotFound);
    };
    let src: i64 = src.parse().map_err(|_| ApiError::NotFound)?;
    match k {
        "jellyfin" | "emby" => jellyfin::image(&state, src, item).await,
        "plex" => plex::image(&state, src, item).await,
        "abs" => audiobookshelf::image(&state, src, item).await,
        _ => Err(ApiError::NotFound),
    }
}

pub async fn relay_image(req: reqwest::RequestBuilder) -> ApiResult<Response> {
    let res = req.send().await.map_err(|e| ApiError::BadGateway(e.without_url().to_string()))?;
    // Images only (addresses may come from feeds); at most 8 MB.
    let is_image = res.headers().get(header::CONTENT_TYPE).and_then(|v| v.to_str().ok()).is_some_and(|t| t.starts_with("image/"));
    if !res.status().is_success() || !is_image || res.content_length().is_some_and(|n| n > 8 << 20) {
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
        "jellyfin" | "emby" => jellyfin::check(&state, &req.kind, &url, &key).await?,
        "plex" => plex::check(&state, &url, &key).await?,
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
        c.execute("DELETE FROM playback WHERE item_key LIKE ?1 || '%'", [&prefix])?;
        c.execute("DELETE FROM list_entry WHERE item_key LIKE ?1 || '%'", [&prefix])?;
        Ok(())
    })
    .await?;
    state.jellyfin_users.lock().unwrap().remove(&id);
    Ok(Json(json!({ "ok": true })))
}
