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

use crate::wsl_probe_policy::{
    DistroExecProbeAttempt, DistroExecProbeClass, DistroExecProbeDecision,
    classify_nonzero_distro_exec, distro_exec_probe_decision,
};

/// The runtime guest's base package set — ONE list, so the `rpm -q` guard and
/// the `dnf install` that follows it cannot drift apart.
///
/// They used to be two hand-maintained spellings of the same set on adjacent
/// lines. A package added to only the guard never installs; a package added to
/// only the install reinstalls on every provision, because the guard never
/// reports it satisfied. Neither failure is loud. Generating both from this
/// array removes the choice rather than policing it.
const GUEST_BASE_PACKAGES: &[&str] = &[
    "systemd",
    "podman",
    "dbus-broker",
    "libcap",
    "shadow-utils",
    "openssl",
    "selinux-policy-targeted",
    "policycoreutils",
    "selinux-policy-devel",
    "checkpolicy",
    // Phase 5 vsock-in-vsock loopback tests.
    "socat",
    // Order 807-c3mf: scripts/bench-accel-lane.sh needs curl AND jq. The guest
    // shipped curl but not jq, so the host that most needs an in-guest
    // measurement could only take one from outside, through the wslrelay
    // mirror, while linux measures in-process. Rows taken at different loci are
    // not the same measurement, which is a comparability hazard in the fleet
    // capability matrix rather than a cosmetic gap.
    "jq",
];

/// Render the idempotent base-package setup script from [`GUEST_BASE_PACKAGES`].
///
/// `rpm -q` short-circuits when everything is present, so re-provision stays
/// cheap; `setcap` is safe to repeat.
fn base_packages_setup() -> String {
    let pkgs = GUEST_BASE_PACKAGES.join(" ");
    format!(
        "set -e\n\
         rpm -q {pkgs} >/dev/null 2>&1 || \\\n  dnf install -y {pkgs}\n\
         for b in /usr/bin/newuidmap /usr/sbin/newuidmap; do [ -e \"$b\" ] && setcap cap_setuid+ep \"$b\" || true; done\n\
         for b in /usr/bin/newgidmap /usr/sbin/newgidmap; do [ -e \"$b\" ] && setcap cap_setgid+ep \"$b\" || true; done\n"
    )
}

/// What the last `reconcile_adopted_guest` actually DID to the adopted guest
/// (order 620-duta). Recorded to disk so `--diagnose` can report it.
///
/// This exists because "the guest reports the same version as the tray" is not
/// the same claim as "this tray deployed that guest", and the two are
/// indistinguishable from the outside. `reconcile_adopted_guest` returns early
/// on a version match, so a tray carrying a NEW binary at an UNCHANGED VERSION
/// injects nothing and leaves a guest that looks correct by every field
/// `--diagnose` previously exposed. That ambiguity cost this project a false
/// "the fix is deployed" reading on 2026-08-11 (627-sgtt), and the packet's own
/// next_action had warned about it beforehand — which is the point: a warning
/// in a plan packet cannot be observed at runtime, and this can.
#[derive(Debug, Clone, PartialEq, Eq, serde::Serialize, serde::Deserialize)]
pub struct GuestWiringRecord {
    /// `WORKSPACE_VERSION` of the tray that performed the reconcile.
    pub tray_version: String,
    /// Headless version the adopted guest reported BEFORE the reconcile.
    /// `None` means no binary was found at all.
    pub guest_version_before: Option<String>,
    /// What the reconcile did. See [`GuestWiringOutcome`].
    pub outcome: GuestWiringOutcome,
    /// UTC RFC3339 timestamp of the reconcile.
    pub ts: String,
    /// Failure detail when `outcome` is `Failed`; `None` otherwise.
    pub error: Option<String>,
}

/// The three things a reconcile can conclude, kept distinct on purpose.
#[derive(Debug, Clone, Copy, PartialEq, Eq, serde::Serialize, serde::Deserialize)]
#[serde(rename_all = "kebab-case")]
pub enum GuestWiringOutcome {
    /// Versions matched, so nothing was injected. The guest's binary is
    /// whatever some EARLIER tray put there — this run did not touch it.
    /// Distinguishing this from `Reinjected` is the entire reason the record
    /// exists.
    SkippedVersionMatch,
    /// The guest was stale or absent and the bootstrap injection ran to
    /// completion: binary, systemd units, and modules-load entry are this
    /// tray's.
    Reinjected,
    /// Injection was attempted and failed; the guest's wiring is in an
    /// unknown state.
    Failed,
}

/// UTC RFC3339 stamp for the reconcile record, seconds precision.
fn now_rfc3339_utc() -> String {
    chrono::Utc::now().to_rfc3339_opts(chrono::SecondsFormat::Secs, true)
}

/// Serialize the outcome of a reconcile so `--diagnose` can report it.
/// Best-effort by design: a tray must never fail to provision because a
/// diagnostic breadcrumb could not be written.
pub fn write_guest_wiring_record(record: &GuestWiringRecord) {
    let path = WslLifecycle::guest_wiring_record_path();
    if let Some(dir) = path.parent()
        && let Err(e) = std::fs::create_dir_all(dir)
    {
        tracing::debug!(%e, "could not create guest wiring state dir");
        return;
    }
    match serde_json::to_vec_pretty(record) {
        Ok(bytes) => {
            if let Err(e) = std::fs::write(&path, bytes) {
                tracing::debug!(%e, "could not write guest wiring record");
            }
        }
        Err(e) => tracing::debug!(%e, "could not serialize guest wiring record"),
    }
}

/// Read back the last recorded reconcile outcome, or `None` when the file is
/// absent or unreadable/corrupt. A missing record is the honest answer for a
/// tray that has not reconciled since the feature landed — it is NOT reported
/// as a version match, which would be the very conflation this record exists
/// to remove.
pub fn read_guest_wiring_record() -> Option<GuestWiringRecord> {
    let path = WslLifecycle::guest_wiring_record_path();
    let bytes = std::fs::read(path).ok()?;
    serde_json::from_slice(&bytes).ok()
}

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

/// windows-260722-1 curated UX strings (operator-approved verbatim — see the
/// packet's `ux-approval` ledger event; tray-ux governance forbids changing
/// them without a new approval). Chips obey the 45-char status cap; the
/// toasts pair with them in `notify_icon`'s terminal-state mapping.
pub const CHIP_FEATURE_SETUP_WARN: &str = "\u{1F7E1} One-time Windows setup\u{2026}";
pub const CHIP_FEATURE_SETUP_PROGRESS: &str = "\u{1F535} Installing Windows feature\u{2026}";
pub const CHIP_FEATURE_RESTART: &str = "\u{1F7E0} Restart Windows to finish setup";
pub const CHIP_FEATURE_FAILED: &str = "\u{1F534} Setup didn't finish \u{2014} Retry";
pub const TOAST_FEATURE_SETUP: &str = "Tillandsias needs a Windows feature that isn't installed yet. Installing it now \u{2014} you may see a Windows approval prompt.";
pub const TOAST_FEATURE_RESTART: &str =
    "Setup is almost done. Restart Windows, then open Tillandsias again.";

/// Error-string markers `notify_icon`'s failure path maps to the curated
/// terminal states (same substring-marker pattern as
/// `classified_short_status`). Pinned by unit tests.
pub const PLATFORM_RESTART_REQUIRED_MARKER: &str = "windows-feature-setup: restart required";
pub const PLATFORM_SETUP_FAILED_MARKER: &str = "windows-feature-setup failed";

/// Hard ceiling for one background `wsl --install --no-distribution` run.
/// The feature download + DISM enablement usually completes well inside
/// this; past it we fail into the curated terminal state (bounded — the
/// vm-provisioning-lifecycle `launch-no-unbounded-loop` invariant).
const FEATURE_INSTALL_TIMEOUT_SECS: u64 = 20 * 60;

/// The probe may boot a stopped utility VM, so it keeps order 418's
/// 60-second budget. Absence of a result is never evidence that the distro
/// is damaged.
const DISTRO_EXEC_PROBE_TIMEOUT_SECS: u64 = 60;

