//! The server's own album directory per music library (Jellyfin, Emby, Plex): the sources
//! cannot sort or group by album artist, genre, year or label, so the clients get the whole
//! list and build the views (albums, artists, samplers, genres, years, new, labels) themselves.
//!
//! Renewal: once a day (or week, or only by hand – setting `music_refresh`) one small query
//! asks for the newest album and the album count; only when they changed is the directory
//! rebuilt. Labels: from the tags at the start of the first track (FLAC, MP3, AIFF; at most
//! 256 KB, own Jellyfin/Emby only, once per album), Plex's "studio", and – only when switched
//! on (`musicbrainz`) – from musicbrainz.org by release id, at most one request per second.

use std::time::Duration;

use axum::{
    extract::{Path, Query, State},
    Json,
};
use chrono::{DateTime, Utc};
use serde::Deserialize;
use serde_json::{json, Value};

use crate::{
    auth::CurrentUser,
    error::{with_db, ApiError, ApiResult},
    jellyfin, plex, sources, AppState,
};

const SAMPLER_ARTISTS: &[&str] = &["various artists", "va", "various", "verschiedene interpreten", "verschiedene künstler"];
/// The "Labels" view is offered once this share of albums has a label.
const LABEL_SHARE: f64 = 0.10;
const TAG_BYTES: u64 = 256 * 1024;
const CHECK_EVERY: Duration = Duration::from_secs(3600);

#[derive(Debug, Clone, Default, PartialEq)]
pub struct Album {
    pub id: String,
    pub title: String,
    pub artist: String,
    pub year: Option<i64>,
    pub genres: Vec<String>,
    pub added_at: Option<String>,
    pub image: bool,
    pub tracks: Option<i64>,
    pub duration_ms: Option<i64>,
    pub mbid: Option<String>,
    pub label: Option<String>,
}

pub fn is_sampler(artist: &str) -> bool {
    SAMPLER_ARTISTS.contains(&artist.trim().to_lowercase().as_str())
}

// ---------------------------------------------------------------- settings

pub async fn setting(state: &AppState, name: &'static str) -> String {
    with_db(&state.db, move |c| Ok(c.query_row("SELECT value FROM setting WHERE name = ?1", [name], |r| r.get::<_, String>(0)).ok()))
        .await
        .ok()
        .flatten()
        .unwrap_or_default()
}

fn refresh_mode(s: &str) -> &str {
    match s {
        "weekly" | "manual" => s,
        _ => "daily",
    }
}

/// `GET /api/v1/settings/music`
pub async fn get_settings(State(state): State<AppState>, _user: CurrentUser) -> ApiResult<Json<Value>> {
    let refresh = setting(&state, "music_refresh").await;
    Ok(Json(json!({
        "refresh": refresh_mode(&refresh),
        "musicbrainz": setting(&state, "musicbrainz").await == "on",
        "musicbrainz_contact": setting(&state, "musicbrainz_contact").await,
    })))
}

#[derive(Deserialize)]
pub struct MusicSettings {
    refresh: Option<String>,
    musicbrainz: Option<bool>,
    musicbrainz_contact: Option<String>,
}

/// `PUT /api/v1/settings/music`: MusicBrainz needs a contact (their rules for the User-Agent).
pub async fn put_settings(State(state): State<AppState>, _user: CurrentUser, Json(req): Json<MusicSettings>) -> ApiResult<Json<Value>> {
    let mut set: Vec<(&str, String)> = Vec::new();
    if let Some(r) = req.refresh {
        if !matches!(r.as_str(), "daily" | "weekly" | "manual") {
            return Err(ApiError::BadRequest("refresh: daily | weekly | manual".into()));
        }
        set.push(("music_refresh", r));
    }
    if let Some(c) = req.musicbrainz_contact {
        let c = c.trim().to_string();
        if c.len() > 200 || c.contains(['\r', '\n', '(', ')']) {
            return Err(ApiError::BadRequest("contact: an e-mail address or URL".into()));
        }
        set.push(("musicbrainz_contact", c));
    }
    if let Some(on) = req.musicbrainz {
        let contact = set.iter().find(|(k, _)| *k == "musicbrainz_contact").map(|(_, v)| v.clone());
        let contact = match contact {
            Some(c) => c,
            None => setting(&state, "musicbrainz_contact").await,
        };
        if on && contact.is_empty() {
            return Err(ApiError::BadRequest("musicbrainz needs a contact address".into()));
        }
        set.push(("musicbrainz", if on { "on" } else { "off" }.into()));
    }
    let wake = set.iter().any(|(k, v)| *k == "musicbrainz" && v == "on");
    with_db(&state.db, move |c| {
        for (k, v) in &set {
            c.execute("INSERT INTO setting (name, value) VALUES (?1, ?2) ON CONFLICT (name) DO UPDATE SET value = excluded.value", (k, v))?;
        }
        Ok(())
    })
    .await?;
    if wake {
        let st = state.clone();
        tokio::spawn(async move { labels(&st).await });
    }
    get_settings(State(state), _user).await
}

