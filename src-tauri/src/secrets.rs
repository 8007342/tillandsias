//! Native secret store + ephemeral token delivery.
//!
//! Tillandsias stores the GitHub OAuth token exclusively in the host OS's
//! native secret store via the `keyring` crate:
//!
//!   - Linux:   libsecret → Secret Service D-Bus API → GNOME Keyring / KDE Wallet
//!   - macOS:   Keychain Services (Security framework)
//!   - Windows: Credential Manager (Wincred, `CredWriteW`)
//!
//! The host Rust process is the sole consumer of the keyring. Containers
//! never see D-Bus, the keyring API, or any host credential beyond a
//! single ephemeral file this module writes immediately before launch
//! and unlinks when the container stops.
//!
//! # Keyring entry
//!
//!   Service: `tillandsias`
//!   Key:     `github-oauth-token`
//!
//! # Token-file delivery
//!
//! At container launch, `prepare_token_file(container_name)` reads the
//! keyring, writes the token to a per-container ephemeral file under
//! `token_file_root()/<container-name>/github_token` (mode `0600` on Unix;
//! per-user NTFS ACL on Windows), and returns the path. The caller puts
//! that path into `LaunchContext::token_file_path`; `build_podman_args`
//! bind-mounts it read-only at `/run/secrets/github_token`.
//!
//! When the container stops (or Tillandsias exits), the orchestrator calls
//! `cleanup_token_file(container_name)` to unlink the file and its parent
//! directory. `cleanup_all_token_files()` sweeps the whole tree on app exit.
//!
//! @trace spec:native-secrets-store, spec:secrets-management

use std::path::{Path, PathBuf};

use tracing::{debug, info, info_span, trace, warn};

/// Keyring service name.
const SERVICE: &str = "tillandsias";

/// Keyring entry key for the GitHub OAuth token.
const GITHUB_TOKEN_KEY: &str = "github-oauth-token";

// @trace spec:native-secrets-store, knowledge:infra/os-keyring
/// Store the GitHub OAuth token in the native keyring.
///
/// Returns `Ok(())` on success. Returns `Err` if the keyring is unavailable —
/// the caller should refuse to proceed rather than fall back.
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
        "Token written via keyring crate to the platform-native secret store"
    );
    Ok(())
}

/// Retrieve the GitHub OAuth token from the native keyring.
///
/// Returns `Ok(Some(token))` if found, `Ok(None)` if no entry exists,
/// `Err` if the keyring itself is unavailable. Callers must surface
/// `Err` honestly — there is no fallback credential path.
///
/// @trace spec:native-secrets-store, spec:secrets-management
pub fn retrieve_github_token() -> Result<Option<String>, String> {
    let _span = info_span!("retrieve_github_token", accountability = true, category = "secrets").entered();
    let entry = keyring::Entry::new(SERVICE, GITHUB_TOKEN_KEY)
        .map_err(|e| format!("Failed to create keyring entry: {e}"))?;
    match entry.get_password() {
        Ok(token) => {
            info!(
                accountability = true,
                category = "secrets",
                safety = "Retrieved from OS keyring in-process, never written to disk",
                spec = "native-secrets-store",
                "GitHub token retrieved from OS keyring"
            );
            Ok(Some(token))
        }
        Err(keyring::Error::NoEntry) => {
            debug!("No GitHub token in native keyring");
            Ok(None)
        }
        Err(e) => Err(format!("Keyring unavailable: {e}")),
    }
}

/// Delete the GitHub OAuth token from the native keyring (logout).
///
/// Idempotent: `Ok(())` if the entry did not exist.
#[allow(dead_code)] // API surface — future logout flow
pub fn delete_github_token() -> Result<(), String> {
    let entry = keyring::Entry::new(SERVICE, GITHUB_TOKEN_KEY)
        .map_err(|e| format!("Failed to create keyring entry: {e}"))?;
    match entry.delete_credential() {
        Ok(()) => {
            info!(
                accountability = true,
                category = "secrets",
                safety = "Token removed from OS keyring",
                spec = "native-secrets-store",
                "GitHub token deleted from native keyring"
            );
            Ok(())
        }
        Err(keyring::Error::NoEntry) => Ok(()),
        Err(e) => Err(format!("Failed to delete token: {e}")),
    }
}

// ---------------------------------------------------------------------------
// Ephemeral token file delivery
// ---------------------------------------------------------------------------

/// Root directory for per-container token files.
///
/// - Linux:   `$XDG_RUNTIME_DIR/tillandsias/tokens/` (real tmpfs)
/// - macOS:   `$TMPDIR/tillandsias-tokens/` (per-user tmpfs under /var/folders)
/// - Windows: `%LOCALAPPDATA%\Temp\tillandsias-tokens\` (per-user NTFS —
///            not literal tmpfs, but user-scoped and swept on cleanup)
fn token_file_root() -> PathBuf {
    #[cfg(target_os = "linux")]
    {
        if let Ok(xdg) = std::env::var("XDG_RUNTIME_DIR") {
            return PathBuf::from(xdg).join("tillandsias").join("tokens");
        }
    }
    std::env::temp_dir().join("tillandsias-tokens")
}

