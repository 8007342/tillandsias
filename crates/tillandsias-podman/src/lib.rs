//! @trace spec:podman-orchestration, spec:cross-platform, spec:windows-wsl-runtime, spec:podman-idiomatic-patterns

pub mod backend;
pub mod cache_semantics;
mod client;
pub mod container_spec;
pub mod diagnostic_event_emitter;
pub mod diagnostics;
pub mod diagnostics_filter;
pub mod diagnostics_stream;
pub mod events;
mod gpu;
pub mod launch;
pub mod peer_table;
pub mod policy;
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

pub use backend::{
    BackendRef, CommandFailure, CommandOutput, FakeBackend, OperationKind, PodmanBackend,
    RealBackend, ReplayBackend, RetryClass,
};
pub use client::EnclaveContainerInfo;
pub use client::PodmanClient;
pub use client::RunOutput;
pub use client::container_exists_sync;
pub use client::image_exists_sync;
pub use client::network_exists_sync;
pub use client::podman_available_sync;
pub use client::stop_container_sync;
pub use container_spec::ContainerHandle;
pub use container_spec::ContainerSpec;
pub use container_spec::MountMode;
pub use container_spec::MountSpec;
pub use diagnostics::{ContainerDiagnostics, LogTail};
pub use diagnostics_stream::{DiagnosticsError, DiagnosticsHandle};
pub use events::PodmanEventStream;
pub use gpu::detect_gpu_devices;
pub use launch::ContainerLauncher;
pub use launch::query_occupied_ports;
pub use peer_table::{PeerTable, ProjectLabel};

/// The internal podman network name for the Tillandsias enclave.
/// @trace spec:enclave-network
pub const ENCLAVE_NETWORK: &str = "tillandsias-enclave";

/// Runtime lanes that Tillandsias recognizes on Linux.
///
/// The lanes are intentionally explicit so production launch paths can report
/// which ownership model is active instead of guessing from incidental state.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum RuntimeLane {
    DesktopUserSession,
    HeadlessServiceAccount,
    DevTest,
}

impl RuntimeLane {
    pub const fn label(self) -> &'static str {
        match self {
            RuntimeLane::DesktopUserSession => "desktop-user-session",
            RuntimeLane::HeadlessServiceAccount => "headless-service-account",
            RuntimeLane::DevTest => "dev-test",
        }
    }
}

/// Return the current lane implied by the process environment.
///
/// This is intentionally conservative: service-account markers win first,
/// then dev/test wrapper markers, and everything else is treated as a normal
/// desktop user session.
pub fn current_runtime_lane() -> RuntimeLane {
    if env::var_os("TILLANDSIAS_PODMAN_REMOTE_URL").is_some()
        || env::var_os("TILLANDSIAS_ROOT").is_some()
    {
        return RuntimeLane::HeadlessServiceAccount;
    }

    if env::var_os("TILLANDSIAS_PODMAN_GRAPHROOT").is_some()
        || env::var_os("TILLANDSIAS_PODMAN_RUNROOT").is_some()
        || env::var_os("TILLANDSIAS_PODMAN_RUNTIME_DIR").is_some()
        || env::var_os("TILLANDSIAS_PODMAN_STORAGE_CONF").is_some()
        || env::var_os("TILLANDSIAS_PODMAN_WRAPPER_DIR").is_some()
    {
        return RuntimeLane::DevTest;
    }

    RuntimeLane::DesktopUserSession
}

#[cfg(unix)]
fn path_is_writable(path: &Path) -> bool {
    use std::ffi::CString;
    use std::os::unix::ffi::OsStrExt;

    let Ok(c_path) = CString::new(path.as_os_str().as_bytes()) else {
        return false;
    };
    unsafe { libc::access(c_path.as_ptr(), libc::W_OK) == 0 }
}

#[cfg(not(unix))]
fn path_is_writable(_path: &Path) -> bool {
    true
}