// ---------------------------------------------------------------- fetching from the sources

/// All albums of a library, and (count, newest album id) for the change check.
async fn fetch(state: &AppState, src: i64, kind: &str, lib: &str) -> ApiResult<Vec<Album>> {
    match kind {
        "jellyfin" | "emby" => {
            let jf = jellyfin::source(state, src).await?;
            let uid = jf.user_id(state).await?;
            let mut out = Vec::new();
            let mut start = 0;
            loop {
                let v = jf
                    .get(&state.http, &format!("/Users/{uid}/Items"), &[
                        ("ParentId", lib.to_string()),
                        ("IncludeItemTypes", "MusicAlbum".into()),
                        ("Recursive", "true".into()),
                        ("Fields", "Genres,DateCreated,ProviderIds,ChildCount,ProductionYear,Studios".into()),
                        ("StartIndex", start.to_string()),
                        ("Limit", "1000".into()),
                    ])
                    .await?;
                let items = v["Items"].as_array().cloned().unwrap_or_default();
                out.extend(items.iter().map(album_jellyfin));
                start += items.len();
                if items.is_empty() || start as i64 >= v["TotalRecordCount"].as_i64().unwrap_or(0) {
                    break;
                }
            }
            Ok(out)
        }
        "plex" => {
            let p = plex::source(state, src).await?;
            let sec = lib.strip_prefix('s').filter(|s| plex::valid_id(s)).ok_or_else(|| ApiError::BadRequest("invalid library".into()))?;
            let v = p.get(&state.http, &format!("/library/sections/{sec}/all"), &[("type", "9".into())]).await?;
            Ok(v["MediaContainer"]["Metadata"].as_array().map(|a| a.iter().map(album_plex).collect()).unwrap_or_default())
        }
        _ => Err(ApiError::NotFound),
    }
}

async fn latest(state: &AppState, src: i64, kind: &str, lib: &str) -> ApiResult<(i64, String)> {
    match kind {
        "jellyfin" | "emby" => {
            let jf = jellyfin::source(state, src).await?;
            let uid = jf.user_id(state).await?;
            let v = jf
                .get(&state.http, &format!("/Users/{uid}/Items"), &[
                    ("ParentId", lib.to_string()),
                    ("IncludeItemTypes", "MusicAlbum".into()),
                    ("Recursive", "true".into()),
                    ("SortBy", "DateCreated".into()),
                    ("SortOrder", "Descending".into()),
                    ("Limit", "1".into()),
                ])
                .await?;
            Ok((v["TotalRecordCount"].as_i64().unwrap_or(0), v["Items"][0]["Id"].as_str().unwrap_or("").to_string()))
        }
        "plex" => {
            let p = plex::source(state, src).await?;
            let sec = lib.strip_prefix('s').filter(|s| plex::valid_id(s)).ok_or_else(|| ApiError::BadRequest("invalid library".into()))?;
            let v = p
                .get(&state.http, &format!("/library/sections/{sec}/all"), &[
                    ("type", "9".into()),
                    ("sort", "addedAt:desc".into()),
                    ("X-Plex-Container-Start", "0".into()),
                    ("X-Plex-Container-Size", "1".into()),
                ])
                .await?;
            let mc = &v["MediaContainer"];
            Ok((mc["totalSize"].as_i64().or_else(|| mc["size"].as_i64()).unwrap_or(0), mc["Metadata"][0]["ratingKey"].as_str().unwrap_or("").to_string()))
        }
        _ => Err(ApiError::NotFound),
    }
}

