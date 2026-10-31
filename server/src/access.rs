//! Access log: one line per request (client IP, method, path, status, duration) at target
//! `access`, so it can be filtered in the journal. Query strings are never logged because
//! they may carry tokens. The client IP is taken from `X-Forwarded-For` only when the
//! direct peer is a configured trusted proxy.

use std::{net::SocketAddr, time::Instant};

use axum::{
    extract::{ConnectInfo, Request, State},
    middleware::Next,
    response::Response,
};

use crate::AppState;

pub async fn log(
    State(state): State<AppState>,
    ConnectInfo(peer): ConnectInfo<SocketAddr>,
    req: Request,
    next: Next,
) -> Response {
    let started = Instant::now();
    let client = client_ip(&state, peer, &req);
    let method = req.method().clone();
    let path = req.uri().path().to_owned();
    let res = next.run(req).await;
    tracing::info!(
        target: "access",
        "{client} {method} {path} {} {}ms",
        res.status().as_u16(),
        started.elapsed().as_millis()
    );
    res
}

fn client_ip(state: &AppState, peer: SocketAddr, req: &Request) -> String {
    if state.config.trusted_proxies.contains(&peer.ip()) {
        // The proxy appends the address it saw; the last entry is the one it vouches for.
        if let Some(ip) = req
            .headers()
            .get("x-forwarded-for")
            .and_then(|v| v.to_str().ok())
            .and_then(|v| v.rsplit(',').next())
            .map(str::trim)
            .filter(|s| s.parse::<std::net::IpAddr>().is_ok())
        {
            return format!("{ip} via {}", peer.ip());
        }
    }
    peer.ip().to_string()
}
