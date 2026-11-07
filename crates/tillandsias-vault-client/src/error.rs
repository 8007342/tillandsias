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
        VaultError::Network(error_chain(&err))
    }
}

/// 2000-camv: reqwest's own message is only "error sending request for url
/// (...)"; the cause (a TLS verify failure, a refused connect) is in the
/// source chain. Every link is kept, so a caller can classify the failure.
pub(crate) fn error_chain(err: &dyn std::error::Error) -> String {
    let mut out = err.to_string();
    let mut source = err.source();
    while let Some(s) = source {
        out.push_str(": ");
        out.push_str(&s.to_string());
        source = s.source();
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    #[derive(Debug)]
    struct E(&'static str, Option<Box<E>>);
    impl std::fmt::Display for E {
        fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
            f.write_str(self.0)
        }
    }
    impl std::error::Error for E {
        fn source(&self) -> Option<&(dyn std::error::Error + 'static)> {
            self.1.as_deref().map(|e| e as _)
        }
    }

    /// ORDER 2000-camv: the network error keeps the cause. Pre-fix: FAILS, only
    /// the top message survived, so a TLS failure could not be told apart.
    #[test]
    fn a_network_error_keeps_its_cause() {
        let e = E(
            "error sending request for url (https://127.0.0.1:8201/v1/sys/health)",
            Some(Box::new(E(
                "client error (Connect)",
                Some(Box::new(E("invalid peer certificate: UnknownIssuer", None))),
            ))),
        );
        let got = error_chain(&e);
        assert!(
            got.ends_with("invalid peer certificate: UnknownIssuer"),
            "{got}"
        );
    }
}