pub fn album_jellyfin(v: &Value) -> Album {
    let artist = v["AlbumArtist"]
        .as_str()
        .filter(|s| !s.is_empty())
        .or_else(|| v["AlbumArtists"][0]["Name"].as_str())
        .or_else(|| v["Artists"][0].as_str())
        .unwrap_or("")
        .to_string();
    Album {
        id: v["Id"].as_str().unwrap_or("").to_string(),
        title: v["Name"].as_str().unwrap_or("").to_string(),
        artist,
        year: v["ProductionYear"].as_i64(),
        genres: v["Genres"].as_array().map(|g| g.iter().filter_map(|x| x.as_str()).map(str::to_string).collect()).unwrap_or_default(),
        added_at: v["DateCreated"].as_str().map(str::to_string),
        image: v["ImageTags"]["Primary"].is_string(),
        tracks: v["ChildCount"].as_i64(),
        duration_ms: v["RunTimeTicks"].as_i64().map(|t| t / 10_000),
        mbid: v["ProviderIds"]["MusicBrainzAlbum"].as_str().filter(|s| !s.is_empty()).map(str::to_string),
        label: None,
    }
}

pub fn album_plex(m: &Value) -> Album {
    Album {
        id: m["ratingKey"].as_str().unwrap_or("").to_string(),
        title: m["title"].as_str().unwrap_or("").to_string(),
        artist: m["parentTitle"].as_str().unwrap_or("").to_string(),
        year: m["year"].as_i64(),
        genres: m["Genre"].as_array().map(|g| g.iter().filter_map(|x| x["tag"].as_str()).map(str::to_string).collect()).unwrap_or_default(),
        added_at: m["addedAt"].as_i64().and_then(|t| DateTime::from_timestamp(t, 0)).map(|d| d.to_rfc3339()),
        image: m["thumb"].is_string(),
        tracks: m["leafCount"].as_i64(),
        duration_ms: m["duration"].as_i64(),
        mbid: None,
        label: m["studio"].as_str().map(str::trim).filter(|s| !s.is_empty()).map(str::to_string),
    }
}

// ---------------------------------------------------------------- the directory

/// Rebuilds the directory of a library; labels already found are kept.
pub async fn build(state: &AppState, src: i64, lib: &str) -> ApiResult<usize> {
    let kind = sources::kind(state, src).await?;
    let albums = fetch(state, src, &kind, lib).await?;
    let (total, newest) = latest(state, src, &kind, lib).await.unwrap_or((albums.len() as i64, String::new()));
    let lib = lib.to_string();
    let n = albums.len();
    let plex = kind == "plex";
    with_db(&state.db, move |c| {
        let tx = c.transaction()?;
        tx.execute("CREATE TEMP TABLE IF NOT EXISTS seen (id TEXT PRIMARY KEY)", [])?;
        tx.execute("DELETE FROM seen", [])?;
        for a in &albums {
            tx.execute(
                "INSERT INTO music_album (source_id, library, album_id, title, artist, year, genres, added_at, image, tracks, duration_ms, mbid, label)
                 VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13)
                 ON CONFLICT (source_id, album_id) DO UPDATE SET library = excluded.library, title = excluded.title,
                   artist = excluded.artist, year = excluded.year, genres = excluded.genres, added_at = excluded.added_at,
                   image = excluded.image, tracks = excluded.tracks, duration_ms = excluded.duration_ms, mbid = excluded.mbid,
                   label = CASE WHEN ?14 THEN excluded.label ELSE music_album.label END",
                rusqlite::params![
                    src, lib, a.id, a.title, a.artist, a.year, serde_json::to_string(&a.genres).unwrap(), a.added_at,
                    a.image.then_some("1"), a.tracks, a.duration_ms, a.mbid, a.label, plex
                ],
            )?;
            tx.execute("INSERT OR IGNORE INTO seen (id) VALUES (?1)", [&a.id])?;
        }
        tx.execute("DELETE FROM music_album WHERE source_id = ?1 AND library = ?2 AND album_id NOT IN (SELECT id FROM seen)", (src, &lib))?;
        let now = Utc::now().to_rfc3339();
        tx.execute(
            "INSERT INTO music_index (source_id, library, built_at, checked_at, newest, total) VALUES (?1, ?2, ?3, ?3, ?4, ?5)
             ON CONFLICT (source_id, library) DO UPDATE SET built_at = excluded.built_at, checked_at = excluded.checked_at,
               newest = excluded.newest, total = excluded.total",
            (src, &lib, &now, &newest, total),
        )?;
        tx.commit()?;
        Ok(())
    })
    .await?;
    let st = state.clone();
    tokio::spawn(async move { labels(&st).await });
    Ok(n)
}

