// @trace spec:forge-staleness, spec:logging-levels, spec:runtime-logging

use std::path::{Path, PathBuf};

use tracing::{debug, warn};

use crate::state::Os;

/// Default container image (base name — version tag computed at runtime).
const DEFAULT_IMAGE: &str = "tillandsias-forge";

/// Default port range start.
const DEFAULT_PORT_START: u16 = 3000;
const DEFAULT_PORT_END: u16 = 3019;

/// Default debounce for filesystem scanner.
const DEFAULT_DEBOUNCE_MS: u64 = 2000;

/// Which AI coding agent to launch in forge containers.
#[derive(Debug, Clone, Copy, PartialEq, Eq, serde::Serialize, serde::Deserialize)]
#[serde(rename_all = "lowercase")]
#[derive(Default)]
pub enum SelectedAgent {
    OpenCode,
    Claude,
    /// OpenCode's browser-based UI served by `opencode serve` and rendered
    /// in the secure browser launch path. Default for new installs.
    /// @trace spec:browser-isolation-tray-integration, spec:opencode-web-session-otp
    #[serde(rename = "opencode-web")]
    #[default]
    OpenCodeWeb,
}

// @trace spec:browser-isolation-tray-integration, spec:opencode-web-session-otp

impl SelectedAgent {
    /// The string value passed as `TILLANDSIAS_AGENT` env var.
    pub fn as_env_str(&self) -> &'static str {
        match self {
            Self::OpenCode => "opencode",
            Self::Claude => "claude",
            Self::OpenCodeWeb => "opencode-web",
        }
    }

    /// Parse from a string (case-insensitive). Returns `None` for unknown values.
    pub fn from_str_opt(s: &str) -> Option<Self> {
        match s.to_lowercase().as_str() {
            "opencode" => Some(Self::OpenCode),
            "claude" => Some(Self::Claude),
            "opencode-web" => Some(Self::OpenCodeWeb),
            _ => None,
        }
    }

    /// Display name for menu labels.
    pub fn display_name(&self) -> &'static str {
        match self {
            Self::OpenCode => "OpenCode",
            Self::Claude => "Claude",
            Self::OpenCodeWeb => "OpenCode Web",
        }
    }

    /// Returns true if the agent is the browser-based OpenCode Web variant.
    /// @trace spec:browser-isolation-tray-integration, spec:opencode-web-session-otp
    pub fn is_web(&self) -> bool {
        matches!(self, Self::OpenCodeWeb)
    }
}

/// Agent selection configuration.
#[derive(Debug, Clone, serde::Serialize, serde::Deserialize, Default)]
pub struct AgentConfig {
    #[serde(default)]
    pub selected: SelectedAgent,
}

/// Internationalization configuration.
#[derive(Debug, Clone, serde::Serialize, serde::Deserialize)]
pub struct I18nConfig {
    #[serde(default = "default_language")]
    pub language: String,
}

impl Default for I18nConfig {
    fn default() -> Self {
        Self {
            language: default_language(),
        }
    }
}

fn default_language() -> String {
    "en".to_string()
}

/// Forge container runtime configuration.
///
/// Controls how per-launch tmpfs budgets are computed and bounded for the
/// project-source hot path (`/home/forge/src`).
///
/// @trace spec:forge-hot-cold-split, spec:cheatsheets-license-tiered
#[derive(Debug, Clone, serde::Serialize, serde::Deserialize)]
pub struct ForgeConfig {
    /// Maximum size (MB) for the per-launch `/home/forge/src` tmpfs.
    /// The compute_hot_budget helper clamps its result to this ceiling.
    /// Default: 4096 (4 GB).
    #[serde(default = "default_hot_path_max_mb")]
    pub hot_path_max_mb: u32,

    /// Inflation multiplier applied to the git mirror's pack size when
    /// computing the `/home/forge/src` tmpfs budget. A working tree is
    /// typically 2–5× the pack size; 4× is a safe conservative default.
    /// Default: 4.
    #[serde(default = "default_hot_path_inflation")]
    pub hot_path_inflation: u32,

    /// User override (in MB) for the pull-on-demand cheatsheet cache RAM
    /// soft-cap. When `Some`, the override wins over auto-detection from
    /// `MemTotal`; when `None`, the host RAM tier (Modest/Normal/Plentiful)
    /// is auto-resolved at tray startup. The resolved cap is exported into
    /// every forge container as `TILLANDSIAS_PULL_CACHE_RAM_MB`.
    ///
    /// Tier table (auto-detection):
    ///   - `MemTotal < 8 GiB`   → 64 MB
    ///   - `8 GiB ≤ MemTotal < 32 GiB` → 128 MB
    ///   - `MemTotal ≥ 32 GiB`  → 1024 MB
    ///
    /// Default: `None` (use auto-detection).
    /// @trace spec:cheatsheets-license-tiered
    #[serde(default)]
    pub pull_cache_ram_mb: Option<u32>,
}

impl Default for ForgeConfig {
    fn default() -> Self {
        Self {
            hot_path_max_mb: default_hot_path_max_mb(),
            hot_path_inflation: default_hot_path_inflation(),
            pull_cache_ram_mb: None,
        }
    }
}

fn default_hot_path_max_mb() -> u32 {
    4096
}

fn default_hot_path_inflation() -> u32 {
    4
}

/// Floor for the `/home/forge/src` tmpfs budget (MB).
///
/// Spec § "Per-launch project source budget" Scenario "Empty mirror
/// returns floor (256 MB)" mandates this minimum so a brand-new
/// project clones cleanly even when its mirror is empty.
///
/// @trace spec:forge-hot-cold-split
pub const HOT_PATH_BUDGET_FLOOR_MB: u32 = 256;

