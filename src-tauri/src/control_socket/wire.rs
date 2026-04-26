//! Re-export shim for the `tillandsias-control-wire` workspace crate.
//!
//! The postcard schema lives in `crates/tillandsias-control-wire/` so the
//! router-side sidecar can speak the wire format without pulling in the
//! tray's tauri / tokio-tungstenite / reqwest dependency tree.
//!
//! @trace spec:tray-host-control-socket

pub use tillandsias_control_wire::*;
