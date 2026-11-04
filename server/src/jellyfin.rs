//! Jellyfin as a source: library browsing, item metadata incl. audio quality, stream and
//! image URLs. The API key stays on the server; clients only see audiojoe URLs.

use std::{collections::HashMap, time::Duration};

use axum::{http::header, response::Response};
use serde_json::{json, Value};

use crate::{
    audiobookshelf::natural_cmp,
    error::{with_db, ApiError, ApiResult},
    sources::Browse,
    AppState,
};

/// Jellyfin and Emby (Jellyfin is a fork of Emby; the API is largely the same).
/// Emby: tested against Emby Server 4.10 (tools/dev/e2e.py, EMBY_TEST_FILE).
#[derive(Clone)]
pub struct Jellyfin {
    pub source_id: i64,
    pub base: String,
    key: String,
    /// "jellyfin" or "emby" – also the prefix of item keys.
    pub kind: String,
}

impl Jellyfin {
    /// Request header carrying the API key.
    pub fn auth(&self) -> (header::HeaderName, String) {
        if self.kind == "emby" {
            return (header::HeaderName::from_static("x-emby-token"), self.key.clone());
        }
        (
            header::AUTHORIZATION,
            format!(
                "MediaBrowser Client=\"audiojoe\", Device=\"audiojoe-server\", DeviceId=\"audiojoe-server\", Version=\"{}\", Token=\"{}\"",
                env!("CARGO_PKG_VERSION"),
                self.key
            ),
        )
    }

    pub(crate) async fn get(&self, http: &reqwest::Client, path: &str, query: &[(&str, String)]) -> ApiResult<Value> {
        let res = http
            .get(format!("{}{path}", self.base))
            .query(query)
            .header(self.auth().0, self.auth().1)
            .timeout(Duration::from_secs(20))
            .send()
            .await
            .map_err(|e| ApiError::BadGateway(format!("{} unreachable: {}", self.kind, e.without_url())))?;
        if res.status() == reqwest::StatusCode::NOT_FOUND {
            return Err(ApiError::NotFound);
        }
        if !res.status().is_success() {
            return Err(ApiError::BadGateway(format!("jellyfin answered {}", res.status())));
        }
        res.json().await.map_err(|e| ApiError::BadGateway(format!("jellyfin: invalid response: {e}")))
    }

    /// The Jellyfin user whose library is browsed: the first administrator.
    pub(crate) async fn user_id(&self, state: &AppState) -> ApiResult<String> {
        if let Some(id) = state.jellyfin_users.lock().unwrap().get(&self.source_id) {
            return Ok(id.clone());
        }
        let users = self.get(&state.http, "/Users", &[]).await?;
        let users = users.as_array().cloned().unwrap_or_default();
        let user = users
            .iter()
            .find(|u| u["Policy"]["IsAdministrator"].as_bool() == Some(true))
            .or_else(|| users.first())
            .and_then(|u| u["Id"].as_str())
            .ok_or_else(|| ApiError::BadGateway("jellyfin has no users".into()))?
            .to_string();
        state.jellyfin_users.lock().unwrap().insert(self.source_id, user.clone());
        Ok(user)
    }

    pub fn stream_url(&self, item: &str) -> String {
        format!("{}/Audio/{}/stream?static=true", self.base, item)
    }

    pub async fn item(&self, state: &AppState, item: &str) -> ApiResult<Value> {
        let uid = self.user_id(state).await?;
        let v = self
            .get(&state.http, &format!("/Users/{uid}/Items/{item}"), &[("Fields", "MediaSources,MediaStreams,Overview".into())])
            .await?;
        Ok(normalize(&self.kind, self.source_id, &v))
    }
}

/// Loads a Jellyfin or Emby source.
pub async fn source(state: &AppState, id: i64) -> ApiResult<Jellyfin> {
    with_db(&state.db, move |c| {
        Ok(c.query_row(
            "SELECT url, secret, kind FROM source WHERE id = ?1 AND kind IN ('jellyfin', 'emby')",
            [id],
            |r| Ok(Jellyfin { source_id: id, base: r.get(0)?, key: r.get(1)?, kind: r.get(2)? }),
        )?)
    })
    .await
}