/// Parse the `size-pack` field from `git count-objects -v -H` output.
///
/// Canonical git output (human-readable mode, `-H`):
///
/// ```text
/// count: 0
/// size: 0
/// in-pack: 1234
/// packs: 1
/// size-pack: 12345
/// prune-packable: 0
/// garbage: 0
/// size-garbage: 0
/// ```
///
/// Returns the parsed `size-pack` value in **KiB** (git's reporting
/// unit when called with `-H`; the suffix is `KiB` for sub-MiB sizes
/// and `MiB` / `GiB` for larger packs — but in the `-v` (non-`-H`)
/// flow git omits the suffix entirely and reports raw KiB, which is
/// what the forge launcher actually parses today).
///
/// On missing field or unparseable value, returns `0` — the spec
/// scenario "Empty mirror returns floor (256 MB)" depends on this
/// fallback so the launcher doesn't fail-closed on a fresh project.
///
/// Note: the spec's "200 MB" example talks about MiB; this parser
/// returns KiB so the caller can do a single multiplication into the
/// budget. Compose with [`compute_hot_budget`] to get the final cap.
///
/// @trace spec:forge-hot-cold-split (Requirement: Per-launch project
///   source budget — step 1 + 2 of compute_hot_budget recipe)
pub fn parse_size_pack_kb(count_objects_output: &str) -> u64 {
    for line in count_objects_output.lines() {
        let trimmed = line.trim();
        if let Some(rest) = trimmed.strip_prefix("size-pack:") {
            return rest.trim().parse::<u64>().unwrap_or(0);
        }
    }
    0
}

/// Compute the `/home/forge/src` tmpfs budget (in MB) for a forge
/// launch, given the project's git mirror pack size in KiB.
///
/// Spec § "Per-launch project source budget" recipe:
///
/// 1. Pack size (KiB) → MiB: `pack_size_kb / 1024` (integer division
///    — we round down before inflation, then the clamp absorbs the
///    1 KiB rounding error).
/// 2. Multiply by [`ForgeConfig::hot_path_inflation`] (default 4).
/// 3. Clamp to `[HOT_PATH_BUDGET_FLOOR_MB, ForgeConfig::hot_path_
///    max_mb]` (default ceiling: 4096 MB).
///
/// Spec scenarios:
/// - Pack 200 MB × 4 = 800 MB → returns 800 (within [256, 4096]).
/// - Empty mirror (pack 0) → inflated 0 → clamped UP to 256 (floor).
/// - Pack 2 GiB × 4 = 8192 MB → clamped DOWN to 4096 (ceiling).
///
/// `u32` arithmetic is safe: max input `(u64::MAX / 1024)` ≈ 16 EiB
/// in MB still overflows, but the clamp truncates well before that.
/// Use `saturating_mul` to make the inflation step explicit.
///
/// @trace spec:forge-hot-cold-split (Requirement: Per-launch project
///   source budget — full recipe)
pub fn compute_hot_budget(pack_size_kb: u64, config: &ForgeConfig) -> u32 {
    // Step 1: KiB → MiB (integer division; truncation absorbed by clamp).
    let pack_size_mb = (pack_size_kb / 1024) as u32;
    // Step 2: × inflation (saturating; a malicious config with huge
    // inflation can't panic).
    let inflated = pack_size_mb.saturating_mul(config.hot_path_inflation);
    // Step 3: clamp to [floor, ceiling]. `max` first so an empty mirror
    // (inflated == 0) rises to the floor; `min` second so anything
    // above ceiling falls to the cap.
    inflated
        .max(HOT_PATH_BUDGET_FLOOR_MB)
        .min(config.hot_path_max_mb)
}

/// Global configuration loaded from `~/.config/tillandsias/config.toml`.
#[derive(Debug, Clone, serde::Serialize, serde::Deserialize)]
pub struct GlobalConfig {
    #[serde(default = "default_scanner_config")]
    pub scanner: ScannerConfig,

    #[serde(default = "default_defaults_config")]
    pub defaults: DefaultsConfig,

    #[serde(default)]
    pub security: SecurityConfig,

    #[serde(default)]
    pub updates: UpdatesConfig,

    #[serde(default)]
    pub agent: AgentConfig,

    #[serde(default)]
    pub i18n: I18nConfig,

    /// Forge-container runtime tuning (tmpfs budget for hot paths).
    /// @trace spec:forge-hot-cold-split
    #[serde(default)]
    pub forge: ForgeConfig,
}

/// Scanner settings.
#[derive(Debug, Clone, serde::Serialize, serde::Deserialize)]
pub struct ScannerConfig {
    #[serde(default = "default_watch_paths")]
    pub watch_paths: Vec<PathBuf>,

    #[serde(default = "default_debounce_ms")]
    pub debounce_ms: u64,
}

/// Default container/runtime settings.
#[derive(Debug, Clone, serde::Serialize, serde::Deserialize)]
pub struct DefaultsConfig {
    #[serde(default = "default_image")]
    pub image: String,

    #[serde(default = "default_port_range")]
    pub port_range: String,
}

/// Security flags — these are non-negotiable and cannot be weakened.
#[derive(Debug, Clone, serde::Serialize, serde::Deserialize)]
pub struct SecurityConfig {
    #[serde(default = "true_val")]
    pub cap_drop_all: bool,

    #[serde(default = "true_val")]
    pub no_new_privileges: bool,

    #[serde(default = "true_val")]
    pub userns_keep_id: bool,
}

/// Auto-updater settings.
/// @trace spec:update-system
#[derive(Debug, Clone, serde::Serialize, serde::Deserialize)]
pub struct UpdatesConfig {
    /// How often to check for updates, in hours. Default: 6.
    #[serde(default = "default_check_interval_hours")]
    pub check_interval_hours: u64,

    /// Whether to check for updates on app launch. Default: true.
    #[serde(default = "true_val")]
    pub check_on_launch: bool,
}

impl Default for UpdatesConfig {
    fn default() -> Self {
        Self {
            check_interval_hours: default_check_interval_hours(),
            check_on_launch: true,
        }
    }
}

