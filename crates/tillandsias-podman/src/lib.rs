//! @trace spec:podman-orchestration, spec:cross-platform, spec:windows-wsl-runtime

mod client;
pub mod cache_semantics;
pub mod container_spec;
pub mod events;
mod gpu;
pub mod launch;
pub mod peer_table;
pub mod runtime;

use std::env;
use std::fs;
use std::path::{Path, PathBuf};
use std::sync::OnceLock;

#[cfg(unix)]
use std::os::unix::fs::PermissionsExt;

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

pub use client::PodmanClient;
pub use client::RunOutput;
pub use client::network_exists_sync;
pub use container_spec::ContainerHandle;
pub use container_spec::ContainerSpec;
pub use container_spec::MountMode;
pub use container_spec::MountSpec;
pub use events::PodmanEventStream;
pub use gpu::detect_gpu_devices;
pub use launch::ContainerLauncher;
pub use launch::query_occupied_ports;
pub use peer_table::{PeerTable, ProjectLabel};

/// The internal podman network name for the Tillandsias enclave.
/// @trace spec:enclave-network
pub const ENCLAVE_NETWORK: &str = "tillandsias-enclave";

fn resolve_podman_bin() -> PathBuf {
    if let Some(bin) = env::var_os("TILLANDSIAS_PODMAN_BIN") {
        return PathBuf::from(bin);
    }

    if let Some(path) = env::var_os("PATH") {
        for dir in env::split_paths(&path) {
            let candidate = dir.join("podman");
            if !candidate.exists() {
                continue;
            }
            #[cfg(unix)]
            {
                if let Ok(metadata) = fs::metadata(&candidate)
                    && metadata.permissions().mode() & 0o111 == 0
                {
                    continue;
                }
            }
            return candidate;
        }
    }

    for candidate in ["/usr/bin/podman", "/bin/podman", "/usr/local/bin/podman"] {
        let candidate = PathBuf::from(candidate);
        if candidate.exists() {
            return candidate;
        }
    }

    PathBuf::from("podman")
}

fn env_path_if_not_litmus(name: &str) -> Option<PathBuf> {
    let value = env::var_os(name)?;
    let path = PathBuf::from(value);
    if path.to_string_lossy().contains("target/litmus-podman")
        || path.to_string_lossy().contains("target/litmus-runtime")
    {
        None
    } else {
        Some(path)
    }
}

fn host_session_bus_path() -> Option<PathBuf> {
    if let Some(address) = env::var_os("DBUS_SESSION_BUS_ADDRESS") {
        let address = address.to_string_lossy();
        if let Some(path) = address.strip_prefix("unix:path=") {
            let path = PathBuf::from(path);
            if path.exists() {
                return Some(path);
            }
        }
    }

    env::var_os("XDG_RUNTIME_DIR").map(|runtime_dir| PathBuf::from(runtime_dir).join("bus"))
}

fn prepare_podman_runtime_dir(runtime_dir: &Path) {
    let _ = fs::create_dir_all(runtime_dir);

    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        let _ = fs::set_permissions(runtime_dir, fs::Permissions::from_mode(0o700));

        if let Some(host_runtime_dir) = env::var_os("XDG_RUNTIME_DIR") {
            let host_runtime_dir = PathBuf::from(host_runtime_dir);
            if host_runtime_dir != runtime_dir {
                if let Some(host_bus) = host_session_bus_path() {
                    let runtime_bus = runtime_dir.join("bus");
                    if !runtime_bus.exists() {
                        let _ = std::os::unix::fs::symlink(&host_bus, &runtime_bus);
                    }
                }

                let host_systemd = host_runtime_dir.join("systemd");
                let runtime_systemd = runtime_dir.join("systemd");
                if host_systemd.exists() && !runtime_systemd.exists() {
                    let _ = std::os::unix::fs::symlink(&host_systemd, &runtime_systemd);
                }
            }
        }
    }
}

/// Find the podman binary path.
///
/// Tillandsias treats Podman as a host precondition: it must be on PATH.
pub fn find_podman_path() -> PathBuf {
    resolve_podman_bin()
}

fn podman_graphroot() -> PathBuf {
    if let Some(graphroot) = env_path_if_not_litmus("TILLANDSIAS_PODMAN_GRAPHROOT") {
        return graphroot;
    }

    if let Some(home) = env::var_os("HOME") {
        let home = PathBuf::from(home);
        let candidate = home.join(".local/share/tillandsias/podman");
        if fs::create_dir_all(&candidate).is_ok() {
            return candidate;
        }
    }

    PathBuf::from("/tmp/tillandsias-podman-root")
}

fn podman_runroot() -> PathBuf {
    env_path_if_not_litmus("TILLANDSIAS_PODMAN_RUNROOT")
        .unwrap_or_else(|| PathBuf::from("/tmp/tillandsias-podman-runroot"))
}

