//! `tillandsias-tray --diagnose` — installed-tray support diagnostic.
//!
//! Mirrors `tillandsias-windows-tray::notify_icon::diagnose` (commit
//! `20fb9d1f`) in spirit — a one-shot CLI flag that prints a bundled
//! health report and exits without launching AppKit. Designed to be
//! invoked from the terminal during user-attended smoke sessions:
//!
//! ```bash
//! /Applications/Tillandsias.app/Contents/MacOS/tillandsias-tray --diagnose
//! ```
//!
//! **macOS-specific limitation vs. windows-tray**: Apple's
//! `Virtualization.framework` vsock is per-VM-handle, not per-host
//! (macOS has no `AF_VSOCK`). A standalone `--diagnose` process
//! therefore cannot reach a separately-running tray's VM control
//! wire — it would need to be the same process that started the VM
//! to hold the `VZVirtioSocketDevice` handle. So unlike windows, the
//! macOS report covers static/filesystem health only:
//!
//!   * version (`CARGO_PKG_VERSION` baked at build)
//!   * bundle identity (whether the binary lives inside an `.app`)
//!   * image-root artifacts (rootfs.img / vmlinuz / initramfs.img)
//!   * manifest pin source (bundled, first 12 chars of SHA)
//!
//! Live wire status comes from clicking the menubar icon (which the
//! 30 s `spawn_vm_status_poller` already drives into the chip text).
//! A future `--attach-existing-tray` would need a host-side Unix
//! socket forwarder; that's a v0.0.2 enhancement.
//!
//! Exit codes mirror windows' shape:
//!   * `0` — image-root provisioned, bundle valid
//!   * `2` — degraded (image-root not provisioned yet — run the
//!     tray once to materialize)
//!   * `1` — hard failure (only used if even the static checks
//!     cannot complete)
//!
//! macOS-only. The non-macOS branch of the crate never compiles this
//! module.
//!
//! @trace spec:macos-native-tray.diagnose@v1,
//!        plan/steps/20-macos-tray-v0_0_1.md (m4 sub-task B slice 11)

#![cfg(target_os = "macos")]

use std::io;
use std::path::PathBuf;
use std::pin::Pin;
use std::sync::OnceLock;
use std::task::{Context, Poll};

use tokio::io::{AsyncRead, AsyncWrite, ReadBuf};

use tillandsias_control_wire::guest_transport::GuestEndpoint;
use tillandsias_secure_channel::{EncryptedStream, HopId, channel_psk, client_handshake};

use crate::guest_binary::stage_embedded_guest_binary;

/// Manifest bundled at build time so the binary doesn't need the repo or
/// network to know its artifact-URL template + pinned SHAs. Same constant
/// pattern as `action_host::BUNDLED_MANIFEST_TOML` — both the tray UI and
/// the headless `--provision` mode consume it.
const BUNDLED_MANIFEST_TOML: &str = include_str!("../../../images/vm/manifest.toml");

/// Where the .app installer materializes VM artifacts on a macOS host.
/// Mirrors `status_item::default_image_root` so `--diagnose` reads the
/// same paths the live tray writes/reads.
fn image_root() -> PathBuf {
    let home = std::env::var_os("HOME")
        .map(PathBuf::from)
        .unwrap_or_else(|| PathBuf::from("/tmp"));
    home.join("Library/Application Support/tillandsias")
}

/// Guest crash-loop DETECTION state file. On macOS `--diagnose` is
/// static/filesystem-only (no live wire handle — `Virtualization.framework`
/// vsock is per-VM-handle, not per-host), so the crash-loop verdict is READ
/// from this file, which the long-lived tray process updates on each
/// VM-status observation. Lives in the same `image_root` the tray already
/// reads/writes, so the two agree.
///
/// @trace plan/issues/guest-crashloop-detection-and-ephemeral-reset-2026-07-17.md
pub fn crashloop_state_path() -> PathBuf {
    image_root().join("crashloop.state")
}

fn unix_now_secs() -> u64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0)
}

/// Read the persisted crash-loop detector and render its verdict in the PINNED
/// grammar `^(healthy|starting|crash-loop:[a-z0-9-]+)$`. A missing/unwritten
/// state file yields `starting` (nothing observed yet), never a panic.
///
/// @trace plan/issues/guest-crashloop-detection-and-ephemeral-reset-2026-07-17.md
pub fn guest_health_verdict() -> String {
    tillandsias_control_wire::crashloop::CrashLoopDetector::load(&crashloop_state_path())
        .verdict(unix_now_secs())
        .verdict()
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum SecureControlWireMode {
    Off,
    On,
}

fn secure_control_wire_mode() -> Result<SecureControlWireMode, String> {
    static MODE: OnceLock<Result<SecureControlWireMode, String>> = OnceLock::new();
    MODE.get_or_init(|| match std::env::var("TILLANDSIAS_SECURE_CONTROL_WIRE") {
        Ok(raw) if raw.eq_ignore_ascii_case("on") => Ok(SecureControlWireMode::On),
        Ok(raw) if raw.eq_ignore_ascii_case("off") || raw.is_empty() => {
            Ok(SecureControlWireMode::Off)
        }
        Ok(raw) => Err(format!(
            "TILLANDSIAS_SECURE_CONTROL_WIRE must be 'on' or 'off' (got {raw:?})"
        )),
        Err(std::env::VarError::NotPresent) => Ok(SecureControlWireMode::Off),
        Err(err) => Err(format!("TILLANDSIAS_SECURE_CONTROL_WIRE: {err}")),
    })
    .clone()
}

type GuestWireStream = Box<dyn tillandsias_control_wire::transport::AsyncReadWrite + Unpin + Send>;

enum ControlWireStream {
    Plain(GuestWireStream),
    Secure(Box<EncryptedStream<GuestWireStream>>),
}

impl AsyncRead for ControlWireStream {
    fn poll_read(
        self: Pin<&mut Self>,
        cx: &mut Context<'_>,
        out: &mut ReadBuf<'_>,
    ) -> Poll<io::Result<()>> {
        match self.get_mut() {
            ControlWireStream::Plain(stream) => Pin::new(stream).poll_read(cx, out),
            ControlWireStream::Secure(stream) => Pin::new(stream).poll_read(cx, out),
        }
    }
}

impl AsyncWrite for ControlWireStream {
    fn poll_write(
        self: Pin<&mut Self>,
        cx: &mut Context<'_>,
        buf: &[u8],
    ) -> Poll<io::Result<usize>> {
        match self.get_mut() {
            ControlWireStream::Plain(stream) => Pin::new(stream).poll_write(cx, buf),
            ControlWireStream::Secure(stream) => Pin::new(stream).poll_write(cx, buf),
        }
    }

    fn poll_flush(self: Pin<&mut Self>, cx: &mut Context<'_>) -> Poll<io::Result<()>> {
        match self.get_mut() {
            ControlWireStream::Plain(stream) => Pin::new(stream).poll_flush(cx),
            ControlWireStream::Secure(stream) => Pin::new(stream).poll_flush(cx),
        }
    }

    fn poll_shutdown(self: Pin<&mut Self>, cx: &mut Context<'_>) -> Poll<io::Result<()>> {
        match self.get_mut() {
            ControlWireStream::Plain(stream) => Pin::new(stream).poll_shutdown(cx),
            ControlWireStream::Secure(stream) => Pin::new(stream).poll_shutdown(cx),
        }
    }
}

async fn open_control_wire_stream(
    vz: &tillandsias_vm_layer::vz::VzRuntime,
    port: u32,
    timeout: std::time::Duration,
) -> Result<ControlWireStream, String> {
    let endpoint = GuestEndpoint::MacVz { port };
    let stream = vz
        .open_guest_transport_stream_current_thread(&endpoint, timeout)
        .await
        .map_err(|e| e.to_string())?;

    match secure_control_wire_mode()? {
        SecureControlWireMode::Off => Ok(ControlWireStream::Plain(stream)),
        SecureControlWireMode::On => {
            let psk = channel_psk(
                tillandsias_secure_channel::workspace_version(),
                tillandsias_control_wire::WIRE_VERSION,
                HopId::HostGuest,
            );
            // 733-mppc. Same defect as action_host.rs's copy of this function,
            // and WORSE HERE because of where it sits: this is the DIAGNOSTIC
            // path, so the tool an operator reaches for when the host is sick
            // was itself the thing that hung. A guest that completes the socket
            // and then stalls mid-Noise parked `--diagnose` forever.
            //
            // THE BOUND IS THE CALLER'S, and for an interactive tool that is the
            // deliberate choice rather than an inherited one. Criterion 2 warns
            // against inheriting an exec-shaped timeout that would leave the
            // diagnostic hanging for minutes; the callers here pass 30s (and
            // `probe_phase_secure_or_plain` passes the readiness probe's own
            // per-attempt budget), so the ceiling is tens of seconds, not
            // minutes — an operator gets an answer while a genuinely slow guest
            // on a loaded host still completes. A shorter fixed constant was
            // rejected: it would make the readiness probe, which legitimately
            // retries against a booting guest, fail faster than the guest can
            // reasonably answer.
            let secure =
                crate::action_host::secure_handshake_bounded(stream, &psk, timeout).await?;
            Ok(ControlWireStream::Secure(Box::new(secure)))
        }
    }
}

/// `VzRuntime::wait_phase_ready`'s per-attempt probe callback. `vm-layer`
/// does not depend on `tillandsias-secure-channel`, so it cannot decide
/// Plain-vs-Secure itself; this reuses the exact `open_control_wire_stream`
/// opener that `--exec-guest` / `--list-cloud-projects` / GitHub login use,
/// so readiness probing never bypasses secure mode when it is enabled.
/// @trace plan/issues/secure-channel-release-and-probe-hardening-2026-07-05.md
async fn probe_phase_secure_or_plain(
    vz: &tillandsias_vm_layer::vz::VzRuntime,
    timeout: std::time::Duration,
) -> Result<tillandsias_control_wire::VmPhase, String> {
    use tillandsias_control_wire::transport::CONTROL_WIRE_VSOCK_PORT;

    let stream = open_control_wire_stream(vz, CONTROL_WIRE_VSOCK_PORT, timeout).await?;
    tillandsias_vm_layer::vsock_exec::probe_vm_phase(stream).await
}

/// Output format selected via `--diagnose` (default) or
/// `--diagnose --json`. Mirrors windows-tray's `DiagnoseFormat`
/// (commit c4908438).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum DiagnoseFormat {
    Human,
    Json,
}

/// Bundled diagnostic-report payload. Both human and JSON formatters
/// emit exactly these fields, so support tooling that parses the JSON
/// gets the same data the user sees in the terminal. Mirrors windows-
/// tray's `DiagnoseReport` (commit c4908438) — field names match
/// byte-for-byte where the concept exists on both hosts; macOS-only
/// fields and windows-only fields differ.
#[derive(serde::Serialize)]
pub struct DiagnoseReport {
    pub version: &'static str,
    pub guest_version: Option<String>,
    pub in_app: bool,
    pub exe_path: Option<String>,
    pub image_root: String,
    pub rootfs_present: bool,
    pub rootfs_bytes: Option<u64>,
    pub kernel_present: bool,
    pub kernel_bytes: Option<u64>,
    pub initrd_present: bool,
    pub initrd_bytes: Option<u64>,
    pub release_tag: &'static str,
    pub manifest_pin_aarch64_qcow2: Option<String>,
    pub provisioned: bool,
    /// 701-kgvk. Which guest binary this bundle carries, versus the one actually
    /// staged for the guest to install on its next boot. The staging path is
    /// keyed only on `$HOME` and the guest reinstalls from it unconditionally,
    /// so an older `.app` started later silently downgrades the guest — stickily,
    /// across reboots and guest resets. Nothing surfaced that before: the only
    /// integrity gate compares a VERSION string that does not roll between
    /// builds. A real skew on this host had to be found by hashing by hand.
    pub guest_binary_bundle_sha256: Option<String>,
    pub guest_binary_staged_sha256: Option<String>,
    /// `Some(false)` means the guest will boot a DIFFERENT binary than this
    /// bundle carries. `None` means undecidable (no bundle, or nothing staged
    /// yet) and must never be read as "fine".
    pub guest_binary_staged_matches_bundle: Option<bool>,
    /// Order 735-2g5i. Whether a live tray process owns the VM right now,
    /// established by probing the tray's own singleton lock.
    ///
    /// This is macOS's answer to the question Windows answers with
    /// `wire.reachable`: is somebody actively working on this? macOS cannot ask
    /// the guest directly — its vsock is per-VM-handle with no AF_VSOCK, so the
    /// live phase is reachable ONLY from inside the tray process (see the
    /// "Control wire status" note in `print_human`). Singleton ownership is the
    /// strongest FACT a separate `--diagnose` process can establish, and like
    /// the Windows probe it is an observation rather than an inference from
    /// timing.
    pub vm_owner_live: bool,

