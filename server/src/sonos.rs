//! Sonos speakers, controlled directly over UPnP/SOAP (port 1400) at fixed IP addresses –
//! no SSDP/multicast discovery. A speaker that is switched off is a normal state.
//!
//! The speaker fetches the audio itself from a second, LAN-only HTTP port of this server
//! (`sonos_listen`): Sonos does not accept HTTPS with private certificates. That port
//! serves nothing but streams behind signed, expiring URLs – no login, no API.
//! Hi-res sources are converted on the fly: S2 plays up to 24 bit/48 kHz, S1 up to 16 bit.
//!
//! While a speaker plays one of our streams, its position is stored as the user's
//! playback position (device "Sonos <room>"), so other devices continue from there.

use std::{collections::HashMap, net::SocketAddr, time::Duration};

use axum::{
    extract::{Path, State},
    http::{HeaderMap, StatusCode},
    response::{IntoResponse, Response},
    routing::get,
    Json, Router,
};
use base64::Engine;
use chrono::Utc;
use hmac::{Hmac, Mac};
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use sha2::Sha256;

use crate::{
    auth::CurrentUser,
    error::{with_db, ApiError, ApiResult},
    media, playback, AppState,
};

const TIMEOUT: Duration = Duration::from_secs(3);
/// Stream URLs stay valid this long (Sonos re-requests ranges while playing).
const URL_HOURS: i64 = 24;
const POLL_EVERY: Duration = Duration::from_secs(10);

// ---------------------------------------------------------------- SOAP

const AVT: (&str, &str) = ("/MediaRenderer/AVTransport/Control", "urn:schemas-upnp-org:service:AVTransport:1");
const RC: (&str, &str) = ("/MediaRenderer/RenderingControl/Control", "urn:schemas-upnp-org:service:RenderingControl:1");
const ZGT: (&str, &str) = ("/ZoneGroupTopology/Control", "urn:schemas-upnp-org:service:ZoneGroupTopology:1");

pub fn xml_escape(s: &str) -> String {
    s.replace('&', "&amp;").replace('<', "&lt;").replace('>', "&gt;").replace('"', "&quot;").replace('\'', "&apos;")
}

fn envelope(service: &str, action: &str, args: &str) -> String {
    format!(
        "<?xml version=\"1.0\" encoding=\"utf-8\"?><s:Envelope xmlns:s=\"http://schemas.xmlsoap.org/soap/envelope/\" \
         s:encodingStyle=\"http://schemas.xmlsoap.org/soap/encoding/\"><s:Body><u:{action} xmlns:u=\"{service}\">{args}</u:{action}></s:Body></s:Envelope>"
    )
}

async fn soap(http: &reqwest::Client, ip: &str, (path, service): (&str, &str), action: &str, args: &str) -> ApiResult<String> {
    let res = http
        .post(format!("http://{ip}:1400{path}"))
        .header("content-type", "text/xml; charset=utf-8")
        .header("soapaction", format!("\"{service}#{action}\""))
        .body(envelope(service, action, args))
        .timeout(TIMEOUT)
        .send()
        .await
        .map_err(|_| ApiError::BadGateway(format!("speaker {ip} not reachable")))?;
    let status = res.status();
    let body = res.text().await.unwrap_or_default();
    if !status.is_success() {
        let code = tag(&body, "errorCode").unwrap_or_default();
        return Err(ApiError::BadGateway(format!("speaker {ip}: {action} failed ({status}, UPnP error {code})")));
    }
    Ok(body)
}

/// Text content of the first `<name>` element.
fn tag(xml: &str, name: &str) -> Option<String> {
    let start = xml.find(&format!("<{name}>"))? + name.len() + 2;
    let end = xml[start..].find(&format!("</{name}>"))? + start;
    Some(xml[start..end].to_string())
}

fn unescape(s: &str) -> String {
    s.replace("&lt;", "<").replace("&gt;", ">").replace("&quot;", "\"").replace("&apos;", "'").replace("&amp;", "&")
}

