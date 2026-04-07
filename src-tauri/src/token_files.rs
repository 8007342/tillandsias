//! Per-container token file management on tmpfs.
//!
//! Manages GitHub OAuth tokens as files on tmpfs (RAM-backed filesystem)
//! for secure injection into containers via bind mount. Tokens are never
//! written to persistent storage.
//!
//! # Token file location
//!
//! ```text
//! $XDG_RUNTIME_DIR/tillandsias/tokens/<container-name>/github_token
//! ```
//!
//! - `$XDG_RUNTIME_DIR` is guaranteed tmpfs on systemd-based systems
//! - Falls back to `$TMPDIR` on macOS (also tmpfs-backed)
//! - Falls back to system temp dir on other platforms
//!
//! # Lifecycle
//!
//! 1. **Write**: Before container launch, token is written atomically
//! 2. **Mount**: Token file is bind-mounted read-only at `/run/secrets/github_token`
//! 3. **Refresh**: Every 55 minutes, token is re-read from keyring and rewritten
//! 4. **Delete**: On container stop, token file and directory are removed
//! 5. **Cleanup**: On app exit (or panic), all token files are removed
//!
//! @trace spec:secret-rotation

use std::fs;
use std::path::PathBuf;

#[cfg(unix)]
use std::os::unix::fs::PermissionsExt;

use tracing::{debug, info, warn};

/// Resolve the tmpfs-backed base directory for token files.
///
/// Resolution order:
/// 1. `$XDG_RUNTIME_DIR/tillandsias/tokens/` (Linux, guaranteed tmpfs)
/// 2. `$TMPDIR/tillandsias/tokens/` (macOS, usually tmpfs)
/// 3. Platform temp dir + `tillandsias/tokens/` (fallback)
pub fn token_dir() -> PathBuf {
    // Try XDG_RUNTIME_DIR first (Linux with systemd — guaranteed tmpfs)
    if let Ok(xdg) = std::env::var("XDG_RUNTIME_DIR") {
        let path = PathBuf::from(xdg);
        if path.exists() {
            return path.join("tillandsias").join("tokens");
        }
    }

    // Try TMPDIR (macOS — usually tmpfs-backed)
    if let Ok(tmpdir) = std::env::var("TMPDIR") {
        let path = PathBuf::from(tmpdir);
        if path.exists() {
            return path.join("tillandsias").join("tokens");
        }
    }

    // Fallback: platform temp dir with user isolation via $USER
    let mut base = std::env::temp_dir();
    if let Ok(user) = std::env::var("USER") {
        base = base.join(format!("tillandsias-{user}"));
    } else {
        base = base.join("tillandsias");
    }
    base.join("tokens")
}

/// Write a GitHub token to the tmpfs-backed token file for a container.
///
/// Creates the directory `<token_dir>/<container_name>/` with mode 0700,
/// writes the token atomically (write to `.tmp`, rename), and sets mode 0600.
///
/// Returns the full path to the token file on success.
///
/// @trace spec:secret-rotation
pub fn write_token(container_name: &str, token: &str) -> Result<PathBuf, String> {
    let base = token_dir();
    let container_dir = base.join(container_name);

    // Create container-specific directory with mode 0700
    fs::create_dir_all(&container_dir)
        .map_err(|e| format!("Cannot create token directory {}: {e}", container_dir.display()))?;

    #[cfg(unix)]
    if let Err(e) = fs::set_permissions(&container_dir, fs::Permissions::from_mode(0o700)) {
        warn!(
            accountability = true,
            category = "secrets",
            spec = "secret-management",
            error = %e,
            "Token directory permissions not set to 0700 — may be world-readable"
        );
    }

    let token_path = container_dir.join("github_token");
    let tmp_path = container_dir.join("github_token.tmp");

    // Write to temp file first
    fs::write(&tmp_path, token)
        .map_err(|e| format!("Cannot write token temp file: {e}"))?;

    // Set mode 0600 on temp file before rename
    #[cfg(unix)]
    fs::set_permissions(&tmp_path, fs::Permissions::from_mode(0o600))
        .map_err(|e| format!("Cannot set token file permissions: {e}"))?;

    // Atomic rename (POSIX guarantees atomicity on same filesystem)
    fs::rename(&tmp_path, &token_path)
        .map_err(|e| {
            // Clean up temp file on rename failure
            let _ = fs::remove_file(&tmp_path);
            format!("Cannot rename token file: {e}")
        })?;

    info!(
        target: "secrets",
        accountability = true,
        category = "secrets",
        spec = "secret-rotation",
        "Token file written for {container_name} \u{2192} tmpfs ({path}), mounted ro",
        path = token_path.display(),
    );

    Ok(token_path)
}

/// Read the token for a container, if it exists.
#[allow(dead_code)]
pub fn read_token(container_name: &str) -> Option<String> {
    let path = token_dir().join(container_name).join("github_token");
    fs::read_to_string(path).ok()
}

/// Delete the token file and directory for a specific container.
///
/// Best-effort: no error if already gone.
///
/// @trace spec:secret-rotation
pub fn delete_token(container_name: &str) {
    let container_dir = token_dir().join(container_name);
    if container_dir.exists() {
        if let Err(e) = fs::remove_dir_all(&container_dir) {
            warn!(
                target: "secrets",
                container = %container_name,
                error = %e,
                "Failed to delete token directory (best-effort)"
            );
        } else {
            info!(
                target: "secrets",
                accountability = true,
                category = "secrets",
                spec = "secret-rotation",
                "Token revoked for {container_name} (container stopped)",
            );
        }
    }
}

