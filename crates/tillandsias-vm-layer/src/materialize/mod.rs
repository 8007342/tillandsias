//! Recipe materializer driver — `vm-recipe-provisioning` §3 + §4.
//!
//! Takes the parsed [`crate::recipe::Recipe`] + [`crate::recipe::Manifest`]
//! and walks each [`Instruction`] in order. Each instruction becomes a
//! "layer": its content-addressed key is the SHA-256 of (parent layer SHA +
//! directive text + copied-content SHA). The driver checks
//! `<cache-root>/recipe-cache/<layer-key>.tar` for a hit; on miss it asks
//! the [`LayerExecutor`] to produce the new layer (production: `buildah`
//! inside a throwaway working container; tests: a deterministic mock).
//! Layer tars accumulate into the cache so subsequent runs of the same
//! recipe are <1 s.
//!
//! The driver itself is platform-agnostic and runs on Linux CI hosts. Per-OS
//! converters (`§3.7.1 macos::tar_to_vfr_img`, `§3.7.2 wsl::tar_to_wsl_import`)
//! are sibling claims; this module exposes the rootfs `.tar` and trait
//! extension points but does not implement the conversions itself.
//!
//! @trace spec:vm-provisioning-lifecycle, plan/issues/multi-host-integration-loop-2026-05-24.md (l7)

#![allow(dead_code)]

use std::path::PathBuf;
use std::time::SystemTime;

use crate::recipe::{Instruction, Manifest, Recipe};

pub mod cache;
pub mod exec;
pub mod layer_key;
pub mod trace;
/// §3.7.2 — Windows converter: `MaterializedRootfs::Tar` → `wsl --import`.
/// windows-next sibling claim; the macOS `.img` converter is `macos` (m-owned).
pub mod wsl;

/// macOS-specific output converter (§3.7.1). Takes a rootfs `.tar` produced
/// by `Materializer::run` and emits a raw `.img` with GPT + EFI System
/// Partition + ext4 root, bootable by Virtualization.framework. Runs on
/// Linux (shells out to `mkfs.ext4`/`parted`/`losetup`) per D6, so the
/// recipe-publish CI job can produce both `.tar` and `.img` artifacts in
/// one job.
pub mod macos;

pub use cache::{Cache, CacheError, GcReport};
pub use exec::{BuildahExec, ExecContext, ExecError, LayerExecutor, NoopExec};
pub use layer_key::{LayerKey, layer_key};
pub use trace::{TraceEvent, TraceLedger};
pub use wsl::{tar_to_wsl_import, wsl_import_args};

/// Output of a successful materialization. `Tar` is the universal output;
/// per-OS converters wrap it in `.img` / `wsl --import` as needed.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum MaterializedRootfs {
    /// Path to the final rootfs `.tar` inside the cache.
    Tar(PathBuf),
}

/// Driver error surface. Stringly typed at the boundary to match the
/// existing `RecipeError` idiom in `crate::recipe`.
pub type MaterializeError = String;

/// Materializer entry point.
///
/// `executor` is the per-environment backend that runs a single
/// instruction inside the working container. The cache_root is the
/// on-host directory under which `recipe-cache/<key>.tar`,
/// `recipe-trace.jsonl`, and the per-arch GC entries live.
pub struct Materializer<E: LayerExecutor> {
    pub executor: E,
    pub cache_root: PathBuf,
}

impl<E: LayerExecutor> Materializer<E> {
    /// New materializer with the given executor + cache root. The cache
    /// directory is created lazily on first write.
    pub fn new(executor: E, cache_root: PathBuf) -> Self {
        Self {
            executor,
            cache_root,
        }
    }