/// "H:MM:SS" → milliseconds.
pub fn parse_time(s: &str) -> Option<i64> {
    let p: Vec<i64> = s.split(':').map(|x| x.split('.').next().unwrap_or("0").parse().ok()).collect::<Option<_>>()?;
    Some(p.iter().fold(0, |a, n| a * 60 + n) * 1000)
}

pub fn format_time(ms: i64) -> String {
    let s = ms.max(0) / 1000;
    format!("{}:{:02}:{:02}", s / 3600, (s % 3600) / 60, s % 60)
}

// ---------------------------------------------------------------- speakers

#[derive(Clone, Debug)]
pub struct Speaker {
    pub id: i64,
    pub ip: String,
    pub name: String,
    pub uuid: String,
    pub model: String,
    pub s2: bool,
}

/// Reads name, id and model from the speaker (no state is changed).
async fn describe(http: &reqwest::Client, ip: &str) -> ApiResult<(String, String, String, bool)> {
    let xml = http
        .get(format!("http://{ip}:1400/xml/device_description.xml"))
        .timeout(TIMEOUT)
        .send()
        .await
        .map_err(|_| ApiError::BadGateway(format!("no Sonos speaker at {ip}")))?
        .text()
        .await
        .map_err(|_| ApiError::BadGateway(format!("no Sonos speaker at {ip}")))?;
    let name = tag(&xml, "roomName").ok_or_else(|| ApiError::BadGateway(format!("no Sonos speaker at {ip}")))?;
    let uuid = tag(&xml, "UDN").unwrap_or_default().trim_start_matches("uuid:").to_string();
    let model = tag(&xml, "modelName").unwrap_or_default();
    // S2 system software starts at major version 60 (S1 ended with 57.x). Inferred, not documented.
    let major: i64 = tag(&xml, "softwareVersion").and_then(|v| v.split('.').next()?.parse().ok()).unwrap_or(0);
    Ok((name, uuid, model, major >= 60))
}

async fn speakers(state: &AppState) -> ApiResult<Vec<Speaker>> {
    with_db(&state.db, |c| {
        let mut stmt = c.prepare("SELECT id, ip, name, uuid, model, s2 FROM sonos_speaker ORDER BY name, ip")?;
        let rows = stmt
            .query_map([], |r| Ok(Speaker { id: r.get(0)?, ip: r.get(1)?, name: r.get(2)?, uuid: r.get(3)?, model: r.get(4)?, s2: r.get(5)? }))?
            .collect::<Result<Vec<_>, _>>()?;
        Ok(rows)
    })
    .await
}

async fn speaker(state: &AppState, id: i64) -> ApiResult<Speaker> {
    speakers(state).await?.into_iter().find(|s| s.id == id).ok_or(ApiError::NotFound)
}

/// Group coordinator of a speaker (playback commands go there), as IP.
async fn coordinator(state: &AppState, sp: &Speaker) -> ApiResult<String> {
    let xml = soap(&state.http, &sp.ip, ZGT, "GetZoneGroupState", "").await?;
    let groups = unescape(&tag(&xml, "ZoneGroupState").unwrap_or_default());
    for g in groups.split("<ZoneGroup ").skip(1) {
        if g.contains(&sp.uuid) {
            let coord = g.split("Coordinator=\"").nth(1).and_then(|r| r.split('"').next()).unwrap_or_default();
            for m in g.split("<ZoneGroupMember ").skip(1) {
                if m.contains(&format!("UUID=\"{coord}\"")) {
                    if let Some(ip) = m.split("Location=\"http://").nth(1).and_then(|r| r.split(':').next()) {
                        return Ok(ip.to_string());
                    }
                }
            }
        }
    }
    Ok(sp.ip.clone())
}

