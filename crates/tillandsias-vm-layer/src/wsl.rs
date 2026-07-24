//! WSL2 backend for the VM runtime.
//!
//! Shells out to `wsl.exe --exec`, `wsl.exe --import`, `wsl.exe --terminate`.
//! Manages a single distro per host (default name `tillandsias`).
//!
//! Windows-only. On Linux/macOS this module compiles but every method
//! returns `Err("WslRuntime is Windows-only")` so the workspace links.
//!
//! @trace spec:vm-idiomatic-layer, spec:windows-native-tray

#![allow(dead_code)]

use std::path::PathBuf;
use std::process::ExitStatus;
use std::time::Duration;

use crate::{ProvisionManifest, VmError, VmRuntime};

/// Canonical name of the Tillandsias WSL distro. Single source of truth:
/// the tray's `wsl_lifecycle::DISTRO_NAME` and the order-312 stdio-bridge
/// transport both resolve to this const (an env seam,
/// `TILLANDSIAS_WSL_DISTRO`, overrides it at runtime for tests/ops).
/// Lives here (not in `transport_windows`) so non-Windows targets can
/// still link against it.
pub const DEFAULT_WSL_DISTRO: &str = "tillandsias";

/// Hard wall for the broad WSL-service shutdown recovery. `kill_on_drop`
/// terminates the host child if the wall fires, so callers do not merely stop
/// awaiting an unbounded `wsl.exe --shutdown`.
const WSL_SHUTDOWN_RECOVERY_TIMEOUT_SECS: u64 = 60;

/// The order-326 forge-user + `/home/forge/src` ownership contract as one
/// idempotent root shell script (uid 1000 + rootless-podman subordinate
/// ranges per `images/default/cheatsheets/runtime/fedora-minimal-wsl2.md`).
/// Ends with a writability probe FROM the forge uid so a wrong state fails
/// the provision loudly instead of surfacing minutes later as a clone
/// EACCES inside a lane container. Explicit `\n` escapes (not source
/// newlines) so a CRLF checkout can never smuggle `\r` into the guest sh.
const FORGE_USER_SETUP_SCRIPT: &str = "set -eu\n\
    if ! id forge >/dev/null 2>&1; then\n\
    useradd -u 1000 -m -s /bin/bash forge\n\
    fi\n\
    grep -q '^forge:' /etc/subuid 2>/dev/null || usermod --add-subuids 100000-165535 forge\n\
    grep -q '^forge:' /etc/subgid 2>/dev/null || usermod --add-subgids 100000-165535 forge\n\
    mkdir -p /home/forge/src\n\
    chown -R forge:forge /home/forge\n\
    probe=/home/forge/src/.tillandsias-write-probe\n\
    if command -v runuser >/dev/null 2>&1; then\n\
    runuser -u forge -- /bin/sh -c \": > $probe && rm -f $probe\"\n\
    elif command -v su >/dev/null 2>&1; then\n\
    su -s /bin/sh forge -c \": > $probe && rm -f $probe\"\n\
    else\n\
    [ \"$(stat -c %U /home/forge/src)\" = forge ]\n\
    fi || { echo 'order-326 assertion: /home/forge/src is not writable by the forge user' >&2; exit 1; }\n";

/// Classified WSL platform preflight verdict (order 323). First-install
/// Windows hosts commonly sit in states where NO amount of VM-start
/// retrying can succeed (WSL stub only, VirtualMachinePlatform enabled but
/// reboot pending — DISM 3010, firmware virtualization off); today those
/// burn the 5-poke retry storm and surface as a crash-like generic
/// failure. Mirrors the order-312 membership-classified hcsdiag pattern:
/// classify confidently, fail fast with the exact remediation, and leave
/// UNKNOWN failures to the existing retry/recovery path.
/// @trace plan/index.yaml wsl-platform-preflight-classification (order 323)
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub enum WslPlatformVerdict {
    /// Healthy (S4), or an unclassified state the retry path owns.
    #[default]
    Ok,
    /// S1: fresh Windows ships only the `wsl.exe` stub (locale-stable
    /// `aka.ms/wslinstall` marker in `wsl --status` output).
    WslPlatformAbsent,
    /// S2: WSL app present but VirtualMachinePlatform needs the pending
    /// restart (DISM 3010; CBS RebootPending key present).
    RebootPending,
    /// S3: hardware virtualization off in firmware (HypervisorPresent =
    /// false AND VirtualizationFirmwareEnabled = false).
    VirtualizationDisabled,
}

impl WslPlatformVerdict {
    /// Stable machine-readable token for `--diagnose --json` (`wsl_platform`).
    pub fn as_diagnose_str(&self) -> &'static str {
        match self {
            WslPlatformVerdict::Ok => "ok",
            WslPlatformVerdict::WslPlatformAbsent => "absent",
            WslPlatformVerdict::RebootPending => "reboot-pending",
            WslPlatformVerdict::VirtualizationDisabled => "virtualization-disabled",
        }
    }

    /// Operator-facing remediation for classified-fatal states; `None` when
    /// starting the VM is worth attempting. These exact strings are the UX
    /// contract from the 2026-07-13 operator directive — pinned by unit
    /// test and litmus; change them only with the plan packet.
    pub fn remediation(&self) -> Option<&'static str> {
        match self {
            WslPlatformVerdict::Ok => None,
            WslPlatformVerdict::WslPlatformAbsent => Some(
                "WSL is not installed — install it with `wsl --install --no-distribution`, \
                 then relaunch Tillandsias.",
            ),
            WslPlatformVerdict::RebootPending => Some(
                "WSL2 requires a restart to finish installing — please reboot Windows \
                 and relaunch Tillandsias.",
            ),
            WslPlatformVerdict::VirtualizationDisabled => Some(
                "hardware virtualization is disabled — enable VT-x/AMD-V in your \
                 BIOS/UEFI settings, then relaunch Tillandsias.",
            ),
        }
    }
}

/// Raw host probe results feeding [`classify_wsl_platform`]. Kept separate
/// from probe COLLECTION so the S1-S4 signature mapping is a pure,
/// cross-platform unit-testable function (the recipes were captured live on
/// a fresh Win11 host — plan/issues/wsl2-reboot-pending-first-install-ux-2026-07-13.md).
#[derive(Debug, Clone, Default)]
pub struct WslPlatformProbes {
    /// `wsl --status` exited 0.
    pub wsl_status_ok: bool,
    /// NUL-stripped combined stdout+stderr of `wsl --status` (UTF-16LE pipe
    /// output arrives as interleaved NULs; same discipline as
    /// `wsl_list_quiet`).
    pub wsl_status_output: String,
    /// `HKLM\...\Component Based Servicing\RebootPending` key present.
    pub reboot_pending_key: bool,
    /// `Win32_ComputerSystem.HypervisorPresent` (`None` = probe failed).
    pub hypervisor_present: Option<bool>,
    /// `Win32_Processor.VirtualizationFirmwareEnabled` (`None` = probe failed).
    pub virtualization_firmware_enabled: Option<bool>,
}

/// Pure S1-S4 classifier. Deliberately conservative: only confident
/// signatures short-circuit; anything else returns `Ok` so the existing
/// retry/recovery machinery keeps owning unknown failures.
pub fn classify_wsl_platform(p: &WslPlatformProbes) -> WslPlatformVerdict {
    if p.wsl_status_ok {
        // S4. Note: a healthy WSL with an UNRELATED pending Windows reboot
        // lands here on purpose — the CBS key alone must never block a
        // working install.
        return WslPlatformVerdict::Ok;
    }
    // S1: match the locale-stable install URL, not the English prose.
    if p.wsl_status_output.contains("aka.ms/wslinstall") {
        return WslPlatformVerdict::WslPlatformAbsent;
    }
    // S3: both firmware signals must agree (half-known is not confident).
    if p.hypervisor_present == Some(false) && p.virtualization_firmware_enabled == Some(false) {
        return WslPlatformVerdict::VirtualizationDisabled;
    }
    // S2: WSL app present (status ran but unhealthy) + pending servicing
    // reboot.
    if p.reboot_pending_key {
        return WslPlatformVerdict::RebootPending;
    }
    WslPlatformVerdict::Ok
}

