//! Episode chapters, in this order: the feed's chapter file (Podcasting 2.0 `podcast:chapters`),
//! Podlove Simple Chapters in the feed (`psc:chapters`), ID3 CHAP frames at the start of the MP3.
//! Podlove is read with the feed; the chapter file and ID3 at the first opening, then stored.
//! A single chapter counts as none. Out: `[{title, start_ms, end_ms}]`, like Audiobookshelf.

use std::time::Duration;

use futures_util::StreamExt;
use reqwest::header;
use serde_json::{json, Value};

use crate::{error::with_db, AppState};

/// ID3 is read from the first 2 MB of the episode only.
const ID3_BYTES: usize = 2 * 1024 * 1024;
const MAX_JSON_BYTES: usize = 1024 * 1024;

pub struct Chapter {
    pub title: String,
    pub start_ms: i64,
    pub end_ms: Option<i64>,
}

/// Sorted, ends filled in from the next start (the last one from the duration), [] for one chapter.
pub fn to_json(mut list: Vec<Chapter>, duration_ms: Option<i64>) -> Value {
    list.retain(|c| c.start_ms >= 0);
    list.sort_by_key(|c| c.start_ms);
    list.dedup_by_key(|c| c.start_ms);
    if list.len() < 2 {
        return json!([]);
    }
    let starts: Vec<i64> = list.iter().skip(1).map(|c| c.start_ms).collect();
    let out: Vec<Value> = list
        .iter()
        .enumerate()
        .map(|(i, c)| {
            let next = starts.get(i).copied();
            let end = next.or(c.end_ms.filter(|&e| e > c.start_ms)).or(duration_ms).unwrap_or(c.start_ms);
            json!({ "title": c.title.trim(), "start_ms": c.start_ms, "end_ms": end })
        })
        .collect();
    Value::Array(out)
}

/// Normal play time: `HH:MM:SS.mmm`, `MM:SS`, `SS` or `SS.mmm`.
pub fn npt(s: &str) -> Option<i64> {
    let s = s.trim();
    let (main, frac) = match s.split_once('.') {
        Some((m, f)) => (m, f),
        None => (s, ""),
    };
    let mut secs = 0i64;
    for p in main.split(':') {
        secs = secs * 60 + p.trim().parse::<i64>().ok()?;
    }
    let ms = if frac.is_empty() { 0 } else { format!("{:0<3}", &frac[..frac.len().min(3)]).parse::<i64>().ok()? };
    Some(secs * 1000 + ms)
}

/// Podlove Simple Chapters and the URL of a Podcasting 2.0 chapter file of a feed item.
pub fn from_item(it: &rss::Item) -> (Vec<Chapter>, String) {
    let mut psc = Vec::new();
    let mut url = String::new();
    for names in it.extensions().values() {
        for ext in names.get("chapters").into_iter().flatten() {
            if let Some(u) = ext.attrs().get("url").filter(|u| u.starts_with("https://") || u.starts_with("http://")) {
                url = u.trim().to_string();
            }
            for c in ext.children().get("chapter").into_iter().flatten() {
                if let Some(start) = c.attrs().get("start").and_then(|s| npt(s)) {
                    psc.push(Chapter { title: c.attrs().get("title").cloned().unwrap_or_default(), start_ms: start, end_ms: None });
                }
            }
        }
    }
    (psc, url)
}

/// A Podcasting 2.0 JSON chapter file; entries with `"toc": false` are not listed.
pub fn from_json(v: &Value) -> Vec<Chapter> {
    v["chapters"]
        .as_array()
        .map(|a| {
            a.iter()
                .filter(|c| c["toc"].as_bool() != Some(false))
                .filter_map(|c| {
                    Some(Chapter {
                        title: c["title"].as_str().unwrap_or("").to_string(),
                        start_ms: (c["startTime"].as_f64()? * 1000.0) as i64,
                        end_ms: c["endTime"].as_f64().map(|e| (e * 1000.0) as i64),
                    })
                })
                .collect()
        })
        .unwrap_or_default()
}

fn syncsafe(b: &[u8]) -> usize {
    b.iter().fold(0, |n, &x| (n << 7) | (x & 0x7f) as usize)
}

fn be32(b: &[u8]) -> usize {
    b.iter().fold(0, |n, &x| (n << 8) | x as usize)
}

