//! Compatibility entrypoint for the canonical image build engine.
//!
//! This binary intentionally contains no independent freshness or Podman
//! logic. It resolves the repository root and delegates every argument to
//! `scripts/build-image.sh`, the same engine used by public shell wrappers.
//!
//! @trace spec:user-runtime-lifecycle, spec:litmus-framework

use std::env;
use std::path::{Path, PathBuf};
use std::process::{self, Command};

fn find_repo_root() -> Result<PathBuf, String> {
    if let Some(root) = env::var_os("TILLANDSIAS_ROOT") {
        let root = PathBuf::from(root);
        if root.join("scripts/build-image.sh").is_file() {
            return Ok(root);
        }
        return Err(format!(
            "TILLANDSIAS_ROOT does not contain scripts/build-image.sh: {}",
            root.display()
        ));
    }

    let mut current = env::current_dir().map_err(|error| error.to_string())?;
    loop {
        if current.join("scripts/build-image.sh").is_file() {
            return Ok(current);
        }
        if !current.pop() {
            break;
        }
    }

    let manifest_root = Path::new(env!("CARGO_MANIFEST_DIR")).join("../..");
    if manifest_root.join("scripts/build-image.sh").is_file() {
        return manifest_root
            .canonicalize()
            .map_err(|error| error.to_string());
    }

    Err("unable to locate repository root containing scripts/build-image.sh".to_string())
}

fn run() -> Result<i32, String> {
    let root = find_repo_root()?;
    let script = root.join("scripts/build-image.sh");
    let status = Command::new(&script)
        .args(env::args_os().skip(1))
        .current_dir(&root)
        .status()
        .map_err(|error| format!("failed to execute {}: {error}", script.display()))?;
    Ok(status.code().unwrap_or(1))
}

fn main() {
    match run() {
        Ok(code) => process::exit(code),
        Err(error) => {
            eprintln!("build-image: {error}");
            process::exit(1);
        }
    }
}