/// Parse the two `True`/`False` lines the CIM probe prints (HypervisorPresent
/// then VirtualizationFirmwareEnabled). Pure for unit-testing; tolerant of
/// CRLF, NULs, and missing lines.
pub fn parse_cim_bool_lines(s: &str) -> (Option<bool>, Option<bool>) {
    let mut lines = s
        .replace('\u{0}', "")
        .lines()
        .map(|l| l.trim().to_ascii_lowercase())
        .filter(|l| !l.is_empty())
        .collect::<Vec<_>>()
        .into_iter();
    let mut next_bool = || match lines.next().as_deref() {
        Some("true") => Some(true),
        Some("false") => Some(false),
        _ => None,
    };
    let hypervisor = next_bool();
    let firmware = next_bool();
    (hypervisor, firmware)
}

/// Reverse lookup: diagnose token → remediation, for surfaces that carry
/// only the serialized token (e.g. the tray's human `--diagnose` print).
/// Unknown tokens (incl. "ok") yield `None`.
pub fn classify_remediation_for_token(token: &str) -> Option<&'static str> {
    match token {
        "absent" => WslPlatformVerdict::WslPlatformAbsent.remediation(),
        "reboot-pending" => WslPlatformVerdict::RebootPending.remediation(),
        "virtualization-disabled" => WslPlatformVerdict::VirtualizationDisabled.remediation(),
        _ => None,
    }
}

/// Scan a provisioning/start error string for the order-323 classified
/// remediations and return the short status-chip text for the tray's
/// length-limited menu status line (the toast carries the full string).
/// `None` = not a classified failure; keep the generic chip.
/// Order 419 extends the map to the launch/import-phase verdicts.
pub fn classified_short_status(err: &str) -> Option<&'static str> {
    if err.contains("WSL2 requires a restart") {
        Some("WSL2 requires a restart \u{2014} reboot Windows")
    } else if err.contains("WSL is not installed") {
        Some("WSL is not installed \u{2014} run `wsl --install`")
    } else if err.contains("hardware virtualization is disabled") {
        Some("Virtualization disabled \u{2014} enable in BIOS/UEFI")
    } else if err.contains("WSL kernel/runtime needs an update") {
        Some("WSL needs an update \u{2014} run `wsl --update`")
    } else if err.contains("host drive is low on space") {
        Some("Host disk low \u{2014} free space, then Retry")
    } else if err.contains("wsl --import failed") {
        Some("VM import failed \u{2014} see log, then Retry")
    } else {
        None
    }
}

/// Order 419 (launch-phase taxonomy): map confident `wsl.exe` stderr
/// signatures from the LAUNCH/import phase to actionable remediations.
/// Conservative like [`classify_wsl_platform`]: only unambiguous
/// signatures classify; unknown stderr returns `None` and the generic
/// bounded-retry machinery keeps ownership. Pure for unit pinning.
/// @trace spec:vm-provisioning-lifecycle
pub fn classify_launch_stderr(stderr: &str) -> Option<&'static str> {
    let s = stderr.to_ascii_lowercase();
    // Kernel/runtime out of date: WSL prints an explicit `wsl --update`
    // instruction (locale-stable command token) or the 0x8037010a /
    // WSL_E_KERNEL_NOT_FOUND family.
    if s.contains("wsl --update") || s.contains("kernel file is not found") {
        return Some(
            "The WSL kernel/runtime needs an update. Run `wsl --update` from \
             PowerShell, then Retry.",
        );
    }
    // 0x80370102: the HCS rejected VM creation — virtualization off (or
    // nested-virt unavailable). Locale-stable HRESULT token.
    if s.contains("0x80370102") {
        return Some(
            "The virtual machine could not start because hardware \
             virtualization is disabled. Enable VT-x/AMD-V in BIOS/UEFI, \
             then Retry.",
        );
    }
    // 0x80070070: ERROR_DISK_FULL surfaced by wsl --import / VHDX growth.
    if s.contains("0x80070070") || s.contains("not enough space on the disk") {
        return Some(
            "The host drive is low on space \u{2014} the VM import/start could \
             not complete. Free disk space, then Retry.",
        );
    }
    None
}

/// WSL2-backed VM runtime.
///
/// On Windows the methods invoke `wsl.exe` under the hood (Phase-2 skeleton:
/// real wsl shell-outs land below the `#[cfg(target_os = "windows")]` gate).
/// On other targets the trait impl exists for cross-platform linkability
/// but every method returns a structured "not supported on this OS" error.
pub struct WslRuntime {
    /// Distro name registered with `wsl --import`. Default `tillandsias`.
    pub distro_name: String,
    /// Install path on the Windows host (`%LOCALAPPDATA%\tillandsias\wsl\`).
    pub install_root: PathBuf,
}

impl WslRuntime {
    /// Construct a runtime handle. Does NOT touch the host yet.
    pub fn new(distro_name: impl Into<String>, install_root: PathBuf) -> Self {
        Self {
            distro_name: distro_name.into(),
            install_root,
        }
    }
}

/// Hard floor for available space on the guest root filesystem, in GiB.
/// Below this the forge-base image build (full dev toolchain + podman
/// overlay store + project checkout) WILL run the root filesystem out of
/// space and every agent attach dies with a blank timing-out terminal —
/// the exact macOS order-294 failure (guest disk was the ~5 GB Fedora
/// default). Matches the >=32 GiB floor vz.rs pins for its 250G resize.
/// @trace plan/index.yaml windows-guest-disk-resize-forge-fit (order 297)
const MIN_GUEST_ROOT_AVAIL_GIB: u64 = 32;

/// Parity intent with macOS `GUEST_DISK_SIZE` ("250G"): a 250 GiB disk
/// yields ~240 GiB available after ext4 overhead. WSL2's dynamic VHDX
/// default (1 TB on current WSL, 256 GB historically) clears this on any
/// stock host; a `.wslconfig` `defaultVhdSize` cap or a fixed-size rootfs
/// import can drop below it. Below intent we WARN (forge still fits);
/// below the floor we fail provisioning loud.
const INTENDED_GUEST_ROOT_AVAIL_GIB: u64 = 240;

/// Parse `df -Pk <mount>` output (POSIX format) into available KiB —
/// column 4 of the first data line. Host-side parse so the guest needs
/// nothing beyond coreutils `df`.
fn parse_df_avail_kib(df_output: &str) -> Option<u64> {
    df_output
        .lines()
        .nth(1)?
        .split_whitespace()
        .nth(3)?
        .parse()
        .ok()
}

/// Provisioning-time headroom verdict for the guest root filesystem.
/// `Err(msg)` = fail provisioning loud (below the forge-fit floor);
/// `Ok(Some(msg))` = proceed but warn (below the macOS 250G parity
/// intent); `Ok(None)` = full headroom.
fn evaluate_guest_root_headroom(avail_kib: u64) -> Result<Option<String>, String> {
    let avail_gib = avail_kib / (1024 * 1024);
    if avail_gib < MIN_GUEST_ROOT_AVAIL_GIB {
        return Err(format!(
            "guest root filesystem has only {avail_gib} GiB available — below the \
             {MIN_GUEST_ROOT_AVAIL_GIB} GiB forge-fit floor, so the forge-base image \
             build will run out of space and every agent attach will fail (order 297; \
             macOS sibling order 294). Check `.wslconfig` for a defaultVhdSize cap, or \
             grow the distro disk: `wsl --manage <distro> --resize <size>` then \
             `resize2fs` inside the guest."
        ));
    }
    if avail_gib < INTENDED_GUEST_ROOT_AVAIL_GIB {
        return Ok(Some(format!(
            "guest root filesystem has {avail_gib} GiB available — above the \
             {MIN_GUEST_ROOT_AVAIL_GIB} GiB floor but below the \
             {INTENDED_GUEST_ROOT_AVAIL_GIB} GiB target (macOS 250G parity, order 297). \
             Large forge workloads may exhaust it; consider growing the distro VHDX."
        )));
    }
    Ok(None)
}

// ---------------------------------------------------------------------------
// Windows: real wsl.exe shell-outs.
// @trace spec:vm-idiomatic-layer
// ---------------------------------------------------------------------------

