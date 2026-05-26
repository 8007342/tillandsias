//! Windows-side glue between the tray and `tillandsias-vm-layer::WslRuntime`.
//!
//! Owns the install-path discovery (`%LOCALAPPDATA%\tillandsias\wsl`), the
//! cache directory (`%LOCALAPPDATA%\tillandsias\cache`), and the
//! provisioning bootstrap that downloads the Fedora rootfs + tillandsias
//! binary, calls `wsl --import`, and starts the in-VM headless via
//! systemd. Per the host-shell plan, the actual heavy lifting lives in
//! `WslRuntime::provision`; this module orchestrates progress reporting +
//! `bootstrap` sequencing.
//!
//! @trace spec:windows-native-tray, spec:vm-idiomatic-layer

#![allow(dead_code)]

use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::time::Duration;

use tillandsias_host_shell::provisioning::{ProvisionPhase, ProvisionProgress};
use tillandsias_vm_layer::fetch::{
    ProvisioningPins, RemoteArtifact, download_verified, is_sha256_hex,
};
use tillandsias_vm_layer::materialize::{MaterializedRootfs, tar_to_wsl_import};
use tillandsias_vm_layer::recipe::Manifest;
use tillandsias_vm_layer::{ProvisionManifest, VmRuntime, wsl::WslRuntime};

/// Committed per-release pins (rootfs + headless binary URLs and checksums).
/// Embedded so an installed, checkout-free tray still provisions correctly.
///
/// @trace spec:vm-provisioning-lifecycle
const PROVISIONING_MANIFEST: &str = include_str!("../assets/provisioning-manifest.json");

/// The recipe materialization manifest (l9 `[output]` artifact-URL + SHA
/// contract), embedded so the installed, checkout-free tray can resolve the
/// CI-published rootfs without a repo. Manifest-delivery decision (w5 consumer
/// question): embed at build time — one trusted artifact, no runtime fetch of
/// the trust root.
const RECIPE_MANIFEST: &str = include_str!("../../../images/vm/manifest.toml");

/// Release tag the rootfs artifacts are published under. Tag-source decision
/// (w5 consumer question): a build-time constant for v0.0.1. TODO: wire to the
/// workspace CalVer version so it tracks releases automatically rather than
/// being bumped by hand each release.
const RECIPE_RELEASE_TAG: &str = "v0.2.260526.1";

/// Convenience wrapper around `tillandsias-vm-layer::wsl::WslRuntime` that
/// carries the tray's preferred defaults (distro name `tillandsias`,
/// install root under `%LOCALAPPDATA%`).
pub struct WslLifecycle {
    runtime: WslRuntime,
}

impl Default for WslLifecycle {
    fn default() -> Self {
        Self::new()
    }
}

impl WslLifecycle {
    pub fn new() -> Self {
        Self {
            runtime: WslRuntime::new("tillandsias", Self::install_root()),
        }
    }

    pub fn install_root() -> PathBuf {
        // %LOCALAPPDATA%\tillandsias\wsl
        let base = std::env::var_os("LOCALAPPDATA")
            .map(PathBuf::from)
            .unwrap_or_else(|| PathBuf::from("C:\\Users\\Public\\AppData\\Local"));
        base.join("tillandsias").join("wsl")
    }

    pub fn cache_root() -> PathBuf {
        let base = std::env::var_os("LOCALAPPDATA")
            .map(PathBuf::from)
            .unwrap_or_else(|| PathBuf::from("C:\\Users\\Public\\AppData\\Local"));
        base.join("tillandsias").join("cache")
    }

    pub fn rootfs_cache_path(sha256_short: &str) -> PathBuf {
        Self::cache_root().join(format!("rootfs-fedora-44-{}.tar.xz", sha256_short))
    }

    pub fn binary_cache_path(version: &str) -> PathBuf {
        Self::cache_root()
            .join("bin")
            .join(format!("tillandsias-headless-{}", version))
    }

    /// Wake the distro by issuing a cheap `wsl --exec true` through the
    /// runtime. Idempotent.
    pub async fn ensure_started(&self) -> Result<(), String> {
        self.runtime.start().await
    }

    /// Graceful shutdown — issued by the tray on Quit. The host-shell's
    /// `VmLifecycle::stop` is the production entry point; this wrapper
    /// exists for callers that don't want the full `VmLifecycle` machinery.
    pub async fn graceful_shutdown(&self) -> Result<(), String> {
        self.runtime.stop(Duration::from_secs(30)).await
    }

