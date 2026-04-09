//! Shared user-facing string constants for error paths.
//!
//! These compile-time constants are used in `map_err` closures that require
//! `&str`. For locale-aware strings in UI contexts, use `i18n::t()` directly.

// ── Compile-time constants (English) ──────────────────────────────────────────

pub const SETUP_ERROR: &str = "Tillandsias is setting up. If this persists, please reinstall from https://github.com/8007342/tillandsias";
pub const ENV_NOT_READY: &str = "Development environment not ready yet. Tillandsias will set it up automatically \u{2014} please try again in a few minutes.";
#[allow(dead_code)] // Reserved for installation validation error path
pub const INSTALL_INCOMPLETE: &str = "Tillandsias installation may be incomplete. Please reinstall from https://github.com/8007342/tillandsias";
