//! Per-launch forge swap — the tray half of order 1376-8zdz.
//!
//! Operator ruling 2026-09-26: "a new swapfile every launch … thrown away and
//! deleted on shutdown". The root half (scripts/forge-swap/, installed once by
//! `sudo bash scripts/install-forge-swap-service.sh`) provides a
//! `tillandsias-swap@<id>.service` template that a polkit rule lets this user
//! start and stop without a password. This module brackets ONE attached forge
//! launch with it:
//!
//!   1. open `/run/user/<uid>/tillandsias/swap-<id>.lease` and hold an
//!      exclusive `flock` on it for the life of the launch — the root gc timer
//!      stops any instance whose lease it can take, so a `kill -9` of this
//!      process frees the swap within one gc period;
//!   2. `systemctl --no-ask-password start tillandsias-swap@<id>.service`;
//!   3. on drop (the attached container has exited): `systemctl stop`, then
//!      release and remove the lease.
//!
//! NEVER BLOCKS A LAUNCH. Not installed, polkit refusal, a failed start: each
//! prints one named `[tillandsias] swap:` line and the forge runs without a
//! disk swapfile, exactly as it did before this module existed.
//!
//! The instance id is derived here, never taken from input, and always matches
//! the helper's `[A-Za-z0-9-]{1,64}` (a mismatch would be refused there).
// @trace order:1376-8zdz, spec:forge-memory-swap

use std::path::{Path, PathBuf};

pub(crate) const TEMPLATE: &str = "/etc/systemd/system/tillandsias-swap@.service";
pub(crate) const INSTALL_CMD: &str = "sudo bash scripts/install-forge-swap-service.sh";

/// Derive the instance id from the container name and this process: every
/// char outside `[A-Za-z0-9-]` becomes `-`, and the result is capped at 64
/// with the pid kept, so two launches of one name cannot share an instance.
pub(crate) fn instance_id(container_name: &str, pid: u32) -> String {
    let suffix = format!("-{pid}");
    let mut base: String = container_name
        .chars()
        .map(|c| {
            if c.is_ascii_alphanumeric() || c == '-' {
                c
            } else {
                '-'
            }
        })
        .collect();
    base.truncate(64 - suffix.len());
    let base = if base.is_empty() {
        "forge".to_string()
    } else {
        base
    };
    format!("{base}{suffix}")
}

fn lease_dir() -> PathBuf {
    std::env::var_os("XDG_RUNTIME_DIR")
        .map(PathBuf::from)
        .unwrap_or_else(|| PathBuf::from(format!("/run/user/{}", unsafe { libc::getuid() })))
        .join("tillandsias")
}

/// Held for the life of one attached launch; dropping it stops the swap.
pub(crate) struct SwapLease {
    unit: String,
    lease_path: PathBuf,
    _lock: std::fs::File,
    debug: bool,
}

fn systemctl(verb: &str, unit: &str) -> Result<(), String> {
    let out = std::process::Command::new("systemctl")
        .args(["--no-ask-password", verb, unit])
        .output()
        .map_err(|e| format!("systemctl {verb}: {e}"))?;
    if out.status.success() {
        Ok(())
    } else {
        Err(String::from_utf8_lossy(&out.stderr).trim().to_string())
    }
}

/// Take the lease and start this launch's swap instance, or say why not.
pub(crate) fn acquire(container_name: &str, debug: bool) -> Option<SwapLease> {
    if !Path::new(TEMPLATE).exists() {
        eprintln!(
            "[tillandsias] swap: per-launch swap not installed — the forge runs without a \
             disk swapfile. One-time, to enable it: {INSTALL_CMD} (1376-8zdz)"
        );
        return None;
    }
    let id = instance_id(container_name, std::process::id());
    let unit = format!("tillandsias-swap@{id}.service");
    let dir = lease_dir();
    if let Err(e) = std::fs::create_dir_all(&dir) {
        eprintln!(
            "[tillandsias] swap: skipped — cannot create {}: {e}",
            dir.display()
        );
        return None;
    }
    let lease_path = dir.join(format!("swap-{id}.lease"));
    let lock = match std::fs::OpenOptions::new()
        .create(true)
        .truncate(false)
        .write(true)
        .open(&lease_path)
    {
        Ok(f) => f,
        Err(e) => {
            eprintln!(
                "[tillandsias] swap: skipped — lease {}: {e}",
                lease_path.display()
            );
            return None;
        }
    };
    use std::os::fd::AsRawFd;
    if unsafe { libc::flock(lock.as_raw_fd(), libc::LOCK_EX | libc::LOCK_NB) } != 0 {
        eprintln!(
            "[tillandsias] swap: skipped — lease {} is held by another process",
            lease_path.display()
        );
        return None;
    }
    if let Err(e) = systemctl("start", &unit) {
        let _ = std::fs::remove_file(&lease_path);
        eprintln!(
            "[tillandsias] swap: skipped — `systemctl start {unit}` refused: {e}. The forge runs \
             without a disk swapfile. If this says authentication is required, the polkit rule \
             is missing: {INSTALL_CMD}"
        );
        return None;
    }
    eprintln!("[tillandsias] swap: {unit} started (removed when this forge exits)");
    Some(SwapLease {
        unit,
        lease_path,
        _lock: lock,
        debug,
    })
}

impl Drop for SwapLease {
    fn drop(&mut self) {
        // Stop BEFORE releasing the lease: the gc must never see a free lease
        // for an instance this process is still tearing down.
        match systemctl("stop", &self.unit) {
            Ok(()) => {
                if self.debug {
                    eprintln!("[tillandsias] swap: {} stopped", self.unit);
                }
            }
            Err(e) => eprintln!(
                "[tillandsias] swap: `systemctl stop {}` failed: {e} — the gc timer will remove it",
                self.unit
            ),
        }
        let _ = std::fs::remove_file(&self.lease_path);
        // the flock is released when `_lock` closes, after this body
    }
}

#[cfg(test)]
mod tests {
    use super::instance_id;

    fn valid(id: &str) -> bool {
        (1..=64).contains(&id.len()) && id.chars().all(|c| c.is_ascii_alphanumeric() || c == '-')
    }

    /// The id must always pass the root helper's [A-Za-z0-9-]{1,64}, whatever
    /// the container name — a mismatch would be refused there and the forge
    /// would silently run without swap.
    #[test]
    fn instance_ids_always_match_the_helpers_grammar() {
        let long = "x".repeat(200);
        for name in [
            "tillandsias-yoga-forge",
            "a b/../c",
            "ünïcödé_name.with.dots",
            "",
            long.as_str(),
        ] {
            let id = instance_id(name, 4_294_967_295);
            assert!(valid(&id), "{name:?} -> {id:?}");
            assert!(id.ends_with("-4294967295"), "{id}");
        }
        assert_eq!(
            instance_id("tillandsias-yoga-forge", 42),
            "tillandsias-yoga-forge-42"
        );
        assert_ne!(instance_id("same", 1), instance_id("same", 2));
    }
}
