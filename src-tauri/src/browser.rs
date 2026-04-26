//! Native browser launcher for OpenCode Web sessions.
//!
//! Replaces the Tauri WebKit2GTK webview entirely. On Attach Here (web mode),
//! the tray detects the user's browser and spawns it in app-mode (single-site
//! window, no tabs, no URL bar) pointed at the forge's router-fronted
//! `<project>.opencode.localhost` URL. The host-side router container
//! (Caddy bound to `127.0.0.1:80`) reverse-proxies into the forge over the
//! enclave network — port 80 is implicit, no path segment.
//!
//! Detection order (first match wins): Safari → Chrome → Chromium →
//! Microsoft Edge → Firefox → OS default (xdg-open / open / start).
//!
//! Per-project isolation is per-browser:
//!   Chromium family: `--user-data-dir=<tmpdir>`
//!   Firefox:         `--profile <tmpdir> --no-remote`
//!   Safari:          no isolation knob (accepted tradeoff on macOS)
//!   fallback:        whatever the OS default browser does
//!
//! @trace spec:opencode-web-session

use std::path::{Path, PathBuf};
use std::process::{Child, Command};
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

use tracing::{debug, info, warn};

/// Which browser family was detected + how to launch it.
///
/// The order of variants is also the detection preference order
/// (first match wins).
///
/// @trace spec:opencode-web-session
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum BrowserKind {
    /// Safari on macOS — `open -n -a Safari <url>`. No profile isolation.
    #[cfg_attr(not(target_os = "macos"), allow(dead_code))]
    Safari,
    /// Chrome / Chromium / Edge family — `--app=<url> --user-data-dir=<tmp>`.
    /// `bin` holds the resolved executable path.
    Chromium { bin: PathBuf },
    /// Firefox — `--new-instance --no-remote --profile <tmp> <url>`.
    Firefox { bin: PathBuf },
    /// OS-default launcher. Last-resort fallback when none of the above
    /// resolved — launches a normal browser window/tab via the platform
    /// convention.
    OsDefault,
}

impl BrowserKind {
    /// Human-readable name for logs.
    fn name(&self) -> &'static str {
        match self {
            BrowserKind::Safari => "Safari",
            BrowserKind::Chromium { .. } => "Chromium-family",
            BrowserKind::Firefox { .. } => "Firefox",
            BrowserKind::OsDefault => "OS default",
        }
    }
}

/// Sanitize a project name for use in a URL hostname.
/// Keeps `[a-z0-9-]`, everything else becomes `-`.
fn sanitize_hostname_label(name: &str) -> String {
    name.chars()
        .map(|c| {
            if c.is_ascii_alphanumeric() || c == '-' {
                c.to_ascii_lowercase()
            } else {
                '-'
            }
        })
        .collect()
}

/// Encode bytes as URL-safe base64 with no padding — the exact shape
/// OpenCode's SolidJS router expects in its `:dir` route segment.
/// Matches JS `btoa(...)` with `+`→`-` and `/`→`_` substitutions.
///
/// @trace spec:opencode-web-session
fn base64_url_encode(bytes: &[u8]) -> String {
    const ALPHABET: &[u8; 64] =
        b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
    let mut out = String::with_capacity(bytes.len().div_ceil(3) * 4);
    let mut i = 0;
    while i + 3 <= bytes.len() {
        let n = ((bytes[i] as u32) << 16) | ((bytes[i + 1] as u32) << 8) | (bytes[i + 2] as u32);
        out.push(ALPHABET[((n >> 18) & 0x3f) as usize] as char);
        out.push(ALPHABET[((n >> 12) & 0x3f) as usize] as char);
        out.push(ALPHABET[((n >> 6) & 0x3f) as usize] as char);
        out.push(ALPHABET[(n & 0x3f) as usize] as char);
        i += 3;
    }
    let remaining = bytes.len() - i;
    if remaining == 1 {
        let n = (bytes[i] as u32) << 16;
        out.push(ALPHABET[((n >> 18) & 0x3f) as usize] as char);
        out.push(ALPHABET[((n >> 12) & 0x3f) as usize] as char);
    } else if remaining == 2 {
        let n = ((bytes[i] as u32) << 16) | ((bytes[i + 1] as u32) << 8);
        out.push(ALPHABET[((n >> 18) & 0x3f) as usize] as char);
        out.push(ALPHABET[((n >> 12) & 0x3f) as usize] as char);
        out.push(ALPHABET[((n >> 6) & 0x3f) as usize] as char);
    }
    out.replace('+', "-").replace('/', "_")
}

