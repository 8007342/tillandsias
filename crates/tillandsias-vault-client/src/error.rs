//! Error taxonomy for the Vault client.
//!
//! @trace spec:tillandsias-vault
//! @cheatsheet runtime/hashicorp-vault-tillandsias.md
// freshness: auditor=linux-macuahuitl-fable5-20260816t0552z date=2026-08-16 verdict=refreshed scope=re-validated against lib.rs map_response (lines ~177-179): 401/403->Unauthorized, 404->NotFound, 503->Sealed, reqwest->Network, remainder->Other — matches this file's rustdoc exactly; taxonomy still complete for current consumers incl. the 722-hthz kv-v2 cas=0 create-only path (400 cas violations intentionally route through Other with body text); no dead variants; thiserror idiom current

use thiserror::Error;

/// All errors returned by [`crate::VaultClient`].
///
/// Variants map directly to the Vault HTTP response codes the client cares
/// about:
/// - 401/403  → [`VaultError::Unauthorized`]
/// - 404      → [`VaultError::NotFound`]
/// - 503      → [`VaultError::Sealed`]
///
/// Network failures (DNS, TCP, TLS, body decode) collapse into
/// [`VaultError::Network`]. Anything we don't recognize (5xx, malformed JSON,
/// unexpected schema) lands in [`VaultError::Other`].
#[derive(Debug, Error)]
pub enum VaultError {
    /// Transport-layer failure: connection refused, DNS, TLS, etc.
    #[error("vault network error: {0}")]
    Network(String),

    /// 401 / 403 — token missing, expired, or denied by policy.
    #[error("vault unauthorized: {0}")]
    Unauthorized(String),

    /// 503 — Vault is sealed or in standby without forwarding enabled.
    #[error("vault sealed: {0}")]
    Sealed(String),

    /// 404 — secret path does not exist.
    #[error("vault not found: {0}")]
    NotFound(String),

    /// Anything else: 5xx, malformed JSON, schema mismatch.
    #[error("vault error: {0}")]
    Other(String),
}

impl From<reqwest::Error> for VaultError {
    fn from(err: reqwest::Error) -> Self {
        VaultError::Network(err.to_string())
    }
}