#[derive(Deserialize)]
pub struct Library {
    parent: String,
}

/// `GET /api/v1/sources/{id}/music?parent=<library>`: all albums (built on first use).
pub async fn albums(State(state): State<AppState>, _user: CurrentUser, Path(src): Path<i64>, Query(q): Query<Library>) -> ApiResult<Json<Value>> {
    let lib = q.parent.clone();
    if lib.is_empty() || lib.len() > 80 {
        return Err(ApiError::BadRequest("invalid library".into()));
    }
    let kind = sources::kind(&state, src).await?;
    if !matches!(kind.as_str(), "jellyfin" | "emby" | "plex") {
        return Err(ApiError::NotFound);
    }
    let l = lib.clone();
    let built: Option<String> = with_db(&state.db, move |c| {
        Ok(c.query_row("SELECT built_at FROM music_index WHERE source_id = ?1 AND library = ?2", (src, &l), |r| r.get(0)).ok())
    })
    .await?;
    if built.is_none() {
        build(&state, src, &lib).await?;
    }
    let l = lib.clone();
    let (rows, built_at): (Vec<Value>, String) = with_db(&state.db, move |c| {
        let built_at: String = c.query_row("SELECT built_at FROM music_index WHERE source_id = ?1 AND library = ?2", (src, &l), |r| r.get(0))?;
        let mut st = c.prepare(
            "SELECT album_id, title, artist, year, genres, added_at, image, tracks, duration_ms, label
             FROM music_album WHERE source_id = ?1 AND library = ?2",
        )?;
        let rows = st
            .query_map((src, &l), |r| {
                let id: String = r.get(0)?;
                let artist: String = r.get(2)?;
                let key = format!("{kind}:{src}:{id}");
                Ok(json!({
                    "key": key, "kind": "album", "title": r.get::<_, String>(1)?, "subtitle": artist, "artist": artist,
                    "sampler": is_sampler(&artist), "year": r.get::<_, Option<i64>>(3)?,
                    "genres": serde_json::from_str::<Value>(&r.get::<_, String>(4)?).unwrap_or(json!([])),
                    "added": r.get::<_, Option<String>>(5)?,
                    "image": r.get::<_, Option<String>>(6)?.map(|_| format!("/api/v1/image/{key}")),
                    "tracks": r.get::<_, Option<i64>>(7)?, "duration_ms": r.get::<_, Option<i64>>(8)?,
                    "label": r.get::<_, Option<String>>(9)?,
                }))
            })?
            .collect::<Result<Vec<_>, _>>()?;
        Ok((rows, built_at))
    })
    .await?;
    let with_label = rows.iter().filter(|a| a["label"].is_string()).count();
    let labels = !rows.is_empty() && with_label as f64 >= LABEL_SHARE * rows.len() as f64;
    Ok(Json(json!({ "albums": rows, "built_at": built_at, "labels": labels })))
}

/// `POST /api/v1/sources/{id}/music/refresh?parent=<library>` ("read in again now").
pub async fn refresh(State(state): State<AppState>, _user: CurrentUser, Path(src): Path<i64>, Query(q): Query<Library>) -> ApiResult<Json<Value>> {
    let n = build(&state, src, &q.parent).await?;
    Ok(Json(json!({ "albums": n })))
}

