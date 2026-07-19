//! §3.7.2 — WSL converter: feed a materialized rootfs tar to `wsl --import`.
//!
//! The recipe materializer ([`super::Materializer`]) produces a universal
//! [`MaterializedRootfs::Tar`]. On Windows the install path is `wsl --import`,
//! which ingests a rootfs tar directly — no `.img` wrapping (contrast the
//! macOS `materialize::macos::tar_to_vfr_img` converter, which builds an
//! EFI+ext4 image for Virtualization.framework). This is the Windows sibling
//! slice claimed by windows-next; the driver itself is Linux-owned (lease
//! `linux-l-mat-2026-05-25T15Z`).
//!
//! @trace spec:vm-provisioning-lifecycle §3.7.2,
//! plan/issues/tray-convergence-coordination.md (per-OS materializer backend)

use std::ffi::OsString;
use std::path::Path;

use super::{MaterializeError, MaterializedRootfs};

/// WSL2 is the only supported version for the tillandsias distro.
const WSL_VERSION: &str = "2";

/// Build the `wsl --import` argv for a materialized rootfs tar (§3.7.2).
///
/// Pure — constructs the argument vector without touching `wsl.exe`, so the
/// command shape is unit-testable on any host (Linux CI included). The caller
/// runs it via [`tar_to_wsl_import`].
///
/// Shape: `--import <distro> <install_dir> <rootfs.tar> --version 2`,
/// identical to `WslRuntime::provision`'s import step so both the
/// download-path and the recipe-materializer path register the distro the
/// same way.
pub fn wsl_import_args(
    distro: &str,
    install_dir: &Path,
    rootfs: &MaterializedRootfs,
) -> Vec<OsString> {
    let MaterializedRootfs::Tar(tar) = rootfs;
    vec![
        OsString::from("--import"),
        OsString::from(distro),
        install_dir.as_os_str().to_os_string(),
        tar.as_os_str().to_os_string(),
        OsString::from("--version"),
        OsString::from(WSL_VERSION),
    ]
}

/// Import a materialized rootfs tar as a WSL2 distro (§3.7.2).
///
/// Validates the tar exists, then runs `wsl --import …`. Registering-once
/// idempotency (skip if the distro already exists) is the caller's concern —
/// `WslRuntime::provision` checks `wsl --list --quiet` first; this converter is
/// the lower-level import primitive the recipe path calls once it knows a fresh
/// import is needed.
///
/// Runtime is Windows-only (`wsl.exe`); the pure [`wsl_import_args`] above is
/// the cross-platform-testable half.
///
/// @trace spec:vm-provisioning-lifecycle §3.7.2
pub async fn tar_to_wsl_import(
    distro: &str,
    install_dir: &Path,
    rootfs: &MaterializedRootfs,
) -> Result<(), MaterializeError> {
    let MaterializedRootfs::Tar(tar) = rootfs;
    if !tar.exists() {
        return Err(format!(
            "materialized rootfs tar missing at {}",
            tar.display()
        ));
    }
    // Order 419: check HOST drive headroom BEFORE `wsl --import` writes the
    // VHDX. The import materializes roughly the tar's expanded content into
    // ext4-on-VHDX; running the host drive dry mid-import used to yield a
    // bare "wsl --import exited <status>" that read as a crash. Fail loud
    // and actionable up-front instead.
    let tar_len = std::fs::metadata(tar).map(|m| m.len()).unwrap_or(0);
    let avail = fs2::available_space(install_dir).unwrap_or(u64::MAX);
    if let Err(msg) = evaluate_host_import_headroom(avail, tar_len) {
        return Err(msg);
    }
    let args = wsl_import_args(distro, install_dir, rootfs);
    let mut cmd = tokio::process::Command::new("wsl");
    cmd.args(&args).env("WSL_UTF8", "1");
    crate::no_window_async(&mut cmd);
    let output = cmd
        .output()
        .await
        .map_err(|e| format!("wsl --import failed to spawn: {e}"))?;
    if !output.status.success() {
        // Keep the child's stderr — for a GUI tray this is the only text
        // naming the real failure (order 419).
        let stderr = String::from_utf8_lossy(&output.stderr)
            .replace('\u{0}', "")
            .trim()
            .to_string();
        if let Some(remediation) = crate::wsl::classify_launch_stderr(&stderr) {
            return Err(format!("wsl --import failed (classified). {remediation}"));
        }
        return Err(format!(
            "wsl --import failed: exited {}; stderr: {}",
            output.status,
            if stderr.is_empty() { "(empty)" } else { &stderr }
        ));
    }
    Ok(())
}

