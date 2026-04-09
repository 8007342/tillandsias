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

/// Convert a path to MSYS2 format suitable for Git Bash.
///
/// On Windows, `C:\Users\foo` must become `/c/Users/foo` — not just `C:/Users/foo`.
/// Git Bash's virtual filesystem doesn't understand drive letters as path prefixes.
/// When bash.exe is launched from a native Windows process (no MSYS2 layer),
/// there's no automatic path translation, so we must do it explicitly.
///
/// On non-Windows, returns the path as-is.
#[allow(dead_code)] // Cross-platform utility — used on Windows launch paths
pub fn bash_path(path: &std::path::Path) -> String {
    let s = path.to_string_lossy().replace('\\', "/");
    if cfg!(target_os = "windows") {
        // Convert "C:/foo" to "/c/foo" (MSYS2 mount format)
        if s.len() >= 2 && s.as_bytes()[1] == b':' {
            let drive = s.as_bytes()[0].to_ascii_lowercase() as char;
            format!("/{drive}{}", &s[2..])
        } else {
            s
        }
    } else {
        s
    }
}

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
pub const BUILD_IMAGE: &str = include_str!("../../scripts/build-image.sh");
pub const BUILD_TOOLS_OVERLAY: &str = include_str!("../../scripts/build-tools-overlay.sh");
#[allow(dead_code)] // Used by GitHub login flow (--github-login CLI path)
pub const GH_AUTH_LOGIN: &str = include_str!("../../gh-auth-login.sh");

// ---------------------------------------------------------------------------
// Image sources — flake
// ---------------------------------------------------------------------------
pub const FLAKE_NIX: &str = include_str!("../../flake.nix");
pub const FLAKE_LOCK: &str = include_str!("../../flake.lock");

// ---------------------------------------------------------------------------
// Image sources — forge (default) image
// ---------------------------------------------------------------------------
pub const FORGE_ENTRYPOINT: &str = include_str!("../../images/default/entrypoint.sh");
pub const FORGE_LIB_COMMON: &str = include_str!("../../images/default/lib-common.sh");
pub const FORGE_ENTRYPOINT_OPENCODE: &str =
    include_str!("../../images/default/entrypoint-forge-opencode.sh");
pub const FORGE_ENTRYPOINT_CLAUDE: &str =
    include_str!("../../images/default/entrypoint-forge-claude.sh");
pub const FORGE_ENTRYPOINT_TERMINAL: &str =
    include_str!("../../images/default/entrypoint-terminal.sh");
pub const FORGE_WELCOME: &str = include_str!("../../images/default/forge-welcome.sh");
pub const FORGE_CONTAINERFILE: &str = include_str!("../../images/default/Containerfile");
pub const FORGE_OPENCODE_JSON: &str = include_str!("../../images/default/opencode.json");

// GIT_ASKPASS helper for secure token delivery
pub const FORGE_GIT_ASKPASS: &str =
    include_str!("../../images/default/git-askpass-tillandsias.sh");

// Config overlay — opinionated configs extracted to ramdisk (tmpfs)
// @trace spec:layered-tools-overlay
pub const CONFIG_OVERLAY_OPENCODE: &str =
    include_str!("../../images/default/config-overlay/opencode/config.json");

// Config overlay — methodology instruction files for AI agents
// @trace spec:layered-tools-overlay
pub const CONFIG_OVERLAY_INSTRUCTIONS_METHODOLOGY: &str =
    include_str!("../../images/default/config-overlay/opencode/instructions/methodology.md");
pub const CONFIG_OVERLAY_INSTRUCTIONS_FLUTTER: &str =
    include_str!("../../images/default/config-overlay/opencode/instructions/flutter.md");

// MCP servers — lightweight tool scripts for forge containers
// @trace spec:layered-tools-overlay, spec:git-mirror-service
pub const CONFIG_OVERLAY_MCP_GIT_TOOLS: &str =
    include_str!("../../images/default/config-overlay/mcp/git-tools.sh");
pub const CONFIG_OVERLAY_MCP_PROJECT_INFO: &str =
    include_str!("../../images/default/config-overlay/mcp/project-info.sh");

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

// ---------------------------------------------------------------------------
// Image sources — git service image
// @trace spec:git-mirror-service
// ---------------------------------------------------------------------------
pub const GIT_ENTRYPOINT: &str = include_str!("../../images/git/entrypoint.sh");
pub const GIT_CONTAINERFILE: &str = include_str!("../../images/git/Containerfile");
pub const POST_RECEIVE_HOOK: &str = include_str!("../../images/git/post-receive-hook.sh");