fn podman_runtime_dir() -> PathBuf {
    if let Some(runtime_dir) = env_path_if_not_litmus("TILLANDSIAS_PODMAN_RUNTIME_DIR") {
        return runtime_dir;
    }

    PathBuf::from("/tmp/tillandsias-podman-runtime")
}

fn podman_wrapper_dir() -> PathBuf {
    env_path_if_not_litmus("TILLANDSIAS_PODMAN_WRAPPER_DIR")
        .unwrap_or_else(|| PathBuf::from("/tmp/tillandsias-podman-wrapper"))
}

fn podman_remote_url() -> Option<String> {
    let value = env::var("TILLANDSIAS_PODMAN_REMOTE_URL")
        .ok()
        .or_else(|| env::var("CONTAINER_HOST").ok())?;
    let trimmed = value.trim();
    if trimmed.is_empty() {
        None
    } else {
        Some(trimmed.to_string())
    }
}

fn podman_storage_conf() -> PathBuf {
    static STORAGE_CONF: OnceLock<PathBuf> = OnceLock::new();
    STORAGE_CONF
        .get_or_init(|| {
            let wrapper_dir = podman_wrapper_dir();
            let runtime_dir = podman_runtime_dir();
            let graphroot = podman_graphroot();
            let runroot = podman_runroot();
            let storage_conf = env_path_if_not_litmus("TILLANDSIAS_PODMAN_STORAGE_CONF")
                .unwrap_or_else(|| wrapper_dir.join("storage.conf"));

            let _ = fs::create_dir_all(&wrapper_dir);
            let _ = fs::create_dir_all(&runtime_dir);
            let _ = fs::create_dir_all(&graphroot);
            let _ = fs::create_dir_all(&runroot);
            prepare_podman_runtime_dir(&runtime_dir);

            let contents = format!(
                "[storage]\ndriver = \"vfs\"\ngraphroot = \"{}\"\nrunroot = \"{}\"\n",
                graphroot.display(),
                runroot.display()
            );
            let needs_write = fs::read_to_string(&storage_conf)
                .map(|existing| existing != contents)
                .unwrap_or(true);
            if needs_write {
                let _ = fs::write(&storage_conf, contents);
            }

            storage_conf
        })
        .clone()
}

fn local_transport_should_isolate_storage() -> bool {
    env::var_os("TILLANDSIAS_PODMAN_GRAPHROOT").is_some()
        || env::var_os("TILLANDSIAS_PODMAN_RUNROOT").is_some()
        || env::var_os("TILLANDSIAS_PODMAN_RUNTIME_DIR").is_some()
        || env::var_os("TILLANDSIAS_PODMAN_STORAGE_CONF").is_some()
}

fn configure_podman_environment(cmd: &mut std::process::Command) {
    let remote_url = podman_remote_url();
    configure_podman_environment_with_transport(cmd, remote_url.as_deref());
}

fn configure_podman_environment_with_transport(
    cmd: &mut std::process::Command,
    remote_url: Option<&str>,
) {
    let runtime_dir = podman_runtime_dir();
    cmd.env_remove("TILLANDSIAS_PODMAN_GRAPHROOT");
    cmd.env_remove("TILLANDSIAS_PODMAN_RUNROOT");
    cmd.env_remove("TILLANDSIAS_PODMAN_RUNTIME_DIR");
    cmd.env_remove("TILLANDSIAS_PODMAN_WRAPPER_DIR");
    cmd.env_remove("TILLANDSIAS_PODMAN_STORAGE_CONF");
    cmd.env_remove("TILLANDSIAS_PODMAN_REMOTE_URL");
    cmd.env_remove("CONTAINER_HOST");
    cmd.env_remove("CONTAINER_CONNECTION");

    if let Some(remote_url) = remote_url {
        let remote_runtime_dir = runtime_dir;
        let _ = fs::create_dir_all(&remote_runtime_dir);
        prepare_podman_runtime_dir(&remote_runtime_dir);
        cmd.env("XDG_RUNTIME_DIR", remote_runtime_dir);
        cmd.arg("--remote");
        cmd.arg("--url");
        cmd.arg(remote_url);
        return;
    }

    if local_transport_should_isolate_storage() {
        let storage_conf = podman_storage_conf();
        let graphroot = podman_graphroot();
        let runroot = podman_runroot();
        cmd.env("XDG_RUNTIME_DIR", &runtime_dir);
        let bus_address = runtime_dir.join("bus");
        if bus_address.exists() {
            cmd.env(
                "DBUS_SESSION_BUS_ADDRESS",
                format!("unix:path={}", bus_address.display()),
            );
        }
        cmd.env("CONTAINERS_STORAGE_CONF", storage_conf);
        cmd.arg("--root");
        cmd.arg(graphroot);
        cmd.arg("--runroot");
        cmd.arg(runroot);
        cmd.arg("--tmpdir");
        cmd.arg(podman_runtime_dir());
    }
}