async fn status_of(state: &AppState, sp: &Speaker) -> Value {
    let mut out = json!({ "id": sp.id, "ip": sp.ip, "name": sp.name, "model": sp.model, "s2": sp.s2, "reachable": false });
    let Ok(coord) = coordinator(state, sp).await else {
        return out;
    };
    let transport = soap(&state.http, &coord, AVT, "GetTransportInfo", "<InstanceID>0</InstanceID>").await.ok();
    let pos = soap(&state.http, &coord, AVT, "GetPositionInfo", "<InstanceID>0</InstanceID>").await.ok();
    let volume = soap(&state.http, &sp.ip, RC, "GetVolume", "<InstanceID>0</InstanceID><Channel>Master</Channel>").await.ok();
    let uri = pos.as_deref().and_then(|p| tag(p, "TrackURI")).map(|u| unescape(&u)).unwrap_or_default();
    let ours = decode_uri(state, &uri);
    let o = out.as_object_mut().unwrap();
    o.insert("reachable".into(), json!(true));
    o.insert("coordinator".into(), json!(coord));
    o.insert("state".into(), json!(transport.as_deref().and_then(|t| tag(t, "CurrentTransportState"))));
    o.insert("volume".into(), json!(volume.as_deref().and_then(|v| tag(v, "CurrentVolume")).and_then(|v| v.parse::<i64>().ok())));
    o.insert("position_ms".into(), json!(ours.as_ref().and_then(|c| pos.as_deref().and_then(|p| tag(p, "RelTime")).and_then(|t| parse_time(&t)).map(|ms| ms + c.offset_ms))));
    o.insert("item_key".into(), json!(ours.map(|c| c.key)));
    out
}

// ---------------------------------------------------------------- signed stream URLs

#[derive(Serialize, Deserialize, Clone, Debug)]
pub struct Claim {
    pub user: i64,
    pub key: String,
    #[serde(default)]
    pub part: Option<usize>,
    /// Part start within the whole item (for the position of multi-file books).
    #[serde(default)]
    pub offset_ms: i64,
    pub profile: String,
    pub exp: i64,
    /// Name of the speaker (for the device name of positions).
    pub room: String,
}

type HmacSha256 = Hmac<Sha256>;
const B64: base64::engine::GeneralPurpose = base64::engine::general_purpose::URL_SAFE_NO_PAD;

pub fn sign(secret: &[u8], c: &Claim) -> String {
    let payload = B64.encode(serde_json::to_vec(c).unwrap());
    let mut mac = HmacSha256::new_from_slice(secret).unwrap();
    mac.update(payload.as_bytes());
    format!("{payload}.{}", B64.encode(mac.finalize().into_bytes()))
}

pub fn verify(secret: &[u8], token: &str) -> Option<Claim> {
    let (payload, sig) = token.split_once('.')?;
    let mut mac = HmacSha256::new_from_slice(secret).ok()?;
    mac.update(payload.as_bytes());
    mac.verify_slice(&B64.decode(sig).ok()?).ok()?;
    let c: Claim = serde_json::from_slice(&B64.decode(payload).ok()?).ok()?;
    (c.exp > Utc::now().timestamp()).then_some(c)
}

fn decode_uri(state: &AppState, uri: &str) -> Option<Claim> {
    let token = uri.split("/sonos/").nth(1)?.split(['?', '#']).next()?;
    verify(&state.sonos_secret, token)
}

/// Second listener, LAN only: `GET /sonos/<signed token>` relays the stream.
pub fn lan_router(state: AppState) -> Router {
    Router::new().route("/sonos/{token}", get(lan_stream)).with_state(state)
}

async fn lan_stream(State(state): State<AppState>, Path(token): Path<String>, headers: HeaderMap) -> Response {
    let token = token.trim_end_matches(".mp3").trim_end_matches(".flac").to_string();
    let Some(c) = verify(&state.sonos_secret, &token) else {
        return StatusCode::FORBIDDEN.into_response();
    };
    let user = CurrentUser { id: c.user, name: String::new(), session_id: 0, device: format!("Sonos {}", c.room) };
    media::stream_for(&state, &user, &c.key, c.part.unwrap_or(0), &c.profile, &headers)
        .await
        .unwrap_or_else(|e| e.into_response())
}

