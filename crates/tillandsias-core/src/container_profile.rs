//! Declarative container profiles.
//!
//! Each profile fully describes a container type's launch configuration:
//! entrypoint, mounts, env vars, and secrets. A single `build_podman_args()`
//! function in the tray/CLI binary converts a profile + context into a
//! `Vec<String>` of podman arguments.
//!
//! Security flags are NOT part of profiles — they are hardcoded in the
//! arg builder and cannot be overridden.
//!
//! @trace spec:environment-runtime, spec:podman-orchestration

use std::path::PathBuf;

/// A declarative description of how to launch a container type.
///
/// Built-in profiles are defined as functions returning `ContainerProfile`.
/// The struct deliberately avoids absolute paths — those are resolved at
/// launch time via [`LaunchContext`].
#[derive(Debug, Clone)]
pub struct ContainerProfile {
    /// Entrypoint binary (absolute path inside the container).
    pub entrypoint: &'static str,

    /// Working directory inside the container. `None` = container default.
    pub working_dir: Option<WorkingDir>,

    /// Volume mounts with logical keys resolved at launch time.
    pub mounts: Vec<ProfileMount>,

    /// Environment variables. Values use `EnvValue` for deferred resolution.
    pub env_vars: Vec<ProfileEnvVar>,

    /// Secret mounts — only present for profiles that need them.
    pub secrets: Vec<SecretMount>,

    /// Override the default image tag (e.g., web uses `tillandsias-web`).
    pub image_override: Option<&'static str>,

    /// Process limit (`--pids-limit`). Prevents fork bombs and constrains
    /// each container to its intended workload.
    /// @trace spec:secret-management, spec:podman-orchestration
    pub pids_limit: u32,

    /// Make the root filesystem read-only (`--read-only`). Service containers
    /// (git, proxy, inference) use this; forge/terminal need mutable workspace.
    /// @trace spec:podman-orchestration
    pub read_only: bool,

    /// Tmpfs mounts for runtime directories when `read_only` is true.
    /// Each entry is a container path (e.g., "/tmp", "/var/run/squid").
    /// @trace spec:podman-orchestration
    pub tmpfs_mounts: Vec<&'static str>,
}

/// A volume mount with a logical host key resolved at launch time.
#[derive(Debug, Clone)]
pub struct ProfileMount {
    /// Logical key identifying the host path.
    pub host_key: MountSource,

    /// Absolute path inside the container.
    pub container_path: &'static str,

    /// Mount mode.
    pub mode: MountMode,
}

/// Logical source of a mount — resolved to an absolute path by the launcher.
#[derive(Debug, Clone)]
pub enum MountSource {
    /// The project directory itself.
    ProjectDir,
    /// The tillandsias cache directory (~/.cache/tillandsias).
    CacheDir,
    /// Pre-built tools overlay directory (~/.cache/tillandsias/tools-overlay/current).
    /// Resolved at launch time; mount is skipped if the overlay doesn't exist yet.
    /// @trace spec:layered-tools-overlay
    ToolsOverlay,
    /// Opinionated config overlay on tmpfs (ramdisk) for fast reads.
    /// Resolved at launch time from `$XDG_RUNTIME_DIR/tillandsias/config-overlay/`.
    /// Mount is skipped if the tmpfs directory doesn't exist yet.
    /// @trace spec:layered-tools-overlay
    ConfigOverlay,
}

/// Mount permission mode.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum MountMode {
    Ro,
    Rw,
}

impl MountMode {
    pub fn as_str(&self) -> &'static str {
        match self {
            Self::Ro => "ro",
            Self::Rw => "rw",
        }
    }
}

/// An environment variable with a value resolved at launch time.
#[derive(Debug, Clone)]
pub struct ProfileEnvVar {
    pub name: &'static str,
    pub value: EnvValue,
}

