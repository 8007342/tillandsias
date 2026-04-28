//! Scripts and image sources embedded in the binary at compile time.
//!
//! Every executable script and image source file is baked into the signed
//! binary via `include_str!`. At runtime they are extracted to a temporary
//! directory under `$XDG_RUNTIME_DIR/tillandsias/` (RAM-backed, per-session),
//! executed, and cleaned up.
//!
//! This closes the supply-chain gap where unsigned scripts in
//! `~/.local/share/tillandsias/` could be tampered with.
//!
//! @trace spec:embedded-scripts, spec:default-image

use std::fs;
use std::path::PathBuf;

#[cfg(unix)]
use std::os::unix::fs::PermissionsExt;

use tracing::{debug, warn};

/// Strip the Windows extended-path prefix `\\?\` (and `\\?\UNC\`) from a path.
///
/// `Path::canonicalize()` on Windows returns paths in the extended form
/// `\\?\C:\Users\foo` to bypass the legacy MAX_PATH=260 limit. Most consumers
/// (including git, podman, tracing log fields) handle this fine — but `git
/// clone <source>` parses the leading `\\` as a UNC URL and then chokes on
/// the `?` character with "hostname contains invalid characters".
///
/// This helper strips the `\\?\` prefix when the remainder is a normal
/// drive-letter path. UNC paths (`\\?\UNC\server\share`) are *not* simplified
/// because there is no shorter form for them.
///
/// On non-Windows, returns the path unchanged.
///
/// @trace spec:cli-mode, spec:cross-platform, spec:fix-windows-extended-path
pub fn simplify_path(path: &std::path::Path) -> PathBuf {
    if !cfg!(target_os = "windows") {
        return path.to_path_buf();
    }
    let s = path.to_string_lossy();
    // Strip `\\?\` if followed by a drive letter (e.g. `\\?\C:\foo`).
    // Leave `\\?\UNC\server\share` alone — UNC paths cannot be simplified.
    if let Some(rest) = s.strip_prefix(r"\\?\")
        && !rest.starts_with("UNC\\") && rest.len() >= 2 && rest.as_bytes()[1] == b':' {
            return PathBuf::from(rest);
        }
    path.to_path_buf()
}

// @tombstone obsolete:bash-path-helper
// Removed 2026-04-27 in v0.1.170. Safe to delete after v0.1.170.250.
// MSYS2 path conversion is no longer needed — bash scripts have been
// replaced with direct podman/gh CLI calls from Rust on all platforms.
// The helper was only used for the `build-image.sh` and `gh-auth-login.sh`
// workarounds on Windows.

/// Write content to a file, stripping \r so scripts work inside Linux
/// containers even when compiled on Windows with core.autocrlf=true.
fn write_lf(path: &std::path::Path, content: &str) -> std::io::Result<()> {
    if content.contains('\r') {
        fs::write(path, content.replace('\r', ""))
    } else {
        fs::write(path, content)
    }
}

// ---------------------------------------------------------------------------
// Executable scripts
// ---------------------------------------------------------------------------
// @tombstone obsolete:embedded-build-image-script
// Removed 2026-04-27 in v0.1.170. Safe to delete after v0.1.170.250.
// Image builds are now driven directly from Rust via ImageBuilder::run(),
// which calls `podman build` directly. The bash script is kept in the repo
// for manual developer use but is no longer embedded or extracted at runtime.

// build-tools-overlay.sh tombstoned 2026-04-25 — agents are hard-installed in
// the forge image; no runtime overlay build required.
// @trace spec:tombstone-tools-overlay
// @trace spec:native-secrets-store
// GitHub login is driven from Rust (`runner::run_github_login`): `gh auth
// login` runs via `podman exec` against a keep-alive git-service container,
// the token is harvested with `gh auth token`, stored in the OS keyring,
// and the container is torn down. No embedded shell wrapper needed.

// ---------------------------------------------------------------------------
// Image sources — flake
// ---------------------------------------------------------------------------
pub const FLAKE_NIX: &str = include_str!("../../flake.nix");
pub const FLAKE_LOCK: &str = include_str!("../../flake.lock");

// ---------------------------------------------------------------------------
// Image sources — router (Caddy reverse proxy)
// @trace spec:subdomain-routing-via-reverse-proxy
// ---------------------------------------------------------------------------
pub const ROUTER_CONTAINERFILE: &str = include_str!("../../images/router/Containerfile");
pub const ROUTER_BASE_CADDYFILE: &str = include_str!("../../images/router/base.Caddyfile");
pub const ROUTER_ENTRYPOINT: &str = include_str!("../../images/router/entrypoint.sh");
pub const ROUTER_RELOAD_SCRIPT: &str = include_str!("../../images/router/router-reload.sh");
// @trace spec:external-logs-layer
pub const ROUTER_EXTERNAL_LOGS_MANIFEST: &str =
    include_str!("../../images/router/external-logs.yaml");
// @trace spec:opencode-web-session-otp
// Pre-built static-musl binary (~2.5 MB stripped). Built by
// `scripts/build-sidecar.sh`, kicked off automatically by
// `src-tauri/build.rs` so a plain `cargo build` of the tray Just Works.
// The binary ships embedded so deployed tray instances can rebuild the
// router image without the workspace source on disk.
pub const ROUTER_SIDECAR_BINARY: &[u8] =
    include_bytes!("../../images/router/tillandsias-router-sidecar");

// ---------------------------------------------------------------------------
// Image sources — forge (default) image
// ---------------------------------------------------------------------------
pub const FORGE_ENTRYPOINT: &str = include_str!("../../images/default/entrypoint.sh");
pub const FORGE_LIB_COMMON: &str = include_str!("../../images/default/lib-common.sh");
pub const FORGE_ENTRYPOINT_OPENCODE: &str =
    include_str!("../../images/default/entrypoint-forge-opencode.sh");
// @trace spec:opencode-web-session, spec:default-image
pub const FORGE_ENTRYPOINT_OPENCODE_WEB: &str =
    include_str!("../../images/default/entrypoint-forge-opencode-web.sh");
pub const FORGE_ENTRYPOINT_CLAUDE: &str =
    include_str!("../../images/default/entrypoint-forge-claude.sh");
pub const FORGE_ENTRYPOINT_TERMINAL: &str =
    include_str!("../../images/default/entrypoint-terminal.sh");
// @trace spec:opencode-web-session
// Node.js SSE keepalive proxy — fronts `opencode serve` so Bun's default
// 10s HTTP idleTimeout doesn't drop `/event` / `/global/event` streams
// when the session goes idle.
pub const FORGE_SSE_KEEPALIVE_PROXY: &str =
    include_str!("../../images/default/sse-keepalive-proxy.js");
pub const FORGE_WELCOME: &str = include_str!("../../images/default/forge-welcome.sh");
pub const FORGE_CONTAINERFILE: &str = include_str!("../../images/default/Containerfile");
pub const FORGE_OPENCODE_JSON: &str = include_str!("../../images/default/opencode.json");
// @trace spec:cheatsheets-license-tiered, spec:external-logs-layer
// Forge container's external-logs producer manifest — declares the
// cheatsheet-telemetry role's lookups.jsonl as the only permitted file in
// /var/log/tillandsias/external/cheatsheet-telemetry/. Baked at
// /etc/tillandsias/external-logs.yaml; consumed by the tray-side auditor.
pub const FORGE_EXTERNAL_LOGS_MANIFEST: &str =
    include_str!("../../images/default/external-logs.yaml");

// @trace spec:forge-environment-discoverability
// Four discoverability CLIs the agent invokes on first turn to learn what
// the forge ships. COPY'd into /opt/agents/tillandsias-cli/bin in the image
// build (see images/default/Containerfile) and symlinked into /usr/local/bin.
pub const FORGE_CLI_INVENTORY: &str =
    include_str!("../../images/default/cli/tillandsias-inventory");
pub const FORGE_CLI_SERVICES: &str =
    include_str!("../../images/default/cli/tillandsias-services");
pub const FORGE_CLI_MODELS: &str = include_str!("../../images/default/cli/tillandsias-models");
pub const FORGE_CLI_LOGS: &str = include_str!("../../images/default/cli/tillandsias-logs");

// No forge GIT_ASKPASS const — the forge-side askpass was tombstoned.
// Forge containers have ZERO credentials; only the git-service container
// receives the ephemeral token (see images/git/git-askpass-tillandsias.sh
// + GIT_SERVICE_ASKPASS below).
// @trace spec:secrets-management, spec:forge-offline

// Config overlay — opinionated configs extracted to ramdisk (tmpfs)
// @trace spec:layered-tools-overlay
pub const CONFIG_OVERLAY_OPENCODE: &str =
    include_str!("../../images/default/config-overlay/opencode/config.json");

// @trace spec:opencode-web-session, spec:default-image
pub const CONFIG_OVERLAY_OPENCODE_TUI: &str =
    include_str!("../../images/default/config-overlay/opencode/tui.json");

// Config overlay — methodology instruction files for AI agents
// @trace spec:layered-tools-overlay
pub const CONFIG_OVERLAY_INSTRUCTIONS_METHODOLOGY: &str =
    include_str!("../../images/default/config-overlay/opencode/instructions/methodology.md");
pub const CONFIG_OVERLAY_INSTRUCTIONS_FLUTTER: &str =
    include_str!("../../images/default/config-overlay/opencode/instructions/flutter.md");
pub const CONFIG_OVERLAY_INSTRUCTIONS_MODEL_ROUTING: &str =
    include_str!("../../images/default/config-overlay/opencode/instructions/model-routing.md");
pub const CONFIG_OVERLAY_INSTRUCTIONS_WEB_SERVICES: &str =
    include_str!("../../images/default/config-overlay/opencode/instructions/web-services.md");

// Summarizer scripts for project analysis
// @trace spec:project-bootstrap-readme, spec:default-image
pub const SCRIPT_SUMMARIZE_CARGO: &str = include_str!("../../scripts/summarize-cargo.sh");
pub const SCRIPT_SUMMARIZE_NIX: &str = include_str!("../../scripts/summarize-nix.sh");
pub const SCRIPT_SUMMARIZE_PACKAGE_JSON: &str = include_str!("../../scripts/summarize-package-json.sh");
pub const SCRIPT_SUMMARIZE_PUBSPEC: &str = include_str!("../../scripts/summarize-pubspec.sh");
pub const SCRIPT_SUMMARIZE_GO_MOD: &str = include_str!("../../scripts/summarize-go-mod.sh");
pub const SCRIPT_SUMMARIZE_PYPROJECT: &str = include_str!("../../scripts/summarize-pyproject.sh");

// Config overlay — agent skills and workflows
// @trace spec:project-bootstrap-readme, spec:default-image
pub const CONFIG_OVERLAY_AGENT_STARTUP: &str =
    include_str!("../../images/default/config-overlay/opencode/agent/startup.md");
pub const CONFIG_OVERLAY_AGENT_STATUS: &str =
    include_str!("../../images/default/config-overlay/opencode/agent/status.md");
pub const CONFIG_OVERLAY_AGENT_BOOTSTRAP_README: &str =
    include_str!("../../images/default/config-overlay/opencode/agent/bootstrap-readme.md");
pub const CONFIG_OVERLAY_AGENT_BOOTSTRAP_README_AND_PROJECT: &str =
    include_str!("../../images/default/config-overlay/opencode/agent/bootstrap-readme-and-project.md");

// MCP servers — lightweight tool scripts for forge containers
// @trace spec:layered-tools-overlay, spec:git-mirror-service, spec:host-browser-mcp
pub const CONFIG_OVERLAY_MCP_GIT_TOOLS: &str =
    include_str!("../../images/default/config-overlay/mcp/git-tools.sh");
pub const CONFIG_OVERLAY_MCP_PROJECT_INFO: &str =
    include_str!("../../images/default/config-overlay/mcp/project-info.sh");
pub const CONFIG_OVERLAY_MCP_HOST_BROWSER: &str =
    include_str!("../../images/default/config-overlay/mcp/host-browser.sh");

// Shell configs
pub const SHELL_BASHRC: &str = include_str!("../../images/default/shell/bashrc");
pub const SHELL_FISH_CONFIG: &str = include_str!("../../images/default/shell/config.fish");
pub const SHELL_ZSHRC: &str = include_str!("../../images/default/shell/zshrc");

// Locale files
pub const LOCALE_EN: &str = include_str!("../../images/default/locales/en.sh");
pub const LOCALE_ES: &str = include_str!("../../images/default/locales/es.sh");
pub const LOCALE_JA: &str = include_str!("../../images/default/locales/ja.sh");
pub const LOCALE_ZH_HANT: &str = include_str!("../../images/default/locales/zh-Hant.sh");
pub const LOCALE_ZH_HANS: &str = include_str!("../../images/default/locales/zh-Hans.sh");
pub const LOCALE_AR: &str = include_str!("../../images/default/locales/ar.sh");
pub const LOCALE_KO: &str = include_str!("../../images/default/locales/ko.sh");
pub const LOCALE_HI: &str = include_str!("../../images/default/locales/hi.sh");
pub const LOCALE_TA: &str = include_str!("../../images/default/locales/ta.sh");
pub const LOCALE_TE: &str = include_str!("../../images/default/locales/te.sh");
pub const LOCALE_FR: &str = include_str!("../../images/default/locales/fr.sh");
pub const LOCALE_PT: &str = include_str!("../../images/default/locales/pt.sh");
pub const LOCALE_IT: &str = include_str!("../../images/default/locales/it.sh");
pub const LOCALE_RO: &str = include_str!("../../images/default/locales/ro.sh");
pub const LOCALE_RU: &str = include_str!("../../images/default/locales/ru.sh");
pub const LOCALE_NAH: &str = include_str!("../../images/default/locales/nah.sh");
pub const LOCALE_DE: &str = include_str!("../../images/default/locales/de.sh");

// ---------------------------------------------------------------------------
// Image sources — web image
// ---------------------------------------------------------------------------
pub const WEB_ENTRYPOINT: &str = include_str!("../../images/web/entrypoint.sh");
pub const WEB_CONTAINERFILE: &str = include_str!("../../images/web/Containerfile");

// ---------------------------------------------------------------------------
// Image sources — proxy image
// @trace spec:proxy-container
// ---------------------------------------------------------------------------
pub const PROXY_ENTRYPOINT: &str = include_str!("../../images/proxy/entrypoint.sh");
pub const PROXY_CONTAINERFILE: &str = include_str!("../../images/proxy/Containerfile");
pub const PROXY_SQUID_CONF: &str = include_str!("../../images/proxy/squid.conf");
pub const PROXY_ALLOWLIST: &str = include_str!("../../images/proxy/allowlist.txt");
// @trace spec:external-logs-layer
pub const PROXY_EXTERNAL_LOGS_MANIFEST: &str =
    include_str!("../../images/proxy/external-logs.yaml");

// ---------------------------------------------------------------------------
// Image sources — git service image
// @trace spec:git-mirror-service
// ---------------------------------------------------------------------------
pub const GIT_ENTRYPOINT: &str = include_str!("../../images/git/entrypoint.sh");
pub const GIT_CONTAINERFILE: &str = include_str!("../../images/git/Containerfile");
pub const POST_RECEIVE_HOOK: &str = include_str!("../../images/git/post-receive-hook.sh");
// @trace spec:secrets-management, spec:git-mirror-service
pub const GIT_ASKPASS_TILLANDSIAS: &str =
    include_str!("../../images/git/git-askpass-tillandsias.sh");
// @trace spec:external-logs-layer
pub const GIT_EXTERNAL_LOGS_MANIFEST: &str =
    include_str!("../../images/git/external-logs.yaml");

// ---------------------------------------------------------------------------
// Image sources — inference image
// @trace spec:inference-container
// ---------------------------------------------------------------------------
pub const INFERENCE_ENTRYPOINT: &str = include_str!("../../images/inference/entrypoint.sh");
pub const INFERENCE_CONTAINERFILE: &str = include_str!("../../images/inference/Containerfile");
// @trace spec:external-logs-layer
pub const INFERENCE_EXTERNAL_LOGS_MANIFEST: &str =
    include_str!("../../images/inference/external-logs.yaml");

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

/// Runtime temp directory for embedded scripts.
///
/// Prefers `$XDG_RUNTIME_DIR/tillandsias/` (RAM-backed, per-session on Linux).
/// Falls back to `$TMPDIR/tillandsias-embedded/`.
fn runtime_dir() -> PathBuf {
    if let Ok(xdg) = std::env::var("XDG_RUNTIME_DIR") {
        PathBuf::from(xdg).join("tillandsias")
    } else {
        std::env::temp_dir().join("tillandsias-embedded")
    }
}

/// Write a script to the runtime temp directory with 0700 permissions.
///
/// Returns the absolute path to the written file.
#[allow(dead_code)]
pub fn write_temp_script(name: &str, content: &str) -> Result<PathBuf, String> {
    let dir = runtime_dir();
    fs::create_dir_all(&dir).map_err(|e| format!("Cannot create temp dir: {e}"))?;

    let path = dir.join(name);
    write_lf(&path, content).map_err(|e| format!("Cannot write {name}: {e}"))?;

    #[cfg(unix)]
    fs::set_permissions(&path, fs::Permissions::from_mode(0o700))
        .map_err(|e| format!("Cannot set permissions on {name}: {e}"))?;

    debug!(path = %path.display(), "Wrote embedded script to temp");
    Ok(path)
}

/// Write the full image source tree to a temp directory.
///
/// Recreates the directory layout that `nix build` and direct `podman build`
/// commands expect:
///
/// ```text
/// <dir>/
///   flake.nix
///   flake.lock
///   images/
///     default/
///       entrypoint.sh
///       Containerfile
///       opencode.json
///       skills/command/{bash,bash-private}.md
///       shell/{bashrc,config.fish,zshrc}
///       config-overlay/opencode/config.json
///       config-overlay/mcp/{git-tools,project-info}.sh
///       locales/{en,es,ja,zh-Hant,zh-Hans,ar,ko,hi,ta,te,fr,pt,it,ro,ru,nah,de}.sh
///     web/
///       entrypoint.sh
///       Containerfile
///     git/
///       entrypoint.sh
///       Containerfile
///       post-receive-hook.sh
///     inference/
///       entrypoint.sh
///       Containerfile
/// ```
///
/// Note: `scripts/build-image.sh` is no longer extracted. Image builds are
/// driven directly from Rust via `ImageBuilder::run()` which calls `podman build`.
///
/// Returns the root temp directory path. The caller should clean up via
/// [`cleanup_image_sources`] after the build completes (or rely on
/// session cleanup of `$XDG_RUNTIME_DIR`).
// @trace spec:embedded-scripts/image-source-extraction, spec:direct-podman-calls
pub fn write_image_sources() -> Result<PathBuf, String> {
    // Use a per-process directory to avoid collisions between the tray app's
    // background build and concurrent CLI invocations.
    let pid = std::process::id();
    let dir = runtime_dir().join(format!("image-sources-{pid}"));

    // Recreate fresh each time
    let _ = fs::remove_dir_all(&dir);
    fs::create_dir_all(&dir).map_err(|e| format!("Cannot create image sources dir: {e}"))?;

    // -- Flake files --
    write_lf(&dir.join("flake.nix"), FLAKE_NIX).map_err(|e| format!("flake.nix: {e}"))?;
    write_lf(&dir.join("flake.lock"), FLAKE_LOCK).map_err(|e| format!("flake.lock: {e}"))?;

    // -- Scripts --
    // @tombstone obsolete:embedded-build-image-script
    // build-image.sh is no longer extracted. Image builds are driven from Rust.
    // build-tools-overlay.sh not emitted — tombstoned 2026-04-25.
    // @trace spec:tombstone-tools-overlay

    // -- scripts/ (summarizers for project analysis) --
    let scripts_dir = dir.join("scripts");
    fs::create_dir_all(&scripts_dir).map_err(|e| format!("scripts dir: {e}"))?;
    write_lf(&scripts_dir.join("summarize-cargo.sh"), SCRIPT_SUMMARIZE_CARGO)
        .map_err(|e| format!("scripts/summarize-cargo.sh: {e}"))?;
    write_lf(&scripts_dir.join("summarize-nix.sh"), SCRIPT_SUMMARIZE_NIX)
        .map_err(|e| format!("scripts/summarize-nix.sh: {e}"))?;
    write_lf(&scripts_dir.join("summarize-package-json.sh"), SCRIPT_SUMMARIZE_PACKAGE_JSON)
        .map_err(|e| format!("scripts/summarize-package-json.sh: {e}"))?;
    write_lf(&scripts_dir.join("summarize-pubspec.sh"), SCRIPT_SUMMARIZE_PUBSPEC)
        .map_err(|e| format!("scripts/summarize-pubspec.sh: {e}"))?;
    write_lf(&scripts_dir.join("summarize-go-mod.sh"), SCRIPT_SUMMARIZE_GO_MOD)
        .map_err(|e| format!("scripts/summarize-go-mod.sh: {e}"))?;
    write_lf(&scripts_dir.join("summarize-pyproject.sh"), SCRIPT_SUMMARIZE_PYPROJECT)
        .map_err(|e| format!("scripts/summarize-pyproject.sh: {e}"))?;

    // -- images/default/ --
    let default_dir = dir.join("images").join("default");
    fs::create_dir_all(&default_dir).map_err(|e| format!("images/default dir: {e}"))?;
    write_lf(&default_dir.join("entrypoint.sh"), FORGE_ENTRYPOINT)
        .map_err(|e| format!("entrypoint.sh: {e}"))?;
    write_lf(&default_dir.join("lib-common.sh"), FORGE_LIB_COMMON)
        .map_err(|e| format!("lib-common.sh: {e}"))?;
    write_lf(
        &default_dir.join("entrypoint-forge-opencode.sh"),
        FORGE_ENTRYPOINT_OPENCODE,
    )
    .map_err(|e| format!("entrypoint-forge-opencode.sh: {e}"))?;
    // @trace spec:opencode-web-session, spec:default-image
    write_lf(
        &default_dir.join("entrypoint-forge-opencode-web.sh"),
        FORGE_ENTRYPOINT_OPENCODE_WEB,
    )
    .map_err(|e| format!("entrypoint-forge-opencode-web.sh: {e}"))?;
    write_lf(
        &default_dir.join("entrypoint-forge-claude.sh"),
        FORGE_ENTRYPOINT_CLAUDE,
    )
    .map_err(|e| format!("entrypoint-forge-claude.sh: {e}"))?;
    write_lf(
        &default_dir.join("entrypoint-terminal.sh"),
        FORGE_ENTRYPOINT_TERMINAL,
    )
    .map_err(|e| format!("entrypoint-terminal.sh: {e}"))?;
    // @trace spec:opencode-web-session
    write_lf(
        &default_dir.join("sse-keepalive-proxy.js"),
        FORGE_SSE_KEEPALIVE_PROXY,
    )
    .map_err(|e| format!("sse-keepalive-proxy.js: {e}"))?;
    write_lf(&default_dir.join("forge-welcome.sh"), FORGE_WELCOME)
        .map_err(|e| format!("forge-welcome.sh: {e}"))?;
    write_lf(&default_dir.join("Containerfile"), FORGE_CONTAINERFILE)
        .map_err(|e| format!("Containerfile: {e}"))?;
    write_lf(&default_dir.join("opencode.json"), FORGE_OPENCODE_JSON)
        .map_err(|e| format!("opencode.json: {e}"))?;
    // @trace spec:cheatsheets-license-tiered, spec:external-logs-layer
    write_lf(
        &default_dir.join("external-logs.yaml"),
        FORGE_EXTERNAL_LOGS_MANIFEST,
    )
    .map_err(|e| format!("forge external-logs.yaml: {e}"))?;

    // @trace spec:forge-environment-discoverability
    let cli_dir = default_dir.join("cli");
    fs::create_dir_all(&cli_dir).map_err(|e| format!("cli dir: {e}"))?;
    write_lf(&cli_dir.join("tillandsias-inventory"), FORGE_CLI_INVENTORY)
        .map_err(|e| format!("cli/tillandsias-inventory: {e}"))?;
    write_lf(&cli_dir.join("tillandsias-services"), FORGE_CLI_SERVICES)
        .map_err(|e| format!("cli/tillandsias-services: {e}"))?;
    write_lf(&cli_dir.join("tillandsias-models"), FORGE_CLI_MODELS)
        .map_err(|e| format!("cli/tillandsias-models: {e}"))?;
    write_lf(&cli_dir.join("tillandsias-logs"), FORGE_CLI_LOGS)
        .map_err(|e| format!("cli/tillandsias-logs: {e}"))?;

    // No forge GIT_ASKPASS — tombstoned.
    // @trace spec:secrets-management
    #[cfg(unix)]
    {
        // Scripts in scripts/ directory
        for name in [
            "summarize-cargo.sh",
            "summarize-nix.sh",
            "summarize-package-json.sh",
            "summarize-pubspec.sh",
            "summarize-go-mod.sh",
            "summarize-pyproject.sh",
        ] {
            let path = scripts_dir.join(name);
            if let Err(e) = fs::set_permissions(&path, fs::Permissions::from_mode(0o755)) {
                warn!(
                    file = %path.display(),
                    error = %e,
                    "Failed to set executable permission — summarizer scripts may not run"
                );
            }
        }

        // Entrypoints and utilities in images/default/
        for name in [
            "entrypoint.sh",
            "entrypoint-forge-opencode.sh",
            // @trace spec:opencode-web-session
            "entrypoint-forge-opencode-web.sh",
            "entrypoint-forge-claude.sh",
            "entrypoint-terminal.sh",
            // @trace spec:opencode-web-session
            "sse-keepalive-proxy.js",
        ] {
            let path = default_dir.join(name);
            if let Err(e) = fs::set_permissions(&path, fs::Permissions::from_mode(0o755)) {
                warn!(
                    file = %path.display(),
                    error = %e,
                    "Failed to set executable permission — container entrypoint may fail"
                );
            }
        }
        // @trace spec:forge-environment-discoverability
        // Discoverability CLIs live under cli/; chmod separately because
        // the loop above only handles default-dir scripts.
        for name in [
            "tillandsias-inventory",
            "tillandsias-services",
            "tillandsias-models",
            "tillandsias-logs",
        ] {
            let path = cli_dir.join(name);
            if let Err(e) = fs::set_permissions(&path, fs::Permissions::from_mode(0o755)) {
                warn!(
                    file = %path.display(),
                    error = %e,
                    "Failed to set executable permission — discoverability CLI will not run"
                );
            }
        }
    }

    // Shell configs
    let shell_dir = default_dir.join("shell");
    fs::create_dir_all(&shell_dir).map_err(|e| format!("shell dir: {e}"))?;
    write_lf(&shell_dir.join("bashrc"), SHELL_BASHRC).map_err(|e| format!("bashrc: {e}"))?;
    write_lf(&shell_dir.join("config.fish"), SHELL_FISH_CONFIG)
        .map_err(|e| format!("config.fish: {e}"))?;
    write_lf(&shell_dir.join("zshrc"), SHELL_ZSHRC).map_err(|e| format!("zshrc: {e}"))?;

    // Config overlay — opinionated configs extracted to ramdisk at runtime
    // @trace spec:layered-tools-overlay
    let config_overlay_dir = default_dir.join("config-overlay").join("opencode");
    fs::create_dir_all(&config_overlay_dir)
        .map_err(|e| format!("config-overlay/opencode dir: {e}"))?;
    write_lf(
        &config_overlay_dir.join("config.json"),
        CONFIG_OVERLAY_OPENCODE,
    )
    .map_err(|e| format!("config-overlay/opencode/config.json: {e}"))?;
    // @trace spec:opencode-web-session, spec:default-image
    write_lf(
        &config_overlay_dir.join("tui.json"),
        CONFIG_OVERLAY_OPENCODE_TUI,
    )
    .map_err(|e| format!("config-overlay/opencode/tui.json: {e}"))?;

    // Config overlay — methodology instruction files for AI agents
    // @trace spec:layered-tools-overlay
    let instructions_dir = config_overlay_dir.join("instructions");
    fs::create_dir_all(&instructions_dir)
        .map_err(|e| format!("config-overlay/opencode/instructions dir: {e}"))?;
    write_lf(
        &instructions_dir.join("methodology.md"),
        CONFIG_OVERLAY_INSTRUCTIONS_METHODOLOGY,
    )
    .map_err(|e| format!("config-overlay/opencode/instructions/methodology.md: {e}"))?;
    write_lf(
        &instructions_dir.join("flutter.md"),
        CONFIG_OVERLAY_INSTRUCTIONS_FLUTTER,
    )
    .map_err(|e| format!("config-overlay/opencode/instructions/flutter.md: {e}"))?;
    write_lf(
        &instructions_dir.join("model-routing.md"),
        CONFIG_OVERLAY_INSTRUCTIONS_MODEL_ROUTING,
    )
    .map_err(|e| format!("config-overlay/opencode/instructions/model-routing.md: {e}"))?;
    write_lf(
        &instructions_dir.join("web-services.md"),
        CONFIG_OVERLAY_INSTRUCTIONS_WEB_SERVICES,
    )
    .map_err(|e| format!("config-overlay/opencode/instructions/web-services.md: {e}"))?;

    // Config overlay — agent skills and workflows
    // @trace spec:project-bootstrap-readme, spec:default-image
    let agent_dir = config_overlay_dir.join("agent");
    fs::create_dir_all(&agent_dir)
        .map_err(|e| format!("config-overlay/opencode/agent dir: {e}"))?;
    write_lf(
        &agent_dir.join("startup.md"),
        CONFIG_OVERLAY_AGENT_STARTUP,
    )
    .map_err(|e| format!("config-overlay/opencode/agent/startup.md: {e}"))?;
    write_lf(
        &agent_dir.join("status.md"),
        CONFIG_OVERLAY_AGENT_STATUS,
    )
    .map_err(|e| format!("config-overlay/opencode/agent/status.md: {e}"))?;
    write_lf(
        &agent_dir.join("bootstrap-readme.md"),
        CONFIG_OVERLAY_AGENT_BOOTSTRAP_README,
    )
    .map_err(|e| format!("config-overlay/opencode/agent/bootstrap-readme.md: {e}"))?;
    write_lf(
        &agent_dir.join("bootstrap-readme-and-project.md"),
        CONFIG_OVERLAY_AGENT_BOOTSTRAP_README_AND_PROJECT,
    )
    .map_err(|e| format!("config-overlay/opencode/agent/bootstrap-readme-and-project.md: {e}"))?;

    // Config overlay — MCP servers
    // @trace spec:layered-tools-overlay, spec:host-browser-mcp
    let mcp_dir = default_dir.join("config-overlay").join("mcp");
    fs::create_dir_all(&mcp_dir).map_err(|e| format!("config-overlay/mcp dir: {e}"))?;
    write_lf(&mcp_dir.join("git-tools.sh"), CONFIG_OVERLAY_MCP_GIT_TOOLS)
        .map_err(|e| format!("config-overlay/mcp/git-tools.sh: {e}"))?;
    write_lf(
        &mcp_dir.join("project-info.sh"),
        CONFIG_OVERLAY_MCP_PROJECT_INFO,
    )
    .map_err(|e| format!("config-overlay/mcp/project-info.sh: {e}"))?;
    write_lf(
        &mcp_dir.join("host-browser.sh"),
        CONFIG_OVERLAY_MCP_HOST_BROWSER,
    )
    .map_err(|e| format!("config-overlay/mcp/host-browser.sh: {e}"))?;
    #[cfg(unix)]
    {
        for name in ["git-tools.sh", "project-info.sh", "host-browser.sh"] {
            let path = mcp_dir.join(name);
            if let Err(e) = fs::set_permissions(&path, fs::Permissions::from_mode(0o755)) {
                warn!(
                    file = %path.display(),
                    error = %e,
                    "Failed to set executable permission — MCP server may fail"
                );
            }
        }
    }

    // Locale files
    let locales_dir = default_dir.join("locales");
    fs::create_dir_all(&locales_dir).map_err(|e| format!("locales dir: {e}"))?;
    write_lf(&locales_dir.join("en.sh"), LOCALE_EN).map_err(|e| format!("en.sh: {e}"))?;
    write_lf(&locales_dir.join("es.sh"), LOCALE_ES).map_err(|e| format!("es.sh: {e}"))?;
    write_lf(&locales_dir.join("ja.sh"), LOCALE_JA).map_err(|e| format!("ja.sh: {e}"))?;
    write_lf(&locales_dir.join("zh-Hant.sh"), LOCALE_ZH_HANT)
        .map_err(|e| format!("zh-Hant.sh: {e}"))?;
    write_lf(&locales_dir.join("zh-Hans.sh"), LOCALE_ZH_HANS)
        .map_err(|e| format!("zh-Hans.sh: {e}"))?;
    write_lf(&locales_dir.join("ar.sh"), LOCALE_AR).map_err(|e| format!("ar.sh: {e}"))?;
    write_lf(&locales_dir.join("ko.sh"), LOCALE_KO).map_err(|e| format!("ko.sh: {e}"))?;
    write_lf(&locales_dir.join("hi.sh"), LOCALE_HI).map_err(|e| format!("hi.sh: {e}"))?;
    write_lf(&locales_dir.join("ta.sh"), LOCALE_TA).map_err(|e| format!("ta.sh: {e}"))?;
    write_lf(&locales_dir.join("te.sh"), LOCALE_TE).map_err(|e| format!("te.sh: {e}"))?;
    write_lf(&locales_dir.join("fr.sh"), LOCALE_FR).map_err(|e| format!("fr.sh: {e}"))?;
    write_lf(&locales_dir.join("pt.sh"), LOCALE_PT).map_err(|e| format!("pt.sh: {e}"))?;
    write_lf(&locales_dir.join("it.sh"), LOCALE_IT).map_err(|e| format!("it.sh: {e}"))?;
    write_lf(&locales_dir.join("ro.sh"), LOCALE_RO).map_err(|e| format!("ro.sh: {e}"))?;
    write_lf(&locales_dir.join("ru.sh"), LOCALE_RU).map_err(|e| format!("ru.sh: {e}"))?;
    write_lf(&locales_dir.join("nah.sh"), LOCALE_NAH).map_err(|e| format!("nah.sh: {e}"))?;
    write_lf(&locales_dir.join("de.sh"), LOCALE_DE).map_err(|e| format!("de.sh: {e}"))?;

    // -- images/web/ --
    let web_dir = dir.join("images").join("web");
    fs::create_dir_all(&web_dir).map_err(|e| format!("images/web dir: {e}"))?;
    write_lf(&web_dir.join("entrypoint.sh"), WEB_ENTRYPOINT)
        .map_err(|e| format!("web entrypoint: {e}"))?;
    write_lf(&web_dir.join("Containerfile"), WEB_CONTAINERFILE)
        .map_err(|e| format!("web Containerfile: {e}"))?;
    #[cfg(unix)]
    {
        let path = web_dir.join("entrypoint.sh");
        if let Err(e) = fs::set_permissions(&path, fs::Permissions::from_mode(0o755)) {
            warn!(
                file = %path.display(),
                error = %e,
                "Failed to set executable permission — container entrypoint may fail"
            );
        }
    }

    // -- images/proxy/ --
    // @trace spec:proxy-container
    let proxy_dir = dir.join("images").join("proxy");
    fs::create_dir_all(&proxy_dir).map_err(|e| format!("images/proxy dir: {e}"))?;
    write_lf(&proxy_dir.join("entrypoint.sh"), PROXY_ENTRYPOINT)
        .map_err(|e| format!("proxy entrypoint: {e}"))?;
    write_lf(&proxy_dir.join("Containerfile"), PROXY_CONTAINERFILE)
        .map_err(|e| format!("proxy Containerfile: {e}"))?;
    write_lf(&proxy_dir.join("squid.conf"), PROXY_SQUID_CONF)
        .map_err(|e| format!("proxy squid.conf: {e}"))?;
    write_lf(&proxy_dir.join("allowlist.txt"), PROXY_ALLOWLIST)
        .map_err(|e| format!("proxy allowlist: {e}"))?;
    // @trace spec:external-logs-layer
    write_lf(&proxy_dir.join("external-logs.yaml"), PROXY_EXTERNAL_LOGS_MANIFEST)
        .map_err(|e| format!("proxy external-logs.yaml: {e}"))?;
    #[cfg(unix)]
    {
        let path = proxy_dir.join("entrypoint.sh");
        if let Err(e) = fs::set_permissions(&path, fs::Permissions::from_mode(0o755)) {
            warn!(
                file = %path.display(),
                error = %e,
                "Failed to set executable permission — container entrypoint may fail"
            );
        }
    }

    // -- images/router/ --
    // @trace spec:subdomain-routing-via-reverse-proxy, spec:opencode-web-session-otp
    let router_dir = dir.join("images").join("router");
    fs::create_dir_all(&router_dir).map_err(|e| format!("images/router dir: {e}"))?;
    write_lf(&router_dir.join("Containerfile"), ROUTER_CONTAINERFILE)
        .map_err(|e| format!("router Containerfile: {e}"))?;
    write_lf(&router_dir.join("base.Caddyfile"), ROUTER_BASE_CADDYFILE)
        .map_err(|e| format!("router base.Caddyfile: {e}"))?;
    write_lf(&router_dir.join("entrypoint.sh"), ROUTER_ENTRYPOINT)
        .map_err(|e| format!("router entrypoint: {e}"))?;
    write_lf(&router_dir.join("router-reload.sh"), ROUTER_RELOAD_SCRIPT)
        .map_err(|e| format!("router-reload.sh: {e}"))?;
    // @trace spec:external-logs-layer
    write_lf(&router_dir.join("external-logs.yaml"), ROUTER_EXTERNAL_LOGS_MANIFEST)
        .map_err(|e| format!("router external-logs.yaml: {e}"))?;
    // @trace spec:opencode-web-session-otp
    // Sidecar binary (binary blob, not LF-normalised text — write raw).
    fs::write(
        router_dir.join("tillandsias-router-sidecar"),
        ROUTER_SIDECAR_BINARY,
    )
    .map_err(|e| format!("router sidecar binary: {e}"))?;
    #[cfg(unix)]
    {
        for name in ["entrypoint.sh", "router-reload.sh", "tillandsias-router-sidecar"] {
            let path = router_dir.join(name);
            if let Err(e) = fs::set_permissions(&path, fs::Permissions::from_mode(0o755)) {
                warn!(
                    file = %path.display(),
                    error = %e,
                    "Failed to set executable permission — router script"
                );
            }
        }
    }

    // -- images/git/ --
    // @trace spec:git-mirror-service
    let git_dir = dir.join("images").join("git");
    fs::create_dir_all(&git_dir).map_err(|e| format!("images/git dir: {e}"))?;
    write_lf(&git_dir.join("entrypoint.sh"), GIT_ENTRYPOINT)
        .map_err(|e| format!("git entrypoint: {e}"))?;
    write_lf(&git_dir.join("Containerfile"), GIT_CONTAINERFILE)
        .map_err(|e| format!("git Containerfile: {e}"))?;
    write_lf(&git_dir.join("post-receive-hook.sh"), POST_RECEIVE_HOOK)
        .map_err(|e| format!("git post-receive-hook: {e}"))?;
    // @trace spec:secrets-management, spec:git-mirror-service
    write_lf(&git_dir.join("git-askpass-tillandsias.sh"), GIT_ASKPASS_TILLANDSIAS)
        .map_err(|e| format!("git askpass script: {e}"))?;
    // @trace spec:external-logs-layer
    write_lf(&git_dir.join("external-logs.yaml"), GIT_EXTERNAL_LOGS_MANIFEST)
        .map_err(|e| format!("git external-logs.yaml: {e}"))?;
    #[cfg(unix)]
    {
        for name in ["entrypoint.sh", "post-receive-hook.sh", "git-askpass-tillandsias.sh"] {
            let path = git_dir.join(name);
            if let Err(e) = fs::set_permissions(&path, fs::Permissions::from_mode(0o755)) {
                warn!(
                    file = %path.display(),
                    error = %e,
                    "Failed to set executable permission — container entrypoint may fail"
                );
            }
        }
    }

    // -- images/inference/ --
    // @trace spec:inference-container
    let inference_dir = dir.join("images").join("inference");
    fs::create_dir_all(&inference_dir).map_err(|e| format!("images/inference dir: {e}"))?;
    write_lf(&inference_dir.join("entrypoint.sh"), INFERENCE_ENTRYPOINT)
        .map_err(|e| format!("inference entrypoint: {e}"))?;
    write_lf(&inference_dir.join("Containerfile"), INFERENCE_CONTAINERFILE)
        .map_err(|e| format!("inference Containerfile: {e}"))?;
    // @trace spec:external-logs-layer
    write_lf(&inference_dir.join("external-logs.yaml"), INFERENCE_EXTERNAL_LOGS_MANIFEST)
        .map_err(|e| format!("inference external-logs.yaml: {e}"))?;
    #[cfg(unix)]
    {
        let path = inference_dir.join("entrypoint.sh");
        if let Err(e) = fs::set_permissions(&path, fs::Permissions::from_mode(0o755)) {
            warn!(
                file = %path.display(),
                error = %e,
                "Failed to set executable permission — container entrypoint may fail"
            );
        }
    }

    debug!(dir = %dir.display(), "Wrote embedded image sources to temp");
    Ok(dir)
}

/// Extract embedded config overlay files to tmpfs (ramdisk).
///
/// Writes opinionated config files to `$XDG_RUNTIME_DIR/tillandsias/config-overlay/`
/// where they live on RAM-backed tmpfs for maximum read speed. Container entrypoints
/// symlink into this directory — no copying, every read goes to ramdisk.
///
/// Called early in the startup flow, before containers launch.
///
/// @trace spec:layered-tools-overlay
pub fn extract_config_overlay() -> Result<PathBuf, String> {
    let dir = runtime_dir().join("config-overlay");

    // @trace spec:layered-tools-overlay, spec:opencode-web-session
    // CRITICAL: preserve the directory inode. `extract_config_overlay` is
    // invoked on every Attach Here (from `ensure_infrastructure_ready`),
    // and running forge containers have their `.config-overlay` bind-mounted
    // to this path. If we `remove_dir_all` + recreate, the new dir gets a
    // new inode; bind mounts in existing containers become orphan
    // "//deleted" entries and appear empty from inside — MCP scripts vanish
    // mid-session, OpenCode's /command endpoint hangs 60s waiting for a
    // stdio response that never comes, and the UI freezes.
    //
    // Instead, overwrite files in place. write_lf truncates + rewrites
    // content; directories are created with `create_dir_all` which is a
    // no-op if present. The inode the kernel gave us at first extraction
    // is stable for the process lifetime, and every forge container sees
    // live updates on subsequent re-extractions.
    fs::create_dir_all(&dir).map_err(|e| format!("Cannot create config-overlay dir: {e}"))?;

    // -- opencode/ --
    let opencode_dir = dir.join("opencode");
    fs::create_dir_all(&opencode_dir)
        .map_err(|e| format!("Cannot create config-overlay/opencode dir: {e}"))?;
    write_lf(&opencode_dir.join("config.json"), CONFIG_OVERLAY_OPENCODE)
        .map_err(|e| format!("config-overlay/opencode/config.json: {e}"))?;

    // -- opencode/instructions/ -- methodology docs for AI agents
    // @trace spec:layered-tools-overlay
    let instructions_dir = opencode_dir.join("instructions");
    fs::create_dir_all(&instructions_dir)
        .map_err(|e| format!("Cannot create config-overlay/opencode/instructions dir: {e}"))?;
    write_lf(
        &instructions_dir.join("methodology.md"),
        CONFIG_OVERLAY_INSTRUCTIONS_METHODOLOGY,
    )
    .map_err(|e| format!("config-overlay/opencode/instructions/methodology.md: {e}"))?;
    write_lf(
        &instructions_dir.join("flutter.md"),
        CONFIG_OVERLAY_INSTRUCTIONS_FLUTTER,
    )
    .map_err(|e| format!("config-overlay/opencode/instructions/flutter.md: {e}"))?;
    write_lf(
        &instructions_dir.join("model-routing.md"),
        CONFIG_OVERLAY_INSTRUCTIONS_MODEL_ROUTING,
    )
    .map_err(|e| format!("config-overlay/opencode/instructions/model-routing.md: {e}"))?;
    write_lf(
        &instructions_dir.join("web-services.md"),
        CONFIG_OVERLAY_INSTRUCTIONS_WEB_SERVICES,
    )
    .map_err(|e| format!("config-overlay/opencode/instructions/web-services.md: {e}"))?;

    // -- mcp/ -- MCP server scripts (must be executable)
    // @trace spec:layered-tools-overlay, spec:host-browser-mcp
    let mcp_dir = dir.join("mcp");
    fs::create_dir_all(&mcp_dir)
        .map_err(|e| format!("Cannot create config-overlay/mcp dir: {e}"))?;
    write_lf(
        &mcp_dir.join("git-tools.sh"),
        CONFIG_OVERLAY_MCP_GIT_TOOLS,
    )
    .map_err(|e| format!("config-overlay/mcp/git-tools.sh: {e}"))?;
    write_lf(
        &mcp_dir.join("project-info.sh"),
        CONFIG_OVERLAY_MCP_PROJECT_INFO,
    )
    .map_err(|e| format!("config-overlay/mcp/project-info.sh: {e}"))?;
    write_lf(
        &mcp_dir.join("host-browser.sh"),
        CONFIG_OVERLAY_MCP_HOST_BROWSER,
    )
    .map_err(|e| format!("config-overlay/mcp/host-browser.sh: {e}"))?;
    #[cfg(unix)]
    {
        for name in ["git-tools.sh", "project-info.sh", "host-browser.sh"] {
            let path = mcp_dir.join(name);
            if let Err(e) = fs::set_permissions(&path, fs::Permissions::from_mode(0o755)) {
                warn!(
                    file = %path.display(),
                    error = %e,
                    "Failed to set executable permission — MCP server may fail"
                );
            }
        }
    }

    debug!(dir = %dir.display(), "Extracted config overlay to tmpfs");
    Ok(dir)
}

/// Remove the extracted image sources temp directory.
pub fn cleanup_image_sources() {
    let pid = std::process::id();
    let dir = runtime_dir().join(format!("image-sources-{pid}"));
    if dir.exists() {
        if let Err(e) = fs::remove_dir_all(&dir) {
            debug!(error = %e, "Failed to clean up image sources temp dir");
        } else {
            debug!("Cleaned up image sources temp dir");
        }
    }
    // Also clean up legacy shared dir if it exists
    let legacy = runtime_dir().join("image-sources");
    let _ = fs::remove_dir_all(&legacy);
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::path::Path;

    // @trace spec:fix-windows-extended-path
    #[test]
    fn simplify_path_strips_extended_drive_prefix() {
        // Only meaningful on Windows; on Unix the function is identity.
        let p = Path::new(r"\\?\C:\Users\bullo\src\tillandsias");
        let out = simplify_path(p);
        if cfg!(target_os = "windows") {
            assert_eq!(out, PathBuf::from(r"C:\Users\bullo\src\tillandsias"));
        } else {
            assert_eq!(out, p.to_path_buf());
        }
    }

    // @trace spec:fix-windows-extended-path
    #[test]
    fn simplify_path_preserves_unc_paths() {
        // \\?\UNC\server\share has no shorter form — leave it alone.
        let p = Path::new(r"\\?\UNC\server\share\dir");
        let out = simplify_path(p);
        assert_eq!(out, p.to_path_buf());
    }

    // @trace spec:fix-windows-extended-path
    #[test]
    fn simplify_path_passthrough_when_no_prefix() {
        let p = Path::new(r"C:\Users\bullo");
        let out = simplify_path(p);
        assert_eq!(out, p.to_path_buf());
    }

    // @trace spec:fix-windows-extended-path
    #[test]
    fn simplify_path_unix_paths_unchanged() {
        let p = Path::new("/home/forge/src/test1");
        let out = simplify_path(p);
        assert_eq!(out, p.to_path_buf());
    }

    // @trace spec:default-image, spec:embedded-scripts, spec:opencode-web-session
    /// Guard against the v0.1.159.189 bug: every file that the Containerfile
    /// expects under `images/default/` must be emitted by `write_image_sources()`.
    /// This test walks the real `images/default/` directory on disk (build-time
    /// cwd = crate root), then for each file checks that a file of the same
    /// name lands in the extracted temp dir. If someone adds a new file to
    /// `images/default/` without registering it in this module, the release
    /// binary will fail at `podman build` time on the user's machine; this
    /// test catches it pre-merge.
    #[test]
    fn every_default_image_source_is_embedded_and_extracted() {
        // cwd when running unit tests for the `tillandsias` bin is the crate dir
        // (`src-tauri/`). `images/default/` lives at the workspace root, one
        // directory up.
        let images_default = PathBuf::from("../images/default");
        assert!(
            images_default.is_dir(),
            "expected workspace-relative {:?} to exist",
            images_default
        );

        let expected: std::collections::HashSet<String> = std::fs::read_dir(&images_default)
            .unwrap()
            .filter_map(|e| e.ok())
            .filter(|e| e.file_type().map(|t| t.is_file()).unwrap_or(false))
            .map(|e| e.file_name().to_string_lossy().into_owned())
            // Skip files that are NOT extracted because they're not part of the
            // build context (e.g. sibling docs, config-overlay subdir content
            // handled separately, or files read only at host-side build time).
            // Keep this allowlist minimal; when adding, document why.
            .filter(|name| {
                // `opencode.json` is embedded via FORGE_OPENCODE_JSON — covered.
                // `git-askpass-tillandsias.sh` is embedded — covered.
                // `Containerfile` itself is embedded — covered.
                // `forge-welcome.sh` is embedded — covered.
                // `lib-common.sh` is embedded — covered.
                // Currently every file on disk in images/default/ is expected
                // to land in the extracted tree. If a future file is genuinely
                // not wanted there (e.g. a README), add a `.gitkeep`-style
                // carve-out here with a comment explaining why.
                !name.starts_with(".") && name != "README.md"
            })
            .collect();

        let extracted = write_image_sources().expect("write_image_sources should succeed");
        let extracted_default = extracted.join("images/default");

        let actual: std::collections::HashSet<String> = std::fs::read_dir(&extracted_default)
            .expect("extracted images/default should exist")
            .filter_map(|e| e.ok())
            .filter(|e| e.file_type().map(|t| t.is_file()).unwrap_or(false))
            .map(|e| e.file_name().to_string_lossy().into_owned())
            .collect();

        let missing: Vec<_> = expected.difference(&actual).collect();
        assert!(
            missing.is_empty(),
            "images/default/ files present on disk but not embedded/extracted: {:?}\n\
             Add them to `src-tauri/src/embedded.rs` (include_str! const + \
             write_lf in write_image_sources(); if executable, also to the \
             chmod loop).",
            missing
        );

        // Also verify the specific OpenCode Web entrypoint that regressed in
        // v0.1.159.189 is both present and executable on Unix.
        let opencode_web =
            extracted_default.join("entrypoint-forge-opencode-web.sh");
        assert!(
            opencode_web.is_file(),
            "entrypoint-forge-opencode-web.sh must be extracted"
        );
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            let mode = std::fs::metadata(&opencode_web).unwrap().permissions().mode();
            assert!(
                mode & 0o111 != 0,
                "entrypoint-forge-opencode-web.sh must be executable; got mode {:o}",
                mode
            );
        }

        // Cleanup
        let _ = std::fs::remove_dir_all(&extracted);
    }

    /// Sibling audit for `images/router/`: every file on disk must land in
    /// the extracted tree. Catches the v0.1.170.244 bug where chunk 4 of
    /// the OTP convergence shipped a multi-stage Containerfile + a
    /// `.containerignore` but neither was registered in `embedded.rs`,
    /// causing deployed binaries to fail at podman build time with
    /// "unable to parse ignore file".
    ///
    /// @trace spec:opencode-web-session-otp, spec:embedded-scripts
    #[test]
    fn every_router_image_source_is_embedded_and_extracted() {
        let images_router = PathBuf::from("../images/router");
        assert!(
            images_router.is_dir(),
            "expected workspace-relative {:?} to exist",
            images_router
        );

        let expected: std::collections::HashSet<String> = std::fs::read_dir(&images_router)
            .unwrap()
            .filter_map(|e| e.ok())
            .filter(|e| e.file_type().map(|t| t.is_file()).unwrap_or(false))
            .map(|e| e.file_name().to_string_lossy().into_owned())
            .filter(|name| !name.starts_with(".") && name != "README.md")
            .collect();

        let extracted = write_image_sources().expect("write_image_sources should succeed");
        let extracted_router = extracted.join("images/router");

        let actual: std::collections::HashSet<String> = std::fs::read_dir(&extracted_router)
            .expect("extracted images/router should exist")
            .filter_map(|e| e.ok())
            .filter(|e| e.file_type().map(|t| t.is_file()).unwrap_or(false))
            .map(|e| e.file_name().to_string_lossy().into_owned())
            .collect();

        let missing: Vec<_> = expected.difference(&actual).collect();
        assert!(
            missing.is_empty(),
            "images/router/ files present on disk but not embedded/extracted: {:?}\n\
             Add them to `src-tauri/src/embedded.rs` (include_str!/include_bytes! const + \
             write call in write_image_sources(); if executable, also to the \
             chmod loop).",
            missing
        );

        // The sidecar binary must be present and executable on Unix.
        let sidecar = extracted_router.join("tillandsias-router-sidecar");
        assert!(
            sidecar.is_file(),
            "tillandsias-router-sidecar must be extracted"
        );
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            let mode = std::fs::metadata(&sidecar).unwrap().permissions().mode();
            assert!(
                mode & 0o111 != 0,
                "tillandsias-router-sidecar must be executable; got mode {:o}",
                mode
            );
        }

        let _ = std::fs::remove_dir_all(&extracted);
    }
}
