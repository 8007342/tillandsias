//! CLI argument parser for Tillandsias.
//!
//! Determines whether the binary should start in tray mode (no args)
//! or CLI attach mode (`tillandsias <path>`).

use std::path::PathBuf;

use tillandsias_core::config::SelectedAgent;

/// The 4-part version string embedded from the VERSION file at build time.
///
/// This is the canonical version: Major.Minor.ChangeCount.Build (e.g., "0.1.97.76").
/// It matches the version shown in issue reports, release tags, and accountability output.
const VERSION_FULL: &str = include_str!("../../VERSION");

// ---------------------------------------------------------------------------
// Log configuration
// ---------------------------------------------------------------------------

/// Valid user-facing log module names.
const VALID_MODULES: &[&str] = &[
    "secrets",
    "containers",
    "updates",
    "scanner",
    "menu",
    "events",
    "proxy",
    "enclave",
    "git",
];

/// Valid log level names (case-insensitive).
const VALID_LEVELS: &[&str] = &["off", "error", "warn", "info", "debug", "trace"];

/// Accountability window variants.
///
/// Each variant corresponds to a `--log-*` flag that enables a curated view
/// of a specific subsystem's operations.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum AccountabilityWindow {
    /// `--log-secret-management` — trace secret lifecycle operations.
    SecretManagement,
    /// `--log-image-management` — trace container image build/pull operations (future).
    ImageManagement,
    /// `--log-update-cycle` — trace self-update operations (future).
    UpdateCycle,
    /// `--log-proxy` — trace proxy request/cache operations.
    // @trace spec:proxy-container
    ProxyManagement,
    /// `--log-enclave` — trace enclave network lifecycle operations.
    // @trace spec:enclave-network
    EnclaveManagement,
    /// `--log-git` — trace git mirror lifecycle and push operations.
    // @trace spec:git-mirror-service
    GitManagement,
}

/// Per-module log level override parsed from `--log=module:level;...`.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ModuleLevel {
    /// User-facing module name (e.g., "secrets").
    pub module: String,
    /// Tracing level string (e.g., "trace", "debug").
    pub level: String,
}

/// Logging configuration parsed from CLI flags.
///
/// This is separate from `CliMode` because logging flags compose with any
/// mode — you can use `--log=secrets:trace` with tray mode, attach mode, etc.
#[derive(Debug, Clone, Default)]
pub struct LogConfig {
    /// Per-module log level overrides from `--log=module:level;...`.
    pub modules: Vec<ModuleLevel>,
    /// Active accountability windows from `--log-*` flags.
    pub accountability: Vec<AccountabilityWindow>,
}

/// Parse a `--log=module:level;module:level` value into module/level pairs.
///
/// Warns on unknown modules and invalid levels to stderr. Invalid entries
/// are skipped — the application still starts normally.
fn parse_log_value(value: &str) -> Vec<ModuleLevel> {
    let mut result = Vec::new();

    for pair in value.split(';') {
        let pair = pair.trim();
        if pair.is_empty() {
            continue;
        }

        let Some((module, level)) = pair.split_once(':') else {
            eprintln!("Warning: Invalid log pair (expected module:level): {pair}");
            continue;
        };

        let module = module.trim();
        let level = level.trim().to_lowercase();

        if !VALID_MODULES.contains(&module) {
            eprintln!(
                "Warning: Unknown log module: {module}. Valid modules: {}",
                VALID_MODULES.join(", ")
            );
            continue;
        }

        if !VALID_LEVELS.contains(&level.as_str()) {
            eprintln!(
                "Error: Invalid log level: {level}. Valid levels: {}",
                VALID_LEVELS.join(", ")
            );
            // Fall back to info for this module
            result.push(ModuleLevel {
                module: module.to_string(),
                level: "info".to_string(),
            });
            continue;
        }

        result.push(ModuleLevel {
            module: module.to_string(),
            level,
        });
    }

    result
}

