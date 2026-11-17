//! HTML to Markdown, feeds to Markdown, and paging. Deliberately small: the
//! agent needs the text, the headings, the links and the code, not layout.
//! Scripts, styles and other non-content elements are dropped outright, so no
//! page script ever reaches the agent as text.
//!
//! @trace spec:proxy-container, order:2041-csm4

const SKIP: &[&str] = &[
    "script", "style", "noscript", "svg", "template", "head", "iframe", "object",
];

/// Convert an HTML document to Markdown.
pub fn html_to_markdown(html: &str) -> String {
    let mut out = String::new();
    let mut skip_depth: Option<(String, usize)> = None;
    let mut pre = 0usize;
    let mut links: Vec<Option<String>> = Vec::new();
    let mut rest = html;
    while !rest.is_empty() {
        let Some(lt) = rest.find('<') else {
            if skip_depth.is_none() {
                push_text(&mut out, rest, pre > 0);
            }
            break;
        };
        if skip_depth.is_none() {
            push_text(&mut out, &rest[..lt], pre > 0);
        }
        rest = &rest[lt..];
        if rest.starts_with("<!--") {
            rest = rest.find("-->").map(|e| &rest[e + 3..]).unwrap_or("");
            continue;
        }
        let Some(gt) = rest.find('>') else { break };
        let tag = &rest[1..gt];
        rest = &rest[gt + 1..];
        let closing = tag.starts_with('/');
        let body = tag.trim_start_matches('/');
        let name: String = body
            .chars()
            .take_while(|c| c.is_ascii_alphanumeric())
            .collect::<String>()
            .to_ascii_lowercase();
        if name.is_empty() {
            continue;
        }
        if let Some((skip, depth)) = &mut skip_depth {
            if name == *skip {
                if closing {
                    *depth -= 1;
                    if *depth == 0 {
                        skip_depth = None;
                    }
                } else if !body.ends_with('/') {
                    *depth += 1;
                }
            }
            continue;
        }
        if !closing && SKIP.contains(&name.as_str()) && !body.ends_with('/') {
            skip_depth = Some((name, 1));
            continue;
        }
        match (name.as_str(), closing) {
            (h, false)
                if h.len() == 2 && h.starts_with('h') && h.as_bytes()[1].is_ascii_digit() =>
            {
                let n = (h.as_bytes()[1] - b'0').clamp(1, 6) as usize;
                block(&mut out);
                out.push_str(&"#".repeat(n));
                out.push(' ');
            }
            (h, true) if h.len() == 2 && h.starts_with('h') && h.as_bytes()[1].is_ascii_digit() => {
                block(&mut out)
            }
            (
                "p" | "div" | "section" | "article" | "table" | "ul" | "ol" | "blockquote" | "main",
                _,
            ) => block(&mut out),
            ("tr", _) | ("br", _) => line(&mut out),
            ("td" | "th", false) => out.push_str(" | "),
            ("li", false) => {
                line(&mut out);
                out.push_str("- ");
            }
            ("pre", false) => {
                block(&mut out);
                out.push_str("```\n");
                pre += 1;
            }
            ("pre", true) => {
                pre = pre.saturating_sub(1);
                if !out.ends_with('\n') {
                    out.push('\n');
                }
                out.push_str("```");
                block(&mut out);
            }
            ("code", _) if pre == 0 => out.push('`'),
            ("strong" | "b", _) => out.push_str("**"),
            ("em" | "i", _) => out.push('_'),
            ("a", false) => {
                let href = attr(body, "href").filter(|h| !h.starts_with("javascript:"));
                if href.is_some() {
                    out.push('[');
                }
                links.push(href);
            }
            ("a", true) => {
                if let Some(Some(h)) = links.pop() {
                    out.push_str("](");
                    out.push_str(&h);
                    out.push(')');
                }
            }
            _ => {}
        }
    }
    tidy(&out)
}

fn push_text(out: &mut String, raw: &str, pre: bool) {
    let text = decode_entities(raw);
    if pre {
        out.push_str(&text);
        return;
    }
    let mut last_space = out.ends_with([' ', '\n']) || out.is_empty();
    for c in text.chars() {
        if c.is_whitespace() {
            if !last_space {
                out.push(' ');
                last_space = true;
            }
        } else {
            out.push(c);
            last_space = false;
        }
    }
}

