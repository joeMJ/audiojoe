//! Login with user name, password (Argon2id) and TOTP (mandatory), device sessions.
//!
//! Clients authenticate with `Authorization: Bearer <token>` (apps) or the HttpOnly cookie
//! `aj_session` (web app; also covers <audio> and EventSource, which cannot set headers).
//! Only the SHA-256 of a session token is stored.

use std::{
    collections::HashMap,
    net::{IpAddr, SocketAddr},
    sync::Mutex,
    time::{Duration, Instant},
};

use argon2::{
    password_hash::{rand_core::OsRng, PasswordHash, PasswordHasher, PasswordVerifier, SaltString},
    Argon2,
};
use axum::{
    extract::{ConnectInfo, FromRequestParts, State},
    http::{header, request::Parts, HeaderMap, HeaderValue},
    response::{IntoResponse, Response},
    Json,
};
use base64::Engine;
use rand::RngCore;
use serde::Deserialize;
use sha2::{Digest, Sha256};
use totp_rs::{Algorithm, Secret, TOTP};

use crate::{
    error::{with_db, ApiError, ApiResult},
    AppState,
};

const COOKIE: &str = "aj_session";
pub(crate) const SESSION_DAYS: u32 = 180;
/// Failed logins allowed per client IP and per user name within `FAIL_WINDOW`.
const MAX_FAILS: u32 = 5;
const FAIL_WINDOW: Duration = Duration::from_secs(15 * 60);
const ISSUER: &str = "audiojoe";

// ---------------------------------------------------------------- passwords and TOTP

pub fn hash_password(password: &str) -> anyhow::Result<String> {
    let salt = SaltString::generate(&mut OsRng);
    Argon2::default()
        .hash_password(password.as_bytes(), &salt)
        .map(|h| h.to_string())
        .map_err(|e| anyhow::anyhow!("hashing failed: {e}"))
}

pub(crate) fn verify_password(hash: &str, password: &str) -> bool {
    PasswordHash::new(hash)
        .map(|h| Argon2::default().verify_password(password.as_bytes(), &h).is_ok())
        .unwrap_or(false)
}

pub fn new_totp_secret() -> String {
    let mut bytes = [0u8; 20];
    rand::thread_rng().fill_bytes(&mut bytes);
    Secret::Raw(bytes.to_vec()).to_encoded().to_string()
}

pub fn totp(secret: &str, account: &str) -> anyhow::Result<TOTP> {
    let bytes = Secret::Encoded(secret.to_string())
        .to_bytes()
        .map_err(|e| anyhow::anyhow!("invalid TOTP secret: {e:?}"))?;
    TOTP::new(Algorithm::SHA1, 6, 1, 30, bytes, Some(ISSUER.into()), account.into())
        .map_err(|e| anyhow::anyhow!("invalid TOTP: {e}"))
}

/// Random token, URL-safe base64 without padding.
pub fn random_token() -> String {
    let mut bytes = [0u8; 32];
    rand::thread_rng().fill_bytes(&mut bytes);
    base64::engine::general_purpose::URL_SAFE_NO_PAD.encode(bytes)
}

pub(crate) fn token_hash(token: &str) -> String {
    format!("{:x}", Sha256::digest(token.as_bytes()))
}

// ---------------------------------------------------------------- throttling

/// Counts failed logins per key; also remembers used TOTP steps to block replays.
#[derive(Default)]
pub struct Guard {
    fails: Mutex<HashMap<String, (u32, Instant)>>,
    used_steps: Mutex<HashMap<i64, u64>>,
}

impl Guard {
    pub(crate) fn blocked(&self, key: &str) -> bool {
        let mut fails = self.fails.lock().unwrap();
        match fails.get(key) {
            Some((n, since)) if since.elapsed() < FAIL_WINDOW => *n >= MAX_FAILS,
            Some(_) => {
                fails.remove(key);
                false
            }
            None => false,
        }
    }

    pub(crate) fn fail(&self, key: &str) {
        let mut fails = self.fails.lock().unwrap();
        let e = fails.entry(key.to_string()).or_insert((0, Instant::now()));
        if e.1.elapsed() >= FAIL_WINDOW {
            *e = (0, Instant::now());
        }
        e.0 += 1;
    }

    pub(crate) fn clear(&self, key: &str) {
        self.fails.lock().unwrap().remove(key);
    }

