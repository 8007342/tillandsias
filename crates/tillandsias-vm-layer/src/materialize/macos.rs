//! macOS-specific materializer output: convert a rootfs `.tar` into a raw
//! `.img` with GPT + EFI System Partition + ext4 root, bootable by
//! Apple's Virtualization.framework (`VZEFIBootLoader` +
//! `VZDiskImageStorageDeviceAttachment`).
//!
//! Per D6 the actual conversion runs on Linux CI (the `recipe-publish`
//! workflow): the loopback + ext4 toolchain doesn't exist natively on
//! macOS. The macOS host fetches the pre-built `.img` from the GitHub
//! release. This module exists in the macOS dep graph so callers (the
//! tray's first-run provisioning, the spike) can reference the converter
//! function without cfg-gating their imports.
//!
//! v0.0.1 implementation: shell-out to `scripts/materialize-macos-tar-to-img.sh`.
//! Production-quality alternative would be a pure-Rust implementation
//! using `gpt` + `tar2ext4` crates; for v0.0.1 the shell approach reuses
//! the well-tested parted/mkfs.ext4 toolchain and keeps the converter
//! readable.
//!
//! @trace openspec/changes/vm-recipe-provisioning §3.7.1, §2b.2, §D6

use std::path::{Path, PathBuf};
use std::process::Command;

/// Errors produced by `tar_to_vfr_img`. String-error idiom matches the rest
/// of `vm-layer::VmError` for consistency at the tray's status surface.
#[derive(Debug)]
pub enum ConvertError {
    /// The conversion script wasn't found at the expected location.
    /// `scripts/materialize-macos-tar-to-img.sh` must exist alongside the
    /// repo; this fires when the function is invoked from a built binary
    /// that doesn't know the repo root (which is most production calls —
    /// the function is intended for CI/build-time use, not runtime).
    ScriptNotFound(PathBuf),
    /// The `.tar` input does not exist or isn't readable.
    TarMissing(PathBuf),
    /// The shell script exited non-zero. Stderr captured so the caller can
    /// surface the failing parted/mkfs/losetup command name in the tray.
    ScriptFailed { exit_code: i32, stderr: String },
    /// `Command::spawn` itself failed (e.g. EPERM, the script wasn't
    /// executable, the system has no `/bin/bash`).
    SpawnFailed(std::io::Error),
}

impl std::fmt::Display for ConvertError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::ScriptNotFound(p) => {
                write!(f, "materialize-macos-tar-to-img.sh not found at {}", p.display())
            }
            Self::TarMissing(p) => write!(f, "rootfs tar missing at {}", p.display()),
            Self::ScriptFailed { exit_code, stderr } => write!(
                f,
                "tar→img conversion script exited {exit_code}; stderr:\n{stderr}"
            ),
            Self::SpawnFailed(e) => write!(f, "failed to spawn conversion script: {e}"),
        }
    }
}

impl std::error::Error for ConvertError {}

/// Convert a materialized rootfs `.tar` into a VFR-bootable raw `.img`.
///
/// Inputs:
///   - `tar`:           absolute path to the materialized rootfs tar (the
///                      output of `materialize::run` once Linux's §3
///                      driver lands; or a hand-rolled tar for testing).
///   - `out_img`:       absolute path to write the resulting `.img`. Will
///                      be overwritten if it exists.
///   - `script`:        absolute path to `scripts/materialize-macos-tar-to-img.sh`.
///                      For most callers `script_for_repo_root(repo)`
///                      derives this automatically.
///
/// Returns `Ok(())` on a successful conversion; the `.img` is written to
/// `out_img` and is ready to be served as the `aarch64.img` artifact of
/// the recipe-publish CI job.
///
/// **Runs on Linux only** (the shell script gates `uname -s == Linux`
/// because mkfs.ext4 isn't a native macOS tool). On macOS this function
/// returns `ConvertError::ScriptFailed` with a clear stderr the caller can
/// surface.
///
/// **Needs root** (losetup + mount). CI runs as root; dev invocations
/// need `sudo`.
///
/// @trace openspec/changes/vm-recipe-provisioning §3.7.1, §D6
pub fn tar_to_vfr_img(
    tar: &Path,
    out_img: &Path,
    script: &Path,
) -> Result<(), ConvertError> {
    if !script.exists() {
        return Err(ConvertError::ScriptNotFound(script.to_path_buf()));
    }
    if !tar.exists() {
        return Err(ConvertError::TarMissing(tar.to_path_buf()));
    }

    let output = Command::new("bash")
        .arg(script)
        .arg(tar)
        .arg(out_img)
        .output()
        .map_err(ConvertError::SpawnFailed)?;

    if !output.status.success() {
        let stderr = String::from_utf8_lossy(&output.stderr).into_owned();
        return Err(ConvertError::ScriptFailed {
            exit_code: output.status.code().unwrap_or(-1),
            stderr,
        });
    }
    Ok(())
}

/// Derive the canonical script path from the repo root: `<repo>/scripts/
/// materialize-macos-tar-to-img.sh`.
pub fn script_for_repo_root(repo_root: &Path) -> PathBuf {
    repo_root.join("scripts/materialize-macos-tar-to-img.sh")
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn error_implements_std_error() {
        fn assert_err<T: std::error::Error>() {}
        assert_err::<ConvertError>();

        let e = ConvertError::TarMissing(PathBuf::from("/no/such/path.tar"));
        let s = format!("{e}");
        assert!(s.contains("/no/such/path.tar"));
    }

    /// Conversion script path follows the documented convention.
    #[test]
    fn script_path_is_under_repo_root_scripts() {
        let root = PathBuf::from("/tmp/repo");
        let s = script_for_repo_root(&root);
        assert_eq!(
            s,
            PathBuf::from("/tmp/repo/scripts/materialize-macos-tar-to-img.sh")
        );
    }

    /// Missing script returns the documented error (not a panic or a
    /// generic IoError).
    #[test]
    fn missing_script_returns_clear_error() {
        let tmp = tempfile::tempdir().unwrap();
        let bogus_script = tmp.path().join("does-not-exist.sh");
        let bogus_tar = tmp.path().join("bogus.tar");
        std::fs::write(&bogus_tar, b"").unwrap();

        let err = tar_to_vfr_img(&bogus_tar, &tmp.path().join("out.img"), &bogus_script)
            .expect_err("should fail on missing script");
        match err {
            ConvertError::ScriptNotFound(p) => assert_eq!(p, bogus_script),
            other => panic!("expected ScriptNotFound, got {other:?}"),
        }
    }

    /// Missing tar (with valid script path) returns the documented error.
    #[test]
    fn missing_tar_returns_clear_error() {
        let tmp = tempfile::tempdir().unwrap();
        let script = tmp.path().join("fake.sh");
        std::fs::write(&script, "#!/bin/bash\nexit 0\n").unwrap();
        let bogus_tar = tmp.path().join("nope.tar");

        let err = tar_to_vfr_img(&bogus_tar, &tmp.path().join("out.img"), &script)
            .expect_err("should fail on missing tar");
        match err {
            ConvertError::TarMissing(p) => assert_eq!(p, bogus_tar),
            other => panic!("expected TarMissing, got {other:?}"),
        }
    }
}