/// Build the browser-facing URL for a project — legacy port-numbered form.
///
/// Shape: `http://<project>.localhost:<port>/<base64url(/home/forge/src/<project>)>/`
///
/// The base64 directory segment is what OpenCode's SolidJS router uses to
/// pin the session to the mounted project. Without it, the SPA root handler
/// shows a project picker ("Select a project") instead of landing directly
/// in the project's chat. We tried bare `/` earlier and the picker always
/// appeared — the `process.cwd()` fallback in the server's
/// `InstanceMiddleware` only resolves the directory for API requests, not
/// for the SPA's own initial render.
///
/// The user rarely sees this URL — app-mode hides the URL bar, and the
/// hostname already carries the project name for error contexts. The
/// base64 suffix is the trade-off for landing directly in the project.
///
/// - `<project>` is the sanitized project name (lowercase alphanumeric + hyphen).
///   Per RFC 6761 §6.3, browsers resolve `*.localhost` to loopback.
/// - `<port>` is the loopback-only host port the tray allocated for the forge.
///
/// **Deprecated**: superseded by [`build_subdomain_url`], which returns the
/// router-fronted `<project>.opencode.localhost` form (port 80 implicit, no
/// path segment). Kept for now so callers can migrate gradually.
// TODO: remove once all callers migrate
///
/// @trace spec:opencode-web-session, spec:subdomain-routing-via-reverse-proxy
#[allow(dead_code)]
pub fn build_attach_url(project_name: &str, host_port: u16) -> String {
    let host_label = sanitize_hostname_label(project_name);
    let project_dir = format!("/home/forge/src/{project_name}");
    let dir_b64 = base64_url_encode(project_dir.as_bytes());
    format!("http://{host_label}.localhost:{host_port}/{dir_b64}/")
}

/// Build the browser-facing URL for a project — router-fronted subdomain form.
///
/// Shape: `http://opencode.<project>.localhost:8080/`
///
/// Service-leftmost ordering: the service identifier (`opencode`) comes
/// FIRST, then the project name. This groups all per-project services
/// under one `*.<project>.localhost` namespace so future additions like
/// `web.<project>.localhost` (Flutter dev), `dashboard.<project>.localhost`
/// (agent UI), or `www.<project>.localhost` (static preview) sort
/// visually together when the user has multiple projects active.
///
/// The router container (Caddy) is published at `127.0.0.1:8080:80` —
/// internal Caddy listener stays on `:80` (allowed inside the container's
/// user namespace), but the host-side publish uses `:8080` because rootless
/// podman cannot bind ports below `net.ipv4.ip_unprivileged_port_start`
/// (default `1024` on Fedora and most distros). The router matches the
/// Host header `opencode.<project>.localhost` and reverse-proxies to the
/// project's forge container on the enclave network. There is no base64
/// path segment — the hostname carries both the project identity and the
/// service identifier, and OpenCode's `InstanceMiddleware` resolves the
/// project directory via `process.cwd()` (the forge entrypoint `cd`s
/// into `$PROJECT_DIR` before launching `opencode serve`).
///
/// `*.localhost` is hardcoded to loopback in Chromium (M64+), Firefox
/// (84+), and systemd-resolved (v245+), so no `/etc/hosts` entries are
/// needed. Subdomain depth does not affect this — `opencode.java.localhost`
/// resolves to loopback exactly like `java.opencode.localhost` did. The
/// browser sees this as a secure context (W3C Secure Contexts §3.1)
/// despite plain HTTP — loopback origins are secure regardless of port.
///
/// `<project>` is the sanitized project name (lowercase alphanumeric +
/// hyphen).
///
/// @trace spec:subdomain-routing-via-reverse-proxy, spec:opencode-web-session, spec:subdomain-naming-flip
/// @cheatsheet runtime/forge-container.md
///
/// @tombstone superseded:subdomain-naming-flip — kept for three releases
/// (until 0.1.169.231). Prior shape was
/// `format!("http://{host_label}.opencode.localhost:8080/")`
/// (project-leftmost). Flipped to service-leftmost so future per-project
/// services slot under `*.<project>.localhost` naturally.
pub fn build_subdomain_url(project_name: &str) -> String {
    let host_label = sanitize_hostname_label(project_name);
    format!("http://opencode.{host_label}.localhost:8080/")
}

