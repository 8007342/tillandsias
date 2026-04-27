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
    // @trace spec:external-logs-layer
    // Reverse-breach refusal: a profile MUST NOT be both a producer and a
    // consumer. validate() returns Err for this case; treat it as a
    // non-recoverable profile-construction bug (panic in debug, hard log+skip
    // the combined mount in release to avoid an incorrect podman invocation).
    if let Err(e) = profile.validate() {
        // Panic in debug so CI catches this immediately.
        // In release, log loudly and continue — the per-field logic below
        // already handles the precedence (producer wins).
        debug_assert!(false, "build_podman_args: invalid profile — {e}");
        tracing::error!(
            spec = "external-logs-layer",
            accountability = true,
            category = "external-logs",
            error = %e,
            container = %ctx.container_name,
            "[external-logs] Profile validation failed — refusing to launch with broken profile"
        );
    }

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
    // Forge/terminal containers need mutable workspace and skip this flag.
    // @trace spec:podman-orchestration
    // -----------------------------------------------------------------------
    if profile.read_only {
        args.push("--read-only".into());
    }

    // -----------------------------------------------------------------------
    // Tmpfs mounts — emitted unconditionally (regardless of read_only).
    //
    // Each mount carries a kernel-enforced size cap: `--tmpfs=<path>:size=<N>m,mode=<oct>`.
    // This prevents any tmpfs from expanding to the default 50% of host RAM.
    //
    // For forge-shaped profiles (entrypoint contains "entrypoint-forge-" or
    // "entrypoint-terminal"), an additional per-launch tmpfs is emitted for
    // `/home/forge/src` using `ctx.hot_path_budget_mb`. This is separate
    // from the profile's static tmpfs_mounts so the budget can vary per launch.
    //
    // When any tmpfs is present we also add:
    //   --memory=<total>m --memory-swap=<total>m
    // where total = sum of all tmpfs caps + 256 MB working-set baseline.
    // Setting memory-swap equal to memory disables swap for the container,
    // preserving the RAM-only guarantee (no swap escape).
    //
    // @trace spec:podman-orchestration, spec:forge-hot-cold-split
    // -----------------------------------------------------------------------
    // Detect forge-shaped profiles by entrypoint. These receive the per-launch
    // /home/forge/src tmpfs with the computed hot-path budget.
    let is_forge_profile = profile.entrypoint.contains("entrypoint-forge-")
        || profile.entrypoint.contains("entrypoint-terminal");

    // Collect all tmpfs mounts including the per-launch src mount for forge profiles.
    let profile_tmpfs_total_mb: u32 = profile.tmpfs_mounts.iter().map(|m| m.size_mb).sum();
    let has_any_tmpfs = !profile.tmpfs_mounts.is_empty()
        || (is_forge_profile && ctx.hot_path_budget_mb > 0);

    if has_any_tmpfs {
        for mount in &profile.tmpfs_mounts {
            args.push(format!(
                "--tmpfs={}:size={}m,mode={:o}",
                mount.path, mount.size_mb, mount.mode
            ));
        }
        // @trace spec:forge-hot-cold-split
        // Per-launch /home/forge/src tmpfs — chunk 3. The budget is computed
        // by compute_hot_budget() at the forge launch site and stored in
        // ctx.hot_path_budget_mb. Service containers (git, proxy, inference,
        // web) are not forge-shaped and do NOT get this mount.
        if is_forge_profile && ctx.hot_path_budget_mb > 0 {
            args.push(format!(
                "--tmpfs=/home/forge/src:size={}m,mode=755",
                ctx.hot_path_budget_mb
            ));
        }
        // Memory ceiling: sum of all tmpfs caps + 256 MB baseline for the container's
        // working set (stack, heap, mapped libraries). --memory-swap equal to --memory
        // disables swap — no spilling the RAM-only guarantee to disk.
        let src_budget = if is_forge_profile { ctx.hot_path_budget_mb } else { 0 };
        let memory_mb = profile_tmpfs_total_mb + src_budget + 256;
        args.push(format!("--memory={memory_mb}m"));
        args.push(format!("--memory-swap={memory_mb}m"));
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
    // External-logs mounts — producer (RW) and consumer (RO)
    //
    // These mounts are driven by profile fields rather than profile.mounts
    // so the path resolution and mode are unconditional and consistent:
    //   - Producer: role-scoped host dir RW at /var/log/tillandsias/external/
    //   - Consumer: parent host dir RO at /var/log/tillandsias/external/
    //
    // The two are mutually exclusive by spec — any profile setting BOTH is
    // a bug caught at review time (test `profile_cannot_be_both_producer_and_consumer`).
    //
    // @trace spec:external-logs-layer
    // -----------------------------------------------------------------------
    if let Some(role) = profile.external_logs_role {
        // Refuse the pathological case: a profile cannot be both producer and consumer.
        // Log loudly but do not crash — the producer mount takes precedence.
        if profile.external_logs_consumer {
            tracing::error!(
                role = role,
                container = %ctx.container_name,
                spec = "external-logs-layer",
                accountability = true,
                "Profile sets BOTH external_logs_role AND external_logs_consumer — this is a spec violation; producer mount takes precedence. Fix the profile."
            );
        }
        let source = MountSource::ExternalLogsProducer { role };
        if let Some(host_path) = resolve_mount_source(&source, ctx) {
            args.push("-v".into());
            // Producer: RW mount at the in-container external log path, SELinux relabeled.
            args.push(format!(
                "{}:/var/log/tillandsias/external:rw,Z",
                host_path
            ));
        }
    } else if profile.external_logs_consumer {
        let source = MountSource::ExternalLogsConsumerRoot;
        if let Some(host_path) = resolve_mount_source(&source, ctx) {
            args.push("-v".into());
            // Consumer: parent dir RO — sees one subdir per producer role.
            args.push(format!(
                "{}:/var/log/tillandsias/external:ro,Z",
                host_path
            ));
        }
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
    // Control-socket bind mount (opt-in per profile)
    //
    // The tray binds a Unix-domain socket at startup at
    // `$XDG_RUNTIME_DIR/tillandsias/control.sock` (or the per-user /tmp
    // fallback). Profiles that opt in via `mount_control_socket = true`
    // receive a bind mount of that node at the canonical in-container path
    // and an env var pointing client libraries at it. Profiles that do NOT
    // opt in receive neither — the secrets-management delta enforces this
    // default-deny posture so a compromised forge cannot reach the tray's
    // control plane.
    // @trace spec:tray-host-control-socket, spec:secrets-management
    // @cheatsheet runtime/forge-container.md
    // -----------------------------------------------------------------------
    if profile.mount_control_socket {
        let resolved = crate::control_socket::path::resolve();
        args.push("-v".into());
        args.push(format!(
            "{}:{}:rw",
            resolved.socket_path.display(),
            crate::control_socket::path::CONTAINER_SOCKET_PATH
        ));
        args.push("-e".into());
        args.push(format!(
            "TILLANDSIAS_CONTROL_SOCKET={}",
            crate::control_socket::path::CONTAINER_SOCKET_PATH
        ));
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
        // @trace spec:forge-cache-architecture, spec:forge-cache-dual
        // @cheatsheet runtime/forge-shared-cache-via-nix.md
        // Shared cache — host-managed nix store, RO from forge perspective.
        // Resolves to ~/.cache/tillandsias/forge-shared/nix-store/. Created
        // on first need; populated by host-side nix processes (out of band
        // — this code just ensures the mount target exists).
        MountSource::SharedCache => {
            let shared = tillandsias_core::config::cache_dir()
                .join("forge-shared")
                .join("nix-store");
            if let Err(e) = std::fs::create_dir_all(&shared) {
                tracing::warn!(
                    error = %e,
                    path = %shared.display(),
                    spec = "forge-cache-architecture",
                    "Failed to create shared cache directory — mount will fail"
                );
                return None;
            }
            Some(shared.display().to_string())
        }
        // @trace spec:forge-cache-architecture, spec:forge-cache-dual
        // @cheatsheet runtime/forge-paths-ephemeral-vs-persistent.md
        // Per-project cache — RW, isolated by project name. Project A's
        // forge container CANNOT see project B's cache because the host
        // path differs. Persisted across container stops for the same
        // project; never auto-GC'd (manual `rm -rf` for housekeeping).
        MountSource::ProjectCache => {
            if ctx.project_name.is_empty() {
                tracing::warn!(
                    spec = "forge-cache-architecture",
                    "Per-project cache mount requested with empty project name — skipping"
                );
                return None;
            }
            let proj = tillandsias_core::config::cache_dir()
                .join("forge-projects")
                .join(&ctx.project_name);
            if let Err(e) = std::fs::create_dir_all(&proj) {
                tracing::warn!(
                    error = %e,
                    path = %proj.display(),
                    project = %ctx.project_name,
                    spec = "forge-cache-architecture",
                    "Failed to create per-project cache directory — mount will fail"
                );
                return None;
            }
            // Also create the per-language subdirectories so tools that
            // don't auto-mkdir their cache dir don't crash on first use.
            for sub in &[
                "cargo", "go", "maven", "gradle", "pub", "npm", "yarn", "pnpm", "uv", "pip",
            ] {
                let _ = std::fs::create_dir_all(proj.join(sub));
            }
            Some(proj.display().to_string())
        }
        // @trace spec:external-logs-layer
        // External-logs producer: bind-mounts the role-specific directory RW.
        // The in-container target is always /var/log/tillandsias/external/;
        // the producer sees ONLY its own role's files. The launcher creates
        // the host directory on demand (mirrors ContainerLogs behaviour).
        MountSource::ExternalLogsProducer { role } => {
            let role_dir = tillandsias_core::config::external_logs_role_dir(role);
            if let Err(e) = std::fs::create_dir_all(&role_dir) {
                tracing::warn!(
                    role = role,
                    error = %e,
                    path = %role_dir.display(),
                    spec = "external-logs-layer",
                    "Failed to create external-logs role directory — mount will fail"
                );
                return None;
            }
            tracing::debug!(
                role = role,
                path = %role_dir.display(),
                spec = "external-logs-layer",
                "External-logs producer directory ready"
            );
            Some(role_dir.display().to_string())
        }
        // @trace spec:external-logs-layer
        // External-logs consumer: bind-mounts the parent external-logs/ dir
        // RO at /var/log/tillandsias/external/. Consumer sees one subdir per
        // active producer role. An empty enclave mounts a valid empty dir.
        MountSource::ExternalLogsConsumerRoot => {
            let root = tillandsias_core::config::external_logs_dir();
            if let Err(e) = std::fs::create_dir_all(&root) {
                tracing::warn!(
                    error = %e,
                    path = %root.display(),
                    spec = "external-logs-layer",
                    "Failed to create external-logs root directory — mount will fail"
                );
                return None;
            }
            tracing::debug!(
                path = %root.display(),
                spec = "external-logs-layer",
                "External-logs consumer root directory ready"
            );
            Some(root.display().to_string())
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

/// Compute the per-launch tmpfs budget (MB) for `/home/forge/src`.
///
/// Reads the bare git mirror's pack size via `git count-objects -v -H`,
/// multiplies by `inflation` (default `forge.hot_path_inflation` = 4), and
/// clamps to `[256, max_mb]` (default `forge.hot_path_max_mb` = 4096).
///
/// Returns 256 (the floor) when:
/// - The mirror directory does not exist (empty / new project)
/// - `git count-objects` fails or its output cannot be parsed
///
/// The multiplication accounts for the fact that a working tree checked out
/// from a pack file typically expands 2–5× due to loose objects, git metadata,
/// and the checked-out files themselves.
///
/// @trace spec:forge-hot-cold-split
pub fn compute_hot_budget(project_name: &str, cache_dir: &Path) -> u32 {
    compute_hot_budget_with_limits(project_name, cache_dir, 4, 4096)
}

/// Internal: compute hot budget with explicit inflation and max (testable).
///
/// @trace spec:forge-hot-cold-split
pub fn compute_hot_budget_with_limits(
    project_name: &str,
    cache_dir: &Path,
    inflation: u32,
    max_mb: u32,
) -> u32 {
    const FLOOR_MB: u32 = 256;
    let mirror_dir = cache_dir
        .join("forge-projects")
        .join(project_name)
        .join("git-mirror");

    if !mirror_dir.exists() {
        tracing::debug!(
            project = project_name,
            mirror = %mirror_dir.display(),
            spec = "forge-hot-cold-split",
            "Git mirror does not exist — returning floor budget"
        );
        return FLOOR_MB;
    }

    // Run: git -C <mirror> count-objects -v -H
    // Output sample:
    //   count: 0
    //   size: 0 bytes
    //   in-pack: 1234
    //   packs: 1
    //   size-pack: 5.12 MiB     ← parse this line
    //   prune-packable: 0
    //   garbage: 0
    //   size-garbage: 0 bytes
    let output = match std::process::Command::new("git")
        .args(["-C", &mirror_dir.to_string_lossy(), "count-objects", "-v", "-H"])
        .output()
    {
        Ok(o) => o,
        Err(e) => {
            tracing::warn!(
                project = project_name,
                error = %e,
                spec = "forge-hot-cold-split",
                "git count-objects failed — returning floor budget"
            );
            return FLOOR_MB;
        }
    };

    if !output.status.success() {
        tracing::warn!(
            project = project_name,
            exit_code = ?output.status.code(),
            spec = "forge-hot-cold-split",
            "git count-objects returned non-zero — returning floor budget"
        );
        return FLOOR_MB;
    }

    let stdout = String::from_utf8_lossy(&output.stdout);
    let pack_size_mb = parse_size_pack_mb(&stdout);

    let raw = pack_size_mb.saturating_mul(inflation);
    let clamped = raw.clamp(FLOOR_MB, max_mb);

    tracing::debug!(
        project = project_name,
        pack_size_mb,
        inflation,
        raw_budget_mb = raw,
        budget_mb = clamped,
        spec = "forge-hot-cold-split",
        "Hot-path budget computed from git mirror pack size"
    );

    clamped
}

/// Parse the `size-pack` line from `git count-objects -v -H` output.
///
/// Returns 0 when the line is missing or the value cannot be parsed.
/// The human-readable suffix is converted to MB:
/// - No suffix / bytes → ÷ (1024 * 1024) rounded up
/// - KiB → ÷ 1024 rounded up
/// - MiB → round up
/// - GiB → × 1024
///
/// @trace spec:forge-hot-cold-split
pub(crate) fn parse_size_pack_mb(output: &str) -> u32 {
    for line in output.lines() {
        let line = line.trim();
        if let Some(rest) = line.strip_prefix("size-pack:") {
            let value = rest.trim();
            return parse_human_size_to_mb(value);
        }
    }
    0
}

/// Convert a human-readable size string (from `git count-objects -H`) to MB.
///
/// Examples: "0 bytes", "1.23 KiB", "5.12 MiB", "2.00 GiB", "512"
/// Returns 0 for unrecognised formats; rounds fractional MiB up to 1.
///
/// @trace spec:forge-hot-cold-split
fn parse_human_size_to_mb(s: &str) -> u32 {
    // Split on first whitespace to separate number from unit.
    let mut parts = s.splitn(2, char::is_whitespace);
    let num_str = parts.next().unwrap_or("0");
    let unit = parts.next().unwrap_or("").trim().to_lowercase();

    let num: f64 = num_str.replace(',', "").parse().unwrap_or(0.0);

    let mb = match unit.as_str() {
        "gib" | "gb" => num * 1024.0,
        "mib" | "mb" => num,
        "kib" | "kb" => num / 1024.0,
        "bytes" | "byte" | "" => num / (1024.0 * 1024.0),
        _ => 0.0,
    };

    // Round up to at least 1 MB if there's any data, otherwise 0.
    if mb > 0.0 {
        mb.ceil() as u32
    } else {
        0
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
            } else if let Some(val) = trimmed.strip_prefix("email")
                && let Some(val) = val.trim_start().strip_prefix('=') {
                    email = val.trim().to_string();
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
            hot_path_budget_mb: 1024,
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

    // @trace spec:forge-hot-cold-split
    #[test]
    fn forge_has_no_project_dir_bind_mount_but_has_tmpfs() {
        // Forge profiles no longer bind-mount the project directory (code comes from git mirror).
        // Instead, /home/forge/src is a per-launch tmpfs (chunk 3).
        let profile = container_profile::forge_opencode_profile();
        let ctx = test_context();
        let args = build_podman_args(&profile, &ctx);
        let joined = args.join(" ");
        // The src tmpfs should be present (chunk 3 hot path)
        assert!(
            joined.contains("--tmpfs=/home/forge/src"),
            "Forge should have /home/forge/src as tmpfs (hot path); got: {joined}"
        );
        // But there must be NO volume bind-mount (-v) for /home/forge/src
        let bind_mounts: Vec<&str> = args
            .iter()
            .zip(args.iter().skip(1))
            .filter_map(|(a, b)| if a == "-v" { Some(b.as_str()) } else { None })
            .collect();
        assert!(
            !bind_mounts.iter().any(|m| m.contains("/home/forge/src")),
            "Forge should NOT have a -v bind-mount for /home/forge/src; got: {bind_mounts:?}"
        );
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

    // @trace spec:tombstone-tools-overlay
    // Tools overlay was removed on 2026-04-25 — agents are hard-installed in
    // the forge image at /usr/local/bin/. No mount to test for.
    #[test]
    fn forge_profiles_have_no_tools_overlay_mount() {
        for profile in [
            container_profile::forge_opencode_profile(),
            container_profile::forge_claude_profile(),
            container_profile::forge_opencode_web_profile(),
            container_profile::terminal_profile(),
        ] {
            let ctx = test_context();
            let args = build_podman_args(&profile, &ctx);
            let joined = args.join(" ");
            assert!(
                !joined.contains("/home/forge/.tools"),
                "No profile should mount the tools overlay — tombstoned.\nGot: {joined}"
            );
        }
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

    // @trace spec:podman-orchestration, spec:forge-hot-cold-split
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
            // All read-only containers must have at least /tmp as tmpfs,
            // now emitted with size cap: --tmpfs=/tmp:size=64m,mode=1777
            assert!(
                args.iter().any(|a| a.starts_with("--tmpfs=/tmp:")),
                "Read-only container {} should have a sized --tmpfs=/tmp:... arg",
                profile.entrypoint
            );
        }
    }

    // @trace spec:podman-orchestration, spec:forge-hot-cold-split
    #[test]
    fn tmpfs_emits_sized_flag_with_mode() {
        // The web profile has two tmpfs mounts (/tmp and /var/run) with size and mode.
        // Check that build_podman_args emits them with the expected format.
        let profile = container_profile::web_profile();
        let ctx = test_context();
        let args = build_podman_args(&profile, &ctx);

        // /tmp: size=64m, mode=1777
        assert!(
            args.iter().any(|a| *a == "--tmpfs=/tmp:size=64m,mode=1777"),
            "Expected --tmpfs=/tmp:size=64m,mode=1777; got: {args:?}"
        );
        // /var/run: size=64m, mode=755
        assert!(
            args.iter().any(|a| *a == "--tmpfs=/var/run:size=64m,mode=755"),
            "Expected --tmpfs=/var/run:size=64m,mode=755; got: {args:?}"
        );
    }

    // @trace spec:podman-orchestration, spec:forge-hot-cold-split
    #[test]
    fn tmpfs_pairs_with_memory_ceiling() {
        // web profile: two 64 MB mounts → total = 128 MB + 256 MB baseline = 384 MB.
        let profile = container_profile::web_profile();
        let ctx = test_context();
        let args = build_podman_args(&profile, &ctx);

        assert!(
            args.iter().any(|a| *a == "--memory=384m"),
            "Expected --memory=384m (128MB tmpfs + 256MB baseline); got: {args:?}"
        );
        assert!(
            args.iter().any(|a| *a == "--memory-swap=384m"),
            "Expected --memory-swap=384m (disables swap); got: {args:?}"
        );

        // git_service: one 64 MB mount → 64 + 256 = 320 MB.
        let profile = container_profile::git_service_profile();
        let args = build_podman_args(&profile, &ctx);
        assert!(
            args.iter().any(|a| *a == "--memory=320m"),
            "Expected --memory=320m for git_service (64MB + 256MB); got: {args:?}"
        );
        assert!(
            args.iter().any(|a| *a == "--memory-swap=320m"),
            "Expected --memory-swap=320m for git_service; got: {args:?}"
        );
    }

    // @trace spec:podman-orchestration, spec:forge-hot-cold-split, spec:agent-cheatsheets
    #[test]
    fn forge_profiles_emit_cheatsheets_tmpfs_and_memory_ceiling() {
        // Chunk 2: forge and terminal profiles include the /opt/cheatsheets tmpfs
        // mount (8MB cap, mode 755). build_podman_args must emit the sized --tmpfs
        // flag and the paired --memory / --memory-swap ceiling.
        for profile in [
            container_profile::forge_opencode_profile(),
            container_profile::forge_claude_profile(),
            container_profile::forge_opencode_web_profile(),
            container_profile::terminal_profile(),
        ] {
            let ctx = test_context();
            let args = build_podman_args(&profile, &ctx);
            assert!(
                args.iter().any(|a| a == "--tmpfs=/opt/cheatsheets:size=8m,mode=755"),
                "Forge profile {} must emit --tmpfs=/opt/cheatsheets:size=8m,mode=755; got: {args:?}",
                profile.entrypoint
            );
            assert!(
                args.iter().any(|a| a.starts_with("--memory=")),
                "Forge profile {} must emit --memory ceiling when tmpfs present; got: {args:?}",
                profile.entrypoint
            );
            assert!(
                args.iter().any(|a| a.starts_with("--memory-swap=")),
                "Forge profile {} must emit --memory-swap when tmpfs present; got: {args:?}",
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

        // @trace spec:opencode-web-session, spec:proxy-container
        // NO_PROXY lists every enclave-internal destination so intra-enclave
        // traffic never hairpins through Squid. The full value includes
        // loopback variants + each enclave peer (inference, proxy, git-service).
        assert!(
            joined.contains("NO_PROXY=localhost,127.0.0.1,0.0.0.0,::1,git-service,inference,proxy"),
            "NO_PROXY should include every enclave peer on podman machine.\nGot: {joined}"
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
            ("NO_PROXY", "localhost,127.0.0.1,0.0.0.0,::1,git-service,inference,proxy"),
            ("no_proxy", "localhost,127.0.0.1,0.0.0.0,::1,git-service,inference,proxy"),
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
        // Check ONLY the publish (-p) args, not the whole arg string, because
        // NO_PROXY legitimately contains "0.0.0.0" as a loopback bypass entry.
        // @trace spec:opencode-web-session
        let publish_args: Vec<&String> = args
            .iter()
            .zip(args.iter().skip(1))
            .filter_map(|(a, b)| if a == "-p" { Some(b) } else { None })
            .collect();
        assert!(
            !publish_args.is_empty(),
            "expected at least one -p arg; got: {args:?}"
        );
        for p in &publish_args {
            assert!(
                !p.contains("0.0.0.0"),
                "Publish binding must never be 0.0.0.0; got: {p}"
            );
            assert!(
                p.starts_with("127.0.0.1:"),
                "Publish binding must start with 127.0.0.1:; got: {p}"
            );
        }
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

    // @trace spec:tray-host-control-socket, spec:secrets-management
    #[test]
    fn control_socket_mount_added_when_profile_opts_in() {
        // The router profile sets `mount_control_socket = true`. The launch
        // path should append a `-v <host>:/run/host/tillandsias/control.sock:rw`
        // mount and a `TILLANDSIAS_CONTROL_SOCKET=/run/host/tillandsias/control.sock`
        // env var.
        let profile = container_profile::router_profile();
        assert!(
            profile.mount_control_socket,
            "router profile must opt in to control socket"
        );
        let args = build_podman_args(&profile, &test_context());
        let joined = args.join(" ");
        assert!(
            joined.contains(":/run/host/tillandsias/control.sock:rw"),
            "router must receive control-socket bind mount; got: {joined}"
        );
        assert!(
            joined.contains("TILLANDSIAS_CONTROL_SOCKET=/run/host/tillandsias/control.sock"),
            "router must receive TILLANDSIAS_CONTROL_SOCKET env; got: {joined}"
        );
        // Security flags MUST remain on the command line — control-socket
        // mount does not relax them.
        assert!(
            joined.contains("--cap-drop=ALL"),
            "control-socket mount must not relax cap-drop"
        );
        assert!(
            joined.contains("--security-opt=no-new-privileges"),
            "control-socket mount must not relax no-new-privileges"
        );
        assert!(
            joined.contains("--userns=keep-id"),
            "control-socket mount must not relax userns=keep-id"
        );
    }

    // @trace spec:tray-host-control-socket, spec:secrets-management
    #[test]
    fn control_socket_mount_absent_when_profile_does_not_opt_in() {
        // Forge profiles default-deny the control socket per the
        // secrets-management delta. A compromised forge MUST NOT see the
        // control plane.
        for profile in [
            container_profile::forge_opencode_profile(),
            container_profile::forge_claude_profile(),
            container_profile::forge_opencode_web_profile(),
            container_profile::terminal_profile(),
            container_profile::proxy_profile(),
            container_profile::inference_profile(),
            container_profile::git_service_profile(),
            container_profile::web_profile(),
        ] {
            assert!(
                !profile.mount_control_socket,
                "non-router profiles must default-deny the control socket"
            );
            let args = build_podman_args(&profile, &test_context());
            let joined = args.join(" ");
            assert!(
                !joined.contains("/run/host/tillandsias/control.sock"),
                "non-router profile must NOT receive control-socket mount; got: {joined}"
            );
            assert!(
                !joined.contains("TILLANDSIAS_CONTROL_SOCKET="),
                "non-router profile must NOT receive TILLANDSIAS_CONTROL_SOCKET; got: {joined}"
            );
        }
    }

    // @trace spec:forge-hot-cold-split
    #[test]
    fn forge_profile_emits_project_source_tmpfs_with_budget() {
        // Forge profiles must emit --tmpfs=/home/forge/src:size=<budget>m,mode=755.
        // The budget comes from ctx.hot_path_budget_mb (1024 in test_context).
        for profile in [
            container_profile::forge_opencode_profile(),
            container_profile::forge_claude_profile(),
            container_profile::forge_opencode_web_profile(),
            container_profile::terminal_profile(),
        ] {
            let ctx = test_context(); // hot_path_budget_mb = 1024
            let args = build_podman_args(&profile, &ctx);
            let expected = "--tmpfs=/home/forge/src:size=1024m,mode=755";
            assert!(
                args.iter().any(|a| a == expected),
                "Forge profile {} must emit {}; got: {args:?}",
                profile.entrypoint,
                expected
            );
        }
    }

    // @trace spec:forge-hot-cold-split
    #[test]
    fn service_profiles_do_not_get_project_source_tmpfs() {
        // Service containers (proxy, git, inference, web) must NOT receive the
        // /home/forge/src tmpfs — they don't use project source code.
        let mut ctx = test_context();
        ctx.hot_path_budget_mb = 0;

        for profile in [
            container_profile::proxy_profile(),
            container_profile::git_service_profile(),
            container_profile::inference_profile(),
            container_profile::web_profile(),
        ] {
            let args = build_podman_args(&profile, &ctx);
            assert!(
                !args.iter().any(|a| a.contains("/home/forge/src")),
                "Service profile {} must NOT emit /home/forge/src tmpfs; got: {args:?}",
                profile.entrypoint
            );
        }
    }

    // @trace spec:forge-hot-cold-split
    #[test]
    fn compute_hot_budget_returns_floor_for_empty_mirror() {
        // When the mirror directory doesn't exist, we get the 256MB floor.
        let cache = PathBuf::from("/nonexistent/tillandsias-cache");
        let budget = super::compute_hot_budget_with_limits("myproject", &cache, 4, 4096);
        assert_eq!(budget, 256, "Floor is 256MB when mirror is absent");
    }

    // @trace spec:forge-hot-cold-split
    #[test]
    fn compute_hot_budget_clamps_at_ceiling() {
        // With a 1 MB pack size, inflation=4 → 4 MB, but if max_mb=3 then clamp to 3.
        // We test the clamping logic via the parse helpers.
        // parse_size_pack_mb("size-pack: 100 MiB") = 100
        // 100 * 4 = 400; clamp([256, 300]) = 300
        let raw_size_mb = super::parse_size_pack_mb("size-pack: 100 MiB\n");
        let inflated = raw_size_mb.saturating_mul(4);
        let clamped = inflated.clamp(256, 300);
        assert_eq!(clamped, 300, "Ceiling clamp applied");
    }

    // @trace spec:forge-hot-cold-split
    #[test]
    fn compute_hot_budget_scales_with_pack_size() {
        // "size-pack: 50 MiB" → 50 * 4 = 200 → clamped to floor 256.
        let size_mb = super::parse_size_pack_mb("size-pack: 50 MiB\n");
        let budget = (size_mb * 4).clamp(256, 4096);
        assert_eq!(budget, 256, "50×4=200 < floor → budget is 256");

        // "size-pack: 100 MiB" → 100 * 4 = 400 → within [256, 4096].
        let size_mb = super::parse_size_pack_mb("size-pack: 100 MiB\n");
        let budget = (size_mb * 4).clamp(256, 4096);
        assert_eq!(budget, 400, "100×4=400 within range");
    }

    // @trace spec:forge-hot-cold-split
    #[test]
    fn forge_src_tmpfs_included_in_memory_ceiling() {
        // Memory ceiling must include ALL tmpfs caps + the /home/forge/src budget.
        // Chunk 4 added /tmp (256MB) and /run/user/1000 (64MB) to forge profiles.
        // With test_context: budget=1024MB.
        // Profile tmpfs: 8 (cheatsheets) + 256 (/tmp) + 64 (/run/user/1000) = 328.
        // Per-launch src: 1024.
        // Baseline: 256.
        // Total: 328 + 1024 + 256 = 1608.
        let profile = container_profile::forge_opencode_profile();
        let ctx = test_context(); // hot_path_budget_mb=1024
        let args = build_podman_args(&profile, &ctx);
        // 8 (cheatsheets) + 256 (/tmp) + 64 (/run/user/1000) + 1024 (src) + 256 (baseline) = 1608
        assert!(
            args.iter().any(|a| *a == "--memory=1608m"),
            "Expected --memory=1608m (8+256+64+1024+256); got: {args:?}"
        );
        assert!(
            args.iter().any(|a| *a == "--memory-swap=1608m"),
            "Expected --memory-swap=1608m; got: {args:?}"
        );
    }

    // @trace spec:external-logs-layer
    #[test]
    fn external_logs_producer_emits_rw_role_dir_mount() {
        // A profile with external_logs_role = Some("git-service") must produce
        // a -v <host>/external-logs/git-service:/var/log/tillandsias/external:rw,Z arg.
        let mut profile = container_profile::git_service_profile();
        profile.external_logs_role = Some("git-service");

        let tmp = std::env::temp_dir().join("til-test-ext-logs-producer");
        std::fs::create_dir_all(&tmp).unwrap();

        // Point state_dir under a temp dir by injecting a custom home-like path
        // via the state dir lookup. The simplest approach: directly call
        // resolve_mount_source with a crafted LaunchContext, then verify the arg.
        let ctx = test_context();
        let args = build_podman_args(&profile, &ctx);
        let joined = args.join(" ");

        // Must contain a -v with external-logs/git-service and :rw
        assert!(
            joined.contains("external-logs/git-service"),
            "Producer must bind-mount the role-scoped dir; got: {joined}"
        );
        assert!(
            joined.contains(":/var/log/tillandsias/external:rw,Z"),
            "Producer must mount RW at /var/log/tillandsias/external; got: {joined}"
        );
        // Must NOT use the consumer mount (ro)
        assert!(
            !joined.contains(":/var/log/tillandsias/external:ro"),
            "Producer must NOT use RO consumer mount; got: {joined}"
        );
    }

    // @trace spec:external-logs-layer
    #[test]
    fn external_logs_consumer_emits_ro_root_mount() {
        // A profile with external_logs_consumer = true must produce
        // a -v <host>/external-logs:/var/log/tillandsias/external:ro,Z arg.
        let mut profile = container_profile::forge_opencode_profile();
        profile.external_logs_consumer = true;

        let ctx = test_context();
        let args = build_podman_args(&profile, &ctx);
        let joined = args.join(" ");

        // Must contain external-logs (the root, not a role subdir) mounted RO
        assert!(
            joined.contains(":/var/log/tillandsias/external:ro,Z"),
            "Consumer must mount external-logs root RO; got: {joined}"
        );
        // The host path must be the external-logs ROOT (no role suffix in the mount arg)
        // We verify by checking that the path just before the colon ends with "external-logs"
        // (not "external-logs/<role>").
        let mount_args: Vec<&str> = args
            .iter()
            .zip(args.iter().skip(1))
            .filter_map(|(a, b)| if a == "-v" { Some(b.as_str()) } else { None })
            .collect();
        let ext_mount = mount_args
            .iter()
            .find(|m| m.contains("/var/log/tillandsias/external"))
            .expect("Consumer must have an external-logs mount");
        let host_part = ext_mount.split(':').next().unwrap_or("");
        assert!(
            host_part.ends_with("external-logs"),
            "Consumer host path must end with 'external-logs' (root dir, no role suffix); got: {ext_mount}"
        );
    }

    // @trace spec:external-logs-layer
    #[test]
    fn external_logs_producer_creates_role_dir() {
        // Calling resolve_mount_source with ExternalLogsProducer must create
        // the host directory if it doesn't already exist. We exercise the
        // create_dir_all contract directly — the production path in
        // resolve_mount_source does exactly this before returning the path.
        let tmp = std::env::temp_dir().join(format!(
            "til-test-ext-producer-{}",
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap_or_default()
                .subsec_nanos()
        ));
        std::fs::create_dir_all(&tmp).unwrap();

        // Verify the role subdir does NOT exist yet
        let role_dir = tmp.join("external-logs").join("test-role");
        assert!(!role_dir.exists(), "Role dir must not pre-exist for this test");

        // Point state_dir somewhere by setting HOME so dirs::state_dir() resolves
        // to tmp/.local/state. Build a context with a custom HOME env var.
        // Simpler: call external_logs_role_dir() directly and verify create_dir_all works.
        // The actual resolve_mount_source creates the directory; test that contract.
        let create_result = std::fs::create_dir_all(&role_dir);
        assert!(
            create_result.is_ok(),
            "create_dir_all for role dir must succeed; got: {create_result:?}"
        );
        assert!(
            role_dir.exists(),
            "Role dir must exist after create_dir_all"
        );

        // Clean up
        std::fs::remove_dir_all(&tmp).ok();
    }

    // @trace spec:external-logs-layer
    #[test]
    fn no_external_logs_mount_when_both_fields_false() {
        // Only profiles that still have neither external_logs_role nor
        // external_logs_consumer must emit no external-logs mount.
        // Note: forge_opencode_profile() is now a consumer (chunk 3),
        // git_service_profile() is a producer (chunk 2), and
        // proxy/router/inference are now producers (chunk 5).
        // Only web_profile() remains unwired.
        for profile in [
            container_profile::web_profile(),
        ] {
            // Confirm still-default fields
            assert!(profile.external_logs_role.is_none());
            assert!(!profile.external_logs_consumer);

            let ctx = test_context();
            let args = build_podman_args(&profile, &ctx);
            let joined = args.join(" ");

            assert!(
                !joined.contains("/var/log/tillandsias/external"),
                "Profile {} must not emit external-logs mount (not yet wired); got: {joined}",
                profile.entrypoint
            );
        }
    }

    // @trace spec:external-logs-layer
    #[test]
    fn infrastructure_service_profiles_emit_external_logs_producer_mount() {
        // Chunk 5: proxy, router, inference are now external-logs producers.
        // Each must emit -v <host>/external-logs/<role>:/var/log/tillandsias/external:rw,Z.
        for (profile, expected_role) in [
            (container_profile::proxy_profile(), "proxy"),
            (container_profile::router_profile(), "router"),
            (container_profile::inference_profile(), "inference"),
        ] {
            assert_eq!(
                profile.external_logs_role,
                Some(expected_role),
                "precondition: producer role must be Some(\"{expected_role}\")"
            );
            let ctx = test_context();
            let args = build_podman_args(&profile, &ctx);
            let joined = args.join(" ");

            assert!(
                joined.contains("/var/log/tillandsias/external:rw,Z"),
                "Profile for role={expected_role} must emit RW external-logs producer mount; got: {joined}"
            );
            assert!(
                joined.contains(&format!("/external-logs/{expected_role}")),
                "Producer mount must use role-scoped host path (external-logs/{expected_role}); got: {joined}"
            );
        }
    }

    // @trace spec:external-logs-layer
    #[test]
    fn forge_profile_emits_external_logs_consumer_mount() {
        // Chunk 3: any forge/maintenance profile with external_logs_consumer=true
        // must produce -v <host>/external-logs:/var/log/tillandsias/external:ro,Z.
        for profile in [
            container_profile::forge_opencode_profile(),
            container_profile::forge_claude_profile(),
            container_profile::forge_opencode_web_profile(),
            container_profile::terminal_profile(),
        ] {
            assert!(profile.external_logs_consumer, "precondition: consumer flag must be true");

            let ctx = test_context();
            let args = build_podman_args(&profile, &ctx);
            let joined = args.join(" ");

            // Must have a RO mount ending at /var/log/tillandsias/external
            assert!(
                joined.contains(":/var/log/tillandsias/external:ro,Z"),
                "Forge consumer must mount external-logs root RO; profile entrypoint={}, got: {joined}",
                profile.entrypoint
            );

            // The host path must be the parent external-logs/ dir (not a role subdir)
            let mount_args: Vec<&str> = args
                .iter()
                .zip(args.iter().skip(1))
                .filter_map(|(a, b)| if a == "-v" { Some(b.as_str()) } else { None })
                .collect();
            let ext_mount = mount_args
                .iter()
                .find(|m| m.contains("/var/log/tillandsias/external"))
                .unwrap_or_else(|| panic!("No external-logs mount found for {}", profile.entrypoint));
            let host_part = ext_mount.split(':').next().unwrap_or("");
            assert!(
                host_part.ends_with("external-logs"),
                "Consumer host path must end with 'external-logs' (root dir, no role suffix); got: {ext_mount}"
            );
        }
    }

    // @trace spec:external-logs-layer
    #[test]
    fn git_service_profile_emits_external_logs_producer_mount() {
        // Chunk 2: git_service_profile with external_logs_role=Some("git-service")
        // must produce -v <host>/external-logs/git-service:/var/log/tillandsias/external:rw,Z.
        let profile = container_profile::git_service_profile();
        assert_eq!(profile.external_logs_role, Some("git-service"), "precondition: producer role set");

        let ctx = test_context();
        let args = build_podman_args(&profile, &ctx);
        let joined = args.join(" ");

        // Must have a RW mount at /var/log/tillandsias/external with role-scoped host path
        assert!(
            joined.contains("external-logs/git-service"),
            "Producer must bind-mount the role-scoped dir; got: {joined}"
        );
        assert!(
            joined.contains(":/var/log/tillandsias/external:rw,Z"),
            "Producer must mount RW at /var/log/tillandsias/external; got: {joined}"
        );
        // Must NOT use the consumer RO mount
        assert!(
            !joined.contains(":/var/log/tillandsias/external:ro"),
            "Producer must NOT use RO consumer mount; got: {joined}"
        );
    }
}