// ---------------------------------------------------------------------------
// Image sources — inference image
// @trace spec:inference-container
// ---------------------------------------------------------------------------
pub const INFERENCE_ENTRYPOINT: &str = include_str!("../../images/inference/entrypoint.sh");
pub const INFERENCE_CONTAINERFILE: &str = include_str!("../../images/inference/Containerfile");

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
/// Recreates the directory layout that `build-image.sh` and `nix build`
/// expect:
///
/// ```text
/// <dir>/
///   flake.nix
///   flake.lock
///   scripts/
///     build-image.sh
///     build-tools-overlay.sh
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
/// Returns the root temp directory path. The caller should clean up via
/// [`cleanup_image_sources`] after the build completes (or rely on
/// session cleanup of `$XDG_RUNTIME_DIR`).
// @trace spec:embedded-scripts/image-source-extraction
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
    let scripts_dir = dir.join("scripts");
    fs::create_dir_all(&scripts_dir).map_err(|e| format!("scripts dir: {e}"))?;
    write_lf(&scripts_dir.join("build-image.sh"), BUILD_IMAGE)
        .map_err(|e| format!("build-image.sh: {e}"))?;
    write_lf(
        &scripts_dir.join("build-tools-overlay.sh"),
        BUILD_TOOLS_OVERLAY,
    )
    .map_err(|e| format!("build-tools-overlay.sh: {e}"))?;
    #[cfg(unix)]
    {
        let path = scripts_dir.join("build-image.sh");
        if let Err(e) = fs::set_permissions(&path, fs::Permissions::from_mode(0o700)) {
            warn!(
                file = %path.display(),
                error = %e,
                "Failed to set executable permission — container entrypoint may fail"
            );
        }
        let path = scripts_dir.join("build-tools-overlay.sh");
        if let Err(e) = fs::set_permissions(&path, fs::Permissions::from_mode(0o700)) {
            warn!(
                file = %path.display(),
                error = %e,
                "Failed to set executable permission — container entrypoint may fail"
            );
        }
    }

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
    write_lf(&default_dir.join("forge-welcome.sh"), FORGE_WELCOME)
        .map_err(|e| format!("forge-welcome.sh: {e}"))?;
    write_lf(&default_dir.join("Containerfile"), FORGE_CONTAINERFILE)
        .map_err(|e| format!("Containerfile: {e}"))?;
    write_lf(&default_dir.join("opencode.json"), FORGE_OPENCODE_JSON)
        .map_err(|e| format!("opencode.json: {e}"))?;
    write_lf(
        &default_dir.join("git-askpass-tillandsias.sh"),
        FORGE_GIT_ASKPASS,
    )
    .map_err(|e| format!("git-askpass-tillandsias.sh: {e}"))?;
    #[cfg(unix)]
    {
        for name in [
            "entrypoint.sh",
            "entrypoint-forge-opencode.sh",
            "entrypoint-forge-claude.sh",
            "entrypoint-terminal.sh",
            "git-askpass-tillandsias.sh",
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

    // Config overlay — MCP servers
    // @trace spec:layered-tools-overlay
    let mcp_dir = default_dir.join("config-overlay").join("mcp");
    fs::create_dir_all(&mcp_dir).map_err(|e| format!("config-overlay/mcp dir: {e}"))?;
    write_lf(&mcp_dir.join("git-tools.sh"), CONFIG_OVERLAY_MCP_GIT_TOOLS)
        .map_err(|e| format!("config-overlay/mcp/git-tools.sh: {e}"))?;
    write_lf(
        &mcp_dir.join("project-info.sh"),
        CONFIG_OVERLAY_MCP_PROJECT_INFO,
    )
    .map_err(|e| format!("config-overlay/mcp/project-info.sh: {e}"))?;
    #[cfg(unix)]
    {
        for name in ["git-tools.sh", "project-info.sh"] {
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
    #[cfg(unix)]
    {
        for name in ["entrypoint.sh", "post-receive-hook.sh"] {
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

    // Recreate fresh each time — configs may have changed between versions
    let _ = fs::remove_dir_all(&dir);
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

    // -- mcp/ -- MCP server scripts (must be executable)
    // @trace spec:layered-tools-overlay
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
    #[cfg(unix)]
    {
        for name in ["git-tools.sh", "project-info.sh"] {
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