/// Audio quality of the first audio stream of a Jellyfin item.
fn quality(v: &Value) -> Value {
    let src = &v["MediaSources"][0];
    let streams = src["MediaStreams"].as_array().or_else(|| v["MediaStreams"].as_array());
    let audio = streams.and_then(|s| s.iter().find(|m| m["Type"] == "Audio"));
    match audio {
        Some(a) => json!({
            "codec": a["Codec"].as_str().unwrap_or("").to_lowercase(),
            "sample_rate": a["SampleRate"].as_i64(),
            "bit_depth": a["BitDepth"].as_i64(),
            "bitrate": a["BitRate"].as_i64().or_else(|| src["Bitrate"].as_i64()),
            "channels": a["Channels"].as_i64(),
            "container": src["Container"].as_str(),
            "size": src["Size"].as_i64(),
        }),
        None => Value::Null,
    }
}

fn normalize(prefix: &str, source: i64, v: &Value) -> Value {
    let id = v["Id"].as_str().unwrap_or_default();
    let typ = v["Type"].as_str().unwrap_or_default();
    let kind = match typ {
        "Audio" => "track",
        "MusicAlbum" => "album",
        "MusicArtist" => "artist",
        _ => "folder",
    };
    let artists = v["AlbumArtist"]
        .as_str()
        .map(str::to_string)
        .or_else(|| v["Artists"].as_array().map(|a| a.iter().filter_map(|x| x.as_str()).collect::<Vec<_>>().join(", ")))
        .unwrap_or_default();
    let subtitle = match kind {
        "track" => [artists.as_str(), v["Album"].as_str().unwrap_or("")].iter().filter(|s| !s.is_empty()).cloned().collect::<Vec<_>>().join(" · "),
        _ => artists,
    };
    json!({
        "key": format!("{prefix}:{source}:{id}"),
        "kind": kind,
        "title": v["Name"].as_str().unwrap_or(""),
        "subtitle": subtitle,
        "year": v["ProductionYear"].as_i64(),
        "genres": v["Genres"].as_array().map(|g| g.iter().filter_map(|x| x.as_str()).take(4).collect::<Vec<_>>()).unwrap_or_default(),
        "track": v["IndexNumber"].as_i64(),
        "disc": v["ParentIndexNumber"].as_i64(),
        "duration_ms": v["RunTimeTicks"].as_i64().map(|t| t / 10_000),
        "image": v["ImageTags"]["Primary"].as_str().map(|_| format!("/api/v1/image/{prefix}:{source}:{id}")),
        "description": v["Overview"].as_str().map(crate::podcasts::plain_text),
        "notes": v["Overview"].as_str().map(crate::notes::html).filter(|s| !s.is_empty()),
        "quality": if kind == "track" { quality(v) } else { Value::Null },
        // The album of a title: the apps' cache pill saves the whole album.
        "album": v["AlbumId"].as_str().filter(|a| kind == "track" && valid_id(a)).map(|a| format!("{prefix}:{source}:{a}")),
    })
}

// ---------------------------------------------------------------- browsing

pub fn valid_id(id: &str) -> bool {
    !id.is_empty() && id.len() <= 64 && id.chars().all(|c| c.is_ascii_alphanumeric() || c == '-')
}

