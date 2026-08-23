// @trace spec:user-runtime-lifecycle, spec:linux-native-portable-executable, spec:init-command
use std::fs;
use std::io::Write;
#[cfg(unix)]
use std::os::unix::fs::PermissionsExt;
use std::path::{Path, PathBuf};

#[derive(Debug, Clone, Eq, PartialEq)]
struct Asset {
    source: PathBuf,
    dest: String,
}

fn main() {
    let manifest_dir = PathBuf::from(std::env::var("CARGO_MANIFEST_DIR").unwrap());
    let repo_root = manifest_dir
        .parent()
        .and_then(Path::parent)
        .expect("crate lives under repo_root/crates/tillandsias-headless");
    let out_dir = PathBuf::from(std::env::var("OUT_DIR").unwrap());
    let generated = out_dir.join("runtime_assets_generated.rs");

    // ── Order 852-dk9z: a probe-code fingerprint the capability cache keys on ──
    //
    // load_or_probe used to invalidate only on parse failure, schema_version, or
    // legacy_tier. None of those move when enumeration LOGIC changes, so a
    // rebuilt binary served its predecessor's document verbatim and the row
    // generator wrapped it into a "fresh" probe. Measured twice: yoga after
    // 850-bif2's AMD enumeration landed, and pirria after 856-fwyh's Intel
    // disposition landed — both published the pre-fix document.
    //
    // Hashing the SOURCE means no human has to remember to bump anything: any
    // edit to the probe changes the identity, which is exactly the property a
    // hand-maintained revision constant fails to provide.
    let probe_src = manifest_dir.join("src").join("accel_probe.rs");
    println!("cargo:rerun-if-changed={}", probe_src.display());
    let probe_bytes =
        fs::read(&probe_src).unwrap_or_else(|e| panic!("read {}: {e}", probe_src.display()));
    let mut probe_hash: u64 = 0xcbf2_9ce4_8422_2325;
    for b in &probe_bytes {
        probe_hash ^= *b as u64;
        probe_hash = probe_hash.wrapping_mul(0x0000_0100_0000_01b3);
    }
    println!("cargo:rustc-env=TILLANDSIAS_PROBE_REVISION={probe_hash:016x}");

    let mut assets = Vec::new();
    collect_assets(
        &repo_root.join("images"),
        &repo_root.join("images"),
        repo_root,
        "",
        &mut assets,
    );
    collect_assets(
        &repo_root.join("observatorium"),
        &repo_root.join("observatorium"),
        repo_root,
        "",
        &mut assets,
    );
    collect_assets(
        &repo_root.join("skills"),
        &repo_root.join("skills"),
        repo_root,
        "images/default/skills",
        &mut assets,
    );

    for rel in ["scripts/manage-cache.sh", "scripts/run-observatorium.sh"] {
        let path = repo_root.join(rel);
        if path.is_file() {
            assets.push(Asset {
                source: path.clone(),
                dest: rel.to_string(),
            });
        } else {
            panic!("required runtime asset missing: {}", path.display());
        }
    }

    assets.sort_by(|a, b| a.dest.cmp(&b.dest));

    for asset in &assets {
        println!("cargo:rerun-if-changed={}", asset.source.display());
    }
    println!(
        "cargo:rerun-if-changed={}",
        repo_root.join("images").display()
    );
    println!(
        "cargo:rerun-if-changed={}",
        repo_root.join("observatorium").display()
    );
    println!(
        "cargo:rerun-if-changed={}",
        repo_root.join("skills").display()
    );
    println!(
        "cargo:rerun-if-changed={}",
        repo_root.join("scripts/manage-cache.sh").display()
    );
    println!(
        "cargo:rerun-if-changed={}",
        repo_root.join("scripts/run-observatorium.sh").display()
    );

    let required = [
        "images/default/Containerfile.base",
        "images/default/Containerfile",
        "images/proxy/Containerfile",
        "images/proxy/allowlist.txt",
        "images/git/Containerfile",
        "images/inference/Containerfile",
        "images/router/Containerfile",
        "images/router/base.Caddyfile",
        "images/router/tillandsias-router-sidecar",
        "images/chromium/Containerfile.core",
        "images/chromium/Containerfile.framework",
        "images/web/Containerfile",
        "observatorium/index.html",
        "scripts/manage-cache.sh",
        "scripts/run-observatorium.sh",
        "skills/advance-work-from-plan/SKILL.md",
    ];
    for rel in required {
        if !repo_root.join(rel).is_file() {
            // Every other entry in `required` is a tracked file: if it is gone,
            // the checkout is broken and the path alone says so. The router
            // sidecar is the one BUILD ARTIFACT in the list (order 710-w9kc
            // un-committed it), so its absence is the normal state of a fresh
            // clone and means "a build step has not run yet", not "your tree is
            // corrupt". Naming the remedy here is what separates those two.
            //
            // This message is the whole reason the gap survived: three
            // entrypoints compiled this crate without staging the sidecar
            // first, and each failed with a bare path to a file the reader had
            // never heard of and could not restore from git (723-wd8i).
            if rel == "images/router/tillandsias-router-sidecar" {
                panic!(
                    "required runtime asset missing: {}\n\
                     \n\
                     This is a BUILD ARTIFACT, not a tracked file — it is built \
                     from crates/tillandsias-router-sidecar, never committed \
                     (order 710-w9kc). A fresh clone will not have it.\n\
                     \n\
                     Produce it, then rebuild:\n    \
                     bash scripts/build-sidecar.sh\n\
                     \n\
                     If you hit this from a build script, that script is missing \
                     the staging call that build.sh and scripts/build-image.sh \
                     already make.",
                    repo_root.join(rel).display()
                );
            }
            panic!(
                "required runtime asset missing: {}",
                repo_root.join(rel).display()
            );
        }
    }

    let mut file = fs::File::create(&generated).unwrap();
    writeln!(file, "// Auto-generated by build.rs; do not edit.").unwrap();
    writeln!(file).unwrap();
    writeln!(
        file,
        "pub const EMBEDDED_RUNTIME_ASSETS: &[EmbeddedRuntimeAsset] = &["
    )
    .unwrap();

    for asset in assets {
        let abs = asset.source.to_string_lossy();
        let executable = is_executable(&asset.source);
        writeln!(
            file,
            "    EmbeddedRuntimeAsset {{ path: {:?}, bytes: include_bytes!({:?}), executable: {} }},",
            asset.dest, abs, executable
        )
        .unwrap();
    }

    writeln!(file, "];").unwrap();
}