/// How an environment variable's value is determined.
#[derive(Debug, Clone)]
pub enum EnvValue {
    /// Resolved from `LaunchContext` at launch time.
    FromContext(ContextKey),
    /// A fixed string literal.
    Literal(&'static str),
}

/// Keys into `LaunchContext` for deferred env var resolution.
#[derive(Debug, Clone)]
pub enum ContextKey {
    ProjectName,
    HostOs,
    AgentName,
    /// The user's selected language as a full POSIX LANG value (e.g., "ja_JP.UTF-8").
    /// @trace spec:environment-runtime
    Language,
    /// Git author name, read from the cached gitconfig.
    GitAuthorName,
    /// Git author email, read from the cached gitconfig.
    GitAuthorEmail,
}

/// A secret that may be mounted as a volume or injected as an env var.
#[derive(Debug, Clone)]
pub struct SecretMount {
    /// What kind of secret this is.
    pub kind: SecretKind,
}

/// The types of secrets a profile can request.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum SecretKind {
    /// Forward the host D-Bus session bus socket for keyring access.
    /// D-Bus is the sole credential path — if unavailable, git operations
    /// fail explicitly rather than falling back to less-secure mechanisms.
    /// @trace spec:git-mirror-service, spec:secret-management
    DbusSession,
}

/// Working directory specification inside the container.
#[derive(Debug, Clone)]
pub enum WorkingDir {
    /// `/home/forge/src/<project_name>` — for per-project terminals.
    ProjectSubdir,
    /// `/home/forge/src` — for root terminals.
    SrcRoot,
}

/// Context provided at launch time for resolving logical keys to real paths.
#[derive(Debug, Clone)]
pub struct LaunchContext {
    pub container_name: String,
    pub project_path: PathBuf,
    pub project_name: String,
    pub cache_dir: PathBuf,
    pub port_range: (u16, u16),
    pub host_os: String,
    pub detached: bool,
    pub is_watch_root: bool,

    // Custom mounts from project config
    pub custom_mounts: Vec<crate::config::MountConfig>,

    // Image tag (resolved before launch)
    pub image_tag: String,

    /// The user's selected language code (e.g., "ja", "es", "zh-Hant").
    /// Resolved to a full POSIX LANG value via `language_to_lang_value()`.
    /// @trace spec:environment-runtime
    pub selected_language: String,

    /// Optional podman network to attach the container to.
    /// When `Some`, adds `--network=<value>` to the podman args.
    /// Forge containers use `Some("tillandsias-enclave")`, proxy uses
    /// `Some("tillandsias-enclave,bridge")` for dual-homing.
    /// @trace spec:enclave-network, spec:proxy-container
    pub network: Option<String>,

    /// Git author name for GIT_AUTHOR_NAME / GIT_COMMITTER_NAME env vars.
    /// Read from `~/.cache/tillandsias/secrets/git/.gitconfig` at launch time.
    pub git_author_name: String,

    /// Git author email for GIT_AUTHOR_EMAIL / GIT_COMMITTER_EMAIL env vars.
    /// Read from `~/.cache/tillandsias/secrets/git/.gitconfig` at launch time.
    pub git_author_email: String,
}

// ---------------------------------------------------------------------------
// Built-in profiles
// ---------------------------------------------------------------------------

// @trace spec:environment-runtime, knowledge:infra/podman-rootless
/// Forge container for OpenCode (no secrets — fully offline, credential-free).
pub fn forge_opencode_profile() -> ContainerProfile {
    ContainerProfile {
        entrypoint: "/usr/local/bin/entrypoint-forge-opencode.sh",
        working_dir: None,
        mounts: common_forge_mounts(),
        env_vars: common_forge_env(),
        secrets: vec![],
        image_override: None,
        pids_limit: 512,      // Compilers, language servers, AI tools
        read_only: false,      // Forge needs mutable workspace
        tmpfs_mounts: vec![],
    }
}

