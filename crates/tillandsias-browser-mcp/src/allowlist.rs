//! URL allowlist enforcement for `browser.open`.
//!
//! @trace spec:host-browser-mcp, spec:opencode-web-session-otp
//! @cheatsheet web/http.md

use std::collections::HashSet;
use std::fmt;
use url::{Host, Url};

const OBSERVATORIUM_HOST: &str = "observatorium.tillandsias.localhost";

/// Parsed and validated browser URL.
#[derive(Debug, Clone)]
pub struct AllowedUrl {
    pub url: Url,
    pub host: String,
    pub project_label: String,
    pub service_label: String,
}

/// Defense-in-depth allowlist for browser navigation.
/// Validates URLs against active `.localhost` routes from the window registry.
/// @trace spec:host-browser-mcp
pub struct BrowserAllowlist {
    /// Set of active routes in format `<service>.<project>.localhost:8080`
    active_routes: HashSet<String>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum AllowlistDeny {
    InvalidUrl(String),
    UnsupportedScheme(String),
    MissingHost,
    IpLiteral,
    BareLocalhost,
    UserInfo,
    WrongPort { expected: u16, actual: Option<u16> },
    ProjectMismatch { expected: String, actual: String },
    OpencodeSelf,
    HostShape,
}

impl fmt::Display for AllowlistDeny {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            AllowlistDeny::InvalidUrl(reason) => write!(f, "invalid-url: {reason}"),
            AllowlistDeny::UnsupportedScheme(scheme) => {
                write!(f, "unsupported scheme: {scheme}")
            }
            AllowlistDeny::MissingHost => write!(f, "missing host"),
            AllowlistDeny::IpLiteral => write!(f, "host must not be an IP literal"),
            AllowlistDeny::BareLocalhost => write!(f, "bare localhost is not allowed"),
            AllowlistDeny::UserInfo => write!(f, "userinfo is not allowed"),
            AllowlistDeny::WrongPort { expected, actual } => {
                write!(f, "port must be {expected} (got {actual:?})")
            }
            AllowlistDeny::ProjectMismatch { expected, actual } => {
                write!(
                    f,
                    "project suffix mismatch: expected {expected}, got {actual}"
                )
            }
            AllowlistDeny::OpencodeSelf => write!(f, "opencode-self host is not allowed"),
            AllowlistDeny::HostShape => write!(f, "host must be <service>.<project>.localhost"),
        }
    }
}

impl std::error::Error for AllowlistDeny {}

impl BrowserAllowlist {
    /// Create a new allowlist from active window routes.
    /// Expects window metadata with URL and project information.
    /// @trace spec:host-browser-mcp
    pub fn new(active_hosts: &[String]) -> Self {
        Self {
            active_routes: active_hosts.iter().cloned().collect(),
        }
    }

    /// Create an empty allowlist (no routes allowed).
    pub fn empty() -> Self {
        Self {
            active_routes: HashSet::new(),
        }
    }

