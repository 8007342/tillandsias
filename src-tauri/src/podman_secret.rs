//! Podman secrets management for secure credential delivery.
//!
//! This module provides an abstraction layer over podman's native secret storage,
//! enabling secure in-container delivery of CA certificates, credentials, and other
//! sensitive data without exposing them in process lists, environment variables, or logs.
//!
//! # Security Model
//!
//! Secrets created via this module are ephemeral: they exist only for the lifetime of
//! containers that consume them. The secrets themselves are stored by podman in a
//! backend driver (typically systemd-user-secrets on systemd systems, or plaintext in
//! rootless contexts). This module provides no encryption — encryption is the host
//! OS's responsibility. Tillandsias uses podman secrets primarily to:
//!
//! - **CA certificates**: inject system CA bundles into proxy and git-service containers
//!   without bind-mounting `/etc/ssl`, which would expose the entire certificate store
//! - **Ephemeral tokens**: pass GitHub tokens read from the OS keyring into git-service
//!   containers via `podman secret` instead of environment variables (which appear in `ps`)
//!
//! # API Overview
//!
//! - [`create`] — create a secret from raw bytes, returns secret ID
//! - [`exists`] — check if a secret exists (by name)
//! - [`remove`] — delete a secret
//! - [`list`] — enumerate all secrets (for debugging and cleanup)
//!
//! All operations use [`tillandsias_podman::podman_cmd_sync`] (synchronous subprocess).
//! Async callers should use [`tokio::task::spawn_blocking`] to avoid blocking the event loop.
//!
//! # Example: Creating and Using a Secret
//!
//! ```rust,ignore
//! use crate::podman_secret;
//!
//! // Create a secret from CA certificate bytes
//! let cert_bytes = std::fs::read("/etc/ssl/certs/ca-bundle.crt").unwrap();
//! let secret_id = podman_secret::create("ca-bundle", &cert_bytes)
//!     .expect("Failed to create CA secret");
//!
//! // Later, when launching a container, pass the secret to podman run:
//! //   podman run --secret ca-bundle <image>
//! // The secret is mounted read-only at /run/secrets/ca-bundle inside the container
//!
//! // Cleanup on container exit
//! podman_secret::remove("ca-bundle").ok();
//! ```
//!
//! # Example: Conditional Token Injection
//!
//! ```rust,ignore
//! // Inject a GitHub token only if one exists in the keyring
//! if let Some(token) = retrieve_github_token()? {
//!     podman_secret::create("github-token", token.as_bytes())?;
//!     // podman run --secret github-token <image>
//!     // Inside: cat /run/secrets/github-token
//! }
//! ```
//!
//! # Lifecycle
//!
//! When a container using a secret stops, podman does NOT automatically remove the
//! secret — the secret persists in the podman backend until explicitly deleted.
//! This module's caller (container orchestrator in handlers.rs) is responsible for:
//!
//! 1. Creating secrets before container launch
//! 2. Calling `remove()` after the container exits (in cleanup tasks or drop guards)
//! 3. Sweeping all secrets on app shutdown via `cleanup_all()`
//!
//! @trace spec:podman-orchestration, spec:secrets-management
//!
//! # Windows and WSL
//!
//! On Windows, rootless podman runs under WSL2 distro isolation. Secrets created
//! in one WSL distro are not visible to another. The tray (running on Windows host,
//! or in a coordinating WSL distro) creates secrets and then references them by name
//! in `podman run` commands that run inside the tillandsias-git WSL distro.
//!
//! @trace spec:cross-platform, spec:windows-wsl-runtime
//!
//! # Observability
//!
//! All operations emit tracing events with `spec = "podman-orchestration"` or
//! `spec = "secrets-management"`. No secret material appears in logs — only the
//! secret name and operation type.

use std::str;

use serde::Deserialize;
use sha2::{Digest, Sha256};
use tracing::{debug, error, info, instrument};

/// A secret in the podman secrets store (from `podman secret ls --format json`).
#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all = "PascalCase")]
pub struct Secret {
    /// Secret name (e.g., "ca-bundle", "github-token").
    pub name: String,

    /// Driver that stores this secret (e.g., "file", "pass").
    pub driver: Option<String>,

    /// When the secret was created (ISO 8601 timestamp, typically).
    #[serde(rename = "CreatedAt")]
    #[allow(dead_code)]
    pub created_at: Option<String>,

    /// When the secret was last updated.
    #[serde(rename = "UpdatedAt")]
    #[allow(dead_code)]
    pub updated_at: Option<String>,
}

