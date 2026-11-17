//! The fetch path. In order, for every URL including each redirect hop:
//! the catalog must cover it, every address its host resolves to must be
//! public, the connection is pinned to an address that passed, robots.txt
//! must allow it, and the response is capped. No cookie store, no
//! credentials, no Authorization or Referer header, ever.
//!
//! @trace spec:proxy-container, order:2041-csm4

use crate::catalog::Catalog;
use crate::ipguard;
use crate::robots::{self, Robots};
use std::collections::HashMap;
use std::net::SocketAddr;
use std::sync::Mutex;
use std::time::Duration;
use url::Url;

pub const MAX_BYTES: usize = 4 * 1024 * 1024;
pub const MAX_REDIRECTS: usize = 5;
pub const DEFAULT_PER_MINUTE: u32 = 60;
pub const DEFAULT_BURST: u32 = 20;
const TIMEOUT: Duration = Duration::from_secs(20);

/// Why a fetch did not happen. `kind()` is the audit verdict.
#[derive(Debug, PartialEq, Eq)]
pub enum Refusal {
    BadUrl(String),
    NotInCatalog(String),
    Unresolvable(String),
    NonPublicAddress {
        host: String,
        ip: String,
        why: &'static str,
    },
    Robots(String),
    TooManyRedirects,
    UnsupportedType(String),
    TooLarge,
    Upstream(String),
}

impl Refusal {
    pub fn kind(&self) -> &'static str {
        match self {
            Refusal::BadUrl(_) => "bad-url",
            Refusal::NotInCatalog(_) => "not-in-catalog",
            Refusal::Unresolvable(_) => "unresolvable",
            Refusal::NonPublicAddress { .. } => "non-public-address",
            Refusal::Robots(_) => "robots-disallow",
            Refusal::TooManyRedirects => "too-many-redirects",
            Refusal::UnsupportedType(_) => "unsupported-type",
            Refusal::TooLarge => "too-large",
            Refusal::Upstream(_) => "upstream-error",
        }
    }
}

impl std::fmt::Display for Refusal {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Refusal::BadUrl(u) => write!(f, "not a valid URL: {u}"),
            Refusal::NotInCatalog(u) => write!(
                f,
                "{u} is not in the enclave-fetch catalog; ask the operator to add it (images/enclave-fetch/catalog.yaml)"
            ),
            Refusal::Unresolvable(h) => write!(f, "{h} did not resolve"),
            Refusal::NonPublicAddress { host, ip, why } => {
                write!(
                    f,
                    "{host} resolves to {ip} ({why}); only public addresses are fetched"
                )
            }
            Refusal::Robots(u) => write!(f, "robots.txt disallows {u}"),
            Refusal::TooManyRedirects => write!(f, "more than {MAX_REDIRECTS} redirects"),
            Refusal::UnsupportedType(t) => write!(f, "content type {t} is not text"),
            Refusal::TooLarge => write!(f, "response larger than {MAX_BYTES} bytes"),
            Refusal::Upstream(e) => write!(f, "upstream: {e}"),
        }
    }
}

/// A fetched document.
#[derive(Debug)]
pub struct Fetched {
    pub final_url: Url,
    pub content_type: String,
    pub body: String,
}

/// Fixed answers for a host, so tests can exercise the address checks
/// without DNS.
pub type ResolveOverride = HashMap<String, Vec<SocketAddr>>;

pub struct Fetcher {
    pub catalog: Catalog,
    /// Upstream HTTP proxy (the proxy's research port). When set, squid makes
    /// the connection: the address checks still run here first, but the pin
    /// is squid's resolution, not ours (curated-egress-tiers task 7.1 closes
    /// that with the SNI/destination check).
    pub proxy: Option<String>,
    pub resolve_override: ResolveOverride,
    /// Per-client call limit (order 2041-9aiq).
    pub limiter: crate::ratelimit::Limiter,
    robots: Mutex<HashMap<String, Robots>>,
}