/// How the application should run based on CLI arguments.
pub enum CliMode {
    /// No arguments — start the system tray application.
    Tray,

    /// `tillandsias --version` — print version and exit.
    Version,

    /// `tillandsias --init` — pre-build all container images (proxy, forge, git, inference).
    /// `tillandsias --init --force` — rebuild all from scratch.
    Init { force: bool },

    /// `tillandsias --stats` — print disk usage report and exit.
    Stats,

    /// `tillandsias --clean` — remove stale artifacts and exit.
    Clean,

    /// `tillandsias --update` — check for updates and apply if available, then exit.
    Update,

    /// `tillandsias --github-login` — run GitHub authentication flow and exit.
    GitHubLogin,

    /// A project path was given — launch an interactive development environment.
    Attach {
        /// Absolute path to the project directory.
        path: PathBuf,
        /// Environment short name (e.g., "forge" -> "tillandsias-forge:v0.1.97").
        image: String,
        /// Show verbose debug output.
        debug: bool,
        /// Drop into fish shell instead of default entrypoint (troubleshooting).
        bash: bool,
        /// Override the configured agent for this session.
        agent_override: Option<SelectedAgent>,
    },
}

const USAGE: &str = "\
Tillandsias — development environments that just work

USAGE:
    tillandsias                     Start the system tray app
    tillandsias <path>              Attach to a project
    tillandsias <path> --opencode   Attach using OpenCode
    tillandsias <path> --claude     Attach using Claude Code
    tillandsias <path> --bash       Open maintenance terminal
    tillandsias --github-login      Authenticate with GitHub
    tillandsias --init              Pre-build development environments
    tillandsias --init --force      Rebuild forge image from scratch
    tillandsias --stats             Show disk usage from Tillandsias artifacts
    tillandsias --clean             Remove stale artifacts and reclaim disk space
    tillandsias --update            Check for updates and apply if available
    tillandsias --version           Show version information
    tillandsias --help              Show this help

ACCOUNTABILITY:
  --log-secret-management    Show how secrets are safely handled
  --log-image-management     Show environment lifecycle
  --log-update-cycle         Show update check and apply flow
  --log-proxy                Show proxy request and cache operations
  --log-enclave              Show enclave network lifecycle
  --log-git                  Show git mirror and push operations

OPTIONS:
  --log=MODULES              Per-module log levels (secrets:trace;events:debug)
  --env <name>               Environment to use (default: forge)
  --debug                    Show verbose output including commands
  --opencode                 Use OpenCode for this session
  --claude                   Use Claude Code for this session
  --bash                     Open maintenance terminal
  --github-login             Run GitHub authentication flow
  --version                  Show version and exit
  --help                     Show this help

MAINTENANCE:
  init                       Pre-build development environment
  --stats                    Show disk usage from artifacts
  --clean                    Remove stale artifacts
  --update                   Check for and apply updates
";