/// Forge container for Claude (no secrets — fully offline, credential-free).
// TODO: Claude authentication needs a credential service (Phase 5+)
pub fn forge_claude_profile() -> ContainerProfile {
    ContainerProfile {
        entrypoint: "/usr/local/bin/entrypoint-forge-claude.sh",
        working_dir: None,
        mounts: common_forge_mounts(),
        env_vars: common_forge_env(),
        secrets: vec![],
        image_override: None,
        pids_limit: 512,      // Compilers, language servers, AI tools
        read_only: false,      // Forge needs mutable workspace
        tmpfs_mounts: vec![],
    }
}

/// Maintenance terminal — fish shell, no secrets, no API keys.
pub fn terminal_profile() -> ContainerProfile {
    ContainerProfile {
        entrypoint: "/usr/local/bin/entrypoint-terminal.sh",
        // No working_dir — entrypoint clones from git mirror then cd's.
        // Setting -w would fail because the directory doesn't exist until after clone.
        working_dir: None,
        mounts: common_forge_mounts(),
        pids_limit: 512,      // Same as forge (maintenance shell)
        read_only: false,      // Terminal needs mutable workspace
        tmpfs_mounts: vec![],
        env_vars: vec![
            ProfileEnvVar {
                name: "TILLANDSIAS_PROJECT",
                value: EnvValue::FromContext(ContextKey::ProjectName),
            },
            ProfileEnvVar {
                name: "TILLANDSIAS_HOST_OS",
                value: EnvValue::FromContext(ContextKey::HostOs),
            },
            // @trace spec:environment-runtime
            ProfileEnvVar {
                name: "LANG",
                value: EnvValue::FromContext(ContextKey::Language),
            },
            ProfileEnvVar {
                name: "LANGUAGE",
                value: EnvValue::FromContext(ContextKey::Language),
            },
            // Git identity from cached gitconfig (replaces mounted .gitconfig)
            ProfileEnvVar {
                name: "GIT_AUTHOR_NAME",
                value: EnvValue::FromContext(ContextKey::GitAuthorName),
            },
            ProfileEnvVar {
                name: "GIT_AUTHOR_EMAIL",
                value: EnvValue::FromContext(ContextKey::GitAuthorEmail),
            },
            ProfileEnvVar {
                name: "GIT_COMMITTER_NAME",
                value: EnvValue::FromContext(ContextKey::GitAuthorName),
            },
            ProfileEnvVar {
                name: "GIT_COMMITTER_EMAIL",
                value: EnvValue::FromContext(ContextKey::GitAuthorEmail),
            },
            // @trace spec:git-mirror-service
            ProfileEnvVar {
                name: "TILLANDSIAS_GIT_SERVICE",
                value: EnvValue::Literal("git-service"),
            },
            // @trace spec:inference-container
            ProfileEnvVar {
                name: "OLLAMA_HOST",
                value: EnvValue::Literal("http://inference:11434"),
            },
            // @trace spec:proxy-container, spec:enclave-network
            ProfileEnvVar {
                name: "HTTP_PROXY",
                value: EnvValue::Literal("http://proxy:3128"),
            },
            ProfileEnvVar {
                name: "HTTPS_PROXY",
                value: EnvValue::Literal("http://proxy:3128"),
            },
            ProfileEnvVar {
                name: "NO_PROXY",
                value: EnvValue::Literal("localhost,127.0.0.1,git-service"),
            },
            ProfileEnvVar {
                name: "http_proxy",
                value: EnvValue::Literal("http://proxy:3128"),
            },
            ProfileEnvVar {
                name: "https_proxy",
                value: EnvValue::Literal("http://proxy:3128"),
            },
            ProfileEnvVar {
                name: "no_proxy",
                value: EnvValue::Literal("localhost,127.0.0.1,git-service"),
            },
        ],
        secrets: vec![],
        image_override: None,
    }
}