/// Daily (or weekly) check of every known directory; rebuilds only after a change.
pub async fn refresh_loop(state: AppState) {
    loop {
        tokio::time::sleep(CHECK_EVERY).await;
        let mode = setting(&state, "music_refresh").await;
        let every = match refresh_mode(&mode) {
            "manual" => continue,
            "weekly" => chrono::Duration::days(7),
            _ => chrono::Duration::days(1),
        };
        let Ok(due) = with_db(&state.db, |c| {
            let mut st = c.prepare("SELECT source_id, library, checked_at, newest, total FROM music_index")?;
            let rows = st.query_map([], |r| Ok((r.get::<_, i64>(0)?, r.get::<_, String>(1)?, r.get::<_, String>(2)?, r.get::<_, String>(3)?, r.get::<_, i64>(4)?)))?;
            Ok(rows.collect::<Result<Vec<_>, _>>()?)
        })
        .await
        else {
            continue;
        };
        for (src, lib, checked, newest, total) in due {
            let old = DateTime::parse_from_rfc3339(&checked).map(|d| d.with_timezone(&Utc)).unwrap_or_default();
            if Utc::now() - old < every {
                continue;
            }
            let Ok(kind) = sources::kind(&state, src).await else { continue };
            let Ok((n, id)) = latest(&state, src, &kind, &lib).await else { continue };
            if n != total || id != newest {
                if let Err(e) = build(&state, src, &lib).await {
                    tracing::warn!("music directory {src}/{lib}: {e:?}");
                }
            } else {
                let now = Utc::now().to_rfc3339();
                let _ = with_db(&state.db, move |c| {
                    c.execute("UPDATE music_index SET checked_at = ?3 WHERE source_id = ?1 AND library = ?2", (src, &lib, &now))?;
                    Ok(())
                })
                .await;
            }
        }
    }
}

// ---------------------------------------------------------------- labels

static LABELS_RUNNING: std::sync::atomic::AtomicBool = std::sync::atomic::AtomicBool::new(false);

/// Fills in labels in the background: file tags first, then MusicBrainz when switched on.
pub async fn labels(state: &AppState) {
    use std::sync::atomic::Ordering;
    if LABELS_RUNNING.swap(true, Ordering::SeqCst) {
        return;
    }
    label_tags(state).await;
    if setting(state, "musicbrainz").await == "on" {
        label_musicbrainz(state).await;
    }
    LABELS_RUNNING.store(false, Ordering::SeqCst);
}

async fn label_tags(state: &AppState) {
    let Ok(todo) = with_db(&state.db, |c| {
        let mut st = c.prepare(
            "SELECT a.source_id, a.album_id FROM music_album a JOIN source s ON s.id = a.source_id
             WHERE a.label IS NULL AND a.label_tags = 0 AND s.kind IN ('jellyfin', 'emby')",
        )?;
        let rows = st.query_map([], |r| Ok((r.get::<_, i64>(0)?, r.get::<_, String>(1)?)))?;
        Ok(rows.collect::<Result<Vec<_>, _>>()?)
    })
    .await
    else {
        return;
    };
    for (src, album) in todo {
        let label = tag_label_of(state, src, &album).await;
        let _ = with_db(&state.db, move |c| {
            c.execute("UPDATE music_album SET label_tags = 1, label = COALESCE(label, ?3) WHERE source_id = ?1 AND album_id = ?2", (src, &album, label))?;
            Ok(())
        })
        .await;
        // Gentle on the media server.
        tokio::time::sleep(Duration::from_millis(250)).await;
    }
}

/// Label from the start of an album's first track (FLAC, MP3, AIFF only).
async fn tag_label_of(state: &AppState, src: i64, album: &str) -> Option<String> {
    let jf = jellyfin::source(state, src).await.ok()?;
    let uid = jf.user_id(state).await.ok()?;
    let v = jf
        .get(&state.http, &format!("/Users/{uid}/Items"), &[
            ("ParentId", album.to_string()),
            ("IncludeItemTypes", "Audio".into()),
            ("SortBy", "ParentIndexNumber,IndexNumber".into()),
            ("Limit", "1".into()),
            ("Fields", "MediaSources".into()),
        ])
        .await
        .ok()?;
    let track = &v["Items"][0];
    let container = track["MediaSources"][0]["Container"].as_str().unwrap_or("").to_lowercase();
    if !matches!(container.as_str(), "flac" | "mp3" | "aiff" | "aif") {
        return None;
    }
    let id = track["Id"].as_str()?;
    let (name, value) = jf.auth();
    let res = state
        .http
        .get(jf.stream_url(id))
        .header(name, value)
        .header("range", format!("bytes=0-{}", TAG_BYTES - 1))
        .timeout(Duration::from_secs(20))
        .send()
        .await
        .ok()?;
    let mut buf = Vec::new();
    let mut res = res;
    while let Ok(Some(chunk)) = res.chunk().await {
        buf.extend_from_slice(&chunk);
        if buf.len() as u64 >= TAG_BYTES {
            break;
        }
    }
    label_from_tags(&buf)
}