fn default_check_interval_hours() -> u64 {
    6
}

/// Per-project configuration loaded from `<project>/.tillandsias/config.toml`.
#[derive(Debug, Clone, Default, serde::Serialize, serde::Deserialize)]
pub struct ProjectConfig {
    pub image: Option<String>,
    pub port_range: Option<String>,

    #[serde(default)]
    pub mounts: Vec<MountConfig>,

    pub runtime: Option<RuntimeConfig>,

    /// Web server configuration for "Serve Here".
    pub web: Option<WebConfig>,
}

/// Web server configuration for the `[web]` section of per-project config.
#[derive(Debug, Clone, Default, serde::Serialize, serde::Deserialize)]
pub struct WebConfig {
    /// Explicit document root override (relative to project root).
    /// When absent, auto-detection is used: public/ → dist/ → build/ → _site/ → out/ → project root.
    pub document_root: Option<String>,

    /// Port for the web container. Defaults to 8080, increments on conflict.
    pub port: Option<u16>,
}

/// A custom volume mount.
#[derive(Debug, Clone, serde::Serialize, serde::Deserialize)]
pub struct MountConfig {
    pub host: String,
    pub container: String,
    #[serde(default = "default_rw")]
    pub mode: String,
}

/// Runtime configuration section.
#[derive(Debug, Clone, serde::Serialize, serde::Deserialize)]
pub struct RuntimeConfig {
    pub command: Option<String>,
    pub port: Option<u16>,
}

impl Default for GlobalConfig {
    fn default() -> Self {
        Self {
            scanner: default_scanner_config(),
            defaults: default_defaults_config(),
            security: SecurityConfig::default(),
            updates: UpdatesConfig::default(),
            agent: AgentConfig::default(),
            i18n: I18nConfig::default(),
            forge: ForgeConfig::default(),
        }
    }
}

impl Default for SecurityConfig {
    fn default() -> Self {
        Self {
            cap_drop_all: true,
            no_new_privileges: true,
            userns_keep_id: true,
        }
    }
}

impl GlobalConfig {
    /// Merge with a project config. Project values override global defaults.
    /// Security flags can only be strengthened, never weakened.
    pub fn merge_with_project(&self, project: &ProjectConfig) -> ResolvedConfig {
        let image = project
            .image
            .clone()
            .unwrap_or_else(|| self.defaults.image.clone());

        let port_range = project
            .port_range
            .clone()
            .unwrap_or_else(|| self.defaults.port_range.clone());

        // Security flags: always enforce the baseline (true), project cannot weaken
        let security = SecurityConfig {
            cap_drop_all: true,
            no_new_privileges: true,
            userns_keep_id: true,
        };

        ResolvedConfig {
            image,
            port_range,
            security,
            mounts: project.mounts.clone(),
            runtime: project.runtime.clone(),
        }
    }

    /// Parse a port range string like "3000-3019" into (start, end).
    pub fn parse_port_range(s: &str) -> Option<(u16, u16)> {
        let parts: Vec<&str> = s.split('-').collect();
        if parts.len() == 2 {
            let start = parts[0].parse().ok()?;
            let end = parts[1].parse().ok()?;
            Some((start, end))
        } else {
            None
        }
    }
}

/// Fully resolved configuration for launching an environment.
#[derive(Debug, Clone)]
pub struct ResolvedConfig {
    pub image: String,
    pub port_range: String,
    pub security: SecurityConfig,
    pub mounts: Vec<MountConfig>,
    pub runtime: Option<RuntimeConfig>,
}

/// Platform-aware config directory.
pub fn config_dir() -> PathBuf {
    match Os::detect() {
        Os::Linux => dirs::config_dir()
            .unwrap_or_else(|| PathBuf::from("~/.config"))
            .join("tillandsias"),
        Os::MacOS => dirs::config_dir()
            .unwrap_or_else(|| PathBuf::from("~/Library/Application Support"))
            .join("tillandsias"),
        Os::Windows => dirs::config_dir()
            .unwrap_or_else(|| PathBuf::from("AppData/Roaming"))
            .join("tillandsias"),
    }
}

/// Platform-aware data directory (~/.local/share/tillandsias on Linux).
pub fn data_dir() -> PathBuf {
    match Os::detect() {
        Os::Linux => dirs::data_local_dir()
            .unwrap_or_else(|| PathBuf::from("~/.local/share"))
            .join("tillandsias"),
        Os::MacOS => dirs::data_local_dir()
            .unwrap_or_else(|| PathBuf::from("~/Library/Application Support"))
            .join("tillandsias"),
        Os::Windows => dirs::data_local_dir()
            .unwrap_or_else(|| PathBuf::from("AppData/Local"))
            .join("tillandsias"),
    }
}

/// Platform-aware log directory.
///
/// - Linux: `~/.local/state/tillandsias/`
/// - macOS: `~/Library/Logs/tillandsias/`
/// - Windows: `%LOCALAPPDATA%/tillandsias/logs/`
pub fn log_dir() -> PathBuf {
    match Os::detect() {
        Os::Linux => dirs::state_dir()
            .unwrap_or_else(|| {
                dirs::home_dir()
                    .unwrap_or_else(|| PathBuf::from("~"))
                    .join(".local/state")
            })
            .join("tillandsias"),
        Os::MacOS => dirs::home_dir()
            .unwrap_or_else(|| PathBuf::from("~"))
            .join("Library/Logs/tillandsias"),
        Os::Windows => dirs::data_local_dir()
            .unwrap_or_else(|| PathBuf::from("AppData/Local"))
            .join("tillandsias")
            .join("logs"),
    }
}

