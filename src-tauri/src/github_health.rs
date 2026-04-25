//! GitHub credential health classifier.
//!
//! Distinguishes "GitHub is down" from "user is not authenticated" so the
//! tray UI can pick the right next action: keep working from cached state
//! vs. surface a sign-in flow.
//!
//! Returns one of four classifications, each maps to a tray menu stage in
//! `simplified-tray-ux`:
//!
//! - `Authenticated`        — token present, GitHub returned 200 → `Authed`
//! - `CredentialMissing`    — no token in OS keyring → `NoAuth`
//! - `CredentialInvalid`    — 401/403 from GitHub → `NoAuth`
//! - `GithubUnreachable`    — DNS/timeout/5xx/transient → `NetIssue`
//!
//! @trace spec:simplified-tray-ux

use std::time::Duration;

use tracing::{debug, info, warn};

/// Result of a single credential health probe.
///
/// @trace spec:simplified-tray-ux
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum CredentialHealth {
    /// Token present, GitHub returned 200 with a user payload.
    Authenticated,
    /// No token in the keyring. User has never signed in (or signed out).
    CredentialMissing,
    /// Token present but GitHub rejected it (401/403).
    CredentialInvalid,
    /// Network or transient server error — token may be valid, we just
    /// can't tell right now. `reason` carries a short description for
    /// logging / telemetry.
    GithubUnreachable { reason: String },
}

impl std::fmt::Display for CredentialHealth {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            CredentialHealth::Authenticated => write!(f, "authenticated"),
            CredentialHealth::CredentialMissing => write!(f, "credential-missing"),
            CredentialHealth::CredentialInvalid => write!(f, "credential-invalid"),
            CredentialHealth::GithubUnreachable { reason } => write!(f, "unreachable ({reason})"),
        }
    }
}

/// Total budget for a single probe — keyring read + HTTP round-trip.
///
/// On a 10s timeout the result is `GithubUnreachable`, never
/// `CredentialInvalid`. The tray must not fail closed on a slow probe.
const PROBE_TIMEOUT: Duration = Duration::from_secs(10);

/// Run the full credential health probe.
///
/// Steps:
/// 1. Read the token from the OS keyring (synchronous — `keyring` is sync,
///    fast, in-process).
/// 2. If absent → `CredentialMissing`.
/// 3. If present → `GET https://api.github.com/user` with the token in
///    `Authorization: token <...>`, capped at `PROBE_TIMEOUT`.
/// 4. Classify the response per the matrix in the spec.
///
/// Never panics. Never returns `CredentialInvalid` on a timeout — that
/// would force a confusing "your token is bad" prompt during a flaky
/// network. Timeouts are always `GithubUnreachable`.
///
/// @trace spec:simplified-tray-ux
#[allow(dead_code)] // Wired in by the TrayMenu refactor — see spec phase 6.
pub async fn probe() -> CredentialHealth {
    let result =
        tokio::time::timeout(PROBE_TIMEOUT, probe_inner("https://api.github.com")).await;
    match result {
        Ok(health) => {
            info!(
                accountability = true,
                category = "secrets",
                spec = "simplified-tray-ux",
                health = %health,
                "GitHub credential health probe complete"
            );
            health
        }
        Err(_elapsed) => {
            let reason = format!("probe exceeded {}s budget", PROBE_TIMEOUT.as_secs());
            warn!(
                spec = "simplified-tray-ux",
                "GitHub credential probe timed out after {}s — classifying as GithubUnreachable",
                PROBE_TIMEOUT.as_secs()
            );
            CredentialHealth::GithubUnreachable { reason }
        }
    }
}

async fn probe_inner(base_url: &str) -> CredentialHealth {
    // Step 1 — token from keyring.
    let token = match tokio::task::spawn_blocking(crate::secrets::retrieve_github_token)
        .await
    {
        Ok(Ok(Some(t))) if !t.trim().is_empty() => t,
        Ok(Ok(_)) => {
            debug!(spec = "simplified-tray-ux", "No GitHub token in keyring → CredentialMissing");
            return CredentialHealth::CredentialMissing;
        }
        Ok(Err(e)) => {
            // Keyring unavailable (D-Bus down, Secret Service crashed, etc).
            // Treat as Unreachable — we don't know if a token would have
            // worked. Prevents the tray from forcing a sign-in dance just
            // because the user's keyring daemon is restarting.
            warn!(
                spec = "simplified-tray-ux",
                error = %e,
                "Keyring read failed — classifying as GithubUnreachable"
            );
            return CredentialHealth::GithubUnreachable {
                reason: format!("keyring unavailable: {e}"),
            };
        }
        Err(join_err) => {
            warn!(spec = "simplified-tray-ux", error = %join_err, "Keyring spawn_blocking panicked");
            return CredentialHealth::GithubUnreachable {
                reason: format!("keyring task panicked: {join_err}"),
            };
        }
    };

    // Step 2 — HTTP probe to <base_url>/user.
    probe_with_token(base_url, &token, PROBE_TIMEOUT).await
}