// ---------------------------------------------------------------- handlers

pub async fn list(State(state): State<AppState>, _user: CurrentUser) -> ApiResult<Json<Value>> {
    let list = speakers(&state).await?;
    let futures = list.iter().map(|sp| status_of(&state, sp));
    Ok(Json(Value::Array(futures_util::future::join_all(futures).await)))
}

#[derive(Deserialize)]
pub struct AddSpeaker {
    ip: String,
}

async fn add_ip(state: &AppState, ip: &str) -> ApiResult<Value> {
    ip.parse::<std::net::Ipv4Addr>().map_err(|_| ApiError::BadRequest("IPv4 address expected".into()))?;
    let (name, uuid, model, s2) = describe(&state.http, ip).await?;
    let ip = ip.to_string();
    with_db(&state.db, move |c| {
        c.execute(
            "INSERT INTO sonos_speaker (ip, name, uuid, model, s2) VALUES (?1, ?2, ?3, ?4, ?5)
             ON CONFLICT (ip) DO UPDATE SET name = excluded.name, uuid = excluded.uuid, model = excluded.model, s2 = excluded.s2",
            (&ip, &name, &uuid, &model, s2),
        )?;
        Ok(json!({ "ip": ip, "name": name, "model": model, "s2": s2 }))
    })
    .await
}

pub async fn add(State(state): State<AppState>, _user: CurrentUser, Json(req): Json<AddSpeaker>) -> ApiResult<Json<Value>> {
    add_ip(&state, req.ip.trim()).await.map(Json)
}

/// Probes the configured address range (unicast HTTP, no multicast) and adds what answers.
pub async fn scan(State(state): State<AppState>, _user: CurrentUser) -> ApiResult<Json<Value>> {
    let Some(range) = state.config.sonos.as_ref().and_then(|s| s.scan.clone()) else {
        return Err(ApiError::BadRequest("no sonos.scan range configured".into()));
    };
    let (from, to) = range.split_once('-').ok_or_else(|| ApiError::BadRequest("range a.b.c.d-a.b.c.e".into()))?;
    let a: std::net::Ipv4Addr = from.trim().parse().map_err(|_| ApiError::BadRequest("bad range".into()))?;
    let b: std::net::Ipv4Addr = to.trim().parse().map_err(|_| ApiError::BadRequest("bad range".into()))?;
    let (a, b) = (u32::from(a), u32::from(b));
    if b < a || b - a > 64 {
        return Err(ApiError::BadRequest("range of at most 64 addresses".into()));
    }
    let probes = (a..=b).map(|n| {
        let st = state.clone();
        async move { add_ip(&st, &std::net::Ipv4Addr::from(n).to_string()).await.ok() }
    });
    let found: Vec<Value> = futures_util::future::join_all(probes).await.into_iter().flatten().collect();
    Ok(Json(Value::Array(found)))
}

pub async fn remove(State(state): State<AppState>, _user: CurrentUser, Path(id): Path<i64>) -> ApiResult<Json<Value>> {
    with_db(&state.db, move |c| {
        if c.execute("DELETE FROM sonos_speaker WHERE id = ?1", [id])? == 0 {
            return Err(ApiError::NotFound);
        }
        Ok(Json(json!({ "ok": true })))
    })
    .await
}

#[derive(Deserialize)]
pub struct PlayRequest {
    key: String,
    #[serde(default)]
    position_ms: i64,
}