    /// Guest metrics snapshot (778-n9z2), read over the control wire.
    ///
    /// The wire types travel through UNCHANGED — every counter stays
    /// `Option<u64>` and every sample keeps its `error`, with no
    /// `skip_serializing_if` anywhere on the path, so a counter that could
    /// not be collected serialises as JSON `null` and never as a healthy
    /// zero (spec:observability-metrics; the tray hop is exactly where that
    /// contract would be lost).
    ///
    /// `None` on the ordinary standalone `--diagnose`: a separate process
    /// holds no VM handle (VZ vsock is per-VM-handle, macOS has no
    /// AF_VSOCK), so there is nothing to read. `metrics_status` always says
    /// which of those it is.
    pub metrics: Option<tillandsias_control_wire::MetricsSnapshotWire>,

    /// Why `metrics` is or is not populated. Grammar, pinned by test:
    ///   `ok`
    ///   `unsupported:no-live-wire-handle`     — standalone --diagnose
    ///   `unsupported:guest-lacks-capability`  — HelloAck server_caps lacks it
    ///   `error:<slug>`                        — the read was attempted and failed
    ///
    /// A status is mandatory precisely because absence is ambiguous: "no
    /// metrics" must never be readable as "no containers".
    pub metrics_status: String,
}

/// Status constant for the default standalone path — no VM handle, so the
/// wire cannot be read at all. Named so the value cannot drift between the
/// collector and its test.
pub(crate) const METRICS_STATUS_NO_HANDLE: &str = "unsupported:no-live-wire-handle";

/// Status constant for a guest whose HelloAck did not advertise
/// `MetricsSnapshotRequest`. Feature detection is by CAPABILITY, never by
/// wire-version comparison — a version number says what the peer is, a
/// capability says what it can do (778-n9z2 exit criterion 1).
pub(crate) const METRICS_STATUS_NO_CAPABILITY: &str = "unsupported:guest-lacks-capability";

/// Entry point invoked from `main` when `--diagnose` is on argv.
/// Returns the exit code to bubble up via `std::process::exit`.
pub fn main(format: DiagnoseFormat) -> i32 {
    let report = collect_report();
    match format {
        DiagnoseFormat::Human => print_human(&report),
        DiagnoseFormat::Json => print_json(&report),
    }
    exit_code_from(&report)
}

fn collect_report() -> DiagnoseReport {
    let exe = std::env::current_exe().ok();
    let in_app = exe
        .as_ref()
        .and_then(|p| p.to_str())
        .map(|s| s.contains("/Tillandsias.app/"))
        .unwrap_or(false);
    let exe_path = exe.as_ref().map(|p| p.display().to_string());

    let root = image_root();
    let image_root_str = root.display().to_string();
    let (rootfs_present, rootfs_bytes) = stat_file(&root.join("rootfs.img"));
    let (kernel_present, kernel_bytes) = stat_file(&root.join("vmlinuz"));
    let (initrd_present, initrd_bytes) = stat_file(&root.join("initramfs.img"));
    let provisioned = rootfs_present;

    let manifest_pin_aarch64_qcow2 = parse_aarch64_qcow2_sha(BUNDLED_MANIFEST_TOML);
    let provenance = crate::guest_binary::guest_binary_provenance();

    DiagnoseReport {
        version: env!("CARGO_PKG_VERSION"),
        guest_version: None,
        in_app,
        exe_path,
        image_root: image_root_str,
        rootfs_present,
        rootfs_bytes,
        kernel_present,
        kernel_bytes,
        initrd_present,
        initrd_bytes,
        release_tag: crate::action_host::FEDORA_BASELINE,
        manifest_pin_aarch64_qcow2,
        provisioned,
        guest_binary_bundle_sha256: provenance.bundle_sha256,
        guest_binary_staged_sha256: provenance.staged_sha256,
        guest_binary_staged_matches_bundle: provenance.staged_matches_bundle,
        vm_owner_live: live_tray_owns_vm(),
        // collect_report() runs in a process with no VM handle by
        // construction. It must NOT boot one: install-macos.sh runs
        // `--diagnose --json` synchronously during install, so a wire read
        // on this path would start a VM mid-install and could race a live
        // tray's handle. The opt-in verb below is the only reader.
        metrics: None,
        metrics_status: METRICS_STATUS_NO_HANDLE.to_string(),
    }
}

/// Is a live tray holding the VM singleton right now? (order 735-2g5i)
///
/// `Ok(None)` is WouldBlock — the lock is held, i.e. a running tray owns the
/// VM. Acquiring and immediately dropping the guard is side-effect free when
/// the lock is free, which is what makes this safe to call from a read-only
/// report. A probe infrastructure error returns false: an unknown owner must
/// never be reported as a live one, because that is the direction that tells
/// automation to keep waiting.
fn live_tray_owns_vm() -> bool {
    matches!(
        tillandsias_core::singleton::SingletonGuard::try_acquire("tillandsias-macos-tray"),
        Ok(None)
    )
}

fn stat_file(path: &std::path::Path) -> (bool, Option<u64>) {
    match std::fs::metadata(path) {
        Ok(md) => (true, Some(md.len())),
        Err(_) => (false, None),
    }
}

fn print_human(r: &DiagnoseReport) {
    println!("Tillandsias.app diagnostic report");
    println!("================================");
    println!();
    println!("Version:    {}", r.version);
    println!(
        "Bundle:     {}",
        if r.in_app {
            "inside Tillandsias.app (codesigned ad-hoc at build)"
        } else {
            "running outside .app (development binary)"
        }
    );
    if let Some(ref exe_path) = r.exe_path {
        println!("Exe:        {exe_path}");
    }
    println!("Image-root: {}", r.image_root);
    print_artifact("  rootfs.img", r.rootfs_present, r.rootfs_bytes);
    print_artifact("  vmlinuz", r.kernel_present, r.kernel_bytes);
    print_artifact("  initramfs.img", r.initrd_present, r.initrd_bytes);
    println!("Release:    {}", r.release_tag);
    println!("Manifest:   bundled at build (compile-time include_str!)");
    match &r.manifest_pin_aarch64_qcow2 {
        Some(sha) => println!("  aarch64.qcow2 SHA-256 pin: {sha}\u{2026}"),
        None => println!("  aarch64.qcow2 SHA-256 pin: (not found / parse skipped)"),
    }
    println!();
    println!("Control wire status:");
    println!("  (live VM phase + podman_ready are only reachable from");
    println!("   the running tray process itself — macOS vsock is per-");
    println!("   VM-handle, no AF_VSOCK. Click the menubar icon for");
    println!("   the live chip; the 30 s poller refreshes it in place.)");
    println!();
    // Guest crash-loop DETECTION verdict. Read from the state file the live
    // tray persists (this `--diagnose` process holds no live wire handle, per
    // the module-header limitation). Emits the PINNED grammar
    // ^(healthy|starting|crash-loop:[a-z0-9-]+)$; a repeated
    // restart/unseal/handshake pattern flips it to crash-loop:<subsystem>.
    // Additive — does NOT affect the 0/2/1 exit-code contract.
    // @trace plan/issues/guest-crashloop-detection-and-ephemeral-reset-2026-07-17.md
    println!("Guest health: {}", guest_health_verdict());
    println!();
    // 701-kgvk. The guest reinstalls its headless binary from the staged copy on
    // EVERY boot, and that path is keyed only on $HOME — so an older .app
    // started later silently downgrades the guest, and stays downgraded. Print
    // it here because a skew is otherwise invisible: the only integrity gate
    // compares a VERSION string that does not roll between builds.
    println!("Guest binary:");
    match (
        &r.guest_binary_bundle_sha256,
        &r.guest_binary_staged_sha256,
        r.guest_binary_staged_matches_bundle,
    ) {
        (Some(b), Some(_), Some(true)) => {
            println!(
                "  in sync — staged copy matches this bundle ({}…)",
                &b[..12]
            );
        }
        (Some(b), Some(s), Some(false)) => {
            println!(
                "  *** SKEW *** the guest will install a DIFFERENT binary than this bundle carries."
            );
            println!("      this bundle : {}…", &b[..12]);
            println!("      staged copy : {}…", &s[..12]);
            println!("      The staged copy wins on the guest's next boot. Another (likely older)");
            println!("      Tillandsias.app staged it. Re-stage from the build you intend to run.");
        }
        (None, _, _) => {
            println!("  unknown — no bundled guest binary found (running outside .app?);");
            println!("      a run like this stages NOTHING, so the guest keeps whatever it has.");
        }
        (_, None, _) => {
            println!("  not staged yet — the guest has never been given a binary from this host.");
        }
        // Both hashes present but no verdict is structurally impossible today;
        // report it as unknown rather than silently implying agreement.
        (Some(_), Some(_), None) => {
            println!("  unknown — both binaries readable but comparison unavailable.");
        }
    }
    println!();
    if r.provisioned {
        println!("Status: PROVISIONED — first-launch materialization complete.");
    } else if r.vm_owner_live {
        // Order 735-2g5i. Distinct from the line below, and distinctly EXITED:
        // a running tray owns the VM and the boot artifacts are not there yet,
        // which is what provisioning-in-progress looks like from outside the
        // tray process. Telling the operator to "launch the tray once" here
        // would be advice to do the thing they are already doing.
        println!(
            "Status: CONVERGING (exit {DIAGNOSE_EXIT_CONVERGING}) — a running tray owns the VM \
             and is still materializing it."
        );
        println!(
            "        Not an error. Re-run --diagnose in a few moments; the tray's \
             menubar chip shows live progress."
        );
    } else {
        println!(
            "Status: NOT PROVISIONED — launch the tray once (or `open \
             /Applications/Tillandsias.app`) to fetch rootfs.img on \
             first launch."
        );
    }
}

fn print_artifact(label: &str, present: bool, bytes: Option<u64>) {
    if present {
        println!("{label:<16}  present, {} bytes", bytes.unwrap_or(0));
    } else {
        println!("{label:<16}  MISSING");
    }
}

fn print_json(r: &DiagnoseReport) {
    match serde_json::to_string_pretty(r) {
        Ok(s) => println!("{s}"),
        Err(e) => {
            // Best-effort: emit a single-line fallback object so the
            // tool consuming the output isn't stuck parsing empty stdout.
            eprintln!("[tillandsias-tray] --diagnose --json serialize failed: {e}");
            println!("{{\"error\":\"serialize failed: {e}\"}}");
        }
    }
}

/// Exit code for a converging VM: not ready yet, and not broken (order
/// 735-2g5i, matching windows-tray's `DIAGNOSE_EXIT_CONVERGING` from 647-i98k).
///
/// THE DEFECT this closes: a converging state and a broken state shared exit 2,
/// so any scripted post-install check that runs `--diagnose` once and branches
/// on the code declares a still-provisioning host broken. Windows hit exactly
/// that in the 644-a3wj curl smoke and separated the two; macOS still collapsed
/// them, which is the asymmetry
/// `litmus:exit-code-provisioned-zero-degraded-two-symmetric` was reporting.
///
/// macOS reaches the same verdict from a DIFFERENT fact, because it cannot
/// reach the same one. Windows asks the guest and believes the phase it names.
/// macOS has no AF_VSOCK — the live phase is readable only from inside the tray
/// process — so a separate `--diagnose` cannot ask. What it CAN establish is
/// whether a live tray owns the VM, and that is an observation of the same
/// kind: somebody is working on this right now.
pub(crate) const DIAGNOSE_EXIT_CONVERGING: i32 = 3;

fn exit_code_from(r: &DiagnoseReport) -> i32 {
    if r.provisioned {
        return 0;
    }
    // Boot artifacts absent WHILE a live tray owns the VM is the unambiguous
    // converging case: provisioning is the first thing the tray does, so the
    // artifacts are missing BECAUSE the work is still underway. Automation
    // should keep waiting.
    //
    // No live owner stays exit 2 deliberately, mirroring the Windows reasoning
    // for an unreachable wire: with nothing holding the VM, an incomplete image
    // root is indistinguishable from a failed provision, and inventing a third
    // verdict from leftover staging files would trade a false "broken" for a
    // false "converging" — the worse error, because it tells automation to wait
    // for something that will never arrive. Staging residue (`rootfs.qcow2`,
    // `rootfs.img.xz.partial`, `*.part`) survives a crashed provision, so its
    // mere presence is not evidence that anything is still running.
    if r.vm_owner_live {
        return DIAGNOSE_EXIT_CONVERGING;
    }
    2
}