pub async fn browse(state: &AppState, source_id: i64, q: &Browse) -> ApiResult<Value> {
    let jf = source(state, source_id).await?;
    let uid = jf.user_id(state).await?;
    let start = q.start.unwrap_or(0).to_string();
    let limit = q.limit.unwrap_or(100).clamp(1, 500).to_string();
    let fields = ("Fields", "MediaSources,MediaStreams".to_string());

    let items: Value = if let Some(term) = q.search.clone().filter(|s| !s.trim().is_empty()) {
        jf.get(&state.http, &format!("/Users/{uid}/Items"), &[
            ("SearchTerm", term),
            ("IncludeItemTypes", "MusicAlbum,Audio,MusicArtist".into()),
            ("Recursive", "true".into()),
            ("StartIndex", start),
            ("Limit", limit),
            fields,
        ])
        .await?
    } else if let Some(parent) = q.parent.clone() {
        if !valid_id(&parent) {
            return Err(ApiError::BadRequest("invalid parent".into()));
        }
        let p = jf.get(&state.http, &format!("/Users/{uid}/Items/{parent}"), &[]).await?;
        let mut query = vec![("ParentId", parent.clone()), ("StartIndex", start), ("Limit", limit), fields];
        match (p["Type"].as_str(), p["CollectionType"].as_str()) {
            // Music library: all albums, alphabetically.
            (_, Some("music")) => query.extend([
                ("IncludeItemTypes", "MusicAlbum".to_string()),
                ("Recursive", "true".to_string()),
                ("SortBy", "AlbumArtist,SortName".to_string()),
            ]),
            (Some("MusicAlbum"), _) => query.push(("SortBy", "ParentIndexNumber,IndexNumber,SortName".to_string())),
            (Some("MusicArtist"), _) => {
                query.retain(|(k, _)| *k != "ParentId");
                query.extend([
                    ("ArtistIds", parent),
                    ("IncludeItemTypes", "MusicAlbum".to_string()),
                    ("Recursive", "true".to_string()),
                    ("SortBy", "ProductionYear,SortName".to_string()),
                ]);
            }
            _ => query.push(("SortBy", "IsFolder,SortName".to_string())),
        }
        jf.get(&state.http, &format!("/Users/{uid}/Items"), &query).await?
    } else {
        // Top level: the audio libraries.
        let views = jf.get(&state.http, &format!("/Users/{uid}/Views"), &[]).await?;
        let items: Vec<Value> = views["Items"]
            .as_array()
            .map(|a| {
                a.iter()
                    .filter(|v| matches!(v["CollectionType"].as_str(), Some("music" | "audiobooks" | "books") | None))
                    .cloned()
                    .collect()
            })
            .unwrap_or_default();
        json!({ "Items": items, "TotalRecordCount": items.len() })
    };

    let list: Vec<Value> = items["Items"].as_array().map(|a| a.iter().map(|v| normalize(&jf.kind, source_id, v)).collect()).unwrap_or_default();
    Ok(json!({ "items": list, "total": items["TotalRecordCount"] }))
}

/// Cover image of an item, relayed so the API key never reaches the client.
pub async fn image(state: &AppState, src: i64, item: &str) -> ApiResult<Response> {
    if !valid_id(item) {
        return Err(ApiError::NotFound);
    }
    let jf = source(state, src).await?;
    let req = state
        .http
        .get(format!("{}/Items/{item}/Images/Primary", jf.base))
        .query(&[("maxHeight", "400"), ("quality", "85")])
        .header(jf.auth().0, jf.auth().1);
    crate::sources::relay_image(req).await
}

// ---------------------------------------------------------------- audiobooks
//
// Jellyfin ("Books" library) and Emby ("Audiobooks" library) keep one audiobook per folder:
// the audio files carry album (= book title) and album artist (= author). Keys of books are
// `jbook:<source>:<folder>`; a file lying directly in the library is a book of its own.
// Neither server knows series or narrators for audiobooks.

/// Audiobook libraries of a source: (id, name).
pub async fn book_libraries(state: &AppState, src: i64) -> ApiResult<Vec<(String, String)>> {
    let jf = source(state, src).await?;
    let uid = jf.user_id(state).await?;
    let views = jf.get(&state.http, &format!("/Users/{uid}/Views"), &[]).await?;
    Ok(views["Items"]
        .as_array()
        .map(|a| {
            a.iter()
                .filter(|v| matches!(v["CollectionType"].as_str(), Some("audiobooks" | "books")))
                .filter_map(|v| Some((v["Id"].as_str()?.to_string(), v["Name"].as_str().unwrap_or("").to_string())))
                .collect()
        })
        .unwrap_or_default())
}

const BOOK_FIELDS: &str = "ParentId,Album,AlbumArtist,Artists,ProductionYear,DateCreated,Overview,RunTimeTicks,ImageTags";

/// All items of a kind below a folder, page by page (a household library fits in memory).
async fn all_items(jf: &Jellyfin, state: &AppState, uid: &str, parent: &str, types: &str) -> ApiResult<Vec<Value>> {
    let mut out: Vec<Value> = Vec::new();
    loop {
        let v = jf
            .get(&state.http, &format!("/Users/{uid}/Items"), &[
                ("ParentId", parent.to_string()),
                ("Recursive", "true".to_string()),
                ("IncludeItemTypes", types.to_string()),
                ("Fields", BOOK_FIELDS.to_string()),
                ("SortBy", "ParentIndexNumber,IndexNumber,SortName".to_string()),
                ("StartIndex", out.len().to_string()),
                ("Limit", "1000".to_string()),
            ])
            .await?;
        let page = v["Items"].as_array().cloned().unwrap_or_default();
        let n = page.len();
        out.extend(page);
        if n < 1000 || out.len() >= 20_000 {
            return Ok(out);
        }
    }
}