/// Web container — httpd with project public dir only.
pub fn web_profile() -> ContainerProfile {
    ContainerProfile {
        entrypoint: "/entrypoint.sh",
        working_dir: None,
        mounts: vec![ProfileMount {
            host_key: MountSource::ProjectDir,
            container_path: "/var/www/html",
            mode: MountMode::Ro,
        }],
        env_vars: vec![],
        secrets: vec![],
        image_override: Some("tillandsias-web:latest"),
        pids_limit: 32,        // Only httpd
        read_only: true,       // Static file server — no writes needed
        tmpfs_mounts: vec!["/tmp", "/var/run"],
    }
}

/// Proxy container — caching HTTP/HTTPS proxy with domain allowlist.
///
/// Runs a Squid-based forward proxy inside the enclave network. Forge containers
/// route all HTTP(S) traffic through this proxy, which enforces a domain allowlist
/// and caches responses to reduce bandwidth and latency.
///
/// The proxy has NO secrets and NO env vars — it is a passive service container.
/// Its image tag is resolved at launch time via `LaunchContext.image_tag`, not
/// through `image_override` (which is static and cannot include the version).
///
/// @trace spec:proxy-container, spec:enclave-network
pub fn proxy_profile() -> ContainerProfile {
    ContainerProfile {
        entrypoint: "/usr/local/bin/entrypoint.sh",
        working_dir: None,
        mounts: vec![
            ProfileMount {
                host_key: MountSource::CacheDir,
                container_path: "/var/spool/squid",
                mode: MountMode::Rw,
            },
        ],
        env_vars: vec![],
        secrets: vec![],
        image_override: None,
        pids_limit: 32,        // Only squid + helpers
        read_only: true,       // Service container — immutable root FS
        tmpfs_mounts: vec!["/tmp", "/var/run/squid", "/var/log/squid"],
    }
}

/// Inference container — local LLM inference via ollama.
///
/// Runs an ollama server inside the enclave network. Forge containers connect
/// to it via `OLLAMA_HOST=http://inference:11434`. The model cache is mounted
/// dynamically at launch time from `~/.cache/tillandsias/models/`.
///
/// The inference container needs proxy env vars so ollama can download models
/// through the enclave proxy. No secrets are needed.
///
/// @trace spec:inference-container
pub fn inference_profile() -> ContainerProfile {
    ContainerProfile {
        entrypoint: "/usr/local/bin/entrypoint.sh",
        working_dir: None,
        mounts: vec![],  // Model cache mount added dynamically at launch time
        env_vars: vec![
            // Proxy env vars so ollama can download models through the proxy
            ProfileEnvVar {
                name: "HTTP_PROXY",
                value: EnvValue::Literal("http://proxy:3128"),
            },
            ProfileEnvVar {
                name: "HTTPS_PROXY",
                value: EnvValue::Literal("http://proxy:3128"),
            },
            ProfileEnvVar {
                name: "http_proxy",
                value: EnvValue::Literal("http://proxy:3128"),
            },
            ProfileEnvVar {
                name: "https_proxy",
                value: EnvValue::Literal("http://proxy:3128"),
            },
        ],
        secrets: vec![],  // No credentials needed
        image_override: None,
        pids_limit: 128,       // Ollama server + model runners
        read_only: true,       // Service container — immutable root FS
        tmpfs_mounts: vec!["/tmp"],
    }
}

/// Git service container — bare mirror + git daemon + D-Bus for credentials.
///
/// Runs a local git daemon inside the enclave network. Forge containers clone
/// and fetch from this service instead of hitting the internet directly.
///
/// Mounts are intentionally empty — the mirror volume is added dynamically at
/// launch time based on the project being served. D-Bus session bus forwarding
/// is the sole credential path — if unavailable, git operations fail explicitly.
///
/// @trace spec:git-mirror-service, spec:secret-management
pub fn git_service_profile() -> ContainerProfile {
    ContainerProfile {
        entrypoint: "/usr/local/bin/entrypoint.sh",
        working_dir: None,
        mounts: vec![], // Mirror volume added dynamically per-project
        env_vars: vec![],
        secrets: vec![
            SecretMount {
                kind: SecretKind::DbusSession,
            },
        ],
        image_override: None,
        pids_limit: 64,        // Only git-daemon + git processes
        read_only: true,       // Service container — immutable root FS
        tmpfs_mounts: vec!["/tmp"],
    }
}