/// Build a background `wsl.exe` command with CREATE_NO_WINDOW applied.
/// From the GUI-subsystem tray a raw console child flashes a visible window
/// per invocation — the operator-reported "terminals popping open and
/// closing" (2026-07-12). Interactive lane terminals go through
/// `spawn_wsl_terminal` (CREATE_NEW_CONSOLE) instead, never through this.
/// @trace spec:no-terminal-flicker
fn wsl_cmd() -> tokio::process::Command {
    let mut cmd = tillandsias_vm_layer::wsl_command_async();
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

/// The observable result of one `wsl -d <distro> --exec /bin/true` attempt.
///
/// Only [`DistroFailure`](Self::DistroFailure) proves that `wsl.exe` spawned,
/// completed, rejected the distro exec, and the WSL service was independently
/// classified as sane. Service failures, timeouts, and spawn/wait errors are
/// inconclusive infrastructure outcomes and must never authorize unregistering
/// the distro.
#[derive(Debug)]
enum DistroExecProbeResult {
    Healthy,
    DistroFailure(String),
    ServiceFailure(String),
    Timeout,
    InfrastructureFailure(String),
}

impl DistroExecProbeResult {
    fn class(&self) -> DistroExecProbeClass {
        match self {
            Self::Healthy => DistroExecProbeClass::Healthy,
            Self::DistroFailure(_) => DistroExecProbeClass::DistroFailure,
            Self::ServiceFailure(_) => DistroExecProbeClass::ServiceFailure,
            Self::Timeout => DistroExecProbeClass::Timeout,
            Self::InfrastructureFailure(_) => DistroExecProbeClass::InfrastructureFailure,
        }
    }

    fn inconclusive_error(&self, attempt: &str) -> String {
        match self {
            Self::Timeout => format!(
                "registered distro exec probe {attempt} timed out; \
                 refusing destructive self-heal because the result is inconclusive"
            ),
            Self::ServiceFailure(error) => format!(
                "registered distro exec probe {attempt} hit a WSL-service failure: {error}; \
                 refusing destructive self-heal because the distro result is inconclusive"
            ),
            Self::InfrastructureFailure(error) => format!(
                "registered distro exec probe {attempt} could not run: {error}; \
                 refusing destructive self-heal because the result is inconclusive"
            ),
            Self::Healthy | Self::DistroFailure(_) => {
                "internal error: conclusive distro probe routed as inconclusive".to_string()
            }
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum RegisteredDistroDisposition {
    UseRegistered,
    ReprovisionDamaged,
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

    /// Where the last reconcile outcome is recorded for `--diagnose`
    /// (order 620-duta): `%LOCALAPPDATA%\tillandsias\state\guest-wiring.json`.
    ///
    /// It has to be a FILE rather than a process-global. `--diagnose` runs as
    /// its own short-lived process and never performs a reconcile, so an
    /// in-memory record would be empty in exactly the invocation that wants to
    /// report it.
    pub fn guest_wiring_record_path() -> PathBuf {
        let base = std::env::var_os("LOCALAPPDATA")
            .map(PathBuf::from)
            .unwrap_or_else(|| PathBuf::from("C:\\Users\\Public\\AppData\\Local"));
        base.join("tillandsias")
            .join("state")
            .join("guest-wiring.json")
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

        // windows-260722-1: consult the order-323 platform classifier BEFORE
        // any download or import. Previously the preflight only ran inside
        // WslRuntime::start(), so an absent-WSL host sat through the full
        // rootfs fetch and then failed with a misleading import error. An
        // absent platform now runs the curated background install; S2/S3
        // fail loud with their pinned remediations up-front.
        self.ensure_wsl_platform(&progress).await?;

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
        // the fast path only when the distro passes an actual exec probe.
        // A timeout or WSL-service failure gets one bounded recovery + retry;
        // only a completed nonzero exec with an independently sane WSL service
        // authorizes one-shot self-heal by discarding the damaged guest.
        // Inconclusive outcomes abort non-destructively (the guest is disposable
        // only after damage is proven, per
        // plan/issues/guest-crashloop-detection-and-ephemeral-reset-2026-07-17.md).
        if self.runtime.is_registered().await {
            match self.registered_distro_disposition().await? {
                RegisteredDistroDisposition::UseRegistered => {
                    // Adopt pre-marker healthy installs: probe green is the truth.
                    self.write_import_complete_marker().await;
                    progress.report_phase(ProvisionPhase::StartingVm);
                    self.runtime.start().await?;
                    // The exec probe proves the distro can run /bin/true — not
                    // that its Tillandsias wiring matches THIS tray. A distro
                    // survives tray upgrades, and injection historically ran
                    // only on first provision, so an adopted guest can carry a
                    // stale headless binary (older wire revision → silently
                    // dropped Hello → permanent "handshake: early eof", the
                    // order-282 class) and stale units/modules (pre-312 guests
                    // lack the vsock_loopback modules-load the socat bridge
                    // needs). Reconcile before spending the connect budget.
                    let wiring = match self.reconcile_adopted_guest(&progress).await {
                        Ok(outcome) => outcome,
                        Err(e) => {
                            tracing::warn!(
                                error = %e,
                                "adopted-guest reconciliation failed; connecting \
                                 with existing guest wiring"
                            );
                            GuestWiringOutcome::Failed
                        }
                    };
                    progress.report_phase(ProvisionPhase::Connecting);
                    const CW_PORT: u32 =
                        tillandsias_control_wire::transport::CONTROL_WIRE_VSOCK_PORT;
                    let connect = {
                        let _keepalive = self.spawn_keepalive(false).ok();
                        self.connect_with_backoff(CW_PORT).await
                    };
                    match connect {
                        Ok(()) => return Ok(()),
                        Err(e) if Self::handshake_failure_warrants_reprovision(wiring) => {
                            // Order 648-772y. Exhausting the budget WAS the
                            // defect: the fix for a guest whose wiring this run
                            // just rewrote is known, and nothing tried it.
                            tracing::error!(
                                error = %e,
                                ?wiring,
                                "control wire unreachable after this run rewrote the \
                                 guest wiring — discarding the guest and reprovisioning"
                            );
                            progress.report_message(
                                "\u{267B}\u{FE0F} Guest unreachable after a version-skew rewrite \u{2014} reprovisioning from scratch\u{2026}",
                            );
                            self.unregister_distro().await?;
                            let _ =
                                tokio::fs::remove_file(&Self::import_complete_marker_path()).await;
                            // Fall through to the full download + import path.
                        }
                        Err(e) => return Err(e),
                    }
                }
                RegisteredDistroDisposition::ReprovisionDamaged => {
                    let marker = Self::import_complete_marker_path();
                    tracing::error!(
                        marker_present = marker.exists(),
                        "registered WSL distro explicitly failed the exec probe — \
                         treating the guest as damaged and reprovisioning from \
                         scratch (one-shot self-heal; the guest is disposable \
                         by design)"
                    );
                    progress.report_message(
                        "\u{267B}\u{FE0F} Local VM is damaged — reprovisioning from scratch...",
                    );
                    self.unregister_distro().await?;
                    let _ = tokio::fs::remove_file(&marker).await;
                    // Fall through to the full download + import path below.
                }
            }
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

        // Hold a keepalive across the connect loop so the VM doesn't idle out
        // mid-wait — and DROP it before any recovery below, or the keepalive is
        // the thing keeping the wedged VM alive.
        let connect = {
            let _keepalive = self.spawn_keepalive(false).ok();
            self.connect_with_backoff(CW_PORT).await
        };

        if let Err(error) = &connect {
            // Order 664-frz0. A FRESH start whose wire never came up leaves a
            // utility VM that has never been reachable and has no value alive.
            // On 2026-08-10 one sat wedged for ~15 minutes while the host
            // progressively froze around it (forensics:
            // plan/issues/host-freeze-during-vm-start-forensics-2026-08-10.md —
            // the freeze was a Hyper-V/WSL2 platform hang, not ours, but our
            // unreachable VM was the context and we left it running).
            //
            // The bounded recovery already exists and is already used by the
            // exec-probe path; this is one more caller, not new machinery.
            //
            // Exactly once, and only here: this is the fresh-provision tail, so
            // by construction the wire has never been healthy in this run. A
            // handshake that fails AFTER a previously-healthy wire belongs to
            // the keepalive supervisor, which is separately bounded — see
            // `keepalive_supervisor_gives_up_after_cap_with_backoff`. Recovering
            // there would fight the supervisor for the same VM.
            tracing::error!(
                %error,
                "control wire never came up on a fresh VM start — running one \
                 bounded WSL shutdown recovery so the wedged VM does not linger"
            );
            match WslRuntime::perform_wsl_shutdown_recovery().await {
                Ok(()) => tracing::info!(
                    "bounded WSL shutdown recovery completed after a wedged fresh start"
                ),
                // The recovery failing does not change the provisioning verdict:
                // the original handshake error is what the operator needs, and
                // replacing it with a recovery error would hide the actual
                // failure behind its cleanup.
                Err(recovery_error) => tracing::warn!(
                    %recovery_error,
                    "bounded WSL shutdown recovery failed after a wedged fresh start"
                ),
            }
        }

        connect
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

    /// Version reported by the adopted guest's installed headless binary,
    /// normalized to the bare workspace version (`"0.4.260804.1"`). `None`
    /// when the binary is absent, non-executable, or the probe times out —
    /// all of which equally demand re-injection.
    async fn adopted_guest_headless_version(&self) -> Option<String> {
        let mut cmd = wsl_cmd();
        cmd.kill_on_drop(true);
        let fut = cmd
            .args([
                "-d",
                self.distro_name(),
                "-u",
                "root",
                "--",
                "/usr/local/bin/tillandsias-headless",
                "--version",
            ])
            .output();
        match tokio::time::timeout(Duration::from_secs(30), fut).await {
            Ok(Ok(output)) if output.status.success() => {
                parse_headless_version(&String::from_utf8_lossy(&output.stdout))
            }
            _ => None,
        }
    }

    /// Re-run the (idempotent) bootstrap injection when the adopted guest's
    /// headless version differs from this tray's `WORKSPACE_VERSION` or the
    /// binary is missing entirely. Heals every stale-wiring lane at once:
    /// the guest binary (embedded asset or version-pinned fetch script), the
    /// systemd units (retired `NoNewPrivileges` hardening made rootful podman
    /// select rootless mode and fail uid_map writes), and the
    /// `vsock_loopback` modules-load entry the non-elevated socat bridge
    /// requires. Version-equal guests are left untouched, so the fast path
    /// stays fast on healthy installs.
    async fn reconcile_adopted_guest(
        &self,
        progress: &Arc<dyn ProvisionProgress>,
    ) -> Result<GuestWiringOutcome, String> {
        let workspace = env!("WORKSPACE_VERSION");
        let guest = self.adopted_guest_headless_version().await;
        // Order 620-duta: record what this reconcile concluded, on EVERY exit
        // path including the early return. The early return is the one that
        // most needs recording — it is invisible from the outside and looks
        // identical to a successful injection in every other diagnose field.
        let record = |outcome: GuestWiringOutcome, error: Option<String>| {
            write_guest_wiring_record(&GuestWiringRecord {
                tray_version: workspace.to_string(),
                guest_version_before: guest.clone(),
                outcome,
                ts: now_rfc3339_utc(),
                error,
            });
        };
        if guest.as_deref() == Some(workspace) {
            record(GuestWiringOutcome::SkippedVersionMatch, None);
            return Ok(GuestWiringOutcome::SkippedVersionMatch);
        }
        tracing::info!(
            guest_version = guest.as_deref().unwrap_or("<absent>"),
            tray_version = %workspace,
            "adopted guest wiring is stale — re-injecting bootstrap logic"
        );
        // Order 648-772y criterion 2: the skew and the rewrite go to the
        // OPERATOR, not only to the log. The 648-jv69 incident was diagnosed
        // afterwards from a preserved diagnostics bundle; the person watching
        // the tray at the time saw a generic "updating components" and then a
        // three-minute stall. Naming both versions is what lets "I just rolled
        // back to stable" connect to what they are seeing.
        progress.report_message(&format!(
            "\u{1F504} Guest wiring is {} (guest {}, this build {}) \u{2014} re-injecting\u{2026}",
            if guest.is_some() {
                "version-skewed"
            } else {
                "absent"
            },
            guest.as_deref().unwrap_or("<absent>"),
            workspace
        ));
        let injected = self.inject_stale_guest_wiring(progress).await;
        match &injected {
            Ok(()) => record(GuestWiringOutcome::Reinjected, None),
            Err(e) => record(GuestWiringOutcome::Failed, Some(e.clone())),
        }
        injected.map(|()| GuestWiringOutcome::Reinjected)
    }

    /// Order 648-772y. Does a failed control-wire handshake justify discarding
    /// the guest and re-provisioning?
    ///
    /// Only when THIS run rewrote the guest's wiring. That is the 648-jv69
    /// shape: a 0.4.260809.2 tray adopted a guest provisioned by 0.4.260810.1,
    /// correctly judged the wiring skewed, re-injected OLDER bootstrap logic,
    /// and the next tray's handshake then never completed — ten 30s timeouts
    /// and a hard failure, with nothing trying the one thing that fixes it.
    /// Rewriting the wiring and then failing to reach the guest is strong
    /// evidence that the rewrite is what broke it.
    ///
    /// `SkippedVersionMatch` deliberately does NOT qualify. A handshake failing
    /// against wiring this run did not touch is failing for some other reason,
    /// and discarding the guest on that evidence is a guess with a re-download
    /// attached. The recovery is one-shot by construction: it lives on the
    /// adopted path and falls through to a fresh provision, which cannot
    /// re-enter it.
    fn handshake_failure_warrants_reprovision(wiring: GuestWiringOutcome) -> bool {
        match wiring {
            // The rewrite landed, or landed partially and failed — either way
            // the wiring is this run's doing and is the prime suspect.
            GuestWiringOutcome::Reinjected | GuestWiringOutcome::Failed => true,
            // Untouched wiring: something else is wrong; do not destroy a guest
            // to find out.
            GuestWiringOutcome::SkippedVersionMatch => false,
        }
    }

    /// The injection half of [`Self::reconcile_adopted_guest`], split out so
    /// every `?` inside it lands on ONE result the caller records. Folding the
    /// record into each early return by hand is how a later edit adds a fourth
    /// `?` and silently stops recording failures.
    async fn inject_stale_guest_wiring(
        &self,
        _progress: &Arc<dyn ProvisionProgress>,
    ) -> Result<(), String> {
        self.ensure_base_packages().await?;
        // A provision interrupted between ensure_base_packages and
        // configure_recipe_distro leaves an adopted guest that boots WITHOUT
        // systemd (no wsl.conf flip) — inject's `systemctl enable --now`
        // cannot work there (Esmeralda field repro, 2026-08-09: the 300s dnf
        // ceiling fired mid-provision and the next launch adopted the
        // half-provisioned import). Detect via the canonical
        // /run/systemd/system marker and finish the configure step first.
        let systemd_booted = wsl_cmd()
            .args([
                "-d",
                self.distro_name(),
                "-u",
                "root",
                "--",
                "test",
                "-d",
                "/run/systemd/system",
            ])
            .status()
            .await
            .map(|s| s.success())
            .unwrap_or(false);
        if !systemd_booted {
            tracing::info!(
                "adopted guest is not systemd-booted — completing the \
                 configure step before injection"
            );
            self.runtime
                .configure_recipe_distro()
                .await
                .map_err(|e| format!("configure adopted guest failed: {e}"))?;
            self.runtime.start().await?;
        }
        // Stop the stale listener first: overwriting a running ELF fails
        // with ETXTBSY, and the old unit may carry the retired hardening.
        self.wsl_root_sh(
            "systemctl stop tillandsias-headless.service \
             tillandsias-headless-fetch.service 2>/dev/null || true",
        )
        .await?;
        self.inject_bootstrap_logic().await?;
        // inject's `enable --now` starts the stopped units; restart is
        // belt-and-braces so the fresh binary + unit definitions are live
        // even if systemd considered a unit still active.
        self.wsl_root_sh(
            "systemctl restart tillandsias-headless-fetch.service \
             tillandsias-headless.service",
        )
        .await?;
        Ok(())
    }

    /// Resolve a registered distro without conflating missing evidence with
    /// damage. A first timeout or WSL-service failure invokes the existing
    /// WSL-service shutdown recovery exactly once and retries the probe exactly
    /// once. Recovery failure, a second inconclusive result, or any
    /// infrastructure error returns an error without reaching
    /// `unregister_distro`.
    async fn registered_distro_disposition(&self) -> Result<RegisteredDistroDisposition, String> {
        let first = self.distro_exec_probe().await;
        match distro_exec_probe_decision(DistroExecProbeAttempt::Initial, first.class()) {
            DistroExecProbeDecision::UseRegistered => {
                return Ok(RegisteredDistroDisposition::UseRegistered);
            }
            DistroExecProbeDecision::ReprovisionDamaged => {
                return Ok(RegisteredDistroDisposition::ReprovisionDamaged);
            }
            DistroExecProbeDecision::FailNonDestructively => {
                return Err(first.inconclusive_error("initial attempt"));
            }
            DistroExecProbeDecision::RecoverAndRetry => {}
        }

        tracing::warn!(
            "registered distro exec probe was inconclusive (timeout or \
             WSL-service failure); attempting one bounded WSL-service shutdown \
             recovery before one retry"
        );
        if let Err(error) = WslRuntime::perform_wsl_shutdown_recovery().await {
            return Err(format!(
                "WSL-service shutdown recovery failed: {error}; \
                 refusing destructive self-heal"
            ));
        }

        let retry = self.distro_exec_probe().await;
        match distro_exec_probe_decision(
            DistroExecProbeAttempt::AfterShutdownRecovery,
            retry.class(),
        ) {
            DistroExecProbeDecision::UseRegistered => {
                tracing::info!("registered distro exec probe passed after WSL-service recovery");
                Ok(RegisteredDistroDisposition::UseRegistered)
            }
            DistroExecProbeDecision::ReprovisionDamaged => {
                Ok(RegisteredDistroDisposition::ReprovisionDamaged)
            }
            DistroExecProbeDecision::FailNonDestructively => {
                Err(retry.inconclusive_error("after WSL-service recovery"))
            }
            DistroExecProbeDecision::RecoverAndRetry => {
                unreachable!("the state machine never recovers twice")
            }
        }
    }

    /// Cheap integrity probe for a registered distro: can it actually exec?
    /// `wsl -d <distro> --exec /bin/true` (hidden window, 60s cap — first
    /// exec may boot the utility VM). A partial/corrupt import returns an
    /// explicit non-zero exit; a healthy distro exits 0. A non-zero result is
    /// damage evidence only when a separate service-sanity probe passes and
    /// stderr carries no WSL-service failure marker. Timeout, service failure,
    /// and spawn/wait errors remain distinct, inconclusive outcomes.
    async fn distro_exec_probe(&self) -> DistroExecProbeResult {
        let mut cmd = wsl_cmd();
        cmd.kill_on_drop(true);
        let fut = cmd
            .args(["-d", self.distro_name(), "--exec", "/bin/true"])
            .output();
        match tokio::time::timeout(Duration::from_secs(DISTRO_EXEC_PROBE_TIMEOUT_SECS), fut).await {
            Ok(Ok(output)) if output.status.success() => DistroExecProbeResult::Healthy,
            Ok(Ok(output)) => {
                // No NUL scrub: `wsl_cmd()` sets WSL_UTF8=1 (2026-08-17), so
                // wsl.exe's own stderr arrives as UTF-8.
                let stderr = String::from_utf8_lossy(&output.stderr).trim().to_string();
                let service_sane = WslRuntime::is_wsl_service_sane().await;
                match classify_nonzero_distro_exec(&stderr, service_sane) {
                    DistroExecProbeClass::DistroFailure => {
                        tracing::warn!(
                            status = %output.status,
                            stderr = %stderr,
                            "distro exec probe failed while WSL service was independently sane"
                        );
                        DistroExecProbeResult::DistroFailure(format!("{}: {stderr}", output.status))
                    }
                    DistroExecProbeClass::ServiceFailure => {
                        tracing::warn!(
                            status = %output.status,
                            stderr = %stderr,
                            service_sane,
                            "distro exec probe hit a WSL-service failure; distro damage is unproven"
                        );
                        DistroExecProbeResult::ServiceFailure(format!(
                            "{}: {stderr}",
                            output.status
                        ))
                    }
                    other => unreachable!("non-zero classifier returned {other:?}"),
                }
            }
            Ok(Err(e)) => {
                tracing::warn!(error = %e, "distro exec probe failed to spawn wsl.exe");
                DistroExecProbeResult::InfrastructureFailure(e.to_string())
            }
            Err(_) => {
                tracing::warn!(
                    timeout_s = DISTRO_EXEC_PROBE_TIMEOUT_SECS,
                    "distro exec probe timed out; result is inconclusive"
                );
                DistroExecProbeResult::Timeout
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
    /// (deletes the distro + its VHDX). Called after an independently
    /// service-sane failed integrity probe (one-shot self-heal) and by the
    /// user-invoked `wipe_guest` reset path, both on the ephemeral-reset
    /// doctrine.
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

    /// windows-260722-1: make the WSL platform a first-class provisioning
    /// precondition. Classify the host (order-323 probes) BEFORE anything is
    /// downloaded:
    ///
    /// - `Ok` → proceed.
    /// - `RebootPending` / `VirtualizationDisabled` → fail loud immediately
    ///   with the pinned remediation (previously only surfaced after the
    ///   full rootfs fetch, at `start()`).
    /// - `WslPlatformAbsent` → the curated one-time setup flow: run
    ///   `wsl --install --no-distribution` in the BACKGROUND (hidden window,
    ///   wsl.exe raises its own UAC prompt when needed), stream its output
    ///   lines through the provisioning progress sink under the approved
    ///   chip, then re-classify. Exactly one attempt per provisioning run,
    ///   hard 20-minute ceiling — bounded by construction. Terminal
    ///   outcomes are marker-tagged errors `notify_icon` maps to the
    ///   approved restart/failure chips + toasts.
    async fn ensure_wsl_platform(
        &self,
        progress: &Arc<dyn ProvisionProgress>,
    ) -> Result<(), String> {
        use tillandsias_vm_layer::wsl::{WslPlatformVerdict, wsl_platform_preflight};
        let verdict = tokio::task::spawn_blocking(wsl_platform_preflight)
            .await
            .unwrap_or(WslPlatformVerdict::Ok);
        match verdict {
            WslPlatformVerdict::Ok => return Ok(()),
            WslPlatformVerdict::WslPlatformAbsent => {}
            other => {
                return Err(format!(
                    "WSL platform preflight: {}",
                    other.remediation().unwrap_or("platform not ready")
                ));
            }
        }

        tracing::warn!(
            "WSL platform absent — running the one-time background \
             `wsl --install --no-distribution` (single bounded attempt)"
        );
        progress.report_message(CHIP_FEATURE_SETUP_WARN);

        let mut cmd = tillandsias_vm_layer::wsl_command_async();
        cmd.args(["--install", "--no-distribution"])
            .stdin(std::process::Stdio::null())
            .stdout(std::process::Stdio::piped())
            .stderr(std::process::Stdio::piped());
        tillandsias_vm_layer::no_window_async(&mut cmd);
        let mut child = cmd.spawn().map_err(|e| {
            format!("{PLATFORM_SETUP_FAILED_MARKER}: could not start wsl --install: {e}")
        })?;

        let stdout = child.stdout.take();
        let stderr = child.stderr.take();
        let progress_for_stream = progress.clone();
        let stream_task = tokio::spawn(async move {
            use tokio::io::AsyncBufReadExt;
            // Drain BOTH pipes CONCURRENTLY (boundary-audit finding
            // 2026-07-22): sequential stdout-then-stderr held the ~4 KB
            // stderr pipe full when the child dumped a verbose error, so
            // the child blocked in write(stderr), stdout never EOF'd, and
            // the mutual wedge rode the whole 20-minute ceiling — losing
            // the very diagnostic this task exists to capture.
            let stdout_side = async {
                let mut last_line = String::new();
                if let Some(out) = stdout {
                    let mut lines = tokio::io::BufReader::new(out).lines();
                    while let Ok(Some(line)) = lines.next_line().await {
                        // No NUL scrub — the command carries WSL_UTF8=1.
                        let line = line.trim().to_string();
                        if line.is_empty() {
                            continue;
                        }
                        tracing::info!(installer_line = %line, "windows feature install progress");
                        progress_for_stream
                            .report_message(&format!("{CHIP_FEATURE_SETUP_PROGRESS} {line}"));
                        last_line = line;
                    }
                }
                last_line
            };
            let stderr_side = async {
                let mut err_tail = String::new();
                if let Some(err) = stderr {
                    let mut lines = tokio::io::BufReader::new(err).lines();
                    while let Ok(Some(line)) = lines.next_line().await {
                        // No NUL scrub — the command carries WSL_UTF8=1.
                        let line = line.trim().to_string();
                        if !line.is_empty() {
                            err_tail = line;
                        }
                    }
                }
                err_tail
            };
            tokio::join!(stdout_side, stderr_side)
        });

        let status = match tokio::time::timeout(
            Duration::from_secs(FEATURE_INSTALL_TIMEOUT_SECS),
            child.wait(),
        )
        .await
        {
            Ok(Ok(status)) => status,
            Ok(Err(e)) => {
                return Err(format!(
                    "{PLATFORM_SETUP_FAILED_MARKER}: wsl --install could not be awaited: {e}"
                ));
            }
            Err(_) => {
                let _ = child.kill().await;
                // The kill EOFs both pipes; give the drain a moment so the
                // timeout error carries whatever the installer actually said
                // instead of only the ceiling number.
                let (last_line, err_tail) =
                    tokio::time::timeout(Duration::from_secs(5), stream_task)
                        .await
                        .ok()
                        .and_then(|r| r.ok())
                        .unwrap_or_default();
                let detail = if err_tail.is_empty() {
                    last_line
                } else {
                    err_tail
                };
                return Err(format!(
                    "{PLATFORM_SETUP_FAILED_MARKER}: wsl --install did not finish within \
                     {FEATURE_INSTALL_TIMEOUT_SECS}s{}",
                    if detail.is_empty() {
                        String::new()
                    } else {
                        format!("; last output: {detail}")
                    }
                ));
            }
        };
        let (last_line, err_tail) = stream_task.await.unwrap_or_default();

        // Truth is the re-probe, not the exit status: a successful feature
        // enablement often needs a reboot before `wsl --status` goes healthy.
        let after = tokio::task::spawn_blocking(wsl_platform_preflight)
            .await
            .unwrap_or(WslPlatformVerdict::WslPlatformAbsent);
        match after {
            WslPlatformVerdict::Ok => {
                tracing::info!("windows feature install completed; platform healthy — continuing");
                Ok(())
            }
            WslPlatformVerdict::RebootPending => Err(PLATFORM_RESTART_REQUIRED_MARKER.to_string()),
            _ if status.success() => {
                // Install claims success but the platform isn't visible yet —
                // the classic needs-a-reboot shape even without the CBS key.
                Err(PLATFORM_RESTART_REQUIRED_MARKER.to_string())
            }
            _ => Err(format!(
                "{PLATFORM_SETUP_FAILED_MARKER}: wsl --install exited {status}; last output: {}",
                if err_tail.is_empty() {
                    &last_line
                } else {
                    &err_tail
                }
            )),
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
        //
        // `jq` (order 807-c3mf): the shared accel benchmark
        // (scripts/bench-accel-lane.sh) requires curl and jq, and this guest had
        // curl but not jq — so the ONE host that most needs an in-guest
        // measurement could only take it from outside, through the wslrelay
        // loopback mirror, while linux runs it in-process. That difference is a
        // comparability hazard in the fleet capability matrix, not a cosmetic
        // one: two rows taken at different loci are not the same measurement.
        // Precedent for a test/diagnostic dependency in this list is `socat`
        // directly above, and jq is smaller than selinux-policy-devel already
        // here. The alternative — dropping jq from bench-accel-lane.sh — was
        // rejected only because that script is another host's and this image is
        // ours; if the fleet later prefers a dependency-free bench, remove this.
        //
        let setup = base_packages_setup();
        // 25 min, not 5: on N100-class hosts with cold dnf metadata the base
        // set legitimately takes ~10 min (Esmeralda field evidence,
        // 2026-08-08: DNS verified healthy, dnf still mid-transaction when
        // the old 300s ceiling fired — the orphaned dnf then finished in the
        // guest after the tray had already declared failure). rpm -q
        // short-circuits when everything is installed, so retries are cheap.
        tokio::time::timeout(Duration::from_secs(1500), self.wsl_root_sh(&setup))
            .await
            .map_err(|_| {
                "Package installation timed out after 25 min — the WSL2 network may be \
                 broken, or the host/link is too slow even for the low-end budget"
                    .to_string()
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

        // 1b. github-login.sh — the interactive login wrapper the tray's
        // GitHub Login terminal runs. Exists so the terminal argv is a single
        // bare path with NO shell metacharacters: the previous inline
        // `bash -lc '<script with quotes/${}/&&/()>'` had to survive BOTH
        // std::process MSVC quoting AND wt.exe's own re-parse, and arrived
        // mangled (Esmeralda field crash, 2026-08-09 — the window died
        // instantly and its error text carried terminal-hostile escapes).
        // All output is tee'd to a guest-side log so failures are readable
        // without copying from a terminal. stdin stays the tty (the
        // interactive-mode gate checks stdin only).
        //
        // The pipeline is SAFE, but only because of a binary-side fix. Running
        // the login here — through a pipeline or any other non-`exec` form —
        // means it is not a session leader, so its startup `setpgid(0, 0)`
        // actually succeeds and moves it into a background process group; the
        // `podman exec --tty` that collects the token then touches the
        // controlling terminal from that background group, the kernel stops it
        // (SIGTTIN/SIGTTOU), and the window stays blank forever behind a
        // 0-byte log. That was the v0.4.260809.2 field failure. The fix is
        // `should_own_process_group` in tillandsias-headless `main()`, which
        // keeps an interactive lane in the launching shell's foreground group.
        // Do NOT "fix" a future recurrence by de-piping this wrapper: piping is
        // not the mechanism (a non-interactive bash pipeline does not change
        // process groups), and dropping the tee only costs the log that makes
        // the next failure legible.
        // @trace plan/issues/windows-github-login-blank-terminal-2026-08-09.md
        let github_login_wrapper = r#"#!/usr/bin/env bash
set -u
export HOME="${HOME:-/root}"
export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
install -d -m 0700 "$XDG_RUNTIME_DIR"
export TILLANDSIAS_VAULT_API_BASE_URL="${TILLANDSIAS_VAULT_API_BASE_URL:-https://vault:8200}"
LOG_DIR="$HOME/.cache/tillandsias"
LOG="$LOG_DIR/github-login-last.log"
install -d -m 0700 "$LOG_DIR"
/usr/local/bin/tillandsias-headless --github-login 2>&1 | tee "$LOG"
rc=${PIPESTATUS[0]}
if [ "$rc" -ne 0 ]; then
  printf '\n[tillandsias] github-login exited %s; full output saved to %s\n' "$rc" "$LOG"
  sleep 10
fi
exit "$rc"
"#;
        self.wsl_root_write(
            "/usr/local/lib/tillandsias/github-login.sh",
            github_login_wrapper,
            true,
        )
        .await?;

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

        // 2b. headless-ready.sh — ASSERT A BOUND LISTENER (order 735-ewzp).
        //
        // The preflight above cannot do this and never could: it is an
        // ExecStartPre, so it runs BEFORE the binary and by construction has
        // nothing to observe. Its `vsock_device=present` test only proves
        // /dev/vsock exists, and vsock_loopback alone provides that node —
        // this image loads that module deliberately.
        //
        // The gap that motivates it: a guest binary built without the
        // listen-vsock feature started, logged `app.started`, satisfied the
        // preflight, and systemd held the unit `active (running)` with
        // `--listen-vsock 42420` on its command line — while nothing was bound
        // and no host could ever connect. Every readiness signal was green.
        // The host saw only a seven-and-a-half minute timeout.
        //
        // This proves the property instead of a proxy for it: connect to the
        // port and see whether something accepts. CID 1 is VMADDR_CID_LOCAL,
        // so the probe stays inside the guest and needs no host involvement —
        // measured working in a live guest before this was written. socat
        // ships in the image built WITH_VSOCK, so no new dependency.
        //
        // WHERE THIS RUNS, and why it moved (order 757-4hdt). It was an
        // ExecStartPost on the daemon's own unit with a 15-second deadline.
        // That killed clean-room provisioning of the published v0.4.260815.1:
        // the probe reported NOT-BOUND at fifteen seconds, and because an
        // ExecStartPost is a control process, systemd STOPPED a perfectly
        // healthy daemon mid-build. Restart=on-failure began the same
        // minutes-long work again, and it never converged; measured five
        // failures with the unit still `activating`.
        //
        // WHY THE PROBE SAID NOT-BOUND, corrected (order 795-jeym, measured
        // 2026-08-17). This comment used to say the daemon "bootstraps Vault
        // and builds the proxy image -- minutes of work -- BEFORE it binds
        // 42420". That is not what the code does and never was. The bind is
        // the FIRST await in the vsock task: `run_headless_async` reaches
        // `maybe_spawn_vsock_listener` through non-blocking calls only, and
        // the vault/proxy work is driven by the liveness task, which is gated
        // on VmPhase::Ready and dispatched through `spawn_blocking`, so it
        // cannot precede the bind. Measured on four cold boots of this guest:
        // the listener answers 61ms, 78ms, 90ms and 255ms after daemon start,
        // and the 255ms case is the genuinely cold one where the vault image
        // was MISSING and provisioning then ran for a further 24 seconds.
        // The listener was bound 36ms BEFORE provisioning began.
        //
        // The real cause is the one 757-4hdt found later and recorded in its
        // own verification event: `vsock_loopback` was not loaded on that
        // boot. This probe connects to CID 1 (VMADDR_CID_LOCAL), which
        // REQUIRES that module, so it reported the control wire down while
        // the wire was working. The module load races the probe; the bind
        // does not. That is why the modprobe and the ENETUNREACH branch
        // below are the load-bearing half of the fix, and why a shorter
        // deadline is gated on making the module dependency deterministic
        // rather than on reordering anything in the daemon.
        //
        // Keeping the superseded diagnosis here had a cost: it was read as
        // current and a p1 release-blocker packet was filed to implement it.
        //
        // Raising the deadline in place would not have fixed it: ExecStartPost
        // BLOCKS activation, so a generous window turns a fast failure into a
        // ten-minute hang of `systemctl enable --now`. The fault was placing an
        // assertion where failing it stops the subject. A probe that can kill
        // the healthy process it measures is not a check.
        //
        // So it is now its OWN oneshot unit, ordered after the daemon and
        // wanted by it. Failing leaves the daemon untouched and shows up in
        // `systemctl --failed` and the journal -- a signal that is loud without
        // being lethal. The deadline is generous because nothing waits on it,
        // and it still retries because it races a Type=exec ExecStart.
        let ready_script = r#"#!/usr/bin/env bash
set -uo pipefail
PORT="${1:-42420}"

# CID 1 is VMADDR_CID_LOCAL, and reaching it requires the vsock_loopback
# module. A fresh guest does NOT have it loaded -- measured on a clean-room
# provision of v0.4.260815.1 -- and without it this probe reported the control
# wire down while the HOST was talking to the guest perfectly happily
# (phase=Ready, podman_ready=true). The host arrives over hvsocket to the VM's
# own CID and never touches loopback, so the probe was asserting a path nobody
# depends on and failing a healthy system (order 757-4hdt).
#
# ORDER 798-emje: by the time this runs the module is supposed to ALREADY be
# there -- provisioning loads it before it starts any unit, and this unit is
# ordered `After=systemd-modules-load.service`. This modprobe stays as the
# backstop and is load-bearing (removing it recreates 757-4hdt's false alarm on
# a guest whose modules-load.d entry was never written), but it is no longer
# SILENT. It reports the module state it observed BEFORE acting and after, so:
#
#   before=loaded  -> the ordering held; the verdict below did not race anything
#   before=missing -> the ordering did NOT hold and only this backstop saved the
#                     run. That is a defect regression, and it is now greppable
#                     in the journal instead of being invisible behind a passing
#                     probe -- which is precisely how this bug survived from
#                     735-ewzp through 757-4hdt to 798-emje.
#
# A probe that works by winning a race and a probe that works because the
# dependency was satisfied print the same verdict. These two words are what
# tell them apart.
vsock_loopback_state() {
  if [ -d /sys/module/vsock_loopback ] || grep -q '^vsock_loopback ' /proc/modules; then
    echo loaded
  else
    echo missing
  fi
}
before="$(vsock_loopback_state)"
if [ "$before" = missing ]; then
  modprobe vsock_loopback 2>/dev/null || true
fi
after="$(vsock_loopback_state)"
echo "[tillandsias-ready] vsock_loopback before=${before} after=${after}"

# The two failure modes are DISTINGUISHABLE and must not be conflated:
#   ENETUNREACH "Network is unreachable"  -> no loopback transport; this probe
#                                            cannot see the property from here
#   ECONNREFUSED "Connection refused"     -> transport fine, nothing listening,
#                                            which is exactly the defect
#                                            735-ewzp exists to catch
# Reporting the first as NOT-BOUND is a false alarm about a working system;
# reporting it as OK would be the always-passes probe 735-ewzp replaced.
# So it gets its own verdict and its own exit code.
# The 900s is NOT a bind-latency budget. Measured over four cold boots
# (order 795-jeym, 2026-08-17) the listener answers 61-255 ms after daemon
# start, so 900s is ~3500x the worst observed bind. What the window actually
# covers is the `vsock_loopback` module load racing this probe: the modprobe
# above is best-effort, and on a boot where systemd-modules-load has not run
# yet the retry loop is the only thing that converges. Shorten this ONLY
# after that dependency is made deterministic (ordering the unit after
# systemd-modules-load.service, or an ExecStartPre modprobe) -- otherwise a
# short deadline just converts a slow pass into a fast INDETERMINATE.
DEADLINE=$(( $(date +%s) + ${TILLANDSIAS_READY_TIMEOUT:-900} ))
last=""
while :; do
  # The CONNECT address must come FIRST. Written the other way round --
  # `socat -u /dev/null VSOCK-CONNECT:1:$PORT` -- socat reaches EOF on
  # /dev/null and exits 0 BEFORE the connection can fail, so the probe passes
  # against a dead port. That form was measured returning 0 for both a live
  # and a dead port: a readiness check that always succeeds, which is worse
  # than the signal it replaces.
  last="$(timeout 8 socat -T1 "VSOCK-CONNECT:1:${PORT}" /dev/null 2>&1)" && {
    echo "[tillandsias-ready] vsock_listener=bound port=${PORT}"
    exit 0
  }
  if [ "$(date +%s)" -ge "$DEADLINE" ]; then
    case "$last" in
      *"Network is unreachable"*)
        echo "[tillandsias-ready] vsock_listener=INDETERMINATE port=${PORT} -- no vsock loopback transport in this guest (vsock_loopback absent), so a guest-local probe cannot observe the listener; this says NOTHING about host reachability, which uses hvsocket. Check the host side with: tillandsias-tray --diagnose --json" >&2
        exit 2
        ;;
      *)
        echo "[tillandsias-ready] vsock_listener=NOT-BOUND port=${PORT} -- the transport works but nothing accepts on the control-wire port; the host cannot reach this guest. Last error: ${last}" >&2
        exit 1
        ;;
    esac
  fi
  sleep 1
done
"#;
        self.wsl_root_write(
            "/usr/local/lib/tillandsias/headless-ready.sh",
            ready_script,
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
        // Low-end-host kill switch (N100 field host, 2026-08-08): when the
        // TRAY's environment carries TILLANDSIAS_NO_LOCAL_INFERENCE, forward
        // it into the guest service so lane launches skip the
        // tillandsias-inference container (~2.1GB ollama self-install +
        // resident serve). The guest-side gate lives in tillandsias-headless
        // main.rs (local_inference_disabled).
        let low_power_env = if std::env::var("TILLANDSIAS_NO_LOCAL_INFERENCE")
            .map(|v| {
                let v = v.trim();
                !v.is_empty() && v != "0"
            })
            .unwrap_or(false)
        {
            "Environment=TILLANDSIAS_NO_LOCAL_INFERENCE=1\n"
        } else {
            ""
        };
        let headless_unit = format!(
            r#"[Unit]
Description=Tillandsias headless (in-VM vsock control wire)
After=network-online.target podman.socket tillandsias-headless-fetch.service
Wants=network-online.target podman.socket
Requires=tillandsias-headless-fetch.service
# Bound the restart loop (order 735-ewzp). A daemon that can never start
# should end in `failed`, loudly and once, not restart every two seconds
# forever. This used to say "the restart loop the ExecStartPost readiness
# probe can create"; that probe is no longer on this unit (757-4hdt) and the
# stale wording briefly made a `grep -c ExecStartPost` on the generated file
# report 1 during verification -- a comment answering a check about
# directives, which is the shape 601-462g names. These are [Unit] directives on
# modern systemd -- placing them under [Service], where they read more
# naturally, gets them silently ignored, which would be the same
# looks-configured-does-nothing shape this packet exists to remove.
StartLimitIntervalSec=120
StartLimitBurst=3
[Service]
Type=exec
ExecStartPre=/usr/bin/mkdir -p /run/user/0
ExecStartPre=/usr/bin/chmod 0700 /run/user/0
ExecStartPre=/usr/local/lib/tillandsias/headless-preflight.sh
Environment=HOME=/root
Environment=XDG_RUNTIME_DIR=/run/user/0
Environment=TILLANDSIAS_VAULT_API_BASE_URL=https://vault:8200
{low_power_env}ExecStart=/usr/local/bin/tillandsias-headless --listen-vsock 42420
Restart=on-failure
RestartSec=2s
StandardOutput=journal+console
StandardError=journal+console
[Install]
WantedBy=multi-user.target
"#
        );
        self.wsl_root_write(
            "/etc/systemd/system/tillandsias-headless.service",
            &headless_unit,
            false,
        )
        .await?;

        // 4b. tillandsias-headless-ready.service — the readiness ASSERTION,
        // deliberately a separate unit (order 757-4hdt).
        //
        // `Wants=` rather than `Requires=`, and no `Before=` on anything: this
        // unit must be able to fail without taking the daemon or the boot with
        // it. That separation IS the fix -- the same script as an ExecStartPost
        // stopped a healthy daemon on every cold boot.
        //
        // It still fails loudly. A failed oneshot is listed by
        // `systemctl --failed` and its stderr lands in the journal, so an
        // unbound control wire remains a red signal to anyone looking -- which
        // was 735-ewzp's whole point, and is preserved here rather than traded
        // away for the fix.
        //
        // ORDER 798-emje: `After=systemd-modules-load.service` is the whole
        // deterministic-ordering fix on the boot path, and it is one line
        // because systemd already owns this problem. The probe connects to
        // CID 1, which needs `vsock_loopback`; the module arrives from
        // /etc/modules-load.d/tillandsias-vsock.conf via
        // systemd-modules-load.service. That service is `Before=sysinit.target`
        // and this unit is `After=basic.target` by DefaultDependencies, so the
        // edge is ALREADY implied on a normal boot -- but implied is not
        // declared, and an implied edge is invisible to the reader, unassertable
        // by a test, and silently lost the day anyone adds
        // `DefaultDependencies=no` or socket-activates this. Declaring it costs
        // nothing at runtime and turns "it happens to work" into "systemd
        // refuses to run it early".
        //
        // `Wants=`, not `Requires=`: if the module genuinely cannot load, the
        // loader unit fails and THIS unit must still run, so the probe can
        // report INDETERMINATE (exit 2). Requires= would skip the probe and
        // collapse the third state into "never ran", which is exactly the
        // information loss 798-emje forbids -- the third state is a real fact
        // ("this probe cannot observe the property from here") and neither PASS
        // nor FAIL is a truthful place to fold it.
        let ready_unit = r#"[Unit]
Description=Tillandsias control-wire readiness assertion
After=tillandsias-headless.service
Wants=tillandsias-headless.service
After=systemd-modules-load.service
Wants=systemd-modules-load.service
[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/lib/tillandsias/headless-ready.sh 42420
StandardOutput=journal+console
StandardError=journal+console
[Install]
WantedBy=multi-user.target
"#;
        self.wsl_root_write(
            "/etc/systemd/system/tillandsias-headless-ready.service",
            ready_unit,
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

        // Persist vsock_loopback so it survives WSL2 restarts, and load it
        // HERE -- before the units below are started.
        // CONFIG_VSOCKETS_LOOPBACK=m (confirmed: WSL2 kernel 6.6.114.1).
        // Required for Phase 5 (vsock-in-vsock container transport, CID 1).
        // @trace plan/issues/vsock-kernel-probe-results-2026-06-29.md
        //
        // ORDER 798-emje -- THIS MOVED, and the move is the fix on the
        // clean-room path. This block used to sit at the very END of
        // inject_bootstrap_logic, ~60 lines AFTER the `systemctl enable --now`
        // below. So on a first provision the sequence was: start the daemon,
        // start the readiness assertion, and only THEN write modules-load.d and
        // modprobe. The probe raced a module load that provisioning had not yet
        // performed, and the race was in OUR call order, not in the kernel's.
        //
        // That is exactly what the truly-cold boot recorded under 757-4hdt: the
        // guest logged `preflight vsock_loopback missing`, and the module was
        // loaded 249 ms later. 249 ms is not a kernel being slow, it is these
        // two statements in the wrong order. Loading before the enable makes
        // the first-provision path deterministic without any waiting, polling,
        // or deadline; the boot path is handled by the modules-load.d entry
        // written here plus the ready unit's `After=systemd-modules-load.service`.
        //
        // It CONFIRMS rather than assuming: `modprobe` alone can no-op on a
        // kernel that lacks the module and leave a silent gap for the probe to
        // discover minutes later. It does NOT fail provisioning when the module
        // is unavailable -- that is a legitimate guest configuration, the host
        // wire (hvsocket) does not use loopback at all, and the correct verdict
        // for it is the probe's INDETERMINATE, not a dead provision.
        self.wsl_root_sh(
            "echo 'vsock_loopback' > /etc/modules-load.d/tillandsias-vsock.conf; \
             modprobe vsock_loopback 2>/dev/null; \
             if [ -d /sys/module/vsock_loopback ] || grep -q '^vsock_loopback ' /proc/modules; then \
               echo '[tillandsias-provision] vsock_loopback=loaded'; \
             else \
               echo '[tillandsias-provision] vsock_loopback=unavailable -- the guest-local readiness probe will report INDETERMINATE; host reachability uses hvsocket and is unaffected'; \
             fi",
        )
        .await?;

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
            // tillandsias-headless-ready.service is enabled but NOT started
            // here, and the distinction is load-bearing (order 757-4hdt).
            // `--now` on the assertion would block this command until the
            // listener binds -- minutes on a cold boot -- and then fail the
            // whole provisioning step if it timed out, which is precisely the
            // coupling that broke v0.4.260815.1. `enable` alone writes the
            // WantedBy symlink so it runs on the next boot, and it is started
            // detached below so a cold boot still gets the assertion without
            // provisioning waiting on it.
            "systemctl daemon-reload && systemctl enable --now podman.socket tillandsias-headless-fetch.service tillandsias-headless.service && \
             systemctl enable tillandsias-headless-ready.service && \
             { systemctl start --no-block tillandsias-headless-ready.service 2>/dev/null || true; } && \
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

        // In-VM marker: WSL distros inherit the Windows hostname, so the
        // headless' hostname-based in-VM detection never fires here and bare
        // CLI lanes (e.g. --github-login shells without the unit's env)
        // misclassified as a native Linux host — probing vault at the
        // TLS-hanging 127.0.0.1:8201 port-forward (Esmeralda, 2026-08-09).
        // vault_bootstrap::is_running_in_vm checks this marker.
        self.wsl_root_sh("mkdir -p /etc/tillandsias && touch /etc/tillandsias/in-vm")
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

/// `"Tillandsias v0.3.260712.1"` → `"0.3.260712.1"`. Tolerates surrounding
/// whitespace/extra lines and a bare version without the product prefix.
/// `None` on empty output — the caller treats that as "binary absent".
fn parse_headless_version(stdout: &str) -> Option<String> {
    let line = stdout.lines().find(|l| !l.trim().is_empty())?.trim();
    let v = line.strip_prefix("Tillandsias v").unwrap_or(line).trim();
    (!v.is_empty()).then(|| v.to_string())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    /// The drift class this generator exists to remove: every package must
    /// appear in BOTH the `rpm -q` guard and the `dnf install`, because a
    /// package in only the guard never installs and one in only the install
    /// reinstalls on every provision — and neither is loud.
    fn base_package_setup_lists_every_package_in_both_the_guard_and_the_install() {
        let setup = base_packages_setup();
        let (guard, install) = setup
            .split_once("dnf install -y")
            .expect("setup must contain the dnf install arm");

        assert!(guard.contains("rpm -q"), "guard arm missing:\n{setup}");
        for pkg in GUEST_BASE_PACKAGES {
            assert!(
                guard.contains(pkg),
                "{pkg} missing from the rpm -q guard — it would reinstall every provision:\n{setup}"
            );
            assert!(
                install.contains(pkg),
                "{pkg} missing from the dnf install — it would never install:\n{setup}"
            );
        }
    }

    #[test]
    /// Order 807-c3mf: the accel bench needs jq in the guest, so that this
    /// host's capability-matrix row can be taken at locus=in-guest rather than
    /// host-side-via-mirror.
    fn guest_base_packages_carry_jq_for_the_shared_accel_bench() {
        assert!(
            GUEST_BASE_PACKAGES.contains(&"jq"),
            "jq must ship in the runtime guest or bench-accel-lane.sh cannot run there"
        );
    }

    /// The 0-byte `github-login-last.log` is what made the v0.4.260809.2 blank
    /// terminal so hard to read: it proved the login produced no output at all.
    /// Keep the full-output tee — the terminal-safety half of that fix lives in
    /// tillandsias-headless `should_own_process_group`, not here.
    ///
    /// @trace plan/issues/windows-github-login-blank-terminal-2026-08-09.md
    #[test]
    fn github_login_wrapper_captures_full_output_for_diagnosis() {
        let source = include_str!("wsl_lifecycle.rs");
        let start = source
            .find("let github_login_wrapper = r#\"")
            .expect("the GitHub-Login wrapper must exist");
        let body = &source[start..start + 900];
        let launch = body
            .lines()
            .find(|l| l.contains("tillandsias-headless --github-login"))
            .expect("the wrapper must launch tillandsias-headless --github-login");

        // Every other injected artifact calls the guest binary by absolute
        // path; a bare name makes a PATH without /usr/local/bin fail with a
        // `command not found` indistinguishable from the blank-terminal hang.
        assert!(
            launch.contains("/usr/local/bin/tillandsias-headless"),
            "the wrapper must invoke the guest binary by absolute path: {launch}"
        );

        assert!(
            launch.contains("2>&1 | tee"),
            "both streams must reach the guest-side log, or the next failure is \
             undiagnosable again: {launch}"
        );
        assert!(
            body.contains("rc=${PIPESTATUS[0]}"),
            "the login's own exit code must survive the pipeline, not tee's"
        );
    }

    #[test]
    fn parse_headless_version_extracts_bare_version() {
        assert_eq!(
            parse_headless_version("Tillandsias v0.3.260712.1\n"),
            Some("0.3.260712.1".to_string())
        );
        assert_eq!(
            parse_headless_version("\n  Tillandsias v0.4.260804.1  \n"),
            Some("0.4.260804.1".to_string())
        );
        assert_eq!(
            parse_headless_version("0.4.260804.1"),
            Some("0.4.260804.1".to_string())
        );
        assert_eq!(parse_headless_version(""), None);
        assert_eq!(parse_headless_version("   \n \n"), None);
    }

    #[test]
    fn inconclusive_probe_errors_refuse_destructive_self_heal() {
        for result in [
            DistroExecProbeResult::Timeout,
            DistroExecProbeResult::ServiceFailure("E_UNEXPECTED".into()),
            DistroExecProbeResult::InfrastructureFailure("spawn denied".into()),
        ] {
            let error = result.inconclusive_error("test attempt");
            assert!(error.contains("refusing destructive self-heal"));
        }

        let damage = DistroExecProbeResult::DistroFailure("exit code 1".into());
        assert_eq!(damage.class(), DistroExecProbeClass::DistroFailure);
    }

    /// Order 664-frz0. A fresh VM start whose wire never came up must not leave
    /// the utility VM running.
    ///
    /// Source-shape, for the same reason as the 648-772y pin below: the defect
    /// is a MISSING CALL on a specific path, and no behavioural test of
    /// `perform_wsl_shutdown_recovery` — which already works and is already
    /// used elsewhere — can observe that a path fails to call it.
    #[test]
    fn a_wedged_fresh_start_runs_one_bounded_shutdown_recovery() {
        // Read the PRODUCT half only. `include_str!` of this file also contains
        // this test, which names the recovery call three times — the first
        // version of this test scanned itself and counted them. A window that
        // can accidentally include the test module is not a window at all.
        let source = include_str!("wsl_lifecycle.rs");
        let product = source
            .split(
                "
#[cfg(test)]",
            )
            .next()
            .expect("the product half precedes the test module");
        // The fresh-provision tail: everything after the LAST
        // write_import_complete_marker in the product half, which is where a
        // never-reachable VM is left behind.
        let fresh_tail = product
            .rsplit("self.write_import_complete_marker().await;")
            .next()
            .expect("the fresh-provision tail must exist");
        // …and stop at the end of the provisioning function. Without this the
        // window runs on into `registered_distro_disposition`, which has its own
        // (pre-existing, correct) call to the same recovery — and the
        // exactly-once assertion would count that one too.
        let fresh_tail = fresh_tail
            .split(
                "
    /// ",
            )
            .next()
            .expect("the function is followed by the next item's docs");
        assert!(
            fresh_tail.contains("WslRuntime::perform_wsl_shutdown_recovery().await"),
            "a wedged fresh start must run the bounded recovery"
        );
        assert_eq!(
            fresh_tail
                .matches("WslRuntime::perform_wsl_shutdown_recovery().await")
                .count(),
            1,
            "exactly once — a retry loop here would fight the platform hang, not clear it"
        );
        // The keepalive must be released before the recovery, or the thing
        // holding the wedged VM alive is us.
        let keepalive = fresh_tail
            .find("let _keepalive = self.spawn_keepalive(false).ok();")
            .expect("the connect loop still holds a keepalive");
        let recovery = fresh_tail
            .find("WslRuntime::perform_wsl_shutdown_recovery().await")
            .expect("recovery is present");
        let scope_end = fresh_tail[keepalive..recovery]
            .find("\n        };")
            .expect("the keepalive must live in a scope that closes before recovery");
        assert!(
            keepalive + scope_end < recovery,
            "the keepalive scope must close before the shutdown recovery runs"
        );
    }

    /// NEGATIVE CONTROL for the criterion the packet states second: recovery is
    /// for a wire that NEVER came up. A handshake failing after a previously
    /// healthy wire belongs to the keepalive supervisor, which is separately
    /// bounded, and recovering there would leave two mechanisms fighting over
    /// one VM. The supervisor lives inside `spawn_keepalive`'s respawn loop.
    #[test]
    fn the_keepalive_supervisor_does_not_also_shut_the_vm_down() {
        let source = include_str!("wsl_lifecycle.rs");
        let source = source
            .split(
                "
#[cfg(test)]",
            )
            .next()
            .expect("the product half precedes the test module");
        let supervisor = source
            .split("pub fn spawn_keepalive(&self, debug: bool)")
            .nth(1)
            .expect("spawn_keepalive must exist");
        let supervisor = supervisor
            .split(
                "
    pub ",
            )
            .next()
            .unwrap_or(supervisor);
        assert!(
            supervisor.contains("keepalive gave up after repeated rapid failures"),
            "this window must actually contain the supervisor's give-up path"
        );
        assert!(
            !supervisor.contains("perform_wsl_shutdown_recovery"),
            "the supervisor must not also trigger shutdown recovery"
        );
    }

    /// Order 648-772y. The recovery decision, isolated so it can be tested
    /// without a WSL host: the live closure needs an actual downgrade-then-
    /// upgrade cycle, and this is the part that can be pinned everywhere.
    #[test]
    fn only_a_wiring_rewrite_authorizes_discarding_the_guest() {
        // The 648-jv69 shape: this run rewrote the wiring, then could not talk
        // to the guest. Terminate + reprovision is the known fix and nothing
        // was trying it — the budget just ran out.
        assert!(WslLifecycle::handshake_failure_warrants_reprovision(
            GuestWiringOutcome::Reinjected
        ));
        // A partial rewrite is at least as suspect as a complete one.
        assert!(WslLifecycle::handshake_failure_warrants_reprovision(
            GuestWiringOutcome::Failed
        ));
        // NEGATIVE CONTROL, and the reason this is a function rather than an
        // `if err`: wiring this run did not touch is failing for some OTHER
        // reason. Reprovisioning there would destroy a healthy guest and
        // re-download a rootfs to chase a fault that has nothing to do with
        // version skew — a destructive guess dressed as a fix.
        assert!(!WslLifecycle::handshake_failure_warrants_reprovision(
            GuestWiringOutcome::SkippedVersionMatch
        ));
    }

    /// The decision above only matters if the adopted path actually consults
    /// it. Before 648-772y that path ended in `return self.connect_with_backoff(...)`,
    /// so a failure was terminal by construction — no call site to notice was
    /// missing. This pins that the recovery is wired in, and that the guest is
    /// discarded (unregister + marker removal) rather than merely retried.
    #[test]
    fn adopted_path_recovers_instead_of_exhausting_the_connect_budget() {
        let source = include_str!("wsl_lifecycle.rs");
        let adopted = source
            .split("RegisteredDistroDisposition::UseRegistered =>")
            .nth(1)
            .expect("adopted-guest arm must exist")
            .split("RegisteredDistroDisposition::ReprovisionDamaged")
            .next()
            .expect("adopted arm is bounded by the damaged arm");
        assert!(
            !adopted.contains("return self.connect_with_backoff"),
            "a failed handshake on the adopted path must not be terminal"
        );
        assert!(
            adopted.contains("handshake_failure_warrants_reprovision(wiring)"),
            "the adopted path must consult the recovery decision"
        );
        assert!(
            adopted.contains("self.unregister_distro().await?"),
            "recovery must discard the guest, not just retry the handshake"
        );
        assert!(
            adopted.contains("import_complete_marker_path"),
            "recovery must clear the marker so the fresh provision is not skipped"
        );
    }

    /// Criterion 2. The 648-jv69 incident was diagnosed after the fact from a
    /// preserved diagnostics bundle; the operator watching at the time saw a
    /// generic message and a stall. Both versions must reach them.
    #[test]
    fn version_skew_is_reported_to_the_operator_with_both_versions() {
        let source = include_str!("wsl_lifecycle.rs");
        let reconcile = source
            .split("async fn reconcile_adopted_guest")
            .nth(1)
            .expect("reconcile must exist")
            .split("async fn inject_stale_guest_wiring")
            .next()
            .expect("reconcile is bounded by the injection half");
        assert!(
            reconcile.contains("report_message(&format!("),
            "the operator message must carry the versions, not a fixed string"
        );
        assert!(
            reconcile.contains("guest {}, this build {}"),
            "both the guest and tray versions must be named to the operator"
        );
        assert!(
            reconcile.contains("tray_version = %workspace"),
            "the structured log line stays — the bundle is still the record"
        );
    }

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

    /// windows-260722-1: the curated strings are an operator-approved UX
    /// contract (tray-ux governance) — verbatim pins, the 45-char chip cap,
    /// and the internals-vocabulary ban. Changing any of these requires a
    /// NEW recorded approval.
    #[test]
    fn feature_setup_ux_strings_match_operator_approval() {
        assert_eq!(
            CHIP_FEATURE_SETUP_WARN,
            "\u{1F7E1} One-time Windows setup\u{2026}"
        );
        assert_eq!(
            CHIP_FEATURE_SETUP_PROGRESS,
            "\u{1F535} Installing Windows feature\u{2026}"
        );
        assert_eq!(
            CHIP_FEATURE_RESTART,
            "\u{1F7E0} Restart Windows to finish setup"
        );
        assert_eq!(
            CHIP_FEATURE_FAILED,
            "\u{1F534} Setup didn't finish \u{2014} Retry"
        );
        for chip in [
            CHIP_FEATURE_SETUP_WARN,
            CHIP_FEATURE_SETUP_PROGRESS,
            CHIP_FEATURE_RESTART,
            CHIP_FEATURE_FAILED,
        ] {
            assert!(
                chip.chars().count() <= 45,
                "chip exceeds status cap: {chip}"
            );
        }
        for text in [
            CHIP_FEATURE_SETUP_WARN,
            CHIP_FEATURE_SETUP_PROGRESS,
            CHIP_FEATURE_RESTART,
            CHIP_FEATURE_FAILED,
            TOAST_FEATURE_SETUP,
            TOAST_FEATURE_RESTART,
        ] {
            for banned in ["WSL", "VM", "provision", "virtualization"] {
                assert!(
                    !text.contains(banned),
                    "internals vocabulary {banned:?} in end-user text: {text}"
                );
            }
        }
        assert!(PLATFORM_RESTART_REQUIRED_MARKER.starts_with("windows-feature-setup"));
        assert!(PLATFORM_SETUP_FAILED_MARKER.starts_with("windows-feature-setup"));
    }

    /// windows-260722-1: the platform ensure MUST run before the registered
    /// fast path and before any download — an absent-WSL host must never
    /// fetch the rootfs first (the 2026-07-22 field failure shape).
    #[test]
    fn platform_ensure_runs_before_any_download() {
        let source = include_str!("wsl_lifecycle.rs");
        let body = source
            .split("pub async fn provision_via_recipe")
            .nth(1)
            .expect("provision_via_recipe present");
        let ensure = body
            .find("ensure_wsl_platform")
            .expect("platform ensure called in provision path");
        let registered = body
            .find("is_registered")
            .expect("registered fast path present");
        let download = body
            .find("download_verified")
            .expect("download site present");
        assert!(
            ensure < registered && ensure < download,
            "ensure_wsl_platform must precede the fast path and the download"
        );
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

        // ORDER 735-ewzp: something must ASSERT A BOUND LISTENER after start,
        // not merely that the unit reached `active`. A guest binary built
        // without the listen-vsock feature satisfied every existing signal
        // here — the preflight passed, the process logged app.started, systemd
        // held the unit active — while nothing accepted on 42420 and the host
        // saw a seven-and-a-half minute timeout.
        //
        // ORDER 757-4hdt: that assertion must NOT live on the daemon's unit.
        // As an ExecStartPost with a 15s deadline it stopped a healthy daemon
        // on every cold boot, because the daemon spends minutes building images
        // before it binds. Both properties are pinned together here: the probe
        // exists, and it is not wired anywhere that failing it kills the
        // daemon.
        assert!(
            !headless_unit.contains("ExecStartPost="),
            "the daemon unit must have no ExecStartPost: a control process that              fails there STOPS the service it was measuring (757-4hdt): {headless_unit}"
        );
        let ready_unit = source
            .split("// 4b. tillandsias-headless-ready.service")
            .nth(1)
            .and_then(|tail| tail.split("// 5. home-forge-src.mount").next())
            .expect("ready unit window");
        assert!(
            ready_unit.contains("ExecStart=/usr/local/lib/tillandsias/headless-ready.sh 42420"),
            "the readiness assertion must still run, just not on the daemon's unit: {ready_unit}"
        );
        assert!(
            ready_unit.contains("Type=oneshot"),
            "the assertion is a oneshot, not a service that gets restarted: {ready_unit}"
        );
        // `Wants=`, never `Requires=`: a failed assertion must not drag the
        // daemon down, which is the entire point of moving it.
        assert!(
            ready_unit.contains("Wants=tillandsias-headless.service")
                && !ready_unit.contains("Requires=tillandsias-headless.service"),
            "the assertion must be able to fail alone: {ready_unit}"
        );
        // Provisioning must not BLOCK on the assertion either -- `--now` on it
        // would hang `systemctl enable` for the whole cold-boot image build and
        // then fail the provisioning step, recreating the coupling.
        // Scoped to the provisioning window, NOT the whole file: `include_str!`
        // pulls in this test too, so a whole-source `!contains` would match the
        // assertion's own literal and fail against itself. That trap has bitten
        // this file's checks before.
        let enable_window = source
            .split("// Enable AND start the units now.")
            .nth(1)
            .and_then(|tail| tail.split("// Phase 3d:").next())
            .expect("enable window");
        assert!(
            enable_window.contains("systemctl enable tillandsias-headless-ready.service")
                && !enable_window.contains("enable --now tillandsias-headless-ready.service"),
            "provisioning must enable the assertion without waiting on it (757-4hdt): {enable_window}"
        );
        // The script it names must actually be installed, or the unit fails on
        // a missing file and the diagnosis is about the wrong thing.
        assert!(
            source.contains("/usr/local/lib/tillandsias/headless-ready.sh"),
            "the readiness script the unit references must be written to the guest"
        );
        assert!(
            source.contains("VSOCK-CONNECT:1:"),
            "readiness must connect to the port (CID 1 = VMADDR_CID_LOCAL), not test /dev/vsock"
        );
        // ORDER 757-4hdt: CID 1 needs the vsock_loopback module, which a fresh
        // guest does NOT have loaded. Without these three properties the probe
        // reported the wire down while the host was talking to the guest
        // happily (phase=Ready, podman_ready=true) — a false alarm about a
        // working system. Verified by execution in a live guest: module absent
        // -> loads it and reports bound (exit 0); transport up with nothing
        // listening -> NOT-BOUND (exit 1); no loopback transport at all ->
        // INDETERMINATE (exit 2).
        assert!(
            source.contains("modprobe vsock_loopback"),
            "the probe must load the transport CID 1 depends on before judging"
        );
        assert!(
            source.contains("vsock_listener=INDETERMINATE"),
            "an absent loopback transport must get its own verdict, not be              reported as an unbound listener"
        );
        assert!(
            source.contains("Network is unreachable"),
            "the probe must branch on ENETUNREACH (no transport) versus a              refused connection (nothing listening) — conflating them is how it              failed a healthy system"
        );
        // The connect address must be socat's FIRST argument. With /dev/null
        // first, socat hits EOF and exits 0 before the connection can fail --
        // measured returning 0 against BOTH a live and a dead port, i.e. a
        // check that always passes. This assertion pins the discriminating
        // form, not merely the presence of the address.
        assert!(
            source.contains("socat -T1 \"VSOCK-CONNECT:1:${PORT}\" /dev/null"),
            "the connect address must precede the sink, or the probe passes against a dead port"
        );
        assert!(
            source.contains("vsock_listener=NOT-BOUND"),
            "the failure must name the property that is false, not a generic error"
        );

        // ORDER 798-emje: the module the probe depends on must be present
        // DETERMINISTICALLY before the probe judges, on both paths.
        //
        // These assertions run against the unit LITERAL, not the comment window
        // above it. `ready_unit` spans the explanatory comments too, and those
        // comments now discuss `After=systemd-modules-load.service` by name --
        // so a window-scoped `contains` would keep passing after someone deleted
        // the directive and left the prose. That is 601-462g exactly, and this
        // file has already been bitten by it once (the stale ExecStartPost
        // wording that made a `grep -c` report 1).
        let ready_unit_literal = ready_unit
            .split("let ready_unit = r#\"")
            .nth(1)
            .and_then(|tail| tail.split("\"#;").next())
            .expect("ready unit literal");
        assert!(
            ready_unit_literal.contains("After=systemd-modules-load.service"),
            "the readiness assertion must be ORDERED after the module load, not              race it: the probe connects to CID 1, which requires vsock_loopback              (798-emje): {ready_unit_literal}"
        );
        assert!(
            ready_unit_literal.contains("Wants=systemd-modules-load.service")
                && !ready_unit_literal.contains("Requires=systemd-modules-load.service"),
            "Wants=, never Requires=: a guest where the module genuinely cannot              load must still RUN the probe so it can report INDETERMINATE (exit 2).              Requires= skips it and collapses the third state into 'never ran'              (798-emje): {ready_unit_literal}"
        );

        // The clean-room half. Provisioning used to load the module at the END
        // of inject_bootstrap_logic, ~60 lines AFTER it started the units — so a
        // first provision started the probe and modprobed afterwards. Measured:
        // `preflight vsock_loopback missing`, module loaded 249ms later. The
        // race was in this function's statement order, so the fix is this
        // function's statement order, and THAT is what this pins.
        let provision_window = source
            .split("// 5. home-forge-src.mount")
            .nth(1)
            .and_then(|tail| tail.split("// Phase 3d:").next())
            .expect("provision window");
        let modprobe_at = provision_window
            .find("/etc/modules-load.d/tillandsias-vsock.conf")
            .expect("provisioning must write the modules-load.d entry");
        let enable_at = provision_window
            .find("systemctl enable --now podman.socket")
            .expect("provisioning must enable the units");
        assert!(
            modprobe_at < enable_at,
            "vsock_loopback must be loaded BEFORE the units are started: starting              the readiness assertion first and modprobing afterwards is the              cold-boot race itself (798-emje). modprobe_at={modprobe_at}              enable_at={enable_at}"
        );
        // Loading without confirming leaves the same silent gap one statement
        // later: modprobe no-ops on a kernel without the module and says nothing.
        assert!(
            provision_window.contains("[tillandsias-provision] vsock_loopback=loaded"),
            "provisioning must CONFIRM the module is present, not assume modprobe              worked (798-emje): {provision_window}"
        );
        // And the probe must say which state it started from, so a run that
        // worked because the ordering held is distinguishable from one that
        // worked because the backstop modprobe won a race. Both print the same
        // verdict; only this line separates them.
        assert!(
            source.contains("[tillandsias-ready] vsock_loopback before=${before} after=${after}"),
            "the probe must report the module state it OBSERVED before judging,              or a regression of the ordering is invisible behind a passing probe              (798-emje)"
        );
        // The restart bound belongs to [Unit]; under [Service] systemd ignores
        // it silently, which would leave a permanently-broken guest restarting
        // every two seconds forever.
        // Positional, not a split: this test slices raw SOURCE between two
        // comment markers, so the window contains prose that mentions
        // [Service] and a naive split lands in a comment.
        let burst = headless_unit
            .find("StartLimitBurst=3")
            .expect("start-limit burst is declared");
        let interval = headless_unit
            .find("StartLimitIntervalSec=120")
            .expect("start-limit interval is declared");
        let service_block = headless_unit
            .find("Type=exec")
            .expect("the [Service] block starts at Type=exec");
        assert!(
            burst < service_block && interval < service_block,
            "start-limit directives must precede the [Service] block, i.e. sit in [Unit], \
             where systemd actually reads them"
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
