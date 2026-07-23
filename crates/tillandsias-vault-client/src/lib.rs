//! HashiCorp Vault client for Tillandsias.
//!
//! Talks to the in-enclave `tillandsias-vault` container over its
//! enclave-local TLS listener (`https://vault:8200`). All secrets are
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

/// Server-side lifetime for a reusable Vault Agent AppRole SecretID.
///
/// This is twice the 24h client-token max TTL: long enough to prove and use a
/// max-TTL re-authentication, but finite so SIGKILL or host loss cannot orphan
/// an unlimited credential when the in-process accessor registry is lost.
pub const APPROLE_AGENT_SECRET_ID_TTL: &str = "48h";

/// Launch-scoped AppRole material for a long-running Vault Agent.
///
/// The role ID is not confidential by itself, but it is kept private with the
/// secret ID so callers cannot accidentally log either field through a derived
/// `Debug` implementation. All three strings are zeroized on drop.
pub struct AppRoleCredentials {
    role_id: String,
    secret_id: String,
    secret_id_accessor: String,
}

impl AppRoleCredentials {
    pub fn role_id(&self) -> &str {
        &self.role_id
    }

    pub fn secret_id(&self) -> &str {
        &self.secret_id
    }

    pub fn secret_id_accessor(&self) -> &str {
        &self.secret_id_accessor
    }
}

impl Drop for AppRoleCredentials {
    fn drop(&mut self) {
        self.role_id.zeroize();
        self.secret_id.zeroize();
        self.secret_id_accessor.zeroize();
    }
}

/// Parse a response that may contain credential material, then overwrite the
/// raw response buffer immediately. Callers must remove any secret strings
/// from the returned JSON value with [`take_required_json_string`] so the
/// generic value cannot retain a second heap copy.
fn parse_sensitive_json(mut body: String, context: &str) -> Result<Value, VaultError> {
    let parsed = serde_json::from_str(&body)
        .map_err(|e| VaultError::Other(format!("malformed {context} response: {e}")));
    body.zeroize();
    parsed
}

