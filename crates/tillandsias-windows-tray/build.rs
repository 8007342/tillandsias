//! Build script for the Windows tray binary.
//!
//! On Windows builds (`cargo build --target x86_64-pc-windows-*`) this
//! invokes `embed-resource` to compile and link a Win32 resource script
//! that bundles:
//! - The app icon (`tillandsias.ico`)
//! - A side-by-side manifest declaring `requireAdministrator = false`
//!   and per-monitor V2 DPI awareness
//!
//! On non-Windows targets (cross-checking from the Linux dev box without
//! mingw, or building the Linux stub) the script is a no-op.
//!
//! Per the wave-25 scaffold, when the `.ico` asset is missing we still
//! return success — the linker just doesn't get a resource section, which
//! is fine for `cargo check` and for early-cycle development before
//! marketing-finalised art lands.
//!
//! @trace spec:windows-native-tray

fn main() {
    let manifest_dir_path =
        std::path::PathBuf::from(std::env::var("CARGO_MANIFEST_DIR").unwrap_or_default());

    // Generate dummy headless binaries if they do not exist so include_bytes! compiles
    let assets_dir = manifest_dir_path.join("assets");
    let _ = std::fs::create_dir_all(&assets_dir);
    let x86_bin = assets_dir.join("tillandsias-headless-x86_64-unknown-linux-musl");
    if !x86_bin.exists() {
        let _ = std::fs::write(&x86_bin, b"");
    }
    let arm_bin = assets_dir.join("tillandsias-headless-aarch64-unknown-linux-musl");
    if !arm_bin.exists() {
        let _ = std::fs::write(&arm_bin, b"");
    }

    // Read the workspace VERSION file and expose it as WORKSPACE_VERSION so
    // `--diagnose --json` reports the release version (`0.2.260528.1`) rather
    // than the crate's static `Cargo.toml` `version = "0.1.0"`. The crate
    // versions don't get bumped per release; the repo-root VERSION file is
    // the single source of truth (the install/build scripts already quote
    // it). This is set UNCONDITIONALLY (before the windows-target gate)
    // so cross-checks from Linux also have the env var available.
    let version_file = manifest_dir_path.join("../../VERSION");
    let workspace_version = std::fs::read_to_string(&version_file)
        .map(|s| s.trim().to_string())
        .unwrap_or_else(|_| env!("CARGO_PKG_VERSION").to_string());
    println!("cargo:rerun-if-changed=../../VERSION");
    println!("cargo:rustc-env=WORKSPACE_VERSION={workspace_version}");

    // Bake the short git commit SHA the binary was built from so support
    // tooling can correlate a running tray to a specific commit (operators
    // pasting `--diagnose --json` into a bug report make `build_commit`
    // ground-truth for triage). Best-effort: if git isn't on PATH or this
    // isn't a working tree (e.g. building from a source tarball), emit
    // "unknown" rather than failing the build. Set BEFORE the windows-target
    // gate for the same cross-check-from-Linux reason as WORKSPACE_VERSION.
    //
    // Re-run tracking: .git/HEAD alone is NOT enough — it only changes on a
    // branch switch/checkout (it holds `ref: refs/heads/<branch>`), while a
    // commit or merge on the SAME branch rewrites .git/refs/heads/<branch>
    // instead. Without tracking the resolved ref file, an incremental rebuild
    // keeps the previous BUILD_COMMIT_SHA and the installed binary lies about
    // its commit (observed 2026-07-09: rebuild at 8797003f still reported
    // a68c9825), which would also make the e2e freshness gate (embedded SHA
    // == HEAD) spuriously fail on a genuinely fresh binary.
    println!("cargo:rerun-if-changed=../../.git/HEAD");
    let git_dir = manifest_dir_path.join("../../.git");
    if let Ok(head) = std::fs::read_to_string(git_dir.join("HEAD"))
        && let Some(ref_path) = head.trim().strip_prefix("ref: ")
    {
        println!("cargo:rerun-if-changed=../../.git/{ref_path}");
    }
    // Refs can also live packed (git gc/pack-refs); only track the file when
    // it exists — cargo re-runs unconditionally for a tracked-but-missing path.
    if git_dir.join("packed-refs").exists() {
        println!("cargo:rerun-if-changed=../../.git/packed-refs");
    }
    println!("cargo:rerun-if-env-changed=BUILD_COMMIT_SHA_OVERRIDE");
    let build_commit = std::env::var("BUILD_COMMIT_SHA_OVERRIDE").unwrap_or_else(|_| {
        std::process::Command::new("git")
            .args(["rev-parse", "--short", "HEAD"])
            .current_dir(&manifest_dir_path)
            .output()
            .ok()
            .filter(|o| o.status.success())
            .and_then(|o| String::from_utf8(o.stdout).ok())
            .map(|s| s.trim().to_string())
            .filter(|s| !s.is_empty())
            .unwrap_or_else(|| "unknown".to_string())
    });
    println!("cargo:rustc-env=BUILD_COMMIT_SHA={build_commit}");

    // Only emit the rerun-if directives + the resource compile invocation
    // when the host is producing a Windows artifact. `cargo check` from
    // Linux against `x86_64-pc-windows-gnu` triggers this path.
    let target = std::env::var("TARGET").unwrap_or_default();
    if !target.contains("windows") {
        return;
    }

    let manifest_dir = std::env::var("CARGO_MANIFEST_DIR").unwrap_or_default();
    let resource_path = std::path::PathBuf::from(&manifest_dir)
        .join("assets")
        .join("tillandsias.rc");

    println!("cargo:rerun-if-changed=assets/tillandsias.rc");
    println!("cargo:rerun-if-changed=assets/tillandsias.ico");
    println!("cargo:rerun-if-changed=assets/tillandsias.manifest");

    if !resource_path.exists() {
        // Asset bundle not present yet — emit a friendly warning but DO
        // NOT fail the build. The wave-25 scaffold ships before final
        // art lands; cargo check stays green.
        println!(
            "cargo:warning=tillandsias-windows-tray: assets/tillandsias.rc missing, \
             skipping resource embed (placeholder icon will be used at runtime)"
        );
        return;
    }

    // Compile + link the resource script. `embed-resource::compile` returns
    // a `CompilationResult` indicating whether it linked the resources or
    // emitted a warning. We tolerate the warning case so the build still
    // succeeds when mingw's windres isn't fully wired (common on Linux
    // dev boxes cross-checking the Windows target).
    let result = embed_resource::compile(&resource_path, embed_resource::NONE);
    if let Err(err) = result.manifest_optional() {
        println!(
            "cargo:warning=tillandsias-windows-tray: embed-resource compile failed: {err} — continuing"
        );
    }

    // windows-260722-3: VERSIONINFO resource, GENERATED per build so the
    // metadata always carries the real workspace version. Task Manager /
    // Explorer Details then show the operator-dictated identity
    // "Tillandsias v<version> by Tlatoāni" instead of the bare exe name.
    // Numeric FILEVERSION fields are u16, so YYMMDD (e.g. 260722) cannot
    // ride one field: encoded as major, minor, YYMM, DD*100+N — monotonic
    // within each field. The STRING values carry the full untruncated
    // version. UTF-8 with `#pragma code_page(65001)` keeps the macron in
    // "Tlatoāni" intact under both rc.exe and windres.
    let numeric = {
        let parts: Vec<u32> = workspace_version
            .split('.')
            .filter_map(|p| p.parse().ok())
            .collect();
        match parts.as_slice() {
            [maj, min, yymmdd, n] => {
                format!(
                    "{},{},{},{}",
                    maj,
                    min,
                    yymmdd / 100,
                    (yymmdd % 100) * 100 + n
                )
            }
            _ => "0,0,0,0".to_string(),
        }
    };
    let description = format!("Tillandsias v{workspace_version} by Tlatoāni");
    let version_rc = format!(
        r#"1 VERSIONINFO
FILEVERSION {numeric}
PRODUCTVERSION {numeric}
BEGIN
  BLOCK "StringFileInfo"
  BEGIN
    BLOCK "040904B0"
    BEGIN
      VALUE "CompanyName", "Tlatoāni"
      VALUE "FileDescription", "{description}"
      VALUE "FileVersion", "{workspace_version}"
      VALUE "InternalName", "tillandsias-tray"
      VALUE "OriginalFilename", "tillandsias-tray.exe"
      VALUE "ProductName", "Tillandsias"
      VALUE "ProductVersion", "{workspace_version}"
    END
  END
  BLOCK "VarFileInfo"
  BEGIN
    VALUE "Translation", 0x0409, 0x04B0
  END
END
"#
    );
    let out_dir = std::env::var("OUT_DIR").unwrap_or_default();
    let version_rc_path = std::path::PathBuf::from(&out_dir).join("version.rc");
    // UTF-16LE with BOM: rc.exe reads it natively, preserving the macron in
    // "Tlatoāni" (the UTF-8 code_page pragma proved unreliable — the first
    // build flattened ā to a).
    let version_rc: Vec<u8> = std::iter::once(0xFEFFu16)
        .chain(version_rc.encode_utf16())
        .flat_map(|u| u.to_le_bytes())
        .collect();
    if std::fs::write(&version_rc_path, version_rc).is_ok() {
        let result = embed_resource::compile(&version_rc_path, embed_resource::NONE);
        if let Err(err) = result.manifest_optional() {
            println!(
                "cargo:warning=tillandsias-windows-tray: VERSIONINFO embed failed: {err} — continuing"
            );
        }
    }
}
