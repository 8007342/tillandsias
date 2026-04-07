//! Native secret store integration.
//!
//! Stores and retrieves the GitHub OAuth token using the host OS's native
//! secret service (GNOME Keyring on Linux, Keychain on macOS, Credential
//! Manager on Windows) via the `keyring` crate.
//!
//! The `gh` CLI stores its token in `~/.cache/tillandsias/secrets/gh/hosts.yml`
//! as plain YAML. This module:
//!
//!   1. Reads the token from `hosts.yml` and stores it in the keyring
//!      (migration, runs once on first launch after upgrade).
//!   2. On every container launch, retrieves the token from the keyring
//!      and writes a fresh `hosts.yml` so the existing mount logic works.
//!   3. Falls back to the plain `hosts.yml` if the keyring is unavailable
//!      (headless, SSH, locked keyring).
//!
//! # Keyring entry
//!
//!   Service: `tillandsias`
//!   Key:     `github-oauth-token`
//!
//! @trace spec:native-secrets-store

use std::fs;
use std::path::PathBuf;

use tracing::{debug, info, info_span, trace, warn};

use tillandsias_core::config::cache_dir;

/// Keyring service name.
const SERVICE: &str = "tillandsias";

/// Keyring entry key for the GitHub OAuth token.
const GITHUB_TOKEN_KEY: &str = "github-oauth-token";


/// Path to the `hosts.yml` file in the secrets cache.
fn hosts_yml_path() -> PathBuf {
    cache_dir().join("secrets").join("gh").join("hosts.yml")
}

// @trace spec:native-secrets-store, knowledge:infra/os-keyring
/// Store the GitHub OAuth token in the native keyring.
///
/// Returns `Ok(())` on success. Returns `Err` if the keyring is
/// unavailable — the caller should log and fall back.
pub fn store_github_token(token: &str) -> Result<(), String> {
    let _span = info_span!("store_github_token", accountability = true, category = "secrets").entered();
    let entry = keyring::Entry::new(SERVICE, GITHUB_TOKEN_KEY)
        .map_err(|e| format!("Failed to create keyring entry: {e}"))?;
    entry
        .set_password(token)
        .map_err(|e| format!("Failed to store token in keyring: {e}"))?;
    info!(
        accountability = true,
        category = "secrets",
        safety = "Token stored in OS keyring, not written to disk",
        spec = "native-secrets-store",
        "GitHub token stored in native keyring"
    );
    trace!(
        spec = "native-secrets-store",
        "Token stored via keyring crate -> secret-service D-Bus API"
    );
    Ok(())
}

/// Retrieve the GitHub OAuth token from the native keyring.
///
/// Returns `Ok(Some(token))` if found, `Ok(None)` if no entry exists,
/// and `Err` if the keyring is unavailable.
pub fn retrieve_github_token() -> Result<Option<String>, String> {
    let _span = info_span!("retrieve_github_token", accountability = true, category = "secrets").entered();
    let entry = keyring::Entry::new(SERVICE, GITHUB_TOKEN_KEY)
        .map_err(|e| format!("Failed to create keyring entry: {e}"))?;
    match entry.get_password() {
        Ok(token) => {
            info!(
                accountability = true,
                category = "secrets",
                safety = "Retrieved via D-Bus session bus, never written to disk",
                spec = "native-secrets-store",
                "GitHub token retrieved from OS keyring"
            );
            trace!(
                spec = "native-secrets-store",
                "Token read via keyring crate -> secret-service D-Bus API"
            );
            Ok(Some(token))
        }
        Err(keyring::Error::NoEntry) => {
            debug!("No GitHub token in native keyring, checking hosts.yml fallback");
            // Fall back to reading hosts.yml directly (e.g., after gh auth login
            // before migration, or when keyring is unavailable on Windows).
            let path = hosts_yml_path();
            match fs::read_to_string(&path) {
                Ok(contents) => {
                    if let Some(token) = extract_token_from_hosts_yml(&contents) {
                        debug!("Found token in hosts.yml fallback");
                        Ok(Some(token))
                    } else {
                        Ok(None)
                    }
                }
                Err(_) => Ok(None),
            }
        }
        Err(e) => {
            debug!("Keyring error: {e}, checking hosts.yml fallback");
            let path = hosts_yml_path();
            match fs::read_to_string(&path) {
                Ok(contents) => Ok(extract_token_from_hosts_yml(&contents)),
                Err(_) => Ok(None),
            }
        }
    }
}


/// Extract the OAuth token from a `hosts.yml` file's contents.
///
/// The `gh` CLI writes `hosts.yml` in this format:
///
/// ```yaml
/// github.com:
///     oauth_token: gho_xxxxxxxxxxxx
///     user: username
///     git_protocol: https
/// ```
///
/// We do a simple line-based parse to avoid adding a YAML dependency.
fn extract_token_from_hosts_yml(contents: &str) -> Option<String> {
    for line in contents.lines() {
        let trimmed = line.trim();
        if let Some(rest) = trimmed.strip_prefix("oauth_token:") {
            let token = rest.trim().to_string();
            if !token.is_empty() {
                return Some(token);
            }
        }
    }
    None
}

