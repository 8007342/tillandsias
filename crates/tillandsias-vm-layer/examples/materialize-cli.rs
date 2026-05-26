//! materialize-cli — CI-friendly front-end for `tillandsias-vm-layer::
//! materialize::Materializer`. Drives the recipe-publish workflow:
//! recipe + manifest + arch → rootfs `.tar`. Per-OS converters
//! (`materialize::macos::tar_to_vfr_img`, `materialize::wsl::
//! tar_to_wsl_import`) wrap the `.tar` separately.
//!
//! Usage:
//!
//!     cargo run -p tillandsias-vm-layer --example materialize-cli \
//!         --features materialize -- \
//!         --recipe   images/vm/Recipefile \
//!         --manifest images/vm/manifest.toml \
//!         --arch     aarch64 \
//!         --cache-root  /tmp/recipe-cache \
//!         --output   /tmp/rootfs.tar \
//!         [--executor noop]    (default: buildah; noop is for smoke tests)
//!
//! Exit codes:
//!   0  successful materialization; rootfs written to --output
//!   2  argument parse error
//!   3  recipe / manifest parse error
//!   4  materializer exec error (e.g. buildah missing, build step failed)
//!   5  output-copy error
//!
//! @trace openspec/changes/vm-recipe-provisioning §2b.3, §D6

#[cfg(not(feature = "materialize"))]
fn main() {
    eprintln!(
        "materialize-cli requires --features materialize; rebuild with \
         `cargo run -p tillandsias-vm-layer --example materialize-cli \
         --features materialize -- …`"
    );
    std::process::exit(2);
}

#[cfg(feature = "materialize")]
fn main() {
    real_main()
}

#[cfg(feature = "materialize")]
fn real_main() {
    use std::path::PathBuf;

    use tillandsias_vm_layer::materialize::{
        BuildahExec, MaterializedRootfs, Materializer, NoopExec,
    };
    use tillandsias_vm_layer::recipe::{Manifest, Recipe};

    let args = parse_args();
    eprintln!(
        "[materialize-cli] recipe={} manifest={} arch={} cache={} output={} executor={:?}",
        args.recipe.display(),
        args.manifest.display(),
        args.arch.as_str(),
        args.cache_root.display(),
        args.output.display(),
        args.executor
    );

    // Parse recipe + manifest.
    let recipe = match Recipe::parse(&args.recipe) {
        Ok(r) => r,
        Err(e) => {
            eprintln!("[materialize-cli] recipe parse: {e}");
            std::process::exit(3);
        }
    };
    let manifest = match Manifest::load(&args.manifest) {
        Ok(m) => m,
        Err(e) => {
            eprintln!("[materialize-cli] manifest load: {e}");
            std::process::exit(3);
        }
    };

    // Materialize. The Executor choice gives us a smoke-test path that
    // doesn't need buildah on the runner — useful for CI workflows that
    // want to sanity-check the recipe parse + driver shape without the
    // multi-minute buildah pull/build cycle.
    let rootfs: Result<MaterializedRootfs, _> = match args.executor {
        Executor::Buildah => {
            // Build context = the Recipefile's parent dir, so relative
            // `COPY bootstrap/ ...` sources resolve against
            // `images/vm/bootstrap/` regardless of the process CWD.
            let context_dir = args
                .recipe
                .parent()
                .map(|p| p.to_path_buf())
                .unwrap_or_else(|| std::path::PathBuf::from("."));
            let exec = BuildahExec::default().with_context(context_dir);
            let m = Materializer::new(exec, args.cache_root.clone());
            m.run(&recipe, &manifest, args.arch)
        }
        Executor::Noop => {
            let m = Materializer::new(NoopExec::default(), args.cache_root.clone());
            m.run(&recipe, &manifest, args.arch)
        }
    };
    let MaterializedRootfs::Tar(tar_path) = match rootfs {
        Ok(r) => r,
        Err(e) => {
            eprintln!("[materialize-cli] materializer: {e}");
            std::process::exit(4);
        }
    };

    // Copy the rootfs.tar to the caller-specified output path. We don't
    // move (rename) because the cache may live on a different filesystem
    // from the output; copy + leave the cache entry intact for layer reuse.
    if let Err(e) = std::fs::copy(&tar_path, &args.output) {
        eprintln!(
            "[materialize-cli] copy {} → {}: {e}",
            tar_path.display(),
            args.output.display()
        );
        std::process::exit(5);
    }

    eprintln!(
        "[materialize-cli] done: wrote {} bytes to {}",
        std::fs::metadata(&args.output)
            .map(|m| m.len())
            .unwrap_or(0),
        args.output.display()
    );

    // Compile-time check that the unused-import lint doesn't fire.
    let _ = PathBuf::new();
}

