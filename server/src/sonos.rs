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
//!
//! "Play there" opens a session per room (`sonos_session`, kept across restarts): the queue
//! it plays, its state and position. A stop, a takeover or the speaker playing something
//! else ends it; the user's devices get an event `sonos` and the room's `device` row.

use std::{
    collections::HashMap,
    net::SocketAddr,
    time::{Duration, Instant},
};

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
    devices, media, playback, AppState,
};

const START_TIMEOUT: Duration = Duration::from_secs(20);
const TIMEOUT: Duration = Duration::from_secs(3);
/// Stream URLs stay valid this long (Sonos re-requests ranges while playing).
const URL_HOURS: i64 = 24;
/// Coordinators with a session are asked this often (and right after each command) …
const POLL_EVERY: Duration = Duration::from_secs(5);
/// … without one only this often.
const IDLE_EVERY: Duration = Duration::from_secs(30);
/// A session whose speaker answers but stays stopped this long has ended.
const STOPPED_GRACE: Duration = Duration::from_secs(20);
/// A session whose speaker gives no full answer this long has ended (switched off, gone from the network).
/// A speaker on a weak network misses single rounds while it plays on; that alone does not end its
/// session (Badezimmer 2026-11-11: answered every few seconds, the session ended after 20 s).
const UNREACHABLE_GRACE: Duration = Duration::from_secs(120);
/// A title counts as heard when its last position lay this close to its end.
const HEARD_TAIL_MS: i64 = 30_000;

// ---------------------------------------------------------------- SOAP

const AVT: (&str, &str) = ("/MediaRenderer/AVTransport/Control", "urn:schemas-upnp-org:service:AVTransport:1");
const RC: (&str, &str) = ("/MediaRenderer/RenderingControl/Control", "urn:schemas-upnp-org:service:RenderingControl:1");
const ZGT: (&str, &str) = ("/ZoneGroupTopology/Control", "urn:schemas-upnp-org:service:ZoneGroupTopology:1");
const GRC: (&str, &str) = ("/MediaRenderer/GroupRenderingControl/Control", "urn:schemas-upnp-org:service:GroupRenderingControl:1");

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
        // Starting playback waits until the speaker has opened the stream (ffmpeg start-up
        // for converted sources); everything else must answer fast, speakers may be off.
        .timeout(if matches!(action, "SetAVTransportURI" | "Seek" | "Play") { START_TIMEOUT } else { TIMEOUT })
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

/// A room in a group. Invisible members (the second speaker of a stereo pair, sub and
/// surrounds of a home theatre) belong to a visible one and are never grouped on their own.
#[derive(Clone, Debug, PartialEq)]
pub struct Member {
    pub uuid: String,
    pub name: String,
    pub ip: String,
    pub visible: bool,
}

#[derive(Clone, Debug, PartialEq)]
pub struct Group {
    pub coordinator: String,
    pub members: Vec<Member>,
}

impl Group {
    fn coordinator_ip(&self) -> Option<&str> {
        self.members.iter().find(|m| m.uuid == self.coordinator).map(|m| m.ip.as_str())
    }

    /// Visible rooms, the coordinator first.
    pub fn rooms(&self) -> Vec<&Member> {
        let mut r: Vec<&Member> = self.members.iter().filter(|m| m.visible).collect();
        r.sort_by_key(|m| m.uuid != self.coordinator);
        r
    }
}

fn attr(el: &str, name: &str) -> Option<String> {
    let start = el.find(&format!(" {name}=\""))? + name.len() + 3;
    Some(el[start..].split('"').next()?.to_string())
}

/// Groups from a `ZoneGroupState` document (already unescaped).
pub fn parse_groups(xml: &str) -> Vec<Group> {
    xml.split("<ZoneGroup ")
        .skip(1)
        .map(|g| {
            let head = format!(" {}", g.split('>').next().unwrap_or_default());
            let members = g
                .split('<')
                .filter(|e| e.starts_with("ZoneGroupMember ") || e.starts_with("Satellite "))
                .filter_map(|e| {
                    let e = format!(" {}", e.split_once(' ')?.1);
                    let ip = attr(&e, "Location")?.trim_start_matches("http://").split(':').next()?.to_string();
                    Some(Member { uuid: attr(&e, "UUID")?, name: attr(&e, "ZoneName").unwrap_or_default(), ip, visible: attr(&e, "Invisible").as_deref() != Some("1") })
                })
                .collect();
            Group { coordinator: attr(&head, "Coordinator").unwrap_or_default(), members }
        })
        .collect()
}

/// Current groups, asked from the first speaker that answers.
async fn topology(state: &AppState, list: &[Speaker]) -> Vec<Group> {
    for sp in list {
        if let Ok(xml) = soap(&state.http, &sp.ip, ZGT, "GetZoneGroupState", "").await {
            return parse_groups(&unescape(&tag(&xml, "ZoneGroupState").unwrap_or_default()));
        }
    }
    Vec::new()
}

fn group_of<'a>(groups: &'a [Group], uuid: &str) -> Option<&'a Group> {
    groups.iter().find(|g| g.members.iter().any(|m| m.uuid == uuid))
}

/// Group coordinator of a speaker (playback commands go there), as IP.
async fn coordinator(state: &AppState, sp: &Speaker) -> ApiResult<String> {
    let xml = soap(&state.http, &sp.ip, ZGT, "GetZoneGroupState", "").await?;
    let groups = parse_groups(&unescape(&tag(&xml, "ZoneGroupState").unwrap_or_default()));
    Ok(group_of(&groups, &sp.uuid).and_then(|g| g.coordinator_ip()).unwrap_or(&sp.ip).to_string())
}