async fn label_musicbrainz(state: &AppState) {
    let contact = setting(state, "musicbrainz_contact").await;
    if contact.is_empty() {
        return;
    }
    let agent = format!("audiojoe/{} ( {contact} )", env!("CARGO_PKG_VERSION"));
    let Ok(todo) = with_db(&state.db, |c| {
        let mut st = c.prepare("SELECT source_id, album_id, mbid FROM music_album WHERE label IS NULL AND mbid IS NOT NULL AND label_mb = 0")?;
        let rows = st.query_map([], |r| Ok((r.get::<_, i64>(0)?, r.get::<_, String>(1)?, r.get::<_, String>(2)?)))?;
        Ok(rows.collect::<Result<Vec<_>, _>>()?)
    })
    .await
    else {
        return;
    };
    for (src, album, mbid) in todo {
        if setting(state, "musicbrainz").await != "on" {
            return;
        }
        if !mbid.chars().all(|c| c.is_ascii_hexdigit() || c == '-') || mbid.len() > 40 {
            continue;
        }
        let res = state
            .http
            .get(format!("https://musicbrainz.org/ws/2/release/{mbid}"))
            .query(&[("inc", "labels"), ("fmt", "json")])
            .header("user-agent", &agent)
            .timeout(Duration::from_secs(20))
            .send()
            .await;
        let label = match res {
            Ok(r) if r.status().is_success() => r.json::<Value>().await.ok().and_then(|v| {
                v["label-info"].as_array()?.iter().find_map(|l| l["label"]["name"].as_str().map(str::to_string))
            }),
            // Rate limit: try again in the next round.
            Ok(r) if r.status() == reqwest::StatusCode::SERVICE_UNAVAILABLE => {
                tokio::time::sleep(Duration::from_secs(5)).await;
                continue;
            }
            _ => None,
        };
        let _ = with_db(&state.db, move |c| {
            c.execute("UPDATE music_album SET label_mb = 1, label = COALESCE(label, ?3) WHERE source_id = ?1 AND album_id = ?2", (src, &album, label))?;
            Ok(())
        })
        .await;
        tokio::time::sleep(Duration::from_millis(1100)).await;
    }
}

// ---------------------------------------------------------------- tag parsing

/// Record label from FLAC Vorbis comments or ID3v2 (MP3, AIFF's "ID3 " chunk).
pub fn label_from_tags(b: &[u8]) -> Option<String> {
    if b.starts_with(b"fLaC") {
        return flac_label(b);
    }
    if b.starts_with(b"ID3") {
        return id3_label(b);
    }
    if b.starts_with(b"FORM") && b.len() > 12 && (&b[8..12] == b"AIFF" || &b[8..12] == b"AIFC") {
        let mut i = 12;
        while i + 8 <= b.len() {
            let id = &b[i..i + 4];
            let len = u32::from_be_bytes(b[i + 4..i + 8].try_into().ok()?) as usize;
            if id == b"ID3 " || id == b"id3 " {
                return id3_label(b.get(i + 8..(i + 8 + len).min(b.len()))?);
            }
            i += 8 + len + (len & 1);
        }
    }
    None
}

fn clean(s: &str) -> Option<String> {
    let s = s.trim_matches(|c: char| c == '\0' || c.is_whitespace());
    (!s.is_empty() && s.len() <= 120).then(|| s.to_string())
}

fn flac_label(b: &[u8]) -> Option<String> {
    let mut i = 4;
    while i + 4 <= b.len() {
        let last = b[i] & 0x80 != 0;
        let kind = b[i] & 0x7f;
        let len = u32::from_be_bytes([0, b[i + 1], b[i + 2], b[i + 3]]) as usize;
        let body = b.get(i + 4..(i + 4 + len).min(b.len()))?;
        if kind == 4 {
            let u32le = |p: usize| body.get(p..p + 4).map(|x| u32::from_le_bytes(x.try_into().unwrap()) as usize);
            let mut p = 4 + u32le(0)?;
            let n = u32le(p)?;
            p += 4;
            let mut found: Option<(usize, String)> = None;
            for _ in 0..n {
                let l = u32le(p)?;
                let e = String::from_utf8_lossy(body.get(p + 4..(p + 4 + l).min(body.len()))?).to_string();
                p += 4 + l;
                if let Some((k, v)) = e.split_once('=') {
                    let rank = match k.to_ascii_uppercase().as_str() {
                        "LABEL" => 0,
                        "ORGANIZATION" | "ORGANISATION" => 1,
                        "PUBLISHER" => 2,
                        _ => continue,
                    };
                    if found.as_ref().is_none_or(|(r, _)| rank < *r) {
                        if let Some(v) = clean(v) {
                            found = Some((rank, v));
                        }
                    }
                }
            }
            return found.map(|(_, v)| v);
        }
        if last {
            break;
        }
        i += 4 + len;
    }
    None
}

