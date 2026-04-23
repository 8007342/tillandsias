//! Single entry point for building podman run arguments from container profiles.
//!
//! Replaces the duplicated arg-building code in `handlers.rs` and `runner.rs`.
//! All container types (forge-opencode, forge-claude, terminal, web) use
//! `build_podman_args()` with the appropriate profile and context.
//!
//! # Security
//!
//! Non-negotiable security flags are hardcoded in `build_podman_args()` and
//! are never read from profiles, config, or any external source. The only
//! way to change them is to modify this source file.
//!
//! @trace spec:podman-orchestration, spec:environment-runtime

use std::path::Path;

use tillandsias_core::container_profile::{
    ContainerProfile, ContextKey, EnvValue, LaunchContext, MountSource, SecretKind, WorkingDir,
};

/// Build the `podman run` argument list from a declarative profile and launch context.
///
/// The returned `Vec<String>` is ready to pass to `podman run` (without the
/// `run` subcommand itself).
///
/// Security flags are unconditionally prepended — profiles cannot disable them.
pub fn build_podman_args(profile: &ContainerProfile, ctx: &LaunchContext) -> Vec<String> {
    let mut args = Vec::with_capacity(48);

    // -----------------------------------------------------------------------
    // Interaction mode
    // -----------------------------------------------------------------------
    if ctx.detached {
        args.push("-d".into());
    } else {
        args.push("-it".into());
    }

    // -----------------------------------------------------------------------
    // Non-negotiable security flags (hardcoded, NEVER from profile)
    // @trace spec:podman-orchestration/security-hardened-defaults, knowledge:infra/podman-security
    // -----------------------------------------------------------------------
    // @trace spec:opencode-web-session
    // Persistent containers (OpenCode Web) deliberately omit `--rm` so they
    // survive the originating click. `-d` is still applied when `ctx.detached`.
    if !ctx.persistent {
        args.push("--rm".into());
    }
    args.push("--init".into());
    args.push("--stop-timeout=10".into());
    args.push("--name".into());
    args.push(ctx.container_name.clone());
    args.push("--cap-drop=ALL".into());
    args.push("--security-opt=no-new-privileges".into());
    args.push("--userns=keep-id".into());
    args.push("--security-opt=label=disable".into());

    // -----------------------------------------------------------------------
    // Process limit — prevents fork bombs, constrains each container to its
    // intended workload. Values are set per-profile in container_profile.rs.
    // @trace spec:podman-orchestration, spec:secrets-management
    // -----------------------------------------------------------------------
    args.push(format!("--pids-limit={}", profile.pids_limit));

    // -----------------------------------------------------------------------
    // Read-only root filesystem — service containers (git, proxy, inference,
    // web) run with immutable root FS. Runtime dirs get explicit tmpfs mounts.
    // Forge/terminal containers need mutable workspace and skip this.
    // @trace spec:podman-orchestration
    // -----------------------------------------------------------------------
    if profile.read_only {
        args.push("--read-only".into());
        for tmpfs_path in &profile.tmpfs_mounts {
            args.push(format!("--tmpfs={tmpfs_path}"));
        }
    }

    // -----------------------------------------------------------------------
    // GPU passthrough (Linux only)
    // @trace spec:podman-orchestration/gpu-passthrough
    // -----------------------------------------------------------------------
    if cfg!(target_os = "linux") {
        for flag in tillandsias_podman::detect_gpu_devices() {
            args.push(flag);
        }
    }

    // -----------------------------------------------------------------------
    // Network (enclave or dual-homed)
    // @trace spec:enclave-network, spec:proxy-container
    // -----------------------------------------------------------------------
    if let Some(ref net) = ctx.network {
        args.push(format!("--network={net}"));
    }

    // -----------------------------------------------------------------------
    // Port range — skipped for enclave-only containers (they communicate
    // through the internal network, not host ports). Only expose ports for
    // containers with no network (legacy) or dual-homed containers.
    // @trace spec:enclave-network, spec:proxy-container
    // -----------------------------------------------------------------------
    let is_enclave_only = ctx.network.as_deref().is_some_and(|n| {
        // Enclave-only if network starts with the enclave name and doesn't include
        // a second network (comma-separated means dual-homed, e.g., "enclave:alias=proxy,podman")
        let enclave = tillandsias_podman::ENCLAVE_NETWORK;
        n.starts_with(enclave) && !n.contains(',')
    });
    // @trace spec:opencode-web-session
    // OpenCode Web joins the enclave but MUST publish a loopback-only host
    // port so the Tauri webview (running on the host) can reach the server.
    // When `web_host_port` is Some, emit a single-port publish bound to
    // 127.0.0.1 and skip the legacy range publish entirely — overrides the
    // enclave-only skip above.
    if let Some(p) = ctx.web_host_port {
        if ctx.port_range != (0, 0) {
            tracing::debug!(
                container = %ctx.container_name,
                web_host_port = p,
                port_range = ?ctx.port_range,
                "web_host_port set alongside port_range; ignoring port_range to avoid double-publish"
            );
        }
        args.push("-p".into());
        args.push(format!("127.0.0.1:{}:4096", p));
    } else if ctx.port_range != (0, 0) && !is_enclave_only {
        args.push("-p".into());
        args.push(format!(
            "{}-{}:{}-{}",
            ctx.port_range.0, ctx.port_range.1, ctx.port_range.0, ctx.port_range.1
        ));
    }

    // -----------------------------------------------------------------------
    // Entrypoint
    // -----------------------------------------------------------------------
    args.push("--entrypoint".into());
    args.push(profile.entrypoint.to_string());

    // -----------------------------------------------------------------------
    // Working directory
    // -----------------------------------------------------------------------
    if let Some(ref wd) = profile.working_dir {
        let dir = match wd {
            WorkingDir::ProjectSubdir => {
                format!("/home/forge/src/{}", ctx.project_name)
            }
            WorkingDir::SrcRoot => "/home/forge/src".to_string(),
        };
        args.push("-w".into());
        args.push(dir);
    }

    // -----------------------------------------------------------------------
    // Environment variables (resolved from context)
    // -----------------------------------------------------------------------
    for env_var in &profile.env_vars {
        let value = match &env_var.value {
            EnvValue::FromContext(key) => match key {
                ContextKey::ProjectName => ctx.project_name.clone(),
                ContextKey::HostOs => ctx.host_os.clone(),
                // @trace spec:opencode-web-session, spec:environment-runtime
                ContextKey::AgentName => {
                    // The agent name is derived from which profile is used;
                    // forge-opencode-web -> "opencode-web", forge-opencode -> "opencode",
                    // forge-claude -> "claude". We infer it from the entrypoint to keep
                    // profiles self-contained. Most-specific substring wins — the
                    // `opencode-web` arm MUST come before `opencode` because the web
                    // entrypoint path also contains the substring `opencode`.
                    if profile.entrypoint.contains("opencode-web") {
                        "opencode-web".to_string()
                    } else if profile.entrypoint.contains("opencode") {
                        "opencode".to_string()
                    } else {
                        "claude".to_string()
                    }
                }
                // @trace spec:environment-runtime
                ContextKey::Language => {
                    tillandsias_core::config::language_to_lang_value(&ctx.selected_language).to_string()
                }
                ContextKey::GitAuthorName => ctx.git_author_name.clone(),
                ContextKey::GitAuthorEmail => ctx.git_author_email.clone(),
            },
            EnvValue::Literal(s) => {
                // @trace spec:enclave-network
                // On podman machine (macOS/Windows), rewrite enclave DNS aliases
                // to localhost. Internal network DNS doesn't work through gvproxy,
                // so services publish ports to the host and containers reach them
                // via localhost:<port> instead.
                if ctx.use_port_mapping {
                    rewrite_enclave_env(env_var.name, s)
                } else {
                    s.to_string()
                }
            }
        };
        // @trace spec:git-mirror-service
        // Skip git identity vars when empty — git treats `GIT_AUTHOR_NAME=""`
        // as an explicit empty name and refuses to commit with "empty ident
        // name not allowed", even when [user] is set in a gitconfig. If we
        // cannot resolve the identity, let git use its own resolution chain
        // inside the container (entrypoint sets config from whatever we pass
        // as non-empty; if we pass nothing, it'll error loudly only on commit,
        // with a clear message).
        let is_git_identity = matches!(
            env_var.value,
            EnvValue::FromContext(ContextKey::GitAuthorName)
                | EnvValue::FromContext(ContextKey::GitAuthorEmail)
        );
        if is_git_identity && value.is_empty() {
            continue;
        }
        args.push("-e".into());
        args.push(format!("{}={}", env_var.name, value));
    }

    // -----------------------------------------------------------------------
    // Host aliases for podman machine (Windows/macOS)
    // @trace spec:enclave-network, spec:cross-platform, spec:fix-podman-machine-host-aliases
    //
    // On podman machine, the enclave-network DNS doesn't work through gvproxy,
    // so the four enclave services publish ports to the host (-p 3128:3128,
    // -p 9418:9418, -p 11434:11434). Other containers reach those ports via
    // the *host gateway* — NOT via 127.0.0.1, which inside a container points
    // at the container's own loopback (where nothing is listening).
    //
    // `host-gateway` is the magic value Podman/Docker resolve to the host
    // gateway IP at runtime (169.254.1.2 on this WSL setup). Combined with
    // --add-host, friendly service names (`proxy`, `git-service`, `inference`)
    // resolve correctly inside the container without env-var rewriting:
    // entrypoints can use `git clone git://git-service:9418/...` exactly as
    // they would on Linux with the enclave network.
    // -----------------------------------------------------------------------
    if ctx.use_port_mapping {
        for alias in ["proxy", "git-service", "inference"] {
            args.push("--add-host".into());
            args.push(format!("{alias}:host-gateway"));
        }
    }

    // -----------------------------------------------------------------------
    // Volume mounts (resolved from context)
    // @trace spec:podman-orchestration/volume-mount-strategy
    // -----------------------------------------------------------------------
    for mount in &profile.mounts {
        let host_path = match resolve_mount_source(&mount.host_key, ctx) {
            Some(p) => p,
            None => continue, // Skip mount — source doesn't exist yet
        };
        let container_path =
            resolve_container_path(mount.container_path, mount.host_key.clone(), ctx);
        args.push("-v".into());
        args.push(format!(
            "{}:{}:{}",
            host_path,
            container_path,
            mount.mode.as_str()
        ));
    }

    // -----------------------------------------------------------------------
    // Secret mounts (only present for profiles that declare them)
    //
    // The host has already read the GitHub token from the OS keyring and
    // written it to `ctx.token_file_path`. We bind-mount that file read-only
    // at the fixed in-container path `/run/secrets/github_token`. If the
    // context carries no path (no token in keyring → user not logged in),
    // the mount is skipped; git operations requiring auth will fail loudly.
    // The host is responsible for unlinking the file when the container stops.
    // @trace spec:secrets-management, spec:native-secrets-store
    // -----------------------------------------------------------------------
    for secret in &profile.secrets {
        match &secret.kind {
            SecretKind::GitHubToken => {
                if let Some(ref token_file) = ctx.token_file_path {
                    args.push("-v".into());
                    args.push(format!("{}:/run/secrets/github_token:ro", token_file.display()));
                    args.push("-e".into());
                    args.push("GIT_ASKPASS=/usr/local/bin/git-askpass-tillandsias.sh".into());

                    tracing::info!(
                        accountability = true,
                        category = "secrets",
                        safety = "GitHub token bind-mounted :ro from host keyring; container sees only this file, no D-Bus, no keyring API",
                        spec = "secrets-management",
                        container = %ctx.container_name,
                        "Credential isolation boundary: GitHub token delivered via ephemeral tmpfs file"
                    );
                } else {
                    tracing::warn!(
                        accountability = true,
                        category = "secrets",
                        spec = "secrets-management",
                        container = %ctx.container_name,
                        "Container requested GitHubToken but no token is available in host keyring — authenticated git operations will fail"
                    );
                }
            }
        }
    }

    // -----------------------------------------------------------------------
    // Custom mounts from project config (appended after profile mounts)
    // -----------------------------------------------------------------------
    for mount in &ctx.custom_mounts {
        args.push("-v".into());
        args.push(format!("{}:{}:{}", mount.host, mount.container, mount.mode));
    }

    // -----------------------------------------------------------------------
    // Image tag (always last)
    // -----------------------------------------------------------------------
    let image = profile
        .image_override
        .map(|s| s.to_string())
        .unwrap_or_else(|| ctx.image_tag.clone());
    args.push(image);

    args
}