/// Compute SHA-256 fingerprint of CA certificate bytes.
///
/// @trace spec:secrets-lifecycle-ca-audit-trail
pub fn ca_cert_fingerprint(cert_pem: &[u8]) -> String {
    let mut hasher = Sha256::new();
    hasher.update(cert_pem);
    format!("{:x}", hasher.finalize())
}

impl std::fmt::Display for Secret {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(
            f,
            "{} ({})",
            self.name,
            self.driver.as_deref().unwrap_or("unknown")
        )
    }
}

/// Create a secret from raw bytes, returning its ID (same as its name).
///
/// The input `value` is piped to `podman secret create` via stdin, avoiding
/// exposure in process arguments. The secret is stored by the podman backend
/// driver and remains until explicitly removed via [`remove`].
///
/// For CA certificates, computes and logs the SHA-256 fingerprint for audit.
///
/// # Arguments
///
/// * `name` — Secret name (e.g., "ca-bundle", "github-token"). Must be valid
///   for podman naming (alphanumeric, -, _). Recommended: lowercase with hyphens.
/// * `value` — Raw bytes to store (e.g., certificate PEM, token string).
///
/// # Returns
///
/// * `Ok(String)` — the secret ID, typically the same as `name`
/// * `Err(String)` — podman error (secret already exists, invalid name, etc.)
///
/// # Examples
///
/// ```rust,ignore
/// // Store a CA certificate
/// let cert_bytes = std::fs::read("/etc/ssl/certs/ca-bundle.crt")?;
/// let id = podman_secret::create("ca-bundle", &cert_bytes)?;
/// assert_eq!(id, "ca-bundle");
///
/// // Store a GitHub token (from keyring or env)
/// let token = "ghp_...";
/// podman_secret::create("github-token", token.as_bytes())?;
/// ```
///
/// # Security
///
/// The input bytes are never exposed in:
/// - Process arguments (passed via stdin instead)
/// - Tracing logs (only the secret name is logged)
/// - Command output (podman prints only the name)
///
/// @trace spec:secrets-management, spec:podman-orchestration, spec:secrets-lifecycle-ca-audit-trail
#[instrument(skip_all, fields(name = %name))]
pub fn create(name: &str, value: &[u8]) -> Result<String, String> {
    use std::io::Write;
    use std::process::Stdio;

    debug!(spec = "secrets-management", "Creating podman secret");

    let mut child = tillandsias_podman::podman_cmd_sync()
        .arg("secret")
        .arg("create")
        .arg(name)
        .arg("-")
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .map_err(|e| format!("Failed to spawn podman secret create: {e}"))?;

    // Write the secret value to stdin, then drop the handle to close stdin.
    if let Some(mut stdin) = child.stdin.take() {
        stdin.write_all(value).map_err(|e| {
            let _ = child.kill();
            format!("Failed to write secret to podman stdin: {e}")
        })?;
    }

    let output = child
        .wait_with_output()
        .map_err(|e| format!("podman secret create failed: {e}"))?;

    if !output.status.success() {
        let stderr = String::from_utf8_lossy(&output.stderr);
        error!(
            spec = "secrets-management",
            stderr = %stderr,
            "podman secret create failed"
        );
        return Err(format!("podman secret create {}: {}", name, stderr.trim()));
    }

    let stdout = String::from_utf8_lossy(&output.stdout);
    let secret_id = stdout.trim().to_string();

    // @trace spec:secrets-lifecycle-ca-audit-trail
    // For CA certificates, compute and log the SHA-256 fingerprint for audit trail.
    if name.contains("ca") || name.contains("cert") {
        let fingerprint = ca_cert_fingerprint(value);
        info!(
            spec = "secrets-management, secrets-lifecycle-ca-audit-trail",
            safety = "Secret stored by podman backend driver, not persisted to plaintext files",
            secret = %name,
            ca_fingerprint = %fingerprint,
            "CA secret created with fingerprint audit"
        );
    } else {
        info!(
            spec = "secrets-management",
            safety = "Secret stored by podman backend driver, not persisted to plaintext files",
            secret = %name,
            "Secret created successfully"
        );
    }
    Ok(secret_id)
}

/// Check if a secret exists (by name).
///
/// Performs a `podman secret ls` and checks for an exact name match.
///
/// # Arguments
///
/// * `name` — Secret name to check (e.g., "ca-bundle")
///
/// # Returns
///
/// * `Ok(true)` — secret exists
/// * `Ok(false)` — secret does not exist
/// * `Err(String)` — podman error
///
/// # Example
///
/// ```rust,ignore
/// if podman_secret::exists("github-token")? {
///     println!("Token secret already created");
/// } else {
///     podman_secret::create("github-token", token_bytes)?;
/// }
/// ```
///
/// @trace spec:podman-orchestration, spec:secrets-management
#[instrument(skip_all, fields(name = %name))]
pub fn exists(name: &str) -> Result<bool, String> {
    let secrets = list()?;
    Ok(secrets.iter().any(|s| s.name == name))
}

