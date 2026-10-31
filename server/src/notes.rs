//! Shownotes: the formatted description of an episode or item as filtered HTML. Only
//! paragraphs, line breaks, lists, headings, emphasis and links survive; scripts, styles,
//! images and every attribute but a link's target are removed. The clients render this small
//! set themselves.

use std::collections::HashSet;

/// Longest source text taken in (bytes); longer notes are cut, the filter closes open tags.
const MAX_SOURCE: usize = 64 * 1024;

/// Filtered HTML from a feed's or source's description. Plain text (no tags) becomes
/// paragraphs, with bare web addresses turned into links.
pub fn html(src: &str) -> String {
    let src = src.trim();
    if src.is_empty() {
        return String::new();
    }
    let src = cut(src, MAX_SOURCE);
    let src = if looks_like_html(src) { src.to_string() } else { from_plain(src) };
    let tags: HashSet<&str> =
        ["p", "br", "ul", "ol", "li", "a", "b", "strong", "i", "em", "h1", "h2", "h3", "h4", "h5", "h6", "blockquote"]
            .into_iter()
            .collect();
    let clean = ammonia::Builder::default()
        .tags(tags)
        .clean_content_tags(["script", "style"].into_iter().collect())
        .generic_attributes(HashSet::new())
        .tag_attributes([("a", ["href"].into_iter().collect())].into_iter().collect())
        .url_schemes(["http", "https", "mailto"].into_iter().collect())
        .url_relative(ammonia::UrlRelative::Deny)
        .link_rel(Some("noopener noreferrer nofollow"))
        .clean(&src)
        .to_string();
    // Empty paragraphs left over from removed images or spacer markup.
    let clean = clean.replace("<p></p>", "").replace("<p><br></p>", "");
    clean.trim().to_string()
}

fn cut(s: &str, max: usize) -> &str {
    if s.len() <= max {
        return s;
    }
    let mut end = max;
    while !s.is_char_boundary(end) {
        end -= 1;
    }
    &s[..end]
}

fn looks_like_html(s: &str) -> bool {
    let l = s.to_ascii_lowercase();
    ["<p", "<br", "<a ", "<ul", "<ol", "<li", "<div", "<b>", "<strong", "<i>", "<em", "<h1", "<h2", "<h3", "<span"]
        .iter()
        .any(|t| l.contains(t))
}

fn escape(s: &str) -> String {
    s.replace('&', "&amp;").replace('<', "&lt;").replace('>', "&gt;").replace('"', "&quot;")
}

/// Plain text to paragraphs: blank lines separate paragraphs, single newlines become breaks.
fn from_plain(s: &str) -> String {
    let s = s.replace("\r\n", "\n");
    s.split("\n\n")
        .map(str::trim)
        .filter(|p| !p.is_empty())
        .map(|p| format!("<p>{}</p>", p.lines().map(linkify).collect::<Vec<_>>().join("<br>")))
        .collect()
}

/// Escapes a line and turns http(s) addresses into links.
fn linkify(line: &str) -> String {
    let mut out = String::new();
    for (i, word) in line.split(' ').enumerate() {
        if i > 0 {
            out.push(' ');
        }
        let trimmed = word.trim_end_matches(['.', ',', ';', ':', ')', '!', '?']);
        if (trimmed.starts_with("https://") || trimmed.starts_with("http://")) && trimmed.len() > 8 {
            let e = escape(trimmed);
            out.push_str(&format!("<a href=\"{e}\">{e}</a>{}", escape(&word[trimmed.len()..])));
        } else {
            out.push_str(&escape(word));
        }
    }
    out
}

#[cfg(test)]
mod tests {
    use super::html;

    #[test]
    fn keeps_structure_and_removes_the_rest() {
        let out = html(
            r#"<p style="color:red" onclick="x()">Hallo <b>Welt</b></p><script>alert(1)</script>
               <img src="https://tracker.example/p.gif"><ul><li><a href="https://example.org/a" target="_blank">Link</a></li>
               <li><a href="javascript:alert(1)">böse</a></li></ul><iframe src="https://x"></iframe>"#,
        );
        assert!(out.contains("<p>Hallo <b>Welt</b></p>"), "{out}");
        assert!(out.contains(r#"<a href="https://example.org/a" rel="noopener noreferrer nofollow">Link</a>"#), "{out}");
        assert!(!out.contains("script") && !out.contains("alert") && !out.contains("img") && !out.contains("iframe"), "{out}");
        assert!(!out.contains("style") && !out.contains("onclick") && !out.contains("target"), "{out}");
    }

    #[test]
    fn plain_text_becomes_paragraphs_with_links() {
        let out = html("Erste Zeile\nzweite Zeile\n\nMehr unter https://example.org/x. Danke <3");
        assert_eq!(
            out,
            r#"<p>Erste Zeile<br>zweite Zeile</p><p>Mehr unter <a href="https://example.org/x" rel="noopener noreferrer nofollow">https://example.org/x</a>. Danke &lt;3</p>"#
        );
    }
}
