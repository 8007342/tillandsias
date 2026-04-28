//! URL allowlist enforcement for browser.open.
//!
//! Validates URLs against six rules:
//! 1. Scheme must be http (not https, ftp, etc.)
//! 2. Host must not be an IP literal
//! 3. Host must end with `.<project>.localhost`
//! 4. Leftmost label must not be `opencode`
//! 5. Port must be 8080
//! 6. No userinfo (username:password)
//!
//! @trace spec:host-browser-mcp, spec:opencode-web-session
//! @cheatsheet web/http.md

use url::Url;

#[derive(Debug, Clone)]
pub enum AllowlistDenyReason {
    InvalidScheme,
    IpLiteral,
    WrongTLD,
    MissingProjectSuffix,
    OpencodeLabelDenied,
    WrongPort,
    HasUserinfo,
    ParseError,
}

impl std::fmt::Display for AllowlistDenyReason {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            AllowlistDenyReason::InvalidScheme => write!(f, "scheme must be http"),
            AllowlistDenyReason::IpLiteral => write!(f, "IP literals not allowed"),
            AllowlistDenyReason::WrongTLD => write!(f, "must use .localhost TLD"),
            AllowlistDenyReason::MissingProjectSuffix => {
                write!(f, "host must match <service>.<project>.localhost")
            }
            AllowlistDenyReason::OpencodeLabelDenied => {
                write!(f, "opencode.* URLs are not allowed (agent's own UI)")
            }
            AllowlistDenyReason::WrongPort => write!(f, "port must be 8080"),
            AllowlistDenyReason::HasUserinfo => write!(f, "no userinfo allowed"),
            AllowlistDenyReason::ParseError => write!(f, "URL parse error"),
        }
    }
}

/// Validate a URL against the allowlist.
///
/// Returns the parsed URL if allowed, or a DenyReason if rejected.
pub fn validate(url: &str, project: &str) -> Result<Url, AllowlistDenyReason> {
    let parsed = Url::parse(url).map_err(|_| AllowlistDenyReason::ParseError)?;

    // Rule 1: Scheme must be http
    if parsed.scheme() != "http" {
        return Err(AllowlistDenyReason::InvalidScheme);
    }

    // Rule 6: No userinfo
    if parsed.username() != "" || parsed.password().is_some() {
        return Err(AllowlistDenyReason::HasUserinfo);
    }

    let host_str = parsed
        .host_str()
        .ok_or(AllowlistDenyReason::ParseError)?;

    // Rule 2: Not an IP literal
    if host_str.parse::<std::net::IpAddr>().is_ok() {
        return Err(AllowlistDenyReason::IpLiteral);
    }

    // Rule 3 & 5: Must be `*.*.localhost` on port 8080
    if !host_str.ends_with(".localhost") {
        return Err(AllowlistDenyReason::WrongTLD);
    }

    if parsed.port() != Some(8080) {
        return Err(AllowlistDenyReason::WrongPort);
    }

    // Rule 3: Host must end with `.<project>.localhost`
    let required_suffix = format!(".{}.localhost", project);
    if !host_str.ends_with(&required_suffix) {
        return Err(AllowlistDenyReason::MissingProjectSuffix);
    }

    // Rule 4: Leftmost label must not be `opencode`
    let labels: Vec<&str> = host_str.split('.').collect();
    if !labels.is_empty() && labels[0] == "opencode" {
        return Err(AllowlistDenyReason::OpencodeLabelDenied);
    }

    Ok(parsed)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn allow_simple_web_service() {
        // web.<project>.localhost:8080 should succeed
        let result = validate("http://web.my-project.localhost:8080/", "my-project");
        assert!(result.is_ok());
    }

    #[test]
    fn allow_api_service() {
        // api.<project>.localhost:8080 should succeed
        let result = validate("http://api.my-project.localhost:8080/foo?q=1", "my-project");
        assert!(result.is_ok());
    }

    #[test]
    fn deny_opencode_label() {
        // opencode.<project>.localhost is explicitly denied
        let result =
            validate("http://opencode.my-project.localhost:8080/", "my-project");
        assert!(matches!(result, Err(AllowlistDenyReason::OpencodeLabelDenied)));
    }

    #[test]
    fn deny_https() {
        let result = validate("https://web.my-project.localhost:8080/", "my-project");
        assert!(matches!(result, Err(AllowlistDenyReason::InvalidScheme)));
    }

    #[test]
    fn deny_ip_literal() {
        let result = validate("http://127.0.0.1:8080/", "my-project");
        assert!(matches!(result, Err(AllowlistDenyReason::IpLiteral)));
    }

    #[test]
    fn deny_wrong_port() {
        let result = validate("http://web.my-project.localhost:9000/", "my-project");
        assert!(matches!(result, Err(AllowlistDenyReason::WrongPort)));
    }

    #[test]
    fn deny_wrong_project() {
        let result = validate("http://web.other-project.localhost:8080/", "my-project");
        assert!(matches!(result, Err(AllowlistDenyReason::MissingProjectSuffix)));
    }

    #[test]
    fn deny_wrong_tld() {
        let result = validate("http://web.my-project.example.com:8080/", "my-project");
        assert!(matches!(result, Err(AllowlistDenyReason::WrongTLD)));
    }

    #[test]
    fn deny_userinfo() {
        let result = validate("http://user:pass@web.my-project.localhost:8080/", "my-project");
        assert!(matches!(result, Err(AllowlistDenyReason::HasUserinfo)));
    }

    #[test]
    fn allow_multiple_labels() {
        // <service>.<sub>.<project>.localhost is okay as long as leftmost isn't opencode
        let result = validate("http://foo.bar.my-project.localhost:8080/", "my-project");
        assert!(result.is_ok());
    }
}
