//! Userspace Chromium resolution + lazy install.
//!
//! Two responsibilities, both gated on the host-chromium-on-demand spec:
//!
//! 1. **Resolution** ([`resolve`]) — at tray init time, find a Chromium
//!    binary the tray is allowed to launch. Priority order, first hit
//!    wins:
//!      - Userspace install at
//!        `<XDG_DATA_HOME>/tillandsias/chromium/current/...`
//!      - System `chromium` / `chromium-browser` on PATH
//!      - System `google-chrome` / `google-chrome-stable` on PATH
//!      - System `microsoft-edge-stable` / `microsoft-edge` on PATH
//!      - Hard error
//!
//! 2. **Lazy install** ([`run_install_subcommand`]) — back the
//!    `tillandsias --install-chromium [--from-zip <path>]` CLI by
//!    shelling out to `scripts/install-chromium.sh` with the pinned
//!    version + per-platform SHA-256 digests baked in at compile time
//!    (see `build.rs`).
//!
//! Both surfaces are silent at runtime: there is NO dialog, NO menu
//! item, and NO background download from the tray. The only consent
//! gate is the `curl ... | bash` install moment (per
//! `feedback_no_unauthorized_ux` and the spec's `Consent gate is the
//! curl installer; no runtime UI` requirement).
//!
//! @trace spec:host-chromium-on-demand
//! @cheatsheet runtime/forge-paths-ephemeral-vs-persistent.md

use std::path::{Path, PathBuf};
use std::process::Command;

use tracing::{debug, info, warn};

/// The pinned Chromium version embedded at compile time from
/// `scripts/install.sh`. Empty string when build.rs could not parse the
/// install script (e.g. the crate is built outside the workspace) — the
/// install path will fail fast in that case.
///
/// @trace spec:host-chromium-on-demand
pub const CHROMIUM_VERSION: &str = env!("TILLANDSIAS_CHROMIUM_VERSION");

/// Per-platform SHA-256 pin (Linux x86_64).
///
/// @trace spec:host-chromium-on-demand
pub const CHROMIUM_SHA256_LINUX64: &str = env!("TILLANDSIAS_CHROMIUM_SHA256_LINUX64");

/// Per-platform SHA-256 pin (macOS arm64).
///
/// @trace spec:host-chromium-on-demand
pub const CHROMIUM_SHA256_MAC_ARM64: &str = env!("TILLANDSIAS_CHROMIUM_SHA256_MAC_ARM64");

/// Per-platform SHA-256 pin (macOS x86_64).
///
/// @trace spec:host-chromium-on-demand
pub const CHROMIUM_SHA256_MAC_X64: &str = env!("TILLANDSIAS_CHROMIUM_SHA256_MAC_X64");

/// Per-platform SHA-256 pin (Windows x86_64).
///
/// @trace spec:host-chromium-on-demand
pub const CHROMIUM_SHA256_WIN64: &str = env!("TILLANDSIAS_CHROMIUM_SHA256_WIN64");

/// Resolved Chromium binary, with a label naming the source.
///
/// @trace spec:host-chromium-on-demand
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ResolvedChromium {
    /// Absolute path to the binary.
    pub bin: PathBuf,
    /// Where this binary came from — "userspace-install" or
    /// "system-fallback" — for accountability log emission.
    pub source: ChromiumSource,
}

/// Source of the resolved binary.
///
/// @trace spec:host-chromium-on-demand
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ChromiumSource {
    /// `<XDG_DATA_HOME>/tillandsias/chromium/current/...` — what
    /// `scripts/install.sh` (or `tillandsias --install-chromium`)
    /// installs. Preferred over any system browser per the spec's
    /// `Detection priority` requirement.
    UserspaceInstall,
    /// A Chromium-family binary discovered on `$PATH`. Used only when
    /// no userspace install is present (graceful-degradation path for
    /// users who installed via direct AppImage download).
    SystemFallback,
}

impl ChromiumSource {
    /// String tag used in tracing fields (`using = "system-fallback"`
    /// in the spec's accountability scenario). Currently only the
    /// fallback path emits this through a hardcoded string in `resolve`;
    /// callers that want to attribute a downstream log line back to the
    /// resolved source should use this method to keep the tag stable.
    #[allow(dead_code)]
    pub const fn as_str(self) -> &'static str {
        match self {
            ChromiumSource::UserspaceInstall => "userspace-install",
            ChromiumSource::SystemFallback => "system-fallback",
        }
    }
}