/// Create a `tokio::process::Command` for podman with a clean library environment.
///
/// - Assumes podman is available on PATH
/// - Removes `LD_LIBRARY_PATH` and `LD_PRELOAD` (bundled libs can conflict with
///   host libraries, causing `undefined symbol: seccomp_export_bpf_mem`)
///
/// On Windows, uses CREATE_NO_WINDOW to prevent console window flashing, and
/// explicitly sets piped stdio so handles remain valid after FreeConsole().
pub fn podman_cmd() -> tokio::process::Command {
    let mut cmd = tokio::process::Command::new(find_podman_path());
    cmd.env_remove("LD_LIBRARY_PATH");
    cmd.env_remove("LD_PRELOAD");
    configure_podman_environment(cmd.as_std_mut());

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
    configure_podman_environment(&mut cmd);

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

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::{Mutex, OnceLock};

    fn args_of(cmd: &std::process::Command) -> Vec<String> {
        cmd.get_args()
            .map(|arg| arg.to_string_lossy().into_owned())
            .collect()
    }

    fn env_lock() -> std::sync::MutexGuard<'static, ()> {
        static ENV_LOCK: OnceLock<Mutex<()>> = OnceLock::new();
        ENV_LOCK.get_or_init(|| Mutex::new(())).lock().unwrap()
    }

    #[test]
    fn remote_transport_uses_remote_flag_and_skips_local_storage_args() {
        let _guard = env_lock();
        unsafe {
            std::env::remove_var("TILLANDSIAS_PODMAN_GRAPHROOT");
            std::env::remove_var("TILLANDSIAS_PODMAN_RUNROOT");
            std::env::remove_var("TILLANDSIAS_PODMAN_STORAGE_CONF");
            std::env::set_var(
                "TILLANDSIAS_PODMAN_RUNTIME_DIR",
                "/tmp/tillandsias-podman-runtime-test",
            );
        }
        let mut cmd = std::process::Command::new("podman");
        configure_podman_environment_with_transport(
            &mut cmd,
            Some("unix:///run/user/1000/podman/podman.sock"),
        );

        let args = args_of(&cmd);
        assert_eq!(
            args,
            vec![
                "--remote".to_string(),
                "--url".to_string(),
                "unix:///run/user/1000/podman/podman.sock".to_string(),
            ]
        );
        assert!(cmd.get_envs().any(|(key, value)| {
            key == std::ffi::OsStr::new("XDG_RUNTIME_DIR")
                && value
                    .and_then(|v| v.to_str())
                    .map(|v| v == "/tmp/tillandsias-podman-runtime-test")
                    .unwrap_or(false)
        }));

        unsafe {
            std::env::remove_var("TILLANDSIAS_PODMAN_RUNTIME_DIR");
        }
    }

    #[test]
    fn local_transport_uses_host_defaults_without_isolation_env() {
        let mut cmd = std::process::Command::new("podman");
        let _guard = env_lock();
        unsafe {
            std::env::remove_var("TILLANDSIAS_PODMAN_GRAPHROOT");
            std::env::remove_var("TILLANDSIAS_PODMAN_RUNROOT");
            std::env::remove_var("TILLANDSIAS_PODMAN_RUNTIME_DIR");
            std::env::remove_var("TILLANDSIAS_PODMAN_STORAGE_CONF");
        }
        configure_podman_environment_with_transport(&mut cmd, None);

        let args = args_of(&cmd);
        assert!(!args.iter().any(|arg| arg == "--root"));
        assert!(!args.iter().any(|arg| arg == "--runroot"));
        assert!(!args.iter().any(|arg| arg == "--tmpdir"));
    }

    #[test]
    fn local_transport_isolation_env_enables_storage_overrides() {
        let _guard = env_lock();
        let mut cmd = std::process::Command::new("podman");
        unsafe {
            std::env::set_var("TILLANDSIAS_PODMAN_GRAPHROOT", "/tmp/tillandsias-graphroot");
            std::env::set_var("TILLANDSIAS_PODMAN_RUNROOT", "/tmp/tillandsias-runroot");
            std::env::set_var("TILLANDSIAS_PODMAN_RUNTIME_DIR", "/tmp/tillandsias-runtime");
            std::env::set_var(
                "TILLANDSIAS_PODMAN_STORAGE_CONF",
                "/tmp/tillandsias-storage.conf",
            );
        }

        configure_podman_environment_with_transport(&mut cmd, None);

        let args = args_of(&cmd);
        assert!(args.iter().any(|arg| arg == "--root"));
        assert!(args.iter().any(|arg| arg == "--runroot"));
        assert!(args.iter().any(|arg| arg == "--tmpdir"));

        unsafe {
            std::env::remove_var("TILLANDSIAS_PODMAN_GRAPHROOT");
            std::env::remove_var("TILLANDSIAS_PODMAN_RUNROOT");
            std::env::remove_var("TILLANDSIAS_PODMAN_RUNTIME_DIR");
            std::env::remove_var("TILLANDSIAS_PODMAN_STORAGE_CONF");
        }
    }
}