/// Entry point invoked from `main` when `--provision` is on argv.
/// Downloads the Fedora Cloud qcow2, converts it to raw for
/// Virtualization.framework, and SHA-verifies against the manifest
/// pin — all without launching the NSApplication event loop.
/// Prints JSON-line progress to stdout for script consumption.
///
/// Exit codes:
///   * `0` — provisioned (or already provisioned)
///   * `1` — hard failure (manifest parse, network, conversion, SHA)
///
/// `--reset-guest` CLI verb (windows-260717-4): intentional EPHEMERAL RESET —
/// delete the provisioned boot artifacts (rootfs.img and with it the in-VM
/// vault, vmlinuz, initramfs.img), clear the persisted crash-loop state (a
/// fresh guest has a fresh history), then re-run the exact same
/// `provision_main` path `--provision` uses. Destructive by design: state of
/// value lives in the cloud; the only cost is one re-authentication. The
/// dispatcher gates this behind `require_no_live_tray` (order 277) so it
/// never wipes the disk out from under a running tray's VM.
///
/// @trace plan/issues/guest-crashloop-detection-and-ephemeral-reset-2026-07-17.md
pub fn reset_guest_main() -> i32 {
    eprintln!(
        "[reset-guest] This discards the local guest and its cached credentials. \
         Everything lives in the cloud \u{2014} you'll re-authenticate once."
    );
    let vz = tillandsias_vm_layer::vz::VzRuntime::new(3, image_root());
    if let Err(err) = vz.wipe_provisioned_artifacts() {
        eprintln!("[reset-guest] RESULT: FAILED \u{2014} wipe: {err}");
        return 1;
    }
    let _ = std::fs::remove_file(crashloop_state_path());
    eprintln!("[reset-guest] guest wiped \u{2014} reprovisioning from scratch\u{2026}");
    provision_main()
}

pub fn provision_main() -> i32 {
    if let Err(err) = stage_embedded_guest_binary() {
        eprintln!("{{\"error\":\"stage guest binary: {err}\"}}");
        return 1;
    }
    let image_root = image_root();
    let vz = tillandsias_vm_layer::vz::VzRuntime::new(3, image_root);

    if vz.is_provisioned() {
        println!(
            "{{\"status\":\"already_provisioned\",\"path\":\"{}\"}}",
            vz.rootfs_image_path().display()
        );
        return 0;
    }

    let manifest = match tillandsias_vm_layer::recipe::Manifest::from_toml(BUNDLED_MANIFEST_TOML) {
        Ok(m) => m,
        Err(e) => {
            let escaped =
                serde_json::to_string(&e.to_string()).unwrap_or_else(|_| format!("\"{e}\""));
            println!(
                "{{\"error\":\"manifest parse: {}\",\"detail\":{}}}",
                e, escaped
            );
            return 1;
        }
    };

    let rt = match tokio::runtime::Runtime::new() {
        Ok(r) => r,
        Err(e) => {
            println!("{{\"error\":\"tokio runtime: {e}\"}}");
            return 1;
        }
    };

    let on_phase = |phase: &str| {
        let escaped = serde_json::to_string(phase).unwrap_or_else(|_| format!("\"{}\"", phase));
        println!("{{\"phase\":{}}}", escaped);
    };

    match rt.block_on(vz.fetch_fedora_cloud_image(&manifest, &on_phase)) {
        Ok(()) => {
            println!(
                "{{\"status\":\"provisioned\",\"path\":\"{}\"}}",
                vz.rootfs_image_path().display()
            );
            0
        }
        Err(e) => {
            let escaped = serde_json::to_string(&e).unwrap_or_else(|_| format!("\"{}\"", e));
            println!("{{\"error\":{}}}", escaped);
            1
        }
    }
}

/// How long `--exec-guest` waits for piped stdin to reach EOF before giving up
/// on it and booting anyway. Generous enough for a real producer
/// (`gh auth token | …`), short enough that an inherited-but-idle stdin costs
/// seconds instead of forever. A full boot + guest exec measures ~9s on this
/// host, so this is the same order as the work it precedes.
const STDIN_FORWARD_TIMEOUT: std::time::Duration = std::time::Duration::from_secs(5);

/// Read piped stdin to EOF, but never block the caller past `timeout`.
///
/// 663-69kp ROOT CAUSE. The previous shape was `if !stdin().is_terminal() {
/// read_to_end() }` — treating "not a TTY" as "a pipe that will EOF". That
/// holds for `printf … | tray --exec-guest`, and fails for every stdin
/// inherited from a parent that keeps the write end open: an agent harness, a
/// launchd job, a background shell. There `read_to_end` blocks forever, on the
/// main thread, BEFORE the first `eprintln!` and before the VM is created —
/// which is exactly the reported symptom ("hangs before printing even
/// '[exec-guest] starting VM…', nothing reaches stderr"). Measured live
/// 2026-08-11: identical invocations, 12+ minutes silent with inherited stdin
/// vs 9s to completion with `</dev/null`. The packet's standing hypothesis was
/// a VZ storage/disk lock; it is not — no VM process is ever created.
///
/// The read happens on a detached helper thread so the timeout is real: a
/// thread parked in `read(2)` cannot be cancelled, and this is a one-shot
/// process, so the thread is left to die with it.
fn read_piped_stdin_bounded(timeout: std::time::Duration) -> Vec<u8> {
    use std::io::{IsTerminal, Read};

    if std::io::stdin().is_terminal() {
        return Vec::new();
    }
    let (tx, rx) = std::sync::mpsc::channel::<Vec<u8>>();
    std::thread::spawn(move || {
        let mut buf = Vec::new();
        let _ = std::io::stdin().read_to_end(&mut buf);
        let _ = tx.send(buf);
    });
    match rx.recv_timeout(timeout) {
        Ok(buf) => buf,
        Err(_) => {
            eprintln!(
                "[exec-guest] warning: stdin is not a terminal but sent no EOF within {}s — \
                 continuing with NO forwarded stdin.\n\
                 If you meant to pipe input, make sure the producer closes its end \
                 (e.g. `printf '…' | tillandsias-tray --exec-guest …`).\n\
                 If you did not, pass `</dev/null` to say so explicitly.",
                timeout.as_secs()
            );
            Vec::new()
        }
    }
}

/// `--exec-guest <argv...>`: boot the provisioned VM, run `argv` in the guest
/// over the control wire (the same `vsock_exec` path `VzRuntime::exec` uses),
/// print the guest's output + exit, then stop the VM. The real-path proof for
/// the idiomatic exec layer and a reusable headless smoke tool.
///
/// MUST run on the process main thread: Vz `start()`/`stop()` dispatch their VZ
/// completion handlers to the main dispatch queue and pump the CFRunLoop from
/// the calling thread, so the whole flow runs on a **current-thread** runtime on
/// the main thread (mirrors the `vz-spike` headless boot, not the tray's
/// NSApp-on-main + worker model).
///
/// @trace plan/issues/optimization-macos-vz-idiomatic-exec-layer-2026-06-21.md
pub fn exec_guest_main(argv: Vec<String>) -> i32 {
    use tillandsias_vm_layer::VmRuntime;

    if argv.is_empty() {
        eprintln!("--exec-guest requires a command, e.g. --exec-guest /bin/echo HELLO");
        return 2;
    }
    if let Err(err) = stage_embedded_guest_binary() {
        eprintln!("{{\"error\":\"stage guest binary: {err}\"}}");
        return 1;
    }
    let vz = tillandsias_vm_layer::vz::VzRuntime::new(3, image_root());
    vz.set_serial_to_log(true); // keep guest serial getty noise off the user terminal
    if !vz.is_provisioned() {
        eprintln!("{{\"error\":\"not provisioned; run --provision first\"}}");
        return 1;
    }

    let rt = match tokio::runtime::Builder::new_current_thread()
        .enable_all()
        .build()
    {
        Ok(r) => r,
        Err(e) => {
            eprintln!("{{\"error\":\"tokio runtime: {e}\"}}");
            return 1;
        }
    };

    let argv_ref: Vec<&str> = argv.iter().map(|s| s.as_str()).collect();

    // Forward piped host stdin to the guest (delivered on the child's stdin +
    // /dev/tty), so e.g. `printf 'tok\n' | --exec-guest <login-cmd>` works.
    let stdin_bytes: Vec<u8> = read_piped_stdin_bounded(STDIN_FORWARD_TIMEOUT);

    rt.block_on(async move {
        use std::time::Duration;
        use tillandsias_control_wire::transport::CONTROL_WIRE_VSOCK_PORT;

        eprintln!("[exec-guest] starting VM…");
        if let Err(e) = vz.start().await {
            eprintln!("{{\"error\":\"start: {e}\"}}");
            return 1;
        }
        eprintln!("[exec-guest] waiting for VM phase Ready…");
        if let Err(e) = vz
            .wait_phase_ready(Duration::from_secs(300), |t| {
                probe_phase_secure_or_plain(&vz, t)
            })
            .await
        {
            eprintln!("{{\"error\":\"wait_phase_ready: {e}\"}}");
            let _ = vz.stop(Duration::from_secs(10)).await;
            return 1;
        }
        eprintln!("[exec-guest] running: {argv_ref:?}");
        // Connect on THIS (main) thread, not via the trait-level default
        // opener: VZ delivers the connect completion on the main dispatch
        // queue, which is only serviced while the main thread pumps the
        // CFRunLoop. The current-thread GuestTransport helper preserves the
        // per-attempt timeout that readiness probes pass down.
        let stream =
            match open_control_wire_stream(&vz, CONTROL_WIRE_VSOCK_PORT, Duration::from_secs(30))
                .await
            {
                Ok(s) => s,
                Err(e) => {
                    eprintln!("{{\"error\":\"vsock connect: {e}\"}}");
                    let _ = vz.stop(Duration::from_secs(10)).await;
                    return 1;
                }
            };
        // Stream output chunk-by-chunk so long-running commands (curl, --init,
        // forge) show progress live instead of buffering until exit.
        let result = {
            use std::io::Write;
            let stdout = std::io::stdout();
            tillandsias_vm_layer::vsock_exec::exec_over_stream_with_input_streaming(
                stream,
                &argv_ref,
                &stdin_bytes,
                |chunk| {
                    let mut out = stdout.lock();
                    let _ = out.write_all(chunk);
                    let _ = out.flush();
                },
            )
            .await
        };
        let _ = vz.stop(Duration::from_secs(10)).await;

        match result {
            Ok(out) => {
                let signal = out
                    .exit
                    .signal
                    .map(|s| s.to_string())
                    .unwrap_or_else(|| "null".to_string());
                eprintln!(
                    "{{\"status\":\"ok\",\"exit_code\":{},\"signal\":{}}}",
                    out.exit.code, signal,
                );
                out.exit.code
            }
            Err(e) => {
                eprintln!("{{\"error\":\"exec: {e}\"}}");
                1
            }
        }
    })
}

/// How long a NON-INTERACTIVE stdin gets to answer a prompt before we give up.
///
/// Generous compared to `STDIN_FORWARD_TIMEOUT`'s 5s, because a pipe feeding a
/// three-prompt login may be doing real work between lines. Still bounded,
/// because the alternative is unbounded (see `prompt_line`).
const PROMPT_LINE_PIPED_TIMEOUT: std::time::Duration = std::time::Duration::from_secs(30);

