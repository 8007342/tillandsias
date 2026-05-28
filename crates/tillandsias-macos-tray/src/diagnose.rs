//! `tillandsias-tray --diagnose` — installed-tray support diagnostic.
//!
//! Mirrors `tillandsias-windows-tray::notify_icon::diagnose` (commit
//! `20fb9d1f`) in spirit — a one-shot CLI flag that prints a bundled
//! health report and exits without launching AppKit. Designed to be
//! invoked from the terminal during user-attended smoke sessions:
//!
//! ```bash
//! /Applications/Tillandsias.app/Contents/MacOS/tillandsias-tray --diagnose
//! ```
//!
//! **macOS-specific limitation vs. windows-tray**: Apple's
//! `Virtualization.framework` vsock is per-VM-handle, not per-host
//! (macOS has no `AF_VSOCK`). A standalone `--diagnose` process
//! therefore cannot reach a separately-running tray's VM control
//! wire — it would need to be the same process that started the VM
//! to hold the `VZVirtioSocketDevice` handle. So unlike windows, the
//! macOS report covers static/filesystem health only:
//!
//!   * version (`CARGO_PKG_VERSION` baked at build)
//!   * bundle identity (whether the binary lives inside an `.app`)
//!   * image-root artifacts (rootfs.img / vmlinuz / initramfs.img)
//!   * manifest pin source (bundled, first 12 chars of SHA)
//!
//! Live wire status comes from clicking the menubar icon (which the
//! 30 s `spawn_vm_status_poller` already drives into the chip text).
//! A future `--attach-existing-tray` would need a host-side Unix
//! socket forwarder; that's a v0.0.2 enhancement.
//!
//! Exit codes mirror windows' shape:
//!   * `0` — image-root provisioned, bundle valid
//!   * `2` — degraded (image-root not provisioned yet — run the
//!     tray once to materialize)
//!   * `1` — hard failure (only used if even the static checks
//!     cannot complete)
//!
//! macOS-only. The non-macOS branch of the crate never compiles this
//! module.
//!
//! @trace spec:macos-native-tray.diagnose@v1,
//!        plan/steps/20-macos-tray-v0_0_1.md (m4 sub-task B slice 11)

#![cfg(target_os = "macos")]

use std::path::PathBuf;

/// Where the .app installer materializes VM artifacts on a macOS host.
/// Mirrors `status_item::default_image_root` so `--diagnose` reads the
/// same paths the live tray writes/reads.
fn image_root() -> PathBuf {
    let home = std::env::var_os("HOME")
        .map(PathBuf::from)
        .unwrap_or_else(|| PathBuf::from("/tmp"));
    home.join("Library/Application Support/tillandsias")
}

/// Entry point invoked from `main` when `--diagnose` is on argv.
/// Returns the exit code to bubble up via `std::process::exit`.
pub fn main() -> i32 {
    println!("Tillandsias.app diagnostic report");
    println!("================================");
    println!();

    // 1. Version
    println!("Version:    {}", env!("CARGO_PKG_VERSION"));

    // 2. Bundle identity — exe path containment is the cheapest
    //    signal we're running from a packaged .app vs. cargo build.
    let exe = std::env::current_exe().ok();
    let in_app = exe
        .as_ref()
        .and_then(|p| p.to_str())
        .map(|s| s.contains("/Tillandsias.app/"))
        .unwrap_or(false);
    println!(
        "Bundle:     {}",
        if in_app {
            "inside Tillandsias.app (codesigned ad-hoc at build)"
        } else {
            "running outside .app (development binary)"
        }
    );
    if let Some(exe_path) = exe {
        println!("Exe:        {}", exe_path.display());
    }

    // 3. Image-root artifacts. A user who reports "the tray doesn't
    //    seem to do anything" most often hasn't run a successful
    //    first-launch yet — the materializer hasn't populated these.
    let root = image_root();
    println!("Image-root: {}", root.display());
    let rootfs = root.join("rootfs.img");
    let kernel = root.join("vmlinuz");
    let initrd = root.join("initramfs.img");
    let mut provisioned = true;
    for (label, path) in [
        ("  rootfs.img", &rootfs),
        ("  vmlinuz", &kernel),
        ("  initramfs.img", &initrd),
    ] {
        match std::fs::metadata(path) {
            Ok(md) => println!("{label:<16}  present, {} bytes", md.len()),
            Err(_) => {
                println!("{label:<16}  MISSING");
                provisioned = false;
            }
        }
    }

    // 4. Release tag (compile-time bundled) — the GitHub release
    //    the .app will fetch the rootfs.img.xz from on first launch.
    //    Surfaced separately from the manifest pin so the operator
    //    can spot tag/SHA mismatches at a glance. Matches windows-
    //    tray's --diagnose layout (commit 4fff31af).
    println!("Release:    {}", crate::action_host::RECIPE_RELEASE_TAG);

    // 5. Manifest pin (compile-time bundled) — confirms the .app
    //    knows which SHA it expects post-decompress. Useful when
    //    the user sees "SHA mismatch" errors or wonders which build
    //    of the recipe the .app pins to.
    print_manifest_pin();

    // 6. Live wire — explicitly disclaim macOS's limitation so the
    //    user knows where to look instead.
    println!();
    println!("Control wire status:");
    println!("  (live VM phase + podman_ready are only reachable from");
    println!("   the running tray process itself — macOS vsock is per-");
    println!("   VM-handle, no AF_VSOCK. Click the menubar icon for");
    println!("   the live chip; the 30 s poller refreshes it in place.)");

    println!();
    if provisioned {
        println!("Status: PROVISIONED — first-launch materialization complete.");
        0
    } else {
        println!(
            "Status: NOT PROVISIONED — launch the tray once (or `open \
             /Applications/Tillandsias.app`) to fetch rootfs.img on \
             first launch."
        );
        2
    }
}

