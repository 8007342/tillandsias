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

use tracing::debug;

// ---------------------------------------------------------------------------
// Executable scripts
// ---------------------------------------------------------------------------
pub const BUILD_IMAGE: &str = include_str!("../../scripts/build-image.sh");
pub const GH_AUTH_LOGIN: &str = include_str!("../../gh-auth-login.sh");
pub const CLAUDE_API_KEY_PROMPT: &str = include_str!("../../claude-api-key-prompt.sh");

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

// Shell configs
pub const SHELL_BASHRC: &str = include_str!("../../images/default/shell/bashrc");
pub const SHELL_FISH_CONFIG: &str = include_str!("../../images/default/shell/config.fish");
pub const SHELL_ZSHRC: &str = include_str!("../../images/default/shell/zshrc");

// Locale files
pub const LOCALE_EN: &str = include_str!("../../images/default/locales/en.sh");
pub const LOCALE_ES: &str = include_str!("../../images/default/locales/es.sh");

// ---------------------------------------------------------------------------
// Image sources — web image
// ---------------------------------------------------------------------------
pub const WEB_ENTRYPOINT: &str = include_str!("../../images/web/entrypoint.sh");
pub const WEB_CONTAINERFILE: &str = include_str!("../../images/web/Containerfile");

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
    fs::write(&path, content).map_err(|e| format!("Cannot write {name}: {e}"))?;

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
///   images/
///     default/
///       entrypoint.sh
///       Containerfile
///       opencode.json
///       skills/command/{bash,bash-private}.md
///       shell/{bashrc,config.fish,zshrc}
///       locales/{en.sh,es.sh}
///     web/
///       entrypoint.sh
///       Containerfile
/// ```
///
/// Returns the root temp directory path. The caller should clean up via
/// [`cleanup_image_sources`] after the build completes (or rely on
/// session cleanup of `$XDG_RUNTIME_DIR`).
// @trace spec:embedded-scripts/image-source-extraction
pub fn write_image_sources() -> Result<PathBuf, String> {
    let dir = runtime_dir().join("image-sources");

    // Recreate fresh each time
    let _ = fs::remove_dir_all(&dir);
    fs::create_dir_all(&dir).map_err(|e| format!("Cannot create image sources dir: {e}"))?;

    // -- Flake files --
    fs::write(dir.join("flake.nix"), FLAKE_NIX).map_err(|e| format!("flake.nix: {e}"))?;
    fs::write(dir.join("flake.lock"), FLAKE_LOCK).map_err(|e| format!("flake.lock: {e}"))?;

    // -- Scripts --
    let scripts_dir = dir.join("scripts");
    fs::create_dir_all(&scripts_dir).map_err(|e| format!("scripts dir: {e}"))?;
    fs::write(scripts_dir.join("build-image.sh"), BUILD_IMAGE)
        .map_err(|e| format!("build-image.sh: {e}"))?;
    #[cfg(unix)]
    fs::set_permissions(
        scripts_dir.join("build-image.sh"),
        fs::Permissions::from_mode(0o700),
    )
    .ok();

    // -- images/default/ --
    let default_dir = dir.join("images").join("default");
    fs::create_dir_all(&default_dir).map_err(|e| format!("images/default dir: {e}"))?;
    fs::write(default_dir.join("entrypoint.sh"), FORGE_ENTRYPOINT)
        .map_err(|e| format!("entrypoint.sh: {e}"))?;
    fs::write(default_dir.join("lib-common.sh"), FORGE_LIB_COMMON)
        .map_err(|e| format!("lib-common.sh: {e}"))?;
    fs::write(
        default_dir.join("entrypoint-forge-opencode.sh"),
        FORGE_ENTRYPOINT_OPENCODE,
    )
    .map_err(|e| format!("entrypoint-forge-opencode.sh: {e}"))?;
    fs::write(
        default_dir.join("entrypoint-forge-claude.sh"),
        FORGE_ENTRYPOINT_CLAUDE,
    )
    .map_err(|e| format!("entrypoint-forge-claude.sh: {e}"))?;
    fs::write(
        default_dir.join("entrypoint-terminal.sh"),
        FORGE_ENTRYPOINT_TERMINAL,
    )
    .map_err(|e| format!("entrypoint-terminal.sh: {e}"))?;
    fs::write(default_dir.join("forge-welcome.sh"), FORGE_WELCOME)
        .map_err(|e| format!("forge-welcome.sh: {e}"))?;
    fs::write(default_dir.join("Containerfile"), FORGE_CONTAINERFILE)
        .map_err(|e| format!("Containerfile: {e}"))?;
    fs::write(default_dir.join("opencode.json"), FORGE_OPENCODE_JSON)
        .map_err(|e| format!("opencode.json: {e}"))?;
    fs::write(
        default_dir.join("git-askpass-tillandsias.sh"),
        FORGE_GIT_ASKPASS,
    )
    .map_err(|e| format!("git-askpass-tillandsias.sh: {e}"))?;
    #[cfg(unix)]
    {
        fs::set_permissions(
            default_dir.join("entrypoint.sh"),
            fs::Permissions::from_mode(0o755),
        )
        .ok();
        fs::set_permissions(
            default_dir.join("entrypoint-forge-opencode.sh"),
            fs::Permissions::from_mode(0o755),
        )
        .ok();
        fs::set_permissions(
            default_dir.join("entrypoint-forge-claude.sh"),
            fs::Permissions::from_mode(0o755),
        )
        .ok();
        fs::set_permissions(
            default_dir.join("entrypoint-terminal.sh"),
            fs::Permissions::from_mode(0o755),
        )
        .ok();
        fs::set_permissions(
            default_dir.join("git-askpass-tillandsias.sh"),
            fs::Permissions::from_mode(0o755),
        )
        .ok();
    }

    // Shell configs
    let shell_dir = default_dir.join("shell");
    fs::create_dir_all(&shell_dir).map_err(|e| format!("shell dir: {e}"))?;
    fs::write(shell_dir.join("bashrc"), SHELL_BASHRC).map_err(|e| format!("bashrc: {e}"))?;
    fs::write(shell_dir.join("config.fish"), SHELL_FISH_CONFIG)
        .map_err(|e| format!("config.fish: {e}"))?;
    fs::write(shell_dir.join("zshrc"), SHELL_ZSHRC).map_err(|e| format!("zshrc: {e}"))?;

    // Locale files
    let locales_dir = default_dir.join("locales");
    fs::create_dir_all(&locales_dir).map_err(|e| format!("locales dir: {e}"))?;
    fs::write(locales_dir.join("en.sh"), LOCALE_EN).map_err(|e| format!("en.sh: {e}"))?;
    fs::write(locales_dir.join("es.sh"), LOCALE_ES).map_err(|e| format!("es.sh: {e}"))?;

    // -- images/web/ --
    let web_dir = dir.join("images").join("web");
    fs::create_dir_all(&web_dir).map_err(|e| format!("images/web dir: {e}"))?;
    fs::write(web_dir.join("entrypoint.sh"), WEB_ENTRYPOINT)
        .map_err(|e| format!("web entrypoint: {e}"))?;
    fs::write(web_dir.join("Containerfile"), WEB_CONTAINERFILE)
        .map_err(|e| format!("web Containerfile: {e}"))?;
    #[cfg(unix)]
    fs::set_permissions(
        web_dir.join("entrypoint.sh"),
        fs::Permissions::from_mode(0o755),
    )
    .ok();

    debug!(dir = %dir.display(), "Wrote embedded image sources to temp");
    Ok(dir)
}

/// Remove the extracted image sources temp directory.
pub fn cleanup_image_sources() {
    let dir = runtime_dir().join("image-sources");
    if dir.exists() {
        if let Err(e) = fs::remove_dir_all(&dir) {
            debug!(error = %e, "Failed to clean up image sources temp dir");
        } else {
            debug!("Cleaned up image sources temp dir");
        }
    }
}
