//! Native secret store integration.
//!
//! Stores and retrieves the GitHub OAuth token using the host OS's native
//! secret service (GNOME Keyring on Linux, Keychain on macOS, Credential
//! Manager on Windows) via the `keyring` crate.
//!
//! Credentials reach containers exclusively via D-Bus session bus forwarding
//! to the host keyring. The git service container is the only D-Bus consumer;
//! forge/terminal containers have zero credential access.
//!
//! If D-Bus is unavailable, git operations fail explicitly rather than falling
//! back to less-secure mechanisms.
//!
//! # Keyring entry
//!
//!   Service: `tillandsias`
//!   Key:     `github-oauth-token`
//!
//! @trace spec:native-secrets-store

use tracing::{debug, info, info_span, trace};

/// Keyring service name.
const SERVICE: &str = "tillandsias";

/// Keyring entry key for the GitHub OAuth token.
const GITHUB_TOKEN_KEY: &str = "github-oauth-token";

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
///
/// D-Bus is the sole credential path. If the keyring is unavailable,
/// this returns `Err` — callers should let git operations fail explicitly
/// rather than falling back to less-secure mechanisms.
///
/// @trace spec:native-secrets-store, spec:secret-management
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
            debug!("No GitHub token in native keyring");
            Ok(None)
        }
        Err(e) => {
            Err(format!("Keyring unavailable: {e}"))
        }
    }
}
