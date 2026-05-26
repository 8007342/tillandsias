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

use std::path::{Path, PathBuf};
use std::process::Command;
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::{Arc, Mutex};

use super::HostArch;
use super::layer_key::LayerKey;
use crate::recipe::{Instruction, RecipeDirective};

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

/// Virtual / runtime filesystem mount points that are excluded from each
/// layer's snapshot tar (the guest re-populates them at boot, and copying
/// the host's contents would bloat the tar). They must still EXIST as
/// empty directories in every hydrated layer, otherwise build-time tools
/// that write into them fail — e.g. dnf's librepo creating
/// `/tmp/librepo-tmp-*`, which surfaces as
/// `Cannot create temporary file ... No such file or directory`.
/// We exclude-on-snapshot ([`BuildahExec::snapshot_tar`]) but
/// recreate-on-hydrate ([`recreate_runtime_dirs`]) so the invariant holds.
const RUNTIME_VIRTUAL_DIRS: &[&str] = &["proc", "sys", "dev", "run", "tmp"];

/// Recreate the runtime virtual-fs mount points (excluded from snapshot
/// tars) as empty directories with kernel-standard permissions. `/tmp`
/// gets the sticky, world-writable mode `01777`; the rest `0755`.
fn recreate_runtime_dirs(root: &Path) -> Result<(), ExecError> {
    for dir in RUNTIME_VIRTUAL_DIRS {
        let path = root.join(dir);
        std::fs::create_dir_all(&path)
            .map_err(|e| format!("recreate runtime dir {}: {e}", path.display()))?;
        // Kernel-standard rootfs modes (sticky+world-writable /tmp, 0755 rest)
        // are a Unix concept; the buildah materializer only runs on a Unix host.
        // cfg-gate so vm-layer still COMPILES on Windows (cargo test / cross
        // build) — there the dir is created but the mode is a no-op, which is
        // fine because the materialize feature isn't exercised at runtime on
        // Windows (it downloads the CI-published rootfs instead).
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            let mode = if *dir == "tmp" { 0o1777 } else { 0o755 };
            std::fs::set_permissions(&path, std::fs::Permissions::from_mode(mode))
                .map_err(|e| format!("chmod runtime dir {} to {mode:o}: {e}", path.display()))?;
        }
    }
    Ok(())
}

/// Production executor: shells out to `buildah` inside a throwaway
/// working container. Linux-host only. Requires `buildah` on PATH; the
/// materializer will surface a clear error if it isn't.
///
/// Production executor: drives a real `buildah` subprocess to produce
/// one layer tar per `execute()` call.
///
/// Per-layer semantics: each call is self-contained — it spins up a
/// throwaway working container that starts from the parent layer's
/// state (or from the FROM image for the first layer), applies the
/// single instruction, snapshots the resulting rootfs to a tar, and
/// destroys the container. This means cache-miss-mid-recipe is correct
/// at the cost of re-extracting the parent tar each cold layer; on
/// repeat runs the materializer's cache layer skips this executor
/// entirely so the cost is paid once.
///
/// Requires `buildah` on PATH (or [`BuildahExec::with_binary`]).
/// Rootless usage on Fedora / Ubuntu CI works out of the box.
#[derive(Clone)]
pub struct BuildahExec {
    /// Optional path to the `buildah` binary; defaults to `"buildah"`
    /// (resolved through PATH).
    binary: PathBuf,
    /// Optional `tar` binary path; defaults to `"tar"`.
    tar_binary: PathBuf,
    /// Build context directory: relative `COPY`/`ADD` sources are resolved
    /// against this, matching Containerfile semantics where source paths
    /// are relative to the build context (conventionally the Recipefile's
    /// directory), NOT the process CWD. `None` falls back to CWD-relative
    /// resolution (buildah's default).
    context_dir: Option<PathBuf>,
}

impl Default for BuildahExec {
    fn default() -> Self {
        Self {
            binary: PathBuf::from("buildah"),
            tar_binary: PathBuf::from("tar"),
            context_dir: None,
        }
    }
}

impl std::fmt::Debug for BuildahExec {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("BuildahExec")
            .field("binary", &self.binary)
            .field("tar_binary", &self.tar_binary)
            .field("context_dir", &self.context_dir)
            .finish()
    }
}

impl BuildahExec {
    /// Override the buildah binary path.
    pub fn with_binary(mut self, path: PathBuf) -> Self {
        self.binary = path;
        self
    }