async fn status_of(state: &AppState, sp: &Speaker, all: &[Speaker], groups: &[Group], user: i64, sessions: &[Session]) -> Value {
    let mut out = json!({ "id": sp.id, "ip": sp.ip, "name": sp.name, "model": sp.model, "s2": sp.s2, "reachable": false });
    let Some(group) = group_of(groups, &sp.uuid) else {
        return out;
    };
    let Some(coord) = group.coordinator_ip().map(str::to_string) else {
        return out;
    };
    let rooms = group.rooms();
    let id_of = |uuid: &str| all.iter().find(|s| s.uuid == uuid).map(|s| s.id);
    let grouped = rooms.len() > 1;
    let group_volume = if grouped {
        soap(&state.http, &coord, GRC, "GetGroupVolume", "<InstanceID>0</InstanceID>").await.ok().and_then(|v| tag(&v, "CurrentVolume")).and_then(|v| v.parse::<i64>().ok())
    } else {
        None
    };
    let visible = group.members.iter().any(|m| m.uuid == sp.uuid && m.visible);
    let transport = soap(&state.http, &coord, AVT, "GetTransportInfo", "<InstanceID>0</InstanceID>").await.ok();
    let pos = soap(&state.http, &coord, AVT, "GetPositionInfo", "<InstanceID>0</InstanceID>").await.ok();
    let volume = soap(&state.http, &sp.ip, RC, "GetVolume", "<InstanceID>0</InstanceID><Channel>Master</Channel>").await.ok();
    let uri = pos.as_deref().and_then(|p| tag(p, "TrackURI")).map(|u| unescape(&u)).unwrap_or_default();
    let ours = decode_uri(state, &uri);
    let o = out.as_object_mut().unwrap();
    o.insert("reachable".into(), json!(true));
    o.insert("coordinator".into(), json!(coord));
    o.insert("visible".into(), json!(visible));
    o.insert("group".into(), json!(group.coordinator));
    o.insert("group_name".into(), json!(rooms.iter().map(|m| m.name.as_str()).collect::<Vec<_>>().join(" + ")));
    o.insert("group_rooms".into(), json!(rooms.iter().filter_map(|m| id_of(&m.uuid)).collect::<Vec<_>>()));
    o.insert("group_volume".into(), json!(group_volume));
    o.insert("state".into(), json!(transport.as_deref().and_then(|t| tag(t, "CurrentTransportState"))));
    o.insert("volume".into(), json!(volume.as_deref().and_then(|v| tag(v, "CurrentVolume")).and_then(|v| v.parse::<i64>().ok())));
    o.insert("position_ms".into(), json!(ours.as_ref().and_then(|c| pos.as_deref().and_then(|p| tag(p, "RelTime")).and_then(|t| parse_time(&t)).map(|ms| ms + c.offset_ms + c.start_ms))));
    let playing = matches!(o["state"].as_str(), Some("PLAYING" | "TRANSITIONING"));
    let session = sessions.iter().find(|s| s.coordinator == coord || group.members.iter().any(|m| all.iter().any(|a| a.id == s.room_id && a.uuid == m.uuid)));
    let busy = session.is_some_and(|s| s.user != user) || (playing && occupied(ours.as_ref().map(|c| c.user), &uri, user));
    o.insert("busy".into(), json!(busy));
    o.insert("session".into(), json!(session.filter(|s| s.user == user).map(|s| json!({
        "room": s.room_id, "state": s.state, "key": s.key, "started_by": s.started_by }))));
    o.insert("item_key".into(), json!(ours.map(|c| c.key)));
    // Remaining time of the speaker's own sleep timer (asked only while something of ours plays there).
    let sleep_s = if o["session"].is_null() {
        None
    } else {
        soap(&state.http, &coord, AVT, "GetRemainingSleepTimerDuration", "<InstanceID>0</InstanceID>").await.ok()
            .and_then(|r| tag(&r, "RemainingSleepTimerDuration")).and_then(|t| parse_time(&t)).map(|ms| ms / 1000)
    };
    o.insert("sleep_s".into(), json!(sleep_s));
    out
}

/// Whether a speaker plays something that is not this user's: another service, another user.
fn occupied(claim_user: Option<i64>, uri: &str, user: i64) -> bool {
    match claim_user {
        Some(u) => u != user,
        None => !uri.is_empty(),
    }
}

/// Whether a title whose last position was `at` has been heard to its end.
fn heard_to_end(at: i64, duration_ms: Option<i64>) -> bool {
    duration_ms.is_some_and(|d| d > 0 && at >= d - HEARD_TAIL_MS)
}

// ---------------------------------------------------------------- sessions

#[derive(Clone, Debug, PartialEq)]
pub struct Session {
    pub room_id: i64,
    pub room: String,
    pub coordinator: String,
    pub user: i64,
    pub key: String,
    pub queue: Vec<String>,
    pub idx: usize,
    pub state: String,
    pub position_ms: i64,
    pub started_by: String,
}

impl Session {
    fn device(&self) -> String {
        format!("Sonos {}", self.room)
    }
}

/// Sessions that have not ended.
fn load_sessions(c: &rusqlite::Connection) -> rusqlite::Result<Vec<Session>> {
    let mut st = c.prepare(
        "SELECT s.room_id, p.name, s.coordinator, s.user_id, s.item_key, s.queue, s.idx, s.state, s.position_ms, s.started_by
         FROM sonos_session s JOIN sonos_speaker p ON p.id = s.room_id WHERE s.state <> 'ended' ORDER BY s.room_id",
    )?;
    let rows = st.query_map([], |r| {
        Ok(Session {
            room_id: r.get(0)?,
            room: r.get(1)?,
            coordinator: r.get(2)?,
            user: r.get(3)?,
            key: r.get(4)?,
            queue: serde_json::from_str(&r.get::<_, String>(5)?).unwrap_or_default(),
            idx: r.get::<_, i64>(6)?.max(0) as usize,
            state: r.get(7)?,
            position_ms: r.get(8)?,
            started_by: r.get(9)?,
        })
    })?;
    rows.collect()
}

/// Opens (or replaces) the session of a room; a group has one session at its coordinator.
fn open_session(c: &rusqlite::Connection, s: &Session) -> rusqlite::Result<()> {
    let now = playback::now();
    c.execute("DELETE FROM sonos_session WHERE coordinator = ?1 AND room_id <> ?2", (&s.coordinator, s.room_id))?;
    c.execute(
        "INSERT INTO sonos_session (room_id, coordinator, user_id, item_key, queue, idx, state, position_ms, started_by,
                                    started_at, updated_at)
         VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?10)
         ON CONFLICT (room_id) DO UPDATE SET coordinator = excluded.coordinator, user_id = excluded.user_id,
           item_key = excluded.item_key, queue = excluded.queue, idx = excluded.idx, state = excluded.state,
           position_ms = excluded.position_ms, started_by = excluded.started_by, started_at = excluded.started_at,
           updated_at = excluded.updated_at",
        (s.room_id, &s.coordinator, s.user, &s.key, serde_json::to_string(&s.queue).unwrap(), s.idx as i64, &s.state,
         s.position_ms, &s.started_by, &now),
    )?;
    Ok(())
}

fn save_session(c: &rusqlite::Connection, s: &Session) -> rusqlite::Result<()> {
    c.execute(
        "UPDATE sonos_session SET coordinator = ?2, item_key = ?3, idx = ?4, state = ?5, position_ms = ?6, updated_at = ?7
         WHERE room_id = ?1",
        (s.room_id, &s.coordinator, &s.key, s.idx as i64, &s.state, s.position_ms, playback::now()),
    )?;
    Ok(())
}

async fn sessions(state: &AppState) -> Vec<Session> {
    with_db(&state.db, |c| Ok(load_sessions(c)?)).await.unwrap_or_default()
}

/// The queue the device last played, as keys, if it contains `key`; else just `key`.
fn queue_of(c: &rusqlite::Connection, user: i64, device: &str, key: &str) -> (Vec<String>, usize) {
    let data: Option<String> =
        c.query_row("SELECT data FROM queue WHERE user_id = ?1 AND device = ?2", (user, device), |r| r.get(0)).ok();
    let keys: Vec<String> = data
        .and_then(|d| serde_json::from_str::<Value>(&d).ok())
        .and_then(|q| q["items"].as_array().map(|a| a.iter().filter_map(|i| i["key"].as_str().map(str::to_string)).collect()))
        .unwrap_or_default();
    match keys.iter().position(|k| k == key) {
        Some(i) => (keys, i),
        None => (vec![key.to_string()], 0),
    }
}

