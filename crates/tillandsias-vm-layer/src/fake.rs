//! Linux-only fake VM runtime for the Phase-2 dev loop.
//!
//! Mocks WSL/VZ by running the requested argv directly on the host via
//! `tokio::process::Command`. Lets Linux developers exercise the
//! `VmRuntime` trait + the host shell's orchestration logic without
//! needing a real WSL distro or a Virtualization.framework guest.
//!
//! Idempotency contract:
//! - `provision` records the manifest paths in a marker file under
//!   `marker_dir`. A second call with the same manifest is a cheap no-op
//!   and SHALL NOT re-execute any host commands.
//! - `start`/`stop` flip an in-memory `running` flag.
//! - `exec` runs the argv on the host; the exit status is propagated
//!   verbatim so tests can assert on `success()` / `code()`.
//! - `wait_ready` simply returns `Ok(())` (the host is always "ready").
//!
//! This module is gated behind `feature = "fake"` AND `target_os = "linux"`
//! so it never leaks into the real Windows / macOS build paths.
//!
//! @trace spec:vm-idiomatic-layer

use std::path::PathBuf;
use std::process::ExitStatus;
use std::sync::Mutex;
use std::time::Duration;

use tokio::fs;
use tokio::process::Command;

use crate::{ProvisionManifest, VmError, VmRuntime};

/// Host-side fake of a `VmRuntime`. Persists provisioning state in a marker
/// file under `marker_dir` so idempotency survives across process restarts
/// inside a single test run.
///
/// @trace spec:vm-idiomatic-layer
pub struct FakeVmRuntime {
    /// Where to drop the `provisioned.marker` file recording the manifest
    /// inputs that have already been satisfied.
    marker_dir: PathBuf,
    /// In-memory toggle flipped by `start`/`stop`. Tests inspect this via
    /// `is_running`.
    running: Mutex<bool>,
}

impl FakeVmRuntime {
    /// Construct a fake whose provisioning marker lives under `marker_dir`.
    /// The directory is created lazily inside `provision`.
    pub fn new(marker_dir: impl Into<PathBuf>) -> Self {
        Self {
            marker_dir: marker_dir.into(),
            running: Mutex::new(false),
        }
    }

    /// True if `start` was called more recently than `stop`. Test-only
    /// helper — production callers query `wait_ready` instead.
    pub fn is_running(&self) -> bool {
        *self.running.lock().expect("running lock poisoned")
    }

    fn marker_path(&self) -> PathBuf {
        self.marker_dir.join("provisioned.marker")
    }

    fn manifest_fingerprint(manifest: &ProvisionManifest) -> String {
        // Stable textual fingerprint of the fields that decide whether a
        // re-provision is needed. Not a security hash — just a cheap
        // string compare against the previously-stored marker.
        format!(
            "rootfs={}\nbinary={}\ncid={}\nport={}\nshared={}\n",
            manifest.rootfs_tarball.display(),
            manifest.tillandsias_binary.display(),
            manifest.vsock_cid,
            manifest.vsock_port,
            manifest.shared_host_dir.display(),
        )
    }
}

#[async_trait::async_trait]
impl VmRuntime for FakeVmRuntime {
    async fn provision(&self, manifest: &ProvisionManifest) -> Result<(), VmError> {
        let marker = self.marker_path();
        let fingerprint = Self::manifest_fingerprint(manifest);
        if let Ok(existing) = fs::read_to_string(&marker).await
            && existing == fingerprint
        {
            return Ok(());
        }

        fs::create_dir_all(&self.marker_dir)
            .await
            .map_err(|e| format!("fake provision: create_dir_all failed: {e}"))?;
        fs::write(&marker, fingerprint)
            .await
            .map_err(|e| format!("fake provision: write marker failed: {e}"))?;
        Ok(())
    }

    async fn start(&self) -> Result<(), VmError> {
        *self.running.lock().expect("running lock poisoned") = true;
        Ok(())
    }

    async fn stop(&self, _drain_timeout: Duration) -> Result<(), VmError> {
        *self.running.lock().expect("running lock poisoned") = false;
        Ok(())
    }

    async fn exec(&self, argv: &[&str]) -> Result<ExitStatus, VmError> {
        let Some((program, rest)) = argv.split_first() else {
            return Err("fake exec: argv is empty".to_string());
        };
        let mut cmd = Command::new(program);
        cmd.args(rest);
        let status = cmd
            .status()
            .await
            .map_err(|e| format!("fake exec: spawn {program} failed: {e}"))?;
        Ok(status)
    }

    async fn wait_ready(&self, _timeout: Duration) -> Result<(), VmError> {
        // The host is always ready; in the fake loop there's nothing to wait
        // on. Real backends poll their vsock readiness file.
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use std::path::Path;

    use super::*;

    fn manifest_with_paths(rootfs: &Path, binary: &Path, shared: &Path) -> ProvisionManifest {
        ProvisionManifest {
            rootfs_tarball: rootfs.to_path_buf(),
            tillandsias_binary: binary.to_path_buf(),
            vsock_cid: 7,
            vsock_port: 42420,
            shared_host_dir: shared.to_path_buf(),
        }
    }

    /// @trace spec:vm-idiomatic-layer
    #[tokio::test]
    async fn fake_runtime_executes_argv_and_returns_exit_status() {
        let dir = tempfile::tempdir().unwrap();
        let rt = FakeVmRuntime::new(dir.path().to_path_buf());

        let ok = rt.exec(&["true"]).await.expect("true should run");
        assert!(ok.success(), "`true` should yield success: {ok:?}");

        let fail = rt.exec(&["false"]).await.expect("false should run");
        assert!(!fail.success(), "`false` should yield failure: {fail:?}");
        assert_eq!(fail.code(), Some(1), "`false` exits with code 1");
    }

    /// @trace spec:vm-idiomatic-layer
    #[tokio::test]
    async fn fake_runtime_provision_is_idempotent() {
        let dir = tempfile::tempdir().unwrap();
        let manifest = manifest_with_paths(
            &PathBuf::from("/tmp/rootfs.tar.xz"),
            &PathBuf::from("/tmp/tillandsias"),
            &PathBuf::from("/home/user/src"),
        );

        let rt = FakeVmRuntime::new(dir.path().to_path_buf());
        rt.provision(&manifest).await.expect("first provision");

        let marker_path = dir.path().join("provisioned.marker");
        let first_mtime = fs::metadata(&marker_path)
            .await
            .expect("marker exists after first provision")
            .modified()
            .expect("mtime");

        // Sleep one tick so the marker's mtime would differ if a second
        // write actually happened.
        tokio::time::sleep(Duration::from_millis(20)).await;

        rt.provision(&manifest).await.expect("second provision");
        let second_mtime = fs::metadata(&marker_path)
            .await
            .expect("marker still present")
            .modified()
            .expect("mtime");
        assert_eq!(
            first_mtime, second_mtime,
            "second provision must be a no-op (marker mtime unchanged)"
        );
    }

    /// @trace spec:vm-idiomatic-layer
    #[tokio::test]
    async fn fake_runtime_start_stop_toggles_running() {
        let dir = tempfile::tempdir().unwrap();
        let rt = FakeVmRuntime::new(dir.path().to_path_buf());
        assert!(!rt.is_running(), "fresh fake is not running");
        rt.start().await.unwrap();
        assert!(rt.is_running(), "after start, fake is running");
        rt.stop(Duration::from_secs(1)).await.unwrap();
        assert!(!rt.is_running(), "after stop, fake is not running");
    }
}
