//! The user's devices: what each one plays (reported with every position), whether it is
//! online (an open event stream), and commands from one device to another.
//!
//! A command is an event `command` with the target's device name; every device of the user
//! receives it, only the target acts on it and reports its new state right away.

use std::{
    collections::HashMap,
    sync::{Arc, Mutex},
};

use axum::{
    extract::{Path, State},
    Json,
};
use rusqlite::OptionalExtension;
use serde::Deserialize;
use serde_json::{json, Value};

use crate::{
    auth::CurrentUser,
    error::{with_db, ApiError, ApiResult},
    AppState,
};

/// Open event streams per (user, device).
pub type Online = Arc<Mutex<HashMap<(i64, String), usize>>>;

pub const KINDS: &[&str] = &["linux", "windows", "android", "web", "sonos"];
const STATES: &[&str] = &["playing", "paused", "stopped"];
const ACTIONS: &[&str] = &["pause", "resume", "stop", "next", "prev", "seek", "takeover", "play"];

/// A device's report, sent along with a position.
pub struct Report<'a> {
    pub kind: Option<&'a str>,
    pub state: &'a str,
    pub key: &'a str,
    pub title: &'a str,
    pub subtitle: &'a str,
    pub position_ms: i64,
    pub duration_ms: Option<i64>,
    pub queue_index: Option<i64>,
    pub updated_at: &'a str,
}

pub fn valid_kind(k: &str) -> bool {
    KINDS.contains(&k)
}

pub fn valid_state(s: &str) -> bool {
    STATES.contains(&s)
}

/// Stores a report unless a newer one is there; returns whether it was stored.
pub fn report(c: &rusqlite::Connection, user: i64, device: &str, r: &Report) -> rusqlite::Result<bool> {
    let n = c.execute(
        "INSERT INTO device_state (user_id, device, kind, state, item_key, title, subtitle, position_ms, duration_ms,
                                   queue_index, updated_at)
         VALUES (?1, ?2, COALESCE(?3, ''), ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11)
         ON CONFLICT (user_id, device) DO UPDATE SET
           kind = COALESCE(?3, kind), state = excluded.state, item_key = excluded.item_key,
           title = CASE WHEN excluded.title <> '' OR excluded.item_key <> item_key THEN excluded.title ELSE title END,
           subtitle = CASE WHEN excluded.subtitle <> '' OR excluded.item_key <> item_key THEN excluded.subtitle ELSE subtitle END,
           position_ms = excluded.position_ms,
           duration_ms = CASE WHEN excluded.item_key = item_key THEN COALESCE(excluded.duration_ms, duration_ms)
                              ELSE excluded.duration_ms END,
           queue_index = excluded.queue_index, updated_at = excluded.updated_at
         WHERE excluded.updated_at >= device_state.updated_at",
        (user, device, r.kind, r.state, r.key, r.title.chars().take(300).collect::<String>(),
         r.subtitle.chars().take(300).collect::<String>(), r.position_ms, r.duration_ms, r.queue_index, r.updated_at),
    )?;
    Ok(n > 0)
}

/// Remembers the kind of a device that connects, without touching its state.
pub fn set_kind(c: &rusqlite::Connection, user: i64, device: &str, kind: &str) -> rusqlite::Result<()> {
    c.execute(
        "INSERT INTO device_state (user_id, device, kind, updated_at) VALUES (?1, ?2, ?3, ?4)
         ON CONFLICT (user_id, device) DO UPDATE SET kind = excluded.kind",
        (user, device, kind, crate::playback::now()),
    )?;
    Ok(())
}

fn is_online(online: &Online, user: i64, device: &str) -> bool {
    online.lock().unwrap().get(&(user, device.to_string())).is_some_and(|n| *n > 0)
}

