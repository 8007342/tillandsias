//! Shared user-facing string constants.
//!
//! Error messages that appear in more than 2 locations are defined here to
//! ensure a single source of truth. When the GitHub URL or wording changes,
//! it only needs to change in one place.

/// Shown when an internal setup step fails. Instructs the user to reinstall if
/// the problem persists.
pub const SETUP_ERROR: &str = "Tillandsias is setting up. If this persists, please reinstall from https://github.com/8007342/tillandsias";

/// Shown when the development environment image is not yet available and the
/// user tries to launch a project.
pub const ENV_NOT_READY: &str = "Development environment not ready yet. Tillandsias will set it up automatically \u{2014} please try again in a few minutes.";

/// Shown when an embedded script cannot be extracted, suggesting the installation
/// archive is corrupt or partial.
pub const INSTALL_INCOMPLETE: &str = "Tillandsias installation may be incomplete. Please reinstall from https://github.com/8007342/tillandsias";