    /// Accepts a TOTP step only once per user (and never an older one).
    fn use_step(&self, user: i64, step: u64) -> bool {
        let mut used = self.used_steps.lock().unwrap();
        match used.get(&user) {
            Some(&last) if step <= last => false,
            _ => {
                used.insert(user, step);
                true
            }
        }
    }
}

/// Client address for throttling: the address the trusted proxy reports, else the peer.
fn client_ip(state: &AppState, peer: SocketAddr, headers: &HeaderMap) -> IpAddr {
    if state.config.trusted_proxies.contains(&peer.ip()) {
        if let Some(ip) = headers
            .get("x-forwarded-for")
            .and_then(|v| v.to_str().ok())
            .and_then(|v| v.rsplit(',').next())
            .and_then(|s| s.trim().parse().ok())
        {
            return ip;
        }
    }
    peer.ip()
}

// ---------------------------------------------------------------- handlers

#[derive(Deserialize)]
pub struct LoginRequest {
    username: String,
    password: String,
    totp: String,
    device: String,
}

pub async fn login(
    State(state): State<AppState>,
    ConnectInfo(peer): ConnectInfo<SocketAddr>,
    headers: HeaderMap,
    Json(req): Json<LoginRequest>,
) -> ApiResult<Response> {
    let ip_key = format!("ip:{}", client_ip(&state, peer, &headers));
    let user_key = format!("user:{}", req.username.to_lowercase());
    if state.guard.blocked(&ip_key) || state.guard.blocked(&user_key) {
        return Err(ApiError::TooManyRequests);
    }
    let device: String = req.device.trim().chars().take(80).collect();
    if device.is_empty() {
        return Err(ApiError::BadRequest("device name required".into()));
    }

    let name = req.username.clone();
    let row = with_db(&state.db, move |c| {
        Ok(c.query_row(
            "SELECT id, password_hash, totp_secret FROM user WHERE name = ?1",
            [&name],
            |r| Ok((r.get::<_, i64>(0)?, r.get::<_, String>(1)?, r.get::<_, String>(2)?)),
        )
        .ok())
    })
    .await?;

    // Verify on the blocking pool; for unknown users against a dummy hash so the response
    // time does not reveal whether the name exists.
    let password = req.password.clone();
    let hash = row.as_ref().map(|r| r.1.clone()).unwrap_or_else(|| state.dummy_hash.to_string());
    let password_ok = tokio::task::spawn_blocking(move || verify_password(&hash, &password))
        .await
        .unwrap_or(false);

    let user = match row {
        Some((id, _, secret)) if password_ok => {
            let t = totp(&secret, &req.username)?;
            let now = std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap()
                .as_secs();
            let code = req.totp.trim();
            // Current, previous and next step (clock drift), each usable once.
            let step = [now, now.saturating_sub(30), now + 30]
                .into_iter()
                .find(|&ts| t.generate(ts) == code)
                .map(|ts| ts / 30);
            match step {
                Some(s) if state.guard.use_step(id, s) => Some(id),
                _ => None,
            }
        }
        _ => None,
    };
    let Some(user_id) = user else {
        state.guard.fail(&ip_key);
        state.guard.fail(&user_key);
        tracing::warn!(target: "access", "login failed for {:?} from {ip_key}", req.username);
        return Err(ApiError::Unauthorized);
    };
    state.guard.clear(&ip_key);
    state.guard.clear(&user_key);

    let token = random_token();
    let th = token_hash(&token);
    let dev = device.clone();
    with_db(&state.db, move |c| {
        c.execute(
            "INSERT INTO session (user_id, token_hash, device, expires_at)
             VALUES (?1, ?2, ?3, strftime('%Y-%m-%dT%H:%M:%SZ', 'now', ?4))",
            (user_id, th, dev, format!("+{SESSION_DAYS} days")),
        )?;
        // Expired sessions of all users are removed here, so they do not pile up.
        c.execute("DELETE FROM session WHERE expires_at <= strftime('%Y-%m-%dT%H:%M:%SZ', 'now')", [])?;
        Ok(())
    })
    .await?;
    tracing::info!(target: "access", "login {:?} device {device:?}", req.username);

    let cookie = format!(
        "{COOKIE}={token}; HttpOnly; Secure; SameSite=Strict; Path=/; Max-Age={}",
        SESSION_DAYS * 86400
    );
    let mut res = Json(serde_json::json!({ "token": token, "user": req.username, "device": device })).into_response();
    res.headers_mut().insert(header::SET_COOKIE, HeaderValue::from_str(&cookie).unwrap());
    Ok(res)
}

