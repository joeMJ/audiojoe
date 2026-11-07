mod access;
mod audiobookshelf;
mod chapters;
mod auth;
mod cli;
mod config;
mod db;
mod devices;
mod docs;
mod error;
mod gpodder;
mod jellyfin;
mod lists;
mod maintenance;
mod media;
mod music;
mod notes;
mod opml;
mod playback;
mod plex;
mod podcasts;
mod prefs;
mod radio;
mod sonos;
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
    http::{header, HeaderName, HeaderValue},
    middleware,
    routing::{delete, get, post, put},
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
    /// Key that signs the stream URLs given to Sonos speakers (kept across restarts).
    pub sonos_secret: Arc<Vec<u8>>,
    pub online: devices::Online,
    /// Wakes the Sonos poll loop right after a command.
    pub sonos_poke: Arc<tokio::sync::Notify>,
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
    let db = db::open(&config.database)?;
    let sonos_secret = {
        let c = db.lock().unwrap();
        let existing: Option<String> = c.query_row("SELECT value FROM setting WHERE name = 'sonos_secret'", [], |r| r.get(0)).ok();
        let secret = existing.unwrap_or_else(auth::random_token);
        c.execute("INSERT OR IGNORE INTO setting (name, value) VALUES ('sonos_secret', ?1)", [&secret])?;
        Arc::new(secret.into_bytes())
    };
    let state = AppState {
        db,
        http: reqwest::Client::builder()
            .user_agent(concat!("audiojoe/", env!("CARGO_PKG_VERSION")))
            .connect_timeout(std::time::Duration::from_secs(5))
            .build()?,
        config: Arc::new(config),
        guard: Default::default(),
        dummy_hash: Arc::new(auth::hash_password(&auth::random_token())?),
        events: tokio::sync::broadcast::channel(256).0,
        jellyfin_users: Default::default(),
        sonos_secret,
        online: Default::default(),
        sonos_poke: Default::default(),
    };
    tokio::spawn(podcasts::refresh_loop(state.clone()));
    tokio::spawn(audiobookshelf::sync_loop(state.clone()));
    tokio::spawn(music::refresh_loop(state.clone()));
    if let Some(addr) = sonos::lan_addr(&state) {
        let lan = tokio::net::TcpListener::bind(addr).await?;
        tracing::info!("Sonos stream port on {addr} (LAN only)");
        let router = sonos::lan_router(state.clone()).layer(middleware::from_fn_with_state(state.clone(), access::log));
        tokio::spawn(async move {
            let _ = axum::serve(lan, router.into_make_service_with_connect_info::<SocketAddr>()).await;
        });
        tokio::spawn(sonos::poll_loop(state.clone()));
    }

    let web = ServeDir::new(&state.config.web_root)
        .fallback(ServeFile::new(state.config.web_root.join("index.html")));
    // Car test page: open without login, static only, kept out of search indexes.
    let testcar = Router::new()
        .fallback_service(ServeDir::new(state.config.web_root.join("testcar")))
        .layer(SetResponseHeaderLayer::overriding(
            HeaderName::from_static("x-robots-tag"),
            HeaderValue::from_static("noindex, nofollow"),
        ));
    let app = Router::new()
        .route("/api/v1/health", get(health))
        .route("/api/v1/auth/login", post(auth::login))
        .route("/api/v1/auth/logout", post(auth::logout))
        .route("/api/v1/me", get(auth::me))
        .route("/api/v1/sessions", get(auth::sessions))
        .route("/api/v1/sessions/{id}", delete(auth::revoke))
        .route("/api/v1/sessions/{id}/label", put(devices::label))
        .route("/api/v1/podcasts/search", get(podcasts::search))
        .route("/api/v1/sources", get(sources::list).post(sources::add))
        .route("/api/v1/sources/{id}", delete(sources::delete))
        .route("/api/v1/sources/{id}/browse", get(sources::browse))
        .route("/api/v1/sources/{id}/books", get(sources::books))
        .route("/api/v1/books/libraries", get(sources::book_libraries))
        .route("/api/v1/sources/{id}/libraries", get(sources::libraries))
        .route("/api/v1/sources/{id}/music", get(music::albums))
        .route("/api/v1/sources/{id}/music/refresh", post(music::refresh))
        .route("/api/v1/settings/music", get(music::get_settings).put(music::put_settings))
        .route("/api/v1/settings/playback", get(prefs::get_playback).put(prefs::put_playback))
        .route("/api/v1/sources/{id}/libraries/{library}", axum::routing::put(sources::set_library))
        .route("/api/v1/image/{key}", get(sources::image))
        .route("/api/v1/podcasts", get(podcasts::list).post(podcasts::subscribe))
        .route("/api/v1/podcasts/opml", get(opml::export).post(opml::import))
        .route("/api/v1/podcasts/{id}", delete(podcasts::unsubscribe))
        .route("/api/v1/podcasts/{id}/episodes", get(podcasts::episodes))
        .route("/api/v1/podcasts/{id}/refresh", post(podcasts::refresh))
        .route("/api/v1/episodes/latest", get(podcasts::latest))
        .route("/api/v1/radio/search", get(radio::search))
        .route("/api/v1/radio/favorites", get(radio::favorites).put(radio::order_favorites))
        .route("/api/v1/lists/{list}", get(lists::get).post(lists::add).put(lists::order))
        .route("/api/v1/lists/{list}/{key}", delete(lists::remove))
        .route("/api/v1/radio/favorites/{uuid}", axum::routing::put(radio::add_favorite).delete(radio::remove_favorite))
        .route("/api/v1/maintenance", get(maintenance::status).put(maintenance::set_mode))
        .route("/api/v1/maintenance/update", post(maintenance::request_update))
        .route("/api/v1/maintenance/check", post(maintenance::request_check))
        .route("/api/v1/maintenance/app/{platform}", get(maintenance::app_download))
        .route("/api/v1/maintenance/sums", get(maintenance::sums))
        .route("/api/v1/gpodder", get(gpodder::info))
        .route("/api/v1/gpodder/password", post(gpodder::new_password).delete(gpodder::drop_password))
        // gpodder-compatible sync for other podcast apps (/api/2/…, /subscriptions/…).
        .merge(gpodder::router())
        .route("/api/v1/sonos", get(sonos::list).post(sonos::add))
        .route("/api/v1/sonos/scan", post(sonos::scan))
        .route("/api/v1/sonos/setup", get(sonos::setup))
        .route("/api/v1/sonos/{id}", delete(sonos::remove))
        .route("/api/v1/sonos/{id}/play", post(sonos::play))
        .route("/api/v1/sonos/{id}/command", post(sonos::command))
        .route("/api/v1/sonos/{id}/join", post(sonos::join))
        .route("/api/v1/sonos/{id}/leave", post(sonos::leave))
        .route("/api/v1/items/{key}", get(media::item))
        .route("/api/v1/stream/{key}", get(media::stream))
        .route("/api/v1/playback", get(playback::list).post(playback::sync))
        .route("/api/v1/playback/{key}", get(playback::get).put(playback::put))
        .route("/api/v1/queue", axum::routing::put(playback::put_queue))
        .route("/api/v1/queue/{key}", get(playback::get_queue))
        .route("/api/v1/events", get(playback::events))
        .route("/api/v1/devices", get(devices::devices))
        .route("/api/v1/devices/{device}/command", post(devices::command))
        .route("/docs/{file}", get(docs::english))
        .route("/docs/de/{file}", get(docs::german))
        .route("/docs/screenshots/{file}", get(docs::screenshot))
        .nest_service("/testcar", testcar)
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