/// Build a background `wsl.exe` command with CREATE_NO_WINDOW applied.
/// Every non-interactive wsl spawn in this module must come from here —
/// from the GUI-subsystem tray a raw console child flashes a visible
/// window per invocation (operator repro 2026-07-12: start-poke +
/// wait_ready + handshake retries flashed consoles every few seconds).
/// The deliberately-interactive debug keepalive is the one exemption.
#[cfg(target_os = "windows")]
fn wsl_cmd() -> tokio::process::Command {
    let mut cmd = tokio::process::Command::new("wsl");
    crate::no_window_async(&mut cmd);
    cmd
}

/// Collect the order-323 platform probes (sync — callable from the tray's
/// synchronous `--diagnose` path; async callers wrap in `spawn_blocking`).
/// Every child is a background spawn from the GUI tray → `no_window_sync`.
#[cfg(target_os = "windows")]
pub fn collect_wsl_platform_probes() -> WslPlatformProbes {
    let mut probes = WslPlatformProbes::default();

    let mut status_cmd = std::process::Command::new("wsl");
    status_cmd.arg("--status");
    crate::no_window_sync(&mut status_cmd);
    if let Ok(out) = status_cmd.output() {
        probes.wsl_status_ok = out.status.success();
        let mut text = String::from_utf8_lossy(&out.stdout).replace('\u{0}', "");
        text.push_str(&String::from_utf8_lossy(&out.stderr).replace('\u{0}', ""));
        probes.wsl_status_output = text;
    }

    // `reg query` exits 0 iff the key exists — no output parsing (locale-safe).
    let mut reg_cmd = std::process::Command::new("reg");
    reg_cmd.args([
        "query",
        r"HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending",
    ]);
    crate::no_window_sync(&mut reg_cmd);
    probes.reboot_pending_key = reg_cmd
        .output()
        .map(|o| o.status.success())
        .unwrap_or(false);

    // One PowerShell round-trip for both CIM booleans (True/False lines are
    // locale-invariant .NET Boolean formatting).
    let mut ps_cmd = std::process::Command::new("powershell");
    ps_cmd.args([
        "-NoProfile",
        "-NonInteractive",
        "-Command",
        "(Get-CimInstance Win32_ComputerSystem).HypervisorPresent; \
         (Get-CimInstance Win32_Processor | Select-Object -First 1).VirtualizationFirmwareEnabled",
    ]);
    crate::no_window_sync(&mut ps_cmd);
    if let Ok(out) = ps_cmd.output() {
        let text = String::from_utf8_lossy(&out.stdout).to_string();
        let (hypervisor, firmware) = parse_cim_bool_lines(&text);
        probes.hypervisor_present = hypervisor;
        probes.virtualization_firmware_enabled = firmware;
    }

    probes
}

/// Probe + classify in one call (order 323).
#[cfg(target_os = "windows")]
pub fn wsl_platform_preflight() -> WslPlatformVerdict {
    classify_wsl_platform(&collect_wsl_platform_probes())
}

#[cfg(target_os = "windows")]
impl WslRuntime {
    async fn wsl_list_quiet() -> Result<String, VmError> {
        let output = wsl_cmd()
            .args(["--list", "--quiet"])
            .output()
            .await
            .map_err(|e| format!("wsl --list failed: {e}"))?;
        if !output.status.success() {
            return Err(format!(
                "wsl --list exited {}: {}",
                output.status,
                String::from_utf8_lossy(&output.stderr)
            ));
        }
        // WSL emits UTF-16LE on some Windows builds; tolerate either by
        // dropping invalid bytes. Distro names are ASCII in practice.
        Ok(String::from_utf8_lossy(&output.stdout)
            .replace('\u{0}', "")
            .to_string())
    }

    fn distro_listed(listing: &str, distro: &str) -> bool {
        listing
            .lines()
            .map(|line| line.trim())
            .any(|name| name.eq_ignore_ascii_case(distro))
    }

    /// True if this distro is already registered with WSL (a prior import
    /// succeeded). Lets callers (e.g. the recipe provision path) skip the
    /// download + `wsl --import` and go straight to start, making first-run
    /// provisioning idempotent. A `wsl --list` failure is treated as
    /// "not registered" (the caller then attempts a fresh import).
    pub async fn is_registered(&self) -> bool {
        match Self::wsl_list_quiet().await {
            Ok(listing) => Self::distro_listed(&listing, &self.distro_name),
            Err(_) => false,
        }
    }

    pub async fn is_wsl_service_sane() -> bool {
        match tokio::time::timeout(Duration::from_secs(5), Self::wsl_list_quiet()).await {
            Ok(Ok(_)) => true,
            Ok(Err(e)) => {
                let err_str = e.to_string();
                if err_str.contains("WSL/Service") || err_str.contains("E_UNEXPECTED") {
                    false
                } else {
                    !err_str.contains("WSL/Service") && !err_str.contains("E_UNEXPECTED")
                }
            }
            Err(_) => false,
        }
    }

    pub async fn perform_wsl_shutdown_recovery() -> Result<(), String> {
        tracing::warn!("WSL service appears wedged. Attempting recovery via wsl --shutdown...");
        let mut cmd = wsl_cmd();
        cmd.kill_on_drop(true);
        let status = match tokio::time::timeout(
            Duration::from_secs(WSL_SHUTDOWN_RECOVERY_TIMEOUT_SECS),
            cmd.arg("--shutdown").status(),
        )
        .await
        {
            Ok(Ok(status)) => status,
            Ok(Err(error)) => {
                return Err(format!("wsl --shutdown failed to spawn or wait: {error}"));
            }
            Err(_) => {
                return Err(format!(
                    "wsl --shutdown timed out after \
                     {WSL_SHUTDOWN_RECOVERY_TIMEOUT_SECS}s"
                ));
            }
        };
        if status.success() {
            tracing::info!("wsl --shutdown completed successfully");
            tokio::time::sleep(Duration::from_secs(2)).await;
            Ok(())
        } else {
            Err(format!("wsl --shutdown exited with status {status}"))
        }
    }
}

#[cfg(target_os = "windows")]
impl WslRuntime {
    /// Run a SINGLE shell command inside the distro as root. Captures
    /// stderr for error messages.
    ///
    /// Order 366: `wsl` without `--exec` re-joins its trailing args and
    /// re-parses them through the guest login shell, so anything beyond a
    /// single simple command arrives shredded (order-326 live repro:
    /// `$probe` empty, `mkdir` never ran). Every script-shaped payload
    /// (wsl.conf heredocs, the systemd unit writer, the forge-user setup)
    /// was migrated to [`Self::wsl_root_sh_stdin`]; the guard below fails
    /// loud before spawning if a multi-line payload ever lands here again.
    async fn wsl_root_sh(&self, script: &str) -> Result<(), VmError> {
        if script.contains('\n') {
            return Err(format!(
                "wsl_root_sh: multi-line script rejected — the guest login shell \
                 re-parses arg-delivered payloads (use wsl_root_sh_stdin; order 366). \
                 First line: {:?}",
                script.lines().next().unwrap_or_default()
            ));
        }
        let output = wsl_cmd()
            .arg("--distribution")
            .arg(&self.distro_name)
            .arg("--user")
            .arg("root")
            .arg("--")
            .arg("/bin/sh")
            .arg("-c")
            .arg(script)
            .output()
            .await
            .map_err(|e| format!("wsl root sh failed: {e}"))?;
        if !output.status.success() {
            return Err(format!(
                "wsl root sh exited {}: {}",
                output.status,
                String::from_utf8_lossy(&output.stderr)
            ));
        }
        Ok(())
    }