    /// Full first-run bootstrap. Reports progress through the
    /// `ProvisionProgress` sink so the tray can update its condensed
    /// status line.
    ///
    /// Sequence (idempotent at every step):
    /// 1. `SettingUp` — verify cache directories exist.
    /// 2. `DownloadingRootfs` — fetch Fedora 44 rootfs (skip if cached).
    /// 3. `DownloadingTillandsias` — fetch the matching headless binary
    ///    from the GitHub release (skip if cached).
    /// 4. `InstallingTillandsias` — call `WslRuntime::provision` (which
    ///    does `wsl --import` + drops the systemd unit). Skipped if the
    ///    distro is already registered.
    /// 5. `StartingVm` — `WslRuntime::start`.
    /// 6. `Connecting` — the caller's vsock handshake step.
    ///
    /// @trace spec:vm-provisioning-lifecycle
    pub async fn bootstrap(&self, progress: Arc<dyn ProvisionProgress>) -> Result<(), String> {
        progress.report_phase(ProvisionPhase::SettingUp);
        tokio::fs::create_dir_all(Self::cache_root())
            .await
            .map_err(|e| format!("create cache_root failed: {e}"))?;
        tokio::fs::create_dir_all(Self::install_root())
            .await
            .map_err(|e| format!("create install_root failed: {e}"))?;

        let pins = ProvisioningPins::from_json(PROVISIONING_MANIFEST)?;

        progress.report_phase(ProvisionPhase::DownloadingRootfs);
        let rootfs = download_rootfs(&Self::cache_root(), &pins).await?;

        progress.report_phase(ProvisionPhase::DownloadingTillandsias);
        let binary = download_headless_binary(&Self::cache_root(), &pins).await?;

        progress.report_phase(ProvisionPhase::InstallingTillandsias);
        let manifest = ProvisionManifest {
            rootfs_tarball: rootfs,
            tillandsias_binary: binary,
            vsock_cid: 0, // WSL assigns dynamically
            vsock_port: tillandsias_control_wire::transport::CONTROL_WIRE_VSOCK_PORT,
            shared_host_dir: user_src_dir(),
        };
        self.runtime.provision(&manifest).await?;

        progress.report_phase(ProvisionPhase::StartingVm);
        self.runtime.start().await?;

        progress.report_phase(ProvisionPhase::Connecting);
        Ok(())
    }

    /// Recipe-path first-run provisioning — the **w5 flip**. Supersedes the
    /// legacy [`bootstrap`](Self::bootstrap) OCI-base + separate-binary path:
    ///
    /// 1. `SettingUp` — ensure cache/install dirs.
    /// 2. `DownloadingRootfs` — resolve the CI-published rootfs from the
    ///    embedded recipe manifest (l9 `[output]` URL + SHA) and
    ///    `download_verified` it (SHA-gated; resumable).
    /// 3. `InstallingTillandsias` — `materialize::wsl::tar_to_wsl_import` →
    ///    `wsl --import`. No separate binary drop / unit install: the recipe
    ///    rootfs self-installs the headless on first boot
    ///    (`bootstrap/20-tillandsias.sh`) and already carries the systemd unit.
    /// 4. `StartingVm` — `WslRuntime::start`.
    ///
    /// Idempotency note: `WslRuntime::provision`'s skip-if-registered guard is
    /// not yet shared here; callers should probe (`ensure_vm_provisioned`)
    /// before invoking on an already-imported distro (follow-up).
    ///
    /// @trace plan/issues/tray-convergence-coordination.md (w5 flip),
    /// spec:vm-provisioning-lifecycle.provision.first-run-downloads@v1
    pub async fn provision_via_recipe(
        &self,
        progress: Arc<dyn ProvisionProgress>,
    ) -> Result<(), String> {
        progress.report_phase(ProvisionPhase::SettingUp);
        tokio::fs::create_dir_all(Self::cache_root())
            .await
            .map_err(|e| format!("create cache_root failed: {e}"))?;
        tokio::fs::create_dir_all(Self::install_root())
            .await
            .map_err(|e| format!("create install_root failed: {e}"))?;

        // Idempotent: if a prior run already imported the distro, skip the
        // download + `wsl --import` and just (re)start it.
        if self.runtime.is_registered().await {
            progress.report_phase(ProvisionPhase::StartingVm);
            self.runtime.start().await?;
            progress.report_phase(ProvisionPhase::Connecting);
            return Ok(());
        }

        let manifest = Manifest::from_toml(RECIPE_MANIFEST)
            .map_err(|e| format!("parse embedded recipe manifest: {e}"))?;
        let artifact = recipe_rootfs_artifact(&manifest, RECIPE_RELEASE_TAG)?;

        progress.report_phase(ProvisionPhase::DownloadingRootfs);
        let dest = Self::cache_root().join("rootfs").join(format!(
            "tillandsias-rootfs-x86_64-{}.tar",
            &artifact.sha256[..12]
        ));
        download_verified(&artifact, &dest, &|_, _| {}).await?;

        progress.report_phase(ProvisionPhase::InstallingTillandsias);
        tar_to_wsl_import(
            "tillandsias",
            &Self::install_root(),
            &MaterializedRootfs::Tar(dest),
        )
        .await?;
        // Enable systemd via /etc/wsl.conf + terminate, so the next start boots
        // under systemd and the recipe rootfs's first-boot headless self-install
        // (fetch-headless.sh) + systemd unit run. No binary drop / unit install.
        self.runtime.configure_recipe_distro().await?;

        progress.report_phase(ProvisionPhase::StartingVm);
        self.runtime.start().await?;

        progress.report_phase(ProvisionPhase::Connecting);
        Ok(())
    }
}

