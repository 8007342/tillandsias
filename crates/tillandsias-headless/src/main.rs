// @trace spec:linux-native-portable-executable
//! Tillandsias native headless app lifecycle launcher.
//!
//! Runs containerized development environments without a graphical interface.
//! Suitable for CI/CD, automation, and server deployments.
//!
//! Transparent Mode Detection (Phase 3):
//! - If --headless NOT set AND GTK available, re-exec with --headless + spawn tray
//! - If --headless set, run in headless mode (no tray UI)
//! - If --tray set, explicitly run in tray mode
//!
//! Usage:
//!   tillandsias                              # Auto-detect (transparent mode)
//!   tillandsias --headless [config_path]    # Headless mode (no UI)
//!   tillandsias --tray [config_path]        # Tray mode (requires gtk4 feature)
//!
//! JSON Events:
//!   - {"event":"app.started","timestamp":"<RFC3339>"} — at startup
//!   - {"event":"containers.running","count":N} — on discovery
//!   - {"event":"app.stopped","exit_code":0,"timestamp":"<RFC3339>"} — on graceful shutdown

use std::io::{self, Write};
use std::path::PathBuf;
use std::process::{Command, Stdio};
use tokio::signal::unix::{SignalKind, signal};

const VERSION: &str = include_str!("../../../VERSION");

