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
    let result = tokio::time::timeout(PROBE_TIMEOUT, probe_inner()).await;
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

async fn probe_inner() -> CredentialHealth {
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

    // Step 2 — HTTP probe to api.github.com/user.
    let client = match reqwest::Client::builder()
        .timeout(PROBE_TIMEOUT)
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

    let response = client
        .get("https://api.github.com/user")
        .header("Accept", "application/vnd.github+json")
        .header("X-GitHub-Api-Version", "2022-11-28")
        .bearer_auth(&token)
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
}
