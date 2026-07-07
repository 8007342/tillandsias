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
}
