//! Browser process launcher for `browser.open`.
//!
//! @trace spec:host-browser-mcp, spec:host-chromium-on-demand
//! @cheatsheet web/cdp.md

use std::fs;
use std::io::{Read, Write};
use std::net::{SocketAddr, TcpListener, TcpStream};
use std::path::{Path, PathBuf};
use std::process::{Child, Command, Stdio};
use std::time::{Duration, Instant};

use serde_json::Value;
use url::Url;
use uuid::Uuid;

use crate::window_registry::WindowEntry;

#[derive(Debug, thiserror::Error)]
pub enum LaunchError {
    #[error("bundled chromium not yet downloaded")]
    BrowserUnavailable,
    #[error("failed to spawn browser: {0}")]
    Spawn(String),
    #[error("browser metadata probe failed: {0}")]
    Probe(String),
    #[error("io error: {0}")]
    Io(#[from] std::io::Error),
}

fn home_dir() -> Option<PathBuf> {
    std::env::var_os("HOME")
        .map(PathBuf::from)
        .or_else(|| std::env::var_os("USERPROFILE").map(PathBuf::from))
}

fn writable_root(candidates: impl IntoIterator<Item = PathBuf>) -> Option<PathBuf> {
    candidates
        .into_iter()
        .find(|candidate| fs::create_dir_all(candidate).is_ok())
}

fn cache_root() -> Option<PathBuf> {
    let mut candidates = Vec::new();
    if let Some(value) = std::env::var_os("XDG_CACHE_HOME") {
        candidates.push(PathBuf::from(value).join("tillandsias/chromium"));
    }
    if let Some(home) = home_dir() {
        candidates.push(home.join(".cache/tillandsias/chromium"));
    }
    candidates.push(PathBuf::from("/tmp/tillandsias/chromium"));
    writable_root(candidates)
}

fn runtime_root() -> PathBuf {
    let mut candidates = Vec::new();
    if let Some(value) = std::env::var_os("XDG_RUNTIME_DIR") {
        candidates.push(PathBuf::from(value).join("tillandsias/mcp"));
    }
    if let Some(value) = std::env::var_os("TMPDIR") {
        candidates.push(PathBuf::from(value).join("tillandsias/mcp"));
    }
    candidates.push(PathBuf::from("/tmp/tillandsias/mcp"));
    writable_root(candidates).unwrap_or_else(|| PathBuf::from("/tmp/tillandsias/mcp"))
}

fn resolve_browser_binary(override_bin: Option<&Path>) -> Result<PathBuf, LaunchError> {
    if let Some(bin) = override_bin {
        return Ok(bin.to_path_buf());
    }
    if let Some(value) = std::env::var_os("TILLANDSIAS_BROWSER_BIN") {
        return Ok(PathBuf::from(value));
    }
    if let Some(value) = std::env::var_os("TILLANDSIAS_CHROMIUM_BIN") {
        return Ok(PathBuf::from(value));
    }

    let root = cache_root().ok_or(LaunchError::BrowserUnavailable)?;
    let candidates = [
        root.join("current/chrome"),
        root.join("current/chrome-linux64/chrome"),
        root.join("current/chrome.exe"),
        root.join("chrome"),
        root.join("chrome-linux64/chrome"),
    ];

    candidates
        .into_iter()
        .find(|candidate| candidate.exists())
        .ok_or(LaunchError::BrowserUnavailable)
}

fn reserve_port() -> Result<u16, std::io::Error> {
    let listener = TcpListener::bind(("127.0.0.1", 0))?;
    let port = listener.local_addr()?.port();
    drop(listener);
    Ok(port)
}

fn profile_root() -> PathBuf {
    runtime_root()
}

fn ensure_dir(path: &Path) -> Result<(), std::io::Error> {
    fs::create_dir_all(path)
}

fn cdp_http_list(port: u16) -> Result<Option<(String, String)>, LaunchError> {
    let addr = SocketAddr::from(([127, 0, 0, 1], port));
    let deadline = Instant::now() + Duration::from_millis(1500);
    while Instant::now() < deadline {
        match TcpStream::connect_timeout(&addr, Duration::from_millis(150)) {
            Ok(mut stream) => {
                let _ = stream.set_read_timeout(Some(Duration::from_millis(150)));
                let _ = stream.set_write_timeout(Some(Duration::from_millis(150)));
                let request =
                    b"GET /json/list HTTP/1.1\r\nHost: 127.0.0.1\r\nConnection: close\r\n\r\n";
                stream.write_all(request)?;
                let mut response = String::new();
                stream.read_to_string(&mut response)?;
                let body = response
                    .split_once("\r\n\r\n")
                    .map(|(_, body)| body)
                    .unwrap_or("");
                let parsed: Value = serde_json::from_str(body)
                    .map_err(|err| LaunchError::Probe(err.to_string()))?;
                let Some(first) = parsed.as_array().and_then(|items| items.first()) else {
                    return Err(LaunchError::Probe("no CDP targets discovered".to_string()));
                };
                let target_id = first
                    .get("id")
                    .and_then(|value| value.as_str())
                    .unwrap_or("unknown")
                    .to_string();
                let title = first
                    .get("title")
                    .and_then(|value| value.as_str())
                    .unwrap_or("browser")
                    .to_string();
                return Ok(Some((target_id, title)));
            }
            Err(_) => {
                std::thread::sleep(Duration::from_millis(100));
            }
        }
    }

    Ok(None)
}

fn default_title(url: &Url) -> String {
    url.host_str().unwrap_or("browser").to_string()
}

fn spawn_browser(
    binary: &Path,
    url: &Url,
    user_data_dir: &Path,
    cdp_port: u16,
) -> Result<Child, LaunchError> {
    let mut command = Command::new(binary);
    command
        .arg(format!("--app={}", url.as_str()))
        .arg(format!("--user-data-dir={}", user_data_dir.display()))
        .arg("--incognito")
        .arg("--no-first-run")
        .arg("--no-default-browser-check")
        .arg(format!("--remote-debugging-port={cdp_port}"))
        .arg("--remote-debugging-address=127.0.0.1")
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::null());