/// Plays an item on the speaker's group, starting at a position.
pub async fn play(
    State(state): State<AppState>,
    user: CurrentUser,
    Path(id): Path<i64>,
    Json(req): Json<PlayRequest>,
) -> ApiResult<Json<Value>> {
    let lan = state.config.sonos.as_ref().and_then(|s| s.listen).ok_or_else(|| ApiError::BadRequest("sonos.listen not configured".into()))?;
    let sp = speaker(&state, id).await?;
    let coord = coordinator(&state, &sp).await?;
    let meta = media::meta_for(&state, &user, &req.key).await?;
    // Multi-file books: the file containing the position.
    let parts = meta["parts"].as_array().cloned().unwrap_or_default();
    let (part, offset) = parts
        .iter()
        .filter(|p| p["start_ms"].as_i64().unwrap_or(0) <= req.position_ms)
        .last()
        .map(|p| (Some(p["index"].as_u64().unwrap_or(0) as usize), p["start_ms"].as_i64().unwrap_or(0)))
        .unwrap_or((None, 0));
    let claim = Claim {
        user: user.id,
        key: req.key.clone(),
        part: if parts.len() > 1 { part } else { None },
        offset_ms: if parts.len() > 1 { offset } else { 0 },
        profile: if sp.s2 { "sonos-s2" } else { "sonos-s1" }.into(),
        exp: Utc::now().timestamp() + URL_HOURS * 3600,
        room: sp.name.clone(),
    };
    let token = sign(&state.sonos_secret, &claim);
    let live = meta["kind"] == "radio";
    let url = if live { format!("x-rincon-mp3radio://{lan}/sonos/{token}") } else { format!("http://{lan}/sonos/{token}") };
    let didl = didl(&meta, &url);
    soap(&state.http, &coord, AVT, "SetAVTransportURI",
         &format!("<InstanceID>0</InstanceID><CurrentURI>{}</CurrentURI><CurrentURIMetaData>{}</CurrentURIMetaData>", xml_escape(&url), xml_escape(&didl))).await?;
    let local = req.position_ms - claim.offset_ms;
    if !live && local > 1000 {
        // Some sources are not seekable before playback starts; ignore that error.
        let _ = soap(&state.http, &coord, AVT, "Seek",
                     &format!("<InstanceID>0</InstanceID><Unit>REL_TIME</Unit><Target>{}</Target>", format_time(local))).await;
    }
    soap(&state.http, &coord, AVT, "Play", "<InstanceID>0</InstanceID><Speed>1</Speed>").await?;
    Ok(Json(json!({ "ok": true, "speaker": sp.name, "coordinator": coord })))
}

fn didl(meta: &Value, url: &str) -> String {
    let class = if meta["kind"] == "radio" { "object.item.audioItem.audioBroadcast" } else { "object.item.audioItem.musicTrack" };
    format!(
        "<DIDL-Lite xmlns:dc=\"http://purl.org/dc/elements/1.1/\" xmlns:upnp=\"urn:schemas-upnp-org:metadata-1-0/upnp/\" \
         xmlns:r=\"urn:schemas-rinconnetworks-com:metadata-1-0/\" xmlns=\"urn:schemas-upnp-org:metadata-1-0/DIDL-Lite/\">\
         <item id=\"audiojoe\" parentID=\"audiojoe\" restricted=\"true\"><dc:title>{}</dc:title><dc:creator>{}</dc:creator>\
         <upnp:class>{class}</upnp:class><res protocolInfo=\"http-get:*:*:*\">{}</res></item></DIDL-Lite>",
        xml_escape(meta["title"].as_str().unwrap_or("audiojoe")),
        xml_escape(meta["subtitle"].as_str().unwrap_or("")),
        xml_escape(url),
    )
}

#[derive(Deserialize)]
pub struct Command {
    action: String,
    volume: Option<i64>,
}