/// Text of an ID3 text frame: the encoding byte, then Latin-1, UTF-16 (with BOM), UTF-16BE or UTF-8.
fn id3_text(b: &[u8]) -> String {
    let Some((&enc, t)) = b.split_first() else { return String::new() };
    let s = match enc {
        1 | 2 => {
            let (le, t) = match t {
                [0xff, 0xfe, r @ ..] => (true, r),
                [0xfe, 0xff, r @ ..] => (false, r),
                r => (false, r),
            };
            let units: Vec<u16> = t.chunks_exact(2).map(|c| if le { u16::from_le_bytes([c[0], c[1]]) } else { u16::from_be_bytes([c[0], c[1]]) }).collect();
            String::from_utf16_lossy(&units)
        }
        3 => String::from_utf8_lossy(t).into_owned(),
        _ => t.iter().map(|&c| c as char).collect(),
    };
    s.trim_end_matches('\0').split('\0').next().unwrap_or("").to_string()
}

/// Frames of an ID3v2.3/2.4 frame area: (id, body).
fn frames(mut b: &[u8], v4: bool) -> Vec<(&[u8], &[u8])> {
    let mut out = Vec::new();
    while b.len() >= 10 && b[0] != 0 {
        let size = if v4 { syncsafe(&b[4..8]) } else { be32(&b[4..8]) };
        if size > b.len() - 10 {
            break;
        }
        out.push((&b[..4], &b[10..10 + size]));
        b = &b[10 + size..];
    }
    out
}

/// CHAP frames of an ID3v2.3/2.4 tag at the start of a file.
pub fn from_id3(b: &[u8]) -> Vec<Chapter> {
    if b.len() < 10 || &b[..3] != b"ID3" || !(b[3] == 3 || b[3] == 4) {
        return Vec::new();
    }
    let v4 = b[3] == 4;
    let end = (10 + syncsafe(&b[6..10])).min(b.len());
    let mut body = &b[10..end];
    // Extended header.
    if b[5] & 0x40 != 0 && body.len() >= 4 {
        let n = if v4 { syncsafe(&body[..4]) } else { be32(&body[..4]) + 4 };
        body = body.get(n..).unwrap_or(&[]);
    }
    frames(body, v4)
        .into_iter()
        .filter(|(id, _)| *id == b"CHAP")
        .filter_map(|(_, f)| {
            let z = f.iter().position(|&c| c == 0)?;
            let t = f.get(z + 1..z + 17)?;
            let (start, stop) = (be32(&t[..4]) as i64, be32(&t[4..8]) as i64);
            let title = frames(&f[z + 17..], v4).into_iter().find(|(id, _)| *id == b"TIT2").map(|(_, x)| id3_text(x)).unwrap_or_default();
            Some(Chapter { title, start_ms: start, end_ms: Some(stop) })
        })
        .collect()
}

async fn fetch(http: &reqwest::Client, url: &str, range: bool, max: usize) -> anyhow::Result<Vec<u8>> {
    let mut req = http.get(url).timeout(Duration::from_secs(20));
    if range {
        req = req.header(header::RANGE, format!("bytes=0-{}", max - 1));
    }
    let res = req.send().await?.error_for_status()?;
    let mut body = Vec::new();
    let mut stream = res.bytes_stream();
    while let Some(chunk) = stream.next().await {
        body.extend_from_slice(&chunk?);
        if body.len() >= max {
            anyhow::ensure!(range, "chapter file larger than {max} bytes");
            body.truncate(max);
            break;
        }
    }
    Ok(body)
}

