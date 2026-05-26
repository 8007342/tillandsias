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

// ---------------------------------------------------------------------------
// Windows: real wsl.exe shell-outs.
// @trace spec:vm-idiomatic-layer
// ---------------------------------------------------------------------------

#[cfg(target_os = "windows")]
impl WslRuntime {
    async fn wsl_list_quiet() -> Result<String, VmError> {
        let output = tokio::process::Command::new("wsl")
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
}

#[cfg(target_os = "windows")]
impl WslRuntime {
    /// Run a shell command inside the distro as root. Used for the
    /// post-import wiring (wsl.conf, systemd unit install). Captures
    /// stderr for error messages.
    async fn wsl_root_sh(&self, script: &str) -> Result<(), VmError> {
        let output = tokio::process::Command::new("wsl")
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

    /// Post-import wiring for a RECIPE-materialized distro (w5 path): write
    /// `/etc/wsl.conf` (systemd on, /mnt automount off, default user `forge`)
    /// then `wsl --terminate` so the next start boots under systemd. Unlike
    /// [`VmRuntime::provision`], it does NOT drop a binary or install the
    /// systemd unit — the recipe rootfs already carries the unit and a
    /// first-boot headless self-install (`images/vm/bootstrap/20-tillandsias.sh`).
    ///
    /// @trace spec:vm-provisioning-lifecycle.provision.first-run-downloads@v1
    pub async fn configure_recipe_distro(&self) -> Result<(), VmError> {
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
        let _ = tokio::process::Command::new("wsl")
            .arg("--terminate")
            .arg(&self.distro_name)
            .status()
            .await;
        Ok(())
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
        let status = tokio::process::Command::new("wsl")
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
        let mut child = tokio::process::Command::new("wsl")
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
        let unit = format!(
            "cat > /etc/systemd/system/tillandsias-headless.service << 'EOF'\n\
             [Unit]\n\
             Description=Tillandsias in-VM headless (vsock control wire)\n\
             After=network-online.target\n\
             Wants=network-online.target\n\
             [Service]\n\
             Type=simple\n\
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
        let _ = tokio::process::Command::new("wsl")
            .arg("--terminate")
            .arg(&self.distro_name)
            .status()
            .await;

        Ok(())
    }

    async fn start(&self) -> Result<(), VmError> {
        // WSL distros auto-start on the first command; just poke `echo ready`.
        let status = tokio::process::Command::new("wsl")
            .arg("--distribution")
            .arg(&self.distro_name)
            .arg("--exec")
            .arg("echo")
            .arg("ready")
            .status()
            .await
            .map_err(|e| format!("wsl --exec echo failed: {e}"))?;
        if !status.success() {
            return Err(format!("wsl start poke exited {status}"));
        }
        Ok(())
    }

    async fn stop(&self, _drain_timeout: Duration) -> Result<(), VmError> {
        let status = tokio::process::Command::new("wsl")
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
        let mut cmd = tokio::process::Command::new("wsl");
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
            let probe = tokio::process::Command::new("wsl")
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