/// Parse CLI arguments and return the appropriate mode plus log configuration.
///
/// Returns `None` if `--help` was requested (usage is printed to stdout
/// and the caller should exit).
///
/// `LogConfig` is always returned alongside the mode — logging flags compose
/// with any mode (tray, attach, etc.).
pub fn parse() -> Option<(CliMode, LogConfig)> {
    let args: Vec<String> = std::env::args().skip(1).collect();

    // Pre-scan for log flags (they apply to ALL modes).
    let log_config = parse_log_flags(&args);

    // No arguments — tray mode.
    if args.is_empty() {
        return Some((CliMode::Tray, log_config));
    }

    // `tillandsias --help` — print usage and exit (checked before all modes).
    if args.iter().any(|a| a == "--help" || a == "-h") {
        print!("{USAGE}");
        return None;
    }

    // `tillandsias --version` — print version and exit.
    if args.iter().any(|a| a == "--version" || a == "-V") {
        return Some((CliMode::Version, log_config));
    }

    // `tillandsias --init` or `tillandsias init` — pre-build images.
    // `tillandsias --init --force` — rebuild even if already built.
    if args.iter().any(|a| a == "--init") || args.first().map(|s| s.as_str()) == Some("init") {
        let force = args.iter().any(|a| a == "--force");
        return Some((CliMode::Init { force }, log_config));
    }

    // `tillandsias --stats` — disk usage report.
    if args.iter().any(|a| a == "--stats") {
        return Some((CliMode::Stats, log_config));
    }

    // `tillandsias --clean` — artifact cleanup.
    if args.iter().any(|a| a == "--clean") {
        return Some((CliMode::Clean, log_config));
    }

    // `tillandsias --update` — check for updates and apply.
    if args.iter().any(|a| a == "--update") {
        return Some((CliMode::Update, log_config));
    }

    // `tillandsias --github-login` — run GitHub auth flow.
    if args.iter().any(|a| a == "--github-login") {
        return Some((CliMode::GitHubLogin, log_config));
    }

    let mut path: Option<PathBuf> = None;
    let mut image = "forge".to_string();
    let mut debug = false;
    let mut bash = false;
    let mut agent_override: Option<SelectedAgent> = None;
    let mut i = 0;

    while i < args.len() {
        match args[i].as_str() {
            "--help" | "-h" => {
                print!("{USAGE}");
                return None;
            }
            "--version" => {
                let v = VERSION_FULL.trim();
                println!("tillandsias {v}");
                return None;
            }
            // --image kept for backwards compatibility; --env is the new preferred form.
            "--image" | "--env" => {
                let flag = args[i].clone();
                i += 1;
                if i >= args.len() {
                    eprintln!("Error: {flag} requires a value");
                    print!("{USAGE}");
                    return None;
                }
                image = args[i].clone();
            }
            "--debug" => {
                debug = true;
            }
            "--bash" => {
                bash = true;
            }
            "--opencode" => {
                agent_override = Some(SelectedAgent::OpenCode);
            }
            "--claude" => {
                agent_override = Some(SelectedAgent::Claude);
            }
            // Log flags — already parsed by parse_log_flags(), skip here.
            "--log-secret-management" | "--log-image-management" | "--log-update-cycle"
            | "--log-proxy" | "--log-enclave" | "--log-git" => {}
            arg if arg.starts_with("--log=") => {}
            arg => {
                // Skip Tauri-injected flags (they start with --)
                if arg.starts_with('-') {
                    // Unknown flag — ignore (could be Tauri internals)
                    i += 1;
                    continue;
                }
                // Positional argument = project path
                path = Some(PathBuf::from(arg));
            }
        }
        i += 1;
    }

    match path {
        Some(p) => Some((
            CliMode::Attach {
                path: p,
                image,
                debug,
                bash,
                agent_override,
            },
            log_config,
        )),
        None => {
            // Had flags but no path — tray mode (could be Tauri flags)
            Some((CliMode::Tray, log_config))
        }
    }
}

/// Extract log configuration flags from the argument list.
///
/// Scans for `--log=...`, `--log-secret-management`, `--log-image-management`,
/// `--log-update-cycle`, `--log-proxy`, `--log-enclave`, and `--log-git`. These flags are orthogonal to the mode — they
/// configure the tracing subscriber regardless of whether the app runs as a
/// tray, attach, or utility command.
fn parse_log_flags(args: &[String]) -> LogConfig {
    let mut config = LogConfig::default();

    for arg in args {
        if let Some(value) = arg.strip_prefix("--log=") {
            config.modules = parse_log_value(value);
        } else if arg == "--log-secret-management" {
            if !config
                .accountability
                .contains(&AccountabilityWindow::SecretManagement)
            {
                config
                    .accountability
                    .push(AccountabilityWindow::SecretManagement);
            }
        } else if arg == "--log-image-management" {
            if !config
                .accountability
                .contains(&AccountabilityWindow::ImageManagement)
            {
                config
                    .accountability
                    .push(AccountabilityWindow::ImageManagement);
            }
        } else if arg == "--log-update-cycle" {
            if !config
                .accountability
                .contains(&AccountabilityWindow::UpdateCycle)
            {
                config
                    .accountability
                    .push(AccountabilityWindow::UpdateCycle);
            }
        // @trace spec:proxy-container
        } else if arg == "--log-proxy" {
            if !config
                .accountability
                .contains(&AccountabilityWindow::ProxyManagement)
            {
                config
                    .accountability
                    .push(AccountabilityWindow::ProxyManagement);
            }
        // @trace spec:enclave-network
        } else if arg == "--log-enclave" {
            if !config
                .accountability
                .contains(&AccountabilityWindow::EnclaveManagement)
            {
                config
                    .accountability
                    .push(AccountabilityWindow::EnclaveManagement);
            }
        // @trace spec:git-mirror-service
        } else if arg == "--log-git" {
            if !config
                .accountability
                .contains(&AccountabilityWindow::GitManagement)
            {
                config
                    .accountability
                    .push(AccountabilityWindow::GitManagement);
            }
        }
    }

    config
}

