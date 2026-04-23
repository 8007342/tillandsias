//! Tauri webview sessions for OpenCode Web.
//!
//! Each "Attach Here" click in web mode opens a runtime-created
//! `WebviewWindow` pointing at the project's local-loopback OpenCode Web
//! server. Windows are labeled `web-<project>-<epoch_ms>` so multiple
//! webviews can attach to the same container concurrently. Closing a window
//! does not stop the underlying container.
//!
//! @trace spec:opencode-web-session

use std::sync::OnceLock;
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

use tauri::{AppHandle, Manager, Runtime, Url, WebviewUrl, WebviewWindowBuilder, Wry};
use tracing::{debug, info, warn};

/// Process-global AppHandle, installed once from Tauri's `.setup()` closure.
///
/// The `*_global` convenience wrappers fetch this handle so callers in
/// `handlers.rs` (which run on the tokio event-loop, not inside a Tauri
/// command) can open and close webviews without threading an AppHandle
/// through every signature.
///
/// @trace spec:opencode-web-session
static APP_HANDLE: OnceLock<AppHandle<Wry>> = OnceLock::new();

/// Install the global AppHandle for the `*_global` convenience wrappers.
///
/// Call once from the Tauri `.setup()` closure in `main.rs`. Subsequent
/// calls log a warning and are otherwise ignored — the first handle wins.
///
/// @trace spec:opencode-web-session
pub fn set_app_handle(handle: AppHandle<Wry>) {
    if APP_HANDLE.set(handle).is_err() {
        warn!(
            spec = "opencode-web-session",
            "AppHandle already set — ignoring duplicate set"
        );
    }
}

/// Replace non-alphanumeric characters with `-` so the label is safe to use
/// as a window identifier and stable to match on later.
fn sanitize(project_name: &str) -> String {
    project_name
        .chars()
        .map(|c| if c.is_ascii_alphanumeric() { c } else { '-' })
        .collect()
}

/// Current epoch time in milliseconds, used as a monotonic suffix on
/// webview window labels.
fn epoch_ms() -> u128 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_millis())
        .unwrap_or(0)
}

/// Open a new Tauri WebviewWindow pointing at a project's OpenCode Web
/// server. Unique labels allow many concurrent webviews per container.
///
/// The window has no linkage to the container — closing it leaves the
/// server running, and another webview can reattach on the next click.
///
/// @trace spec:opencode-web-session
pub fn open_web_session<R: Runtime>(
    app: &AppHandle<R>,
    project_name: &str,
    genus_label: &str,
    host_port: u16,
) -> tauri::Result<()> {
    let label = format!("web-{}-{}", sanitize(project_name), epoch_ms());
    let url_str = format!("http://127.0.0.1:{host_port}/");
    // 127.0.0.1 with a u16 port is always a valid URL; unwrap is safe.
    let url: Url = url_str.parse().expect("valid loopback URL");
    let title = format!("Tillandsias — {project_name} ({genus_label})");

    info!(
        project = project_name,
        genus = genus_label,
        port = host_port,
        label = %label,
        "opening opencode-web session"
    );

    WebviewWindowBuilder::new(app, &label, WebviewUrl::External(url))
        .title(title)
        .inner_size(1200.0, 800.0)
        .resizable(true)
        .build()
        .map(|_| ())
}

/// Close every webview window whose label begins with `web-<project>-`.
///
/// @trace spec:opencode-web-session
pub fn close_web_sessions_for_project<R: Runtime>(app: &AppHandle<R>, project_name: &str) {
    let prefix = format!("web-{}-", sanitize(project_name));
    let windows = app.webview_windows();
    for (label, window) in windows {
        if label.starts_with(&prefix) {
            match window.close() {
                Ok(()) => debug!(label = %label, "closed opencode-web session window"),
                Err(e) => warn!(label = %label, error = %e, "failed to close opencode-web session window"),
            }
        }
    }
}

/// Close every web-session window (any project). Called from shutdown_all().
///
/// @trace spec:opencode-web-session, spec:app-lifecycle
pub fn close_all_web_sessions<R: Runtime>(app: &AppHandle<R>) {
    let windows = app.webview_windows();
    for (label, window) in windows {
        if label.starts_with("web-") {
            match window.close() {
                Ok(()) => debug!(label = %label, "closed opencode-web session window on shutdown"),
                Err(e) => warn!(label = %label, error = %e, "failed to close opencode-web session window on shutdown"),
            }
        }
    }
}

/// Poll `GET http://127.0.0.1:<host_port>/` until the server responds with a
/// non-5xx status or the 30-second budget elapses.
///
/// Uses exponential backoff (1s, 2s, 4s, 8s cap) between attempts. Any
/// `status < 500` is treated as ready — OpenCode may return 4xx during init,
/// and we only care that the server is accepting connections.
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

        // Sleep, but never overrun the budget.
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

/// Open a webview against `http://127.0.0.1:<host_port>/` using the
/// process-global AppHandle. Returns an error if the handle has not been
/// installed yet via [`set_app_handle`].
///
/// @trace spec:opencode-web-session
pub fn open_web_session_global(
    project_name: &str,
    genus_label: &str,
    host_port: u16,
) -> tauri::Result<()> {
    match APP_HANDLE.get() {
        Some(app) => open_web_session(app, project_name, genus_label, host_port),
        None => {
            warn!(
                spec = "opencode-web-session",
                project = project_name,
                "AppHandle not set — cannot open webview"
            );
            Err(tauri::Error::Io(std::io::Error::other(
                "AppHandle not set — cannot open webview",
            )))
        }
    }
}

/// Close every webview for `project_name` using the process-global AppHandle.
/// If the handle has not been installed, logs a warning and returns silently.
///
/// @trace spec:opencode-web-session
pub fn close_web_sessions_for_project_global(project_name: &str) {
    match APP_HANDLE.get() {
        Some(app) => close_web_sessions_for_project(app, project_name),
        None => warn!(
            spec = "opencode-web-session",
            project = project_name,
            "AppHandle not set — cannot close project webviews"
        ),
    }
}

/// Close every open `web-*` webview using the process-global AppHandle.
/// If the handle has not been installed, logs a warning and returns silently.
///
/// @trace spec:opencode-web-session, spec:app-lifecycle
pub fn close_all_web_sessions_global() {
    match APP_HANDLE.get() {
        Some(app) => close_all_web_sessions(app),
        None => warn!(
            spec = "opencode-web-session",
            "AppHandle not set — cannot close webviews on shutdown"
        ),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn sanitize_preserves_alphanumeric() {
        assert_eq!(sanitize("myproject123"), "myproject123");
    }

    #[test]
    fn sanitize_replaces_non_alphanumeric() {
        assert_eq!(sanitize("my project/with.weird_chars"), "my-project-with-weird-chars");
    }

    #[test]
    fn sanitize_hyphens_become_hyphens() {
        // Hyphens themselves are not alphanumeric so they become `-` (identity).
        assert_eq!(sanitize("cool-project"), "cool-project");
    }
}