fn author_of(f: &Value) -> String {
    f["AlbumArtist"]
        .as_str()
        .map(str::trim)
        .filter(|s| !s.is_empty())
        .map(str::to_string)
        .or_else(|| f["Artists"].as_array().and_then(|a| a.first()).and_then(|x| x.as_str()).map(|s| s.trim().to_string()))
        .unwrap_or_default()
}

fn epoch_ms(v: &Value) -> Option<i64> {
    v.as_str().and_then(|s| chrono::DateTime::parse_from_rfc3339(s).ok()).map(|d| d.timestamp_millis())
}

/// Cover: the folder's own image, else the first file that has one.
fn cover(kind: &str, src: i64, folder: Option<&Value>, files: &[Value]) -> Value {
    if let Some(f) = folder.filter(|f| f["ImageTags"]["Primary"].is_string()) {
        return json!(format!("/api/v1/image/jbook:{src}:{}", f["Id"].as_str().unwrap_or("")));
    }
    files
        .iter()
        .find(|f| f["ImageTags"]["Primary"].is_string())
        .map(|f| json!(format!("/api/v1/image/{kind}:{src}:{}", f["Id"].as_str().unwrap_or(""))))
        .unwrap_or(Value::Null)
}

/// The shelf of a library (same shape as Audiobookshelf's): books, authors, series (none).
pub fn shelf(kind: &str, src: i64, lib: &str, files: &[Value], folders: &HashMap<String, Value>, progress: &HashMap<String, (i64, bool)>) -> Value {
    struct B { id: String, flat: bool, files: Vec<Value> }
    let mut order: Vec<String> = Vec::new();
    let mut books: HashMap<String, B> = HashMap::new();
    for f in files {
        let parent = f["ParentId"].as_str().unwrap_or("");
        let (id, flat) = if !parent.is_empty() && parent != lib { (parent.to_string(), false) } else { (f["Id"].as_str().unwrap_or("").to_string(), true) };
        if !books.contains_key(&id) {
            order.push(id.clone());
        }
        books.entry(id.clone()).or_insert(B { id, flat, files: Vec::new() }).files.push(f.clone());
    }
    let mut out: Vec<Value> = order
        .iter()
        .map(|id| {
            let b = &books[id];
            let folder = if b.flat { None } else { folders.get(&b.id) };
            let first = &b.files[0];
            let title = first["Album"]
                .as_str()
                .map(str::trim)
                .filter(|s| !s.is_empty())
                .or_else(|| folder.and_then(|f| f["Name"].as_str()))
                .or_else(|| first["Name"].as_str())
                .unwrap_or("")
                .to_string();
            let author = author_of(first);
            let key = format!("jbook:{src}:{}", b.id);
            let (pos, fin) = progress.get(&key).copied().unwrap_or((0, false));
            let duration: i64 = b.files.iter().filter_map(|f| f["RunTimeTicks"].as_i64()).map(|t| t / 10_000).sum();
            let added = folder.and_then(|f| epoch_ms(&f["DateCreated"])).or_else(|| b.files.iter().filter_map(|f| epoch_ms(&f["DateCreated"])).min());
            json!({
                "key": key, "kind": "book", "title": title, "subtitle": author,
                "year": first["ProductionYear"].as_i64(),
                "duration_ms": duration, "image": cover(kind, src, folder, &b.files), "quality": null,
                "author": author, "narrator": "", "series": null, "sequence": null, "volume": null,
                "added": added, "position_ms": pos, "finished": fin,
            })
        })
        .collect();
    out.sort_by(|a, b| natural_cmp(a["title"].as_str().unwrap_or(""), b["title"].as_str().unwrap_or("")));
    let mut authors: std::collections::BTreeMap<String, (String, usize)> = Default::default();
    for b in out.iter().filter(|b| !b["author"].as_str().unwrap_or("").is_empty()) {
        let name = b["author"].as_str().unwrap_or("");
        authors.entry(name.to_lowercase()).or_insert_with(|| (name.to_string(), 0)).1 += 1;
    }
    let authors: Vec<Value> = authors.into_values().map(|(name, n)| json!({ "name": name, "books": n })).collect();
    json!({ "books": out, "authors": authors, "series": [] })
}

