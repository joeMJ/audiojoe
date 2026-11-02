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
    /// Former browser probe section (removed in 0.2.0); still accepted so old configs keep working.
    #[serde(default, rename = "probe")]
    _probe: Option<toml::Value>,
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

impl Config {
    pub fn load(path: &std::path::Path) -> Result<Self> {
        let text = std::fs::read_to_string(path)
            .with_context(|| format!("cannot read config {}", path.display()))?;
        let cfg: Config =
            toml::from_str(&text).with_context(|| format!("invalid config {}", path.display()))?;
        Ok(cfg)
    }
}

#[cfg(test)]
mod tests {
    #[test]
    fn old_probe_section_is_accepted() {
        let text = "listen = \"127.0.0.1:8080\"\ndatabase = \"/tmp/a.db\"\nweb_root = \"/tmp\"\n\n[probe]\ntoken = \"x\"\nupstream = \"http://127.0.0.1:8090\"\n";
        assert!(toml::from_str::<super::Config>(text).is_ok());
    }
}