    /// Run a multi-line root shell SCRIPT inside the distro, delivered via
    /// STDIN. `wsl` without `--exec` re-joins its trailing args and re-parses
    /// them through the guest login shell, which mangles any script carrying
    /// quotes, `$` expansions, or multi-line control flow (live repro
    /// 2026-07-15: the order-326 setup script arrived line-shredded through
    /// [`Self::wsl_root_sh`] — `$probe` expanded empty, `mkdir` never ran;
    /// the single-command/heredoc uses of `wsl_root_sh` survive that
    /// re-parse, scripts do not). Stdin has no such round-trip: the guest
    /// `/bin/sh` reads the bytes verbatim.
    async fn wsl_root_sh_stdin(&self, script: &str) -> Result<(), VmError> {
        use tokio::io::AsyncWriteExt;
        let mut child = wsl_cmd()
            .arg("--distribution")
            .arg(&self.distro_name)
            .arg("--user")
            .arg("root")
            .arg("--")
            .arg("/bin/sh")
            .stdin(std::process::Stdio::piped())
            .stdout(std::process::Stdio::piped())
            .stderr(std::process::Stdio::piped())
            .spawn()
            .map_err(|e| format!("wsl root sh (stdin) failed to spawn: {e}"))?;
        let mut stdin = child
            .stdin
            .take()
            .ok_or_else(|| "wsl root sh (stdin): stdin missing".to_string())?;
        stdin
            .write_all(script.as_bytes())
            .await
            .map_err(|e| format!("wsl root sh (stdin): write failed: {e}"))?;
        drop(stdin); // EOF so the guest sh runs the script and exits.
        let output = child
            .wait_with_output()
            .await
            .map_err(|e| format!("wsl root sh (stdin) failed: {e}"))?;
        if !output.status.success() {
            return Err(format!(
                "wsl root sh (stdin) exited {}: {}",
                output.status,
                String::from_utf8_lossy(&output.stderr).replace('\u{0}', "")
            ));
        }
        Ok(())
    }

    /// Measure available KiB on the guest root filesystem via `df -Pk /`.
    async fn guest_root_avail_kib(&self) -> Result<u64, VmError> {
        let output = wsl_cmd()
            .arg("--distribution")
            .arg(&self.distro_name)
            .arg("--user")
            .arg("root")
            .arg("--")
            .arg("/bin/sh")
            .arg("-c")
            .arg("df -Pk /")
            .output()
            .await
            .map_err(|e| format!("guest df spawn failed: {e}"))?;
        if !output.status.success() {
            return Err(format!(
                "guest df exited {}: {}",
                output.status,
                String::from_utf8_lossy(&output.stderr)
            ));
        }
        let stdout = String::from_utf8_lossy(&output.stdout).replace('\u{0}', "");
        parse_df_avail_kib(&stdout)
            .ok_or_else(|| format!("guest df output unparseable: {stdout:?}"))
    }

    /// Provisioning-time guest disk headroom assertion (order 297, macOS
    /// sibling of order 294): fail loud BEFORE the first forge-base build
    /// when the imported distro's root filesystem is capped near the
    /// Fedora default (~5 GB), instead of every agent attach dying later
    /// with a blank timing-out terminal. Runs on both provisioning paths
    /// (recipe `configure_recipe_distro` + legacy `provision`).
    async fn assert_guest_disk_headroom(&self) -> Result<(), VmError> {
        let avail_kib = self.guest_root_avail_kib().await?;
        match evaluate_guest_root_headroom(avail_kib)? {
            Some(warning) => tracing::warn!("{warning}"),
            None => tracing::info!(
                "guest root headroom OK: {} GiB available",
                avail_kib / (1024 * 1024)
            ),
        }
        Ok(())
    }

    /// Provisioning-time forge-user + `/home/forge/src` ownership ensure
    /// (order 326). The recipe rootfs ships NEITHER the `forge` user NOR
    /// forge-owned `/home/forge/src`: on a cold Windows provision the dir
    /// arrives root:root 0755 and the first containerized cloud clone dies
    /// with EACCES (`--cap-drop=ALL` leaves no DAC_OVERRIDE, even for a
    /// uid-0 container process). Runs on both provisioning paths and fails
    /// loud at provision time via an in-script writability probe from the
    /// forge uid — mirroring the order-297 headroom assertion pattern —
    /// instead of at first clone, minutes later, with a misleading error.
    /// @trace plan/index.yaml wsl-guest-forge-user-src-ownership (order 326)
    async fn ensure_forge_user_and_src(&self) -> Result<(), VmError> {
        // MUST be the stdin variant: arg-delivered scripts get re-parsed by
        // the guest login shell and this one arrives shredded (2026-07-15
        // cold-provision repro — the probe caught it, as designed).
        self.wsl_root_sh_stdin(FORGE_USER_SETUP_SCRIPT).await?;
        tracing::info!("forge user + /home/forge/src ownership ensured (order 326)");
        Ok(())
    }

    /// Post-import wiring for a RECIPE-materialized distro (w5 path): write
    /// `/etc/wsl.conf` (systemd on, /mnt automount off, default user `forge`)
    /// then `wsl --terminate` so the next start boots under systemd. Unlike
    /// [`VmRuntime::provision`], it does NOT drop a binary or install the
    /// systemd unit — the recipe rootfs already carries the unit and a
    /// first-boot headless self-install (`images/vm/bootstrap/20-tillandsias.sh`).
    ///
    /// @trace spec:vm-provisioning-lifecycle.provision.first-run-downloads@v1
    pub async fn configure_recipe_distro(&self) -> Result<(), VmError> {
        // Fail loud before any wiring if the imported root filesystem lacks
        // forge-fit headroom (order 297).
        self.assert_guest_disk_headroom().await?;
        // Create the forge user and hand it /home/forge before any lane can
        // clone into it (order 326).
        self.ensure_forge_user_and_src().await?;
        // NOTE: no `[user] default = forge` here (unlike `provision`): the recipe
        // rootfs does NOT create a `forge` Linux user (verified via E2E import,
        // 2026-05-26), so defaulting to it would break `wsl -d tillandsias` login.
        // Default user stays root; "Open Shell" enters the forge *podman
        // container* via `podman exec`, not a forge Linux login.
        self.wsl_root_sh_stdin(
            "cat > /etc/wsl.conf << 'EOF'\n\
             [boot]\n\
             systemd = true\n\
             [interop]\n\
             enabled = true\n\
             appendWindowsPath = false\n\
             [automount]\n\
             enabled = false\n\
             EOF",
        )
        .await?;
        // Terminate so the next start picks up systemd + the new wsl.conf.
        let _ = wsl_cmd()
            .arg("--terminate")
            .arg(&self.distro_name)
            .status()
            .await;
        Ok(())
    }

    /// Spawn a long-lived `wsl --exec` session that **keeps the WSL2 utility VM
    /// alive** for the tray's lifetime. WSL2 idles the utility VM down when no
    /// host-side session is active, which silently drops the in-VM headless +
    /// the HvSocket control wire (`connect` then times out, WSAETIMEDOUT). An
    /// active `wsl --exec sleep infinity` holds it open (verified E2E
    /// 2026-05-27: with a held session the control wire stays reachable; without
    /// one the VM idles out within ~60s).
    ///
    /// The caller holds the returned [`tokio::process::Child`] for as long as the
    /// VM should stay warm; it's `kill_on_drop`, so dropping it releases the VM
    /// to idle normally (and `stop`/Quit terminates the VM regardless).
    ///
    /// @trace spec:vm-idiomatic-layer, plan/issues/tray-convergence-coordination.md (w9)
    pub fn spawn_keepalive(&self, debug: bool) -> Result<tokio::process::Child, VmError> {
        // Deliberate wsl_cmd() exemption: the debug keepalive IS an
        // interactive console (titled journalctl follow) — only the
        // non-debug variant must stay windowless.
        let mut cmd = tokio::process::Command::new("wsl");
        cmd.arg("--distribution")
            .arg(&self.distro_name)
            .kill_on_drop(true);

        if debug {
            cmd.arg("--exec")
                .arg("bash")
                .arg("-c")
                .arg("echo -ne '\\033]0;Tillandsias debug console\\007'; exec journalctl -fu tillandsias-headless");
        } else {
            cmd.arg("--exec")
                .arg("sleep")
                .arg("infinity")
                .stdin(std::process::Stdio::null())
                .stdout(std::process::Stdio::null())
                .stderr(std::process::Stdio::null());
            crate::no_window_async(&mut cmd);
        }

        cmd.spawn()
            .map_err(|e| format!("spawn WSL keepalive failed: {e}"))
    }
}

