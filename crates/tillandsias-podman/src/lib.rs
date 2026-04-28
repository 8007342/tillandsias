//! @trace spec:podman-orchestration, spec:cross-platform, spec:windows-wsl-runtime

mod client;
pub mod events;
mod gpu;
pub mod launch;
pub mod peer_table;
pub mod runtime;

/// Windows CREATE_NO_WINDOW process creation flag.
/// @trace spec:cross-platform, spec:windows-wsl-runtime, spec:no-terminal-flicker
/// @cheatsheet runtime/windows-process-creation.md
///
/// When std::process::Command spawns a child on Windows, the child inherits
/// the parent's console — but if there's no console (GUI tray context) OR
/// the child is a console program (wsl.exe, podman.exe), Windows allocates
/// a NEW console window for the child by default. That window flashes for a
/// few hundred ms before the child exits, producing the "flickering windows"
/// the user sees during enclave bring-up.
///
/// CREATE_NO_WINDOW (0x08000000) tells CreateProcess NOT to allocate a
/// console for the child. Documented at:
/// https://learn.microsoft.com/en-us/windows/win32/procthread/process-creation-flags
#[cfg(target_os = "windows")]
pub const CREATE_NO_WINDOW: u32 = 0x0800_0000;

/// Apply CREATE_NO_WINDOW to a tokio Command on Windows. No-op on other platforms.
/// All Tillandsias background `wsl.exe` / `podman.exe` invocations should pass
/// through this so the user never sees a console flash.
/// @trace spec:cross-platform, spec:windows-wsl-runtime, spec:no-terminal-flicker
pub fn no_window_async(cmd: &mut tokio::process::Command) -> &mut tokio::process::Command {
    #[cfg(target_os = "windows")]
    {
        use std::os::windows::process::CommandExt;
        cmd.as_std_mut().creation_flags(CREATE_NO_WINDOW);
    }
    cmd
}

/// Apply CREATE_NO_WINDOW to a synchronous std Command on Windows. No-op elsewhere.
/// @trace spec:cross-platform, spec:windows-wsl-runtime, spec:no-terminal-flicker
pub fn no_window_sync(cmd: &mut std::process::Command) -> &mut std::process::Command {
    #[cfg(target_os = "windows")]
    {
        use std::os::windows::process::CommandExt;
        cmd.creation_flags(CREATE_NO_WINDOW);
    }
    cmd
}

pub use client::network_exists_sync;
pub use client::PodmanClient;
pub use client::RunOutput;
pub use events::PodmanEventStream;
pub use gpu::detect_gpu_devices;
pub use launch::ContainerLauncher;
pub use launch::query_occupied_ports;
pub use peer_table::{PeerTable, ProjectLabel};

/// The internal podman network name for the Tillandsias enclave.
/// @trace spec:enclave-network
pub const ENCLAVE_NETWORK: &str = "tillandsias-enclave";

/// Find the podman binary path.
///
/// AppImages and some sandboxed environments may not have `/usr/bin` in PATH.
/// On Windows, Start Menu launches have a minimal PATH that excludes Podman.
/// We check common locations before falling back to bare `podman` (PATH lookup).
pub fn find_podman_path() -> &'static str {
    #[cfg(target_os = "windows")]
    {
        // Windows: check common install locations before PATH fallback.
        // Podman Desktop and winget both install to Program Files.
        static WIN_PATHS: &[&str] = &[
            r"C:\Program Files\RedHat\Podman\podman.exe",
            r"C:\Program Files\Podman\podman.exe",
            r"C:\ProgramData\chocolatey\bin\podman.exe",
        ];

        for path in WIN_PATHS {
            if std::path::Path::new(path).exists() {
                return path;
            }
        }
        // Fallback to PATH lookup
        "podman"
    }

    #[cfg(not(target_os = "windows"))]
    {
        // Check standard locations first — avoids PATH issues in AppImage/Flatpak
        static PATHS: &[&str] = &[
            "/usr/bin/podman",
            "/usr/local/bin/podman",
            "/bin/podman",
            "/opt/homebrew/bin/podman", // Homebrew on Apple Silicon
            "/opt/local/bin/podman",    // MacPorts
        ];

        for path in PATHS {
            if std::path::Path::new(path).exists() {
                return path;
            }
        }
        // Fallback to PATH lookup
        "podman"
    }
}

/// Create a `tokio::process::Command` for podman with a clean library environment.
///
/// - Resolves podman by absolute path (AppImages may not have /usr/bin in PATH)
/// - Removes `LD_LIBRARY_PATH` and `LD_PRELOAD` (AppImage bundled libs conflict
///   with host libraries, causing `undefined symbol: seccomp_export_bpf_mem`)
///
/// On Windows, uses CREATE_NO_WINDOW to prevent console window flashing, and
/// explicitly sets piped stdio so handles remain valid after FreeConsole().
pub fn podman_cmd() -> tokio::process::Command {
    let mut cmd = tokio::process::Command::new(find_podman_path());
    cmd.env_remove("LD_LIBRARY_PATH");
    cmd.env_remove("LD_PRELOAD");

    // Close inherited file descriptors >= 3 before exec'ing podman.
    // AppImage's squashfuse FUSE mount creates FDs that crun cannot
    // stat through /proc/self/fd/, causing OCI permission denied errors.
    // @trace spec:podman-orchestration/fuse-fd-sanitization, knowledge:infra/fuse-userspace-fs
    #[cfg(target_os = "linux")]
    unsafe {
        cmd.pre_exec(|| {
            for fd in 3..1024 {
                libc::close(fd);
            }
            Ok(())
        });
    }

    // Prevent flashing console windows when podman is called from the tray app.
    // After FreeConsole() the inherited stdio handles become invalid, which can
    // cause ERROR_NOT_SUPPORTED (50) when Rust's stdlib sets STARTF_USESTDHANDLES
    // with those stale handles. Piping all three streams ensures CreateProcess
    // receives valid handles regardless of console state.
    // @trace spec:podman-orchestration
    #[cfg(target_os = "windows")]
    {
        cmd.creation_flags(0x08000000); // CREATE_NO_WINDOW
        cmd.stdin(std::process::Stdio::null());
        cmd.stdout(std::process::Stdio::piped());
        cmd.stderr(std::process::Stdio::piped());
    }

    cmd
}

/// Same as [`podman_cmd`] but returns a `std::process::Command` for synchronous use.
pub fn podman_cmd_sync() -> std::process::Command {
    let mut cmd = std::process::Command::new(find_podman_path());
    cmd.env_remove("LD_LIBRARY_PATH");
    cmd.env_remove("LD_PRELOAD");

    // Prevent flashing console windows. See podman_cmd() for rationale.
    #[cfg(target_os = "windows")]
    {
        use std::os::windows::process::CommandExt;
        cmd.creation_flags(0x08000000); // CREATE_NO_WINDOW
        cmd.stdin(std::process::Stdio::null());
        cmd.stdout(std::process::Stdio::piped());
        cmd.stderr(std::process::Stdio::piped());
    }

    // Close inherited file descriptors >= 3 before exec'ing podman.
    // AppImage's squashfuse FUSE mount creates FDs that crun cannot
    // stat through /proc/self/fd/, causing OCI permission denied errors.
    // @trace spec:podman-orchestration/fuse-fd-sanitization, knowledge:infra/fuse-userspace-fs
    #[cfg(target_os = "linux")]
    {
        use std::os::unix::process::CommandExt;
        unsafe {
            cmd.pre_exec(|| {
                for fd in 3..1024 {
                    libc::close(fd);
                }
                Ok(())
            });
        }
    }

    cmd
}