/// Shell-quote a podman argument list into a single command string.
///
/// Arguments containing spaces, quotes, or special characters are wrapped in
/// single quotes with interior single quotes escaped. Arguments without special
/// characters pass through unquoted for readability.
///
/// Used when constructing command strings for `open_terminal()` which passes
/// the command to a shell (e.g., `bash -c` or `ptyxis -x`).
pub fn shell_quote_join(args: &[String]) -> String {
    args.iter()
        .map(|arg| {
            if arg.is_empty() {
                if cfg!(target_os = "windows") {
                    "\"\"".to_string()
                } else {
                    "''".to_string()
                }
            } else if arg
                .chars()
                .all(|c| c.is_ascii_alphanumeric() || "-_=:/.@+,".contains(c))
            {
                arg.clone()
            } else if cfg!(target_os = "windows") {
                // Windows cmd.exe uses double quotes, not single quotes.
                // Escape interior double quotes by doubling them.
                format!("\"{}\"", arg.replace('"', "\"\""))
            } else {
                // Unix: single quotes, escape interior single quotes
                format!("'{}'", arg.replace('\'', "'\\''"))
            }
        })
        .collect::<Vec<_>>()
        .join(" ")
}

/// Rewrite enclave service env var values for podman machine.
///
/// Historically this function rewrote `proxy`, `git-service`, and `inference`
/// hostnames to `localhost` because the enclave-network DNS doesn't work
/// through gvproxy on podman machine (Windows/macOS). That broke connectivity
/// inside containers — `localhost:<port>` from inside a container is the
/// container's own loopback, not the host where the published ports live.
///
/// As of `fix-podman-machine-host-aliases`, the friendly hostnames resolve
/// via `--add-host alias:host-gateway` injected in `build_podman_args`. This
/// function therefore passes through unchanged on podman machine — entrypoints
/// can use `proxy:3128`, `git-service:9418`, `inference:11434` exactly as
/// they would on Linux with the real enclave network.
///
/// We keep the function and its call site so the rewrite hook is available
/// if a future setup needs it (e.g. native podman with no gvproxy).
///
/// @trace spec:enclave-network, spec:fix-podman-machine-host-aliases
fn rewrite_enclave_env(_name: &str, original: &str) -> String {
    original.to_string()
}

