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

/// Convert a path to a string suitable for Git Bash on Windows.
///
/// Windows paths use backslashes (`C:\Users\...`) which bash interprets
/// as escape characters, mangling the path. This converts to forward slashes.
/// Available on all platforms so `cfg!(target_os = "windows")` branches compile.
pub fn bash_path(path: &std::path::Path) -> String {
    path.to_string_lossy().replace('\\', "/")
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
///   images/
///     default/
///       entrypoint.sh
///       Containerfile
///       opencode.json
///       skills/command/{bash,bash-private}.md
///       shell/{bashrc,config.fish,zshrc}
///       locales/{en,es,ja,zh-Hant,zh-Hans,ar,ko,hi,ta,te,fr,pt,it,ro,ru,nah}.sh
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
    #[cfg(unix)]
    fs::set_permissions(
        scripts_dir.join("build-image.sh"),
        fs::Permissions::from_mode(0o700),
    )
    .ok();

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
    write_lf(&shell_dir.join("bashrc"), SHELL_BASHRC).map_err(|e| format!("bashrc: {e}"))?;
    write_lf(&shell_dir.join("config.fish"), SHELL_FISH_CONFIG)
        .map_err(|e| format!("config.fish: {e}"))?;
    write_lf(&shell_dir.join("zshrc"), SHELL_ZSHRC).map_err(|e| format!("zshrc: {e}"))?;

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

    // -- images/web/ --
    let web_dir = dir.join("images").join("web");
    fs::create_dir_all(&web_dir).map_err(|e| format!("images/web dir: {e}"))?;
    write_lf(&web_dir.join("entrypoint.sh"), WEB_ENTRYPOINT)
        .map_err(|e| format!("web entrypoint: {e}"))?;
    write_lf(&web_dir.join("Containerfile"), WEB_CONTAINERFILE)
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
