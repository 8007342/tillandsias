//! Host-resident MCP server for browser automation.
//!
//! Provides `browser.open`, `browser.click`, `browser.type`, etc. over MCP JSON-RPC
//! stdio transport. Bridges the forge's agents to the host's CDP-driven browser windows.
//!
//! @trace spec:host-browser-mcp, spec:browser-debounce, spec:browser-isolation-launcher
//! @cheatsheet web/mcp.md, web/cdp.md

pub mod allowlist;
pub mod cdp_client;
pub mod framing;
pub mod launcher;
pub mod server;
pub mod window_registry;

pub use cdp_client::{CdpConnectionPool, CdpSession};
pub use server::{BrowserMcpServer, McpServerConfig};

// Order 779-dqsv: the per-session concurrent-call limit (DEFAULT_CONCURRENT_CALLS)
// was REMOVED. Its only transport handles one request at a time, so the limit
// could never bind — see `BrowserMcpServer` for the full reasoning and for where
// a limit belongs if a future transport pipelines requests.