/// Resolve a logical mount source to an absolute host path.
///
/// Returns `None` when the source does not exist yet (e.g., tools overlay
/// not built). The caller skips the mount in that case.
/// @trace spec:layered-tools-overlay
fn resolve_mount_source(source: &MountSource, ctx: &LaunchContext) -> Option<String> {
    match source {
        MountSource::ProjectDir => Some(ctx.project_path.display().to_string()),
        MountSource::CacheDir => Some(ctx.cache_dir.display().to_string()),
        // @trace spec:layered-tools-overlay, spec:tools-overlay-fast-reuse, spec:overlay-mount-cache
        // Fast-path: process-lifetime snapshot cache. The cache is populated
        // by `ensure_tools_overlay()` which is awaited in `handle_attach_here`
        // BEFORE `build_podman_args` (the function that calls us), so this
        // should always hit on the warm path.
        //
        // Defensive fallback: if the snapshot was invalidated mid-launch
        // (race with a background rebuild) or the user is on a code path
        // that bypassed `ensure_tools_overlay`, fall back to the original
        // `exists()` check. Entrypoints additionally fall back to inline
        // install if no mount is provided at all.
        MountSource::ToolsOverlay => {
            if let Some(path) = crate::tools_overlay::cached_overlay_for(
                &crate::handlers::forge_image_tag(),
            ) {
                Some(path.display().to_string())
            } else {
                let overlay_path = ctx.cache_dir
                    .join("tools-overlay")
                    .join("current");
                if overlay_path.exists() {
                    Some(overlay_path.display().to_string())
                } else {
                    None
                }
            }
        }
        // @trace spec:layered-tools-overlay
        // Configs live on tmpfs (ramdisk) for fast reads — zero disk I/O.
        MountSource::ConfigOverlay => {
            let base = if let Ok(xdg) = std::env::var("XDG_RUNTIME_DIR") {
                std::path::PathBuf::from(xdg)
            } else {
                std::env::temp_dir()
            };
            let overlay_path = base
                .join("tillandsias")
                .join("config-overlay");
            if overlay_path.exists() {
                Some(overlay_path.display().to_string())
            } else {
                None // Skip mount — entrypoints will use defaults
            }
        }
        // @trace spec:podman-orchestration
        // Per-container log directory — each container writes its own logs.
        MountSource::ContainerLogs => {
            let log_path = tillandsias_core::config::container_log_dir(&ctx.container_name);
            // Create the directory if missing — podman fails with
            // "no such file or directory" if the mount source doesn't exist.
            if let Err(e) = std::fs::create_dir_all(&log_path) {
                tracing::warn!(
                    container = %ctx.container_name,
                    error = %e,
                    "Failed to create container log directory"
                );
            }
            Some(log_path.display().to_string())
        }
    }
}

/// Resolve the container path, handling the project mount's watch-root vs subdir logic.
fn resolve_container_path(
    base_container_path: &str,
    source: MountSource,
    ctx: &LaunchContext,
) -> String {
    if let MountSource::ProjectDir = source {
        if ctx.is_watch_root {
            // Mount watch root directly at /home/forge/src
            base_container_path.to_string()
        } else {
            // Mount project as a subdirectory: /home/forge/src/<project_name>
            format!("{}/{}", base_container_path, ctx.project_name)
        }
    } else {
        base_container_path.to_string()
    }
}

