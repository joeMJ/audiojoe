//! The documentation from `docs/` as HTML pages, built into the server so that the apps can link
//! to it ("About" → manual, privacy) before and without a public repository:
//! `/docs/<page>.html` in English, `/docs/de/<page>.html` in German, `/docs/screenshots/<file>`.
//! No login needed: the pages only contain what the public repository contains.

use axum::{
    extract::Path,
    http::{header, HeaderValue, StatusCode},
    response::{IntoResponse, Response},
};
use pulldown_cmark::{html, CowStr, Event, Options, Parser, Tag};

/// (page, German Markdown, English Markdown, file names that link to it)
const PAGES: &[(&str, &str, &str, &[&str])] = &[
    ("start", include_str!("../../docs/ERSTE-SCHRITTE.md"), include_str!("../../docs/ERSTE-SCHRITTE.en.md"),
     &["ERSTE-SCHRITTE.md", "ERSTE-SCHRITTE.en.md"]),
    ("manual", include_str!("../../docs/ANLEITUNG.md"), include_str!("../../docs/ANLEITUNG.en.md"),
     &["ANLEITUNG.md", "ANLEITUNG.en.md"]),
    ("install", include_str!("../../docs/install-server.md"), include_str!("../../docs/install-server.en.md"),
     &["install-server.md", "install-server.en.md"]),
    ("install-ubuntu", include_str!("../../docs/install-ubuntu.md"), include_str!("../../docs/install-ubuntu.en.md"),
     &["install-ubuntu.md", "install-ubuntu.en.md"]),
    ("install-debian", include_str!("../../docs/install-debian.md"), include_str!("../../docs/install-debian.en.md"),
     &["install-debian.md", "install-debian.en.md"]),
    ("install-windows", include_str!("../../docs/install-windows.md"), include_str!("../../docs/install-windows.en.md"),
     &["install-windows.md", "install-windows.en.md"]),
    ("install-android", include_str!("../../docs/install-android.md"), include_str!("../../docs/install-android.en.md"),
     &["install-android.md", "install-android.en.md"]),
    ("privacy", include_str!("../../docs/DATENSCHUTZ.md"), include_str!("../../docs/DATENSCHUTZ.en.md"),
     &["DATENSCHUTZ.md", "DATENSCHUTZ.en.md"]),
    ("third-party", include_str!("../../THIRD_PARTY.md"), include_str!("../../THIRD_PARTY.md"),
     &["THIRD_PARTY.md", "../THIRD_PARTY.md"]),
];

include!(concat!(env!("OUT_DIR"), "/screenshots.rs"));

const REPO: &str = "https://github.com/joeMJ/audiojoe/blob/main/";

/// A link target in the Markdown as a path on this server (other pages, screenshots); files that
/// are not served (licence, sources) point to the public repository.
fn target(url: &str, de: bool) -> String {
    if url.contains("://") || url.starts_with('#') || url.starts_with("mailto:") {
        return url.to_string();
    }
    let (file, anchor) = url.split_once('#').map_or((url, ""), |(f, a)| (f, a));
    let anchor = if anchor.is_empty() { String::new() } else { format!("#{anchor}") };
    if let Some(shot) = file.strip_prefix("screenshots/").or_else(|| file.strip_prefix("docs/screenshots/")) {
        return format!("/docs/screenshots/{shot}");
    }
    if file.is_empty() {
        return anchor;
    }
    let name = file.trim_start_matches("docs/");
    match PAGES.iter().find(|p| p.3.contains(&name)) {
        Some(p) => format!("/docs/{}{}.html{anchor}", if de { "de/" } else { "" }, p.0),
        None => format!("{REPO}{}{anchor}", file.trim_start_matches("../")),
    }
}

