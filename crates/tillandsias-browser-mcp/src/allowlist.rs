//! URL allowlist enforcement for `browser.open`.
//!
//! @trace spec:host-browser-mcp, spec:opencode-web-session-otp
//! @cheatsheet web/http.md

use std::fmt;
use url::{Host, Url};

/// Parsed and validated browser URL.
#[derive(Debug, Clone)]
pub struct AllowedUrl {
    pub url: Url,
    pub host: String,
    pub project_label: String,
    pub service_label: String,
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
                write!(f, "project suffix mismatch: expected {expected}, got {actual}")
            }
            AllowlistDeny::OpencodeSelf => write!(f, "opencode-self host is not allowed"),
            AllowlistDeny::HostShape => write!(f, "host must be <service>.<project>.localhost"),
        }
    }
}

impl std::error::Error for AllowlistDeny {}

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

    if parsed.port() != Some(8080) {
        return Err(AllowlistDeny::WrongPort {
            expected: 8080,
            actual: parsed.port(),
        });
    }

    let host = parsed
        .host_str()
        .ok_or(AllowlistDeny::MissingHost)?
        .to_string();

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
}