#[cfg(target_os = "windows")]
#[async_trait::async_trait]
impl VmRuntime for WslRuntime {
    /// First-run provisioning per `vm-provisioning-lifecycle.provision.first-run-downloads@v1`:
    ///
    /// 1. Skip if the distro is already registered.
    /// 2. `wsl --import` the rootfs tarball at `install_root`.
    /// 3. Write `/etc/wsl.conf` enabling systemd + disabling /mnt automount.
    /// 4. Drop the staged `tillandsias-headless` binary into `/usr/local/bin/`.
    /// 5. Install the `tillandsias-headless.service` systemd unit.
    /// 6. `wsl --terminate` so the next start picks up systemd.
    ///
    /// Each step is idempotent: re-running `provision` after a successful
    /// previous run is a no-op (the distro check at the top short-circuits).
    async fn provision(&self, manifest: &ProvisionManifest) -> Result<(), VmError> {
        let listing = Self::wsl_list_quiet().await?;
        if Self::distro_listed(&listing, &self.distro_name) {
            return Ok(());
        }
        tokio::fs::create_dir_all(&self.install_root)
            .await
            .map_err(|e| format!("create install_root failed: {e}"))?;
        if !manifest.rootfs_tarball.exists() {
            return Err(format!(
                "rootfs tarball missing at {}",
                manifest.rootfs_tarball.display()
            ));
        }
        if !manifest.tillandsias_binary.exists() {
            return Err(format!(
                "tillandsias binary missing at {}",
                manifest.tillandsias_binary.display()
            ));
        }

        // Step 1: import.
        let status = wsl_cmd()
            .arg("--import")
            .arg(&self.distro_name)
            .arg(&self.install_root)
            .arg(&manifest.rootfs_tarball)
            .arg("--version")
            .arg("2")
            .status()
            .await
            .map_err(|e| format!("wsl --import failed to spawn: {e}"))?;
        if !status.success() {
            return Err(format!("wsl --import exited {status}"));
        }

        // Fail loud before any wiring if the imported root filesystem lacks
        // forge-fit headroom (order 297).
        self.assert_guest_disk_headroom().await?;

        // This path sets `[user] default = forge` below, so the user must
        // exist (and own /home/forge) before the next distro start — the
        // rootfs does not ship it (order 326).
        self.ensure_forge_user_and_src().await?;

        // Step 2: write /etc/wsl.conf with systemd + automount=false.
        self.wsl_root_sh_stdin(
            "cat > /etc/wsl.conf << 'EOF'\n\
             [boot]\n\
             systemd = true\n\
             [user]\n\
             default = forge\n\
             [interop]\n\
             enabled = true\n\
             appendWindowsPath = false\n\
             [automount]\n\
             enabled = false\n\
             EOF",
        )
        .await?;

        // Step 3: copy the tillandsias binary into /usr/local/bin.
        //
        // The wsl --import path translation from a Windows path to an
        // in-VM path lives via the `\\?\` UNC paths, which `wsl --exec`
        // can read through /mnt/c. To keep this idempotent and self-
        // contained, we shell out a `cp` from the auto-mounted host path
        // (we re-enable it briefly via /init/wsl1 fallback — but the
        // simpler approach is to use `wsl --user root install`).
        //
        // We pass the binary as a literal Windows path through `wsl
        // --install`-style argument substitution via stdin. For now we
        // perform the copy by piping bytes through `wsl --exec` since
        // automount is disabled.
        let binary_bytes = tokio::fs::read(&manifest.tillandsias_binary)
            .await
            .map_err(|e| format!("read tillandsias binary failed: {e}"))?;
        let mut child = wsl_cmd()
            .arg("--distribution")
            .arg(&self.distro_name)
            .arg("--user")
            .arg("root")
            .arg("--")
            .arg("/bin/sh")
            .arg("-c")
            .arg(
                "cat > /usr/local/bin/tillandsias-headless && \
                 chmod +x /usr/local/bin/tillandsias-headless",
            )
            .stdin(std::process::Stdio::piped())
            .spawn()
            .map_err(|e| format!("install tillandsias binary spawn failed: {e}"))?;
        if let Some(stdin) = child.stdin.as_mut() {
            use tokio::io::AsyncWriteExt;
            stdin
                .write_all(&binary_bytes)
                .await
                .map_err(|e| format!("write tillandsias binary stdin failed: {e}"))?;
        }
        let install_status = child
            .wait()
            .await
            .map_err(|e| format!("install tillandsias binary wait failed: {e}"))?;
        if !install_status.success() {
            return Err(format!(
                "install tillandsias binary exited {install_status}"
            ));
        }

        // Step 4: install the systemd unit + enable it.
        //
        // HOME + XDG_RUNTIME_DIR must match what the exec'd login/satisfier
        // lanes resolve (host-shell pty preamble defaults XDG_RUNTIME_DIR to
        // /run/user/$(id -u) — /run/user/0 for root). The order-232
        // per-resource flocks live under $XDG_RUNTIME_DIR/tillandsias-locks;
        // if this unit leaves the variable unset, resource_lock::lock_dir()
        // falls back to /tmp/tillandsias-locks-0 while the exec'd satisfier
        // locks under /run/user/0/tillandsias-locks — two disjoint lock
        // namespaces, and the vault name-in-use race (orders 259/274)
        // reproduces on every fresh-distro first login. The recipe-path unit
        // (windows-tray wsl_lifecycle.rs) and the macOS unit (vz.rs) carry
        // the same pins; /run/user/0 needs the ExecStartPre mkdir because
        // nothing else creates it before logind sees a root session.
        let unit = format!(
            "cat > /etc/systemd/system/tillandsias-headless.service << 'EOF'\n\
             [Unit]\n\
             Description=Tillandsias in-VM headless (vsock control wire)\n\
             After=network-online.target\n\
             Wants=network-online.target\n\
             [Service]\n\
             Type=simple\n\
             ExecStartPre=/usr/bin/mkdir -p /run/user/0\n\
             ExecStartPre=/usr/bin/chmod 0700 /run/user/0\n\
             Environment=HOME=/root\n\
             Environment=XDG_RUNTIME_DIR=/run/user/0\n\
             ExecStart=/usr/local/bin/tillandsias-headless --listen-vsock {port}\n\
             Restart=always\n\
             RestartSec=1s\n\
             [Install]\n\
             WantedBy=multi-user.target\n\
             EOF\n\
             systemctl daemon-reload || true\n\
             systemctl enable tillandsias-headless.service",
            port = manifest.vsock_port
        );
        self.wsl_root_sh_stdin(&unit).await?;

        // Step 5: terminate so the next start picks up the new wsl.conf
        // and systemd.
        let _ = wsl_cmd()
            .arg("--terminate")
            .arg(&self.distro_name)
            .status()
            .await;

        Ok(())
    }

