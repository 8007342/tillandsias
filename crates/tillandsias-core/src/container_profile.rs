//! Declarative container profiles.
//!
//! Each profile fully describes a container type's launch configuration:
//! entrypoint, mounts, env vars, and secrets. A single `build_podman_args()`
//! function in the tray/CLI binary converts a profile + context into a
//! `Vec<String>` of podman arguments.
//!
//! Security flags are NOT part of profiles — they are hardcoded in the
//! arg builder and cannot be overridden.

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
}

/// A secret that may be mounted as a volume or injected as an env var.
#[derive(Debug, Clone)]
pub struct SecretMount {
    /// What kind of secret this is.
    pub kind: SecretKind,
}

/// The types of secrets a profile can request.
#[derive(Debug, Clone)]
pub enum SecretKind {
    /// Mount ~/.claude/ into the container (rw).
    ClaudeDir,
    /// Inject ANTHROPIC_API_KEY from the OS keyring.
    ClaudeApiKey,
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

    // Resolved secret paths (from keyring, filesystem)
    pub claude_api_key: Option<String>,
    pub claude_dir: Option<PathBuf>,
    pub gh_dir: PathBuf,
    pub git_dir: PathBuf,

    // Custom mounts from project config
    pub custom_mounts: Vec<crate::config::MountConfig>,

    // Image tag (resolved before launch)
    pub image_tag: String,
}

// ---------------------------------------------------------------------------
// Built-in profiles
// ---------------------------------------------------------------------------

/// Forge container for OpenCode (no Claude secrets).
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

/// Forge container for Claude (with Claude dir + API key).
pub fn forge_claude_profile() -> ContainerProfile {
    ContainerProfile {
        entrypoint: "/usr/local/bin/entrypoint-forge-claude.sh",
        working_dir: None,
        mounts: common_forge_mounts(),
        env_vars: common_forge_env(),
        secrets: vec![
            SecretMount {
                kind: SecretKind::ClaudeDir,
            },
            SecretMount {
                kind: SecretKind::ClaudeApiKey,
            },
        ],
        image_override: None,
    }
}

/// Maintenance terminal — fish shell, no agent secrets, no API keys.
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
            ProfileEnvVar {
                name: "GIT_CONFIG_GLOBAL",
                value: EnvValue::Literal(
                    "/home/forge/.config/tillandsias-git/.gitconfig",
                ),
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

// ---------------------------------------------------------------------------
// Shared mount/env definitions
// ---------------------------------------------------------------------------

fn common_forge_mounts() -> Vec<ProfileMount> {
    vec![
        ProfileMount {
            host_key: MountSource::ProjectDir,
            // Container path for project is resolved dynamically (watch root vs subdir)
            container_path: "/home/forge/src",
            mode: MountMode::Rw,
        },
        ProfileMount {
            host_key: MountSource::CacheDir,
            container_path: "/home/forge/.cache/tillandsias",
            mode: MountMode::Rw,
        },
        ProfileMount {
            host_key: MountSource::SecretsSubdir("gh"),
            container_path: "/home/forge/.config/gh",
            mode: MountMode::Ro,
        },
        ProfileMount {
            host_key: MountSource::SecretsSubdir("git"),
            container_path: "/home/forge/.config/tillandsias-git",
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
            name: "GIT_CONFIG_GLOBAL",
            value: EnvValue::Literal("/home/forge/.config/tillandsias-git/.gitconfig"),
        },
        ProfileEnvVar {
            name: "TILLANDSIAS_AGENT",
            value: EnvValue::FromContext(ContextKey::AgentName),
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
        assert!(profile.secrets.is_empty());
        assert_eq!(
            profile.entrypoint,
            "/usr/local/bin/entrypoint-forge-opencode.sh"
        );
    }

    #[test]
    fn forge_claude_has_claude_secrets() {
        let profile = forge_claude_profile();
        assert_eq!(profile.secrets.len(), 2);
        assert!(profile
            .secrets
            .iter()
            .any(|s| matches!(s.kind, SecretKind::ClaudeDir)));
        assert!(profile
            .secrets
            .iter()
            .any(|s| matches!(s.kind, SecretKind::ClaudeApiKey)));
    }

    #[test]
    fn terminal_has_no_secrets() {
        let profile = terminal_profile();
        assert!(profile.secrets.is_empty());
        assert_eq!(
            profile.entrypoint,
            "/usr/local/bin/entrypoint-terminal.sh"
        );
        assert!(matches!(
            profile.working_dir,
            Some(WorkingDir::ProjectSubdir)
        ));
    }

    #[test]
    fn web_has_readonly_mount_only() {
        let profile = web_profile();
        assert!(profile.secrets.is_empty());
        assert!(profile.env_vars.is_empty());
        assert_eq!(profile.mounts.len(), 1);
        assert_eq!(profile.mounts[0].mode, MountMode::Ro);
        assert_eq!(profile.image_override, Some("tillandsias-web:latest"));
    }

    #[test]
    fn forge_profiles_have_four_mounts() {
        let opencode = forge_opencode_profile();
        let claude = forge_claude_profile();
        // project, cache, gh, git
        assert_eq!(opencode.mounts.len(), 4);
        assert_eq!(claude.mounts.len(), 4);
    }

    #[test]
    fn forge_profiles_have_four_env_vars() {
        let opencode = forge_opencode_profile();
        let claude = forge_claude_profile();
        // PROJECT, HOST_OS, GIT_CONFIG_GLOBAL, AGENT
        assert_eq!(opencode.env_vars.len(), 4);
        assert_eq!(claude.env_vars.len(), 4);
    }

    #[test]
    fn terminal_has_three_env_vars() {
        let profile = terminal_profile();
        // PROJECT, HOST_OS, GIT_CONFIG_GLOBAL (no AGENT)
        assert_eq!(profile.env_vars.len(), 3);
    }
}