/// Chapters of an episode: stored ones, else looked up now (chapter file, else ID3 of an MP3)
/// and stored – [] when there are none, so the lookup happens once.
pub async fn of_episode(state: &AppState, id: i64) -> Value {
    let row = with_db(&state.db, move |c| {
        Ok(c.query_row("SELECT chapters, chapters_url, url, mime, duration_s FROM episode WHERE id = ?1", [id], |r| {
            Ok((r.get::<_, Option<String>>(0)?, r.get::<_, String>(1)?, r.get::<_, String>(2)?, r.get::<_, String>(3)?, r.get::<_, Option<i64>>(4)?))
        })?)
    })
    .await;
    let Ok((stored, file, url, mime, dur)) = row else { return json!([]) };
    if let Some(v) = stored.and_then(|s| serde_json::from_str::<Value>(&s).ok()) {
        return v;
    }
    let dur = dur.map(|d| d * 1000);
    let mut list = Vec::new();
    if !file.is_empty() {
        if let Ok(b) = fetch(&state.http, &file, false, MAX_JSON_BYTES).await {
            list = serde_json::from_slice::<Value>(&b).map(|v| from_json(&v)).unwrap_or_default();
        }
    }
    let mp3 = mime.contains("mpeg") || mime.contains("mp3") || url.split('?').next().unwrap_or("").ends_with(".mp3");
    if list.len() < 2 && mp3 {
        if let Ok(b) = fetch(&state.http, &url, true, ID3_BYTES).await {
            list = from_id3(&b);
        }
    }
    let out = to_json(list, dur);
    let s = out.to_string();
    let _ = with_db(&state.db, move |c| Ok(c.execute("UPDATE episode SET chapters = ?2 WHERE id = ?1", (id, s))?)).await;
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn times() {
        assert_eq!(npt("00:01:02.5"), Some(62_500));
        assert_eq!(npt("01:02"), Some(62_000));
        assert_eq!(npt("75"), Some(75_000));
        assert_eq!(npt("1:00:00.123"), Some(3_600_123));
        assert_eq!(npt("x"), None);
    }

    #[test]
    fn podlove_and_file() {
        let xml = r#"<rss version="2.0" xmlns:psc="http://podlove.org/simple-chapters" xmlns:podcast="https://podcastindex.org/namespace/1.0"><channel><title>t</title>
          <item><title>e</title><enclosure url="https://x/e.mp3" type="audio/mpeg" length="1"/>
            <podcast:chapters url="https://x/c.json" type="application/json+chapters"/>
            <psc:chapters version="1.2"><psc:chapter start="00:00:00" title="Intro"/><psc:chapter start="00:05:30.250" title="Thema"/></psc:chapters>
          </item></channel></rss>"#;
        let ch = rss::Channel::read_from(xml.as_bytes()).unwrap();
        let (psc, url) = from_item(&ch.items()[0]);
        assert_eq!(url, "https://x/c.json");
        let v = to_json(psc, Some(600_000));
        assert_eq!(v, json!([{"title":"Intro","start_ms":0,"end_ms":330_250},{"title":"Thema","start_ms":330_250,"end_ms":600_000}]));

        let file = json!({"version":"1.2.0","chapters":[{"startTime":0,"title":"A"},{"startTime":10.5,"title":"hidden","toc":false},{"startTime":20,"title":"B","endTime":30}]});
        assert_eq!(to_json(from_json(&file), None), json!([{"title":"A","start_ms":0,"end_ms":20_000},{"title":"B","start_ms":20_000,"end_ms":30_000}]));
        // One chapter is none.
        assert_eq!(to_json(vec![Chapter { title: "x".into(), start_ms: 0, end_ms: None }], None), json!([]));
    }

    fn frame(id: &[u8], body: &[u8]) -> Vec<u8> {
        let mut f = id.to_vec();
        f.extend_from_slice(&(body.len() as u32).to_be_bytes());
        f.extend_from_slice(&[0, 0]);
        f.extend_from_slice(body);
        f
    }

    #[test]
    fn id3_chapters() {
        let chap = |eid: &str, s: u32, e: u32, title: &str| {
            let mut b = eid.as_bytes().to_vec();
            b.push(0);
            for n in [s, e, u32::MAX, u32::MAX] {
                b.extend_from_slice(&n.to_be_bytes());
            }
            let mut t = vec![3u8];
            t.extend_from_slice(title.as_bytes());
            b.extend(frame(b"TIT2", &t));
            frame(b"CHAP", &b)
        };
        let mut body = frame(b"TIT2", b"\x00Episode");
        body.extend(chap("c1", 0, 60_000, "Anfang"));
        body.extend(chap("c2", 60_000, 120_000, "Grüße"));
        let n = body.len() as u32;
        let mut tag = b"ID3\x03\x00\x00".to_vec();
        tag.extend([(n >> 21) as u8 & 0x7f, (n >> 14) as u8 & 0x7f, (n >> 7) as u8 & 0x7f, n as u8 & 0x7f]);
        tag.extend(body);
        tag.extend([0xff, 0xfb, 0x90]);
        assert_eq!(to_json(from_id3(&tag), None),
            json!([{"title":"Anfang","start_ms":0,"end_ms":60_000},{"title":"Grüße","start_ms":60_000,"end_ms":120_000}]));
        assert!(from_id3(b"not a tag").is_empty());
    }
}
