mod client;
pub mod events;
mod gpu;
pub mod launch;

pub use client::PodmanClient;
pub use events::PodmanEventStream;
pub use gpu::detect_gpu_devices;
pub use launch::ContainerLauncher;
pub use launch::query_occupied_ports;

/// Create a `tokio::process::Command` for podman with a clean library environment.
///
/// AppImages bundle their own libraries and set `LD_LIBRARY_PATH` which leaks
/// into child processes. Podman (a host binary) then loads the AppImage's
/// older `libseccomp` instead of the host's, causing symbol errors like
/// `undefined symbol: seccomp_export_bpf_mem`.
///
/// This helper removes `LD_LIBRARY_PATH` so podman uses the host's libraries.
pub fn podman_cmd() -> tokio::process::Command {
    let mut cmd = tokio::process::Command::new("podman");
    cmd.env_remove("LD_LIBRARY_PATH");
    cmd.env_remove("LD_PRELOAD");
    cmd
}

/// Same as [`podman_cmd`] but returns a `std::process::Command` for synchronous use.
pub fn podman_cmd_sync() -> std::process::Command {
    let mut cmd = std::process::Command::new("podman");
    cmd.env_remove("LD_LIBRARY_PATH");
    cmd.env_remove("LD_PRELOAD");
    cmd
}