// ---------------------------------------------------------------------------
// Welcome banner
// ---------------------------------------------------------------------------

/// Forge image status for the welcome banner.
pub enum ForgeStatus {
    /// Current version's forge image is present.
    Ready(String),
    /// No current image, but an older version exists.
    UpdateNeeded {
        /// The expected (current) tag.
        expected: String,
        /// The tag of an older version that was found.
        current: String,
    },
    /// No forge image exists at all.
    NotBuilt,
    /// Podman is not available — Forge line should be omitted.
    PodmanUnavailable,
}

/// Run `podman --version` synchronously and extract the version string.
///
/// Returns `Some("5.8.1")` on success, `None` if podman is absent or the
/// output is in an unexpected format.
pub fn detect_podman_version() -> Option<String> {
    let output = std::process::Command::new("podman")
        .arg("--version")
        .env_remove("LD_LIBRARY_PATH")
        .env_remove("LD_PRELOAD")
        .output()
        .ok()?;

    if !output.status.success() {
        return None;
    }

    // Expected format: "podman version 5.8.1"
    let stdout = String::from_utf8_lossy(&output.stdout);
    stdout
        .trim()
        .strip_prefix("podman version ")
        .map(|v| v.to_string())
}

/// Check the forge image status synchronously via `podman image exists`.
///
/// Uses `TILLANDSIAS_FULL_VERSION` (4-part) to match `handlers::forge_image_tag()`.
pub fn check_forge_image_status() -> ForgeStatus {
    let version_full = env!("TILLANDSIAS_FULL_VERSION");
    let expected_tag = format!("tillandsias-forge:v{version_full}");

    // First verify podman is callable at all.
    let probe = std::process::Command::new("podman")
        .arg("--version")
        .env_remove("LD_LIBRARY_PATH")
        .env_remove("LD_PRELOAD")
        .output();

    if probe.is_err() {
        return ForgeStatus::PodmanUnavailable;
    }

    // Check if the current version's image exists.
    let current_exists = std::process::Command::new("podman")
        .args(["image", "exists", &expected_tag])
        .env_remove("LD_LIBRARY_PATH")
        .env_remove("LD_PRELOAD")
        .status()
        .map(|s| s.success())
        .unwrap_or(false);

    if current_exists {
        return ForgeStatus::Ready(expected_tag);
    }

    // Check for any older versioned forge image.
    let older = std::process::Command::new("podman")
        .args([
            "images",
            "--format",
            "{{.Repository}}:{{.Tag}}",
            "--filter",
            "reference=tillandsias-forge:v*",
        ])
        .env_remove("LD_LIBRARY_PATH")
        .env_remove("LD_PRELOAD")
        .output();

    if let Ok(out) = older {
        let stdout = String::from_utf8_lossy(&out.stdout);
        if let Some(older_tag) = stdout
            .lines()
            .map(|l| l.trim())
            .find(|l| !l.is_empty() && l.starts_with("tillandsias-forge:v"))
        {
            return ForgeStatus::UpdateNeeded {
                expected: expected_tag,
                current: older_tag.to_string(),
            };
        }
    }

    ForgeStatus::NotBuilt
}