/// Returns the token-file path for a given container (no I/O).
fn token_file_path(container_name: &str) -> PathBuf {
    token_file_root().join(container_name).join("github_token")
}

/// Read the token from the OS keyring and write it to an ephemeral file
/// ready for bind-mount into `container_name`.
///
/// Returns `Ok(Some(path))` on success, `Ok(None)` if the keyring has no
/// token (user hasn't run `--github-login` yet — the caller should let
/// authenticated git operations fail with a clear message), and `Err` if
/// the keyring is unreachable or the file write fails.
///
/// The file is written atomically: content goes to `<path>.tmp`, then
/// renamed into place. On Unix, the file mode is `0600` and the parent
/// directory mode is `0700`. On Windows, NTFS inherits the per-user ACL
/// from `%LOCALAPPDATA%` which is already user-scoped.
///
/// @trace spec:secrets-management, spec:native-secrets-store, spec:secret-rotation
pub fn prepare_token_file(container_name: &str) -> Result<Option<PathBuf>, String> {
    let token = match retrieve_github_token()? {
        Some(t) => t,
        None => return Ok(None),
    };

    let final_path = token_file_path(container_name);
    let parent = final_path.parent().expect("token path always has parent");

    std::fs::create_dir_all(parent).map_err(|e| {
        format!("Cannot create token dir {}: {e}", parent.display())
    })?;
    secure_dir(parent)?;

    let tmp_path = parent.join("github_token.tmp");
    write_secure(&tmp_path, token.as_bytes())?;

    // Atomic rename onto final path (overwrites any stale file).
    std::fs::rename(&tmp_path, &final_path).map_err(|e| {
        let _ = std::fs::remove_file(&tmp_path);
        format!("Atomic rename of token file failed: {e}")
    })?;

    info!(
        accountability = true,
        category = "secrets",
        safety = "Token written to ephemeral per-container file for :ro bind-mount; unlinked on container stop",
        spec = "secrets-management",
        container = %container_name,
        path = %final_path.display(),
        "Prepared ephemeral token file for container launch"
    );
    Ok(Some(final_path))
}

/// Remove the ephemeral token file for `container_name` and its parent dir.
/// Idempotent; silent-ok if nothing is there.
///
/// @trace spec:secrets-management, spec:secret-rotation
pub fn cleanup_token_file(container_name: &str) {
    let path = token_file_path(container_name);
    if let Err(e) = std::fs::remove_file(&path) {
        if e.kind() != std::io::ErrorKind::NotFound {
            warn!(
                spec = "secrets-management",
                container = %container_name,
                error = %e,
                "Token file unlink failed — may leak briefly until app exit sweep"
            );
        }
    }
    if let Some(parent) = path.parent() {
        let _ = std::fs::remove_dir(parent);
    }
    debug!(
        spec = "secrets-management",
        container = %container_name,
        "Ephemeral token file swept"
    );
}

/// Remove the entire per-container token directory tree. Called on app exit
/// / Drop guard / panic cleanup so no leftover secret file survives a crash.
///
/// @trace spec:secrets-management
#[allow(dead_code)] // wired into shutdown cleanup
pub fn cleanup_all_token_files() {
    let root = token_file_root();
    if root.exists() {
        if let Err(e) = std::fs::remove_dir_all(&root) {
            warn!(
                spec = "secrets-management",
                path = %root.display(),
                error = %e,
                "Failed to sweep token directory on shutdown"
            );
        } else {
            info!(
                accountability = true,
                category = "secrets",
                spec = "secrets-management",
                "All ephemeral token files cleaned on shutdown"
            );
        }
    }
}

/// Set `0700` on a directory (Unix). No-op on Windows (relies on
/// `%LOCALAPPDATA%` per-user ACL).
fn secure_dir(path: &Path) -> Result<(), String> {
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        let mut perm = std::fs::metadata(path)
            .map_err(|e| format!("stat {}: {e}", path.display()))?
            .permissions();
        perm.set_mode(0o700);
        std::fs::set_permissions(path, perm)
            .map_err(|e| format!("chmod 0700 {}: {e}", path.display()))?;
    }
    #[cfg(not(unix))]
    {
        let _ = path;
    }
    Ok(())
}

/// Write bytes to `path`, creating with mode `0600` (Unix). On Windows the
/// file inherits the per-user ACL of the parent directory.
fn write_secure(path: &Path, content: &[u8]) -> Result<(), String> {
    use std::io::Write;
    // Open with explicit restrictive mode on Unix. std::fs::File::create on
    // Windows simply honors the parent ACL.
    #[cfg(unix)]
    let mut f = {
        use std::os::unix::fs::OpenOptionsExt;
        std::fs::OpenOptions::new()
            .create(true)
            .truncate(true)
            .write(true)
            .mode(0o600)
            .open(path)
            .map_err(|e| format!("create {}: {e}", path.display()))?
    };
    #[cfg(not(unix))]
    let mut f = std::fs::OpenOptions::new()
        .create(true)
        .truncate(true)
        .write(true)
        .open(path)
        .map_err(|e| format!("create {}: {e}", path.display()))?;

    f.write_all(content)
        .map_err(|e| format!("write {}: {e}", path.display()))?;
    f.sync_all()
        .map_err(|e| format!("fsync {}: {e}", path.display()))?;
    Ok(())
}