impl Fetcher {
    pub fn new(catalog: Catalog, proxy: Option<String>) -> Self {
        Self {
            catalog,
            proxy,
            resolve_override: HashMap::new(),
            limiter: crate::ratelimit::Limiter::new(DEFAULT_PER_MINUTE, DEFAULT_BURST),
            robots: Mutex::new(HashMap::new()),
        }
    }

    /// The catalog and address checks for one URL; returns the address to pin.
    pub async fn admit(&self, raw: &str) -> Result<(Url, SocketAddr), Refusal> {
        let url = Url::parse(raw).map_err(|_| Refusal::BadUrl(raw.to_string()))?;
        if self.catalog.covering(&url).is_none() {
            return Err(Refusal::NotInCatalog(url.to_string()));
        }
        let addr = self.pin(&url).await?;
        Ok((url, addr))
    }

    async fn pin(&self, url: &Url) -> Result<SocketAddr, Refusal> {
        let host = url
            .host_str()
            .ok_or_else(|| Refusal::BadUrl(url.to_string()))?;
        let port = url.port_or_known_default().unwrap_or(443);
        let addrs: Vec<SocketAddr> = match self.resolve_override.get(host) {
            Some(a) => a.clone(),
            None => tokio::net::lookup_host((host, port))
                .await
                .map_err(|_| Refusal::Unresolvable(host.to_string()))?
                .collect(),
        };
        if addrs.is_empty() {
            return Err(Refusal::Unresolvable(host.to_string()));
        }
        // Every answer must be public: a mixed answer is how rebinding hides.
        for a in &addrs {
            if let Some(why) = ipguard::refusal(a.ip()) {
                return Err(Refusal::NonPublicAddress {
                    host: host.to_string(),
                    ip: a.ip().to_string(),
                    why,
                });
            }
        }
        Ok(addrs[0])
    }

    fn client(&self, url: &Url, addr: SocketAddr) -> Result<reqwest::Client, Refusal> {
        let mut b = reqwest::Client::builder()
            .redirect(reqwest::redirect::Policy::none())
            .timeout(TIMEOUT)
            .user_agent(format!("{}/{}", robots::AGENT, env!("CARGO_PKG_VERSION")))
            .referer(false)
            .https_only(true);
        match &self.proxy {
            Some(p) => {
                b = b.proxy(reqwest::Proxy::all(p).map_err(|e| Refusal::Upstream(e.to_string()))?)
            }
            None => {
                b = b
                    .no_proxy()
                    .resolve(url.host_str().unwrap_or_default(), addr)
            }
        }
        b.build().map_err(|e| Refusal::Upstream(e.to_string()))
    }

    async fn robots_for(&self, url: &Url, addr: SocketAddr) -> Robots {
        let origin = url.origin().ascii_serialization();
        if let Some(r) = self
            .robots
            .lock()
            .ok()
            .and_then(|m| m.get(&origin).cloned())
        {
            return r;
        }
        let r = match self.client(url, addr) {
            Ok(c) => match c.get(format!("{origin}/robots.txt")).send().await {
                Ok(resp) if resp.status().is_success() => {
                    Robots::parse(&resp.text().await.unwrap_or_default())
                }
                Ok(resp) if resp.status().is_client_error() => Robots::allow_all(),
                _ => Robots::disallow_all(),
            },
            Err(_) => Robots::disallow_all(),
        };
        if let Ok(mut m) = self.robots.lock() {
            m.insert(origin, r.clone());
        }
        r
    }

