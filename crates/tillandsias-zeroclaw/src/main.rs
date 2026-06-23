//! `tillandsias-zeroclaw` binary entry point.
//!
//! Usage:
//!   tillandsias-zeroclaw \
//!       --project-path /home/user/src/myproject \
//!       [--socket /run/user/1000/tillandsias/zeroclaw-myproject.sock]
//!
//! The server binds a Unix socket, then accepts one connection per container
//! launch. When the connection closes (container exits / socat terminates),
//! the server exits and the tray removes the socket file.
//!
//! Credentials (Vault token, Podman socket) are never exposed through this
//! surface — all tool calls run as the host user in the project directory.
//!
//! @trace spec:zeroclaw-orchestration

use std::env;
use std::fs;
use std::path::PathBuf;
use std::sync::Arc;

use tillandsias_zeroclaw::{SOCKET_ENV, ZeroClawAllowlist};
use tokio::net::UnixListener;
use tracing::{error, info};

#[tokio::main]
async fn main() -> Result<(), Box<dyn std::error::Error>> {
    tracing_subscriber::fmt()
        .with_env_filter(
            tracing_subscriber::EnvFilter::from_default_env()
                .add_directive("tillandsias_zeroclaw=info".parse()?),
        )
        .init();

    let args: Vec<String> = env::args().collect();
    let (project_path, socket_path) = parse_args(&args)?;

    let allowlist = Arc::new(ZeroClawAllowlist::new(&project_path));

    // Remove stale socket if it exists (previous crash / unclean exit).
    if socket_path.exists() {
        fs::remove_file(&socket_path)?;
    }
    // Ensure parent directory exists.
    if let Some(parent) = socket_path.parent() {
        fs::create_dir_all(parent)?;
    }

    let listener = UnixListener::bind(&socket_path)?;
    info!(
        socket = %socket_path.display(),
        project = %project_path.display(),
        "zeroclaw-mcp: listening"
    );

    // Accept connections sequentially (one container per launch).
    loop {
        match listener.accept().await {
            Ok((stream, _addr)) => {
                tillandsias_zeroclaw::serve_connection(stream, &allowlist).await;
            }
            Err(e) => {
                error!(err = %e, "zeroclaw-mcp: accept error");
                break;
            }
        }
    }

    let _ = fs::remove_file(&socket_path);
    Ok(())
}

/// Parse `--project-path <path>` and optional `--socket <path>` from argv.
fn parse_args(args: &[String]) -> Result<(PathBuf, PathBuf), String> {
    let mut project_path: Option<PathBuf> = None;
    let mut socket_path: Option<PathBuf> = None;

    let mut i = 1;
    while i < args.len() {
        match args[i].as_str() {
            "--project-path" => {
                i += 1;
                project_path = Some(PathBuf::from(
                    args.get(i).ok_or("--project-path requires a value")?,
                ));
            }
            "--socket" => {
                i += 1;
                socket_path = Some(PathBuf::from(
                    args.get(i).ok_or("--socket requires a value")?,
                ));
            }
            _ => {}
        }
        i += 1;
    }

    let project_path = project_path.ok_or_else(|| "--project-path is required".to_string())?;

    let socket_path = socket_path
        .or_else(|| env::var_os(SOCKET_ENV).map(PathBuf::from))
        .unwrap_or_else(|| {
            let project_name = project_path
                .file_name()
                .and_then(|n| n.to_str())
                .unwrap_or("unknown");
            let runtime_dir = env::var_os("XDG_RUNTIME_DIR")
                .map(PathBuf::from)
                .unwrap_or_else(|| {
                    PathBuf::from(format!(
                        "/run/user/{}",
                        // SAFETY: getuid is always safe to call.
                        unsafe { libc::getuid() }
                    ))
                });
            runtime_dir.join(format!("tillandsias/zeroclaw-{project_name}.sock"))
        });

    Ok((project_path, socket_path))
}