/// Platform-aware state directory root for Tillandsias.
///
/// This is the same root that `log_dir()` builds on:
/// - Linux: `~/.local/state/tillandsias/`
/// - macOS: `~/Library/Logs/tillandsias/`
/// - Windows: `%LOCALAPPDATA%/tillandsias/logs/`
///
/// Exposed separately so that `external_logs_dir()` and future sibling
/// paths can be computed without coupling to the `log` concept.
pub fn state_dir() -> PathBuf {
    log_dir()
}

/// Host directory for EXTERNAL logs across all producer roles.
///
/// Returns `<state_dir>/external-logs/` — a sibling of the
/// `containers/<container>/logs/` INTERNAL directories.
///
/// The launcher bind-mounts this directory RO at
/// `/var/log/tillandsias/external/` inside consumer containers so they
/// see one subdirectory per active producer role.
///
/// @trace spec:external-logs-layer
pub fn external_logs_dir() -> PathBuf {
    state_dir().join("external-logs")
}

/// Host directory for a specific producer's EXTERNAL logs.
///
/// Returns `<state_dir>/external-logs/<role>/`.
/// The launcher creates this directory on first launch if absent and
/// bind-mounts it RW at `/var/log/tillandsias/external/` inside the
/// producer container. The producer can ONLY see its own role's files.
///
/// @trace spec:external-logs-layer
pub fn external_logs_role_dir(role: &str) -> PathBuf {
    external_logs_dir().join(role)
}

/// Per-container log directory under the platform-aware log root.
///
/// Returns `<log_dir>/containers/<container_name>/logs/`.
/// Each container gets an isolated log directory for accountability and
/// log rotation. The caller is responsible for creating the directory.
///
/// @trace spec:podman-orchestration
pub fn container_log_dir(container_name: &str) -> PathBuf {
    // Strip redundant "tillandsias-" prefix — already namespaced under
    // ~/.local/state/tillandsias/containers/
    let short_name = container_name
        .strip_prefix("tillandsias-")
        .unwrap_or(container_name);
    log_dir().join("containers").join(short_name).join("logs")
}

/// Platform-aware cache directory.
pub fn cache_dir() -> PathBuf {
    match Os::detect() {
        Os::Linux => dirs::cache_dir()
            .unwrap_or_else(|| PathBuf::from("~/.cache"))
            .join("tillandsias"),
        Os::MacOS => dirs::cache_dir()
            .unwrap_or_else(|| PathBuf::from("~/Library/Caches"))
            .join("tillandsias"),
        Os::Windows => dirs::cache_dir()
            .unwrap_or_else(|| PathBuf::from("AppData/Local"))
            .join("tillandsias"),
    }
}

/// Load global config from disk, falling back to defaults.
pub fn load_global_config() -> GlobalConfig {
    let path = config_dir().join("config.toml");
    load_global_config_from(&path)
}

/// Generate a verbose, user-friendly config file with extensive comments.
///
/// Average Joe should understand every setting and feel safe. Technical
/// jargon is avoided. Security settings are documented as read-only.
///
/// @trace spec:environment-runtime
pub fn generate_verbose_config(config: &GlobalConfig) -> String {
    let watch_paths: Vec<String> = config
        .scanner
        .watch_paths
        .iter()
        .map(|p| {
            let path_str = p.display().to_string();
            // Escape backslashes for TOML
            let escaped = path_str.replace('\\', "\\\\");
            format!("\"{}\"", escaped)
        })
        .collect();
    let watch_paths_str = watch_paths.join(", ");

    format!(
        r#"# =====================================================================
# Tillandsias Configuration
# =====================================================================
#
# This file controls how Tillandsias works on your computer.
# You normally don't need to change anything here — the app
# manages itself automatically. But if you're curious, here's
# what everything does!
#
# This file is safe to delete — Tillandsias will recreate it
# with default settings on next launch.
#
# =====================================================================

# -- Where to find your projects ----------------------------------------
#
# Tillandsias watches these folders for projects to show in the
# tray menu. Add any folder where you keep your code.
#
# Example: watch_paths = ["/home/you/projects", "/home/you/work"]

[scanner]
watch_paths = [{watch_paths}]

# How long to wait (in milliseconds) after a file changes before
# refreshing the project list. Higher values mean fewer refreshes
# but slower detection. Lower values are more responsive but may
# cause unnecessary work. Default: 2000 (2 seconds).
debounce_ms = {debounce_ms}

# -- Your language -------------------------------------------------------
#
# Tillandsias speaks many languages! Set yours here, or change it
# from the tray menu under Settings > Language.
#
# Available: en, es, de, fr, pt, it, ro, ru, ja, ko, zh-Hans,
#            zh-Hant, ar, hi, ta, te, nah

[i18n]
language = "{language}"

# -- Your preferred coding assistant --------------------------------------
#
# Which AI coding tool opens when you click "Attach Here".
# You can also choose from the tray menu.
#
# Options: "opencode" or "claude"

[agent]
selected = "{agent}"

# -- Automatic updates ----------------------------------------------------
#
# Tillandsias checks for updates automatically so you always
# have the latest features and security fixes.

[updates]
check_interval_hours = {check_interval_hours}  # Check every {check_interval_hours} hours
check_on_launch = {check_on_launch}     # Also check when the app starts

# -- Advanced: Port range -------------------------------------------------
#
# When Tillandsias creates a development environment, it needs
# some network ports for communication. These ports are only
# accessible on your computer (not from the internet).
#
# You probably don't need to change this unless another app
# is using ports in this range.

[defaults]
port_range = "{port_range}"

# -- Security (read-only) -------------------------------------------------
#
# These security settings are always on and cannot be changed.
# They're listed here so you know what's protecting your system:
#
#   cap_drop_all:       Drops all special permissions from environments
#   no_new_privileges:  Prevents programs from gaining extra access
#   userns_keep_id:     Your files keep their normal ownership
#
# These settings protect your code and your computer.
# They cannot be weakened, even by editing this file.

[security]
cap_drop_all = true
no_new_privileges = true
userns_keep_id = true
"#,
        watch_paths = watch_paths_str,
        debounce_ms = config.scanner.debounce_ms,
        language = config.i18n.language,
        agent = config.agent.selected.as_env_str(),
        check_interval_hours = config.updates.check_interval_hours,
        check_on_launch = config.updates.check_on_launch,
        port_range = config.defaults.port_range,
    )
}

