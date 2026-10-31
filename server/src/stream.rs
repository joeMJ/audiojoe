//! Relays an upstream audio stream to the client without storing it.
//! Range requests are passed through so clients can seek and resume interrupted downloads.

use axum::{
    body::Body,
    http::{header, HeaderMap, HeaderName, StatusCode},
    response::{IntoResponse, Response},
};
use futures_util::TryStreamExt;

/// Response headers copied from the upstream response.
const PASS_HEADERS: &[HeaderName] = &[
    header::CONTENT_TYPE,
    header::CONTENT_LENGTH,
    header::CONTENT_RANGE,
    header::ACCEPT_RANGES,
    header::ETAG,
    header::LAST_MODIFIED,
];

/// `extra` are request headers for the upstream (e.g. the source's authorization).
pub async fn relay(
    client: &reqwest::Client,
    url: &str,
    req_headers: &HeaderMap,
    extra: &[(HeaderName, String)],
) -> Response {
    let mut req = client.get(url);
    for h in [header::RANGE, header::IF_RANGE] {
        if let Some(v) = req_headers.get(&h) {
            req = req.header(h, v);
        }
    }
    for (k, v) in extra {
        req = req.header(k, v);
    }
    let upstream = match req.send().await {
        Ok(r) => r,
        Err(e) => {
            // Without the URL: it may contain credentials of the source.
            tracing::warn!("upstream unreachable: {}", e.without_url());
            return (StatusCode::BAD_GATEWAY, "upstream unreachable").into_response();
        }
    };
    let status = StatusCode::from_u16(upstream.status().as_u16()).unwrap_or(StatusCode::BAD_GATEWAY);
    let mut builder = Response::builder().status(status);
    for h in PASS_HEADERS {
        if let Some(v) = upstream.headers().get(h.as_str()) {
            if let Ok(v) = header::HeaderValue::from_bytes(v.as_bytes()) {
                builder = builder.header(h, v);
            }
        }
    }
    // Test sources announce a checksum of the complete file so clients can verify downloads.
    if let Some(v) = upstream.headers().get("x-content-sha256") {
        builder = builder.header("x-content-sha256", v.as_bytes());
    }
    let body = Body::from_stream(upstream.bytes_stream().map_err(std::io::Error::other));
    builder
        .header(header::CACHE_CONTROL, "no-store")
        .body(body)
        .unwrap_or_else(|_| StatusCode::INTERNAL_SERVER_ERROR.into_response())
}