/// Pure host-headroom verdict for `wsl --import` (order 419): require space
/// for ~2x the rootfs tar (VHDX materialization + ext4 overhead) plus a
/// 2 GiB safety floor. `Err` carries the actionable operator message.
pub fn evaluate_host_import_headroom(avail_bytes: u64, tar_bytes: u64) -> Result<(), String> {
    const SAFETY_FLOOR_BYTES: u64 = 2 * 1024 * 1024 * 1024;
    let needed = tar_bytes.saturating_mul(2).saturating_add(SAFETY_FLOOR_BYTES);
    if avail_bytes < needed {
        return Err(format!(
            "the host drive is low on space: {} MiB available, but importing the \
             VM needs roughly {} MiB (2x the rootfs image + safety floor). Free \
             disk space, then Retry.",
            avail_bytes / (1024 * 1024),
            needed / (1024 * 1024)
        ));
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::path::PathBuf;

    /// Order 419: the pre-import gate needs 2x tar + 2 GiB; boundary cases
    /// pinned so the arithmetic can't silently regress.
    #[test]
    fn host_import_headroom_requires_double_tar_plus_floor() {
        const GIB: u64 = 1024 * 1024 * 1024;
        // 1 GiB tar → needs 4 GiB.
        assert!(evaluate_host_import_headroom(4 * GIB, GIB).is_ok());
        let err = evaluate_host_import_headroom(4 * GIB - 1, GIB).unwrap_err();
        assert!(err.contains("host drive is low on space"));
        assert!(err.contains("Free disk space"));
        // Unknown tar size (0) still enforces the 2 GiB floor.
        assert!(evaluate_host_import_headroom(2 * GIB, 0).is_ok());
        assert!(evaluate_host_import_headroom(GIB, 0).is_err());
    }

    #[test]
    fn import_args_match_wslruntime_provision_shape() {
        let rootfs = MaterializedRootfs::Tar(PathBuf::from(r"C:\cache\rootfs-fedora-44.tar"));
        let args = wsl_import_args(
            "tillandsias",
            Path::new(r"C:\Users\me\AppData\Local\tillandsias\wsl"),
            &rootfs,
        );
        let as_str: Vec<String> = args
            .iter()
            .map(|a| a.to_string_lossy().into_owned())
            .collect();
        assert_eq!(
            as_str,
            vec![
                "--import".to_string(),
                "tillandsias".to_string(),
                r"C:\Users\me\AppData\Local\tillandsias\wsl".to_string(),
                r"C:\cache\rootfs-fedora-44.tar".to_string(),
                "--version".to_string(),
                "2".to_string(),
            ]
        );
    }

    /// The tar path comes straight from `MaterializedRootfs::Tar`, so an
    /// arbitrary cache path round-trips into argv[3] unchanged.
    #[test]
    fn import_args_carry_the_materialized_tar_path() {
        let tar = PathBuf::from("/var/cache/recipe-cache/abc123.tar");
        let rootfs = MaterializedRootfs::Tar(tar.clone());
        let args = wsl_import_args("til", Path::new("/install"), &rootfs);
        assert_eq!(args[3], tar.into_os_string());
    }
}
