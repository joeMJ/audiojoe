//! OPML import and export of podcast subscriptions (the format every podcast app reads).

use axum::{
    extract::State,
    http::header,
    response::{IntoResponse, Response},
    Json,
};
use futures_util::StreamExt;
use quick_xml::{events::Event, escape::escape, Reader};
use serde_json::{json, Value};

use crate::{
    auth::CurrentUser,
    error::{with_db, ApiError, ApiResult},
    podcasts, AppState,
};

const MAX_FEEDS: usize = 1000;
/// Feeds fetched at the same time during an import.
const PARALLEL: usize = 4;

/// Feed addresses of all `<outline xmlUrl=…>` elements, in document order, without duplicates.
pub fn feed_urls(xml: &str) -> anyhow::Result<Vec<String>> {
    let mut reader = Reader::from_str(xml);
    let mut urls: Vec<String> = Vec::new();
    loop {
        match reader.read_event()? {
            Event::Start(e) | Event::Empty(e) if e.local_name().as_ref() == b"outline" => {
                for a in e.attributes().flatten() {
                    if a.key.local_name().as_ref().eq_ignore_ascii_case(b"xmlUrl") {
                        let url = a.decoded_and_normalized_value(quick_xml::XmlVersion::Implicit1_0, reader.decoder())?.trim().to_string();
                        if !url.is_empty() && !urls.contains(&url) {
                            urls.push(url);
                        }
                    }
                }
            }
            Event::Eof => break,
            _ => {}
        }
    }
    Ok(urls)
}

pub async fn export(State(state): State<AppState>, user: CurrentUser) -> ApiResult<Response> {
    let feeds: Vec<(String, String)> = with_db(&state.db, move |c| {
        let mut stmt = c.prepare(
            "SELECT p.title, p.feed_url FROM podcast p JOIN subscription s ON s.podcast_id = p.id
             WHERE s.user_id = ?1 ORDER BY p.title COLLATE NOCASE",
        )?;
        let rows = stmt.query_map([user.id], |r| Ok((r.get(0)?, r.get(1)?)))?.collect::<Result<_, _>>()?;
        Ok(rows)
    })
    .await?;
    let mut xml = String::from(
        "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<opml version=\"2.0\">\n  <head><title>audiojoe</title></head>\n  <body>\n",
    );
    for (title, url) in feeds {
        let title = if title.is_empty() { url.clone() } else { title };
        xml += &format!(
            "    <outline type=\"rss\" text=\"{t}\" title=\"{t}\" xmlUrl=\"{u}\"/>\n",
            t = escape(title.as_str()),
            u = escape(url.as_str())
        );
    }
    xml += "  </body>\n</opml>\n";
    Ok((
        [
            (header::CONTENT_TYPE, "text/x-opml; charset=utf-8"),
            (header::CONTENT_DISPOSITION, "attachment; filename=\"audiojoe.opml\""),
        ],
        xml,
    )
        .into_response())
}

/// Body: the OPML file. Subscribes to every feed in it; unusable feeds are listed, not fatal.
pub async fn import(State(state): State<AppState>, user: CurrentUser, body: String) -> ApiResult<Json<Value>> {
    let urls = feed_urls(&body).map_err(|e| ApiError::BadRequest(format!("not an OPML file: {e}")))?;
    if urls.is_empty() {
        return Err(ApiError::BadRequest("no feeds in this OPML file".into()));
    }
    if urls.len() > MAX_FEEDS {
        return Err(ApiError::BadRequest(format!("more than {MAX_FEEDS} feeds")));
    }
    let uid = user.id;
    let before: Vec<String> = with_db(&state.db, move |c| {
        let mut stmt = c.prepare("SELECT p.feed_url FROM podcast p JOIN subscription s ON s.podcast_id = p.id WHERE s.user_id = ?1")?;
        let rows = stmt.query_map([uid], |r| r.get(0))?.collect::<Result<_, _>>()?;
        Ok(rows)
    })
    .await?;
    let results: Vec<(String, Result<i64, String>)> = futures_util::stream::iter(urls)
        .map(|url| {
            let state = state.clone();
            async move {
                let r = podcasts::subscribe_url(&state, uid, &url).await.map_err(reason);
                (url, r)
            }
        })
        .buffer_unordered(PARALLEL)
        .collect()
        .await;
    let (mut added, mut existing, mut failed) = (0, 0, Vec::new());
    for (url, r) in results {
        match r {
            Ok(_) if before.contains(&url) => existing += 1,
            Ok(_) => added += 1,
            Err(e) => failed.push(json!({ "feed_url": url, "error": e })),
        }
    }
    Ok(Json(json!({ "added": added, "existing": existing, "failed": failed })))
}

/// Short reason for the import report (internal details stay in the log).
fn reason(e: ApiError) -> String {
    match e {
        ApiError::BadRequest(m) | ApiError::BadGateway(m) => m,
        ApiError::Internal(e) => {
            tracing::error!("OPML import: {e:#}");
            "internal error".into()
        }
        _ => "failed".into(),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn reads_nested_outlines() {
        let xml = r#"<?xml version="1.0"?><opml version="1.0"><head/><body>
            <outline text="Gruppe"><outline type="rss" text="A &amp; B" xmlUrl="https://a.example/feed?x=1&amp;y=2"/>
            <outline text="ohne"/></outline>
            <outline type="rss" xmlurl=" https://b.example/rss "></outline>
            <outline type="rss" xmlUrl="https://b.example/rss"/>
          </body></opml>"#;
        assert_eq!(feed_urls(xml).unwrap(), ["https://a.example/feed?x=1&y=2", "https://b.example/rss"]);
        assert!(feed_urls("<opml><body><outline").is_err() || feed_urls("<opml><body><outline").unwrap().is_empty());
    }
}
