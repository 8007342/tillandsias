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
    /// @trace spec:secrets-management, spec:podman-orchestration
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
    /// Opinionated config overlay on tmpfs (ramdisk) for fast reads.
    /// Resolved at launch time from `$XDG_RUNTIME_DIR/tillandsias/config-overlay/`.
    /// Mount is skipped if the tmpfs directory doesn't exist yet.
    /// @trace spec:layered-tools-overlay
    ConfigOverlay,
    /// Per-container log directory.
    /// Resolved at launch time to `~/.local/state/tillandsias/containers/<name>/logs/`.
    /// Each container gets its own isolated log directory mounted RW.
    /// @trace spec:podman-orchestration
    ContainerLogs,
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
///
/// Tokens live exclusively in the host OS keyring (Linux Secret Service,
/// macOS Keychain, Windows Credential Manager). The host reads the keyring
/// at container launch, writes the token to an ephemeral file, and bind-
/// mounts it read-only into the container. The container never sees D-Bus,
/// the keyring, or any host credential beyond this one file.
/// @trace spec:secrets-management, spec:native-secrets-store
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum SecretKind {
    /// Bind-mount the GitHub OAuth token at `/run/secrets/github_token:ro`.
    /// The host writes the token from the OS keyring to `ctx.token_file_path`
    /// before launch and unlinks it when the container stops.
    /// @trace spec:git-mirror-service, spec:secrets-management, spec:native-secrets-store
    GitHubToken,
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

    /// Absolute host path to an ephemeral file holding the GitHub OAuth token.
    ///
    /// Populated by the orchestrator when the profile includes
    /// `SecretKind::GitHubToken` and the host keyring has a token. `None`
    /// means no token is available (login required) or the profile does
    /// not request one. The host is responsible for writing this file with
    /// mode 0600 before launch and unlinking it on container stop.
    /// @trace spec:secrets-management, spec:native-secrets-store
    pub token_file_path: Option<PathBuf>,

    /// When true, containers use localhost port mapping instead of DNS aliases.
    ///
    /// On podman machine (macOS/Windows), the internal enclave network's DNS
    /// doesn't work through gvproxy. Containers can't resolve aliases like
    /// `proxy`, `git-service`, `inference`. Instead, services publish ports
    /// to the host and containers reach them via `localhost:<port>`.
    ///
    /// When true, `build_podman_args()` rewrites enclave service env vars:
    /// - `HTTP_PROXY`/`HTTPS_PROXY` -> `http://localhost:3128`
    /// - `TILLANDSIAS_GIT_SERVICE` -> `localhost`
    /// - `OLLAMA_HOST` -> `http://localhost:11434`
    /// - `NO_PROXY` -> `localhost,127.0.0.1`
    ///
    /// @trace spec:enclave-network
    pub use_port_mapping: bool,

    /// @trace spec:opencode-web-session
    /// If true, skip `--rm` so the container persists after its originating
    /// click. Used by OpenCode Web forge containers.
    pub persistent: bool,

    /// @trace spec:opencode-web-session
    /// If Some(host_port), publish `127.0.0.1:<host_port>:4096` and override
    /// the enclave-only port-skip logic. Mutually exclusive with the legacy
    /// port_range publish — when Some, port_range is ignored.
    pub web_host_port: Option<u16>,
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

// @trace spec:opencode-web-session, spec:default-image
/// Forge container for OpenCode Web (headless HTTP server on :4096; no TTY).
/// Reuses the same mounts and env vars as the CLI OpenCode profile; only the
/// entrypoint differs. `TILLANDSIAS_AGENT` is set to `opencode-web` by the
/// caller's context, which routes to `entrypoint-forge-opencode-web.sh`.
pub fn forge_opencode_web_profile() -> ContainerProfile {
    ContainerProfile {
        entrypoint: "/usr/local/bin/entrypoint-forge-opencode-web.sh",
        working_dir: None,
        mounts: common_forge_mounts(),
        env_vars: common_forge_env(),
        secrets: vec![],
        image_override: None,
        pids_limit: 512,
        read_only: false,
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
            // @trace spec:opencode-web-session, spec:proxy-container
            // NO_PROXY covers loopback variants + every enclave-internal peer so
            // intra-enclave traffic (inference:11434, git-service:9418, proxy
            // self-reach) never hairpins through Squid. Without this, tools like
            // opencode/bun see HTTP_PROXY set and route LOCAL requests through
            // the proxy, which denies them because the destination isn't
            // allowlisted — causing hangs on every inference probe.
            ProfileEnvVar {
                name: "NO_PROXY",
                value: EnvValue::Literal("localhost,127.0.0.1,0.0.0.0,::1,git-service,inference,proxy"),
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
                value: EnvValue::Literal("localhost,127.0.0.1,0.0.0.0,::1,git-service,inference,proxy"),
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
        mounts: vec![
            ProfileMount {
                host_key: MountSource::ProjectDir,
                container_path: "/var/www/html",
                mode: MountMode::Ro,
            },
            // @trace spec:podman-orchestration
            ProfileMount {
                host_key: MountSource::ContainerLogs,
                container_path: "/var/log/tillandsias",
                mode: MountMode::Rw,
            },
        ],
        env_vars: vec![],
        secrets: vec![],
        image_override: Some("tillandsias-web:latest"),
        pids_limit: 32,        // Only httpd
        read_only: true,       // Static file server — no writes needed
        tmpfs_mounts: vec!["/tmp", "/var/run"],
    }
}

/// Router container — Caddy 2 reverse proxy mapping
/// `<project>.<service>.localhost` to enclave containers by name + port.
///
/// Runs Caddy on port 80 inside the enclave (DNS alias `router`) and is
/// host-published only on `127.0.0.1:80` (loopback). The host kernel
/// restricts the listener to loopback; Caddy adds a defence-in-depth
/// `remote_ip` allowlist that rejects any source not on loopback or RFC
/// 1918 private blocks.
///
/// The dynamic Caddyfile is bind-mounted into the container at
/// `/run/router/dynamic.Caddyfile` from
/// `$XDG_RUNTIME_DIR/tillandsias/router/dynamic.Caddyfile` (tmpfs).
/// `handlers::regenerate_router_caddyfile` rewrites it on each attach
/// and signals reload via `caddy reload` over the container's local
/// admin API.
///
/// @trace spec:subdomain-routing-via-reverse-proxy, spec:enclave-network
pub fn router_profile() -> ContainerProfile {
    ContainerProfile {
        entrypoint: "/usr/local/bin/entrypoint.sh",
        working_dir: None,
        mounts: vec![
            // Per-container log directory — Caddy writes access + error logs here.
            // @trace spec:podman-orchestration
            ProfileMount {
                host_key: MountSource::ContainerLogs,
                container_path: "/var/log/tillandsias",
                mode: MountMode::Rw,
            },
            // The dynamic Caddyfile is bind-mounted dynamically by
            // handlers::ensure_router_running so the path includes the
            // tmpfs base resolved at launch time.
        ],
        env_vars: vec![],
        secrets: vec![],
        image_override: None,
        pids_limit: 64,        // Caddy + a single watcher
        // NOT read-only: caddy needs writable /tmp for the merged
        // Caddyfile and /tmp/caddy-storage. Writable root is fine in
        // a single-purpose container with no shell access.
        read_only: false,
        tmpfs_mounts: vec![],
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
            // @trace spec:podman-orchestration
            ProfileMount {
                host_key: MountSource::ContainerLogs,
                container_path: "/var/log/tillandsias",
                mode: MountMode::Rw,
            },
        ],
        env_vars: vec![],
        secrets: vec![],
        image_override: None,
        pids_limit: 32,        // Only squid + helpers
        // NOT read-only: squid needs writable /var/spool/squid (cache),
        // /var/run/squid (PID), /var/log/squid (logs), /var/lib/squid (SSL DB).
        // With --read-only + --tmpfs, the tmpfs dirs are root-owned but squid
        // runs as UID 1000 (proxy) via --userns=keep-id → permission denied.
        // Security comes from cap-drop, pids-limit, and enclave isolation.
        read_only: false,
        tmpfs_mounts: vec![],
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
        mounts: vec![
            // @trace spec:podman-orchestration
            // Model cache mount added dynamically at launch time; log dir from profile.
            ProfileMount {
                host_key: MountSource::ContainerLogs,
                container_path: "/var/log/tillandsias",
                mode: MountMode::Rw,
            },
        ],
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
            // @trace spec:inference-container, spec:proxy-container
            // NO_PROXY is mandatory here: ollama does internal health probes
            // against its own listen address (0.0.0.0:11434, 127.0.0.1:11434)
            // and these would otherwise traverse Squid and be denied — every
            // denied probe delays model readiness. Covering enclave peers
            // ensures any inter-container probe stays inside the network.
            ProfileEnvVar {
                name: "NO_PROXY",
                value: EnvValue::Literal("localhost,127.0.0.1,0.0.0.0,::1,inference,proxy,git-service"),
            },
            ProfileEnvVar {
                name: "no_proxy",
                value: EnvValue::Literal("localhost,127.0.0.1,0.0.0.0,::1,inference,proxy,git-service"),
            },
        ],
        secrets: vec![],  // No credentials needed
        image_override: None,
        pids_limit: 128,       // Ollama server + model runners
        // NOT read-only: ollama needs writable home dir for runtime state,
        // model downloads, and temporary files. Same --userns=keep-id
        // tmpfs ownership issue as squid (UID 1000 can't write root-owned tmpfs).
        read_only: false,
        tmpfs_mounts: vec![],
    }
}

