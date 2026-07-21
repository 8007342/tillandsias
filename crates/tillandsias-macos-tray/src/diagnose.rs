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
            let secure = client_handshake(stream, &psk)
                .await
                .map_err(|e| format!("secure control wire handshake failed: {e}"))?;
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
}

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
    }
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
    if r.provisioned {
        println!("Status: PROVISIONED — first-launch materialization complete.");
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

fn exit_code_from(r: &DiagnoseReport) -> i32 {
    if r.provisioned { 0 } else { 2 }
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
    // /dev/tty), so e.g. `printf 'tok\n' | --exec-guest <login-cmd>` works. Skip
    // when stdin is a TTY (no piped input) to avoid blocking on read_to_end.
    let stdin_bytes: Vec<u8> = {
        use std::io::{IsTerminal, Read};
        if std::io::stdin().is_terminal() {
            Vec::new()
        } else {
            let mut buf = Vec::new();
            let _ = std::io::stdin().read_to_end(&mut buf);
            buf
        }
    };

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

/// Prompt the user on the host terminal and read a single line. When `hidden`,
/// terminal echo is disabled via `stty -echo` for the duration (no extra crate
/// dep) so secrets like the PAT are not shown. Returns the trimmed line.
fn prompt_line(label: &str, hidden: bool) -> String {
    use std::io::Write;
    print!("{label}: ");
    let _ = std::io::stdout().flush();
    if hidden {
        let _ = std::process::Command::new("stty").arg("-echo").status();
    }
    let mut line = String::new();
    let _ = std::io::stdin().read_line(&mut line);
    if hidden {
        let _ = std::process::Command::new("stty").arg("echo").status();
        println!(); // newline the suppressed Enter would have produced
    }
    line.trim().to_string()
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
        let expects = vec![
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
        ];
        eprintln!("[github-login] driving guest login (git name -> email -> token)…");
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
                //   2. Ensure the ephemeral CA key is group/world-readable (0o644)
                //      so Squid (uid 1000) can read it. headless currently sets 0o600;
                //      if the file already exists with correct perms the openssl block
                //      is skipped (ca_bundle_needs_refresh returns false for fresh files).
                // TODO(linux-next): remove once headless sets 0o640 and rm-on-reuse
                // is fixed in ensure_proxy_running.
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
                   chmod 644 /tmp/tillandsias-ca/intermediate.key || true; \
                 fi; \
                 exec /usr/local/bin/tillandsias-headless --github-login",
            ],
            expects,
            |ev| eprintln!("[github-login] {ev}"),
        )
        .await;
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

        // Same CA cert + exited-proxy workaround as github_login_main.
        // ensure_proxy_running (called by headless --list-cloud-projects) needs
        // a 0o644 key so squid (uid 1000) can read it, and no leftover exited
        // container blocking `podman run --name tillandsias-proxy`.
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
                     chmod 644 /tmp/tillandsias-ca/intermediate.key || true; \
                   fi; \
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

    // ────────────────────────────────────────────────────────────────
    //  JSON schema-pin tests (mirrors windows-tray e96d1fc8)
    //
    //  The --diagnose --json schema is a public surface that
    //  scripts/tray-diagnose.sh (and any future support tooling
    //  uploading the JSON) parse field-by-field. Renames or removes
    //  here must break the build, not silently break the consumer.
    // ────────────────────────────────────────────────────────────────

    use super::{DiagnoseReport, exit_code_from};

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

    /// `exit_code_from` is the public contract `tray-diagnose.sh`
    /// (and `--diagnose --json`'s own `main`) rely on for the
    /// 0/2/1 exit contract. Pin the mapping so accidental flips
    /// (e.g. returning the wrong code for provisioned=true) break
    /// the build.
    #[test]
    fn exit_code_provisioned_zero_degraded_two() {
        let mut report = baseline_diagnose_report();
        assert_eq!(exit_code_from(&report), 0);
        report.provisioned = false;
        assert_eq!(exit_code_from(&report), 2);
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
}
