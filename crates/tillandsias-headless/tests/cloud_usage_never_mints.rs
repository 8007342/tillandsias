//! ORDER 2000-camv: `tillandsias --cloud-usage`, the read the pre-push hook's
//! release preflight runs, never mints the host CA and never starts Vault.
//!
//! Caught on macuahuitl 2026-11-04 23:43:56: the CA was re-minted within
//! 0.2 s of `--cloud-usage` starting under the pre-push hook. Its Cloudflare
//! store read started Vault when podman answered "not running", and that
//! start reached `ensure_ca_bundle`, which re-minted the CA under the running
//! Vault. This runs the real binary on a scratch HOME with a podman that
//! answers "no such container" for everything, and asserts the CA directory
//! is byte-identical afterwards.
//!
//! Needs the `host-services` and `vault` features (`--cloud-usage` is not
//! compiled without them):
//! `cargo test -p tillandsias-headless --features tray --test cloud_usage_never_mints`
#![cfg(all(unix, feature = "host-services", feature = "vault"))]

use std::collections::BTreeMap;
use std::os::unix::fs::PermissionsExt;
use std::path::Path;
use std::process::Command;

fn snapshot(dir: &Path) -> BTreeMap<String, Vec<u8>> {
    let mut out = BTreeMap::new();
    for entry in std::fs::read_dir(dir).unwrap().flatten() {
        let name = entry.file_name().to_string_lossy().into_owned();
        let bytes = std::fs::read(entry.path()).unwrap_or_default();
        out.insert(name, bytes);
    }
    out
}

#[test]
fn cloud_usage_leaves_the_ca_directory_byte_identical() {
    let scratch = tempfile::tempdir().unwrap();
    let home = scratch.path().join("home");
    let run = scratch.path().join("run");
    let ca = Path::new(&tillandsias_core::ca_path::state_root_expanded(
        home.to_str().unwrap(),
    ))
    .join("ca");
    std::fs::create_dir_all(&ca).unwrap();
    std::fs::create_dir_all(&run).unwrap();
    std::fs::set_permissions(&run, std::fs::Permissions::from_mode(0o700)).unwrap();
    // A CA that ensure_ca_bundle would replace: the cert is unreadable and
    // there is no key, so any path that reaches a mint rewrites this dir.
    std::fs::write(ca.join("intermediate.crt"), b"not a certificate\n").unwrap();

    // podman: every container is absent, every other verb fails.
    let podman = scratch.path().join("podman");
    std::fs::write(
        &podman,
        "#!/bin/sh\necho 'Error: no such container' >&2\nexit 125\n",
    )
    .unwrap();
    std::fs::set_permissions(&podman, std::fs::Permissions::from_mode(0o755)).unwrap();

    let before = snapshot(&ca);
    let out = Command::new(env!("CARGO_BIN_EXE_tillandsias"))
        .arg("--cloud-usage")
        .env("HOME", &home)
        .env("XDG_RUNTIME_DIR", &run)
        .env("XDG_CACHE_HOME", home.join(".cache"))
        .env("XDG_CONFIG_HOME", home.join(".config"))
        .env("XDG_STATE_HOME", home.join(".local/state"))
        .env("TILLANDSIAS_PODMAN_BIN", &podman)
        // Never the operator's keyring or session bus.
        .env("DBUS_SESSION_BUS_ADDRESS", "unix:path=/nonexistent")
        .env_remove("TILLANDSIAS_HOST_KIND")
        .output()
        .expect("run tillandsias --cloud-usage");
    let stderr = String::from_utf8_lossy(&out.stderr);
    assert!(
        !stderr.contains("refused:cloud-usage:not-compiled"),
        "the binary under test lacks --cloud-usage: {stderr}"
    );
    assert_eq!(
        snapshot(&ca),
        before,
        "--cloud-usage changed the CA directory; stderr:\n{stderr}"
    );
    assert!(
        !stderr.contains("warn:ca-reminted"),
        "--cloud-usage re-minted the CA; stderr:\n{stderr}"
    );
}
