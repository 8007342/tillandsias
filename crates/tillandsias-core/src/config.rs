use std::path::{Path, PathBuf};

use tracing::{debug, warn};

use crate::state::Os;

/// Default container image.
const DEFAULT_IMAGE: &str = "ghcr.io/8007342/macuahuitl:latest";

/// Default port range start.
const DEFAULT_PORT_START: u16 = 3000;
const DEFAULT_PORT_END: u16 = 3019;

/// Default debounce for filesystem scanner.
const DEFAULT_DEBOUNCE_MS: u64 = 2000;

/// Which AI coding agent to launch in forge containers.
#[derive(Debug, Clone, Copy, PartialEq, Eq, serde::Serialize, serde::Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum SelectedAgent {
    OpenCode,
    Claude,
}

impl Default for SelectedAgent {
    fn default() -> Self {
        Self::OpenCode
    }
}

impl SelectedAgent {
    /// The string value passed as `TILLANDSIAS_AGENT` env var.
    pub fn as_env_str(&self) -> &'static str {
        match self {
            Self::OpenCode => "opencode",
            Self::Claude => "claude",
        }
    }

    /// Parse from a string (case-insensitive). Returns `None` for unknown values.
    pub fn from_str_opt(s: &str) -> Option<Self> {
        match s.to_lowercase().as_str() {
            "opencode" => Some(Self::OpenCode),
            "claude" => Some(Self::Claude),
            _ => None,
        }
    }

    /// Display name for menu labels.
    pub fn display_name(&self) -> &'static str {
        match self {
            Self::OpenCode => "OpenCode",
            Self::Claude => "Claude",
        }
    }
}

/// Agent selection configuration.
#[derive(Debug, Clone, serde::Serialize, serde::Deserialize)]
pub struct AgentConfig {
    #[serde(default)]
    pub selected: SelectedAgent,
}

impl Default for AgentConfig {
    fn default() -> Self {
        Self {
            selected: SelectedAgent::default(),
        }
    }
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

/// Save the selected language to the global config file.
///
/// Reads the existing config, updates the i18n section, and writes it back.
/// Creates the config directory and file if they don't exist.
pub fn save_selected_language(language: &str) {
    let dir = config_dir();
    if let Err(e) = std::fs::create_dir_all(&dir) {
        warn!(error = %e, "Failed to create config directory");
        return;
    }

    let path = dir.join("config.toml");
    let mut config = load_global_config_from(&path);
    config.i18n.language = language.to_string();

    match toml::to_string_pretty(&config) {
        Ok(contents) => {
            if let Err(e) = std::fs::write(&path, contents) {
                warn!(error = %e, "Failed to write config file");
            } else {
                debug!(?path, language, "Language selection saved");
            }
        }
        Err(e) => {
            warn!(error = %e, "Failed to serialize config");
        }
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
/// Reads the existing config, updates the agent section, and writes it back.
/// Creates the config directory and file if they don't exist.
pub fn save_selected_agent(agent: SelectedAgent) {
    let dir = config_dir();
    if let Err(e) = std::fs::create_dir_all(&dir) {
        warn!(error = %e, "Failed to create config directory");
        return;
    }

    let path = dir.join("config.toml");
    let mut config = load_global_config_from(&path);
    config.agent.selected = agent;

    match toml::to_string_pretty(&config) {
        Ok(contents) => {
            if let Err(e) = std::fs::write(&path, contents) {
                warn!(error = %e, "Failed to write config file");
            } else {
                debug!(?path, agent = agent.as_env_str(), "Agent selection saved");
            }
        }
        Err(e) => {
            warn!(error = %e, "Failed to serialize config");
        }
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

#[cfg(test)]
mod tests {
    use super::*;

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