/// Save the selected language to the global config file.
///
/// Reads the existing config, updates the i18n section, and writes it back
/// as a verbose, user-friendly file with extensive comments.
/// Creates the config directory and file if they don't exist.
///
/// @trace spec:environment-runtime
pub fn save_selected_language(language: &str) {
    let dir = config_dir();
    if let Err(e) = std::fs::create_dir_all(&dir) {
        warn!(error = %e, "Failed to create config directory");
        return;
    }

    let path = dir.join("config.toml");
    let mut config = load_global_config_from(&path);
    config.i18n.language = language.to_string();

    let contents = generate_verbose_config(&config);
    if let Err(e) = std::fs::write(&path, &contents) {
        warn!(error = %e, "Failed to write config file");
    } else {
        debug!(?path, language, "Language selection saved");
    }
}

/// Map a language code to a full POSIX LANG value for containers.
///
/// Used when propagating the user's language selection into containers
/// via the `LANG` and `LANGUAGE` environment variables.
///
/// @trace spec:environment-runtime
pub fn language_to_lang_value(code: &str) -> &'static str {
    match code {
        "en" => "en_US.UTF-8",
        "es" => "es_MX.UTF-8",
        "ja" => "ja_JP.UTF-8",
        "zh-Hant" => "zh_TW.UTF-8",
        "zh-Hans" => "zh_CN.UTF-8",
        "ar" => "ar_SA.UTF-8",
        "ko" => "ko_KR.UTF-8",
        "hi" => "hi_IN.UTF-8",
        "ta" => "ta_IN.UTF-8",
        "te" => "te_IN.UTF-8",
        "fr" => "fr_FR.UTF-8",
        "pt" => "pt_BR.UTF-8",
        "it" => "it_IT.UTF-8",
        "ro" => "ro_RO.UTF-8",
        "ru" => "ru_RU.UTF-8",
        "nah" => "nah_MX.UTF-8",
        _ => "en_US.UTF-8",
    }
}

/// Save the selected agent to the global config file.
///
/// Reads the existing config, updates the agent section, and writes it back
/// as a verbose, user-friendly file with extensive comments.
/// Creates the config directory and file if they don't exist.
///
/// @trace spec:environment-runtime
pub fn save_selected_agent(agent: SelectedAgent) {
    let dir = config_dir();
    if let Err(e) = std::fs::create_dir_all(&dir) {
        warn!(error = %e, "Failed to create config directory");
        return;
    }

    let path = dir.join("config.toml");
    let mut config = load_global_config_from(&path);
    config.agent.selected = agent;

    let contents = generate_verbose_config(&config);
    if let Err(e) = std::fs::write(&path, &contents) {
        warn!(error = %e, "Failed to write config file");
    } else {
        debug!(?path, agent = agent.as_env_str(), "Agent selection saved");
    }
}

/// Load global config from a specific path (for testing).
pub fn load_global_config_from(path: &Path) -> GlobalConfig {
    match std::fs::read_to_string(path) {
        Ok(contents) => {
            debug!(?path, "Loaded config file");
            toml::from_str(&contents).unwrap_or_else(|e| {
                warn!(?path, error = %e, "Failed to parse config, using defaults");
                GlobalConfig::default()
            })
        }
        Err(_) => {
            debug!(?path, "No config file found, using defaults");
            GlobalConfig::default()
        }
    }
}

/// Load project config from a project directory.
pub fn load_project_config(project_path: &Path) -> ProjectConfig {
    let path = project_path.join(".tillandsias").join("config.toml");
    match std::fs::read_to_string(path) {
        Ok(contents) => toml::from_str(&contents).unwrap_or_default(),
        Err(_) => ProjectConfig::default(),
    }
}

// Default value functions for serde
fn default_scanner_config() -> ScannerConfig {
    ScannerConfig {
        watch_paths: default_watch_paths(),
        debounce_ms: DEFAULT_DEBOUNCE_MS,
    }
}

fn default_defaults_config() -> DefaultsConfig {
    DefaultsConfig {
        image: default_image(),
        port_range: default_port_range(),
    }
}

fn default_watch_paths() -> Vec<PathBuf> {
    vec![
        dirs::home_dir()
            .unwrap_or_else(|| PathBuf::from("~"))
            .join("src"),
    ]
}

fn default_debounce_ms() -> u64 {
    DEFAULT_DEBOUNCE_MS
}

fn default_image() -> String {
    DEFAULT_IMAGE.to_string()
}

fn default_port_range() -> String {
    format!("{DEFAULT_PORT_START}-{DEFAULT_PORT_END}")
}

fn default_rw() -> String {
    "rw".to_string()
}

fn true_val() -> bool {
    true
}

