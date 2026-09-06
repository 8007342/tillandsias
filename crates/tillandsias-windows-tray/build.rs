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

    // ORDER 776-g6r3 — MSIX logo assets.
    //
    // The Store manifest needs Square44x44Logo, Square150x150Logo and
    // StoreLogo as PNGs. They are RENDERED, not checked in, for the reason
    // every generated asset in this tree is: a committed PNG silently stops
    // matching the SVG it came from, and nothing goes red when it does.
    //
    // Written to `<target>/msix-logos/` rather than OUT_DIR alone, because the
    // consumer is scripts/build-windows-tray.ps1 — a PowerShell packaging step
    // that cannot discover OUT_DIR's hashed path. Deriving the target dir by
    // walking up from OUT_DIR keeps it correct under CARGO_TARGET_DIR
    // overrides, which this fleet uses on the WSL2 lane.
    //
    // Best-effort by design, matching the .ico policy above: a missing SVG must
    // not break `cargo check` on a Linux host that will never package an MSIX.
    // The packaging step is where absence becomes an error, because that is
    // where it actually matters — see package-msix in build-windows-tray.ps1.
    render_msix_logos(&manifest_dir_path);

    // Generate dummy headless binaries if they do not exist so include_bytes! compiles.
    //
    // ORDER 1059-ry6t: THE PLACEHOLDER STAYS, THE SILENCE DOES NOT. Writing an
    // empty file here is the same accommodation render_msix_logos documents
    // above -- a missing asset must not break `cargo check` on a host that will
    // never package -- and that policy already names where absence becomes an
    // error: "the packaging step ... because that is where it actually
    // matters". This asset never got the second half.
    //
    // WHAT THAT COST, measured 2026-09-05: the asset was 0 bytes on
    // esmeraldinha since 2026-08-23 and 0 bytes on yolanda since 2026-08-22 --
    // two of two Windows hosts checked, because build.rs CREATES the
    // placeholder on first build and nothing ever replaces it. So the default
    // state of a Windows dev checkout is a tray that compiles, links, prints
    // `Built:` and exits 0, and whose guest injection is a silent no-op. A tray
    // built that way does not fail at build; it fails later, in a guest that
    // behaves like an older release for no visible reason.
    //
    // The warning fires on the ZERO-BYTE CONDITION rather than only on
    // creation, because the file persists: a host that generated the
    // placeholder in August would otherwise never be told again.
    let assets_dir = manifest_dir_path.join("assets");
    let _ = std::fs::create_dir_all(&assets_dir);
    for arch in ["x86_64", "aarch64"] {
        let bin = assets_dir.join(format!("tillandsias-headless-{arch}-unknown-linux-musl"));
        if !bin.exists() {
            let _ = std::fs::write(&bin, b"");
        }
        let is_placeholder = std::fs::metadata(&bin)
            .map(|m| m.len() == 0)
            .unwrap_or(true);
        if is_placeholder {
            println!(
                "cargo:warning=tillandsias-windows-tray: {} is 0 bytes (placeholder). \
                 This build embeds an EMPTY guest binary, so guest injection will be a \
                 SILENT NO-OP at runtime. Stage the real musl headless before packaging \
                 -- scripts/build-windows-tray.ps1 refuses on this condition (1059-ry6t).",
                bin.display()
            );
        }
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

    // The staged guest binaries are pulled in with `include_bytes!` from
    // assets/, and cargo did NOT rebuild when only those files changed.
    // Measured 2026-08-15: after restaging the x86_64 guest binary, the asset
    // on disk contained 0.4.260815.1 while the compiled test still asserted
    // against the previous embed and failed; touching a .rs file fixed it.
    //
    // The failure direction is the dangerous one. A developer restages a guest
    // binary, rebuilds, and ships a tray carrying the PREVIOUS one — and
    // embedded_guest_headless_matches_workspace_version cannot catch it,
    // because the stale build is exactly the build that does not recompile the
    // test either. Declaring the dependency is the fix; the test is the
    // backstop, not the guard.
    for arch in ["x86_64", "aarch64"] {
        println!("cargo:rerun-if-changed=assets/tillandsias-headless-{arch}-unknown-linux-musl");
    }

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
    // 765-evbt: when BUILD_COMMIT_SHA_OVERRIDE is set, suppress .git rerun
    // directives — the SHA is fixed by the caller and git activity must not
    // bust the fingerprint. The env-changed directive is placed first so
    // cargo tracks the override for the re-run decision.
    println!("cargo:rerun-if-env-changed=BUILD_COMMIT_SHA_OVERRIDE");
    let override_mode = std::env::var("BUILD_COMMIT_SHA_OVERRIDE").is_ok();
    if !override_mode {
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
    }
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

/// Render the three MSIX logo sizes from the xerographica bloom SVG.
///
/// ORDER 776-g6r3. Sizes are the Store's required set for a desktop package:
/// 44x44 (taskbar/app list), 150x150 (medium tile), 50x50 (StoreLogo, used in
/// the listing and in the installer dialog).
fn render_msix_logos(manifest_dir: &std::path::Path) {
    let svg = manifest_dir.join("../../assets/icons/xerographica/bloom.svg");
    println!("cargo:rerun-if-changed=../../assets/icons/xerographica/bloom.svg");
    if !svg.exists() {
        return;
    }
    let Ok(out_dir) = std::env::var("OUT_DIR") else {
        return;
    };
    // OUT_DIR is <target>/<profile>/build/<pkg>-<hash>/out — four levels down.
    let mut target_root = std::path::PathBuf::from(&out_dir);
    for _ in 0..4 {
        if !target_root.pop() {
            return;
        }
    }
    let logo_dir = target_root.join("msix-logos");
    if std::fs::create_dir_all(&logo_dir).is_err() {
        return;
    }
    for (name, size) in [
        ("Square44x44Logo.png", 44u32),
        ("Square150x150Logo.png", 150),
        ("StoreLogo.png", 50),
    ] {
        let _ = render_one_logo(&svg, &logo_dir.join(name), size);
    }
}

/// Returns Err rather than panicking: see the best-effort note at the call site.
fn render_one_logo(
    svg_path: &std::path::Path,
    png_path: &std::path::Path,
    size: u32,
) -> Result<(), String> {
    let svg_data = std::fs::read(svg_path).map_err(|e| e.to_string())?;
    let tree = resvg::usvg::Tree::from_data(&svg_data, &resvg::usvg::Options::default())
        .map_err(|e| e.to_string())?;
    let mut pixmap = tiny_skia::Pixmap::new(size, size).ok_or("pixmap")?;
    let svg_size = tree.size();
    // Uniform scale + centre, NOT the per-axis stretch the tray-icon renderer
    // uses. Store logos are square and the source is not necessarily; stretching
    // a bloom to fill 44x44 is visibly wrong in the taskbar, where this asset is
    // seen most.
    let scale = (size as f32 / svg_size.width()).min(size as f32 / svg_size.height());
    let tx = (size as f32 - svg_size.width() * scale) / 2.0;
    let ty = (size as f32 - svg_size.height() * scale) / 2.0;
    let transform = tiny_skia::Transform::from_translate(tx, ty).pre_scale(scale, scale);
    resvg::render(&tree, transform, &mut pixmap.as_mut());
    let png = pixmap.encode_png().map_err(|e| e.to_string())?;
    std::fs::write(png_path, &png).map_err(|e| e.to_string())
}
