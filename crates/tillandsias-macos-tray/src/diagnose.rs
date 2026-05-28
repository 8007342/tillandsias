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

/// Output format selected via `--diagnose` (default) or
/// `--diagnose --json`. Mirrors windows-tray's `DiagnoseFormat`
/// (commit c4908438).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum DiagnoseFormat {
    Human,
    Json,
}

/// Bundled diagnostic-report payload. Both human and JSON formatters
/// emit exactly these fields, so support tooling that parses the JSON
/// gets the same data the user sees in the terminal. Mirrors windows-
/// tray's `DiagnoseReport` (commit c4908438) — field names match
/// byte-for-byte where the concept exists on both hosts; macOS-only
/// fields and windows-only fields differ.
#[derive(serde::Serialize)]
pub struct DiagnoseReport {
    pub version: &'static str,
    pub in_app: bool,
    pub exe_path: Option<String>,
    pub image_root: String,
    pub rootfs_present: bool,
    pub rootfs_bytes: Option<u64>,
    pub kernel_present: bool,
    pub kernel_bytes: Option<u64>,
    pub initrd_present: bool,
    pub initrd_bytes: Option<u64>,
    pub release_tag: &'static str,
    pub manifest_pin_aarch64_img: Option<String>,
    pub provisioned: bool,
}

/// Entry point invoked from `main` when `--diagnose` is on argv.
/// Returns the exit code to bubble up via `std::process::exit`.
pub fn main(format: DiagnoseFormat) -> i32 {
    let report = collect_report();
    match format {
        DiagnoseFormat::Human => print_human(&report),
        DiagnoseFormat::Json => print_json(&report),
    }
    exit_code_from(&report)
}

fn collect_report() -> DiagnoseReport {
    let exe = std::env::current_exe().ok();
    let in_app = exe
        .as_ref()
        .and_then(|p| p.to_str())
        .map(|s| s.contains("/Tillandsias.app/"))
        .unwrap_or(false);
    let exe_path = exe.as_ref().map(|p| p.display().to_string());

    let root = image_root();
    let image_root_str = root.display().to_string();
    let (rootfs_present, rootfs_bytes) = stat_file(&root.join("rootfs.img"));
    let (kernel_present, kernel_bytes) = stat_file(&root.join("vmlinuz"));
    let (initrd_present, initrd_bytes) = stat_file(&root.join("initramfs.img"));
    let provisioned = rootfs_present && kernel_present && initrd_present;

    const BUNDLED_MANIFEST_TOML: &str = include_str!("../../../images/vm/manifest.toml");
    let manifest_pin_aarch64_img = parse_aarch64_img_sha(BUNDLED_MANIFEST_TOML);

    DiagnoseReport {
        version: env!("CARGO_PKG_VERSION"),
        in_app,
        exe_path,
        image_root: image_root_str,
        rootfs_present,
        rootfs_bytes,
        kernel_present,
        kernel_bytes,
        initrd_present,
        initrd_bytes,
        release_tag: crate::action_host::RECIPE_RELEASE_TAG,
        manifest_pin_aarch64_img,
        provisioned,
    }
}

fn stat_file(path: &std::path::Path) -> (bool, Option<u64>) {
    match std::fs::metadata(path) {
        Ok(md) => (true, Some(md.len())),
        Err(_) => (false, None),
    }
}

fn print_human(r: &DiagnoseReport) {
    println!("Tillandsias.app diagnostic report");
    println!("================================");
    println!();
    println!("Version:    {}", r.version);
    println!(
        "Bundle:     {}",
        if r.in_app {
            "inside Tillandsias.app (codesigned ad-hoc at build)"
        } else {
            "running outside .app (development binary)"
        }
    );
    if let Some(ref exe_path) = r.exe_path {
        println!("Exe:        {exe_path}");
    }
    println!("Image-root: {}", r.image_root);
    print_artifact("  rootfs.img", r.rootfs_present, r.rootfs_bytes);
    print_artifact("  vmlinuz", r.kernel_present, r.kernel_bytes);
    print_artifact("  initramfs.img", r.initrd_present, r.initrd_bytes);
    println!("Release:    {}", r.release_tag);
    println!("Manifest:   bundled at build (compile-time include_str!)");
    match &r.manifest_pin_aarch64_img {
        Some(sha) => println!("  aarch64.img SHA-256 pin: {sha}\u{2026}"),
        None => println!("  aarch64.img SHA-256 pin: (not found / parse skipped)"),
    }
    println!();
    println!("Control wire status:");
    println!("  (live VM phase + podman_ready are only reachable from");
    println!("   the running tray process itself — macOS vsock is per-");
    println!("   VM-handle, no AF_VSOCK. Click the menubar icon for");
    println!("   the live chip; the 30 s poller refreshes it in place.)");
    println!();
    if r.provisioned {
        println!("Status: PROVISIONED — first-launch materialization complete.");
    } else {
        println!(
            "Status: NOT PROVISIONED — launch the tray once (or `open \
             /Applications/Tillandsias.app`) to fetch rootfs.img on \
             first launch."
        );
    }
}