/// Probe `$PATH` for a given executable. Returns its absolute path on first
/// match. Pure `$PATH` iteration so we don't shell out.
fn which(name: &str) -> Option<PathBuf> {
    let path = std::env::var_os("PATH")?;
    for dir in std::env::split_paths(&path) {
        let candidate = dir.join(name);
        if is_executable(&candidate) {
            return Some(candidate);
        }
    }
    None
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

/// Detect the user's browser. Returns the first match in the preferred order.
///
/// @trace spec:opencode-web-session
pub fn detect_browser() -> BrowserKind {
    // 1. Safari — macOS only.
    #[cfg(target_os = "macos")]
    {
        if Path::new("/Applications/Safari.app/Contents/MacOS/Safari").exists() {
            return BrowserKind::Safari;
        }
    }

    // 2. Chromium family — try binaries in preferred order.
    // Canonical Linux/path names first, then macOS bundle paths.
    let chromium_candidates: &[&str] = &[
        "google-chrome",
        "google-chrome-stable",
        "chromium",
        "chromium-browser",
        "chrome",
        "microsoft-edge",
        "microsoft-edge-stable",
        "msedge",
    ];
    for c in chromium_candidates {
        if let Some(bin) = which(c) {
            return BrowserKind::Chromium { bin };
        }
    }
    #[cfg(target_os = "macos")]
    {
        for path in [
            "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome",
            "/Applications/Chromium.app/Contents/MacOS/Chromium",
            "/Applications/Microsoft Edge.app/Contents/MacOS/Microsoft Edge",
        ] {
            if Path::new(path).exists() {
                return BrowserKind::Chromium { bin: PathBuf::from(path) };
            }
        }
    }

    // 3. Firefox.
    if let Some(bin) = which("firefox") {
        return BrowserKind::Firefox { bin };
    }
    #[cfg(target_os = "macos")]
    {
        let p = "/Applications/Firefox.app/Contents/MacOS/firefox";
        if Path::new(p).exists() {
            return BrowserKind::Firefox { bin: PathBuf::from(p) };
        }
    }

    // 4. Fallback — OS default launcher.
    BrowserKind::OsDefault
}

/// Allocate a temporary per-session profile / user-data directory under
/// `$XDG_RUNTIME_DIR/tillandsias/browser/<project>-<epoch>`. Created fresh;
/// cleaned up by systemd on user logout regardless.
fn session_profile_dir(project_name: &str) -> PathBuf {
    let base = std::env::var_os("XDG_RUNTIME_DIR")
        .map(PathBuf::from)
        .unwrap_or_else(std::env::temp_dir);
    let epoch_ms = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_millis())
        .unwrap_or(0);
    let dir = base
        .join("tillandsias")
        .join("browser")
        .join(format!("{}-{}", sanitize_hostname_label(project_name), epoch_ms));
    if let Err(e) = std::fs::create_dir_all(&dir) {
        warn!(
            spec = "opencode-web-session",
            error = %e,
            path = %dir.display(),
            "Failed to create browser profile dir — launch will still try without isolation"
        );
    }
    dir
}