fn id3_text(enc: u8, data: &[u8]) -> String {
    match enc {
        1 | 2 => {
            let (be, start) = match data {
                [0xFE, 0xFF, ..] => (true, 2),
                [0xFF, 0xFE, ..] => (false, 2),
                _ => (enc == 2, 0),
            };
            let units: Vec<u16> = data[start..]
                .chunks_exact(2)
                .map(|c| if be { u16::from_be_bytes([c[0], c[1]]) } else { u16::from_le_bytes([c[0], c[1]]) })
                .take_while(|&u| u != 0)
                .collect();
            String::from_utf16_lossy(&units)
        }
        3 => String::from_utf8_lossy(data.split(|&c| c == 0).next().unwrap_or(&[])).to_string(),
        _ => data.iter().take_while(|&&c| c != 0).map(|&c| c as char).collect(),
    }
}

fn id3_label(b: &[u8]) -> Option<String> {
    if b.len() < 10 || &b[0..3] != b"ID3" {
        return None;
    }
    let ver = b[3];
    let synch = |x: &[u8]| ((x[0] as usize) << 21) | ((x[1] as usize) << 14) | ((x[2] as usize) << 7) | x[3] as usize;
    let size = synch(&b[6..10]);
    let end = (10 + size).min(b.len());
    let mut i = 10;
    if b[5] & 0x40 != 0 && i + 4 <= end {
        // Extended header.
        let n = if ver == 4 { synch(&b[i..i + 4]) } else { u32::from_be_bytes(b[i..i + 4].try_into().ok()?) as usize + 4 };
        i += n;
    }
    let mut txxx: Option<String> = None;
    while i + 10 <= end {
        let id = &b[i..i + 4];
        if id[0] == 0 {
            break;
        }
        let len = if ver == 4 { synch(&b[i + 4..i + 8]) } else { u32::from_be_bytes(b[i + 4..i + 8].try_into().ok()?) as usize };
        let data = b.get(i + 10..(i + 10 + len).min(end))?;
        if id == b"TPUB" && !data.is_empty() {
            if let Some(v) = clean(&id3_text(data[0], &data[1..])) {
                return Some(v);
            }
        }
        if id == b"TXXX" && !data.is_empty() && txxx.is_none() {
            let enc = data[0];
            let text = id3_text(enc, &data[1..]);
            if text.eq_ignore_ascii_case("LABEL") {
                // Value follows the description's terminator.
                let skip = 1 + if matches!(enc, 1 | 2) {
                    data[1..].chunks_exact(2).position(|c| c == [0, 0]).map(|p| p * 2 + 2).unwrap_or(data.len())
                } else {
                    data[1..].iter().position(|&c| c == 0).map(|p| p + 1).unwrap_or(data.len())
                };
                if skip < data.len() {
                    txxx = clean(&id3_text(enc, &data[skip..]));
                }
            }
        }
        i += 10 + len;
    }
    txxx
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn samplers() {
        assert!(is_sampler("Various Artists"));
        assert!(is_sampler(" VA "));
        assert!(is_sampler("VARIOUS"));
        assert!(is_sampler("Verschiedene Interpreten"));
        assert!(!is_sampler("Above & Beyond"));
    }

    fn flac_with(comments: &[&str]) -> Vec<u8> {
        let mut body = Vec::new();
        body.extend_from_slice(&3u32.to_le_bytes());
        body.extend_from_slice(b"ref");
        body.extend_from_slice(&(comments.len() as u32).to_le_bytes());
        for c in comments {
            body.extend_from_slice(&(c.len() as u32).to_le_bytes());
            body.extend_from_slice(c.as_bytes());
        }
        let mut b = b"fLaC".to_vec();
        b.extend_from_slice(&[0x00, 0, 0, 34]);
        b.extend_from_slice(&[0u8; 34]);
        let n = body.len() as u32;
        b.extend_from_slice(&[0x84, (n >> 16) as u8, (n >> 8) as u8, n as u8]);
        b.extend_from_slice(&body);
        b
    }

    #[test]
    fn flac_labels() {
        assert_eq!(label_from_tags(&flac_with(&["ARTIST=x", "ORGANIZATION=Org", "LABEL=Anjunabeats"])).as_deref(), Some("Anjunabeats"));
        assert_eq!(label_from_tags(&flac_with(&["organization=Ultra"])).as_deref(), Some("Ultra"));
        assert_eq!(label_from_tags(&flac_with(&["ARTIST=x"])), None);
    }

    fn id3_with(frames: &[(&[u8; 4], Vec<u8>)], ver: u8) -> Vec<u8> {
        let mut body = Vec::new();
        for (id, data) in frames {
            body.extend_from_slice(*id);
            let n = data.len() as u32;
            if ver == 4 {
                body.extend_from_slice(&[(n >> 21) as u8 & 0x7f, (n >> 14) as u8 & 0x7f, (n >> 7) as u8 & 0x7f, n as u8 & 0x7f]);
            } else {
                body.extend_from_slice(&n.to_be_bytes());
            }
            body.extend_from_slice(&[0, 0]);
            body.extend_from_slice(data);
        }
        let n = body.len();
        let mut b = vec![b'I', b'D', b'3', ver, 0, 0];
        b.extend_from_slice(&[(n >> 21) as u8 & 0x7f, (n >> 14) as u8 & 0x7f, (n >> 7) as u8 & 0x7f, n as u8 & 0x7f]);
        b.extend_from_slice(&body);
        b
    }

    #[test]
    fn id3_labels() {
        let mut tpub = vec![3u8];
        tpub.extend_from_slice("Kompakt".as_bytes());
        assert_eq!(label_from_tags(&id3_with(&[(b"TIT2", b"\x00Title".to_vec()), (b"TPUB", tpub)], 4)).as_deref(), Some("Kompakt"));
        let mut utf16 = vec![1u8, 0xFF, 0xFE];
        for u in "Warp".encode_utf16() {
            utf16.extend_from_slice(&u.to_le_bytes());
        }
        assert_eq!(label_from_tags(&id3_with(&[(b"TPUB", utf16)], 3)).as_deref(), Some("Warp"));
        assert_eq!(label_from_tags(&id3_with(&[(b"TXXX", b"\x00LABEL\x00Ninja Tune".to_vec())], 3)).as_deref(), Some("Ninja Tune"));
        // AIFF with an ID3 chunk.
        let id3 = id3_with(&[(b"TPUB", b"\x00R&S".to_vec())], 3);
        let mut aiff = b"FORM\0\0\0\0AIFF".to_vec();
        aiff.extend_from_slice(b"COMM");
        aiff.extend_from_slice(&18u32.to_be_bytes());
        aiff.extend_from_slice(&[0u8; 18]);
        aiff.extend_from_slice(b"ID3 ");
        aiff.extend_from_slice(&(id3.len() as u32).to_be_bytes());
        aiff.extend_from_slice(&id3);
        assert_eq!(label_from_tags(&aiff).as_deref(), Some("R&S"));
        assert_eq!(label_from_tags(b"RIFF....WAVE"), None);
    }

    #[test]
    fn albums_from_sources() {
        let j = json!({ "Id": "a1", "Name": "Classics 01", "AlbumArtist": "Above & Beyond", "ProductionYear": 2004,
                        "Genres": ["Trance"], "DateCreated": "2024-01-01T00:00:00Z", "ImageTags": { "Primary": "x" },
                        "ChildCount": 12, "ProviderIds": { "MusicBrainzAlbum": "abc-1" } });
        let a = album_jellyfin(&j);
        assert_eq!((a.artist.as_str(), a.year, a.tracks, a.mbid.as_deref(), a.image), ("Above & Beyond", Some(2004), Some(12), Some("abc-1"), true));
        let p = json!({ "ratingKey": "9", "title": "Hits", "parentTitle": "Various Artists", "studio": "Ministry", "addedAt": 1700000000, "leafCount": 20 });
        let b = album_plex(&p);
        assert_eq!((b.label.as_deref(), b.tracks), (Some("Ministry"), Some(20)));
        assert!(b.added_at.unwrap().starts_with("2023-11-14"));
        assert!(is_sampler(&b.artist));
    }
}
