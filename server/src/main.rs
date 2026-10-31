mod access;
mod audiobookshelf;
mod auth;
mod cli;
mod config;
mod db;
mod error;
mod jellyfin;
mod media;
mod playback;
mod podcasts;
mod probe;
mod sources;
mod stream;

use std::{
    collections::HashMap,
    net::SocketAddr,
    path::PathBuf,
    sync::{Arc, Mutex},
};

use anyhow::Result;
use axum::{
    extract::DefaultBodyLimit,
    http::{header, HeaderValue},
    middleware,
    routing::{delete, get, post},
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
    pub guard: Arc<auth::Guard>,
    /// Argon2 hash of a random password; verified for unknown user names (equal timing).
    pub dummy_hash: Arc<String>,
    pub events: playback::Events,
    /// Jellyfin user id per source, looked up once.
    pub jellyfin_users: Arc<Mutex<HashMap<i64, String>>>,
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

    // [--config FILE] [serve | help | user …]
    let mut args: Vec<String> = std::env::args().skip(1).collect();
    let path = match args.iter().position(|a| a == "--config") {
        Some(i) if i + 1 < args.len() => {
            let p = PathBuf::from(args.remove(i + 1));
            args.remove(i);
            p
        }
        _ => PathBuf::from("/etc/audiojoe/config.toml"),
    };
    match args.first().map(String::as_str) {
        None | Some("serve") => {}
        Some("help" | "--help" | "-h") => {
            println!("audiojoe-server {VERSION}\n\n  audiojoe-server [--config FILE] [serve]\n  audiojoe-server [--config FILE] user add|passwd|totp-reset|delete NAME [--password-file FILE]\n  audiojoe-server [--config FILE] user list");
            return Ok(());
        }
        Some(_) => return cli::run(&config::Config::load(&path)?, &args),
    }
    let config = config::Config::load(&path)?;
    let state = AppState {
        db: db::open(&config.database)?,
        http: reqwest::Client::builder()
            .user_agent(concat!("audiojoe/", env!("CARGO_PKG_VERSION")))
            .connect_timeout(std::time::Duration::from_secs(5))
            .build()?,
        config: Arc::new(config),
        guard: Default::default(),
        dummy_hash: Arc::new(auth::hash_password(&auth::random_token())?),
        events: tokio::sync::broadcast::channel(256).0,
        jellyfin_users: Default::default(),
    };
    tokio::spawn(podcasts::refresh_loop(state.clone()));
    tokio::spawn(audiobookshelf::sync_loop(state.clone()));

    let web = ServeDir::new(&state.config.web_root)
        .fallback(ServeFile::new(state.config.web_root.join("index.html")));
    let app = Router::new()
        .route("/api/v1/health", get(health))
        .route("/api/v1/probe/results", post(probe::submit).get(probe::list))
        .route("/api/v1/probe/stream/{file}", get(probe::stream))
        .route("/api/v1/auth/login", post(auth::login))
        .route("/api/v1/auth/logout", post(auth::logout))
        .route("/api/v1/me", get(auth::me))
        .route("/api/v1/sessions", get(auth::sessions))
        .route("/api/v1/sessions/{id}", delete(auth::revoke))
        .route("/api/v1/podcasts/search", get(podcasts::search))
        .route("/api/v1/sources", get(sources::list).post(sources::add))
        .route("/api/v1/sources/{id}", delete(sources::delete))
        .route("/api/v1/sources/{id}/browse", get(sources::browse))
        .route("/api/v1/image/{key}", get(sources::image))
        .route("/api/v1/podcasts", get(podcasts::list).post(podcasts::subscribe))
        .route("/api/v1/podcasts/{id}", delete(podcasts::unsubscribe))
        .route("/api/v1/podcasts/{id}/episodes", get(podcasts::episodes))
        .route("/api/v1/podcasts/{id}/refresh", post(podcasts::refresh))
        .route("/api/v1/episodes/latest", get(podcasts::latest))
        .route("/api/v1/items/{key}", get(media::item))
        .route("/api/v1/stream/{key}", get(media::stream))
        .route("/api/v1/playback", get(playback::list).post(playback::sync))
        .route("/api/v1/playback/{key}", get(playback::get).put(playback::put))
        .route("/api/v1/events", get(playback::events))
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
    // Graceful shutdown waits for open connections, but live event streams never end on
    // their own: after the signal, running requests get 3 s, then the server exits.
    let (stop_tx, mut stop_rx) = tokio::sync::watch::channel(false);
    let server = axum::serve(listener, app.into_make_service_with_connect_info::<SocketAddr>())
        .with_graceful_shutdown(async move {
            shutdown().await;
            let _ = stop_tx.send(true);
        });
    tokio::select! {
        r = server => r?,
        _ = async {
            let _ = stop_rx.wait_for(|stopped| *stopped).await;
            tokio::time::sleep(std::time::Duration::from_secs(3)).await;
        } => tracing::info!("open connections closed after shutdown grace period"),
    }
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