/// Read git author name and email.
///
/// Precedence:
///   1. `<cache_dir>/secrets/git/.gitconfig` (Tillandsias-managed, set via
///      `tillandsias --github-login` or the manual identity prompt)
///   2. `~/.gitconfig` (the user's host git config, same on all platforms)
///
/// Returns `("", "")` when neither source has a `[user]` name/email. The
/// caller MUST treat empty values as "do not inject GIT_AUTHOR_* env vars"
/// — empty strings cause git to abort with "empty ident name not allowed".
/// @trace spec:git-mirror-service
pub fn read_git_identity(cache_dir: &Path) -> (String, String) {
    let cache_gitconfig = cache_dir.join("secrets").join("git").join(".gitconfig");
    let (mut name, mut email) = parse_user_from_gitconfig(&cache_gitconfig);

    // Host fallback — identical across Linux/macOS/Windows.
    if (name.is_empty() || email.is_empty())
        && let Some(home) = dirs::home_dir()
    {
        let (host_name, host_email) = parse_user_from_gitconfig(&home.join(".gitconfig"));
        if name.is_empty() {
            name = host_name;
        }
        if email.is_empty() {
            email = host_email;
        }
    }

    // Sanitize to prevent command injection via env vars.
    // Rust's Command API doesn't use a shell, but defense-in-depth
    // strips control chars and suspicious sequences.
    // @trace spec:podman-orchestration
    (sanitize_identity(&name), sanitize_identity(&email))
}

/// Parse `[user] name = ... / email = ...` out of a gitconfig-style file.
/// Returns `("", "")` on any error (missing file, unparseable, missing fields).
fn parse_user_from_gitconfig(path: &Path) -> (String, String) {
    let content = match std::fs::read_to_string(path) {
        Ok(c) => c,
        Err(_) => return (String::new(), String::new()),
    };

    let mut name = String::new();
    let mut email = String::new();
    let mut in_user_section = false;

    for line in content.lines() {
        let trimmed = line.trim();
        if trimmed.starts_with('[') {
            in_user_section = trimmed == "[user]";
            continue;
        }
        if in_user_section {
            if let Some(val) = trimmed.strip_prefix("name") {
                if let Some(val) = val.trim_start().strip_prefix('=') {
                    name = val.trim().to_string();
                }
            } else if let Some(val) = trimmed.strip_prefix("email") {
                if let Some(val) = val.trim_start().strip_prefix('=') {
                    email = val.trim().to_string();
                }
            }
        }
    }

    (name, email)
}

/// Strip potentially dangerous characters from user identity strings.
/// Allows Unicode letters, numbers, spaces, and common name/email chars.
/// @trace spec:podman-orchestration
fn sanitize_identity(input: &str) -> String {
    input
        .chars()
        .filter(|c| {
            // Allow printable chars, reject control chars and shell metacharacters
            !c.is_control()
                && *c != ';'
                && *c != '|'
                && *c != '&'
                && *c != '`'
                && *c != '$'
                && *c != '\\'
                && *c != '"'
                && *c != '\''
        })
        .take(256) // max length
        .collect()
}

