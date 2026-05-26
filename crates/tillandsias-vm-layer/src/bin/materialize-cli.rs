//! `materialize-cli` — drive the recipe materializer end-to-end from the
//! command line so a developer (or CI's `recipe-smoke` job §6.4) can
//! produce a real rootfs `.tar` from `images/vm/Recipefile` +
//! `images/vm/manifest.toml`.
//!
//! Task §8.2 of `openspec/changes/vm-recipe-provisioning/tasks.md`:
//!
//! ```bash
//! cargo run -p tillandsias-vm-layer --features materialize --bin materialize-cli -- \
//!   images/vm/Recipefile images/vm/manifest.toml x86_64
//! ```
//!
//! Prints the final rootfs tar path + its SHA-256 to stdout. Use the
//! SHA to populate `images/vm/manifest.toml` `[output] expected_rootfs_sha`
//! per Task §6.5.
//!
//! Requires `buildah` on PATH (Linux host) and ~5 GB free disk for the
//! cache. On rootless Fedora / Ubuntu it works out of the box.
//!
//! @trace spec:vm-provisioning-lifecycle (§8.2)

use std::path::PathBuf;
use std::process::ExitCode;

use sha2::{Digest, Sha256};
use tillandsias_vm_layer::materialize::{BuildahExec, HostArch, MaterializedRootfs, Materializer};
use tillandsias_vm_layer::recipe::{Manifest, Recipe};

const USAGE: &str = r#"USAGE:
  materialize-cli <RECIPE> <MANIFEST> <ARCH> [--cache-root <DIR>] [--buildah <PATH>]

ARGS:
  RECIPE          Path to images/vm/Recipefile (or any Containerfile-shape file).
  MANIFEST        Path to images/vm/manifest.toml.
  ARCH            x86_64 or aarch64.

OPTIONS:
  --cache-root    Cache directory; default: $XDG_CACHE_HOME/tillandsias/recipe-cache
                  or ~/.cache/tillandsias/recipe-cache.
  --buildah       Path to the buildah binary; default: buildah (PATH lookup).

OUTPUT:
  Prints two lines on success:
    rootfs_tar=<path>
    sha256=<hex>
  Exits 1 with a single error line on failure.
"#;

fn main() -> ExitCode {
    match run() {
        Ok(()) => ExitCode::SUCCESS,
        Err(err) => {
            eprintln!("materialize-cli: {err}");
            ExitCode::FAILURE
        }
    }
}

fn run() -> Result<(), String> {
    let args: Args = parse_args(std::env::args().skip(1))?;

    let recipe = Recipe::parse(&args.recipe)
        .map_err(|e| format!("parse recipe {}: {e}", args.recipe.display()))?;
    let manifest = Manifest::load(&args.manifest)
        .map_err(|e| format!("parse manifest {}: {e}", args.manifest.display()))?;

    let executor = if let Some(path) = args.buildah {
        BuildahExec::default().with_binary(path)
    } else {
        BuildahExec::default()
    };

    let mat = Materializer::new(executor, args.cache_root.clone());
    let result = mat
        .run(&recipe, &manifest, args.arch)
        .map_err(|e| format!("materialize: {e}"))?;
    let tar_path = match result {
        MaterializedRootfs::Tar(p) => p,
    };

    let sha =
        sha256_file(&tar_path).map_err(|e| format!("sha256 of {}: {e}", tar_path.display()))?;

    println!("rootfs_tar={}", tar_path.display());
    println!("sha256={sha}");
    Ok(())
}

struct Args {
    recipe: PathBuf,
    manifest: PathBuf,
    arch: HostArch,
    cache_root: PathBuf,
    buildah: Option<PathBuf>,
}

fn parse_args<I: Iterator<Item = String>>(mut iter: I) -> Result<Args, String> {
    let mut positional: Vec<String> = Vec::new();
    let mut cache_root: Option<PathBuf> = None;
    let mut buildah: Option<PathBuf> = None;

    while let Some(arg) = iter.next() {
        match arg.as_str() {
            "-h" | "--help" => {
                print!("{USAGE}");
                std::process::exit(0);
            }
            "--cache-root" => {
                let v = iter.next().ok_or("--cache-root needs a value")?;
                cache_root = Some(PathBuf::from(v));
            }
            "--buildah" => {
                let v = iter.next().ok_or("--buildah needs a value")?;
                buildah = Some(PathBuf::from(v));
            }
            _ if arg.starts_with("--") => {
                return Err(format!("unknown flag: {arg}"));
            }
            _ => positional.push(arg),
        }
    }

    if positional.len() != 3 {
        return Err(format!(
            "expected 3 positional args (RECIPE MANIFEST ARCH), got {}\n\n{USAGE}",
            positional.len()
        ));
    }
    let recipe = PathBuf::from(&positional[0]);
    let manifest = PathBuf::from(&positional[1]);
    let arch = match positional[2].as_str() {
        "x86_64" => HostArch::X86_64,
        "aarch64" => HostArch::Aarch64,
        other => {
            return Err(format!(
                "unknown ARCH {other:?}; expected x86_64 or aarch64"
            ));
        }
    };
    let cache_root = cache_root.unwrap_or_else(default_cache_root);

    Ok(Args {
        recipe,
        manifest,
        arch,
        cache_root,
        buildah,
    })
}

fn default_cache_root() -> PathBuf {
    if let Ok(xdg) = std::env::var("XDG_CACHE_HOME") {
        if !xdg.is_empty() {
            return PathBuf::from(xdg).join("tillandsias").join("recipe-cache");
        }
    }
    let home = std::env::var("HOME").unwrap_or_else(|_| ".".into());
    PathBuf::from(home)
        .join(".cache")
        .join("tillandsias")
        .join("recipe-cache")
}

fn sha256_file(path: &std::path::Path) -> std::io::Result<String> {
    use std::io::Read;
    let mut file = std::fs::File::open(path)?;
    let mut hasher = Sha256::new();
    let mut buf = vec![0u8; 64 * 1024];
    loop {
        let n = file.read(&mut buf)?;
        if n == 0 {
            break;
        }
        hasher.update(&buf[..n]);
    }
    Ok(hex_encode(&hasher.finalize()))
}

fn hex_encode(bytes: &[u8]) -> String {
    const HEX: &[u8; 16] = b"0123456789abcdef";
    let mut out = String::with_capacity(bytes.len() * 2);
    for &b in bytes {
        out.push(HEX[(b >> 4) as usize] as char);
        out.push(HEX[(b & 0x0f) as usize] as char);
    }
    out
}