/// Prompt the user on the host terminal and read a single line. When `hidden`,
/// terminal echo is disabled via `stty -echo` for the duration (no extra crate
/// dep) so secrets like the PAT are not shown. Returns the trimmed line, or an
/// empty string when stdin could not answer — callers already treat empty as a
/// hard error.
///
/// 663-69kp THIRD PATH. 689-stig bounded the `--exec-guest` stdin read and
/// 689-y2my dealt with the guest heartbeat resetting the exec idle deadline.
/// This function was the remaining unbounded read, and it is the one
/// `--github-login` uses (three call sites). It is worse-placed than the one
/// 689-stig fixed, in a way that changes the SIGNATURE of the hang:
///
///   * `read_line` here had NO `is_terminal()` guard and no timeout at all;
///   * it is called from inside a `DynamicExpect` response closure, i.e. AFTER
///     the VM is booted and the control-wire stream is open — so the symptom is
///     NOT the pre-breadcrumb silence of 689-stig, it is a wedge that already
///     printed its progress lines and is holding a live VM;
///   * and per the comment on the `expects` list below, the guest's 30s PTY
///     heartbeat keeps resetting the exec idle deadline (689-y2my), so nothing
///     upstream bounds the wait either.
///
/// So an unattended `--github-login` WITHOUT `--with-token` boots a VM, reaches
/// the guest's token prompt, and then blocks here forever on a stdin whose
/// parent never closes the write end — an agent harness, a launchd job, a
/// background shell. The 07-29 prompt-ordering deadlock the comment below
/// describes was a SECOND, independent cause of the same 70-minute wedges; it
/// was fixed by reordering, which is why this one survived.
///
/// The rule mirrors 689-stig's insight — "not a TTY" is not "a pipe that will
/// EOF" — without breaking interactive use:
///   * stdin IS a terminal: read unbounded. A human is reading the prompt and
///     typing a token; timing that out would be the bug.
///   * stdin is NOT a terminal: bounded, and on expiry refuse LOUDLY telling the
///     operator how to answer by pipe.
///
/// The refusal deliberately does NOT suggest `--with-token`. That is a
/// tillandsias-headless (GUEST) flag with no macOS host equivalent, and
/// suggesting it here would repeat 663-acdw, where it cost one session two blind
/// credential runs. On macOS the host drives the guest login over the control
/// wire, so PIPING credentials to `--github-login` is the supported unattended
/// path (main.rs:262-271 is the authority) — which is exactly the path this
/// bounded read has to keep working, not merely tolerate.
fn prompt_line(label: &str, hidden: bool) -> String {
    use std::io::{IsTerminal, Write};

    print!("{label}: ");
    let _ = std::io::stdout().flush();

    // Echo suppression must be undone on EVERY exit from this function,
    // including the timeout path. Leaving a terminal with echo off after an
    // already-confusing hang is a hostile end state, and it outlives the
    // process.
    if hidden {
        let _ = std::process::Command::new("stty").arg("-echo").status();
    }
    let restore_echo = || {
        if hidden {
            let _ = std::process::Command::new("stty").arg("echo").status();
            println!(); // newline the suppressed Enter would have produced
        }
    };

    if std::io::stdin().is_terminal() {
        let mut line = String::new();
        let _ = std::io::stdin().read_line(&mut line);
        restore_echo();
        return line.trim().to_string();
    }

    // Non-interactive: the read happens on a detached helper thread so the
    // timeout is real — a thread parked in `read(2)` cannot be cancelled. This
    // is a one-shot process, so the thread is left to die with it.
    let (tx, rx) = std::sync::mpsc::channel::<String>();
    std::thread::spawn(move || {
        let mut line = String::new();
        let _ = std::io::stdin().read_line(&mut line);
        let _ = tx.send(line);
    });
    match rx.recv_timeout(PROMPT_LINE_PIPED_TIMEOUT) {
        Ok(line) => {
            restore_echo();
            line.trim().to_string()
        }
        Err(_) => {
            restore_echo();
            eprintln!(
                "[github-login] stdin is not a terminal and sent no line for \"{label}\" \
                 within {}s — refusing to wait longer.\n\
                 A VM is already booted and the guest is waiting at its prompt, so an \
                 unbounded wait here holds a live VM open indefinitely (663-69kp).\n\
                 On macOS the host drives the guest login over the control wire, so pipe \
                 the answers in — one full line each, in this order (token, author name, \
                 author email), with the producer closing its end:\n\
                 \x20 printf '%s\\n%s\\n%s\\n' \"$TOKEN\" \"$NAME\" \"$EMAIL\" \
                 | tillandsias-tray --github-login\n\
                 (`--with-token` is a tillandsias-headless GUEST flag and is NOT accepted \
                 here — see 663-acdw.)",
                PROMPT_LINE_PIPED_TIMEOUT.as_secs()
            );
            String::new()
        }
    }
}

/// `--transport-conformance`: run the shared GuestTransport conformance
/// fixtures (order 128) against the live VZ backend (order 126 exit
/// criterion 3, "both primitives pass the shared conformance fixtures on
/// Darwin").
///
/// Threading: the fixtures call the REAL trait methods
/// (`GuestTransport::{open_stream, exec, exec_streaming}`), whose VZ connect
/// completions land on the main dispatch queue. A headless caller that parks
/// the main thread in `block_on` would deadlock them (see
/// `open_vsock_stream_current_thread` docs) — so boot + readiness run on the
/// main thread (their helpers pump internally), the fixture set runs on a
/// worker-thread runtime, and the main thread pumps the CFRunLoop until the
/// worker finishes. That is the same division of labor as the AppKit tray,
/// so the run proves the exact code path production uses.
///
/// Verdict grammar (greppable, falsifiable):
/// `transport-conformance: PASS n=<N>` or
/// `transport-conformance: FAIL <fixture>: <reason>`.
pub fn transport_conformance_main() -> i32 {
    use std::sync::Arc;
    use std::time::Duration;
    use tillandsias_control_wire::transport::CONTROL_WIRE_VSOCK_PORT;
    use tillandsias_vm_layer::VmRuntime;
    use tillandsias_vm_layer::transport_conformance::{
        all_passed, render_report, run_all_with_progress,
    };

    if let Err(err) = stage_embedded_guest_binary() {
        eprintln!("{{\"error\":\"stage guest binary: {err}\"}}");
        return 1;
    }
    let vz = Arc::new(tillandsias_vm_layer::vz::VzRuntime::new(3, image_root()));
    vz.set_serial_to_log(true);
    if !vz.is_provisioned() {
        eprintln!(
            "{{\"error\":\"not provisioned; run --provision or launch the tray once first\"}}"
        );
        return 1;
    }
    let rt = match tokio::runtime::Builder::new_current_thread()
        .enable_all()
        .build()
    {
        Ok(r) => r,
        Err(e) => {
            eprintln!("{{\"error\":\"tokio runtime: {e}\"}}");
            return 1;
        }
    };

    // Boot + readiness on the main thread (helpers pump the runloop).
    let booted = rt.block_on(async {
        eprintln!("[transport-conformance] starting VM…");
        if let Err(e) = vz.start().await {
            eprintln!("{{\"error\":\"start: {e}\"}}");
            return false;
        }
        eprintln!("[transport-conformance] waiting for VM phase Ready…");
        if let Err(e) = vz
            .wait_phase_ready(Duration::from_secs(300), |t| {
                probe_phase_secure_or_plain(&vz, t)
            })
            .await
        {
            eprintln!("{{\"error\":\"wait_phase_ready: {e}\"}}");
            return false;
        }
        true
    });
    if !booted {
        let _ = rt.block_on(vz.stop(Duration::from_secs(10)));
        return 1;
    }

    // Fixtures on a worker runtime; main thread pumps the CFRunLoop so the
    // trait-level VZ connects (spawn_blocking + main-queue completion) fire.
    eprintln!("[transport-conformance] running shared fixtures over GuestEndpoint::MacVz…");
    let worker_vz = Arc::clone(&vz);
    let worker = std::thread::spawn(move || {
        let rt = tokio::runtime::Builder::new_current_thread()
            .enable_all()
            .build()
            .map_err(|e| format!("worker tokio runtime: {e}"))?;
        let ep = GuestEndpoint::MacVz {
            port: CONTROL_WIRE_VSOCK_PORT,
        };
        Ok::<_, String>(rt.block_on(async {
            let t: &dyn tillandsias_control_wire::guest_transport::GuestTransport = &*worker_vz;
            // Stream each verdict as it lands (loud floor; a buffered
            // report hides which fixture is hanging).
            run_all_with_progress(t, &ep, &mut |r| match &r.outcome {
                Ok(()) => eprintln!("[transport-conformance] fixture {} ok", r.name),
                Err(e) => eprintln!("[transport-conformance] fixture {} FAIL: {e}", r.name),
            })
            .await
        }))
    });
    while !worker.is_finished() {
        tillandsias_vm_layer::vz::boot::pump_cf_loop_for(Duration::from_millis(50));
    }
    let results = match worker.join() {
        Ok(Ok(results)) => results,
        Ok(Err(e)) => {
            eprintln!("{{\"error\":\"{e}\"}}");
            let _ = rt.block_on(vz.stop(Duration::from_secs(10)));
            return 1;
        }
        Err(_) => {
            eprintln!("{{\"error\":\"conformance worker panicked\"}}");
            let _ = rt.block_on(vz.stop(Duration::from_secs(10)));
            return 1;
        }
    };

    print!("{}", render_report(&results));
    let _ = rt.block_on(vz.stop(Duration::from_secs(10)));
    if all_passed(&results) { 0 } else { 1 }
}