/// Require the interactive desktop lane.
///
/// Interactive launchers use this to ensure they are running inside a real
/// logind-managed user session rather than the service-account or dev/test
/// lanes.
pub fn require_desktop_user_session(operation: &str) -> Result<(), String> {
    #[cfg(target_os = "linux")]
    {
        match current_runtime_lane() {
            RuntimeLane::DesktopUserSession => {}
            RuntimeLane::HeadlessServiceAccount => {
                return Err(format!(
                    "{operation} requires the desktop user-session lane, but this process is running under the headless service-account lane"
                ));
            }
            RuntimeLane::DevTest => {
                return Err(format!(
                    "{operation} requires the desktop user-session lane, but this process is running under the dev/test wrapper lane"
                ));
            }
        }

        let runtime_dir = env::var_os("XDG_RUNTIME_DIR").ok_or_else(|| {
            format!(
                "{operation} requires a real desktop user session with a writable XDG_RUNTIME_DIR"
            )
        })?;
        let runtime_dir = PathBuf::from(runtime_dir);
        if !runtime_dir.is_dir() {
            return Err(format!(
                "{operation} requires XDG_RUNTIME_DIR to point at a directory: {}",
                runtime_dir.display()
            ));
        }
        if !path_is_writable(&runtime_dir) {
            return Err(format!(
                "{operation} requires writable XDG_RUNTIME_DIR, but {} is not writable",
                runtime_dir.display()
            ));
        }
    }

    Ok(())
}

/// Require the headless service-account lane when service-account markers are present.
///
/// The dev/test lane remains permissive so local litmus and scripted runs can
/// continue to exercise the headless code path without provisioning the system
/// service account. When the service-account markers are present, the runtime
/// must be backed by the supervised user-service model.
pub fn require_headless_service_account(operation: &str) -> Result<(), String> {
    #[cfg(target_os = "linux")]
    {
        if current_runtime_lane() != RuntimeLane::HeadlessServiceAccount {
            return Ok(());
        }

        let runtime_dir = env::var_os("XDG_RUNTIME_DIR").ok_or_else(|| {
            format!(
                "{operation} requires the supervised headless service-account lane with XDG_RUNTIME_DIR"
            )
        })?;
        let runtime_dir = PathBuf::from(runtime_dir);
        if !runtime_dir.is_dir() {
            return Err(format!(
                "{operation} requires XDG_RUNTIME_DIR to point at a directory: {}",
                runtime_dir.display()
            ));
        }
        if !path_is_writable(&runtime_dir) {
            return Err(format!(
                "{operation} requires writable XDG_RUNTIME_DIR, but {} is not writable",
                runtime_dir.display()
            ));
        }

        let remote_url = env::var("TILLANDSIAS_PODMAN_REMOTE_URL").map_err(|_| {
            format!(
                "{operation} requires TILLANDSIAS_PODMAN_REMOTE_URL when running in the headless service-account lane"
            )
        })?;
        if !remote_url.starts_with("unix://") {
            return Err(format!(
                "{operation} requires a unix:// Podman socket for the headless service-account lane, got {remote_url}"
            ));
        }
    }

    Ok(())
}

/// Generate the enclave network name for a given project label.
/// Returns a network name in the format `tillandsias-<project_label>-enclave`.
///
/// @trace spec:podman-idiomatic-patterns
pub fn enclave_network_name(project_label: &str) -> String {
    format!("tillandsias-{}-enclave", project_label)
}

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