    /// Check if a URL is allowed by the active routes.
    ///
    /// Allows:
    /// - `http://*.localhost:8080/` (any service under any active project)
    /// - `https://*.localhost:8080/` (HTTPS variant)
    /// - `http://127.0.0.1:8080/` and `https://127.0.0.1:8080/` (localhost testing)
    /// - If active_routes is empty, allow any properly formatted `.localhost:8080` URL
    ///   (defense-in-depth at app layer; network layer validates via router)
    ///
    /// Denies:
    /// - Any external domains
    /// - `opencode.*` (prevents recursive OpenCode Web launch)
    /// - Non-standard ports
    ///
    /// @trace spec:host-browser-mcp
    pub fn is_allowed(&self, url: &str) -> bool {
        let parsed = match Url::parse(url) {
            Ok(u) => u,
            Err(_) => return false,
        };

        // Only allow http and https schemes
        if !matches!(parsed.scheme(), "http" | "https") {
            return false;
        }

        let host_str = match parsed.host_str() {
            Some(h) => h,
            None => return false,
        };

        if host_str == OBSERVATORIUM_HOST {
            return matches!(parsed.scheme(), "https")
                && parsed.username().is_empty()
                && parsed.password().is_none()
                && parsed.port().is_none_or(|port| port == 443);
        }

        let port = parsed.port().unwrap_or(match parsed.scheme() {
            "https" => 443,
            _ => 80,
        });

        // Allow 127.0.0.1 and [::1] for localhost testing (even without active routes)
        if (host_str == "127.0.0.1" || host_str == "[::1]" || host_str == "::1")
            && (port == 8080 || port == 80)
        {
            return true;
        }

        // Must be localhost TLD
        if !host_str.ends_with(".localhost") {
            return false;
        }

        // Prevent recursive OpenCode Web launch (always blocked, regardless of active routes)
        if host_str.starts_with("opencode.") {
            return false;
        }

        // Port must be 8080 (or 80 for HTTPS variants on RFC 6761 loopback)
        if port != 8080 && port != 80 {
            return false;
        }

        // If there are active routes, check if this host is in them
        // If no active routes are registered yet (first-use scenario), allow any properly
        // formatted .localhost:8080 URL. The reverse-proxy validates at the network layer.
        if !self.active_routes.is_empty() {
            let route_key = if port == 8080 {
                format!("{}:8080", host_str)
            } else {
                format!("{}:80", host_str)
            };
            return self.active_routes.contains(&route_key);
        }

        // No active routes registered yet: allow properly formatted localhost URLs
        // Network-layer validation via reverse-proxy will reject actual requests
        // to non-existent routes
        true
    }
}

fn split_host_labels(host: &str) -> Vec<&str> {
    host.split('.').collect()
}

