//! Layer executor abstraction (§3.4 of vm-recipe-provisioning).
//!
//! The materializer is platform-agnostic; the actual fork-and-run of one
//! recipe directive inside a throwaway working container is delegated to
//! a [`LayerExecutor`] impl. Production: [`BuildahExec`] (Linux-host
//! buildah subprocess). Tests: [`NoopExec`] (writes a deterministic
//! placeholder tar so the cache + ledger paths still exercise correctly).
//!
//! When sibling agents implement §3.7.1 (`materialize::macos`) or §3.7.2
//! (`materialize::wsl`), they consume the rootfs `.tar` this trait
//! produces — not this trait itself. The per-OS converters are output
//! adapters; the executor is the input pump.
//!
//! @trace spec:vm-provisioning-lifecycle (§3.4)

use std::path::PathBuf;
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::{Arc, Mutex};

use super::HostArch;
use super::layer_key::LayerKey;
use crate::recipe::Instruction;

pub type ExecError = String;

/// What the materializer hands to a `LayerExecutor::execute` call.
#[derive(Debug, Clone)]
pub struct ExecContext {
    /// Parent layer tar, if this isn't the first layer. The executor
    /// extracts it as the starting filesystem state.
    pub parent_layer: Option<PathBuf>,
    /// Target arch this layer is being built for.
    pub host_arch: HostArch,
    /// Directory the executor should drop its produced tar into. The
    /// cache subsequently `rename`s it to the canonical `<arch>/<key>.tar`
    /// path.
    pub cache_dir: PathBuf,
    /// Pre-computed layer key. Convenient for naming the output tar.
    pub layer_key: LayerKey,
}

/// One pluggable backend that runs a single recipe instruction inside a
/// build environment and emits the resulting filesystem as a tar.
pub trait LayerExecutor {
    /// Run `instruction` against `ctx.parent_layer`'s filesystem,
    /// returning the path to the new layer's tar (which the caller will
    /// `rename` into the cache).
    ///
    /// On error, the materializer aborts the recipe walk; the cache
    /// retains all layers that already succeeded.
    fn execute(&self, instruction: &Instruction, ctx: &ExecContext) -> Result<PathBuf, ExecError>;
}

// -- Real production impl: `buildah` subprocess -----------------------------

/// Production executor: shells out to `buildah` inside a throwaway
/// working container. Linux-host only. Requires `buildah` on PATH; the
/// materializer will surface a clear error if it isn't.
///
/// The current scaffold focuses on the abstraction and the cache/key
/// plumbing; the real subprocess driving (`buildah from <base>`, `buildah
/// run <ctr> <argv>`, `buildah commit`, `tar` export) will be wired in a
/// follow-on once the recipe-smoke CI job exists to validate it against
/// a real Fedora base. The struct exists today so call sites and feature
/// flags settle.
#[derive(Debug, Clone, Default)]
pub struct BuildahExec {
    /// Optional path to the `buildah` binary; defaults to `"buildah"`
    /// (resolved through PATH).
    pub binary: Option<PathBuf>,
}

impl LayerExecutor for BuildahExec {
    fn execute(
        &self,
        _instruction: &Instruction,
        _ctx: &ExecContext,
    ) -> Result<PathBuf, ExecError> {
        Err(
            "BuildahExec is a scaffold; real subprocess wiring lands with the recipe-smoke CI job (§6.4 of vm-recipe-provisioning)".into()
        )
    }
}

// -- Test impl: deterministic placeholder -----------------------------------

/// Test executor: writes a deterministic 1-byte tar named after the
/// layer key + arch into `ctx.cache_dir`. Used by the materializer
/// integration tests so the cache + ledger paths run end-to-end without
/// requiring a real `buildah`.
///
/// Tracks call count for cache-hit assertions. Cloning shares the
/// underlying counter + key list via `Arc` so the materializer can take
/// `clone()` as owned while tests observe the original.
#[derive(Debug, Default, Clone)]
pub struct NoopExec {
    inner: Arc<NoopExecInner>,
}

#[derive(Debug, Default)]
struct NoopExecInner {
    calls: AtomicUsize,
    last_keys: Mutex<Vec<LayerKey>>,
}

impl NoopExec {
    pub fn call_count(&self) -> usize {
        self.inner.calls.load(Ordering::SeqCst)
    }

    pub fn last_keys(&self) -> Vec<LayerKey> {
        self.inner
            .last_keys
            .lock()
            .map(|g| g.clone())
            .unwrap_or_default()
    }
}

impl LayerExecutor for NoopExec {
    fn execute(&self, _instruction: &Instruction, ctx: &ExecContext) -> Result<PathBuf, ExecError> {
        let dst_dir = ctx.cache_dir.join(ctx.host_arch.as_str());
        std::fs::create_dir_all(&dst_dir)
            .map_err(|e| format!("noop-exec mkdir {}: {e}", dst_dir.display()))?;
        let dst = dst_dir.join(format!("{}.tar.tmp", ctx.layer_key.as_str()));
        std::fs::write(&dst, b"noop-layer")
            .map_err(|e| format!("noop-exec write {}: {e}", dst.display()))?;
        self.inner.calls.fetch_add(1, Ordering::SeqCst);
        if let Ok(mut g) = self.inner.last_keys.lock() {
            g.push(ctx.layer_key.clone());
        }
        Ok(dst)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::materialize::layer_key::layer_key;

    #[test]
    fn noop_exec_increments_call_count() {
        let tmp = tempfile::tempdir().unwrap();
        let exec = NoopExec::default();
        let key = layer_key(
            None,
            &Instruction::Run { script: "x".into() },
            HostArch::X86_64,
        );
        let ctx = ExecContext {
            parent_layer: None,
            host_arch: HostArch::X86_64,
            cache_dir: tmp.path().to_path_buf(),
            layer_key: key,
        };
        let _ = exec
            .execute(&Instruction::Run { script: "x".into() }, &ctx)
            .unwrap();
        assert_eq!(exec.call_count(), 1);
    }

    #[test]
    fn buildah_exec_scaffold_returns_clear_unimplemented() {
        let tmp = tempfile::tempdir().unwrap();
        let exec = BuildahExec::default();
        let key = layer_key(
            None,
            &Instruction::Run { script: "x".into() },
            HostArch::X86_64,
        );
        let ctx = ExecContext {
            parent_layer: None,
            host_arch: HostArch::X86_64,
            cache_dir: tmp.path().to_path_buf(),
            layer_key: key,
        };
        let err = exec
            .execute(&Instruction::Run { script: "x".into() }, &ctx)
            .expect_err("scaffold should error");
        assert!(err.contains("recipe-smoke"), "got {err:?}");
    }
}