/// `--github-login`: boot the VM and drive the *released* guest
/// `tillandsias-headless --github-login` over the control wire. Each end user is
/// **prompted on the host terminal for their OWN** git author name, git author
/// email, and GitHub PAT — nothing is defaulted from the operator's host git
/// config. The token echo is suppressed (`stty -echo`) and the values are fed to
/// the guest's prompts via the proven expect-style PTY input path, so the token
/// lands on the guest `/dev/tty` and never appears in `argv`. (The host process
/// does hold the token transiently in memory while delivering it; it is never
/// logged or written to argv.)
///
/// Operator usage: run in a terminal and answer the prompts —
///   tillandsias-tray --github-login
///
/// @trace spec:gh-auth-script, plan/issues/optimization-macos-vz-idiomatic-exec-layer-2026-06-21.md
pub fn github_login_main() -> i32 {
    use tillandsias_vm_layer::VmRuntime;

    if let Err(err) = stage_embedded_guest_binary() {
        eprintln!("{{\"error\":\"stage guest binary: {err}\"}}");
        return 1;
    }
    let vz = tillandsias_vm_layer::vz::VzRuntime::new(3, image_root());
    vz.set_serial_to_log(true); // keep guest serial getty noise off the user terminal
    if !vz.is_provisioned() {
        eprintln!(
            "{{\"error\":\"not provisioned; run --provision or launch the tray once first\"}}"
        );
        return 1;
    }
    let rt = match tokio::runtime::Builder::new_current_thread()
        .enable_all()
        .build()
    {
        Ok(r) => r,
        Err(e) => {
            eprintln!("{{\"error\":\"tokio runtime: {e}\"}}");
            return 1;
        }
    };

    rt.block_on(async move {
        use std::time::Duration;
        use tillandsias_control_wire::transport::CONTROL_WIRE_VSOCK_PORT;
        use tillandsias_vm_layer::vsock_exec::{DynamicExpect, exec_over_stream_expect_dynamic};

        eprintln!("[github-login] starting VM…");
        if let Err(e) = vz.start().await {
            eprintln!("{{\"error\":\"start: {e}\"}}");
            return 1;
        }
        eprintln!("[github-login] waiting for VM phase Ready…");
        if let Err(e) = vz
            .wait_phase_ready(Duration::from_secs(300), |t| {
                probe_phase_secure_or_plain(&vz, t)
            })
            .await
        {
            eprintln!("{{\"error\":\"wait_phase_ready: {e}\"}}");
            let _ = vz.stop(Duration::from_secs(10)).await;
            return 1;
        }
        let stream =
            match open_control_wire_stream(&vz, CONTROL_WIRE_VSOCK_PORT, Duration::from_secs(30))
                .await
            {
                Ok(s) => s,
                Err(e) => {
                    eprintln!("{{\"error\":\"vsock connect: {e}\"}}");
                    let _ = vz.stop(Duration::from_secs(10)).await;
                    return 1;
                }
            };
        eprintln!(
            "[github-login] control wire ready; guest auth preflight runs before credential prompts"
        );
        // ORDER IS LOAD-BEARING and must track the GUEST, which prompts
        // CREDENTIAL FIRST, identity second — see the operator directive of
        // 2026-07-29 quoted at crates/tillandsias-headless/src/main.rs:7647
        // ("Prompting for name/email before the token led operators to believe
        // those fields WERE their GitHub credentials").
        //
        // This list said name -> email -> token, i.e. the pre-07-29 guest, and
        // `DynamicExpect` is strictly sequential: the host scanned for "author
        // name" while the guest sat blocked on its token prompt, and neither
        // side could move. That deadlock is silent and, because the guest's 30s
        // PTY heartbeat keeps resetting the exec idle deadline (689-y2my), it
        // is also unbounded — the 70-minute wedges of 2026-08-10/11. The
        // attended login of 2026-07-24 worked precisely because it predates the
        // guest's reorder.
        let expects = vec![
            DynamicExpect {
                needle: b"authentication token".to_vec(),
                label: "github token".to_string(),
                response: Box::new(|| {
                    let pat = prompt_line("GitHub Personal Access Token (hidden)", true);
                    if pat.is_empty() {
                        return Err("--github-login: a GitHub token is required".to_string());
                    }
                    Ok(format!("{pat}\n").into_bytes())
                }),
            },
            DynamicExpect {
                needle: b"author name".to_vec(),
                label: "git author name".to_string(),
                response: Box::new(|| {
                    let name = prompt_line("Git author name", false);
                    if name.is_empty() {
                        return Err(
                            "--github-login: git author name and email are both required"
                                .to_string(),
                        );
                    }
                    Ok(format!("{name}\n").into_bytes())
                }),
            },
            DynamicExpect {
                needle: b"author email".to_vec(),
                label: "git author email".to_string(),
                response: Box::new(|| {
                    let email = prompt_line("Git author email", false);
                    if email.is_empty() {
                        return Err(
                            "--github-login: git author name and email are both required"
                                .to_string(),
                        );
                    }
                    Ok(format!("{email}\n").into_bytes())
                }),
            },
        ];
        eprintln!("[github-login] driving guest login (token -> git name -> email)…");
        let result = exec_over_stream_expect_dynamic(
            stream,
            &[
                "/bin/bash",
                "-lc",
                // The control-wire exec env is cleared (no host-env leak), but
                // the guest `--github-login` needs:
                //   - HOME: prompt_and_store_git_identity writes the managed
                //     git identity (name/email — not the token) under $HOME.
                //   - XDG_RUNTIME_DIR (+writable): require_desktop_user_session
                //     gate on the DesktopUserSession lane.
                //   - TILLANDSIAS_VAULT_API_BASE_URL: the guest vault bootstrap
                //     probes the enclave service DNS name, not the default
                //     loopback publish which is Linux-only.
                // The GitHub token itself is handled by the released flow inside
                // an ephemeral `--rm` git container (piped to `gh auth login
                // --with-token`, written to Vault, container destroyed on exit),
                // so nothing unencrypted is left at rest here.
                //
                // Pre-flight before handing off to headless:
                //   1. Remove any exited proxy container from a prior attempt so
                //      `ensure_proxy_running` can `podman run --name tillandsias-proxy`
                //      without "name already in use".
                //   2. Clamp the ephemeral CA key to 0o600 and heal an existing
                //      widened key DOWN (772-shi9).
                //      This block used to chmod 644 "so Squid (uid 1000) can read
                //      it". That reason is FALSE since 755-qcxh: the key reaches
                //      the proxy as the `tillandsias-ca-key` podman secret
                //      (uid=1000,gid=1000,mode=0400 — main.rs
                //      PROXY_CA_KEY_SECRET_OPTS), and images/proxy/entrypoint.sh
                //      reads ONLY /run/secrets/tillandsias-ca-key, exiting 1 when
                //      it is absent. Nothing in the guest reads this file's mode:
                //      the headless that writes and re-reads it runs as root
                //      (vz.rs writes the unit with no User=).
                //      The heal is UNCONDITIONAL, outside the `test -s` guard,
                //      because an already-present 0644 key skips the openssl block
                //      entirely — and `ensure_proxy_running` early-returns when the
                //      proxy is already up, BEFORE the ensure_ca_bundle call that
                //      would otherwise heal it, so the widened key would survive
                //      for the VM's lifetime.
                "export HOME=/root; export XDG_RUNTIME_DIR=/run/user/0; \
                 export TILLANDSIAS_VAULT_API_BASE_URL=https://vault:8200; \
                 install -d -m 0700 \"$XDG_RUNTIME_DIR\"; \
                 podman rm tillandsias-proxy 2>/dev/null || true; \
                 if ! test -s /tmp/tillandsias-ca/intermediate.key 2>/dev/null; then \
                   mkdir -p /tmp/tillandsias-ca && \
                   openssl req -x509 -newkey rsa:2048 \
                     -keyout /tmp/tillandsias-ca/intermediate.key \
                     -out /tmp/tillandsias-ca/intermediate.crt \
                     -days 25 -nodes -subj '/CN=Tillandsias CA' 2>/dev/null && \
                   chmod 600 /tmp/tillandsias-ca/intermediate.key || true; \
                 fi; \
                 chmod 600 /tmp/tillandsias-ca/intermediate.key 2>/dev/null || true; \
                 exec /usr/local/bin/tillandsias-headless --github-login",
            ],
            expects,
            |ev| eprintln!("[github-login] {ev}"),
        )
        .await;

        // 701-g98y: capture the NEW epoch's handover into the host Keychain
        // BEFORE stopping the VM.
        //
        // A successful login initializes a fresh Vault inside the guest, so the
        // guest now holds a share and root token the host has never seen — the
        // Keychain still holds the PREVIOUS epoch. Until this call existed, that
        // divergence was permanent for a CLI login: the capture half runs only
        // from the GUI tray's paths (action_host.rs), and when the tray next
        // connected it would DELIVER its stale Keychain values into the guest
        // first — overwriting the epoch this command had just created — and only
        // then ask for a handover that was no longer pending. Seeding from the
        // CLI and then opening the tray could therefore destroy the credential
        // the CLI had just proven durable.
        //
        // Capture only, never deliver: this process is the one that CAUSED the
        // new epoch, so anything it holds is older by construction.
        //
        // Best-effort by design — the login itself has already succeeded and its
        // exit code must not change here. A failure is reported loudly because
        // the consequence (a later tray launch clobbering a good credential) is
        // silent and expensive.
        if matches!(&result, Ok(out) if out.exit.code == 0) {
            match open_control_wire_stream(&vz, CONTROL_WIRE_VSOCK_PORT, Duration::from_secs(30))
                .await
            {
                Ok(hstream) => {
                    use tillandsias_control_wire::transport::Transport;
                    use tillandsias_host_shell::vsock_client::Client;
                    let mut client = Client::from_stream(
                        Box::new(hstream),
                        Transport::Vsock {
                            // Same guest CID the VzRuntime was constructed with
                            // at the top of this function.
                            cid: 3,
                            port: CONTROL_WIRE_VSOCK_PORT,
                        },
                    );
                    match client.handshake().await {
                        Ok(_) => {
                            match crate::installation_uuid::capture_vault_handover(&mut client).await
                            {
                                Ok(true) => eprintln!(
                                    "[github-login] host Keychain updated with this login's vault handover"
                                ),
                                // Say what actually happened. A guest holds a
                                // pending handover ONLY after a FRESH Vault init;
                                // a login that reused an already-initialized
                                // Vault has nothing to hand over, and claiming
                                // "updated" there is a success message with no
                                // evidence behind it. IMPORTANT for the operator:
                                // this branch means the Keychain still holds
                                // whatever epoch it held before, which may be
                                // OLDER than the guest's — 701-g98y's hazard is
                                // NOT cleared by this path.
                                Ok(false) => eprintln!(
                                    "[github-login] no pending vault handover to capture — the guest reused an \
                                     already-initialized Vault, so the host Keychain is UNCHANGED. If it was \
                                     already older than the guest's epoch it still is; re-verify with \
                                     --list-cloud-projects after the first tray start (701-g98y)."
                                ),
                                Err(e) => eprintln!(
                                    "[github-login] WARNING: could not capture the vault handover ({e}). \
                                     The login succeeded, but the host Keychain still holds an OLDER epoch — \
                                     opening the tray may overwrite this credential. Re-verify with \
                                     --list-cloud-projects after the first tray start (701-g98y)."
                                ),
                            }
                        }
                        Err(e) => eprintln!(
                            "[github-login] WARNING: handover capture handshake failed ({e}); host Keychain not updated (701-g98y)"
                        ),
                    }
                }
                Err(e) => eprintln!(
                    "[github-login] WARNING: handover capture could not connect ({e}); host Keychain not updated (701-g98y)"
                ),
            }
        }

        let _ = vz.stop(Duration::from_secs(10)).await;

        match result {
            Ok(out) => {
                // Guest output is safe to print: name/email are not secret and
                // the token prompt is `read -rs` (never echoed to the PTY).
                use std::io::Write;
                let _ = std::io::stdout().write_all(&out.stdout);
                let _ = std::io::stdout().flush();
                println!();
                println!(
                    "{{\"status\":\"login-finished\",\"exit_code\":{}}}",
                    out.exit.code
                );
                if out.exit.code == 0 {
                    eprintln!(
                        "[github-login] SUCCESS — the token is in the guest Vault. \
                         Click the tray; the menu should reveal the project submenus."
                    );
                }
                out.exit.code
            }
            Err(e) => {
                eprintln!("{{\"error\":\"login: {e}\"}}");
                1
            }
        }
    })
}

/// `--list-cloud-projects`: boot the VM and run the in-guest
/// `tillandsias-headless --list-cloud-projects` over the control wire, streaming
/// the repo listing to stdout. Mirrors the Linux headless CLI mode for 1:1 tray
/// parity (order 128 parity-matrix row `list-cloud-projects`).
///
/// Requires a prior `--github-login` run to have stored the GitHub token in Vault.
/// `--diagnose --with-metrics`: the ONLY path that reads guest metrics over
/// the control wire (778-n9z2 exit criterion 1).
///
/// Separate from `main(format)` deliberately. A standalone `--diagnose` must
/// stay a static, VM-free report: `scripts/install-macos.sh` runs
/// `--diagnose --json` synchronously during install, so booting a VM on the
/// default path would start a guest mid-install and could collide with a live
/// tray's VM handle. `main.rs` gates this verb with `require_no_live_tray`
/// for the same reason every other VM-booting one-shot is gated (order 277).
///
/// The exit code stays the ordinary `exit_code_from(&report)` contract
/// {0,3,2,1}: a metrics failure is reported IN the report, never by changing
/// the code an operator's script branches on.
///
/// @trace spec:observability-metrics, spec:macos-native-tray
pub fn metrics_snapshot_main(format: DiagnoseFormat) -> i32 {
    use tillandsias_vm_layer::VmRuntime;

    let mut report = collect_report();

    if let Err(err) = stage_embedded_guest_binary() {
        report.metrics_status = "error:stage-guest-binary".to_string();
        eprintln!("[diagnose] stage guest binary: {err}");
        return finish_metrics_report(report, format);
    }
    let vz = tillandsias_vm_layer::vz::VzRuntime::new(3, image_root());
    vz.set_serial_to_log(true);
    if !vz.is_provisioned() {
        report.metrics_status = "error:not-provisioned".to_string();
        eprintln!("[diagnose] not provisioned; run --provision or launch the tray once first");
        return finish_metrics_report(report, format);
    }

    let rt = match tokio::runtime::Builder::new_current_thread()
        .enable_all()
        .build()
    {
        Ok(r) => r,
        Err(e) => {
            report.metrics_status = "error:tokio-runtime".to_string();
            eprintln!("[diagnose] tokio runtime: {e}");
            return finish_metrics_report(report, format);
        }
    };

    let outcome: Result<Option<tillandsias_control_wire::MetricsSnapshotWire>, String> = rt
        .block_on(async {
            use std::time::Duration;
            use tillandsias_control_wire::transport::CONTROL_WIRE_VSOCK_PORT;

            eprintln!("[diagnose] starting VM for the metrics read…");
            vz.start().await.map_err(|e| format!("start: {e}"))?;
            let result = async {
                vz.wait_phase_ready(Duration::from_secs(300), |t| {
                    probe_phase_secure_or_plain(&vz, t)
                })
                .await
                .map_err(|e| format!("wait_phase_ready: {e}"))?;
                let stream =
                    open_control_wire_stream(&vz, CONTROL_WIRE_VSOCK_PORT, Duration::from_secs(30))
                        .await
                        .map_err(|e| format!("vsock connect: {e}"))?;
                tillandsias_vm_layer::vsock_exec::fetch_metrics_snapshot(stream).await
            }
            .await;
            // Stop the VM whatever happened: this verb owns the VM it booted.
            let _ = vz.stop(Duration::from_secs(10)).await;
            result
        });

    match outcome {
        Ok(Some(snapshot)) => {
            report.metrics = Some(snapshot);
            report.metrics_status = "ok".to_string();
        }
        Ok(None) => {
            // Handshake fine, capability absent — an older guest, not a fault.
            report.metrics_status = METRICS_STATUS_NO_CAPABILITY.to_string();
        }
        Err(e) => {
            eprintln!("[diagnose] metrics read failed: {e}");
            report.metrics_status = "error:wire-read".to_string();
        }
    }
    finish_metrics_report(report, format)
}

/// Print a metrics-bearing report and return the ordinary diagnose exit code.
fn finish_metrics_report(report: DiagnoseReport, format: DiagnoseFormat) -> i32 {
    match format {
        DiagnoseFormat::Human => print_human(&report),
        DiagnoseFormat::Json => print_json(&report),
    }
    exit_code_from(&report)
}