/// Ensure the git secrets directory exists and return its path.
///
/// Creates `secrets/git/` under the cache dir and ensures the `.gitconfig`
/// file exists inside it. This directory holds ONLY the git commit-identity
/// config; GitHub OAuth tokens live in the OS keyring.
///
/// @trace spec:native-secrets-store
#[allow(dead_code)] // API surface — used by GitHub login and secrets mount flows
pub fn ensure_secrets_dirs(cache_dir: &Path) -> std::path::PathBuf {
    let secrets_dir = cache_dir.join("secrets");
    let git_dir = secrets_dir.join("git");

    std::fs::create_dir_all(&git_dir).ok();

    // Ensure .gitconfig FILE exists inside the git dir
    let gitconfig_path = git_dir.join(".gitconfig");
    if !gitconfig_path.exists() {
        std::fs::File::create(&gitconfig_path).ok();
    }

    git_dir
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

#[cfg(test)]
mod tests {
    use super::*;
    use std::path::PathBuf;
    use tillandsias_core::container_profile;

    fn test_context() -> LaunchContext {
        LaunchContext {
            container_name: "tillandsias-myproject-aeranthos".into(),
            project_path: PathBuf::from("/home/user/src/myproject"),
            project_name: "myproject".into(),
            cache_dir: PathBuf::from("/home/user/.cache/tillandsias"),
            port_range: (3000, 3019),
            host_os: "Fedora Silverblue 43".into(),
            detached: false,
            is_watch_root: false,
            custom_mounts: vec![],
            image_tag: "tillandsias-forge:v0.1.90".into(),
            selected_language: "en".into(),
            network: None,
            git_author_name: "Test User".into(),
            git_author_email: "test@example.com".into(),
            token_file_path: None,
            use_port_mapping: false,
            persistent: false,
            web_host_port: None,
        }
    }

    #[test]
    fn security_flags_always_present() {
        let profiles = [
            container_profile::forge_opencode_profile(),
            container_profile::forge_claude_profile(),
            container_profile::terminal_profile(),
            container_profile::web_profile(),
        ];

        for profile in &profiles {
            let args = build_podman_args(profile, &test_context());
            assert!(
                args.contains(&"--cap-drop=ALL".to_string()),
                "Missing --cap-drop=ALL"
            );
            assert!(args.contains(&"--security-opt=no-new-privileges".to_string()));
            assert!(args.contains(&"--userns=keep-id".to_string()));
            assert!(args.contains(&"--security-opt=label=disable".to_string()));
            assert!(args.contains(&"--rm".to_string()));
            assert!(args.contains(&"--init".to_string()));
            assert!(args.contains(&"--stop-timeout=10".to_string()));
            // pids-limit must always be present
            assert!(
                args.iter().any(|a| a.starts_with("--pids-limit=")),
                "Missing --pids-limit"
            );
        }
    }

    #[test]
    fn forge_opencode_has_no_secrets() {
        let profile = container_profile::forge_opencode_profile();
        let args = build_podman_args(&profile, &test_context());
        let joined = args.join(" ");
        // No token mount, no GIT_ASKPASS
        assert!(!joined.contains("/run/secrets/github_token"));
        assert!(!joined.contains("GIT_ASKPASS"));
        // No Claude secrets
        assert!(!joined.contains("ANTHROPIC_API_KEY"));
        assert!(!joined.contains(".claude:rw"));
        // Has git identity env vars instead
        assert!(joined.contains("GIT_AUTHOR_NAME=Test User"));
        assert!(joined.contains("GIT_AUTHOR_EMAIL=test@example.com"));
    }

    #[test]
    fn forge_claude_has_no_secrets() {
        let profile = container_profile::forge_claude_profile();
        let args = build_podman_args(&profile, &test_context());
        let joined = args.join(" ");
        // No token mount, no Claude dir mount
        assert!(!joined.contains("/run/secrets/github_token"));
        assert!(!joined.contains("GIT_ASKPASS"));
        assert!(!joined.contains("ANTHROPIC_API_KEY"));
        assert!(!joined.contains(".claude:rw"));
    }

    #[test]
    fn terminal_has_no_secrets() {
        let profile = container_profile::terminal_profile();
        let args = build_podman_args(&profile, &test_context());
        let joined = args.join(" ");
        // No token mount, no GIT_ASKPASS
        assert!(!joined.contains("/run/secrets/github_token"));
        assert!(!joined.contains("GIT_ASKPASS"));
        // No Claude secrets
        assert!(!joined.contains("ANTHROPIC_API_KEY"));
        assert!(!joined.contains(".claude:rw"));
        // Has git identity env vars
        assert!(joined.contains("GIT_AUTHOR_NAME=Test User"));
    }

    #[test]
    fn web_minimal_mounts() {
        let profile = container_profile::web_profile();
        let args = build_podman_args(&profile, &test_context());
        let joined = args.join(" ");
        // Web gets only the project mount (read-only at /var/www/html)
        assert!(joined.contains("/home/user/src/myproject:/var/www/html/myproject:ro"));
        // No cache, no gh, no git
        assert!(!joined.contains(".cache/tillandsias"));
        assert!(!joined.contains(".config/gh"));
        assert!(!joined.contains("tillandsias-git"));
        // No GitHub token mount
        assert!(!joined.contains("/run/secrets/github_token"));
        assert!(!joined.contains("GIT_ASKPASS"));
        // Uses override image
        assert!(joined.contains("tillandsias-web:latest"));
    }

    #[test]
    fn detached_mode_uses_d_flag() {
        let profile = container_profile::forge_opencode_profile();
        let mut ctx = test_context();
        ctx.detached = true;
        let args = build_podman_args(&profile, &ctx);
        assert!(args.contains(&"-d".to_string()));
        assert!(!args.contains(&"-it".to_string()));
    }

    #[test]
    fn interactive_mode_uses_it_flag() {
        let profile = container_profile::forge_opencode_profile();
        let args = build_podman_args(&profile, &test_context());
        assert!(args.contains(&"-it".to_string()));
        assert!(!args.contains(&"-d".to_string()));
    }

    #[test]
    fn watch_root_mounts_at_src_for_web() {
        // Forge profiles no longer have project dir mount (code comes from git mirror).
        // Test with web profile which still has the project dir mount.
        let profile = container_profile::web_profile();
        let mut ctx = test_context();
        ctx.is_watch_root = true;
        let args = build_podman_args(&profile, &ctx);
        let joined = args.join(" ");
        // Should mount at /var/www/html, NOT /var/www/html/myproject
        assert!(joined.contains("/home/user/src/myproject:/var/www/html:ro"));
    }

    #[test]
    fn forge_has_no_project_dir_mount() {
        let profile = container_profile::forge_opencode_profile();
        let ctx = test_context();
        let args = build_podman_args(&profile, &ctx);
        let joined = args.join(" ");
        // Forge profiles no longer mount the project directory (code comes from git mirror)
        assert!(!joined.contains("/home/forge/src"), "Forge should not have project dir mount");
    }

    #[test]
    fn terminal_has_no_working_dir() {
        // Terminal no longer sets -w because the project dir doesn't exist
        // until the entrypoint clones from the git mirror.
        let profile = container_profile::terminal_profile();
        let ctx = test_context();
        let args = build_podman_args(&profile, &ctx);
        assert!(
            !args.contains(&"-w".to_string()),
            "Terminal should not set -w (entrypoint clones then cd's)"
        );
    }

    #[test]
    fn custom_mounts_appended() {
        let profile = container_profile::forge_opencode_profile();
        let mut ctx = test_context();
        ctx.custom_mounts
            .push(tillandsias_core::config::MountConfig {
                host: "/data/models".into(),
                container: "/models".into(),
                mode: "ro".into(),
            });
        let args = build_podman_args(&profile, &ctx);
        let joined = args.join(" ");
        assert!(joined.contains("/data/models:/models:ro"));
    }

    #[test]
    fn image_is_always_last() {
        let profiles = [
            container_profile::forge_opencode_profile(),
            container_profile::forge_claude_profile(),
            container_profile::terminal_profile(),
            container_profile::web_profile(),
        ];

        for profile in &profiles {
            let args = build_podman_args(profile, &test_context());
            let last = args.last().unwrap();
            // Image tag should not start with - (it's not a flag)
            assert!(
                !last.starts_with('-'),
                "Last arg should be image tag, got: {last}"
            );
        }
    }

    #[test]
    fn port_range_present() {
        let profile = container_profile::forge_opencode_profile();
        let args = build_podman_args(&profile, &test_context());
        let joined = args.join(" ");
        assert!(joined.contains("3000-3019:3000-3019"));
    }

    #[test]
    fn entrypoint_set_from_profile() {
        let profile = container_profile::forge_claude_profile();
        let args = build_podman_args(&profile, &test_context());
        let ep_idx = args
            .iter()
            .position(|a| a == "--entrypoint")
            .expect("--entrypoint flag present");
        assert_eq!(
            args[ep_idx + 1],
            "/usr/local/bin/entrypoint-forge-claude.sh"
        );
    }

    // TOMBSTONED: `dbus_session_mounts_socket_when_env_set` and
    // `dbus_session_skipped_when_env_unset` tested the D-Bus-in-container
    // credential path, which the native-secrets-store refactor superseded.
    // The keyring now lives in the host Rust process; the git-service
    // container receives a read-only token file via bind mount (SecretKind::
    // GitHubToken). Containers no longer see D-Bus. See
    // openspec/specs/secrets-management/spec.md and
    // openspec/specs/native-secrets-store/spec.md.
    // @trace spec:secrets-management, spec:native-secrets-store

    // @trace spec:layered-tools-overlay
    #[test]
    fn tools_overlay_skipped_when_dir_absent() {
        let profile = container_profile::forge_opencode_profile();
        let ctx = test_context();
        let args = build_podman_args(&profile, &ctx);
        let joined = args.join(" ");
        // Tools overlay dir doesn't exist in the test context, so mount is skipped
        assert!(
            !joined.contains("/home/forge/.tools"),
            "Tools overlay mount should be skipped when directory doesn't exist"
        );
    }

    // @trace spec:layered-tools-overlay
    #[test]
    fn tools_overlay_mounted_when_dir_exists() {
        let profile = container_profile::forge_claude_profile();
        let tmp_dir = std::env::temp_dir().join("tillandsias-test-tools-overlay");
        let overlay_dir = tmp_dir.join("tools-overlay").join("current");
        std::fs::create_dir_all(&overlay_dir).unwrap();

        let mut ctx = test_context();
        ctx.cache_dir = tmp_dir.clone();

        let args = build_podman_args(&profile, &ctx);
        let joined = args.join(" ");

        let expected = format!("{}:/home/forge/.tools:ro", overlay_dir.display());
        assert!(
            joined.contains(&expected),
            "Tools overlay should be mounted read-only. Expected: {expected}\nGot: {joined}"
        );

        // Clean up
        std::fs::remove_dir_all(&tmp_dir).ok();
    }

    // @trace spec:layered-tools-overlay
    #[test]
    #[ignore] // Filesystem race with `config_overlay_mounted_when_dir_exists` — both
              // munge the same `$XDG_RUNTIME_DIR/tillandsias/config-overlay` path.
              // Passes when run individually. Kept for documentation; a proper fix
              // would isolate each test's runtime_dir via a mutable LaunchContext.
    fn config_overlay_skipped_when_dir_absent() {
        // Ensure the overlay dir does NOT exist (another test may have created it)
        let base = if let Ok(xdg) = std::env::var("XDG_RUNTIME_DIR") {
            std::path::PathBuf::from(xdg)
        } else {
            std::env::temp_dir()
        };
        let overlay_dir = base.join("tillandsias").join("config-overlay");
        let _ = std::fs::remove_dir_all(&overlay_dir);

        let profile = container_profile::forge_opencode_profile();
        let ctx = test_context();
        let args = build_podman_args(&profile, &ctx);
        let joined = args.join(" ");
        assert!(
            !joined.contains("/home/forge/.config-overlay"),
            "Config overlay mount should be skipped when tmpfs directory doesn't exist"
        );
    }

    // @trace spec:layered-tools-overlay
    #[test]
    fn config_overlay_mounted_when_dir_exists() {
        let profile = container_profile::forge_opencode_profile();

        // Create the config-overlay directory under the real runtime dir
        // (or temp dir if XDG_RUNTIME_DIR is unset) — avoids env var races
        // with other tests.
        let base = if let Ok(xdg) = std::env::var("XDG_RUNTIME_DIR") {
            std::path::PathBuf::from(xdg)
        } else {
            std::env::temp_dir()
        };
        let overlay_dir = base.join("tillandsias").join("config-overlay");
        std::fs::create_dir_all(&overlay_dir).unwrap();

        let ctx = test_context();
        let args = build_podman_args(&profile, &ctx);
        let joined = args.join(" ");

        let expected = format!("{}:/home/forge/.config-overlay:ro", overlay_dir.display());
        assert!(
            joined.contains(&expected),
            "Config overlay should be mounted read-only. Expected: {expected}\nGot: {joined}"
        );

        // Clean up — remove only the config-overlay dir, not the parent
        std::fs::remove_dir_all(&overlay_dir).ok();
    }

    // @trace spec:git-mirror-service
    #[test]
    fn git_service_has_no_mounts_no_env_vars() {
        let profile = container_profile::git_service_profile();
        // SAFETY: Test-only env var manipulation.
        unsafe { std::env::remove_var("DBUS_SESSION_BUS_ADDRESS") };
        let ctx = test_context();

        let args = build_podman_args(&profile, &ctx);
        let joined = args.join(" ");

        // No profile mounts (mounts vec is empty)
        assert!(
            !joined.contains("/home/forge/src"),
            "Git service should have no project mount from profile"
        );
        // No profile env vars
        assert!(
            !joined.contains("TILLANDSIAS_PROJECT="),
            "Git service should have no env vars from profile"
        );
        // Image should still be last
        let last = args.last().unwrap();
        assert!(
            !last.starts_with('-'),
            "Last arg should be image tag, got: {last}"
        );
    }

    // @trace spec:podman-orchestration, spec:secrets-management
    #[test]
    fn pids_limit_per_container_type() {
        let cases: Vec<(container_profile::ContainerProfile, u32)> = vec![
            (container_profile::forge_opencode_profile(), 512),
            (container_profile::forge_claude_profile(), 512),
            (container_profile::terminal_profile(), 512),
            (container_profile::git_service_profile(), 64),
            (container_profile::proxy_profile(), 32),
            (container_profile::inference_profile(), 128),
            (container_profile::web_profile(), 32),
        ];

        // SAFETY: Test-only env var manipulation.
        unsafe { std::env::remove_var("DBUS_SESSION_BUS_ADDRESS") };

        for (profile, expected_limit) in &cases {
            let ctx = test_context();
            let args = build_podman_args(profile, &ctx);
            let expected = format!("--pids-limit={expected_limit}");
            assert!(
                args.contains(&expected),
                "Expected {expected} for profile with entrypoint {}",
                profile.entrypoint
            );
        }
    }

    // @trace spec:podman-orchestration
    #[test]
    fn service_containers_have_read_only_fs() {
        // Proxy and inference are NOT read-only — they need writable runtime dirs.
        // With --userns=keep-id, tmpfs dirs are root-owned but process runs as UID 1000.
        let read_only_profiles = [
            container_profile::git_service_profile(),
            container_profile::web_profile(),
        ];

        // SAFETY: Test-only env var manipulation.
        unsafe { std::env::remove_var("DBUS_SESSION_BUS_ADDRESS") };

        for profile in &read_only_profiles {
            let ctx = test_context();
            let args = build_podman_args(profile, &ctx);
            assert!(
                args.contains(&"--read-only".to_string()),
                "Service container {} should have --read-only",
                profile.entrypoint
            );
            // All read-only containers must have at least /tmp as tmpfs
            assert!(
                args.contains(&"--tmpfs=/tmp".to_string()),
                "Read-only container {} should have --tmpfs=/tmp",
                profile.entrypoint
            );
        }
    }

    // @trace spec:podman-orchestration
    #[test]
    fn forge_containers_are_not_read_only() {
        let mutable_profiles = [
            container_profile::forge_opencode_profile(),
            container_profile::forge_claude_profile(),
            container_profile::terminal_profile(),
        ];

        for profile in &mutable_profiles {
            let args = build_podman_args(profile, &test_context());
            assert!(
                !args.contains(&"--read-only".to_string()),
                "Forge/terminal {} should NOT have --read-only",
                profile.entrypoint
            );
        }
    }

    // @trace spec:proxy-container
    #[test]
    fn proxy_is_not_read_only() {
        // Proxy needs writable runtime dirs (/var/spool/squid, /var/run/squid, etc).
        // With --read-only + --tmpfs, dirs are root-owned but squid runs as UID 1000
        // via --userns=keep-id → permission denied → squid crashes.
        unsafe { std::env::remove_var("DBUS_SESSION_BUS_ADDRESS") };

        let profile = container_profile::proxy_profile();
        let ctx = test_context();
        let args = build_podman_args(&profile, &ctx);
        assert!(
            !args.contains(&"--read-only".to_string()),
            "Proxy must NOT have --read-only (squid needs writable runtime dirs)"
        );
    }

    // @trace spec:enclave-network, spec:fix-podman-machine-host-aliases
    #[test]
    fn port_mapping_uses_friendly_aliases_resolved_via_host_gateway() {
        // After fix-podman-machine-host-aliases: env vars keep the friendly
        // service names. They resolve correctly inside the container because
        // build_podman_args injects `--add-host alias:host-gateway` for each
        // enclave service when port mapping is enabled. Inside the container,
        // `proxy`, `git-service`, and `inference` resolve to the host gateway
        // IP and reach the published ports.
        let profile = container_profile::forge_opencode_profile();
        let mut ctx = test_context();
        ctx.use_port_mapping = true;
        let args = build_podman_args(&profile, &ctx);
        let joined = args.join(" ");

        // Proxy env vars use the DNS alias (resolved via --add-host)
        assert!(
            joined.contains("HTTP_PROXY=http://proxy:3128"),
            "HTTP_PROXY should use the proxy alias on podman machine.\nGot: {joined}"
        );
        assert!(
            joined.contains("HTTPS_PROXY=http://proxy:3128"),
            "HTTPS_PROXY should use the proxy alias on podman machine"
        );
        assert!(
            joined.contains("http_proxy=http://proxy:3128"),
            "http_proxy should use the proxy alias on podman machine"
        );
        assert!(
            joined.contains("https_proxy=http://proxy:3128"),
            "https_proxy should use the proxy alias on podman machine"
        );

        // Git service uses the alias
        assert!(
            joined.contains("TILLANDSIAS_GIT_SERVICE=git-service"),
            "TILLANDSIAS_GIT_SERVICE should be the git-service alias on podman machine.\nGot: {joined}"
        );

        // Ollama uses the alias
        assert!(
            joined.contains("OLLAMA_HOST=http://inference:11434"),
            "OLLAMA_HOST should use the inference alias on podman machine.\nGot: {joined}"
        );

        // NO_PROXY keeps git-service in the bypass list (same as Linux)
        assert!(
            joined.contains("NO_PROXY=localhost,127.0.0.1,git-service"),
            "NO_PROXY should include git-service on podman machine.\nGot: {joined}"
        );

        // --add-host entries route the friendly aliases to the host gateway
        assert!(
            joined.contains("--add-host proxy:host-gateway"),
            "Expected --add-host proxy:host-gateway in podman args.\nGot: {joined}"
        );
        assert!(
            joined.contains("--add-host git-service:host-gateway"),
            "Expected --add-host git-service:host-gateway in podman args.\nGot: {joined}"
        );
        assert!(
            joined.contains("--add-host inference:host-gateway"),
            "Expected --add-host inference:host-gateway in podman args.\nGot: {joined}"
        );
    }

    // @trace spec:enclave-network, spec:fix-podman-machine-host-aliases
    #[test]
    fn rewrite_enclave_env_passes_through_after_host_aliases_fix() {
        // After fix-podman-machine-host-aliases the rewrite is a no-op:
        // friendly aliases (proxy, git-service, inference) are routed via
        // --add-host alias:host-gateway, so containers reach the published
        // ports using the same alias names they would on Linux. The function
        // is kept as a hook for hypothetical future setups that need different
        // values, but today it returns its input unchanged.
        for (name, value) in [
            ("HTTP_PROXY", "http://proxy:3128"),
            ("HTTPS_PROXY", "http://proxy:3128"),
            ("http_proxy", "http://proxy:3128"),
            ("https_proxy", "http://proxy:3128"),
            ("TILLANDSIAS_GIT_SERVICE", "git-service"),
            ("OLLAMA_HOST", "http://inference:11434"),
            ("NO_PROXY", "localhost,127.0.0.1,git-service"),
            ("no_proxy", "localhost,127.0.0.1,git-service"),
        ] {
            assert_eq!(
                super::rewrite_enclave_env(name, value),
                value,
                "rewrite_enclave_env({name}, {value}) should be a no-op after host-aliases fix"
            );
        }
    }

    // @trace spec:enclave-network
    #[test]
    fn rewrite_enclave_env_passes_through_unknown_vars() {
        assert_eq!(
            super::rewrite_enclave_env("TILLANDSIAS_PROJECT", "myproject"),
            "myproject"
        );
        assert_eq!(
            super::rewrite_enclave_env("SOME_OTHER_VAR", "value"),
            "value"
        );
    }

    // @trace spec:enclave-network
    #[test]
    fn no_port_mapping_keeps_dns_aliases() {
        let profile = container_profile::forge_opencode_profile();
        let mut ctx = test_context();
        ctx.use_port_mapping = false;
        let args = build_podman_args(&profile, &ctx);
        let joined = args.join(" ");

        // Proxy env vars should use DNS aliases
        assert!(
            joined.contains("HTTP_PROXY=http://proxy:3128"),
            "HTTP_PROXY should use DNS alias when not on podman machine.\nGot: {joined}"
        );
        assert!(
            joined.contains("TILLANDSIAS_GIT_SERVICE=git-service"),
            "TILLANDSIAS_GIT_SERVICE should use DNS alias when not on podman machine"
        );
        assert!(
            joined.contains("OLLAMA_HOST=http://inference:11434"),
            "OLLAMA_HOST should use DNS alias when not on podman machine"
        );
    }

    /// Helper: find whether `args` contains `flag` immediately followed by `value`.
    fn has_flag_value(args: &[String], flag: &str, value: &str) -> bool {
        args.windows(2)
            .any(|w| w[0] == flag && w[1] == value)
    }

    // @trace spec:opencode-web-session
    #[test]
    fn test_web_host_port_produces_loopback_publish() {
        let profile = container_profile::forge_opencode_web_profile();
        let mut ctx = test_context();
        ctx.detached = true;
        ctx.persistent = true;
        ctx.web_host_port = Some(17000);
        // Clear range so we're certain the loopback publish is the only -p.
        ctx.port_range = (0, 0);

        let args = build_podman_args(&profile, &ctx);

        assert!(
            has_flag_value(&args, "-p", "127.0.0.1:17000:4096"),
            "Expected `-p 127.0.0.1:17000:4096` in args, got: {args:?}"
        );
        assert!(
            !args.contains(&"--rm".to_string()),
            "Persistent container must NOT have --rm, got: {args:?}"
        );
        assert!(
            args.contains(&"-d".to_string()),
            "Detached container must have -d, got: {args:?}"
        );
    }

    // @trace spec:opencode-web-session
    #[test]
    fn test_persistent_without_web_port_still_publishes_range() {
        let profile = container_profile::forge_opencode_profile();
        let mut ctx = test_context();
        ctx.persistent = true;
        ctx.web_host_port = None;
        ctx.port_range = (3000, 3019);
        // Ensure no enclave-only short-circuit kicks in.
        ctx.network = None;

        let args = build_podman_args(&profile, &ctx);

        assert!(
            has_flag_value(&args, "-p", "3000-3019:3000-3019"),
            "Expected legacy range publish `-p 3000-3019:3000-3019`, got: {args:?}"
        );
        assert!(
            !args.contains(&"--rm".to_string()),
            "Persistent container must NOT have --rm, got: {args:?}"
        );
    }

    // @trace spec:opencode-web-session
    #[test]
    fn test_web_host_port_overrides_enclave_only_skip() {
        let profile = container_profile::forge_opencode_web_profile();
        let mut ctx = test_context();
        ctx.detached = true;
        ctx.persistent = true;
        ctx.network = Some(tillandsias_podman::ENCLAVE_NETWORK.to_string());
        ctx.web_host_port = Some(17000);

        let args = build_podman_args(&profile, &ctx);

        // Even though the container is enclave-only (which normally suppresses
        // port publishing), the web_host_port override must still emit the
        // loopback publish.
        assert!(
            has_flag_value(&args, "-p", "127.0.0.1:17000:4096"),
            "web_host_port must override enclave-only skip; got: {args:?}"
        );
        // And it must be bound to loopback — never 0.0.0.0 or bare.
        let joined = args.join(" ");
        assert!(
            !joined.contains("0.0.0.0"),
            "Publish must never bind to 0.0.0.0; got: {joined}"
        );
    }

    // @trace spec:opencode-web-session, spec:environment-runtime
    #[test]
    fn test_agent_name_opencode_web_wins() {
        let profile = container_profile::forge_opencode_web_profile();
        // Sanity: the web profile's entrypoint contains both "opencode-web" and "opencode".
        assert!(profile.entrypoint.contains("opencode-web"));
        assert!(profile.entrypoint.contains("opencode"));

        let args = build_podman_args(&profile, &test_context());
        let joined = args.join(" ");

        assert!(
            joined.contains("TILLANDSIAS_AGENT=opencode-web"),
            "AgentName must resolve to `opencode-web` for the web entrypoint, got: {joined}"
        );
        // Make sure the less-specific arm didn't win.
        assert!(
            !joined.contains("TILLANDSIAS_AGENT=opencode ")
                && !joined.ends_with("TILLANDSIAS_AGENT=opencode"),
            "AgentName must NOT resolve to plain `opencode` for the web entrypoint, got: {joined}"
        );
    }
}