/// Stores the session's room as a device (kind `sonos`) and tells the user's devices.
async fn report_room(state: &AppState, s: &Session, title: &str, subtitle: &str, duration_ms: Option<i64>) {
    let (s2, t, st, now) = (s.clone(), title.to_string(), subtitle.to_string(), playback::now());
    let dev_state = match s.state.as_str() {
        "playing" => "playing",
        "paused" => "paused",
        _ => "stopped",
    };
    let stored = with_db(&state.db, move |c| {
        let r = devices::Report { kind: Some("sonos"), state: dev_state, key: &s2.key, title: &t, subtitle: &st,
                                  position_ms: s2.position_ms, duration_ms, queue_index: Some(s2.idx as i64), updated_at: &now };
        Ok(devices::report(c, s2.user, &s2.device(), &r)?)
    })
    .await;
    if stored.unwrap_or(false) {
        devices::notify(state, s.user, &s.device()).await;
    }
}

/// Ends a session: stopped, taken over, or the speaker plays something else.
async fn end_session(state: &AppState, s: &Session, reason: &str) {
    let mut e = s.clone();
    e.state = "ended".into();
    let e2 = e.clone();
    let _ = with_db(&state.db, move |c| Ok(save_session(c, &e2)?)).await;
    tracing::info!("sonos {}: session ended ({reason})", s.room);
    report_room(state, &e, "", "", None).await;
    let _ = state.events.send((s.user, json!({ "type": "sonos", "room": s.room_id, "state": "ended", "reason": reason,
                                                "key": s.key, "position_ms": s.position_ms }))); 
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
    /// Start within the file for converted streams, which the speaker cannot seek.
    #[serde(default, skip_serializing_if = "is_zero")]
    pub start_ms: i64,
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

/// Checks a token; a trailing file extension (`.mp3`, not signed) is ignored.
fn is_zero(n: &i64) -> bool {
    *n == 0
}

pub fn verify(secret: &[u8], token: &str) -> Option<Claim> {
    let (payload, sig) = token.split_once('.')?;
    let sig = sig.split_once('.').map_or(sig, |(s, _)| s);
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
    let Some(c) = verify(&state.sonos_secret, &token) else {
        return StatusCode::FORBIDDEN.into_response();
    };
    media::stream_for(&state, &stream_user(&c), &c.key, c.part.unwrap_or(0), &c.profile, c.start_ms, &headers)
        .await
        .unwrap_or_else(|e| e.into_response())
}

// ---------------------------------------------------------------- handlers

pub async fn list(State(state): State<AppState>, user: CurrentUser) -> ApiResult<Json<Value>> {
    let list = speakers(&state).await?;
    let groups = topology(&state, &list).await;
    let open = sessions(&state).await;
    let futures = list.iter().map(|sp| status_of(&state, sp, &list, &groups, user.id, &open));
    Ok(Json(Value::Array(futures_util::future::join_all(futures).await)))
}

/// Whether Sonos is set up on this server (stream port) and the range "scan" probes.
pub async fn setup(State(state): State<AppState>, _user: CurrentUser) -> Json<Value> {
    let cfg = state.config.sonos.as_ref();
    Json(json!({ "enabled": cfg.and_then(|s| s.listen).is_some(), "scan": cfg.and_then(|s| s.scan.clone()) }))
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

/// Plays an item on the speaker's group, starting at a position, and opens the room's
/// session with the calling device's queue.
pub async fn play(
    State(state): State<AppState>,
    user: CurrentUser,
    Path(id): Path<i64>,
    Json(req): Json<PlayRequest>,
) -> ApiResult<Json<Value>> {
    let sp = speaker(&state, id).await?;
    let coord = coordinator(&state, &sp).await?;
    let open = sessions(&state).await;
    if open.iter().any(|s| (s.room_id == id || s.coordinator == coord) && s.user != user.id) {
        return Err(ApiError::Conflict("speaker is busy".into()));
    }
    // Playback that starts on the speaker (no session of ours there yet) begins at the account's start volume,
    // each room of a group alike (0.3.1, user 2026-11-11 „204 ja“). A new title in a running session keeps
    // the volume the user has set.
    if !open.iter().any(|s| s.room_id == id || s.coordinator == coord) {
        let uid = user.id;
        let v = with_db(&state.db, move |c| Ok(crate::prefs::read_sonos(c, uid)?)).await
            .ok().and_then(|s| s["start_volume"].as_i64()).unwrap_or(crate::prefs::SONOS_START_VOLUME);
        let ips: Vec<String> = match room(&state, &sp).await {
            Ok((_, g)) => g.rooms().iter().map(|m| m.ip.clone()).collect(),
            Err(_) => vec![sp.ip.clone()],
        };
        for ip in ips {
            if let Err(e) = soap(&state.http, &ip, RC, "SetVolume",
                                 &format!("<InstanceID>0</InstanceID><Channel>Master</Channel><DesiredVolume>{v}</DesiredVolume>")).await {
                tracing::warn!("sonos {ip}: start volume not set: {e:?}");
            }
        }
    }
    start(&state, &user, &sp, &coord, &req.key, req.position_ms).await?;
    let (uid, dev, key) = (user.id, user.device.clone(), req.key.clone());
    let (queue, idx) = with_db(&state.db, move |c| Ok(queue_of(c, uid, &dev, &key))).await?;
    let s = Session { room_id: sp.id, room: sp.name.clone(), coordinator: coord.clone(), user: user.id, key: req.key.clone(),
                      queue, idx, state: "playing".into(), position_ms: req.position_ms, started_by: user.device.clone() };
    let s2 = s.clone();
    with_db(&state.db, move |c| Ok(open_session(c, &s2)?)).await?;
    let meta = media::meta_for(&state, &user, &req.key).await.unwrap_or(Value::Null);
    report_room(&state, &s, meta["title"].as_str().unwrap_or(""), meta["subtitle"].as_str().unwrap_or(""), meta["duration_ms"].as_i64()).await;
    state.sonos_poke.notify_one();
    Ok(Json(json!({ "ok": true, "speaker": sp.name, "coordinator": coord })))
}

/// Sends an item to a coordinator, starting at a position, and queues what follows.
async fn start(state: &AppState, user: &CurrentUser, sp: &Speaker, coord: &str, key: &str, position_ms: i64) -> ApiResult<()> {
    let lan = state.config.sonos.as_ref().and_then(|s| s.listen).ok_or_else(|| ApiError::BadRequest("sonos.listen not configured".into()))?;
    let req = PlayRequest { key: key.to_string(), position_ms };
    let meta = media::meta_for(state, user, &req.key).await?;
    // Multi-file books: the file containing the position.
    let parts = meta["parts"].as_array().cloned().unwrap_or_default();
    let (part, offset) = parts
        .iter()
        .filter(|p| p["start_ms"].as_i64().unwrap_or(0) <= req.position_ms)
        .last()
        .map(|p| (Some(p["index"].as_u64().unwrap_or(0) as usize), p["start_ms"].as_i64().unwrap_or(0)))
        .unwrap_or((None, 0));
    let profile = if sp.s2 { "sonos-s2" } else { "sonos-s1" };
    let offset_ms = if parts.len() > 1 { offset } else { 0 };
    let local = req.position_ms - offset_ms;
    let converted = media::conversion(&meta["quality"], profile)?.is_some();
    let claim = Claim {
        user: user.id,
        key: req.key.clone(),
        part: if parts.len() > 1 { part } else { None },
        offset_ms,
        start_ms: if converted && local > 1000 { local } else { 0 },
        profile: profile.into(),
        exp: Utc::now().timestamp() + URL_HOURS * 3600,
        room: sp.name.clone(),
    };
    let live = meta["kind"] == "radio";
    let (url, didl) = track(state, lan, &meta, &claim);
    soap(&state.http, coord, AVT, "SetAVTransportURI",
         &format!("<InstanceID>0</InstanceID><CurrentURI>{}</CurrentURI><CurrentURIMetaData>{}</CurrentURIMetaData>", xml_escape(&url), xml_escape(&didl))).await?;
    if !live && !converted && local > 1000 {
        // Some sources are not seekable before playback starts; ignore that error.
        let _ = soap(&state.http, coord, AVT, "Seek",
                     &format!("<InstanceID>0</InstanceID><Unit>REL_TIME</Unit><Target>{}</Target>", format_time(local))).await;
    }
    soap(&state.http, coord, AVT, "Play", "<InstanceID>0</InstanceID><Speed>1</Speed>").await?;
    queue_next(state, lan, coord, &meta, &claim).await;
    Ok(())
}

/// Moves to a position: a seek within the file the speaker plays, else the stream anew
/// (converted streams cannot seek; multi-file books may need another file).
async fn seek(state: &AppState, user: &CurrentUser, sp: &Speaker, coord: &str, key: &str, position_ms: i64) -> ApiResult<()> {
    let pos = soap(&state.http, coord, AVT, "GetPositionInfo", "<InstanceID>0</InstanceID>").await?;
    let claim = decode_uri(state, &unescape(&tag(&pos, "TrackURI").unwrap_or_default()));
    if let Some(c) = claim.filter(|c| c.key == key && c.start_ms == 0) {
        let meta = media::meta_for(state, user, key).await?;
        let converted = media::conversion(&meta["quality"], &c.profile)?.is_some();
        let parts = meta["parts"].as_array().cloned().unwrap_or_default();
        let end = parts.iter().find(|p| p["start_ms"].as_i64() == Some(c.offset_ms)).and_then(|p| p["duration_ms"].as_i64()).map(|d| c.offset_ms + d);
        let same_file = parts.len() < 2 || (position_ms >= c.offset_ms && end.is_none_or(|e| position_ms < e));
        if !converted && same_file {
            soap(&state.http, coord, AVT, "Seek",
                 &format!("<InstanceID>0</InstanceID><Unit>REL_TIME</Unit><Target>{}</Target>", format_time(position_ms - c.offset_ms))).await?;
            return Ok(());
        }
    }
    start(state, user, sp, coord, key, position_ms).await
}

/// Signed stream URL and DIDL metadata for the file a claim describes.
fn track(state: &AppState, lan: SocketAddr, meta: &Value, claim: &Claim) -> (String, String) {
    let token = sign(&state.sonos_secret, claim);
    let converted = matches!(media::conversion(&meta["quality"], &claim.profile), Ok(Some(_)));
    let (ext, mime) = file_type(&meta["quality"], converted);
    let url = if meta["kind"] == "radio" { format!("x-rincon-mp3radio://{lan}/sonos/{token}") } else { format!("http://{lan}/sonos/{token}.{ext}") };
    let didl = didl(meta, &url, mime);
    (url, didl)
}

/// Hands the speaker what follows, so it continues on its own: the next file of a multi-file
/// book, else the next title of the queue the item was played from (an album, a list).
async fn queue_next(state: &AppState, lan: SocketAddr, coord: &str, meta: &Value, claim: &Claim) {
    let next_part = claim.part.and_then(|part| meta["parts"].as_array().and_then(|p| p.get(part + 1)).map(|n| (part + 1, n.clone())));
    let (meta, claim) = if let Some((part, next)) = next_part {
        let claim = Claim {
            part: Some(part),
            offset_ms: next["start_ms"].as_i64().unwrap_or(0),
            start_ms: 0,
            exp: Utc::now().timestamp() + URL_HOURS * 3600,
            ..claim.clone()
        };
        (meta.clone(), claim)
    } else {
        let Some(key) = next_in_queue(state, claim.user, &claim.key).await else { return };
        let Ok(meta) = media::meta_for(state, &stream_user(claim), &key).await else { return };
        if meta["kind"] == "radio" {
            return;
        }
        let multi = meta["parts"].as_array().is_some_and(|p| p.len() > 1);
        let claim = Claim {
            key,
            part: multi.then_some(0),
            offset_ms: 0,
            start_ms: 0,
            exp: Utc::now().timestamp() + URL_HOURS * 3600,
            ..claim.clone()
        };
        (meta, claim)
    };
    let (url, didl) = track(state, lan, &meta, &claim);
    if let Err(e) = soap(&state.http, coord, AVT, "SetNextAVTransportURI",
                         &format!("<InstanceID>0</InstanceID><NextURI>{}</NextURI><NextURIMetaData>{}</NextURIMetaData>", xml_escape(&url), xml_escape(&didl))).await {
        tracing::warn!("sonos {coord}: next title not queued: {e:?}");
    }
}

/// The title after `key` in the user's most recent queue that contains it.
async fn next_in_queue(state: &AppState, user: i64, key: &str) -> Option<String> {
    let key = key.to_string();
    with_db(&state.db, move |c| {
        let mut st = c.prepare("SELECT data FROM queue WHERE user_id = ?1 ORDER BY current_key = ?2 DESC, updated_at DESC")?;
        let rows: Vec<String> = st.query_map((user, &key), |r| r.get(0))?.collect::<Result<_, _>>()?;
        Ok(rows.iter().find_map(|d| {
            let q: Value = serde_json::from_str(d).ok()?;
            let items = q["items"].as_array()?;
            let i = items.iter().position(|it| it["key"] == key.as_str())?;
            items.get(i + 1)?["key"].as_str().map(str::to_string)
        }))
    })
    .await
    .ok()
    .flatten()
}

/// The owner of a stream, as seen by the media layer.
fn stream_user(c: &Claim) -> CurrentUser {
    CurrentUser { id: c.user, name: String::new(), session_id: 0, device: format!("Sonos {}", c.room) }
}

/// File extension and MIME type of what the speaker receives; Sonos rejects untyped URLs
/// (UPnP error 714) and does not play PCM announced as MP3.
fn file_type(quality: &Value, converted: bool) -> (&'static str, &'static str) {
    let codec = quality["codec"].as_str().unwrap_or("");
    if converted {
        return ("flac", "audio/flac");
    }
    if codec.starts_with("pcm_") || codec == "pcm" || codec == "wav" {
        return match quality["container"].as_str().unwrap_or("") {
            "aiff" | "aif" => ("aif", "audio/aiff"),
            _ => ("wav", "audio/wav"),
        };
    }
    match codec {
        "flac" => ("flac", "audio/flac"),
        "aac" | "mp4a" | "alac" => ("m4a", "audio/mp4"),
        "ogg" | "vorbis" => ("ogg", "application/ogg"),
        "opus" => ("opus", "audio/ogg"),
        _ => ("mp3", "audio/mpeg"),
    }
}

fn didl(meta: &Value, url: &str, mime: &str) -> String {
    let class = if meta["kind"] == "radio" { "object.item.audioItem.audioBroadcast" } else { "object.item.audioItem.musicTrack" };
    format!(
        "<DIDL-Lite xmlns:dc=\"http://purl.org/dc/elements/1.1/\" xmlns:upnp=\"urn:schemas-upnp-org:metadata-1-0/upnp/\" \
         xmlns:r=\"urn:schemas-rinconnetworks-com:metadata-1-0/\" xmlns=\"urn:schemas-upnp-org:metadata-1-0/DIDL-Lite/\">\
         <item id=\"audiojoe\" parentID=\"audiojoe\" restricted=\"true\"><dc:title>{}</dc:title><dc:creator>{}</dc:creator>\
         <upnp:class>{class}</upnp:class><res protocolInfo=\"http-get:*:{mime}:*\">{}</res></item></DIDL-Lite>",
        xml_escape(meta["title"].as_str().unwrap_or("audiojoe")),
        xml_escape(meta["subtitle"].as_str().unwrap_or("")),
        xml_escape(url),
    )
}

#[derive(Deserialize)]
pub struct Command {
    action: String,
    volume: Option<i64>,
    #[serde(default)]
    position_ms: Option<i64>,
    /// `sleep`: minutes until the speaker stops (its own sleep timer), 0 switches it off.
    #[serde(default)]
    minutes: Option<i64>,
}

/// Longest sleep time accepted (the Sonos app offers up to two hours).
const SLEEP_MAX_MINUTES: i64 = 180;

/// `NewSleepTimerDuration` for the speaker: "H:MM:SS", empty switches the timer off.
fn sleep_duration(minutes: i64) -> String {
    if minutes <= 0 { String::new() } else { format_time(minutes * 60_000) }
}

/// A visible room of the speaker's group, or an error for parts of pairs and home theatres.
async fn room(state: &AppState, sp: &Speaker) -> ApiResult<(Vec<Group>, Group)> {
    let groups = topology(state, std::slice::from_ref(sp)).await;
    let g = group_of(&groups, &sp.uuid).cloned().ok_or_else(|| ApiError::BadGateway(format!("speaker {} not reachable", sp.ip)))?;
    if !g.members.iter().any(|m| m.uuid == sp.uuid && m.visible) {
        return Err(ApiError::BadRequest("part of a stereo pair or home theatre; group its room instead".into()));
    }
    Ok((groups, g))
}

#[derive(Deserialize)]
pub struct Join {
    /// Any speaker of the group to join.
    to: i64,
}

/// Adds the speaker's room to another room's group (stereo pairs and home theatres move whole).
pub async fn join(State(state): State<AppState>, _user: CurrentUser, Path(id): Path<i64>, Json(req): Json<Join>) -> ApiResult<Json<Value>> {
    let sp = speaker(&state, id).await?;
    let target = speaker(&state, req.to).await?;
    room(&state, &sp).await?;
    let (_, g) = room(&state, &target).await?;
    if g.members.iter().any(|m| m.uuid == sp.uuid) {
        return Ok(Json(json!({ "ok": true })));
    }
    soap(&state.http, &sp.ip, AVT, "SetAVTransportURI",
         &format!("<InstanceID>0</InstanceID><CurrentURI>x-rincon:{}</CurrentURI><CurrentURIMetaData></CurrentURIMetaData>", g.coordinator)).await?;
    Ok(Json(json!({ "ok": true })))
}

/// Takes the speaker's room out of its group; the others keep playing.
pub async fn leave(State(state): State<AppState>, _user: CurrentUser, Path(id): Path<i64>) -> ApiResult<Json<Value>> {
    let sp = speaker(&state, id).await?;
    let (_, g) = room(&state, &sp).await?;
    if g.rooms().len() > 1 {
        soap(&state.http, &sp.ip, AVT, "BecomeCoordinatorOfStandaloneGroup", "<InstanceID>0</InstanceID>").await?;
    }
    Ok(Json(json!({ "ok": true })))
}

/// pause | resume | stop | volume (the whole group) | room_volume (this room only) |
/// next | prev (title of the session's queue) | seek (position_ms) | takeover (pauses, ends
/// the session and answers with the position, so the calling device continues there) |
/// sleep (minutes; the speaker's own sleep timer, so it stops without app and server; 0 = off)
pub async fn command(
    State(state): State<AppState>,
    user: CurrentUser,
    Path(id): Path<i64>,
    Json(cmd): Json<Command>,
) -> ApiResult<Json<Value>> {
    let sp = speaker(&state, id).await?;
    let coord = coordinator(&state, &sp).await?;
    let session = sessions(&state).await.into_iter().find(|s| s.room_id == id || s.coordinator == coord);
    if session.as_ref().is_some_and(|s| s.user != user.id) {
        return Err(ApiError::Conflict("speaker is busy".into()));
    }
    let need = || session.clone().ok_or_else(|| ApiError::BadRequest("nothing of ours plays there".into()));
    let mut answer = json!({ "ok": true });
    match cmd.action.as_str() {
        "pause" => soap(&state.http, &coord, AVT, "Pause", "<InstanceID>0</InstanceID>").await?,
        "resume" => soap(&state.http, &coord, AVT, "Play", "<InstanceID>0</InstanceID><Speed>1</Speed>").await?,
        "stop" => {
            let r = soap(&state.http, &coord, AVT, "Stop", "<InstanceID>0</InstanceID>").await?;
            if let Some(s) = &session {
                end_session(&state, s, "stop").await;
            }
            r
        }
        "next" | "prev" => {
            let mut s = need()?;
            let i = if cmd.action == "next" { s.idx + 1 } else { s.idx.checked_sub(1).ok_or_else(|| ApiError::BadRequest("no previous title".into()))? };
            let key = s.queue.get(i).cloned().ok_or_else(|| ApiError::BadRequest("no next title".into()))?;
            let room = speaker(&state, s.room_id).await?;
            start(&state, &user, &room, &coord, &key, 0).await?;
            (s.key, s.idx, s.position_ms, s.state) = (key, i, 0, "playing".into());
            let s2 = s.clone();
            with_db(&state.db, move |c| Ok(save_session(c, &s2)?)).await?;
            String::new()
        }
        "seek" => {
            let s = need()?;
            let at = cmd.position_ms.filter(|p| *p >= 0).ok_or_else(|| ApiError::BadRequest("position_ms required".into()))?;
            let room = speaker(&state, s.room_id).await?;
            seek(&state, &user, &room, &coord, &s.key, at).await?;
            String::new()
        }
        "takeover" => {
            let r = soap(&state.http, &coord, AVT, "Pause", "<InstanceID>0</InstanceID>").await?;
            let pos = soap(&state.http, &coord, AVT, "GetPositionInfo", "<InstanceID>0</InstanceID>").await?;
            if let Some(c) = decode_uri(&state, &unescape(&tag(&pos, "TrackURI").unwrap_or_default())).filter(|c| c.user == user.id) {
                let at = tag(&pos, "RelTime").and_then(|t| parse_time(&t)).map(|ms| ms + c.offset_ms + c.start_ms).unwrap_or(0);
                let ext = playback::External { position_ms: at, duration_ms: None, finished: false, updated_at: Utc::now(),
                                               title: String::new(), subtitle: String::new() };
                let _ = playback::apply_external(&state, user.id, &format!("Sonos {}", c.room), &c.key, ext).await;
                answer = json!({ "ok": true, "key": c.key, "position_ms": at });
                if let Some(mut s) = session.clone() {
                    s.position_ms = at;
                    end_session(&state, &s, "takeover").await;
                }
            }
            r
        }
        "volume" | "room_volume" => {
            let v = cmd.volume.ok_or_else(|| ApiError::BadRequest("volume 0–100 required".into()))?.clamp(0, 100);
            let grouped = cmd.action == "volume" && room(&state, &sp).await.is_ok_and(|(_, g)| g.rooms().len() > 1);
            if grouped {
                // Keeps the rooms' ratio, as the Sonos app does.
                soap(&state.http, &coord, GRC, "SnapshotGroupVolume", "<InstanceID>0</InstanceID>").await?;
                soap(&state.http, &coord, GRC, "SetGroupVolume", &format!("<InstanceID>0</InstanceID><DesiredVolume>{v}</DesiredVolume>")).await?
            } else {
                soap(&state.http, &sp.ip, RC, "SetVolume", &format!("<InstanceID>0</InstanceID><Channel>Master</Channel><DesiredVolume>{v}</DesiredVolume>")).await?
            }
        }
        "sleep" => {
            need()?;
            let m = cmd.minutes.filter(|m| (0..=SLEEP_MAX_MINUTES).contains(m))
                .ok_or_else(|| ApiError::BadRequest(format!("minutes 0–{SLEEP_MAX_MINUTES} required")))?;
            soap(&state.http, &coord, AVT, "ConfigureSleepTimer",
                 &format!("<InstanceID>0</InstanceID><NewSleepTimerDuration>{}</NewSleepTimerDuration>", sleep_duration(m))).await?
        }
        _ => return Err(ApiError::BadRequest("action: pause | resume | stop | volume | room_volume | next | prev | seek | takeover | sleep".into())),
    };
    state.sonos_poke.notify_one();
    Ok(Json(answer))
}

/// What the poll loop remembers between rounds.
#[derive(Default)]
struct Poller {
    /// Per coordinator: the last stored position, the track whose successor has been queued,
    /// and the item playing (user, room, key, position).
    last: HashMap<String, i64>,
    queued: HashMap<String, String>,
    playing: HashMap<String, (i64, String, String, i64)>,
    /// Title, subtitle and duration per item, so positions stored for the speaker carry them.
    titles: HashMap<String, (String, String, Option<i64>)>,
    /// Since when a session's speaker has answered as stopped …
    stopped_since: HashMap<i64, Instant>,
    /// … or has given no full answer (not counted as stopped).
    unreachable_since: HashMap<i64, Instant>,
    /// The reason last logged per address, so a switched-off speaker is logged once.
    warned: HashMap<String, String>,
}

impl Poller {
    /// Logs a failure once per address and again only when the reason changes.
    fn warn(&mut self, addr: &str, reason: &str) -> bool {
        if self.warned.get(addr).map(String::as_str) == Some(reason) {
            return false;
        }
        tracing::warn!("sonos {addr}: poll failed: {reason}");
        self.warned.insert(addr.to_string(), reason.to_string());
        true
    }

    fn ok(&mut self, addr: &str) {
        if self.warned.remove(addr).is_some() {
            tracing::info!("sonos {addr}: answers again");
        }
    }

    async fn title(&mut self, state: &AppState, c: &Claim) -> (String, String, Option<i64>) {
        if !self.titles.contains_key(&c.key) {
            if let Ok(meta) = media::meta_for(state, &stream_user(c), &c.key).await {
                let text = |k: &str| meta[k].as_str().unwrap_or_default().to_string();
                self.titles.insert(c.key.clone(), (text("title"), text("subtitle"), meta["duration_ms"].as_i64()));
            }
        }
        self.titles.get(&c.key).cloned().unwrap_or_default()
    }

    /// A session's speaker answered and did not play: ends the session after the grace time.
    async fn not_playing(&mut self, state: &AppState, s: &Session) {
        self.unreachable_since.remove(&s.room_id);
        let since = *self.stopped_since.entry(s.room_id).or_insert_with(Instant::now);
        if since.elapsed() >= STOPPED_GRACE {
            self.stopped_since.remove(&s.room_id);
            end_session(state, s, "stopped").await;
        }
    }

    /// A session's speaker gave no full answer: ends the session only after the longer grace time.
    async fn unreachable(&mut self, state: &AppState, s: &Session) {
        let since = *self.unreachable_since.entry(s.room_id).or_insert_with(Instant::now);
        if since.elapsed() >= UNREACHABLE_GRACE {
            self.unreachable_since.remove(&s.room_id);
            self.stopped_since.remove(&s.room_id);
            end_session(state, s, "unreachable").await;
        }
    }

    /// A session's speaker answered and plays (or ended it otherwise): both clocks start anew.
    fn answered(&mut self, room: i64) {
        self.stopped_since.remove(&room);
        self.unreachable_since.remove(&room);
    }
}

/// Follows sessions and stores the position of speakers that play one of our streams.
pub async fn poll_loop(state: AppState) {
    let mut p = Poller::default();
    loop {
        let wait = if sessions(&state).await.is_empty() { IDLE_EVERY } else { POLL_EVERY };
        tokio::select! {
            _ = tokio::time::sleep(wait) => {}
            _ = state.sonos_poke.notified() => {}
        }
        poll_once(&state, &mut p).await;
    }
}

async fn poll_once(state: &AppState, p: &mut Poller) {
    let Ok(list) = speakers(state).await else { return };
    // All at once: speakers that are switched off would otherwise hold up the round by their timeout.
    let found = futures_util::future::join_all(list.iter().map(|sp| coordinator(state, sp))).await;
    let mut coord_of: HashMap<i64, String> = HashMap::new();
    for (sp, r) in list.iter().zip(found) {
        match r {
            Ok(c) => {
                p.ok(&sp.ip);
                coord_of.insert(sp.id, c);
            }
            Err(e) => {
                p.warn(&sp.ip, &format!("{e:?}"));
            }
        }
    }
    // Sessions follow their room's group; a room that does not answer counts as unreachable, not as stopped.
    let mut open = Vec::new();
    for mut s in sessions(state).await {
        match coord_of.get(&s.room_id) {
            Some(c) => {
                s.coordinator = c.clone();
                open.push(s);
            }
            None => p.unreachable(state, &s).await,
        }
    }
    let coords: std::collections::BTreeSet<String> = coord_of.values().cloned().collect();
    for coord in coords {
        let here: Vec<Session> = open.iter().filter(|s| s.coordinator == coord).cloned().collect();
        let answers = async {
            let pos = soap(&state.http, &coord, AVT, "GetPositionInfo", "<InstanceID>0</InstanceID>").await?;
            let transport = soap(&state.http, &coord, AVT, "GetTransportInfo", "<InstanceID>0</InstanceID>").await?;
            Ok::<_, ApiError>((pos, transport))
        };
        let (pos, transport) = match answers.await {
            Ok(a) => a,
            Err(e) => {
                p.warn(&coord, &format!("{e:?}"));
                for s in &here {
                    p.unreachable(state, s).await;
                }
                continue;
            }
        };
        p.ok(&coord);
        let ts = tag(&transport, "CurrentTransportState").unwrap_or_default();
        let uri = unescape(&tag(&pos, "TrackURI").unwrap_or_default());
        let claim = decode_uri(state, &uri);
        let global = claim.as_ref().and_then(|c| tag(&pos, "RelTime").and_then(|t| parse_time(&t)).map(|ms| c.offset_ms + c.start_ms + ms));
        for s in &here {
            if occupied(claim.as_ref().map(|c| c.user), &uri, s.user) {
                p.answered(s.room_id);
                end_session(state, s, "foreign").await;
                continue;
            }
            if !matches!(ts.as_str(), "PLAYING" | "PAUSED_PLAYBACK" | "TRANSITIONING") {
                p.not_playing(state, s).await;
                continue;
            }
            p.answered(s.room_id);
            let mut n = s.clone();
            if let Some(c) = &claim {
                if c.key != n.key {
                    n.key = c.key.clone();
                    if let Some(i) = n.queue.iter().position(|k| *k == c.key) {
                        n.idx = i;
                    }
                }
            }
            if let Some(g) = global {
                n.position_ms = g;
            }
            n.state = if ts == "PAUSED_PLAYBACK" { "paused" } else { "playing" }.into();
            let n2 = n.clone();
            let _ = with_db(&state.db, move |c| Ok(save_session(c, &n2)?)).await;
            let (title, subtitle, duration) = match &claim {
                Some(c) => p.title(state, c).await,
                None => Default::default(),
            };
            report_room(state, &n, &title, &subtitle, duration).await;
        }
        let Some(c) = claim else { continue };
        // Radio has no position; a stopped speaker keeps its last track at 0:00: no position to store.
        if c.key.starts_with("radio:") || !matches!(ts.as_str(), "PLAYING" | "PAUSED_PLAYBACK") {
            continue;
        }
        if p.queued.get(&coord) != Some(&uri) {
            // A new track (started here or reached by the speaker): queue what follows it.
            if let (Some(lan), Ok(meta)) = (lan_addr(state), media::meta_for(state, &stream_user(&c), &c.key).await) {
                queue_next(state, lan, &coord, &meta, &c).await;
            }
            p.queued.insert(coord.clone(), uri.clone());
        }
        let Some(global) = global else { continue };
        let device = format!("Sonos {}", c.room);
        // The speaker moved on to another title: the one before is heard to the end only
        // when its last position lay within its last 30 seconds.
        if let Some((user, room, key, at)) = p.playing.get(&coord).cloned() {
            if key != c.key {
                let duration = p.titles.get(&key).and_then(|t| t.2);
                if heard_to_end(at, duration) {
                    let done = playback::External { position_ms: at, duration_ms: duration, finished: true, updated_at: Utc::now(),
                                                    title: String::new(), subtitle: String::new() };
                    let _ = playback::apply_external(state, user, &format!("Sonos {room}"), &key, done).await;
                }
            }
        }
        p.playing.insert(coord.clone(), (c.user, c.room.clone(), c.key.clone(), global));
        if p.last.get(&coord).is_some_and(|&l| (l - global).abs() < 2000) {
            continue; // paused or unchanged
        }
        p.last.insert(coord.clone(), global);
        let (title, subtitle, duration) = p.title(state, &c).await;
        let ext = playback::External { position_ms: global, duration_ms: duration, finished: false, updated_at: Utc::now(), title, subtitle };
        let _ = playback::apply_external(state, c.user, &device, &c.key, ext).await;
    }
}

pub fn lan_addr(state: &AppState) -> Option<SocketAddr> {
    state.config.sonos.as_ref().and_then(|s| s.listen)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn db() -> rusqlite::Connection {
        let c = crate::db::open_memory().unwrap();
        c.execute("INSERT INTO user (id, name, password_hash, totp_secret) VALUES (1, 'u', 'x', 'y')", []).unwrap();
        for (id, ip, name) in [(5, "10.0.0.2", "Buero"), (6, "10.0.0.3", "Badezimmer")] {
            c.execute("INSERT INTO sonos_speaker (id, ip, name, uuid, model, s2) VALUES (?1, ?2, ?3, ?3, 'One', 1)", (id, ip, name)).unwrap();
        }
        c
    }

    fn session(room: i64, coord: &str) -> Session {
        Session { room_id: room, room: if room == 5 { "Buero".into() } else { "Badezimmer".into() }, coordinator: coord.into(),
                  user: 1, key: "jellyfin:1:a".into(), queue: vec!["jellyfin:1:a".into(), "jellyfin:1:b".into()], idx: 0,
                  state: "playing".into(), position_ms: 1000, started_by: "Linux".into() }
    }

    #[test]
    fn sessions_survive_a_restart_and_a_group_has_one() {
        let c = db();
        open_session(&c, &session(5, "10.0.0.2")).unwrap();
        assert_eq!(load_sessions(&c).unwrap(), vec![session(5, "10.0.0.2")]);
        // Badezimmer joined Buero's group and plays there now: one session for the group.
        open_session(&c, &session(6, "10.0.0.2")).unwrap();
        let open = load_sessions(&c).unwrap();
        assert_eq!(open.len(), 1);
        assert_eq!(open[0].room_id, 6);
        let mut moved = open[0].clone();
        (moved.key, moved.idx, moved.position_ms) = ("jellyfin:1:b".into(), 1, 0);
        save_session(&c, &moved).unwrap();
        assert_eq!(load_sessions(&c).unwrap(), vec![moved.clone()]);
        moved.state = "ended".into();
        save_session(&c, &moved).unwrap();
        assert!(load_sessions(&c).unwrap().is_empty());
    }

    #[test]
    fn the_queue_comes_from_the_playing_device() {
        let c = db();
        c.execute(
            "INSERT INTO queue (user_id, device, current_key, data, updated_at) VALUES (1, 'Linux', 'a:2', ?1, 'x')",
            [r#"{"items":[{"key":"a:1"},{"key":"a:2"},{"key":"a:3"}],"index":1}"#],
        )
        .unwrap();
        assert_eq!(queue_of(&c, 1, "Linux", "a:2"), (vec!["a:1".into(), "a:2".into(), "a:3".into()], 1));
        assert_eq!(queue_of(&c, 1, "Linux", "b:9"), (vec!["b:9".into()], 0));
        assert_eq!(queue_of(&c, 1, "Pixel", "a:2"), (vec!["a:2".into()], 0));
    }

    #[test]
    fn heard_only_near_the_end_and_foreign_streams_occupy() {
        assert!(heard_to_end(580_000, Some(600_000)));
        assert!(!heard_to_end(500_000, Some(600_000)));
        assert!(!heard_to_end(599_000, None));
        assert!(occupied(None, "x-sonos-spotify:abc", 1));
        assert!(occupied(Some(2), "http://lan/sonos/t", 1));
        assert!(!occupied(Some(1), "http://lan/sonos/t", 1));
        assert!(!occupied(None, "", 1));
    }

    #[test]
    fn a_failure_is_logged_once_per_reason() {
        let mut p = Poller::default();
        assert!(p.warn("10.0.0.2", "not reachable"));
        assert!(!p.warn("10.0.0.2", "not reachable"));
        assert!(p.warn("10.0.0.2", "UPnP error 701"));
        p.ok("10.0.0.2");
        assert!(p.warn("10.0.0.2", "UPnP error 701"));
    }

    #[test]
    fn times() {
        assert_eq!(parse_time("0:14:02"), Some(842_000));
        assert_eq!(parse_time("1:02:03.250"), Some(3_723_000));
        assert_eq!(format_time(3_723_000), "1:02:03");
    }

    #[test]
    fn sleep_timer_durations() {
        assert_eq!(sleep_duration(0), "");
        assert_eq!(sleep_duration(5), "0:05:00");
        assert_eq!(sleep_duration(90), "1:30:00");
        // The speaker answers "H:MM:SS" (empty when off), read back in seconds.
        assert_eq!(parse_time("0:29:59").map(|ms| ms / 1000), Some(1799));
    }

    #[test]
    fn tokens() {
        let secret = b"0123456789abcdef0123456789abcdef";
        let c = Claim { user: 1, key: "episode:5".into(), part: None, offset_ms: 0, start_ms: 0, profile: "sonos-s2".into(),
                        exp: Utc::now().timestamp() + 60, room: "Büro".into() };
        let t = sign(secret, &c);
        assert_eq!(verify(secret, &t).unwrap().key, "episode:5");
        assert!(verify(b"another-secret-another-secret-xx", &t).is_none());
        assert_eq!(verify(secret, &format!("{t}.mp3")).unwrap().key, "episode:5");
        let mut tampered = t.clone();
        tampered.replace_range(0..1, if t.starts_with('e') { "f" } else { "e" });
        assert!(verify(secret, &tampered).is_none());
        let old = Claim { exp: Utc::now().timestamp() - 1, ..c };
        assert!(verify(secret, &sign(secret, &old)).is_none());
    }

    #[test]
    fn groups() {
        let xml = r#"<ZoneGroups><ZoneGroup Coordinator="RINCON_B" ID="RINCON_B:294"><ZoneGroupMember UUID="RINCON_A" Location="http://10.0.0.3:1400/xml/device_description.xml" ZoneName="Buero"/><ZoneGroupMember UUID="RINCON_B" Location="http://10.0.0.2:1400/xml/device_description.xml" ZoneName="Badezimmer"/></ZoneGroup><ZoneGroup Coordinator="RINCON_S" ID="RINCON_S:1"><ZoneGroupMember UUID="RINCON_S" Location="http://10.0.0.4:1400/x" ZoneName="Schlafzimmer" ChannelMapSet="x"/><ZoneGroupMember UUID="RINCON_T" Location="http://10.0.0.5:1400/x" ZoneName="Schlafzimmer" Invisible="1" ChannelMapSet="x"/></ZoneGroup><ZoneGroup Coordinator="RINCON_H" ID="RINCON_H:27"><ZoneGroupMember UUID="RINCON_H" Location="http://10.0.0.6:1400/x" ZoneName="Wohnzimmer" HTSatChanMapSet="x"><Satellite UUID="RINCON_W" Location="http://10.0.0.7:1400/x" ZoneName="Wohnzimmer" Invisible="1"/></ZoneGroupMember></ZoneGroup></ZoneGroups>"#;
        let g = parse_groups(xml);
        assert_eq!(g.len(), 3);
        assert_eq!(g[0].coordinator_ip(), Some("10.0.0.2"));
        assert_eq!(g[0].rooms().iter().map(|m| m.name.as_str()).collect::<Vec<_>>(), ["Badezimmer", "Buero"]);
        assert_eq!(g[1].rooms().len(), 1, "stereo pair is one room");
        assert!(!g[1].members[1].visible);
        assert_eq!(g[2].members.len(), 2);
        assert_eq!(g[2].rooms().len(), 1, "home theatre is one room");
        assert_eq!(group_of(&g, "RINCON_W").map(|x| x.coordinator.as_str()), Some("RINCON_H"));
    }

    #[test]
    fn file_types() {
        let wav = json!({ "codec": "pcm_s16le", "container": "wav", "sample_rate": 44100, "bit_depth": 16 });
        assert_eq!(file_type(&wav, false), ("wav", "audio/wav"));
        assert_eq!(file_type(&json!({ "codec": "pcm_s16be", "container": "aiff" }), false), ("aif", "audio/aiff"));
        assert_eq!(file_type(&json!({ "codec": "pcm_s24le", "container": "wav" }), true), ("flac", "audio/flac"));
        assert_eq!(file_type(&json!({ "codec": "mp3" }), false), ("mp3", "audio/mpeg"));
        assert_eq!(file_type(&json!({ "codec": "flac" }), false), ("flac", "audio/flac"));
    }

    #[test]
    fn escaping() {
        assert_eq!(xml_escape("a<b>&\"c\""), "a&lt;b&gt;&amp;&quot;c&quot;");
        assert_eq!(unescape(&xml_escape("x & <y>")), "x & <y>");
    }
}