/// All devices of the user: signed-in app devices (also without a report) and devices with a
/// report. Sonos rooms come from the speakers' own rows (kind `sonos`).
pub fn list(c: &rusqlite::Connection, online: &Online, user: i64, me: &str) -> rusqlite::Result<Vec<Value>> {
    let mut stmt = c.prepare(
        "SELECT d.device, d.kind, d.state, d.item_key, d.title, d.subtitle, d.position_ms, d.duration_ms, d.queue_index,
                d.updated_at, s.last_seen
         FROM device_state d
         LEFT JOIN (SELECT device, MAX(last_seen) AS last_seen FROM session WHERE user_id = ?1 GROUP BY device) s
           ON s.device = d.device
         WHERE d.user_id = ?1 AND (s.device IS NOT NULL OR d.kind = 'sonos')
         UNION ALL
         SELECT device, '', 'stopped', '', '', '', 0, NULL, NULL, '', MAX(last_seen)
         FROM session WHERE user_id = ?1
           AND device NOT IN (SELECT device FROM device_state WHERE user_id = ?1)
         GROUP BY device
         ORDER BY 1",
    )?;
    let rows = stmt.query_map([user], |r| {
        let device: String = r.get(0)?;
        let kind: String = r.get(1)?;
        let up = kind == "sonos" || is_online(online, user, &device);
        Ok(json!({
            "device": device,
            "kind": kind,
            "state": r.get::<_, String>(2)?,
            "key": r.get::<_, String>(3)?,
            "title": r.get::<_, String>(4)?,
            "subtitle": r.get::<_, String>(5)?,
            "position_ms": r.get::<_, i64>(6)?,
            "duration_ms": r.get::<_, Option<i64>>(7)?,
            "queue_index": r.get::<_, Option<i64>>(8)?,
            "updated_at": r.get::<_, String>(9)?,
            "last_seen": r.get::<_, Option<String>>(10)?,
            "online": up,
            "current": device == me,
        }))
    })?;
    let mut rows = rows.collect::<rusqlite::Result<Vec<Value>>>()?;
    let labels = labels(c, user)?;
    for d in &mut rows {
        let l = d["device"].as_str().and_then(|n| labels.get(n)).cloned();
        d["label"] = json!(l);
    }
    Ok(rows)
}

/// The names given to the user's devices (device name -> label).
pub fn labels(c: &rusqlite::Connection, user: i64) -> rusqlite::Result<HashMap<String, String>> {
    let mut st = c.prepare("SELECT device, label FROM device_label WHERE user_id = ?1")?;
    let rows = st.query_map([user], |r| Ok((r.get(0)?, r.get(1)?)))?;
    rows.collect()
}

/// Longest name a device can be given, in characters.
const LABEL_MAX: usize = 40;

/// Checks a name to give a device (user 2026-11-07: 1–40 characters, no control or format
/// characters); returns it without surrounding white space, `None` for an empty one (back to the
/// device name).
pub fn clean_label(raw: &str) -> Result<Option<String>, ApiError> {
    let l = raw.trim();
    if l.is_empty() {
        return Ok(None);
    }
    if l.chars().count() > LABEL_MAX {
        return Err(ApiError::BadRequest(format!("name longer than {LABEL_MAX} characters")));
    }
    let cs: Vec<char> = l.chars().collect();
    for (i, &ch) in cs.iter().enumerate() {
        // The zero width joiner only inside an emoji (e.g. 👨‍👩‍👧), where it is not invisible.
        let joins = ch == '\u{200D}' && i > 0 && i + 1 < cs.len() && pictograph(cs[i - 1]) && pictograph(cs[i + 1]);
        if ch.is_control() || (format_char(ch) && !joins) {
            return Err(ApiError::BadRequest(format!("name contains an invisible character (U+{:04X})", ch as u32)));
        }
    }
    Ok(Some(l.to_string()))
}

/// Emoji and other pictographs, and the variation selector after them.
fn pictograph(c: char) -> bool {
    matches!(c as u32, 0x2300..=0x23FF | 0x2600..=0x27BF | 0x2B00..=0x2BFF | 0xFE0F | 0x1F000..=0x1FAFF)
}