/// Delete all token files for all containers.
///
/// Removes the entire `<token_dir>/` tree. Called on app exit.
///
/// @trace spec:secret-rotation
pub fn delete_all_tokens() {
    let base = token_dir();
    if !base.exists() {
        return;
    }

    // Count files before deletion for accountability logging
    let count = fs::read_dir(&base)
        .map(|entries| entries.count())
        .unwrap_or(0);

    if let Err(e) = fs::remove_dir_all(&base) {
        warn!(
            target: "secrets",
            error = %e,
            "Failed to delete all token files on exit (best-effort)"
        );
    } else {
        info!(
            target: "secrets",
            accountability = true,
            category = "secrets",
            spec = "secret-rotation",
            "All token files cleaned up (app exit, {count} containers)",
        );
    }
}

/// Guard that calls `delete_all_tokens()` on drop.
///
/// Ensures cleanup even on panic. Create early in `main()` and hold
/// for the lifetime of the application.
pub struct TokenCleanupGuard;

impl Drop for TokenCleanupGuard {
    fn drop(&mut self) {
        debug!(target: "secrets", "TokenCleanupGuard dropping — cleaning up all token files");
        delete_all_tokens();
    }
}

/// Check whether the token directory is on tmpfs.
///
/// Returns `true` if `$XDG_RUNTIME_DIR` is set and writable (Linux),
/// or `$TMPDIR` is set (macOS). Used to decide whether to warn about
/// fallback to non-tmpfs storage.
#[allow(dead_code)]
pub fn is_tmpfs_available() -> bool {
    if let Ok(xdg) = std::env::var("XDG_RUNTIME_DIR") {
        let path = PathBuf::from(xdg);
        return path.exists() && path.is_dir();
    }
    if let Ok(tmpdir) = std::env::var("TMPDIR") {
        let path = PathBuf::from(tmpdir);
        return path.exists() && path.is_dir();
    }
    false
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

#[cfg(test)]
mod tests {
    use super::*;
    use std::fs;
    use std::sync::Mutex;

    /// Guards tests that share `token_dir()` — `delete_all_tokens()` removes
    /// the entire base directory, so it must not run concurrently with writes.
    static TOKEN_DIR_LOCK: Mutex<()> = Mutex::new(());

    /// Helper: create a temporary token directory for testing.
    fn test_token_dir() -> PathBuf {
        let dir = std::env::temp_dir()
            .join("tillandsias-test-tokens")
            .join(format!("{}", std::process::id()));
        let _ = fs::remove_dir_all(&dir);
        fs::create_dir_all(&dir).unwrap();
        dir
    }

    #[test]
    fn token_dir_resolves() {
        let dir = token_dir();
        assert!(
            dir.to_string_lossy().contains("tillandsias"),
            "Token dir should contain 'tillandsias': {}",
            dir.display()
        );
        assert!(
            dir.to_string_lossy().contains("tokens"),
            "Token dir should contain 'tokens': {}",
            dir.display()
        );
    }

    #[test]
    fn write_and_read_token() {
        let _guard = TOKEN_DIR_LOCK.lock().unwrap();
        let container = format!("test-container-{}", std::process::id());
        let token = "gho_test_token_12345";

        // Write
        let path = write_token(&container, token).expect("write_token should succeed");
        assert!(path.exists(), "Token file should exist after write");

        // Read
        let content = fs::read_to_string(&path).unwrap();
        assert_eq!(content, token);

        // Read via public API
        let read_back = read_token(&container);
        assert_eq!(read_back, Some(token.to_string()));

        // Verify permissions (Unix only)
        #[cfg(unix)]
        {
            let meta = fs::metadata(&path).unwrap();
            let mode = meta.permissions().mode() & 0o777;
            assert_eq!(mode, 0o600, "Token file should have mode 0600");

            let dir_meta = fs::metadata(path.parent().unwrap()).unwrap();
            let dir_mode = dir_meta.permissions().mode() & 0o777;
            assert_eq!(dir_mode, 0o700, "Token directory should have mode 0700");
        }

        // Cleanup
        delete_token(&container);
        assert!(!path.exists(), "Token file should be gone after delete");
    }

    #[test]
    fn delete_nonexistent_is_noop() {
        // Should not panic or error
        delete_token("nonexistent-container-12345");
    }

    #[test]
    fn write_overwrites_existing() {
        let _guard = TOKEN_DIR_LOCK.lock().unwrap();
        let container = format!("test-overwrite-{}", std::process::id());

        write_token(&container, "first_token").unwrap();
        let path = write_token(&container, "second_token").unwrap();

        let content = fs::read_to_string(&path).unwrap();
        assert_eq!(content, "second_token");

        delete_token(&container);
    }

    #[test]
    fn delete_all_removes_everything() {
        let _guard = TOKEN_DIR_LOCK.lock().unwrap();
        let c1 = format!("test-all-1-{}", std::process::id());
        let c2 = format!("test-all-2-{}", std::process::id());

        let p1 = write_token(&c1, "token1").unwrap();
        let p2 = write_token(&c2, "token2").unwrap();
        assert!(p1.exists());
        assert!(p2.exists());

        delete_all_tokens();
        assert!(!p1.exists());
        assert!(!p2.exists());
    }
}