/// Print the welcome banner to stdout if stdout is an interactive terminal.
///
/// Suppressed when:
/// - stdout is not a TTY (piped or redirected)
/// - `debug` is true (debug output replaces the banner with more detailed info)
///
/// Called only in CLI attach mode — tray mode and subcommands (`--help`,
/// `--stats`, `--clean`, `--update`, `init`) do not call this function.
pub fn print_welcome_banner(debug: bool) {
    use std::io::IsTerminal as _;

    // Never print when output is piped or redirected.
    if !std::io::stdout().is_terminal() {
        return;
    }

    // Debug mode uses its own verbose output.
    if debug {
        return;
    }

    let version = VERSION_FULL.trim();
    let os = tillandsias_core::config::detect_host_os();

    // ANSI color codes
    const GREEN: &str = "\x1b[32m";
    const DIM: &str = "\x1b[2m";
    const CYAN: &str = "\x1b[36m";
    const YELLOW: &str = "\x1b[33m";
    const RESET: &str = "\x1b[0m";
    const DIM_RED: &str = "\x1b[2;31m";

    println!("{GREEN}Tillandsias v{version}{RESET}");

    // OS line
    println!("   {DIM}OS:{RESET}     {CYAN}{os}{RESET}");

    // Podman line
    match detect_podman_version() {
        Some(pv) => {
            println!("   {DIM}Podman:{RESET} {CYAN}{pv}{RESET}");

            // Forge line (only when podman is available)
            match check_forge_image_status() {
                ForgeStatus::Ready(tag) => {
                    println!("   {DIM}Forge:{RESET}  {CYAN}{tag} (ready){RESET}");
                }
                ForgeStatus::UpdateNeeded { expected, current } => {
                    println!(
                        "   {DIM}Forge:{RESET}  {YELLOW}update needed (current: {current}, expected: {expected}){RESET}"
                    );
                }
                ForgeStatus::NotBuilt => {
                    println!(
                        "   {DIM}Forge:{RESET}  {YELLOW}not built (run: tillandsias init){RESET}"
                    );
                }
                ForgeStatus::PodmanUnavailable => {
                    // Podman appeared available from --version but image check failed.
                    // Omit forge line.
                }
            }
        }
        None => {
            println!("   {DIM}Podman:{RESET} {DIM_RED}not found{RESET}");
            println!();
            println!("   {YELLOW}Install podman to use Tillandsias.{RESET}");
        }
    }

    println!();
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn version_full_is_four_parts() {
        let v = VERSION_FULL.trim();
        assert!(!v.is_empty(), "VERSION_FULL must not be empty");
        let parts: Vec<&str> = v.split('.').collect();
        assert_eq!(
            parts.len(),
            4,
            "VERSION_FULL should be 4-part semver, got: {v}"
        );
    }

    #[test]
    fn usage_contains_all_sections() {
        assert!(USAGE.contains("USAGE:"), "help missing USAGE section");
        assert!(
            USAGE.contains("ACCOUNTABILITY:"),
            "help missing ACCOUNTABILITY section"
        );
        assert!(USAGE.contains("OPTIONS:"), "help missing OPTIONS section");
        assert!(
            USAGE.contains("MAINTENANCE:"),
            "help missing MAINTENANCE section"
        );
    }

    #[test]
    fn usage_has_no_forbidden_words() {
        let lower = USAGE.to_lowercase();
        assert!(
            !lower.contains("container"),
            "help contains forbidden word 'container'"
        );
        assert!(
            !lower.contains("runtime"),
            "help contains forbidden word 'runtime'"
        );
    }

    #[test]
    fn usage_accountability_before_options() {
        let accountability_pos = USAGE.find("ACCOUNTABILITY:").unwrap();
        let options_pos = USAGE.find("OPTIONS:").unwrap();
        assert!(
            accountability_pos < options_pos,
            "ACCOUNTABILITY section must appear before OPTIONS section"
        );
    }

    #[test]
    fn usage_has_version_flag() {
        assert!(USAGE.contains("--version"), "help must mention --version");
    }

    #[test]
    fn detect_podman_version_parses_standard_format() {
        // Simulate the parsing logic against a known-good output string.
        let line = "podman version 5.8.1";
        let result = line.strip_prefix("podman version ").map(|v| v.to_string());
        assert_eq!(result, Some("5.8.1".to_string()));
    }

    #[test]
    fn detect_podman_version_rejects_unexpected_format() {
        let line = "unexpected output format";
        let result = line.strip_prefix("podman version ").map(|v| v.to_string());
        assert_eq!(result, None);
    }

    #[test]
    fn detect_podman_version_rejects_empty() {
        let line = "";
        let result = line.strip_prefix("podman version ").map(|v| v.to_string());
        assert_eq!(result, None);
    }

    // --- Log configuration tests ---

    #[test]
    fn parse_single_module() {
        let result = parse_log_value("secrets:trace");
        assert_eq!(result.len(), 1);
        assert_eq!(result[0].module, "secrets");
        assert_eq!(result[0].level, "trace");
    }

    #[test]
    fn parse_multiple_modules() {
        let result = parse_log_value("secrets:trace;containers:debug;scanner:off");
        assert_eq!(result.len(), 3);
        assert_eq!(result[0].module, "secrets");
        assert_eq!(result[0].level, "trace");
        assert_eq!(result[1].module, "containers");
        assert_eq!(result[1].level, "debug");
        assert_eq!(result[2].module, "scanner");
        assert_eq!(result[2].level, "off");
    }

    #[test]
    fn parse_unknown_module_skipped() {
        let result = parse_log_value("bogus:debug;secrets:info");
        assert_eq!(result.len(), 1);
        assert_eq!(result[0].module, "secrets");
    }

    #[test]
    fn parse_invalid_level_falls_back_to_info() {
        let result = parse_log_value("secrets:potato");
        assert_eq!(result.len(), 1);
        assert_eq!(result[0].module, "secrets");
        assert_eq!(result[0].level, "info");
    }

    #[test]
    fn parse_empty_log_value() {
        let result = parse_log_value("");
        assert!(result.is_empty());
    }

    #[test]
    fn parse_missing_colon_skipped() {
        let result = parse_log_value("secrets-trace");
        assert!(result.is_empty());
    }

    #[test]
    fn parse_level_case_insensitive() {
        let result = parse_log_value("secrets:TRACE");
        assert_eq!(result.len(), 1);
        assert_eq!(result[0].level, "trace");
    }

    #[test]
    fn parse_log_flags_combined() {
        let args: Vec<String> = vec![
            "--log=secrets:trace;containers:debug".into(),
            "--log-secret-management".into(),
            "some-path".into(),
        ];
        let config = parse_log_flags(&args);
        assert_eq!(config.modules.len(), 2);
        assert_eq!(config.accountability.len(), 1);
        assert_eq!(
            config.accountability[0],
            AccountabilityWindow::SecretManagement
        );
    }

    #[test]
    fn parse_log_flags_no_duplicates() {
        let args: Vec<String> = vec![
            "--log-secret-management".into(),
            "--log-secret-management".into(),
        ];
        let config = parse_log_flags(&args);
        assert_eq!(config.accountability.len(), 1);
    }

    #[test]
    fn module_to_targets_all_six() {
        for module in VALID_MODULES {
            let targets = crate::logging::module_to_targets(module);
            assert!(
                !targets.is_empty(),
                "Module '{module}' should map to at least one Rust target"
            );
        }
    }

    #[test]
    fn module_to_targets_unknown_empty() {
        let targets = crate::logging::module_to_targets("nonexistent");
        assert!(targets.is_empty());
    }
}