/// Unicode format characters (general category Cf): invisible, they change how text runs or joins.
fn format_char(c: char) -> bool {
    matches!(c as u32,
        0x00AD | 0x0600..=0x0605 | 0x061C | 0x06DD | 0x070F | 0x0890..=0x0891 | 0x08E2 | 0x180E
        | 0x200B..=0x200F | 0x202A..=0x202E | 0x2060..=0x2064 | 0x2066..=0x206F | 0xFEFF | 0xFFF9..=0xFFFB
        | 0x110BD | 0x110CD | 0x13430..=0x1343F | 0x1BCA0..=0x1BCA3 | 0x1D173..=0x1D17A | 0xE0001 | 0xE0020..=0xE007F)
}

/// Gives the device of session `session` the name `label` (`None`: back to the device name);
/// returns the device name. A name another device of the account shows already (labels and
/// device names, upper and lower case alike) is refused.
pub fn set_label(c: &mut rusqlite::Connection, user: i64, session: i64, label: Option<&str>) -> Result<String, ApiError> {
    let tx = c.transaction()?;
    let device: String = tx
        .query_row("SELECT device FROM session WHERE id = ?1 AND user_id = ?2", (session, user), |r| r.get(0))
        .optional()?
        .ok_or(ApiError::NotFound)?;
    match label {
        None => {
            tx.execute("DELETE FROM device_label WHERE user_id = ?1 AND device = ?2", (user, &device))?;
        }
        Some(l) => {
            let want = l.to_lowercase();
            let labels = labels(&tx, user)?;
            let mut names = tx.prepare(
                "SELECT device FROM session WHERE user_id = ?1 UNION SELECT device FROM device_state WHERE user_id = ?1",
            )?;
            let others: Vec<String> = names.query_map([user], |r| r.get(0))?.collect::<Result<_, _>>()?;
            drop(names);
            let taken = others
                .iter()
                .filter(|d| **d != device)
                .any(|d| labels.get(d).unwrap_or(d).to_lowercase() == want);
            if taken {
                return Err(ApiError::Conflict("name already taken".into()));
            }
            tx.execute(
                "INSERT INTO device_label (user_id, device, label) VALUES (?1, ?2, ?3)
                 ON CONFLICT (user_id, device) DO UPDATE SET label = excluded.label",
                (user, &device, l),
            )?;
        }
    }
    tx.commit()?;
    Ok(device)
}

#[derive(Deserialize)]
pub struct Label {
    #[serde(default)]
    label: String,
}

/// `PUT /sessions/{id}/label`: names the device of a session; every device of the account may
/// do it. The other devices learn it from the `device` event.
pub async fn label(
    State(state): State<AppState>,
    user: CurrentUser,
    Path(session): Path<i64>,
    Json(b): Json<Label>,
) -> ApiResult<Json<Value>> {
    let label = clean_label(&b.label)?;
    let l = label.clone();
    let device = with_db(&state.db, move |c| set_label(c, user.id, session, l.as_deref())).await?;
    notify(&state, user.id, &device).await;
    Ok(Json(json!({ "device": device, "label": label })))
}

/// One device as in `list`, for the `device` event.
pub fn one(c: &rusqlite::Connection, online: &Online, user: i64, device: &str) -> rusqlite::Result<Option<Value>> {
    Ok(list(c, online, user, "")?.into_iter().find(|d| d["device"] == device).map(|mut d| {
        d.as_object_mut().unwrap().remove("current");
        d
    }))
}

/// Sends the `device` event with the device's current row.
pub async fn notify(state: &AppState, user: i64, device: &str) {
    let (online, dev) = (state.online.clone(), device.to_string());
    if let Ok(Some(d)) = with_db(&state.db, move |c| Ok(one(c, &online, user, &dev)?)).await {
        let _ = state.events.send((user, json!({ "type": "device", "device": d })));
    }
}