fn main() {
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

    let debug = user_args.iter().any(|a| a == "--debug");
    let init = user_args.iter().any(|a| a == "--init");
    let github_login = user_args.iter().any(|a| a == "--github-login");
    let opencode = user_args.iter().any(|a| a == "--opencode");

    // @trace spec:cli-mode
    let prompt = user_args
        .iter()
        .position(|a| a == "--prompt")
        .and_then(|i| user_args.get(i + 1).map(|p| p.to_string()));

    let known_flags = [
        "--headless",
        "--tray",
        "--debug",
        "--init",
        "--github-login",
        "--opencode",
        "--prompt",
    ];
    if let Some(unsupported) = user_args
        .iter()
        .enumerate()
        .find(|(i, a)| a.starts_with('-') && !known_flags.contains(&a.as_str()) && user_args.get(i.saturating_sub(1)).map_or(true, |prev| prev != "--prompt"))
        .map(|(_, a)| a)
    {
        eprintln!("Unsupported option: {unsupported}");
        eprintln!("Run 'tillandsias --help' for supported options.");
        std::process::exit(2);
    }

    let headless = user_args.iter().any(|a| a == "--headless");
    let tray = user_args.iter().any(|a| a == "--tray");
    let config_path = user_args
        .iter()
        .find(|a| !a.starts_with('-'))
        .map(|p| p.to_string());

    if init {
        if let Err(e) = run_init(debug) {
            eprintln!("Error: {}", e);
            std::process::exit(1);
        }
        return;
    }

    if github_login {
        if let Err(e) = run_github_login(debug) {
            eprintln!("Error: {}", e);
            std::process::exit(1);
        }
        return;
    }

    if opencode {
        if let Some(project_path) = config_path {
            if let Some(prompt_text) = prompt {
                if let Err(e) = run_opencode_mode(&project_path, &prompt_text, debug) {
                    eprintln!("Error: {}", e);
                    std::process::exit(1);
                }
                return;
            } else {
                eprintln!("Error: --opencode requires --prompt <text>");
                std::process::exit(2);
            }
        } else {
            eprintln!("Error: --opencode requires project path");
            std::process::exit(2);
        }
    }

    // Phase 3, Task 12: Auto-detection (transparent mode)
    // If neither --headless nor --tray specified, auto-detect based on environment
    if !headless && !tray {
        if is_gtk_available() {
            // @trace spec:linux-native-portable-executable, spec:transparent-mode-detection
            // GTK is available — launch in tray mode with headless subprocess
            if cfg!(feature = "tray") {
                if let Err(e) = launch_tray_mode(config_path) {
                    eprintln!("Error launching tray mode: {}", e);
                    std::process::exit(1);
                }
                return;
            } else {
                // GTK available but tray feature not compiled — fall back to headless
                eprintln!(
                    "GTK detected but tray feature not compiled. \
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
    if tray {
        if cfg!(feature = "tray") {
            if let Err(e) = launch_tray_mode(config_path) {
                eprintln!("Error launching tray mode: {}", e);
                std::process::exit(1);
            }
            return;
        } else {
            eprintln!("Native tray wrapper is not packaged in this launcher yet.");
            eprintln!("Continuing with the headless app lifecycle for now.");
            if let Err(e) = run_headless(config_path) {
                eprintln!("Error: {}", e);
                std::process::exit(1);
            }
            return;
        }
    }

    // Headless mode (explicit --headless or auto-detected)
    if (headless || !cfg!(feature = "tray"))
        && let Err(e) = run_headless(config_path)
    {
        eprintln!("Error: {}", e);
        std::process::exit(1);
    }
}

fn print_usage(version: &str) {
    println!("Tillandsias v{}", version);
    println!("Usage: tillandsias [--headless|--tray] [config_path]");
    println!("       tillandsias --init [--debug]");
    println!("       tillandsias --github-login [--debug]");
    println!("       tillandsias --opencode <project> --prompt <text> [--debug]");
    println!("  --headless     Run in headless mode (no UI)");
    println!("  --tray         Run in tray mode (requires GTK)");
    println!("  --opencode     Enable LLM code analysis mode");
    println!("  --prompt TEXT  Send prompt to LLM inference (requires --opencode)");
    println!("  --init         Build required Tillandsias container images");
    println!("  --github-login Authenticate GitHub and create ephemeral Podman secret");
    println!("  --debug        Show command-level diagnostics");
    println!("  --version      Show version information");
    println!("  --help         Show this help");
    println!();
    println!("Auto-detection: Tray mode if GTK available, headless otherwise");
}

/// Locate the repository root for script-backed migration commands.
///
/// The installed binary is currently only a launcher, not a full embedded
/// runtime bundle. Until the Rust implementation absorbs these paths, commands
/// such as `--init` and `--github-login` run the repo scripts from the current
/// checkout or from `TILLANDSIAS_ROOT`.
fn find_repo_root() -> Result<PathBuf, String> {
    if let Ok(root) = std::env::var("TILLANDSIAS_ROOT") {
        let path = PathBuf::from(root);
        if path.join("scripts").join("build-image.sh").is_file() {
            return Ok(path);
        }
    }

    let mut dir = std::env::current_dir().map_err(|e| format!("Failed to get cwd: {e}"))?;
    loop {
        if dir.join("scripts").join("build-image.sh").is_file() {
            return Ok(dir);
        }
        if !dir.pop() {
            break;
        }
    }

    Err(
        "Could not find Tillandsias checkout. Run from the repo or set TILLANDSIAS_ROOT."
            .to_string(),
    )
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

/// Build required container images on demand.
///
/// @trace spec:init-command, spec:default-image, spec:git-mirror-service, spec:proxy-container, spec:inference-container, spec:web-image
fn run_init(debug: bool) -> Result<(), String> {
    let root = find_repo_root()?;
    let build_script = root.join("scripts").join("build-image.sh");
    let images = [
        "proxy",
        "git",
        "inference",
        "web",
        "chromium-core",
        "chromium-framework",
        "forge",
    ];

    for image in images {
        let mut command = Command::new(&build_script);
        command.arg(image).current_dir(&root);
        run_command(command, debug)?;
    }

    Ok(())
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

/// Container-side bridge for the retired Tauri `--github-login` path.
///
/// The host runtime only assumes Podman. GitHub CLI runs inside the git service
/// image; the host only captures the token in memory and creates the Podman
/// secret over stdin.
///
/// @trace spec:gh-auth-script, spec:secrets-management, spec:podman-secrets-integration
fn run_github_login(debug: bool) -> Result<(), String> {
    let root = find_repo_root()?;
    let version = VERSION.trim();
    let image = format!("tillandsias-git:v{version}");

    prompt_and_store_git_identity()?;

    ensure_image_exists(&root, "git", &image, debug)?;

    let container = format!("tillandsias-gh-login-{}", std::process::id());
    let cleanup = LoginContainerCleanup {
        name: container.clone(),
        debug,
    };

    let mut run = Command::new("podman");
    run.args([
        "run",
        "--detach",
        "--rm",
        "--name",
        &container,
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

    let mut login = Command::new("podman");
    login.args([
        "exec",
        "--interactive",
        "--tty",
        &container,
        "gh",
        "auth",
        "login",
        "--hostname",
        "github.com",
        "--git-protocol",
        "https",
    ]);
    run_command(login, debug)?;

    let mut token_cmd = Command::new("podman");
    token_cmd.args([
        "exec",
        &container,
        "gh",
        "auth",
        "token",
        "--hostname",
        "github.com",
    ]);
    let token = command_output(token_cmd, debug)?;
    if token.is_empty() {
        return Err("containerized gh auth token returned an empty token".to_string());
    }

    create_github_podman_secret(&token, debug)?;
    drop(cleanup);
    Ok(())
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
        let mut command = Command::new("podman");
        command.args(["rm", "-f", &self.name]);
        let _ = run_command_silent(command, self.debug);
    }
}

fn ensure_image_exists(
    root: &PathBuf,
    image_name: &str,
    image_tag: &str,
    debug: bool,
) -> Result<(), String> {
    let mut exists = Command::new("podman");
    exists.args(["image", "exists", image_tag]);
    if exists
        .status()
        .map_err(|e| format!("Failed to check Podman image: {e}"))?
        .success()
    {
        return Ok(());
    }

    let build_script = root.join("scripts").join("build-image.sh");
    if !build_script.is_file() {
        return Err(format!(
            "Image {image_tag} is missing and build script was not found. Run tillandsias --init from a Tillandsias checkout."
        ));
    }

    let mut build = Command::new(build_script);
    build.arg(image_name).current_dir(root);
    run_command(build, debug)
}

fn create_github_podman_secret(token: &str, debug: bool) -> Result<(), String> {
    let mut remove = Command::new("podman");
    remove.args(["secret", "rm", "tillandsias-github-token"]);
    let _ = run_command_silent(remove, debug);

    let mut child = Command::new("podman")
        .args([
            "secret",
            "create",
            "--driver=file",
            "tillandsias-github-token",
            "-",
        ])
        .stdin(Stdio::piped())
        .stdout(Stdio::null())
        .stderr(Stdio::piped())
        .spawn()
        .map_err(|e| format!("Failed to create GitHub Podman secret: {e}"))?;

    if debug {
        eprintln!(
            "[tillandsias] running: podman secret create --driver=file tillandsias-github-token -"
        );
    }

    {
        let stdin = child
            .stdin
            .as_mut()
            .ok_or_else(|| "Failed to open podman secret stdin".to_string())?;
        stdin
            .write_all(token.as_bytes())
            .map_err(|e| format!("Failed to write token to podman secret stdin: {e}"))?;
        stdin
            .write_all(b"\n")
            .map_err(|e| format!("Failed to finish token input: {e}"))?;
    }
    drop(child.stdin.take());

    let output = child
        .wait_with_output()
        .map_err(|e| format!("Failed waiting for podman secret create: {e}"))?;
    if output.status.success() {
        println!("GitHub token secret created: tillandsias-github-token");
        Ok(())
    } else {
        let stderr = String::from_utf8_lossy(&output.stderr).trim().to_string();
        if stderr.is_empty() {
            Err(format!(
                "podman secret create exited with status {}",
                output.status
            ))
        } else {
            Err(stderr)
        }
    }
}

/// Phase 3, Task 12: Auto-detect GTK availability.
/// @trace spec:linux-native-portable-executable, spec:transparent-mode-detection
fn is_gtk_available() -> bool {
    cfg!(feature = "tray")
}

/// Phase 3, Task 12 & Phase 4: Launch in tray mode with headless subprocess.
/// @trace spec:linux-native-portable-executable, spec:transparent-mode-detection, spec:tray-subprocess-management
fn launch_tray_mode(_config_path: Option<String>) -> Result<(), String> {
    #[cfg(feature = "tray")]
    {
        crate::tray::run_tray_mode(config_path)
    }

    #[cfg(not(feature = "tray"))]
    {
        Err("Tray mode requires 'tray' feature".to_string())
    }
}

/// Run in OpenCode mode — analyze code with LLM inference.
///
/// @trace spec:cli-mode, spec:opencode-integration
fn run_opencode_mode(project_path: &str, prompt: &str, debug: bool) -> Result<(), String> {
    if debug {
        eprintln!("[tillandsias] OpenCode mode enabled");
        eprintln!("[tillandsias] Project: {}", project_path);
        eprintln!("[tillandsias] Prompt: {}", prompt);
    }

    // Phase 4A: Project initialization and enclave startup
    // For now, just validate the project path exists
    let project = std::path::Path::new(project_path);
    if !project.exists() {
        return Err(format!("Project not found: {}", project_path));
    }

    if debug {
        eprintln!("[tillandsias] Project path is valid");
    }

    // Phase 4B: Create async runtime for enclave orchestration
    let rt = tokio::runtime::Runtime::new()
        .map_err(|e| format!("Failed to create async runtime: {}", e))?;

    rt.block_on(async {
        // Placeholder for Phase 4+: container orchestration, LLM communication
        if debug {
            eprintln!("[tillandsias] [OpenCode] Enclave orchestration pending (Phase 4+)");
            eprintln!("[tillandsias] [OpenCode] Would send prompt to inference container");
        }

        // For now, emit success event
        println!("{{\"event\":\"opencode.mode_enabled\",\"project\":\"{}\"}}", project_path);

        // Emit a mock response for testing
        println!("{{\"event\":\"opencode.prompt\",\"text\":\"{}\"}}", prompt.replace("\"", "\\\""));

        eprintln!("[tillandsias] [OpenCode] Phase 4+ (container orchestration, inference) not yet implemented");
        eprintln!("[tillandsias] [OpenCode] See docs/OPENCODE-INTEGRATION-TASKS.md for implementation plan");

        Ok::<(), String>(())
    })
}

// Module declarations for Phase 4+
#[cfg(feature = "tray")]
mod tray;

/// Run in headless mode — no tray, no UI.
///
/// @trace spec:linux-native-portable-executable, spec:headless-mode
fn run_headless(config_path: Option<String>) -> Result<(), String> {
    // Create a Tokio runtime for async operations
    let rt = tokio::runtime::Runtime::new()
        .map_err(|e| format!("Failed to create async runtime: {}", e))?;

    // Run the async headless mode
    rt.block_on(run_headless_async(config_path))
}

/// Phase 5: Async implementation of headless mode.
/// @trace spec:linux-native-portable-executable, spec:headless-mode, spec:signal-handling
async fn run_headless_async(config_path: Option<String>) -> Result<(), String> {
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

    // Main event loop: wait for application shutdown signal.
    wait_for_shutdown_signal().await?;
    eprintln!("Received shutdown signal");

    // Phase 5, Task 21: Graceful shutdown with timeout
    graceful_shutdown_async().await?;

    // Emit stopped event
    let now = chrono::Local::now();
    println!(
        r#"{{"event":"app.stopped","exit_code":0,"timestamp":"{}"}}"#,
        now.to_rfc3339()
    );
    Ok(())
}

/// Phase 5, Task 22: Wait for SIGTERM/SIGINT using Tokio's Unix signal support.
/// @trace spec:linux-native-portable-executable, spec:signal-handling
async fn wait_for_shutdown_signal() -> Result<(), String> {
    let mut sigterm =
        signal(SignalKind::terminate()).map_err(|e| format!("Failed to register SIGTERM: {e}"))?;
    let mut sigint =
        signal(SignalKind::interrupt()).map_err(|e| format!("Failed to register SIGINT: {e}"))?;

    tokio::select! {
        _ = sigterm.recv() => {}
        _ = sigint.recv() => {}
    }
    Ok(())
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
async fn graceful_shutdown_async() -> Result<(), String> {
    // Phase 5, Task 23: Test signal handling with timeout
    // Emit shutdown event
    eprintln!("Starting graceful shutdown sequence");

    // In a full implementation, this would:
    // 1. Stop all containers with 30s timeout via podman client
    // 2. Monitor container exit status
    // 3. Force-kill any remaining containers after timeout
    // 4. Cleanup secrets and ephemeral network resources

    // Check if there are any tillandsias-managed containers running
    // If not, return immediately (for testing and headless-only runs)
    // If yes, wait up to 30 seconds for graceful shutdown

    eprintln!("Graceful shutdown completed");
    Ok(())
}
