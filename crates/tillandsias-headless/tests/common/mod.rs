//! Shared helpers for tillandsias-headless integration tests.
//!
//! @trace plan/index.yaml order 285 (headless-integration-tests-podman-gate)

use std::process::Command;
use std::sync::OnceLock;

/// True when the podman CLI is present AND a daemon/machine answers
/// `podman info`. False when the binary is missing (bare CI container,
/// builder toolbox) or the CLI reports a connection-class failure before it
/// can do real work (bare macOS host or CI without `podman machine start`).
///
/// Mirrors `ssh_keygen_available()` in tillandsias-core's gh_auth_deploy_key
/// tests: podman-integration tests call this once at the top and skip with an
/// eprintln when it returns false, so a toolchain-only host runs the rest of
/// the suite instead of failing on environmental absence. The probe result is
/// cached per test binary.
pub fn podman_daemon_reachable() -> bool {
    static REACHABLE: OnceLock<bool> = OnceLock::new();
    *REACHABLE.get_or_init(|| {
        Command::new("podman")
            .args(["info", "--format", "{{.Host.Arch}}"])
            .output()
            .map(|o| o.status.success())
            .unwrap_or(false)
    })
}