/// `/api/v1/sources/{id}/books?parent=<library>` for Jellyfin and Emby.
pub async fn library(state: &AppState, user: i64, src: i64, lib: &str) -> ApiResult<Value> {
    if !valid_id(lib) {
        return Err(ApiError::BadRequest("invalid library".into()));
    }
    let jf = source(state, src).await?;
    let uid = jf.user_id(state).await?;
    let files = all_items(&jf, state, &uid, lib, "Audio,AudioBook").await?;
    let folders: HashMap<String, Value> = all_items(&jf, state, &uid, lib, "Folder,MusicAlbum")
        .await?
        .into_iter()
        .filter_map(|f| Some((f["Id"].as_str()?.to_string(), f)))
        .collect();
    let prefix = format!("jbook:{src}:");
    let progress: HashMap<String, (i64, bool)> = with_db(&state.db, move |c| {
        let mut st = c.prepare("SELECT item_key, position_ms, finished FROM playback WHERE user_id = ?1 AND item_key LIKE ?2 || '%'")?;
        let rows = st.query_map((user, &prefix), |r| Ok((r.get::<_, String>(0)?, (r.get::<_, i64>(1)?, r.get::<_, bool>(2)?))))?;
        Ok(rows.collect::<Result<_, _>>()?)
    })
    .await?;
    Ok(shelf(&jf.kind, src, lib, &files, &folders, &progress))
}

/// A book for playing: metadata with parts (one per file) and the files' stream URLs.
pub async fn book(state: &AppState, jf: &Jellyfin, id: &str) -> ApiResult<(Value, Vec<String>)> {
    if !valid_id(id) {
        return Err(ApiError::NotFound);
    }
    let uid = jf.user_id(state).await?;
    let fields = format!("{BOOK_FIELDS},MediaSources,MediaStreams");
    let v = jf.get(&state.http, &format!("/Users/{uid}/Items/{id}"), &[("Fields", fields.clone())]).await?;
    let files: Vec<Value> = if v["IsFolder"] == true {
        jf.get(&state.http, &format!("/Users/{uid}/Items"), &[
            ("ParentId", id.to_string()),
            ("Recursive", "true".to_string()),
            ("IncludeItemTypes", "Audio,AudioBook".to_string()),
            ("SortBy", "ParentIndexNumber,IndexNumber,SortName".to_string()),
            ("Fields", fields),
        ])
        .await?["Items"]
            .as_array()
            .cloned()
            .unwrap_or_default()
    } else {
        vec![v.clone()]
    };
    if files.is_empty() {
        return Err(ApiError::NotFound);
    }
    let folder = (v["IsFolder"] == true).then_some(&v);
    let first = &files[0];
    let title = first["Album"]
        .as_str()
        .map(str::trim)
        .filter(|s| !s.is_empty())
        .or_else(|| v["Name"].as_str())
        .unwrap_or("")
        .to_string();
    let mut parts = Vec::new();
    let mut offset = 0i64;
    for (i, f) in files.iter().enumerate() {
        let dur = f["RunTimeTicks"].as_i64().unwrap_or(0) / 10_000;
        parts.push(json!({ "index": i, "start_ms": offset, "duration_ms": dur, "title": f["Name"].as_str().unwrap_or("") }));
        offset += dur;
    }
    let chapters: Vec<Value> = parts.iter().map(|p| json!({ "title": p["title"], "start_ms": p["start_ms"],
        "end_ms": p["start_ms"].as_i64().unwrap_or(0) + p["duration_ms"].as_i64().unwrap_or(0) })).collect();
    let overview = folder.and_then(|f| f["Overview"].as_str()).or_else(|| first["Overview"].as_str());
    let meta = json!({
        "key": format!("jbook:{}:{id}", jf.source_id), "kind": "book", "title": title, "subtitle": author_of(first),
        "year": first["ProductionYear"].as_i64(), "duration_ms": offset,
        "image": cover(&jf.kind, jf.source_id, folder, &files),
        "description": overview.map(crate::podcasts::plain_text),
        "notes": overview.map(crate::notes::html).filter(|s| !s.is_empty()),
        "quality": quality(first), "parts": parts, "chapters": chapters,
    });
    let urls = files.iter().map(|f| jf.stream_url(f["Id"].as_str().unwrap_or(""))).collect();
    Ok((meta, urls))
}