/// Counts an open event stream; the returned guard counts it down again when the stream ends.
pub fn connect(state: &AppState, user: i64, device: &str) -> StreamGuard {
    let first = {
        let mut m = state.online.lock().unwrap();
        let n = m.entry((user, device.to_string())).or_insert(0);
        *n += 1;
        *n == 1
    };
    if first {
        let (s, d) = (state.clone(), device.to_string());
        tokio::spawn(async move { notify(&s, user, &d).await });
    }
    StreamGuard { state: state.clone(), user, device: device.to_string() }
}

pub struct StreamGuard {
    state: AppState,
    user: i64,
    device: String,
}

impl Drop for StreamGuard {
    fn drop(&mut self) {
        let last = {
            let mut m = self.state.online.lock().unwrap();
            let key = (self.user, self.device.clone());
            match m.get_mut(&key) {
                Some(n) if *n > 1 => {
                    *n -= 1;
                    false
                }
                _ => {
                    m.remove(&key);
                    true
                }
            }
        };
        if last {
            if let Ok(rt) = tokio::runtime::Handle::try_current() {
                let (s, u, d) = (self.state.clone(), self.user, self.device.clone());
                rt.spawn(async move { notify(&s, u, &d).await });
            }
        }
    }
}

pub async fn devices(State(state): State<AppState>, user: CurrentUser) -> ApiResult<Json<Value>> {
    let online = state.online.clone();
    with_db(&state.db, move |c| Ok(Json(Value::Array(list(c, &online, user.id, &user.device)?)))).await
}

#[derive(Deserialize)]
pub struct Command {
    action: String,
    #[serde(default)]
    position_ms: Option<i64>,
    /// `play`: the title to play and the queue it belongs to ({items, index, entry}).
    #[serde(default)]
    key: Option<String>,
    #[serde(default)]
    queue: Option<Value>,
}

/// Checks a command for `target`; the error tells why it cannot be sent.
pub fn check(kind: Option<&str>, online: bool, cmd: &Command) -> Result<(), ApiError> {
    if !ACTIONS.contains(&cmd.action.as_str()) {
        return Err(ApiError::BadRequest("unknown action".into()));
    }
    if cmd.action == "seek" && cmd.position_ms.is_none_or(|p| p < 0) {
        return Err(ApiError::BadRequest("position_ms required".into()));
    }
    if cmd.action == "play" && cmd.key.as_deref().is_none_or(str::is_empty) {
        return Err(ApiError::BadRequest("key required".into()));
    }
    match kind {
        None => Err(ApiError::NotFound),
        Some("sonos") => Err(ApiError::BadRequest("Sonos rooms take commands via /api/v1/sonos".into())),
        Some("web") => Err(ApiError::BadRequest("the web player takes no commands".into())),
        Some(_) if !online => Err(ApiError::Conflict("device is offline".into())),
        Some(_) => Ok(()),
    }
}