/// Build a minimal `hosts.yml` contents from a bare token.
///
/// Produces the YAML that the `gh` CLI expects:
///
/// ```yaml
/// github.com:
///     oauth_token: <token>
///     git_protocol: https
/// ```
fn build_hosts_yml(token: &str) -> String {
    format!("github.com:\n    oauth_token: {token}\n    git_protocol: https\n")
}

/// Migrate an existing plain text token from `hosts.yml` into the native
/// keyring. No-op if:
///   - `hosts.yml` does not exist or is empty
///   - The keyring already contains a token
///   - The keyring is unavailable (logs a warning)
///
/// This is idempotent and safe to call on every startup.
pub fn migrate_token_to_keyring() {
    let _span = info_span!("migrate_token_to_keyring", accountability = true, category = "secrets").entered();
    let path = hosts_yml_path();

    // Read the hosts.yml file
    let contents = match fs::read_to_string(&path) {
        Ok(c) if !c.trim().is_empty() => c,
        _ => {
            debug!("No hosts.yml to migrate");
            return;
        }
    };

    // Extract the token
    let token = match extract_token_from_hosts_yml(&contents) {
        Some(t) => t,
        None => {
            debug!("hosts.yml exists but no oauth_token found");
            return;
        }
    };

    // Check if keyring already has a token
    match retrieve_github_token() {
        Ok(Some(_)) => {
            debug!("Keyring already has a GitHub token, skipping migration");
            return;
        }
        Ok(None) => {
            // Proceed with migration
        }
        Err(e) => {
            warn!("Keyring unavailable during migration check: {e}");
            return;
        }
    }

    // Store in keyring
    match store_github_token(&token) {
        Ok(()) => {
            info!(
                accountability = true,
                category = "secrets",
                safety = "Token moved from plain text file to OS keyring",
                spec = "native-secrets-store",
                "Migrated GitHub token from hosts.yml to native keyring"
            );
        }
        Err(e) => {
            warn!("Failed to migrate token to keyring: {e}");
        }
    }
}

/// Write (or refresh) `hosts.yml` from the native keyring.
///
/// Retrieves the token from the keyring and writes a fresh `hosts.yml`
/// to the secrets directory so containers can mount it. If the keyring
/// is unavailable or empty, the existing `hosts.yml` (if any) is left
/// untouched.
///
/// Call this before every `podman run` that needs GitHub credentials.
pub fn write_hosts_yml_from_keyring() {
    let _span = info_span!("write_hosts_yml_from_keyring", accountability = true, category = "secrets").entered();
    let token = match retrieve_github_token() {
        Ok(Some(t)) => t,
        Ok(None) => {
            debug!("No token in keyring; leaving hosts.yml as-is");
            return;
        }
        Err(e) => {
            warn!("Keyring unavailable: {e}; leaving hosts.yml as-is");
            return;
        }
    };

    let path = hosts_yml_path();

    // Ensure the parent directory exists
    if let Some(parent) = path.parent() {
        fs::create_dir_all(parent).ok();
    }

    let contents = build_hosts_yml(&token);
    match fs::write(&path, &contents) {
        Ok(()) => {
            info!(
                accountability = true,
                category = "secrets",
                safety = "Refreshed from keyring for container mount, overwritten on next launch",
                spec = "native-secrets-store",
                "hosts.yml refreshed from keyring for container launch"
            );
            trace!(
                spec = "native-secrets-store",
                "hosts.yml written to {} (bind-mounted into container as ro)",
                path.display()
            );
        }
        Err(e) => {
            warn!("Failed to write hosts.yml: {e}");
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn extract_token_standard_format() {
        let yml = "\
github.com:
    oauth_token: gho_abc123xyz
    user: testuser
    git_protocol: https
";
        assert_eq!(
            extract_token_from_hosts_yml(yml),
            Some("gho_abc123xyz".to_string())
        );
    }

    #[test]
    fn extract_token_no_token() {
        let yml = "\
github.com:
    user: testuser
    git_protocol: https
";
        assert_eq!(extract_token_from_hosts_yml(yml), None);
    }

    #[test]
    fn extract_token_empty_value() {
        let yml = "\
github.com:
    oauth_token:
    user: testuser
";
        assert_eq!(extract_token_from_hosts_yml(yml), None);
    }

    #[test]
    fn build_hosts_yml_format() {
        let result = build_hosts_yml("gho_test123");
        assert!(result.contains("oauth_token: gho_test123"));
        assert!(result.contains("github.com:"));
        assert!(result.contains("git_protocol: https"));
    }
}