/// Move one required string out of a JSON response without including the
/// response body in a schema error. AppRole issuance responses contain a
/// SecretID, so formatting the whole value into an error would leak that
/// credential precisely when an adjacent field is missing.
fn take_required_json_string(
    value: &mut Value,
    pointer: &str,
    field: &str,
) -> Result<String, VaultError> {
    let Some(slot) = value.pointer_mut(pointer) else {
        return Err(VaultError::Other(format!(
            "missing {field} in Vault response"
        )));
    };
    match std::mem::take(slot) {
        Value::String(text) if !text.is_empty() => Ok(text),
        Value::String(mut text) => {
            text.zeroize();
            Err(VaultError::Other(format!(
                "empty {field} in Vault response"
            )))
        }
        _ => Err(VaultError::Other(format!(
            "missing {field} in Vault response"
        ))),
    }
}

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
    /// the `/v1` prefix (e.g. `https://vault:8200`).
    pub fn new(base_url: impl Into<String>, token: impl Into<String>) -> Self {
        Self::with_client(
            base_url,
            token,
            reqwest::Client::builder()
                .timeout(Duration::from_secs(10))
                .build()
                .expect("reqwest client build should not fail on default config"),
        )
    }

    /// Create a client that trusts the PEM-encoded CA which issued the
    /// enclave Vault server certificate.
    pub fn new_with_ca_certificate(
        base_url: impl Into<String>,
        token: impl Into<String>,
        ca_pem: &[u8],
    ) -> Result<Self, VaultError> {
        let certificate = reqwest::Certificate::from_pem(ca_pem)
            .map_err(|e| VaultError::Other(format!("invalid Vault CA certificate: {e}")))?;
        let client = reqwest::Client::builder()
            .timeout(Duration::from_secs(10))
            .add_root_certificate(certificate)
            .build()?;
        Ok(Self::with_client(base_url, token, client))
    }

    fn with_client(
        base_url: impl Into<String>,
        token: impl Into<String>,
        client: reqwest::Client,
    ) -> Self {
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
            value.get("data").cloned().ok_or_else(|| {
                VaultError::Other(format!("missing data field in response: {value}"))
            })
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

    /// Issue launch-scoped AppRole material without consuming it in a login.
    ///
    /// Long-running containers give this material to Vault Agent through a
    /// Podman secret. Agent can then renew the current client token and
    /// re-authenticate after that token reaches its hard max TTL.
    pub async fn issue_approle_credentials(
        &self,
        role: &str,
    ) -> Result<AppRoleCredentials, VaultError> {
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
            let body = resp.text().await?;
            let mut v = parse_sensitive_json(body, "AppRole role ID")?;
            take_required_json_string(&mut v, "/data/role_id", "role_id")?
        };

        let (secret_id, secret_id_accessor): (String, String) = {
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
            let body = resp.text().await?;
            let mut v = parse_sensitive_json(body, "AppRole SecretID")?;
            let mut secret_id = take_required_json_string(&mut v, "/data/secret_id", "secret_id")?;
            let secret_id_accessor = match take_required_json_string(
                &mut v,
                "/data/secret_id_accessor",
                "secret_id_accessor",
            ) {
                Ok(accessor) => accessor,
                Err(error) => {
                    secret_id.zeroize();
                    return Err(error);
                }
            };
            (secret_id, secret_id_accessor)
        };

        Ok(AppRoleCredentials {
            role_id,
            secret_id,
            secret_id_accessor,
        })
    }

    /// Mint a child token scoped to the named AppRole.
    ///
    /// One-shot callers consume fresh AppRole material immediately. Long-lived
    /// callers should use [`Self::issue_approle_credentials`] and Vault Agent
    /// so they can re-authenticate after the original token reaches max TTL.
    pub async fn issue_approle_token(&self, role: &str) -> Result<String, VaultError> {
        let credentials = self.issue_approle_credentials(role).await?;
        let url = self.url("auth/approle/login");
        #[derive(Serialize)]
        struct AppRoleLogin<'a> {
            role_id: &'a str,
            secret_id: &'a str,
        }
        let body = AppRoleLogin {
            role_id: credentials.role_id(),
            secret_id: credentials.secret_id(),
        };
        let resp = self.client.post(&url).json(&body).send().await?;
        let status = resp.status();
        if !status.is_success() {
            let body = resp.text().await.unwrap_or_default();
            return Err(Self::map_status(status, body));
        }
        let body = resp.text().await?;
        let mut v = parse_sensitive_json(body, "AppRole login")?;
        take_required_json_string(&mut v, "/auth/client_token", "auth.client_token")
    }

    /// Revoke reusable AppRole login material by its non-secret accessor.
    ///
    /// Vault Agent needs the same secret ID again after a client token reaches
    /// max TTL, so git-mirror credentials are intentionally reusable for the
    /// container lifetime. The host destroys the accessor during shutdown.
    pub async fn destroy_approle_secret_id_accessor(
        &self,
        role: &str,
        secret_id_accessor: &str,
    ) -> Result<(), VaultError> {
        let url = self.url(&format!(
            "auth/approle/role/{role}/secret-id-accessor/destroy"
        ));
        let resp = self
            .client
            .post(&url)
            .header("X-Vault-Token", &self.token)
            .json(&serde_json::json!({ "secret_id_accessor": secret_id_accessor }))
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

    /// Check if a given AppRole exists.
    pub async fn approle_role_exists(&self, role: &str) -> Result<bool, VaultError> {
        let url = self.url(&format!("auth/approle/role/{role}/role-id"));
        let resp = self
            .client
            .get(&url)
            .header("X-Vault-Token", &self.token)
            .send()
            .await?;
        let status = resp.status();
        if status.is_success() {
            Ok(true)
        } else if status == StatusCode::NOT_FOUND {
            Ok(false)
        } else {
            let body = resp.text().await.unwrap_or_default();
            Err(Self::map_status(status, body))
        }
    }

    /// Write an HCL policy at the given name. Idempotent — Vault overwrites
    /// the policy body on every call. Used by the tray's vault bootstrap
    /// path to load each `Policy::hcl()` body without shelling out to the
    /// `vault` CLI.
    pub async fn write_policy(&self, name: &str, hcl: &str) -> Result<(), VaultError> {
        let url = self.url(&format!("sys/policies/acl/{name}"));
        let body = serde_json::json!({ "policy": hcl });
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

    /// Enable the AppRole auth backend. Idempotent: a 400 "path is already
    /// in use" is squashed to `Ok(())` so callers can call this on every
    /// boot.
    pub async fn enable_approle(&self) -> Result<(), VaultError> {
        let url = self.url("sys/auth/approle");
        let body = serde_json::json!({ "type": "approle" });
        let resp = self
            .client
            .post(&url)
            .header("X-Vault-Token", &self.token)
            .json(&body)
            .send()
            .await?;
        let status = resp.status();
        if status.is_success() || status == StatusCode::NO_CONTENT {
            return Ok(());
        }
        if status == StatusCode::BAD_REQUEST {
            // Vault returns 400 when the auth method already exists. Treat
            // as success.
            return Ok(());
        }
        let body = resp.text().await.unwrap_or_default();
        Err(Self::map_status(status, body))
    }

    /// Create an AppRole role bound to the named policies with the supplied
    /// TTLs (seconds). Idempotent — Vault overwrites the role config on
    /// repeated calls.
    pub async fn create_approle_role(
        &self,
        role: &str,
        policies: &[&str],
        token_ttl_secs: u64,
        token_max_ttl_secs: u64,
    ) -> Result<(), VaultError> {
        self.create_approle_role_with_secret_id_lifecycle(
            role,
            policies,
            token_ttl_secs,
            token_max_ttl_secs,
            1,
            "30s",
        )
        .await
    }

    /// Create the dedicated long-running AppRole consumed by Vault Agent.
    ///
    /// A normal one-use/30-second SecretID cannot authenticate again after
    /// the first client token reaches max TTL. This role therefore permits
    /// reuse for a bounded 48h window or until the host explicitly destroys
    /// its SecretID accessor. Its client tokens are explicitly unlimited-use
    /// (`token_num_uses=0`), as required by Vault Agent auto-auth.
    pub async fn create_approle_agent_role(
        &self,
        role: &str,
        policies: &[&str],
        token_ttl_secs: u64,
        token_max_ttl_secs: u64,
    ) -> Result<(), VaultError> {
        self.create_approle_role_with_secret_id_lifecycle(
            role,
            policies,
            token_ttl_secs,
            token_max_ttl_secs,
            0,
            APPROLE_AGENT_SECRET_ID_TTL,
        )
        .await
    }

    async fn create_approle_role_with_secret_id_lifecycle(
        &self,
        role: &str,
        policies: &[&str],
        token_ttl_secs: u64,
        token_max_ttl_secs: u64,
        secret_id_num_uses: u64,
        secret_id_ttl: &str,
    ) -> Result<(), VaultError> {
        let url = self.url(&format!("auth/approle/role/{role}"));
        let body = serde_json::json!({
            "token_policies": policies.join(","),
            "token_ttl": format!("{token_ttl_secs}s"),
            "token_max_ttl": format!("{token_max_ttl_secs}s"),
            // Vault Agent auto-auth cannot use limited-use client tokens.
            // Pin the Vault default explicitly so role updates cannot inherit
            // a stale nonzero value from an earlier configuration.
            "token_num_uses": 0,
            "secret_id_num_uses": secret_id_num_uses,
            "secret_id_ttl": secret_id_ttl,
        });
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

    /// Validate this client's token against `GET /v1/auth/token/lookup-self`.
    ///
    /// `Ok(())` proves the token is accepted by the server's token store.
    /// A stale/rotated cached root token surfaces as
    /// [`VaultError::Unauthorized`] — the detect half of the order-383
    /// stale-root-token heal seam.
    pub async fn token_lookup_self(&self) -> Result<(), VaultError> {
        let resp = self
            .client
            .get(self.url("auth/token/lookup-self"))
            .header("X-Vault-Token", &self.token)
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

    /// List AppRole role names (`LIST /v1/auth/approle/role`).
    ///
    /// An empty backend returns 404 from Vault; that is mapped to
    /// `Ok(vec![])` — only permission problems and transport failures are
    /// errors. Used by the post-heal reachability probe (order 383): a
    /// healed root token that still gets `Unauthorized` here means the
    /// token/storage skew is deeper than the root token.
    pub async fn list_approle_roles(&self) -> Result<Vec<String>, VaultError> {
        let url = format!("{}?list=true", self.url("auth/approle/role"));
        let resp = self
            .client
            .get(&url)
            .header("X-Vault-Token", &self.token)
            .send()
            .await?;
        let status = resp.status();
        if status == StatusCode::NOT_FOUND {
            return Ok(Vec::new());
        }
        if !status.is_success() {
            let body = resp.text().await.unwrap_or_default();
            return Err(Self::map_status(status, body));
        }
        let v: Value = resp.json().await?;
        Ok(v.pointer("/data/keys")
            .and_then(Value::as_array)
            .map(|keys| {
                keys.iter()
                    .filter_map(Value::as_str)
                    .map(str::to_string)
                    .collect()
            })
            .unwrap_or_default())
    }

    /// Cancel any in-progress root-token generation attempt
    /// (`DELETE /v1/sys/generate-root/attempt`). Idempotent; needs no
    /// token. Always call before [`Self::generate_root_start`] — a stale
    /// half-finished attempt keeps its nonce but never re-reveals its OTP,
    /// so resuming one is impossible.
    pub async fn generate_root_cancel(&self) -> Result<(), VaultError> {
        let resp = self
            .client
            .delete(self.url("sys/generate-root/attempt"))
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

    /// Start a root-token generation attempt
    /// (`POST /v1/sys/generate-root/attempt`). Vault generates the OTP
    /// server-side and reveals it ONLY in this response. Needs no token —
    /// the flow is authenticated by possession of unseal key shares.
    pub async fn generate_root_start(&self) -> Result<GenerateRootAttempt, VaultError> {
        let resp = self
            .client
            .post(self.url("sys/generate-root/attempt"))
            .json(&serde_json::json!({}))
            .send()
            .await?;
        let status = resp.status();
        if !status.is_success() {
            let body = resp.text().await.unwrap_or_default();
            return Err(Self::map_status(status, body));
        }
        let v: Value = resp.json().await?;
        let nonce = v
            .get("nonce")
            .and_then(Value::as_str)
            .map(str::to_string)
            .ok_or_else(|| VaultError::Other(format!("missing nonce in response: {v}")))?;
        let otp = v
            .get("otp")
            .and_then(Value::as_str)
            .map(str::to_string)
            .ok_or_else(|| VaultError::Other(format!("missing otp in response: {v}")))?;
        Ok(GenerateRootAttempt {
            nonce,
            otp,
            required: v.get("required").and_then(Value::as_u64).unwrap_or(1),
        })
    }

    /// Feed one unseal key share into the active generate-root attempt
    /// (`PUT /v1/sys/generate-root/update`). `key` accepts the share as
    /// base64 or hex — the same encoding `vault operator unseal` takes.
    pub async fn generate_root_update(
        &self,
        key: &str,
        nonce: &str,
    ) -> Result<GenerateRootProgress, VaultError> {
        let resp = self
            .client
            .put(self.url("sys/generate-root/update"))
            .json(&serde_json::json!({ "key": key, "nonce": nonce }))
            .send()
            .await?;
        let status = resp.status();
        if !status.is_success() {
            let body = resp.text().await.unwrap_or_default();
            return Err(Self::map_status(status, body));
        }
        let v: Value = resp.json().await?;
        let encoded_token = v
            .get("encoded_token")
            .and_then(Value::as_str)
            .filter(|s| !s.is_empty())
            // Pre-1.0 servers used encoded_root_token; accept both.
            .or_else(|| {
                v.get("encoded_root_token")
                    .and_then(Value::as_str)
                    .filter(|s| !s.is_empty())
            })
            .map(str::to_string);
        Ok(GenerateRootProgress {
            complete: v.get("complete").and_then(Value::as_bool).unwrap_or(false),
            encoded_token,
        })
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
            initialized: v
                .get("initialized")
                .and_then(Value::as_bool)
                .unwrap_or(false),
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

/// A started root-token generation attempt (`sys/generate-root/attempt`).
/// The OTP is revealed only in this response and is required to decode
/// the final encoded token.
#[derive(Debug, Clone)]
pub struct GenerateRootAttempt {
    pub nonce: String,
    pub otp: String,
    /// Number of unseal key shares required to complete the attempt.
    pub required: u64,
}

/// Progress of a generate-root attempt after feeding in a key share.
#[derive(Debug, Clone)]
pub struct GenerateRootProgress {
    pub complete: bool,
    /// Present once `complete`; decode with
    /// [`decode_generated_root_token`].
    pub encoded_token: Option<String>,
}

/// Decode the `encoded_token` returned by a completed generate-root
/// attempt: base64 (raw, standard alphabet) decode, then XOR with the
/// attempt's OTP bytes — the same transform `vault operator
/// generate-root -decode` performs. Pure; pinned by unit test.
pub fn decode_generated_root_token(encoded: &str, otp: &str) -> Result<String, VaultError> {
    use base64::Engine;
    let trimmed = encoded.trim_end_matches('=');
    let token_xor = base64::engine::general_purpose::STANDARD_NO_PAD
        .decode(trimmed)
        .map_err(|e| VaultError::Other(format!("encoded root token is not base64: {e}")))?;
    let otp_bytes = otp.as_bytes();
    if token_xor.len() != otp_bytes.len() {
        return Err(VaultError::Other(format!(
            "encoded root token length {} does not match OTP length {} — cannot XOR-decode",
            token_xor.len(),
            otp_bytes.len()
        )));
    }
    let decoded: Vec<u8> = token_xor
        .iter()
        .zip(otp_bytes)
        .map(|(a, b)| a ^ b)
        .collect();
    String::from_utf8(decoded)
        .map_err(|e| VaultError::Other(format!("decoded root token is not UTF-8: {e}")))
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
        let c = VaultClient::new("https://vault:8200", "root");
        assert_eq!(c.url("sys/health"), "https://vault:8200/v1/sys/health");
        let c2 = VaultClient::new("https://vault:8200/", "root");
        assert_eq!(c2.url("/sys/health"), "https://vault:8200/v1/sys/health");
    }

    #[test]
    fn decode_generated_root_token_round_trips() {
        use base64::Engine;
        // Order 383: mirror Vault's encode side (token XOR otp, base64
        // raw-std) and assert the decoder recovers the token exactly.
        let token = "hvs.fixture-root-token-for-decode";
        let otp = "0123456789abcdefghijklmnopqrstuvw";
        assert_eq!(token.len(), otp.len(), "fixture lengths must match");
        let xored: Vec<u8> = token
            .as_bytes()
            .iter()
            .zip(otp.as_bytes())
            .map(|(a, b)| a ^ b)
            .collect();
        let encoded = base64::engine::general_purpose::STANDARD_NO_PAD.encode(&xored);
        assert_eq!(
            decode_generated_root_token(&encoded, otp).expect("decode"),
            token
        );
        // Padded input (some Vault builds emit padding) must also decode.
        let padded = base64::engine::general_purpose::STANDARD.encode(&xored);
        assert_eq!(
            decode_generated_root_token(&padded, otp).expect("padded decode"),
            token
        );
    }

    #[test]
    fn decode_generated_root_token_rejects_bad_inputs() {
        // Length mismatch: OTP shorter than the encoded token.
        decode_generated_root_token("aGVsbG8", "xy").expect_err("length mismatch must fail");
        // Not base64 at all.
        decode_generated_root_token("!!!not-base64!!!", "irrelevant")
            .expect_err("invalid base64 must fail");
    }

    #[test]
    fn invalid_ca_certificate_is_rejected() {
        VaultClient::new_with_ca_certificate(
            "https://vault:8200",
            "root",
            b"-----BEGIN CERTIFICATE-----\nAAAA\n-----END CERTIFICATE-----\n",
        )
        .expect_err("invalid PEM must fail");
    }
}