/// HTTP-only probe — token already in hand, keyring already consulted.
///
/// Split out from `probe_inner` so unit tests can drive it against a
/// `wiremock` server without going through the OS keyring. Production code
/// always reaches this through `probe_inner` → `probe`. `http_timeout`
/// controls the per-request reqwest timeout; production uses
/// `PROBE_TIMEOUT`, tests use a short value to exercise the timeout branch
/// quickly.
///
/// @trace spec:simplified-tray-ux
async fn probe_with_token(
    base_url: &str,
    token: &str,
    http_timeout: Duration,
) -> CredentialHealth {
    let client = match reqwest::Client::builder()
        .timeout(http_timeout)
        .user_agent(concat!(
            "tillandsias/",
            env!("CARGO_PKG_VERSION"),
            " credential-health-probe"
        ))
        .build()
    {
        Ok(c) => c,
        Err(e) => {
            return CredentialHealth::GithubUnreachable {
                reason: format!("HTTP client build failed: {e}"),
            };
        }
    };

    let url = format!("{}/user", base_url.trim_end_matches('/'));
    let response = client
        .get(&url)
        .header("Accept", "application/vnd.github+json")
        .header("X-GitHub-Api-Version", "2022-11-28")
        .bearer_auth(token)
        .send()
        .await;

    match response {
        Ok(resp) => match resp.status().as_u16() {
            200..=299 => CredentialHealth::Authenticated,
            401 | 403 => CredentialHealth::CredentialInvalid,
            // 5xx, 429, 408, etc. — server-side, retryable.
            other if (500..=599).contains(&other) || other == 429 || other == 408 => {
                CredentialHealth::GithubUnreachable {
                    reason: format!("HTTP {other}"),
                }
            }
            // Any other 4xx — treat as unreachable rather than "invalid"
            // because the user's token may be fine; some API quirk is
            // misclassified.
            other => CredentialHealth::GithubUnreachable {
                reason: format!("unexpected HTTP {other}"),
            },
        },
        Err(e) if e.is_timeout() => CredentialHealth::GithubUnreachable {
            reason: "HTTP timeout".to_string(),
        },
        Err(e) if e.is_connect() => CredentialHealth::GithubUnreachable {
            reason: format!("connection refused: {e}"),
        },
        Err(e) => CredentialHealth::GithubUnreachable {
            reason: format!("transport error: {e}"),
        },
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use wiremock::matchers::{method, path};
    use wiremock::{Mock, MockServer, ResponseTemplate};

    /// Default HTTP timeout for the four "got an HTTP response" scenarios.
    /// Long enough that wiremock's near-instant responses never race the
    /// timeout, short enough that a misconfigured test fails fast.
    const FAST_TIMEOUT: Duration = Duration::from_secs(2);

    /// Install the rustls `ring` crypto provider exactly once for the test
    /// process. Mirrors what `update_cli::run()` does in production —
    /// reqwest is built with `rustls-no-provider`, so something has to
    /// install one before the first HTTPS / rustls usage. Tests don't go
    /// through Tauri setup, so this fills the gap.
    fn ensure_crypto_provider() {
        use std::sync::Once;
        static INIT: Once = Once::new();
        INIT.call_once(|| {
            let _ = rustls::crypto::ring::default_provider().install_default();
        });
    }

    /// Stand up a wiremock server returning `status` for `GET /user`.
    /// The base URL it returns has no trailing `/user` — `probe_with_token`
    /// appends that itself, matching the production GitHub URL shape.
    async fn mock_user_endpoint(status: u16) -> MockServer {
        let server = MockServer::start().await;
        Mock::given(method("GET"))
            .and(path("/user"))
            .respond_with(ResponseTemplate::new(status))
            .mount(&server)
            .await;
        server
    }

    #[test]
    fn display_format() {
        assert_eq!(CredentialHealth::Authenticated.to_string(), "authenticated");
        assert_eq!(
            CredentialHealth::CredentialMissing.to_string(),
            "credential-missing"
        );
        assert_eq!(
            CredentialHealth::CredentialInvalid.to_string(),
            "credential-invalid"
        );
        assert_eq!(
            CredentialHealth::GithubUnreachable {
                reason: "DNS failure".to_string()
            }
            .to_string(),
            "unreachable (DNS failure)"
        );
    }

    #[test]
    fn classifications_are_distinct() {
        let states = [
            CredentialHealth::Authenticated,
            CredentialHealth::CredentialMissing,
            CredentialHealth::CredentialInvalid,
            CredentialHealth::GithubUnreachable {
                reason: "x".to_string(),
            },
        ];
        // No two are equal.
        for i in 0..states.len() {
            for j in i + 1..states.len() {
                assert_ne!(states[i], states[j]);
            }
        }
    }

    /// HTTP 200 with a valid token classifies as `Authenticated`.
    /// @trace spec:simplified-tray-ux
    #[tokio::test]
    async fn http_200_classifies_as_authenticated() {
        ensure_crypto_provider();
        let server = mock_user_endpoint(200).await;
        let result = probe_with_token(&server.uri(), "ghp_valid_token", FAST_TIMEOUT).await;
        assert_eq!(result, CredentialHealth::Authenticated);
    }

    /// HTTP 401 (bad credentials) classifies as `CredentialInvalid` so the
    /// tray surfaces a sign-in flow rather than a network warning.
    /// @trace spec:simplified-tray-ux
    #[tokio::test]
    async fn http_401_classifies_as_credential_invalid() {
        ensure_crypto_provider();
        let server = mock_user_endpoint(401).await;
        let result = probe_with_token(&server.uri(), "ghp_revoked_token", FAST_TIMEOUT).await;
        assert_eq!(result, CredentialHealth::CredentialInvalid);
    }

    /// HTTP 403 (forbidden / token lacks scopes) is also `CredentialInvalid`
    /// — the user must intervene with a new token.
    /// @trace spec:simplified-tray-ux
    #[tokio::test]
    async fn http_403_classifies_as_credential_invalid() {
        ensure_crypto_provider();
        let server = mock_user_endpoint(403).await;
        let result =
            probe_with_token(&server.uri(), "ghp_underscoped_token", FAST_TIMEOUT).await;
        assert_eq!(result, CredentialHealth::CredentialInvalid);
    }

    /// HTTP 500 (GitHub server error) classifies as `GithubUnreachable` —
    /// the token may still be valid, we just can't tell. Tray should keep
    /// working from cached state.
    /// @trace spec:simplified-tray-ux
    #[tokio::test]
    async fn http_500_classifies_as_unreachable() {
        ensure_crypto_provider();
        let server = mock_user_endpoint(500).await;
        let result = probe_with_token(&server.uri(), "ghp_some_token", FAST_TIMEOUT).await;
        match result {
            CredentialHealth::GithubUnreachable { reason } => {
                assert!(
                    reason.contains("500"),
                    "expected reason to mention 500, got: {reason}"
                );
            }
            other => panic!("expected GithubUnreachable for HTTP 500, got: {other:?}"),
        }
    }

    /// HTTP 429 (rate limited) classifies as `GithubUnreachable` — retry
    /// after the rate-limit window, don't pester the user about credentials.
    /// @trace spec:simplified-tray-ux
    #[tokio::test]
    async fn http_429_classifies_as_unreachable() {
        ensure_crypto_provider();
        let server = mock_user_endpoint(429).await;
        let result = probe_with_token(&server.uri(), "ghp_some_token", FAST_TIMEOUT).await;
        match result {
            CredentialHealth::GithubUnreachable { reason } => {
                assert!(
                    reason.contains("429"),
                    "expected reason to mention 429, got: {reason}"
                );
            }
            other => panic!("expected GithubUnreachable for HTTP 429, got: {other:?}"),
        }
    }

    /// Connection refused (nothing listening on the target port) classifies
    /// as `GithubUnreachable`. We grab a free port, drop the listener so the
    /// OS knows the port is closed, then point the probe at it.
    /// @trace spec:simplified-tray-ux
    #[tokio::test]
    async fn connection_refused_classifies_as_unreachable() {
        ensure_crypto_provider();
        // Bind to an ephemeral port, capture it, then immediately drop the
        // listener — the port goes back to the kernel, connections to it
        // get RST'd → reqwest sees a connect error.
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let addr = listener.local_addr().unwrap();
        drop(listener);

        let base_url = format!("http://{addr}");
        let result = probe_with_token(&base_url, "ghp_some_token", FAST_TIMEOUT).await;
        match result {
            CredentialHealth::GithubUnreachable { reason } => {
                // reqwest reports the underlying transport error. Either the
                // is_connect() branch ("connection refused") or the generic
                // transport branch can fire depending on platform — both are
                // valid Unreachable classifications. Just sanity-check the
                // result isn't accidentally Authenticated/CredentialInvalid.
                assert!(
                    !reason.is_empty(),
                    "expected non-empty unreachable reason"
                );
            }
            other => panic!("expected GithubUnreachable for refused conn, got: {other:?}"),
        }
    }

    /// A response that takes longer than the per-request HTTP timeout
    /// classifies as `GithubUnreachable` via the timeout branch — never as
    /// `CredentialInvalid`. The tray must not fail closed on a flaky
    /// network. We use a short `http_timeout` (200ms) and a wiremock delay
    /// well past it (2s) to exercise the path without making the test slow.
    /// @trace spec:simplified-tray-ux
    #[tokio::test]
    async fn slow_response_classifies_as_unreachable_via_timeout() {
        ensure_crypto_provider();
        let server = MockServer::start().await;
        Mock::given(method("GET"))
            .and(path("/user"))
            .respond_with(
                ResponseTemplate::new(200).set_delay(Duration::from_secs(2)),
            )
            .mount(&server)
            .await;

        let short_timeout = Duration::from_millis(200);
        let result = probe_with_token(&server.uri(), "ghp_some_token", short_timeout).await;
        match result {
            CredentialHealth::GithubUnreachable { reason } => {
                assert!(
                    reason.to_lowercase().contains("timeout"),
                    "expected reason to mention timeout, got: {reason}"
                );
            }
            other => panic!("expected GithubUnreachable for slow response, got: {other:?}"),
        }
    }
}