fn print_manifest_pin() {
    const BUNDLED_MANIFEST_TOML: &str = include_str!("../../../images/vm/manifest.toml");
    println!("Manifest:   bundled at build (compile-time include_str!)");
    match parse_aarch64_img_sha(BUNDLED_MANIFEST_TOML) {
        Some(sha) => println!("  aarch64.img SHA-256 pin: {sha}…"),
        None => println!("  aarch64.img SHA-256 pin: (not found / parse skipped)"),
    }
}

/// Extract the first 12-char SHA-256 prefix for `aarch64.img` from a
/// manifest.toml body. Pure, testable — both the quoted-key form
/// (`"aarch64.img" = "<sha>"`, the actual file) and the bare-key
/// form (`aarch64.img = "<sha>"`) parse. Returns the 12-char prefix
/// or None if no valid pin is found.
fn parse_aarch64_img_sha(manifest_toml: &str) -> Option<String> {
    for line in manifest_toml.lines() {
        let trimmed = line.trim().trim_start_matches('"');
        if let Some(rest) = trimmed.strip_prefix("aarch64.img") {
            let rest = rest.trim_start_matches(['"', ' ', '=', '"']);
            let sha: String = rest.chars().take_while(|c| c.is_ascii_hexdigit()).collect();
            if sha.len() >= 12 {
                return Some(sha[..12].to_string());
            }
        }
    }
    None
}

#[cfg(test)]
mod tests {
    use super::parse_aarch64_img_sha;

    /// `parse_aarch64_img_sha` reads the actual manifest.toml format
    /// the recipe-publish CI emits (`"aarch64.img" = "<sha>"` inside
    /// `[output.expected_rootfs_sha]`). Asserts on a single 12-char
    /// prefix so the test isn't sensitive to the live SHA changing
    /// across CI runs.
    #[test]
    fn parses_quoted_key_sha_form() {
        let manifest = r#"
[output.expected_rootfs_sha]
"aarch64.tar" = "ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff"
"aarch64.img" = "6859a7bcc4a9d686ec3735c09bbf04aed00c08647586e2e75492fe5829730bee"
"#;
        assert_eq!(
            parse_aarch64_img_sha(manifest),
            Some("6859a7bcc4a9".to_string())
        );
    }

    /// Tolerate the bare-key form too. TOML accepts both for keys
    /// that contain only `[A-Za-z0-9_-]` plus dots, so future
    /// manifest authors might drop the quotes.
    #[test]
    fn parses_bare_key_sha_form() {
        let manifest =
            "aarch64.img = \"abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789\"";
        assert_eq!(
            parse_aarch64_img_sha(manifest),
            Some("abcdef012345".to_string())
        );
    }

    /// Placeholder SHA ("pending-ci") must NOT parse as a valid
    /// pin — `take_while(is_ascii_hexdigit)` produces "" since `p`
    /// is hex but the resulting prefix is too short. Return None so
    /// the diagnose report falls back to "(not found / parse
    /// skipped)" instead of printing garbage.
    #[test]
    fn refuses_placeholder_pending_ci() {
        let manifest = r#""aarch64.img" = "pending-ci""#;
        assert_eq!(parse_aarch64_img_sha(manifest), None);
    }
}