/// Git service container — bare mirror + git daemon + tmpfs GitHub token.
///
/// Runs a local git daemon inside the enclave network. Forge containers clone
/// and fetch from this service instead of hitting the internet directly.
///
/// Mounts: log dir always; mirror volume added dynamically per-project.
/// Credentials: the host writes the GitHub OAuth token (from the OS keyring)
/// to an ephemeral file and bind-mounts it read-only at
/// `/run/secrets/github_token`. The container never sees D-Bus, the host
/// keyring, or any other host secret.
///
/// @trace spec:git-mirror-service, spec:secrets-management, spec:native-secrets-store
pub fn git_service_profile() -> ContainerProfile {
    ContainerProfile {
        entrypoint: "/usr/local/bin/entrypoint.sh",
        working_dir: None,
        mounts: vec![
            // @trace spec:podman-orchestration
            // Mirror volume added dynamically per-project; log dir from profile.
            ProfileMount {
                host_key: MountSource::ContainerLogs,
                container_path: "/var/log/tillandsias",
                mode: MountMode::Rw,
            },
        ],
        env_vars: vec![
            // @trace spec:git-mirror-service, spec:proxy-container
            // The post-receive hook pushes the bare mirror to GitHub via
            // HTTPS. The enclave network has no external DNS or routing —
            // without these proxy vars, `git push origin` fails with
            // "Could not resolve host: github.com" and forge commits are
            // silently stranded in the mirror (data-loss risk: if the
            // mirror container dies before the push succeeds on retry,
            // the commit is gone). Squid's allowlist already admits
            // `.github.com`; ssl_bump is `splice all` so we don't need
            // to inject the CA cert here — HTTPS is a plain CONNECT tunnel.
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
            // Loopback + enclave peers bypass the proxy so intra-service
            // traffic (git-daemon on localhost, any future sidecar) stays
            // local.
            ProfileEnvVar {
                name: "NO_PROXY",
                value: EnvValue::Literal("localhost,127.0.0.1,0.0.0.0,::1,git-service,inference,proxy"),
            },
            ProfileEnvVar {
                name: "no_proxy",
                value: EnvValue::Literal("localhost,127.0.0.1,0.0.0.0,::1,git-service,inference,proxy"),
            },
        ],
        secrets: vec![
            SecretMount {
                kind: SecretKind::GitHubToken,
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
    // Mounts: config overlay (read-only ramdisk) + per-container log dir (RW).
    // The old tools overlay was tombstoned on 2026-04-25 — agents (claude,
    // opencode, openspec) are hard-installed in the forge image under
    // /opt/agents/ with /usr/local/bin/ symlinks.
    // @trace spec:proxy-container, spec:tombstone-tools-overlay, spec:podman-orchestration
    vec![
        // Opinionated configs on ramdisk — entrypoints copy into ~/.config/
        ProfileMount {
            host_key: MountSource::ConfigOverlay,
            container_path: "/home/forge/.config-overlay",
            mode: MountMode::Ro,
        },
        // Per-container log directory — each container writes its own logs in isolation.
        // @trace spec:podman-orchestration
        ProfileMount {
            host_key: MountSource::ContainerLogs,
            container_path: "/var/log/tillandsias",
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
        // @trace spec:opencode-web-session, spec:proxy-container
        // NO_PROXY lists every enclave-internal destination (loopback variants
        // + service names) so intra-enclave traffic never hairpins through
        // Squid. Without this, tools like opencode/bun see HTTP_PROXY set and
        // route local requests through the proxy, which denies them because
        // the destination isn't allowlisted — causing hangs on every
        // inference probe. Applies to every forge variant.
        ProfileEnvVar {
            name: "NO_PROXY",
            value: EnvValue::Literal("localhost,127.0.0.1,0.0.0.0,::1,git-service,inference,proxy"),
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
            value: EnvValue::Literal("localhost,127.0.0.1,0.0.0.0,::1,git-service,inference,proxy"),
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
    fn web_has_readonly_mount_and_logs() {
        let profile = web_profile();
        assert!(profile.secrets.is_empty(), "Web profile should have no secrets");
        assert!(profile.env_vars.is_empty());
        assert_eq!(profile.mounts.len(), 2, "Web has project mount + container logs");
        assert_eq!(profile.mounts[0].mode, MountMode::Ro);
        assert!(matches!(profile.mounts[1].host_key, MountSource::ContainerLogs));
        assert_eq!(profile.mounts[1].container_path, "/var/log/tillandsias");
        assert_eq!(profile.mounts[1].mode, MountMode::Rw);
        assert_eq!(profile.image_override, Some("tillandsias-web:latest"));
    }

    // @trace spec:tombstone-tools-overlay, spec:podman-orchestration
    #[test]
    fn forge_profiles_have_no_tools_overlay_mount() {
        let opencode = forge_opencode_profile();
        let claude = forge_claude_profile();
        // Mounts: config overlay (read-only) + container logs (RW). Tools
        // overlay was tombstoned 2026-04-25 — agents are hard-installed.
        assert_eq!(opencode.mounts.len(), 2);
        assert_eq!(claude.mounts.len(), 2);
        assert!(
            !opencode.mounts.iter().any(|m| m.container_path == "/home/forge/.tools"),
            "No profile should mount the tools overlay — tombstoned"
        );
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

    // @trace spec:git-mirror-service, spec:secrets-management, spec:podman-orchestration
    #[test]
    fn git_service_has_github_token_and_log_mount() {
        let profile = git_service_profile();
        assert_eq!(
            profile.secrets.len(),
            1,
            "Git service should request GitHubToken only (host keyring → tmpfs mount)"
        );
        assert!(
            profile
                .secrets
                .iter()
                .any(|s| s.kind == SecretKind::GitHubToken),
            "Git service must request GitHubToken for authenticated push/fetch"
        );
        // Only static mount is ContainerLogs — mirror volume added dynamically per-project
        assert_eq!(
            profile.mounts.len(),
            1,
            "Git service has only the ContainerLogs mount (mirror added dynamically)"
        );
        assert!(
            matches!(profile.mounts[0].host_key, MountSource::ContainerLogs),
            "Git service mount must be ContainerLogs"
        );
        assert_eq!(profile.mounts[0].container_path, "/var/log/tillandsias");
        assert_eq!(profile.mounts[0].mode, MountMode::Rw);
        // Git service has HTTP(S)_PROXY + NO_PROXY env vars so the post-receive
        // retry-push can reach github.com through the enclave proxy.
        // @trace spec:git-mirror-service, spec:proxy-container
        assert!(
            profile.env_vars.iter().any(|e| e.name == "HTTPS_PROXY"),
            "Git service needs HTTPS_PROXY for post-receive push to github.com"
        );
        assert!(
            profile.env_vars.iter().any(|e| e.name == "NO_PROXY"),
            "Git service needs NO_PROXY to bypass proxy for enclave peers"
        );
        assert!(
            profile.image_override.is_none(),
            "Git service image tag comes from LaunchContext"
        );
        assert_eq!(profile.entrypoint, "/usr/local/bin/entrypoint.sh");
    }

    // @trace spec:inference-container, spec:podman-orchestration
    #[test]
    fn inference_has_proxy_env_vars_no_secrets_with_log_mount() {
        let profile = inference_profile();
        assert!(profile.secrets.is_empty(), "Inference must have no secrets");
        // Only static mount is ContainerLogs — model cache added dynamically at launch time
        assert_eq!(
            profile.mounts.len(),
            1,
            "Inference has only the ContainerLogs mount (model cache added dynamically)"
        );
        assert!(
            matches!(profile.mounts[0].host_key, MountSource::ContainerLogs),
            "Inference mount must be ContainerLogs"
        );
        assert_eq!(profile.mounts[0].container_path, "/var/log/tillandsias");
        assert_eq!(profile.mounts[0].mode, MountMode::Rw);
        // @trace spec:inference-container, spec:proxy-container
        // 6 proxy env vars: HTTP_PROXY, HTTPS_PROXY, http_proxy, https_proxy,
        // NO_PROXY, no_proxy. NO_PROXY is required so ollama's loopback probes
        // don't hairpin through Squid (which would deny them).
        assert_eq!(
            profile.env_vars.len(),
            6,
            "Inference should have 6 proxy env vars (4 proxy + 2 bypass)"
        );
        assert!(
            profile.env_vars.iter().any(|e| e.name == "HTTP_PROXY"),
            "Inference must have HTTP_PROXY"
        );
        assert!(
            profile.env_vars.iter().any(|e| e.name == "https_proxy"),
            "Inference must have https_proxy"
        );
        let no_proxy = profile
            .env_vars
            .iter()
            .find(|e| e.name == "NO_PROXY")
            .expect("Inference must have NO_PROXY");
        if let EnvValue::Literal(v) = no_proxy.value {
            assert!(
                v.contains("0.0.0.0") && v.contains("127.0.0.1") && v.contains("localhost"),
                "NO_PROXY must cover loopback; got: {v}"
            );
        } else {
            panic!("NO_PROXY must be a literal");
        }
        assert!(
            profile.image_override.is_none(),
            "Inference image tag comes from LaunchContext"
        );
        assert_eq!(profile.entrypoint, "/usr/local/bin/entrypoint.sh");
    }

    // @trace spec:proxy-container, spec:enclave-network, spec:podman-orchestration
    #[test]
    fn proxy_has_no_secrets_no_env_vars() {
        let profile = proxy_profile();
        assert!(profile.secrets.is_empty(), "Proxy must have no secrets");
        assert!(profile.env_vars.is_empty(), "Proxy is a passive service — no env vars");
        assert_eq!(profile.mounts.len(), 2, "Proxy has cache mount + container logs");
        assert_eq!(profile.mounts[0].container_path, "/var/spool/squid");
        assert_eq!(profile.mounts[0].mode, MountMode::Rw);
        assert!(matches!(profile.mounts[1].host_key, MountSource::ContainerLogs));
        assert_eq!(profile.mounts[1].container_path, "/var/log/tillandsias");
        assert_eq!(profile.mounts[1].mode, MountMode::Rw);
        assert!(profile.image_override.is_none(), "Proxy image tag comes from LaunchContext");
    }

    // @trace spec:tombstone-tools-overlay, spec:default-image
    #[test]
    fn agents_are_hard_installed_paths() {
        // After the tombstone of the runtime tools overlay, agents live at
        // /usr/local/bin/ (symlinked from /opt/agents/...) — baked into the
        // forge image at build time per images/default/Containerfile.
        // No profile mount targets /home/forge/.tools anymore.
        let profile = forge_opencode_profile();
        assert!(
            !profile.mounts.iter().any(|m| m.container_path == "/home/forge/.tools"),
            "Profiles must not mount the old tools overlay — agents are image-baked"
        );
    }

    // @trace spec:podman-orchestration, spec:secrets-management
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

    // @trace spec:podman-orchestration, spec:secrets-management
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
        // Proxy and inference are NOT read-only — they need writable runtime dirs.
        // With --userns=keep-id, tmpfs dirs are root-owned but process runs as UID 1000.
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
        // Only git_service and web are read-only.
        // Proxy and inference need writable dirs (--userns=keep-id tmpfs ownership issue).
        let profiles = [
            ("git_service", git_service_profile()),
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
    fn proxy_is_not_read_only() {
        // Proxy needs writable /var/spool/squid, /var/run/squid, /var/log/squid,
        // /var/lib/squid. With --read-only + --tmpfs, dirs are root-owned but
        // squid runs as UID 1000 via --userns=keep-id → permission denied.
        let profile = proxy_profile();
        assert!(!profile.read_only, "Proxy must NOT be read-only (squid needs writable runtime dirs)");
    }

    // @trace spec:podman-orchestration
    #[test]
    fn all_profiles_have_container_logs_mount() {
        let profiles: Vec<(&str, ContainerProfile)> = vec![
            ("forge_opencode", forge_opencode_profile()),
            ("forge_claude", forge_claude_profile()),
            ("terminal", terminal_profile()),
            ("web", web_profile()),
            ("proxy", proxy_profile()),
            ("inference", inference_profile()),
            ("git_service", git_service_profile()),
        ];

        for (name, profile) in &profiles {
            let has_log_mount = profile.mounts.iter().any(|m| {
                matches!(m.host_key, MountSource::ContainerLogs)
                    && m.container_path == "/var/log/tillandsias"
                    && m.mode == MountMode::Rw
            });
            assert!(
                has_log_mount,
                "Profile {name} must have a ContainerLogs mount at /var/log/tillandsias (RW)"
            );
        }
    }
}