pub(crate) fn user_src_dir() -> PathBuf {
    let base = std::env::var_os("USERPROFILE")
        .map(PathBuf::from)
        .unwrap_or_else(|| PathBuf::from("C:\\Users\\Public"));
    base.join("src")
}

/// Download + SHA-verify the pinned Fedora rootfs archive into the cache.
///
/// Returns the local path to the verified archive. NOTE: this is a Fedora
/// **OCI image archive**, not a flat rootfs — `WslRuntime::provision` must
/// flatten its layer(s) into a rootfs tar before `wsl --import` (Phase 2b).
///
/// @trace spec:vm-provisioning-lifecycle.provision.first-run-downloads@v1
async fn download_rootfs(cache_root: &Path, pins: &ProvisioningPins) -> Result<PathBuf, String> {
    let short = &pins.rootfs.sha256[..pins.rootfs.sha256.len().min(12)];
    let dest = cache_root
        .join("rootfs")
        .join(format!("rootfs-fedora-44-{short}.oci.tar.xz"));
    download_verified(&pins.rootfs, &dest, &|_, _| {}).await?;
    Ok(dest)
}

/// Download + SHA-verify the pinned `tillandsias-linux-x86_64` headless
/// binary (the in-VM process) into the cache.
///
/// @trace spec:vm-provisioning-lifecycle.provision.first-run-downloads@v1
async fn download_headless_binary(
    cache_root: &Path,
    pins: &ProvisioningPins,
) -> Result<PathBuf, String> {
    let dest = cache_root.join("bin").join(format!(
        "tillandsias-headless-{}",
        pins.headless_release_tag
    ));
    download_verified(&pins.headless_binary, &dest, &|_, _| {}).await?;
    Ok(dest)
}

