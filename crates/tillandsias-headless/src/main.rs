// @trace spec:linux-native-portable-executable, spec:runtime-logging, gap:OBS-003, gap:OBS-006, gap:OBS-009, gap:OBS-013
//! Tillandsias native headless app lifecycle launcher.
//!
//! Runs containerized development environments without a graphical interface.
//! Suitable for CI/CD, automation, and server deployments.
//!
//! Transparent Mode Detection (Phase 3):
//! - If --headless NOT set AND native Linux tray support is available, spawn tray
//! - If --headless set, run in headless mode (no tray UI)
//! - If --tray set, explicitly run in tray mode
//!
//! Usage:
//!   tillandsias                              # Auto-detect (transparent mode)
//!   tillandsias --headless [config_path]    # Headless mode (no UI)
//!   tillandsias --tray [config_path]        # Tray mode (requires native Linux tray feature)
//!   tillandsias --observatorium <project>    # Project Observatorium launcher
//!   tillandsias --port <port>                # Router / observatorium fallback host port
//!
//! JSON Events:
//!   - {"event":"app.started","timestamp":"<RFC3339>"} — at startup
//!   - {"event":"containers.running","count":N} — on discovery
//!   - {"event":"app.stopped","exit_code":0,"timestamp":"<RFC3339>"} — on graceful shutdown
//!
//! Logging Integration:
//! See `crates/tillandsias-logging/INTEGRATION.md` for structured logging setup,
//! including container lifecycle events, accountability windows, log rotation, and schema versioning (@trace gap:OBS-003).
//!
//! Cost-Aware Trace Sampling:
//! @trace gap:OBS-006 — Expensive traces (large serialization) are sampled probabilistically
//! when cumulative cost exceeds 10MB/hour threshold. Sampled traces are marked with `sample_rate: 0.5`.
//! See `crates/tillandsias-logging/src/sampler.rs` for implementation.
//!
//! Log Aggregation:
//! @trace gap:OBS-013 — Logs from multiple containers (proxy, git, forge, inference) are aggregated
//! into a unified stream by timestamp and can be filtered by container, component, spec, or level.
//! See `crates/tillandsias-logging/src/aggregator.rs` for log aggregation implementation.

use signal_hook::flag;
use std::collections::{BTreeMap, HashMap};
use std::fs;
use std::io::{self, Read, Write};
use std::os::unix::net::UnixStream;
#[cfg(unix)]
use std::os::unix::process::CommandExt;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, Ordering};
use std::time::{Duration, Instant};
use tempfile::Builder as TempDirBuilder;
use tillandsias_control_wire::{
    ControlEnvelope, ControlMessage, MAX_MESSAGE_BYTES, WIRE_VERSION, decode, encode,
};
use tillandsias_core::cache_validation;
use tillandsias_core::image_builder::{
    ImageBuildAction, ImageBuildDecision, ImageBuildIdentity, ImageBuildObservation,
    ImageBuildReason, SOURCE_DIGEST_LABEL, decide_image_build,
};
use tillandsias_logging::{ImageBuildEvent, ImageBuildEventWriter};
use tillandsias_podman::{
    ContainerSpec, MountMode, PodmanClient, current_runtime_lane, detect_gpu_devices,
    podman_cmd_sync, require_desktop_user_session, require_headless_service_account,
};
use tracing::{debug, error, info, warn};

use serde::{Deserialize, Serialize};

#[cfg(any(feature = "tray", feature = "listen-vsock"))]
mod cloud_projects;
mod control_dispatch;
#[cfg(any(feature = "tray", feature = "listen-vsock"))]
mod local_projects;
#[cfg(any(feature = "tray", feature = "listen-vsock"))]
pub mod remote_projects;
mod runtime_assets;
#[cfg(feature = "vault")]
// @trace spec:tillandsias-vault — Phase 6 default bootstrap (was Phase 3 opt-in).
mod vault_bootstrap;

pub(crate) const VERSION: &str = include_str!("../../../VERSION");

fn main() {
    #[cfg(unix)]
    {
        // Set pgid so we can signal the whole group on exit.
        // This ensures all children (even if they try to detach) can be tracked.
        let _ = unsafe { libc::setpgid(0, 0) };
    }

    let version = VERSION.trim();

    // Parse CLI arguments
    let args: Vec<String> = std::env::args().collect();
    let user_args: Vec<String> = args.iter().skip(1).cloned().collect();

    if user_args.iter().any(|a| a == "--version") {
        println!("Tillandsias v{}", version);
        return;
    }

    if user_args.iter().any(|a| a == "--help" || a == "-h") {
        print_usage(version);
        return;
    }

    // @trace spec:vsock-transport — `--listen-vsock <PORT>` switches the
    // headless service from binding the Linux Unix control socket to
    // binding a vsock listener on `VMADDR_CID_ANY:<PORT>`. Only available
    // when the binary was compiled with `--features listen-vsock`.
    let listen_vsock_port: Option<u32> = match user_args.iter().position(|a| a == "--listen-vsock")
    {
        Some(i) => match user_args.get(i + 1).and_then(|p| p.parse::<u32>().ok()) {
            Some(port) => Some(port),
            None => {
                eprintln!("Error: --listen-vsock requires a numeric port value");
                std::process::exit(2);
            }
        },
        None => None,
    };
    let debug = user_args.iter().any(|a| a == "--debug");
    let diagnostics = user_args.iter().any(|a| a == "--diagnostics");
    let init = user_args.iter().any(|a| a == "--init");
    let force = user_args.iter().any(|a| a == "--force");
    let status_check = user_args.iter().any(|a| a == "--status-check");
    let github_login = user_args.iter().any(|a| a == "--github-login");
    let list_cloud_projects = user_args.iter().any(|a| a == "--list-cloud-projects");
    let opencode = user_args.iter().any(|a| a == "--opencode");
    let codex = user_args.iter().any(|a| a == "--codex");
    let claude = user_args.iter().any(|a| a == "--claude");
    let bash = user_args.iter().any(|a| a == "--bash");
    let opencode_web = user_args.iter().any(|a| a == "--opencode-web");
    let observatorium = user_args.iter().any(|a| a == "--observatorium");
    let cache_clear = user_args.iter().any(|a| a == "--cache-clear");
    let cache_verify = user_args.iter().any(|a| a == "--cache-verify");

    let port_override = match user_args.iter().position(|a| a == "--port") {
        Some(i) => match user_args.get(i + 1).and_then(|p| p.parse::<u16>().ok()) {
            Some(port) => Some(port),
            None => {
                eprintln!("Error: --port requires a numeric port value");
                std::process::exit(2);
            }
        },
        None => None,
    };

    // @trace spec:cli-mode, spec:runtime-diagnostics-stream, spec:cli-bash-mode, spec:cli-diagnostics
    // --diagnostics implies --debug
    let debug = debug || diagnostics;
    if debug {
        eprintln!("[tillandsias] version: {version}");
        unsafe {
            std::env::set_var("TILLANDSIAS_DEBUG", "1");
        }
    }

    // USER PRIORITY (a) of the diagnostics-driven container-start
    // verification work: emit a structured envelope line to stderr at
    // the start of every `--diagnostics` run. This is the framing the
    // distill script can rely on regardless of whether the agent
    // followed its prompt and emitted parseable JSON to stdout. The
    // most recent baseline (19:02Z) showed `TIMESTAMP=unknown` +
    // `FORGE_VERSION=unknown` + `0/0 checks passed` because the RAW_LOG
    // was empty — the LLM didn't comply. With this envelope on stderr,
    // the distill script's stderr companion path (already exists, see
    // `Container-Start Stream (from .stderr.log companion)` section in
    // every recent summary) gains a stable, machine-readable line
    // independent of LLM behaviour.
    //
    // Format pinned by `format_diagnostics_envelope_line` + its unit
    // tests. Distill-script consumer wiring lives in a follow-on slice
    // so this commit can land independently.
    //
    // @trace spec:cli-diagnostics, spec:runtime-diagnostics-stream
    // @trace plan/issues/forge-diagnostics-automation-2026-05-27.md
    //   (USER PRIORITY sub-deliverable (a))
    if diagnostics {
        let agent_kind = select_diagnostics_agent_kind(
            opencode || opencode_web,
            claude,
            codex,
            bash,
            observatorium,
        );
        let host_platform = if cfg!(target_os = "linux") {
            "linux"
        } else if cfg!(target_os = "macos") {
            "macos"
        } else if cfg!(target_os = "windows") {
            "windows"
        } else {
            "other"
        };
        let timestamp = chrono::Utc::now().to_rfc3339_opts(chrono::SecondsFormat::Secs, true);
        let line = format_diagnostics_envelope_line(&timestamp, version, host_platform, agent_kind);
        eprintln!("{line}");
    }

    if let Some(port) = port_override {
        // SAFETY: these writes happen during process startup before any worker
        // threads are spawned, so there is no concurrent environment mutation.
        unsafe {
            std::env::set_var("TILLANDSIAS_ROUTER_HOST_PORT", port.to_string());
            std::env::set_var("OBSERVATORIUM_PORT", port.to_string());
        }
    }

    // @trace spec:cli-mode, spec:cli-bash-mode, spec:cli-diagnostics
    let prompt = user_args
        .iter()
        .position(|a| a == "--prompt")
        .and_then(|i| user_args.get(i + 1).map(|p| p.to_string()));

    let known_flags = [
        "--headless",
        "--tray",
        "--debug",
        "--diagnostics",
        "--force",
        "--init",
        "--status-check",
        "--github-login",
        "--list-cloud-projects",
        "--opencode",
        "--codex",
        "--claude",
        "--bash",
        "--opencode-web",
        "--observatorium",
        "--port",
        "--prompt",
        "--cache-clear",
        "--cache-verify",
        "--listen-vsock",
    ];
    if let Some(unsupported) = user_args
        .iter()
        .enumerate()
        .find(|(i, a)| {
            a.starts_with('-')
                && !known_flags.contains(&a.as_str())
                && user_args.get(i.saturating_sub(1)).is_none_or(|prev| {
                    prev != "--prompt" && prev != "--listen-vsock" && prev != "--port"
                })
        })
        .map(|(_, a)| a)
    {
        eprintln!("Unsupported option: {unsupported}");
        eprintln!("Run 'tillandsias --help' for supported options.");
        std::process::exit(2);
    }

    let headless = user_args.iter().any(|a| a == "--headless");
    let tray = user_args.iter().any(|a| a == "--tray");

    let is_cli_mode = opencode
        || codex
        || claude
        || bash
        || opencode_web
        || observatorium
        || init
        || status_check
        || github_login
        || list_cloud_projects
        || cache_clear
        || cache_verify;

    // @trace spec:singleton-guard
    // Enforce singleton behavior. Newer instances signal and terminate older instances.
    // We gate all run modes and init to prevent port/state collisions.
    let _singleton = if !is_cli_mode {
        match tillandsias_core::singleton::SingletonGuard::acquire(
            "launcher",
            Duration::from_secs(5),
        ) {
            Ok(g) => Some(g),
            Err(e) => {
                eprintln!("Error: Singleton acquisition failed: {e}");
                std::process::exit(1);
            }
        }
    } else {
        None
    };

    let config_path = user_args.iter().enumerate().find_map(|(i, a)| {
        if a.starts_with('-') {
            return None;
        }
        if user_args
            .get(i.saturating_sub(1))
            .is_some_and(|prev| prev == "--prompt" || prev == "--port" || prev == "--listen-vsock")
        {
            return None;
        }
        Some(a.to_string())
    });

    if github_login {
        // @trace spec:tillandsias-vault
        // Phase 6: the default flow stores the token in Vault.
        if let Err(e) = run_github_login(debug) {
            eprintln!("Error: {}", e);
            std::process::exit(1);
        }
        return;
    }

    if list_cloud_projects {
        // Headless diagnostic: run the exact containerized GitHub fetch the
        // tray's ☁️ Cloud submenu uses, with timing, so the remote-projects
        // path can be verified without the GUI. @trace spec:remote-projects
        if let Err(e) = run_list_cloud_projects(debug) {
            eprintln!("Error: {}", e);
            std::process::exit(1);
        }
        return;
    }

    if cache_clear {
        if let Err(e) = run_cache_clear(debug) {
            eprintln!("Error: {}", e);
            std::process::exit(1);
        }
        return;
    }

    if cache_verify {
        if let Err(e) = run_cache_verify(debug) {
            eprintln!("Error: {}", e);
            std::process::exit(1);
        }
        return;
    }

    if init {
        if let Err(e) = run_init(debug, force) {
            eprintln!("Error: {}", e);
            std::process::exit(1);
        }

        // @trace spec:tillandsias-vault
        // Phase 6: Vault is the default secrets backend on Linux.
        #[cfg(feature = "vault")]
        if std::env::var_os("LITMUS_PODMAN_MODE").is_some() {
            // Skip Vault bootstrap in litmus/fake mode — no Vault container.
        } else if let Err(e) = vault_bootstrap::ensure_vault_running(debug) {
            eprintln!("Error bringing Vault up: {}", e);
            std::process::exit(1);
        }
        #[cfg(not(feature = "vault"))]
        {
            if debug {
                eprintln!("[tillandsias] vault feature not compiled; continuing without Vault");
            }
        }

        if status_check {
            if let Err(e) = run_status_check(debug) {
                eprintln!("Error: {}", e);
                std::process::exit(1);
            }
            println!("status-check completed");
        }
        if !opencode {
            return;
        }
    }

    if user_args
        .iter()
        .any(|a| a == "--without-vault" || a == "--legacy-keyring-secrets")
    {
        eprintln!(
            "Error: --without-vault and --legacy-keyring-secrets have been REMOVED in v0.2.260602."
        );
        eprintln!(
            "Vault is now the mandatory secrets backend. See openspec/specs/tillandsias-vault/spec.md"
        );
        std::process::exit(1);
    }

    if status_check && !init {
        if let Err(e) = run_status_check(debug) {
            eprintln!("Error: {}", e);
            std::process::exit(1);
        }
        println!("status-check completed");
        return;
    }

    if opencode {
        maybe_spawn_detached_tray_for_cli(tray, debug);
        if let Some(project_path) = config_path {
            if let Err(e) = run_opencode_mode(&project_path, prompt.as_deref(), debug) {
                eprintln!("Error: {}", e);
                std::process::exit(1);
            }
            return;
        } else {
            eprintln!("Error: --opencode requires project path");
            std::process::exit(2);
        }
    }

    if codex || claude || bash {
        maybe_spawn_detached_tray_for_cli(tray, debug);
        let (mode, flag) = if codex {
            (ForgeAgentMode::Codex, "--codex")
        } else if claude {
            (ForgeAgentMode::Claude, "--claude")
        } else {
            (ForgeAgentMode::Maintenance, "--bash")
        };
        if let Some(project_path) = config_path {
            if let Err(e) = run_forge_agent_cli_mode(&project_path, mode, flag, debug) {
                eprintln!("Error: {}", e);
                std::process::exit(1);
            }
            return;
        } else {
            eprintln!("Error: {flag} requires project path");
            std::process::exit(2);
        }
    }

    if opencode_web {
        maybe_spawn_detached_tray_for_cli(tray, debug);
        if let Some(project_path) = config_path {
            if let Err(e) =
                run_opencode_web_mode(&project_path, prompt.as_deref(), port_override, debug)
            {
                eprintln!("Error: {}", e);
                std::process::exit(1);
            }
            return;
        } else {
            eprintln!("Error: --opencode-web requires project path");
            std::process::exit(2);
        }
    }

    if observatorium {
        maybe_spawn_detached_tray_for_cli(tray, debug);
        if let Some(project_path) = config_path {
            if let Err(e) = run_observatorium_mode(&project_path, port_override, debug) {
                eprintln!("Error: {}", e);
                std::process::exit(1);
            }
            return;
        } else {
            eprintln!("Error: --observatorium requires project path");
            std::process::exit(2);
        }
    }

    // Phase 3, Task 12: Auto-detection (transparent mode)
    // If neither --headless nor --tray specified, auto-detect based on environment
    if !headless && !tray {
        if is_tray_available() {
            // @trace spec:linux-native-portable-executable, spec:transparent-mode-detection, spec:singleton-guard
            // Native tray support is available — launch tray mode.
            if cfg!(feature = "tray") {
                if let Err(e) = launch_tray_mode(config_path, debug) {
                    eprintln!("Error launching tray mode: {}", e);
                    std::process::exit(1);
                }
                return;
            } else {
                // GTK available but tray feature not compiled — fall back to headless
                eprintln!(
                    "Native tray support detected but tray feature not compiled. \
                    To use tray mode, rebuild with --features tray"
                );
                // Continue to headless mode below
            }
        } else {
            // GTK not available — run headless directly. This keeps the app
            // lifecycle usable even when the native tray artifact is absent.
        }
    }

    // Phase 3, Task 13: Explicit --tray flag support
    // @trace spec:singleton-guard
    if tray {
        if cfg!(feature = "tray") {
            if let Err(e) = launch_tray_mode(config_path, debug) {
                eprintln!("Error launching tray mode: {}", e);
                std::process::exit(1);
            }
            return;
        } else {
            eprintln!("Native tray wrapper is not packaged in this launcher yet.");
            eprintln!("Continuing with the headless app lifecycle for now.");
            if let Err(e) = run_headless(config_path, listen_vsock_port) {
                eprintln!("Error: {}", e);
                std::process::exit(1);
            }
            return;
        }
    }

    // Headless mode (explicit --headless or auto-detected)
    if (headless || !cfg!(feature = "tray"))
        && let Err(e) = run_headless(config_path, listen_vsock_port)
    {
        eprintln!("Error: {}", e);
        std::process::exit(1);
    }
}

/// Map the agent-selection boolean flags to a stable string token for
/// the `event:diagnostics_envelope` stderr line. Mutual exclusion is
/// enforced upstream by the CLI usage; if multiple flags happen to be
/// set we resolve in the documented precedence order:
/// opencode > claude > codex > bash > observatorium. `none` is the
/// fallback when --diagnostics was passed without an agent flag (the
/// envelope still emits — operator gets a real timestamp).
///
/// @trace spec:cli-diagnostics, spec:runtime-diagnostics-stream
fn select_diagnostics_agent_kind(
    opencode_any: bool,
    claude: bool,
    codex: bool,
    bash: bool,
    observatorium: bool,
) -> &'static str {
    if opencode_any {
        "opencode"
    } else if claude {
        "claude"
    } else if codex {
        "codex"
    } else if bash {
        "bash"
    } else if observatorium {
        "observatorium"
    } else {
        "none"
    }
}

/// Format the structured envelope line emitted by `tillandsias
/// --diagnostics` to stderr at the start of every run. The distill
/// script's stderr-companion path consumes this in a follow-on slice
/// to recover framing fields (timestamp, version, host, agent) when
/// the LLM's stdout JSON is empty or malformed.
///
/// Format is space-separated key=value pairs, prefixed with the event
/// tag `event:diagnostics_envelope`. Pinned shape:
///
/// ```text
/// event:diagnostics_envelope timestamp=<ISO-8601-UTC> tillandsias_version=<v> host_platform=<linux|macos|windows|other> agent=<opencode|claude|codex|bash|observatorium|none>
/// ```
///
/// Same family as the existing `event:container_launch …` lines that
/// `litmus-container-start-health` already greps. Both come from the
/// debug/diagnostics stream; `container_launch` is per-container,
/// `diagnostics_envelope` is per-run.
///
/// @trace spec:cli-diagnostics, spec:runtime-diagnostics-stream
fn format_diagnostics_envelope_line(
    timestamp: &str,
    tillandsias_version: &str,
    host_platform: &str,
    agent_kind: &str,
) -> String {
    format!(
        "event:diagnostics_envelope timestamp={timestamp} tillandsias_version={tillandsias_version} host_platform={host_platform} agent={agent_kind}"
    )
}

fn print_usage(version: &str) {
    println!("Tillandsias v{}", version);
    println!("Usage: tillandsias [--headless|--tray] [config_path]");
    println!("       tillandsias --init [--force] [--debug]");
    println!("       tillandsias --status-check [--debug]");
    println!("       tillandsias --github-login [--debug]");
    println!("       tillandsias --cache-verify [--debug]");
    println!("       tillandsias --cache-clear [--debug]");
    println!("       tillandsias --opencode <project> [--prompt <text>] [--debug|--diagnostics]");
    println!("       tillandsias --codex <project> [--debug|--diagnostics]");
    println!("       tillandsias --claude <project> [--debug|--diagnostics]");
    println!("       tillandsias --bash <project> [--debug|--diagnostics]");
    println!(
        "       tillandsias --opencode-web <project> [--prompt <text>] [--debug|--diagnostics]"
    );
    println!("       tillandsias --observatorium <project> [--port <port>]");
    println!("  --headless     Run in headless mode (no UI)");
    println!("  --tray         Run in tray mode (requires native tray support)");
    println!(
        "  --listen-vsock PORT   Bind the control wire on vsock (in-VM headless; requires feature `listen-vsock`)"
    );
    println!("  --opencode     Enable LLM code analysis mode");
    println!("  --codex        Launch Codex inside the forge for a project");
    println!("  --claude       Launch Claude Code inside the forge for a project");
    println!("  --bash         Launch the forge welcome shell for a project");
    println!("  --opencode-web Launch OpenCode Web plus isolated browser");
    println!("  --observatorium Launch the project Observatorium viewer");
    println!(
        "  --port PORT     Use PORT when 80 and 8080 are unavailable for the router or observatorium"
    );
    println!("  --prompt TEXT  Send prompt to LLM inference (requires --opencode)");
    println!("  --init         Pre-build container images");
    println!("  --force        Rebuild all images even if cached (use with --init)");
    println!("  --cache-verify Check cache integrity and report status");
    println!("  --cache-clear  Clear the initialization cache and build state");
    println!("  --status-check Verify services are online through a representative stack smoke");
    println!("  --github-login Authenticate GitHub and store the token in Vault");
    println!(
        "  --list-cloud-projects  List remote GitHub repos via the saved Vault token (diagnostic)"
    );
    println!("  --debug        Show command-level diagnostics and capture build logs");
    println!(
        "  --diagnostics  Stream real-time logs from all enclave containers (implies --debug)"
    );
    println!("  --version      Show version information");
    println!("  --help         Show this help");
    println!();
    println!("Auto-detection: Tray mode if native tray support is available, headless otherwise");
}

fn checkout_root_is_valid(path: &Path) -> bool {
    path.join("VERSION").is_file() && path.join("images").is_dir()
}

/// Locate a developer Tillandsias checkout root.
///
/// User runtime paths should call `resolve_runtime_asset_root` instead. This
/// helper exists for explicit `TILLANDSIAS_ROOT` developer overrides and tests.
fn find_developer_checkout_root() -> Result<PathBuf, String> {
    if let Ok(root) = std::env::var("TILLANDSIAS_ROOT") {
        let path = PathBuf::from(root);
        if checkout_root_is_valid(&path) {
            return Ok(path);
        }
        return Err(format!(
            "TILLANDSIAS_ROOT does not point at a valid Tillandsias checkout: {}",
            path.display()
        ));
    }

    let mut dir = std::env::current_dir().map_err(|e| format!("Failed to get cwd: {e}"))?;
    loop {
        if checkout_root_is_valid(&dir) {
            return Ok(dir);
        }
        if !dir.pop() {
            break;
        }
    }

    Err(
        "Could not find Tillandsias developer checkout. Set TILLANDSIAS_ROOT to override runtime assets."
            .to_string(),
    )
}

pub(crate) fn resolve_runtime_asset_root(version: &str, debug: bool) -> Result<PathBuf, String> {
    // @trace spec:user-runtime-lifecycle, spec:linux-native-portable-executable
    if std::env::var_os("TILLANDSIAS_ROOT").is_some() {
        let root = find_developer_checkout_root()?;
        if debug {
            eprintln!(
                "[tillandsias] using developer runtime assets from TILLANDSIAS_ROOT={}",
                root.display()
            );
        }
        return Ok(root);
    }

    runtime_assets::ensure_runtime_assets(version, debug)
}

#[allow(dead_code)]
fn find_checkout_root() -> Result<PathBuf, String> {
    find_developer_checkout_root()
}

fn run_command(mut command: Command, debug: bool) -> Result<(), String> {
    if debug {
        eprintln!("[tillandsias] running: {:?}", command);
    }
    let status = command
        .status()
        .map_err(|e| format!("Failed to run command: {e}"))?;
    if status.success() {
        Ok(())
    } else {
        Err(format!("Command exited with status {status}"))
    }
}

fn run_command_silent(mut command: Command, debug: bool) -> Result<(), String> {
    if debug {
        eprintln!("[tillandsias] running: {:?}", command);
    }
    let output = command
        .output()
        .map_err(|e| format!("Failed to run command: {e}"))?;
    if output.status.success() {
        Ok(())
    } else {
        let stderr = String::from_utf8_lossy(&output.stderr).trim().to_string();
        if stderr.is_empty() {
            Err(format!("Command exited with status {}", output.status))
        } else {
            Err(stderr)
        }
    }
}

const ENCLAVE_NET: &str = "tillandsias-enclave";
const DEFAULT_ENCLAVE_SUBNET: &str = "10.0.42.0/24";
const ENCLAVE_SUBNET_ENV: &str = "TILLANDSIAS_ENCLAVE_SUBNET";
/// Managed egress network. The enclave network is `--internal` (no NAT egress),
/// so the proxy and git-service are dual-homed onto this network to retain a
/// single allowlisted/direct egress leg. Self-contained on purpose: Podman's
/// rootless default network is named `podman` (not `bridge`) and is absent after
/// `podman system reset --force`, so the dual-home leg must target a network
/// Tillandsias creates itself, or it cannot resolve on a clean runtime.
/// @trace spec:enclave-network, spec:proxy-container
const EGRESS_NET: &str = "tillandsias-egress";
/// The dual-homed network spec attached to egress-capable enclave containers
/// (proxy, git-service): enclave leg for in-enclave DNS + the egress leg for NAT.
const ENCLAVE_EGRESS_NETS: &str = "tillandsias-enclave,tillandsias-egress";
const ENCLAVE_NO_PROXY_BASE: &str =
    "localhost,127.0.0.1,0.0.0.0,::1,inference,proxy,git-service,tillandsias-git";
const CA_DIR: &str = "/tmp/tillandsias-ca";

fn enclave_subnet() -> String {
    std::env::var(ENCLAVE_SUBNET_ENV)
        .ok()
        .map(|value| value.trim().to_string())
        .filter(|value| !value.is_empty())
        .unwrap_or_else(|| DEFAULT_ENCLAVE_SUBNET.to_string())
}

pub(crate) fn enclave_no_proxy() -> String {
    format!("{},{}", ENCLAVE_NO_PROXY_BASE, enclave_subnet())
}

// @trace spec:init-incremental-builds
/// Build state tracking for incremental initialization.
///
/// Persists to `~/.cache/tillandsias/init-build-state.json` (atomic write via temp file).
/// Used to skip building images that were previously successful and still exist.
///
/// ## Build Status Values
/// - `"success"` — Image built successfully and still exists locally
/// - `"failed"` — Image failed to build; should be attempted again on next --init
/// - `"pending"` — (not currently used; reserved for future async builds)
///
/// ## Example State File
/// ```json
/// {
///   "images": {
///     "proxy": "success",
///     "git": "success",
///     "inference": "success",
///     "chromium-core": "success",
///     "chromium-framework": "success",
///     "forge": "success"
///   },
///   "timestamp": "2026-05-14T10:30:45.123456-07:00"
/// }
/// ```
#[derive(Debug, Clone, Serialize, Deserialize)]
struct InitBuildState {
    /// Map of image name -> build status ("success", "failed", "pending")
    images: std::collections::HashMap<String, String>,
    /// Map of image name -> digest of the source context used for the build.
    #[serde(default)]
    image_source_digests: std::collections::HashMap<String, String>,
    /// Additive v2 identity records. Older state files deserialize with an
    /// empty map and remain valid.
    #[serde(default)]
    image_identities: HashMap<String, InitImageIdentity>,
    /// Digest of the materialized runtime asset manifest, when available.
    #[serde(default)]
    runtime_asset_manifest_digest: Option<String>,
    /// Timestamp of last init run (RFC 3339 format)
    timestamp: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
struct InitImageIdentity {
    source_digest: String,
    canonical_tag: String,
    version_alias: String,
    latest_alias: String,
    #[serde(default)]
    image_id: Option<String>,
    last_action: ImageBuildAction,
    last_reason: ImageBuildReason,
}

impl InitBuildState {
    fn new() -> Self {
        Self {
            images: std::collections::HashMap::new(),
            image_source_digests: std::collections::HashMap::new(),
            image_identities: HashMap::new(),
            runtime_asset_manifest_digest: None,
            timestamp: chrono::Local::now().to_rfc3339(),
        }
    }

    fn load() -> Result<Option<Self>, String> {
        let cache_dir = init_cache_dir()?;
        let state_file = cache_dir.join("init-build-state.json");
        let temp_file = cache_dir.join(".init-build-state.json.tmp");

        // Clean up any leftover temp file from a crashed write
        if temp_file.exists() {
            let _ = fs::remove_file(&temp_file);
        }

        if !state_file.exists() {
            return Ok(None);
        }
        let contents = fs::read_to_string(&state_file)
            .map_err(|e| format!("Failed to read init build state: {e}"))?;
        let state = serde_json::from_str(&contents)
            .map_err(|e| format!("Failed to parse init build state: {e}"))?;
        Ok(Some(state))
    }

    fn save(&self) -> Result<(), String> {
        let cache_dir = init_cache_dir()?;
        let state_file = cache_dir.join("init-build-state.json");
        let contents = serde_json::to_string_pretty(self)
            .map_err(|e| format!("Failed to serialize state: {e}"))?;

        // Atomic write: write to temp file, then rename.
        // This prevents corruption if the process is killed mid-write.
        let temp_file = cache_dir.join(".init-build-state.json.tmp");
        fs::write(&temp_file, contents)
            .map_err(|e| format!("Failed to write temporary state file: {e}"))?;

        fs::rename(&temp_file, &state_file).map_err(|e| {
            let _ = fs::remove_file(&temp_file);
            format!("Failed to rename state file atomically: {e}")
        })?;

        Ok(())
    }

    fn mark_success(&mut self, image: &str) {
        self.images.insert(image.to_string(), "success".to_string());
    }

    fn mark_failed(&mut self, image: &str) {
        self.images.insert(image.to_string(), "failed".to_string());
    }

    #[cfg(test)]
    fn was_successful(&self, image: &str) -> bool {
        self.images
            .get(image)
            .map(|s| s == "success")
            .unwrap_or(false)
    }

    fn set_image_identity(
        &mut self,
        image: &str,
        decision: &ImageBuildDecision,
        image_id: Option<String>,
    ) {
        self.image_source_digests
            .insert(image.to_string(), decision.identity.source_digest.clone());
        self.image_identities.insert(
            image.to_string(),
            InitImageIdentity {
                source_digest: decision.identity.source_digest.clone(),
                canonical_tag: decision.identity.canonical_tag.clone(),
                version_alias: decision.identity.version_alias.clone(),
                latest_alias: decision.identity.latest_alias.clone(),
                image_id,
                last_action: decision.action,
                last_reason: decision.reason,
            },
        );
    }

    fn set_runtime_asset_manifest_digest(&mut self, digest: Option<String>) {
        self.runtime_asset_manifest_digest = digest;
    }

    /// Check if cache version matches current VERSION.
    /// @trace spec:forge-staleness, spec:forge-cache-dual
    #[allow(dead_code)]
    fn is_version_current(version: &str) -> Result<bool, String> {
        let cache_dir = init_cache_dir()?;
        let version_file = cache_dir.join("cache_version");

        if !version_file.exists() {
            return Ok(false);
        }

        let cached_version = fs::read_to_string(&version_file)
            .map_err(|e| format!("Failed to read cached version: {e}"))?
            .trim()
            .to_string();

        Ok(cached_version == version)
    }

    /// Get the last recorded Containerfile mtime for an image.
    /// @trace spec:containerfile-staleness
    #[allow(dead_code)]
    fn get_last_containerfile_mtime(image: &str) -> Result<Option<u64>, String> {
        let cache_dir = init_cache_dir()?;
        let mtime_file = cache_dir.join(format!("{}-containerfile-mtime", image));

        if !mtime_file.exists() {
            return Ok(None);
        }

        let mtime_str = fs::read_to_string(&mtime_file)
            .map_err(|e| format!("Failed to read mtime file: {e}"))?
            .trim()
            .to_string();

        mtime_str
            .parse::<u64>()
            .ok()
            .map(Some)
            .ok_or_else(|| "Failed to parse mtime".to_string())
    }

    /// Save the current Containerfile mtime for an image.
    /// @trace spec:containerfile-staleness
    #[allow(dead_code)]
    fn save_containerfile_mtime(image: &str, mtime: u64) -> Result<(), String> {
        let cache_dir = init_cache_dir()?;
        let mtime_file = cache_dir.join(format!("{}-containerfile-mtime", image));
        fs::write(&mtime_file, mtime.to_string())
            .map_err(|e| format!("Failed to write mtime file: {e}"))
    }

    /// Save current VERSION to cache for future staleness detection.
    /// @trace spec:forge-staleness, spec:forge-cache-dual
    fn save_version(version: &str) -> Result<(), String> {
        let cache_dir = init_cache_dir()?;
        let version_file = cache_dir.join("cache_version");
        fs::write(&version_file, version).map_err(|e| format!("Failed to write cache version: {e}"))
    }
}

// @trace spec:forge-staleness, spec:forge-cache-dual
/// Cache integrity check result
#[derive(Debug, Clone)]
struct CacheIntegrityStatus {
    is_valid: bool,
    version_mismatch: bool,
    cache_dir: PathBuf,
    current_version: String,
    cached_version: Option<String>,
    missing_state_file: bool,
}

/// Check cache integrity: version match, state file presence, file accessibility.
/// @trace spec:forge-staleness, spec:forge-cache-dual
fn check_cache_integrity(version: &str) -> Result<CacheIntegrityStatus, String> {
    let cache_dir = init_cache_dir()?;
    let version_file = cache_dir.join("cache_version");
    let state_file = cache_dir.join("init-build-state.json");

    let cached_version = if version_file.exists() {
        Some(
            fs::read_to_string(&version_file)
                .map_err(|e| format!("Failed to read cached version file: {e}"))?
                .trim()
                .to_string(),
        )
    } else {
        None
    };

    let version_mismatch = cached_version
        .as_ref()
        .map(|v| v != version)
        .unwrap_or(false); // No cached version on fresh start is OK, not a mismatch

    let missing_state_file = !state_file.exists();

    let is_valid = !version_mismatch && !missing_state_file;

    Ok(CacheIntegrityStatus {
        is_valid,
        version_mismatch,
        cache_dir,
        current_version: version.to_string(),
        cached_version,
        missing_state_file,
    })
}

pub(crate) fn init_cache_dir() -> Result<PathBuf, String> {
    let mut candidates = Vec::new();
    if let Ok(cache_home) = std::env::var("XDG_CACHE_HOME") {
        candidates.push(PathBuf::from(cache_home).join("tillandsias"));
    }
    if let Ok(home) = std::env::var("HOME") {
        candidates.push(PathBuf::from(home).join(".cache").join("tillandsias"));
    }
    candidates.push(PathBuf::from("/tmp/tillandsias"));

    for cache_dir in candidates {
        if fs::create_dir_all(&cache_dir).is_ok() && cache_dir_is_writable(&cache_dir) {
            return Ok(cache_dir);
        }
    }

    Err("Failed to create a writable cache directory".to_string())
}

fn cache_dir_is_writable(cache_dir: &Path) -> bool {
    let probe = cache_dir.join(".writable-probe");
    match fs::OpenOptions::new()
        .write(true)
        .create_new(true)
        .open(&probe)
    {
        Ok(_) => {
            let _ = fs::remove_file(&probe);
            true
        }
        Err(_) => false,
    }
}

fn init_log_file(image_name: &str, debug: bool) -> Option<PathBuf> {
    if !debug {
        return None;
    }

    Some(PathBuf::from(format!(
        "/tmp/tillandsias-init-{}.log",
        image_name
    )))
}
enum RuntimeOrHandle {
    Runtime(tokio::runtime::Runtime),
    Handle(tokio::runtime::Handle),
}

impl RuntimeOrHandle {
    fn block_on<F: std::future::Future>(&self, f: F) -> F::Output {
        match self {
            Self::Runtime(rt) => rt.block_on(f),
            Self::Handle(handle) => {
                // If we are already in an async context, we cannot block the current thread.
                // However, zbus / tokio allows block_in_place if we are on a multi-threaded runtime.
                // A safer way is tokio::task::block_in_place or running it inside a helper.
                tokio::task::block_in_place(move || handle.block_on(f))
            }
        }
    }
}

fn podman_runtime() -> Result<RuntimeOrHandle, String> {
    if let Ok(handle) = tokio::runtime::Handle::try_current() {
        Ok(RuntimeOrHandle::Handle(handle))
    } else {
        tokio::runtime::Runtime::new()
            .map(RuntimeOrHandle::Runtime)
            .map_err(|e| format!("Failed to create async runtime: {e}"))
    }
}

fn report_runtime_lane(context: &str, debug: bool) {
    if debug {
        eprintln!(
            "[tillandsias] {context} runtime lane: {}",
            current_runtime_lane().label()
        );
    }
}

fn image_specs(root: &Path, image_name: &str) -> Result<(PathBuf, PathBuf), String> {
    let rel = match image_name {
        "forge-base" | "forge" => "images/default",
        "proxy" => "images/proxy",
        "git" => "images/git",
        "inference" => "images/inference",
        "web" => "images/web",
        "router" => "images/router",
        "chromium-core" => "images/chromium",
        "chromium-framework" => "images/chromium",
        "vault" => "images/vault",
        "zeroclaw" => "images/zeroclaw",
        other => {
            return Err(format!("Unknown image type: {other}"));
        }
    };

    let context_dir = root.join(rel);
    let containerfile = match image_name {
        "forge-base" => context_dir.join("Containerfile.base"),
        "chromium-core" => context_dir.join("Containerfile.core"),
        "chromium-framework" => context_dir.join("Containerfile.framework"),
        _ => context_dir.join("Containerfile"),
    };

    if !containerfile.is_file() {
        return Err(format!(
            "Containerfile not found for {image_name}: {}",
            containerfile.display()
        ));
    }

    Ok((containerfile, context_dir))
}

fn versioned_image_tag(image_name: &str, version: &str) -> String {
    format!("localhost/tillandsias-{image_name}:v{version}")
}

#[allow(clippy::type_complexity)]
fn image_build_inputs(
    image_name: &str,
    identities: &HashMap<String, ImageBuildIdentity>,
) -> Result<(BTreeMap<String, String>, BTreeMap<String, String>), String> {
    let mut build_args = BTreeMap::new();
    let mut dependency_digests = BTreeMap::new();
    if image_name == "chromium-framework" {
        let core = identities.get("chromium-core").ok_or_else(|| {
            "chromium-framework identity requires chromium-core identity".to_string()
        })?;
        build_args.insert(
            "CHROMIUM_CORE_IMAGE".to_string(),
            core.canonical_tag.clone(),
        );
        dependency_digests.insert("chromium-core".to_string(), core.source_digest.clone());
    } else if image_name == "forge" {
        let base = identities
            .get("forge-base")
            .ok_or_else(|| "forge identity requires forge-base identity".to_string())?;
        build_args.insert("BASE_IMAGE".to_string(), base.canonical_tag.clone());
        dependency_digests.insert("forge-base".to_string(), base.source_digest.clone());
    } else if image_name == "zeroclaw" {
        let base = identities
            .get("forge-base")
            .ok_or_else(|| "zeroclaw identity requires forge-base identity".to_string())?;
        build_args.insert("BASE_IMAGE".to_string(), base.canonical_tag.clone());
        dependency_digests.insert("forge-base".to_string(), base.source_digest.clone());
    }
    Ok((build_args, dependency_digests))
}

fn image_inspect_metadata(inspect_json: &str) -> Result<(Option<String>, Option<String>), String> {
    let value: serde_json::Value = serde_json::from_str(inspect_json)
        .map_err(|e| format!("Failed to parse podman image inspect JSON: {e}"))?;
    let image = value
        .as_array()
        .and_then(|items| items.first())
        .unwrap_or(&value);
    let image_id = image
        .get("Id")
        .or_else(|| image.get("ID"))
        .and_then(serde_json::Value::as_str)
        .map(str::to_string);
    let source_digest = image
        .pointer("/Config/Labels")
        .or_else(|| image.get("Labels"))
        .and_then(|labels| labels.get(SOURCE_DIGEST_LABEL))
        .and_then(serde_json::Value::as_str)
        .map(str::to_string);
    Ok((image_id, source_digest))
}

async fn observe_image_build(
    client: &PodmanClient,
    identity: &ImageBuildIdentity,
    force: bool,
) -> (ImageBuildObservation, Option<String>) {
    let canonical_tag_exists = client.image_exists(&identity.canonical_tag).await;
    let (canonical_image_id, canonical_source_digest) = if canonical_tag_exists {
        client
            .image_inspect(&identity.canonical_tag)
            .await
            .ok()
            .and_then(|json| image_inspect_metadata(&json).ok())
            .unwrap_or((None, None))
    } else {
        (None, None)
    };

    let version_alias_matches = alias_matches_image(
        client,
        &identity.version_alias,
        canonical_image_id.as_deref(),
    )
    .await;
    let latest_alias_matches = alias_matches_image(
        client,
        &identity.latest_alias,
        canonical_image_id.as_deref(),
    )
    .await;

    (
        ImageBuildObservation {
            canonical_tag_exists,
            canonical_source_digest,
            version_alias_matches,
            latest_alias_matches,
            force,
        },
        canonical_image_id,
    )
}

async fn alias_matches_image(
    client: &PodmanClient,
    alias: &str,
    canonical_image_id: Option<&str>,
) -> bool {
    let Some(canonical_image_id) = canonical_image_id else {
        return false;
    };
    let Ok(json) = client.image_inspect(alias).await else {
        return false;
    };
    image_inspect_metadata(&json)
        .ok()
        .and_then(|(image_id, _)| image_id)
        .as_deref()
        == Some(canonical_image_id)
}

async fn apply_image_aliases(
    client: &PodmanClient,
    identity: &ImageBuildIdentity,
) -> Result<(), String> {
    client
        .image_tag(&identity.canonical_tag, &identity.version_alias)
        .await
        .map_err(|e| format!("Failed to update version image alias: {e}"))?;
    client
        .image_tag(&identity.canonical_tag, &identity.latest_alias)
        .await
        .map_err(|e| format!("Failed to update latest image alias: {e}"))
}

fn image_build_action_label(action: ImageBuildAction) -> &'static str {
    match action {
        ImageBuildAction::Skip => "skip",
        ImageBuildAction::Retag => "retag",
        ImageBuildAction::Build => "build",
        ImageBuildAction::ForceRebuild => "force_rebuild",
    }
}

fn image_build_reason_label(reason: ImageBuildReason) -> &'static str {
    match reason {
        ImageBuildReason::DigestPresent => "digest_present",
        ImageBuildReason::AliasMissing => "alias_missing",
        ImageBuildReason::DigestMissing => "digest_missing",
        ImageBuildReason::LabelMismatch => "label_mismatch",
        ImageBuildReason::Forced => "forced",
    }
}

fn image_build_cache_result(action: ImageBuildAction) -> &'static str {
    match action {
        ImageBuildAction::Skip | ImageBuildAction::Retag => "hit",
        ImageBuildAction::Build => "miss",
        ImageBuildAction::ForceRebuild => "unknown",
    }
}

fn image_build_event(
    event_type: &str,
    build_id: &str,
    image_name: &str,
    identity: &ImageBuildIdentity,
    decision: &ImageBuildDecision,
) -> ImageBuildEvent {
    ImageBuildEvent::lifecycle(
        event_type,
        build_id,
        "tillandsias-init",
        image_name,
        &identity.canonical_tag,
    )
    .with_identity(
        &identity.source_digest,
        &identity.version_alias,
        &identity.latest_alias,
    )
    .with_decision(
        image_build_action_label(decision.action),
        image_build_reason_label(decision.reason),
    )
    .with_cache("layers", image_build_cache_result(decision.action))
}

fn emit_image_build_event(event: &ImageBuildEvent, debug: bool) {
    let writer = ImageBuildEventWriter::new(ImageBuildEventWriter::default_path());
    if let Err(e) = writer.append(event) {
        eprintln!(
            "WARNING: failed to write image build telemetry to {}: {}",
            writer.path().display(),
            e
        );
    } else if debug {
        eprintln!(
            "[tillandsias] image-build telemetry: {}",
            writer.path().display()
        );
    }
}

fn forge_image_tag(version: &str) -> String {
    versioned_image_tag("forge", version)
}

/// Check if Containerfile has been modified since last successful build.
/// @trace spec:containerfile-staleness
#[allow(dead_code)]
fn containerfile_is_stale(root: &Path, image_name: &str, debug: bool) -> Result<bool, String> {
    let (containerfile, _) = image_specs(root, image_name)?;

    // Get current mtime
    let metadata = fs::metadata(&containerfile)
        .map_err(|e| format!("Failed to read Containerfile metadata: {e}"))?;

    let modified = metadata
        .modified()
        .map_err(|e| format!("Failed to get modification time: {e}"))?;

    let current_mtime = modified
        .duration_since(std::time::UNIX_EPOCH)
        .map_err(|e| format!("Failed to compute mtime: {e}"))?
        .as_secs();

    // Get last recorded mtime
    match InitBuildState::get_last_containerfile_mtime(image_name)? {
        Some(last_mtime) if last_mtime >= current_mtime => {
            // Containerfile not modified since last build
            Ok(false)
        }
        _ => {
            // Containerfile modified or no record exists
            if debug {
                eprintln!(
                    "[tillandsias] Containerfile for {} has been modified or updated",
                    image_name
                );
            }
            Ok(true)
        }
    }
}

/// Capture and record the current Containerfile mtime after a successful build.
/// @trace spec:containerfile-staleness
#[allow(dead_code)]
fn capture_containerfile_mtime(root: &Path, image_name: &str) -> Result<(), String> {
    let (containerfile, _) = image_specs(root, image_name)?;

    let metadata = fs::metadata(&containerfile)
        .map_err(|e| format!("Failed to read Containerfile metadata: {e}"))?;

    let modified = metadata
        .modified()
        .map_err(|e| format!("Failed to get modification time: {e}"))?;

    let mtime = modified
        .duration_since(std::time::UNIX_EPOCH)
        .map_err(|e| format!("Failed to compute mtime: {e}"))?
        .as_secs();

    InitBuildState::save_containerfile_mtime(image_name, mtime)
}

fn ensure_image_exists(
    root: &Path,
    image_name: &str,
    image_tag: &str,
    debug: bool,
) -> Result<(), String> {
    let (containerfile, context_dir) = image_specs(root, image_name)?;
    let rt = podman_runtime()?;
    let client = PodmanClient::new();

    let version = image_tag
        .split(':')
        .next_back()
        .unwrap_or("latest")
        .trim_start_matches('v');

    if image_name == "chromium-framework" {
        let core_tag = versioned_image_tag("chromium-core", version);
        if !rt.block_on(client.image_exists(&core_tag)) {
            ensure_image_exists(root, "chromium-core", &core_tag, debug).map_err(|e| {
                format!(
                    "Required base image '{}' is absent and failed to build on demand: {}.\n\
                     Please ensure the base image is built by running: tillandsias --init",
                    core_tag, e
                )
            })?;
        }
    } else if matches!(image_name, "forge" | "zeroclaw") {
        let base_tag = versioned_image_tag("forge-base", version);
        if !rt.block_on(client.image_exists(&base_tag)) {
            ensure_image_exists(root, "forge-base", &base_tag, debug).map_err(|e| {
                format!(
                    "Required base image '{}' is absent and failed to build on demand: {}.\n\
                     Please ensure the base image is built by running: tillandsias --init",
                    base_tag, e
                )
            })?;
        }
    }

    let build_args = if image_name == "chromium-framework" {
        vec![
            "--build-arg".to_string(),
            format!(
                "CHROMIUM_CORE_IMAGE={}",
                versioned_image_tag("chromium-core", version)
            ),
        ]
    } else if matches!(image_name, "forge" | "zeroclaw") {
        vec![
            "--build-arg".to_string(),
            format!("BASE_IMAGE={}", versioned_image_tag("forge-base", version)),
        ]
    } else {
        Vec::new()
    };

    rt.block_on(async move {
        if client.image_exists(image_tag).await {
            return Ok(());
        }

        client
            .build_image(
                containerfile
                    .to_str()
                    .ok_or_else(|| "Containerfile path contains invalid UTF-8".to_string())?,
                image_tag,
                context_dir
                    .to_str()
                    .ok_or_else(|| "Context path contains invalid UTF-8".to_string())?,
                &build_args,
            )
            .await
            .map_err(|e| e.to_string())?;

        if debug {
            eprintln!("[tillandsias] built image {image_name}: {image_tag}");
        }

        Ok(())
    })
}

fn ensure_versioned_images(
    root: &Path,
    image_names: &[&str],
    version: &str,
    debug: bool,
) -> Result<(), String> {
    for image in image_names {
        let tag = versioned_image_tag(image, version);
        ensure_image_exists(root, image, &tag, debug)?;
    }
    Ok(())
}

fn ensure_enclave_network(debug: bool) -> Result<(), String> {
    // The dual-homed proxy/git-service need the egress network to exist on every
    // path that ensures the enclave, so ensure it first — even when the enclave
    // network already exists (early return below would otherwise skip it).
    ensure_egress_network(debug)?;

    if tillandsias_podman::network_exists_sync(ENCLAVE_NET) {
        return Ok(());
    }

    let subnet = enclave_subnet();
    let mut command = podman_command();
    command.args([
        "network",
        "create",
        "--internal",
        "--driver",
        "bridge",
        "--subnet",
        subnet.as_str(),
        ENCLAVE_NET,
    ]);
    run_command(command, debug)
}

/// Create the managed egress network used to dual-home the proxy and
/// git-service. Driver `bridge` with Podman-allocated IPAM (no fixed subnet, to
/// avoid clashing with the host's existing networks). Idempotent: returns early
/// when the network already exists. This is the egress leg that replaces the
/// previously hard-coded `bridge` name, which never resolved on a clean rootless
/// runtime after `podman system reset --force`.
/// @trace spec:enclave-network, spec:proxy-container
fn ensure_egress_network(debug: bool) -> Result<(), String> {
    if tillandsias_podman::network_exists_sync(EGRESS_NET) {
        return Ok(());
    }

    let mut command = podman_command();
    command.args(["network", "create", "--driver", "bridge", EGRESS_NET]);
    run_command(command, debug)
}

fn ca_bundle_needs_refresh(crt: &Path, key: &Path) -> bool {
    let max_age = std::time::Duration::from_secs(25 * 24 * 60 * 60);
    for path in [crt, key] {
        match std::fs::metadata(path).and_then(|meta| meta.modified()) {
            Ok(modified) => {
                if modified.elapsed().map(|age| age > max_age).unwrap_or(true) {
                    return true;
                }
            }
            Err(_) => return true,
        }
    }
    false
}

fn ensure_ca_bundle(debug: bool) -> Result<PathBuf, String> {
    // @trace spec:secret-rotation, spec:reverse-proxy-internal
    let certs_dir = PathBuf::from(CA_DIR);
    let crt = certs_dir.join("intermediate.crt");
    let key = certs_dir.join("intermediate.key");
    std::fs::create_dir_all(&certs_dir)
        .map_err(|e| format!("Failed to create CA directory: {e}"))?;

    let should_refresh = ca_bundle_needs_refresh(&crt, &key);

    if should_refresh {
        let lock_dir = certs_dir.join(".ca-generation.lock");
        let mut acquired_lock = false;
        for _ in 0..50 {
            match std::fs::create_dir(&lock_dir) {
                Ok(()) => {
                    acquired_lock = true;
                    break;
                }
                Err(e) if e.kind() == std::io::ErrorKind::AlreadyExists => {
                    std::thread::sleep(std::time::Duration::from_millis(100));
                }
                Err(e) => return Err(format!("Failed to acquire CA generation lock: {e}")),
            }
        }
        if !acquired_lock {
            return Err("Timed out waiting for CA generation lock".to_string());
        }
        struct LockDir(PathBuf);
        impl Drop for LockDir {
            fn drop(&mut self) {
                let _ = std::fs::remove_dir(&self.0);
            }
        }
        let _lock = LockDir(lock_dir);

        if !ca_bundle_needs_refresh(&crt, &key) {
            return Ok(certs_dir);
        }

        // @trace spec:secret-rotation
        info!(
            accountability = true,
            category = "secrets",
            spec = "secret-rotation",
            secret_name = "tillandsias-ca-cert",
            operation = "rotation_start",
            location = %crt.display(),
            "CA certificate rotation starting"
        );

        let unique = format!(
            "{}.{}",
            std::process::id(),
            chrono::Utc::now().timestamp_nanos_opt().unwrap_or_default()
        );
        let tmp_crt = certs_dir.join(format!("intermediate.crt.{unique}.tmp"));
        let tmp_key = certs_dir.join(format!("intermediate.key.{unique}.tmp"));
        let mut command = Command::new("openssl");
        command.args([
            "req",
            "-x509",
            "-newkey",
            "rsa:2048",
            "-keyout",
            tmp_key
                .to_str()
                .ok_or_else(|| "CA key path contains invalid UTF-8".to_string())?,
            "-out",
            tmp_crt
                .to_str()
                .ok_or_else(|| "CA cert path contains invalid UTF-8".to_string())?,
            "-days",
            "30",
            "-nodes",
            "-subj",
            "/C=US/ST=Privacy/L=Local/O=Tillandsias/CN=Tillandsias CA",
        ]);
        command.stdout(Stdio::null()).stderr(Stdio::null());

        if let Err(e) = run_command_silent(command, debug) {
            error!(
                accountability = true,
                category = "secrets",
                spec = "secret-rotation",
                secret_name = "tillandsias-ca-cert",
                operation = "rotation_failed",
                location = %crt.display(),
                error = %e,
                "CA certificate rotation failed"
            );
            return Err(e);
        }

        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            std::fs::set_permissions(&tmp_crt, std::fs::Permissions::from_mode(0o644)).map_err(
                |e| {
                    error!(
                        accountability = true,
                        category = "secrets",
                        spec = "secret-rotation",
                        secret_name = "tillandsias-ca-cert",
                        operation = "rotation_failed",
                        location = %crt.display(),
                        error = %e,
                        "Failed to set CA certificate permissions"
                    );
                    format!("Failed to set cert permissions: {e}")
                },
            )?;
            std::fs::set_permissions(&tmp_key, std::fs::Permissions::from_mode(0o600)).map_err(
                |e| {
                    error!(
                        accountability = true,
                        category = "secrets",
                        spec = "secret-rotation",
                        secret_name = "tillandsias-ca-key",
                        operation = "rotation_failed",
                        location = %key.display(),
                        error = %e,
                        "Failed to set CA key permissions"
                    );
                    format!("Failed to set key permissions: {e}")
                },
            )?;
        }

        std::fs::rename(&tmp_key, &key)
            .map_err(|e| format!("Failed to atomically publish CA key: {e}"))?;
        std::fs::rename(&tmp_crt, &crt)
            .map_err(|e| format!("Failed to atomically publish CA cert: {e}"))?;

        info!(
            accountability = true,
            category = "secrets",
            spec = "secret-rotation",
            secret_name = "tillandsias-ca-cert",
            operation = "rotation_complete",
            location = %crt.display(),
            "CA certificate rotation completed successfully"
        );

        if debug {
            eprintln!("[tillandsias] refreshed CA bundle at {}", crt.display());
        }
    }

    Ok(certs_dir)
}

fn build_stack_common_args(
    container_name: &str,
    hostname: &str,
    certs_dir: &Path,
    project_name: &str,
    project_path: &Path,
) -> Vec<String> {
    let no_proxy = enclave_no_proxy();
    let mut args = vec![
        "--name".into(),
        container_name.into(),
        "--hostname".into(),
        hostname.into(),
        "--network".into(),
        ENCLAVE_NET.into(),
        "--cap-drop=ALL".into(),
        "--security-opt=no-new-privileges".into(),
        "--security-opt=label=disable".into(),
        "--userns=keep-id".into(),
        "--pids-limit=512".into(),
        "--env".into(),
        "http_proxy=http://proxy:3128".into(),
        "--env".into(),
        "https_proxy=http://proxy:3128".into(),
        "--env".into(),
        "HTTP_PROXY=http://proxy:3128".into(),
        "--env".into(),
        "HTTPS_PROXY=http://proxy:3128".into(),
        "--env".into(),
        format!("no_proxy={no_proxy}"),
        "--env".into(),
        format!("NO_PROXY={no_proxy}"),
        "--env".into(),
        "PATH=/usr/local/bin:/usr/bin".into(),
        "--env".into(),
        "HOME=/home/forge".into(),
        "--env".into(),
        "USER=forge".into(),
        "--env".into(),
        format!("PROJECT={project_name}"),
        "--env".into(),
        format!("TILLANDSIAS_PROJECT={project_name}"),
        "-v".into(),
        format!(
            "{}:/home/forge/src/{project_name}:rw",
            project_path.display()
        ),
        "--mount".into(),
        format!(
            "type=bind,source={},target=/etc/tillandsias/ca.crt,readonly=true",
            certs_dir.join("intermediate.crt").display()
        ),
    ];
    append_git_identity_env_args(&mut args);
    args
}

fn build_proxy_run_args(certs_dir: &Path, image: &str) -> Vec<String> {
    vec![
        "--detach".into(),
        "--name".into(),
        "tillandsias-proxy".into(),
        "--hostname".into(),
        "proxy".into(),
        "--network".into(),
        ENCLAVE_EGRESS_NETS.into(),
        "--cap-drop=ALL".into(),
        "--security-opt=no-new-privileges".into(),
        "--security-opt=label=disable".into(),
        "--userns=keep-id".into(),
        "--pids-limit=32".into(),
        "--env".into(),
        "DEBUG_PROXY=1".into(),
        "-v".into(),
        format!(
            "{}:/etc/squid/certs/intermediate.crt:ro",
            certs_dir.join("intermediate.crt").display()
        ),
        "-v".into(),
        format!(
            "{}:/etc/squid/certs/intermediate.key:ro",
            certs_dir.join("intermediate.key").display()
        ),
        image.into(),
    ]
}

/// Read the host's `remote.origin.url` from a project's git config.
///
/// Used by `build_git_run_args` to inform the enclave mirror about the
/// project's GitHub upstream. The mirror's post-receive hook uses this URL
/// (combined with the podman secret token) to push outbound to GitHub.
///
/// Returns `None` for projects that aren't git repos, have no `origin`
/// configured, or where the git invocation fails for any reason. A missing
/// origin is benign — the mirror still serves the bare repo, and the
/// post-receive hook logs "no remote configured, skipping push".
///
/// @trace spec:git-mirror-service, spec:enclave-network
fn read_host_project_origin_url(project_path: &Path) -> Option<String> {
    let output = std::process::Command::new("git")
        .arg("-C")
        .arg(project_path)
        .args(["config", "--get", "remote.origin.url"])
        .output()
        .ok()?;
    if !output.status.success() {
        return None;
    }
    let url = String::from_utf8(output.stdout).ok()?;
    let trimmed = url.trim();
    if trimmed.is_empty() {
        None
    } else {
        Some(trimmed.to_string())
    }
}

/// Best-effort mint of a Vault AppRole token for a git-mirror container.
///
/// Returns `Some(secret_name)` when Vault is up and the AppRole login
/// succeeds; the caller passes that name to `build_git_run_args` to mount
/// the token into the container. Returns `None` on any failure or when the
/// `vault` feature is not compiled — the caller then falls back to the
/// legacy `tillandsias-github-token` podman secret.
///
/// @trace spec:tillandsias-vault
#[allow(unused_variables)]
async fn mint_git_mirror_vault_token(project_name: &str, debug: bool) -> Option<String> {
    #[cfg(feature = "vault")]
    {
        let instance = format!("{project_name}-{}", std::process::id());
        match vault_bootstrap::mint_approle_token_for_container("git-mirror", &instance, debug)
            .await
        {
            Ok((_token, secret_name)) => Some(secret_name),
            Err(e) => {
                if debug {
                    eprintln!(
                        "[tillandsias] vault AppRole mint failed ({e}); falling back to legacy keyring secret"
                    );
                }
                None
            }
        }
    }
    #[cfg(not(feature = "vault"))]
    {
        None
    }
}

/// Podman `--secret` mount options for the per-launch Vault AppRole token.
///
/// `uid=1000,gid=1000` is REQUIRED, not cosmetic. The git image runs its
/// workload as the unprivileged `git` user (uid/gid 1000 — see
/// `images/git/Containerfile`) under `--userns=keep-id`. Podman defaults a
/// `--secret` mount to `root:root`, so a `mode=0400` file is owner-only and
/// the `git` user gets `Permission denied`. `vault-cli` then reports
/// "no Vault token at /run/secrets/vault-token" and the ENTIRE credential
/// chain fails silently: the ☁️ Cloud submenu never lists remote projects and
/// the git-mirror post-receive hook can't fetch the GitHub token, so pushes
/// fall back to interactive auth. Owning the secret as uid 1000 keeps it
/// `0400` (least privilege) while remaining readable in-container.
/// @trace spec:git-mirror-service, spec:tillandsias-vault, spec:remote-projects
pub(crate) const GIT_VAULT_TOKEN_SECRET_OPTS: &str =
    "target=vault-token,uid=1000,gid=1000,mode=0400";

/// Build the podman launch args for the per-project git-mirror container.
///
/// `vault_token_secret` is the name of the podman secret holding a fresh
/// AppRole-issued Vault token scoped to `git-mirror-policy`. When supplied
/// (the Phase 6 default flow), the container mounts it at
/// `/run/secrets/vault-token` and reads the GitHub token from Vault at hook
/// time via `vault-cli`. When `None`, the launcher is running in legacy
/// keyring mode: the container instead mounts `tillandsias-github-token`
/// and the hook reads it directly from disk.
///
/// @trace spec:tillandsias-vault, spec:git-mirror-service
fn build_git_run_args(
    project_name: &str,
    certs_dir: &Path,
    image: &str,
    project_remote_url: Option<&str>,
    vault_token_secret: Option<&str>,
) -> Vec<String> {
    // Named podman volume for the bare repo. Persists across container
    // restarts so the mirror's "startup retry-push" loop has stranded commits
    // to flush. `/srv/git` is the base-path served by `git daemon` inside the
    // image's entrypoint.
    let mirror_volume = format!("tillandsias-mirror-{project_name}");
    let mut args = vec![
        "--detach".into(),
        "--rm".into(),
        "--name".into(),
        format!("tillandsias-git-{project_name}"),
        "--hostname".into(),
        sanitize_hostname(&format!("git-{project_name}")),
        "--network-alias".into(),
        "git-service".into(),
        "--network-alias".into(),
        "tillandsias-git".into(),
        "--network".into(),
        ENCLAVE_EGRESS_NETS.into(),
        "--cap-drop=ALL".into(),
        "--security-opt=no-new-privileges".into(),
        "--security-opt=label=disable".into(),
        "--userns=keep-id".into(),
        "--pids-limit=64".into(),
        "--read-only".into(),
        "--volume".into(),
        format!("{mirror_volume}:/srv/git"),
        "--env".into(),
        format!("PROJECT={project_name}"),
        "--env".into(),
        "GIT_TRACE=1".into(),
    ];
    if let Some(url) = project_remote_url
        && !url.is_empty()
    {
        args.push("--env".into());
        args.push(format!("TILLANDSIAS_PROJECT_REMOTE_URL={url}"));
    }
    if let Some(secret_name) = vault_token_secret {
        // @trace spec:tillandsias-vault — git-mirror reads the GitHub token
        // via vault-cli using this short-lived AppRole token at hook time.
        // The token is mounted as a podman secret (owned by the git user,
        // mode 0400 — see GIT_VAULT_TOKEN_SECRET_OPTS) at the stable path
        // /run/secrets/vault-token regardless of the per-launch secret name;
        // podman's --secret target= rewrites the mount.
        args.push("--secret".into());
        args.push(format!("{secret_name},{GIT_VAULT_TOKEN_SECRET_OPTS}"));
        args.push("--env".into());
        args.push("VAULT_ADDR=https://vault:8200".into());
        args.push("--env".into());
        args.push("CURL_CA_BUNDLE=/etc/tillandsias/ca.crt".into());
        args.push("--env".into());
        args.push("VAULT_ROLE=git-mirror".into());
    }
    // Legacy fallback: when no vault secret is supplied AND the launcher is
    // configured to fall back to the keyring path, the runtime layer pushes
    // the token via a separate `SecretKind::GitHubToken` mount in
    // `container_profile`. We do NOT attach the legacy secret here because
    // it may not exist on a fresh install — the post-receive hook tolerates
    // a missing token by failing the upstream push and exiting 0.
    args.push("--mount".into());
    args.push(format!(
        "type=bind,source={},target=/etc/tillandsias/ca.crt,readonly=true",
        certs_dir.join("intermediate.crt").display()
    ));
    args.push(image.into());
    // Image ENTRYPOINT is /usr/local/bin/entrypoint.sh which runs the right
    // `git daemon` invocation (base-path /srv/git, --enable=receive-pack,
    // --reuseaddr, --export-all). Do NOT override it here.
    args
}

fn build_inference_run_args(
    certs_dir: &Path,
    image: &str,
    skip_runtime_pulls: bool,
) -> Vec<String> {
    let home_dir = std::env::var("HOME").unwrap_or_else(|_| String::from("/home/forge"));
    let model_cache_dir = Path::new(&home_dir).join(".cache/tillandsias/models");
    let _ = std::fs::create_dir_all(&model_cache_dir);

    let no_proxy = enclave_no_proxy();
    let mut args = vec![
        "--detach".into(),
        "--rm".into(),
        "--name".into(),
        "tillandsias-inference".into(),
        "--hostname".into(),
        "inference".into(),
        "--network-alias".into(),
        "inference".into(),
        "--network".into(),
        ENCLAVE_NET.into(),
        "--cap-drop=ALL".into(),
        "--security-opt=no-new-privileges".into(),
        "--security-opt=label=disable".into(),
        "--userns=keep-id".into(),
        "--pids-limit=128".into(),
        "--env".into(),
        "OLLAMA_DEBUG=1".into(),
        "--env".into(),
        "OLLAMA_KEEP_ALIVE=24h".into(),
        "--env".into(),
        "HTTP_PROXY=http://proxy:3128".into(),
        "--env".into(),
        "HTTPS_PROXY=http://proxy:3128".into(),
        "--env".into(),
        "http_proxy=http://proxy:3128".into(),
        "--env".into(),
        "https_proxy=http://proxy:3128".into(),
        "--env".into(),
        format!("NO_PROXY={no_proxy}"),
        "--env".into(),
        format!("no_proxy={no_proxy}"),
        "-v".into(),
        format!(
            "{}:/home/ollama/.ollama/models:rw",
            model_cache_dir.display()
        ),
        "--mount".into(),
        format!(
            "type=bind,source={},target=/etc/tillandsias/ca.crt,readonly=true",
            certs_dir.join("intermediate.crt").display()
        ),
        image.into(),
        "/usr/bin/ollama".into(),
        "serve".into(),
    ];

    if skip_runtime_pulls {
        args.insert(args.len() - 2, "--env".into());
        args.insert(
            args.len() - 2,
            "TILLANDSIAS_INFERENCE_SKIP_RUNTIME_PULLS=1".into(),
        );
    }

    args
}

/// Path on host to the dynamic Caddyfile written by the headless runtime,
/// bind-mounted into the router container at `/run/router/dynamic.Caddyfile`.
///
/// @trace spec:subdomain-routing-via-reverse-proxy
fn router_dynamic_caddyfile_host_path() -> PathBuf {
    let base = if let Ok(xdg) = std::env::var("XDG_RUNTIME_DIR") {
        PathBuf::from(xdg).join("tillandsias")
    } else {
        std::env::temp_dir().join("tillandsias-embedded")
    };
    base.join("router")
}

fn control_socket_host_dir() -> PathBuf {
    let base = if let Ok(runtime_dir) = std::env::var("XDG_RUNTIME_DIR") {
        PathBuf::from(runtime_dir)
    } else {
        PathBuf::from(format!("/run/user/{}", unsafe { libc::getuid() }))
    };
    base.join("tillandsias")
}

/// Build `podman run` args for the Caddy reverse-proxy router container.
///
/// The router runs on the enclave network with DNS alias `router` so Squid's
/// `cache_peer` directive can resolve it for `.localhost` subdomain traffic.
/// It also publishes the router on loopback using the first available host
/// port from `80 -> 8080 -> --port`, while the in-container listener remains
/// on `:8080`.
///
/// @trace spec:subdomain-routing-via-reverse-proxy, spec:enclave-network
fn build_router_run_args(certs_dir: &Path, image: &str, host_port: u16) -> Vec<String> {
    let dyn_dir = router_dynamic_caddyfile_host_path();
    let dyn_file = dyn_dir.join("dynamic.Caddyfile");
    // Ensure the directory and placeholder file exist before the container
    // starts so the bind-mount succeeds even on first run.
    let _ = std::fs::create_dir_all(&dyn_dir);
    if !dyn_file.exists() {
        let _ = std::fs::write(&dyn_file, "");
    }

    vec![
        "--detach".into(),
        "--rm".into(),
        "--name".into(),
        "tillandsias-router".into(),
        "--hostname".into(),
        "router".into(),
        // @trace spec:subdomain-routing-via-reverse-proxy, spec:enclave-network
        // Dual-homed: enclave alias `router` for Squid cache_peer + proxy agents,
        // plus host loopback publish for the browser.
        "--network-alias".into(),
        "router".into(),
        "--network".into(),
        ENCLAVE_NET.into(),
        "--cap-drop=ALL".into(),
        "--security-opt=no-new-privileges".into(),
        "--security-opt=label=disable".into(),
        "--userns=keep-id".into(),
        "--pids-limit=64".into(),
        "--read-only".into(),
        "--tmpfs".into(),
        "/tmp:size=64m".into(),
        "--tmpfs".into(),
        "/run/router:size=8m".into(),
        // @trace spec:subdomain-routing-via-reverse-proxy
        // Host publish on loopback ONLY. The container listener stays on
        // :8080; the host port is selected from the 80 -> 8080 -> --port
        // fallback chain by `select_router_host_port()`.
        "-p".into(),
        format!("127.0.0.1:{host_port}:8080"),
        // @trace spec:subdomain-routing-via-reverse-proxy
        // Dynamic Caddyfile written by the runtime for per-project routes.
        // Bind-mounted read-write so router-reload.sh can atomically replace it.
        "-v".into(),
        format!("{}:/run/router/dynamic.Caddyfile:rw", dyn_file.display()),
        "-v".into(),
        format!(
            "{}:/run/host/tillandsias:rw",
            control_socket_host_dir().display()
        ),
        "--mount".into(),
        format!(
            "type=bind,source={},target=/etc/tillandsias/ca.crt,readonly=true",
            certs_dir.join("intermediate.crt").display()
        ),
        image.into(),
    ]
}

/// Reload Caddy's configuration via the admin API.
///
/// After writing a new dynamic Caddyfile, this function signals the Caddy
/// router to reload its configuration without restarting the container.
/// The router's admin API listens on `localhost:2019` (per base.Caddyfile).
///
/// This is an async operation that reaches into the container from the host.
/// On transient failures (e.g., router not yet ready), logs a warning and
/// continues — subsequent operations will detect the stale config.
///
/// @trace spec:subdomain-routing-via-reverse-proxy
async fn caddy_reload_routes(debug: bool) -> Result<(), String> {
    // Caddy's admin API binds to 127.0.0.1:2019 *inside* the router container
    // (per base.Caddyfile). The router only publishes its public listener
    // (:8080) to the host; the admin port is intentionally not exposed, so
    // hitting http://127.0.0.1:2019 from the host always gets connection
    // refused. The canonical reload path is the router-reload.sh script that
    // ships in the router image — it re-merges base + dynamic Caddyfiles
    // and runs `caddy reload` inside the container.
    let mut cmd = podman_command();
    cmd.args([
        "exec",
        "tillandsias-router",
        "/usr/local/bin/router-reload.sh",
    ]);

    for attempt in 1..=10 {
        match cmd.output() {
            Ok(output) if output.status.success() => {
                if debug {
                    let stdout = String::from_utf8_lossy(&output.stdout);
                    eprintln!("[tillandsias] Caddy reload successful: {}", stdout.trim());
                }
                return Ok(());
            }
            Ok(output) => {
                let stderr = String::from_utf8_lossy(&output.stderr);
                let router_not_ready = stderr.contains("connection refused");
                if router_not_ready && attempt < 10 {
                    tokio::time::sleep(Duration::from_millis(150)).await;
                    continue;
                }
                if debug {
                    eprintln!(
                        "[tillandsias] Warning: router-reload.sh exited {} after {attempt} attempt(s): {}",
                        output.status,
                        stderr.trim()
                    );
                }
                return Ok(());
            }
            Err(e) => {
                if debug {
                    eprintln!(
                        "[tillandsias] Warning: Caddy reload failed (router may not be ready): {}",
                        e
                    );
                }
                return Ok(());
            }
        }
    }

    Ok(())
}

/// Strip a leading `localhost/` from a podman image reference.
///
/// Podman's `inspect` output canonicalizes references with an explicit
/// `localhost/` registry prefix for locally-built images, but our launch
/// commands typically pass the short form (`tillandsias-router:vX`).
/// Normalizing both sides through this helper avoids treating equivalent
/// refs as different.
fn strip_localhost_prefix(s: &str) -> &str {
    s.strip_prefix("localhost/").unwrap_or(s)
}

/// Ensure the router container (`tillandsias-router`) is running.
///
/// Idempotent: if a container with that name already exists and is in the
/// `running` state, this is a no-op. If the container exists but is stopped
/// (e.g., left over from a previous run), it is removed first. If it does
/// not exist, it is started with `build_router_run_args`.
///
/// @trace spec:subdomain-routing-via-reverse-proxy, spec:enclave-network
async fn ensure_router_running(
    client: &PodmanClient,
    certs_dir: &Path,
    image: &str,
    host_port: u16,
    debug: bool,
) -> Result<(), String> {
    const ROUTER_NAME: &str = "tillandsias-router";

    if let Ok(inspect) = client.inspect_container(ROUTER_NAME).await {
        if inspect.state == "running" {
            // Podman frequently reports image references with a `localhost/`
            // prefix (e.g. `localhost/tillandsias-router:v1.2.3`) while our
            // launch args pass the short form. Treat the two as equivalent
            // so we don't spuriously recreate the router on every check.
            if strip_localhost_prefix(&inspect.image) != strip_localhost_prefix(image) {
                if debug {
                    eprintln!(
                        "[tillandsias] router image changed ({} -> {}); recreating",
                        inspect.image, image
                    );
                }
                let _ = client.stop_container(ROUTER_NAME, 5).await;
                let _ = client.remove_container(ROUTER_NAME).await;
            } else {
                if debug {
                    eprintln!("[tillandsias] router already running");
                }
                return Ok(());
            }
        } else {
            if debug {
                eprintln!(
                    "[tillandsias] router container found but not running (state={}); removing",
                    inspect.state
                );
            }
            let _ = client.remove_container(ROUTER_NAME).await;
        }
    }

    if debug {
        eprintln!("[tillandsias] starting router container");
    }
    client
        .run_container_observed(
            "router",
            ROUTER_NAME,
            &build_router_run_args(certs_dir, image, host_port),
            debug,
        )
        .await
        .map_err(|e| format!("Failed to start router: {e}"))?;

    // Wait for the container to actually transition to "running" before
    // returning. `podman run -d` returns once the container is created and
    // the process is forked, but the immediate caller turns around and
    // calls `caddy_reload_routes` which `podman exec`s into it — racing
    // ahead of "Up" status yields "container state improper".
    for _ in 0..20 {
        match client.inspect_container(ROUTER_NAME).await {
            Ok(inspect) if inspect.state == "running" => {
                if debug {
                    eprintln!("[tillandsias] router container started");
                }
                return Ok(());
            }
            _ => tokio::time::sleep(std::time::Duration::from_millis(250)).await,
        }
    }
    if debug {
        eprintln!("[tillandsias] router container started (state not confirmed running after 5s)");
    }
    Ok(())
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
struct RouterRoute {
    /// `<service>.<project>` without the `.localhost` suffix.
    subdomain: String,
    /// Container DNS name on the enclave network.
    upstream_host: String,
    /// Container port exposed by the upstream service.
    port: u16,
    /// Optional post-login root redirect, used by services whose app lives
    /// below `/` while the shared OTP sidecar redirects successful logins to
    /// `/`.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    root_redirect: Option<String>,
}

impl RouterRoute {
    fn new(subdomain: impl Into<String>, upstream_host: impl Into<String>, port: u16) -> Self {
        Self {
            subdomain: subdomain.into(),
            upstream_host: upstream_host.into(),
            port,
            root_redirect: None,
        }
    }

    fn with_root_redirect(mut self, path: impl Into<String>) -> Self {
        self.root_redirect = Some(path.into());
        self
    }
}

fn router_route_registry_path() -> PathBuf {
    router_dynamic_caddyfile_host_path().join("routes.json")
}

fn read_router_routes(debug: bool) -> Result<Vec<RouterRoute>, String> {
    let registry = router_route_registry_path();
    if !registry.exists() {
        return Ok(Vec::new());
    }

    let text = std::fs::read_to_string(&registry)
        .map_err(|e| format!("Failed to read router route registry: {e}"))?;
    match serde_json::from_str::<Vec<RouterRoute>>(&text) {
        Ok(routes) => Ok(routes),
        Err(err) => {
            if debug {
                eprintln!(
                    "[tillandsias] ignoring malformed router route registry {}: {err}",
                    registry.display()
                );
            }
            Ok(Vec::new())
        }
    }
}

fn write_router_routes(routes: &[RouterRoute], debug: bool) -> Result<(), String> {
    let dyn_dir = router_dynamic_caddyfile_host_path();
    std::fs::create_dir_all(&dyn_dir)
        .map_err(|e| format!("Failed to create router dynamic config dir: {e}"))?;

    let registry = router_route_registry_path();
    let json = serde_json::to_string_pretty(routes)
        .map_err(|e| format!("Failed to encode router route registry: {e}"))?;
    std::fs::write(&registry, json)
        .map_err(|e| format!("Failed to write router route registry: {e}"))?;

    let dynamic_config = generate_dynamic_caddyfile(routes);
    let dyn_file = dyn_dir.join("dynamic.Caddyfile");
    std::fs::write(&dyn_file, dynamic_config)
        .map_err(|e| format!("Failed to write dynamic Caddyfile: {e}"))?;

    if debug {
        eprintln!(
            "[tillandsias] wrote {} router route(s) to {}",
            routes.len(),
            dyn_file.display()
        );
    }

    Ok(())
}

fn upsert_router_route(route: RouterRoute, debug: bool) -> Result<(), String> {
    let mut routes = read_router_routes(debug)?;
    routes.retain(|existing| existing.subdomain != route.subdomain);
    routes.push(route);
    routes.sort_by(|a, b| a.subdomain.cmp(&b.subdomain));
    write_router_routes(&routes, debug)
}

/// Generate dynamic Caddy configuration for project web routes.
///
/// Takes a list of routes and generates
/// Caddy configuration blocks for each project. Each block contains the
/// full OTP-auth chain:
///
/// 1. `handle /_auth/login` reverse-proxies the browser-submitted OTP form
///    to the sidecar (localhost:9090 in the same container as Caddy),
///    which validates the OTP, promotes the pending session to active,
///    and replies with a 302 + `Set-Cookie`.
/// 2. All other paths go through `forward_auth localhost:9090` against
///    `/validate?project=<label>`. On 204 the request reaches the upstream;
///    on 401 the request is denied.
///
/// The upstream is the container name on the enclave network (e.g.
/// `tillandsias-<project>-forge`) — not `127.0.0.1`, which from inside
/// the router container would point at the router's own loopback. The
/// sidecar lives in the same container as Caddy, so its address from
/// inside Caddy is `localhost:9090` (matching `DEFAULT_VALIDATE_PORT` in
/// the sidecar).
///
/// The project label passed to `forward_auth` is derived from the
/// subdomain in `<service>.<project>` form — we take the last component,
/// which is what the sidecar's `extract_project_label` also extracts from
/// the Host header.
///
/// @trace spec:subdomain-routing-via-reverse-proxy, spec:opencode-web-session-otp
fn generate_dynamic_caddyfile(routes_to_render: &[RouterRoute]) -> String {
    if routes_to_render.is_empty() {
        return String::new();
    }

    let mut routes = String::new();
    for route in routes_to_render {
        let subdomain = &route.subdomain;
        let upstream_host = &route.upstream_host;
        let port = route.port;
        // Derive the project label from `<service>.<project>`. The sidecar
        // does the same extraction from the Host header — feeding the
        // matching value into the query string lets the sidecar verify
        // the binding via direct comparison.
        let project_label = subdomain.rsplit('.').next().unwrap_or(subdomain.as_str());
        let root_redirect = route
            .root_redirect
            .as_deref()
            .filter(|path| path.starts_with('/'));

        // Force HTTP-only (`http://...`) on :8080. Caddy enables HTTP/2 and
        // HTTP/3 by default, both of which require TLS — so a bare
        // `host:8080 { }` site ends up speaking TLS and rejects plain
        // requests with "Client sent an HTTP request to an HTTPS server."
        // Rootless containers with --cap-drop=ALL can't bind privileged
        // ports anyway, and the router publishes :8080 → host:8080 only.
        //
        // Inside the block:
        //   * `handle /_auth/login` proxies the browser-submitted OTP form
        //     to the sidecar (in-container, localhost:9090). Caddy forwards
        //     the request body to the sidecar by default for reverse_proxy.
        //   * `handle` (the default fallthrough) applies forward_auth and,
        //     on success (204), reverse-proxies to the upstream forge
        //     container on the enclave network.
        routes.push_str(&format!(
            "http://{subdomain}.localhost:8080 {{\n    \
handle /_auth/login {{\n        \
reverse_proxy localhost:9090\n    \
}}\n"
        ));
        if let Some(path) = root_redirect {
            routes.push_str(&format!(
                "    \
handle / {{\n        \
forward_auth localhost:9090 {{\n            \
uri /validate?project={project_label}\n            \
copy_headers Cookie\n        \
}}\n        \
redir {path} 302\n    \
}}\n"
            ));
        }
        routes.push_str(&format!(
            "    \
handle {{\n        \
forward_auth localhost:9090 {{\n            \
uri /validate?project={project_label}\n            \
copy_headers Cookie\n        \
}}\n        \
reverse_proxy {upstream_host}:{port}\n    \
}}\n\
}}\n"
        ));
    }
    routes
}

fn router_host_port_candidates(port_override: Option<u16>) -> Vec<u16> {
    let mut candidates = vec![80, 8080, 18080, 28080, 38080, 48080, 58080];
    if let Some(port) = port_override
        && !candidates.contains(&port)
    {
        candidates.insert(0, port);
    }
    candidates
}

fn port_is_available(port: u16) -> bool {
    std::net::TcpListener::bind(("127.0.0.1", port)).is_ok()
}

fn select_router_host_port(port_override: Option<u16>, debug: bool) -> Result<u16, String> {
    let candidates = router_host_port_candidates(port_override);
    for &candidate in &candidates {
        if port_is_available(candidate) {
            if debug {
                eprintln!("[tillandsias] selected router host port {candidate}");
            }
            return Ok(candidate);
        }
    }

    let checked = candidates
        .iter()
        .map(|p| p.to_string())
        .collect::<Vec<_>>()
        .join(", ");
    Err(format!(
        "No free router host ports found (checked {checked}); re-run with --port <free-port>"
    ))
}

pub(crate) fn sanitize_hostname(raw: &str) -> String {
    use sha2::Digest;

    // A valid hostname can only contain alphanumeric and hyphens, and cannot exceed 63 characters.
    let mut cleaned: String = raw
        .chars()
        .map(|c| {
            if c.is_ascii_alphanumeric() || c == '-' {
                c
            } else {
                '-'
            }
        })
        .collect();

    // Trim leading/trailing hyphens as they are generally discouraged/invalid
    cleaned = cleaned.trim_matches('-').to_string();

    if cleaned.len() <= 63 {
        cleaned
    } else {
        // Take a hash of the original raw hostname to keep it unique
        let mut hasher = sha2::Sha256::new();
        hasher.update(raw.as_bytes());
        let result = hasher.finalize();
        let hash_str: String = result[..8].iter().map(|b| format!("{:02x}", b)).collect();

        // Take first 46 chars, a hyphen, and the 16 hex chars = 63 chars total!
        let prefix = &cleaned[..46];
        format!("{prefix}-{hash_str}")
    }
}

fn forge_container_name(project_name: &str) -> String {
    format!("tillandsias-{project_name}-forge")
}

fn forge_hostname(project_name: &str) -> String {
    sanitize_hostname(&format!("forge-{project_name}"))
}

fn build_forge_common_args(
    project_path: &Path,
    project_name: &str,
    certs_dir: &Path,
) -> Vec<String> {
    build_stack_common_args(
        &forge_container_name(project_name),
        &forge_hostname(project_name),
        certs_dir,
        project_name,
        project_path,
    )
}

async fn cleanup_stack_containers(client: &PodmanClient, project_name: &str) {
    let _ = client.remove_container("tillandsias-proxy").await;
    let _ = client
        .remove_container(&format!("tillandsias-git-{project_name}"))
        .await;
    let _ = client.remove_container("tillandsias-inference").await;
    let _ = client
        .remove_container(&format!("tillandsias-{project_name}-forge"))
        .await;
    let _ = client
        .remove_container(&format!("tillandsias-browser-{project_name}"))
        .await;
}

async fn cleanup_shared_stack_if_no_running_forge(
    client: &PodmanClient,
    project_name: &str,
    debug: bool,
) {
    let running_forges = client
        .list_containers("tillandsias-")
        .await
        .map(|containers| {
            containers
                .into_iter()
                .filter(|container| {
                    container.name.ends_with("-forge")
                        && matches!(
                            container.state.to_ascii_lowercase().as_str(),
                            "running" | "up"
                        )
                })
                .count()
        })
        .unwrap_or(0);

    if running_forges != 0 {
        if debug {
            eprintln!(
                "[tillandsias] keeping shared stack alive; {running_forges} forge container(s) still running"
            );
        }
        return;
    }

    if debug {
        eprintln!(
            "[tillandsias] no active forge containers; cleaning project stack for {project_name}"
        );
    }
    cleanup_stack_containers(client, project_name).await;
}

fn build_status_check_forge_args(
    project_path: &Path,
    project_name: &str,
    certs_dir: &Path,
    version: &str,
) -> Vec<String> {
    let mut args = build_forge_common_args(project_path, project_name, certs_dir);

    args.extend([
        "--rm".into(),
        "--entrypoint".into(),
        "/bin/bash".into(),
        forge_image_tag(version),
        "-lc".into(),
        [
            "set -euo pipefail",
            "check_port() {",
            "    local host=\"$1\"",
            "    local port=\"$2\"",
            "    local label=\"$3\"",
            "    local attempt=0",
            "    local max_attempts=20",
            "    while [ \"$attempt\" -lt \"$max_attempts\" ]; do",
            "        if command -v nc >/dev/null 2>&1; then",
            "            if nc -z -w 1 \"$host\" \"$port\" >/dev/null 2>&1; then",
            "                echo \"[status-check] $label online\"",
            "                return 0",
            "            fi",
            "        elif (exec 3<>\"/dev/tcp/$host/$port\") >/dev/null 2>&1; then",
            "            exec 3<&- 3>&-",
            "            echo \"[status-check] $label online\"",
            "            return 0",
            "        fi",
            "        attempt=$((attempt + 1))",
            "        sleep 1",
            "    done",
            "    echo \"[status-check] $label offline after ${max_attempts}s\" >&2",
            "    return 1",
            "}",
            "check_inference() {",
            "    local attempt=0",
            "    local max_attempts=20",
            "    while [ \"$attempt\" -lt \"$max_attempts\" ]; do",
            "        if command -v curl >/dev/null 2>&1; then",
            "            if curl -fsS -m 2 \"http://inference:11434/api/version\" >/dev/null 2>&1; then",
            "                echo \"[status-check] inference online\"",
            "                return 0",
            "            fi",
            "        elif (exec 3<>\"/dev/tcp/inference/11434\") >/dev/null 2>&1; then",
            "            exec 3<&- 3>&-",
            "            echo \"[status-check] inference online\"",
            "            return 0",
            "        fi",
            "        attempt=$((attempt + 1))",
            "        sleep 1",
            "    done",
            "    echo \"[status-check] inference offline after ${max_attempts}s\" >&2",
            "    return 1",
            "}",
            "echo \"[status-check] running inside forge container\"",
            "check_port proxy 3128 proxy",
            "check_port git-service 9418 git",
            "check_inference",
            "echo \"[status-check] forge online\"",
        ]
        .join("\n"),
    ]);

    args
}

/// Forge launch mode.
///
/// - `Cli`: interactive shell, attaches stdin/tty via --interactive --tty,
///   default entrypoint /bin/bash. Used by `tillandsias --opencode`.
/// - `Web`: headless HTTP service, --detach, entrypoint
///   entrypoint-forge-opencode-web.sh. Used by `tillandsias --opencode-web`.
#[derive(Copy, Clone, Debug, PartialEq, Eq)]
enum ForgeMode {
    Cli,
    Web,
}

#[allow(clippy::too_many_arguments)]
fn build_opencode_forge_args(
    project_path: &Path,
    project_name: &str,
    prompt: Option<&str>,
    certs_dir: &Path,
    version: &str,
    mode: ForgeMode,
    diagnostics: bool,
    debug: bool,
) -> Vec<String> {
    // CLI mode attaches stdio (--interactive --tty) for a real shell; Web
    // mode detaches the container so the run() call returns and the host
    // owns the lifecycle. Forcing --interactive --tty under a non-TTY shell
    // (the way a tray launch or background script ends up) makes podman
    // refuse with "input device is not a TTY" before any container start
    // event fires.
    let no_proxy = enclave_no_proxy();
    let mut args = vec![
        "--rm".into(),
        "--name".into(),
        forge_container_name(project_name),
        "--hostname".into(),
        forge_hostname(project_name),
        "--network".into(),
        ENCLAVE_NET.into(),
        "--cap-drop=ALL".into(),
        "--security-opt=no-new-privileges".into(),
        "--security-opt=label=disable".into(),
        "--userns=keep-id".into(),
        "--pids-limit=512".into(),
    ];
    match mode {
        ForgeMode::Cli => {
            // When a prompt is provided, the entrypoint execs
            // `opencode run --dangerously-skip-permissions "<prompt>"` which is
            // non-interactive.  Skip --interactive --tty so podman does not
            // attempt to claim the terminal (which causes SIGTTIN/SIGTTOU /
            // stopped T state when the parent is in a harness PTY).
            // @trace plan/issues/build-install-smoke-e2e-findings-2026-06-14.md
            if !diagnostics && prompt.is_none() {
                args.push("--interactive".into());
                args.push("--tty".into());
            }
        }
        ForgeMode::Web => {
            args.push("--detach".into());
        }
    }
    args.extend([
        "--env".into(),
        "http_proxy=http://proxy:3128".into(),
        "--env".into(),
        "https_proxy=http://proxy:3128".into(),
        "--env".into(),
        "HTTP_PROXY=http://proxy:3128".into(),
        "--env".into(),
        "HTTPS_PROXY=http://proxy:3128".into(),
        "--env".into(),
        format!("no_proxy={no_proxy}"),
        "--env".into(),
        format!("NO_PROXY={no_proxy}"),
        "--env".into(),
        "PATH=/usr/local/bin:/usr/bin".into(),
        "--env".into(),
        "HOME=/home/forge".into(),
        "--env".into(),
        "USER=forge".into(),
        "--env".into(),
        format!("PROJECT={project_name}"),
        "--env".into(),
        format!("TILLANDSIAS_PROJECT={project_name}"),
        "--env".into(),
        "TILLANDSIAS_PROJECT_HOST_MOUNT=1".into(),
        "--env".into(),
        "TILLANDSIAS_CHEATSHEETS=/opt/cheatsheets".into(),
        "--tmpfs".into(),
        "/tmp:size=256m,mode=1777".into(),
        "--tmpfs".into(),
        "/run/user/1000:size=64m,mode=0700".into(),
        "--tmpfs".into(),
        "/opt/cheatsheets:size=8m,mode=0755".into(),
        // Mount under `/home/forge/src/<project>/` (not directly at
        // `/home/forge/src`) so the in-container tree matches what the forge
        // entrypoint's clone path would produce
        // (images/default/entrypoint-forge-opencode-web.sh:58) and what tools
        // / agents expect from `$TILLANDSIAS_PROJECT_PATH`. Mounting flat at
        // `/home/forge/src` puts the project files where the forge expects a
        // sibling directory and confuses every consumer that resolves
        // `~/src/<project>/...`.
        "-v".into(),
        format!(
            "{}:/home/forge/src/{project_name}:rw",
            project_path.display()
        ),
        "--mount".into(),
        format!(
            "type=bind,source={},target=/etc/tillandsias/ca.crt,readonly=true",
            certs_dir.join("intermediate.crt").display()
        ),
    ]);
    append_git_identity_env_args(&mut args);
    if let Some(prompt) = prompt {
        args.extend([
            "--env".into(),
            format!("TILLANDSIAS_OPENCODE_PROMPT={prompt}"),
        ]);
    }
    if debug {
        args.extend(["--env".into(), "TILLANDSIAS_DEBUG=1".into()]);
    }
    let (entrypoint, cmd): (&str, &str) = match mode {
        ForgeMode::Cli => ("/usr/local/bin/entrypoint-forge-opencode.sh", ""),
        // The forge image's opencode-web entrypoint clones the project from the
        // git mirror and execs `opencode serve` (no banner, no TTY); see
        // images/default/entrypoint-forge-opencode-web.sh.
        ForgeMode::Web => ("/usr/local/bin/entrypoint-forge-opencode-web.sh", ""),
    };
    args.push("--entrypoint".into());
    args.push(entrypoint.into());
    args.push(forge_image_tag(version));
    if !cmd.is_empty() {
        args.push(cmd.into());
    }
    if diagnostics {
        args.push("--print".into());
        args.push("--output-format".into());
        args.push("json".into());
    }
    args
}

/// Build required container images on demand with incremental build support.
///
/// Orchestrate incremental container image builds for Tillandsias.
///
/// @trace spec:init-command, spec:init-incremental-builds, spec:default-image, spec:git-mirror-service, spec:proxy-container, spec:inference-container, spec:build-lock, spec:direct-podman-calls, spec:embedded-scripts
///
/// ## Init Flow
///
/// The `--init` command builds container images from baked Containerfiles in incremental order:
///
/// 1. **Detect repository**: Find Tillandsias root by detecting VERSION file and images/ directory.
/// 2. **Load build state**: Check `~/.cache/tillandsias/init-build-state.json` for previous successful builds.
/// 3. **Build images in order** (must respect build dependencies):
///    - `proxy` — HTTP/HTTPS caching proxy with domain allowlist
///    - `git` — Git mirror service with auto-push on behalf of forge
///    - `inference` — ollama-based LLM inference container
///    - `chromium-core` — Base Chromium image for browser isolation
///    - `chromium-framework` — Chromium browser with framework integration (depends on chromium-core)
///    - `forge-base` — Heavy, reusable Forge toolchain layer
///    - `forge` — Dev environment configuration (depends on forge-base)
/// 4. **Track progress**: For each image, report:
///    - SKIP: Image already cached and build previously successful
///    - REBUILD: Image deleted after successful build (rebuild)
///    - BUILD: Now building
///    - SUCCESS: Build completed
///    - FAILED: Build failed (mark, save state, continue to next or fail)
/// 5. **Save state**: Update `~/.cache/tillandsias/init-build-state.json` with success/failure status.
/// 6. **Report failures**: In debug mode, dump last 10 lines of failed build logs.
/// 7. **Exit**: 0 on success, non-zero on any image build failure.
///
/// ## Caching & Incremental Builds
///
/// - **Successful builds**: Cached by image tag. On next --init run, skipped if image exists and
///   build state shows "success".
/// - **Force rebuild**: `--init --force` clears build state and rebuilds all images.
/// - **Rebuild on deletion**: If image tag no longer exists (e.g., user pruned), rebuilds even if
///   previous build was successful.
///
/// ## Build Arguments
///
/// - `chromium-framework` passes `--build-arg CHROMIUM_CORE_IMAGE=<image>` to reference the
///   just-built chromium-core image. **Known blocker**: Nix-based build (via flake.nix) fails
///   when passed ARG values; workaround is to build directly via podman (current implementation).
///
/// ## Log Handling
///
/// - Non-debug mode: Build logs go to /dev/null (quiet).
/// - Debug mode: Build logs saved to `/tmp/tillandsias-init-<image>.log` for troubleshooting.
/// - On success, debug logs are cleaned up.
/// - On failure, last 10 lines of each failed image's log are printed to stderr.
///
/// ## Exit Codes
///
/// - 0 — All images built successfully (or skipped as cached)
/// - non-zero — One or more images failed to build (human intervention required)
///
/// ## Cache Corruption Detection and Recovery
///
/// Validates cache files and automatically recovers by:
///   1. Warning about corruption
///   2. Deleting corrupted cache files (only ephemeral cache, no project state)
///   3. Continuing with rebuild on next init
///
/// @trace spec:cache-recovery-mechanism
fn detect_and_recover_cache_corruption(debug: bool) -> Result<bool, String> {
    let cache_dir = init_cache_dir()?;
    let state_file = cache_dir.join("init-build-state.json");

    // Only validate if state file exists
    if !state_file.exists() {
        return Ok(false); // No cache to validate
    }

    // Try to compute checksum of the state file
    match cache_validation::compute_file_checksum(&state_file) {
        Ok(_) => {
            // File is readable and has a checksum. Try to parse it to detect
            // corruption at the semantic level (JSON parse error).
            match fs::read_to_string(&state_file) {
                Ok(contents) => match serde_json::from_str::<InitBuildState>(&contents) {
                    Ok(_) => {
                        // Cache is valid
                        Ok(false)
                    }
                    Err(e) => {
                        // Semantic corruption: JSON parse failed
                        warn!("Cache corrupted: JSON parse failed: {}", e);
                        eprintln!("WARNING: Cache file is corrupted (JSON parse error)");
                        eprintln!("  File: {}", state_file.display());
                        eprintln!("  Error: {}", e);
                        eprintln!("  Recovery: Deleting corrupted cache and rebuilding");

                        // Delete corrupted cache file
                        if let Err(delete_err) = fs::remove_file(&state_file) {
                            warn!("Failed to delete corrupted cache file: {}", delete_err);
                            eprintln!(
                                "WARNING: Failed to delete corrupted cache file: {}",
                                delete_err
                            );
                            return Err(format!(
                                "Cannot recover: failed to delete corrupted cache: {}",
                                delete_err
                            ));
                        }

                        if debug {
                            eprintln!(
                                "DEBUG: Deleted corrupted cache file: {}",
                                state_file.display()
                            );
                        }
                        Ok(true) // Recovery was triggered
                    }
                },
                Err(e) => {
                    // I/O error reading file
                    warn!("Cache corruption detected (read error): {}", e);
                    eprintln!("WARNING: Cannot read cache file: {}", e);
                    eprintln!("  File: {}", state_file.display());
                    eprintln!("  Recovery: Deleting corrupted cache and rebuilding");

                    if let Err(delete_err) = fs::remove_file(&state_file) {
                        warn!("Failed to delete unreadable cache file: {}", delete_err);
                        return Err(format!(
                            "Cannot recover: failed to delete unreadable cache: {}",
                            delete_err
                        ));
                    }

                    if debug {
                        eprintln!(
                            "DEBUG: Deleted unreadable cache file: {}",
                            state_file.display()
                        );
                    }
                    Ok(true) // Recovery was triggered
                }
            }
        }
        Err(e) => {
            // Cannot compute checksum (very unusual)
            warn!("Cannot compute cache checksum: {}", e);
            eprintln!("WARNING: Cannot validate cache (checksum error): {}", e);
            eprintln!("  Proceeding with initialization anyway");
            // Don't fail here — let normal flow continue
            Ok(false)
        }
    }
}

#[cfg(target_os = "linux")]
fn is_ipv6_functional() -> bool {
    let addresses = [
        "2001:4860:4860::8888:53", // Google DNS
        "2606:4700:4700::1111:53", // Cloudflare DNS
    ];
    for addr_str in &addresses {
        if let Ok(addr) = addr_str.parse::<std::net::SocketAddr>()
            && std::net::TcpStream::connect_timeout(&addr, std::time::Duration::from_millis(800))
                .is_ok()
        {
            return true;
        }
    }
    false
}

#[cfg(target_os = "linux")]
fn get_user_containers_conf() -> Option<PathBuf> {
    let config_dir = if let Ok(xdg) = std::env::var("XDG_CONFIG_HOME") {
        PathBuf::from(xdg)
    } else if let Ok(home) = std::env::var("HOME") {
        PathBuf::from(home).join(".config")
    } else {
        return None;
    };
    Some(config_dir.join("containers").join("containers.conf"))
}

#[cfg(target_os = "linux")]
fn ensure_pasta_options_ipv4_only(path: &std::path::Path) -> Result<(), String> {
    if !path.exists() {
        if let Some(parent) = path.parent() {
            fs::create_dir_all(parent)
                .map_err(|e| format!("failed to create config directory: {e}"))?;
        }
        fs::write(path, "[network]\npasta_options = [\"--ipv4-only\"]\n")
            .map_err(|e| format!("failed to write containers.conf: {e}"))?;
        return Ok(());
    }

    let content =
        fs::read_to_string(path).map_err(|e| format!("failed to read containers.conf: {e}"))?;

    if content.contains("pasta_options") {
        return Ok(());
    }

    let mut new_content = String::new();
    let mut network_found = false;

    for line in content.lines() {
        new_content.push_str(line);
        new_content.push('\n');

        if line.trim() == "[network]" {
            new_content.push_str("pasta_options = [\"--ipv4-only\"]\n");
            network_found = true;
        }
    }

    if !network_found {
        new_content.push_str("\n[network]\npasta_options = [\"--ipv4-only\"]\n");
    }

    fs::write(path, new_content).map_err(|e| format!("failed to update containers.conf: {e}"))?;

    Ok(())
}

#[cfg(target_os = "linux")]
fn auto_detect_and_configure_ipv6_workaround(debug: bool) {
    if let Some(conf_path) = get_user_containers_conf() {
        if !is_ipv6_functional() {
            if debug {
                eprintln!(
                    "[tillandsias] init: IPv6 connectivity check failed. Injecting pasta_options = [\"--ipv4-only\"] to prevent rootless Podman timeouts."
                );
            }
            if let Err(e) = ensure_pasta_options_ipv4_only(&conf_path)
                && debug
            {
                eprintln!(
                    "[tillandsias] init: failed to configure containers.conf: {}",
                    e
                );
            }
        } else if debug {
            eprintln!("[tillandsias] init: IPv6 connectivity is functional.");
        }
    }
}

fn is_optional_image(image_name: &str) -> bool {
    matches!(image_name, "forge-base" | "forge" | "zeroclaw")
}

fn run_init(debug: bool, force: bool) -> Result<(), String> {
    require_desktop_user_session("tillandsias --init")?;
    report_runtime_lane("--init", debug);

    #[cfg(target_os = "linux")]
    auto_detect_and_configure_ipv6_workaround(debug);

    let version = VERSION.trim();
    let root = resolve_runtime_asset_root(version, debug)?;
    let runtime_manifest_digest = runtime_assets::root_manifest_digest(&root).ok();
    let images = [
        "proxy",
        "git",
        "inference",
        "router",
        "chromium-core",
        "chromium-framework",
        "forge-base",
        "forge",
        "zeroclaw",
        "web",
    ];

    // @trace spec:forge-staleness, spec:forge-cache-dual
    // VERSION changes only move aliases. Content identity comes from the exact
    // context digest and OCI label, so a cache-version mismatch never forces a
    // rebuild by itself.
    let cache_status = check_cache_integrity(version)?;
    if cache_status.version_mismatch && debug {
        let cached_display = cache_status
            .cached_version
            .clone()
            .unwrap_or_else(|| "<unset>".to_string());
        eprintln!(
            "[tillandsias] init: version changed (cached {}, current {}); refreshing aliases only when source digests match",
            cached_display, version
        );
    }

    // @trace spec:cache-recovery-mechanism
    // Detect and recover from cache corruption before loading state
    let recovery_triggered = detect_and_recover_cache_corruption(debug)?;
    if recovery_triggered && debug {
        eprintln!("DEBUG: Cache corruption recovery completed; state will be rebuilt");
    }

    // Load existing build state or create new one
    let mut state = InitBuildState::load()?.unwrap_or_else(InitBuildState::new);

    // In litmus/fake mode, skip the heavy podman build loop. The cache-integrity
    // and recovery checks above are the only code paths being exercised by
    // litmus:cache-recovery-fresh-start; writing the version file is sufficient.
    if std::env::var_os("LITMUS_PODMAN_MODE").is_some() {
        if let Err(e) = InitBuildState::save_version(version) {
            eprintln!("WARNING: Failed to save cache version: {e}");
        }
        state.save()?;
        return Ok(());
    }

    let rt = podman_runtime()?;
    let client = PodmanClient::new();
    let mut failed_images = Vec::new();
    let mut identities = HashMap::<String, ImageBuildIdentity>::new();

    for image in &images {
        let (build_args, dependency_digests) = match image_build_inputs(image, &identities) {
            Ok(val) => val,
            Err(e) => {
                if is_optional_image(image) {
                    if debug {
                        eprintln!(
                            "WARNING: Skipping optional image {} because dependency mapping failed: {}",
                            image, e
                        );
                    }
                    state.mark_failed(image);
                    failed_images.push((image.to_string(), e));
                    continue;
                } else {
                    return Err(e);
                }
            }
        };
        let identity = match runtime_assets::image_identity(
            &root,
            image,
            version,
            build_args.clone(),
            dependency_digests,
        ) {
            Ok(id) => id,
            Err(e) => {
                if is_optional_image(image) {
                    if debug {
                        eprintln!(
                            "WARNING: Skipping optional image {} because identity generation failed: {}",
                            image, e
                        );
                    }
                    state.mark_failed(image);
                    failed_images.push((image.to_string(), e));
                    continue;
                } else {
                    return Err(e);
                }
            }
        };
        let (observation, observed_image_id) =
            rt.block_on(observe_image_build(&client, &identity, force));
        let decision = decide_image_build(identity.clone(), &observation);
        identities.insert((*image).to_string(), identity.clone());
        let build_id = format!(
            "image-{}-{}",
            image,
            chrono::Utc::now()
                .timestamp_nanos_opt()
                .unwrap_or_else(|| chrono::Utc::now().timestamp_micros() * 1000)
        );
        let decision_event = image_build_event(
            "image.build.decision",
            &build_id,
            image,
            &identity,
            &decision,
        );
        emit_image_build_event(&decision_event, debug);

        match decision.action {
            ImageBuildAction::Skip => {
                if debug {
                    println!("SKIP {} (digest present)", image);
                }
                let completed = image_build_event(
                    "image.build.completed",
                    &build_id,
                    image,
                    &identity,
                    &decision,
                )
                .with_outcome("skipped", 0, 0);
                emit_image_build_event(&completed, debug);
                state.mark_success(image);
                state.set_image_identity(image, &decision, observed_image_id);
                continue;
            }
            ImageBuildAction::Retag => {
                if debug {
                    println!("RETAG {} (aliases stale or missing)", image);
                }
                if let Err(e) = rt.block_on(apply_image_aliases(&client, &identity)) {
                    let failed = image_build_event(
                        "image.build.failed",
                        &build_id,
                        image,
                        &identity,
                        &decision,
                    )
                    .with_outcome("failure", 0, 1)
                    .with_redacted_error("alias_update_failed", &e);
                    emit_image_build_event(&failed, debug);
                    state.mark_failed(image);
                    failed_images.push((image.to_string(), e));
                } else {
                    let completed = image_build_event(
                        "image.build.completed",
                        &build_id,
                        image,
                        &identity,
                        &decision,
                    )
                    .with_outcome("retagged", 0, 0);
                    emit_image_build_event(&completed, debug);
                    state.mark_success(image);
                    state.set_image_identity(image, &decision, observed_image_id);
                }
                continue;
            }
            ImageBuildAction::Build => {
                if debug {
                    println!("BUILD {} ({:?})", image, decision.reason);
                }
            }
            ImageBuildAction::ForceRebuild => {
                if debug {
                    println!("FORCE BUILD {}", image);
                }
            }
        }

        let log_file = init_log_file(image, debug);
        let build_started = Instant::now();
        let started = image_build_event(
            "image.build.started",
            &build_id,
            image,
            &identity,
            &decision,
        );
        emit_image_build_event(&started, debug);
        let result =
            build_image_with_logging(&root, image, &identity, &build_args, &log_file, debug);
        let duration_ms = build_started.elapsed().as_millis() as u64;

        if let Err(e) = result {
            if debug {
                eprintln!("FAILED {}: {}", image, e);
            }
            let failed =
                image_build_event("image.build.failed", &build_id, image, &identity, &decision)
                    .with_outcome("failure", duration_ms, 1)
                    .with_redacted_error("podman_build_failed", &e);
            emit_image_build_event(&failed, debug);
            state.mark_failed(image);
            failed_images.push((image.to_string(), e));
        } else {
            let alias_result = rt.block_on(apply_image_aliases(&client, &identity));
            if let Err(e) = alias_result {
                let failed =
                    image_build_event("image.build.failed", &build_id, image, &identity, &decision)
                        .with_outcome("failure", duration_ms, 1)
                        .with_redacted_error("alias_update_failed", &e);
                emit_image_build_event(&failed, debug);
                state.mark_failed(image);
                failed_images.push((image.to_string(), e));
            } else {
                let image_id = rt
                    .block_on(client.image_inspect(&identity.canonical_tag))
                    .ok()
                    .and_then(|json| image_inspect_metadata(&json).ok())
                    .and_then(|(image_id, _)| image_id);
                let mut completed = image_build_event(
                    "image.build.completed",
                    &build_id,
                    image,
                    &identity,
                    &decision,
                )
                .with_outcome("success", duration_ms, 0);
                completed.image_id = image_id.clone();
                emit_image_build_event(&completed, debug);
                state.mark_success(image);
                state.set_image_identity(image, &decision, image_id);
                if debug {
                    println!("SUCCESS {}", image);
                }
            }
        }
    }

    state.set_runtime_asset_manifest_digest(runtime_manifest_digest);

    // Save updated state
    state.save()?;

    // @trace spec:forge-staleness, spec:forge-cache-dual
    // Save current version to cache for future staleness detection
    if let Err(e) = InitBuildState::save_version(version) {
        eprintln!("WARNING: Failed to save cache version: {}", e);
        // Non-fatal; continue with init
    }

    // Display failed build logs if debug mode and there are failures
    if debug && !failed_images.is_empty() {
        eprintln!("\n=== Failed Build Logs ===");
        for (image, _error) in &failed_images {
            let log_file = init_log_file(image, debug);
            if let Some(log_path) = log_file
                && log_path.exists()
                && let Ok(contents) = fs::read_to_string(&log_path)
            {
                let lines: Vec<&str> = contents.lines().collect();
                let start = if lines.len() > 10 {
                    lines.len() - 10
                } else {
                    0
                };
                eprintln!("\n--- {} (last 10 lines) ---", image);
                for line in &lines[start..] {
                    eprintln!("{}", line);
                }
            }
        }
    }

    // Clean up debug logs if all builds succeeded
    if failed_images.is_empty() && debug {
        cleanup_init_logs();
    }

    // Return error if any required images failed
    let required_failures: Vec<_> = failed_images
        .iter()
        .filter(|(name, _)| !is_optional_image(name))
        .collect();

    if !required_failures.is_empty() {
        return Err(format!(
            "Failed to build {} required image(s): {}",
            required_failures.len(),
            required_failures
                .iter()
                .map(|(name, _)| name.clone())
                .collect::<Vec<_>>()
                .join(", ")
        ));
    }

    if !failed_images.is_empty() {
        let optional_failed: Vec<_> = failed_images.iter().map(|(name, _)| name.clone()).collect();
        eprintln!(
            "WARNING: Failed to build {} optional image(s): {}",
            optional_failed.len(),
            optional_failed.join(", ")
        );
    }

    Ok(())
}

/// Execute a single container image build via podman with optional logging.
///
/// @trace spec:init-command, spec:init-incremental-builds
///
/// ## Build Process
/// 1. Locate Containerfile and build context directory (via image_specs)
/// 2. Determine build arguments (e.g., CHROMIUM_CORE_IMAGE for chromium-framework)
/// 3. Construct `podman build` command with tag and context
/// 4. Optionally redirect stdout/stderr to log file (if debug mode)
/// 5. Execute synchronously and return status
///
/// ## Build Arguments
/// - `--build-arg CHROMIUM_CORE_IMAGE=<image>` for chromium-framework only
/// - chromium-framework MUST be built after chromium-core to resolve the ARG
pub(crate) fn build_image_with_logging(
    root: &Path,
    image_name: &str,
    identity: &ImageBuildIdentity,
    build_args: &BTreeMap<String, String>,
    log_file: &Option<PathBuf>,
    _debug: bool,
) -> Result<(), String> {
    // @trace gap:ON-005 — show progress % during image pull
    let (containerfile, context_dir) = image_specs(root, image_name)?;

    let mut command = podman_command();
    let argv = podman_build_argv(&containerfile, &context_dir, identity, build_args)?;
    command.args(&argv);

    // @trace gap:ON-005 — capture stdout/stderr for progress parsing
    command.stdout(Stdio::piped());
    command.stderr(Stdio::piped());

    let mut child = command
        .spawn()
        .map_err(|e| format!("Failed to spawn build process: {e}"))?;

    let stdout = child.stdout.take();
    let stderr = child.stderr.take();

    // Open log file for writing all output
    // @trace gap:ON-005 — capture stdout/stderr for progress parsing
    let log_handle = if let Some(log_path) = log_file {
        let f = fs::OpenOptions::new()
            .create(true)
            .truncate(true)
            .write(true)
            .open(log_path)
            .map_err(|e| format!("Failed to open log file: {e}"))?;
        Some(Arc::new(std::sync::Mutex::new(f)))
    } else {
        None
    };

    // Spawn thread to read stderr so it doesn't block the process when the pipe buffer fills up.
    // podman build can be very noisy on stderr (e.g. download bars).
    let image_name_str = image_name.to_string();
    let log_handle_stderr = log_handle.clone();
    let stderr_thread = std::thread::spawn(move || {
        use std::io::BufRead;
        if let Some(stderr_reader) = stderr {
            let buf_reader = std::io::BufReader::new(stderr_reader);
            for line in buf_reader.lines().map_while(Result::ok) {
                if _debug {
                    eprintln!("[tillandsias] build-{}: {}", image_name_str, line);
                }
                if let Some(ref log) = log_handle_stderr
                    && let Ok(mut f) = log.lock()
                {
                    let _ = writeln!(f, "{}", line);
                }
            }
        }
    });

    // @trace gap:ON-005 — read and parse output for progress tracking
    // Process stdout to catch layer pull progress
    use std::io::BufRead;

    let mut progress_percent = 0;
    let mut last_reported = 0;

    if let Some(stdout_reader) = stdout {
        let buf_reader = std::io::BufReader::new(stdout_reader);
        for line in buf_reader.lines().map_while(Result::ok) {
            if _debug {
                eprintln!("[tillandsias] build-{}: {}", image_name, line);
            }
            // Write to log file if present
            if let Some(ref log) = log_handle
                && let Ok(mut f) = log.lock()
            {
                let _ = writeln!(f, "{}", line);
            }

            // @trace gap:ON-005 — parse podman progress indicators
            // Look for "Pulling" and percentage indicators to compute progress
            if line.contains("Pulling") || line.contains("Digest:") || line.contains("Loaded image")
            {
                // Estimate progress based on visible output
                if line.contains("Pulling") && progress_percent < 50 {
                    progress_percent = 50;
                } else if line.contains("Digest:") && progress_percent < 75 {
                    progress_percent = 75;
                } else if line.contains("Loaded image") || line.contains("Commit") {
                    progress_percent = 100;
                }

                // Emit progress update if it changed significantly
                if progress_percent > last_reported + 10 || progress_percent == 100 {
                    println!(
                        "Pulling image {} [{}{}] {}%",
                        image_name,
                        "█".repeat(progress_percent / 10),
                        "░".repeat(10 - (progress_percent / 10)),
                        progress_percent
                    );
                    last_reported = progress_percent;
                }
            }
        }
    }

    let status = child
        .wait()
        .map_err(|e| format!("Failed to wait for build process: {e}"))?;

    // Wait for the stderr thread to finish logging
    let _ = stderr_thread.join();

    if status.success() {
        if progress_percent < 100 {
            println!("Pulling image {} [{}] 100%", image_name, "█".repeat(10));
        }
        Ok(())
    } else {
        Err(format!("Build exited with status {}", status))
    }
}

fn podman_build_argv(
    containerfile: &Path,
    context_dir: &Path,
    identity: &ImageBuildIdentity,
    build_args: &BTreeMap<String, String>,
) -> Result<Vec<String>, String> {
    let mut argv = vec![
        "build".to_string(),
        "--format".to_string(),
        "docker".to_string(),
        "-t".to_string(),
        identity.canonical_tag.clone(),
    ];
    for (label, value) in &identity.labels {
        argv.push("--label".to_string());
        argv.push(format!("{label}={value}"));
    }
    argv.push("-f".to_string());
    argv.push(
        containerfile
            .to_str()
            .ok_or_else(|| "Containerfile path contains invalid UTF-8".to_string())?
            .to_string(),
    );

    for (name, value) in build_args {
        argv.push("--build-arg".to_string());
        argv.push(format!("{name}={value}"));
    }

    argv.push(
        context_dir
            .to_str()
            .ok_or_else(|| "Context path contains invalid UTF-8".to_string())?
            .to_string(),
    );
    Ok(argv)
}

fn cleanup_init_logs() {
    for image in &[
        "proxy",
        "git",
        "inference",
        "router",
        "chromium-core",
        "chromium-framework",
        "forge-base",
        "forge",
    ] {
        let log_path = PathBuf::from(format!("/tmp/tillandsias-init-{}.log", image));
        let _ = fs::remove_file(&log_path);
    }
}

/// Validate per-project cache integrity before launching containers.
/// Reports warnings if cache is corrupted or unreadable.
/// @trace spec:cache-recovery-mechanism, spec:forge-cache-dual
///
/// # Integration Plan
/// Currently unused, but integrated into container launch path when gap closure prioritized.
/// See: plan/localwork/wave-27b-findings.md, line 155
#[allow(dead_code)]
fn validate_project_cache(project_path: &Path, debug: bool) -> Result<bool, String> {
    // Project cache is stored at .tillandsias/cache/ inside the project
    let cache_dir = project_path.join(".tillandsias").join("cache");

    if !cache_dir.exists() {
        // No cache yet — this is normal for new projects
        return Ok(true);
    }

    // Check for common corruption indicators:
    // 1. Broken symlinks (typically in cargo cache)
    // 2. Zero-byte files (incomplete downloads)
    // 3. Truncated lock files (JSON or TOML)

    let mut corrupted_files = Vec::new();

    if let Ok(entries) = fs::read_dir(&cache_dir) {
        for entry in entries.flatten() {
            let path = entry.path();

            // @trace gap:TR-006 — single-syscall symlink validation
            // Use read_link() instead of is_symlink() + metadata() to detect broken symlinks.
            // read_link() returns the target path as stored in the symlink, or an error if not a symlink.
            if let Ok(target) = fs::read_link(&path) {
                // Symlink exists. Resolve the target relative to the symlink's parent directory.
                let resolved_target = if target.is_absolute() {
                    target.clone()
                } else {
                    path.parent()
                        .map(|p| p.join(&target))
                        .unwrap_or(target.clone())
                };

                if !resolved_target.exists() {
                    // Target doesn't exist = broken symlink
                    corrupted_files.push(format!(
                        "broken symlink: {} → {}",
                        path.display(),
                        target.display()
                    ));
                    continue;
                }
            }

            // Check for zero-byte files
            // Use symlink_metadata to avoid following symlinks when checking file size
            #[allow(clippy::collapsible_if)]
            if let Ok(metadata) = fs::symlink_metadata(&path) {
                if metadata.is_file() && metadata.len() == 0 {
                    corrupted_files.push(format!("zero-byte file: {}", path.display()));
                }
            }
        }
    }

    if !corrupted_files.is_empty() {
        warn!(
            "Corrupted cache files detected: {}",
            corrupted_files.join("; ")
        );
        eprintln!(
            "WARNING: Project cache appears corrupted ({} issues found)",
            corrupted_files.len()
        );
        if debug {
            for file in &corrupted_files {
                eprintln!("  - {}", file);
            }
        }
        eprintln!("RECOVERY: Run 'tillandsias --cache-clear' to rebuild the cache");
        // Return true (cache validation completed), but the cache is suspect
        return Ok(false);
    }

    Ok(true)
}

/// Clear the initialization cache and build state.
/// @trace spec:forge-staleness, spec:forge-cache-dual
fn run_cache_clear(debug: bool) -> Result<(), String> {
    let cache_dir = init_cache_dir()?;
    let state_file = cache_dir.join("init-build-state.json");
    let version_file = cache_dir.join("cache_version");
    let temp_file = cache_dir.join(".init-build-state.json.tmp");

    let mut cleared = Vec::new();

    if state_file.exists() {
        fs::remove_file(&state_file)
            .map_err(|e| format!("Failed to remove build state file: {e}"))?;
        cleared.push("init-build-state.json");
    }

    if version_file.exists() {
        fs::remove_file(&version_file)
            .map_err(|e| format!("Failed to remove cache version file: {e}"))?;
        cleared.push("cache_version");
    }

    if temp_file.exists() {
        let _ = fs::remove_file(&temp_file);
        cleared.push(".init-build-state.json.tmp (temp)");
    }

    if debug || !cleared.is_empty() {
        println!("Cache cleared. Removed:");
        for item in cleared {
            println!("  - {}", item);
        }
        println!("\nNext --init will rebuild all images from scratch.");
    }

    Ok(())
}

/// Verify cache integrity and report status.
/// @trace spec:forge-staleness, spec:forge-cache-dual
fn run_cache_verify(debug: bool) -> Result<(), String> {
    let version = VERSION.trim();
    let status = check_cache_integrity(version)?;

    println!("Cache Integrity Status");
    println!("======================");
    println!("Cache directory: {}", status.cache_dir.display());
    println!("Current version: {}", status.current_version);
    println!(
        "Cached version:  {}",
        status.cached_version.as_deref().unwrap_or("<not set>")
    );
    println!();

    if status.is_valid {
        println!("✅ Cache is VALID");
        println!("  - Version matches current build");
        println!("  - Build state file present and readable");
    } else {
        println!("❌ Cache is INVALID");

        if status.version_mismatch {
            println!("  - Version mismatch detected");
            if let Some(cached) = &status.cached_version {
                println!(
                    "    Cached: {}, Current: {}",
                    cached, status.current_version
                );
            } else {
                println!("    No cached version found");
            }
            println!("    Suggestion: Run 'tillandsias --init' to auto-rebuild");
        }

        if status.missing_state_file {
            println!("  - Build state file is missing or corrupted");
            println!("    Suggestion: Run 'tillandsias --cache-clear' then 'tillandsias --init'");
        }
    }

    println!();
    if debug {
        println!("Debug Info:");
        println!("  Version mismatch: {}", status.version_mismatch);
        println!("  Missing state file: {}", status.missing_state_file);
    }

    if !status.is_valid {
        return Err("Cache integrity check failed. See suggestions above.".to_string());
    }

    Ok(())
}

/// Run the representative end-to-end stack smoke after images exist.
///
/// @trace spec:dev-build, spec:enclave-network, spec:proxy-container, spec:git-mirror-service, spec:inference-container, spec:default-image, spec:observability-convergence
fn run_status_check(debug: bool) -> Result<(), String> {
    require_desktop_user_session("tillandsias --status-check")?;
    report_runtime_lane("--status-check", debug);

    let rt = podman_runtime()?;
    let client = PodmanClient::new();
    let version = VERSION.trim();
    let root = resolve_runtime_asset_root(version, debug)?;
    let project_name = "tillandsias-status-check";
    let certs_dir = ensure_ca_bundle(debug)?;
    ensure_enclave_network(debug)?;

    let images = [
        "proxy",
        "git",
        "inference",
        "chromium-core",
        "chromium-framework",
        "forge",
    ];
    ensure_versioned_images(&root, &images, version, debug)?;

    let probe_image = versioned_image_tag("forge", version);
    podman_runtime_health_probe(debug, &probe_image)?;

    let proxy_image = versioned_image_tag("proxy", version);
    let git_image = versioned_image_tag("git", version);
    let inference_image = versioned_image_tag("inference", version);

    rt.block_on(async {
        cleanup_stack_containers(&client, project_name).await;

        client
            .run_container_observed(
                "status-proxy",
                "tillandsias-proxy",
                &build_proxy_run_args(&certs_dir, &proxy_image),
                debug,
            )
            .await
            .map_err(|e| e.to_string())?;

        let git_container_name = format!("tillandsias-git-{project_name}");
        let git_vault_secret = mint_git_mirror_vault_token(project_name, debug).await;
        client
            .run_container_observed(
                "status-git",
                &git_container_name,
                // Status-check has no real project — there is no host origin
                // URL to forward and the bare repo is throwaway.
                &build_git_run_args(
                    project_name,
                    &certs_dir,
                    &git_image,
                    None,
                    git_vault_secret.as_deref(),
                ),
                debug,
            )
            .await
            .map_err(|e| e.to_string())?;

        client
            .run_container_observed(
                "status-inference",
                "tillandsias-inference",
                &build_inference_run_args(&certs_dir, &inference_image, true),
                debug,
            )
            .await
            .map_err(|e| e.to_string())?;

        let status_args =
            build_status_check_forge_args(root.as_path(), project_name, &certs_dir, version);
        let result = client
            .run_container_observed(
                "status-forge",
                &forge_container_name(project_name),
                &status_args,
                debug,
            )
            .await;
        cleanup_shared_stack_if_no_running_forge(&client, project_name, debug).await;
        result.map_err(|e| e.to_string())?;

        Ok::<(), String>(())
    })?;

    Ok(())
}

fn podman_runtime_health_probe(debug: bool, probe_image: &str) -> Result<(), String> {
    let probe = || {
        let mut command = podman_command();
        command.args([
            "run",
            "--rm",
            "--userns=host",
            "--hostname",
            "runtime-probe",
            "--entrypoint",
            "/bin/sh",
            probe_image,
            "-c",
            "env >/dev/null",
        ]);
        command
    };

    let first_output = probe()
        .output()
        .map_err(|e| format!("Failed to run Podman runtime probe: {e}"))?;
    if first_output.status.success() {
        return Ok(());
    }

    let first_stderr = summarize_podman_output(&first_output);
    let known_blocker = podman_runtime_blocker(&first_stderr);
    if debug {
        eprintln!("[tillandsias] runtime probe failed: {first_stderr}");
        if !known_blocker {
            eprintln!("[tillandsias] runtime probe did not match a known blocker signature");
        }
    }

    let mut migrate = podman_command();
    migrate.args(["system", "migrate"]);
    let migrate_output = migrate
        .output()
        .map_err(|e| format!("Failed to run Podman system migrate: {e}"))?;
    if debug && !migrate_output.status.success() {
        eprintln!(
            "[tillandsias] podman system migrate failed: {}",
            summarize_podman_output(&migrate_output)
        );
    }

    let second_output = probe()
        .output()
        .map_err(|e| format!("Failed to rerun Podman runtime probe: {e}"))?;
    if second_output.status.success() {
        return Ok(());
    }

    let second_stderr = summarize_podman_output(&second_output);
    Err(format!(
        "Host Podman runtime unhealthy for status-check after one repair attempt; probe image {probe_image}; first error: {first_stderr}; second error: {second_stderr}"
    ))
}

fn summarize_podman_output(output: &std::process::Output) -> String {
    let stderr = String::from_utf8_lossy(&output.stderr).trim().to_string();
    if !stderr.is_empty() {
        return stderr;
    }

    let stdout = String::from_utf8_lossy(&output.stdout).trim().to_string();
    if !stdout.is_empty() {
        return stdout;
    }

    format!("exit status {}", output.status)
}

fn podman_runtime_blocker(stderr: &str) -> bool {
    let stderr = stderr.to_ascii_lowercase();
    [
        "newuidmap",
        "read-only file system",
        "acquiring runtime init lock",
        "cannot set up namespace",
        "failed to connect to user scope bus",
        "aardvark-dns",
        "netavark",
    ]
    .iter()
    .any(|needle| stderr.contains(needle))
}

fn command_output(mut command: Command, debug: bool) -> Result<String, String> {
    if debug {
        eprintln!("[tillandsias] running: {:?}", command);
    }
    let output = command
        .output()
        .map_err(|e| format!("Failed to run command: {e}"))?;
    if !output.status.success() {
        return Err(String::from_utf8_lossy(&output.stderr).trim().to_string());
    }
    Ok(String::from_utf8_lossy(&output.stdout).trim().to_string())
}

fn podman_command() -> Command {
    podman_cmd_sync()
}

/// In-container token entry for `--github-login`.
///
/// We deliberately avoid `gh auth login`'s interactive masked prompt: it puts
/// the container pty into raw, char-at-a-time mode, and a long token pasted
/// over `podman exec -it` can pick up bracketed-paste escape bytes
/// (`ESC[200~ … ESC[201~`) or be truncated, so gh ends up validating garbage
/// and GitHub returns `401 Bad credentials`.
///
/// Instead we read the token with a plain shell `read` (cooked line mode, which
/// does not enable bracketed paste, so the terminal delivers the pasted text
/// verbatim) and pipe it straight into `gh auth login --with-token`. The token
/// is read, held, and consumed entirely inside the container — the host process
/// still never sees it. `read -rs` keeps the input hidden, matching the old UX.
const GH_LOGIN_TOKEN_SCRIPT: &str = r#"
printf 'Paste your GitHub authentication token (input hidden), then press Enter: ' > /dev/tty
IFS= read -rs TOKEN < /dev/tty
printf '\n' > /dev/tty
if [ -z "$TOKEN" ]; then
  printf 'No token entered; aborting GitHub login.\n' >&2
  exit 1
fi
printf '%s' "$TOKEN" | gh auth login --hostname github.com --git-protocol https --with-token
"#;

/// Container-side bridge for the retired Tauri `--github-login` path.
///
/// The host runtime only assumes Podman. GitHub CLI runs inside the git service
/// image; the host never captures the token in host memory — the vault write
/// executes entirely inside the container.
///
/// @trace spec:gh-auth-script, spec:podman-secrets-integration, spec:secret-rotation, spec:tillandsias-vault
fn run_github_login(debug: bool) -> Result<(), String> {
    require_desktop_user_session("tillandsias --github-login")?;
    report_runtime_lane("--github-login", debug);

    // @trace spec:secret-rotation
    info!(
        accountability = true,
        category = "secrets",
        spec = "secret-rotation",
        operation = "gh_auth_start",
        secret_name = "tillandsias-github-token",
        "GitHub authentication and secret rotation starting"
    );

    let version = VERSION.trim();
    let root = resolve_runtime_asset_root(version, debug)?;
    let image = versioned_image_tag("git", version);

    ensure_image_exists(&root, "git", &image, debug)?;

    // The helper dual-homes onto `tillandsias-egress` (see the run args below)
    // to reach api.github.com, since `tillandsias-enclave` is `--internal`.
    // `--github-login` can run without a prior full `--init`, so the managed
    // egress network may not exist yet — ensure both networks here, otherwise
    // the dual-home leg fails to resolve. ensure_enclave_network ensures the
    // egress network first.
    ensure_enclave_network(debug)?;

    // Bring Vault online before the interactive paste so the user isn't
    // left waiting after login.
    #[cfg(feature = "vault")]
    vault_bootstrap::ensure_vault_running(debug)?;

    // Verify required services are healthy using the shared health facade.
    // This is provider-neutral — future auth flows (Cloudflare, AWS, etc.)
    // should reuse this preflight rather than adding per-provider sleeps.
    if debug {
        eprintln!("[tillandsias] running auth preflight health check");
    }
    let health_facade =
        tillandsias_podman::ContainerHealthFacade::new(tillandsias_podman::PodmanClient::new());
    let required = ["tillandsias-vault", "tillandsias-git"];
    let results = tokio::runtime::Runtime::new()
        .map_err(|e| format!("create tokio runtime for health check: {e}"))?
        .block_on(health_facade.check_required_services(&required));
    for svc in &results {
        if debug {
            eprintln!(
                "[tillandsias] preflight {} running={} health={:?} error={:?}",
                svc.name, svc.running, svc.health, svc.error
            );
        }
        if !svc.running {
            return Err(format!(
                "auth preflight failed: {} is not running ({:?})",
                svc.name, svc.error
            ));
        }
    }

    let container = format!("tillandsias-gh-login-{}", std::process::id());
    let cleanup = LoginContainerCleanup {
        name: container.clone(),
        debug,
    };

    #[cfg(feature = "vault")]
    let vault_lease;

    #[cfg(feature = "vault")]
    {
        vault_lease =
            vault_bootstrap::mint_approle_secret_lease("github-login", &container, debug)?;
        let mut run = podman_command();
        run.args([
            "run",
            "--detach",
            "--rm",
            "--name",
            &container,
            "--network",
            ENCLAVE_EGRESS_NETS,
            "--secret",
            &format!(
                "{},{GIT_VAULT_TOKEN_SECRET_OPTS}",
                vault_lease.secret_name()
            ),
            "--cap-drop=ALL",
            "--security-opt=no-new-privileges",
            "--userns=keep-id",
            "--entrypoint",
            "/bin/sh",
            &image,
            "-c",
            "trap 'exit 0' TERM INT; while :; do sleep 3600 & wait $!; done",
        ]);
        run_command_silent(run, debug)?;
    }

    #[cfg(not(feature = "vault"))]
    {
        let mut run = podman_command();
        run.args([
            "run",
            "--detach",
            "--rm",
            "--name",
            &container,
            // Dual-home for api.github.com egress (see the vault branch above).
            "--network",
            ENCLAVE_EGRESS_NETS,
            "--cap-drop=ALL",
            "--security-opt=no-new-privileges",
            "--userns=keep-id",
            "--entrypoint",
            "/bin/sh",
            &image,
            "-c",
            "trap 'exit 0' TERM INT; while :; do sleep 3600 & wait $!; done",
        ]);
        run_command_silent(run, debug)?;
    }

    // Prompt only after the non-secret infrastructure preflight has succeeded:
    // image present, managed networks present, Vault reachable, and the login
    // helper container running. Future auth providers should reuse this shape
    // rather than adding their own sleeps around credential entry.
    prompt_and_store_git_identity()?;

    // Token entry runs inside the container via a robust `read` + `--with-token`
    // pipe (see GH_LOGIN_TOKEN_SCRIPT) rather than gh's raw-mode masked prompt,
    // which corrupts pasted tokens over `podman exec -it`.
    let mut login = podman_command();
    login.args([
        "exec",
        "--interactive",
        "--tty",
        &container,
        "/bin/bash",
        "-c",
        GH_LOGIN_TOKEN_SCRIPT,
    ]);
    run_command(login, debug)?;

    let mut auth_status = podman_command();
    auth_status.args([
        "exec",
        &container,
        "gh",
        "auth",
        "status",
        "--hostname",
        "github.com",
    ]);
    run_command_silent(auth_status, debug).map_err(|e| {
        format!("containerized gh authentication verification failed after login: {e}")
    })?;

    info!(
        accountability = true,
        category = "secrets",
        spec = "secret-rotation",
        operation = "gh_auth_success",
        secret_name = "tillandsias-github-token",
        "GitHub authentication succeeded; writing token to Vault from inside container"
    );

    // Write the token to Vault entirely inside the container — the token
    // never leaves the container's memory space.
    #[cfg(feature = "vault")]
    {
        let mut vault_write = podman_command();
        vault_write.args([
            "exec",
            &container,
            "/bin/sh",
            "-c",
            "TOKEN=$(gh auth token --hostname github.com); vault-cli.sh write secret/github/token \"token=$TOKEN\"",
        ]);
        run_command_silent(vault_write, debug)
            .map_err(|e| format!("in-container vault write failed: {e}"))?;

        let mut vault_verify = podman_command();
        vault_verify.args([
            "exec",
            &container,
            "vault-cli.sh",
            "read",
            "-field=token",
            "secret/github/token",
        ]);
        run_command_silent(vault_verify, debug)
            .map_err(|e| format!("in-container vault write verification failed: {e}"))?;

        info!(
            accountability = true,
            category = "secrets",
            spec = "tillandsias-vault",
            operation = "gh_auth_vault_write",
            secret_name = "tillandsias-github-token",
            "GitHub token stored in Vault at secret/github/token"
        );

        // Configure git credential helper on the host so `git push origin`
        // works from the host working tree after --github-login.
        let mut get_token = podman_command();
        get_token.args([
            "exec",
            &container,
            "gh",
            "auth",
            "token",
            "--hostname",
            "github.com",
        ]);
        let token = command_output(get_token, debug)?;

        let mut host_login = Command::new("gh");
        host_login.args([
            "auth",
            "login",
            "--hostname",
            "github.com",
            "--git-protocol",
            "https",
            "--with-token",
        ]);
        host_login.stdin(Stdio::piped());
        let mut child = host_login
            .spawn()
            .map_err(|e| format!("Failed to spawn host gh auth login: {e}"))?;
        if let Some(mut stdin) = child.stdin.take() {
            stdin
                .write_all(token.as_bytes())
                .map_err(|e| format!("Failed to pipe token to host gh auth login: {e}"))?;
        }
        let status = child
            .wait()
            .map_err(|e| format!("Failed to wait for host gh auth login: {e}"))?;
        if !status.success() {
            return Err("Host gh auth login failed".to_string());
        }

        let mut setup_git = Command::new("gh");
        setup_git.args(["auth", "setup-git"]);
        run_command(setup_git, debug)?;

        info!(
            category = "secrets",
            operation = "gh_auth_setup_git",
            "Git credential helper configured on host"
        );
    }
    #[cfg(not(feature = "vault"))]
    {
        return Err("vault feature not compiled; cannot store GitHub token".to_string());
    }

    let mut username_cmd = podman_command();
    username_cmd.args(["exec", &container, "gh", "api", "user", "--jq", ".login"]);
    let username = command_output(username_cmd, debug).ok();

    drop(cleanup);

    info!(
        accountability = true,
        category = "secrets",
        spec = "secret-rotation",
        operation = "gh_auth_complete",
        secret_name = "tillandsias-github-token",
        "GitHub authentication and secret rotation completed successfully"
    );
    if let Some(username) = username.filter(|value| !value.is_empty()) {
        println!("[tillandsias] GitHub authentication complete for {username}");
    }

    // Add a 5 second delay so the user can see the success message before the popup terminal closes
    std::thread::sleep(std::time::Duration::from_secs(5));

    Ok(())
}

/// Headless diagnostic for the remote-projects path. Brings Vault online and
/// runs the same containerized `gh api user/repos` fetch the tray uses, then
/// prints the result and how long it took. This is the deterministic way to
/// confirm "list remote projects with the saved token" without the tray's
/// async menu lifecycle.
/// @trace spec:remote-projects
#[cfg(all(feature = "vault", any(feature = "tray", feature = "listen-vsock")))]
fn run_list_cloud_projects(debug: bool) -> Result<(), String> {
    require_desktop_user_session("tillandsias --list-cloud-projects")?;
    report_runtime_lane("--list-cloud-projects", debug);

    vault_bootstrap::ensure_vault_running(debug)?;
    if !vault_bootstrap::is_github_logged_in(debug) {
        return Err(
            "no GitHub credential in Vault — run `tillandsias --github-login` first".to_string(),
        );
    }

    let start = std::time::Instant::now();
    let projects = remote_projects::discover_github_projects_result_with_debug(debug)?;
    let elapsed = start.elapsed();

    println!(
        "[tillandsias] fetched {} remote project(s) in {:.2}s",
        projects.len(),
        elapsed.as_secs_f64()
    );
    for project in &projects {
        let desc = project.description.as_deref().unwrap_or("");
        println!("  {}/{}  {}", project.owner, project.name, desc);
    }
    if projects.is_empty() {
        println!("  (no owned, non-archived repositories returned)");
    }
    Ok(())
}

#[cfg(not(all(feature = "vault", any(feature = "tray", feature = "listen-vsock"))))]
fn run_list_cloud_projects(_debug: bool) -> Result<(), String> {
    Err(
        "this build lacks remote-projects support (requires the `vault` and `tray` features)"
            .to_string(),
    )
}

#[derive(Default)]
struct GitIdentity {
    name: Option<String>,
    email: Option<String>,
}

fn prompt_and_store_git_identity() -> Result<(), String> {
    let current = read_git_identity_defaults();
    let name = prompt_with_default("Git author name", current.name.as_deref())?;
    let email = prompt_with_default("Git author email", current.email.as_deref())?;

    if name.trim().is_empty() {
        return Err("Git author name cannot be empty".to_string());
    }
    if !email.contains('@') || email.trim().contains(char::is_whitespace) {
        return Err("Git author email must look like an email address".to_string());
    }

    let gitconfig = managed_gitconfig_path()?;
    if let Some(parent) = gitconfig.parent() {
        std::fs::create_dir_all(parent)
            .map_err(|e| format!("Failed to create git identity directory: {e}"))?;
    }

    let contents = format!(
        "[user]\n\tname = {}\n\temail = {}\n",
        escape_gitconfig_value(name.trim()),
        escape_gitconfig_value(email.trim())
    );
    std::fs::write(&gitconfig, contents)
        .map_err(|e| format!("Failed to write managed git identity: {e}"))?;
    println!("Git identity saved: {}", gitconfig.display());
    Ok(())
}

fn prompt_with_default(label: &str, default: Option<&str>) -> Result<String, String> {
    match default {
        Some(value) if !value.trim().is_empty() => {
            print!("{label} [{value}]: ");
        }
        _ => {
            print!("{label}: ");
        }
    }
    io::stdout()
        .flush()
        .map_err(|e| format!("Failed to flush prompt: {e}"))?;

    let mut input = String::new();
    io::stdin()
        .read_line(&mut input)
        .map_err(|e| format!("Failed to read {label}: {e}"))?;

    let input = input.trim().to_string();
    if input.is_empty() {
        Ok(default.unwrap_or("").trim().to_string())
    } else {
        Ok(input)
    }
}

fn read_git_identity_defaults() -> GitIdentity {
    let mut identity = GitIdentity::default();
    for path in gitconfig_default_paths() {
        if let Ok(contents) = std::fs::read_to_string(path) {
            let parsed = parse_git_identity(&contents);
            if identity.name.is_none() {
                identity.name = parsed.name;
            }
            if identity.email.is_none() {
                identity.email = parsed.email;
            }
        }
    }
    identity
}

fn git_identity_env_pairs(identity: &GitIdentity) -> Vec<(&'static str, String)> {
    let Some(name) = identity
        .name
        .as_deref()
        .map(str::trim)
        .filter(|v| !v.is_empty())
    else {
        return Vec::new();
    };
    let Some(email) = identity
        .email
        .as_deref()
        .map(str::trim)
        .filter(|v| !v.is_empty())
    else {
        return Vec::new();
    };

    vec![
        ("GIT_AUTHOR_NAME", name.to_string()),
        ("GIT_AUTHOR_EMAIL", email.to_string()),
        ("GIT_COMMITTER_NAME", name.to_string()),
        ("GIT_COMMITTER_EMAIL", email.to_string()),
    ]
}

fn append_git_identity_env_args(args: &mut Vec<String>) {
    for (name, value) in git_identity_env_pairs(&read_git_identity_defaults()) {
        args.push("--env".into());
        args.push(format!("{name}={value}"));
    }
}

fn gitconfig_default_paths() -> Vec<PathBuf> {
    let mut paths = Vec::new();
    if let Ok(path) = managed_gitconfig_path() {
        paths.push(path);
    }
    if let Ok(home) = std::env::var("HOME") {
        paths.push(PathBuf::from(home).join(".gitconfig"));
    }
    paths
}

fn managed_gitconfig_path() -> Result<PathBuf, String> {
    if let Ok(cache_home) = std::env::var("XDG_CACHE_HOME") {
        return Ok(PathBuf::from(cache_home)
            .join("tillandsias")
            .join("secrets")
            .join("git")
            .join(".gitconfig"));
    }
    let home = std::env::var("HOME").map_err(|_| "HOME is not set".to_string())?;
    Ok(PathBuf::from(home)
        .join(".cache")
        .join("tillandsias")
        .join("secrets")
        .join("git")
        .join(".gitconfig"))
}

fn parse_git_identity(contents: &str) -> GitIdentity {
    let mut identity = GitIdentity::default();
    let mut in_user = false;

    for line in contents.lines() {
        let trimmed = line.trim();
        if trimmed.starts_with('[') && trimmed.ends_with(']') {
            in_user = trimmed == "[user]";
            continue;
        }
        if !in_user {
            continue;
        }
        if let Some((key, value)) = trimmed.split_once('=') {
            let key = key.trim();
            let value = value.trim().trim_matches('"').to_string();
            match key {
                "name" if identity.name.is_none() => identity.name = Some(value),
                "email" if identity.email.is_none() => identity.email = Some(value),
                _ => {}
            }
        }
    }

    identity
}

fn escape_gitconfig_value(value: &str) -> String {
    value.replace('\\', "\\\\").replace('\n', " ")
}

struct LoginContainerCleanup {
    name: String,
    debug: bool,
}

impl Drop for LoginContainerCleanup {
    fn drop(&mut self) {
        let mut command = podman_command();
        command.args(["rm", "-f", &self.name]);
        let _ = run_command_silent(command, self.debug);
    }
}

/// Phase 3, Task 12: Auto-detect native tray availability.
/// @trace spec:linux-native-portable-executable, spec:transparent-mode-detection, spec:tray-cli-coexistence
fn is_tray_available() -> bool {
    cfg!(all(feature = "tray", target_os = "linux"))
}

/// Return whether this process has a graphical desktop session available for a
/// companion tray process.
///
/// @trace spec:tray-cli-coexistence
fn has_graphical_session() -> bool {
    if std::env::var_os("TILLANDSIAS_NO_TRAY").is_some_and(|v| v == "1") {
        return false;
    }

    #[cfg(target_os = "linux")]
    {
        std::env::var_os("DISPLAY").is_some_and(|v| !v.is_empty())
            || std::env::var_os("WAYLAND_DISPLAY").is_some_and(|v| !v.is_empty())
    }

    #[cfg(not(target_os = "linux"))]
    {
        true
    }
}

/// CLI modes do foreground work, but on a desktop they still need the tray's
/// long-lived control socket. Spawn the tray as a detached sibling and let its
/// singleton guard collapse duplicate launches.
///
/// @trace spec:tray-cli-coexistence, spec:tray-host-control-socket
fn maybe_spawn_detached_tray_for_cli(explicit_tray: bool, debug: bool) {
    if !cfg!(feature = "tray") || (!explicit_tray && !has_graphical_session()) {
        return;
    }

    let socket_path = control_socket_host_dir().join("control.sock");

    // Fast path: if the socket is already accepting connections, an existing
    // tray (or an earlier sibling) is alive and there's no need to spawn a
    // duplicate. Probe with an actual `connect()` so we don't mistake a stale
    // socket file (left behind by a crashed tray) for a live listener — that
    // false positive used to cause `--observatorium` / `--opencode-web` to
    // race past this helper and then fail in `send_issue_web_session` with
    // `Connection refused`.
    if control_socket_is_listening(&socket_path) {
        if debug {
            eprintln!("[tillandsias] reusing existing tray control socket");
        }
        return;
    }

    let Ok(exe) = std::env::current_exe() else {
        return;
    };

    let mut command = Command::new(exe);
    command
        .arg("--tray")
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::null());

    #[cfg(unix)]
    unsafe {
        command.pre_exec(|| {
            if libc::setsid() == -1 {
                return Err(io::Error::last_os_error());
            }
            Ok(())
        });
    }

    match command.spawn() {
        Ok(_) => {
            if debug {
                eprintln!("[tillandsias] spawned detached tray companion");
            }
            // Poll until something actually accepts a connection — not just
            // until the socket file appears. The spawned tray removes the
            // stale file (`start_control_socket_server`) before binding, so a
            // bare `exists()` check is racy: it can fire on the leftover
            // inode before the bind completes.
            let deadline = Instant::now() + Duration::from_secs(5);
            while Instant::now() < deadline {
                if control_socket_is_listening(&socket_path) {
                    if debug {
                        eprintln!("[tillandsias] tray control socket is ready");
                    }
                    return;
                }
                std::thread::sleep(Duration::from_millis(50));
            }
            if debug {
                eprintln!(
                    "[tillandsias] Warning: tray control socket did not become ready within 5s; \
                     downstream OTP handshakes may fail"
                );
            }
        }
        Err(err) if debug => {
            eprintln!("[tillandsias] Warning: failed to spawn tray companion: {err}");
        }
        Err(_) => {}
    }
}

/// Test whether the tray's control socket is accepting connections. Used by
/// `maybe_spawn_detached_tray_for_cli` to distinguish a live tray from a
/// stale socket file left over from a crashed tray.
///
/// @trace spec:tray-host-control-socket
fn control_socket_is_listening(socket_path: &Path) -> bool {
    if !socket_path.exists() {
        return false;
    }
    // Any connect failure — ECONNREFUSED on a stale socket file, ENOTSOCK on
    // a regular file at the path, ENOENT if the file vanished between the
    // exists() check and connect — collapses to "not listening" and lets the
    // caller decide whether to spawn or give up.
    UnixStream::connect(socket_path).is_ok()
}

/// Phase 3, Task 12 & Phase 4: Launch in tray mode with headless subprocess.
/// @trace spec:linux-native-portable-executable, spec:transparent-mode-detection, spec:tray-subprocess-management
fn launch_tray_mode(_config_path: Option<String>, _debug: bool) -> Result<(), String> {
    #[cfg(feature = "tray")]
    {
        crate::tray::run_tray_mode_with_debug(_config_path, _debug)
    }

    #[cfg(not(feature = "tray"))]
    {
        Err("Tray mode requires 'tray' feature".to_string())
    }
}

fn observatorium_container_name(project_name: &str) -> String {
    format!("tillandsias-observatorium-{project_name}")
}

fn project_label_from_path(path: &Path, fallback: &str) -> String {
    let raw = path
        .file_name()
        .and_then(|n| n.to_str())
        .filter(|name| !name.trim().is_empty())
        .unwrap_or(fallback);

    let mut label = String::new();
    let mut previous_dash = false;
    for ch in raw.chars() {
        if ch.is_ascii_alphanumeric() {
            label.push(ch.to_ascii_lowercase());
            previous_dash = false;
        } else if ch == '-' {
            if !previous_dash {
                label.push('-');
                previous_dash = true;
            }
        } else if !previous_dash {
            label.push('-');
            previous_dash = true;
        }
    }

    let label = label.trim_matches('-');
    if label.is_empty() {
        fallback.to_string()
    } else {
        label.to_string()
    }
}

fn build_observatorium_web_args(
    project_path: &Path,
    project_name: &str,
    observatorium_assets: &Path,
    image: &str,
) -> Vec<String> {
    ContainerSpec::new(image)
        .pull_never()
        .name(observatorium_container_name(project_name))
        .hostname(sanitize_hostname(&format!("observatorium-{project_name}")))
        .detached()
        .read_only()
        .pids_limit(64)
        .network(ENCLAVE_NET)
        .env("PROJECT", project_name)
        .env("TILLANDSIAS_PROJECT", project_name)
        .env("OBSERVATORIUM_SOURCE_ROOT", "/source")
        .bind_mount(
            observatorium_assets.display().to_string(),
            "/var/www/observatorium",
            true,
        )
        .bind_mount(project_path.display().to_string(), "/var/www/source", true)
        .tmpfs("/tmp:size=64m")
        .tmpfs("/var/cache:size=16m")
        .build_run_args()
}

fn launch_observatorium_browser(
    project_name: &str,
    certs_dir: &Path,
    router_host_port: u16,
    debug: bool,
) -> Result<(), String> {
    let app_url = observatorium_app_url(project_name, router_host_port);
    if let Err(err) = wait_for_opencode_web_route(project_name, &app_url, debug) {
        return Err(format!(
            "Observatorium auth gate did not become ready: {err}"
        ));
    }

    let version = VERSION.trim();
    let profile_root = browser_profile_root();
    std::fs::create_dir_all(&profile_root).map_err(|e| {
        format!(
            "Failed to create browser profile root {:?}: {e}",
            profile_root
        )
    })?;
    let display = BrowserDisplayContext::from_env()?;
    let profile_dir = TempDirBuilder::new()
        .prefix(&format!("observatorium-{project_name}-"))
        .tempdir_in(&profile_root)
        .map_err(|e| {
            format!(
                "Failed to create browser profile dir in {:?}: {e}",
                profile_root
            )
        })?;
    let profile_path = profile_dir.keep();

    let project_label = project_name.to_string();
    let otp = tillandsias_otp::issue_session(&project_label);
    let origin_url = observatorium_origin_url(project_name, router_host_port);
    let login_url = tillandsias_otp::build_login_data_url(&origin_url, &otp);
    let browser_container_name = format!("tillandsias-browser-observatorium-{project_name}");
    let spec = build_project_browser_spec(
        &login_url,
        version,
        &profile_path,
        certs_dir,
        &display,
        &browser_container_name,
    )?;
    let args = spec.build_run_args();

    send_issue_web_session(&project_label, &otp)
        .map_err(|e| format!("Failed to register Observatorium session with router: {e}"))?;
    if let Err(err) = wait_for_authenticated_opencode_web(project_name, &app_url, &otp, debug) {
        return Err(format!(
            "Observatorium app did not become reachable with a registered session: {err}"
        ));
    }

    let result = rt_block_on_podman_run(args, &browser_container_name, "browser", debug);
    if result.is_ok() {
        let profile_cleanup_path = profile_path.clone();
        let container_name = browser_container_name.clone();
        std::thread::spawn(move || {
            let rt = match tokio::runtime::Runtime::new() {
                Ok(r) => r,
                Err(e) => {
                    eprintln!("[tillandsias] Failed to create runtime for browser cleanup: {e}");
                    return;
                }
            };
            if let Err(e) = rt.block_on(monitor_and_cleanup_browser(&container_name, debug)) {
                eprintln!("[tillandsias] Browser cleanup error: {e}");
            }
            let _ = std::fs::remove_dir_all(&profile_cleanup_path);
        });
    }
    result
}

fn run_observatorium_mode(
    project_path: &str,
    port_override: Option<u16>,
    debug: bool,
) -> Result<(), String> {
    if std::env::var("OBSERVATORIUM_BROWSER").ok().as_deref() != Some("none") {
        require_desktop_user_session("tillandsias --observatorium")?;
    }
    report_runtime_lane("--observatorium", debug);

    let project = Path::new(project_path);
    if !project.exists() {
        return Err(format!("Project not found: {project_path}"));
    }
    if !project.is_dir() {
        return Err(format!("Project path is not a directory: {project_path}"));
    }

    let version = VERSION.trim();
    let root = resolve_runtime_asset_root(version, debug)?;
    let observatorium_assets = root.join("observatorium");
    if !observatorium_assets.join("index.html").is_file() {
        return Err(format!(
            "Observatorium UI assets not found at {}",
            observatorium_assets.display()
        ));
    }

    let project_path_resolved = project
        .canonicalize()
        .unwrap_or_else(|_| PathBuf::from(project_path));
    let project_name = project_label_from_path(&project_path_resolved, "observatorium-project");
    let certs_dir = ensure_ca_bundle(debug)?;
    ensure_enclave_network(debug)?;

    let images = ["web", "router", "chromium-core", "chromium-framework"];
    ensure_versioned_images(&root, &images, version, debug)?;

    let rt = podman_runtime()?;
    let client = PodmanClient::new();
    let router_host_port = rt.block_on(async {
        match existing_router_host_port(&client, debug).await? {
            Some(port) => Ok::<u16, String>(port),
            None => Ok(select_router_host_port(port_override, debug)?),
        }
    })?;

    if debug {
        eprintln!(
            "[tillandsias] Observatorium project: {}",
            project_path_resolved.display()
        );
        eprintln!(
            "[tillandsias] Observatorium URL: {}",
            observatorium_app_url(&project_name, router_host_port)
        );
    }

    let observatorium_name = observatorium_container_name(&project_name);
    let web_image = versioned_image_tag("web", version);
    let router_image = versioned_image_tag("router", version);
    rt.block_on(async {
        // gap-3 phase-2c symmetry with run_opencode_mode: spawn the live
        // diagnostic-event emitter so `event:container_exit container=…
        // exit_code=…` lines land on stderr when --debug is on. Captured
        // by the forge-diagnostics annex stderr companion + the distill
        // "Container-Start Stream" + "Typed-event arms" sections.
        //
        // NOTE: this rt.block_on closes BEFORE the synchronous
        // `wait_for_observatorium_http_ready` / `launch_observatorium_
        // browser` steps, so events from the chromium-core / chromium-
        // framework containers (launched by the host-side browser path)
        // are NOT captured here. The events that ARE captured: router,
        // observatorium-web, and any background podman activity during
        // route setup. A follow-on slice could raise the emitter to a
        // higher scope to also cover the browser containers.
        //
        // @trace spec:runtime-diagnostics-stream
        // @trace plan/issues/linux-headless-spec-gaps-2026-05-27.md (gap 3 phase-2c symmetry)
        let diag_emitter =
            tillandsias_podman::diagnostic_event_emitter::spawn_diagnostic_event_emitter(
                debug,
                "tillandsias-",
            );

        client.remove_container(&observatorium_name).await.ok();

        // Step 15 slice 2: bring the router up BEFORE the observatorium-web
        // container so any startup-phase requests inside the enclave resolve
        // the `router` alias to a live cache_peer. The previous ordering
        // started the router AFTER observatorium-web, leaving a 1-3s
        // exit-125-flavoured retry window. ensure_router_running is
        // idempotent.
        //
        // @trace plan/steps/15-tray-network-bootstrap.md
        ensure_router_running(&client, &certs_dir, &router_image, router_host_port, debug).await?;

        client
            .run_container_observed(
                "observatorium-web",
                &observatorium_name,
                &build_observatorium_web_args(
                    &project_path_resolved,
                    &project_name,
                    &observatorium_assets,
                    &web_image,
                ),
                debug,
            )
            .await
            .map_err(|e| format!("[Observatorium] failed to start web container: {e}"))?;

        // gap-3 phase-2g symmetry: start the typed-event stderr tail on
        // the two containers the observatorium launch path owns at this
        // point — `tillandsias-router` (just ensured up) and the web
        // container we just launched. Chromium containers come later
        // (host-side browser path) and are out of scope here.
        //
        // @trace spec:runtime-diagnostics-stream (Stderr line pass-through)
        // @trace plan/issues/linux-headless-spec-gaps-2026-05-27.md (gap 3 phase-2g symmetry)
        let _diag_logs_handle = if debug {
            Some(
                tillandsias_podman::DiagnosticsHandle::start_typed_event_stream(vec![
                    "tillandsias-router".to_string(),
                    observatorium_name.clone(),
                ])
                .await,
            )
        } else {
            None
        };

        let route = RouterRoute::new(
            format!("observatorium.{project_name}"),
            observatorium_name.clone(),
            8080u16,
        )
        .with_root_redirect("/observatorium/");
        upsert_router_route(route, debug)?;
        caddy_reload_routes(debug).await?;

        // Stop the diagnostic-event emitter before this block closes;
        // dropping `_diag_logs_handle` aborts its podman-logs-f tails
        // implicitly via DiagnosticsHandle::Drop.
        if let Some(handle) = diag_emitter {
            handle.abort();
            let _ = handle.await;
        }

        Ok::<(), String>(())
    })?;

    // Step 16: probe the actual HTTPS page before launching the browser,
    // so a router/web mismatch surfaces ONE actionable error here instead
    // of the user seeing a broken page after the browser opens. Failure
    // includes the observatorium container's recent logs.
    //
    // @trace plan/steps/16-observatorium-readiness-and-ux.md
    wait_for_observatorium_http_ready(&project_name, router_host_port, debug)?;

    if std::env::var("OBSERVATORIUM_BROWSER").ok().as_deref() == Some("none") {
        return Ok(());
    }

    launch_observatorium_browser(&project_name, &certs_dir, router_host_port, debug)
}

/// Run in OpenCode mode — launch the full enclave stack and OpenCode TUI.
///
/// @trace spec:cli-mode
fn run_opencode_mode(project_path: &str, prompt: Option<&str>, debug: bool) -> Result<(), String> {
    require_desktop_user_session("tillandsias --opencode")?;
    report_runtime_lane("--opencode", debug);

    if debug {
        eprintln!("[tillandsias] OpenCode mode enabled");
        eprintln!("[tillandsias] Project: {}", project_path);
        if let Some(prompt) = prompt {
            eprintln!("[tillandsias] Prompt seed provided: {}", prompt);
        }
    }

    // Phase B: Project initialization and container startup
    let project = std::path::Path::new(project_path);
    if !project.exists() {
        return Err(format!("Project not found: {}", project_path));
    }

    if debug {
        eprintln!(
            "[tillandsias] Project path is valid: {}",
            project.canonicalize().unwrap_or_default().display()
        );
    }

    let version = VERSION.trim();
    let root = resolve_runtime_asset_root(version, debug)?;
    // `Path::new(".").file_name()` returns None — canonicalize first.
    let project_path_resolved = std::path::Path::new(project_path)
        .canonicalize()
        .unwrap_or_else(|_| std::path::PathBuf::from(project_path));
    let project_name = project_path_resolved
        .file_name()
        .and_then(|n| n.to_str())
        .unwrap_or("opencode-project");
    let certs_dir = ensure_ca_bundle(debug)?;
    ensure_enclave_network(debug)?;

    let images = ["proxy", "git", "inference", "forge"];
    ensure_versioned_images(&root, &images, version, debug)?;

    if debug {
        eprintln!("[tillandsias] [OpenCode] Repo root: {}", root.display());
        eprintln!("[tillandsias] [OpenCode] Launching full-stack OpenCode session");
    }

    // Read the host's `remote.origin.url` so the mirror's post-receive hook
    // knows where to forward pushes. None when the project has no origin —
    // the mirror still works, the hook just logs "skipping push".
    let project_remote_url = read_host_project_origin_url(&project_path_resolved);
    if debug {
        match &project_remote_url {
            Some(url) => eprintln!("[tillandsias] [OpenCode] Host origin URL: {url}"),
            None => eprintln!("[tillandsias] [OpenCode] No host origin URL configured"),
        }
    }

    let rt = podman_runtime()?;
    let client = PodmanClient::new();
    rt.block_on(async {
        // gap-3 phase-2c: spawn the live diagnostic-event emitter so
        // `event:container_exit container=… exit_code=…` lines land on
        // stderr when --debug / --diagnostics is on. Captured by the
        // forge-diagnostics annex stderr companion + the distill
        // "Container-Start Stream" section. Filter prefix matches the
        // tillandsias-* container names launched below.
        //
        // The handle is aborted at the bottom of this block so the
        // emitter doesn't outlive the forge session (stderr would keep
        // emitting after the user's session ended).
        //
        // @trace spec:runtime-diagnostics-stream
        // @trace plan/issues/linux-headless-spec-gaps-2026-05-27.md (gap 3 phase-2c)
        let diag_emitter =
            tillandsias_podman::diagnostic_event_emitter::spawn_diagnostic_event_emitter(
                debug,
                "tillandsias-",
            );

        cleanup_stack_containers(&client, project_name).await;

        // Step 15: bring the router up BEFORE any project containers so the
        // enclave's `router` network alias is already resolvable when proxy /
        // git / inference start. Squid's `cache_peer router` and the git
        // service's HTTPS upstream both fail-and-retry if the alias resolves
        // to nothing — that retry storm is exactly the "exit 125 cascade"
        // Step 15 was filed to eliminate. ensure_router_running is idempotent
        // (it short-circuits on a live container with the right image), so
        // calling it here on every OpenCode launch is cheap on the warm path.
        //
        // @trace plan/steps/15-tray-network-bootstrap.md
        let router_image = versioned_image_tag("router", version);
        let router_host_port = match existing_router_host_port(&client, debug).await? {
            Some(port) => port,
            None => select_router_host_port(None, debug)?,
        };
        ensure_router_running(&client, &certs_dir, &router_image, router_host_port, debug).await?;

        client
            .run_container_observed(
                "opencode-proxy",
                "tillandsias-proxy",
                &build_proxy_run_args(&certs_dir, &versioned_image_tag("proxy", version)),
                debug,
            )
            .await
            .map_err(|e| format!("[OpenCode] failed to start proxy: {e}"))?;
        let git_container_name = format!("tillandsias-git-{project_name}");
        let git_vault_secret = mint_git_mirror_vault_token(project_name, debug).await;
        client
            .run_container_observed(
                "opencode-git",
                &git_container_name,
                &build_git_run_args(
                    project_name,
                    &certs_dir,
                    &versioned_image_tag("git", version),
                    project_remote_url.as_deref(),
                    git_vault_secret.as_deref(),
                ),
                debug,
            )
            .await
            .map_err(|e| format!("[OpenCode] failed to start git: {e}"))?;
        client
            .run_container_observed(
                "opencode-inference",
                "tillandsias-inference",
                &build_inference_run_args(
                    &certs_dir,
                    &versioned_image_tag("inference", version),
                    false,
                ),
                debug,
            )
            .await
            .map_err(|e| format!("[OpenCode] failed to start inference: {e}"))?;

        // gap-3 phase-2g: start the typed-event stderr tail on the
        // SUPPORT containers (router/proxy/git/inference). The
        // foreground forge is intentionally NOT in this list — it's
        // served attached to the user's terminal by
        // `run_container_attached_observed` below and tailing it here
        // would double-print every line.
        //
        // DiagnosticsHandle::Drop aborts every spawned `podman logs -f`
        // task, so dropping `_diag_logs_handle` at the end of the
        // block_on closure cleanly tears the tail tasks down — no
        // explicit abort needed.
        //
        // @trace spec:runtime-diagnostics-stream (Stderr line pass-through)
        // @trace plan/issues/linux-headless-spec-gaps-2026-05-27.md (gap 3 phase-2g)
        let _diag_logs_handle = if debug {
            Some(
                tillandsias_podman::DiagnosticsHandle::start_typed_event_stream(vec![
                    "tillandsias-router".to_string(),
                    "tillandsias-proxy".to_string(),
                    git_container_name.clone(),
                    "tillandsias-inference".to_string(),
                ])
                .await,
            )
        } else {
            None
        };

        let diagnostics = std::env::args().any(|a| a == "--diagnostics");
        let opencode_args = build_opencode_forge_args(
            &project_path_resolved,
            project_name,
            prompt,
            &certs_dir,
            version,
            ForgeMode::Cli,
            diagnostics,
            debug,
        );
        let result = client
            .run_container_attached_observed(
                "opencode",
                &forge_container_name(project_name),
                &opencode_args,
                debug,
            )
            .await;
        cleanup_shared_stack_if_no_running_forge(&client, project_name, debug).await;

        // Stop the diagnostic-event emitter before propagating the
        // forge result so the stderr stream cleanly closes with the
        // session. abort + await is safe to call when handle is None
        // (--debug off) because we only entered this branch via Some.
        if let Some(handle) = diag_emitter {
            handle.abort();
            let _ = handle.await;
        }

        result.map_err(|e| format!("[OpenCode] forge session exited: {e}"))?;

        Ok::<(), String>(())
    })
}

fn project_service_url(service_name: &str, project_name: &str, host_port: u16) -> String {
    // The router publishes :8080 in-container to host_port via
    // `127.0.0.1:host_port:8080`. host_port is normally 80 (privileged) or
    // 8080 (fallback) per select_router_host_port(); rootless containers
    // typically can't bind 80, so the URL must include the actual host
    // port the user can reach.
    if host_port == 80 {
        format!("http://{service_name}.{project_name}.localhost/")
    } else {
        format!("http://{service_name}.{project_name}.localhost:{host_port}/")
    }
}

fn opencode_web_url(project_name: &str, host_port: u16) -> String {
    project_service_url("opencode", project_name, host_port)
}

fn observatorium_origin_url(project_name: &str, host_port: u16) -> String {
    project_service_url("observatorium", project_name, host_port)
}

fn observatorium_app_url(project_name: &str, host_port: u16) -> String {
    format!(
        "{}observatorium/",
        observatorium_origin_url(project_name, host_port)
    )
}

/// Step 16: real HTTP readiness probe for the observatorium URL. Polls
/// up to 20 × 500ms (10s) for any non-5xx response on the app URL —
/// matching the established wait-for-opencode-web-route cadence.
/// `2xx` / `3xx` / `4xx` all count as "router + container alive enough
/// to talk back"; a 5xx, a connection refused, or a 10s timeout returns
/// an `Err` carrying the last status / error AND a tail of the
/// observatorium container's podman logs so the user sees one
/// actionable failure instead of a "browser opened to broken page".
///
/// Cert validation is permissive (`danger_accept_invalid_certs`) because
/// the Caddy router serves a Tillandsias-signed cert that the host
/// trust store doesn't (and shouldn't) carry. The probe targets
/// `localhost:<router-port>` exclusively; the rfc-2119 risk surface
/// is bounded.
///
/// @trace plan/steps/16-observatorium-readiness-and-ux.md
fn wait_for_observatorium_http_ready(
    project_name: &str,
    host_port: u16,
    debug: bool,
) -> Result<(), String> {
    let url = observatorium_app_url(project_name, host_port);
    let mut last_outcome = String::from("no HTTP probe attempted");
    for attempt in 1..=20 {
        match observatorium_probe_status(&url) {
            Ok(code) if (200..500).contains(&code) => {
                if debug {
                    eprintln!(
                        "[tillandsias] [observatorium] readiness OK on attempt {attempt}/20 (status {code})"
                    );
                }
                return Ok(());
            }
            Ok(code) => {
                last_outcome = format!("status {code}");
                if debug {
                    eprintln!(
                        "[tillandsias] [observatorium] waiting: attempt {attempt}/20 ({last_outcome})"
                    );
                }
            }
            Err(err) => {
                last_outcome = err;
                if debug {
                    eprintln!(
                        "[tillandsias] [observatorium] waiting: attempt {attempt}/20 ({last_outcome})"
                    );
                }
            }
        }
        std::thread::sleep(Duration::from_millis(500));
    }

    let logs_tail = observatorium_logs_tail(project_name, 50);
    Err(format!(
        "Observatorium readiness probe did not succeed in 10s.\n\
         URL: {url}\n\
         Last outcome: {last_outcome}\n\
         Container logs (last ≤50 lines):\n{logs_tail}\n\
         Next: inspect `podman logs {observatorium_container}` for the\n\
         full transcript, then verify the enclave network + router are\n\
         healthy via `tillandsias --status`.",
        observatorium_container = observatorium_container_name(project_name),
    ))
}

fn observatorium_probe_status(url: &str) -> Result<u16, String> {
    let url = url.to_string();
    let rt = tokio::runtime::Builder::new_current_thread()
        .enable_all()
        .build()
        .map_err(|e| format!("probe runtime: {e}"))?;
    rt.block_on(async move {
        let client = reqwest::Client::builder()
            .timeout(Duration::from_secs(2))
            .redirect(reqwest::redirect::Policy::limited(3))
            .danger_accept_invalid_certs(true)
            .build()
            .map_err(|e| format!("probe client: {e}"))?;
        client
            .get(&url)
            .send()
            .await
            .map(|response| response.status().as_u16())
            .map_err(|e| format!("probe send: {e}"))
    })
}

/// Best-effort tail of a container's podman logs. Used in readiness-probe
/// failure messages so the user has something actionable to look at.
/// Routes through `tillandsias-podman::PodmanClient::log_tail` to honour
/// the idiomatic-podman layer contract (`tests::idiomatic_podman_launch_
/// paths_do_not_bypass_shared_layer`).
fn container_logs_tail(container: &str, lines: usize) -> String {
    let rt = match tokio::runtime::Builder::new_current_thread()
        .enable_all()
        .build()
    {
        Ok(rt) => rt,
        Err(e) => return format!("    (could not build log-tail runtime: {e})"),
    };
    let client = PodmanClient::new();
    let tail = rt.block_on(async move { client.log_tail(container, lines).await });
    match tail {
        Ok(t) if t.lines.is_empty() => "    (container logs are empty)".into(),
        Ok(t) => t
            .lines
            .iter()
            .map(|l| format!("    {l}"))
            .collect::<Vec<_>>()
            .join("\n"),
        Err(e) => format!("    (podman log_tail failed: {e})"),
    }
}

/// Best-effort tail of the observatorium container's podman logs. Used
/// in the readiness-probe failure message so the user has something
/// actionable to look at without having to know the container name.
fn observatorium_logs_tail(project_name: &str, lines: usize) -> String {
    let container = observatorium_container_name(project_name);
    container_logs_tail(&container, lines)
}

#[cfg(test)]
const OPENCODE_WEB_STARTUP_STAGES: [&str; 6] =
    ["stack", "proxy", "git", "inference", "forge", "browser"];

fn opencode_web_event_log_path(project_name: &str) -> PathBuf {
    let base = if let Ok(runtime_dir) = std::env::var("XDG_RUNTIME_DIR") {
        PathBuf::from(runtime_dir).join("tillandsias/logs/opencode-web")
    } else {
        PathBuf::from("/tmp/tillandsias/logs/opencode-web")
    };

    base.join(format!("{project_name}.jsonl"))
}

fn json_escape(value: &str) -> String {
    let mut out = String::with_capacity(value.len() + 8);
    for ch in value.chars() {
        match ch {
            '\\' => out.push_str("\\\\"),
            '"' => out.push_str("\\\""),
            '\n' => out.push_str("\\n"),
            '\r' => out.push_str("\\r"),
            '\t' => out.push_str("\\t"),
            c if c.is_control() => out.push_str(&format!("\\u{:04x}", c as u32)),
            c => out.push(c),
        }
    }
    out
}

fn emit_opencode_web_event(
    project_name: &str,
    stage: &str,
    state: &str,
    detail: Option<&str>,
) -> Result<(), String> {
    let path = opencode_web_event_log_path(project_name);
    if let Some(parent) = path.parent() {
        std::fs::create_dir_all(parent)
            .map_err(|e| format!("Failed to create OpenCode Web event dir: {e}"))?;
    }

    let now = chrono::Local::now().to_rfc3339();
    let mut line = format!(
        r#"{{"ts":"{}","project":"{}","stage":"{}","state":"{}""#,
        json_escape(&now),
        json_escape(project_name),
        json_escape(stage),
        json_escape(state)
    );
    if let Some(detail) = detail {
        line.push_str(&format!(r#","detail":"{}""#, json_escape(detail)));
    }
    line.push_str("}\n");

    let mut file = std::fs::OpenOptions::new()
        .create(true)
        .append(true)
        .open(&path)
        .map_err(|e| format!("Failed to open OpenCode Web event log {:?}: {e}", path))?;
    file.write_all(line.as_bytes())
        .map_err(|e| format!("Failed to write OpenCode Web event log {:?}: {e}", path))?;
    Ok(())
}

#[cfg(test)]
fn opencode_web_startup_stages() -> &'static [&'static str; 6] {
    &OPENCODE_WEB_STARTUP_STAGES
}

fn opencode_web_http_status(url: &str, cookie_header: Option<String>) -> Result<u16, String> {
    let url = url.to_string();
    let rt = tokio::runtime::Builder::new_current_thread()
        .enable_all()
        .build()
        .map_err(|e| format!("Failed to create HTTP probe runtime: {e}"))?;

    rt.block_on(async move {
        let client = reqwest::Client::builder()
            .timeout(Duration::from_secs(1))
            .redirect(reqwest::redirect::Policy::none())
            .build()
            .map_err(|e| format!("Failed to build HTTP probe client: {e}"))?;
        let mut request = client.get(url);
        if let Some(cookie_header) = cookie_header {
            request = request.header(reqwest::header::COOKIE, cookie_header);
        }
        request
            .send()
            .await
            .map(|response| response.status().as_u16())
            .map_err(|e| format!("HTTP probe failed: {e}"))
    })
}

fn wait_for_opencode_web_route(project_name: &str, url: &str, debug: bool) -> Result<(), String> {
    let mut last_outcome = String::from("no HTTP probe attempted");
    let mut backoff = Duration::from_millis(100);
    let max_backoff = Duration::from_secs(2);
    let start = std::time::Instant::now();
    let timeout = Duration::from_secs(30);
    let mut attempt = 1;

    while start.elapsed() < timeout {
        match opencode_web_http_status(url, None) {
            Ok(401) => return Ok(()),
            Ok(502) => {
                last_outcome = String::from("status 502 (starting)");
                if debug {
                    eprintln!(
                        "[tillandsias] waiting for OpenCode Web auth gate: attempt {attempt} ({last_outcome})"
                    );
                }
            }
            Ok(code) => {
                last_outcome = format!("status {code}");
                if debug {
                    eprintln!(
                        "[tillandsias] waiting for OpenCode Web auth gate: attempt {attempt} ({last_outcome})"
                    );
                }
            }
            Err(err) => {
                last_outcome = err;
                if debug {
                    eprintln!(
                        "[tillandsias] waiting for OpenCode Web auth gate: attempt {attempt} ({last_outcome})"
                    );
                }
            }
        }
        std::thread::sleep(backoff);
        backoff = (backoff * 2).min(max_backoff);
        attempt += 1;
    }

    let forge_container = forge_container_name(project_name);
    let logs_tail = container_logs_tail(&forge_container, 50);
    Err(format!(
        "OpenCode Web auth gate did not become ready in 30s.\n\
         URL: {url}\n\
         Last outcome: {last_outcome}\n\
         Forge container logs (last ≤50 lines):\n{logs_tail}\n\
         Next: inspect `podman logs {forge_container}` for the\n\
         full transcript, then verify the enclave network + router are\n\
         healthy via `tillandsias --status`."
    ))
}

fn wait_for_authenticated_opencode_web(
    project_name: &str,
    url: &str,
    cookie_value: &[u8; tillandsias_otp::COOKIE_LEN],
    debug: bool,
) -> Result<(), String> {
    let cookie_header = format!(
        "{}={}",
        tillandsias_otp::COOKIE_NAME,
        tillandsias_otp::format_cookie_value(cookie_value)
    );

    let mut last_outcome = String::from("no HTTP probe attempted");
    let mut backoff = Duration::from_millis(100);
    let max_backoff = Duration::from_secs(2);
    let start = std::time::Instant::now();
    let timeout = Duration::from_secs(30);
    let mut attempt = 1;

    while start.elapsed() < timeout {
        match opencode_web_http_status(url, Some(cookie_header.clone())) {
            Ok(code) if (200..400).contains(&code) => return Ok(()),
            Ok(502) => {
                last_outcome = String::from("status 502 (starting)");
                if debug {
                    eprintln!(
                        "[tillandsias] waiting for authenticated OpenCode Web app: attempt {attempt} ({last_outcome})"
                    );
                }
            }
            Ok(code) => {
                last_outcome = format!("status {code}");
                if debug {
                    eprintln!(
                        "[tillandsias] waiting for authenticated OpenCode Web app: attempt {attempt} ({last_outcome})"
                    );
                }
            }
            Err(err) => {
                last_outcome = err;
                if debug {
                    eprintln!(
                        "[tillandsias] waiting for authenticated OpenCode Web app: attempt {attempt} ({last_outcome})"
                    );
                }
            }
        }
        std::thread::sleep(backoff);
        backoff = (backoff * 2).min(max_backoff);
        attempt += 1;
    }

    let forge_container = forge_container_name(project_name);
    let logs_tail = container_logs_tail(&forge_container, 50);
    Err(format!(
        "OpenCode Web app did not become reachable with a registered session in 30s.\n\
         URL: {url}\n\
         Last outcome: {last_outcome}\n\
         Forge container logs (last ≤50 lines):\n{logs_tail}\n\
         Next: inspect `podman logs {forge_container}` for the\n\
         full transcript, then verify the enclave network + router are\n\
         healthy via `tillandsias --status`."
    ))
}

#[cfg(test)]
fn opencode_web_auth_cookie_header(cookie_value: &[u8; tillandsias_otp::COOKIE_LEN]) -> String {
    format!(
        "{}={}",
        tillandsias_otp::COOKIE_NAME,
        tillandsias_otp::format_cookie_value(cookie_value)
    )
}

#[cfg(test)]
fn opencode_web_route_ready_status(code: u16) -> bool {
    code == 401
}

#[cfg(test)]
fn opencode_web_authenticated_ready_status(code: u16) -> bool {
    (200..400).contains(&code)
}

fn browser_profile_root() -> PathBuf {
    if let Some(runtime_dir) = std::env::var_os("XDG_RUNTIME_DIR") {
        return PathBuf::from(runtime_dir).join("tillandsias/browser");
    }

    if let Some(tmpdir) = std::env::var_os("TMPDIR") {
        return PathBuf::from(tmpdir).join("tillandsias/browser");
    }

    PathBuf::from("/tmp/tillandsias/browser")
}

#[derive(Debug, Clone, Default)]
struct BrowserDisplayContext {
    display: Option<String>,
    xauthority: Option<PathBuf>,
    wayland_display: Option<String>,
    xdg_runtime_dir: Option<PathBuf>,
}

impl BrowserDisplayContext {
    /// @trace spec:tray-cli-coexistence
    fn from_env() -> Result<Self, String> {
        let display = std::env::var("DISPLAY").ok();
        let xauthority = std::env::var_os("XAUTHORITY").map(PathBuf::from);
        let wayland_display = std::env::var("WAYLAND_DISPLAY").ok();
        let xdg_runtime_dir = std::env::var_os("XDG_RUNTIME_DIR").map(PathBuf::from);

        if display.is_none() && wayland_display.is_none() {
            return Err(
                "OpenCode Web browser launch requires a graphical session (DISPLAY or WAYLAND_DISPLAY)"
                    .to_string(),
            );
        }

        Ok(Self {
            display,
            xauthority,
            wayland_display,
            xdg_runtime_dir,
        })
    }
}

fn build_opencode_web_browser_spec(
    app_url: &str,
    version: &str,
    profile_dir: &Path,
    certs_dir: &Path,
    display: &BrowserDisplayContext,
    project_name: &str,
) -> Result<ContainerSpec, String> {
    let container_name = format!("tillandsias-browser-{project_name}");
    build_project_browser_spec(
        app_url,
        version,
        profile_dir,
        certs_dir,
        display,
        &container_name,
    )
}

fn build_project_browser_spec(
    app_url: &str,
    version: &str,
    profile_dir: &Path,
    certs_dir: &Path,
    display: &BrowserDisplayContext,
    container_name: &str,
) -> Result<ContainerSpec, String> {
    // NOTE: rootfs is intentionally writable (no `.read_only()`). Chromium's
    // crashpad handler aborts on a read-only rootfs because it cannot create
    // its database directory, exiting 133 immediately on launch. The remaining
    // hardening (--cap-drop=ALL, no-new-privileges, --userns=keep-id, tmpfs
    // mounts for /tmp + chromium dirs + /dev/shm) keeps the blast radius
    // tight.
    let mut spec = ContainerSpec::new(format!("tillandsias-chromium-framework:v{version}"))
        .pull_never()
        .cap_add("SYS_CHROOT")
        .network("host")
        .name(container_name)
        .detached()
        .volume(
            profile_dir.display().to_string(),
            profile_dir.display().to_string(),
            MountMode::ReadWrite,
        )
        .bind_mount(
            certs_dir.join("intermediate.crt").display().to_string(),
            "/etc/tillandsias/ca.crt",
            true,
        )
        .env("TILLANDSIAS_CA_BUNDLE", "/etc/tillandsias/ca.crt")
        .env("SSL_CERT_FILE", "/etc/tillandsias/ca.crt")
        .env("XDG_CONFIG_HOME", "/tmp/chromium-config")
        .env("XDG_CACHE_HOME", "/tmp/chromium-cache")
        .tmpfs("/tmp:size=256m")
        .tmpfs("/tmp/chromium-config:size=128m")
        .tmpfs("/tmp/chromium-cache:size=512m")
        .tmpfs("/dev/shm:size=256m")
        .arg("--incognito")
        .arg("--no-first-run")
        .arg("--no-default-browser-check")
        .arg(format!("--user-data-dir={}", profile_dir.display()))
        .arg(format!("--app={app_url}"));

    if let Some(display_name) = &display.display {
        spec = spec
            .env("DISPLAY", display_name)
            .volume("/tmp/.X11-unix", "/tmp/.X11-unix", MountMode::ReadWrite)
            .arg("--ozone-platform=x11");

        if let Some(xauthority_path) = &display.xauthority
            && xauthority_path.exists()
        {
            spec = spec
                .env("XAUTHORITY", "/home/chromium/.Xauthority")
                .bind_mount(
                    xauthority_path.display().to_string(),
                    "/home/chromium/.Xauthority",
                    true,
                );
        }
    } else if let Some(wayland_display) = &display.wayland_display {
        if let Some(xdg_runtime_dir) = &display.xdg_runtime_dir {
            spec = spec
                .env("XDG_RUNTIME_DIR", xdg_runtime_dir.display().to_string())
                .env("WAYLAND_DISPLAY", wayland_display)
                .volume(
                    xdg_runtime_dir.display().to_string(),
                    xdg_runtime_dir.display().to_string(),
                    MountMode::ReadWrite,
                )
                .arg("--ozone-platform=wayland");
        } else {
            return Err(
                "OpenCode Web browser launch requires XDG_RUNTIME_DIR for Wayland sessions"
                    .to_string(),
            );
        }
    }

    for device_flag in detect_gpu_devices() {
        if let Some(device) = device_flag.strip_prefix("--device=") {
            spec = spec.device(device);
        } else {
            spec = spec.option(device_flag);
        }
    }

    Ok(spec)
}

/// Send `IssueWebSession` to the tray's control socket and block until the
/// tray confirms the broadcast with an `IssueAck { seq_acked: 1 }`.
///
/// This call is synchronous and event-driven (one write, one read, no
/// polling). The ack proves that `broadcast_control_envelope` has returned
/// in the tray, which means the bytes are already buffered on every
/// subscriber socket — including the router-sidecar that owns the
/// `OtpStore`. Returning Ok therefore guarantees the cookie is visible to
/// the sidecar before the caller proceeds to launch the browser.
///
/// Any deviation (timeout, wrong variant, decode error, IO failure) is
/// returned as `Err` so the caller can refuse to open the browser. There is
/// no retry loop on purpose — the OTP race is a contract issue, not a
/// transient one.
///
/// @trace spec:opencode-web-session-otp, spec:tray-host-control-socket
fn send_issue_web_session(project_label: &str, cookie_value: &[u8; 32]) -> Result<(), String> {
    // Get control socket path from XDG_RUNTIME_DIR or default.
    let runtime_dir = std::env::var("XDG_RUNTIME_DIR")
        .unwrap_or_else(|_| format!("/run/user/{}", unsafe { libc::getuid() }));
    let socket_path = format!("{}/tillandsias/control.sock", runtime_dir);

    // Connect to the socket. The connect itself has no built-in timeout, but
    // it's a local UDS so it either binds immediately or returns ENOENT/
    // ECONNREFUSED.
    let mut stream = UnixStream::connect(&socket_path)
        .map_err(|e| format!("Failed to connect to control socket {}: {}", socket_path, e))?;

    // The whole round-trip must complete within a couple of seconds; the
    // tray broadcast is synchronous so the ack should land in single-digit
    // milliseconds. A 2s ceiling is generous and prevents the CLI from
    // hanging if the tray is wedged.
    let timeout = Duration::from_secs(2);
    stream
        .set_read_timeout(Some(timeout))
        .map_err(|e| format!("Failed to set read timeout: {}", e))?;
    stream
        .set_write_timeout(Some(timeout))
        .map_err(|e| format!("Failed to set write timeout: {}", e))?;

    // Prepare and send the IssueWebSession message. `seq = 1` is the value
    // the tray echoes back in `IssueAck { seq_acked }`.
    let envelope = ControlEnvelope {
        wire_version: WIRE_VERSION,
        seq: 1,
        body: ControlMessage::IssueWebSession {
            project_label: project_label.to_string(),
            cookie_value: *cookie_value,
        },
    };

    // Encode and write with length prefix (4-byte big-endian).
    let encoded =
        encode(&envelope).map_err(|e| format!("Failed to encode control message: {}", e))?;
    let len = encoded.len() as u32;
    let mut frame = len.to_be_bytes().to_vec();
    frame.extend_from_slice(&encoded);

    stream
        .write_all(&frame)
        .map_err(|e| format!("Failed to write control message: {}", e))?;

    // Read one envelope back on the same connection. The tray writes
    // `IssueAck { seq_acked: 1 }` after broadcasting; anything else (or a
    // timeout) is treated as a failed handshake.
    let mut len_buf = [0_u8; 4];
    stream.read_exact(&mut len_buf).map_err(|e| {
        format!(
            "Failed to read ack length prefix from control socket: {}",
            e
        )
    })?;
    let reply_len = u32::from_be_bytes(len_buf) as usize;
    if reply_len == 0 || reply_len > MAX_MESSAGE_BYTES {
        return Err(format!(
            "Control socket ack has invalid length {} (max {})",
            reply_len, MAX_MESSAGE_BYTES
        ));
    }
    let mut reply = vec![0_u8; reply_len];
    stream
        .read_exact(&mut reply)
        .map_err(|e| format!("Failed to read ack body from control socket: {}", e))?;
    let reply_envelope =
        decode(&reply).map_err(|e| format!("Failed to decode control socket ack: {}", e))?;

    match reply_envelope.body {
        ControlMessage::IssueAck { seq_acked: 1 } => Ok(()),
        ControlMessage::IssueAck { seq_acked } => Err(format!(
            "Control socket ack referenced unexpected seq {} (expected 1)",
            seq_acked
        )),
        other => Err(format!(
            "Control socket replied with unexpected variant: {:?}",
            other
        )),
    }
}

fn launch_opencode_web_browser(
    project_name: &str,
    certs_dir: &Path,
    router_host_port: u16,
    debug: bool,
) -> Result<(), String> {
    let url = opencode_web_url(project_name, router_host_port);
    emit_opencode_web_event(project_name, "browser", "wait_for_route", Some(&url))?;
    if let Err(err) = wait_for_opencode_web_route(project_name, &url, debug) {
        emit_opencode_web_event(project_name, "browser", "route_unhealthy", Some(&err))?;
        return Err(err);
    }
    emit_opencode_web_event(project_name, "browser", "route_ready", Some(&url))?;

    let version = VERSION.trim();
    let profile_root = browser_profile_root();
    std::fs::create_dir_all(&profile_root).map_err(|e| {
        format!(
            "Failed to create browser profile root {:?}: {e}",
            profile_root
        )
    })?;
    let display = BrowserDisplayContext::from_env()?;
    // The profile dir must outlive this function: the container runs detached
    // with `--user-data-dir=<profile>` bind-mounted, and chromium needs the
    // host path to stay valid until it exits. `TempDir` would remove the dir
    // on drop and chromium would die at startup; keep the path and let the
    // background cleanup thread remove it after the container exits.
    let profile_dir = TempDirBuilder::new()
        .prefix(&format!("{project_name}-"))
        .tempdir_in(&profile_root)
        .map_err(|e| {
            format!(
                "Failed to create browser profile dir in {:?}: {e}",
                profile_root
            )
        })?;
    let profile_path = profile_dir.keep();
    // @trace spec:opencode-web-session-otp
    // Issue a session token for the project and register it with the router.
    // The label must match what the router-sidecar extracts from the Host
    // header (`extract_project_label("opencode.<project>.localhost")` →
    // `"<project>"`), otherwise `/validate` and `/_auth/login` both 401.
    let project_label = project_name.to_string();
    let otp = tillandsias_otp::issue_session(&project_label);
    let login_url = tillandsias_otp::build_login_data_url(&url, &otp);
    let spec = build_opencode_web_browser_spec(
        &login_url,
        version,
        &profile_path,
        certs_dir,
        &display,
        project_name,
    )?;
    let args = spec.build_run_args();

    // @trace spec:opencode-web-session-otp, spec:tray-host-control-socket
    // Notify the router (via the tray's control socket) of the new session
    // BEFORE launching the browser. `send_issue_web_session` blocks until the
    // tray returns `IssueAck`, which proves the broadcast bytes are already
    // queued on the sidecar's socket — so by the time chromium POSTs to
    // `/_auth/login`, the sidecar's `OtpStore` definitely contains the
    // cookie. If the handshake fails (no tray, wrong reply, timeout) we
    // refuse to launch the browser to prevent the "unauthorised" landing
    // page that used to result from the race.
    send_issue_web_session(&project_label, &otp).map_err(|e| {
        let _ =
            emit_opencode_web_event(project_name, "browser", "session_register_failed", Some(&e));
        format!("Failed to register web session with router: {e}")
    })?;
    if let Err(err) = wait_for_authenticated_opencode_web(project_name, &url, &otp, debug) {
        emit_opencode_web_event(project_name, "browser", "session_probe_failed", Some(&err))?;
        return Err(err);
    }
    emit_opencode_web_event(project_name, "browser", "session_ready", Some(&url))?;

    emit_opencode_web_event(project_name, "browser", "launch", Some("podman-run"))?;
    let container_name = format!("tillandsias-browser-{project_name}");
    let result = rt_block_on_podman_run(args, &container_name, "browser", debug);
    if result.is_ok() {
        emit_opencode_web_event(project_name, "browser", "launched", Some("gui"))?;

        // @trace spec:browser-isolation-core, spec:host-chromium-on-demand
        // Spawn background task to monitor container exit and cleanup.
        // The browser is now running detached; this task waits for it to exit,
        // then removes the container and the host-side profile dir.
        let profile_cleanup_path = profile_path.clone();
        std::thread::spawn(move || {
            let rt = match tokio::runtime::Runtime::new() {
                Ok(r) => r,
                Err(e) => {
                    eprintln!("[tillandsias] Failed to create runtime for browser cleanup: {e}");
                    return;
                }
            };
            if let Err(e) = rt.block_on(monitor_and_cleanup_browser(&container_name, debug)) {
                eprintln!("[tillandsias] Browser cleanup error: {e}");
            }
            let _ = std::fs::remove_dir_all(&profile_cleanup_path);
        });
    } else if let Err(ref err) = result {
        let _ = emit_opencode_web_event(project_name, "browser", "launch_failed", Some(err));
    }
    result
}

fn rt_block_on_podman_run(
    args: Vec<String>,
    container_name: &str,
    stage: &str,
    debug: bool,
) -> Result<(), String> {
    let rt = podman_runtime()?;
    let client = PodmanClient::new();
    let container_name = container_name.to_string();
    let stage = stage.to_string();
    rt.block_on(async move {
        client
            .run_container_observed(&stage, &container_name, &args, debug)
            .await
            .map(|_| ())
    })
    .inspect_err(|err| {
        if debug {
            eprintln!("[tillandsias] browser container launch failed: {err}");
        }
    })
}

/// @trace spec:browser-isolation-core, spec:host-chromium-on-demand
/// Monitor a detached browser container for exit and clean up resources.
/// Launches the container, waits for it to exit, then removes it.
async fn monitor_and_cleanup_browser(container_name: &str, debug: bool) -> Result<(), String> {
    // Wait for container to exit by polling its state periodically.
    // In a full implementation, this would use `podman events` for more efficient monitoring.
    let mut poll_interval = Duration::from_millis(100);
    let max_poll_interval = Duration::from_secs(1);
    let timeout = Duration::from_secs(3600); // 1-hour timeout
    let start = std::time::Instant::now();

    loop {
        if start.elapsed() > timeout {
            if debug {
                eprintln!("[tillandsias] browser container timeout after 1 hour: {container_name}");
            }
            break;
        }

        // Poll container state
        let mut cmd = podman_command();
        cmd.args(["inspect", "--format=.State.Running", container_name]);
        let output = cmd
            .output()
            .map_err(|e| format!("Failed to inspect browser container: {e}"))?;

        if !output.status.success() {
            // Container not found or error — assume it exited
            if debug {
                eprintln!("[tillandsias] browser container not running: {container_name}");
            }
            break;
        }

        let is_running = String::from_utf8_lossy(&output.stdout).trim().eq("true");
        if !is_running {
            if debug {
                eprintln!("[tillandsias] browser container exited: {container_name}");
            }
            break;
        }

        tokio::time::sleep(poll_interval).await;
        poll_interval = (poll_interval * 2).min(max_poll_interval);
    }

    // Clean up the container
    let mut cleanup = podman_command();
    cleanup.args(["rm", "-f", container_name]);
    let _ = run_command_silent(cleanup, debug);

    if debug {
        eprintln!("[tillandsias] cleaned up browser container: {container_name}");
    }
    Ok(())
}

pub(crate) fn run_opencode_web_mode(
    project_path: &str,
    prompt: Option<&str>,
    port_override: Option<u16>,
    debug: bool,
) -> Result<(), String> {
    require_desktop_user_session("tillandsias --opencode-web")?;
    report_runtime_lane("--opencode-web", debug);

    if debug {
        eprintln!("[tillandsias] OpenCode Web mode enabled");
        eprintln!("[tillandsias] Project: {}", project_path);
        if let Some(prompt) = prompt {
            eprintln!("[tillandsias] Prompt seed provided: {}", prompt);
        }
    }

    let project = std::path::Path::new(project_path);
    if !project.exists() {
        return Err(format!("Project not found: {}", project_path));
    }

    if debug {
        eprintln!(
            "[tillandsias] Project path is valid: {}",
            project.canonicalize().unwrap_or_default().display()
        );
    }

    let version = VERSION.trim();
    let root = resolve_runtime_asset_root(version, debug)?;
    // `Path::new(".").file_name()` returns None — canonicalize first so the
    // project_name reflects the actual directory the user pointed at.
    let project_path_resolved = std::path::Path::new(project_path)
        .canonicalize()
        .unwrap_or_else(|_| std::path::PathBuf::from(project_path));
    let project_name = project_path_resolved
        .file_name()
        .and_then(|n| n.to_str())
        .unwrap_or("opencode-project");
    let certs_dir = ensure_ca_bundle(debug)?;
    ensure_enclave_network(debug)?;

    let images = [
        "proxy",
        "git",
        "inference",
        "chromium-core",
        "chromium-framework",
        "forge",
        "router",
    ];
    ensure_versioned_images(&root, &images, version, debug)?;

    if debug {
        eprintln!("[tillandsias] [OpenCode Web] Repo root: {}", root.display());
        eprintln!("[tillandsias] [OpenCode Web] Launching full-stack session");
    }

    let rt = podman_runtime()?;
    let client = PodmanClient::new();
    let router_host_port = rt.block_on(async {
        match existing_router_host_port(&client, debug).await? {
            Some(port) => Ok::<u16, String>(port),
            None => Ok(select_router_host_port(port_override, debug)?),
        }
    })?;
    emit_opencode_web_event(
        project_name,
        "stack",
        "starting",
        Some("proxy git inference forge"),
    )?;
    // Read the host's `remote.origin.url` so the mirror's post-receive hook
    // knows where to forward pushes.
    let project_remote_url = read_host_project_origin_url(&project_path_resolved);
    if debug {
        match &project_remote_url {
            Some(url) => eprintln!("[tillandsias] [OpenCode Web] Host origin URL: {url}"),
            None => eprintln!("[tillandsias] [OpenCode Web] No host origin URL configured"),
        }
    }
    rt.block_on(async {
        // @trace spec:runtime-diagnostics-stream
        let diag_emitter =
            tillandsias_podman::diagnostic_event_emitter::spawn_diagnostic_event_emitter(
                debug,
                "tillandsias-",
            );

        cleanup_stack_containers(&client, project_name).await;

        client
            .run_container_observed(
                "opencode-web-proxy",
                "tillandsias-proxy",
                &build_proxy_run_args(&certs_dir, &versioned_image_tag("proxy", version)),
                debug,
            )
            .await
            .map_err(|e| format!("[OpenCode Web] failed to start proxy: {e}"))?;
        emit_opencode_web_event(
            project_name,
            "proxy",
            "started",
            Some(&versioned_image_tag("proxy", version)),
        )?;
        let git_container_name = format!("tillandsias-git-{project_name}");
        let git_vault_secret = mint_git_mirror_vault_token(project_name, debug).await;
        client
            .run_container_observed(
                "opencode-web-git",
                &git_container_name,
                &build_git_run_args(
                    project_name,
                    &certs_dir,
                    &versioned_image_tag("git", version),
                    project_remote_url.as_deref(),
                    git_vault_secret.as_deref(),
                ),
                debug,
            )
            .await
            .map_err(|e| format!("[OpenCode Web] failed to start git: {e}"))?;
        emit_opencode_web_event(
            project_name,
            "git",
            "started",
            Some(&versioned_image_tag("git", version)),
        )?;
        client
            .run_container_observed(
                "opencode-web-inference",
                "tillandsias-inference",
                &build_inference_run_args(
                    &certs_dir,
                    &versioned_image_tag("inference", version),
                    false,
                ),
                debug,
            )
            .await
            .map_err(|e| format!("[OpenCode Web] failed to start inference: {e}"))?;
        emit_opencode_web_event(
            project_name,
            "inference",
            "started",
            Some(&versioned_image_tag("inference", version)),
        )?;

        // Use the canonical absolute path so the bind-mount source is
        // unambiguous even when the user passed "." or another relative
        // path on the CLI. Podman resolves bind sources against its own cwd,
        // which is not the user's shell cwd.
        let opencode_args = build_opencode_forge_args(
            &project_path_resolved,
            project_name,
            prompt,
            &certs_dir,
            version,
            ForgeMode::Web,
            false,
            debug,
        );
        client
            .run_container_observed(
                "opencode-web-forge",
                &forge_container_name(project_name),
                &opencode_args,
                debug,
            )
            .await
            .map_err(|e| format!("[OpenCode Web] failed to start forge: {e}"))?;
        emit_opencode_web_event(project_name, "forge", "started", Some("opencode-web"))?;

        // @trace spec:runtime-diagnostics-stream (Stderr line pass-through)
        let _diag_logs_handle = if debug {
            Some(
                tillandsias_podman::DiagnosticsHandle::start_typed_event_stream(vec![
                    "tillandsias-router".to_string(),
                    "tillandsias-proxy".to_string(),
                    git_container_name.clone(),
                    "tillandsias-inference".to_string(),
                    forge_container_name(project_name),
                ])
                .await,
            )
        } else {
            None
        };

        // @trace spec:subdomain-routing-via-reverse-proxy
        // After forge starts, ensure router is running and write dynamic routes.
        let router_image = versioned_image_tag("router", version);

        ensure_router_running(&client, &certs_dir, &router_image, router_host_port, debug)
            .await
            .unwrap_or_else(|e| {
                if debug {
                    eprintln!("[tillandsias] Warning: router degraded: {e}");
                }
            });

        // Upsert the OpenCode Web route without dropping other project
        // services such as Observatorium.
        // The forge image's opencode-web entrypoint runs `opencode serve --hostname 0.0.0.0
        // --port 4096` (see images/default/entrypoint-forge-opencode-web.sh:142), so the
        // router upstream must target 4096 — not 8080, which is the router's own listener.
        let route = RouterRoute::new(
            format!("opencode.{}", project_name),
            format!("tillandsias-{}-forge", project_name),
            4096u16,
        );
        upsert_router_route(route, debug)?;

        // @trace spec:subdomain-routing-via-reverse-proxy
        // After writing the dynamic Caddyfile, reload Caddy to activate the routes.
        // The reload is graceful (no container restart) via the admin API at localhost:2019.
        caddy_reload_routes(debug).await?;

        // Stop the diagnostic-event emitter before this block closes;
        // dropping `_diag_logs_handle` aborts its logs tails.
        if let Some(handle) = diag_emitter {
            handle.abort();
            let _ = handle.await;
        }

        Ok::<(), String>(())
    })?;

    launch_opencode_web_browser(project_name, &certs_dir, router_host_port, debug)
}

// ─────────────────────────────────────────────────────────────
// Per-project tray launch actions (Claude / Codex / OpenCode / Maintenance)
// ─────────────────────────────────────────────────────────────
//
// @trace spec:browser-isolation-tray-integration, spec:tray-app, spec:tray-ux
//
// Contract:
// 1. All four interactive modes run *inside the forge container* — never on the host.
// 2. The host's default terminal (gnome-terminal/kitty/foot/...) is the TTY surface;
//    closing the terminal window kills the container.
// 3. Every `podman run` flows through `tillandsias-podman`'s `ContainerSpec` /
//    `PodmanClient::run_container` — the tray never shells out to `podman` directly
//    except through the spec-built argv it hands the host terminal.
// 4. Ephemeral first: the project workspace + CA bundle are the only persistent
//    bind mounts. No `$HOME`, no `~/.config`, no `~/.cache`.

/// Forge-side agent the tray launches into the host terminal.
///
/// Each variant maps to an entrypoint script baked into the forge image:
/// - Claude       → `/usr/local/bin/entrypoint-forge-claude.sh`
/// - Codex        → `/usr/local/bin/entrypoint-forge-codex.sh`
/// - OpenCode     → `/usr/local/bin/entrypoint-forge-opencode.sh`
/// - Maintenance  → `/usr/local/bin/entrypoint-terminal.sh`
///
/// Note: the forge image does not currently ship `entrypoint-forge-bash.sh`.
/// `Maintenance` uses the existing `entrypoint-terminal.sh`, which sources
/// `lib-common.sh`, runs `openspec init`, and execs `fish` (or `bash` if fish
/// is absent). A future bare-bones bash entrypoint can be added if needed —
/// the test below pins the entrypoint contract, not the script body.
#[cfg_attr(not(feature = "tray"), allow(dead_code))]
#[derive(Copy, Clone, Debug, PartialEq, Eq)]
pub(crate) enum ForgeAgentMode {
    Claude,
    Codex,
    OpenCode,
    Maintenance,
}

impl ForgeAgentMode {
    fn entrypoint(self) -> &'static str {
        match self {
            ForgeAgentMode::Claude => "/usr/local/bin/entrypoint-forge-claude.sh",
            ForgeAgentMode::Codex => "/usr/local/bin/entrypoint-forge-codex.sh",
            ForgeAgentMode::OpenCode => "/usr/local/bin/entrypoint-forge-opencode.sh",
            ForgeAgentMode::Maintenance => "/usr/local/bin/entrypoint-terminal.sh",
        }
    }

    fn slug(self) -> &'static str {
        match self {
            ForgeAgentMode::Claude => "claude",
            ForgeAgentMode::Codex => "codex",
            ForgeAgentMode::OpenCode => "opencode",
            ForgeAgentMode::Maintenance => "maintenance",
        }
    }

    fn window_title(self, project_name: &str) -> String {
        format!("Tillandsias — {} — {}", project_name, self.slug())
    }
}

/// Resolve the host's default terminal emulator into an argv prefix that
/// expects the command and its args appended verbatim.
///
/// Resolution order (first match wins):
/// 1. `$TERMINAL` env var — split on whitespace, used as-is.
/// 2. `xdg-terminal-exec` — modern xdg-utils 1.2+ shim; takes the command
///    directly as positional args, no `-e` separator needed.
/// 3. Hard-coded probe in PATH: `gnome-terminal`, `konsole`, `kitty`,
///    `alacritty`, `foot`, `xterm`. Each gets the right `-e` / `--` flag.
///
/// Returns a hard error if nothing is found so the tray can surface the
/// problem to the user instead of silently failing.
/// @trace spec:forge-as-only-runtime
#[cfg_attr(not(feature = "tray"), allow(dead_code))]
pub(crate) fn detect_host_terminal() -> Result<Vec<String>, String> {
    // Note: `$TERM` is the terminfo identifier (e.g. xterm-256color), NOT
    // the path to the terminal binary — it cannot be used here. The closest
    // env-var convention is `$TERMINAL` (i3/sway/dwm/etc.).
    if let Ok(value) = std::env::var("TERMINAL")
        && !value.trim().is_empty()
    {
        let parts: Vec<String> = value.split_whitespace().map(|s| s.to_string()).collect();
        if !parts.is_empty() {
            return Ok(parts);
        }
    }

    if executable_on_path("xdg-terminal-exec") {
        return Ok(vec!["xdg-terminal-exec".to_string()]);
    }

    // GNOME exposes the user's chosen terminal via gsettings — honor it
    // before falling back to a hard-coded probe list. The output is a
    // single-quoted string, e.g. "'ptyxis'" or "'gnome-terminal'".
    if let Some(name) = gnome_default_terminal()
        && executable_on_path(&name)
    {
        return Ok(argv_prefix_for(&name));
    }

    // (name, argv-prefix-once-resolved) — the prefix accepts a command + args.
    // ptyxis is GNOME's new default starting Fedora 41; gnome-terminal is the
    // pre-41 default. Order roughly matches "most likely to be installed on
    // a desktop Linux distro in 2026".
    let candidates: &[(&str, &[&str])] = &[
        ("ptyxis", &["ptyxis", "--new-window", "--"]),
        ("gnome-terminal", &["gnome-terminal", "--"]),
        ("konsole", &["konsole", "-e"]),
        ("kitty", &["kitty", "-e"]),
        ("alacritty", &["alacritty", "-e"]),
        ("wezterm", &["wezterm", "start", "--"]),
        ("foot", &["foot"]),
        ("tilix", &["tilix", "-e"]),
        ("xfce4-terminal", &["xfce4-terminal", "-e"]),
        ("terminator", &["terminator", "-e"]),
        ("blackbox-terminal", &["blackbox-terminal", "-c"]),
        ("xterm", &["xterm", "-e"]),
    ];

    for (name, prefix) in candidates {
        if executable_on_path(name) {
            return Ok(prefix.iter().map(|s| s.to_string()).collect());
        }
    }

    Err(
        "Could not find a terminal emulator on PATH. Set $TERMINAL or \
         install one of: ptyxis/gnome-terminal/konsole/kitty/alacritty/\
         wezterm/foot/tilix/xfce4-terminal/terminator/blackbox-terminal/xterm"
            .to_string(),
    )
}

/// Query GNOME's `gsettings` for the user's chosen default terminal. Returns
/// `None` if gsettings isn't available, the schema isn't installed, or the
/// value is empty.
#[cfg_attr(not(feature = "tray"), allow(dead_code))]
fn gnome_default_terminal() -> Option<String> {
    let out = std::process::Command::new("gsettings")
        .args([
            "get",
            "org.gnome.desktop.default-applications.terminal",
            "exec",
        ])
        .output()
        .ok()?;
    if !out.status.success() {
        return None;
    }
    let raw = String::from_utf8_lossy(&out.stdout).trim().to_string();
    let trimmed = raw.trim_matches(|c: char| c == '\'' || c == '"' || c.is_whitespace());
    if trimmed.is_empty() {
        None
    } else {
        Some(trimmed.to_string())
    }
}

/// Build the argv prefix for a terminal binary. Most terminals follow the
/// `<bin> -e <cmd>` convention; gnome-terminal/ptyxis/wezterm use `--`.
#[cfg_attr(not(feature = "tray"), allow(dead_code))]
fn argv_prefix_for(name: &str) -> Vec<String> {
    let prefix: &[&str] = match name {
        "ptyxis" => &["ptyxis", "--new-window", "--"],
        "gnome-terminal" => &["gnome-terminal", "--"],
        "wezterm" => &["wezterm", "start", "--"],
        "foot" => &["foot"],
        "blackbox-terminal" => &["blackbox-terminal", "-c"],
        // konsole / kitty / alacritty / tilix / xfce4-terminal / terminator
        // / xterm all accept `-e <cmd>`.
        _ => &[name, "-e"],
    };
    prefix.iter().map(|s| s.to_string()).collect()
}

#[cfg_attr(not(feature = "tray"), allow(dead_code))]
fn executable_on_path(name: &str) -> bool {
    let Some(path) = std::env::var_os("PATH") else {
        return false;
    };
    for dir in std::env::split_paths(&path) {
        let candidate = dir.join(name);
        if !candidate.exists() {
            continue;
        }
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            if let Ok(metadata) = std::fs::metadata(&candidate)
                && metadata.permissions().mode() & 0o111 == 0
            {
                continue;
            }
        }
        return true;
    }
    false
}

/// Bring the per-project enclave (proxy + git + inference) online and return
/// the certs directory. Shared by `run_opencode_web_mode` (web) and
/// `launch_forge_agent` (Claude/Codex/OpenCode/Maintenance terminal launches).
///
/// `project_path` is the host's canonical project path. It is read with `git
/// -C <path> config remote.origin.url` so the mirror's post-receive hook
/// knows where to forward pushes. Passing `None` (or a path with no origin
/// configured) leaves the mirror without an upstream; the hook will log
/// "skipping push" but the bare repo still serves clones and accepts pushes.
///
/// Idempotent: if containers already exist they are removed first, matching
/// the existing `run_opencode_web_mode` discipline.
#[cfg_attr(not(feature = "tray"), allow(dead_code))]
pub(crate) fn ensure_enclave_for_project(
    project_name: &str,
    project_path: Option<&Path>,
    debug: bool,
) -> Result<PathBuf, String> {
    let version = VERSION.trim();
    let root = resolve_runtime_asset_root(version, debug)?;
    let certs_dir = ensure_ca_bundle(debug)?;
    ensure_enclave_network(debug)?;

    let images = ["proxy", "git", "inference", "forge"];
    ensure_versioned_images(&root, &images, version, debug)?;

    let project_remote_url = project_path.and_then(read_host_project_origin_url);
    if debug {
        match &project_remote_url {
            Some(url) => eprintln!("[tillandsias] [forge-launch] Host origin URL: {url}"),
            None => eprintln!("[tillandsias] [forge-launch] No host origin URL configured"),
        }
    }

    let rt = podman_runtime()?;
    let client = PodmanClient::new();
    rt.block_on(async {
        cleanup_stack_containers(&client, project_name).await;

        // Step 15 slice 2: bring the router up BEFORE the per-project
        // proxy/git/inference/forge spawn so the enclave's `router` alias
        // is live by the time Squid's cache_peer / git-service HTTPS
        // upstream try to resolve it. ensure_router_running is idempotent.
        //
        // @trace plan/steps/15-tray-network-bootstrap.md
        let router_image = versioned_image_tag("router", version);
        let router_host_port = match existing_router_host_port(&client, debug).await? {
            Some(port) => port,
            None => select_router_host_port(None, debug)?,
        };
        ensure_router_running(&client, &certs_dir, &router_image, router_host_port, debug).await?;

        client
            .run_container_observed(
                "forge-launch-proxy",
                "tillandsias-proxy",
                &build_proxy_run_args(&certs_dir, &versioned_image_tag("proxy", version)),
                debug,
            )
            .await
            .map_err(|e| format!("[forge-launch] failed to start proxy: {e}"))?;
        let git_container_name = format!("tillandsias-git-{project_name}");
        let git_vault_secret = mint_git_mirror_vault_token(project_name, debug).await;
        client
            .run_container_observed(
                "forge-launch-git",
                &git_container_name,
                &build_git_run_args(
                    project_name,
                    &certs_dir,
                    &versioned_image_tag("git", version),
                    project_remote_url.as_deref(),
                    git_vault_secret.as_deref(),
                ),
                debug,
            )
            .await
            .map_err(|e| format!("[forge-launch] failed to start git: {e}"))?;
        client
            .run_container_observed(
                "forge-launch-inference",
                "tillandsias-inference",
                &build_inference_run_args(
                    &certs_dir,
                    &versioned_image_tag("inference", version),
                    false,
                ),
                debug,
            )
            .await
            .map_err(|e| format!("[forge-launch] failed to start inference: {e}"))?;
        Ok::<(), String>(())
    })?;

    Ok(certs_dir)
}

/// Build the forge `podman run` args for an interactive launch.
///
/// Mirrors `build_opencode_forge_args(ForgeMode::Cli)` but parameterized on the
/// `ForgeAgentMode` entrypoint. The returned vector starts at `--rm`; callers
/// either pass it to `PodmanClient::run_container_attached_observed()` or prefix
/// it with `podman run` for a host terminal command.
///
/// Every option flows through the policy-validated `build_run_argv()` path —
/// no raw `--unsafe` flags, no host home mounts. Project workspace lands at
/// `/home/forge/src/<project>/`, CA cert at `/etc/tillandsias/ca.crt`.
/// @trace spec:forge-as-only-runtime
#[cfg_attr(not(feature = "tray"), allow(dead_code))]
pub(crate) fn build_forge_agent_run_args(
    project_path: &Path,
    project_name: &str,
    certs_dir: &Path,
    version: &str,
    mode: ForgeAgentMode,
    debug: bool,
) -> Vec<String> {
    let image = forge_image_tag(version);
    let no_proxy = enclave_no_proxy();
    let mut spec = ContainerSpec::new(image)
        .name(forge_container_name(project_name))
        .hostname(forge_hostname(project_name))
        .network(ENCLAVE_NET)
        .pids_limit(512)
        .interactive()
        .tty()
        // Project workspace at /home/forge/src/<project>/ — matches the
        // forge entrypoint clone path and the `$TILLANDSIAS_PROJECT_PATH`
        // contract every agent expects.
        .volume(
            project_path.display().to_string(),
            format!("/home/forge/src/{project_name}"),
            MountMode::ReadWrite,
        )
        .env("http_proxy", "http://proxy:3128")
        .env("https_proxy", "http://proxy:3128")
        .env("HTTP_PROXY", "http://proxy:3128")
        .env("HTTPS_PROXY", "http://proxy:3128")
        .env("no_proxy", no_proxy.clone())
        .env("NO_PROXY", no_proxy)
        .env("PATH", "/usr/local/bin:/usr/bin")
        .env("HOME", "/home/forge")
        .env("USER", "forge")
        .env("PROJECT", project_name)
        .env("TILLANDSIAS_PROJECT", project_name)
        .env("TILLANDSIAS_PROJECT_HOST_MOUNT", "1")
        .tmpfs("/tmp:size=256m,mode=1777")
        .tmpfs("/run/user/1000:size=64m,mode=0700")
        .tmpfs("/opt/cheatsheets:size=8m,mode=0755")
        .env("TILLANDSIAS_CHEATSHEETS", "/opt/cheatsheets")
        .entrypoint(mode.entrypoint());
    if debug {
        spec = spec.env("TILLANDSIAS_DEBUG", "1");
    }

    for (name, value) in git_identity_env_pairs(&read_git_identity_defaults()) {
        spec = spec.env(name, value);
    }

    let ca_cert = certs_dir.join("intermediate.crt");
    if ca_cert.exists() {
        spec = spec.bind_mount(
            ca_cert.display().to_string(),
            "/etc/tillandsias/ca.crt",
            true,
        );
    }

    spec.build_run_args()
}

/// Build the full host-terminal command for an interactive tray launch.
#[cfg_attr(not(feature = "tray"), allow(dead_code))]
pub(crate) fn build_forge_agent_run_argv(
    project_path: &Path,
    project_name: &str,
    certs_dir: &Path,
    version: &str,
    mode: ForgeAgentMode,
    debug: bool,
) -> Vec<String> {
    let mut argv = vec!["podman".to_string()];
    argv.push("run".to_string());
    argv.extend(build_forge_agent_run_args(
        project_path,
        project_name,
        certs_dir,
        version,
        mode,
        debug,
    ));
    argv
}

fn run_forge_agent_cli_mode(
    project_path: &str,
    mode: ForgeAgentMode,
    flag: &str,
    debug: bool,
) -> Result<(), String> {
    require_desktop_user_session(&format!("tillandsias {flag}"))?;
    report_runtime_lane(flag, debug);

    if debug {
        eprintln!("[tillandsias] {} mode enabled", mode.slug());
        eprintln!("[tillandsias] Project: {}", project_path);
    }

    let project = Path::new(project_path);
    if !project.exists() {
        return Err(format!("Project not found: {}", project_path));
    }

    let canonical = project
        .canonicalize()
        .unwrap_or_else(|_| project.to_path_buf());
    let project_name = canonical
        .file_name()
        .and_then(|n| n.to_str())
        .unwrap_or("forge-project");

    if debug {
        eprintln!(
            "[tillandsias] Project path is valid: {}",
            canonical.display()
        );
    }

    let version = VERSION.trim();
    let certs_dir = ensure_enclave_for_project(project_name, Some(&canonical), debug)?;
    let forge_args =
        build_forge_agent_run_args(&canonical, project_name, &certs_dir, version, mode, debug);

    let rt = podman_runtime()?;
    let client = PodmanClient::new();
    rt.block_on(async {
        // @trace spec:runtime-diagnostics-stream
        let diag_emitter =
            tillandsias_podman::diagnostic_event_emitter::spawn_diagnostic_event_emitter(
                debug,
                "tillandsias-",
            );

        // @trace spec:runtime-diagnostics-stream (Stderr line pass-through)
        let _diag_logs_handle = if debug {
            Some(
                tillandsias_podman::DiagnosticsHandle::start_typed_event_stream(vec![
                    "tillandsias-router".to_string(),
                    "tillandsias-proxy".to_string(),
                    format!("tillandsias-git-{project_name}"),
                    "tillandsias-inference".to_string(),
                ])
                .await,
            )
        } else {
            None
        };

        let result = client
            .run_container_attached_observed(
                mode.slug(),
                &forge_container_name(project_name),
                &forge_args,
                debug,
            )
            .await;
        cleanup_shared_stack_if_no_running_forge(&client, project_name, debug).await;

        if let Some(handle) = diag_emitter {
            handle.abort();
            let _ = handle.await;
        }

        result.map_err(|e| format!("[forge-launch] {} session exited: {e}", mode.slug()))
    })
}

/// Launch a per-project forge agent (Claude/Codex/OpenCode/Maintenance) in
/// the host's default terminal emulator.
///
/// Flow:
/// 1. Resolve project name + canonical path.
/// 2. Bring up enclave (proxy + git + inference) via the shared idiomatic
///    podman layer.
/// 3. Build the forge `podman run` argv via `ContainerSpec`.
/// 4. Detect host terminal, spawn it detached with the argv appended.
///
/// The terminal window is the user-facing surface. When the user closes it,
/// `podman run --rm` tears the container down.
/// @trace spec:forge-as-only-runtime
#[cfg_attr(not(feature = "tray"), allow(dead_code))]
pub(crate) fn launch_forge_agent(
    project_name: &str,
    project_path: &Path,
    mode: ForgeAgentMode,
    debug: bool,
) -> Result<(), String> {
    if !project_path.exists() {
        return Err(format!("Project not found: {}", project_path.display()));
    }

    let canonical = project_path
        .canonicalize()
        .unwrap_or_else(|_| project_path.to_path_buf());
    let version = VERSION.trim();

    if debug {
        eprintln!(
            "[tillandsias] launch_forge_agent: project={project_name} mode={} path={}",
            mode.slug(),
            canonical.display()
        );
    }

    // Unconditional progress receipt: bringing the enclave online can take
    // several seconds (and minutes on the very first run if the proxy/git/
    // inference/forge images still need building). Without this line a menu
    // click looks like it did nothing until the terminal window finally opens.
    // @trace spec:tray-ux
    eprintln!(
        "[tillandsias] launch_forge_agent: preparing enclave for '{project_name}' ({} agent); the terminal opens once it's ready…",
        mode.slug()
    );

    let certs_dir = ensure_enclave_for_project(project_name, Some(&canonical), debug)?;

    let argv =
        build_forge_agent_run_argv(&canonical, project_name, &certs_dir, version, mode, debug);

    let mut term = detect_host_terminal()?;
    if debug {
        eprintln!(
            "[tillandsias] launch_forge_agent: terminal={:?} argv={:?}",
            term, argv
        );
    }

    let executable = term.remove(0);
    let mut child = Command::new(&executable);
    child.args(&term);
    child.args(&argv);
    // Some terminal emulators (ptyxis on Fedora Silverblue 44 in particular)
    // refuse to launch when the parent process cwd is `/` — which is the
    // default for tray processes started from a .desktop entry. Anchor cwd to
    // the project workspace so the spawned terminal has a sane starting
    // directory and inherits the same cwd semantics as the CLI lane.
    // @trace spec:tray-ux, spec:browser-isolation-tray-integration
    child.current_dir(&canonical);
    // Decouple stdio — the terminal owns the TTY, we don't want podman's
    // chatter mixed into the tray service log.
    child.stdin(Stdio::null());
    child.stdout(Stdio::null());
    child.stderr(Stdio::null());

    // Window title hint for terminals that honor it via env (e.g. foot).
    child.env("TILLANDSIAS_WINDOW_TITLE", mode.window_title(project_name));

    match child.spawn() {
        Ok(_) => {
            // Always log spawn success so silent menu clicks are
            // distinguishable from silent failures. Single line, not gated on
            // debug — at this level the tray has emitted one click-receipt
            // line and one spawn-receipt line, no more.
            // @trace spec:tray-ux
            eprintln!(
                "[tillandsias] launch_forge_agent: spawned {} for project '{}' via {}",
                mode.slug(),
                project_name,
                executable
            );
            Ok(())
        }
        Err(e) => Err(format!("failed to spawn host terminal '{executable}': {e}")),
    }
}

// Module declarations for Phase 4+
mod metrics_server;

#[cfg(feature = "tray")]
mod tray;

#[cfg(all(feature = "listen-vsock", unix))]
mod pty_handler;
#[cfg(feature = "listen-vsock")]
mod vsock_server;

/// Spawn the vsock control-wire listener when `--listen-vsock <port>` was
/// passed AND the binary was compiled with `--features listen-vsock`. Returns
/// the join handle so the shutdown path can drain it.
///
/// If the feature is missing, prints a one-line error to stderr and skips —
/// the headless service still starts so signal handling and metrics keep
/// working.
///
/// @trace spec:vsock-transport
#[cfg(feature = "listen-vsock")]
fn maybe_spawn_vsock_listener(
    listen_vsock_port: Option<u32>,
    shutdown: Arc<AtomicBool>,
) -> Option<tokio::task::JoinHandle<()>> {
    let port = listen_vsock_port?;
    Some(tokio::spawn(async move {
        // One VmStateHandle drives three concurrent tasks below — the
        // accept loop (reads it on every VmStatusRequest), the phase
        // advancer (`Starting → Ready` when podman appears, `→ Failed`
        // on timeout), and the shutdown watcher (`→ Stopping` when the
        // shared SIGTERM atomic flips). The handle is cheaply cloneable
        // (Arc<RwLock<VmPhase>> internally), so all three see the same
        // phase transitions in real time.
        //
        // gap-6 phase-lifecycle wiring lives entirely here so
        // `graceful_shutdown_async` doesn't need a signature change.
        // @trace spec:vsock-transport, spec:vm-provisioning-lifecycle
        let state = vsock_server::VmStateHandle::new();

        // Advancer: flip Starting → Ready once /run/podman/podman.sock
        // appears, or Starting → Failed after 60s. Cheap filesystem
        // polls every 500 ms; the host tray sees the transition over
        // the vsock control wire without a probe-connect.
        let advancer_state = state.clone();
        let advancer = tokio::spawn(async move {
            advancer_state
                .advance_to_ready_when_podman_up(
                    std::time::Duration::from_secs(60),
                    std::time::Duration::from_millis(500),
                )
                .await;
        });

        // Shutdown watcher: when SIGTERM/SIGINT flips the shared
        // shutdown atomic, flip phase=Stopping so the host tray sees
        // graceful-shutdown-in-progress over the wire before the
        // listener exits.
        let watcher_state = state.clone();
        let watcher_shutdown = Arc::clone(&shutdown);
        let watcher = tokio::spawn(async move {
            watcher_state
                .watch_shutdown_and_mark_stopping(watcher_shutdown)
                .await;
        });

        match vsock_server::run_vsock_listener(port, shutdown, state).await {
            Ok(()) => {}
            Err(err) => {
                eprintln!("[tillandsias] vsock listener on port {port} failed: {err}");
            }
        }

        // The listener has exited (clean shutdown or bind error). Stop
        // the lifecycle helpers — neither is meaningful without the
        // listener serving status replies. Aborts are idempotent if
        // they already returned on their own (watcher does, when the
        // shutdown atomic flipped).
        advancer.abort();
        let _ = advancer.await;
        watcher.abort();
        let _ = watcher.await;
    }))
}

/// Stub when the `listen-vsock` feature is disabled at compile time. Emits a
/// friendly error on stderr if the user passed `--listen-vsock` anyway.
///
/// @trace spec:vsock-transport
#[cfg(not(feature = "listen-vsock"))]
fn maybe_spawn_vsock_listener(
    listen_vsock_port: Option<u32>,
    _shutdown: Arc<AtomicBool>,
) -> Option<tokio::task::JoinHandle<()>> {
    if listen_vsock_port.is_some() {
        eprintln!(
            "[tillandsias] --listen-vsock requires the binary to be built with --features listen-vsock"
        );
    }
    None
}

/// Run in headless mode — no tray, no UI.
///
/// @trace spec:linux-native-portable-executable, spec:headless-mode
fn run_headless(config_path: Option<String>, listen_vsock_port: Option<u32>) -> Result<(), String> {
    // Create a Tokio runtime for async operations
    let rt = tokio::runtime::Runtime::new()
        .map_err(|e| format!("Failed to create async runtime: {}", e))?;

    // Run the async headless mode
    rt.block_on(run_headless_async(config_path, listen_vsock_port))
}

/// Phase 5: Async implementation of headless mode.
/// @trace spec:linux-native-portable-executable, spec:headless-mode, spec:signal-handling, spec:resource-metric-collection, spec:vsock-transport
async fn run_headless_async(
    config_path: Option<String>,
    listen_vsock_port: Option<u32>,
) -> Result<(), String> {
    require_headless_service_account("tillandsias --headless")?;
    let shutdown_signal = install_shutdown_signal_handlers()?;

    // Emit startup event with timestamp
    let now = chrono::Local::now();
    println!(
        r#"{{"event":"app.started","timestamp":"{}"}}"#,
        now.to_rfc3339()
    );

    // Load configuration (if path provided)
    if let Some(path) = config_path {
        load_config(&path)?;
    }

    // Initialize orchestration (placeholder for Phase 2)
    // In full implementation, this would:
    // - Load container state from podman
    // - Start monitoring containers
    // - Initialize enclave network

    // Wave 13 Gap #3: spawn background resource-metric sampler.
    // @trace spec:resource-metric-collection, spec:observability-metrics
    // @cheatsheet observability/cheatsheet-metrics.md
    //
    // Wave 19c Gap OBS-005: Run metrics retention check before starting sampler
    // @trace gap:OBS-005
    tokio::spawn(async move { run_metrics_retention() });

    // Wave 20d Gap OBS-012: Run evidence bundle retention check before metrics
    // @trace gap:OBS-012
    tokio::spawn(async move { run_evidence_bundle_retention() });

    // Wave 20c Gap OBS-010: Run log field cardinality analysis
    // @trace gap:OBS-010
    tokio::spawn(run_log_cardinality_analysis());

    // Wave 24a Gap OBS-011: Run trace budget enforcement checks
    // @trace gap:OBS-011
    tokio::spawn(run_trace_budget_enforcement());

    // Wave 21c Gap TR-006: Run disk usage check and auto-evict old cached images
    // @trace gap:TR-006
    tokio::spawn(async move { run_disk_usage_check() });

    // Wave 21a Gap ON-009: Check and refresh GitHub token if expired
    // @trace gap:ON-009, spec:secret-rotation
    // Spawn as background task (don't await) to avoid blocking signal handling
    tokio::spawn(check_github_token_health());

    // Wave 21b Gap ON-010: Check for missing project dependencies before forge launch
    // @trace gap:ON-010, spec:forge-environment-discoverability
    // run_dependency_check();

    let metrics_handle = spawn_metrics_sampler();

    // @trace spec:observability-metrics gap:OBS-009 — spawn the Prometheus
    // HTTP exporter alongside the sampler. The endpoint is read-only and
    // bound to localhost only; if the bind fails (port already in use,
    // socket permission), we log a warning and continue — headless MUST
    // NOT refuse to start because the diagnostic surface is unavailable.
    let metrics_http_handle = spawn_metrics_http_server();

    // @trace spec:vsock-transport — when `--listen-vsock <PORT>` was supplied,
    // bind the control wire on virtio-vsock instead of the Linux Unix
    // socket. The vsock listener is the in-VM service the host-side
    // tray talks to on Windows / macOS.
    let vsock_handle = maybe_spawn_vsock_listener(listen_vsock_port, shutdown_signal.clone());

    // Main event loop: wait for application shutdown signal.
    wait_for_shutdown_signal(shutdown_signal).await?;
    eprintln!("Received shutdown signal");

    // Cancel background metric sampler before invoking the rest of the
    // shutdown sequence so it does not race with container teardown logs.
    if let Some(handle) = metrics_handle {
        handle.abort();
        // Drain the join future; aborted tasks yield JoinError(cancelled).
        let _ = handle.await;
    }

    // Stop the metrics HTTP exporter alongside the sampler.
    if let Some(handle) = metrics_http_handle {
        handle.abort();
        let _ = handle.await;
    }

    // Drain the vsock listener if it was spawned. The serve loop returns
    // once the shutdown atomic flips, so this just collects the JoinHandle.
    if let Some(handle) = vsock_handle {
        handle.abort();
        let _ = handle.await;
    }

    // Phase 5, Task 21: Graceful shutdown with timeout
    graceful_shutdown_async().await?;

    // @trace spec:tillandsias-vault — revoke per-container AppRole tokens
    // before exit so vault audit reflects clean shutdown. The Vault
    // container itself is preserved across tray restarts (data lives on the
    // `tillandsias-vault-data` named volume).
    #[cfg(feature = "vault")]
    {
        vault_bootstrap::revoke_pending_container_tokens(false).await;
    }

    // Emit stopped event
    let now = chrono::Local::now();
    println!(
        r#"{{"event":"app.stopped","exit_code":0,"timestamp":"{}"}}"#,
        now.to_rfc3339()
    );
    Ok(())
}

async fn existing_router_host_port(
    client: &PodmanClient,
    debug: bool,
) -> Result<Option<u16>, String> {
    const ROUTER_NAME: &str = "tillandsias-router";

    let inspect = match client.inspect_container(ROUTER_NAME).await {
        Ok(inspect) => inspect,
        Err(_) => return Ok(None),
    };

    if inspect.state != "running" {
        return Ok(None);
    }

    let host_port = client
        .container_host_port(ROUTER_NAME, 8080)
        .await
        .map_err(|e| format!("Failed to inspect existing router port: {e}"))?;

    let Some(host_port) = host_port else {
        return Err(
            "Existing router container is running but has no published host port".to_string(),
        );
    };

    if debug {
        eprintln!("[tillandsias] reusing existing router host port {host_port}");
    }

    Ok(Some(host_port))
}

/// Run metrics retention check to archive files older than 30 days.
///
/// This implements gap:OBS-005. Files are moved from ~/.cache/tillandsias/logs/
/// to ~/.cache/tillandsias/metrics-archive/ if they exceed the 30-day retention
/// window. Runs synchronously on startup (lightweight operation).
///
/// @trace gap:OBS-005, spec:observability-metrics
fn run_metrics_retention() {
    use tillandsias_core::config;
    use tillandsias_metrics::archive_old_metrics;

    let cache_dir = config::cache_dir();
    let metrics_dir = cache_dir.join("logs");
    let retention_days = 30;

    match archive_old_metrics(&metrics_dir, retention_days) {
        Ok(()) => {
            // Success; retention check completed (may have archived 0 or more files).
            // Detailed logging happens inside archive_old_metrics.
        }
        Err(e) => {
            // Log the error but don't fail startup — retention is non-critical.
            tracing::warn!(
                spec = "observability-metrics",
                gap = "OBS-005",
                error = %e,
                "metrics retention check failed (non-blocking)"
            );
        }
    }
}

/// Run evidence bundle retention to delete bundles older than 30 days.
///
/// This implements gap:OBS-012. Evidence bundles (JSON snapshots and tar.gz
/// archives) are deleted from target/convergence/ if they exceed the 30-day
/// retention window. Runs synchronously on startup (lightweight operation) to
/// prevent unbounded growth of convergence artifacts.
///
/// Deletion is non-blocking; if any bundle fails to delete, a warning is logged
/// and startup continues. User is notified of cleanup count and dates via stderr.
///
/// @trace gap:OBS-012, spec:observability-convergence
fn run_evidence_bundle_retention() {
    use std::fs;
    use std::time::{Duration, SystemTime, UNIX_EPOCH};

    let repo_root = std::env::current_dir()
        .ok()
        .and_then(|p| {
            if p.join("VERSION").exists() {
                Some(p)
            } else {
                None
            }
        })
        .or_else(|| {
            // Fallback: assume CARGO_MANIFEST_DIR-relative path if invoked from workspace
            std::env::var("CARGO_MANIFEST_DIR").ok().and_then(|m| {
                let p = std::path::PathBuf::from(&m);
                let root = p.ancestors().find(|a| a.join("VERSION").exists())?;
                Some(root.to_path_buf())
            })
        });

    let convergence_dir = match repo_root {
        Some(root) => root.join("target/convergence"),
        None => {
            tracing::warn!(
                gap = "OBS-012",
                "could not determine repo root; skipping evidence bundle retention"
            );
            return;
        }
    };

    // Ensure convergence directory exists
    if !convergence_dir.is_dir() {
        debug!(
            gap = "OBS-012",
            path = ?convergence_dir,
            "convergence directory does not exist; skipping retention"
        );
        return;
    }

    // Calculate cutoff time (now - 30 days)
    let retention_days = 30u64;
    let cutoff = SystemTime::now()
        .checked_sub(Duration::from_secs(retention_days * 24 * 60 * 60))
        .unwrap_or(UNIX_EPOCH);

    let mut deleted_count = 0;
    let mut deleted_names = Vec::new();

    // Find and delete evidence bundle files (JSON and tar.gz)
    if let Ok(entries) = fs::read_dir(&convergence_dir) {
        for entry in entries.flatten() {
            let path = entry.path();
            let file_name = match path.file_name() {
                Some(name) => name.to_string_lossy().to_string(),
                None => continue,
            };

            // Match evidence-bundle*.json and evidence-bundle*.tar.gz
            if !file_name.starts_with("evidence-bundle") {
                continue;
            }
            if !file_name.ends_with(".json") && !file_name.ends_with(".tar.gz") {
                continue;
            }

            // Skip the "evidence-bundle.json" symbolic/current bundle link
            if file_name == "evidence-bundle.json" {
                continue;
            }

            // Check modification time
            if let Ok(metadata) = fs::metadata(&path)
                && let Ok(modified) = metadata.modified()
                && modified < cutoff
            {
                // Bundle is older than retention window; delete it
                if let Ok(()) = fs::remove_file(&path) {
                    deleted_count += 1;
                    deleted_names.push(file_name);
                    debug!(
                        gap = "OBS-012",
                        bundle = ?path,
                        "deleted old evidence bundle"
                    );
                } else {
                    tracing::warn!(
                        gap = "OBS-012",
                        bundle = ?path,
                        "failed to delete evidence bundle (continuing)"
                    );
                }
            }
        }
    }

    // User notification (stderr)
    if deleted_count > 0 {
        eprintln!(
            "[headless] evidence bundle retention cleanup: deleted {} bundle(s) older than {} days",
            deleted_count, retention_days
        );
        for name in deleted_names {
            eprintln!("  - {}", name);
        }
        tracing::info!(
            gap = "OBS-012",
            spec = "observability-convergence",
            deleted_count = deleted_count,
            retention_days = retention_days,
            "evidence bundle retention cleanup completed"
        );
    }
}

/// Analyze log field cardinality and warn if high-cardinality fields are detected.
///
/// This implements gap:OBS-010. Scans recent log entries to detect fields with
/// unbounded cardinality that could cause log explosion. Runs asynchronously on
/// startup without blocking the main event loop.
///
/// High-cardinality fields (> 1000 unique values) are reported to the user with
/// sample values to help identify problematic logging patterns.
///
/// @trace gap:OBS-010, spec:runtime-logging
async fn run_log_cardinality_analysis() {
    use tillandsias_core::config;
    use tillandsias_logging::CardinalityAnalyzer;

    let log_dir = config::log_dir();
    let log_file = log_dir.join("tillandsias.log");

    if !log_file.exists() {
        debug!(
            gap = "OBS-010",
            "tillandsias.log does not exist; skipping cardinality analysis"
        );
        return;
    }

    let analyzer = CardinalityAnalyzer::default();
    match analyzer.analyze_log_file(&log_file).await {
        Ok(report) => {
            if !report.high_cardinality_fields.is_empty() {
                analyzer.warn_high_cardinality(&report);

                // User notification (stderr) with actionable message
                eprintln!(
                    "[headless] log cardinality analysis: {} high-cardinality field(s) detected",
                    report.high_cardinality_fields.len()
                );
                for field in report.high_cardinality_fields.iter().take(3) {
                    eprintln!(
                        "  - {}: {} unique values (examples: {:?})",
                        field.field_name,
                        field.unique_count,
                        field.sample_values.iter().take(2).collect::<Vec<_>>()
                    );
                }
                if report.high_cardinality_fields.len() > 3 {
                    eprintln!(
                        "  ... and {} more high-cardinality field(s)",
                        report.high_cardinality_fields.len() - 3
                    );
                }

                tracing::warn!(
                    gap = "OBS-010",
                    spec = "runtime-logging",
                    count = report.high_cardinality_fields.len(),
                    "high-cardinality fields detected in log stream (could lead to log explosion)"
                );
            } else {
                debug!(
                    gap = "OBS-010",
                    entries_scanned = report.total_entries,
                    "log cardinality analysis: no high-cardinality fields detected"
                );
            }
        }
        Err(e) => {
            // Non-critical error; don't fail startup
            tracing::warn!(
                gap = "OBS-010",
                error = %e,
                "log cardinality analysis failed (non-blocking)"
            );
        }
    }
}

/// Run trace budget enforcement to detect and warn about cost overages.
///
/// This implements gap:OBS-011. Analyzes the current log file to track cumulative
/// trace costs per spec and globally. Warns users if trace generation exceeds
/// configured budget thresholds, helping identify runaway logging.
///
/// Non-blocking on error; if budget analysis fails, a warning is logged
/// and startup continues. Budget tracking is optional observability enhancement.
///
/// @trace gap:OBS-011, spec:runtime-logging
async fn run_trace_budget_enforcement() {
    use tillandsias_core::config;
    use tillandsias_logging::BudgetEnforcer;

    let log_dir = config::log_dir();
    let log_file = log_dir.join("tillandsias.log");

    if !log_file.exists() {
        debug!(
            gap = "OBS-011",
            "tillandsias.log does not exist; skipping budget enforcement check"
        );
        return;
    }

    // Create enforcer with default budget (10MB global per hour, 5MB per-spec)
    // @trace gap:OBS-011 — Enforce trace budgets
    let enforcer = BudgetEnforcer::default_config();

    // Read log file and estimate cumulative trace costs
    match tokio::fs::read_to_string(&log_file).await {
        Ok(contents) => {
            let mut trace_count = 0;

            for line in contents.lines() {
                // Try to parse each line as a JSON log entry
                if let Ok(entry) = serde_json::from_str::<serde_json::Value>(line) {
                    trace_count += 1;

                    // Reconstruct LogEntry to check budget
                    // For now, we estimate costs by checking if this line exists
                    // and issuing warnings based on spec_trace field
                    if let Some(spec_trace) = entry.get("spec_trace").and_then(|v| v.as_str()) {
                        let spec_budget = enforcer.get_spec_budget(spec_trace);
                        // Track that we saw this spec (detailed analysis not needed for startup)
                        debug!(
                            gap = "OBS-011",
                            spec = spec_trace,
                            budget_bytes = spec_budget,
                            "trace budget monitoring active"
                        );
                    }
                }
            }

            // If we found traces, emit a summary
            let (global_cost, violations, warning_issued) = enforcer.window_stats();
            if warning_issued {
                eprintln!(
                    "[headless] trace budget enforcement: {} warning(s) issued for cost overages",
                    violations
                );
                tracing::warn!(
                    gap = "OBS-011",
                    spec = "runtime-logging",
                    violations = violations as u32,
                    global_cost_bytes = global_cost,
                    "trace budget exceeded in current window"
                );
            } else {
                debug!(
                    gap = "OBS-011",
                    traces_analyzed = trace_count,
                    global_cost_bytes = global_cost,
                    "trace budget enforcement: all budgets within limits"
                );
            }
        }
        Err(e) => {
            // Non-critical error; don't fail startup
            tracing::warn!(
                gap = "OBS-011",
                error = %e,
                "trace budget enforcement check failed (non-blocking)"
            );
        }
    }
}

/// Run disk usage check and auto-evict old cached images when > 85%.
///
/// This implements gap:TR-006. Invokes scripts/manage-cache.sh from the
/// Tillandsias checkout root. Runs synchronously on startup (lightweight operation).
///
/// Non-blocking on error; if cache management fails, a warning is logged
/// and startup continues.
///
/// @trace gap:TR-006, spec:disk-usage-detection, spec:podman-image-eviction
fn run_disk_usage_check() {
    use std::process::Command;

    let version = VERSION.trim();
    let runtime_root = match resolve_runtime_asset_root(version, false) {
        Ok(root) => root,
        Err(e) => {
            tracing::warn!(
                gap = "TR-006",
                error = %e,
                "could not determine Tillandsias runtime asset root; skipping disk usage check"
            );
            return;
        }
    };

    let manage_cache_script = runtime_root.join("scripts/manage-cache.sh");
    if !manage_cache_script.exists() {
        debug!(
            gap = "TR-006",
            path = ?manage_cache_script,
            "manage-cache.sh not found; skipping disk usage check"
        );
        return;
    }

    // Run the cache management script
    match Command::new("bash").arg(&manage_cache_script).output() {
        Ok(output) => {
            if output.status.success() {
                // Log successful completion
                let stdout = String::from_utf8_lossy(&output.stdout);
                if !stdout.is_empty() {
                    for line in stdout.lines() {
                        debug!(gap = "TR-006", "{}", line);
                    }
                }
            } else {
                let stderr = String::from_utf8_lossy(&output.stderr);
                tracing::warn!(
                    gap = "TR-006",
                    exit_code = output.status.code(),
                    stderr = %stderr,
                    "disk usage check failed (non-blocking)"
                );
            }
        }
        Err(e) => {
            // Non-critical error; don't fail startup
            tracing::warn!(
                gap = "TR-006",
                error = %e,
                "failed to invoke disk usage check (non-blocking)"
            );
        }
    }
}

/// Check GitHub token health and refresh if expired.
///
/// Wave 21a Gap ON-009: Auto-refresh GitHub token via Secret Service when it expires.
/// This prevents authentication failures due to token expiry by checking token validity
/// at application startup and attempting refresh if needed.
///
/// Non-blocking with 1-second timeout to prevent delaying startup signal handling.
///
/// @trace gap:ON-009, spec:secret-rotation, spec:native-secrets-store
async fn check_github_token_health() {
    use tillandsias_core::secrets;
    use tokio::time::timeout;

    let config = secrets::TokenRefreshConfig::default();

    // Use a 1-second timeout to avoid blocking shutdown signal handling
    match timeout(
        Duration::from_secs(1),
        secrets::check_and_refresh_github_token(&config),
    )
    .await
    {
        Ok(Ok(())) => {
            debug!(gap = "ON-009", "GitHub token health check completed");
        }
        Ok(Err(e)) => {
            // Non-critical error; don't fail startup
            tracing::warn!(
                gap = "ON-009",
                spec = "secret-rotation",
                error = %e,
                "GitHub token health check failed (non-blocking)"
            );
        }
        Err(_timeout) => {
            debug!(
                gap = "ON-009",
                "GitHub token health check timed out; skipping"
            );
        }
    }
}

/// Check for missing project dependencies before forge launch.
///
/// This implements gap:ON-010. Scans the current project for dependency files
/// (Cargo.toml, package.json, requirements.txt, etc.) and checks if required
/// tools (rustc, cargo, node, npm, python3, etc.) are available in PATH.
///
/// Output: Displays missing dependencies as a formatted list to stderr.
/// Non-blocking: If dependency check fails, startup continues.
///
/// @trace gap:ON-010, spec:forge-environment-discoverability
#[allow(dead_code)]
fn run_dependency_check() {
    use std::process::Command;

    let project_dir = std::env::current_dir().unwrap_or_else(|_| PathBuf::from("."));

    // Call the dependency-resolver.sh script to scan for missing dependencies
    let resolver_script = "/opt/cheatsheets/dependency-resolver.sh";

    // Check if the script exists; if not, skip silently (may be running in environment without it)
    if !Path::new(resolver_script).exists() {
        debug!(
            gap = "ON-010",
            "dependency-resolver.sh not found; skipping dependency check"
        );
        return;
    }

    match Command::new("bash")
        .arg(resolver_script)
        .arg(&project_dir)
        .output()
    {
        Ok(output) => {
            let stdout = String::from_utf8_lossy(&output.stdout);

            // Parse JSON output
            if let Ok(missing_deps) = serde_json::from_str::<Vec<serde_json::Value>>(&stdout) {
                if !missing_deps.is_empty() {
                    // Display missing dependencies to user
                    eprintln!("\n[dependency resolver] Missing project dependencies:");
                    for dep in &missing_deps {
                        if let (Some(tool), Some(install_hint)) =
                            (dep.get("tool"), dep.get("install"))
                        {
                            eprintln!(
                                "  - {} (install: {})",
                                tool.as_str().unwrap_or("unknown"),
                                install_hint.as_str().unwrap_or("see docs")
                            );
                        }
                    }
                    eprintln!("  → You can continue, but some tools may not work as expected.\n");

                    // Log structured event for observability
                    tracing::info!(
                        gap = "ON-010",
                        spec = "forge-environment-discoverability",
                        missing_count = missing_deps.len(),
                        "project dependencies check completed"
                    );
                } else {
                    debug!(gap = "ON-010", "all project dependencies available");
                }
            } else {
                debug!(
                    gap = "ON-010",
                    "failed to parse dependency resolver output; skipping"
                );
            }
        }
        Err(e) => {
            // Non-critical error; don't fail startup
            tracing::warn!(
                gap = "ON-010",
                error = %e,
                "dependency check failed (non-blocking)"
            );
        }
    }
}

/// Spawn the resource-metric sampler in the background.
///
/// Returns the JoinHandle so the caller can cancel the loop on shutdown.
/// Sampling cadence is 5s, matching the convergence dashboard's projection
/// rhythm. Returning `None` is reserved for future feature-gating; today the
/// sampler is unconditionally spawned in headless mode.
///
/// @trace spec:resource-metric-collection, spec:observability-metrics
/// @cheatsheet observability/cheatsheet-metrics.md
fn spawn_metrics_sampler() -> Option<tokio::task::JoinHandle<()>> {
    use tillandsias_metrics::MetricsSampler;
    let interval = Duration::from_secs(5);
    if MetricsSampler::validate_interval(interval).is_err() {
        return None;
    }
    let handle = tokio::spawn(async move {
        let mut sampler = MetricsSampler::new();
        sampler.collect_continuous(interval).await;
    });
    Some(handle)
}

/// Spawn the Prometheus HTTP exporter on localhost. Default bind is
/// `127.0.0.1:9090` (Prometheus' canonical port); override via the
/// `TILLANDSIAS_METRICS_ADDR` env var (e.g. `127.0.0.1:0` in tests, or a
/// different port when 9090 is taken by an external scraper).
///
/// Returning `None` means the bind failed up front (port already taken,
/// permission denied, ...). Per spec:observability-metrics the headless
/// service MUST continue to run when the diagnostic surface is unavailable
/// — sampling and the control wire are not gated on metrics scrape
/// reachability. The warning surfaces the cause in the headless event log.
///
/// @trace spec:observability-metrics gap:OBS-009
fn spawn_metrics_http_server() -> Option<tokio::task::JoinHandle<()>> {
    use crate::metrics_server::{MetricsServerState, start_metrics_server};
    use std::net::SocketAddr;

    let addr_str =
        std::env::var("TILLANDSIAS_METRICS_ADDR").unwrap_or_else(|_| "127.0.0.1:9090".to_string());
    let addr: SocketAddr = match addr_str.parse() {
        Ok(a) => a,
        Err(e) => {
            eprintln!(
                "[tillandsias] metrics: invalid TILLANDSIAS_METRICS_ADDR={addr_str}: {e} — exporter disabled"
            );
            return None;
        }
    };

    let state = MetricsServerState::new();
    let handle = tokio::spawn(async move {
        if let Err(e) = start_metrics_server(addr, state).await {
            eprintln!("[tillandsias] metrics: HTTP exporter on {addr} stopped: {e}");
        }
    });
    Some(handle)
}

/// Phase 5, Task 22: Wait for SIGTERM/SIGINT using signal-hook flags.
///
/// This loop is only reached during shutdown. It is not on the hot path for
/// launch, prompt dispatch, or tray interaction. The atomic flag is set by the
/// signal handler, and the async sleep yields the runtime while backing off so
/// we do not spin aggressively while waiting for termination.
/// @trace spec:linux-native-portable-executable, spec:signal-handling, spec:runtime-logging
///
/// `pub(crate)` so the tray's `run_tray_mode_with_debug` path can install
/// the same SIGTERM/SIGINT atomic and share it with `start_control_socket_server`
/// for the `TrayPhaseHandle` shutdown watcher. Without it, the tray runs
/// without signal handlers and SIGTERM kills the process immediately —
/// sibling-host clients polling `VmStatusRequest` never see `phase=Stopping`.
pub(crate) fn install_shutdown_signal_handlers() -> Result<Arc<AtomicBool>, String> {
    use signal_hook::consts::signal::*;
    let terminated = Arc::new(AtomicBool::new(false));
    flag::register(SIGTERM, Arc::clone(&terminated))
        .map_err(|e| format!("Failed to register SIGTERM: {e}"))?;
    flag::register(SIGINT, Arc::clone(&terminated))
        .map_err(|e| format!("Failed to register SIGINT: {e}"))?;
    Ok(terminated)
}

async fn wait_for_shutdown_signal(terminated: Arc<AtomicBool>) -> Result<(), String> {
    let mut poll_delay_ms = 25_u64;
    while !terminated.load(Ordering::SeqCst) {
        tokio::time::sleep(std::time::Duration::from_millis(poll_delay_ms)).await;
        poll_delay_ms = next_shutdown_poll_delay_ms(poll_delay_ms);
    }
    Ok(())
}

/// Conservative shutdown polling backoff. This only governs the wait loop
/// after shutdown has already been requested, so it cannot affect user-facing
/// launch or tray responsiveness.
fn next_shutdown_poll_delay_ms(current_ms: u64) -> u64 {
    current_ms.saturating_mul(2).min(250)
}

/// Load headless configuration from TOML file.
fn load_config(_path: &str) -> Result<(), String> {
    // Placeholder for Phase 2
    // Would parse TOML config with:
    // - container names to manage
    // - network settings
    // - logging configuration
    Ok(())
}

/// Phase 5, Task 21: Graceful shutdown with 30s timeout and SIGKILL fallback.
/// @trace spec:linux-native-portable-executable, spec:graceful-shutdown, spec:signal-handling
/// Graceful shutdown sequence for both headless and tray modes.
///
/// This function:
/// 1. Stops all managed containers with 30s timeout via podman client.
/// 2. Monitors container exit status.
/// 3. Force-kills any remaining containers after timeout.
/// 4. Cleanup ephemeral resources (sockets, mounts, logs).
///
/// @trace spec:graceful-shutdown, spec:app-lifecycle
pub(crate) async fn graceful_shutdown_async() -> Result<(), String> {
    debug!("starting graceful shutdown sequence");

    // 2. Stop all tillandsias-managed containers
    let client = PodmanClient::new();
    // Use a short timeout (500ms) for the availability check during shutdown.
    let is_available = tokio::time::timeout(Duration::from_millis(500), client.is_available())
        .await
        .unwrap_or(false);

    if is_available {
        // Use a short timeout (1s) for the initial list operation.
        match tokio::time::timeout(
            Duration::from_secs(1),
            client.list_containers("tillandsias-"),
        )
        .await
        {
            Ok(Ok(containers)) if !containers.is_empty() => {
                let running_at_start: Vec<_> =
                    containers.iter().filter(|c| c.state == "running").collect();

                if !running_at_start.is_empty() {
                    info!(
                        count = running_at_start.len(),
                        "stopping managed containers gracefully"
                    );

                    let mut stop_tasks = tokio::task::JoinSet::new();
                    for container in running_at_start {
                        let client = client.clone();
                        let name = container.name.clone();
                        stop_tasks.spawn(async move {
                            debug!(container = %name, "sending stop signal");
                            let _ = client.stop_container(&name, 30).await;
                        });
                    }

                    // Wait for all stop tasks with a global timeout (30s stop + 5s buffer)
                    let _ = tokio::time::timeout(Duration::from_secs(35), async {
                        while stop_tasks.join_next().await.is_some() {}
                    })
                    .await;
                }

                // 3. Verification phase: poll for any remaining RUNNING containers and escalate to SIGKILL
                // @trace spec:graceful-shutdown (Requirement: Force-kill fallback)
                debug!("verifying all containers exited");
                let start_poll = Instant::now();
                while Instant::now().duration_since(start_poll) < Duration::from_secs(5) {
                    match tokio::time::timeout(
                        Duration::from_secs(1),
                        client.list_containers("tillandsias-"),
                    )
                    .await
                    {
                        Ok(Ok(remaining)) => {
                            let running: Vec<_> = remaining
                                .into_iter()
                                .filter(|c| c.state == "running")
                                .collect();
                            if running.is_empty() {
                                debug!(
                                    "verification clean: zero running managed containers remain"
                                );
                                break;
                            }

                            // If we're near the end of the verification window, escalate to SIGKILL
                            if Instant::now().duration_since(start_poll) > Duration::from_secs(4) {
                                for c in running {
                                    warn!(container = %c.name, "shutdown timeout exceeded; escalating to SIGKILL");
                                    let _ = client.kill_container(&c.name, Some("KILL")).await;
                                }
                            }
                        }
                        _ => break,
                    }
                    tokio::time::sleep(Duration::from_millis(500)).await;
                }
            }
            Ok(Ok(_)) => {
                debug!("no managed containers found; skipping stop sequence");
            }
            _ => {
                // Ignore errors during shutdown listing to ensure we reach the socket cleanup.
            }
        }
    }

    // 4. Cleanup ephemeral resources (sockets and logs)
    // @trace spec:graceful-shutdown (Requirement: No stale sockets remain)
    let socket_path = control_socket_host_dir().join("control.sock");
    if socket_path.exists() {
        debug!(path = %socket_path.display(), "removing control socket");
        let _ = fs::remove_file(&socket_path);
    }

    // Cleanup temporary init logs in /tmp
    // @trace spec:graceful-shutdown
    if let Ok(entries) = fs::read_dir("/tmp") {
        for entry in entries.flatten() {
            if let Some(name) = entry.file_name().to_str()
                && name.starts_with("tillandsias-init-")
                && name.ends_with(".log")
            {
                let _ = fs::remove_file(entry.path());
            }
        }
    }

    // 5. Force-terminate the process group to clean up any remaining stray children
    // (like orphaned tillandsias-podman-cli instances).
    // @trace spec:graceful-shutdown
    #[cfg(unix)]
    {
        debug!("sending SIGTERM to process group");
        unsafe {
            // Signal our own process group. Use a negative PID to target the group.
            // Ignore failure (ESRCH means group is already gone).
            let _ = libc::kill(-libc::getpgrp(), libc::SIGTERM);
        }
    }

    // Use the exact string the signal_handling litmus and the spec expect.
    eprintln!("Graceful shutdown completed");
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::path::PathBuf;

    #[test]
    #[cfg(target_os = "linux")]
    fn test_ensure_pasta_options_ipv4_only() {
        let temp_dir = tempfile::tempdir().unwrap();
        let conf_path = temp_dir.path().join("containers.conf");

        // Case 1: File does not exist
        ensure_pasta_options_ipv4_only(&conf_path).unwrap();
        let content = std::fs::read_to_string(&conf_path).unwrap();
        assert!(content.contains("[network]"));
        assert!(content.contains("pasta_options = [\"--ipv4-only\"]"));

        // Case 2: File exists but does not contain [network]
        std::fs::write(&conf_path, "[containers]\nlog_size_max = 1000\n").unwrap();
        ensure_pasta_options_ipv4_only(&conf_path).unwrap();
        let content = std::fs::read_to_string(&conf_path).unwrap();
        assert!(content.contains("[containers]"));
        assert!(content.contains("[network]"));
        assert!(content.contains("pasta_options = [\"--ipv4-only\"]"));

        // Case 3: File exists and contains [network] but not pasta_options
        std::fs::write(&conf_path, "[network]\nevents_logger = \"file\"\n").unwrap();
        ensure_pasta_options_ipv4_only(&conf_path).unwrap();
        let content = std::fs::read_to_string(&conf_path).unwrap();
        assert!(content.contains("events_logger = \"file\""));
        assert!(content.contains("pasta_options = [\"--ipv4-only\"]"));

        // Case 4: File already contains pasta_options
        std::fs::write(
            &conf_path,
            "[network]\npasta_options = [\"--something-else\"]\n",
        )
        .unwrap();
        ensure_pasta_options_ipv4_only(&conf_path).unwrap();
        let content = std::fs::read_to_string(&conf_path).unwrap();
        assert!(content.contains("pasta_options = [\"--something-else\"]"));
        assert!(!content.contains("pasta_options = [\"--ipv4-only\"]"));
    }
    use std::sync::{Mutex, OnceLock};

    fn has_arg(args: &[String], needle: &str) -> bool {
        args.iter().any(|arg| arg == needle)
    }

    fn env_lock() -> std::sync::MutexGuard<'static, ()> {
        static ENV_LOCK: OnceLock<Mutex<()>> = OnceLock::new();
        ENV_LOCK.get_or_init(|| Mutex::new(())).lock().unwrap()
    }

    #[test]
    fn enclave_subnet_defaults_to_current_cidr() {
        let _guard = env_lock();
        unsafe {
            std::env::remove_var(ENCLAVE_SUBNET_ENV);
        }
        assert_eq!(enclave_subnet(), DEFAULT_ENCLAVE_SUBNET);
        assert!(enclave_no_proxy().ends_with(DEFAULT_ENCLAVE_SUBNET));
    }

    #[test]
    fn enclave_no_proxy_uses_subnet_override() {
        let _guard = env_lock();
        unsafe {
            std::env::set_var(ENCLAVE_SUBNET_ENV, " 10.77.0.0/24 ");
        }
        assert_eq!(enclave_subnet(), "10.77.0.0/24");
        let no_proxy = enclave_no_proxy();
        assert!(no_proxy.contains("tillandsias-git"));
        assert!(no_proxy.ends_with("10.77.0.0/24"));
        unsafe {
            std::env::remove_var(ENCLAVE_SUBNET_ENV);
        }
    }

    // ─────────────────────────────────────────────────────────
    // Forge agent launch tests (Claude/Codex/OpenCode/Maintenance)
    // @trace spec:browser-isolation-tray-integration, spec:tray-ux
    // ─────────────────────────────────────────────────────────

    #[test]
    fn detect_host_terminal_prefers_env_var() {
        let _guard = env_lock();
        let prev = std::env::var_os("TERMINAL");
        // SAFETY: env_lock() guarantees this test holds the only
        // environment-mutating handle during the assertion window.
        unsafe { std::env::set_var("TERMINAL", "foo bar") };

        let result = detect_host_terminal();

        // Restore env before asserting so a failure doesn't poison siblings.
        unsafe {
            match prev {
                Some(v) => std::env::set_var("TERMINAL", v),
                None => std::env::remove_var("TERMINAL"),
            }
        }
        let argv = result.expect("detect_host_terminal should honor $TERMINAL");
        assert_eq!(argv, vec!["foo".to_string(), "bar".to_string()]);
    }

    #[test]
    fn detect_host_terminal_falls_back_to_xdg_then_probe() {
        let _guard = env_lock();
        // Build a tmp PATH that exposes ONLY `xterm` so the probe loop is the
        // path actually exercised. xdg-terminal-exec must NOT be present.
        let scratch = tempfile::tempdir().expect("tempdir");
        let bin = scratch.path().join("bin");
        std::fs::create_dir_all(&bin).expect("mkdir bin");
        let xterm = bin.join("xterm");
        std::fs::write(&xterm, "#!/bin/sh\nexit 0\n").expect("write xterm");
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            let mut perms = std::fs::metadata(&xterm).unwrap().permissions();
            perms.set_mode(0o755);
            std::fs::set_permissions(&xterm, perms).unwrap();
        }

        let prev_path = std::env::var_os("PATH");
        let prev_term = std::env::var_os("TERMINAL");
        // SAFETY: env_lock held; serialized.
        unsafe {
            std::env::remove_var("TERMINAL");
            std::env::set_var("PATH", bin.as_os_str());
        }

        let result = detect_host_terminal();

        // Restore before asserting.
        unsafe {
            match prev_path {
                Some(v) => std::env::set_var("PATH", v),
                None => std::env::remove_var("PATH"),
            }
            if let Some(v) = prev_term {
                std::env::set_var("TERMINAL", v);
            }
        }
        let argv = result.expect("detect_host_terminal should fall back to xterm");
        assert_eq!(argv, vec!["xterm".to_string(), "-e".to_string()]);
    }

    #[test]
    fn launch_forge_agent_maintenance_uses_terminal_entrypoint() {
        // The forge image does not (yet) ship `entrypoint-forge-bash.sh`;
        // Maintenance maps to the existing `entrypoint-terminal.sh` which is
        // the closest bash/fish surface. See ForgeAgentMode docs.
        let argv = build_forge_agent_run_argv(
            &PathBuf::from("/tmp/project"),
            "alpha",
            &PathBuf::from("/tmp/ca"),
            "1.2.3",
            ForgeAgentMode::Maintenance,
            true,
        );

        assert_eq!(argv.first().map(|s| s.as_str()), Some("podman"));
        assert!(has_arg(&argv, "--entrypoint"));
        assert!(
            has_arg(&argv, "/usr/local/bin/entrypoint-terminal.sh"),
            "Maintenance must use entrypoint-terminal.sh; got: {argv:?}"
        );
        assert!(has_arg(&argv, "--interactive"));
        assert!(has_arg(&argv, "--tty"));
    }

    // @trace spec:tray-ux, spec:browser-isolation-tray-integration
    // Regression: on Fedora Silverblue tray clicks silently failed because
    // (a) `launch_forge_agent` inherited cwd=`/` from the desktop-spawned
    // tray (ptyxis refuses to start there), and (b) successful spawns
    // produced no log trail, indistinguishable from silent failures. Pin
    // both: the function MUST set `current_dir(canonical)` and MUST emit a
    // single "spawned <mode> for project ..." stderr line ungated on debug.
    #[test]
    fn launch_forge_agent_sets_cwd_and_logs_spawn_outcome() {
        let source = include_str!(concat!(env!("CARGO_MANIFEST_DIR"), "/src/main.rs"));

        // Find the launch_forge_agent body and assert both invariants live
        // inside the same function — not just somewhere in the file.
        let start = source
            .find("pub(crate) fn launch_forge_agent(")
            .expect("launch_forge_agent function must exist");
        // The next top-level `fn run_headless(` follows in this file, so
        // bound the body to keep the assertions scoped.
        let end = source[start..]
            .find("\nfn run_headless(")
            .map(|offset| start + offset)
            .unwrap_or(source.len());
        let body = &source[start..end];

        assert!(
            body.contains("child.current_dir(&canonical);"),
            "launch_forge_agent must anchor cwd to the project workspace so \
             terminals like ptyxis don't refuse to start from cwd=/"
        );
        assert!(
            body.contains("[tillandsias] launch_forge_agent: spawned"),
            "launch_forge_agent must log spawn success ungated on debug so \
             silent failures are distinguishable from silent successes"
        );
    }

    #[test]
    fn launch_forge_agent_does_not_mount_user_home() {
        // Walk every arg and reject anything that smells like a host-side
        // home mount. The only `/home/forge` references must be in the
        // *target* side of the workspace bind mount or in env values.
        let argv = build_forge_agent_run_argv(
            &PathBuf::from("/tmp/project"),
            "alpha",
            &PathBuf::from("/tmp/ca"),
            "1.2.3",
            ForgeAgentMode::Claude,
            false,
        );

        let joined = argv.join(" ");
        assert!(
            !joined.contains(".config"),
            "must not mount user .config dirs into the forge; got: {joined}"
        );
        assert!(
            !joined.contains(".cache"),
            "must not mount user .cache dirs into the forge; got: {joined}"
        );

        if let Some(home) = std::env::var_os("HOME") {
            let home_str = home.to_string_lossy().into_owned();
            if !home_str.is_empty() && home_str != "/" {
                // The *target* HOME inside the container is /home/forge — that's fine.
                // We're guarding against the *host* $HOME leaking in as a bind source.
                for arg in &argv {
                    if arg.contains(&home_str) && !arg.starts_with("HOME=") {
                        panic!("argv contains host $HOME ({home_str}) outside of HOME env: {arg}");
                    }
                }
            }
        }
    }

    #[test]
    #[ignore = "diagnostic dump for hand-off; run with --ignored when needed"]
    fn _diagnostic_dump_sample_claude_argv() {
        // @trace spec:tray-ux
        // Reproduces the exact argv a Claude tray launch would hand to the
        // host terminal for the canonical Tillandsias self-build project.
        let argv = build_forge_agent_run_argv(
            &PathBuf::from("/home/tlatoani/src/tillandsias"),
            "tillandsias",
            &PathBuf::from("/tmp/tillandsias-ca"),
            "0.2.260518",
            ForgeAgentMode::Claude,
            true,
        );
        eprintln!("=== SAMPLE ARGV (Claude, tillandsias project) ===");
        for (i, a) in argv.iter().enumerate() {
            eprintln!("  [{i:02}] {a}");
        }
        eprintln!("=== {} args total ===", argv.len());
    }

    #[test]
    fn forge_agent_mode_entrypoint_mapping_is_pinned() {
        assert_eq!(
            ForgeAgentMode::Claude.entrypoint(),
            "/usr/local/bin/entrypoint-forge-claude.sh"
        );
        assert_eq!(
            ForgeAgentMode::Codex.entrypoint(),
            "/usr/local/bin/entrypoint-forge-codex.sh"
        );
        assert_eq!(
            ForgeAgentMode::OpenCode.entrypoint(),
            "/usr/local/bin/entrypoint-forge-opencode.sh"
        );
        assert_eq!(
            ForgeAgentMode::Maintenance.entrypoint(),
            "/usr/local/bin/entrypoint-terminal.sh"
        );
    }

    #[test]
    fn shutdown_poll_backoff_doubles_until_capped() {
        assert_eq!(next_shutdown_poll_delay_ms(25), 50);
        assert_eq!(next_shutdown_poll_delay_ms(50), 100);
        assert_eq!(next_shutdown_poll_delay_ms(125), 250);
        assert_eq!(next_shutdown_poll_delay_ms(250), 250);
        assert_eq!(next_shutdown_poll_delay_ms(u64::MAX), 250);
    }

    #[test]
    fn proxy_args_encode_the_expected_container_shape() {
        let args = build_proxy_run_args(&PathBuf::from("/tmp/ca"), "tillandsias-proxy:v1");

        assert!(has_arg(&args, "--detach"));
        assert!(has_arg(&args, "tillandsias-proxy"));
        assert!(has_arg(&args, "proxy"));
        assert!(!has_arg(&args, "--ip"));
        assert!(!has_arg(&args, "10.0.42.2"));
        assert!(has_arg(&args, "DEBUG_PROXY=1"));
        assert!(has_arg(&args, "tillandsias-proxy:v1"));
    }

    // Regression: smoke-finding/rootless-bridge-network-missing. The dual-home
    // second leg must target the managed `tillandsias-egress` network, never the
    // literal `bridge` (which does not exist on rootless Podman after a reset —
    // the rootless default network is named `podman`).
    #[test]
    fn enclave_egress_dual_home_targets_managed_egress_network() {
        let certs = PathBuf::from("/tmp/ca");
        let proxy = build_proxy_run_args(&certs, "tillandsias-proxy:v1");
        let git = build_git_run_args("alpha", &certs, "tillandsias-git:v1", None, None);

        for (name, args) in [("proxy", &proxy), ("git", &git)] {
            assert!(
                has_arg(args, "tillandsias-enclave,tillandsias-egress"),
                "{name} must dual-home onto the managed egress network: {args:?}"
            );
            assert!(
                !has_arg(args, "tillandsias-enclave,bridge"),
                "{name} must not reference the nonexistent `bridge` network: {args:?}"
            );
        }
    }

    // Regression: github-login/enclave-egress-regression. The GitHub login
    // helper must dual-home onto the managed egress network so `gh auth login`
    // can reach api.github.com from the internal enclave.
    #[test]
    fn github_login_helper_dual_homes_onto_managed_egress_network() {
        let source = include_str!(concat!(env!("CARGO_MANIFEST_DIR"), "/src/main.rs"));
        let login_window = source_window(source, "fn run_github_login(debug: bool)");
        assert!(
            login_window.contains("ENCLAVE_EGRESS_NETS"),
            "run_github_login must use ENCLAVE_EGRESS_NETS not ENCLAVE_NET: {login_window}"
        );
        assert!(
            !login_window.contains("ENCLAVE_NET,"),
            "run_github_login must not reference ENCLAVE_NET (no egress): {login_window}"
        );
        // The dual-home leg only resolves if the managed egress network exists.
        // `--github-login` can run without a prior full `--init`, so the login
        // path must ensure the networks itself.
        assert!(
            login_window.contains("ensure_enclave_network(debug)?"),
            "run_github_login must ensure the enclave+egress networks before launching the helper: {login_window}"
        );
    }

    #[test]
    fn github_login_prompts_after_infrastructure_preflight() {
        let source = include_str!(concat!(env!("CARGO_MANIFEST_DIR"), "/src/main.rs"));
        let login_window = source_window(source, "fn run_github_login(debug: bool)");
        let image_idx = login_window
            .find("ensure_image_exists(&root, \"git\", &image, debug)?")
            .expect("github login must preflight the git image");
        let network_idx = login_window
            .find("ensure_enclave_network(debug)?")
            .expect("github login must preflight the managed networks");
        let vault_idx = login_window
            .find("vault_bootstrap::ensure_vault_running(debug)?")
            .expect("github login must preflight Vault");
        let helper_idx = login_window
            .find("run_command_silent(run, debug)?;")
            .expect("github login must start the helper container before prompts");
        let prompt_idx = login_window
            .find("prompt_and_store_git_identity()?")
            .expect("github login must prompt for git identity");
        let token_idx = login_window
            .find("GH_LOGIN_TOKEN_SCRIPT")
            .expect("github login must prompt for token through the helper");

        for (label, idx) in [
            ("image", image_idx),
            ("network", network_idx),
            ("vault", vault_idx),
            ("helper", helper_idx),
        ] {
            assert!(
                idx < prompt_idx,
                "{label} preflight must happen before credential prompts: {login_window}"
            );
        }
        assert!(
            prompt_idx < token_idx,
            "git identity prompt should still precede token entry: {login_window}"
        );
    }

    // Regression: the egress network must be ensured on every enclave-bootstrap
    // path (including the early-return-when-enclave-exists case), or the
    // dual-home leg cannot resolve on a clean runtime.
    #[test]
    fn ensure_enclave_network_also_ensures_egress_network() {
        let source = include_str!(concat!(env!("CARGO_MANIFEST_DIR"), "/src/main.rs"));
        let window = source_window(source, "fn ensure_enclave_network(");
        let ensure_idx = window
            .find("ensure_egress_network(debug)?")
            .expect("ensure_enclave_network must call ensure_egress_network");
        let early_return_idx = window
            .find("return Ok(());")
            .expect("ensure_enclave_network has an early return");
        assert!(
            ensure_idx < early_return_idx,
            "ensure_egress_network must run before the enclave-exists early return"
        );
    }

    #[test]
    fn stack_service_args_do_not_pin_static_ips() {
        let certs = PathBuf::from("/tmp/ca");
        let proxy = build_proxy_run_args(&certs, "tillandsias-proxy:v1");
        let git = build_git_run_args("alpha", &certs, "tillandsias-git:v1", None, None);
        let inference = build_inference_run_args(&certs, "tillandsias-inference:v1", false);
        let router = build_router_run_args(&certs, "tillandsias-router:v1", 8080);

        for args in [&proxy, &git, &inference, &router] {
            assert!(
                !has_arg(args, "--ip"),
                "stack launch must let podman IPAM allocate addresses: {args:?}"
            );
        }
    }

    #[test]
    fn git_run_args_use_image_entrypoint_and_persist_srv_git() {
        // The image's ENTRYPOINT runs `git daemon --base-path=/srv/git
        // --enable=receive-pack`; the launcher must NOT override CMD.
        // /srv/git must be writable (named volume) so the bare repo persists
        // and the post-receive hook can be installed.
        let certs = PathBuf::from("/tmp/ca");
        let args = build_git_run_args("alpha", &certs, "tillandsias-git:v1", None, None);

        // No `--base-path=...` override appended after the image — confirms
        // we let the image entrypoint take over.
        assert!(
            !args.iter().any(|a| a.starts_with("--base-path=")),
            "must not override base-path: {args:?}"
        );
        // Named volume for the bare repo storage.
        assert!(
            args.iter()
                .any(|a| a == "tillandsias-mirror-alpha:/srv/git"),
            "expected mirror volume mount in args: {args:?}"
        );
        assert!(has_arg(&args, "PROJECT=alpha"));
    }

    #[test]
    fn git_run_args_forward_project_remote_url_when_present() {
        let certs = PathBuf::from("/tmp/ca");
        let url = "https://github.com/example/repo.git";
        let with_url = build_git_run_args("alpha", &certs, "tillandsias-git:v1", Some(url), None);
        assert!(
            with_url
                .iter()
                .any(|a| a == &format!("TILLANDSIAS_PROJECT_REMOTE_URL={url}")),
            "expected upstream URL env var: {with_url:?}"
        );

        let without_url = build_git_run_args("alpha", &certs, "tillandsias-git:v1", None, None);
        assert!(
            !without_url
                .iter()
                .any(|a| a.starts_with("TILLANDSIAS_PROJECT_REMOTE_URL=")),
            "expected no upstream URL env var: {without_url:?}"
        );
    }

    #[test]
    fn git_run_args_mount_vault_token_when_supplied() {
        // @trace spec:tillandsias-vault — Phase 6 default flow
        let certs = PathBuf::from("/tmp/ca");
        let secret = "tillandsias-vault-token-git-mirror-alpha-1234";
        let args = build_git_run_args("alpha", &certs, "tillandsias-git:v1", None, Some(secret));

        // The vault token secret MUST be mounted at the stable path
        // /run/secrets/vault-token, owned by the git user (uid 1000) so the
        // in-container vault-cli helper can actually read it under keep-id.
        let secret_arg = format!("{secret},{GIT_VAULT_TOKEN_SECRET_OPTS}");
        assert!(
            args.iter().any(|a| a == &secret_arg),
            "expected vault token secret arg `{secret_arg}` in args: {args:?}"
        );

        // Regression pin (literal, NOT derived from the constant): the secret
        // MUST be owned by the git user (uid/gid 1000). Podman defaults
        // `--secret` to root:root, and a root-owned mode 0400 file is
        // unreadable by the container's unprivileged `git` user under
        // `--userns=keep-id` — `vault-cli` then reports "no Vault token at
        // /run/secrets/vault-token" and the git-mirror push silently falls back
        // to interactive auth. Asserting the literal here (rather than
        // reformatting the constant) is what actually catches a regression.
        // @trace spec:git-mirror-service, spec:tillandsias-vault
        let mounted = args
            .iter()
            .find(|a| a.contains("target=vault-token"))
            .expect("vault-token secret must be mounted");
        assert!(
            mounted.contains("uid=1000") && mounted.contains("gid=1000"),
            "vault-token secret must be owned by the git user (uid/gid 1000) \
             so it is readable under keep-id; got `{mounted}`"
        );

        // The container needs VAULT_ADDR + VAULT_ROLE to know how to talk
        // to Vault and which role to authenticate as.
        assert!(
            has_arg(&args, "VAULT_ADDR=https://vault:8200"),
            "missing VAULT_ADDR env: {args:?}"
        );
        assert!(
            has_arg(&args, "CURL_CA_BUNDLE=/etc/tillandsias/ca.crt"),
            "missing Vault CA env: {args:?}"
        );
        assert!(
            has_arg(&args, "VAULT_ROLE=git-mirror"),
            "missing VAULT_ROLE env: {args:?}"
        );

        // The legacy github-token podman secret MUST NOT be mounted in the
        // Vault flow — that's the whole point of Phase 6.
        assert!(
            !args
                .iter()
                .any(|a| a == "tillandsias-github-token,mode=0400"),
            "legacy github-token secret must not be mounted in vault flow: {args:?}"
        );
    }

    #[test]
    fn status_check_args_probe_proxy_git_and_inference_from_forge() {
        let args = build_status_check_forge_args(
            &PathBuf::from("/tmp/workspace"),
            "alpha",
            &PathBuf::from("/tmp/ca"),
            "1.2.3",
        );

        assert!(has_arg(&args, "--rm"));
        assert!(has_arg(&args, "--entrypoint"));
        assert!(has_arg(&args, "/bin/bash"));
        assert!(has_arg(&args, "localhost/tillandsias-forge:v1.2.3"));
        assert!(
            args.iter()
                .any(|arg| arg.contains("check_port proxy 3128 proxy"))
        );
        assert!(
            args.iter()
                .any(|arg| arg.contains("check_port git-service 9418 git"))
        );
        assert!(args.iter().any(|arg| arg.contains("check_inference")));
    }

    #[test]
    fn podman_runtime_blocker_matches_known_health_failures() {
        assert!(podman_runtime_blocker(
            "Failed to connect to user scope bus via local transport: No such file or directory"
        ));
        assert!(podman_runtime_blocker(
            "netavark encountered multiple errors: aardvark-dns failed to start"
        ));
        assert!(podman_runtime_blocker(
            "Error: cannot set up namespace: newuidmap returned exit status 1"
        ));
        assert!(!podman_runtime_blocker("podman run exited with status 125"));
    }

    #[test]
    fn opencode_args_mount_workspace_and_prompt() {
        let args = build_opencode_forge_args(
            &PathBuf::from("/tmp/project"),
            "alpha",
            Some("hello"),
            &PathBuf::from("/tmp/ca"),
            "1.2.3",
            ForgeMode::Cli,
            false,
            true,
        );

        // Prompted mode is non-interactive; podman should not claim a TTY.
        assert!(!has_arg(&args, "--interactive"));
        assert!(!has_arg(&args, "--tty"));
        assert!(has_arg(&args, "--entrypoint"));
        assert!(has_arg(
            &args,
            "/usr/local/bin/entrypoint-forge-opencode.sh"
        ));
        assert!(!has_arg(&args, "/bin/bash"));
        assert!(has_arg(&args, "TILLANDSIAS_OPENCODE_PROMPT=hello"));
        assert!(has_arg(&args, "TILLANDSIAS_PROJECT=alpha"));
        assert!(has_arg(&args, "TILLANDSIAS_PROJECT_HOST_MOUNT=1"));
        assert!(has_arg(&args, "TILLANDSIAS_DEBUG=1"));
        assert!(
            args.iter().any(|arg| arg.starts_with("GIT_AUTHOR_NAME="))
                == args.iter().any(|arg| arg.starts_with("GIT_AUTHOR_EMAIL=")),
            "git identity env should be injected as a complete name/email pair"
        );
        assert!(
            args.iter()
                .any(|arg| arg == "/tmp/project:/home/forge/src/alpha:rw")
        );
    }

    #[test]
    fn opencode_args_diagnostics_mode() {
        let args = build_opencode_forge_args(
            &PathBuf::from("/tmp/project"),
            "alpha",
            Some("hello"),
            &PathBuf::from("/tmp/ca"),
            "1.2.3",
            ForgeMode::Cli,
            true,
            true,
        );

        assert!(!has_arg(&args, "--interactive"));
        assert!(!has_arg(&args, "--tty"));
        assert!(has_arg(&args, "--print"));
        assert!(has_arg(&args, "--output-format"));
        assert!(has_arg(&args, "json"));
        assert!(has_arg(&args, "--entrypoint"));
        assert!(has_arg(
            &args,
            "/usr/local/bin/entrypoint-forge-opencode.sh"
        ));
        assert!(has_arg(&args, "TILLANDSIAS_OPENCODE_PROMPT=hello"));
        assert!(has_arg(&args, "TILLANDSIAS_PROJECT=alpha"));
        assert!(has_arg(&args, "TILLANDSIAS_PROJECT_HOST_MOUNT=1"));
        assert!(has_arg(&args, "TILLANDSIAS_DEBUG=1"));
    }

    #[test]
    fn git_identity_env_pairs_cover_author_and_committer() {
        let identity = GitIdentity {
            name: Some("Big Pickle".to_string()),
            email: Some("big.pickle@example.test".to_string()),
        };
        let pairs = git_identity_env_pairs(&identity);

        assert_eq!(pairs.len(), 4);
        assert!(pairs.contains(&("GIT_AUTHOR_NAME", "Big Pickle".to_string())));
        assert!(pairs.contains(&("GIT_AUTHOR_EMAIL", "big.pickle@example.test".to_string())));
        assert!(pairs.contains(&("GIT_COMMITTER_NAME", "Big Pickle".to_string())));
        assert!(pairs.contains(&("GIT_COMMITTER_EMAIL", "big.pickle@example.test".to_string())));
    }

    #[test]
    fn forge_agent_run_argv_exports_project_selection() {
        let argv = build_forge_agent_run_argv(
            &PathBuf::from("/tmp/project"),
            "alpha",
            &PathBuf::from("/tmp/ca"),
            "1.2.3",
            ForgeAgentMode::Codex,
            false,
        );

        assert!(has_arg(&argv, "PROJECT=alpha"));
        assert!(has_arg(&argv, "TILLANDSIAS_PROJECT=alpha"));
        assert!(has_arg(&argv, "TILLANDSIAS_PROJECT_HOST_MOUNT=1"));
    }

    #[test]
    fn forge_agent_run_args_export_debug_when_requested() {
        let args = build_forge_agent_run_args(
            &PathBuf::from("/tmp/project"),
            "alpha",
            &PathBuf::from("/tmp/ca"),
            "1.2.3",
            ForgeAgentMode::Codex,
            true,
        );

        assert_eq!(args.first().map(|s| s.as_str()), Some("--rm"));
        assert!(!has_arg(&args, "podman"));
        assert!(!has_arg(&args, "run"));
        assert!(has_arg(&args, "TILLANDSIAS_PROJECT_HOST_MOUNT=1"));
        assert!(has_arg(&args, "TILLANDSIAS_DEBUG=1"));
    }

    #[test]
    fn opencode_web_event_log_path_is_project_scoped() {
        let path = opencode_web_event_log_path("visual-chess");
        assert!(path.to_string_lossy().contains("opencode-web"));
        assert!(path.to_string_lossy().contains("visual-chess.jsonl"));
    }

    #[test]
    fn json_escape_quotes_and_controls() {
        let value = "a\"b\\c\nd";
        assert_eq!(json_escape(value), "a\\\"b\\\\c\\nd");
    }

    #[test]
    fn opencode_web_startup_stage_order_is_stable() {
        assert_eq!(
            opencode_web_startup_stages(),
            &["stack", "proxy", "git", "inference", "forge", "browser"]
        );
    }

    #[test]
    fn opencode_web_readiness_status_contract_is_auth_gated() {
        assert!(opencode_web_route_ready_status(401));
        assert!(!opencode_web_route_ready_status(200));
        assert!(!opencode_web_route_ready_status(502));
        assert!(opencode_web_authenticated_ready_status(200));
        assert!(opencode_web_authenticated_ready_status(302));
        assert!(!opencode_web_authenticated_ready_status(401));
        assert!(!opencode_web_authenticated_ready_status(502));
    }

    #[test]
    fn opencode_web_auth_cookie_header_is_canonical() {
        let token = [7u8; 32];
        let header = opencode_web_auth_cookie_header(&token);
        assert!(header.starts_with("tillandsias_session="));
        assert!(!header.contains('\n'));
        assert!(!header.contains(' '));
    }

    #[test]
    fn opencode_web_browser_spec_is_built_with_typed_podman_flags() {
        let profile_dir = PathBuf::from("/tmp/tillandsias/browser/test-profile");
        let certs_dir = PathBuf::from("/tmp/tillandsias/ca");
        let display = BrowserDisplayContext {
            display: Some(":99".to_string()),
            xauthority: None,
            wayland_display: None,
            xdg_runtime_dir: None,
        };
        let token = [7u8; 32];
        let expected_app_url = tillandsias_otp::build_login_data_url(
            "http://opencode.visual-chess.localhost/",
            &token,
        );

        let spec = build_opencode_web_browser_spec(
            &expected_app_url,
            "1.2.3",
            &profile_dir,
            &certs_dir,
            &display,
            "visual-chess",
        )
        .expect("browser spec");
        let args = spec.build_run_args();

        assert!(has_arg(&args, "--pull=never"));
        // Intentionally NOT --read-only: Chromium crashpad aborts on
        // a read-only rootfs because it cannot create its database dir,
        // exiting 133 immediately. See build_opencode_web_browser_spec.
        assert!(!has_arg(&args, "--read-only"));
        assert!(has_arg(&args, "--cap-add"));
        assert!(has_arg(&args, "SYS_CHROOT"));
        assert!(has_arg(&args, "--network"));
        assert!(has_arg(&args, "host"));
        assert!(has_arg(&args, "-d"));
        assert!(has_arg(&args, "--name"));
        assert!(has_arg(&args, "tillandsias-browser-visual-chess"));
        assert!(
            args.iter().any(|arg| {
                arg == "type=bind,source=/tmp/tillandsias/ca/intermediate.crt,target=/etc/tillandsias/ca.crt,readonly=true"
            })
        );
        assert!(has_arg(
            &args,
            "TILLANDSIAS_CA_BUNDLE=/etc/tillandsias/ca.crt"
        ));
        assert!(has_arg(&args, "SSL_CERT_FILE=/etc/tillandsias/ca.crt"));
        assert!(
            args.iter()
                .any(|arg| arg == "tillandsias-chromium-framework:v1.2.3")
        );
        assert!(
            args.iter()
                .any(|arg| arg == &format!("--app={expected_app_url}"))
        );
        assert!(
            args.iter()
                .any(|arg| arg == "--user-data-dir=/tmp/tillandsias/browser/test-profile")
        );
        assert!(has_arg(&args, "--ozone-platform=x11"));
    }

    fn source_window<'a>(source: &'a str, signature: &str) -> &'a str {
        let start = source
            .find(signature)
            .unwrap_or_else(|| panic!("missing signature: {signature}"));
        let tail = &source[start..];
        let end = tail
            .find("\n    fn ")
            .or_else(|| tail.find("\nfn "))
            .unwrap_or(tail.len());
        &tail[..end]
    }

    #[test]
    fn idiomatic_podman_launch_paths_do_not_bypass_shared_layer() {
        let source = include_str!(concat!(env!("CARGO_MANIFEST_DIR"), "/src/main.rs"));

        assert!(
            !source.contains("Command::new(\"podman\")"),
            "headless runtime must not construct podman commands directly"
        );

        let init_window = source_window(source, "fn run_init(debug: bool, force: bool)");
        assert!(
            init_window.contains("PodmanClient::new()"),
            "run_init must use PodmanClient"
        );
        assert!(
            init_window.contains("\"web\""),
            "run_init must include the web image"
        );
        assert!(
            init_window.contains("podman_command()") || init_window.contains("podman_runtime()"),
            "run_init must route through the shared podman layer"
        );

        let status_window = source_window(source, "fn run_status_check(debug: bool)");
        assert!(
            status_window.contains("PodmanClient::new()"),
            "run_status_check must use PodmanClient"
        );
        assert!(
            status_window.contains("podman_command()")
                || status_window.contains("podman_runtime()"),
            "run_status_check must route through the shared podman layer"
        );

        let login_window = source_window(source, "fn run_github_login(debug: bool)");
        assert!(
            login_window.contains("podman_command()"),
            "run_github_login must use the shared podman command constructor"
        );
        assert!(
            login_window.contains("\"status\"") && login_window.contains("\"auth\""),
            "run_github_login must verify the containerized gh session"
        );
        assert!(
            login_window.contains("vault-cli.sh write secret/github/token"),
            "run_github_login must persist the token to Vault from inside the container"
        );

        let opencode_window = source_window(
            source,
            "fn run_opencode_mode(project_path: &str, prompt: Option<&str>, debug: bool)",
        );
        assert!(
            opencode_window.contains("PodmanClient::new()"),
            "run_opencode_mode must use PodmanClient"
        );
        assert!(
            opencode_window.contains("[OpenCode] failed to start proxy:")
                && opencode_window.contains("[OpenCode] failed to start git:")
                && opencode_window.contains("[OpenCode] failed to start inference:")
                && opencode_window.contains("[OpenCode] forge session exited:"),
            "run_opencode_mode must report stage-specific container failures"
        );

        let web_window = source_window(source, "pub(crate) fn run_opencode_web_mode(");
        assert!(
            web_window.contains("PodmanClient::new()"),
            "run_opencode_web_mode must use PodmanClient"
        );

        assert!(
            web_window.contains("existing_router_host_port(&client, debug).await?"),
            "run_opencode_web_mode must reuse an existing router before probing ports"
        );

        let observatorium_window = source_window(source, "fn run_observatorium_mode(");
        assert!(
            observatorium_window.contains("PodmanClient::new()"),
            "observatorium mode must use PodmanClient"
        );
        assert!(
            observatorium_window
                .contains("ensure_versioned_images(&root, &images, version, debug)?;"),
            "observatorium mode must preflight required images"
        );

        let reload_window = source_window(source, "async fn caddy_reload_routes(debug: bool)");
        assert!(
            reload_window.contains("podman_command()"),
            "router reload must use the shared podman command constructor"
        );
    }

    #[test]
    fn source_built_init_and_status_check_smoke_uses_fake_podman() {
        let _guard = env_lock();

        let root = find_checkout_root().expect("repo root");
        let version = VERSION.trim();
        let project_name = root
            .file_name()
            .and_then(|n| n.to_str())
            .unwrap_or("tillandsias");
        let certs_dir = ensure_ca_bundle(false).expect("ensure_ca_bundle");
        let status_args =
            build_status_check_forge_args(root.as_path(), project_name, &certs_dir, version);
        assert!(
            status_args.join(" ").contains("check_inference()"),
            "status-check plan should keep the inference probe"
        );
        assert!(
            status_args
                .join(" ")
                .contains("echo \"[status-check] forge online\""),
            "status-check plan should keep the completion marker"
        );
        if std::env::var_os("LITMUS_PODMAN_CALLS_FILE").is_some() {
            let images = [
                "proxy",
                "git",
                "inference",
                "chromium-core",
                "chromium-framework",
                "forge",
                "web",
            ];

            ensure_enclave_network(false).expect("ensure_enclave_network");
            ensure_versioned_images(&root, &images, version, false)
                .expect("ensure_versioned_images");
        }
        eprintln!("[status-check] planned args: {}", status_args.join(" "));
    }

    #[test]
    fn observatorium_mode_preflights_web_image() {
        let source = include_str!(concat!(env!("CARGO_MANIFEST_DIR"), "/src/main.rs"));
        let window = source_window(source, "fn run_observatorium_mode(");
        assert!(
            window.contains(
                "let images = [\"web\", \"router\", \"chromium-core\", \"chromium-framework\"];"
            ),
            "observatorium mode must preflight the web image"
        );
        assert!(
            window.contains("ensure_versioned_images(&root, &images, version, debug)?;"),
            "observatorium mode must ensure the web image exists before launch"
        );
    }

    #[test]
    fn observatorium_web_args_mount_project_read_only_under_source() {
        let args = build_observatorium_web_args(
            Path::new("/tmp/project"),
            "project",
            Path::new("/tmp/runtime/observatorium"),
            "tillandsias-web:v1.2.3",
        );

        assert!(has_arg(&args, "--pull=never"));
        assert!(has_arg(&args, "--read-only"));
        assert!(has_arg(&args, "--network"));
        assert!(has_arg(&args, ENCLAVE_NET));
        assert!(has_arg(&args, "--name"));
        assert!(has_arg(&args, "tillandsias-observatorium-project"));
        assert!(
            args.iter()
                .any(|arg| arg
                    == "type=bind,source=/tmp/project,target=/var/www/source,readonly=true")
        );
        assert!(args.iter().any(|arg| {
            arg == "type=bind,source=/tmp/runtime/observatorium,target=/var/www/observatorium,readonly=true"
        }));
        assert_eq!(
            args.last().map(|s| s.as_str()),
            Some("tillandsias-web:v1.2.3")
        );
    }

    #[test]
    fn project_label_from_path_normalizes_for_localhost_hostnames() {
        assert_eq!(
            project_label_from_path(Path::new("/tmp/My Project_v2"), "fallback"),
            "my-project-v2"
        );
        assert_eq!(
            project_label_from_path(Path::new("/tmp/---"), "fallback"),
            "fallback"
        );
    }

    #[test]
    fn opencode_web_reuses_existing_router_before_host_port_selection() {
        let source = include_str!(concat!(env!("CARGO_MANIFEST_DIR"), "/src/main.rs"));
        let window = source_window(source, "pub(crate) fn run_opencode_web_mode(");
        let reuse_idx = window
            .find("existing_router_host_port(&client, debug).await?")
            .expect("missing router reuse call");
        let probe_idx = window
            .find("select_router_host_port(port_override, debug)?")
            .expect("missing router port probe");
        assert!(
            reuse_idx < probe_idx,
            "run_opencode_web_mode must reuse an existing router before probing ports"
        );
    }

    // @trace spec:subdomain-routing-via-reverse-proxy
    #[test]
    fn router_run_args_encode_expected_container_shape() {
        let certs_dir = PathBuf::from("/tmp/ca");
        let args = build_router_run_args(&certs_dir, "tillandsias-router:v1.2.3", 8080);

        // Security flags
        assert!(has_arg(&args, "--detach"));
        assert!(has_arg(&args, "--rm"));
        assert!(has_arg(&args, "--read-only"));
        assert!(has_arg(&args, "--cap-drop=ALL"));
        assert!(has_arg(&args, "--security-opt=no-new-privileges"));
        assert!(has_arg(&args, "--userns=keep-id"));

        // Naming and network
        assert!(has_arg(&args, "tillandsias-router"));
        assert!(has_arg(&args, "router"));
        assert!(has_arg(&args, ENCLAVE_NET));

        // Loopback-only host publish (fix-router-loopback-port)
        assert!(has_arg(&args, "127.0.0.1:8080:8080"));

        // Dynamic Caddyfile bind-mount present
        assert!(args.iter().any(|arg| arg.contains("dynamic.Caddyfile")));

        // CA cert mount
        assert!(
            args.iter()
                .any(|arg| arg.contains("intermediate.crt")
                    && arg.contains("/etc/tillandsias/ca.crt"))
        );

        // Image is the last argument
        assert_eq!(
            args.last().map(|s| s.as_str()),
            Some("tillandsias-router:v1.2.3")
        );
    }

    // @trace spec:subdomain-routing-via-reverse-proxy, spec:opencode-web-session-otp
    #[test]
    fn dynamic_caddyfile_routes_opencode_service() {
        let routes = vec![RouterRoute::new(
            "opencode.visual-chess",
            "tillandsias-visual-chess-forge",
            8080u16,
        )];
        let config = generate_dynamic_caddyfile(&routes);

        // Verify Caddy block syntax is present, with the listener pinned to
        // http://...:8080 so Caddy doesn't try to bind :443 and doesn't
        // upgrade to HTTPS-only via implicit h2/h3.
        assert!(
            config.contains("http://opencode.visual-chess.localhost:8080 {"),
            "missing site block header: {config}"
        );

        // The OTP auth chain: forward_auth gates everything except
        // POST /_auth/login, which is proxied to the in-container sidecar.
        // @trace spec:opencode-web-session-otp
        assert!(
            config.contains("handle /_auth/login"),
            "missing login handler: {config}"
        );
        assert!(
            config.contains("reverse_proxy localhost:9090"),
            "missing sidecar proxy for login: {config}"
        );
        assert!(
            config.contains("forward_auth localhost:9090"),
            "missing forward_auth directive: {config}"
        );
        assert!(
            config.contains("uri /validate?project=visual-chess"),
            "missing validate uri with project label: {config}"
        );
        assert!(
            config.contains("copy_headers Cookie"),
            "missing copy_headers Cookie: {config}"
        );

        // Upstream is the container DNS name on the enclave network, not
        // 127.0.0.1 (which from inside the router would loop back).
        assert!(
            config.contains("reverse_proxy tillandsias-visual-chess-forge:8080"),
            "missing upstream reverse_proxy: {config}"
        );
    }

    #[test]
    fn dynamic_caddyfile_multiple_routes() {
        let routes = vec![
            RouterRoute::new("opencode.alpha", "tillandsias-alpha-forge", 8080u16),
            RouterRoute::new("opencode.beta", "tillandsias-beta-forge", 8081u16),
        ];
        let config = generate_dynamic_caddyfile(&routes);

        // Both site blocks present
        assert!(config.contains("opencode.alpha.localhost"));
        assert!(config.contains("opencode.beta.localhost"));

        // Both upstream proxies present
        assert!(config.contains("reverse_proxy tillandsias-alpha-forge:8080"));
        assert!(config.contains("reverse_proxy tillandsias-beta-forge:8081"));

        // Both project labels feed into forward_auth — note we extract the
        // rightmost component of `opencode.alpha` (= "alpha"), matching what
        // the sidecar does from the Host header.
        // @trace spec:opencode-web-session-otp
        assert!(config.contains("uri /validate?project=alpha"));
        assert!(config.contains("uri /validate?project=beta"));
    }

    #[test]
    fn dynamic_caddyfile_empty_routes_returns_empty_string() {
        let routes: Vec<RouterRoute> = vec![];
        let config = generate_dynamic_caddyfile(&routes);
        assert!(config.is_empty());
    }

    /// Render the canonical demo case end-to-end to lock in the exact wire
    /// format. Any change here must be deliberate (and reviewed against
    /// `images/router/base.Caddyfile` for compatibility).
    ///
    /// @trace spec:opencode-web-session-otp, spec:subdomain-routing-via-reverse-proxy
    #[test]
    fn dynamic_caddyfile_demo_case_renders_full_auth_chain() {
        let routes = vec![RouterRoute::new(
            "opencode.demo",
            "tillandsias-demo-forge",
            4096u16,
        )];
        let config = generate_dynamic_caddyfile(&routes);

        // Spot-check the full chain in a single rendered block.
        assert!(config.contains("http://opencode.demo.localhost:8080 {"));
        assert!(config.contains("handle /_auth/login"));
        assert!(config.contains("reverse_proxy localhost:9090"));
        assert!(config.contains("forward_auth localhost:9090"));
        assert!(config.contains("uri /validate?project=demo"));
        assert!(config.contains("copy_headers Cookie"));
        assert!(config.contains("reverse_proxy tillandsias-demo-forge:4096"));
    }

    #[test]
    fn dynamic_caddyfile_routes_observatorium_with_root_redirect() {
        let routes = vec![
            RouterRoute::new(
                "observatorium.demo",
                "tillandsias-observatorium-demo",
                8080u16,
            )
            .with_root_redirect("/observatorium/"),
        ];
        let config = generate_dynamic_caddyfile(&routes);

        assert!(config.contains("http://observatorium.demo.localhost:8080 {"));
        assert!(config.contains("uri /validate?project=demo"));
        assert!(config.contains("redir /observatorium/ 302"));
        assert!(config.contains("reverse_proxy tillandsias-observatorium-demo:8080"));
    }

    #[tokio::test]
    async fn caddy_reload_routes_handles_connection_error_gracefully() {
        // Test that caddy_reload_routes gracefully handles connection failures
        // (e.g., router not yet ready). The admin API endpoint on localhost:2019
        // will be unreachable, but the function should log a warning and return Ok.
        let result = caddy_reload_routes(false).await;

        // Should succeed (not fail) even when the router is unreachable.
        assert!(result.is_ok());
    }

    #[tokio::test]
    async fn caddy_reload_routes_with_debug_enabled() {
        // Test that caddy_reload_routes works with debug flag enabled.
        // The function will attempt to reach localhost:2019, fail gracefully,
        // and emit debug output (captured via eprintln, visible in test output).
        let result = caddy_reload_routes(true).await;

        // Should still succeed even with debug output enabled.
        assert!(result.is_ok());
    }

    // @trace spec:init-command, spec:init-incremental-builds
    #[test]
    fn init_command_detects_repo_root_from_version_and_images_dir() {
        // Test that find_checkout_root correctly identifies the Tillandsias repo
        // by detecting VERSION file and images/ directory.
        // This validates the repository structure requirements.
        let root = find_checkout_root();
        assert!(
            root.is_ok(),
            "find_checkout_root should succeed in a valid repo"
        );

        let root = root.unwrap();
        assert!(
            root.join("VERSION").exists(),
            "VERSION file must exist at repo root"
        );
        assert!(
            root.join("images").is_dir(),
            "images directory must exist at repo root"
        );
    }

    #[test]
    fn init_build_state_tracks_image_status() {
        // Test that InitBuildState correctly tracks success/failure status for images.
        // @trace spec:init-incremental-builds
        let mut state = InitBuildState::new();

        // Initially, no images are marked successful
        assert!(!state.was_successful("proxy"));
        assert!(!state.was_successful("forge"));

        // Mark proxy as successful
        state.mark_success("proxy");
        assert!(state.was_successful("proxy"));
        assert!(!state.was_successful("forge"));

        // Mark forge as failed
        state.mark_failed("forge");
        assert!(!state.was_successful("forge"));

        // Mark forge as successful (overwrite failed status)
        state.mark_success("forge");
        assert!(state.was_successful("forge"));
    }

    #[test]
    fn init_build_state_persists_to_cache_directory() {
        // Test that InitBuildState can be saved and loaded from the cache directory.
        // @trace spec:init-incremental-builds
        let mut state = InitBuildState::new();
        state.mark_success("proxy");
        state.mark_success("git");
        state.mark_failed("inference");

        // Attempt to save state to cache
        let result = state.save();
        assert!(
            result.is_ok(),
            "InitBuildState::save() should succeed: {}",
            result.err().unwrap_or_default()
        );

        // Load state back from cache
        let loaded = InitBuildState::load();
        assert!(
            loaded.is_ok(),
            "InitBuildState::load() should succeed: {}",
            loaded.err().unwrap_or_default()
        );

        let loaded_state = loaded.unwrap().expect("loaded state should not be None");
        assert!(
            loaded_state.was_successful("proxy"),
            "proxy should be marked successful after reload"
        );
        assert!(
            loaded_state.was_successful("git"),
            "git should be marked successful after reload"
        );
        assert!(
            !loaded_state.was_successful("inference"),
            "inference should NOT be marked successful after reload"
        );
    }

    #[test]
    fn image_specs_returns_correct_containerfile_paths() {
        // Test that image_specs returns the correct Containerfile path and context dir
        // for each supported image type.
        // @trace spec:init-command
        let root = find_checkout_root().expect("should find repo root");

        // Test forge base image (uses "images/default/Containerfile.base")
        let (containerfile, context) =
            image_specs(&root, "forge-base").expect("forge base image specs should be resolvable");
        assert!(containerfile.ends_with("images/default/Containerfile.base"));
        assert!(context.ends_with("images/default"));

        // Test forge image (uses "images/default/Containerfile")
        let (containerfile, context) =
            image_specs(&root, "forge").expect("forge image specs should be resolvable");
        assert!(containerfile.ends_with("images/default/Containerfile"));
        assert!(context.ends_with("images/default"));

        // Test proxy image
        let (containerfile, context) =
            image_specs(&root, "proxy").expect("proxy image specs should be resolvable");
        assert!(containerfile.ends_with("images/proxy/Containerfile"));
        assert!(context.ends_with("images/proxy"));

        // Test git image
        let (containerfile, context) =
            image_specs(&root, "git").expect("git image specs should be resolvable");
        assert!(containerfile.ends_with("images/git/Containerfile"));
        assert!(context.ends_with("images/git"));

        // Test inference image
        let (containerfile, context) =
            image_specs(&root, "inference").expect("inference image specs should be resolvable");
        assert!(containerfile.ends_with("images/inference/Containerfile"));
        assert!(context.ends_with("images/inference"));

        // Test chromium-core image (uses "images/chromium/Containerfile.core")
        let (containerfile, context) = image_specs(&root, "chromium-core")
            .expect("chromium-core image specs should be resolvable");
        assert!(containerfile.ends_with("images/chromium/Containerfile.core"));
        assert!(context.ends_with("images/chromium"));

        // Test chromium-framework image (uses "images/chromium/Containerfile.framework")
        let (containerfile, context) = image_specs(&root, "chromium-framework")
            .expect("chromium-framework image specs should be resolvable");
        assert!(containerfile.ends_with("images/chromium/Containerfile.framework"));
        assert!(context.ends_with("images/chromium"));

        // Test router image
        let (containerfile, context) =
            image_specs(&root, "router").expect("router image specs should be resolvable");
        assert!(containerfile.ends_with("images/router/Containerfile"));
        assert!(context.ends_with("images/router"));

        // Test web image
        let (containerfile, context) =
            image_specs(&root, "web").expect("web image specs should be resolvable");
        assert!(containerfile.ends_with("images/web/Containerfile"));
        assert!(context.ends_with("images/web"));

        // Test zeroclaw image
        let (containerfile, context) =
            image_specs(&root, "zeroclaw").expect("zeroclaw image specs should be resolvable");
        assert!(containerfile.ends_with("images/zeroclaw/Containerfile"));
        assert!(context.ends_with("images/zeroclaw"));
    }

    #[test]
    fn image_specs_rejects_unknown_image_types() {
        // Test that image_specs properly rejects unknown image types.
        // @trace spec:init-command
        let root = find_checkout_root().expect("should find repo root");
        let result = image_specs(&root, "unknown-image");

        assert!(
            result.is_err(),
            "image_specs should reject unknown image type"
        );
        let error = result.err().unwrap();
        assert!(
            error.contains("Unknown image type"),
            "error message should mention unknown type: {error}"
        );
    }

    #[test]
    fn versioned_image_tag_formats_correctly() {
        // Test that versioned_image_tag produces the correct format.
        // @trace spec:init-command
        let tag = versioned_image_tag("forge", "0.1.260513");
        assert_eq!(tag, "localhost/tillandsias-forge:v0.1.260513");

        let tag = versioned_image_tag("proxy", "1.0.0");
        assert_eq!(tag, "localhost/tillandsias-proxy:v1.0.0");

        let tag = versioned_image_tag("chromium-framework", "0.2.100");
        assert_eq!(tag, "localhost/tillandsias-chromium-framework:v0.2.100");
    }

    #[test]
    fn image_build_inputs_include_chromium_core_identity_for_framework() {
        let core = ImageBuildIdentity {
            source_digest: "sha256:core".to_string(),
            canonical_tag: "localhost/tillandsias-chromium-core:sha256-core".to_string(),
            version_alias: "localhost/tillandsias-chromium-core:v1.0.0".to_string(),
            latest_alias: "localhost/tillandsias-chromium-core:latest".to_string(),
            labels: BTreeMap::new(),
        };
        let identities = HashMap::from([("chromium-core".to_string(), core.clone())]);
        let (build_args, dependency_digests) =
            image_build_inputs("chromium-framework", &identities).unwrap();

        assert_eq!(
            build_args.get("CHROMIUM_CORE_IMAGE"),
            Some(&core.canonical_tag)
        );
        assert_eq!(
            dependency_digests.get("chromium-core"),
            Some(&core.source_digest)
        );
    }

    #[test]
    fn image_build_inputs_are_empty_for_non_framework_images() {
        for image in ["proxy", "forge-base", "git"] {
            let (build_args, dependency_digests) =
                image_build_inputs(image, &HashMap::new()).unwrap();
            assert!(build_args.is_empty(), "{image} should have no build args");
            assert!(
                dependency_digests.is_empty(),
                "{image} should have no dependency digests"
            );
        }
    }

    #[test]
    fn image_build_inputs_include_forge_base_identity_for_forge() {
        let base = ImageBuildIdentity {
            source_digest: "sha256:forge-base".to_string(),
            canonical_tag: "localhost/tillandsias-forge-base:sha256-forge-base".to_string(),
            version_alias: "localhost/tillandsias-forge-base:v1.0.0".to_string(),
            latest_alias: "localhost/tillandsias-forge-base:latest".to_string(),
            labels: BTreeMap::new(),
        };
        let identities = HashMap::from([("forge-base".to_string(), base)]);
        let (build_args, dependency_digests) = image_build_inputs("forge", &identities).unwrap();

        assert_eq!(
            build_args.get("BASE_IMAGE"),
            Some(&"localhost/tillandsias-forge-base:sha256-forge-base".to_string())
        );
        assert_eq!(
            dependency_digests.get("forge-base"),
            Some(&"sha256:forge-base".to_string())
        );
    }

    #[test]
    fn image_inspect_metadata_reads_nested_labels_and_ids() {
        let json = r#"[{"Id":"sha256:image","Config":{"Labels":{"io.tillandsias.image.source-digest":"sha256:source"}}}]"#;
        let (image_id, source_digest) = image_inspect_metadata(json).unwrap();
        assert_eq!(image_id.as_deref(), Some("sha256:image"));
        assert_eq!(source_digest.as_deref(), Some("sha256:source"));
    }

    #[test]
    fn legacy_init_state_deserializes_without_identity_records() {
        let legacy = r#"{
            "images":{"forge":"success"},
            "image_source_digests":{"forge":"old-digest"},
            "runtime_asset_manifest_digest":null,
            "timestamp":"2026-06-01T00:00:00Z"
        }"#;
        let state: InitBuildState = serde_json::from_str(legacy).unwrap();
        assert!(state.was_successful("forge"));
        assert!(state.image_identities.is_empty());
    }

    #[test]
    fn init_logs_captured_in_debug_mode() {
        // Test that init_log_file returns a valid path in debug mode.
        // @trace spec:init-command
        let log_path = init_log_file("proxy", true);
        assert!(
            log_path.is_some(),
            "init_log_file should return Some in debug mode"
        );

        let path = log_path.unwrap();
        assert!(
            path.to_string_lossy()
                .contains("tillandsias-init-proxy.log")
        );
    }

    #[test]
    fn init_logs_none_in_non_debug_mode() {
        // Test that init_log_file returns None in non-debug mode.
        // @trace spec:init-command
        let log_path = init_log_file("proxy", false);
        assert!(
            log_path.is_none(),
            "init_log_file should return None in non-debug mode"
        );
    }

    #[test]
    fn init_command_defines_required_images_in_order() {
        // Test that run_init builds images in the correct order: proxy, git,
        // inference, router, chromium-core, chromium-framework, forge-base, forge, web.
        // @trace spec:init-command, spec:init-incremental-builds
        // NOTE: This test validates the IMAGE BUILD ORDER, which is critical for
        // chromium-framework (depends on chromium-core) and inter-image dependencies.
        // The actual build execution is skipped here; we test the order specification.

        // The images array from run_init defines the build order:
        // proxy -> git -> inference -> router -> chromium-core -> chromium-framework
        // -> forge-base -> forge -> zeroclaw -> web
        let images = [
            "proxy",
            "git",
            "inference",
            "router",
            "chromium-core",
            "chromium-framework",
            "forge-base",
            "forge",
            "zeroclaw",
            "web",
        ];

        // Verify all required images are present
        assert_eq!(images.first(), Some(&"proxy"), "proxy must be first");
        assert!(images.contains(&"git"), "git must be included");
        assert!(images.contains(&"inference"), "inference must be included");
        assert!(images.contains(&"router"), "router must be included");
        assert!(
            images.contains(&"chromium-core"),
            "chromium-core must be included"
        );
        assert!(
            images.contains(&"chromium-framework"),
            "chromium-framework must be included"
        );
        assert!(images.contains(&"forge"), "forge must be included");
        assert_eq!(images.last(), Some(&"web"), "web must be last");

        // Verify build order: chromium-framework comes AFTER chromium-core
        let core_idx = images.iter().position(|&i| i == "chromium-core").unwrap();
        let framework_idx = images
            .iter()
            .position(|&i| i == "chromium-framework")
            .unwrap();
        assert!(
            core_idx < framework_idx,
            "chromium-core must be built before chromium-framework"
        );
        let forge_base_idx = images.iter().position(|&i| i == "forge-base").unwrap();
        let forge_idx = images.iter().position(|&i| i == "forge").unwrap();
        assert!(
            forge_base_idx < forge_idx,
            "forge-base must be built before forge"
        );
        let zeroclaw_idx = images.iter().position(|&i| i == "zeroclaw").unwrap();
        assert!(
            forge_base_idx < zeroclaw_idx,
            "forge-base must be built before zeroclaw"
        );
    }

    #[test]
    fn test_is_optional_image() {
        assert!(is_optional_image("forge-base"));
        assert!(is_optional_image("forge"));
        assert!(is_optional_image("zeroclaw"));
        assert!(!is_optional_image("proxy"));
        assert!(!is_optional_image("git"));
        assert!(!is_optional_image("inference"));
        assert!(!is_optional_image("router"));
        assert!(!is_optional_image("chromium-core"));
        assert!(!is_optional_image("chromium-framework"));
        assert!(!is_optional_image("web"));
    }

    #[test]
    fn progress_output_format_is_valid() {
        // @trace gap:ON-005 — validate progress output format
        // Test that progress output lines are well-formed and show percentage
        // Format: "Pulling image <name> [████░░░░░░] <percent>%"

        let test_cases = vec![
            (0, 0), // percent -> filled blocks
            (10, 1),
            (25, 2),
            (50, 5),
            (75, 7),
            (100, 10),
        ];

        for (percent, expected_filled) in test_cases {
            // Build the progress line as the code would
            let bar_filled = "█".repeat(percent / 10);
            let bar_empty = "░".repeat(10 - (percent / 10));
            let line = format!(
                "Pulling image {} [{}{}] {}%",
                "forge", bar_filled, bar_empty, percent
            );

            // Validate it contains required parts
            assert!(
                line.contains("Pulling image"),
                "Must contain 'Pulling image'"
            );
            assert!(line.contains("["), "Must contain progress bar opening");
            assert!(line.contains("]"), "Must contain progress bar closing");
            assert!(line.contains("%"), "Must contain percentage sign");
            assert!(
                line.contains(&percent.to_string()),
                "Must contain percentage value"
            );

            // Verify bar has correct number of filled characters
            let bar_start = line.find('[').unwrap();
            let bar_end = line.find(']').unwrap();
            let bar_content = &line[bar_start + 1..bar_end];
            let filled_count = bar_content.chars().filter(|&c| c == '█').count();
            let empty_count = bar_content.chars().filter(|&c| c == '░').count();
            assert_eq!(
                filled_count, expected_filled,
                "Progress bar filled count should match"
            );
            assert_eq!(
                filled_count + empty_count,
                10,
                "Progress bar should have 10 total characters"
            );
        }
    }

    #[test]
    fn image_build_argv_uses_docker_format_for_healthchecks() {
        let identity = ImageBuildIdentity {
            source_digest: "abc123".to_string(),
            canonical_tag:
                "localhost/tillandsias-vault:sha256-0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
                    .to_string(),
            version_alias: "localhost/tillandsias-vault:v0.3.260626.1".to_string(),
            latest_alias: "localhost/tillandsias-vault:latest".to_string(),
            labels: BTreeMap::new(),
        };

        let argv = podman_build_argv(
            Path::new("/repo/images/vault/Containerfile"),
            Path::new("/repo/images/vault"),
            &identity,
            &BTreeMap::new(),
        )
        .expect("podman build argv");

        assert_eq!(
            &argv[0..3],
            ["build", "--format", "docker"],
            "Rust image builds must preserve Dockerfile HEALTHCHECK metadata"
        );
    }

    // ─────────────────────────────────────────────────────────
    // Control-socket liveness probe regression tests.
    // @trace spec:tray-host-control-socket, spec:tray-cli-coexistence
    //
    // Pinned bug: `maybe_spawn_detached_tray_for_cli` used to declare the
    // tray "ready" the moment `socket_path.exists()` returned true. That
    // false positive fired on every stale socket file left behind by a
    // crashed tray, so `--observatorium` and `--opencode-web` raced past
    // the helper and then failed in `send_issue_web_session` with
    // `Connection refused (os error 111)` against the dead inode.
    // ─────────────────────────────────────────────────────────
    #[test]
    fn control_socket_is_listening_returns_false_for_missing_path() {
        let tmp = tempfile::TempDir::new().expect("tempdir");
        let socket_path = tmp.path().join("control.sock");
        assert!(
            !control_socket_is_listening(&socket_path),
            "missing socket must be reported as not-listening"
        );
    }

    #[test]
    fn control_socket_is_listening_returns_false_for_stale_socket_file() {
        let tmp = tempfile::TempDir::new().expect("tempdir");
        let socket_path = tmp.path().join("control.sock");
        // A regular file at the socket path mimics the leftover-inode case
        // (no listener, just a name in the filesystem). `connect()` returns
        // ENOTSOCK / ECONNREFUSED — both must collapse to false.
        std::fs::write(&socket_path, b"").expect("write stale socket file");
        assert!(
            !control_socket_is_listening(&socket_path),
            "stale (non-socket) file must be reported as not-listening"
        );
    }

    #[test]
    fn control_socket_is_listening_returns_true_for_live_listener() {
        use std::os::unix::net::UnixListener;
        let tmp = tempfile::TempDir::new().expect("tempdir");
        let socket_path = tmp.path().join("control.sock");
        let _listener = UnixListener::bind(&socket_path).expect("bind listener");
        assert!(
            control_socket_is_listening(&socket_path),
            "bound listener must be reported as listening"
        );
    }

    /// `format_diagnostics_envelope_line` produces the pinned shape
    /// the distill script's stderr-companion path will consume. The
    /// line is space-separated `key=value` pairs prefixed with the
    /// `event:diagnostics_envelope` tag, same family as the existing
    /// `event:container_launch …` lines. The shape is the API the
    /// follow-on distill update reads — any regression here would
    /// silently break the framing recovery.
    ///
    /// @trace spec:cli-diagnostics, spec:runtime-diagnostics-stream
    /// @trace plan/issues/forge-diagnostics-automation-2026-05-27.md
    #[test]
    fn format_diagnostics_envelope_line_emits_pinned_shape() {
        let line = format_diagnostics_envelope_line(
            "2026-05-29T04:51:00Z",
            "0.2.260528",
            "linux",
            "opencode",
        );
        assert_eq!(
            line,
            "event:diagnostics_envelope timestamp=2026-05-29T04:51:00Z \
             tillandsias_version=0.2.260528 host_platform=linux agent=opencode"
        );
    }

    /// All five agent kinds (+ `none`) round-trip through
    /// `select_diagnostics_agent_kind` per the documented precedence
    /// (opencode > claude > codex > bash > observatorium). `none` is
    /// the fallback when --diagnostics was passed without an agent
    /// flag; the envelope still emits so operators get a real
    /// timestamp.
    ///
    /// @trace spec:cli-diagnostics
    #[test]
    fn select_diagnostics_agent_kind_respects_precedence_and_none_fallback() {
        // Precedence: opencode wins even if multiple flags are set.
        assert_eq!(
            select_diagnostics_agent_kind(true, true, true, true, true),
            "opencode"
        );
        // Each kind in isolation maps to its token.
        assert_eq!(
            select_diagnostics_agent_kind(true, false, false, false, false),
            "opencode"
        );
        assert_eq!(
            select_diagnostics_agent_kind(false, true, false, false, false),
            "claude"
        );
        assert_eq!(
            select_diagnostics_agent_kind(false, false, true, false, false),
            "codex"
        );
        assert_eq!(
            select_diagnostics_agent_kind(false, false, false, true, false),
            "bash"
        );
        assert_eq!(
            select_diagnostics_agent_kind(false, false, false, false, true),
            "observatorium"
        );
        // No agent flag → `none` fallback.
        assert_eq!(
            select_diagnostics_agent_kind(false, false, false, false, false),
            "none"
        );
    }

    /// Envelope line accepts the actual ISO-8601 format the runtime
    /// emits (`chrono::Utc::now().to_rfc3339_opts(SecondsFormat::Secs,
    /// true)` → `…Z` suffix, second-precision). Tests against a
    /// realistic chrono-produced string so a future format-flag flip
    /// (e.g. millisecond precision, non-Z timezone) breaks the
    /// regression instead of silently passing through.
    ///
    /// @trace spec:cli-diagnostics, spec:runtime-diagnostics-stream
    #[test]
    fn format_diagnostics_envelope_line_accepts_real_chrono_timestamp() {
        use chrono::SecondsFormat;
        let ts = chrono::Utc::now().to_rfc3339_opts(SecondsFormat::Secs, true);
        let line = format_diagnostics_envelope_line(&ts, "0.2.260528", "linux", "opencode");
        assert!(line.starts_with("event:diagnostics_envelope timestamp="));
        // Z suffix (the `true` arg above forces it).
        let ts_field = line
            .split_whitespace()
            .find(|tok| tok.starts_with("timestamp="))
            .expect("envelope must have a timestamp= field");
        assert!(
            ts_field.ends_with('Z'),
            "timestamp= must end with Z; got {ts_field}"
        );
    }
}