// ---------------------------------------------------------------------------
// Shared mount/env definitions
// ---------------------------------------------------------------------------

fn common_forge_mounts() -> Vec<ProfileMount> {
    // Code comes from git mirror service, packages through proxy.
    // Mounts: pre-built tools overlay + config overlay (both read-only).
    // @trace spec:proxy-container, spec:layered-tools-overlay
    vec![
        ProfileMount {
            host_key: MountSource::ToolsOverlay,
            container_path: "/home/forge/.tools",
            mode: MountMode::Ro,
        },
        // @trace spec:layered-tools-overlay
        // Opinionated configs on ramdisk — entrypoints symlink into ~/.config/
        ProfileMount {
            host_key: MountSource::ConfigOverlay,
            container_path: "/home/forge/.config-overlay",
            mode: MountMode::Ro,
        },
    ]
}

fn common_forge_env() -> Vec<ProfileEnvVar> {
    vec![
        ProfileEnvVar {
            name: "TILLANDSIAS_PROJECT",
            value: EnvValue::FromContext(ContextKey::ProjectName),
        },
        ProfileEnvVar {
            name: "TILLANDSIAS_HOST_OS",
            value: EnvValue::FromContext(ContextKey::HostOs),
        },
        ProfileEnvVar {
            name: "TILLANDSIAS_AGENT",
            value: EnvValue::FromContext(ContextKey::AgentName),
        },
        // @trace spec:environment-runtime
        ProfileEnvVar {
            name: "LANG",
            value: EnvValue::FromContext(ContextKey::Language),
        },
        ProfileEnvVar {
            name: "LANGUAGE",
            value: EnvValue::FromContext(ContextKey::Language),
        },
        // Git identity from cached gitconfig (replaces mounted .gitconfig)
        ProfileEnvVar {
            name: "GIT_AUTHOR_NAME",
            value: EnvValue::FromContext(ContextKey::GitAuthorName),
        },
        ProfileEnvVar {
            name: "GIT_AUTHOR_EMAIL",
            value: EnvValue::FromContext(ContextKey::GitAuthorEmail),
        },
        ProfileEnvVar {
            name: "GIT_COMMITTER_NAME",
            value: EnvValue::FromContext(ContextKey::GitAuthorName),
        },
        ProfileEnvVar {
            name: "GIT_COMMITTER_EMAIL",
            value: EnvValue::FromContext(ContextKey::GitAuthorEmail),
        },
        // @trace spec:git-mirror-service
        ProfileEnvVar {
            name: "TILLANDSIAS_GIT_SERVICE",
            value: EnvValue::Literal("git-service"),
        },
        // @trace spec:inference-container
        // Point forge containers to the inference service for local LLM access.
        ProfileEnvVar {
            name: "OLLAMA_HOST",
            value: EnvValue::Literal("http://inference:11434"),
        },
        // @trace spec:proxy-container, spec:enclave-network
        // Uppercase — standard for curl, wget, apt, pip, npm, cargo, etc.
        ProfileEnvVar {
            name: "HTTP_PROXY",
            value: EnvValue::Literal("http://proxy:3128"),
        },
        ProfileEnvVar {
            name: "HTTPS_PROXY",
            value: EnvValue::Literal("http://proxy:3128"),
        },
        ProfileEnvVar {
            name: "NO_PROXY",
            value: EnvValue::Literal("localhost,127.0.0.1,git-service"),
        },
        // Lowercase — required by libcurl, Go net/http, some Python libs.
        ProfileEnvVar {
            name: "http_proxy",
            value: EnvValue::Literal("http://proxy:3128"),
        },
        ProfileEnvVar {
            name: "https_proxy",
            value: EnvValue::Literal("http://proxy:3128"),
        },
        ProfileEnvVar {
            name: "no_proxy",
            value: EnvValue::Literal("localhost,127.0.0.1,git-service"),
        },
    ]
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn forge_opencode_has_no_secrets() {
        let profile = forge_opencode_profile();
        assert!(profile.secrets.is_empty(), "Forge opencode must be credential-free");
        assert_eq!(
            profile.entrypoint,
            "/usr/local/bin/entrypoint-forge-opencode.sh"
        );
    }

    #[test]
    fn forge_claude_has_no_secrets() {
        let profile = forge_claude_profile();
        assert!(profile.secrets.is_empty(), "Forge claude must be credential-free");
    }

    #[test]
    fn terminal_has_no_secrets() {
        let profile = terminal_profile();
        assert!(profile.secrets.is_empty(), "Terminal must be credential-free");
        assert_eq!(profile.entrypoint, "/usr/local/bin/entrypoint-terminal.sh");
        // No working_dir — entrypoint clones from mirror then cd's into project
        assert!(profile.working_dir.is_none());
    }

    #[test]
    fn web_has_readonly_mount_only() {
        let profile = web_profile();
        assert!(profile.secrets.is_empty(), "Web profile should have no secrets");
        assert!(profile.env_vars.is_empty());
        assert_eq!(profile.mounts.len(), 1);
        assert_eq!(profile.mounts[0].mode, MountMode::Ro);
        assert_eq!(profile.image_override, Some("tillandsias-web:latest"));
    }

    // @trace spec:layered-tools-overlay
    #[test]
    fn forge_profiles_have_tools_overlay_mount() {
        let opencode = forge_opencode_profile();
        let claude = forge_claude_profile();
        // Mounts: tools overlay + config overlay (both read-only)
        // @trace spec:proxy-container, spec:layered-tools-overlay
        assert_eq!(opencode.mounts.len(), 2);
        assert_eq!(claude.mounts.len(), 2);
        assert_eq!(opencode.mounts[0].container_path, "/home/forge/.tools");
        assert_eq!(opencode.mounts[0].mode, MountMode::Ro);
        assert!(matches!(opencode.mounts[0].host_key, MountSource::ToolsOverlay));
    }

    // @trace spec:layered-tools-overlay
    #[test]
    fn forge_profiles_have_config_overlay_mount() {
        let opencode = forge_opencode_profile();
        let claude = forge_claude_profile();
        let terminal = terminal_profile();
        // Config overlay mount is second in forge profiles, first in terminal
        let oc_cfg = opencode.mounts.iter().find(|m| matches!(m.host_key, MountSource::ConfigOverlay));
        let cc_cfg = claude.mounts.iter().find(|m| matches!(m.host_key, MountSource::ConfigOverlay));
        let tm_cfg = terminal.mounts.iter().find(|m| matches!(m.host_key, MountSource::ConfigOverlay));
        assert!(oc_cfg.is_some(), "OpenCode profile must have ConfigOverlay mount");
        assert!(cc_cfg.is_some(), "Claude profile must have ConfigOverlay mount");
        assert!(tm_cfg.is_some(), "Terminal profile must have ConfigOverlay mount");
        assert_eq!(oc_cfg.unwrap().container_path, "/home/forge/.config-overlay");
        assert_eq!(oc_cfg.unwrap().mode, MountMode::Ro);
    }

    #[test]
    fn forge_profiles_have_seventeen_env_vars() {
        let opencode = forge_opencode_profile();
        let claude = forge_claude_profile();
        // PROJECT, HOST_OS, AGENT, LANG, LANGUAGE,
        // GIT_AUTHOR_NAME, GIT_AUTHOR_EMAIL, GIT_COMMITTER_NAME, GIT_COMMITTER_EMAIL,
        // GIT_SERVICE, OLLAMA_HOST,
        // HTTP_PROXY, HTTPS_PROXY, NO_PROXY, http_proxy, https_proxy, no_proxy
        // @trace spec:proxy-container, spec:enclave-network, spec:git-mirror-service, spec:inference-container
        assert_eq!(opencode.env_vars.len(), 17);
        assert_eq!(claude.env_vars.len(), 17);
    }

    #[test]
    fn terminal_has_sixteen_env_vars() {
        let profile = terminal_profile();
        // PROJECT, HOST_OS, LANG, LANGUAGE (no AGENT)
        // + GIT_AUTHOR_NAME, GIT_AUTHOR_EMAIL, GIT_COMMITTER_NAME, GIT_COMMITTER_EMAIL
        // + TILLANDSIAS_GIT_SERVICE, OLLAMA_HOST
        // + HTTP_PROXY, HTTPS_PROXY, NO_PROXY, http_proxy, https_proxy, no_proxy
        // @trace spec:proxy-container, spec:enclave-network, spec:inference-container, spec:git-mirror-service
        assert_eq!(profile.env_vars.len(), 16);
    }

    // @trace spec:git-mirror-service, spec:secret-management
    #[test]
    fn git_service_has_dbus_only_no_mounts() {
        let profile = git_service_profile();
        assert_eq!(
            profile.secrets.len(),
            1,
            "Git service should have DbusSession only (D-Bus is the sole credential path)"
        );
        assert!(
            profile
                .secrets
                .iter()
                .any(|s| s.kind == SecretKind::DbusSession),
            "Git service must have DbusSession for keyring access"
        );
        assert!(
            profile.mounts.is_empty(),
            "Git service mounts are added dynamically per-project"
        );
        assert!(
            profile.env_vars.is_empty(),
            "Git service has no static env vars"
        );
        assert!(
            profile.image_override.is_none(),
            "Git service image tag comes from LaunchContext"
        );
        assert_eq!(profile.entrypoint, "/usr/local/bin/entrypoint.sh");
    }

    // @trace spec:inference-container
    #[test]
    fn inference_has_proxy_env_vars_no_secrets_no_mounts() {
        let profile = inference_profile();
        assert!(profile.secrets.is_empty(), "Inference must have no secrets");
        assert!(
            profile.mounts.is_empty(),
            "Inference mounts are added dynamically at launch time"
        );
        // 4 proxy env vars: HTTP_PROXY, HTTPS_PROXY, http_proxy, https_proxy
        assert_eq!(
            profile.env_vars.len(),
            4,
            "Inference should have 4 proxy env vars"
        );
        assert!(
            profile
                .env_vars
                .iter()
                .any(|e| e.name == "HTTP_PROXY"),
            "Inference must have HTTP_PROXY"
        );
        assert!(
            profile
                .env_vars
                .iter()
                .any(|e| e.name == "https_proxy"),
            "Inference must have https_proxy"
        );
        assert!(
            profile.image_override.is_none(),
            "Inference image tag comes from LaunchContext"
        );
        assert_eq!(profile.entrypoint, "/usr/local/bin/entrypoint.sh");
    }

    // @trace spec:proxy-container, spec:enclave-network
    #[test]
    fn proxy_has_no_secrets_no_env_vars() {
        let profile = proxy_profile();
        assert!(profile.secrets.is_empty(), "Proxy must have no secrets");
        assert!(profile.env_vars.is_empty(), "Proxy is a passive service — no env vars");
        assert_eq!(profile.mounts.len(), 1, "Proxy has only the cache mount");
        assert_eq!(profile.mounts[0].container_path, "/var/spool/squid");
        assert_eq!(profile.mounts[0].mode, MountMode::Rw);
        assert!(profile.image_override.is_none(), "Proxy image tag comes from LaunchContext");
    }

    // @trace spec:layered-tools-overlay
    #[test]
    fn tools_overlay_expected_paths() {
        // These paths must match between:
        // - scripts/build-tools-overlay.sh (installs to /home/forge/.tools/<tool>)
        // - entrypoint-forge-claude.sh (checks /home/forge/.tools/claude/bin/claude)
        // - entrypoint-forge-opencode.sh (checks /home/forge/.tools/opencode/bin/opencode)
        // - lib-common.sh install_openspec() (checks /home/forge/.tools/openspec/bin/openspec)
        let container_mount = "/home/forge/.tools";
        let expected_bins = [
            format!("{container_mount}/claude/bin/claude"),
            format!("{container_mount}/opencode/bin/opencode"),
            format!("{container_mount}/openspec/bin/openspec"),
        ];

        // Verify the container mount path matches what forge profiles declare
        let profile = forge_opencode_profile();
        assert_eq!(
            profile.mounts[0].container_path, container_mount,
            "Profile mount path must match the expected tools container mount"
        );

        // Verify all expected tool binaries live under the mount root
        for bin in &expected_bins {
            assert!(
                bin.starts_with(container_mount),
                "Tool binary {bin} must be under {container_mount}"
            );
        }
    }

    // @trace spec:podman-orchestration, spec:secret-management
    #[test]
    fn all_profiles_have_pids_limit() {
        let profiles = [
            ("forge_opencode", forge_opencode_profile()),
            ("forge_claude", forge_claude_profile()),
            ("terminal", terminal_profile()),
            ("web", web_profile()),
            ("proxy", proxy_profile()),
            ("inference", inference_profile()),
            ("git_service", git_service_profile()),
        ];

        for (name, profile) in &profiles {
            assert!(
                profile.pids_limit > 0,
                "Profile {name} must have a non-zero pids_limit"
            );
        }
    }

    // @trace spec:podman-orchestration, spec:secret-management
    #[test]
    fn pids_limits_match_container_roles() {
        assert_eq!(forge_opencode_profile().pids_limit, 512, "Forge opencode: compilers + LSP + AI");
        assert_eq!(forge_claude_profile().pids_limit, 512, "Forge claude: compilers + LSP + AI");
        assert_eq!(terminal_profile().pids_limit, 512, "Terminal: same as forge");
        assert_eq!(git_service_profile().pids_limit, 64, "Git service: git-daemon + git only");
        assert_eq!(proxy_profile().pids_limit, 32, "Proxy: squid + helpers only");
        assert_eq!(inference_profile().pids_limit, 128, "Inference: ollama + model runners");
        assert_eq!(web_profile().pids_limit, 32, "Web: httpd only");
    }

    // @trace spec:podman-orchestration
    #[test]
    fn service_containers_are_read_only() {
        assert!(git_service_profile().read_only, "Git service must be read-only");
        assert!(proxy_profile().read_only, "Proxy must be read-only");
        assert!(inference_profile().read_only, "Inference must be read-only");
        assert!(web_profile().read_only, "Web must be read-only");
    }

    // @trace spec:podman-orchestration
    #[test]
    fn forge_containers_are_not_read_only() {
        assert!(!forge_opencode_profile().read_only, "Forge opencode must NOT be read-only");
        assert!(!forge_claude_profile().read_only, "Forge claude must NOT be read-only");
        assert!(!terminal_profile().read_only, "Terminal must NOT be read-only");
    }

    // @trace spec:podman-orchestration
    #[test]
    fn read_only_containers_have_tmpfs_mounts() {
        let profiles = [
            ("git_service", git_service_profile()),
            ("proxy", proxy_profile()),
            ("inference", inference_profile()),
            ("web", web_profile()),
        ];

        for (name, profile) in &profiles {
            assert!(
                profile.read_only,
                "Profile {name} should be read-only"
            );
            assert!(
                profile.tmpfs_mounts.contains(&"/tmp"),
                "Read-only profile {name} must have /tmp as tmpfs"
            );
        }
    }

    // @trace spec:proxy-container
    #[test]
    fn proxy_has_squid_runtime_tmpfs() {
        let profile = proxy_profile();
        assert!(profile.tmpfs_mounts.contains(&"/var/run/squid"), "Proxy must have /var/run/squid tmpfs");
        assert!(profile.tmpfs_mounts.contains(&"/var/log/squid"), "Proxy must have /var/log/squid tmpfs");
    }
}
