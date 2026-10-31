use std::{net::SocketAddr, path::PathBuf};

use anyhow::{Context, Result};
use serde::Deserialize;

/// Server configuration, read from a TOML file (default `/etc/audiojoe/config.toml`).
#[derive(Debug, Clone, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Config {
    /// Address the HTTP API listens on. Bind to the LAN address only; TLS is terminated
    /// by the reverse proxy in front of the server.
    pub listen: SocketAddr,
    /// SQLite database file.
    pub database: PathBuf,
    /// Directory with the built web app (static files).
    pub web_root: PathBuf,
    /// Reverse proxies whose `X-Forwarded-For` header is trusted for the access log.
    #[serde(default)]
    pub trusted_proxies: Vec<std::net::IpAddr>,
    #[serde(default)]
    pub probe: Option<ProbeConfig>,
    #[serde(default)]
    pub sonos: Option<SonosConfig>,
}

/// Sonos speakers fetch streams from a second, LAN-only HTTP port.
#[derive(Debug, Clone, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct SonosConfig {
    /// LAN address of the stream port, e.g. "10.0.0.20:8081". Must be reachable by the speakers.
    pub listen: Option<std::net::SocketAddr>,
    /// Address range probed by "scan", e.g. "10.0.0.230-10.0.0.240".
    pub scan: Option<String>,
}

/// Browser capability probe (stage 0): collects measurements from the in-car browser.
#[derive(Debug, Clone, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct ProbeConfig {
    /// Shared secret that must be passed as `?t=` to read results (submitting is open).
    pub token: String,
    /// Base URL of the test media source the probe streams are relayed from.
    pub upstream: String,
}

impl Config {
    pub fn load(path: &std::path::Path) -> Result<Self> {
        let text = std::fs::read_to_string(path)
            .with_context(|| format!("cannot read config {}", path.display()))?;
        let cfg: Config =
            toml::from_str(&text).with_context(|| format!("invalid config {}", path.display()))?;
        if let Some(p) = &cfg.probe {
            anyhow::ensure!(p.token.len() >= 24, "probe.token must be at least 24 characters");
        }
        Ok(cfg)
    }
}
