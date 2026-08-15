//! Helpers for staging the bundled Linux guest binary into the shared host
//! source tree before VM boot.
//!
//! The macOS tray bundles the matching guest binary under the app bundle's
//! `Contents/Resources/guest/` directory. Before Virtualization.framework
//! boots the VM, we copy that binary into the host's shared `~/src` tree so the
//! guest bootstrap can install it from the virtio-fs mount without a network
//! fetch.

#![cfg(target_os = "macos")]

use std::path::{Path, PathBuf};

fn host_src_dir() -> PathBuf {
    std::env::var_os("HOME")
        .map(PathBuf::from)
        .unwrap_or_else(|| PathBuf::from("/tmp"))
        .join("src")
}

fn guest_binary_filename() -> &'static str {
    match std::env::consts::ARCH {
        "aarch64" => "tillandsias-headless-aarch64-unknown-linux-musl",
        "x86_64" => "tillandsias-headless-x86_64-unknown-linux-musl",
        other => panic!("unsupported macOS host arch for guest binary: {other}"),
    }
}

fn bundle_resource_candidate() -> Option<PathBuf> {
    let resource_name = guest_binary_filename();
    if let Ok(mut exe) = std::env::current_exe() {
        // .../Tillandsias.app/Contents/MacOS/tillandsias-tray
        let _ = exe.pop(); // MacOS
        if let Some(contents) = exe.parent() {
            return Some(contents.join("Resources/guest").join(resource_name));
        }
    }

    let manifest_dir = PathBuf::from(env!("CARGO_MANIFEST_DIR"));
    let dev_candidate = manifest_dir
        .parent()
        .unwrap_or_else(|| Path::new(&manifest_dir))
        .parent()
        .unwrap_or_else(|| Path::new(&manifest_dir))
        .join("dist/Tillandsias.app/Contents/Resources/guest")
        .join(resource_name);
    Some(dev_candidate)
}

pub(crate) fn bundle_resource_path() -> Option<PathBuf> {
    let path = bundle_resource_candidate()?;
    path.exists().then_some(path)
}

/// Path the guest actually installs from on every boot.
///
/// `fetch-headless.sh` copies this over `/usr/local/bin/tillandsias-headless`
/// UNCONDITIONALLY, before its "already installed" short-circuit, so whatever
/// last wrote here decides which headless the guest runs.
pub(crate) fn staged_guest_binary_path() -> PathBuf {
    host_src_dir()
        .join(".tillandsias")
        .join("guest-bin")
        .join("tillandsias-headless")
}

/// SHA-256 of a file, hex, or None when it cannot be read.
fn file_sha256(path: &Path) -> Option<String> {
    use sha2::{Digest, Sha256};
    let bytes = std::fs::read(path).ok()?;
    let mut hasher = Sha256::new();
    hasher.update(&bytes);
    Some(format!("{:x}", hasher.finalize()))
}

/// What the running bundle carries versus what is actually staged for the guest
/// (701-kgvk).
///
/// The staging path is keyed only on `$HOME`, so every tray build on the host
/// writes the SAME file and last-writer-wins. An OLDER `Tillandsias.app`
/// started later silently downgrades the guest, stickily — the downgrade
/// survives reboots and even a guest reset, until a newer bundle re-stages.
/// Nothing detected that: the only integrity gate compares a VERSION string
/// which does not roll between builds, and the tray discards the guest version
/// from the control-wire handshake. A real skew on this host on 2026-08-11 had
/// to be found by hashing files by hand.
///
/// Reported as three fields rather than a single verdict so the two "unknown"
/// cases stay distinguishable from "mismatch": a non-bundled dev run has no
/// bundle to compare, and a host that has never booted a VM has nothing staged.
pub(crate) struct GuestBinaryProvenance {
    pub bundle_sha256: Option<String>,
    pub staged_sha256: Option<String>,
    /// `Some(true)` matched, `Some(false)` SKEWED, `None` undecidable because
    /// one side is absent — never collapse the last case into "fine".
    pub staged_matches_bundle: Option<bool>,
}

