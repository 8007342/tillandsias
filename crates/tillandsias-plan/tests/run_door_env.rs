// @trace order:1838-nwyn
// The run door scrubs the caller's environment but must pass the user-session
// handles toolbox/podman need. A separate process keeps the runner's env intact.
#![cfg(unix)]

use std::process::Command;

#[test]
fn run_door_passes_session_handles_and_scrubs_the_rest() {
    let dir = tempfile::tempdir().unwrap();
    std::fs::create_dir(dir.path().join(".git")).unwrap();
    let out = Command::new(env!("CARGO_BIN_EXE_tillandsias-plan"))
        .current_dir(dir.path())
        .env_remove("CI")
        .env("TILLANDSIAS_REPO_ROOT", dir.path())
        .env("TILLANDSIAS_POLICY_REGIME", "interactive")
        .env("XDG_RUNTIME_DIR", "/run/user/4242")
        .env("DBUS_SESSION_BUS_ADDRESS", "unix:path=/run/user/4242/bus")
        .env("NWYN_SCRUBBED_CONTROL", "leaked")
        .args(["run", "--json", "--", "/usr/bin/env"])
        .output()
        .unwrap();
    let v: serde_json::Value = serde_json::from_slice(&out.stdout).unwrap_or_else(|e| {
        panic!(
            "{e}: {}{}",
            String::from_utf8_lossy(&out.stdout),
            String::from_utf8_lossy(&out.stderr)
        )
    });
    let child = v["stdout"].as_str().unwrap_or_default();
    assert_eq!(v["status"], "exited", "{v}");
    assert!(
        child.contains("XDG_RUNTIME_DIR=/run/user/4242\n"),
        "{child}"
    );
    assert!(
        child.contains("DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/4242/bus\n"),
        "{child}"
    );
    assert!(!child.contains("NWYN_SCRUBBED_CONTROL"), "{child}");
}
