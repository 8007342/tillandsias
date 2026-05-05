//! Host-resident MCP server for browser automation.
//!
//! Provides `browser.open`, `browser.click`, `browser.type`, etc. over MCP JSON-RPC
//! stdio transport. Bridges the forge's agents to the host's CDP-driven browser windows.
//!
//! @trace spec:host-browser-mcp
//! @cheatsheet web/mcp.md, web/cdp.md

pub mod framing;
pub mod server;

pub use server::{BrowserMcpServer, McpServerConfig};

/// Default per-session concurrent call limit (16 tools can run in parallel).
pub const DEFAULT_CONCURRENT_CALLS: usize = 16;