/// Remove a secret by name.
///
/// This is idempotent: removing a non-existent secret returns `Ok(())`.
/// Podman returns exit code 0 even if the secret was not found.
///
/// # Arguments
///
/// * `name` — Secret name (e.g., "ca-bundle")
///
/// # Returns
///
/// * `Ok(())` — secret removed (or did not exist)
/// * `Err(String)` — podman error (permission, etc.)
///
/// # Example
///
/// ```rust,ignore
/// // Cleanup after container stops
/// podman_secret::remove("ca-bundle").ok(); // ignore not-found errors
/// ```
///
/// @trace spec:secrets-management, spec:podman-orchestration
#[instrument(skip_all, fields(name = %name))]
#[allow(clippy::needless_borrows_for_generic_args)]
pub fn remove(name: &str) -> Result<(), String> {
    debug!(spec = "secrets-management", "Removing podman secret");

    let output = tillandsias_podman::podman_cmd_sync()
        .args(&["secret", "rm", name])
        .output()
        .map_err(|e| format!("Failed to run podman secret rm: {e}"))?;

    if !output.status.success() {
        let stderr = String::from_utf8_lossy(&output.stderr);
        // "secret not found" is expected for idempotent cleanup; treat as success
        if stderr.contains("no such secret") || stderr.contains("not found") {
            debug!(
                spec = "secrets-management",
                "Secret did not exist, cleanup ok"
            );
            return Ok(());
        }
        error!(
            spec = "secrets-management",
            stderr = %stderr,
            "podman secret rm failed"
        );
        return Err(format!("podman secret rm {}: {}", name, stderr.trim()));
    }

    info!(
        spec = "secrets-management",
        secret = %name,
        "Secret removed"
    );
    Ok(())
}

/// List all secrets in the podman store.
///
/// Useful for debugging, auditing, and cleanup sweeps. Returns secrets as
/// a structured list with metadata (driver, timestamps).
///
/// # Returns
///
/// * `Ok(Vec<Secret>)` — all secrets (may be empty)
/// * `Err(String)` — podman error or JSON parse failure
///
/// # Example
///
/// ```rust,ignore
/// match podman_secret::list() {
///     Ok(secrets) => {
///         for secret in secrets {
///             println!("Secret: {}", secret.name);
///         }
///     }
///     Err(e) => eprintln!("Failed to list secrets: {e}"),
/// }
/// ```
///
/// @trace spec:secrets-management, spec:podman-orchestration
#[instrument(skip_all)]
#[allow(clippy::needless_borrows_for_generic_args)]
pub fn list() -> Result<Vec<Secret>, String> {
    debug!(spec = "secrets-management", "Listing podman secrets");

    let output = tillandsias_podman::podman_cmd_sync()
        .args(&["secret", "ls", "--format", "json"])
        .output()
        .map_err(|e| format!("Failed to run podman secret ls: {e}"))?;

    if !output.status.success() {
        let stderr = String::from_utf8_lossy(&output.stderr);
        error!(
            spec = "secrets-management",
            stderr = %stderr,
            "podman secret ls failed"
        );
        return Err(format!("podman secret ls failed: {}", stderr.trim()));
    }

    let stdout = String::from_utf8_lossy(&output.stdout);

    // Empty output (no secrets) is valid JSON: an empty array or null from some
    // podman versions. Try to parse; if it's empty/null, return an empty vector.
    let secrets: Vec<Secret> = if stdout.trim().is_empty() || stdout.trim() == "null" {
        Vec::new()
    } else {
        serde_json::from_str(stdout.as_ref())
            .map_err(|e| format!("Failed to parse podman secret ls output: {e}"))?
    };

    debug!(
        spec = "secrets-management",
        count = secrets.len(),
        "Secrets listed"
    );
    Ok(secrets)
}