    async fn start(&self) -> Result<(), VmError> {
        // 0. Classified platform preflight (order 323): on states where no
        // amount of poking can succeed (WSL stub only, reboot pending,
        // firmware virtualization off) fail FAST with the exact remediation
        // instead of burning the 5-poke retry storm. Unknown states pass
        // through to the existing recovery machinery.
        let verdict = tokio::task::spawn_blocking(wsl_platform_preflight)
            .await
            .unwrap_or_default();
        if let Some(remediation) = verdict.remediation() {
            tracing::warn!(
                "WSL platform preflight classified fatal state '{}' — failing fast",
                verdict.as_diagnose_str()
            );
            return Err(format!("WSL platform preflight: {remediation}"));
        }

        // 1. Preflight check: is WSL service sane?
        if !Self::is_wsl_service_sane().await {
            tracing::warn!("WSL service preflight check failed. Attempting auto-recovery...");
            let _ = Self::perform_wsl_shutdown_recovery().await;
        }

        // 2. Retry start poke with backoff
        let mut backoff = Duration::from_millis(500);
        let mut last_poke_stderr = String::new();
        for attempt in 1..=5 {
            tracing::info!("WSL start poke: attempt {}/5", attempt);

            // Check preflight again if we're retrying after a failure
            if attempt > 1 && !Self::is_wsl_service_sane().await {
                tracing::warn!(
                    "WSL service unhealthy on retry attempt {}. Running wsl --shutdown...",
                    attempt
                );
                let _ = Self::perform_wsl_shutdown_recovery().await;
            }

            let output_res = tokio::time::timeout(
                Duration::from_secs(10),
                wsl_cmd()
                    .arg("--distribution")
                    .arg(&self.distro_name)
                    .arg("--exec")
                    .arg("echo")
                    .arg("ready")
                    .env("WSL_UTF8", "1")
                    .output(),
            )
            .await;

            match output_res {
                Ok(Ok(output)) => {
                    if output.status.success() {
                        tracing::info!("WSL start poke succeeded");
                        return Ok(());
                    } else {
                        // Order 419: keep the stderr — a GUI tray otherwise
                        // discards the only text naming the real launch
                        // failure (kernel out of date, HCS refusal, disk).
                        let stderr = String::from_utf8_lossy(&output.stderr)
                            .replace('\u{0}', "")
                            .trim()
                            .to_string();
                        tracing::warn!(
                            attempt,
                            status = %output.status,
                            stderr = %stderr,
                            "WSL start poke attempt failed"
                        );
                        if let Some(remediation) = classify_launch_stderr(&stderr) {
                            // A confident classified verdict never improves
                            // with retries — surface it immediately.
                            return Err(format!("WSL start failed (classified). {remediation}"));
                        }
                        last_poke_stderr = stderr;
                        // If E_UNEXPECTED (-1) or similar error occurs, try to recover
                        if output.status.code() == Some(-1) {
                            let _ = Self::perform_wsl_shutdown_recovery().await;
                        }
                    }
                }
                Ok(Err(e)) => {
                    tracing::warn!("WSL start poke attempt {} failed to spawn: {}", attempt, e);
                }
                Err(_) => {
                    tracing::warn!("WSL start poke attempt {} timed out", attempt);
                }
            }

            if attempt < 5 {
                tracing::info!("Waiting {:?} before retrying start poke...", backoff);
                tokio::time::sleep(backoff).await;
                backoff *= 2;
            }
        }

        // Poke storm exhausted: re-classify before surfacing the generic
        // error. S2 can present with a healthy-looking `wsl --status` while
        // VM creates fail (HCS service unavailable), so the pre-check above
        // may have passed — a post-failure probe still names the real cause
        // for the operator instead of a crash-like generic failure.
        let probes = tokio::task::spawn_blocking(collect_wsl_platform_probes)
            .await
            .unwrap_or_default();
        let verdict = classify_wsl_platform(&probes);
        if let Some(remediation) = verdict.remediation() {
            return Err(format!(
                "WSL start poke failed after 5 attempts. {remediation}"
            ));
        }
        if probes.reboot_pending_key && probes.hypervisor_present == Some(true) {
            // The S2 corner the recipes call out: WSL app healthy on paper,
            // pending servicing reboot, VM starts failing anyway.
            return Err(format!(
                "WSL start poke failed after 5 attempts. {}",
                WslPlatformVerdict::RebootPending
                    .remediation()
                    .unwrap_or_default()
            ));
        }
        // Unclassified: at least carry the last stderr so the failure is
        // attributable from the log/Event Log instead of a bare count.
        if last_poke_stderr.is_empty() {
            Err("WSL start poke failed after 5 attempts".to_string())
        } else {
            Err(format!(
                "WSL start poke failed after 5 attempts; last wsl.exe stderr: {last_poke_stderr}"
            ))
        }
    }

    async fn stop(&self, _drain_timeout: Duration) -> Result<(), VmError> {
        let status = wsl_cmd()
            .arg("--terminate")
            .arg(&self.distro_name)
            .status()
            .await
            .map_err(|e| format!("wsl --terminate failed to spawn: {e}"))?;
        if !status.success() {
            return Err(format!("wsl --terminate exited {status}"));
        }
        Ok(())
    }

    async fn exec(&self, argv: &[&str]) -> Result<ExitStatus, VmError> {
        if argv.is_empty() {
            return Err("wsl exec: argv is empty".to_string());
        }
        let mut cmd = wsl_cmd();
        cmd.arg("--distribution")
            .arg(&self.distro_name)
            .arg("--exec");
        for arg in argv {
            cmd.arg(arg);
        }
        cmd.status()
            .await
            .map_err(|e| format!("wsl --exec spawn failed: {e}"))
    }

    async fn wait_ready(&self, timeout: Duration) -> Result<(), VmError> {
        let deadline = std::time::Instant::now() + timeout;
        loop {
            let probe = wsl_cmd()
                .arg("--distribution")
                .arg(&self.distro_name)
                .arg("--exec")
                .arg("systemctl")
                .arg("is-active")
                .arg("tillandsias-headless")
                .status()
                .await;
            if let Ok(status) = probe
                && status.success()
            {
                return Ok(());
            }
            if std::time::Instant::now() >= deadline {
                return Err("wsl wait_ready: timed out waiting for tillandsias-headless".into());
            }
            tokio::time::sleep(Duration::from_millis(500)).await;
        }
    }
}

// ---------------------------------------------------------------------------
// Non-Windows: cross-platform link stubs. The trait impl exists so call
// sites compile, but every method returns the same "not on this OS" error.
// ---------------------------------------------------------------------------

#[cfg(not(target_os = "windows"))]
#[async_trait::async_trait]
impl VmRuntime for WslRuntime {
    async fn provision(&self, _manifest: &ProvisionManifest) -> Result<(), VmError> {
        Err("WslRuntime is Windows-only".into())
    }

    async fn start(&self) -> Result<(), VmError> {
        Err("WslRuntime is Windows-only".into())
    }

    async fn stop(&self, _drain_timeout: Duration) -> Result<(), VmError> {
        Err("WslRuntime is Windows-only".into())
    }

    async fn exec(&self, _argv: &[&str]) -> Result<ExitStatus, VmError> {
        Err("WslRuntime is Windows-only".into())
    }

