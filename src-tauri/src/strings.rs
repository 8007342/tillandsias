//! Shared user-facing string constants — now backed by the i18n module.
//!
//! Call `strings::setup_error()` etc. for locale-aware lookups at runtime.
//!
//! The constants `SETUP_ERROR`, `ENV_NOT_READY`, and `INSTALL_INCOMPLETE` are
//! kept for backward compatibility with `map_err` closures that require a
//! `&str` constant (not a function call). They always resolve to English;
//! prefer the function forms for user-visible output.

use crate::i18n;

/// Shown when an internal setup step fails. Locale-aware at runtime.
pub fn setup_error() -> &'static str {
    i18n::t("errors.setup")
}

/// Shown when the development environment image is not yet available. Locale-aware.
pub fn env_not_ready() -> &'static str {
    i18n::t("errors.env_not_ready")
}

/// Shown when an embedded script cannot be extracted. Locale-aware at runtime.
pub fn install_incomplete() -> &'static str {
    i18n::t("errors.install_incomplete")
}

// ── Backward-compatible compile-time constants (English) ────────────────────
// Use only where a &str *constant* is required (e.g. inside map_err closures).
// Prefer the function forms above everywhere else.

pub const SETUP_ERROR: &str = "Tillandsias is setting up. If this persists, please reinstall from https://github.com/8007342/tillandsias";
pub const ENV_NOT_READY: &str = "Development environment not ready yet. Tillandsias will set it up automatically \u{2014} please try again in a few minutes.";
pub const INSTALL_INCOMPLETE: &str = "Tillandsias installation may be incomplete. Please reinstall from https://github.com/8007342/tillandsias";