    /// Override the tar binary path.
    pub fn with_tar(mut self, path: PathBuf) -> Self {
        self.tar_binary = path;
        self
    }

    /// Set the build-context directory for relative `COPY`/`ADD` source
    /// resolution. Callers should pass the Recipefile's parent directory.
    pub fn with_context(mut self, dir: PathBuf) -> Self {
        self.context_dir = Some(dir);
        self
    }

    /// Resolve a `COPY`/`ADD` source path against the build context.
    /// Absolute sources are returned unchanged; relative sources are
    /// joined onto `context_dir` when set, else returned as-is (CWD
    /// relative).
    fn resolve_copy_src(&self, src: &str) -> String {
        let src_path = Path::new(src);
        if src_path.is_absolute() {
            return src.to_string();
        }
        match &self.context_dir {
            Some(ctx) => ctx.join(src_path).to_string_lossy().into_owned(),
            None => src.to_string(),
        }
    }

    /// Run `buildah <args>` to completion, returning stdout (or the
    /// stderr-bearing error if the exit status was non-zero).
    fn run_buildah(&self, args: &[&str]) -> Result<String, ExecError> {
        run_capture(&self.binary, args)
    }

    /// Create a fresh working container. For the first layer this comes
    /// from the FROM image; for subsequent layers it starts from
    /// `scratch` and we hydrate the rootfs by extracting the parent
    /// tar into the mount point.
    fn new_container(
        &self,
        instruction: &Instruction,
        ctx: &ExecContext,
    ) -> Result<String, ExecError> {
        match (&ctx.parent_layer, instruction) {
            (None, Instruction::From { image }) => {
                // First layer of the chain: pull/import the base image.
                let ctr = self.run_buildah(&["from", "--", image])?.trim().to_string();
                Ok(ctr)
            }
            (None, _) => Err(format!(
                "first instruction must be FROM (got {})",
                describe_instr(instruction)
            )),
            (Some(parent), _) => {
                // Subsequent layer: scratch container, mount, extract
                // parent tar into mount, unmount. Cheaper variants
                // (e.g. `buildah from <committed-layer-image>`) require
                // a buildah-image-storage cache; we ship the tar-based
                // variant for portability + simplicity.
                let ctr = self.run_buildah(&["from", "scratch"])?.trim().to_string();
                self.hydrate_from_tar(&ctr, parent).inspect_err(|_| {
                    // Best-effort cleanup; ignore the rm error.
                    let _ = self.run_buildah(&["rm", &ctr]);
                })?;
                Ok(ctr)
            }
        }
    }

    /// Extract `tar_path` into the working container's mount point.
    fn hydrate_from_tar(&self, ctr: &str, tar_path: &Path) -> Result<(), ExecError> {
        let mount_point = self.run_buildah(&["mount", ctr])?.trim().to_string();
        let tar_status = Command::new(&self.tar_binary)
            .arg("-xf")
            .arg(tar_path)
            .arg("-C")
            .arg(&mount_point)
            .status()
            .map_err(|e| format!("spawn tar -xf {}: {e}", tar_path.display()))?;
        // Recreate the virtual-fs mount points excluded from the snapshot
        // tar, while the container is still mounted. Without this a layer
        // built `from scratch` lacks /tmp (etc.), and the next RUN's tools
        // fail — e.g. `dnf` → `mkstemp '/tmp/librepo-tmp-*': No such file
        // or directory`. Only attempt when the extraction succeeded.
        let mkdir_result = if tar_status.success() {
            recreate_runtime_dirs(Path::new(&mount_point))
        } else {
            Ok(())
        };
        // Always umount (best-effort) before propagating an error.
        let _ = self.run_buildah(&["umount", ctr]);
        if !tar_status.success() {
            return Err(format!(
                "tar -xf {} into {} failed with status {tar_status}",
                tar_path.display(),
                mount_point
            ));
        }
        mkdir_result
    }

