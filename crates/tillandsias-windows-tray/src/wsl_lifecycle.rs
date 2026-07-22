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

use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::time::Duration;

use tillandsias_control_wire::VmPhase;
use tillandsias_host_shell::provisioning::{ProvisionPhase, ProvisionProgress};
use tillandsias_vm_layer::fetch::{RemoteArtifact, download_verified, is_sha256_hex};
use tillandsias_vm_layer::materialize::{
    MaterializedRootfs, oci::flatten_oci_xz, tar_to_wsl_import,
};
use tillandsias_vm_layer::recipe::Manifest;
use tillandsias_vm_layer::{VmRuntime, wsl::WslRuntime};

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
pub const RECIPE_MANIFEST: &str = include_str!("../../../images/vm/manifest.toml");

/// SELinux policy sources for the tillandsias-headless domain and the Vault
/// container domain. Embedded at build time so the installed, checkout-free
/// tray can write them into the Fedora 44 VM during `inject_bootstrap_logic`.
///
/// Policy is compiled in-VM via `make -f /usr/share/selinux/devel/Makefile`
/// (requires `selinux-policy-devel`, installed by `ensure_base_packages`).
/// The installation step is conditional on `getenforce` returning Permissive
/// or Enforcing — it is a no-op while SELinux remains Disabled.
///
/// @trace plan/issues/selinux-zero-trust-vsock-policy-design-2026-06-29.md (Phase 3d)
const SELINUX_HEADLESS_TE: &str = include_str!("../../../images/selinux/tillandsias_headless.te");
const SELINUX_HEADLESS_FC: &str = include_str!("../../../images/selinux/tillandsias_headless.fc");
const SELINUX_HEADLESS_IF: &str = include_str!("../../../images/selinux/tillandsias_headless.if");
const SELINUX_VAULT_TE: &str = include_str!("../../../images/selinux/tillandsias_vault.te");
const SELINUX_VAULT_FC: &str = include_str!("../../../images/selinux/tillandsias_vault.fc");

/// Staged guest headless binaries (order 190 windows half, order 282).
/// `scripts/build-windows-tray.ps1` copies non-empty artifacts from
/// `target-guest/` (the scripts/build-guest-binaries.sh staging contract)
/// into `assets/` before compiling; `build.rs` touches zero-byte
/// placeholders otherwise so `include_bytes!` always compiles. Empty slice
/// = no staged artifact for that arch = the in-VM fetch-headless release
/// download stays the provisioning path (`inject_bootstrap_logic`).
const EMBEDDED_HEADLESS_X86_64: &[u8] =
    include_bytes!("../assets/tillandsias-headless-x86_64-unknown-linux-musl");
const EMBEDDED_HEADLESS_AARCH64: &[u8] =
    include_bytes!("../assets/tillandsias-headless-aarch64-unknown-linux-musl");

/// The single WSL2 distro the tray manages (see `tillandsias-vm-layer::wsl`,
/// "one distro per host"). Also the `wsl.exe -d <name>` target the Open-Shell
/// terminal attaches to. Aliases the vm-layer const so the order-312 stdio
/// bridge and the tray can never drift to different distros.
pub const DISTRO_NAME: &str = tillandsias_vm_layer::wsl::DEFAULT_WSL_DISTRO;

/// Attempts for the control-wire connect loop (see `connect_with_backoff`).
/// With `connect_backoff_delay`'s 1,2,4,8,16,30…30s capped-exponential
/// schedule this keeps the historical ~3-minute total budget.
const CONNECT_ATTEMPTS: u32 = 10;

/// Delay after connect attempt `attempt` (1-based): doubles from 1s and
/// caps at 30s. Pure so the schedule is unit-testable.
fn connect_backoff_delay(attempt: u32) -> Duration {
    let exp = 1u64 << attempt.saturating_sub(1).min(5);
    Duration::from_secs(exp.min(30))
}

/// Build a background `wsl.exe` command with CREATE_NO_WINDOW applied.
/// From the GUI-subsystem tray a raw console child flashes a visible window
/// per invocation — the operator-reported "terminals popping open and
/// closing" (2026-07-12). Interactive lane terminals go through
/// `spawn_wsl_terminal` (CREATE_NEW_CONSOLE) instead, never through this.
/// @trace spec:no-terminal-flicker
fn wsl_cmd() -> tokio::process::Command {
    let mut cmd = tokio::process::Command::new("wsl");
    tillandsias_vm_layer::no_window_async(&mut cmd);
    cmd
}

/// A guard that aborts the supervised keepalive task when dropped.
pub struct KeepaliveGuard {
    abort_handle: tokio::task::AbortHandle,
    /// Fires `Some(reason)` exactly once if the supervisor gives up (order
    /// 417 terminal failed state). Holders that own a UX surface watch this
    /// to flip the tray into the failed state; connect-window holders that
    /// drop the guard quickly may ignore it.
    terminal_rx: tokio::sync::watch::Receiver<Option<String>>,
}

impl KeepaliveGuard {
    pub fn terminal_rx(&self) -> tokio::sync::watch::Receiver<Option<String>> {
        self.terminal_rx.clone()
    }
}

impl Drop for KeepaliveGuard {
    fn drop(&mut self) {
        self.abort_handle.abort();
    }
}

/// Order 417 (windows-vm-launch-keepalive-loop-bound): bounded supervision
/// for the keepalive respawn loop. The old loop respawned `wsl.exe` every 1s
/// FOREVER; against a distro that can never come up (partial import,
/// kernel/WSL mismatch), every respawn re-poked the WSL2 VM create — the
/// field crash-loop. Consecutive rapid failures back off exponentially
/// (1..60s cap) and give up into a terminal failed state after the cap; a
/// child that stayed alive ≥ [`KEEPALIVE_HEALTHY_RUN_SECS`] resets the
/// counter, so a long-healthy keepalive dying (VM idle, user kill) still
/// respawns promptly (the supervision half of
/// plan/issues/keepalive-terminal-visibility-2026-07-02.md).
const KEEPALIVE_MAX_CONSECUTIVE_FAILURES: u32 = 8;

/// A keepalive child that lived at least this long counts as a healthy run
/// and resets the consecutive-failure counter.
const KEEPALIVE_HEALTHY_RUN_SECS: u64 = 60;

/// Delay before respawn attempt after `consecutive_failures` rapid failures
/// (1-based): doubles from 1s, caps at 60s. Pure for unit pinning.
fn keepalive_backoff_delay(consecutive_failures: u32) -> Duration {
    let exp = 1u64 << consecutive_failures.saturating_sub(1).min(6);
    Duration::from_secs(exp.min(60))
}

/// What the supervisor should do after a keepalive child failed.
#[derive(Debug, PartialEq, Eq)]
enum KeepaliveDecision {
    RetryAfter(Duration),
    GiveUp,
}

/// Pure consecutive-failure state machine backing the keepalive loop, so the
/// bound + reset semantics are unit-testable without spawning wsl.exe.
struct KeepaliveSupervisor {
    consecutive_failures: u32,
}

impl KeepaliveSupervisor {
    fn new() -> Self {
        Self {
            consecutive_failures: 0,
        }
    }

