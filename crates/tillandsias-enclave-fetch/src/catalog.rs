//! The curated catalog: one entry per source, each with a reason and a
//! provenance. A URL is fetchable only when an entry covers it: same scheme,
//! same host, and a path at or under the entry's path.
//!
//! @trace spec:proxy-container, order:2041-csm4

use serde::Deserialize;
use url::Url;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum Kind {
    Docs,
    Feed,
    Page,
}

#[derive(Debug, Clone, Deserialize)]
pub struct Source {
    pub name: String,
    pub kind: Kind,
    pub url: String,
    #[serde(default)]
    pub search: Option<String>,
    pub reason: String,
    pub provenance: String,
}

#[derive(Debug, Clone, Deserialize)]
pub struct Catalog {
    pub version: u32,
    pub sources: Vec<Source>,
}

#[derive(Debug, PartialEq, Eq)]
pub enum CatalogError {
    Parse(String),
    Invalid(String),
}

impl std::fmt::Display for CatalogError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            CatalogError::Parse(e) => write!(f, "catalog parse error: {e}"),
            CatalogError::Invalid(e) => write!(f, "catalog invalid: {e}"),
        }
    }
}

impl Catalog {
    /// Parse and validate. Refuses non-https URLs, empty reasons or
    /// provenance, duplicate names, and a `search` template off the entry's
    /// own host or without `{query}`.
    pub fn parse(text: &str) -> Result<Self, CatalogError> {
        let cat: Catalog =
            serde_yaml::from_str(text).map_err(|e| CatalogError::Parse(e.to_string()))?;
        let mut seen = std::collections::HashSet::new();
        for s in &cat.sources {
            let who = &s.name;
            if !seen.insert(s.name.clone()) {
                return Err(CatalogError::Invalid(format!("{who}: duplicate name")));
            }
            if s.reason.trim().is_empty() || s.provenance.trim().is_empty() {
                return Err(CatalogError::Invalid(format!(
                    "{who}: reason and provenance are required"
                )));
            }
            let u = Url::parse(&s.url)
                .map_err(|e| CatalogError::Invalid(format!("{who}: bad url: {e}")))?;
            if u.scheme() != "https" || u.host_str().is_none() {
                return Err(CatalogError::Invalid(format!("{who}: url must be https")));
            }
            if let Some(t) = &s.search {
                if !t.contains("{query}") {
                    return Err(CatalogError::Invalid(format!(
                        "{who}: search template lacks {{query}}"
                    )));
                }
                let su = Url::parse(&t.replace("{query}", "q"))
                    .map_err(|e| CatalogError::Invalid(format!("{who}: bad search: {e}")))?;
                if su.scheme() != "https" || su.host_str() != u.host_str() {
                    return Err(CatalogError::Invalid(format!(
                        "{who}: search must stay on the entry's https host"
                    )));
                }
            }
        }
        Ok(cat)
    }

    /// The entry covering `url`, if any.
    pub fn covering(&self, url: &Url) -> Option<&Source> {
        self.sources.iter().find(|s| covers(&s.url, url))
    }

    pub fn named(&self, name: &str, kind: Kind) -> Option<&Source> {
        self.sources
            .iter()
            .find(|s| s.name == name && s.kind == kind)
    }
}

/// Whether `base` covers `url`: same scheme, host and port, and the path is
/// `base`'s path or below it on a segment boundary (`/docs/` does not cover
/// `/docsevil`).
pub fn covers(base: &str, url: &Url) -> bool {
    let Ok(b) = Url::parse(base) else {
        return false;
    };
    if b.scheme() != url.scheme()
        || b.host_str().map(str::to_ascii_lowercase) != url.host_str().map(str::to_ascii_lowercase)
        || b.port_or_known_default() != url.port_or_known_default()
        || !url.username().is_empty()
        || url.password().is_some()
    {
        return false;
    }
    let bp = b.path();
    let up = url.path();
    if bp.ends_with('/') {
        up.starts_with(bp) || up == bp.trim_end_matches('/')
    } else {
        up == bp || up.starts_with(&format!("{bp}/"))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const CAT: &str = r#"
version: 1
sources:
  - name: rust-std
    kind: docs
    url: https://doc.rust-lang.org/std/
    search: https://doc.rust-lang.org/std/?search={query}
    reason: r
    provenance: p
  - name: blog
    kind: feed
    url: https://blog.rust-lang.org/feed.xml
    reason: r
    provenance: p
"#;

    fn u(s: &str) -> Url {
        Url::parse(s).unwrap()
    }

    #[test]
    fn covers_paths_on_segment_boundaries() {
        let c = Catalog::parse(CAT).unwrap();
        assert!(
            c.covering(&u("https://doc.rust-lang.org/std/vec/struct.Vec.html"))
                .is_some()
        );
        assert!(c.covering(&u("https://doc.rust-lang.org/std")).is_some());
        assert!(c.covering(&u("https://doc.rust-lang.org/stdx/")).is_none());
        assert!(c.covering(&u("https://doc.rust-lang.org/book/")).is_none());
        assert!(c.covering(&u("http://doc.rust-lang.org/std/")).is_none());
        assert!(
            c.covering(&u("https://doc.rust-lang.org:8443/std/"))
                .is_none()
        );
        assert!(c.covering(&u("https://evil.example/std/")).is_none());
        assert!(c.covering(&u("https://x@doc.rust-lang.org/std/")).is_none());
        assert!(
            c.covering(&u("https://blog.rust-lang.org/feed.xml"))
                .is_some()
        );
        assert!(
            c.covering(&u("https://blog.rust-lang.org/feed.xmlx"))
                .is_none()
        );
    }

    #[test]
    fn refuses_bad_entries() {
        let bad = |s: &str| Catalog::parse(s).is_err();
        assert!(bad(
            "version: 1\nsources:\n  - {name: a, kind: docs, url: 'http://a.org/', reason: r, provenance: p}\n"
        ));
        assert!(bad(
            "version: 1\nsources:\n  - {name: a, kind: docs, url: 'https://a.org/', reason: '', provenance: p}\n"
        ));
        assert!(bad(
            "version: 1\nsources:\n  - {name: a, kind: docs, url: 'https://a.org/', reason: r, provenance: p}\n  - {name: a, kind: feed, url: 'https://b.org/', reason: r, provenance: p}\n"
        ));
        assert!(bad(
            "version: 1\nsources:\n  - {name: a, kind: docs, url: 'https://a.org/', search: 'https://b.org/?q={query}', reason: r, provenance: p}\n"
        ));
        assert!(bad(
            "version: 1\nsources:\n  - {name: a, kind: docs, url: 'https://a.org/', search: 'https://a.org/?q=x', reason: r, provenance: p}\n"
        ));
        assert!(bad(
            "version: 1\nsources:\n  - {name: a, kind: weird, url: 'https://a.org/', reason: r, provenance: p}\n"
        ));
    }

    #[test]
    fn the_shipped_catalog_parses() {
        let text = include_str!("../../../images/enclave-fetch/catalog.yaml");
        let c = Catalog::parse(text).expect("shipped catalog valid");
        assert!(c.named("rust-std", Kind::Docs).is_some());
        assert!(c.sources.iter().any(|s| s.kind == Kind::Feed));
    }
}
