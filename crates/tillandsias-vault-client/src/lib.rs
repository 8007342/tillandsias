//! HashiCorp Vault client and policy templates for Tillandsias.
//!
//! Talks to the in-VM `tillandsias-vault` container over its enclave-local
//! TCP listener (`vault:8200`). All secrets are short-lived tokens scoped
//! by Vault ACL policy. The host never sees long-lived credentials.
//!
//! This crate is a SCAFFOLD ONLY — every function returns `todo!()` or a
//! placeholder default. See `openspec/specs/tillandsias-vault/spec.md`.
//!
//! @trace spec:tillandsias-vault

#![allow(dead_code)]
#![allow(unused)]

pub mod auto_unseal;
pub mod policy;

/// A handle to the Vault HTTP API.
pub struct VaultClient {
    pub base_url: String,
    pub token: Option<String>,
}

impl VaultClient {
    pub fn new(base_url: impl Into<String>) -> Self {
        Self {
            base_url: base_url.into(),
            token: None,
        }
    }

    /// Read a secret at the given path. Returns the raw JSON value or an
    /// error describing the Vault response.
    pub async fn read_secret(&self, _path: &str) -> Result<serde_json::Value, String> {
        todo!("@spec tillandsias-vault: HTTP GET /v1/<path> with token header")
    }

    /// Issue a short-lived child token bound to the named policy.
    pub async fn issue_token(&self, _policy: policy::Policy) -> Result<String, String> {
        todo!("@spec tillandsias-vault: HTTP POST /v1/auth/token/create with policies[]")
    }
}