fn print_artifact(label: &str, present: bool, bytes: Option<u64>) {
    if present {
        println!("{label:<16}  present, {} bytes", bytes.unwrap_or(0));
    } else {
        println!("{label:<16}  MISSING");
    }
}

fn print_json(r: &DiagnoseReport) {
    match serde_json::to_string_pretty(r) {
        Ok(s) => println!("{s}"),
        Err(e) => {
            // Best-effort: emit a single-line fallback object so the
            // tool consuming the output isn't stuck parsing empty stdout.
            eprintln!("[tillandsias-tray] --diagnose --json serialize failed: {e}");
            println!("{{\"error\":\"serialize failed: {e}\"}}");
        }
    }
}

fn exit_code_from(r: &DiagnoseReport) -> i32 {
    if r.provisioned { 0 } else { 2 }
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

    // ────────────────────────────────────────────────────────────────
    //  JSON schema-pin tests (mirrors windows-tray e96d1fc8)
    //
    //  The --diagnose --json schema is a public surface that
    //  scripts/tray-diagnose.sh (and any future support tooling
    //  uploading the JSON) parse field-by-field. Renames or removes
    //  here must break the build, not silently break the consumer.
    // ────────────────────────────────────────────────────────────────

    use super::{DiagnoseReport, exit_code_from};

    fn baseline_diagnose_report() -> DiagnoseReport {
        DiagnoseReport {
            version: "0.1.0",
            in_app: true,
            exe_path: Some(
                "/Applications/Tillandsias.app/Contents/MacOS/tillandsias-tray".to_string(),
            ),
            image_root: "/Users/test/Library/Application Support/tillandsias".to_string(),
            rootfs_present: true,
            rootfs_bytes: Some(8_589_934_592),
            kernel_present: true,
            kernel_bytes: Some(11_534_336),
            initrd_present: true,
            initrd_bytes: Some(67_108_864),
            release_tag: "v0.2.260526.1",
            manifest_pin_aarch64_img: Some("6859a7bcc4a9".to_string()),
            provisioned: true,
        }
    }

    /// Top-level JSON keys are the support-tooling contract.
    /// `tray-diagnose.sh` reads `.version`, `.in_app`, `.release_tag`,
    /// `.manifest_pin_aarch64_img`, `.provisioned`, and the per-
    /// artifact `_present` flags by name. A silent rename of any of
    /// these would degrade the consumer to "FAIL : null".
    #[test]
    fn diagnose_report_json_keys_locked() {
        let report = baseline_diagnose_report();
        let value: serde_json::Value = serde_json::to_value(&report).unwrap();
        let obj = value
            .as_object()
            .expect("DiagnoseReport must serialise as a JSON object");
        for required_key in [
            "version",
            "in_app",
            "exe_path",
            "image_root",
            "rootfs_present",
            "rootfs_bytes",
            "kernel_present",
            "kernel_bytes",
            "initrd_present",
            "initrd_bytes",
            "release_tag",
            "manifest_pin_aarch64_img",
            "provisioned",
        ] {
            assert!(
                obj.contains_key(required_key),
                "DiagnoseReport JSON missing required key {required_key:?}; check serde rename"
            );
        }
    }

    /// `manifest_pin_aarch64_img: None` must serialise as JSON null,
    /// not the literal string "null" or the absent key. Consumer
    /// path: `tray-diagnose.sh` reads `.manifest_pin_aarch64_img //
    /// "(none)"` — `//` only triggers on null/missing, so a string
    /// "null" would silently render as PASS with bogus pin.
    #[test]
    fn diagnose_report_none_pin_serialises_as_null() {
        let mut report = baseline_diagnose_report();
        report.manifest_pin_aarch64_img = None;
        let value: serde_json::Value = serde_json::to_value(&report).unwrap();
        assert_eq!(value["manifest_pin_aarch64_img"], serde_json::Value::Null);
    }

    /// `bytes` fields are `Option<u64>`; missing artifacts MUST
    /// serialise as JSON null. `tray-diagnose.sh` doesn't currently
    /// read the bytes, but a future dashboard expects null for
    /// "absent" so it can render "—" instead of "0".
    #[test]
    fn diagnose_report_none_bytes_serialise_as_null() {
        let mut report = baseline_diagnose_report();
        report.kernel_present = false;
        report.kernel_bytes = None;
        report.initrd_present = false;
        report.initrd_bytes = None;
        let value: serde_json::Value = serde_json::to_value(&report).unwrap();
        assert_eq!(value["kernel_bytes"], serde_json::Value::Null);
        assert_eq!(value["initrd_bytes"], serde_json::Value::Null);
    }

    /// `exit_code_from` is the public contract `tray-diagnose.sh`
    /// (and `--diagnose --json`'s own `main`) rely on for the
    /// 0/2/1 exit contract. Pin the mapping so accidental flips
    /// (e.g. returning the wrong code for provisioned=true) break
    /// the build.
    #[test]
    fn exit_code_provisioned_zero_degraded_two() {
        let mut report = baseline_diagnose_report();
        assert_eq!(exit_code_from(&report), 0);
        report.provisioned = false;
        assert_eq!(exit_code_from(&report), 2);
    }
}
