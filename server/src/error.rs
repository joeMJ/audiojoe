use axum::{
    http::StatusCode,
    response::{IntoResponse, Response},
    Json,
};

use crate::db::Db;

/// Error returned by API handlers; rendered as `{"error": "..."}`.
#[derive(Debug)]
pub enum ApiError {
    BadRequest(String),
    Unauthorized,
    NotFound,
    Conflict(String),
    TooManyRequests,
    BadGateway(String),
    Internal(anyhow::Error),
}

pub type ApiResult<T> = Result<T, ApiError>;

impl IntoResponse for ApiError {
    fn into_response(self) -> Response {
        let (status, msg) = match self {
            ApiError::BadRequest(m) => (StatusCode::BAD_REQUEST, m),
            ApiError::Unauthorized => (StatusCode::UNAUTHORIZED, "unauthorized".into()),
            ApiError::NotFound => (StatusCode::NOT_FOUND, "not found".into()),
            ApiError::Conflict(m) => (StatusCode::CONFLICT, m),
            ApiError::TooManyRequests => (StatusCode::TOO_MANY_REQUESTS, "too many attempts, try again later".into()),
            ApiError::BadGateway(m) => (StatusCode::BAD_GATEWAY, m),
            ApiError::Internal(e) => {
                tracing::error!("internal error: {e:#}");
                (StatusCode::INTERNAL_SERVER_ERROR, "internal error".into())
            }
        };
        (status, Json(serde_json::json!({ "error": msg }))).into_response()
    }
}

impl From<anyhow::Error> for ApiError {
    fn from(e: anyhow::Error) -> Self {
        ApiError::Internal(e)
    }
}

impl From<rusqlite::Error> for ApiError {
    fn from(e: rusqlite::Error) -> Self {
        match e {
            rusqlite::Error::QueryReturnedNoRows => ApiError::NotFound,
            e => ApiError::Internal(e.into()),
        }
    }
}

/// Runs a closure with the database connection on the blocking thread pool.
pub async fn with_db<T, F>(db: &Db, f: F) -> ApiResult<T>
where
    T: Send + 'static,
    F: FnOnce(&mut rusqlite::Connection) -> ApiResult<T> + Send + 'static,
{
    let db = db.clone();
    tokio::task::spawn_blocking(move || f(&mut db.lock().unwrap()))
        .await
        .map_err(|e| ApiError::Internal(e.into()))?
}