/// Detect the host operating system.
/// Returns a human-readable string like "Fedora Silverblue 43" or "macOS 15.4".
pub fn detect_host_os() -> String {
    if cfg!(target_os = "macos") {
        // macOS has no /etc/os-release — use sw_vers instead
        if let Ok(output) = std::process::Command::new("sw_vers")
            .arg("-productVersion")
            .output()
        {
            let version = String::from_utf8_lossy(&output.stdout).trim().to_string();
            if !version.is_empty() {
                return format!("macOS {version}");
            }
        }
        return "macOS".to_string();
    }

    if cfg!(target_os = "windows") {
        // Windows: use `ver` or environment variables
        if let Ok(output) = std::process::Command::new("cmd")
            .args(["/c", "ver"])
            .output()
        {
            let ver = String::from_utf8_lossy(&output.stdout).trim().to_string();
            if !ver.is_empty() {
                return ver;
            }
        }
        return "Windows".to_string();
    }

    if let Ok(content) = std::fs::read_to_string("/etc/os-release") {
        let mut name = String::new();
        let mut version = String::new();
        let mut variant = String::new();
        for line in content.lines() {
            if let Some(val) = line.strip_prefix("NAME=") {
                name = val.trim_matches('"').to_string();
            } else if let Some(val) = line.strip_prefix("VERSION_ID=") {
                version = val.trim_matches('"').to_string();
            } else if let Some(val) = line.strip_prefix("VARIANT=") {
                variant = val.trim_matches('"').to_string();
            }
        }
        if !variant.is_empty() {
            format!("{name} {variant} {version}")
        } else {
            format!("{name} {version}")
        }
    } else {
        "Unknown OS".to_string()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::path::Path;

    #[test]
    fn default_config_values() {
        let config = GlobalConfig::default();
        assert_eq!(config.defaults.image, DEFAULT_IMAGE);
        assert_eq!(config.defaults.port_range, "3000-3019");
        assert!(config.security.cap_drop_all);
        assert!(config.security.no_new_privileges);
        assert!(config.security.userns_keep_id);
        assert_eq!(config.scanner.debounce_ms, 2000);
    }

    // @trace spec:external-logs-layer
    #[test]
    fn external_logs_dir_points_to_state_sibling() {
        let dir = external_logs_dir();
        assert!(dir.ends_with(Path::new("external-logs")));
        assert!(dir.to_string_lossy().contains("tillandsias"));
    }

    // @trace spec:external-logs-layer
    #[test]
    fn external_logs_role_dir_appends_role() {
        let dir = external_logs_role_dir("git-service");
        assert!(dir.ends_with(Path::new("external-logs/git-service")));
    }

    // @trace spec:forge-hot-cold-split
    #[test]
    fn forge_config_defaults_round_trip_through_toml() {
        // Default ForgeConfig values round-trip through TOML correctly.
        let config = GlobalConfig::default();
        assert_eq!(config.forge.hot_path_max_mb, 4096);
        assert_eq!(config.forge.hot_path_inflation, 4);

        // Serialize and deserialize back.
        let toml_str = toml::to_string(&config).unwrap();
        let parsed: GlobalConfig = toml::from_str(&toml_str).unwrap();
        assert_eq!(parsed.forge.hot_path_max_mb, config.forge.hot_path_max_mb);
        assert_eq!(
            parsed.forge.hot_path_inflation,
            config.forge.hot_path_inflation
        );

        // Verify custom values are preserved.
        let custom = r#"
[forge]
hot_path_max_mb = 2048
hot_path_inflation = 6
"#;
        let parsed_custom: GlobalConfig = toml::from_str(custom).unwrap();
        assert_eq!(parsed_custom.forge.hot_path_max_mb, 2048);
        assert_eq!(parsed_custom.forge.hot_path_inflation, 6);
    }

    // @trace spec:forge-hot-cold-split (Requirement: Per-launch project
    //   source budget — Scenario "Budget = git mirror's size-pack ×
    //   forge.hot_path_inflation, clamped [256, forge.hot_path_max_mb]")
    #[test]
    fn compute_hot_budget_inflates_pack_size_by_default_factor() {
        // Spec example: pack size 200 MB and hot_path_inflation = 4
        // → budget = 800 MB, within [256, 4096].
        let config = ForgeConfig::default();
        let pack_size_kb = 200 * 1024; // 200 MiB
        let budget = compute_hot_budget(pack_size_kb, &config);
        assert_eq!(budget, 800, "expected 200 MiB × 4 = 800 MiB budget");
    }

    // @trace spec:forge-hot-cold-split (Scenario "Empty mirror returns
    //   floor (256 MB)")
    #[test]
    fn compute_hot_budget_returns_floor_for_empty_mirror() {
        // Spec: empty mirror or count-objects returns 0 → 256 MB floor.
        let config = ForgeConfig::default();
        let budget = compute_hot_budget(0, &config);
        assert_eq!(
            budget, HOT_PATH_BUDGET_FLOOR_MB,
            "empty mirror MUST rise to the {} MB floor",
            HOT_PATH_BUDGET_FLOOR_MB
        );

        // A pack smaller than the floor (after inflation) MUST also
        // rise to the floor — a 10 KiB pack × 4 = 40 KiB ≈ 0 MB → 256.
        let small_budget = compute_hot_budget(10, &config);
        assert_eq!(
            small_budget, HOT_PATH_BUDGET_FLOOR_MB,
            "sub-floor pack MUST rise to the floor"
        );
    }

    // @trace spec:forge-hot-cold-split (Scenario "Budget exceeds
    //   max_mb → clamped at ceiling")
    #[test]
    fn compute_hot_budget_clamps_at_ceiling_hot_path_max_mb() {
        // Spec example phrasing: when pack × inflation exceeds
        // hot_path_max_mb, return hot_path_max_mb (default 4096 MB).
        let config = ForgeConfig::default();
        // 2 GiB pack × 4 = 8 GiB → must clamp to 4096 MB ceiling.
        let pack_size_kb = 2 * 1024 * 1024; // 2 GiB
        let budget = compute_hot_budget(pack_size_kb, &config);
        assert_eq!(
            budget, config.hot_path_max_mb,
            "huge pack MUST clamp to hot_path_max_mb ceiling"
        );
    }

    // @trace spec:forge-hot-cold-split (custom-config branch — covers
    //   the user-tunable ceiling and inflation knobs)
    #[test]
    fn compute_hot_budget_honours_custom_inflation_and_max() {
        // A user might raise inflation to 8 (large working trees) and
        // lower the ceiling to 2048 (constrained host RAM). Both knobs
        // must compose with the clamp logic.
        let config = ForgeConfig {
            hot_path_inflation: 8,
            hot_path_max_mb: 2048,
            ..ForgeConfig::default()
        };

        // 100 MiB × 8 = 800 MiB (within [256, 2048]).
        let mid = compute_hot_budget(100 * 1024, &config);
        assert_eq!(mid, 800);

        // 500 MiB × 8 = 4000 MiB → clamp to 2048.
        let high = compute_hot_budget(500 * 1024, &config);
        assert_eq!(high, 2048);

        // Saturating multiplication: a malicious config can't overflow
        // u32. 1 PiB × 8 saturates to u32::MAX, then clamps to 2048.
        let huge = compute_hot_budget(u64::MAX / 1024, &config);
        assert_eq!(huge, 2048);
    }

    // @trace spec:forge-hot-cold-split (parser for `git count-objects
    //   -v -H` step 1 of compute_hot_budget recipe)
    #[test]
    fn parse_size_pack_kb_extracts_value_from_canonical_output() {
        let canonical = "count: 0
size: 0
in-pack: 1234
packs: 1
size-pack: 12345
prune-packable: 0
garbage: 0
size-garbage: 0
";
        assert_eq!(parse_size_pack_kb(canonical), 12345);

        // Order-independence: the field can appear anywhere.
        let reordered = "size-pack: 67\ncount: 0\n";
        assert_eq!(parse_size_pack_kb(reordered), 67);

        // Whitespace tolerance around the value.
        let padded = "size-pack:   42   \n";
        assert_eq!(parse_size_pack_kb(padded), 42);
    }

    // @trace spec:forge-hot-cold-split (parser fallback — empty mirror
    //   path: count-objects on a brand-new repo omits size-pack)
    #[test]
    fn parse_size_pack_kb_returns_zero_on_missing_or_unparseable_field() {
        // Missing field entirely (empty repo / git error).
        assert_eq!(parse_size_pack_kb("count: 0\nsize: 0\n"), 0);
        // Empty output.
        assert_eq!(parse_size_pack_kb(""), 0);
        // Unparseable value (corrupt git output).
        assert_eq!(parse_size_pack_kb("size-pack: not-a-number"), 0);
        // Negative-looking value (u64 parse fails).
        assert_eq!(parse_size_pack_kb("size-pack: -1"), 0);
    }

    #[test]
    fn merge_project_overrides_image() {
        let global = GlobalConfig::default();
        let project = ProjectConfig {
            image: Some("custom:latest".to_string()),
            ..Default::default()
        };
        let resolved = global.merge_with_project(&project);
        assert_eq!(resolved.image, "custom:latest");
    }

    #[test]
    fn merge_project_cannot_weaken_security() {
        let global = GlobalConfig::default();
        // Even if somehow a project config had security fields, they'd be ignored
        let project = ProjectConfig::default();
        let resolved = global.merge_with_project(&project);
        assert!(resolved.security.cap_drop_all);
        assert!(resolved.security.no_new_privileges);
        assert!(resolved.security.userns_keep_id);
    }

    #[test]
    fn merge_uses_global_defaults() {
        let global = GlobalConfig::default();
        let project = ProjectConfig::default();
        let resolved = global.merge_with_project(&project);
        assert_eq!(resolved.image, DEFAULT_IMAGE);
        assert_eq!(resolved.port_range, "3000-3019");
    }

    #[test]
    fn parse_port_range_valid() {
        assert_eq!(
            GlobalConfig::parse_port_range("3000-3019"),
            Some((3000, 3019))
        );
        assert_eq!(
            GlobalConfig::parse_port_range("8080-8089"),
            Some((8080, 8089))
        );
    }

    #[test]
    fn parse_port_range_invalid() {
        assert_eq!(GlobalConfig::parse_port_range("invalid"), None);
        assert_eq!(GlobalConfig::parse_port_range("3000"), None);
    }

    #[test]
    fn load_missing_config_returns_defaults() {
        let config = load_global_config_from(Path::new("/nonexistent/config.toml"));
        assert_eq!(config.defaults.image, DEFAULT_IMAGE);
    }

    #[test]
    fn load_toml_config() {
        let dir = std::env::temp_dir().join("tillandsias-test-config");
        std::fs::create_dir_all(&dir).unwrap();
        let path = dir.join("config.toml");
        std::fs::write(
            &path,
            r#"
[defaults]
image = "my-forge:v2"
port_range = "8080-8089"

[scanner]
debounce_ms = 5000
"#,
        )
        .unwrap();

        let config = load_global_config_from(&path);
        assert_eq!(config.defaults.image, "my-forge:v2");
        assert_eq!(config.defaults.port_range, "8080-8089");
        assert_eq!(config.scanner.debounce_ms, 5000);
        // Security always defaults to true
        assert!(config.security.cap_drop_all);

        std::fs::remove_dir_all(&dir).ok();
    }

    #[test]
    fn verbose_config_roundtrips() {
        let config = GlobalConfig::default();
        let verbose = generate_verbose_config(&config);

        // The verbose output must be parseable back to a valid config
        let parsed: GlobalConfig = toml::from_str(&verbose).unwrap();
        assert_eq!(parsed.scanner.debounce_ms, config.scanner.debounce_ms);
        assert_eq!(parsed.defaults.port_range, config.defaults.port_range);
        assert_eq!(parsed.i18n.language, config.i18n.language);
        assert_eq!(parsed.agent.selected, config.agent.selected);
        assert_eq!(
            parsed.updates.check_interval_hours,
            config.updates.check_interval_hours
        );
        assert_eq!(
            parsed.updates.check_on_launch,
            config.updates.check_on_launch
        );
        assert!(parsed.security.cap_drop_all);
        assert!(parsed.security.no_new_privileges);
        assert!(parsed.security.userns_keep_id);
    }

    #[test]
    fn verbose_config_contains_comments() {
        let config = GlobalConfig::default();
        let verbose = generate_verbose_config(&config);

        assert!(verbose.contains("This file is safe to delete"));
        assert!(verbose.contains("Your preferred coding assistant"));
        assert!(verbose.contains("cannot be weakened"));
        assert!(verbose.contains("Your language"));
    }

    // @trace spec:browser-isolation-tray-integration, spec:opencode-web-session-otp
    #[test]
    fn selected_agent_default_is_opencode_web() {
        assert_eq!(SelectedAgent::default(), SelectedAgent::OpenCodeWeb);
    }

    // @trace spec:browser-isolation-tray-integration, spec:opencode-web-session-otp
    #[test]
    fn selected_agent_as_env_str() {
        assert_eq!(SelectedAgent::OpenCode.as_env_str(), "opencode");
        assert_eq!(SelectedAgent::Claude.as_env_str(), "claude");
        assert_eq!(SelectedAgent::OpenCodeWeb.as_env_str(), "opencode-web");
    }

    // @trace spec:browser-isolation-tray-integration, spec:opencode-web-session-otp
    #[test]
    fn selected_agent_from_str_opt() {
        assert_eq!(
            SelectedAgent::from_str_opt("opencode"),
            Some(SelectedAgent::OpenCode)
        );
        assert_eq!(
            SelectedAgent::from_str_opt("claude"),
            Some(SelectedAgent::Claude)
        );
        assert_eq!(
            SelectedAgent::from_str_opt("opencode-web"),
            Some(SelectedAgent::OpenCodeWeb)
        );
        // case-insensitive per existing style
        assert_eq!(
            SelectedAgent::from_str_opt("OpenCode-Web"),
            Some(SelectedAgent::OpenCodeWeb)
        );
        assert_eq!(SelectedAgent::from_str_opt("unknown"), None);
    }

    // @trace spec:browser-isolation-tray-integration, spec:opencode-web-session-otp
    #[test]
    fn selected_agent_display_name() {
        assert_eq!(SelectedAgent::OpenCode.display_name(), "OpenCode");
        assert_eq!(SelectedAgent::Claude.display_name(), "Claude");
        assert_eq!(SelectedAgent::OpenCodeWeb.display_name(), "OpenCode Web");
    }

    // @trace spec:browser-isolation-tray-integration, spec:opencode-web-session-otp
    #[test]
    fn selected_agent_is_web() {
        assert!(!SelectedAgent::OpenCode.is_web());
        assert!(!SelectedAgent::Claude.is_web());
        assert!(SelectedAgent::OpenCodeWeb.is_web());
    }

    // @trace spec:browser-isolation-tray-integration, spec:opencode-web-session-otp
    #[test]
    fn selected_agent_serde_roundtrip() {
        // Existing variants serialize as plain lowercase (rename_all = "lowercase").
        let opencode = toml::to_string(&AgentConfig {
            selected: SelectedAgent::OpenCode,
        })
        .unwrap();
        assert!(opencode.contains("selected = \"opencode\""));

        let claude = toml::to_string(&AgentConfig {
            selected: SelectedAgent::Claude,
        })
        .unwrap();
        assert!(claude.contains("selected = \"claude\""));

        // OpenCodeWeb uses the explicit #[serde(rename = "opencode-web")] form.
        let web = toml::to_string(&AgentConfig {
            selected: SelectedAgent::OpenCodeWeb,
        })
        .unwrap();
        assert!(
            web.contains("selected = \"opencode-web\""),
            "expected opencode-web, got: {web}"
        );

        // Deserialize back.
        let parsed: AgentConfig = toml::from_str("selected = \"opencode-web\"").unwrap();
        assert_eq!(parsed.selected, SelectedAgent::OpenCodeWeb);
        let parsed: AgentConfig = toml::from_str("selected = \"opencode\"").unwrap();
        assert_eq!(parsed.selected, SelectedAgent::OpenCode);
        let parsed: AgentConfig = toml::from_str("selected = \"claude\"").unwrap();
        assert_eq!(parsed.selected, SelectedAgent::Claude);
    }

    // @trace spec:browser-isolation-tray-integration, spec:opencode-web-session-otp
    #[test]
    fn agent_config_default_is_opencode_web() {
        let cfg = AgentConfig::default();
        assert_eq!(cfg.selected, SelectedAgent::OpenCodeWeb);
    }

    // @trace gap:ON-008
    #[test]
    fn agent_profile_auto_load_from_config() {
        // Test that global config correctly loads agent preference
        let config = GlobalConfig::default();
        assert_eq!(config.agent.selected, SelectedAgent::OpenCodeWeb);

        // Test round-trip: parse and serialize agent selection
        let dir = std::env::temp_dir().join("tillandsias-test-agent");
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        let path = dir.join("config.toml");

        // Test Claude agent selection
        std::fs::write(&path, "[agent]\nselected = \"claude\"").unwrap();
        let loaded = load_global_config_from(&path);
        assert_eq!(loaded.agent.selected, SelectedAgent::Claude);
        assert_eq!(loaded.agent.selected.as_env_str(), "claude");

        // Test OpenCode agent selection
        std::fs::write(&path, "[agent]\nselected = \"opencode\"").unwrap();
        let loaded = load_global_config_from(&path);
        assert_eq!(loaded.agent.selected, SelectedAgent::OpenCode);
        assert_eq!(loaded.agent.selected.as_env_str(), "opencode");

        // Test OpenCode Web agent selection
        std::fs::write(&path, "[agent]\nselected = \"opencode-web\"").unwrap();
        let loaded = load_global_config_from(&path);
        assert_eq!(loaded.agent.selected, SelectedAgent::OpenCodeWeb);
        assert_eq!(loaded.agent.selected.as_env_str(), "opencode-web");

        std::fs::remove_dir_all(&dir).ok();
    }
}
