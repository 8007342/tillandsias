//! A small robots.txt reader: the groups for our agent token (or `*` when no
//! group names us), their Allow and Disallow rules, and longest-match wins,
//! with Allow winning a tie (RFC 9309 §2.2.2). `*` and `$` in paths are
//! honoured. An unreadable robots.txt is treated as allow-all, as the RFC says
//! for a 4xx; a 5xx is treated as disallow-all by the caller.
//!
//! @trace spec:proxy-container, order:2041-csm4

pub const AGENT: &str = "tillandsias-enclave-fetch";

#[derive(Debug, Default, Clone)]
pub struct Robots {
    rules: Vec<(bool, String)>,
}

impl Robots {
    pub fn allow_all() -> Self {
        Self::default()
    }

    pub fn disallow_all() -> Self {
        Self {
            rules: vec![(false, "/".into())],
        }
    }

    pub fn parse(text: &str) -> Self {
        let mut ours: Vec<(bool, String)> = Vec::new();
        let mut star: Vec<(bool, String)> = Vec::new();
        let mut named_us = false;
        let mut group_agents: Vec<String> = Vec::new();
        let mut in_rules = false;
        for raw in text.lines() {
            let line = raw.split('#').next().unwrap_or("").trim();
            let Some((k, v)) = line.split_once(':') else {
                continue;
            };
            let k = k.trim().to_ascii_lowercase();
            let v = v.trim();
            match k.as_str() {
                "user-agent" => {
                    if in_rules {
                        group_agents.clear();
                        in_rules = false;
                    }
                    group_agents.push(v.to_ascii_lowercase());
                }
                "allow" | "disallow" => {
                    in_rules = true;
                    if v.is_empty() {
                        continue;
                    }
                    let rule = (k == "allow", v.to_string());
                    if group_agents.iter().any(|a| a == AGENT) {
                        named_us = true;
                        ours.push(rule.clone());
                    }
                    if group_agents.iter().any(|a| a == "*") {
                        star.push(rule);
                    }
                }
                _ => {}
            }
        }
        // A group naming us with only empty rules still names us.
        if !named_us
            && text
                .lines()
                .any(|l| l.trim().to_ascii_lowercase() == format!("user-agent: {AGENT}"))
        {
            named_us = true;
        }
        Robots {
            rules: if named_us { ours } else { star },
        }
    }

    /// Whether `path` (path plus query) may be fetched.
    pub fn allowed(&self, path: &str) -> bool {
        let mut best: Option<(usize, bool)> = None;
        for (allow, pat) in &self.rules {
            if matches(pat, path) {
                let len = pat.len();
                best = match best {
                    Some((l, a)) if l > len || (l == len && a) => Some((l, a)),
                    _ => Some((len, *allow)),
                };
            }
        }
        best.map(|(_, a)| a).unwrap_or(true)
    }
}

fn matches(pat: &str, path: &str) -> bool {
    let (pat, anchored) = match pat.strip_suffix('$') {
        Some(p) => (p, true),
        None => (pat, false),
    };
    let parts: Vec<&str> = pat.split('*').collect();
    let mut pos = 0;
    for (i, part) in parts.iter().enumerate() {
        if i == 0 {
            if !path.starts_with(part) {
                return false;
            }
            pos = part.len();
        } else if let Some(at) = path[pos..].find(part) {
            pos += at + part.len();
        } else {
            return false;
        }
    }
    if anchored {
        if parts.len() == 1 {
            return path.len() == pos;
        }
        let last = parts.last().copied().unwrap_or("");
        return path.ends_with(last);
    }
    true
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn star_group_longest_match_allow_wins_tie() {
        let r = Robots::parse(
            "User-agent: *\nDisallow: /private/\nAllow: /private/ok\nDisallow: /*.pdf$\n",
        );
        assert!(r.allowed("/docs/a.html"));
        assert!(!r.allowed("/private/x"));
        assert!(r.allowed("/private/ok/page"));
        assert!(!r.allowed("/files/a.pdf"));
        assert!(r.allowed("/files/a.pdf?x=1"));
    }

    #[test]
    fn our_group_overrides_star() {
        let r = Robots::parse(&format!(
            "User-agent: *\nDisallow: /\n\nUser-agent: {AGENT}\nDisallow: /secret\n"
        ));
        assert!(r.allowed("/docs"));
        assert!(!r.allowed("/secret/x"));
    }

    #[test]
    fn grouped_agents_share_rules_and_empty_disallow_allows() {
        let r = Robots::parse(
            "User-agent: foo\nUser-agent: *\nDisallow: /a\n\nUser-agent: bar\nDisallow:\n",
        );
        assert!(!r.allowed("/a/b"));
        assert!(r.allowed("/b"));
        assert!(!Robots::disallow_all().allowed("/x"));
        assert!(Robots::allow_all().allowed("/x"));
    }
}
