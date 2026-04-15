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
    args.push("--rm".into());
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
    // @trace spec:podman-orchestration, spec:secret-management
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
    if ctx.port_range != (0, 0) && !is_enclave_only {
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
                ContextKey::AgentName => {
                    // The agent name is derived from which profile is used;
                    // forge-opencode -> "opencode", forge-claude -> "claude".
                    // We infer it from the entrypoint to keep profiles self-contained.
                    if profile.entrypoint.contains("opencode") {
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
            EnvValue::Literal(s) => s.to_string(),
        };
        args.push("-e".into());
        args.push(format!("{}={}", env_var.name, value));
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
    // @trace spec:secret-management
    // -----------------------------------------------------------------------
    for secret in &profile.secrets {
        match &secret.kind {
            SecretKind::DbusSession => {
                // Forward host D-Bus session bus for keyring access.
                // The socket path is extracted from DBUS_SESSION_BUS_ADDRESS
                // and bind-mounted read-only. With --userns=keep-id the UID
                // matches, so D-Bus auth succeeds without mounting the entire
                // runtime directory.
                // @trace spec:git-mirror-service, spec:secret-management
                if let Ok(addr) = std::env::var("DBUS_SESSION_BUS_ADDRESS")
                    && let Some(socket_path) = addr.strip_prefix("unix:path=")
                    && std::path::Path::new(socket_path).exists()
                {
                    args.push("-v".into());
                    args.push(format!("{}:{}:ro", socket_path, socket_path));
                    args.push("-e".into());
                    args.push(format!("DBUS_SESSION_BUS_ADDRESS={}", addr));

                    // @trace spec:secret-management
                    tracing::info!(
                        accountability = true,
                        category = "secrets",
                        safety = "D-Bus session bus forwarded to git service only — forge containers have zero credential access",
                        spec = "secret-management",
                        container = %ctx.container_name,
                        "Credential isolation boundary: git service is the sole D-Bus consumer"
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

/// Resolve a logical mount source to an absolute host path.
///
/// Returns `None` when the source does not exist yet (e.g., tools overlay
/// not built). The caller skips the mount in that case.
/// @trace spec:layered-tools-overlay
fn resolve_mount_source(source: &MountSource, ctx: &LaunchContext) -> Option<String> {
    match source {
        MountSource::ProjectDir => Some(ctx.project_path.display().to_string()),
        MountSource::CacheDir => Some(ctx.cache_dir.display().to_string()),
        // @trace spec:layered-tools-overlay
        MountSource::ToolsOverlay => {
            let overlay_path = ctx.cache_dir
                .join("tools-overlay")
                .join("current");
            // Only mount if the overlay exists (graceful fallback).
            // Entrypoints will fall back to inline install when absent.
            if overlay_path.exists() {
                Some(overlay_path.display().to_string())
            } else {
                None
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

/// Read git author name and email from the cached gitconfig file.
///
/// Parses `~/.cache/tillandsias/secrets/git/.gitconfig` for `[user]` section
/// values. Returns `("", "")` if the file is missing or unparseable.
pub fn read_git_identity(cache_dir: &Path) -> (String, String) {
    let gitconfig = cache_dir.join("secrets").join("git").join(".gitconfig");
    let content = match std::fs::read_to_string(&gitconfig) {
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

    // Sanitize to prevent command injection via env vars.
    // Rust's Command API doesn't use a shell, but defense-in-depth
    // strips control chars and suspicious sequences.
    // @trace spec:podman-orchestration
    (sanitize_identity(&name), sanitize_identity(&email))
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

/// Ensure secrets directories exist and return their paths.
///
/// Creates `secrets/gh/` and `secrets/git/` under the cache dir, and
/// ensures the `.gitconfig` file exists inside the git dir.
///
/// Returns `(gh_dir, git_dir)`.
#[allow(dead_code)] // API surface — used by GitHub login and secrets mount flows
pub fn ensure_secrets_dirs(cache_dir: &Path) -> (std::path::PathBuf, std::path::PathBuf) {
    let secrets_dir = cache_dir.join("secrets");
    let gh_dir = secrets_dir.join("gh");
    let git_dir = secrets_dir.join("git");

    std::fs::create_dir_all(&gh_dir).ok();
    std::fs::create_dir_all(&git_dir).ok();

    // Ensure .gitconfig FILE exists inside the git dir
    let gitconfig_path = git_dir.join(".gitconfig");
    if !gitconfig_path.exists() {
        std::fs::File::create(&gitconfig_path).ok();
    }

    (gh_dir, git_dir)
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

    // @trace spec:git-mirror-service, spec:secret-management
    #[test]
    fn dbus_session_mounts_socket_when_env_set() {
        // Create a temp file to act as the D-Bus socket
        let tmp_dir = std::env::temp_dir().join("tillandsias-test-dbus");
        std::fs::create_dir_all(&tmp_dir).unwrap();
        let socket_path = tmp_dir.join("bus");
        std::fs::File::create(&socket_path).unwrap();

        // Set the env var for this test (note: env vars are process-global,
        // but cargo test runs each test in the same process sequentially
        // for the same test binary unless parallelized — this is acceptable
        // for testing the code path).
        let addr = format!("unix:path={}", socket_path.display());
        // SAFETY: Test-only env var manipulation. These tests are not run in
        // parallel with other tests that read DBUS_SESSION_BUS_ADDRESS.
        unsafe { std::env::set_var("DBUS_SESSION_BUS_ADDRESS", &addr) };

        let profile = container_profile::git_service_profile();
        let args = build_podman_args(&profile, &test_context());
        let joined = args.join(" ");

        // D-Bus socket should be bind-mounted read-only
        let expected_mount = format!("{}:{}:ro", socket_path.display(), socket_path.display());
        assert!(
            joined.contains(&expected_mount),
            "D-Bus socket mount missing. Expected: {expected_mount}\nGot: {joined}"
        );

        // D-Bus address env var should be forwarded
        let expected_env = format!("DBUS_SESSION_BUS_ADDRESS={}", addr);
        assert!(
            joined.contains(&expected_env),
            "DBUS_SESSION_BUS_ADDRESS env var missing"
        );

        // No token file fallback — D-Bus is the sole credential path
        assert!(
            !joined.contains("/run/secrets/github_token"),
            "GitHubToken fallback must not be present — D-Bus is the sole credential path"
        );

        // Clean up
        std::fs::remove_dir_all(&tmp_dir).ok();
        unsafe { std::env::remove_var("DBUS_SESSION_BUS_ADDRESS") };
    }

    // @trace spec:git-mirror-service
    #[test]
    #[ignore] // Flaky in parallel: races with dbus_session_mounts_socket_when_env_set over DBUS_SESSION_BUS_ADDRESS. Passes individually.
    fn dbus_session_skipped_when_env_unset() {
        // SAFETY: Test-only env var manipulation.
        unsafe { std::env::remove_var("DBUS_SESSION_BUS_ADDRESS") };

        let profile = container_profile::git_service_profile();
        let args = build_podman_args(&profile, &test_context());
        let joined = args.join(" ");

        // No D-Bus mount or env var should appear
        assert!(
            !joined.contains("DBUS_SESSION_BUS_ADDRESS"),
            "D-Bus env var should not appear when host env is unset"
        );
    }

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

    // @trace spec:podman-orchestration, spec:secret-management
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
}