    /// Fetch `raw`, following redirects only into the catalog.
    pub async fn get(&self, raw: &str) -> Result<Fetched, Refusal> {
        let mut next = raw.to_string();
        for _ in 0..=MAX_REDIRECTS {
            let (url, addr) = self.admit(&next).await?;
            let mut path = url.path().to_string();
            if let Some(q) = url.query() {
                path = format!("{path}?{q}");
            }
            if !self.robots_for(&url, addr).await.allowed(&path) {
                return Err(Refusal::Robots(url.to_string()));
            }
            let resp = self
                .client(&url, addr)?
                .get(url.clone())
                .send()
                .await
                .map_err(|e| Refusal::Upstream(e.without_url().to_string()))?;
            if resp.status().is_redirection() {
                let loc = resp
                    .headers()
                    .get(reqwest::header::LOCATION)
                    .and_then(|v| v.to_str().ok())
                    .ok_or_else(|| Refusal::Upstream("redirect without Location".into()))?;
                next = url
                    .join(loc)
                    .map_err(|_| Refusal::BadUrl(loc.to_string()))?
                    .to_string();
                continue;
            }
            if !resp.status().is_success() {
                return Err(Refusal::Upstream(format!(
                    "HTTP {}",
                    resp.status().as_u16()
                )));
            }
            let ctype = resp
                .headers()
                .get(reqwest::header::CONTENT_TYPE)
                .and_then(|v| v.to_str().ok())
                .unwrap_or("text/html")
                .to_ascii_lowercase();
            if !is_text(&ctype) {
                return Err(Refusal::UnsupportedType(ctype));
            }
            if resp
                .content_length()
                .is_some_and(|n| n as usize > MAX_BYTES)
            {
                return Err(Refusal::TooLarge);
            }
            let mut resp = resp;
            let mut buf = Vec::new();
            while let Some(chunk) = resp
                .chunk()
                .await
                .map_err(|e| Refusal::Upstream(e.without_url().to_string()))?
            {
                buf.extend_from_slice(&chunk);
                if buf.len() > MAX_BYTES {
                    return Err(Refusal::TooLarge);
                }
            }
            return Ok(Fetched {
                final_url: url,
                content_type: ctype,
                body: String::from_utf8_lossy(&buf).into_owned(),
            });
        }
        Err(Refusal::TooManyRedirects)
    }
}

pub fn is_text(ctype: &str) -> bool {
    let base = ctype.split(';').next().unwrap_or("").trim();
    base.starts_with("text/")
        || base.ends_with("+xml")
        || matches!(
            base,
            "application/xml" | "application/json" | "application/xhtml+xml"
        )
}

#[cfg(test)]
mod tests {
    use super::*;

    fn fetcher() -> Fetcher {
        let cat = Catalog::parse(
            "version: 1\nsources:\n  - {name: d, kind: docs, url: 'https://docs.example.org/guide/', reason: r, provenance: p}\n",
        )
        .unwrap();
        Fetcher::new(cat, None)
    }

    fn with(f: &mut Fetcher, addrs: &[&str]) {
        f.resolve_override.insert(
            "docs.example.org".into(),
            addrs.iter().map(|a| a.parse().unwrap()).collect(),
        );
    }

    #[tokio::test]
    async fn refuses_off_catalog_before_resolving() {
        let f = fetcher();
        let e = f.admit("https://evil.example/guide/").await.unwrap_err();
        assert_eq!(e.kind(), "not-in-catalog");
        assert_eq!(f.admit("not a url").await.unwrap_err().kind(), "bad-url");
    }

    #[tokio::test]
    async fn refuses_a_catalog_host_resolving_inside() {
        for (addrs, why) in [
            (&["127.0.0.1:443"][..], "loopback"),
            (&["10.0.42.40:443"][..], "private"),
            (&["169.254.169.254:443"][..], "metadata"),
            // One public answer does not launder a private one.
            (&["93.184.216.34:443", "192.168.1.5:443"][..], "private"),
        ] {
            let mut f = fetcher();
            with(&mut f, addrs);
            match f.admit("https://docs.example.org/guide/a").await {
                Err(Refusal::NonPublicAddress { why: w, .. }) => assert_eq!(w, why),
                other => panic!("{addrs:?}: {other:?}"),
            }
        }
    }

    #[tokio::test]
    async fn pins_a_public_answer() {
        let mut f = fetcher();
        with(&mut f, &["93.184.216.34:443"]);
        let (u, a) = f.admit("https://docs.example.org/guide/a").await.unwrap();
        assert_eq!(u.path(), "/guide/a");
        assert_eq!(a.to_string(), "93.184.216.34:443");
    }

    #[test]
    fn text_types_only() {
        assert!(is_text("text/html; charset=utf-8"));
        assert!(is_text("application/atom+xml"));
        assert!(!is_text("application/octet-stream"));
        assert!(!is_text("image/png"));
    }
}
