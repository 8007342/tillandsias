// @trace order:811-j9fc
//
// LIVE ARM, on a deliberately unsigned build: a `cargo test` binary on macOS
// is linker-signed with NO entitlements, which is exactly the plain
// `cargo build` tray that cannot start a VM. Pre-fix, start() first grew the
// guest disk, regenerated cidata.iso and created a swap image in the image
// root, and only then failed inside VZ's validate with a message that named an
// Apple API rather than the project's signed build. The refusal must come
// first, by name, with why and remedy, and the image root must be untouched.
#![cfg(target_os = "macos")]

use std::collections::BTreeMap;
use std::path::Path;
use tillandsias_vm_layer::VmRuntime;
use tillandsias_vm_layer::vz::VzRuntime;

fn listing(root: &Path) -> BTreeMap<String, u64> {
    std::fs::read_dir(root)
        .expect("read scratch image root")
        .map(|e| {
            let e = e.expect("dir entry");
            let len = e.metadata().map(|m| m.len()).unwrap_or(u64::MAX);
            (e.file_name().to_string_lossy().into_owned(), len)
        })
        .collect()
}

/// An INDEPENDENT reading of this test binary's entitlements, via codesign, so
/// the test does not trust the probe it is testing.
fn test_binary_has_virtualization_entitlement() -> bool {
    let exe = std::env::current_exe().expect("current exe");
    let out = std::process::Command::new("codesign")
        .args(["-d", "--entitlements", "-", "--xml"])
        .arg(&exe)
        .output()
        .expect("run codesign");
    String::from_utf8_lossy(&out.stdout).contains("com.apple.security.virtualization")
}

#[tokio::test]
async fn an_unentitled_binary_is_refused_by_name_before_touching_the_image_root() {
    if test_binary_has_virtualization_entitlement() {
        eprintln!("skip:vz-entitlement-preflight:test-binary-is-entitled");
        return;
    }
    let dir = tempfile::tempdir().expect("scratch image root");
    std::fs::write(dir.path().join("rootfs.img"), vec![0u8; 1 << 20]).expect("scratch rootfs");
    let before = listing(dir.path());

    let rt = VzRuntime::new(3, dir.path().to_path_buf());
    let err = rt
        .start()
        .await
        .expect_err("an unentitled binary must not start a VM");

    assert!(
        err.starts_with("refused:vm-start:missing-virtualization-entitlement"),
        "the refusal must be named, not a generic VZ error; got: {err}"
    );
    assert!(
        err.contains("why:") && err.contains("remedy:"),
        "why and remedy are required; got: {err}"
    );
    assert!(
        err.contains("scripts/build-macos-tray.sh") && err.contains("dist/Tillandsias.app"),
        "the remedy must name the signed build and bundle; got: {err}"
    );
    assert_eq!(
        listing(dir.path()),
        before,
        "the refused start must not touch the image root"
    );
}