    /// The child ran long enough to count as healthy; forget prior failures.
    fn record_healthy_run(&mut self) {
        self.consecutive_failures = 0;
    }

    fn record_failure(&mut self) -> KeepaliveDecision {
        self.consecutive_failures += 1;
        if self.consecutive_failures >= KEEPALIVE_MAX_CONSECUTIVE_FAILURES {
            KeepaliveDecision::GiveUp
        } else {
            KeepaliveDecision::RetryAfter(keepalive_backoff_delay(self.consecutive_failures))
        }
    }
}

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
            runtime: WslRuntime::new(DISTRO_NAME, Self::install_root()),
        }
    }

    /// The managed distro's name — the `wsl.exe -d <name>` attach target.
    pub fn distro_name(&self) -> &str {
        &self.runtime.distro_name
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
        Self::cache_root().join(format!("rootfs-fedora-44-{}.oci.tar.xz", sha256_short))
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

    /// Spawn a keepalive `wsl --exec` session that holds the WSL2 utility VM
    /// open. The background task supervises it and respawns it if killed —
    /// BOUNDED (order 417): consecutive rapid failures back off exponentially
    /// and give up into a terminal failed state (watch `terminal_rx`) instead
    /// of re-poking wsl.exe every second forever. A classified-fatal platform
    /// failure short-circuits with no respawn at all. The caller holds the
    /// returned `KeepaliveGuard` for the tray's lifetime; dropping it aborts
    /// the task and lets the VM idle normally again.
    pub fn spawn_keepalive(&self, debug: bool) -> Result<KeepaliveGuard, String> {
        let distro_name = self.runtime.distro_name.clone();
        let (terminal_tx, terminal_rx) = tokio::sync::watch::channel(None::<String>);
        let handle = tokio::spawn(async move {
            let mut supervisor = KeepaliveSupervisor::new();
            loop {
                // Install root is unused by spawn_keepalive, so dummy path is fine.
                let runtime = WslRuntime::new(&distro_name, std::path::PathBuf::new());
                let started = std::time::Instant::now();
                let failure = match runtime.spawn_keepalive(debug) {
                    Ok(mut child) => match child.wait().await {
                        Ok(status) => format!("keepalive wsl.exe exited with status {status}"),
                        Err(e) => format!("keepalive wsl.exe failed to wait: {e}"),
                    },
                    Err(e) => {
                        let text = e.to_string();
                        if tillandsias_vm_layer::wsl::classified_short_status(&text).is_some() {
                            // This platform state (WSL absent / reboot pending /
                            // virtualization off) can NEVER succeed by retrying —
                            // give up immediately, zero respawns (417 criterion 2).
                            tracing::error!(
                                error = %text,
                                "keepalive hit a classified-fatal platform failure; not respawning"
                            );
                            let _ = terminal_tx.send(Some(text));
                            return;
                        }
                        format!("failed to spawn keepalive wsl.exe: {text}")
                    }
                };
                if started.elapsed() >= Duration::from_secs(KEEPALIVE_HEALTHY_RUN_SECS) {
                    supervisor.record_healthy_run();
                }
                match supervisor.record_failure() {
                    KeepaliveDecision::RetryAfter(delay) => {
                        tracing::warn!(
                            consecutive_failures = supervisor.consecutive_failures,
                            delay_s = delay.as_secs(),
                            failure = %failure,
                            "keepalive died; respawning after backoff"
                        );
                        tokio::time::sleep(delay).await;
                    }
                    KeepaliveDecision::GiveUp => {
                        // ERROR relays to tray.log + Windows Event Log, so
                        // this terminal state is discoverable post-hoc.
                        tracing::error!(
                            consecutive_failures = supervisor.consecutive_failures,
                            failure = %failure,
                            "keepalive gave up after repeated rapid failures — \
                             not respawning (crash-loop guard); VM may idle out"
                        );
                        let _ = terminal_tx.send(Some(format!(
                            "VM keepalive stopped after {} failed restarts: {failure}",
                            supervisor.consecutive_failures
                        )));
                        return;
                    }
                }
            }
        });
        Ok(KeepaliveGuard {
            abort_handle: handle.abort_handle(),
            terminal_rx,
        })
    }

    /// Graceful shutdown — issued by the tray on Quit. The host-shell's
    /// `VmLifecycle::stop` is the production entry point; this wrapper
    /// exists for callers that don't want the full `VmLifecycle` machinery.
    pub async fn graceful_shutdown(&self) -> Result<(), String> {
        let lock_path = Self::install_root().join("drain.lock");
        if let Err(e) = tokio::fs::write(&lock_path, b"draining").await {
            tracing::warn!("Failed to write drain lock: {e}");
        }
        let res = self.runtime.stop(Duration::from_secs(30)).await;
        let _ = tokio::fs::remove_file(&lock_path).await;
        res
    }

    /// Recipe-path first-run provisioning — the **w11 Fedora pivot**. Supersedes the
    /// legacy OCI-base + separate-binary path:
    ///
    /// 1. `SettingUp` — ensure cache/install dirs.
    /// 2. `DownloadingRootfs` — resolve the official Fedora 44 Container OCI
    ///    archive and `download_verified` it (SHA-gated; resumable).
    /// 3. `InstallingTillandsias` — flatten the OCI layers into a rootfs tar,
    ///    then `wsl --import`. Post-import, inject `wsl.conf` and the bootstrap script
    ///    that curl-installs `tillandsias-headless` on first boot.
    /// 4. `StartingVm` — `WslRuntime::start`.
    ///
    /// @trace plan/issues/rootfs-removal-fedora-wsl-pivot-2026-06-02.md (w11 flip),
    /// spec:vm-provisioning-lifecycle.provision.first-run-downloads@v2
    pub async fn provision_via_recipe(
        &self,
        progress: Arc<dyn ProvisionProgress>,
    ) -> Result<(), String> {
        // R1: observe drain path (wait for drain.lock if it exists)
        let lock_path = Self::install_root().join("drain.lock");
        if lock_path.exists() {
            tracing::info!("WSL VM is currently draining, waiting for teardown to finish...");
            let start_time = std::time::Instant::now();
            while lock_path.exists() {
                if start_time.elapsed().as_secs() > 20 {
                    tracing::warn!("Drain lock timed out, proceeding anyway");
                    break;
                }
                tokio::time::sleep(Duration::from_millis(500)).await;
            }
        }

        progress.report_phase(ProvisionPhase::SettingUp);
        tokio::fs::create_dir_all(Self::cache_root())
            .await
            .map_err(|e| format!("create cache_root failed: {e}"))?;
        tokio::fs::create_dir_all(Self::install_root())
            .await
            .map_err(|e| format!("create install_root failed: {e}"))?;

        // Idempotent: if a prior run already imported the distro, skip the
        // download + `wsl --import` and just (re)start it, then connect to
        // deliver credentials so the headless can bootstrap vault.
        //
        // Order 418 (windows-registered-distro-integrity-probe): registration
        // is a bare name match — a partial/corrupt import (first run killed
        // mid-provision) still LISTS, and every relaunch then fed a dead
        // distro to start()+keepalive: the second crash-loop vector. Trust
        // the fast path only when the distro passes an actual exec probe;
        // otherwise self-heal ONCE by discarding the damaged guest and
        // falling through to a fresh import (ephemeral-by-design: the guest
        // is disposable, plan/issues/guest-crashloop-detection-and-ephemeral-reset-2026-07-17.md).
        if self.runtime.is_registered().await {
            if self.distro_exec_probe().await {
                // Adopt pre-marker healthy installs: probe green is the truth.
                self.write_import_complete_marker().await;
                progress.report_phase(ProvisionPhase::StartingVm);
                self.runtime.start().await?;
                progress.report_phase(ProvisionPhase::Connecting);
                const CW_PORT: u32 = tillandsias_control_wire::transport::CONTROL_WIRE_VSOCK_PORT;
                let _keepalive = self.spawn_keepalive(false).ok();
                return self.connect_with_backoff(CW_PORT).await;
            }
            let marker = Self::import_complete_marker_path();
            tracing::error!(
                marker_present = marker.exists(),
                "registered WSL distro failed the exec probe — treating the \
                 guest as damaged and reprovisioning from scratch (one-shot \
                 self-heal; the guest is disposable by design)"
            );
            progress.report_message(
                "\u{267B}\u{FE0F} Local VM is damaged — reprovisioning from scratch...",
            );
            self.unregister_distro().await?;
            let _ = tokio::fs::remove_file(&marker).await;
            // Fall through to the full download + import path below.
        }

        let manifest = Manifest::from_toml(RECIPE_MANIFEST)
            .map_err(|e| format!("parse embedded recipe manifest: {e}"))?;
        let artifact = recipe_rootfs_artifact(&manifest)?;

        progress.report_phase(ProvisionPhase::DownloadingRootfs);
        let cache_root = Self::cache_root();
        let xz_dest = cache_root.join("rootfs").join(format!(
            "fedora-44-wsl-{}.oci.tar.xz",
            &artifact.sha256[..12]
        ));

        let progress_for_cb = progress.clone();
        let last_pct = std::sync::atomic::AtomicU8::new(101);
        let on_progress = move |downloaded: u64, total: Option<u64>| {
            let Some(total) = total.filter(|t| *t > 0) else {
                return;
            };
            let pct = (downloaded.saturating_mul(100) / total).min(100) as u8;
            if last_pct.swap(pct, std::sync::atomic::Ordering::Relaxed) == pct {
                return;
            }
            let mb = downloaded / (1024 * 1024);
            let total_mb = total / (1024 * 1024);
            progress_for_cb.report_message(&format!(
                "\u{1F535} Downloading Fedora rootfs {mb} / {total_mb} MB ({pct}%)"
            ));
        };
        download_verified(&artifact, &xz_dest, &on_progress).await?;

        progress.report_phase(ProvisionPhase::InstallingTillandsias);
        progress.report_message("\u{1F4E6} Flattening Fedora OCI image...");
        let tar_dest = xz_dest.with_file_name(format!(
            "fedora-44-wsl-{}.rootfs.tar",
            &artifact.sha256[..12]
        ));
        if !tar_dest.exists() {
            let source = xz_dest.clone();
            let destination = tar_dest.clone();
            tokio::task::spawn_blocking(move || flatten_oci_xz(&source, &destination))
                .await
                .map_err(|e| format!("Fedora OCI flatten task failed: {e}"))?
                .map_err(|e| format!("flatten Fedora OCI archive failed: {e}"))?;
        }

        tar_to_wsl_import(
            "tillandsias",
            &Self::install_root(),
            &MaterializedRootfs::Tar(tar_dest),
        )
        .await?;

        // The Fedora Container Base OCI image is init-less and minimal: it ships
        // no systemd (so `systemctl enable` in inject_bootstrap_logic exits 127),
        // no podman (the in-VM forge runtime), and no dbus (systemd-logind — and
        // thus the user-runtime lane's XDG_RUNTIME_DIR — needs it). Install them
        // BEFORE configure_recipe_distro flips wsl.conf to systemd-as-PID1, so the
        // post-flip boot actually finds a systemd to run.
        // @trace plan/issues/smoke-e2e-findings-v0.3.260614.1-2026-06-14.md
        //   (smoke-finding/container-base-missing-systemd-podman)
        progress.report_message("\u{1F4E6} Installing systemd + podman in Fedora base...");
        self.ensure_base_packages().await?;

        // Fedora official images need wsl.conf for systemd, and our bootstrap
        // units for the vsock control wire.
        progress.report_message("\u{2699}\u{FE0F} Configuring Fedora distro...");
        self.runtime.configure_recipe_distro().await?;
        self.inject_bootstrap_logic().await?;

        // Provisioning is complete only past this point; the marker gates the
        // registered fast path on future launches (order 418). An interrupted
        // run leaves no marker AND fails the exec probe, so it re-imports.
        self.write_import_complete_marker().await;

        progress.report_phase(ProvisionPhase::StartingVm);
        self.runtime.start().await?;

        progress.report_phase(ProvisionPhase::Connecting);
        const CW_PORT: u32 = tillandsias_control_wire::transport::CONTROL_WIRE_VSOCK_PORT;

        // Hold a keepalive across the connect loop so the VM doesn't idle out mid-wait.
        let _keepalive = self.spawn_keepalive(false).ok();

        self.connect_with_backoff(CW_PORT).await
    }

    /// Marker written at the end of a COMPLETE provision (import + packages +
    /// configure + bootstrap injection). Its absence on a registered distro
    /// marks a suspect (interrupted) import. Order 418.
    fn import_complete_marker_path() -> PathBuf {
        Self::install_root().join(".import-complete")
    }

    /// Best-effort: the marker is an optimization hint, never a hard gate on
    /// success paths — the exec probe is the authority.
    async fn write_import_complete_marker(&self) {
        let content = format!("{}\n", env!("WORKSPACE_VERSION"));
        if let Err(e) = tokio::fs::write(Self::import_complete_marker_path(), content).await {
            tracing::warn!(error = %e, "could not write import-complete marker");
        }
    }

    /// Cheap integrity probe for a registered distro: can it actually exec?
    /// `wsl -d <distro> --exec /bin/true` (hidden window, 60s cap — first
    /// exec may boot the utility VM). A partial/corrupt import errors out;
    /// a healthy distro exits 0. Timeout counts as failure.
    async fn distro_exec_probe(&self) -> bool {
        let fut = wsl_cmd()
            .args(["-d", self.distro_name(), "--exec", "/bin/true"])
            .status();
        match tokio::time::timeout(Duration::from_secs(60), fut).await {
            Ok(Ok(status)) => status.success(),
            Ok(Err(e)) => {
                tracing::warn!(error = %e, "distro exec probe failed to spawn wsl.exe");
                false
            }
            Err(_) => {
                tracing::warn!("distro exec probe timed out after 60s");
                false
            }
        }
    }

    /// Intentional EPHEMERAL RESET, wipe half (windows-260717-4): terminate
    /// the guest (bounded graceful stop), `wsl --unregister` it — deleting
    /// the distro, its VHDX, and with it the in-VM vault — and clear the
    /// import-complete marker. Destructive BY DESIGN per the operator's
    /// ephemeral doctrine ("rebuild and reprovision from scratch as needed,
    /// destructive ok"): state of value lives in the cloud + the operator's
    /// auth, so the only cost is one re-authentication. Callers follow up
    /// with the exact same `provision_via_recipe` first-provision path,
    /// which initializes vault cleanly (the windows-260717-2 regeneration
    /// bug bites only on re-ensure, never on first init).
    ///
    /// @trace plan/issues/guest-crashloop-detection-and-ephemeral-reset-2026-07-17.md
    pub async fn wipe_guest(&self) -> Result<(), String> {
        // Best-effort bounded stop first so the unregister doesn't race a
        // live utility VM; a failed stop is logged and the unregister
        // proceeds anyway (a wedged guest is precisely the reset use-case).
        if let Err(e) = self.graceful_shutdown().await {
            tracing::warn!(error = %e, "graceful stop before guest wipe failed; unregistering anyway");
        }
        if self.runtime.is_registered().await {
            self.unregister_distro().await?;
        } else {
            tracing::info!(
                distro = self.distro_name(),
                "guest wipe: no registered distro — nothing to unregister"
            );
        }
        let _ = tokio::fs::remove_file(Self::import_complete_marker_path()).await;
        Ok(())
    }

    /// Discard the damaged guest: `wsl --shutdown`-free targeted unregister
    /// (deletes the distro + its VHDX). Called after a failed integrity
    /// probe (one-shot self-heal) and by the user-invoked `wipe_guest`
    /// reset path, both on the ephemeral-reset doctrine.
    async fn unregister_distro(&self) -> Result<(), String> {
        let status = wsl_cmd()
            .args(["--unregister", self.distro_name()])
            .status()
            .await
            .map_err(|e| format!("wsl --unregister failed to spawn: {e}"))?;
        if status.success() {
            tracing::info!(distro = self.distro_name(), "damaged distro unregistered");
            Ok(())
        } else {
            Err(format!(
                "wsl --unregister {} exited with {status} — cannot self-heal; \
                 run the installer with -Purge or `wsl --unregister {}` manually",
                self.distro_name(),
                self.distro_name()
            ))
        }
    }

    /// Connect-until-ready with capped exponential backoff (operator
    /// directive 2026-07-18: every retry loop backs off exponentially).
    /// Fast first probes catch the common quick bring-up; later waits grow
    /// 1→2→4→8→16→30s (cap) so a wedged guest is re-poked ever more gently
    /// instead of on a fixed drumbeat. Total sleep budget ≈181s — the same
    /// ~3-minute envelope as the old fixed 36×5s loop. Schedule pinned by
    /// `connect_backoff_schedule_is_capped_exponential`.
    async fn connect_with_backoff(&self, port: u32) -> Result<(), String> {
        let mut last_err = String::from("(no attempt)");
        for attempt in 1..=CONNECT_ATTEMPTS {
            match self.try_connect_until_ready(port, attempt).await {
                Ok(VmPhase::Ready) | Ok(VmPhase::Starting) => return Ok(()),
                Ok(other) => last_err = format!("VM in phase {other:?}"),
                Err(e) => last_err = e,
            }
            if attempt < CONNECT_ATTEMPTS {
                let delay = connect_backoff_delay(attempt);
                tracing::info!(
                    attempt,
                    delay_s = delay.as_secs(),
                    last = %last_err,
                    "control wire not ready; backing off"
                );
                tokio::time::sleep(delay).await;
            }
        }
        Err(format!(
            "control-wire handshake did not succeed within budget: {last_err}"
        ))
    }

    /// Install + configure what the Fedora **Container Base** OCI image lacks
    /// but a working in-VM tillandsias runtime needs. That image is init-less
    /// and stripped, so a clean import has none of:
    ///   * `systemd` — WSL boots it as PID1 (wsl.conf `systemd=true`) and runs
    ///     the headless units; without it `systemctl enable` exits 127.
    ///   * `podman` — the in-VM forge/container runtime.
    ///   * `dbus-broker` — `systemd-logind` needs it, and logind in turn provides
    ///     the user-runtime lane's `/run/user/<uid>` (XDG_RUNTIME_DIR).
    ///   * `newuidmap`/`newgidmap` filecaps — container images strip the setuid
    ///     caps `shadow-utils` ships, so rootless podman dies with
    ///     "newuidmap: write to uid_map failed: Operation not permitted". Restore
    ///     them with `setcap`.
    ///   * `openssl` CLI — enclave bring-up shells out to `openssl req` to mint
    ///     the Vault HTTPS CA; the minimal base has the libs but not the binary,
    ///     so without it init dies "bringing Vault up: ... (os error 2)".
    ///
    /// Runs BEFORE `configure_recipe_distro` flips wsl.conf to systemd-as-PID1,
    /// so the post-flip boot actually finds a systemd to run. Idempotent: `rpm -q`
    /// guards the install and `setcap` is safe to repeat, so the registered-distro
    /// fast path and re-provision stay cheap.
    ///
    /// @trace plan/issues/smoke-e2e-findings-v0.3.260614.1-2026-06-14.md
    ///   (smoke-finding/container-base-missing-systemd-podman)
    async fn ensure_base_packages(&self) -> Result<(), String> {
        // Phase 3a: include SELinux packages so `inject_bootstrap_logic` can
        // install the policy modules and `getenforce` becomes available.
        // `socat` is added for Phase 5 vsock-in-vsock loopback tests.
        const SETUP: &str = r#"set -e
rpm -q systemd podman dbus-broker libcap shadow-utils openssl \
    selinux-policy-targeted policycoreutils selinux-policy-devel checkpolicy socat \
    >/dev/null 2>&1 || \
  dnf install -y systemd podman dbus-broker libcap shadow-utils openssl \
    selinux-policy-targeted policycoreutils selinux-policy-devel checkpolicy socat
for b in /usr/bin/newuidmap /usr/sbin/newuidmap; do [ -e "$b" ] && setcap cap_setuid+ep "$b" || true; done
for b in /usr/bin/newgidmap /usr/sbin/newgidmap; do [ -e "$b" ] && setcap cap_setgid+ep "$b" || true; done
"#;
        tokio::time::timeout(Duration::from_secs(300), self.wsl_root_sh(SETUP))
            .await
            .map_err(|_| {
                "Package installation timed out after 5 min — WSL2 DNS may be broken".to_string()
            })?
    }

    async fn inject_bootstrap_logic(&self) -> Result<(), String> {
        // Detect guest architecture
        let arch_output = wsl_cmd()
            .arg("-d")
            .arg(DISTRO_NAME)
            .arg("-u")
            .arg("root")
            .arg("--")
            .arg("uname")
            .arg("-m")
            .output()
            .await
            .map_err(|e| format!("failed to detect guest architecture: {e}"))?;
        let arch = String::from_utf8_lossy(&arch_output.stdout)
            .trim()
            .to_string();

        let embedded_bin: &[u8] = match arch.as_str() {
            "x86_64" => EMBEDDED_HEADLESS_X86_64,
            "aarch64" => EMBEDDED_HEADLESS_AARCH64,
            _ => &[],
        };

        if !embedded_bin.is_empty() {
            tracing::info!(%arch, "Injecting embedded tillandsias-headless binary");
            self.wsl_root_write_bytes("/usr/local/bin/tillandsias-headless", embedded_bin, true)
                .await?;

            // Write a no-op fetch-headless.sh so the fetch systemd service compiles and runs cleanly
            self.wsl_root_write(
                "/usr/local/lib/tillandsias/fetch-headless.sh",
                "#!/usr/bin/env bash\nexit 0\n",
                true,
            )
            .await?;
        } else {
            // Absent-asset fallback (order 190 step 3): without a staged
            // binary the guest fetches the LATEST RELEASE, which can be an
            // older wire revision than this tray (version skew — the order
            // 282 trigger). Loud so smoke logs show which lane provisioned.
            tracing::warn!(
                %arch,
                "no embedded tillandsias-headless asset for this arch; guest will \
                 fetch the latest release (version skew possible — stage via \
                 scripts/build-guest-binaries.sh before scripts/build-windows-tray.ps1)"
            );
            // 1. fetch-headless.sh — pinned to THIS tray's version, never
            // `releases/latest` (= newest STABLE by GitHub semantics). The
            // latest-URL fallback is how the v0.3.260719.1 field install got
            // a v0.3.260712.1 guest: CI ships the tray without staged guest
            // binaries, the guest fetched the stable, and every
            // already-fixed guest bug (inference --replace collisions, lane
            // crashes) resurfaced under a new tray. Version skew is worse
            // than a failed fetch — a missing same-version asset must fail
            // loud, not silently downgrade the wire.
            let fetch_script = format!(
                r#"#!/usr/bin/env bash
set -euo pipefail
DEST="/usr/local/bin/tillandsias-headless"
if [[ -x "$DEST" ]]; then exit 0; fi
ARCH="$(uname -m)"
URL="https://github.com/8007342/tillandsias/releases/download/v{version}/tillandsias-headless-${{ARCH}}-unknown-linux-musl"
TMP="$(mktemp)"
trap 'rm -f "$TMP"' EXIT
curl --fail --location --retry 5 --retry-delay 3 --connect-timeout 20 --output "$TMP" "$URL"
install -D -m 0755 "$TMP" "$DEST"
"#,
                version = env!("WORKSPACE_VERSION")
            );
            self.wsl_root_write(
                "/usr/local/lib/tillandsias/fetch-headless.sh",
                &fetch_script,
                true,
            )
            .await?;
        }

        // 2. headless-preflight.sh
        let preflight_script = r#"#!/usr/bin/env bash
set -euo pipefail
DEST="/usr/local/bin/tillandsias-headless"
if [[ ! -x "$DEST" ]]; then
  echo "[tillandsias-preflight] headless_binary=missing"
  exit 1
fi
echo "[tillandsias-preflight] headless_binary=ok"
if [[ ! -e /dev/vsock ]]; then
  echo "[tillandsias-preflight] vsock_device=missing"
  exit 1
fi
echo "[tillandsias-preflight] vsock_device=present"
if [[ -S /run/podman/podman.sock ]]; then
  echo "[tillandsias-preflight] podman_socket=present"
else
  echo "[tillandsias-preflight] podman_socket=missing"
fi
if systemctl is-active --quiet podman.socket; then
  echo "[tillandsias-preflight] podman_socket_unit=active"
else
  echo "[tillandsias-preflight] podman_socket_unit=inactive"
fi
"#;
        self.wsl_root_write(
            "/usr/local/lib/tillandsias/headless-preflight.sh",
            preflight_script,
            true,
        )
        .await?;

        // 3. tillandsias-headless-fetch.service
        let fetch_unit = r#"[Unit]
Description=Ensure tillandsias-headless is present
After=network-online.target
Wants=network-online.target
Before=tillandsias-headless.service
[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/lib/tillandsias/fetch-headless.sh
TimeoutStartSec=300s
StandardOutput=journal+console
StandardError=journal+console
[Install]
WantedBy=multi-user.target
"#;
        self.wsl_root_write(
            "/etc/systemd/system/tillandsias-headless-fetch.service",
            fetch_unit,
            false,
        )
        .await?;

        // 4. tillandsias-headless.service
        //
        // No NoNewPrivileges / CapabilityBoundingSet here: the headless
        // ORCHESTRATES rootful podman in-guest, and a cap-stripped uid-0
        // process makes podman select rootless mode (empty store, pause-
        // process fatals) — every vault/lane ensure exits 125 in a 2s loop
        // while tray-driven wsl.exe flows keep working, so the tray latches
        // on "securing vault" forever. Confining the vsock listener is a
        // separate packet (split units / socket delegation); see
        // plan/issues/headless-podman-events-watcher-rootless-wedge-2026-07-12.md.
        let headless_unit = r#"[Unit]
Description=Tillandsias headless (in-VM vsock control wire)
After=network-online.target podman.socket tillandsias-headless-fetch.service
Wants=network-online.target podman.socket
Requires=tillandsias-headless-fetch.service
[Service]
Type=exec
ExecStartPre=/usr/bin/mkdir -p /run/user/0
ExecStartPre=/usr/bin/chmod 0700 /run/user/0
ExecStartPre=/usr/local/lib/tillandsias/headless-preflight.sh
Environment=HOME=/root
Environment=XDG_RUNTIME_DIR=/run/user/0
Environment=TILLANDSIAS_VAULT_API_BASE_URL=https://vault:8200
ExecStart=/usr/local/bin/tillandsias-headless --listen-vsock 42420
Restart=on-failure
RestartSec=2s
StandardOutput=journal+console
StandardError=journal+console
[Install]
WantedBy=multi-user.target
"#;
        self.wsl_root_write(
            "/etc/systemd/system/tillandsias-headless.service",
            headless_unit,
            false,
        )
        .await?;

        // 5. home-forge-src.mount — targeted drvfs mount of the HOST's
        // `%USERPROFILE%\src` at the in-VM project bind-mount convention
        // `/home/forge/src` (see tillandsias-headless
        // `TILLANDSIAS_IN_VM_PROJECT_ROOT`, default `/home/forge/src`).
        //
        // This is the Windows half of the cross-host contract: macOS mounts
        // the user's ~/src via virtio-fs; Windows mounts via drvfs (9p).
        // Global automount stays DISABLED (`[automount] enabled=false` in
        // wsl.conf, zero-trust posture) — only the src tree is exposed.
        // Cloud checkouts (`tillandsias-headless --cloud owner/repo`) land
        // here, i.e. directly in the host's ~/src, and the forge container
        // volume-mounts the per-project subdir — host→VM→container, the same
        // transparent chain as the Linux native tray's local ~/src.
        //
        // Unit name MUST be the systemd-escaped Where= path
        // (/home/forge/src → home-forge-src.mount) or systemd refuses it.
        // @trace spec:host-shell-architecture, spec:remote-projects
        if let Ok(profile) = std::env::var("USERPROFILE") {
            let host_src = format!("{}\\src", profile.trim_end_matches('\\'));
            let mount_unit = format!(
                "[Unit]\n\
                 Description=Host ~/src (drvfs) at the in-VM project root convention\n\
                 [Mount]\n\
                 What={host_src}\n\
                 Where=/home/forge/src\n\
                 Type=drvfs\n\
                 Options=rw,noatime,metadata\n\
                 [Install]\n\
                 WantedBy=multi-user.target\n"
            );
            self.wsl_root_write(
                "/etc/systemd/system/home-forge-src.mount",
                &mount_unit,
                false,
            )
            .await?;
        } else {
            tracing::warn!("USERPROFILE not set; skipping home-forge-src.mount injection");
        }

        // Enable AND start the units now. `inject_bootstrap_logic` runs after
        // `configure_recipe_distro` has already flipped wsl.conf to
        // systemd-as-PID1, so by this point systemd is up and multi-user.target
        // is already reached. A bare `systemctl enable` only writes the
        // WantedBy symlinks; it does NOT start a unit whose target was already
        // active this boot. The subsequent `runtime.start()` is a no-op on an
        // already-running distro, so without `--now` the headless-fetch +
        // headless units stay `inactive (dead)`, the in-VM binary is never
        // fetched, the vsock control wire never binds, and provision-once hangs
        // in `Connecting` until the budget expires.
        // @trace plan/issues/windows-cold-provision-headless-units-not-started-2026-06-19.md
        self.wsl_root_sh(
            "systemctl daemon-reload && systemctl enable --now podman.socket tillandsias-headless-fetch.service tillandsias-headless.service && \
             { systemctl enable --now home-forge-src.mount 2>/dev/null || true; }",
        )
        .await?;

        // Phase 3d: write SELinux policy files into the VM so they are present
        // when SELinux is eventually enabled (Phase 6). The compilation and
        // `semodule -i` step below is conditional: it is a no-op today (SELinux
        // is Disabled in the Fedora 44 Container Base) and activates automatically
        // once `selinux=1` is added to the WSL2 kernel command line.
        //
        // @trace plan/issues/selinux-zero-trust-vsock-policy-design-2026-06-29.md (Phase 3d)
        // @trace plan/issues/vsock-postmortem-host-guest-design-audit-2026-06-29.md (H12)
        let selinux_dir = "/usr/local/lib/tillandsias/selinux";
        self.wsl_root_sh(&format!("mkdir -p {selinux_dir}")).await?;
        for (filename, content) in [
            ("tillandsias_headless.te", SELINUX_HEADLESS_TE),
            ("tillandsias_headless.fc", SELINUX_HEADLESS_FC),
            ("tillandsias_headless.if", SELINUX_HEADLESS_IF),
            ("tillandsias_vault.te", SELINUX_VAULT_TE),
            ("tillandsias_vault.fc", SELINUX_VAULT_FC),
        ] {
            self.wsl_root_write(&format!("{selinux_dir}/{filename}"), content, false)
                .await?;
        }
        // Conditional: compile + install if SELinux is active (Permissive or Enforcing).
        // On a Disabled system getenforce exits non-zero or prints "Disabled", so the
        // `grep -qiE` fails and the block is skipped entirely.
        self.wsl_root_sh(
            r#"if getenforce 2>/dev/null | grep -qiE '^(Permissive|Enforcing)'; then
    cd /usr/local/lib/tillandsias/selinux && \
    make -f /usr/share/selinux/devel/Makefile tillandsias_headless.pp tillandsias_vault.pp && \
    semodule -i tillandsias_headless.pp tillandsias_vault.pp && \
    semanage permissive -a tillandsias_headless_t 2>/dev/null || true && \
    semanage permissive -a vault_container_t 2>/dev/null || true && \
    { semanage fcontext -a -t vault_data_t '/var/lib/tillandsias/vault-data(/.*)?' || \
      semanage fcontext -m -t vault_data_t '/var/lib/tillandsias/vault-data(/.*)?'; } 2>/dev/null || true && \
    restorecon -Rv /var/lib/tillandsias/vault-data/ 2>/dev/null || true
fi"#,
        )
        .await?;

        // Persist vsock_loopback so it survives WSL2 restarts.
        // CONFIG_VSOCKETS_LOOPBACK=m (confirmed: WSL2 kernel 6.6.114.1).
        // Required for Phase 5 (vsock-in-vsock container transport, CID 1).
        // @trace plan/issues/vsock-kernel-probe-results-2026-06-29.md
        self.wsl_root_sh(
            "echo 'vsock_loopback' > /etc/modules-load.d/tillandsias-vsock.conf && \
             modprobe vsock_loopback 2>/dev/null || true",
        )
        .await?;

        Ok(())
    }

    async fn wsl_root_write(
        &self,
        path: &str,
        content: &str,
        make_executable: bool,
    ) -> Result<(), String> {
        let dir = Path::new(path).parent().unwrap().to_str().unwrap();
        self.wsl_root_sh(&format!("mkdir -p {dir}")).await?;

        let mut child = wsl_cmd()
            .arg("-d")
            .arg(DISTRO_NAME)
            .arg("-u")
            .arg("root")
            .arg("--")
            .arg("sh")
            .arg("-c")
            .arg(format!(
                "cat > {path} && if [ \"{make_executable}\" = \"true\" ]; then chmod +x {path}; fi"
            ))
            .stdin(std::process::Stdio::piped())
            .spawn()
            .map_err(|e| format!("wsl write {path} failed: {e}"))?;

        if let Some(mut stdin) = child.stdin.take() {
            use tokio::io::AsyncWriteExt;
            stdin
                .write_all(content.as_bytes())
                .await
                .map_err(|e| format!("write stdin to {path} failed: {e}"))?;
        }

        let status = child
            .wait()
            .await
            .map_err(|e| format!("wait for wsl write {path} failed: {e}"))?;
        if !status.success() {
            return Err(format!("wsl write {path} exited {status}"));
        }
        Ok(())
    }

    async fn wsl_root_write_bytes(
        &self,
        path: &str,
        content: &[u8],
        make_executable: bool,
    ) -> Result<(), String> {
        let mut child = wsl_cmd()
            .arg("-d")
            .arg(DISTRO_NAME)
            .arg("-u")
            .arg("root")
            .arg("--")
            .arg("sh")
            .arg("-c")
            .arg(format!(
                "cat > {path} && if [ \"{make_executable}\" = \"true\" ]; then chmod +x {path}; fi"
            ))
            .stdin(std::process::Stdio::piped())
            .spawn()
            .map_err(|e| format!("wsl write {path} failed: {e}"))?;

        if let Some(mut stdin) = child.stdin.take() {
            use tokio::io::AsyncWriteExt;
            stdin
                .write_all(content)
                .await
                .map_err(|e| format!("write stdin to {path} failed: {e}"))?;
        }

        let status = child
            .wait()
            .await
            .map_err(|e| format!("wait for wsl write {path} failed: {e}"))?;
        if !status.success() {
            return Err(format!("wsl write {path} exited {status}"));
        }
        Ok(())
    }

    async fn wsl_root_sh(&self, script: &str) -> Result<(), String> {
        let status = wsl_cmd()
            .arg("-d")
            .arg(DISTRO_NAME)
            .arg("-u")
            .arg("root")
            .arg("--")
            .arg("sh")
            .arg("-c")
            .arg(script)
            .status()
            .await
            .map_err(|e| format!("wsl root sh failed: {e}"))?;
        if !status.success() {
            return Err(format!("wsl root sh exited {status} for: {script}"));
        }
        Ok(())
    }

    /// One connect attempt that succeeds only when the VM is **operationally
    /// Ready**: HvSocket handshake → `VmStatusRequest` → require `phase: Ready`.
    /// During first boot the headless reports `Provisioning`/`Starting` while it
    /// self-installs; the caller retries until this returns `Ok`. (Request path
    /// proven E2E: `VmStatusReply { phase: Ready, podman_ready: true }`.)
    ///
    /// Each attempt is bounded by a 30 s `tokio::time::timeout`; if the HvSocket
    /// connect or any RPC stalls (e.g., degraded HCS or half-open connection), the
    /// timeout fires, the attempt returns `Err`, and the retry loop back-offs 5 s
    /// before the next attempt — never hanging the tray indefinitely.
    async fn try_connect_until_ready(&self, port: u32, attempt: u32) -> Result<VmPhase, String> {
        use tillandsias_control_wire::transport::Transport;
        use tillandsias_control_wire::{ControlEnvelope, ControlMessage, WIRE_VERSION};
        use tillandsias_host_shell::vsock_client::Client;

        tokio::time::timeout(Duration::from_secs(30), async {
            // Open the HvSocket transport, then drive the standard host-shell Client
            // (same Hello/HelloAck + request path the macOS tray uses over its
            // VZVirtioSocketConnection stream — slice 4 `80d9196e`).
            let stream = crate::hvsocket::open_and_wrap_hvsocket_stream(port)
                .await
                .map_err(|e| format!("hvsocket open: {e}"))?;
            let mut client = Client::from_stream(stream, Transport::Vsock { cid: 0, port });
            let (wire_version, _guest_version) = client
                .handshake()
                .await
                .map_err(|e| format!("handshake: {e}"))?;
            crate::installation_uuid::deliver_credentials_and_check_handover(&mut client)
                .await
                .map_err(|e| format!("credentials delivery failed: {e}"))?;
            let seq = client.allocate_seq();
            let envelope = ControlEnvelope {
                wire_version: WIRE_VERSION,
                seq,
                body: ControlMessage::VmStatusRequest { seq },
            };
            let reply = client
                .request(&envelope)
                .await
                .map_err(|e| format!("VmStatusRequest: {e}"))?;

            match reply.body {
                ControlMessage::VmStatusReply { phase, .. } => {
                    tracing::info!(
                        wire_version,
                        attempt,
                        "VM handshake success (phase={phase:?})"
                    );
                    // NOTE: `client` is dropped here; promoting the live Client to a
                    // process-wide LIVE_CLIENT for menu actions is Phase 2.
                    Ok(phase)
                }
                other => Err(format!("unexpected reply to VmStatusRequest: {other:?}")),
            }
        })
        .await
        .map_err(|_| format!("attempt {attempt}: connect+handshake timed out after 30s"))?
    }
}

pub(crate) fn user_src_dir() -> PathBuf {
    let base = std::env::var_os("USERPROFILE")
        .map(PathBuf::from)
        .unwrap_or_else(|| PathBuf::from("C:\\Users\\Public"));
    base.join("src")
}

/// Resolve the Windows rootfs artifact (`x86_64.oci.tar.xz`) to a verifiable
/// download pin from the recipe `Manifest` (l9 contract).
///
/// Bridges the recipe `[output]` block's exact URL and
/// `expected_rootfs_sha["x86_64.oci.tar.xz"]` into the [`RemoteArtifact`] that
/// [`download_verified`] consumes.
///
/// @trace plan/issues/rootfs-removal-fedora-wsl-pivot-2026-06-02.md
pub fn recipe_rootfs_artifact(manifest: &Manifest) -> Result<RemoteArtifact, String> {
    const ARCH: &str = "x86_64";
    const FORMAT: &str = "oci.tar.xz";
    const SHA_KEY: &str = "x86_64.oci.tar.xz";

    let url = manifest
        .artifact_url(ARCH, FORMAT, "fedora-pivot")
        .ok_or_else(|| format!("manifest has no artifact URL for \"{SHA_KEY}\""))?;
    let sha = manifest
        .expected_sha(SHA_KEY)
        .ok_or_else(|| format!("manifest [output].expected_rootfs_sha has no \"{SHA_KEY}\" pin"))?;
    if !is_sha256_hex(sha) {
        return Err(format!(
            "rootfs SHA for {SHA_KEY} not yet published (manifest pin = {sha:?})"
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
    fn import_complete_marker_lives_under_install_root() {
        // SAFETY: single-process test env mutation, matching sibling tests.
        unsafe {
            std::env::set_var("LOCALAPPDATA", "C:\\Users\\Tester\\AppData\\Local");
        }
        let marker = WslLifecycle::import_complete_marker_path();
        assert!(marker.starts_with(WslLifecycle::install_root()));
        assert!(marker.ends_with(".import-complete"));
    }

    #[test]
    fn keepalive_supervisor_gives_up_after_cap_with_backoff() {
        let mut sup = KeepaliveSupervisor::new();
        let mut delays = Vec::new();
        let mut give_up_at = None;
        for attempt in 1..=KEEPALIVE_MAX_CONSECUTIVE_FAILURES {
            match sup.record_failure() {
                KeepaliveDecision::RetryAfter(d) => delays.push(d.as_secs()),
                KeepaliveDecision::GiveUp => {
                    give_up_at = Some(attempt);
                    break;
                }
            }
        }
        // Exponential with a ceiling, then a hard give-up — never an
        // unbounded 1s drumbeat (order 417).
        assert_eq!(delays, vec![1, 2, 4, 8, 16, 32, 60]);
        assert_eq!(give_up_at, Some(KEEPALIVE_MAX_CONSECUTIVE_FAILURES));
    }

    #[test]
    fn keepalive_supervisor_healthy_run_resets_failure_count() {
        let mut sup = KeepaliveSupervisor::new();
        for _ in 0..KEEPALIVE_MAX_CONSECUTIVE_FAILURES - 1 {
            let _ = sup.record_failure();
        }
        sup.record_healthy_run();
        // A long-lived child dying afterwards is failure #1 again: prompt
        // 1s respawn, not a give-up — supervision keeps working forever for
        // a healthy-but-occasionally-dying keepalive.
        assert_eq!(
            sup.record_failure(),
            KeepaliveDecision::RetryAfter(Duration::from_secs(1))
        );
    }

    #[test]
    fn connect_backoff_schedule_is_capped_exponential() {
        let secs: Vec<u64> = (1..=CONNECT_ATTEMPTS)
            .map(|a| connect_backoff_delay(a).as_secs())
            .collect();
        assert_eq!(secs, vec![1, 2, 4, 8, 16, 30, 30, 30, 30, 30]);
        // Sleeps happen between attempts only (never after the last), so the
        // worst-case wait stays inside the historical ~3-minute envelope.
        let total: u64 = secs[..(CONNECT_ATTEMPTS as usize - 1)].iter().sum();
        assert!(
            (120..=200).contains(&total),
            "total backoff budget drifted: {total}s"
        );
    }

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

    // A minimal synthetic manifest with a caller-chosen x86_64 OCI archive SHA.
    fn manifest_with_x86_tar_sha(sha: &str) -> Manifest {
        const TMPL: &str = r#"recipe_version = 1
[output.artifact_urls]
"x86_64.oci.tar.xz" = "https://download.fedoraproject.org/pub/fedora/linux/releases/44/Container/x86_64/images/Fedora-Container-Base-Generic-44-1.7.x86_64.oci.tar.xz"
[output.expected_rootfs_sha]
"x86_64.oci.tar.xz" = "__SHA__"
"#;
        Manifest::from_toml(&TMPL.replace("__SHA__", sha)).expect("parse inline manifest")
    }

    #[test]
    fn recipe_rootfs_artifact_resolves_url_and_sha() {
        let sha = "a".repeat(64);
        let m = manifest_with_x86_tar_sha(&sha);
        let art = recipe_rootfs_artifact(&m).expect("resolves with a real SHA");
        assert_eq!(art.sha256, sha);
        assert_eq!(
            art.url,
            "https://download.fedoraproject.org/pub/fedora/linux/releases/44/Container/x86_64/images/Fedora-Container-Base-Generic-44-1.7.x86_64.oci.tar.xz"
        );
    }

    #[test]
    fn wsl_bootstrap_fetch_unit_is_idempotent() {
        let source = include_str!("wsl_lifecycle.rs");
        let fetch_unit = source
            .split("// 3. tillandsias-headless-fetch.service")
            .nth(1)
            .and_then(|tail| tail.split("// 4. tillandsias-headless.service").next())
            .expect("fetch unit window");

        assert!(source.contains("if [[ -x \"$DEST\" ]]; then exit 0; fi"));
        assert!(fetch_unit.contains("Type=oneshot"));
        assert!(fetch_unit.contains("RemainAfterExit=yes"));
        assert!(
            !fetch_unit.contains("ConditionPathExists=!/usr/local/bin/tillandsias-headless"),
            "systemd must run the idempotent fetch oneshot instead of skipping it"
        );
    }

    #[test]
    fn wsl_headless_service_prepares_runtime_env() {
        let source = include_str!("wsl_lifecycle.rs");
        let headless_unit = source
            .split("// 4. tillandsias-headless.service")
            .nth(1)
            .and_then(|tail| tail.split("// Enable AND start the units now.").next())
            .expect("headless unit window");

        assert!(source.contains("cat > {path}"));
        assert!(source.contains("/usr/local/lib/tillandsias/headless-preflight.sh"));
        assert!(source.contains("vsock_device=missing"));
        assert!(source.contains("podman_socket_unit=inactive"));
        assert!(headless_unit.contains("After=network-online.target podman.socket"));
        assert!(headless_unit.contains("Wants=network-online.target podman.socket"));
        assert!(headless_unit.contains("ExecStartPre=/usr/bin/mkdir -p /run/user/0"));
        assert!(headless_unit.contains("ExecStartPre=/usr/bin/chmod 0700 /run/user/0"));
        assert!(
            headless_unit.contains("ExecStartPre=/usr/local/lib/tillandsias/headless-preflight.sh")
        );
        assert!(headless_unit.contains("Environment=HOME=/root"));
        assert!(headless_unit.contains("Environment=XDG_RUNTIME_DIR=/run/user/0"));
        assert!(
            headless_unit.contains("Environment=TILLANDSIAS_VAULT_API_BASE_URL=https://vault:8200")
        );
        assert!(
            !headless_unit.contains("Requires=podman.socket"),
            "podman.socket is a wanted readiness input, not a hard dependency for diagnostics"
        );
        // 2026-07-12: cap-stripping the headless makes uid-0 podman go
        // ROOTLESS (empty store, pause-process fatals) — every vault/lane
        // ensure dies 125 in a 2s loop and the tray latches on "securing
        // vault" while tray-driven wsl.exe flows keep working. The headless
        // unit must keep full root until the listener/orchestrator split
        // lands (headless-podman-events-watcher-rootless-wedge-2026-07-12).
        assert!(
            !headless_unit.contains("NoNewPrivileges="),
            "NoNewPrivileges= breaks headless-driven podman (rootless fallback wedge)"
        );
        assert!(
            !headless_unit.contains("CapabilityBoundingSet="),
            "cap-stripped uid-0 podman selects rootless mode and wedges every ensure"
        );
    }

    /// The network fallback must not curl directly onto the live
    /// `/usr/local/bin/tillandsias-headless` path. Download to a temp file,
    /// then install into place so interrupted writes cannot leave a partial
    /// executable behind.
    ///
    /// @trace plan/issues/race-safeguards-research-2026-07-02.md#r9
    #[test]
    fn wsl_fetch_script_installs_download_via_temp_file() {
        let source = include_str!("wsl_lifecycle.rs");
        let fetch_script = source
            .split("let fetch_script = format!(")
            .nth(1)
            .and_then(|tail| tail.split("\"#,").next())
            .expect("fetch-headless script window");

        assert!(
            fetch_script.contains("TMP=\"$(mktemp)\""),
            "fetch script must create a temp file before downloading"
        );
        // Version-skew guard: the fetch URL must pin THIS tray's release —
        // never `releases/latest`, which resolves to the newest STABLE and
        // provisioned a v0.3.260712.1 guest under a v0.3.260719.1 tray
        // (2026-07-19 field repro: every fixed guest bug resurfaced).
        assert!(
            fetch_script.contains("releases/download/v{version}/"),
            "fetch URL must pin the tray's own version"
        );
        assert!(
            !fetch_script.contains("releases/latest"),
            "fetch URL must never use the stable-only latest alias"
        );
        assert!(
            fetch_script.contains("trap 'rm -f \"$TMP\"' EXIT"),
            "fetch script must clean the temp file"
        );
        assert!(
            fetch_script.contains("--output \"$TMP\" \"$URL\""),
            "curl must write to the temp file, not the live binary"
        );
        assert!(
            fetch_script.contains("install -D -m 0755 \"$TMP\" \"$DEST\""),
            "fetch script must install the temp file into the live path"
        );
        assert!(
            !fetch_script.contains("--output \"$DEST\""),
            "fetch script must not curl directly onto the live binary"
        );
    }

    /// Windows-side half of litmus:guest-binary-embed-integrity (order 282):
    /// a NON-EMPTY embedded guest headless must carry the workspace VERSION
    /// string, so a stale staged binary (built from an older checkout) fails
    /// loud at test time instead of provisioning a version-skewed guest.
    /// Zero-byte placeholders are the sanctioned absent-asset fallback and
    /// pass trivially.
    #[test]
    fn embedded_guest_headless_matches_workspace_version() {
        let version = env!("WORKSPACE_VERSION").as_bytes();
        for (arch, bytes) in [
            ("x86_64", EMBEDDED_HEADLESS_X86_64),
            ("aarch64", EMBEDDED_HEADLESS_AARCH64),
        ] {
            if bytes.is_empty() {
                continue;
            }
            assert!(
                bytes.windows(version.len()).any(|w| w == version),
                "embedded {arch} guest headless does not contain workspace version {} — \
                 stale staged binary; re-run scripts/build-guest-binaries.sh then \
                 scripts/build-windows-tray.ps1",
                env!("WORKSPACE_VERSION")
            );
        }
    }
}