/// Hard error returned when no Chromium-family binary resolves anywhere.
///
/// The message is exactly what `host-chromium-on-demand`'s `Detection
/// priority — userspace first, system fallback, hard error` requirement
/// pins for the missing-binary scenario; surfaces verbatim through the
/// browser launch path so the tray's accountability chip is aligned with
/// what the CLI prints.
///
/// @trace spec:host-chromium-on-demand
pub const NOT_FOUND_MESSAGE: &str =
    "Chromium not installed. Re-run the installer or run \"tillandsias --install-chromium\".";

/// Per-platform tag identifying the Chrome for Testing archive directory.
fn chrome_for_testing_platform() -> Option<&'static str> {
    #[cfg(all(target_os = "linux", target_arch = "x86_64"))]
    {
        Some("linux64")
    }
    #[cfg(all(target_os = "macos", target_arch = "aarch64"))]
    {
        Some("mac-arm64")
    }
    #[cfg(all(target_os = "macos", target_arch = "x86_64"))]
    {
        Some("mac-x64")
    }
    #[cfg(all(target_os = "windows", target_arch = "x86_64"))]
    {
        Some("win64")
    }
    #[cfg(not(any(
        all(target_os = "linux", target_arch = "x86_64"),
        all(target_os = "macos", target_arch = "aarch64"),
        all(target_os = "macos", target_arch = "x86_64"),
        all(target_os = "windows", target_arch = "x86_64"),
    )))]
    {
        None
    }
}

/// Userspace install root (per the spec's `Userspace install location
/// under XDG_DATA_HOME` requirement).
///
/// Honours `XDG_DATA_HOME` when set; otherwise falls back to the
/// platform default. Test code overrides via `TILLANDSIAS_CHROMIUM_ROOT`
/// for hermetic resolution tests.
///
/// @trace spec:host-chromium-on-demand
/// @cheatsheet runtime/forge-paths-ephemeral-vs-persistent.md
pub fn install_root() -> PathBuf {
    if let Some(override_path) = std::env::var_os("TILLANDSIAS_CHROMIUM_ROOT") {
        return PathBuf::from(override_path);
    }

    #[cfg(target_os = "linux")]
    {
        let base = std::env::var_os("XDG_DATA_HOME")
            .map(PathBuf::from)
            .or_else(|| dirs::home_dir().map(|h| h.join(".local/share")))
            .unwrap_or_else(|| PathBuf::from("."));
        return base.join("tillandsias").join("chromium");
    }
    #[cfg(target_os = "macos")]
    {
        let base = dirs::home_dir().unwrap_or_else(|| PathBuf::from("."));
        return base
            .join("Library/Application Support/tillandsias/chromium");
    }
    #[cfg(target_os = "windows")]
    {
        let base = dirs::data_local_dir().unwrap_or_else(|| PathBuf::from("."));
        return base.join("tillandsias").join("chromium");
    }
    #[cfg(not(any(target_os = "linux", target_os = "macos", target_os = "windows")))]
    {
        PathBuf::from("/tmp/tillandsias-chromium")
    }
}

/// Compute the path the `current` symlink (or Windows directory junction)
/// would point at and resolve through to the binary the tray would launch.
/// Returns `None` if the install is missing or incomplete.
fn userspace_install_binary() -> Option<PathBuf> {
    let root = install_root();
    let current = root.join("current");
    if !current.exists() {
        return None;
    }
    let platform = chrome_for_testing_platform()?;
    let extracted_subdir = format!("chrome-{platform}");

    let bin = match platform {
        "linux64" => current.join(extracted_subdir).join("chrome"),
        "mac-arm64" | "mac-x64" => current
            .join(extracted_subdir)
            .join("Google Chrome for Testing.app")
            .join("Contents/MacOS/Google Chrome for Testing"),
        "win64" => current.join(extracted_subdir).join("chrome.exe"),
        _ => return None,
    };
    if is_executable(&bin) { Some(bin) } else { None }
}

