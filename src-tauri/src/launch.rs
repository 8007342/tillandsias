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
    // GPU passthrough (Linux only)
    // @trace spec:podman-orchestration/gpu-passthrough
    // -----------------------------------------------------------------------
    if cfg!(target_os = "linux") {
        for flag in tillandsias_podman::detect_gpu_devices() {
            args.push(flag);
        }
    }

    // -----------------------------------------------------------------------
    // Port range
    // -----------------------------------------------------------------------
    args.push("-p".into());
    args.push(format!(
        "{}-{}:{}-{}",
        ctx.port_range.0, ctx.port_range.1, ctx.port_range.0, ctx.port_range.1
    ));

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
        let host_path = resolve_mount_source(&mount.host_key, ctx);
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
    // @trace spec:secret-rotation
    // -----------------------------------------------------------------------
    for secret in &profile.secrets {
        match &secret.kind {
            SecretKind::GitHubToken => {
                if let Some(ref token_path) = ctx.token_file_path {
                    args.push("-v".into());
                    args.push(format!(
                        "{}:/run/secrets/github_token:ro",
                        token_path.display()
                    ));
                    args.push("-e".into());
                    args.push(
                        "GIT_ASKPASS=/usr/local/bin/git-askpass-tillandsias.sh".into(),
                    );
                }
            }
            SecretKind::ClaudeDir => {
                args.push("-v".into());
                args.push(format!("{}:/home/forge/.claude:rw", ctx.claude_dir.display()));
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

/// Resolve a logical mount source to an absolute host path.
fn resolve_mount_source(source: &MountSource, ctx: &LaunchContext) -> String {
    match source {
        MountSource::ProjectDir => ctx.project_path.display().to_string(),
        MountSource::CacheDir => ctx.cache_dir.display().to_string(),
        MountSource::SecretsSubdir(subdir) => {
            match *subdir {
                "gh" => ctx.gh_dir.display().to_string(),
                "git" => ctx.git_dir.display().to_string(),
                other => {
                    // Fallback: secrets/<subdir> under cache
                    ctx.cache_dir
                        .join("secrets")
                        .join(other)
                        .display()
                        .to_string()
                }
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

/// Ensure secrets directories exist and return their paths.
///
/// Creates `secrets/gh/` and `secrets/git/` under the cache dir, and
/// ensures the `.gitconfig` file exists inside the git dir.
///
/// Returns `(gh_dir, git_dir)`.
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
            claude_dir: PathBuf::from("/home/user/.claude"),
            gh_dir: PathBuf::from("/home/user/.cache/tillandsias/secrets/gh"),
            git_dir: PathBuf::from("/home/user/.cache/tillandsias/secrets/git"),
            token_file_path: Some(PathBuf::from(
                "/run/user/1000/tillandsias/tokens/tillandsias-myproject-aeranthos/github_token",
            )),
            custom_mounts: vec![],
            image_tag: "tillandsias-forge:v0.1.90".into(),
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
        }
    }

    #[test]
    fn forge_opencode_has_github_token_no_claude_secrets() {
        let profile = container_profile::forge_opencode_profile();
        let args = build_podman_args(&profile, &test_context());
        let joined = args.join(" ");
        // Has GitHub token mount
        assert!(joined.contains("/run/secrets/github_token:ro"));
        assert!(joined.contains("GIT_ASKPASS=/usr/local/bin/git-askpass-tillandsias.sh"));
        // No Claude secrets
        assert!(!joined.contains("ANTHROPIC_API_KEY"));
        assert!(!joined.contains(".claude:rw"));
    }

    #[test]
    fn forge_claude_has_claude_and_github_secrets() {
        let profile = container_profile::forge_claude_profile();
        let args = build_podman_args(&profile, &test_context());
        let joined = args.join(" ");
        // Has GitHub token mount
        assert!(joined.contains("/run/secrets/github_token:ro"));
        assert!(joined.contains("GIT_ASKPASS=/usr/local/bin/git-askpass-tillandsias.sh"));
        // No API key injection (removed)
        assert!(!joined.contains("ANTHROPIC_API_KEY"), "API key should never be injected");
        // Has Claude dir mount
        assert!(joined.contains("/home/user/.claude:/home/forge/.claude:rw"));
    }

    #[test]
    fn terminal_has_github_token_no_claude_secrets() {
        let profile = container_profile::terminal_profile();
        let args = build_podman_args(&profile, &test_context());
        let joined = args.join(" ");
        // Has GitHub token mount
        assert!(joined.contains("/run/secrets/github_token:ro"));
        assert!(joined.contains("GIT_ASKPASS=/usr/local/bin/git-askpass-tillandsias.sh"));
        // No Claude secrets
        assert!(!joined.contains("ANTHROPIC_API_KEY"));
        assert!(!joined.contains(".claude:rw"));
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
    fn watch_root_mounts_at_src() {
        let profile = container_profile::forge_opencode_profile();
        let mut ctx = test_context();
        ctx.is_watch_root = true;
        let args = build_podman_args(&profile, &ctx);
        let joined = args.join(" ");
        // Should mount at /home/forge/src, NOT /home/forge/src/myproject
        assert!(joined.contains("/home/user/src/myproject:/home/forge/src:rw"));
    }

    #[test]
    fn project_subdir_mount() {
        let profile = container_profile::forge_opencode_profile();
        let ctx = test_context();
        let args = build_podman_args(&profile, &ctx);
        let joined = args.join(" ");
        // Should mount at /home/forge/src/myproject
        assert!(joined.contains("/home/user/src/myproject:/home/forge/src/myproject:rw"));
    }

    #[test]
    fn terminal_has_working_dir() {
        let profile = container_profile::terminal_profile();
        let ctx = test_context();
        let args = build_podman_args(&profile, &ctx);
        let w_idx = args
            .iter()
            .position(|a| a == "-w")
            .expect("-w flag present");
        assert_eq!(args[w_idx + 1], "/home/forge/src/myproject");
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

    #[test]
    fn github_token_absent_when_token_file_path_is_none() {
        let profile = container_profile::forge_opencode_profile();
        let mut ctx = test_context();
        ctx.token_file_path = None;
        let args = build_podman_args(&profile, &ctx);
        let joined = args.join(" ");
        assert!(!joined.contains("/run/secrets/github_token"));
        assert!(!joined.contains("GIT_ASKPASS"));
    }
}