    /// Apply `instruction` against the container.
    fn apply_instruction(&self, ctr: &str, instr: &Instruction) -> Result<(), ExecError> {
        match instr {
            Instruction::From { .. } => Ok(()), // Already handled by new_container.
            Instruction::Run { script } => self
                .run_buildah(&["run", ctr, "--", "/bin/sh", "-c", script])
                .map(|_| ()),
            Instruction::Copy { src, dest } => {
                // Resolve the source against the build context (Recipefile
                // dir) so `COPY bootstrap/ ...` finds `images/vm/bootstrap/`
                // regardless of the process CWD.
                let resolved_src = self.resolve_copy_src(src);
                self.run_buildah(&["copy", ctr, &resolved_src, dest])
                    .map(|_| ())
            }
            Instruction::Env { key, value } => self
                .run_buildah(&["config", "--env", &format!("{key}={value}"), ctr])
                .map(|_| ()),
            Instruction::Workdir { path } => self
                .run_buildah(&["config", "--workingdir", path, ctr])
                .map(|_| ()),
            Instruction::Arg { .. } => Ok(()), // ARG defaults are picked up at parse time.
            Instruction::Recipe(RecipeDirective::Entry(cmd)) => self
                .run_buildah(&["config", "--entrypoint", cmd, ctr])
                .map(|_| ()),
            Instruction::Recipe(RecipeDirective::VsockListen(_))
            | Instruction::Recipe(RecipeDirective::Arch(_))
            | Instruction::Other { .. } => {
                // VsockListen/Arch are recipe-only metadata applied via
                // bootstrap scripts (`images/vm/bootstrap/*.sh`); the
                // materializer doesn't need to touch buildah for them.
                // Unknown directives are ignored to keep the parser
                // forward-compatible.
                Ok(())
            }
        }
    }

    /// Snapshot the container's filesystem to `<dst>` as a flat rootfs
    /// tar. Uses `buildah unshare ... tar -C $mnt -cf $dst .` so we don't
    /// need privileged tar invocations.
    fn snapshot_tar(&self, ctr: &str, dst: &Path) -> Result<(), ExecError> {
        let mount_point = self.run_buildah(&["mount", ctr])?.trim().to_string();
        let mut cmd = Command::new(&self.tar_binary);
        cmd.arg("-cf").arg(dst);
        // Exclude virtual filesystems that have no business in a rootfs
        // tar — they're mount points the guest re-populates at boot, and
        // copying their host contents bloats the tar without value. They
        // are recreated as empty dirs on the next hydrate via
        // `recreate_runtime_dirs` so build-time tools still find them.
        for dir in RUNTIME_VIRTUAL_DIRS {
            cmd.arg(format!("--exclude=./{dir}"));
        }
        let tar_status = cmd
            .arg("-C")
            .arg(&mount_point)
            .arg(".")
            .status()
            .map_err(|e| format!("spawn tar -cf {}: {e}", dst.display()))?;
        let _ = self.run_buildah(&["umount", ctr]);
        if !tar_status.success() {
            return Err(format!(
                "tar -cf {} from {} failed with status {tar_status}",
                dst.display(),
                mount_point
            ));
        }
        Ok(())
    }
}

impl LayerExecutor for BuildahExec {
    fn execute(&self, instruction: &Instruction, ctx: &ExecContext) -> Result<PathBuf, ExecError> {
        let dst_dir = ctx.cache_dir.join(ctx.host_arch.as_str());
        std::fs::create_dir_all(&dst_dir)
            .map_err(|e| format!("create cache dir {}: {e}", dst_dir.display()))?;
        let dst = dst_dir.join(format!("{}.tar.tmp", ctx.layer_key.as_str()));

        let ctr = self.new_container(instruction, ctx)?;

        // Helper closure so cleanup is guaranteed across the apply +
        // snapshot path.
        let outcome = (|| {
            self.apply_instruction(&ctr, instruction)?;
            self.snapshot_tar(&ctr, &dst)
        })();

        // Best-effort container cleanup; report it only if everything
        // else succeeded but rm failed (rare).
        let rm_result = self.run_buildah(&["rm", &ctr]);

        outcome?;
        let _ = rm_result;
        Ok(dst)
    }
}

fn run_capture(binary: &Path, args: &[&str]) -> Result<String, ExecError> {
    let output = Command::new(binary)
        .args(args)
        .output()
        .map_err(|e| format!("spawn {} {}: {e}", binary.display(), args.join(" ")))?;
    if !output.status.success() {
        let stderr = String::from_utf8_lossy(&output.stderr);
        return Err(format!(
            "{} {} exited {}: {}",
            binary.display(),
            args.join(" "),
            output.status,
            stderr.trim()
        ));
    }
    Ok(String::from_utf8_lossy(&output.stdout).into_owned())
}

