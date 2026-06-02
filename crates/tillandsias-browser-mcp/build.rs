//! Build script for the browser-mcp crate.
//!
//! Reads the workspace VERSION file and exposes it as `WORKSPACE_VERSION`
//! so the MCP server's `initialize` response carries the release version
//! (`0.2.260528.1`) rather than the crate's static `Cargo.toml` `version
//! = "0.1.170"`. The MCP protocol's `serverInfo.version` field is what
//! the AI agent sees as the host-browser-mcp server's protocol version;
//! reporting the workspace VERSION makes cross-version discoverability
//! work (operator pastes the agent's serverInfo into a bug report → can
//! correlate to a specific release).
//!
//! Same shape + fallback pattern as `tillandsias-host-shell/build.rs`
//! and `tillandsias-windows-tray/build.rs`. The shared fix shipped at
//! 2026-05-30T12:21Z (commit 76f93287); this slice closes the
//! browser-mcp-side follow-on flagged in that commit body.
//!
//! @trace spec:host-browser-mcp, spec:tray-app

fn main() {
    let manifest_dir_path =
        std::path::PathBuf::from(std::env::var("CARGO_MANIFEST_DIR").unwrap_or_default());
    let version_file = manifest_dir_path.join("../../VERSION");
    let workspace_version = std::fs::read_to_string(&version_file)
        .map(|s| s.trim().to_string())
        .unwrap_or_else(|_| env!("CARGO_PKG_VERSION").to_string());
    println!("cargo:rerun-if-changed=../../VERSION");
    println!("cargo:rustc-env=WORKSPACE_VERSION={workspace_version}");
}
