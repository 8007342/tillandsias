//! Order 1019-ivia — where the host stages the guest binary, declared once.
//!
//! WHY THIS MOVED. The staged binary lived at
//! `~/src/.tillandsias/guest-bin/tillandsias-headless` and reached the VM
//! through the `home-src` virtio-fs share. That share is what 997-e4v2 exists
//! to retire, and retiring it would have removed guest-binary delivery on
//! macOS silently — `fetch-headless.sh` installs FROM the staged path and only
//! falls back when the share is absent, so the symptom is a guest quietly
//! running an older headless, not an error.
//!
//! WHY NOT `config::state_dir()`. That helper resolves to
//! `~/Library/Logs/tillandsias` on macOS. A staged executable is not a log, and
//! the point of this move is a path whose meaning is the same on both sides of
//! the VM boundary. `${HOME}/.local/state/tillandsias` is the root 998-3z6g
//! measured and adopted for the CA bundle for exactly that reason: durable on a
//! rootless Linux host, and equally creatable in the guest where `HOME=/root`.
//! This follows that decision rather than inventing a second answer to the same
//! question.
//!
//! DECLARED ONCE, in the spirit of 998-qrwu (which removed 38 copies of one
//! path). Both `tillandsias-macos-tray` (which WRITES the staged binary) and
//! `tillandsias-vm-layer` (which reads it to fingerprint, and which builds the
//! share) call in here. A follow-up worth filing, not done here: this root and
//! `ca_path`'s are the same string reached two different ways, and one of them
//! should derive from the other.

use std::path::PathBuf;

/// `${HOME}/.local/state/tillandsias` — the durable per-user state root.
fn xdg_state_root() -> PathBuf {
    std::env::var_os("HOME")
        .map(PathBuf::from)
        .unwrap_or_else(|| PathBuf::from("/tmp"))
        .join(".local/state/tillandsias")
}

/// HOST directory the tray stages the guest binary into.
pub fn guest_bin_dir() -> PathBuf {
    xdg_state_root().join("guest-bin")
}

/// HOST path of the staged guest binary.
pub fn staged_guest_binary() -> PathBuf {
    guest_bin_dir().join("tillandsias-headless")
}

/// GUEST mount point for the share carrying the staged binary.
///
/// `/var/lib` rather than a HOME-relative path INSIDE the guest: the guest runs
/// as root, 998-3z6g measured `/var/lib` as writable and reboot-durable there,
/// and a fixed absolute path keeps the fstab line and `fetch-headless.sh` in
/// agreement without either expanding a variable. The host side is
/// HOME-relative and the guest side is not, deliberately — they are different
/// filesystems and the share tag is what joins them.
pub const GUEST_BIN_MOUNT: &str = "/var/lib/tillandsias/guest-bin";

/// virtio-fs tag joining the host directory to the guest mount point.
pub const GUEST_BIN_SHARE_TAG: &str = "guest-bin";

/// GUEST path `fetch-headless.sh` installs from.
pub const GUEST_STAGED_BINARY: &str = "/var/lib/tillandsias/guest-bin/tillandsias-headless";

#[cfg(test)]
mod tests {
    use super::*;

    /// The staged path must be under the state root, not under `~/src`. That
    /// is the whole packet: a path that survives 997-e4v2 retiring the
    /// `home-src` share.
    #[test]
    fn staging_is_off_home_src() {
        // SAFETY: single-threaded test; the value is read, not cached.
        unsafe { std::env::set_var("HOME", "/home/probe") };
        let p = staged_guest_binary();
        let s = p.to_string_lossy();
        assert!(
            s.starts_with("/home/probe/.local/state/tillandsias/guest-bin/"),
            "staged path must derive from the state root, got {s}"
        );
        assert!(
            !s.contains("/src/"),
            "staged path must not live under ~/src — that share is being retired: {s}"
        );
    }

    /// The guest constants must agree with each other. They are separate
    /// strings because one goes in an fstab line and one in a shell script, and
    /// a mismatch would leave the mount fine and the install path wrong.
    #[test]
    fn guest_mount_and_binary_path_agree() {
        assert!(
            GUEST_STAGED_BINARY.starts_with(GUEST_BIN_MOUNT),
            "the staged binary must sit under the mount point: {GUEST_STAGED_BINARY} vs {GUEST_BIN_MOUNT}"
        );
        assert!(
            !GUEST_STAGED_BINARY.contains("/home/forge/src"),
            "the guest path must not depend on the home-src share"
        );
    }
}
