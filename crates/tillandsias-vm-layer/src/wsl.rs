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
        let status = wsl_cmd()
            .arg("--shutdown")
            .status()
            .await
            .map_err(|e| format!("wsl --shutdown failed to spawn: {e}"))?;
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
    /// Run a shell command inside the distro as root. Used for the
    /// post-import wiring (wsl.conf, systemd unit install). Captures
    /// stderr for error messages.
    async fn wsl_root_sh(&self, script: &str) -> Result<(), VmError> {
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
        self.wsl_root_sh(
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
        self.wsl_root_sh(
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
        self.wsl_root_sh(&unit).await?;

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
        // 1. Preflight check: is WSL service sane?
        if !Self::is_wsl_service_sane().await {
            tracing::warn!("WSL service preflight check failed. Attempting auto-recovery...");
            let _ = Self::perform_wsl_shutdown_recovery().await;
        }

        // 2. Retry start poke with backoff
        let mut backoff = Duration::from_millis(500);
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

            let status_res = tokio::time::timeout(
                Duration::from_secs(10),
                wsl_cmd()
                    .arg("--distribution")
                    .arg(&self.distro_name)
                    .arg("--exec")
                    .arg("echo")
                    .arg("ready")
                    .status(),
            )
            .await;

            match status_res {
                Ok(Ok(status)) => {
                    if status.success() {
                        tracing::info!("WSL start poke succeeded");
                        return Ok(());
                    } else {
                        tracing::warn!(
                            "WSL start poke attempt {} failed with status: {}",
                            attempt,
                            status
                        );
                        // If E_UNEXPECTED (-1) or similar error occurs, try to recover
                        if status.code() == Some(-1) {
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

        Err("WSL start poke failed after 5 attempts".to_string())
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