/// Validate a browser-open URL against the host-browser allowlist rules.
pub fn validate(url: &str, project_label: &str) -> Result<AllowedUrl, AllowlistDeny> {
    let parsed = Url::parse(url).map_err(|err| AllowlistDeny::InvalidUrl(err.to_string()))?;

    match parsed.scheme() {
        "http" | "https" => {}
        other => return Err(AllowlistDeny::UnsupportedScheme(other.to_string())),
    }

    if !parsed.username().is_empty() || parsed.password().is_some() {
        return Err(AllowlistDeny::UserInfo);
    }

    let host = parsed
        .host_str()
        .ok_or(AllowlistDeny::MissingHost)?
        .to_string();

    if host == OBSERVATORIUM_HOST {
        if parsed.scheme() != "https" {
            return Err(AllowlistDeny::UnsupportedScheme(
                parsed.scheme().to_string(),
            ));
        }
        if parsed.port().is_some_and(|port| port != 443) {
            return Err(AllowlistDeny::WrongPort {
                expected: 443,
                actual: parsed.port(),
            });
        }

        return Ok(AllowedUrl {
            url: parsed,
            host,
            project_label: project_label.to_string(),
            service_label: "observatorium".to_string(),
        });
    }

    if parsed.port() != Some(8080) {
        return Err(AllowlistDeny::WrongPort {
            expected: 8080,
            actual: parsed.port(),
        });
    }

    match parsed.host() {
        Some(Host::Ipv4(_)) | Some(Host::Ipv6(_)) => return Err(AllowlistDeny::IpLiteral),
        None => return Err(AllowlistDeny::MissingHost),
        Some(Host::Domain(_)) => {}
    }

    if host == "localhost" || host.ends_with(".localhost") && !host.contains('.') {
        return Err(AllowlistDeny::BareLocalhost);
    }

    let labels = split_host_labels(&host);
    if labels.len() != 3 || labels[2] != "localhost" {
        return Err(AllowlistDeny::HostShape);
    }

    let service_label = labels[0].to_string();
    let host_project_label = labels[1].to_string();
    if host_project_label != project_label {
        return Err(AllowlistDeny::ProjectMismatch {
            expected: project_label.to_string(),
            actual: host_project_label,
        });
    }

    if service_label == "opencode" {
        return Err(AllowlistDeny::OpencodeSelf);
    }

    Ok(AllowedUrl {
        url: parsed,
        host,
        project_label: project_label.to_string(),
        service_label,
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    // Tests for the basic validate() function (format validation only)

    #[test]
    fn accepts_project_localhost_url() {
        let allowed = validate("http://web.acme.localhost:8080/foo?q=1", "acme").unwrap();
        assert_eq!(allowed.host, "web.acme.localhost");
        assert_eq!(allowed.service_label, "web");
    }

    #[test]
    fn rejects_opencode_self() {
        let err = validate("http://opencode.acme.localhost:8080/", "acme").unwrap_err();
        assert!(matches!(err, AllowlistDeny::OpencodeSelf));
    }

    #[test]
    fn rejects_ip_literal() {
        let err = validate("http://127.0.0.1:8080/", "acme").unwrap_err();
        assert!(matches!(err, AllowlistDeny::IpLiteral));
    }

    // Tests for BrowserAllowlist (enforcement against active routes)

    #[test]
    fn allowlist_allows_active_localhost_routes() {
        let mut routes = vec![];
        routes.push("web.acme.localhost:8080".to_string());
        routes.push("api.acme.localhost:8080".to_string());
        routes.push("ui.beta.localhost:8080".to_string());

        let allowlist = BrowserAllowlist::new(&routes);

        // Exact match should be allowed
        assert!(allowlist.is_allowed("http://web.acme.localhost:8080/"));
        assert!(allowlist.is_allowed("http://api.acme.localhost:8080/path"));
        assert!(allowlist.is_allowed("http://ui.beta.localhost:8080/?query=value"));

        // HTTPS variant should be allowed
        assert!(allowlist.is_allowed("https://web.acme.localhost:8080/"));
    }

    #[test]
    fn allowlist_blocks_external_domains() {
        let routes = vec!["web.acme.localhost:8080".to_string()];
        let allowlist = BrowserAllowlist::new(&routes);

        // External domains must be blocked
        assert!(!allowlist.is_allowed("http://google.com/"));
        assert!(!allowlist.is_allowed("https://github.com/"));
        assert!(!allowlist.is_allowed("http://example.com/"));
    }

    #[test]
    fn allowlist_blocks_opencode_recursive_launch() {
        let routes = vec!["opencode.acme.localhost:8080".to_string()];
        let allowlist = BrowserAllowlist::new(&routes);

        // Even if opencode is in routes, it's blocked to prevent recursive launches
        assert!(!allowlist.is_allowed("http://opencode.acme.localhost:8080/"));
        assert!(!allowlist.is_allowed("http://opencode.beta.localhost:8080/"));
    }

    #[test]
    fn allowlist_blocks_non_standard_ports() {
        let routes = vec!["web.acme.localhost:8080".to_string()];
        let allowlist = BrowserAllowlist::new(&routes);

        // Non-standard ports should be blocked
        assert!(!allowlist.is_allowed("http://web.acme.localhost:3000/"));
        assert!(!allowlist.is_allowed("http://web.acme.localhost:9000/"));
        assert!(!allowlist.is_allowed("http://web.acme.localhost:5000/"));
    }

    #[test]
    fn allowlist_blocks_non_localhost_tld() {
        let routes = vec!["web.acme.localhost:8080".to_string()];
        let allowlist = BrowserAllowlist::new(&routes);

        // Must end in .localhost, not other TLDs
        assert!(!allowlist.is_allowed("http://web.acme.local:8080/"));
        assert!(!allowlist.is_allowed("http://web.acme.test:8080/"));
    }

    #[test]
    fn allowlist_allows_localhost_ip_for_testing() {
        let allowlist = BrowserAllowlist::empty();

        // 127.0.0.1 should be allowed even without active routes
        assert!(allowlist.is_allowed("http://127.0.0.1:8080/"));
        assert!(allowlist.is_allowed("http://127.0.0.1:80/"));
        assert!(allowlist.is_allowed("https://127.0.0.1:8080/"));
    }

    #[test]
    fn allowlist_allows_ipv6_loopback_for_testing() {
        let allowlist = BrowserAllowlist::empty();

        // IPv6 loopback should be allowed
        assert!(allowlist.is_allowed("http://[::1]:8080/"));
        assert!(allowlist.is_allowed("http://[::1]:80/"));
        assert!(allowlist.is_allowed("https://[::1]:8080/"));
    }

    #[test]
    fn allowlist_allows_canonical_observatorium_host() {
        let allowlist = BrowserAllowlist::empty();

        assert!(allowlist.is_allowed("https://observatorium.tillandsias.localhost"));
        assert!(allowlist.is_allowed("https://observatorium.tillandsias.localhost/"));
    }

    #[test]
    fn allowlist_blocks_ipv4_non_loopback() {
        let allowlist = BrowserAllowlist::empty();

        // Non-loopback IPs must be blocked
        assert!(!allowlist.is_allowed("http://192.168.1.1:8080/"));
        assert!(!allowlist.is_allowed("http://10.0.0.1:8080/"));
    }

    #[test]
    fn allowlist_blocks_invalid_urls() {
        let allowlist = BrowserAllowlist::empty();

        // Malformed URLs must be blocked
        assert!(!allowlist.is_allowed("not a url"));
        assert!(!allowlist.is_allowed("http://"));
        assert!(!allowlist.is_allowed(""));
    }

    #[test]
    fn allowlist_blocks_unsupported_schemes() {
        let routes = vec!["web.acme.localhost:8080".to_string()];
        let allowlist = BrowserAllowlist::new(&routes);

        // Only http and https allowed
        assert!(!allowlist.is_allowed("ftp://web.acme.localhost:8080/"));
        assert!(!allowlist.is_allowed("file:///etc/passwd"));
        assert!(!allowlist.is_allowed("javascript:alert('xss')"));
    }

    #[test]
    fn allowlist_respects_project_isolation() {
        let routes = vec!["web.acme.localhost:8080".to_string()];
        let allowlist = BrowserAllowlist::new(&routes);

        // Different project should be blocked
        assert!(!allowlist.is_allowed("http://web.beta.localhost:8080/"));
        assert!(!allowlist.is_allowed("http://api.gamma.localhost:8080/"));
    }

    #[test]
    fn allowlist_allows_multiple_services_same_project() {
        let routes = vec![
            "opencode.java.localhost:8080".to_string(),
            "flutter.java.localhost:8080".to_string(),
            "vite.java.localhost:8080".to_string(),
        ];
        let allowlist = BrowserAllowlist::new(&routes);

        // All services under project should be allowed (except opencode)
        assert!(allowlist.is_allowed("http://flutter.java.localhost:8080/"));
        assert!(allowlist.is_allowed("http://vite.java.localhost:8080/"));

        // Opencode is still blocked (recursive launch prevention)
        assert!(!allowlist.is_allowed("http://opencode.java.localhost:8080/"));
    }

    #[test]
    fn allowlist_empty_allows_all_properly_formatted_localhost_routes() {
        let allowlist = BrowserAllowlist::empty();

        // Empty allowlist (first-use scenario) should allow any properly formatted localhost URLs
        // Network-layer validation via reverse-proxy will reject requests to non-existent routes
        assert!(allowlist.is_allowed("http://web.acme.localhost:8080/"));
        assert!(allowlist.is_allowed("http://api.beta.localhost:8080/"));

        // Allow loopback IPs for testing
        assert!(allowlist.is_allowed("http://127.0.0.1:8080/"));

        // But still block recursive opencode launches
        assert!(!allowlist.is_allowed("http://opencode.localhost:8080/"));
    }

    #[test]
    fn validate_allows_canonical_observatorium_host() {
        let allowed = validate("https://observatorium.tillandsias.localhost", "acme").unwrap();
        assert_eq!(allowed.host, OBSERVATORIUM_HOST);
        assert_eq!(allowed.service_label, "observatorium");
    }
}
