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
    /// A subdirectory under the secrets dir (e.g., "gh", "git").
    SecretsSubdir(&'static str),
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
    /// Mount ~/.claude/ into the container (rw).
    ClaudeDir,
    /// Mount GitHub token file at /run/secrets/github_token (ro).
    /// @trace spec:secret-rotation
    GitHubToken,
    /// Forward the host D-Bus session bus socket for keyring access.
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

    // Resolved secret paths (filesystem)
    pub claude_dir: PathBuf,
    pub gh_dir: PathBuf,
    pub git_dir: PathBuf,

    /// Path to the tmpfs-backed GitHub token file for this container.
    /// When `Some`, the file is bind-mounted at `/run/secrets/github_token:ro`
    /// and `GIT_ASKPASS` is set to the forge image's askpass script.
    /// @trace spec:secret-rotation
    pub token_file_path: Option<PathBuf>,

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
    }
}

/// Maintenance terminal — fish shell, no secrets, no API keys.
pub fn terminal_profile() -> ContainerProfile {
    ContainerProfile {
        entrypoint: "/usr/local/bin/entrypoint-terminal.sh",
        working_dir: Some(WorkingDir::ProjectSubdir),
        mounts: common_forge_mounts(),
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
    }
}

/// Git service container — bare mirror + git daemon + D-Bus for credentials.
///
/// Runs a local git daemon inside the enclave network. Forge containers clone
/// and fetch from this service instead of hitting the internet directly.
///
/// Mounts are intentionally empty — the mirror volume is added dynamically at
/// launch time based on the project being served. Secrets include D-Bus socket
/// forwarding (primary, for host keyring access) and a GitHub token fallback
/// for environments where D-Bus is unavailable.
///
/// @trace spec:git-mirror-service
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
            SecretMount {
                kind: SecretKind::GitHubToken, // Fallback for when D-Bus unavailable
            },
        ],
        image_override: None,
    }
}

// ---------------------------------------------------------------------------
// Shared mount/env definitions
// ---------------------------------------------------------------------------

fn common_forge_mounts() -> Vec<ProfileMount> {
    // Only the build cache mount remains. Project code comes from the git mirror
    // service, and credentials are no longer mounted into forge containers.
    vec![
        ProfileMount {
            host_key: MountSource::CacheDir,
            container_path: "/home/forge/.cache/tillandsias",
            mode: MountMode::Rw,
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
        assert!(matches!(
            profile.working_dir,
            Some(WorkingDir::ProjectSubdir)
        ));
    }

    #[test]
    fn web_has_readonly_mount_only() {
        let profile = web_profile();
        assert!(profile.secrets.is_empty(), "Web profile should have no secrets");
        assert!(
            !profile
                .secrets
                .iter()
                .any(|s| s.kind == SecretKind::GitHubToken),
            "Web profile must NOT have GitHubToken"
        );
        assert!(profile.env_vars.is_empty());
        assert_eq!(profile.mounts.len(), 1);
        assert_eq!(profile.mounts[0].mode, MountMode::Ro);
        assert_eq!(profile.image_override, Some("tillandsias-web:latest"));
    }

    #[test]
    fn forge_profiles_have_one_mount() {
        let opencode = forge_opencode_profile();
        let claude = forge_claude_profile();
        // cache only (project dir, gh, git mounts removed)
        assert_eq!(opencode.mounts.len(), 1);
        assert_eq!(claude.mounts.len(), 1);
        assert_eq!(opencode.mounts[0].container_path, "/home/forge/.cache/tillandsias");
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
    fn terminal_has_fifteen_env_vars() {
        let profile = terminal_profile();
        // PROJECT, HOST_OS, LANG, LANGUAGE (no AGENT, no GIT_SERVICE)
        // + GIT_AUTHOR_NAME, GIT_AUTHOR_EMAIL, GIT_COMMITTER_NAME, GIT_COMMITTER_EMAIL
        // + OLLAMA_HOST
        // + HTTP_PROXY, HTTPS_PROXY, NO_PROXY, http_proxy, https_proxy, no_proxy
        // @trace spec:proxy-container, spec:enclave-network, spec:inference-container
        assert_eq!(profile.env_vars.len(), 15);
    }

    // @trace spec:git-mirror-service
    #[test]
    fn git_service_has_dbus_and_token_secrets_no_mounts() {
        let profile = git_service_profile();
        assert_eq!(
            profile.secrets.len(),
            2,
            "Git service should have DbusSession + GitHubToken"
        );
        assert!(
            profile
                .secrets
                .iter()
                .any(|s| s.kind == SecretKind::DbusSession),
            "Git service must have DbusSession for keyring access"
        );
        assert!(
            profile
                .secrets
                .iter()
                .any(|s| s.kind == SecretKind::GitHubToken),
            "Git service must have GitHubToken as fallback"
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
}
