//! Re-export shim for the `tillandsias-otp` workspace crate.
//!
//! The session-cookie store + OTP issuance lives in `crates/tillandsias-otp/`
//! so the router-side sidecar can share it without pulling in the tauri
//! dependency tree. This file keeps `crate::otp::*` paths working for the
//! six tray-side callers (browser.rs, cdp.rs, control_socket/handler.rs,
//! event_loop.rs, main.rs, handlers.rs).
//!
//! @trace spec:opencode-web-session-otp, spec:secrets-management
//! @cheatsheet web/cookie-auth-best-practices.md

pub use tillandsias_otp::*;