    async fn wait_ready(&self, _timeout: Duration) -> Result<(), VmError> {
        Err("WslRuntime is Windows-only".into())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn wsl_shutdown_recovery_owns_a_hard_process_bound() {
        let source = include_str!("wsl.rs");
        let recovery = source
            .split("pub async fn perform_wsl_shutdown_recovery")
            .nth(1)
            .and_then(|tail| tail.split("\n    }\n}").next())
            .expect("shutdown recovery body");
        assert!(recovery.contains("cmd.kill_on_drop(true)"));
        assert!(recovery.contains("tokio::time::timeout("));
        assert!(recovery.contains("WSL_SHUTDOWN_RECOVERY_TIMEOUT_SECS"));
        assert!(recovery.contains("cmd.arg(\"--shutdown\").status()"));
    }

    /// The legacy tarball-path unit writer (`WslRuntime::provision` step 4)
    /// must pin the same lock-namespace environment as the recipe-path unit
    /// (windows-tray `wsl_lifecycle.rs`) and the macOS unit (`vz.rs`): the
    /// boot-path bootstrap and any exec'd login satisfier must resolve the
    /// SAME `$XDG_RUNTIME_DIR/tillandsias-locks` dir, or the order-232 vault
    /// flock never contends across the two guest processes and the
    /// name-in-use race (exit 125 on fresh-distro first login) returns.
    ///
    /// Source pin, not a runtime probe: the unit is a string literal inside
    /// the cfg(windows) provision impl, so this runs on every platform's CI.
    ///
    /// @trace plan/index.yaml wsl-headless-unit-lock-namespace (order 274)
    #[test]
    fn wsl_provision_unit_pins_lock_namespace_env() {
        let source = include_str!("wsl.rs");
        let unit_window = source
            .split("cat > /etc/systemd/system/tillandsias-headless.service << 'EOF'")
            .nth(1)
            .and_then(|tail| tail.split("systemctl daemon-reload").next())
            .expect("headless unit window");

        assert!(
            unit_window.contains("Environment=HOME=/root"),
            "headless unit must pin HOME for the boot-path bootstrap (orders 259/274)"
        );
        assert!(
            unit_window.contains("Environment=XDG_RUNTIME_DIR=/run/user/0"),
            "headless unit must pin XDG_RUNTIME_DIR to the satisfier's lock namespace (orders 259/274)"
        );
        assert!(
            unit_window.contains("ExecStartPre=/usr/bin/mkdir -p /run/user/0"),
            "nothing else creates /run/user/0 before a root logind session exists"
        );
        assert!(
            unit_window.contains("ExecStartPre=/usr/bin/chmod 0700 /run/user/0"),
            "runtime dir must keep the 0700 mode logind would give it"
        );
    }

    /// 2026-07-12 (order 297, macOS sibling order 294): a guest root
    /// filesystem capped near the ~5 GB Fedora default makes the forge-base
    /// image build ENOSPC and every agent attach die with a blank
    /// timing-out terminal. Both provisioning paths must assert forge-fit
    /// headroom BEFORE first use, and the floor must stay generous.
    ///
    /// Source pin (vz.rs `convert_grows_raw_disk_before_first_boot` shape):
    /// the assertion call sites live inside the cfg(windows) impl, so this
    /// runs on every platform's CI.
    /// @trace plan/index.yaml windows-guest-disk-resize-forge-fit (order 297)
    #[test]
    fn provisioning_asserts_guest_disk_headroom() {
        let source = include_str!("wsl.rs");
        let recipe_window = source
            .split("pub async fn configure_recipe_distro")
            .nth(1)
            .and_then(|tail| tail.split("pub fn spawn_keepalive").next())
            .expect("configure_recipe_distro window");
        assert!(
            recipe_window.contains("self.assert_guest_disk_headroom().await?"),
            "recipe provisioning path must assert guest disk headroom (order 297)"
        );
        let provision_window = source
            .split("async fn provision(&self, manifest: &ProvisionManifest)")
            .nth(1)
            .and_then(|tail| tail.split("async fn start").next())
            .expect("legacy provision window");
        assert!(
            provision_window.contains("self.assert_guest_disk_headroom().await?"),
            "legacy provision path must assert guest disk headroom (order 297)"
        );
        // Floor parity with vz.rs (>= 32 GiB) and the macOS 250G intent,
        // pinned behaviorally: 31 GiB must fail, 199 GiB must not be clean.
        const KIB_PER_GIB: u64 = 1024 * 1024;
        assert!(
            evaluate_guest_root_headroom(31 * KIB_PER_GIB).is_err(),
            "forge-fit floor must stay >= 32 GiB (vz.rs floor parity)"
        );
        assert_ne!(
            evaluate_guest_root_headroom(199 * KIB_PER_GIB),
            Ok(None),
            "headroom intent must track the macOS 250G target (>= 200 GiB)"
        );
    }

    /// Order 326: the forge-user setup script is a contract with the guest
    /// (stable uid, rootless-podman ranges, ownership handoff, loud probe)
    /// — pin its load-bearing lines so drift fails here, not in a lane.
    #[test]
    fn forge_user_setup_script_contract() {
        let s = FORGE_USER_SETUP_SCRIPT;
        assert!(s.starts_with("set -eu\n"), "must fail loud on any step");
        assert!(
            s.contains("useradd -u 1000 -m -s /bin/bash forge"),
            "stable uid 1000 per fedora-minimal-wsl2 cheatsheet"
        );
        assert!(s.contains("--add-subuids 100000-165535"));
        assert!(s.contains("--add-subgids 100000-165535"));
        assert!(s.contains("mkdir -p /home/forge/src"));
        assert!(s.contains("chown -R forge:forge /home/forge"));
        assert!(
            s.contains(".tillandsias-write-probe") && s.contains("order-326 assertion"),
            "must probe writability from the forge uid and name the order on failure"
        );
        assert!(!s.contains('\r'), "CR would break the guest /bin/sh");
    }

    /// Order 326: both provisioning paths must run the forge-user ensure
    /// (same source-window pin pattern as the order-297 headroom assert).
    #[test]
    fn provisioning_ensures_forge_user_and_src() {
        let source = include_str!("wsl.rs");
        let recipe_window = source
            .split("pub async fn configure_recipe_distro")
            .nth(1)
            .and_then(|tail| tail.split("pub fn spawn_keepalive").next())
            .expect("configure_recipe_distro window");
        assert!(
            recipe_window.contains("self.ensure_forge_user_and_src().await?"),
            "recipe provisioning path must ensure the forge user (order 326)"
        );
        let provision_window = source
            .split("async fn provision(&self, manifest: &ProvisionManifest)")
            .nth(1)
            .and_then(|tail| tail.split("async fn start").next())
            .expect("legacy provision window");
        assert!(
            provision_window.contains("self.ensure_forge_user_and_src().await?"),
            "legacy provision path must ensure the forge user (order 326)"
        );
        // Delivery pin: the setup script MUST go via stdin. Arg-delivered
        // scripts are re-joined and re-parsed by the guest login shell and
        // arrive shredded (2026-07-15 cold-provision repro).
        let ensure_window = source
            .split("async fn ensure_forge_user_and_src")
            .nth(1)
            .and_then(|tail| tail.split("pub async fn configure_recipe_distro").next())
            .expect("ensure_forge_user_and_src window");
        assert!(
            ensure_window.contains("wsl_root_sh_stdin(FORGE_USER_SETUP_SCRIPT)"),
            "forge-user setup must be stdin-delivered, not arg-delivered (order 326)"
        );
    }

    /// Order 323: the S1-S4 signature mapping, pinned against the recipes
    /// captured live on the fresh yolanda host (2026-07-13). A regression
    /// here re-introduces the crash-like retry storm on first-install
    /// machines.
    #[test]
    fn wsl_platform_classifier_maps_captured_signatures() {
        // S4 healthy: exit 0 wins regardless of other signals (an
        // unrelated pending Windows reboot must never block a working WSL).
        let s4 = WslPlatformProbes {
            wsl_status_ok: true,
            reboot_pending_key: true,
            ..Default::default()
        };
        assert_eq!(classify_wsl_platform(&s4), WslPlatformVerdict::Ok);

        // S1 stub-only: locale-stable aka.ms/wslinstall marker (captured:
        // "You can install by running 'wsl.exe --install'", exit 50/1).
        let s1 = WslPlatformProbes {
            wsl_status_ok: false,
            wsl_status_output: "W\u{0}S\u{0}L\u{0} … https://aka.ms/wslinstall".to_string(),
            ..Default::default()
        };
        // NOTE: collect strips NULs before classify; classifier sees clean
        // text in production — this asserts the marker match itself.
        let s1_clean = WslPlatformProbes {
            wsl_status_output: s1.wsl_status_output.replace('\u{0}', ""),
            ..s1
        };
        assert_eq!(
            classify_wsl_platform(&s1_clean),
            WslPlatformVerdict::WslPlatformAbsent
        );

        // S2 reboot-pending: unhealthy status, no install marker, CBS key.
        let s2 = WslPlatformProbes {
            wsl_status_ok: false,
            reboot_pending_key: true,
            ..Default::default()
        };
        assert_eq!(
            classify_wsl_platform(&s2),
            WslPlatformVerdict::RebootPending
        );

        // S3 virtualization off: BOTH firmware signals must agree…
        let s3 = WslPlatformProbes {
            wsl_status_ok: false,
            hypervisor_present: Some(false),
            virtualization_firmware_enabled: Some(false),
            ..Default::default()
        };
        assert_eq!(
            classify_wsl_platform(&s3),
            WslPlatformVerdict::VirtualizationDisabled
        );
        // …half-known is NOT confident (probe failure must not misclassify).
        let s3_half = WslPlatformProbes {
            wsl_status_ok: false,
            hypervisor_present: Some(false),
            virtualization_firmware_enabled: None,
            ..Default::default()
        };
        assert_eq!(classify_wsl_platform(&s3_half), WslPlatformVerdict::Ok);

        // S3 outranks S2 when both present (a firmware-off box may also
        // have a pending reboot; the reboot won't fix VT-x).
        let s3_and_key = WslPlatformProbes {
            wsl_status_ok: false,
            reboot_pending_key: true,
            hypervisor_present: Some(false),
            virtualization_firmware_enabled: Some(false),
            ..Default::default()
        };
        assert_eq!(
            classify_wsl_platform(&s3_and_key),
            WslPlatformVerdict::VirtualizationDisabled
        );

        // Unclassified failure: retry path keeps ownership.
        let unknown = WslPlatformProbes {
            wsl_status_ok: false,
            wsl_status_output: "some transient service error".to_string(),
            ..Default::default()
        };
        assert_eq!(classify_wsl_platform(&unknown), WslPlatformVerdict::Ok);
    }

    /// Order 323: remediation strings are the operator-directed UX contract
    /// ("WSL2 requires a restart…") + diagnose tokens are schema-stable.
    #[test]
    fn wsl_platform_verdict_remediation_and_tokens() {
        assert_eq!(WslPlatformVerdict::Ok.remediation(), None);
        let reboot = WslPlatformVerdict::RebootPending.remediation().unwrap();
        assert!(
            reboot.contains("WSL2 requires a restart") && reboot.contains("reboot Windows"),
            "operator-directed S2 message drifted: {reboot}"
        );
        let absent = WslPlatformVerdict::WslPlatformAbsent.remediation().unwrap();
        assert!(
            absent.contains("wsl --install --no-distribution"),
            "S1 must give the exact install command: {absent}"
        );
        let virt = WslPlatformVerdict::VirtualizationDisabled
            .remediation()
            .unwrap();
        assert!(
            virt.contains("BIOS/UEFI"),
            "S3 must point at firmware settings: {virt}"
        );
        assert_eq!(WslPlatformVerdict::Ok.as_diagnose_str(), "ok");
        assert_eq!(
            WslPlatformVerdict::WslPlatformAbsent.as_diagnose_str(),
            "absent"
        );
        assert_eq!(
            WslPlatformVerdict::RebootPending.as_diagnose_str(),
            "reboot-pending"
        );
        assert_eq!(
            WslPlatformVerdict::VirtualizationDisabled.as_diagnose_str(),
            "virtualization-disabled"
        );
    }

    /// Order 323: the tray status chip's short-text lookup recognizes every
    /// classified remediation string and nothing else.
    #[test]
    fn classified_short_status_matches_remediations() {
        for verdict in [
            WslPlatformVerdict::WslPlatformAbsent,
            WslPlatformVerdict::RebootPending,
            WslPlatformVerdict::VirtualizationDisabled,
        ] {
            let err = format!("WSL platform preflight: {}", verdict.remediation().unwrap());
            assert!(
                classified_short_status(&err).is_some(),
                "short status must recognize the {verdict:?} remediation"
            );
        }
        assert_eq!(classified_short_status("some generic poke failure"), None);
    }

    /// Order 419: launch-phase stderr signatures classify to actionable
    /// remediations; unknown stderr stays unclassified (generic machinery
    /// keeps ownership); and every launch remediation round-trips through
    /// the tray chip lookup.
    #[test]
    fn classify_launch_stderr_names_kernel_disk_and_virtualization() {
        let kernel = classify_launch_stderr(
            "The WSL 2 kernel file is not found. Please run 'wsl --update'.",
        )
        .expect("kernel signature must classify");
        assert!(kernel.contains("wsl --update"));

        let virt = classify_launch_stderr(
            "The virtual machine could not be started ... Error code: Wsl/Service/CreateInstance/0x80370102",
        )
        .expect("0x80370102 must classify");
        assert!(virt.contains("virtualization"));

        let disk = classify_launch_stderr("There is not enough space on the disk.")
            .expect("disk-full signature must classify");
        assert!(disk.contains("Free disk space"));

        assert_eq!(classify_launch_stderr("catastrophic mystery"), None);
        assert_eq!(classify_launch_stderr(""), None);

        // Chip parity: each classified launch failure has a short chip.
        for stderr in [
            "run 'wsl --update' please",
            "0x80370102",
            "not enough space on the disk",
        ] {
            let remediation = classify_launch_stderr(stderr).unwrap();
            let err = format!("WSL start failed (classified). {remediation}");
            assert!(
                classified_short_status(&err).is_some(),
                "chip lookup must recognize the launch remediation for {stderr:?}"
            );
        }
    }

    /// Order 366: the arg-delivered root-shell path REJECTS multi-line
    /// payloads before spawning anything (the guest login shell re-parses
    /// arg-delivered scripts — order-326 live repro), and every
    /// script-shaped provisioning writer goes via stdin delivery.
    #[cfg(target_os = "windows")]
    #[tokio::test]
    async fn wsl_root_sh_rejects_multiline_payloads() {
        let rt = WslRuntime::new("no-such-distro", std::path::PathBuf::new());
        let err = rt
            .wsl_root_sh("line one\nline two")
            .await
            .expect_err("multi-line payload must be rejected");
        let msg = err.to_string();
        assert!(
            msg.contains("wsl_root_sh_stdin") && msg.contains("order 366"),
            "rejection must name the stdin alternative: {msg}"
        );
    }

    /// Order 366: the three script-shaped provisioning writers (both
    /// wsl.conf heredocs + the systemd unit) are pinned to stdin delivery;
    /// no arg-delivered root-shell call sites remain in the source.
    #[test]
    fn provisioning_writers_use_stdin_delivery() {
        let source = include_str!("wsl.rs");
        // Needles assembled at runtime so this test's own literals don't
        // count themselves in the source scan.
        let arg_needle = format!("self.wsl_root_sh{}", "(");
        let stdin_needle = format!("self.wsl_root_sh_stdin{}", "(");
        assert_eq!(
            source.matches(&arg_needle).count(),
            0,
            "arg-delivered wsl_root_sh call sites must stay at zero — \
             script payloads arrive shredded (order 366); use the _stdin variant"
        );
        assert!(
            source.matches(&stdin_needle).count() >= 4,
            "expected the forge-user ensure + two wsl.conf writers + unit \
             installer on stdin delivery"
        );
    }

    /// CIM probe output parse: True/False lines, CRLF + NUL tolerant,
    /// missing lines degrade to None (never a guess).
    #[test]
    fn parse_cim_bool_lines_shapes() {
        assert_eq!(
            parse_cim_bool_lines("True\r\nFalse\r\n"),
            (Some(true), Some(false))
        );
        assert_eq!(
            parse_cim_bool_lines("T\u{0}r\u{0}u\u{0}e\u{0}\r\nTrue\r\n"),
            (Some(true), Some(true))
        );
        assert_eq!(parse_cim_bool_lines("False\n"), (Some(false), None));
        assert_eq!(parse_cim_bool_lines(""), (None, None));
        assert_eq!(parse_cim_bool_lines("garbage\nTrue\n"), (None, Some(true)));
    }

    /// `df -Pk /` host-side parse: real WSL2 shape (the 2026-07-12 measured
    /// guest), header-only, and garbage all behave.
    #[test]
    fn parse_df_avail_kib_handles_real_and_degenerate_output() {
        let real = "Filesystem     1024-blocks    Used Available Capacity Mounted on\n\
                    /dev/sdd        1055762868 1191700 1000878304       1% /\n";
        assert_eq!(parse_df_avail_kib(real), Some(1_000_878_304));
        assert_eq!(parse_df_avail_kib("Filesystem 1024-blocks\n"), None);
        assert_eq!(parse_df_avail_kib(""), None);
        assert_eq!(
            parse_df_avail_kib("Filesystem\n/dev/sdd not-a-number x y\n"),
            None
        );
    }

    /// Headroom verdict boundaries: below floor fails loud with an
    /// actionable message; between floor and intent warns; at/above intent
    /// is clean.
    #[test]
    fn guest_root_headroom_verdict_boundaries() {
        const KIB_PER_GIB: u64 = 1024 * 1024;
        // ~5 GiB — the exact macOS order-294 regression class.
        let err = evaluate_guest_root_headroom(5 * KIB_PER_GIB)
            .expect_err("below-floor must fail provisioning");
        assert!(err.contains("forge-fit floor"), "names the floor: {err}");
        assert!(err.contains(".wslconfig"), "actionable remediation: {err}");
        // Just under the floor still fails; at the floor passes with warning.
        assert!(evaluate_guest_root_headroom(MIN_GUEST_ROOT_AVAIL_GIB * KIB_PER_GIB - 1).is_err());
        let warn = evaluate_guest_root_headroom(MIN_GUEST_ROOT_AVAIL_GIB * KIB_PER_GIB)
            .expect("at-floor proceeds");
        assert!(warn.is_some(), "below intent must warn");
        // At intent and above (the measured 955 GiB host) are clean.
        assert_eq!(
            evaluate_guest_root_headroom(INTENDED_GUEST_ROOT_AVAIL_GIB * KIB_PER_GIB),
            Ok(None)
        );
        assert_eq!(evaluate_guest_root_headroom(955 * KIB_PER_GIB), Ok(None));
    }
}