/// Launch the native browser against a project's forge URL. Does NOT wait
/// for the browser to close — the browser window is the user's to manage.
/// Returns the spawned [`Child`] handle purely so callers can log the PID
/// or reap the exit if we decide to later. Most callers should just drop
/// the handle immediately.
///
/// The URL handed to the browser is the router-fronted subdomain form
/// (`http://<project>.opencode.localhost/`) — the host-side router
/// container at `127.0.0.1:80` reverse-proxies into the forge. The
/// `host_port` argument is retained only so callers can still pass through
/// the port allocation that backs the legacy `-p 127.0.0.1:<port>:4096`
/// publish; it is not embedded in the URL itself.
///
/// @trace spec:subdomain-routing-via-reverse-proxy, spec:opencode-web-session
pub fn launch_for_project(project_name: &str, host_port: u16) -> Result<Child, String> {
    let _ = host_port; // see doc-comment: legacy publish stays for now, URL ignores it
    let url = build_subdomain_url(project_name);
    let kind = detect_browser();
    info!(
        spec = "subdomain-routing-via-reverse-proxy",
        project = project_name,
        browser = kind.name(),
        url = %url,
        "launching native browser for opencode-web session"
    );

    let child = match &kind {
        BrowserKind::Safari => Command::new("open")
            .args(["-n", "-a", "Safari", &url])
            .spawn()
            .map_err(|e| format!("spawn Safari via `open`: {e}"))?,
        BrowserKind::Chromium { bin } => {
            let profile = session_profile_dir(project_name);
            // --app=<url>         : borderless single-site window
            // --user-data-dir     : isolated per-project profile (tmpfs)
            // --no-first-run      : skip the "welcome" wizard
            // --no-default-browser-check : don't prompt to make default
            // --disable-features=DesktopPWAsWithoutExtensions :
            //     defensive — PWA install UI is also killed at the proxy
            //     (see spec:opencode-web-session "PWA install is explicitly
            //     disabled"), but belt-and-braces: Chromium's install
            //     button relies on this feature flag.
            // --force-dark-mode + WebContentsForceDark :
            //     Signal `prefers-color-scheme: dark` to pages AND activate
            //     Chrome's auto-dark for content that doesn't opt in.
            //     Opencode's own theme-preload (seeded 'dark' by our proxy
            //     bootstrap) already paints dark; this covers every edge
            //     element that doesn't read the theme var (scrollbars, form
            //     controls, about:blank splash frames, etc.) so the entire
            //     window reads dark.
            //
            // GTK_THEME=Adwaita:dark (Linux only):
            //     Chrome/Chromium reads the system GTK theme to style its
            //     own window chrome (title bar + min/max/close buttons in
            //     --app mode). Without this, the title bar renders in the
            //     light theme even when the web content is dark. Setting
            //     the env only for the spawned browser is scoped — doesn't
            //     leak to other processes. macOS + Windows ignore this.
            let mut cmd = Command::new(bin);
            cmd.arg(format!("--app={url}"))
                .arg(format!("--user-data-dir={}", profile.display()))
                .arg("--no-first-run")
                .arg("--no-default-browser-check")
                .arg("--disable-features=DesktopPWAsWithoutExtensions")
                .arg("--force-dark-mode")
                .arg("--enable-features=WebContentsForceDark");
            #[cfg(all(unix, not(target_os = "macos")))]
            {
                cmd.env("GTK_THEME", "Adwaita:dark");
            }
            cmd.spawn().map_err(|e| format!("spawn {}: {e}", bin.display()))?
        }
        BrowserKind::Firefox { bin } => {
            let profile = session_profile_dir(project_name);
            // @trace spec:opencode-web-session
            // Seed a user.js in the fresh profile before launch so Firefox
            // advertises dark prefers-color-scheme to content, regardless
            // of the OS theme. Covers the same ground as Chromium's
            // --force-dark-mode flag. Profile is tmpfs and fresh per
            // attach, so writing here is safe.
            let user_js = profile.join("user.js");
            let prefs = [
                // Force the content-side prefers-color-scheme to dark.
                // 0 = match OS, 1 = dark, 2 = light. We pick dark.
                "user_pref(\"layout.css.prefers-color-scheme.content-override\", 1);",
                // Tell Firefox the system is in dark mode (affects about: pages
                // and anything that reads this pref directly).
                "user_pref(\"ui.systemUsesDarkTheme\", 1);",
                // Disable various first-run / telemetry prompts that can pop
                // a modal over our window on fresh profile.
                "user_pref(\"browser.startup.firstrunSkipsHomepage\", true);",
                "user_pref(\"datareporting.policy.firstRunURL\", \"\");",
                "user_pref(\"browser.shell.checkDefaultBrowser\", false);",
            ]
            .join("\n");
            if let Err(e) = std::fs::write(&user_js, prefs) {
                warn!(
                    spec = "opencode-web-session",
                    error = %e,
                    path = %user_js.display(),
                    "Failed to write Firefox user.js — window will use OS theme"
                );
            }
            // @trace spec:opencode-web-session
            // Firefox also reads GTK_THEME on Linux for its window chrome.
            let mut cmd = Command::new(bin);
            cmd.args(["--new-instance", "--no-remote", "--profile"])
                .arg(&profile)
                .arg(&url);
            #[cfg(all(unix, not(target_os = "macos")))]
            {
                cmd.env("GTK_THEME", "Adwaita:dark");
            }
            cmd.spawn().map_err(|e| format!("spawn firefox: {e}"))?
        }
        BrowserKind::OsDefault => {
            #[cfg(target_os = "macos")]
            let cmd_name = "open";
            #[cfg(target_os = "windows")]
            let cmd_name = "cmd";
            #[cfg(all(unix, not(target_os = "macos")))]
            let cmd_name = "xdg-open";
            Command::new(cmd_name)
                .arg(&url)
                .spawn()
                .map_err(|e| format!("spawn {cmd_name} fallback: {e}"))?
        }
    };
    Ok(child)
}