fn render(md: &str, de: bool) -> (String, String) {
    let opts = Options::ENABLE_TABLES | Options::ENABLE_STRIKETHROUGH | Options::ENABLE_GFM | Options::ENABLE_HEADING_ATTRIBUTES;
    let mut title = String::new();
    let mut in_title = false;
    let events = Parser::new_ext(md, opts).map(|e| match e {
        Event::Start(Tag::Link { link_type, dest_url, title: t, id }) => {
            Event::Start(Tag::Link { link_type, dest_url: CowStr::from(target(&dest_url, de)), title: t, id })
        }
        Event::Start(Tag::Image { link_type, dest_url, title: t, id }) => {
            Event::Start(Tag::Image { link_type, dest_url: CowStr::from(target(&dest_url, de)), title: t, id })
        }
        // Raw HTML in the Markdown (centred pictures in the README style) is passed through –
        // the files come from this repository only – with the picture paths of this server.
        Event::Html(h) => Event::Html(CowStr::from(h.replace("src=\"screenshots/", "src=\"/docs/screenshots/"))),
        Event::InlineHtml(h) => Event::InlineHtml(CowStr::from(h.replace("src=\"screenshots/", "src=\"/docs/screenshots/"))),
        e => e,
    });
    let mut out = String::new();
    let mut events: Vec<Event> = events
        .inspect(|e| match e {
            Event::Start(Tag::Heading { level: pulldown_cmark::HeadingLevel::H1, .. }) if title.is_empty() => in_title = true,
            Event::Text(t) if in_title => title.push_str(t),
            Event::End(pulldown_cmark::TagEnd::Heading(_)) => in_title = false,
            _ => {}
        })
        .collect();
    // Anchors like GitHub's, so links such as `install-server.md#sonos` work here as well.
    for i in 0..events.len() {
        if let Event::Start(Tag::Heading { id: None, .. }) = &events[i] {
            let mut text = String::new();
            for e in &events[i + 1..] {
                match e {
                    Event::Text(t) | Event::Code(t) => text.push_str(t),
                    Event::End(pulldown_cmark::TagEnd::Heading(_)) => break,
                    _ => {}
                }
            }
            if let Event::Start(Tag::Heading { id, .. }) = &mut events[i] {
                *id = Some(CowStr::from(slug(&text)));
            }
        }
    }
    html::push_html(&mut out, events.into_iter());
    (title, out)
}

/// GitHub's heading anchor: lower case, letters, digits, `-` and `_` kept, spaces as `-`.
fn slug(text: &str) -> String {
    text.trim()
        .to_lowercase()
        .chars()
        .filter_map(|c| match c {
            ' ' => Some('-'),
            c if c.is_alphanumeric() || c == '-' || c == '_' => Some(c),
            _ => None,
        })
        .collect()
}

fn escape(s: &str) -> String {
    s.replace('&', "&amp;").replace('<', "&lt;").replace('>', "&gt;").replace('"', "&quot;")
}

fn page(name: &str, de: bool) -> Option<String> {
    let p = PAGES.iter().find(|p| p.0 == name)?;
    let (title, body) = render(if de { p.1 } else { p.2 }, de);
    let nav = |slug: &str, de_label: &str, en_label: &str| {
        let label = if de { de_label } else { en_label };
        let here = if slug == name { " aria-current=\"page\"" } else { "" };
        format!("<a href=\"/docs/{}{slug}.html\"{here}>{label}</a>", if de { "de/" } else { "" })
    };
    let other = if de { format!("<a href=\"/docs/{name}.html\" lang=\"en\">English</a>") }
                else { format!("<a href=\"/docs/de/{name}.html\" lang=\"de\">Deutsch</a>") };
    Some(format!(
        "<!doctype html><html lang=\"{lang}\"><head><meta charset=\"utf-8\">\
         <meta name=\"viewport\" content=\"width=device-width, initial-scale=1\">\
         <title>{title} – audiojoe</title><link rel=\"icon\" href=\"/favicon.png\"><style>{CSS}</style></head><body>\
         <header><a class=\"home\" href=\"/\"><img src=\"/icon-192.png\" alt=\"\" width=\"28\" height=\"28\">audiojoe</a>\
         <nav>{} {} {} {} {other}</nav></header><main>{body}</main></body></html>",
        nav("start", "Erste Schritte", "Getting started"),
        nav("manual", "Anleitung", "Manual"),
        nav("install", "Installation", "Installation"),
        nav("privacy", "Datenschutz", "Privacy"),
        lang = if de { "de" } else { "en" },
        title = escape(&title),
    ))
}