/// Resolve the Windows rootfs artifact (`x86_64.tar`) to a verifiable download
/// pin from the recipe `Manifest` (l9 contract) at the given release `tag`.
///
/// Bridges the recipe `[output]` block — `artifact_url_template` +
/// `expected_rootfs_sha["x86_64.tar"]` — into the [`RemoteArtifact`] that
/// [`download_verified`] consumes, so the recipe-provisioning path reuses the
/// existing verified-download machinery. The trailing step is
/// [`materialize::wsl::tar_to_wsl_import`] on the downloaded tar.
///
/// Returns an error (rather than an unverifiable pin) while the recipe-publish
/// CI has not yet backfilled a real SHA — the manifest still carries the
/// `pending-ci` placeholder, which is NOT 64 hex digits. This is the honest gate
/// until §2b publishes the first artifacts; the URL contract itself is settled.
///
/// @trace plan/issues/tray-convergence-coordination.md (w5-flip consumer contract),
/// spec:vm-provisioning-lifecycle.provision.first-run-downloads@v1
pub fn recipe_rootfs_artifact(manifest: &Manifest, tag: &str) -> Result<RemoteArtifact, String> {
    const ARCH: &str = "x86_64";
    const FORMAT: &str = "tar";
    const SHA_KEY: &str = "x86_64.tar";

    let url = manifest
        .artifact_url(ARCH, FORMAT, tag)
        .ok_or_else(|| "manifest has no [output].artifact_url_template".to_string())?;
    let sha = manifest
        .expected_sha(SHA_KEY)
        .ok_or_else(|| format!("manifest [output].expected_rootfs_sha has no \"{SHA_KEY}\" pin"))?;
    if !is_sha256_hex(sha) {
        return Err(format!(
            "rootfs SHA for {SHA_KEY} not yet published (manifest pin = {sha:?}); \
             the recipe-publish CI (§2b) must run + backfill a real SHA first"
        ));
    }
    Ok(RemoteArtifact {
        url,
        sha256: sha.to_string(),
        bytes: None,
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn install_root_resolves_under_localappdata() {
        // SAFETY: tests set env synchronously; cargo test runs in single
        // process so the env mutation only affects this test.
        unsafe {
            std::env::set_var("LOCALAPPDATA", "C:\\Users\\Tester\\AppData\\Local");
        }
        let root = WslLifecycle::install_root();
        assert!(root.ends_with("tillandsias\\wsl") || root.ends_with("tillandsias/wsl"));
    }

    // The committed recipe manifest — used for a live-contract integration check.
    const REAL_MANIFEST: &str = include_str!("../../../images/vm/manifest.toml");

    // A minimal synthetic manifest with a caller-chosen x86_64.tar SHA, so the
    // resolver tests are robust to the committed manifest's SHA rolling per
    // release (l9 step 3 backfilled real SHAs at a6163af2). Literal `{tag}` /
    // `{arch}` / `{format}` braces are left for `artifact_url` to substitute.
    fn manifest_with_x86_tar_sha(sha: &str) -> Manifest {
        const TMPL: &str = r#"recipe_version = 1
[output]
artifact_url_template = "https://github.com/8007342/tillandsias/releases/download/{tag}/tillandsias-rootfs-{arch}.{format}"
[output.expected_rootfs_sha]
"x86_64.tar" = "__SHA__"
"#;
        Manifest::from_toml(&TMPL.replace("__SHA__", sha)).expect("parse inline manifest")
    }

    #[test]
    fn recipe_rootfs_artifact_gates_on_pending_ci_sha() {
        let m = manifest_with_x86_tar_sha("pending-ci");
        // A non-64-hex placeholder must refuse rather than hand back an
        // unverifiable pin.
        let err = recipe_rootfs_artifact(&m, "v0.2.260526.1").expect_err("pending-ci must gate");
        assert!(err.contains("not yet published"), "unexpected error: {err}");
    }

    #[test]
    fn recipe_rootfs_artifact_resolves_url_and_sha() {
        let sha = "a".repeat(64);
        let m = manifest_with_x86_tar_sha(&sha);
        let art = recipe_rootfs_artifact(&m, "v0.2.260526.1").expect("resolves with a real SHA");
        assert_eq!(art.sha256, sha);
        assert_eq!(
            art.url,
            "https://github.com/8007342/tillandsias/releases/download/\
             v0.2.260526.1/tillandsias-rootfs-x86_64.tar"
        );
    }

    /// Live-contract check: since l9 step 3 backfilled real SHAs, the COMMITTED
    /// manifest now resolves to a verifiable artifact. Asserts shape (64-hex +
    /// URL), not the exact SHA (which rolls per release) — and guards against a
    /// regression back to `pending-ci`.
    #[test]
    fn recipe_rootfs_artifact_resolves_against_committed_manifest() {
        let m = Manifest::from_toml(REAL_MANIFEST).expect("parse committed manifest");
        let art = recipe_rootfs_artifact(&m, "v0.2.260526.1")
            .expect("committed manifest carries a real x86_64.tar SHA (l9 step 3)");
        assert_eq!(
            art.sha256.len(),
            64,
            "expected a 64-hex SHA, got {:?}",
            art.sha256
        );
        assert!(
            art.url
                .ends_with("/v0.2.260526.1/tillandsias-rootfs-x86_64.tar"),
            "unexpected url: {}",
            art.url
        );
    }
}