fn is_executable(path: &Path) -> bool {
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        std::fs::metadata(path)
            .map(|m| m.is_file() && (m.permissions().mode() & 0o111) != 0)
            .unwrap_or(false)
    }
    #[cfg(not(unix))]
    {
        path.is_file()
    }
}

/// Walk `$PATH` looking for an executable named `name`. Returns the
/// absolute path on first match.
fn which_on_path(name: &str) -> Option<PathBuf> {
    let path = std::env::var_os("PATH")?;
    for dir in std::env::split_paths(&path) {
        let candidate = dir.join(name);
        if is_executable(&candidate) {
            return Some(candidate);
        }
    }
    None
}

/// Resolve the Chromium binary the tray is allowed to launch.
///
/// Priority order matches the spec's `Detection priority — userspace
/// first, system fallback, hard error` requirement.
///
/// On the system-fallback path this also emits an accountability info
/// log so power users can see when the tray reaches past the userspace
/// install (per the spec scenario `Userspace install missing, system
/// Chromium present — fallback path`).
///
/// @trace spec:host-chromium-on-demand, spec:opencode-web-session
/// @cheatsheet runtime/forge-paths-ephemeral-vs-persistent.md
pub fn resolve() -> Result<ResolvedChromium, String> {
    if let Some(bin) = userspace_install_binary() {
        debug!(
            spec = "host-chromium-on-demand",
            bin = %bin.display(),
            "Resolved Chromium via userspace install"
        );
        return Ok(ResolvedChromium {
            bin,
            source: ChromiumSource::UserspaceInstall,
        });
    }

    let candidates: &[&str] = &[
        "chromium",
        "chromium-browser",
        "google-chrome",
        "google-chrome-stable",
        "microsoft-edge-stable",
        "microsoft-edge",
    ];
    for name in candidates {
        if let Some(bin) = which_on_path(name) {
            // Spec scenario: emit info-level accountability so the
            // fallback is visible to power users.
            info!(
                accountability = true,
                category = "browser-detect",
                spec = "host-chromium-on-demand",
                cheatsheet = "runtime/forge-paths-ephemeral-vs-persistent.md",
                using = "system-fallback",
                bin = %bin.display(),
                "Userspace Chromium not present — falling back to system PATH binary"
            );
            return Ok(ResolvedChromium {
                bin,
                source: ChromiumSource::SystemFallback,
            });
        }
    }

    // macOS bundle paths — last-chance Chromium-family hits.
    #[cfg(target_os = "macos")]
    {
        for path in [
            "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome",
            "/Applications/Chromium.app/Contents/MacOS/Chromium",
            "/Applications/Microsoft Edge.app/Contents/MacOS/Microsoft Edge",
        ] {
            if Path::new(path).exists() {
                info!(
                    accountability = true,
                    category = "browser-detect",
                    spec = "host-chromium-on-demand",
                    using = "system-fallback",
                    bin = %path,
                    "Userspace Chromium not present — falling back to /Applications binary"
                );
                return Ok(ResolvedChromium {
                    bin: PathBuf::from(path),
                    source: ChromiumSource::SystemFallback,
                });
            }
        }
    }

    Err(NOT_FOUND_MESSAGE.to_string())
}

/// Locate the embedded `install-chromium.sh` helper. Resolution order:
///
/// 1. `TILLANDSIAS_INSTALL_CHROMIUM_SH` env override (used by tests).
/// 2. `<exe-dir>/scripts/install-chromium.sh` (cargo target/debug layout).
/// 3. `<exe-dir>/../../../scripts/install-chromium.sh` (workspace dev path).
/// 4. `~/.local/share/tillandsias/install-chromium.sh` (release-cut copy).
///
/// Returns `None` if the helper cannot be found.
fn locate_install_helper() -> Option<PathBuf> {
    if let Some(p) = std::env::var_os("TILLANDSIAS_INSTALL_CHROMIUM_SH") {
        let pb = PathBuf::from(p);
        if pb.is_file() {
            return Some(pb);
        }
    }
    if let Ok(exe) = std::env::current_exe()
        && let Some(dir) = exe.parent()
    {
        let candidates = [
            dir.join("scripts/install-chromium.sh"),
            dir.join("../../../scripts/install-chromium.sh"),
            dir.join("../../scripts/install-chromium.sh"),
        ];
        for c in candidates.iter() {
            if c.is_file() {
                return Some(c.clone());
            }
        }
    }
    let xdg_data = std::env::var_os("XDG_DATA_HOME")
        .map(PathBuf::from)
        .or_else(|| dirs::home_dir().map(|h| h.join(".local/share")))?;
    let cached = xdg_data.join("tillandsias/install-chromium.sh");
    if cached.is_file() {
        return Some(cached);
    }
    None
}