/// Poll `GET http://127.0.0.1:<host_port>/` until the server responds with
/// a non-5xx status or the 30-second budget elapses. We probe the raw
/// loopback address (not the `.localhost` subdomain URL) because this
/// readiness check runs inside the tray, not in the browser — no need to
/// exercise DNS here. Once ready, we launch the browser against the
/// subdomain URL so the user sees the nice address.
///
/// Uses exponential backoff (1s → 2s → 4s → 8s cap) between attempts.
/// Any `status < 500` is treated as ready.
///
/// @trace spec:opencode-web-session
pub async fn wait_for_web_ready(host_port: u16) -> Result<(), String> {
    let url = format!("http://127.0.0.1:{host_port}/");
    let client = reqwest::Client::builder()
        .timeout(Duration::from_secs(2))
        .build()
        .map_err(|e| format!("failed to build readiness probe client: {e}"))?;

    let start = Instant::now();
    let budget = Duration::from_secs(30);
    let mut backoff = Duration::from_secs(1);
    let max_backoff = Duration::from_secs(8);
    let mut last_error: Option<String> = None;

    while start.elapsed() < budget {
        match client.get(&url).send().await {
            Ok(resp) => {
                let status = resp.status();
                if status.as_u16() < 500 {
                    debug!(
                        port = host_port,
                        status = status.as_u16(),
                        elapsed_ms = start.elapsed().as_millis() as u64,
                        spec = "opencode-web-session",
                        "opencode-web server is ready"
                    );
                    return Ok(());
                }
                last_error = Some(format!("server returned status {status}"));
            }
            Err(e) => {
                last_error = Some(format!("{e}"));
            }
        }

        let remaining = budget.saturating_sub(start.elapsed());
        if remaining.is_zero() {
            break;
        }
        let sleep = std::cmp::min(backoff, remaining);
        tokio::time::sleep(sleep).await;
        backoff = std::cmp::min(backoff * 2, max_backoff);
    }

    Err(format!(
        "opencode-web server on 127.0.0.1:{host_port} did not become ready within 30s (last error: {})",
        last_error.as_deref().unwrap_or("none")
    ))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn sanitize_hostname_label_lowercases_and_hyphenates() {
        assert_eq!(sanitize_hostname_label("MyApp"), "myapp");
        assert_eq!(sanitize_hostname_label("my app"), "my-app");
        assert_eq!(sanitize_hostname_label("app/sub"), "app-sub");
        assert_eq!(sanitize_hostname_label("valid-name-123"), "valid-name-123");
    }

    #[test]
    fn build_attach_url_has_hostname_and_base64_dir() {
        // Legacy port-numbered URL builder — kept until all callers migrate
        // to `build_subdomain_url`. Asserts the old shape so we notice if it
        // is unintentionally changed before removal.
        // @trace spec:opencode-web-session
        let url = build_attach_url("thinking-service", 17000);
        assert!(
            url.starts_with("http://thinking-service.localhost:17000/"),
            "URL must use hostname <project>.localhost — got {url}"
        );
        // base64url of "/home/forge/src/thinking-service"
        assert!(
            url.ends_with("L2hvbWUvZm9yZ2Uvc3JjL3RoaW5raW5nLXNlcnZpY2U/"),
            "URL must end with base64url(/home/forge/src/<project>)/ so the \
             SPA lands directly on the project and doesn't render its \
             picker — got {url}"
        );
    }

    #[test]
    fn build_attach_url_no_ip_in_hostname() {
        let url = build_attach_url("thinking-service", 17000);
        assert!(!url.contains("127.0.0.1"), "got {url}");
    }

    #[test]
    fn build_attach_url_lowercases_mixed_case_project() {
        let url = build_attach_url("MyProject", 17000);
        assert!(
            url.starts_with("http://myproject.localhost:17000/"),
            "got {url}"
        );
    }

    /// Router-fronted URL: service identifier (`opencode`) leftmost, then
    /// project, then `.localhost:8080/`. Service-leftmost grouping enables
    /// future `web.<project>.localhost`, `dashboard.<project>.localhost`,
    /// etc. to slot under the same `*.<project>.localhost` namespace.
    /// @trace spec:subdomain-routing-via-reverse-proxy, spec:opencode-web-session, spec:subdomain-naming-flip
    #[test]
    fn build_subdomain_url_is_service_leftmost_port_8080_no_path() {
        let url = build_subdomain_url("thinking-service");
        assert_eq!(
            url, "http://opencode.thinking-service.localhost:8080/",
            "URL must be exactly opencode.<project>.localhost:8080/ — got {url}"
        );
    }

    /// @trace spec:subdomain-routing-via-reverse-proxy, spec:opencode-web-session, spec:subdomain-naming-flip
    #[test]
    fn build_subdomain_url_uses_rootless_port_8080() {
        let url = build_subdomain_url("thinking-service");
        assert!(!url.contains("127.0.0.1"), "got {url}");
        assert!(
            url.starts_with("http://opencode."),
            "URL must start with `http://opencode.` (service-leftmost) — got {url}"
        );
        assert!(
            url.ends_with(".localhost:8080/"),
            "URL must end with .localhost:8080/ (rootless podman cannot bind :80 — \
             see fix-router-loopback-port spec) — got {url}"
        );
        // No base64 path segment — only "/" after the port.
        assert!(!url.contains("L2hvbWU"), "URL must not carry the legacy base64 dir segment — got {url}");
    }

    /// @trace spec:subdomain-routing-via-reverse-proxy, spec:subdomain-naming-flip
    #[test]
    fn build_subdomain_url_lowercases_mixed_case_project() {
        let url = build_subdomain_url("MyProject");
        assert_eq!(url, "http://opencode.myproject.localhost:8080/");
    }

    /// @trace spec:subdomain-routing-via-reverse-proxy, spec:subdomain-naming-flip
    #[test]
    fn build_subdomain_url_sanitizes_invalid_label_chars() {
        // Spaces and slashes become hyphens (matches host-label rules).
        let url = build_subdomain_url("My App/sub");
        assert_eq!(url, "http://opencode.my-app-sub.localhost:8080/");
    }

    #[test]
    fn base64_url_encode_matches_js_btoa() {
        assert_eq!(
            base64_url_encode(b"/home/forge/src/tetris"),
            "L2hvbWUvZm9yZ2Uvc3JjL3RldHJpcw"
        );
    }

    #[test]
    fn browser_kind_name_labels_are_stable() {
        assert_eq!(BrowserKind::Safari.name(), "Safari");
        assert_eq!(
            BrowserKind::Chromium { bin: PathBuf::from("/tmp/x") }.name(),
            "Chromium-family"
        );
        assert_eq!(
            BrowserKind::Firefox { bin: PathBuf::from("/tmp/x") }.name(),
            "Firefox"
        );
        assert_eq!(BrowserKind::OsDefault.name(), "OS default");
    }
}