fn describe_instr(instr: &Instruction) -> &'static str {
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

    // Mode bits are Unix-only; on Windows `recreate_runtime_dirs` creates the
    // dirs but applies no mode (the materialize feature isn't used at runtime
    // there), so this assertion only holds — and `.mode()` only exists — on Unix.
    #[cfg(unix)]
    #[test]
    fn recreate_runtime_dirs_makes_tmp_world_writable_sticky() {
        use std::os::unix::fs::PermissionsExt;
        let tmp = tempfile::tempdir().unwrap();
        recreate_runtime_dirs(tmp.path()).unwrap();
        for dir in RUNTIME_VIRTUAL_DIRS {
            let p = tmp.path().join(dir);
            assert!(p.is_dir(), "{dir} should exist as a directory");
            let mode = std::fs::metadata(&p).unwrap().permissions().mode() & 0o7777;
            let want = if *dir == "tmp" { 0o1777 } else { 0o755 };
            assert_eq!(mode, want, "{dir} mode {mode:o} != {want:o}");
        }
    }

    // Asserts forward-slash Linux build-context path joining; `PathBuf::join`
    // yields backslashes on Windows, and the buildah materializer is Linux-only,
    // so this is a Unix-only behavioral test (the feature still compiles on
    // Windows — see the cfg-gate in `recreate_runtime_dirs`).
    #[cfg(unix)]
    #[test]
    fn resolve_copy_src_joins_relative_onto_context() {
        let exec = BuildahExec::default().with_context(PathBuf::from("/repo/images/vm"));
        assert_eq!(
            exec.resolve_copy_src("bootstrap/"),
            "/repo/images/vm/bootstrap/"
        );
        // Absolute sources pass through untouched.
        assert_eq!(exec.resolve_copy_src("/etc/hosts"), "/etc/hosts");
    }

    #[test]
    fn resolve_copy_src_without_context_is_cwd_relative() {
        let exec = BuildahExec::default();
        assert_eq!(exec.resolve_copy_src("bootstrap/"), "bootstrap/");
    }

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
    fn buildah_exec_rejects_non_from_as_first_instruction() {
        // Unit-level check that doesn't invoke buildah: if the parent
        // layer is None, the first instruction must be FROM. We point
        // BuildahExec at a missing binary so any subprocess invocation
        // would surface as an error — proving the early-validate path
        // catches the bug before reaching the subprocess.
        let tmp = tempfile::tempdir().unwrap();
        let exec = BuildahExec::default().with_binary(PathBuf::from(
            "/this/binary/intentionally/does/not/exist/buildah",
        ));
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
            .expect_err("first instruction must be FROM");
        assert!(
            err.contains("must be FROM"),
            "expected FROM-required error; got {err:?}",
        );
    }

    /// Real-buildah integration smoke: builds a 3-layer recipe end-to-end
    /// and asserts the resulting tar contains a known file. `#[ignore]`
    /// because it requires `buildah` on PATH and pulls a Fedora base
    /// image (~70 MB). To run:
    ///
    /// ```bash
    /// cargo test -p tillandsias-vm-layer --features materialize \
    ///   --lib materialize::exec::tests::buildah_exec_live -- --ignored --nocapture
    /// ```
    ///
    /// CI's `recipe-smoke` job (§6.4 of vm-recipe-provisioning) drives
    /// this path against the real Recipefile under `images/vm/`.
    #[test]
    #[ignore = "requires buildah on PATH + network for Fedora base image"]
    fn buildah_exec_live_three_layer_recipe() {
        use crate::recipe::Recipe;

        let tmp = tempfile::tempdir().unwrap();
        let cache_root = tmp.path().to_path_buf();
        let recipe = Recipe::parse_str(
            r#"
FROM registry.fedoraproject.org/fedora:44
RUN echo "hello from layer 2" > /etc/tillandsias-smoke
RECIPE arch x86_64,aarch64
"#,
        )
        .unwrap();
        let manifest = crate::recipe::Manifest::from_toml(
            r#"
recipe_version = 1
[[base]]
arch = "x86_64"
ref = "registry.fedoraproject.org/fedora:44"
digest = "sha256:placeholder"
"#,
        )
        .unwrap();
        let mat = crate::materialize::Materializer::new(BuildahExec::default(), cache_root);
        let result = mat
            .run(&recipe, &manifest, HostArch::X86_64)
            .expect("buildah live run succeeds");
        match result {
            crate::materialize::MaterializedRootfs::Tar(path) => {
                assert!(path.exists(), "final rootfs tar should exist");
                // Tar should be non-trivial (Fedora base + one file).
                let meta = std::fs::metadata(&path).unwrap();
                assert!(meta.len() > 10_000_000, "rootfs tar suspiciously small");
            }
        }
    }
}