/// Checks URL and key; returns server name and version.
pub async fn check(state: &AppState, kind: &str, url: &str, key: &str) -> ApiResult<Value> {
    let probe = Jellyfin { source_id: 0, base: url.to_string(), key: key.to_string(), kind: kind.to_string() };
    let info = probe.get(&state.http, "/System/Info", &[]).await?;
    Ok(json!({ "server": info["ServerName"], "version": info["Version"] }))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn track_names_its_album() {
        // 0.1.7: the apps' cache pill saves the whole album of a single title.
        let t = normalize("jellyfin", 2, &json!({ "Id": "t1", "Type": "Audio", "Name": "So What", "AlbumId": "a9" }));
        assert_eq!(t["album"], "jellyfin:2:a9");
        let a = normalize("jellyfin", 2, &json!({ "Id": "a9", "Type": "MusicAlbum", "Name": "Kind of Blue" }));
        assert!(a["album"].is_null());
        let bad = normalize("jellyfin", 2, &json!({ "Id": "t2", "Type": "Audio", "AlbumId": "../x" }));
        assert!(bad["album"].is_null());
    }

    #[test]
    fn shelf_groups_files_by_folder_and_counts_authors() {
        // Emby 4.10, library "Hörbücher" (id 12): files of type Audio with Album/AlbumArtist.
        let f = |id: &str, parent: &str, album: &str, artist: &str, n: i64| json!({
            "Id": id, "Type": "Audio", "ParentId": parent, "Album": album, "AlbumArtist": artist, "Name": format!("Kapitel {n}"),
            "IndexNumber": n, "RunTimeTicks": 200_000_000i64, "DateCreated": "2026-11-01T11:49:00.0000000Z", "ImageTags": {}
        });
        let files = vec![
            f("27", "21", "Die Nebelstadt 1 - Der Anfang", "Anna Beispiel", 1), f("28", "21", "Die Nebelstadt 1 - Der Anfang", "Anna Beispiel", 2),
            f("30", "22", "Die Nebelstadt 2 - Die Rückkehr", "Anna Beispiel", 1),
            f("18", "16", "Das lange Schweigen", "Bert Muster", 1),
            f("40", "12", "", "Carla Solo", 1), // lies directly in the library: a book of its own
        ];
        let folders: HashMap<String, Value> = [("21", "Die Nebelstadt 1 - Der Anfang"), ("22", "Die Nebelstadt 2 - Die Rückkehr"), ("16", "Das lange Schweigen")]
            .iter().map(|(id, name)| (id.to_string(), json!({ "Id": id, "Name": name, "ImageTags": { "Primary": "x" } }))).collect();
        let progress = HashMap::from([("jbook:3:21".to_string(), (5000i64, false))]);
        let s = shelf("emby", 3, "12", &files, &folders, &progress);
        let books = s["books"].as_array().unwrap();
        assert_eq!(books.len(), 4);
        let titles: Vec<&str> = books.iter().map(|b| b["title"].as_str().unwrap()).collect();
        assert_eq!(titles, ["Das lange Schweigen", "Die Nebelstadt 1 - Der Anfang", "Die Nebelstadt 2 - Die Rückkehr", "Kapitel 1"]);
        let neb1 = books.iter().find(|b| b["key"] == "jbook:3:21").unwrap();
        assert_eq!(neb1["duration_ms"], 40_000);
        assert_eq!(neb1["position_ms"], 5000);
        assert_eq!(neb1["image"], "/api/v1/image/jbook:3:21");
        assert_eq!(neb1["author"], "Anna Beispiel");
        assert_eq!(books.iter().find(|b| b["key"] == "jbook:3:40").unwrap()["author"], "Carla Solo");
        let authors = s["authors"].as_array().unwrap();
        assert_eq!(authors.len(), 3);
        assert_eq!(authors.iter().find(|a| a["name"] == "Anna Beispiel").unwrap()["books"], 2);
        assert!(s["series"].as_array().unwrap().is_empty());
    }
}