pub async fn logout(State(state): State<AppState>, user: CurrentUser) -> ApiResult<Response> {
    let sid = user.session_id;
    with_db(&state.db, move |c| {
        c.execute("DELETE FROM session WHERE id = ?1", [sid])?;
        Ok(())
    })
    .await?;
    let mut res = Json(serde_json::json!({ "ok": true })).into_response();
    res.headers_mut().insert(
        header::SET_COOKIE,
        HeaderValue::from_static("aj_session=; HttpOnly; Secure; SameSite=Strict; Path=/; Max-Age=0"),
    );
    Ok(res)
}

pub async fn me(user: CurrentUser) -> Json<serde_json::Value> {
    Json(serde_json::json!({ "user": user.name, "device": user.device }))
}

/// The user's signed-in devices.
pub async fn sessions(State(state): State<AppState>, user: CurrentUser) -> ApiResult<Json<serde_json::Value>> {
    with_db(&state.db, move |c| {
        let mut stmt = c.prepare(
            "SELECT id, device, created_at, last_seen, expires_at FROM session WHERE user_id = ?1 ORDER BY last_seen DESC",
        )?;
        let labels = crate::devices::labels(c, user.id)?;
        let rows = stmt
            .query_map([user.id], |r| {
                let id: i64 = r.get(0)?;
                let device: String = r.get(1)?;
                Ok(serde_json::json!({ "id": id, "label": labels.get(&device), "device": device,
                    "created_at": r.get::<_, String>(2)?, "last_seen": r.get::<_, String>(3)?,
                    "expires_at": r.get::<_, String>(4)?, "current": id == user.session_id }))
            })?
            .collect::<Result<Vec<_>, _>>()?;
        Ok(Json(serde_json::Value::Array(rows)))
    })
    .await
}

/// Signs out one of the user's devices.
pub async fn revoke(
    State(state): State<AppState>,
    user: CurrentUser,
    axum::extract::Path(id): axum::extract::Path<i64>,
) -> ApiResult<Json<serde_json::Value>> {
    with_db(&state.db, move |c| {
        if c.execute("DELETE FROM session WHERE id = ?1 AND user_id = ?2", (id, user.id))? == 0 {
            return Err(ApiError::NotFound);
        }
        Ok(Json(serde_json::json!({ "ok": true })))
    })
    .await
}

// ---------------------------------------------------------------- extractor

/// The authenticated user of a request. Rejects with 401 otherwise.
#[derive(Debug, Clone)]
pub struct CurrentUser {
    pub id: i64,
    pub name: String,
    pub session_id: i64,
    pub device: String,
}

fn token_from(parts: &Parts) -> Option<String> {
    if let Some(v) = parts.headers.get(header::AUTHORIZATION).and_then(|v| v.to_str().ok()) {
        if let Some(t) = v.strip_prefix("Bearer ") {
            return Some(t.trim().to_string());
        }
    }
    parts
        .headers
        .get_all(header::COOKIE)
        .iter()
        .filter_map(|v| v.to_str().ok())
        .flat_map(|v| v.split(';'))
        .filter_map(|kv| kv.trim().split_once('='))
        .find(|(k, _)| *k == COOKIE)
        .map(|(_, v)| v.to_string())
}

impl FromRequestParts<AppState> for CurrentUser {
    type Rejection = ApiError;

    async fn from_request_parts(parts: &mut Parts, state: &AppState) -> Result<Self, Self::Rejection> {
        let token = token_from(parts).ok_or(ApiError::Unauthorized)?;
        let th = token_hash(&token);
        with_db(&state.db, move |c| {
            let user = c
                .query_row(
                    "SELECT u.id, u.name, s.id, s.device FROM session s JOIN user u ON u.id = s.user_id
                     WHERE s.token_hash = ?1 AND s.expires_at > strftime('%Y-%m-%dT%H:%M:%SZ', 'now')",
                    [&th],
                    |r| Ok(CurrentUser { id: r.get(0)?, name: r.get(1)?, session_id: r.get(2)?, device: r.get(3)? }),
                )
                .map_err(|_| ApiError::Unauthorized)?;
            c.execute(
                "UPDATE session SET last_seen = strftime('%Y-%m-%dT%H:%M:%SZ', 'now') WHERE id = ?1",
                [user.session_id],
            )?;
            Ok(user)
        })
        .await
    }
}