#[cfg(feature = "materialize")]
#[derive(Debug, Clone, Copy)]
enum Executor {
    Buildah,
    Noop,
}

#[cfg(feature = "materialize")]
struct Args {
    recipe: std::path::PathBuf,
    manifest: std::path::PathBuf,
    arch: tillandsias_vm_layer::materialize::HostArch,
    cache_root: std::path::PathBuf,
    output: std::path::PathBuf,
    executor: Executor,
}

#[cfg(feature = "materialize")]
fn parse_args() -> Args {
    use std::path::PathBuf;
    use tillandsias_vm_layer::materialize::HostArch;

    let mut recipe = None;
    let mut manifest = None;
    let mut arch = None;
    let mut cache_root = None;
    let mut output = None;
    let mut executor = Executor::Buildah;

    let mut it = std::env::args().skip(1);
    while let Some(a) = it.next() {
        match a.as_str() {
            "--recipe" => recipe = it.next().map(PathBuf::from),
            "--manifest" => manifest = it.next().map(PathBuf::from),
            "--cache-root" => cache_root = it.next().map(PathBuf::from),
            "--output" => output = it.next().map(PathBuf::from),
            "--arch" => {
                arch = match it.next().as_deref() {
                    Some("x86_64") => Some(HostArch::X86_64),
                    Some("aarch64") => Some(HostArch::Aarch64),
                    other => {
                        eprintln!(
                            "[materialize-cli] --arch must be x86_64 or aarch64 (got {other:?})"
                        );
                        std::process::exit(2);
                    }
                };
            }
            "--executor" => {
                executor = match it.next().as_deref() {
                    Some("buildah") => Executor::Buildah,
                    Some("noop") => Executor::Noop,
                    other => {
                        eprintln!(
                            "[materialize-cli] --executor must be buildah|noop (got {other:?})"
                        );
                        std::process::exit(2);
                    }
                };
            }
            "-h" | "--help" => {
                eprintln!(
                    "usage: materialize-cli --recipe <Recipefile> \
                     --manifest <manifest.toml> --arch x86_64|aarch64 \
                     --cache-root <dir> --output <rootfs.tar> \
                     [--executor buildah|noop]"
                );
                std::process::exit(0);
            }
            other => {
                eprintln!("[materialize-cli] unknown arg: {other}");
                std::process::exit(2);
            }
        }
    }

    Args {
        recipe: recipe.unwrap_or_else(|| die_missing("--recipe")),
        manifest: manifest.unwrap_or_else(|| die_missing("--manifest")),
        arch: arch.unwrap_or_else(|| {
            die_missing_arg("--arch");
            unreachable!()
        }),
        cache_root: cache_root.unwrap_or_else(|| die_missing("--cache-root")),
        output: output.unwrap_or_else(|| die_missing("--output")),
        executor,
    }
}

#[cfg(feature = "materialize")]
fn die_missing(arg: &str) -> std::path::PathBuf {
    eprintln!("[materialize-cli] missing required arg: {arg}");
    std::process::exit(2);
}

#[cfg(feature = "materialize")]
fn die_missing_arg(arg: &str) {
    eprintln!("[materialize-cli] missing required arg: {arg}");
    std::process::exit(2);
}
