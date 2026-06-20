//! Host-resident MCP server for NanoClawV2 project-scoped orchestration.
//!
//! Listens on a Unix socket (path from `--socket` / `TILLANDSIAS_NANOCLAW_SOCKET`),
//! accepts connections from the NanoClawV2 container via `socat`, and dispatches
//! only the five approved orchestration actions through the project-locked allowlist.
//!
//! Architecture mirror: identical transport pattern to `tillandsias-browser-mcp`
//! (Unix socket + socat bridge + JSON-RPC 2.0 newline-framed stdio).
//!
//! @trace spec:nanoclawv2-orchestration

pub mod allowlist;
pub mod server;

pub use allowlist::NanoClawAllowlist;
pub use server::serve_connection;

/// Default in-container path the server socket is bind-mounted at.
/// Must match the path used in the container launch spec in `tray/mod.rs`.
pub const DEFAULT_CONTAINER_SOCKET_PATH: &str = "/run/host/tillandsias/nanoclaw.sock";

/// Env var name for overriding the host-side socket path.
pub const SOCKET_ENV: &str = "TILLANDSIAS_NANOCLAW_SOCKET";