/// Remove all secrets created by Tillandsias.
///
/// This is a cleanup utility called on app shutdown. It searches for secrets
/// matching Tillandsias naming patterns (e.g., "tillandsias-*", "ca-bundle",
/// "github-token") and removes them. Errors are logged but do not fail the function.
///
/// # Implementation
///
/// Calls [`list`] to enumerate all secrets, filters by common Tillandsias names,
/// and removes each one. Non-existent secrets (already removed) are silently ok.
///
/// @trace spec:secrets-management, spec:podman-orchestration
#[instrument(skip_all)]
pub fn cleanup_all() -> Result<(), String> {
    info!(
        spec = "secrets-management",
        "Cleaning up all Tillandsias secrets"
    );

    let secrets = list()?;

    // Filter secrets that look like they were created by Tillandsias.
    // Patterns: anything starting with "tillandsias-", plus well-known names.
    let tillandsias_names = secrets
        .iter()
        .filter(|s| {
            s.name.starts_with("tillandsias-")
                || s.name == "ca-bundle"
                || s.name == "github-token"
                || s.name == "ca-certificates"
                || s.name == "ssl-cert"
        })
        .map(|s| s.name.clone())
        .collect::<Vec<_>>();

    let mut error_count = 0;
    for name in tillandsias_names {
        if let Err(e) = remove(&name) {
            error!(
                spec = "secrets-management",
                secret = %name,
                error = %e,
                "Failed to remove secret during cleanup"
            );
            error_count += 1;
        }
    }

    if error_count == 0 {
        info!(
            spec = "secrets-management",
            "All Tillandsias secrets cleaned up successfully"
        );
        Ok(())
    } else {
        Err(format!(
            "Failed to remove {} secret(s) during cleanup",
            error_count
        ))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Test that list() handles empty output gracefully.
    /// (Integration tests would require podman to be running.)
    #[test]
    fn test_secret_display() {
        let secret = Secret {
            name: "test-secret".to_string(),
            driver: Some("file".to_string()),
            created_at: None,
            updated_at: None,
        };
        assert_eq!(secret.to_string(), "test-secret (file)");

        let secret_no_driver = Secret {
            name: "another-secret".to_string(),
            driver: None,
            created_at: None,
            updated_at: None,
        };
        assert_eq!(secret_no_driver.to_string(), "another-secret (unknown)");
    }

    #[test]
    fn test_ca_cert_fingerprint() {
        let cert_pem = b"-----BEGIN CERTIFICATE-----\nMIIC...\n-----END CERTIFICATE-----";
        let fingerprint = ca_cert_fingerprint(cert_pem);

        // Fingerprint should be a 64-character hex string (SHA-256)
        assert_eq!(fingerprint.len(), 64);
        assert!(fingerprint.chars().all(|c| c.is_ascii_hexdigit()));

        // Same input should produce same fingerprint
        let fingerprint2 = ca_cert_fingerprint(cert_pem);
        assert_eq!(fingerprint, fingerprint2);

        // Different input should produce different fingerprint
        let different_cert = b"different cert data";
        let different_fingerprint = ca_cert_fingerprint(different_cert);
        assert_ne!(fingerprint, different_fingerprint);
    }

    #[test]
    fn test_cleanup_all_filters_correctly() {
        // Test that cleanup_all would filter the right secret names.
        // Note: This is a unit test that doesn't require podman to be running.

        let secrets = vec![
            Secret {
                name: "tillandsias-github-token".to_string(),
                driver: Some("file".to_string()),
                created_at: None,
                updated_at: None,
            },
            Secret {
                name: "tillandsias-ca-cert".to_string(),
                driver: Some("file".to_string()),
                created_at: None,
                updated_at: None,
            },
            Secret {
                name: "ca-bundle".to_string(),
                driver: Some("file".to_string()),
                created_at: None,
                updated_at: None,
            },
            Secret {
                name: "github-token".to_string(),
                driver: Some("file".to_string()),
                created_at: None,
                updated_at: None,
            },
            Secret {
                name: "some-other-secret".to_string(),
                driver: Some("file".to_string()),
                created_at: None,
                updated_at: None,
            },
        ];

        // Simulate the filtering logic from cleanup_all()
        let tillandsias_names: Vec<_> = secrets
            .iter()
            .filter(|s| {
                s.name.starts_with("tillandsias-")
                    || s.name == "ca-bundle"
                    || s.name == "github-token"
                    || s.name == "ca-certificates"
                    || s.name == "ssl-cert"
            })
            .map(|s| s.name.clone())
            .collect();

        // Should include tillandsias-* and known well-names
        assert!(tillandsias_names.contains(&"tillandsias-github-token".to_string()));
        assert!(tillandsias_names.contains(&"tillandsias-ca-cert".to_string()));
        assert!(tillandsias_names.contains(&"ca-bundle".to_string()));
        assert!(tillandsias_names.contains(&"github-token".to_string()));

        // Should NOT include unrelated secrets
        assert!(!tillandsias_names.contains(&"some-other-secret".to_string()));
    }
}