pub async fn command(
    State(state): State<AppState>,
    user: CurrentUser,
    Path(target): Path<String>,
    Json(cmd): Json<Command>,
) -> ApiResult<Json<Value>> {
    let (uid, t) = (user.id, target.clone());
    let kind: Option<String> = with_db(&state.db, move |c| {
        let k = c.query_row(
            "SELECT kind FROM device_state WHERE user_id = ?1 AND device = ?2
             UNION ALL SELECT '' FROM session WHERE user_id = ?1 AND device = ?2 LIMIT 1",
            (uid, &t),
            |r| r.get(0),
        );
        match k {
            Ok(k) => Ok(Some(k)),
            Err(rusqlite::Error::QueryReturnedNoRows) => Ok(None),
            Err(e) => Err(e.into()),
        }
    })
    .await?;
    check(kind.as_deref(), is_online(&state.online, user.id, &target), &cmd)?;
    let _ = state.events.send((
        user.id,
        json!({ "type": "command", "target": target, "from": user.device, "action": cmd.action,
                "position_ms": cmd.position_ms, "key": cmd.key, "queue": cmd.queue, "at": crate::playback::now() }),
    ));
    tracing::info!(target: "access", "command {:?} from {:?} to {target:?}", cmd.action, user.device);
    Ok(Json(json!({ "ok": true })))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn db() -> rusqlite::Connection {
        let c = crate::db::open_memory().unwrap();
        c.execute("INSERT INTO user (id, name, password_hash, totp_secret) VALUES (1, 'u', 'x', 'y')", []).unwrap();
        for d in ["Linux", "Pixel"] {
            c.execute(
                "INSERT INTO session (user_id, token_hash, device, expires_at) VALUES (1, ?1, ?1, '2099-01-01')",
                [d],
            )
            .unwrap();
        }
        c
    }

    fn rep<'a>(state: &'a str, key: &'a str, pos: i64, at: &'a str) -> Report<'a> {
        Report { kind: Some("linux"), state, key, title: "T", subtitle: "", position_ms: pos, duration_ms: Some(9000),
                 queue_index: None, updated_at: at }
    }

    #[test]
    fn newest_report_wins_and_devices_list_with_online() {
        let c = db();
        let online: Online = Default::default();
        assert!(report(&c, 1, "Linux", &rep("playing", "episode:1", 1000, "2026-11-03T10:00:00.000Z")).unwrap());
        assert!(!report(&c, 1, "Linux", &rep("paused", "episode:1", 500, "2026-11-03T09:00:00.000Z")).unwrap());
        online.lock().unwrap().insert((1, "Linux".into()), 1);
        let l = list(&c, &online, 1, "Pixel").unwrap();
        assert_eq!(l.len(), 2);
        assert_eq!(l[0]["device"], "Linux");
        assert_eq!(l[0]["state"], "playing");
        assert_eq!(l[0]["position_ms"], 1000);
        assert_eq!(l[0]["online"], true);
        assert_eq!(l[0]["current"], false);
        // Signed in, never reported: listed as stopped and offline.
        assert_eq!(l[1]["device"], "Pixel");
        assert_eq!(l[1]["online"], false);
        assert_eq!(l[1]["current"], true);
    }

    #[test]
    fn label_rules() {
        assert_eq!(clean_label("  Office PC ").unwrap().as_deref(), Some("Office PC"));
        for ok in ["Tablet 13", "Kitchen phone", "Pat's Büro", "Küche 🎵", "👨\u{200D}👩\u{200D}👧 Familie"] {
            assert!(clean_label(ok).unwrap().is_some(), "{ok}");
        }
        assert_eq!(clean_label("   ").unwrap(), None);
        assert!(clean_label(&"x".repeat(40)).is_ok());
        assert!(clean_label(&"ä".repeat(41)).is_err());
        for bad in ["a\nb", "a\tb", "a\u{200B}b", "a\u{200D}b", "\u{202E}abc", "a\u{FEFF}", "a\u{0007}"] {
            assert!(matches!(clean_label(bad), Err(ApiError::BadRequest(_))), "{bad:?}");
        }
    }

    #[test]
    fn a_label_names_the_device_and_nothing_else_changes() {
        let mut c = db();
        let online: Online = Default::default();
        report(&c, 1, "Linux", &rep("playing", "episode:1", 1000, "2026-11-03T10:00:00.000Z")).unwrap();
        let pixel: i64 = c.query_row("SELECT id FROM session WHERE device = 'Pixel'", [], |r| r.get(0)).unwrap();
        let linux: i64 = c.query_row("SELECT id FROM session WHERE device = 'Linux'", [], |r| r.get(0)).unwrap();
        assert_eq!(set_label(&mut c, 1, pixel, Some("Kitchen phone")).unwrap(), "Pixel");
        let l = list(&c, &online, 1, "Pixel").unwrap();
        assert_eq!((l[0]["device"].as_str(), l[0]["label"].is_null()), (Some("Linux"), true));
        assert_eq!((l[1]["device"].as_str(), l[1]["label"].as_str()), (Some("Pixel"), Some("Kitchen phone")));
        assert_eq!(l[1]["current"], true);
        // Keys stay: sessions and reports still under the device name.
        let n: i64 = c.query_row("SELECT COUNT(*) FROM session WHERE device = 'Pixel'", [], |r| r.get(0)).unwrap();
        assert_eq!(n, 1);
        assert_eq!(one(&c, &online, 1, "Pixel").unwrap().unwrap()["label"], "Kitchen phone");
        // Taken: another device's label or its device name, upper and lower case alike.
        assert!(matches!(set_label(&mut c, 1, linux, Some("KITCHEN PHONE")), Err(ApiError::Conflict(_))));
        assert!(matches!(set_label(&mut c, 1, pixel, Some("linux")), Err(ApiError::Conflict(_))));
        // The own name in other case, and a new name, are fine.
        assert!(set_label(&mut c, 1, pixel, Some("Kitchen Phone")).is_ok());
        assert!(set_label(&mut c, 1, linux, Some("Office PC")).is_ok());
        // The device name of a renamed device is free again ("Linux" is shown as "Office PC").
        assert!(set_label(&mut c, 1, pixel, Some("Linux")).is_ok());
        // Back to the device name, and nobody else's session.
        set_label(&mut c, 1, pixel, None).unwrap();
        assert!(labels(&c, 1).unwrap().get("Pixel").is_none());
        assert!(matches!(set_label(&mut c, 2, pixel, Some("x")), Err(ApiError::NotFound)));
        assert!(matches!(set_label(&mut c, 1, 999, Some("x")), Err(ApiError::NotFound)));
    }

    #[test]
    fn signed_out_devices_drop_out_of_the_list() {
        let c = db();
        let online: Online = Default::default();
        report(&c, 1, "Linux", &rep("paused", "episode:1", 1000, "2026-11-03T10:00:00.000Z")).unwrap();
        c.execute("DELETE FROM session WHERE device = 'Linux'", []).unwrap();
        let l = list(&c, &online, 1, "").unwrap();
        assert_eq!(l.len(), 1);
        assert_eq!(l[0]["device"], "Pixel");
    }

    #[test]
    fn new_title_resets_duration_and_kind_stays() {
        let c = db();
        report(&c, 1, "Linux", &rep("playing", "episode:1", 1000, "2026-11-03T10:00:00.000Z")).unwrap();
        let mut r = rep("playing", "episode:2", 0, "2026-11-03T10:01:00.000Z");
        r.kind = None;
        r.duration_ms = None;
        report(&c, 1, "Linux", &r).unwrap();
        let d = one(&c, &Default::default(), 1, "Linux").unwrap().unwrap();
        assert_eq!(d["key"], "episode:2");
        assert_eq!(d["kind"], "linux");
        assert!(d["duration_ms"].is_null());
    }

    #[test]
    fn commands_need_a_known_online_app() {
        let cmd = |a: &str| Command { action: a.into(), position_ms: None, key: None, queue: None };
        assert!(check(Some("linux"), true, &cmd("pause")).is_ok());
        assert!(matches!(check(Some("linux"), false, &cmd("pause")), Err(ApiError::Conflict(_))));
        assert!(matches!(check(None, true, &cmd("pause")), Err(ApiError::NotFound)));
        assert!(matches!(check(Some("web"), true, &cmd("pause")), Err(ApiError::BadRequest(_))));
        assert!(matches!(check(Some("linux"), true, &cmd("explode")), Err(ApiError::BadRequest(_))));
        assert!(matches!(check(Some("linux"), true, &cmd("seek")), Err(ApiError::BadRequest(_))));
        let seek = Command { action: "seek".into(), position_ms: Some(5000), key: None, queue: None };
        assert!(check(Some("android"), true, &seek).is_ok());
        assert!(matches!(check(Some("linux"), true, &cmd("play")), Err(ApiError::BadRequest(_))));
    }
}