fn block(out: &mut String) {
    trim_trailing_spaces(out);
    if !out.is_empty() && !out.ends_with("\n\n") {
        out.push_str(if out.ends_with('\n') { "\n" } else { "\n\n" });
    }
}

fn line(out: &mut String) {
    trim_trailing_spaces(out);
    if !out.is_empty() && !out.ends_with('\n') {
        out.push('\n');
    }
}

fn trim_trailing_spaces(out: &mut String) {
    while out.ends_with(' ') {
        out.pop();
    }
}

fn tidy(s: &str) -> String {
    let mut out = String::new();
    let mut blanks = 0;
    for l in s.lines() {
        let l = l.trim_end();
        if l.trim().is_empty() {
            blanks += 1;
            if blanks > 1 {
                continue;
            }
        } else {
            blanks = 0;
        }
        out.push_str(l);
        out.push('\n');
    }
    out.trim().to_string()
}

/// The value of attribute `name` in a tag body, quoted or bare.
pub fn attr(body: &str, name: &str) -> Option<String> {
    let lower = body.to_ascii_lowercase();
    let mut from = 0;
    while let Some(i) = lower[from..].find(name) {
        let at = from + i;
        from = at + name.len();
        let before_ok = at == 0 || lower.as_bytes()[at - 1].is_ascii_whitespace();
        let after = lower[from..].trim_start();
        if !before_ok || !after.starts_with('=') {
            continue;
        }
        let v = body[body.len() - after.len() + 1..].trim_start();
        let val = if let Some(q) = v.chars().next().filter(|c| *c == '"' || *c == '\'') {
            v[1..].split(q).next().unwrap_or("")
        } else {
            v.split(|c: char| c.is_whitespace() || c == '>' || c == '/')
                .next()
                .unwrap_or("")
        };
        return Some(decode_entities(val));
    }
    None
}

pub fn decode_entities(s: &str) -> String {
    if !s.contains('&') {
        return s.to_string();
    }
    let mut out = String::with_capacity(s.len());
    let mut rest = s;
    while let Some(i) = rest.find('&') {
        out.push_str(&rest[..i]);
        rest = &rest[i..];
        let Some(semi) = rest[..rest.len().min(12)].find(';') else {
            out.push('&');
            rest = &rest[1..];
            continue;
        };
        let ent = &rest[1..semi];
        let rep = match ent {
            "amp" => Some('&'),
            "lt" => Some('<'),
            "gt" => Some('>'),
            "quot" => Some('"'),
            "apos" | "#39" => Some('\''),
            "nbsp" => Some(' '),
            _ if ent.starts_with("#x") || ent.starts_with("#X") => {
                u32::from_str_radix(&ent[2..], 16)
                    .ok()
                    .and_then(char::from_u32)
            }
            _ if ent.starts_with('#') => ent[1..].parse().ok().and_then(char::from_u32),
            _ => None,
        };
        match rep {
            Some(c) => {
                out.push(c);
                rest = &rest[semi + 1..];
            }
            None => {
                out.push('&');
                rest = &rest[1..];
            }
        }
    }
    out.push_str(rest);
    out
}

/// One page of `text`, `size` characters long, 1-based, split on character
/// boundaries. Returns the page and the total page count.
pub fn page(text: &str, page: usize, size: usize) -> (String, usize) {
    let size = size.max(1);
    let chars: Vec<char> = text.chars().collect();
    let total = chars.len().div_ceil(size).max(1);
    let p = page.clamp(1, total);
    let start = (p - 1) * size;
    let end = (start + size).min(chars.len());
    (chars[start..end].iter().collect(), total)
}

