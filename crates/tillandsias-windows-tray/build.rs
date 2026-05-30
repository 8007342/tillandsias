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
    // Read the workspace VERSION file and expose it as WORKSPACE_VERSION so
    // `--diagnose --json` reports the release version (`0.2.260528.1`) rather
    // than the crate's static `Cargo.toml` `version = "0.1.0"`. The crate
    // versions don't get bumped per release; the repo-root VERSION file is
    // the single source of truth (the install/build scripts already quote
    // it). This is set UNCONDITIONALLY (before the windows-target gate)
    // so cross-checks from Linux also have the env var available.
    let manifest_dir_path =
        std::path::PathBuf::from(std::env::var("CARGO_MANIFEST_DIR").unwrap_or_default());
    let version_file = manifest_dir_path.join("../../VERSION");
    let workspace_version = std::fs::read_to_string(&version_file)
        .map(|s| s.trim().to_string())
        .unwrap_or_else(|_| env!("CARGO_PKG_VERSION").to_string());
    println!("cargo:rerun-if-changed=../../VERSION");
    println!("cargo:rustc-env=WORKSPACE_VERSION={workspace_version}");

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
}
