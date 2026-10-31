mod access;
mod config;
mod db;
mod probe;
mod stream;

use std::{net::SocketAddr, path::PathBuf, sync::Arc};

use anyhow::Result;
use axum::{
    extract::DefaultBodyLimit,
    http::{header, HeaderValue},
    middleware,
    routing::{get, post},
    Json, Router,
};
use tower_http::{
    services::{ServeDir, ServeFile},
    set_header::SetResponseHeaderLayer,
};

#[derive(Clone)]
pub struct AppState {
    pub config: Arc<config::Config>,
    pub db: db::Db,
    pub http: reqwest::Client,
}

const VERSION: &str = env!("CARGO_PKG_VERSION");

#[tokio::main]
async fn main() -> Result<()> {
    tracing_subscriber::fmt()
        .with_env_filter(
            tracing_subscriber::EnvFilter::try_from_default_env()
                .unwrap_or_else(|_| "audiojoe_server=info,access=info".into()),
        )
        .with_ansi(std::io::IsTerminal::is_terminal(&std::io::stderr()))
        .init();

    let path = std::env::args()
        .skip_while(|a| a != "--config")
        .nth(1)
        .map(PathBuf::from)
        .unwrap_or_else(|| PathBuf::from("/etc/audiojoe/config.toml"));
    let config = config::Config::load(&path)?;
    let state = AppState {
        db: db::open(&config.database)?,
        http: reqwest::Client::builder()
            .user_agent(concat!("audiojoe/", env!("CARGO_PKG_VERSION")))
            .connect_timeout(std::time::Duration::from_secs(5))
            .build()?,
        config: Arc::new(config),
    };

    let web = ServeDir::new(&state.config.web_root)
        .fallback(ServeFile::new(state.config.web_root.join("index.html")));
    let app = Router::new()
        .route("/api/v1/health", get(health))
        .route("/api/v1/probe/results", post(probe::submit).get(probe::list))
        .route("/api/v1/probe/stream/{file}", get(probe::stream))
        .fallback_service(web)
        .layer(DefaultBodyLimit::max(64 * 1024))
        .layer(middleware::from_fn_with_state(state.clone(), access::log))
        .layer(SetResponseHeaderLayer::overriding(
            header::X_CONTENT_TYPE_OPTIONS,
            HeaderValue::from_static("nosniff"),
        ))
        .layer(SetResponseHeaderLayer::overriding(
            header::REFERRER_POLICY,
            HeaderValue::from_static("no-referrer"),
        ))
        .with_state(state.clone());

    let listener = tokio::net::TcpListener::bind(state.config.listen).await?;
    tracing::info!("audiojoe-server {VERSION} listening on {}", state.config.listen);
    axum::serve(listener, app.into_make_service_with_connect_info::<SocketAddr>())
        .with_graceful_shutdown(shutdown())
        .await?;
    Ok(())
}

/// Resolves on Ctrl-C or SIGTERM (systemd stop).
async fn shutdown() {
    let mut term = tokio::signal::unix::signal(tokio::signal::unix::SignalKind::terminate())
        .expect("cannot install SIGTERM handler");
    tokio::select! {
        _ = tokio::signal::ctrl_c() => {}
        _ = term.recv() => {}
    }
}

async fn health() -> Json<serde_json::Value> {
    Json(serde_json::json!({ "status": "ok", "version": VERSION }))
}