/// RSS `<item>` or Atom `<entry>` elements as a Markdown list, newest first as
/// the feed orders them, at most `limit`.
pub fn feed_to_markdown(xml: &str, limit: usize) -> String {
    let mut out = String::new();
    for tag in ["item", "entry"] {
        let open = format!("<{tag}");
        let close = format!("</{tag}>");
        let mut rest = xml;
        while let Some(i) = rest.find(&open) {
            let after = &rest[i + open.len()..];
            if !after.starts_with(['>', ' ', '\n', '\t', '\r']) {
                rest = after;
                continue;
            }
            let Some(end) = after.find(&close) else { break };
            let item = &after[..end];
            rest = &after[end + close.len()..];
            let title = element(item, "title").unwrap_or_default();
            let link = element(item, "link")
                .filter(|l| !l.is_empty())
                .or_else(|| {
                    item.find("<link")
                        .and_then(|j| item[j..].find('>').map(|k| &item[j + 5..j + k]))
                        .and_then(|b| attr(b, "href"))
                })
                .unwrap_or_default();
            let date = element(item, "pubDate")
                .or_else(|| element(item, "updated"))
                .or_else(|| element(item, "published"))
                .unwrap_or_default();
            out.push_str(&format!(
                "- [{}]({}) {}\n",
                title.trim(),
                link.trim(),
                date.trim()
            ));
            if out.lines().count() >= limit {
                return out.trim_end().to_string();
            }
        }
    }
    out.trim_end().to_string()
}

fn element(xml: &str, name: &str) -> Option<String> {
    let open = format!("<{name}");
    let i = xml.find(&open)?;
    let after = &xml[i + open.len()..];
    let gt = after.find('>')?;
    if after[..gt].ends_with('/') {
        return Some(String::new());
    }
    let body = &after[gt + 1..];
    let end = body.find(&format!("</{name}>"))?;
    let raw = body[..end].trim();
    let raw = raw
        .strip_prefix("<![CDATA[")
        .and_then(|r| r.strip_suffix("]]>"))
        .unwrap_or(raw);
    Some(html_to_markdown(raw))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn converts_structure_and_drops_scripts() {
        let md = html_to_markdown(
            "<html><head><title>T</title><script>alert(1)</script></head><body>\
             <h1>Vec</h1><p>A <b>growable</b> array &amp; more.</p>\
             <script>steal()</script><style>p{}</style>\
             <ul><li>one</li><li><a href=\"/x?a=1&amp;b=2\">two</a></li></ul>\
             <pre><code>let v = vec![1];\n  v.len()</code></pre>\
             <p>inline <code>x</code><!-- hidden --></p></body></html>",
        );
        assert!(
            md.starts_with("# Vec\n\nA **growable** array & more."),
            "{md}"
        );
        assert!(
            !md.contains("alert")
                && !md.contains("steal")
                && !md.contains("p{}")
                && !md.contains("hidden")
        );
        assert!(md.contains("- one\n- [two](/x?a=1&b=2)"), "{md}");
        assert!(md.contains("```\nlet v = vec![1];\n  v.len()\n```"), "{md}");
        assert!(md.contains("inline `x`"));
    }

    #[test]
    fn javascript_links_are_text_only() {
        assert_eq!(html_to_markdown("<a href='javascript:x()'>go</a>"), "go");
    }

    #[test]
    fn entities_and_paging() {
        assert_eq!(
            decode_entities("&lt;a&gt; &#65;&#x42; &bogus; &"),
            "<a> AB &bogus; &"
        );
        let (p, n) = page("abcdé", 2, 2);
        assert_eq!((p.as_str(), n), ("cd", 3));
        assert_eq!(page("abcdé", 9, 2).0, "é");
        assert_eq!(page("", 1, 10), (String::new(), 1));
    }

    #[test]
    fn rss_and_atom() {
        let rss = "<rss><channel><title>B</title><item><title>Rust 1.90</title>\
                   <link>https://blog.rust-lang.org/a</link><pubDate>Mon</pubDate></item>\
                   <item><title><![CDATA[Two & more]]></title><link>https://b/2</link></item></channel></rss>";
        assert_eq!(
            feed_to_markdown(rss, 10),
            "- [Rust 1.90](https://blog.rust-lang.org/a) Mon\n- [Two & more](https://b/2)"
        );
        let atom = "<feed><entry><title>v5.6</title><link rel=\"alternate\" href=\"https://g/r/5.6\"/>\
                    <updated>2026-11-01</updated></entry></feed>";
        assert_eq!(
            feed_to_markdown(atom, 10),
            "- [v5.6](https://g/r/5.6) 2026-11-01"
        );
        assert_eq!(feed_to_markdown(rss, 1).lines().count(), 1);
    }
}