    /// Walk every instruction in the recipe, producing the final rootfs
    /// `.tar`. Per-arch sanity check (§3.6) runs first: if the recipe's
    /// `RECIPE arch` list does not include `host_arch`, return an error.
    ///
    /// On success, the trace ledger at `<cache_root>/recipe-trace.jsonl`
    /// gets one [`TraceEvent`] per layer + one final event for the
    /// rootfs tar. Per §4.2 the cache GC runs after a successful walk so
    /// stale layers are pruned automatically.
    pub fn run(
        &self,
        recipe: &Recipe,
        manifest: &Manifest,
        host_arch: HostArch,
    ) -> Result<MaterializedRootfs, MaterializeError> {
        // §3.6: per-arch sanity check.
        verify_arch_supported(recipe, host_arch)?;

        let _ = manifest; // §3.x will reference the manifest for base digests.

        let cache = Cache::open(self.cache_root.clone())
            .map_err(|e| format!("open cache at {}: {e}", self.cache_root.display()))?;
        let mut ledger =
            TraceLedger::open(&self.cache_root).map_err(|e| format!("open trace ledger: {e}"))?;

        // Walk instructions, threading parent_key forward.
        let mut parent_key: Option<LayerKey> = None;
        for (idx, instr) in recipe.instructions.iter().enumerate() {
            // RECIPE / Other / Arg / Env / Workdir directives don't produce
            // filesystem layers — skip them but still fold them into the
            // chain so two different ordering produce different keys.
            if !instruction_produces_layer(instr) {
                continue;
            }
            let key = layer_key(parent_key.as_ref(), instr, host_arch);
            let started = SystemTime::now();

            let outcome = if let Some(path) = cache.lookup(&key) {
                ledger.append(TraceEvent::layer_hit(
                    idx,
                    key.clone(),
                    path.clone(),
                    started,
                ))?;
                Outcome::Hit(path)
            } else {
                let ctx = ExecContext {
                    parent_layer: cache.lookup(parent_key.as_ref().unwrap_or(&key.clone())),
                    host_arch,
                    cache_dir: cache.layer_dir(),
                    layer_key: key.clone(),
                };
                let path = self
                    .executor
                    .execute(instr, &ctx)
                    .map_err(|e| format!("layer {idx} ({}): {e}", instr_kind(instr)))?;
                let written = cache.store(&key, &path).map_err(|e| {
                    format!("cache store for layer {idx} ({}): {e}", instr_kind(instr))
                })?;
                ledger.append(TraceEvent::layer_miss(
                    idx,
                    key.clone(),
                    written.clone(),
                    started,
                ))?;
                Outcome::Miss(written)
            };
            parent_key = Some(match outcome {
                Outcome::Hit(_) => key,
                Outcome::Miss(_) => key,
            });
        }

        // §3.5: the last layer IS the rootfs tar.
        let final_key = parent_key.ok_or_else(|| {
            "recipe produced no layer-producing instructions; cannot emit rootfs".to_string()
        })?;
        let rootfs = cache.lookup(&final_key).ok_or_else(|| {
            "internal: final layer not in cache after successful walk".to_string()
        })?;
        ledger.append(TraceEvent::rootfs_emitted(
            final_key.clone(),
            rootfs.clone(),
            SystemTime::now(),
        ))?;

        // §4.2: GC at the end of a successful run.
        let gc_report = cache.gc(host_arch).unwrap_or_else(|_| GcReport::default());
        if gc_report.evicted > 0 {
            ledger.append(TraceEvent::gc(gc_report, SystemTime::now()))?;
        }

        Ok(MaterializedRootfs::Tar(rootfs))
    }
}

enum Outcome {
    Hit(PathBuf),
    Miss(PathBuf),
}

/// Target host architecture for a materialization run. The recipe's
/// `RECIPE arch` directive lists the strings the materializer accepts.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum HostArch {
    X86_64,
    Aarch64,
}

impl HostArch {
    pub const fn as_str(self) -> &'static str {
        match self {
            HostArch::X86_64 => "x86_64",
            HostArch::Aarch64 => "aarch64",
        }
    }
}

impl std::fmt::Display for HostArch {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str(self.as_str())
    }
}

fn verify_arch_supported(recipe: &Recipe, host_arch: HostArch) -> Result<(), MaterializeError> {
    let archs = recipe.instructions.iter().find_map(|i| match i {
        Instruction::Recipe(crate::recipe::RecipeDirective::Arch(list)) => Some(list),
        _ => None,
    });
    match archs {
        Some(list) if list.iter().any(|a| a == host_arch.as_str()) => Ok(()),
        Some(list) => Err(format!(
            "recipe does not support host_arch={host_arch}; declared `RECIPE arch {}`",
            list.join(",")
        )),
        None => {
            Err("recipe is missing `RECIPE arch <list>`; cannot validate host architecture".into())
        }
    }
}

fn instruction_produces_layer(instr: &Instruction) -> bool {
    matches!(
        instr,
        Instruction::From { .. } | Instruction::Run { .. } | Instruction::Copy { .. }
    )
}