const CSS: &str = "\
:root{color-scheme:light dark;--bg:#fff;--fg:#1b1f24;--muted:#5a6470;--line:#d5dae0;--accent:#1f5fd1;--panel:#f3f5f8}\
@media (prefers-color-scheme:dark){:root{--bg:#121417;--fg:#e8eaed;--muted:#a3abb5;--line:#343a42;--accent:#7aa7ff;--panel:#1d2126}}\
body{margin:0;background:var(--bg);color:var(--fg);font:16px/1.55 system-ui,sans-serif}\
header{display:flex;flex-wrap:wrap;gap:8px 18px;align-items:center;padding:10px 16px;border-bottom:1px solid var(--line)}\
header .home{display:flex;gap:8px;align-items:center;font-weight:800;color:var(--fg);text-decoration:none}\
header img{border-radius:7px}nav{display:flex;flex-wrap:wrap;gap:4px 14px}nav a[aria-current]{font-weight:800}\
main{max-width:860px;margin:0 auto;padding:8px 16px 48px}a{color:var(--accent)}img{max-width:100%;height:auto}\
table{border-collapse:collapse;display:block;overflow-x:auto}th,td{border:1px solid var(--line);padding:4px 8px;text-align:left;vertical-align:top}\
code{background:var(--panel);padding:1px 4px;border-radius:4px}pre{background:var(--panel);padding:10px;overflow-x:auto;border-radius:6px}\
pre code{padding:0}blockquote{margin:0;padding:2px 14px;border-left:4px solid var(--line);color:var(--muted)}\
.markdown-alert{border-left-color:#c58a00}\
";

fn html_response(body: String) -> Response {
    ([(header::CONTENT_TYPE, HeaderValue::from_static("text/html; charset=utf-8"))], body).into_response()
}

pub async fn english(Path(file): Path<String>) -> Response {
    match file.strip_suffix(".html").and_then(|n| page(n, false)) {
        Some(b) => html_response(b),
        None => StatusCode::NOT_FOUND.into_response(),
    }
}

pub async fn german(Path(file): Path<String>) -> Response {
    match file.strip_suffix(".html").and_then(|n| page(n, true)) {
        Some(b) => html_response(b),
        None => StatusCode::NOT_FOUND.into_response(),
    }
}

pub async fn screenshot(Path(file): Path<String>) -> Response {
    match SCREENSHOTS.iter().find(|s| s.0 == file) {
        Some((_, bytes)) => ([(header::CONTENT_TYPE, HeaderValue::from_static("image/webp"))], *bytes).into_response(),
        None => StatusCode::NOT_FOUND.into_response(),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn links() {
        assert_eq!(target("DATENSCHUTZ.md#immer", true), "/docs/de/privacy.html#immer");
        assert_eq!(target("DATENSCHUTZ.en.md", false), "/docs/privacy.html");
        assert_eq!(target("docs/ANLEITUNG.md", true), "/docs/de/manual.html");
        assert_eq!(target("screenshots/radio.webp", true), "/docs/screenshots/radio.webp");
        assert_eq!(target("../LICENSE", true), "https://github.com/joeMJ/audiojoe/blob/main/LICENSE");
        assert_eq!(target("https://example.org/x", true), "https://example.org/x");
    }

    #[test]
    fn anchors() {
        assert_eq!(slug("Fehler melden und Wünsche"), "fehler-melden-und-wünsche");
        assert_eq!(slug("HTTPS über den Proxy"), "https-über-den-proxy");
        assert!(page("install", true).unwrap().contains("id=\"sonos\""));
    }

    #[test]
    fn every_page_renders() {
        for p in PAGES {
            for de in [true, false] {
                let html = page(p.0, de).unwrap();
                assert!(html.contains("<h1"), "{} has no heading", p.0);
                // Pages that are not built in may be linked on GitHub; no other link may end in .md.
                let local_md = html.split("href=\"").skip(1).filter_map(|r| r.split('"').next())
                    .any(|u| u.split('#').next().unwrap_or("").ends_with(".md") && !u.starts_with(REPO));
                assert!(!local_md, "{} still links a .md file", p.0);
                assert!(!html.contains("src=\"screenshots/"), "{} has a picture path of the repository", p.0);
            }
        }
    }

    /// Every picture a page shows is built into the server (0.1.9 shipped without them).
    #[test]
    fn every_picture_is_built_in() {
        let mut shown = 0;
        for p in PAGES {
            for de in [true, false] {
                let html = page(p.0, de).unwrap();
                for file in html.split("/docs/screenshots/").skip(1).filter_map(|r| r.split('"').next()) {
                    shown += 1;
                    let shot = SCREENSHOTS.iter().find(|s| s.0 == file);
                    assert!(shot.is_some(), "{} shows {file}, which is not built in", p.0);
                    let bytes = shot.unwrap().1;
                    assert!(bytes.len() > 1000 && &bytes[..4] == b"RIFF" && &bytes[8..12] == b"WEBP", "{file} is no WebP picture");
                }
            }
        }
        assert!(shown > 0, "no page shows a picture");
    }
}