pub(crate) fn guest_binary_provenance() -> GuestBinaryProvenance {
    let bundle_sha256 = bundle_resource_path().as_deref().and_then(file_sha256);
    let staged_path = staged_guest_binary_path();
    let staged_sha256 = staged_path
        .exists()
        .then(|| file_sha256(&staged_path))
        .flatten();
    let staged_matches_bundle = match (&bundle_sha256, &staged_sha256) {
        (Some(b), Some(s)) => Some(b == s),
        _ => None,
    };
    GuestBinaryProvenance {
        bundle_sha256,
        staged_sha256,
        staged_matches_bundle,
    }
}

pub(crate) fn stage_embedded_guest_binary() -> Result<Option<PathBuf>, String> {
    let Some(source) = bundle_resource_path() else {
        return Ok(None);
    };
    let dest = host_src_dir()
        .join(".tillandsias")
        .join("guest-bin")
        .join("tillandsias-headless");
    if let Some(parent) = dest.parent() {
        std::fs::create_dir_all(parent)
            .map_err(|e| format!("create guest-binary staging dir {}: {e}", parent.display()))?;
    }
    std::fs::copy(&source, &dest).map_err(|e| {
        format!(
            "copy guest binary {} -> {}: {e}",
            source.display(),
            dest.display()
        )
    })?;
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        std::fs::set_permissions(&dest, std::fs::Permissions::from_mode(0o755))
            .map_err(|e| format!("chmod guest binary {}: {e}", dest.display()))?;
    }
    Ok(Some(dest))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn filename_matches_host_arch() {
        let name = guest_binary_filename();
        assert!(
            name.contains(std::env::consts::ARCH),
            "guest binary filename should reflect host arch"
        );
    }

    /// 701-kgvk. THE VERDICT THAT MATTERS: two different binaries must read as
    /// SKEW. The guest reinstalls from the staged copy on every boot, so a
    /// mismatch means it will run something other than what this bundle
    /// carries — the condition that was silently true on this host on
    /// 2026-08-11 and had to be found by hashing files by hand.
    #[test]
    fn differing_contents_are_reported_as_skew_not_agreement() {
        let dir = std::env::temp_dir().join(format!(
            "tillandsias-701kgvk-skew-{}-{}",
            std::process::id(),
            line!()
        ));
        std::fs::create_dir_all(&dir).expect("temp dir");
        let a = dir.join("bundle");
        let b = dir.join("staged");
        std::fs::write(&a, b"guest-binary-A").expect("write a");
        std::fs::write(&b, b"guest-binary-B-different").expect("write b");

        let ha = file_sha256(&a).expect("hash a");
        let hb = file_sha256(&b).expect("hash b");
        assert_ne!(
            ha, hb,
            "two different binaries must not hash equal — the whole detector rests on this"
        );

        let _ = std::fs::remove_dir_all(&dir);
    }

    /// NEGATIVE CONTROL (bar-raise 634-39ik). A detector that shouted SKEW at
    /// everything would satisfy the test above while being useless — operators
    /// would learn to ignore it, which is worse than silence because it burns
    /// the one signal. Byte-identical copies must read as agreement.
    #[test]
    fn identical_contents_are_reported_as_agreement() {
        let dir = std::env::temp_dir().join(format!(
            "tillandsias-701kgvk-same-{}-{}",
            std::process::id(),
            line!()
        ));
        std::fs::create_dir_all(&dir).expect("temp dir");
        let a = dir.join("bundle");
        let b = dir.join("staged");
        std::fs::write(&a, b"identical-guest-binary").expect("write a");
        std::fs::write(&b, b"identical-guest-binary").expect("write b");

        assert_eq!(
            file_sha256(&a).expect("hash a"),
            file_sha256(&b).expect("hash b"),
            "identical bytes must compare equal, or every healthy host reports a false skew"
        );

        let _ = std::fs::remove_dir_all(&dir);
    }

    /// An absent file must yield None — NOT a hash of nothing that could
    /// accidentally equal another absent side and read as "in sync". The
    /// three-state verdict exists precisely so "undecidable" is never rendered
    /// as "fine".
    #[test]
    fn an_unreadable_side_is_undecidable_never_agreement() {
        let missing = std::env::temp_dir().join(format!(
            "tillandsias-701kgvk-absent-{}-{}",
            std::process::id(),
            line!()
        ));
        assert!(
            file_sha256(&missing).is_none(),
            "an absent binary must hash to None so the verdict stays undecidable"
        );
    }
}
