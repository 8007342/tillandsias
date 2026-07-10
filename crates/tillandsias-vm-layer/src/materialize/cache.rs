//! On-disk layer cache + GC (§3.3 + §4.1 of vm-recipe-provisioning).
//!
//! Layout under `<cache_root>/recipe-cache/`:
//!
//! ```text
//! recipe-cache/
//! ├── <arch>/
//! │   ├── <layer-key-1>.tar
//! │   ├── <layer-key-2>.tar
//! │   └── ...
//! └── (peer-arch directories)
//! ```
//!
//! Layer files are content-addressed by `LayerKey`; the materializer
//! looks up `<arch>/<key>.tar` to decide hit vs miss. GC prunes either
//! by age (default 90 days) or by per-arch count ceiling (default 5),
//! oldest mtime first.
//!
//! @trace spec:vm-provisioning-lifecycle (§3.3, §4.1)

use std::fs;
use std::path::{Path, PathBuf};
use std::time::{Duration, SystemTime};

use super::HostArch;
use super::layer_key::LayerKey;

const DEFAULT_GC_MAX_AGE_DAYS: u64 = 90;
const DEFAULT_GC_PER_ARCH_CEILING: usize = 5;

pub type CacheError = String;

/// Open-or-create handle to the on-disk recipe cache.
#[derive(Debug, Clone)]
pub struct Cache {
    root: PathBuf,
    arch_subdir: PathBuf,
    gc_max_age: Duration,
    gc_per_arch_ceiling: usize,
}

impl Cache {
    /// Create (idempotent) the `recipe-cache/` directory and return a
    /// handle. The arch-specific subdirectory is created lazily on first
    /// `store`.
    pub fn open(root: PathBuf) -> Result<Self, CacheError> {
        let recipe_cache = root.join("recipe-cache");
        fs::create_dir_all(&recipe_cache)
            .map_err(|e| format!("create {}: {e}", recipe_cache.display()))?;
        Ok(Self {
            root,
            arch_subdir: recipe_cache,
            gc_max_age: Duration::from_secs(DEFAULT_GC_MAX_AGE_DAYS * 24 * 60 * 60),
            gc_per_arch_ceiling: DEFAULT_GC_PER_ARCH_CEILING,
        })
    }

    /// Override GC parameters; mainly useful in tests.
    pub fn with_gc(mut self, max_age: Duration, per_arch_ceiling: usize) -> Self {
        self.gc_max_age = max_age;
        self.gc_per_arch_ceiling = per_arch_ceiling;
        self
    }

    /// Directory where layer tars are written. The materializer hands
    /// this to the executor via `ExecContext.cache_dir`.
    pub fn layer_dir(&self) -> PathBuf {
        self.arch_subdir.clone()
    }

    /// Look up `key` on disk; `None` if it's not present.
    pub fn lookup(&self, key: &LayerKey) -> Option<PathBuf> {
        for entry in fs::read_dir(&self.arch_subdir).ok()?.flatten() {
            let path = entry.path();
            if !path.is_dir() {
                continue;
            }
            let candidate = path.join(format!("{}.tar", key.as_str()));
            if candidate.exists() {
                return Some(candidate);
            }
        }
        None
    }

    /// Persist `src` into the cache under `<arch>/<key>.tar`. Returns
    /// the final canonical path. The destination directory is created
    /// on demand.
    pub fn store(&self, key: &LayerKey, src: &Path) -> Result<PathBuf, CacheError> {
        let arch = arch_from_source_path(src).unwrap_or("any");
        let dst_dir = self.arch_subdir.join(arch);
        fs::create_dir_all(&dst_dir).map_err(|e| format!("create {}: {e}", dst_dir.display()))?;
        let dst = dst_dir.join(format!("{}.tar", key.as_str()));
        if src == dst {
            return Ok(dst);
        }
        fs::rename(src, &dst)
            .or_else(|_| fs::copy(src, &dst).map(|_| ()))
            .map_err(|e| format!("move {} -> {}: {e}", src.display(), dst.display()))?;
        Ok(dst)
    }

    /// §4.1: prune layers older than `gc_max_age` AND beyond the per-arch
    /// ceiling (oldest mtime first). Returns a [`GcReport`].
    pub fn gc(&self, arch: HostArch) -> Result<GcReport, CacheError> {
        let dir = self.arch_subdir.join(arch.as_str());
        if !dir.exists() {
            return Ok(GcReport::default());
        }
        let now = SystemTime::now();
        let mut entries: Vec<(PathBuf, SystemTime)> = Vec::new();
        for entry in fs::read_dir(&dir)
            .map_err(|e| format!("read {}: {e}", dir.display()))?
            .flatten()
        {
            let path = entry.path();
            if path.extension().and_then(|e| e.to_str()) != Some("tar") {
                continue;
            }
            let mtime = entry
                .metadata()
                .and_then(|m| m.modified())
                .unwrap_or(SystemTime::UNIX_EPOCH);
            entries.push((path, mtime));
        }
        // Sort oldest first.
        entries.sort_by_key(|(_p, t)| *t);

        let mut evicted = 0usize;

        // Age-based pruning.
        for (path, mtime) in &entries {
            let age = now.duration_since(*mtime).unwrap_or(Duration::ZERO);
            if age > self.gc_max_age && fs::remove_file(path).is_ok() {
                evicted += 1;
            }
        }

        // Count-based pruning (after age pruning, in case both apply).
        let surviving: Vec<&(PathBuf, SystemTime)> =
            entries.iter().filter(|(p, _)| p.exists()).collect();
        if surviving.len() > self.gc_per_arch_ceiling {
            let to_evict = surviving.len() - self.gc_per_arch_ceiling;
            for (path, _) in surviving.iter().take(to_evict) {
                if fs::remove_file(path).is_ok() {
                    evicted += 1;
                }
            }
        }

        Ok(GcReport {
            arch_dir: dir,
            evicted,
        })
    }
}

