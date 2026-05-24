//! HashiCorp Vault client for Tillandsias.
//!
//! Talks to the in-enclave `tillandsias-vault` container over its
//! enclave-local TCP listener (`http://vault:8200`). All secrets are
//! short-lived tokens scoped by Vault ACL policy. The host process holds
//! only the root token at provisioning time; per-container tokens are
//! AppRole-minted with 1h TTLs.
//!
//! See `openspec/specs/tillandsias-vault/spec.md` for the threat model
//! and `cheatsheets/runtime/hashicorp-vault-tillandsias.md` for the
//! operator-facing recipes.
//!
//! @trace spec:tillandsias-vault
//! @cheatsheet runtime/hashicorp-vault-tillandsias.md

pub mod auto_unseal;
pub mod error;
pub mod policy;

pub use error::VaultError;
pub use policy::Policy;

use reqwest::StatusCode;
use serde::{Deserialize, Serialize};
use serde_json::Value;
use std::time::Duration;
use tracing::debug;
use zeroize::Zeroize;

/// Health status returned by `GET /v1/sys/health`.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct HealthStatus {
    pub initialized: bool,
    pub sealed: bool,
    pub standby: bool,
    pub version: String,
}

/// A handle to the Vault HTTP API.
///
/// Cheap to clone (wraps an `Arc`-backed `reqwest::Client` internally).
#[derive(Debug, Clone)]
pub struct VaultClient {
    pub base_url: String,
    pub token: String,
    client: reqwest::Client,
}

impl VaultClient {
    /// Create a new client. `base_url` should be the Vault root WITHOUT
    /// the `/v1` prefix (e.g. `http://vault:8200`).
    pub fn new(base_url: impl Into<String>, token: impl Into<String>) -> Self {
        let client = reqwest::Client::builder()
            .timeout(Duration::from_secs(10))
            .build()
            .expect("reqwest client build should not fail on default config");
        Self {
            base_url: base_url.into(),
            token: token.into(),
            client,
        }
    }

    fn url(&self, path: &str) -> String {
        let trimmed = path.trim_start_matches('/');
        format!("{}/v1/{}", self.base_url.trim_end_matches('/'), trimmed)
    }

    fn map_status(status: StatusCode, body: String) -> VaultError {
        match status {
            StatusCode::UNAUTHORIZED | StatusCode::FORBIDDEN => VaultError::Unauthorized(body),
            StatusCode::NOT_FOUND => VaultError::NotFound(body),
            StatusCode::SERVICE_UNAVAILABLE => VaultError::Sealed(body),
            other => VaultError::Other(format!("vault returned HTTP {other}: {body}")),
        }
    }

    /// Read a KV-v2 secret at the given path. The path may be supplied
    /// either as `secret/data/foo` (full) or just `secret/foo` (the
    /// `data/` infix is inserted automatically when missing).
    ///
    /// Returns the inner `data.data` object — the actual key/value pairs
    /// stored. To get the full envelope (with version metadata), use
    /// [`Self::read_secret_raw`].
    pub async fn read_secret(&self, path: &str) -> Result<Value, VaultError> {
        // `read_secret_raw` returns the top-level `data` object. KV-v2
        // wraps the user payload in another `data` field alongside
        // `metadata`, so the user payload lives at `/data` from here.
        let envelope = self.read_secret_raw(path).await?;
        envelope
            .pointer("/data")
            .cloned()
            .ok_or_else(|| VaultError::Other(format!("missing data.data in response: {envelope}")))
    }

    /// Read a KV-v2 secret and return the FULL envelope (Vault's `data`
    /// object containing `data` and `metadata`).
    pub async fn read_secret_raw(&self, path: &str) -> Result<Value, VaultError> {
        let kv_path = ensure_kv_data_prefix(path);
        debug!(target: "tillandsias_vault_client", path = %kv_path, "GET secret");
        let resp = self
            .client
            .get(self.url(&kv_path))
            .header("X-Vault-Token", &self.token)
            .send()
            .await?;
        let status = resp.status();
        if status.is_success() {
            let value: Value = resp.json().await?;
            value
                .get("data")
                .cloned()
                .ok_or_else(|| VaultError::Other(format!("missing data field in response: {value}")))
        } else {
            let body = resp.text().await.unwrap_or_default();
            Err(Self::map_status(status, body))
        }
    }

    /// Write a KV-v2 secret. `data` is the inner key/value object —
    /// the `{ "data": ... }` envelope is added automatically.
    pub async fn write_secret(&self, path: &str, data: Value) -> Result<(), VaultError> {
        let kv_path = ensure_kv_data_prefix(path);
        let envelope = serde_json::json!({ "data": data });
        debug!(target: "tillandsias_vault_client", path = %kv_path, "PUT secret");
        let resp = self
            .client
            .post(self.url(&kv_path))
            .header("X-Vault-Token", &self.token)
            .json(&envelope)
            .send()
            .await?;
        let status = resp.status();
        if status.is_success() {
            Ok(())
        } else {
            let body = resp.text().await.unwrap_or_default();
            Err(Self::map_status(status, body))
        }
    }