/// Applies the same CA cert / exited-proxy workaround as `github_login_main`
/// (TODO linux-next: remove once headless uses 0o640 + rm-on-reuse).
///
/// @trace spec:remote-projects, plan/issues/tray-feature-parity-matrix-2026-06-28.md
pub fn list_cloud_projects_main() -> i32 {
    use tillandsias_vm_layer::VmRuntime;

    if let Err(err) = stage_embedded_guest_binary() {
        eprintln!("{{\"error\":\"stage guest binary: {err}\"}}");
        return 1;
    }
    let vz = tillandsias_vm_layer::vz::VzRuntime::new(3, image_root());
    vz.set_serial_to_log(true);
    if !vz.is_provisioned() {
        eprintln!(
            "{{\"error\":\"not provisioned; run --provision or launch the tray once first\"}}"
        );
        return 1;
    }

    let rt = match tokio::runtime::Builder::new_current_thread()
        .enable_all()
        .build()
    {
        Ok(r) => r,
        Err(e) => {
            eprintln!("{{\"error\":\"tokio runtime: {e}\"}}");
            return 1;
        }
    };

    rt.block_on(async move {
        use std::time::Duration;
        use tillandsias_control_wire::transport::CONTROL_WIRE_VSOCK_PORT;
        use tillandsias_vm_layer::vsock_exec::exec_over_stream_with_input_streaming;

        eprintln!("[list-cloud-projects] starting VM…");
        if let Err(e) = vz.start().await {
            eprintln!("{{\"error\":\"start: {e}\"}}");
            return 1;
        }
        eprintln!("[list-cloud-projects] waiting for VM phase Ready…");
        if let Err(e) = vz
            .wait_phase_ready(Duration::from_secs(300), |t| {
                probe_phase_secure_or_plain(&vz, t)
            })
            .await
        {
            eprintln!("{{\"error\":\"wait_phase_ready: {e}\"}}");
            let _ = vz.stop(Duration::from_secs(10)).await;
            return 1;
        }
        let stream =
            match open_control_wire_stream(&vz, CONTROL_WIRE_VSOCK_PORT, Duration::from_secs(30))
                .await
            {
                Ok(s) => s,
                Err(e) => {
                    eprintln!("{{\"error\":\"vsock connect: {e}\"}}");
                    let _ = vz.stop(Duration::from_secs(10)).await;
                    return 1;
                }
            };
        eprintln!("[list-cloud-projects] control wire ready; fetching remote projects…");

        // Same CA cert + exited-proxy workaround as github_login_main, including
        // the 0o600 clamp and the unconditional heal-down (772-shi9 — see the
        // reasoning at that site: the proxy gets the key as a 0400 podman
        // secret, so no reader ever needed this file widened).
        let cmd = "export HOME=/root; export XDG_RUNTIME_DIR=/run/user/0; \
                   export TILLANDSIAS_VAULT_API_BASE_URL=https://vault:8200; \
                   install -d -m 0700 \"$XDG_RUNTIME_DIR\"; \
                   podman rm tillandsias-proxy 2>/dev/null || true; \
                   if ! test -s /tmp/tillandsias-ca/intermediate.key 2>/dev/null; then \
                     mkdir -p /tmp/tillandsias-ca && \
                     openssl req -x509 -newkey rsa:2048 \
                       -keyout /tmp/tillandsias-ca/intermediate.key \
                       -out /tmp/tillandsias-ca/intermediate.crt \
                       -days 25 -nodes -subj '/CN=Tillandsias CA' 2>/dev/null && \
                     chmod 600 /tmp/tillandsias-ca/intermediate.key || true; \
                   fi; \
                   chmod 600 /tmp/tillandsias-ca/intermediate.key 2>/dev/null || true; \
                   exec /usr/local/bin/tillandsias-headless --list-cloud-projects";

        let result = exec_over_stream_with_input_streaming(
            stream,
            &["/bin/bash", "-lc", cmd],
            &[],
            |chunk| {
                use std::io::Write;
                let _ = std::io::stdout().write_all(chunk);
                let _ = std::io::stdout().flush();
            },
        )
        .await;
        let _ = vz.stop(Duration::from_secs(10)).await;

        match result {
            Ok(out) => {
                eprintln!(
                    "{{\"status\":\"list-cloud-projects-finished\",\"exit_code\":{}}}",
                    out.exit.code
                );
                out.exit.code
            }
            Err(e) => {
                eprintln!("{{\"error\":\"list-cloud-projects: {e}\"}}");
                1
            }
        }
    })
}

/// `--opencode <path> [--prompt <text>]`: boot the VM and run the in-guest
/// `tillandsias-headless --opencode <path>` over the control wire, streaming
/// PTY output to the host terminal in real-time. When `--prompt` is given the
/// forge runs non-interactively (one shot + exit); without it the session is
/// open-ended until the user exits.
///
/// @trace plan/issues/smoke-curl-install-e2e-macos-v0.3.260626.4-2026-06-26.md
/// Guest-side root where the host's `~/src` arrives via the `home-src`
/// virtiofs share (vz.rs cloud-init fstab entry).
const GUEST_SRC_ROOT: &str = "/home/forge/src";

/// Order 331: translate an operator-supplied project path into the
/// guest-visible form, BEFORE booting the VM.
///
/// Pure over already-absolute host paths so it is unit-pinnable:
/// - a path already under `/home/forge/src` passes through verbatim
///   (the operator supplied the guest form);
/// - a path under `<host_home>/src/…` rewrites to `/home/forge/src/…`
///   (only `~/src` is shared into the guest, so only it can translate);
/// - anything else is rejected with a message naming both accepted forms —
///   failing on the host in milliseconds instead of after a ~60s boot with
///   the guest's opaque "Project not found" (live repro 2026-07-13).
pub fn translate_project_path_for_guest(abs_path: &str, host_home: &str) -> Result<String, String> {
    let guest_root = std::path::Path::new(GUEST_SRC_ROOT);
    let p = std::path::Path::new(abs_path);
    if p.starts_with(guest_root) {
        return Ok(abs_path.to_string());
    }
    let host_src = std::path::Path::new(host_home).join("src");
    if let Ok(rest) = p.strip_prefix(&host_src) {
        if rest.as_os_str().is_empty() {
            return Err(format!(
                "--opencode needs a project INSIDE {}, not the src root itself",
                host_src.display()
            ));
        }
        return Ok(guest_root.join(rest).to_string_lossy().into_owned());
    }
    Err(format!(
        "--opencode project path must be under {} (host form) or {} (guest form); got: {}. \
         Only ~/src is shared into the guest, so projects elsewhere are not visible to the forge.",
        host_src.display(),
        GUEST_SRC_ROOT,
        abs_path
    ))
}

/// Host-side wrapper for [`translate_project_path_for_guest`]: resolves
/// relative paths (including the bare-`.` default) against the current
/// directory via `canonicalize` when the path exists on the host, then
/// applies the pure translation.
fn resolve_project_path_pre_boot(raw: &str) -> Result<String, String> {
    let host_home = std::env::var("HOME").map_err(|_| "HOME is not set".to_string())?;
    // Guest-absolute paths don't exist on the host; skip canonicalize.
    if raw.starts_with(GUEST_SRC_ROOT) {
        return translate_project_path_for_guest(raw, &host_home);
    }
    let abs = std::fs::canonicalize(raw)
        .map(|p| p.to_string_lossy().into_owned())
        .unwrap_or_else(|_| raw.to_string());
    translate_project_path_for_guest(&abs, &host_home)
}

pub fn opencode_main(path: String, prompt: Option<String>) -> i32 {
    use tillandsias_vm_layer::VmRuntime;

    // Order 331: translate/validate on the host BEFORE any VM work.
    let path = match resolve_project_path_pre_boot(&path) {
        Ok(p) => p,
        Err(e) => {
            eprintln!("{{\"error\":\"{e}\"}}");
            return 2;
        }
    };

    if let Err(err) = stage_embedded_guest_binary() {
        eprintln!("{{\"error\":\"stage guest binary: {err}\"}}");
        return 1;
    }
    let vz = tillandsias_vm_layer::vz::VzRuntime::new(3, image_root());
    vz.set_serial_to_log(true);
    if !vz.is_provisioned() {
        eprintln!(
            "{{\"error\":\"not provisioned; run --provision or launch the tray once first\"}}"
        );
        return 1;
    }

    let rt = match tokio::runtime::Builder::new_current_thread()
        .enable_all()
        .build()
    {
        Ok(r) => r,
        Err(e) => {
            eprintln!("{{\"error\":\"tokio runtime: {e}\"}}");
            return 1;
        }
    };

    rt.block_on(async move {
        use std::time::Duration;
        use tillandsias_control_wire::transport::CONTROL_WIRE_VSOCK_PORT;
        use tillandsias_vm_layer::vsock_exec::exec_over_stream_with_input_streaming;

        eprintln!("[opencode] starting VM…");
        if let Err(e) = vz.start().await {
            eprintln!("{{\"error\":\"start: {e}\"}}");
            return 1;
        }
        eprintln!("[opencode] waiting for VM phase Ready…");
        if let Err(e) = vz
            .wait_phase_ready(Duration::from_secs(300), |t| {
                probe_phase_secure_or_plain(&vz, t)
            })
            .await
        {
            eprintln!("{{\"error\":\"wait_phase_ready: {e}\"}}");
            let _ = vz.stop(Duration::from_secs(10)).await;
            return 1;
        }
        let stream =
            match open_control_wire_stream(&vz, CONTROL_WIRE_VSOCK_PORT, Duration::from_secs(30))
                .await
            {
                Ok(s) => s,
                Err(e) => {
                    eprintln!("{{\"error\":\"vsock connect: {e}\"}}");
                    let _ = vz.stop(Duration::from_secs(10)).await;
                    return 1;
                }
            };
        eprintln!("[opencode] control wire ready; launching forge in guest…");

        // Build the shell command for the guest: set required env vars and
        // exec the headless binary with --opencode and optional --prompt.
        // TILLANDSIAS_FORGE_SRC_ISOLATION=clone (order 342): the macOS lane
        // shares the operator's real checkout into the guest over virtiofs,
        // so the forge MUST work on a guest-owned clone — a blocked in-forge
        // cycle once git-cleaned sibling work through this share
        // (plan/issues/forge-shared-checkout-destructive-clean-2026-07-13.md).
        let mut headless_cmd = format!(
            "export HOME=/root; \
             export XDG_RUNTIME_DIR=/run/user/0; \
             export TILLANDSIAS_VAULT_API_BASE_URL=https://vault:8200; \
             export TILLANDSIAS_FORGE_SRC_ISOLATION=clone; \
             install -d -m 0700 \"$XDG_RUNTIME_DIR\"; \
             exec /usr/local/bin/tillandsias-headless --opencode {path}"
        );
        if let Some(ref p) = prompt {
            // Shell-quote the prompt so spaces/special chars are safe.
            let escaped: String = p
                .chars()
                .flat_map(|c| {
                    if c == '\'' {
                        vec!['\'', '\\', '\'', '\'']
                    } else {
                        vec![c]
                    }
                })
                .collect();
            headless_cmd.push_str(&format!(" --prompt '{escaped}'"));
        }

        let argv: &[&str] = &["/bin/bash", "-lc", &headless_cmd];
        let result = exec_over_stream_with_input_streaming(stream, argv, &[], |chunk| {
            use std::io::Write;
            let _ = std::io::stdout().write_all(chunk);
            let _ = std::io::stdout().flush();
        })
        .await;
        let _ = vz.stop(Duration::from_secs(10)).await;

        match result {
            Ok(out) => {
                eprintln!(
                    "{{\"status\":\"opencode-finished\",\"exit_code\":{}}}",
                    out.exit.code
                );
                out.exit.code
            }
            Err(e) => {
                eprintln!("{{\"error\":\"opencode: {e}\"}}");
                1
            }
        }
    })
}

/// Extract the first 12-char SHA-256 prefix for `aarch64.qcow2` from a
/// manifest.toml body. Pure, testable — both the quoted-key form
/// (`"aarch64.qcow2" = "<sha>"`, the actual file) and the bare-key
/// form (`aarch64.qcow2 = "<sha>"`) parse. Returns the 12-char prefix
/// or None if no valid pin is found.
fn parse_aarch64_qcow2_sha(manifest_toml: &str) -> Option<String> {
    for line in manifest_toml.lines() {
        let trimmed = line.trim().trim_start_matches('"');
        if let Some(rest) = trimmed.strip_prefix("aarch64.qcow2") {
            let rest = rest.trim_start_matches(['"', ' ', '=', '"']);
            let sha: String = rest.chars().take_while(|c| c.is_ascii_hexdigit()).collect();
            if sha.len() >= 12 {
                return Some(sha[..12].to_string());
            }
        }
    }
    None
}

#[cfg(test)]
mod tests {
    use super::parse_aarch64_qcow2_sha;
    use super::translate_project_path_for_guest;
    use super::{METRICS_STATUS_NO_CAPABILITY, METRICS_STATUS_NO_HANDLE};

    /// `parse_aarch64_qcow2_sha` reads the actual manifest.toml format
    /// the Fedora pivot emits (`"aarch64.qcow2" = "<sha>"` inside
    /// `[output.expected_rootfs_sha]`). Asserts on a single 12-char
    /// prefix so the test isn't sensitive to the live SHA changing.
    #[test]
    fn parses_quoted_key_sha_form() {
        let manifest = r#"
[output.expected_rootfs_sha]
"aarch64.tar" = "ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff"
"aarch64.qcow2" = "55c60a3b80d3616a08705afd0459e75fe9f03c54aba7a46e4002a41a72fa0d5b"
"#;
        assert_eq!(
            parse_aarch64_qcow2_sha(manifest),
            Some("55c60a3b80d3".to_string())
        );
    }

