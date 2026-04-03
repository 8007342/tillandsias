//! @trace spec:podman-orchestration

mod client;
pub mod events;
mod gpu;
pub mod launch;

pub use client::PodmanClient;
pub use events::PodmanEventStream;
pub use gpu::detect_gpu_devices;
pub use launch::ContainerLauncher;
pub use launch::query_occupied_ports;

/// Find the podman binary path.
///
/// AppImages and some sandboxed environments may not have `/usr/bin` in PATH.
/// We check common locations before falling back to bare `podman` (PATH lookup).
pub fn find_podman_path() -> &'static str {
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

/// Create a `tokio::process::Command` for podman with a clean library environment.
///
/// - Resolves podman by absolute path (AppImages may not have /usr/bin in PATH)
/// - Removes `LD_LIBRARY_PATH` and `LD_PRELOAD` (AppImage bundled libs conflict
///   with host libraries, causing `undefined symbol: seccomp_export_bpf_mem`)
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
    #[cfg(target_os = "windows")]
    cmd.creation_flags(0x08000000); // CREATE_NO_WINDOW

    cmd
}

/// Same as [`podman_cmd`] but returns a `std::process::Command` for synchronous use.
pub fn podman_cmd_sync() -> std::process::Command {
    let mut cmd = std::process::Command::new(find_podman_path());
    cmd.env_remove("LD_LIBRARY_PATH");
    cmd.env_remove("LD_PRELOAD");

    // Prevent flashing console windows when podman is called from the tray app.
    #[cfg(target_os = "windows")]
    {
        use std::os::windows::process::CommandExt;
        cmd.creation_flags(0x08000000); // CREATE_NO_WINDOW
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