fn collect_assets(
    dir: &Path,
    collection_root: &Path,
    repo_root: &Path,
    dest_prefix: &str,
    out: &mut Vec<Asset>,
) {
    if !dir.is_dir() {
        panic!(
            "required runtime asset directory missing: {}",
            dir.display()
        );
    }

    let mut entries = fs::read_dir(dir)
        .unwrap_or_else(|e| panic!("read_dir {}: {e}", dir.display()))
        .map(|entry| entry.unwrap().path())
        .collect::<Vec<_>>();
    entries.sort();

    for path in entries {
        let meta = fs::symlink_metadata(&path)
            .unwrap_or_else(|e| panic!("metadata {}: {e}", path.display()));
        if meta.file_type().is_symlink() {
            panic!(
                "runtime assets must not contain symlinks: {}",
                path.display()
            );
        }

        let rel_repo = path
            .strip_prefix(repo_root)
            .expect("asset under repo root")
            .to_string_lossy()
            .replace('\\', "/");

        // Skip images/default/skills if we are collecting the images/ directory recursively.
        if dest_prefix.is_empty() && rel_repo.starts_with("images/default/skills") {
            continue;
        }

        if meta.is_dir() {
            collect_assets(&path, collection_root, repo_root, dest_prefix, out);
        } else if meta.is_file() {
            let dest = if !dest_prefix.is_empty() {
                let sub_rel = path
                    .strip_prefix(collection_root)
                    .expect("sub-asset under collection root")
                    .to_string_lossy()
                    .replace('\\', "/");
                format!("{dest_prefix}/{sub_rel}")
            } else {
                rel_repo.clone()
            };

            out.push(Asset { source: path, dest });
        }
    }
}

fn is_executable(path: &Path) -> bool {
    #[cfg(unix)]
    {
        fs::metadata(path)
            .map(|m| m.permissions().mode() & 0o111 != 0)
            .unwrap_or(false)
    }
    #[cfg(not(unix))]
    {
        let _ = path;
        false
    }
}