/// Outcome of a [`Cache::gc`] call.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct GcReport {
    pub arch_dir: PathBuf,
    pub evicted: usize,
}

/// If `src` lives under a directory named after an arch the cache
/// recognises, return that arch string. Otherwise the cache treats it
/// as `any`. This lets executors emit their layer tars wherever they
/// want and the cache files them correctly.
fn arch_from_source_path(src: &Path) -> Option<&'static str> {
    let parent_name = src.parent()?.file_name()?.to_str()?;
    match parent_name {
        "x86_64" => Some("x86_64"),
        "aarch64" => Some("aarch64"),
        _ => None,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::materialize::layer_key::{LayerKey, layer_key};
    use crate::recipe::Instruction;
    use std::io::Write;

    fn touch(path: &Path) {
        fs::create_dir_all(path.parent().unwrap()).unwrap();
        let mut f = fs::File::create(path).unwrap();
        f.write_all(b"x").unwrap();
    }

    fn dummy_key(seed: &str) -> LayerKey {
        layer_key(
            None,
            &Instruction::Run {
                script: seed.into(),
            },
            HostArch::X86_64,
        )
    }

    #[test]
    fn open_creates_recipe_cache_dir() {
        let tmp = tempfile::tempdir().unwrap();
        let _ = Cache::open(tmp.path().to_path_buf()).unwrap();
        assert!(tmp.path().join("recipe-cache").is_dir());
    }

    #[test]
    fn store_and_lookup_roundtrip() {
        let tmp = tempfile::tempdir().unwrap();
        let cache = Cache::open(tmp.path().to_path_buf()).unwrap();
        let src = tmp.path().join("x86_64").join("scratch.tar");
        touch(&src);
        let key = dummy_key("layer1");
        let dst = cache.store(&key, &src).unwrap();
        assert!(dst.exists());
        assert_eq!(cache.lookup(&key).as_deref(), Some(dst.as_path()));
    }

    #[test]
    fn lookup_misses_when_key_not_present() {
        let tmp = tempfile::tempdir().unwrap();
        let cache = Cache::open(tmp.path().to_path_buf()).unwrap();
        assert!(cache.lookup(&dummy_key("absent")).is_none());
    }

    #[test]
    fn gc_evicts_beyond_per_arch_ceiling() {
        let tmp = tempfile::tempdir().unwrap();
        let cache = Cache::open(tmp.path().to_path_buf())
            .unwrap()
            .with_gc(Duration::from_secs(365 * 24 * 60 * 60), 3);
        // Seed 6 layer tars under x86_64.
        for i in 0..6 {
            let key = dummy_key(&format!("seed-{i}"));
            let src = tmp.path().join("x86_64").join(format!("s-{i}.tar"));
            touch(&src);
            cache.store(&key, &src).unwrap();
        }
        let report = cache.gc(HostArch::X86_64).unwrap();
        assert_eq!(report.evicted, 3, "should evict 3 to hit ceiling of 3");
        // Remaining count should equal the ceiling.
        let surviving = fs::read_dir(report.arch_dir).unwrap().count();
        assert_eq!(surviving, 3);
    }

    #[test]
    fn gc_evicts_age_expired_entries() {
        let tmp = tempfile::tempdir().unwrap();
        let cache = Cache::open(tmp.path().to_path_buf())
            .unwrap()
            .with_gc(Duration::from_secs(1), 100);
        let key = dummy_key("ancient");
        let src = tmp.path().join("x86_64").join("ancient.tar");
        touch(&src);
        let stored = cache.store(&key, &src).unwrap();
        // Force a stale mtime: filetime crate not available; instead
        // approximate by sleeping 2s. Acceptable for a test that
        // explicitly exercises age behaviour.
        std::thread::sleep(Duration::from_secs(2));
        let report = cache.gc(HostArch::X86_64).unwrap();
        assert!(
            !stored.exists() || report.evicted >= 1,
            "ancient entry should be evicted"
        );
    }

    #[test]
    fn gc_on_missing_arch_dir_is_a_noop() {
        let tmp = tempfile::tempdir().unwrap();
        let cache = Cache::open(tmp.path().to_path_buf()).unwrap();
        let report = cache.gc(HostArch::Aarch64).unwrap();
        assert_eq!(report.evicted, 0);
    }
}