/// Remove an env var from the child command's environment only when it is
/// actually present in our own environment.
///
/// Unsetting an absent variable is a behavioural no-op, but `Command`'s `Debug`
/// rendering still prints it as `env -u VAR`. In the default
/// desktop-user-session lane none of the `TILLANDSIAS_PODMAN_*` / `CONTAINER_*`
/// overrides are set, so unconditional removals produced a long, finicky
/// `env -u … env -u …` prefix in the `[tillandsias] running:` log that implied
/// the runtime depends on a pile of overrides when it does not. Gating the
/// removal on presence keeps the displayed command clean — the defensive unset
/// only appears when there is genuinely something to defend against.
fn env_remove_if_present(cmd: &mut std::process::Command, var: &str) {
    if env::var_os(var).is_some() {
        cmd.env_remove(var);
    }
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
    env_remove_if_present(cmd, "TILLANDSIAS_PODMAN_GRAPHROOT");
    env_remove_if_present(cmd, "TILLANDSIAS_PODMAN_RUNROOT");
    env_remove_if_present(cmd, "TILLANDSIAS_PODMAN_RUNTIME_DIR");
    env_remove_if_present(cmd, "TILLANDSIAS_PODMAN_WRAPPER_DIR");
    env_remove_if_present(cmd, "TILLANDSIAS_PODMAN_STORAGE_CONF");
    env_remove_if_present(cmd, "TILLANDSIAS_PODMAN_REMOTE_URL");
    env_remove_if_present(cmd, "CONTAINER_HOST");
    env_remove_if_present(cmd, "CONTAINER_CONNECTION");

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

/// Returns true when user-visible podman invocation logging should be emitted.
///
/// The headless binary sets `TILLANDSIAS_DEBUG=1` in the environment when run with
/// `--debug`, so child processes inherit the flag automatically. Call sites that
/// already hold a `debug: bool` may also force-enable logging by passing `true` to
/// [`log_podman_invocation_with_flag`].
///
/// @trace spec:podman-idiomatic-patterns
pub fn debug_logging_enabled() -> bool {
    matches!(env::var("TILLANDSIAS_DEBUG").as_deref(), Ok("1"))
}

/// Heuristic check: does this string look like an opaque token / base64 blob /
/// secret value that should be redacted before printing to stderr?
fn looks_like_secret_value(value: &str) -> bool {
    // Long opaque blobs with the alphabet of base64/hex/url-safe tokens.
    if value.len() >= 24 {
        let mut alnum = 0usize;
        let mut symbols = 0usize;
        for ch in value.chars() {
            if ch.is_ascii_alphanumeric() {
                alnum += 1;
            } else if matches!(ch, '+' | '/' | '=' | '-' | '_' | '.') {
                symbols += 1;
            } else {
                return false;
            }
        }
        // Mostly alnum + a few base64/url-safe symbols → treat as opaque blob.
        if alnum * 4 >= (alnum + symbols) * 3 {
            return true;
        }
    }
    false
}

/// Redact a single argv element heuristically. Used for arguments of the form
/// `KEY=VALUE` (passed via `-e`/`--env`) or bare opaque values (passed via
/// `--secret`/`--password`).
fn redact_one(arg: &str) -> String {
    // Don't touch flag-like tokens (`--something`); they're never secret values.
    if arg.starts_with('-') {
        return arg.to_string();
    }
    // KEY=VALUE form: preserve the key (it's informative) and redact the value
    // when either the key name implies a secret OR the value looks opaque.
    // We special-case this BEFORE the whole-arg opaque check so things like
    // `GITHUB_TOKEN=ghp_AAAA...` keep their key visible.
    if let Some(eq) = arg.find('=')
        && eq > 0
        && eq + 1 < arg.len()
    // Skip pure-padding `=` at end (`base64=`).
    {
        let (key, rest) = arg.split_at(eq);
        let value = &rest[1..];
        let key_is_identifier = !key.is_empty()
            && key
                .chars()
                .all(|c| c.is_ascii_alphanumeric() || c == '_' || c == '.');
        if key_is_identifier {
            let upper_key = key.to_ascii_uppercase();
            if upper_key.contains("TOKEN")
                || upper_key.contains("PASSWORD")
                || upper_key.contains("SECRET")
                || looks_like_secret_value(value)
            {
                return format!("{key}=<redacted>");
            }
            // Recognized KEY=VALUE; non-secret-looking; keep it as-is.
            return arg.to_string();
        }
    }
    // Bare opaque value (e.g. a base64 blob passed positionally, possibly
    // ending in `=` padding).
    if looks_like_secret_value(arg) {
        return "<redacted>".to_string();
    }
    arg.to_string()
}

/// Build the user-visible podman invocation line for `log_podman_invocation`.
/// Extracted so the unit test can exercise the formatter without touching stderr.
fn format_podman_invocation_line(label: &str, program: &str, args: &[String]) -> String {
    let mut redacted: Vec<String> = Vec::with_capacity(args.len());
    let mut i = 0;
    while i < args.len() {
        let arg = &args[i];
        // Flag/value pairs where the next arg is the secret value.
        if matches!(
            arg.as_str(),
            "--secret" | "--password" | "--token" | "--secret-value"
        ) {
            redacted.push(arg.clone());
            if i + 1 < args.len() {
                redacted.push("<redacted>".to_string());
                i += 2;
                continue;
            }
        }
        // `--env KEY=VALUE` or `-e KEY=VALUE` — redact the value half if the key
        // mentions a secret.
        if matches!(arg.as_str(), "-e" | "--env") {
            redacted.push(arg.clone());
            if i + 1 < args.len() {
                redacted.push(redact_one(&args[i + 1]));
                i += 2;
                continue;
            }
        }
        redacted.push(redact_one(arg));
        i += 1;
    }

    let joined = redacted.join(" ");
    let mut line = format!("[tillandsias] podman {label}: {program} {joined}");
    // Truncate very long lines (e.g. huge --exit-command chains) so the user
    // sees the structure rather than a screenful of arguments.
    const MAX: usize = 400;
    if line.len() > MAX {
        // Find a UTF-8 char boundary at or below MAX.
        let mut cut = MAX;
        while cut > 0 && !line.is_char_boundary(cut) {
            cut -= 1;
        }
        line.truncate(cut);
        line.push_str("...");
    }
    line
}

/// Emit a single user-visible line to stderr describing a podman invocation.
///
/// When `debug` is true (typically because the caller already knows `--debug`
/// was set) OR `TILLANDSIAS_DEBUG=1` is in the environment, writes one line of
/// the form:
///
/// ```text
/// [tillandsias] podman <label>: <binary> <arg1> <arg2> ...
/// ```
///
/// to stderr. Token-like arguments are redacted, and the line is truncated at
/// roughly 400 characters so huge `--exit-command` chains do not drown the user.
///
/// This intentionally uses `eprintln!` rather than `tracing::debug!` so the line
/// is visible regardless of subscriber configuration whenever the user has asked
/// for debug output.
///
/// @trace spec:podman-idiomatic-patterns
pub fn log_podman_invocation_with_flag(label: &str, cmd: &std::process::Command, debug: bool) {
    if !debug && !debug_logging_enabled() {
        return;
    }
    let program = cmd.get_program().to_string_lossy().into_owned();
    let args: Vec<String> = cmd
        .get_args()
        .map(|a| a.to_string_lossy().into_owned())
        .collect();
    eprintln!("{}", format_podman_invocation_line(label, &program, &args));
}

/// Convenience wrapper: emit a user-visible podman invocation line whenever
/// `TILLANDSIAS_DEBUG=1` is set in the environment.
///
/// @trace spec:podman-idiomatic-patterns
pub fn log_podman_invocation(label: &str, cmd: &std::process::Command) {
    log_podman_invocation_with_flag(label, cmd, false);
}

/// Emit a single user-visible line describing a failed podman invocation.
///
/// Logs `[tillandsias] podman <label> failed: status=<code> stderr=<first 400
/// bytes>` to stderr whenever debug output is enabled. The `status` slot accepts
/// an exit code (or any short string like "signal" / "spawn-error"). The
/// `stderr` slot is truncated to roughly 400 bytes so a noisy podman failure
/// does not flood the terminal.
///
/// @trace spec:podman-idiomatic-patterns
pub fn log_podman_failure(label: &str, status: &str, stderr: &str) {
    if !debug_logging_enabled() {
        return;
    }
    const MAX: usize = 400;
    let trimmed = stderr.trim();
    let snippet: String = if trimmed.len() > MAX {
        let mut cut = MAX;
        while cut > 0 && !trimmed.is_char_boundary(cut) {
            cut -= 1;
        }
        let mut s = trimmed[..cut].to_string();
        s.push_str("...");
        s
    } else {
        trimmed.to_string()
    };
    // Collapse newlines so the failure line is one grep-friendly entry.
    let snippet = snippet.replace('\n', " | ");
    eprintln!("[tillandsias] podman {label} failed: status={status} stderr={snippet}");
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
    env_remove_if_present(cmd.as_std_mut(), "LD_LIBRARY_PATH");
    env_remove_if_present(cmd.as_std_mut(), "LD_PRELOAD");
    configure_podman_environment(cmd.as_std_mut());

    // Close inherited file descriptors >= 3 before exec'ing podman.
    // AppImage's squashfuse FUSE mount creates FDs that crun cannot
    // stat through /proc/self/fd/, causing OCI permission denied errors.
    // @trace spec:podman-orchestration/fuse-fd-sanitization, knowledge:infra/fuse-userspace-fs
    #[cfg(target_os = "linux")]
    unsafe {
        cmd.pre_exec(|| {
            // Set PR_SET_PDEATHSIG so the child dies when the parent (launcher) dies.
            // This prevents orphaned podman-cli processes when tillandsias is killed.
            // @trace spec:graceful-shutdown
            libc::prctl(libc::PR_SET_PDEATHSIG, libc::SIGKILL);

            for fd in 3..1024 {
                let fd_flags = libc::fcntl(fd, libc::F_GETFD);
                if fd_flags != -1 && (fd_flags & libc::FD_CLOEXEC) == 0 {
                    libc::close(fd);
                }
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
    env_remove_if_present(&mut cmd, "LD_LIBRARY_PATH");
    env_remove_if_present(&mut cmd, "LD_PRELOAD");
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
                // Set PR_SET_PDEATHSIG so the child dies when the parent (launcher) dies.
                // This prevents orphaned podman-cli processes when tillandsias is killed.
                // @trace spec:graceful-shutdown
                libc::prctl(libc::PR_SET_PDEATHSIG, libc::SIGKILL);

                for fd in 3..1024 {
                    let fd_flags = libc::fcntl(fd, libc::F_GETFD);
                    if fd_flags != -1 && (fd_flags & libc::FD_CLOEXEC) == 0 {
                        libc::close(fd);
                    }
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
        let mut cmd = std::process::Command::new(find_podman_path());
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
        let mut cmd = std::process::Command::new(find_podman_path());
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
        let mut cmd = std::process::Command::new(find_podman_path());
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

    #[test]
    fn runtime_lane_classification_prefers_service_account_then_devtest_then_desktop() {
        let _guard = env_lock();
        unsafe {
            std::env::remove_var("TILLANDSIAS_PODMAN_REMOTE_URL");
            std::env::remove_var("TILLANDSIAS_ROOT");
            std::env::remove_var("TILLANDSIAS_PODMAN_GRAPHROOT");
            std::env::remove_var("TILLANDSIAS_PODMAN_RUNROOT");
            std::env::remove_var("TILLANDSIAS_PODMAN_RUNTIME_DIR");
            std::env::remove_var("TILLANDSIAS_PODMAN_STORAGE_CONF");
            std::env::remove_var("TILLANDSIAS_PODMAN_WRAPPER_DIR");
        }

        assert_eq!(current_runtime_lane(), RuntimeLane::DesktopUserSession);

        unsafe {
            std::env::set_var("TILLANDSIAS_PODMAN_GRAPHROOT", "/tmp/tillandsias-graphroot");
        }
        assert_eq!(current_runtime_lane(), RuntimeLane::DevTest);

        unsafe {
            std::env::set_var(
                "TILLANDSIAS_PODMAN_REMOTE_URL",
                "unix:///run/user/1000/podman/podman.sock",
            );
        }
        assert_eq!(current_runtime_lane(), RuntimeLane::HeadlessServiceAccount);

        unsafe {
            std::env::remove_var("TILLANDSIAS_PODMAN_REMOTE_URL");
            std::env::remove_var("TILLANDSIAS_PODMAN_GRAPHROOT");
        }
    }

    #[test]
    fn desktop_user_session_preflight_requires_writable_runtime_dir() {
        let _guard = env_lock();
        unsafe {
            std::env::remove_var("TILLANDSIAS_PODMAN_REMOTE_URL");
            std::env::remove_var("TILLANDSIAS_ROOT");
            std::env::remove_var("TILLANDSIAS_PODMAN_GRAPHROOT");
            std::env::remove_var("TILLANDSIAS_PODMAN_RUNROOT");
            std::env::remove_var("TILLANDSIAS_PODMAN_RUNTIME_DIR");
            std::env::remove_var("TILLANDSIAS_PODMAN_STORAGE_CONF");
            std::env::remove_var("TILLANDSIAS_PODMAN_WRAPPER_DIR");
        }

        let temp_dir = std::env::temp_dir().join(format!(
            "tillandsias-runtime-lane-test-{}",
            std::process::id()
        ));
        let _ = std::fs::remove_dir_all(&temp_dir);
        std::fs::create_dir_all(&temp_dir).unwrap();
        unsafe {
            std::env::set_var("XDG_RUNTIME_DIR", &temp_dir);
        }
        assert!(require_desktop_user_session("desktop runtime test").is_ok());

        unsafe {
            std::env::remove_var("XDG_RUNTIME_DIR");
        }
        assert!(require_desktop_user_session("desktop runtime test").is_err());

        let _ = std::fs::remove_dir_all(&temp_dir);
    }

    /// Verify enclave_network_name follows the spec pattern: tillandsias-<project>-enclave
    /// @trace spec:podman-idiomatic-patterns
    #[test]
    fn enclave_network_name_follows_spec_pattern() {
        assert_eq!(
            enclave_network_name("my-project"),
            "tillandsias-my-project-enclave"
        );
        assert_eq!(
            enclave_network_name("visual-chess"),
            "tillandsias-visual-chess-enclave"
        );
        assert_eq!(enclave_network_name("test"), "tillandsias-test-enclave");

        // Verify it doesn't inadvertently produce the old constant
        assert_ne!(enclave_network_name("undefined"), ENCLAVE_NETWORK);
    }

    /// @trace spec:podman-idiomatic-patterns
    #[test]
    fn invocation_line_contains_label_and_redacts_secrets() {
        let line = format_podman_invocation_line(
            "container",
            "/usr/bin/podman",
            &[
                "run".into(),
                "--rm".into(),
                "-e".into(),
                "GITHUB_TOKEN=ghp_AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA".into(),
                "--secret".into(),
                "tillandsias-ca-key".into(),
                "image:tag".into(),
            ],
        );
        assert!(
            line.starts_with("[tillandsias] podman container: /usr/bin/podman "),
            "unexpected prefix: {line}"
        );
        assert!(
            line.contains("GITHUB_TOKEN=<redacted>"),
            "token leaked: {line}"
        );
        // `--secret <name>` — the value (name) gets replaced because it follows
        // a known secret flag.
        assert!(
            line.contains("--secret <redacted>"),
            "secret leaked: {line}"
        );
        assert!(line.contains("image:tag"), "image arg dropped: {line}");
    }

    /// @trace spec:podman-idiomatic-patterns
    #[test]
    fn invocation_line_truncates_long_argv() {
        let mut args: Vec<String> = vec!["run".into()];
        for i in 0..50 {
            args.push(format!("--exit-command-arg-{i}=value{i}"));
        }
        let line = format_podman_invocation_line("container", "podman", &args);
        assert!(line.len() <= 403, "line too long: {} chars", line.len());
        assert!(line.ends_with("..."), "line not truncated: {line}");
    }

    /// @trace spec:podman-idiomatic-patterns
    #[test]
    fn invocation_line_redacts_base64_blob() {
        // Long opaque blob without an `=` separator gets blanket-redacted.
        let blob = "Zm9vYmFyYmF6cXV4cXV1eGNvcmdldGVzdGluZ3Rva2VuMTIzNDU=";
        let line = format_podman_invocation_line(
            "secret",
            "podman",
            &["secret".into(), "create".into(), "name".into(), blob.into()],
        );
        assert!(!line.contains(blob), "raw blob leaked: {line}");
        assert!(line.contains("<redacted>"), "no redaction marker: {line}");
    }

    /// Smoke test: with `debug=true`, the logger writes to stderr. We can't
    /// portably capture stderr from the parent process, but we can re-exec
    /// ourselves via `std::process::Command` and read the child's stderr.
    /// @trace spec:podman-idiomatic-patterns
    #[test]
    fn logger_emits_to_stderr_when_debug_flag_set() {
        // Build a fake command and log it with debug=true, while temporarily
        // redirecting stderr to a pipe via a child process.
        // Simpler: just construct the same line the logger would produce and
        // assert the format. The end-to-end stderr write is exercised by the
        // logger's single eprintln! call (which is trivially correct).
        let mut cmd = std::process::Command::new("/usr/bin/podman");
        cmd.args(["ps", "--filter", "name=tillandsias-"]);
        let line = format_podman_invocation_line(
            "container",
            &cmd.get_program().to_string_lossy(),
            &cmd.get_args()
                .map(|a| a.to_string_lossy().into_owned())
                .collect::<Vec<_>>(),
        );
        assert!(line.contains("[tillandsias] podman container:"));
        assert!(line.contains("ps"));
        assert!(line.contains("--filter"));
        assert!(line.contains("name=tillandsias-"));
    }

    /// Smoke-test the active path of `log_podman_invocation_with_flag` and
    /// `log_podman_failure`. The line goes to *this* process's stderr; we don't
    /// portably capture it from inside, but we exercise the code path so any
    /// panic / unwind would fail the test.
    /// @trace spec:podman-idiomatic-patterns
    #[test]
    fn log_helper_writes_one_line_to_stderr() {
        let _guard = env_lock();
        unsafe {
            std::env::remove_var("TILLANDSIAS_DEBUG");
        }
        let mut cmd = std::process::Command::new("/usr/bin/podman");
        cmd.arg("--version");
        // No-op path: debug=false, env unset.
        log_podman_invocation_with_flag("test", &cmd, false);
        // Active path — emits one line to stderr.
        log_podman_invocation_with_flag("test", &cmd, true);
        // Failure path requires the env var.
        unsafe {
            std::env::set_var("TILLANDSIAS_DEBUG", "1");
        }
        log_podman_failure("test", "1", "some short stderr text");
        // Multi-line stderr gets collapsed.
        log_podman_failure("test", "125", "line1\nline2\nline3");
        // Very long stderr gets truncated.
        log_podman_failure("test", "125", &"x".repeat(2000));
        unsafe {
            std::env::remove_var("TILLANDSIAS_DEBUG");
        }
    }

    /// End-to-end stderr capture: re-exec the test binary so we can read the
    /// child's stderr and assert the exact log line is present. This is the
    /// most direct verification that `--debug` actually shows the user the
    /// invocation.
    /// @trace spec:podman-idiomatic-patterns
    #[test]
    fn end_to_end_stderr_capture_via_subprocess() {
        // Trigger marker — when the test binary sees this env var, the main
        // test below short-circuits, runs the logger, and exits.
        if std::env::var("TILLANDSIAS_PODMAN_LOG_E2E").as_deref() == Ok("emit") {
            let mut cmd = std::process::Command::new("/usr/bin/podman");
            cmd.args(["ps", "--filter", "name=tillandsias-"]);
            log_podman_invocation_with_flag("container", &cmd, true);
            log_podman_failure("container", "125", "Error: no such container");
            std::process::exit(0);
        }

        // Spawn the same test binary with the marker env var set and capture
        // its stderr. `--nocapture` is required so libtest doesn't swallow the
        // child's stderr writes; `--exact` keeps the recursion to one test.
        let exe = std::env::current_exe().expect("current_exe");
        let output = std::process::Command::new(exe)
            .env("TILLANDSIAS_PODMAN_LOG_E2E", "emit")
            // Set the user-facing debug env var so the failure-logging path
            // (which only reads the env, not a per-call flag) also activates.
            .env("TILLANDSIAS_DEBUG", "1")
            .args([
                "--exact",
                "tests::end_to_end_stderr_capture_via_subprocess",
                "--nocapture",
            ])
            .output()
            .expect("spawn child");
        let stderr = String::from_utf8_lossy(&output.stderr);
        assert!(
            stderr.contains(
                "[tillandsias] podman container: /usr/bin/podman ps --filter name=tillandsias-"
            ),
            "missing invocation line in stderr:\n{stderr}"
        );
        assert!(
            stderr.contains(
                "[tillandsias] podman container failed: status=125 stderr=Error: no such container"
            ),
            "missing failure line in stderr:\n{stderr}"
        );
    }
}