    command
        .spawn()
        .map_err(|err| LaunchError::Spawn(err.to_string()))
}

/// Launch a browser window and return its registry entry.
pub fn launch(
    url: &Url,
    project_label: &str,
    browser_binary: Option<&Path>,
    fake_launch: bool,
) -> Result<WindowEntry, LaunchError> {
    let window_id = format!("win-{}", Uuid::new_v4());
    let user_data_dir = profile_root().join(&window_id);
    if !fake_launch {
        ensure_dir(&user_data_dir)?;
    }
    let cdp_port = if fake_launch { 0 } else { reserve_port()? };
    let (child, target_id, title) = if fake_launch {
        (None, format!("{window_id}-target"), default_title(url))
    } else {
        let binary = resolve_browser_binary(browser_binary)?;
        let child = spawn_browser(&binary, url, &user_data_dir, cdp_port)?;
        let probe = cdp_http_list(cdp_port).unwrap_or(None);
        let (target_id, title) =
            probe.unwrap_or_else(|| (format!("{window_id}-target"), default_title(url)));
        (Some(child), target_id, title)
    };

    // @trace spec:browser-window-timeout
    let now = std::time::Instant::now();
    Ok(WindowEntry {
        window_id,
        pid: child.as_ref().map(|child| child.id()).unwrap_or(0),
        cdp_port,
        target_id,
        project_label: project_label.to_string(),
        user_data_dir,
        opened_url: url.as_str().to_string(),
        title,
        child,
        created_at: now,
        last_activity: now,
    })
}

/// Remove a browser profile directory after close.
pub fn remove_profile_dir(path: &Path) {
    let _ = fs::remove_dir_all(path);
}