/// pause | resume | stop | volume
pub async fn command(
    State(state): State<AppState>,
    _user: CurrentUser,
    Path(id): Path<i64>,
    Json(cmd): Json<Command>,
) -> ApiResult<Json<Value>> {
    let sp = speaker(&state, id).await?;
    let coord = coordinator(&state, &sp).await?;
    match cmd.action.as_str() {
        "pause" => soap(&state.http, &coord, AVT, "Pause", "<InstanceID>0</InstanceID>").await?,
        "resume" => soap(&state.http, &coord, AVT, "Play", "<InstanceID>0</InstanceID><Speed>1</Speed>").await?,
        "stop" => soap(&state.http, &coord, AVT, "Stop", "<InstanceID>0</InstanceID>").await?,
        "volume" => {
            let v = cmd.volume.ok_or_else(|| ApiError::BadRequest("volume 0–100 required".into()))?.clamp(0, 100);
            soap(&state.http, &sp.ip, RC, "SetVolume", &format!("<InstanceID>0</InstanceID><Channel>Master</Channel><DesiredVolume>{v}</DesiredVolume>")).await?
        }
        _ => return Err(ApiError::BadRequest("action: pause | resume | stop | volume".into())),
    };
    Ok(Json(json!({ "ok": true })))
}

/// Stores the position of speakers that play one of our streams.
pub async fn poll_loop(state: AppState) {
    let mut last: HashMap<String, i64> = HashMap::new();
    loop {
        tokio::time::sleep(POLL_EVERY).await;
        let Ok(list) = speakers(&state).await else { continue };
        let mut coords = std::collections::HashSet::new();
        for sp in list {
            let Ok(coord) = coordinator(&state, &sp).await else { continue };
            if !coords.insert(coord.clone()) {
                continue;
            }
            let Ok(pos) = soap(&state.http, &coord, AVT, "GetPositionInfo", "<InstanceID>0</InstanceID>").await else { continue };
            let uri = unescape(&tag(&pos, "TrackURI").unwrap_or_default());
            let Some(c) = decode_uri(&state, &uri) else { continue };
            if c.key.starts_with("radio:") {
                continue;
            }
            let Some(ms) = tag(&pos, "RelTime").and_then(|t| parse_time(&t)) else { continue };
            let global = c.offset_ms + ms;
            if last.get(&coord).is_some_and(|&p| (p - global).abs() < 2000) {
                continue; // paused or unchanged
            }
            last.insert(coord.clone(), global);
            let ext = playback::External {
                position_ms: global,
                duration_ms: None,
                finished: false,
                updated_at: Utc::now(),
                title: String::new(),
                subtitle: String::new(),
            };
            let _ = playback::apply_external(&state, c.user, &format!("Sonos {}", c.room), &c.key, ext).await;
        }
    }
}

pub fn lan_addr(state: &AppState) -> Option<SocketAddr> {
    state.config.sonos.as_ref().and_then(|s| s.listen)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn times() {
        assert_eq!(parse_time("0:14:02"), Some(842_000));
        assert_eq!(parse_time("1:02:03.250"), Some(3_723_000));
        assert_eq!(format_time(3_723_000), "1:02:03");
    }

    #[test]
    fn tokens() {
        let secret = b"0123456789abcdef0123456789abcdef";
        let c = Claim { user: 1, key: "episode:5".into(), part: None, offset_ms: 0, profile: "sonos-s2".into(),
                        exp: Utc::now().timestamp() + 60, room: "Büro".into() };
        let t = sign(secret, &c);
        assert_eq!(verify(secret, &t).unwrap().key, "episode:5");
        assert!(verify(b"another-secret-another-secret-xx", &t).is_none());
        let mut tampered = t.clone();
        tampered.replace_range(0..1, if t.starts_with('e') { "f" } else { "e" });
        assert!(verify(secret, &tampered).is_none());
        let old = Claim { exp: Utc::now().timestamp() - 1, ..c };
        assert!(verify(secret, &sign(secret, &old)).is_none());
    }

    #[test]
    fn escaping() {
        assert_eq!(xml_escape("a<b>&\"c\""), "a&lt;b&gt;&amp;&quot;c&quot;");
        assert_eq!(unescape(&xml_escape("x & <y>")), "x & <y>");
    }
}