/// Implementation behind `tillandsias --install-chromium [--from-zip <path>]`.
///
/// Shells out to `scripts/install-chromium.sh` with the embedded pin
/// (version + per-platform SHA-256) in the env. Returns `Ok(())` on a
/// zero exit code; the helper script writes its own progress + error
/// messages to stderr.
///
/// @trace spec:host-chromium-on-demand
pub fn run_install_subcommand(from_zip: Option<&Path>) -> Result<(), String> {
    if CHROMIUM_VERSION.is_empty() {
        return Err(
            "Chromium pin missing from install.sh — run scripts/refresh-chromium-pin.sh first."
                .to_string(),
        );
    }

    let helper = locate_install_helper()
        .ok_or_else(|| "install-chromium.sh helper not found alongside the Tillandsias binary".to_string())?;

    info!(
        accountability = true,
        category = "download",
        source = "host-installer",
        spec = "host-chromium-on-demand",
        cheatsheet = "runtime/forge-paths-ephemeral-vs-persistent.md",
        version = CHROMIUM_VERSION,
        from_zip = from_zip.map(|p| p.display().to_string()).unwrap_or_default(),
        "Starting userspace Chromium install"
    );

    let mut cmd = Command::new("bash");
    cmd.arg(&helper)
        .env("CHROMIUM_VERSION", CHROMIUM_VERSION)
        .env("CHROMIUM_SHA256_LINUX64", CHROMIUM_SHA256_LINUX64)
        .env("CHROMIUM_SHA256_MAC_ARM64", CHROMIUM_SHA256_MAC_ARM64)
        .env("CHROMIUM_SHA256_MAC_X64", CHROMIUM_SHA256_MAC_X64)
        .env("CHROMIUM_SHA256_WIN64", CHROMIUM_SHA256_WIN64);
    if let Some(zip) = from_zip {
        cmd.arg("--from-zip").arg(zip);
    }

    let status = cmd
        .status()
        .map_err(|e| format!("failed to spawn install-chromium.sh: {e}"))?;

    if status.success() {
        info!(
            accountability = true,
            category = "download",
            source = "host-installer",
            spec = "host-chromium-on-demand",
            cheatsheet = "runtime/forge-paths-ephemeral-vs-persistent.md",
            version = CHROMIUM_VERSION,
            "Userspace Chromium install completed"
        );
        Ok(())
    } else {
        warn!(
            accountability = true,
            category = "download",
            source = "host-installer",
            spec = "host-chromium-on-demand",
            version = CHROMIUM_VERSION,
            status = ?status.code(),
            "Userspace Chromium install failed"
        );
        Err(format!(
            "install-chromium.sh exited with status {:?}",
            status.code()
        ))
    }
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::Mutex;
    use tempfile::TempDir;

    /// Serialise tests that mutate process-global env vars (PATH and
    /// TILLANDSIAS_CHROMIUM_ROOT). Without this lock the parallel test
    /// runner can leak one test's env into another's resolution.
    static ENV_LOCK: Mutex<()> = Mutex::new(());

    /// Helper: write a fake "chrome" binary to the userspace layout
    /// inside a temp root so resolve() picks it up.
    fn seed_userspace(root: &Path) -> PathBuf {
        let version = "0.0.0.0";
        let platform = chrome_for_testing_platform().expect("test only runs on supported targets");
        let extracted = format!("chrome-{platform}");
        let version_dir = root.join(version);
        let inner_dir = match platform {
            "linux64" | "win64" => version_dir.join(&extracted),
            "mac-arm64" | "mac-x64" => version_dir
                .join(&extracted)
                .join("Google Chrome for Testing.app")
                .join("Contents/MacOS"),
            _ => version_dir.join(&extracted),
        };
        std::fs::create_dir_all(&inner_dir).unwrap();

        let bin_name = match platform {
            "win64" => "chrome.exe",
            "mac-arm64" | "mac-x64" => "Google Chrome for Testing",
            _ => "chrome",
        };
        let bin = inner_dir.join(bin_name);
        std::fs::write(&bin, b"#!/bin/sh\nexit 0\n").unwrap();
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            let mut perms = std::fs::metadata(&bin).unwrap().permissions();
            perms.set_mode(0o755);
            std::fs::set_permissions(&bin, perms).unwrap();
        }
        // Symlink current → version
        let current = root.join("current");
        #[cfg(unix)]
        std::os::unix::fs::symlink(version, &current).unwrap();
        #[cfg(not(unix))]
        std::fs::create_dir_all(&current).unwrap();
        bin
    }

    /// Helper: a stub `chromium` shell script in a tempdir, made
    /// executable, so PATH lookup picks it up.
    fn seed_path_chromium(dir: &Path, name: &str) -> PathBuf {
        let bin = dir.join(name);
        std::fs::write(&bin, "#!/bin/sh\nexit 0\n").unwrap();
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            let mut perms = std::fs::metadata(&bin).unwrap().permissions();
            perms.set_mode(0o755);
            std::fs::set_permissions(&bin, perms).unwrap();
        }
        bin
    }

    #[test]
    fn install_root_honours_override_env() {
        let _guard = ENV_LOCK.lock().unwrap_or_else(|e| e.into_inner());
        let tmp = TempDir::new().unwrap();
        // SAFETY: env mutation is unsafe in Rust 2024; the ENV_LOCK guard
        // serialises tests against each other and we restore the prior
        // value at the end of the test.
        unsafe {
            std::env::set_var("TILLANDSIAS_CHROMIUM_ROOT", tmp.path());
        }
        assert_eq!(install_root(), tmp.path());
        unsafe {
            std::env::remove_var("TILLANDSIAS_CHROMIUM_ROOT");
        }
    }

    #[test]
    fn chromium_source_str_tags_match_spec() {
        // The spec scenario for the system-fallback log entry pins
        // `using = "system-fallback"` — keep this hardcoded so any
        // accidental rename breaks loudly.
        assert_eq!(ChromiumSource::UserspaceInstall.as_str(), "userspace-install");
        assert_eq!(ChromiumSource::SystemFallback.as_str(), "system-fallback");
    }

    #[test]
    fn not_found_message_matches_spec_text() {
        // The spec hardcodes this string in the
        // `Nothing resolves — hard error, no UI prompt` scenario; an
        // accidental rephrasing here would silently diverge from the
        // accountability chip behaviour.
        assert_eq!(
            NOT_FOUND_MESSAGE,
            "Chromium not installed. Re-run the installer or run \"tillandsias --install-chromium\"."
        );
    }

    #[cfg(unix)]
    #[test]
    fn resolve_prefers_userspace_install_over_system_path() {
        let _guard = ENV_LOCK.lock().unwrap_or_else(|e| e.into_inner());
        // Userspace install present + a stub `chromium` on PATH.
        // Userspace MUST win.
        let userspace = TempDir::new().unwrap();
        let path_dir = TempDir::new().unwrap();
        let user_bin = seed_userspace(userspace.path());
        seed_path_chromium(path_dir.path(), "chromium");

        let saved_path = std::env::var_os("PATH");
        let saved_root = std::env::var_os("TILLANDSIAS_CHROMIUM_ROOT");
        unsafe {
            std::env::set_var("TILLANDSIAS_CHROMIUM_ROOT", userspace.path());
            std::env::set_var("PATH", path_dir.path());
        }

        let resolved = resolve().expect("must resolve userspace install");
        assert_eq!(resolved.source, ChromiumSource::UserspaceInstall);
        // Resolved path goes through the `current` symlink — both should
        // canonicalise to the same file.
        let resolved_canon = std::fs::canonicalize(&resolved.bin).unwrap();
        let user_canon = std::fs::canonicalize(&user_bin).unwrap();
        assert_eq!(resolved_canon, user_canon);

        unsafe {
            if let Some(p) = saved_path {
                std::env::set_var("PATH", p);
            } else {
                std::env::remove_var("PATH");
            }
            if let Some(r) = saved_root {
                std::env::set_var("TILLANDSIAS_CHROMIUM_ROOT", r);
            } else {
                std::env::remove_var("TILLANDSIAS_CHROMIUM_ROOT");
            }
        }
    }

    #[cfg(unix)]
    #[test]
    fn resolve_falls_back_to_system_when_userspace_missing() {
        let _guard = ENV_LOCK.lock().unwrap_or_else(|e| e.into_inner());
        let userspace = TempDir::new().unwrap(); // empty — no install
        let path_dir = TempDir::new().unwrap();
        let path_bin = seed_path_chromium(path_dir.path(), "chromium");

        let saved_path = std::env::var_os("PATH");
        let saved_root = std::env::var_os("TILLANDSIAS_CHROMIUM_ROOT");
        unsafe {
            std::env::set_var("TILLANDSIAS_CHROMIUM_ROOT", userspace.path());
            std::env::set_var("PATH", path_dir.path());
        }

        let resolved = resolve().expect("must fall back to system PATH");
        assert_eq!(resolved.source, ChromiumSource::SystemFallback);
        assert_eq!(resolved.bin, path_bin);

        unsafe {
            if let Some(p) = saved_path {
                std::env::set_var("PATH", p);
            } else {
                std::env::remove_var("PATH");
            }
            if let Some(r) = saved_root {
                std::env::set_var("TILLANDSIAS_CHROMIUM_ROOT", r);
            } else {
                std::env::remove_var("TILLANDSIAS_CHROMIUM_ROOT");
            }
        }
    }

    #[cfg(unix)]
    #[test]
    fn resolve_returns_hard_error_when_nothing_resolves() {
        let _guard = ENV_LOCK.lock().unwrap_or_else(|e| e.into_inner());
        let userspace = TempDir::new().unwrap(); // empty
        let path_dir = TempDir::new().unwrap(); // empty PATH dir

        let saved_path = std::env::var_os("PATH");
        let saved_root = std::env::var_os("TILLANDSIAS_CHROMIUM_ROOT");
        unsafe {
            std::env::set_var("TILLANDSIAS_CHROMIUM_ROOT", userspace.path());
            std::env::set_var("PATH", path_dir.path());
        }

        let err = resolve().expect_err("must hard-error when nothing resolves");
        assert_eq!(err, NOT_FOUND_MESSAGE);

        unsafe {
            if let Some(p) = saved_path {
                std::env::set_var("PATH", p);
            } else {
                std::env::remove_var("PATH");
            }
            if let Some(r) = saved_root {
                std::env::set_var("TILLANDSIAS_CHROMIUM_ROOT", r);
            } else {
                std::env::remove_var("TILLANDSIAS_CHROMIUM_ROOT");
            }
        }
    }

    #[test]
    fn embedded_pin_matches_install_sh() {
        // Acceptance assertion: build.rs emits the same values that the
        // shell script declares. If a developer hand-edits one without
        // the other this test fails (per the
        // `refresh-chromium-pin.sh is the sole authoring path`
        // requirement).
        let install_sh = std::fs::read_to_string(
            std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("../scripts/install.sh"),
        )
        .expect("install.sh must exist alongside the workspace");

        let extract = |key: &str| -> String {
            for line in install_sh.lines() {
                let trimmed = line.trim_start();
                if let Some(rest) = trimmed.strip_prefix(key)
                    && let Some(after_eq) = rest.strip_prefix('=')
                {
                    let v = after_eq.trim();
                    let unquoted = v
                        .strip_prefix('"')
                        .and_then(|s| s.strip_suffix('"'))
                        .unwrap_or(v);
                    return unquoted.to_string();
                }
            }
            String::new()
        };

        assert_eq!(CHROMIUM_VERSION, extract("CHROMIUM_VERSION"));
        assert_eq!(CHROMIUM_SHA256_LINUX64, extract("CHROMIUM_SHA256_LINUX64"));
        assert_eq!(CHROMIUM_SHA256_MAC_ARM64, extract("CHROMIUM_SHA256_MAC_ARM64"));
        assert_eq!(CHROMIUM_SHA256_MAC_X64, extract("CHROMIUM_SHA256_MAC_X64"));
        assert_eq!(CHROMIUM_SHA256_WIN64, extract("CHROMIUM_SHA256_WIN64"));
    }
}
