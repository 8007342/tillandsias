//! Legacy menu helpers — superseded by `tray_menu`.
//!
//! The old hierarchical menu builder has been removed. The only piece kept
//! here is `needs_github_login` because it's used outside the menu code
//! itself (e.g. by `event_loop` to gate remote-repos refresh) and giving it
//! a separate home would require a wider rename. The legacy menu shape
//! is described historically in
//! `openspec/changes/archive/<date>-simplified-tray-ux/`.
//!
//! @trace spec:simplified-tray-ux

/// Check if GitHub authentication is needed.
///
/// Returns `true` when the OS keyring has no GitHub OAuth token, OR when the
/// keyring itself is unavailable. In either case the UI must surface a login
/// prompt: we cannot authenticate without a token, and we no longer keep any
/// on-disk fallback to fall through to.
///
/// @trace spec:native-secrets-store
pub(crate) fn needs_github_login() -> bool {
    !matches!(crate::secrets::retrieve_github_token(), Ok(Some(_)))
}