    /// Mint a child token scoped to the named AppRole.
    ///
    /// Uses the AppRole auth flow under the hood: this client (assumed to
    /// hold the tray/root token) reads the role's `role_id`, mints a fresh
    /// `secret_id`, then logs in as that role to obtain a policy-scoped
    /// token. The resulting token is what gets injected as a podman secret
    /// into the target container.
    pub async fn issue_approle_token(&self, role: &str) -> Result<String, VaultError> {
        // Step 1: read role_id.
        let role_id: String = {
            let url = self.url(&format!("auth/approle/role/{role}/role-id"));
            let resp = self
                .client
                .get(&url)
                .header("X-Vault-Token", &self.token)
                .send()
                .await?;
            let status = resp.status();
            if !status.is_success() {
                let body = resp.text().await.unwrap_or_default();
                return Err(Self::map_status(status, body));
            }
            let v: Value = resp.json().await?;
            v.pointer("/data/role_id")
                .and_then(Value::as_str)
                .map(str::to_string)
                .ok_or_else(|| VaultError::Other(format!("missing role_id in response: {v}")))?
        };

        // Step 2: mint a fresh secret_id.
        let secret_id: String = {
            let url = self.url(&format!("auth/approle/role/{role}/secret-id"));
            let resp = self
                .client
                .post(&url)
                .header("X-Vault-Token", &self.token)
                .send()
                .await?;
            let status = resp.status();
            if !status.is_success() {
                let body = resp.text().await.unwrap_or_default();
                return Err(Self::map_status(status, body));
            }
            let v: Value = resp.json().await?;
            v.pointer("/data/secret_id")
                .and_then(Value::as_str)
                .map(str::to_string)
                .ok_or_else(|| VaultError::Other(format!("missing secret_id in response: {v}")))?
        };

        // Step 3: login.
        let url = self.url("auth/approle/login");
        let body = serde_json::json!({ "role_id": role_id, "secret_id": secret_id });
        let resp = self.client.post(&url).json(&body).send().await?;
        let status = resp.status();
        if !status.is_success() {
            let body = resp.text().await.unwrap_or_default();
            return Err(Self::map_status(status, body));
        }
        let v: Value = resp.json().await?;
        let mut token = v
            .pointer("/auth/client_token")
            .and_then(Value::as_str)
            .map(str::to_string)
            .ok_or_else(|| {
                VaultError::Other(format!("missing auth.client_token in response: {v}"))
            })?;
        let out = token.clone();
        token.zeroize();
        Ok(out)
    }

    /// Revoke the supplied token (lease + accessor + children).
    pub async fn revoke_token(&self, token: &str) -> Result<(), VaultError> {
        let url = self.url("auth/token/revoke");
        let body = serde_json::json!({ "token": token });
        let resp = self
            .client
            .post(&url)
            .header("X-Vault-Token", &self.token)
            .json(&body)
            .send()
            .await?;
        let status = resp.status();
        if status.is_success() || status == StatusCode::NO_CONTENT {
            Ok(())
        } else {
            let body = resp.text().await.unwrap_or_default();
            Err(Self::map_status(status, body))
        }
    }

    /// Probe `GET /v1/sys/health` and decode the response. Vault returns
    /// non-200 codes for non-active states (sealed=503, uninit=501, etc.);
    /// the query params force a 200 so we can decode uniformly.
    pub async fn health(&self) -> Result<HealthStatus, VaultError> {
        let url = format!(
            "{}/v1/sys/health?sealedcode=200&uninitcode=200&standbyok=true",
            self.base_url.trim_end_matches('/')
        );
        let resp = self.client.get(&url).send().await?;
        let v: Value = resp.json().await?;
        Ok(HealthStatus {
            initialized: v.get("initialized").and_then(Value::as_bool).unwrap_or(false),
            sealed: v.get("sealed").and_then(Value::as_bool).unwrap_or(true),
            standby: v.get("standby").and_then(Value::as_bool).unwrap_or(false),
            version: v
                .get("version")
                .and_then(Value::as_str)
                .unwrap_or("unknown")
                .to_string(),
        })
    }
}

/// Normalize a KV-v2 path by inserting the `data/` infix between the
/// mount point and the secret name when missing. Keeps callers from
/// having to remember the KV-v2 quirk: `secret/foo` becomes
/// `secret/data/foo` for reads/writes.
fn ensure_kv_data_prefix(path: &str) -> String {
    let p = path.trim_matches('/');
    if p.is_empty() {
        return p.to_string();
    }
    let mut segments = p.splitn(2, '/');
    let mount = segments.next().unwrap_or("");
    let rest = segments.next().unwrap_or("");
    if rest.starts_with("data/") || rest == "data" {
        p.to_string()
    } else if rest.is_empty() {
        mount.to_string()
    } else {
        format!("{mount}/data/{rest}")
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn ensure_kv_data_prefix_inserts_data_infix() {
        assert_eq!(ensure_kv_data_prefix("secret/foo"), "secret/data/foo");
        assert_eq!(
            ensure_kv_data_prefix("secret/github/token"),
            "secret/data/github/token"
        );
        assert_eq!(ensure_kv_data_prefix("/secret/foo/"), "secret/data/foo");
    }

    #[test]
    fn ensure_kv_data_prefix_is_idempotent() {
        assert_eq!(ensure_kv_data_prefix("secret/data/foo"), "secret/data/foo");
        assert_eq!(
            ensure_kv_data_prefix("secret/data/github/token"),
            "secret/data/github/token"
        );
    }

    #[test]
    fn url_joins_correctly_with_or_without_trailing_slash() {
        let c = VaultClient::new("http://vault:8200", "root");
        assert_eq!(c.url("sys/health"), "http://vault:8200/v1/sys/health");
        let c2 = VaultClient::new("http://vault:8200/", "root");
        assert_eq!(c2.url("/sys/health"), "http://vault:8200/v1/sys/health");
    }
}