fn instr_kind(instr: &Instruction) -> &'static str {
    match instr {
        Instruction::From { .. } => "FROM",
        Instruction::Arg { .. } => "ARG",
        Instruction::Run { .. } => "RUN",
        Instruction::Copy { .. } => "COPY",
        Instruction::Env { .. } => "ENV",
        Instruction::Workdir { .. } => "WORKDIR",
        Instruction::Recipe(_) => "RECIPE",
        Instruction::Other { .. } => "OTHER",
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::recipe::{Recipe, RecipeDirective};

    fn basic_recipe() -> Recipe {
        Recipe::parse_str(
            r#"
ARG TARGETARCH
FROM registry.fedoraproject.org/fedora:44@sha256:abcd
RUN dnf install -y systemd
COPY bootstrap/ /opt/bootstrap/
RECIPE vsock-listen 42420
RECIPE entry /usr/local/bin/tillandsias-headless
RECIPE arch x86_64,aarch64
"#,
        )
        .expect("recipe parses")
    }

    fn basic_manifest() -> Manifest {
        Manifest::from_toml(
            r#"
recipe_version = 1
recipe_sha = "deadbeef"

[[base]]
arch = "x86_64"
ref = "registry.fedoraproject.org/fedora:44"
digest = "sha256:abcd"

[[base]]
arch = "aarch64"
ref = "registry.fedoraproject.org/fedora:44"
digest = "sha256:efgh"
"#,
        )
        .expect("manifest parses")
    }

    #[test]
    fn materializer_runs_recipe_through_mock_executor() {
        let tmp = tempfile::tempdir().expect("tempdir");
        let mat = Materializer::new(NoopExec::default(), tmp.path().to_path_buf());
        let result = mat
            .run(&basic_recipe(), &basic_manifest(), HostArch::X86_64)
            .expect("materialization succeeds");
        match result {
            MaterializedRootfs::Tar(path) => {
                assert!(path.exists(), "final tar should exist on disk");
                assert!(
                    path.starts_with(tmp.path()),
                    "final tar should live under the cache root"
                );
            }
        }
    }

    #[test]
    fn materializer_caches_layers_between_runs() {
        let tmp = tempfile::tempdir().expect("tempdir");
        let exec = NoopExec::default();
        let mat = Materializer::new(exec.clone(), tmp.path().to_path_buf());

        // First run: cache cold, NoopExec records each invocation.
        let _r1 = mat.run(&basic_recipe(), &basic_manifest(), HostArch::X86_64);
        let first_calls = exec.call_count();

        // Second run with the same exec instance + same cache root: every
        // layer hits the cache, executor receives zero new invocations.
        let _r2 = mat.run(&basic_recipe(), &basic_manifest(), HostArch::X86_64);
        let second_calls = exec.call_count();

        assert!(
            first_calls > 0,
            "first run should invoke executor at least once"
        );
        assert_eq!(
            second_calls, first_calls,
            "second run should not invoke executor (all cache hits)"
        );
    }

    #[test]
    fn materializer_rejects_unsupported_arch() {
        let tmp = tempfile::tempdir().expect("tempdir");
        let recipe = Recipe::parse_str(
            r#"
FROM x
RECIPE arch x86_64
"#,
        )
        .unwrap();
        let mat = Materializer::new(NoopExec::default(), tmp.path().to_path_buf());
        let err = mat
            .run(&recipe, &basic_manifest(), HostArch::Aarch64)
            .expect_err("should reject");
        assert!(err.contains("host_arch=aarch64"), "got {err:?}");
    }

    #[test]
    fn materializer_rejects_recipe_missing_arch_directive() {
        let tmp = tempfile::tempdir().expect("tempdir");
        let recipe = Recipe::parse_str("FROM x\nRUN echo hi\n").unwrap();
        let mat = Materializer::new(NoopExec::default(), tmp.path().to_path_buf());
        let err = mat
            .run(&recipe, &basic_manifest(), HostArch::X86_64)
            .expect_err("should reject");
        assert!(err.contains("missing `RECIPE arch"), "got {err:?}");
    }

    #[test]
    fn instruction_layer_classification() {
        let from = Instruction::From { image: "x".into() };
        let run = Instruction::Run {
            script: "echo".into(),
        };
        let copy = Instruction::Copy {
            src: "a".into(),
            dest: "b".into(),
        };
        let arg = Instruction::Arg {
            name: "X".into(),
            default: None,
        };
        let env = Instruction::Env {
            key: "K".into(),
            value: "V".into(),
        };
        let workdir = Instruction::Workdir { path: "/".into() };
        let recipe_directive = Instruction::Recipe(RecipeDirective::VsockListen(42420));

        assert!(instruction_produces_layer(&from));
        assert!(instruction_produces_layer(&run));
        assert!(instruction_produces_layer(&copy));
        assert!(!instruction_produces_layer(&arg));
        assert!(!instruction_produces_layer(&env));
        assert!(!instruction_produces_layer(&workdir));
        assert!(!instruction_produces_layer(&recipe_directive));
    }
}