    /// Tolerate the bare-key form too. TOML accepts both for keys
    /// that contain only `[A-Za-z0-9_-]` plus dots, so future
    /// manifest authors might drop the quotes.
    #[test]
    fn parses_bare_key_sha_form() {
        let manifest =
            "aarch64.qcow2 = \"abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789\"";
        assert_eq!(
            parse_aarch64_qcow2_sha(manifest),
            Some("abcdef012345".to_string())
        );
    }

    /// Placeholder SHA ("pending-ci") must NOT parse as a valid
    /// pin — `take_while(is_ascii_hexdigit)` produces "" since `p`
    /// is hex but the resulting prefix is too short. Return None so
    /// the diagnose report falls back to "(not found / parse
    /// skipped)" instead of printing garbage.
    #[test]
    fn refuses_placeholder_pending_ci() {
        let manifest = r#""aarch64.qcow2" = "pending-ci""#;
        assert_eq!(parse_aarch64_qcow2_sha(manifest), None);
    }

    fn source_window<'a>(source: &'a str, signature: &str) -> &'a str {
        let start = source
            .find(signature)
            .unwrap_or_else(|| panic!("missing signature: {signature}"));
        let tail = &source[start..];
        let end = tail.find("\n///").unwrap_or(tail.len());
        &tail[..end]
    }

    /// 663-69kp THIRD PATH. `prompt_line` is the only remaining stdin read on a
    /// one-shot path, and it had no `is_terminal()` guard and no timeout. It is
    /// reached from inside the `DynamicExpect` closures — after the VM is booted
    /// and the control wire is open — and per 689-y2my the guest's 30s PTY
    /// heartbeat keeps resetting the exec idle deadline, so nothing upstream
    /// bounds it either. An unattended `--github-login` therefore booted a VM and
    /// then blocked here forever on a stdin whose parent never closes.
    ///
    /// HONEST LIMIT OF THIS TEST: it is a SOURCE-SHAPE assertion, not a
    /// behavioural one. It cannot prove the timeout fires — only that the guard
    /// and the bound are present and that the interactive path stays unbounded.
    /// A behavioural test would have to boot a VM, which is far too heavy for a
    /// unit test and is why the property is pinned this way rather than not at
    /// all. Treat a green result here as "the shape is right", not as "measured".
    #[test]
    fn prompt_line_is_bounded_for_non_interactive_stdin() {
        let source = include_str!(concat!(env!("CARGO_MANIFEST_DIR"), "/src/diagnose.rs"));
        let window = source_window(
            source,
            "fn prompt_line(label: &str, hidden: bool) -> String {",
        );

        assert!(
            window.contains("is_terminal()"),
            "prompt_line must distinguish an interactive stdin from a pipe — treating \
             'not a TTY' as 'a pipe that will EOF' is the 689-stig mistake: {window}"
        );
        assert!(
            window.contains("recv_timeout(PROMPT_LINE_PIPED_TIMEOUT)"),
            "the NON-INTERACTIVE read must be bounded, or an unattended --github-login \
             wedges forever holding a live VM (663-69kp): {window}"
        );
        // The interactive branch must stay UNBOUNDED. A human reading a prompt and
        // typing a token must never be timed out; a fix that bounded both paths
        // would satisfy the assertion above and break attended logins.
        let terminal_idx = window
            .find("if std::io::stdin().is_terminal() {")
            .expect("prompt_line must special-case an interactive stdin");
        let terminal_branch = &window[terminal_idx..];
        let terminal_end = terminal_branch
            .find("// Non-interactive")
            .expect("the interactive branch must precede the bounded one");
        assert!(
            !terminal_branch[..terminal_end].contains("recv_timeout"),
            "the INTERACTIVE branch must not be bounded — a human typing a token is not a \
             hang: {}",
            &terminal_branch[..terminal_end]
        );

        // Echo restoration must be reachable from the timeout path too: leaving a
        // terminal with echo off outlives the process.
        assert!(
            window.matches("restore_echo()").count() >= 3,
            "restore_echo must run on the interactive, piped-ok AND timeout exits — a \
             terminal left with echo disabled after a hang is a hostile end state: {window}"
        );

        // The refusal must not send the operator to a flag this binary rejects.
        assert!(
            !window.contains("--github-login --with-token"),
            "must NOT suggest --with-token: it is a tillandsias-headless GUEST flag with no \
             macOS host equivalent, and suggesting it repeats 663-acdw (two blind credential \
             runs). main.rs:262-271 is the authority: pipe to --github-login instead."
        );
    }

    #[test]
    fn github_login_host_prompts_after_control_wire_ready() {
        let source = include_str!(concat!(env!("CARGO_MANIFEST_DIR"), "/src/diagnose.rs"));
        let window = source_window(source, "pub fn github_login_main() -> i32");
        let start_idx = window
            .find("vz.start().await")
            .expect("github login must start the VM");
        let wait_idx = window
            .find("wait_phase_ready(Duration::from_secs(300), |t| {")
            .expect("github login must wait for the VM phase Ready");
        let stream_idx = window
            .find("open_control_wire_stream(")
            .expect("github login must open the control-wire stream");
        let prompt_idx = window
            .find("prompt_line(\"Git author name\"")
            .expect("github login must prompt for git identity");
        let dynamic_idx = window
            .find("let result = exec_over_stream_expect_dynamic")
            .expect("github login must use lazy prompt responses");

        assert!(start_idx < wait_idx);
        assert!(wait_idx < stream_idx);
        assert!(
            stream_idx < prompt_idx,
            "host prompts must not be reachable before VM/control-wire readiness: {window}"
        );
        assert!(
            prompt_idx < dynamic_idx,
            "prompts should be supplied lazily through the dynamic expect path"
        );
    }

    /// Order 259 lock-namespace pin: the login exec preamble's
    /// XDG_RUNTIME_DIR export must stay /run/user/0 — the same value the
    /// guest headless unit pins (vm-layer vz.rs, its own matching test).
    /// The order-232 per-resource flocks live under
    /// $XDG_RUNTIME_DIR/tillandsias-locks; if the two processes resolve
    /// different dirs the vault check+act sections never serialize and the
    /// fresh-VM first-login name-in-use race (exit 125) returns.
    #[test]
    fn github_login_preamble_pins_the_shared_lock_namespace() {
        let source = include_str!(concat!(env!("CARGO_MANIFEST_DIR"), "/src/diagnose.rs"));
        let window = source_window(source, "pub fn github_login_main() -> i32");
        assert!(
            window.contains("export XDG_RUNTIME_DIR=/run/user/0;"),
            "login preamble must export the lock namespace the headless unit pins (order 259)"
        );
    }

    /// litmus:secure-wait-phase-ready — `wait_phase_ready`'s probe callback
    /// must route through the same secure-or-plain opener as user actions
    /// (`open_control_wire_stream`), not a bare `open_vsock_stream*` connect.
    /// Otherwise a flag-ON guest's readiness probe would run in plaintext
    /// even though the guest only speaks Noise, and could hang/fail even
    /// though the real user-facing traffic is correctly secured.
    /// @trace plan/issues/secure-channel-release-and-probe-hardening-2026-07-05.md
    #[test]
    fn probe_phase_secure_or_plain_uses_the_secure_or_plain_opener() {
        let source = include_str!(concat!(env!("CARGO_MANIFEST_DIR"), "/src/diagnose.rs"));
        let start = source
            .find("async fn probe_phase_secure_or_plain(")
            .expect("probe_phase_secure_or_plain must exist");
        let tail = &source[start..];
        // Function bodies here are flat (no nested `}\n}`), so the first
        // `\n}\n` after `start` is this function's own closing brace.
        let end = tail.find("\n}\n").map(|i| i + 2).unwrap_or(tail.len());
        let window = &tail[..end];

        assert!(
            window.contains("open_control_wire_stream("),
            "wait_phase_ready's probe callback must open its connection via \
             open_control_wire_stream (the secure-or-plain opener), not a raw \
             vsock connect: {window}"
        );
        assert!(
            !window.contains("open_vsock_stream"),
            "wait_phase_ready's probe callback must not bypass \
             open_control_wire_stream with a direct vsock connect: {window}"
        );
    }

    /// `--diagnose` and its sibling CLI actions must construct a normalized
    /// macOS guest endpoint and delegate current-thread VZ connection details
    /// to vm-layer, rather than naming `VsockStream` directly.
    ///
    /// @trace spec:host-guest-transport
    #[test]
    fn diagnose_control_wire_opener_uses_guest_transport_endpoint() {
        let source = include_str!(concat!(env!("CARGO_MANIFEST_DIR"), "/src/diagnose.rs"));
        let start = source
            .find("async fn open_control_wire_stream(")
            .expect("open_control_wire_stream must exist");
        let tail = &source[start..];
        let end = tail.find("\n///").unwrap_or(tail.len());
        let window = &tail[..end];

        assert!(
            window.contains("GuestEndpoint::MacVz"),
            "diagnose opener must construct the normalized MacVz endpoint: {window}"
        );
        assert!(
            window.contains("open_guest_transport_stream_current_thread(&endpoint, timeout)"),
            "diagnose opener must delegate current-thread VZ details to vm-layer: {window}"
        );
        assert!(
            !window.contains("open_vsock_stream_current_thread"),
            "diagnose opener must not call the raw VZ connector directly: {window}"
        );
        let raw_stream_type = concat!("transport_macos::", "VsockStream");
        assert!(
            !source.contains(raw_stream_type),
            "diagnose.rs must not name the raw macOS stream type directly"
        );
    }

    /// 778-n9z2 criterion 2 — the NO-FABRICATION contract must survive the
    /// tray hop. A sample that failed to collect carries `error` and absent
    /// counters; it must serialise as JSON `null`s, never as healthy zeros
    /// and never by vanishing from the document (spec:observability-metrics).
    ///
    /// This is the assertion that would catch the two tempting "cleanups" —
    /// a `.unwrap_or(0)` on the counters, or a
    /// `skip_serializing_if = "Option::is_none"` on the wire structs — either
    /// of which silently converts "could not measure" into "measured zero".
    #[test]
    fn metrics_error_sample_renders_null_counters_never_zero() {
        use tillandsias_control_wire::{
            ContainerMetricWire, MetricsSnapshotWire, MountIoMetricWire,
        };

        let mut report = baseline_diagnose_report();
        report.metrics = Some(MetricsSnapshotWire {
            sampled_at_unix: 1_786_900_000,
            containers: vec![ContainerMetricWire {
                name: "tillandsias-proxy".to_string(),
                cpu_usec: None,
                memory_current_bytes: None,
                blkio_read_bytes: None,
                blkio_write_bytes: None,
                blkio_read_ops: None,
                blkio_write_ops: None,
                error: Some("cgroup read failed: ENOENT".to_string()),
            }],
            mounts: vec![MountIoMetricWire {
                path: "/home/forge/src".to_string(),
                device: None,
                read_bytes: None,
                write_bytes: None,
                read_ops: None,
                write_ops: None,
                error: Some("unavailable: virtiofs".to_string()),
            }],
        });
        report.metrics_status = "ok".to_string();

        let json = serde_json::to_value(&report).expect("report must serialise");
        let container = &json["metrics"]["containers"][0];
        assert!(
            container["cpu_usec"].is_null(),
            "an uncollected counter must be null, not a fabricated zero: {container}"
        );
        assert!(
            container["memory_current_bytes"].is_null(),
            "an uncollected counter must be null: {container}"
        );
        assert_eq!(
            container["error"], "cgroup read failed: ENOENT",
            "the sample's error must survive the tray hop"
        );
        let mount = &json["metrics"]["mounts"][0];
        assert!(
            mount["read_bytes"].is_null() && mount["device"].is_null(),
            "an unavailable mount reports nulls, not zeros: {mount}"
        );
        assert_eq!(mount["error"], "unavailable: virtiofs");
        // Absent-vs-null matters: a consumer must be able to tell "no such
        // key" (schema drift) from "known key, unmeasured".
        assert!(
            container.get("cpu_usec").is_some() && mount.get("read_bytes").is_some(),
            "counters must be PRESENT-and-null, never omitted"
        );
    }

    /// 778-n9z2 criterion 1 — the report always says WHY metrics are absent,
    /// and the default standalone path never claims a wire it does not hold.
    #[test]
    fn metrics_status_states_why_metrics_are_absent() {
        let report = baseline_diagnose_report();
        assert_eq!(report.metrics_status, METRICS_STATUS_NO_HANDLE);
        assert!(report.metrics.is_none());

        let json = serde_json::to_value(&report).expect("report must serialise");
        assert!(
            json["metrics"].is_null(),
            "no snapshot must serialise as null, not as an empty object that reads like 'no containers'"
        );
        assert_eq!(json["metrics_status"], METRICS_STATUS_NO_HANDLE);

        for status in [
            "ok",
            METRICS_STATUS_NO_HANDLE,
            METRICS_STATUS_NO_CAPABILITY,
            "error:wire-read",
        ] {
            assert!(
                status == "ok"
                    || status.starts_with("unsupported:")
                    || status.starts_with("error:"),
                "metrics_status grammar is ok|unsupported:<why>|error:<slug>, got {status}"
            );
        }
        // Feature detection is by capability, never by wire version — the
        // constant that carries that decision must name the capability.
        assert_eq!(
            tillandsias_vm_layer::vsock_exec::CAP_METRICS_SNAPSHOT,
            "MetricsSnapshotRequest"
        );
    }

    /// 772-shi9: neither guest exec preamble may widen the CA PRIVATE key.
    ///
    /// Both preambles once ran `chmod 644` on it, justified by "so Squid
    /// (uid 1000) can read it" — false since 755-qcxh made the key travel as a
    /// 0400 podman secret. The widened mode also persisted, because a
    /// preamble that finds the key present skips the openssl block and
    /// `ensure_proxy_running` early-returns before the heal.
    ///
    /// Two mechanics are load-bearing. The key path is assembled with
    /// `concat!` so this test's own literals are not present verbatim in the
    /// scanned source (the same dodge as the raw-stream-type pin above);
    /// without it the negative assertions match themselves. And every
    /// negative is anchored to the KEY path — `intermediate.crt` is
    /// deliberately world-readable, so a bare `chmod 644` scan would forbid
    /// the correct thing.
    #[test]
    fn guest_ca_preflight_never_widens_the_private_key() {
        let source = include_str!(concat!(env!("CARGO_MANIFEST_DIR"), "/src/diagnose.rs"));
        let key = concat!("/tmp/tillandsias-ca/inter", "mediate.key");

        for signature in [
            "pub fn github_login_main() -> i32",
            "pub fn list_cloud_projects_main() -> i32",
        ] {
            let window = source_window(source, signature);
            assert!(
                window.contains(&format!("chmod 600 {key}")),
                "{signature}: preflight must clamp the CA private key to 0600"
            );
            // The heal must sit OUTSIDE the `test -s` guard: an existing 0644
            // key never reaches the openssl block.
            let guarded = window
                .split("fi; \\")
                .next()
                .expect("preamble must contain the test -s guard block");
            let after_guard = &window[guarded.len()..];
            assert!(
                after_guard.contains(&format!("chmod 600 {key}")),
                "{signature}: the heal-down must run unconditionally, after the guard"
            );
        }

        for wide in ["644", "640", "664", "666", "755", "777"] {
            assert!(
                !source.contains(&format!("chmod {wide} {key}")),
                "no code path may chmod the CA private key to {wide} (755-qcxh / 772-shi9)"
            );
        }
    }

    // ────────────────────────────────────────────────────────────────
    //  JSON schema-pin tests (mirrors windows-tray e96d1fc8)
    //
    //  The --diagnose --json schema is a public surface that
    //  scripts/tray-diagnose.sh (and any future support tooling
    //  uploading the JSON) parse field-by-field. Renames or removes
    //  here must break the build, not silently break the consumer.
    // ────────────────────────────────────────────────────────────────

    use super::{DIAGNOSE_EXIT_CONVERGING, DiagnoseReport, exit_code_from};

    fn baseline_diagnose_report() -> DiagnoseReport {
        DiagnoseReport {
            version: env!("CARGO_PKG_VERSION"),
            guest_version: None,
            in_app: true,
            exe_path: Some(
                "/Applications/Tillandsias.app/Contents/MacOS/tillandsias-tray".to_string(),
            ),
            image_root: "/Users/test/Library/Application Support/tillandsias".to_string(),
            rootfs_present: true,
            rootfs_bytes: Some(8_589_934_592),
            kernel_present: false,
            kernel_bytes: None,
            initrd_present: false,
            initrd_bytes: None,
            release_tag: "fedora-44",
            manifest_pin_aarch64_qcow2: Some("55c60a3b80d3".to_string()),
            provisioned: true,
            // 701-kgvk: the healthy shape — bundle and staged agree.
            guest_binary_bundle_sha256: Some("26f120b6b1ef".to_string()),
            guest_binary_staged_sha256: Some("26f120b6b1ef".to_string()),
            guest_binary_staged_matches_bundle: Some(true),
            // A provisioned host at rest: nothing is mid-materialization.
            vm_owner_live: false,
            metrics: None,
            metrics_status: METRICS_STATUS_NO_HANDLE.to_string(),
        }
    }

    /// Top-level JSON keys are the support-tooling contract.
    /// `tray-diagnose.sh` reads `.version`, `.in_app`, `.release_tag`,
    /// `.manifest_pin_aarch64_qcow2`, `.provisioned`, and the per-
    /// artifact `_present` flags by name. A silent rename of any of
    /// these would degrade the consumer to "FAIL : null".
    #[test]
    fn diagnose_report_json_keys_locked() {
        let report = baseline_diagnose_report();
        let value: serde_json::Value = serde_json::to_value(&report).unwrap();
        let obj = value
            .as_object()
            .expect("DiagnoseReport must serialise as a JSON object");
        for required_key in [
            "version",
            "in_app",
            "exe_path",
            "image_root",
            "rootfs_present",
            "rootfs_bytes",
            "kernel_present",
            "kernel_bytes",
            "initrd_present",
            "initrd_bytes",
            "release_tag",
            "manifest_pin_aarch64_qcow2",
            "provisioned",
        ] {
            assert!(
                obj.contains_key(required_key),
                "DiagnoseReport JSON missing required key {required_key:?}; check serde rename"
            );
        }
    }

    /// `manifest_pin_aarch64_qcow2: None` must serialise as JSON null,
    /// not the literal string "null" or the absent key. Consumer
    /// path: `tray-diagnose.sh` reads `.manifest_pin_aarch64_qcow2 //
    /// "(none)"` — `//` only triggers on null/missing, so a string
    /// "null" would silently render as PASS with bogus pin.
    #[test]
    fn diagnose_report_none_pin_serialises_as_null() {
        let mut report = baseline_diagnose_report();
        report.manifest_pin_aarch64_qcow2 = None;
        let value: serde_json::Value = serde_json::to_value(&report).unwrap();
        assert_eq!(value["manifest_pin_aarch64_qcow2"], serde_json::Value::Null);
    }

    /// `bytes` fields are `Option<u64>`; missing artifacts MUST
    /// serialise as JSON null. `tray-diagnose.sh` doesn't currently
    /// read the bytes, but a future dashboard expects null for
    /// "absent" so it can render "—" instead of "0".
    #[test]
    fn diagnose_report_none_bytes_serialise_as_null() {
        let mut report = baseline_diagnose_report();
        report.kernel_present = false;
        report.kernel_bytes = None;
        report.initrd_present = false;
        report.initrd_bytes = None;
        let value: serde_json::Value = serde_json::to_value(&report).unwrap();
        assert_eq!(value["kernel_bytes"], serde_json::Value::Null);
        assert_eq!(value["initrd_bytes"], serde_json::Value::Null);
    }

    /// `exit_code_from` is the public contract `tray-diagnose.sh` (and
    /// `--diagnose --json`'s own `main`) rely on. Pin the mapping so accidental
    /// flips break the build.
    ///
    /// Order 735-2g5i renamed this from `exit_code_provisioned_zero_degraded_two`
    /// to match windows-tray's `exit_code_separates_healthy_converging_and_degraded`,
    /// because the two-state name had become a lie: converging is now its own
    /// verdict. `litmus:exit-code-provisioned-zero-degraded-two-symmetric`
    /// accepts either name on either side precisely so this rename is legal.
    #[test]
    fn exit_code_separates_healthy_converging_and_degraded() {
        let mut report = baseline_diagnose_report();
        assert_eq!(exit_code_from(&report), 0, "provisioned is healthy");

        // NOT provisioned with a live tray owning the VM: converging, not
        // broken. This is the case that used to collapse into 2 and made a
        // scripted post-install check call a still-materializing host broken.
        report.provisioned = false;
        report.vm_owner_live = true;
        assert_eq!(
            exit_code_from(&report),
            DIAGNOSE_EXIT_CONVERGING,
            "a live tray owning an unmaterialized VM is converging, not broken"
        );

        // NEGATIVE CONTROL, load-bearing: with no live owner the same missing
        // artifacts stay exit 2. Without this, "always report converging when
        // unprovisioned" would satisfy the assertion above — and that is the
        // worse failure, because it tells automation to keep waiting on a host
        // where nothing is running.
        report.vm_owner_live = false;
        assert_eq!(
            exit_code_from(&report),
            2,
            "unprovisioned with no live owner is indistinguishable from broken"
        );

        // And converging must never mask a healthy host: provisioned wins
        // regardless of who holds the VM (the steady state — the tray is
        // normally running).
        report.provisioned = true;
        report.vm_owner_live = true;
        assert_eq!(
            exit_code_from(&report),
            0,
            "provisioned is healthy even while the tray owns the VM"
        );
    }

    /// Order 331 pin: the pure host→guest project-path translation.
    #[test]
    fn project_path_translation_rules() {
        let t = |p: &str| translate_project_path_for_guest(p, "/Users/op");
        // host ~/src/<name> → guest path (the 2026-07-13 live repro shape)
        assert_eq!(
            t("/Users/op/src/tillandsias").unwrap(),
            "/home/forge/src/tillandsias"
        );
        // nested subpath translates too
        assert_eq!(
            t("/Users/op/src/tillandsias/crates").unwrap(),
            "/home/forge/src/tillandsias/crates"
        );
        // guest-absolute passes through verbatim
        assert_eq!(
            t("/home/forge/src/tillandsias").unwrap(),
            "/home/forge/src/tillandsias"
        );
        // the src root itself is not a project
        assert!(t("/Users/op/src").unwrap_err().contains("INSIDE"));
        // outside ~/src fails fast with both accepted forms named
        let err = t("/tmp/elsewhere").unwrap_err();
        assert!(
            err.contains("/Users/op/src") && err.contains("/home/forge/src"),
            "{err}"
        );
    }

    // ────────────────────────────────────────────────────────────────
    //  Guest crash-loop DETECTION — the macOS `--diagnose` read path.
    //  (macOS-only tests; the cross-platform detector behavior itself is
    //  pinned in tillandsias-control-wire::crashloop on the Linux dev box.)
    //  @trace plan/issues/guest-crashloop-detection-and-ephemeral-reset-2026-07-17.md
    // ────────────────────────────────────────────────────────────────

    /// The `--diagnose` guest-health line always renders a verdict in the
    /// pinned grammar, even with no state file present (fresh install →
    /// `starting`), and never panics.
    #[test]
    fn guest_health_verdict_matches_pinned_grammar() {
        let v = super::guest_health_verdict();
        assert!(
            tillandsias_control_wire::crashloop::verdict_matches_grammar(&v),
            "guest-health verdict {v:?} must match ^(healthy|starting|crash-loop:[a-z0-9-]+)$"
        );
    }

    /// The crash-loop state file lives under the same `image_root` the live
    /// tray reads/writes, so the writer and this static reader agree.
    #[test]
    fn crashloop_state_path_under_image_root() {
        let p = super::crashloop_state_path();
        assert!(
            p.ends_with("Library/Application Support/tillandsias/crashloop.state"),
            "{}",
            p.display()
        );
    }

    /// A tripped state written to a temp file reads back as
    /// `crash-loop:<subsystem>` — the exact load path `--diagnose` uses.
    #[test]
    fn tripped_state_reads_back_as_crash_loop() {
        use tillandsias_control_wire::crashloop::{
            CrashLoopDetector, CrashLoopSubsystem, GuestHealth,
        };
        let dir = std::env::temp_dir().join(format!("tillandsias-diag-{}", std::process::id()));
        let path = dir.join("crashloop.state");
        let mut det = CrashLoopDetector::new(120, 3);
        det.record_failure(CrashLoopSubsystem::Guest, 10);
        det.record_failure(CrashLoopSubsystem::Guest, 11);
        det.record_failure(CrashLoopSubsystem::Guest, 12);
        det.save(&path).unwrap();
        let mut loaded = CrashLoopDetector::load(&path);
        assert_eq!(
            loaded.verdict(12),
            GuestHealth::CrashLoop(CrashLoopSubsystem::Guest)
        );
        let _ = std::fs::remove_dir_all(&dir);
    }
}
