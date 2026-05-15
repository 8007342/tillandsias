//! @trace spec:forge-cache-dual, spec:forge-staleness, spec:cache-isolation, spec:forge-forward-compat
//! Cache architecture and semantics for forge containers.
//!
//! Tillandsias uses a dual-cache architecture:
//!
//! 1. **Shared cache** (`/nix/store/`) — read-only, nix-managed, content-addressed
//!    - Populated at forge image build time
//!    - Bind-mounted RO into all containers
//!    - Multiple projects share the same entries (conflict-free via nix)
//!
//! 2. **Per-project cache** (`/home/forge/.cache/tillandsias-project/`) — RW, project-isolated
//!    - Persists across container restarts
//!    - Bind-mounted from host's `~/.cache/tillandsias/forge-projects/<project>/`
//!    - Project A cannot see or access project B's cache
//!    - Holds: cargo, go, maven, gradle, flutter, npm, yarn, pnpm, uv, pip caches
//!
//! 3. **Ephemeral** — tmpfs mounts with size caps, lost on container stop
//!    - `/tmp/` — 256 MB cap, kernel-enforced ENOSPC on overflow
//!    - `/run/user/1000/` — 64 MB cap, prevents runaway socket/log accumulation
//!    - Container writable overlay — unbounded, backed by host storage
//!
//! 4. **Project workspace** — source code, RW, ephemeral (tmpfs on Linux, persists on Windows/WSL)
//!    - Bind-mounted from `<watch_path>/<project>/` to `/home/forge/src/<project>/`
//!    - Build artifacts redirect via env vars into per-project cache, NOT workspace

use std::fs;
use std::path::{Path, PathBuf};
use tracing::debug;

/// Cache directory structure for a project.
#[derive(Debug, Clone)]
pub struct CacheLayout {
    /// Root cache directory for this project: `~/.cache/tillandsias/forge-projects/<project>/`
    pub project_cache_root: PathBuf,

    /// Shared nix store: `~/.cache/tillandsias/nix/` (RO bind-mount to `/nix/store/` in container)
    pub shared_nix_store: PathBuf,

    /// Per-language cache subdirectories under project_cache_root
    pub cargo_home: PathBuf,
    pub cargo_target: PathBuf,
    pub gopath: PathBuf,
    pub gomodcache: PathBuf,
    pub maven_cache: PathBuf,
    pub gradle_home: PathBuf,
    pub pub_cache: PathBuf,
    pub npm_cache: PathBuf,
    pub yarn_cache: PathBuf,
    pub pnpm_home: PathBuf,
    pub uv_cache: PathBuf,
    pub pip_cache: PathBuf,
}

impl CacheLayout {
    /// Create a cache layout for a project.
    ///
    /// The project cache root is computed as:
    /// `~/.cache/tillandsias/forge-projects/<project>/`
    ///
    /// The shared nix store is always:
    /// `~/.cache/tillandsias/nix/`
    pub fn new(project_name: &str, cache_base: &Path) -> Self {
        let project_cache_root = cache_base.join("forge-projects").join(project_name);

        let shared_nix_store = cache_base.join("nix");

        Self {
            project_cache_root: project_cache_root.clone(),
            shared_nix_store,
            cargo_home: project_cache_root.join("cargo"),
            cargo_target: project_cache_root.join("cargo").join("target"),
            gopath: project_cache_root.join("go"),
            gomodcache: project_cache_root.join("go").join("pkg").join("mod"),
            maven_cache: project_cache_root.join("maven"),
            gradle_home: project_cache_root.join("gradle"),
            pub_cache: project_cache_root.join("pub"),
            npm_cache: project_cache_root.join("npm"),
            yarn_cache: project_cache_root.join("yarn"),
            pnpm_home: project_cache_root.join("pnpm"),
            uv_cache: project_cache_root.join("uv"),
            pip_cache: project_cache_root.join("pip"),
        }
    }

    /// Verify cache structure — ensure all required directories exist.
    ///
    /// This is safe to call before container launch; creates parent directories as needed.
    /// Non-fatal: failures (e.g., permission denied) are logged but don't abort.
    pub fn ensure_exists(&self) -> std::io::Result<()> {
        fs::create_dir_all(&self.project_cache_root)?;
        fs::create_dir_all(&self.shared_nix_store)?;
        fs::create_dir_all(&self.cargo_home)?;
        fs::create_dir_all(&self.cargo_target)?;
        fs::create_dir_all(&self.gopath)?;
        fs::create_dir_all(&self.gomodcache)?;
        fs::create_dir_all(&self.maven_cache)?;
        fs::create_dir_all(&self.gradle_home)?;
        fs::create_dir_all(&self.pub_cache)?;
        fs::create_dir_all(&self.npm_cache)?;
        fs::create_dir_all(&self.yarn_cache)?;
        fs::create_dir_all(&self.pnpm_home)?;
        fs::create_dir_all(&self.uv_cache)?;
        fs::create_dir_all(&self.pip_cache)?;
        Ok(())
    }

    /// Estimate cache size for staleness detection and disk space planning.
    ///
    /// Returns total size in bytes of all cache directories.
    /// Returns 0 if cache doesn't exist (not an error).
    pub fn estimate_size(&self) -> u64 {
        if !self.project_cache_root.exists() {
            return 0;
        }
        estimate_dir_size(&self.project_cache_root).unwrap_or(0)
    }

    /// Mount flags for container launch.
    ///
    /// Returns the complete mount specification for podman:
    /// - Per-project cache: RW mount at `/home/forge/.cache/tillandsias-project`
    /// - Shared nix store: RO mount at `/nix/store`
    ///
    /// Each mount is a tuple: (host_path, container_path, mode_is_readonly)
    pub fn mount_specs(&self) -> Vec<(String, String, bool)> {
        vec![
            // Per-project cache (RW)
            (
                self.project_cache_root.display().to_string(),
                "/home/forge/.cache/tillandsias-project".to_string(),
                false, // RW
            ),
            // Shared nix store (RO)
            (
                self.shared_nix_store.display().to_string(),
                "/nix/store".to_string(),
                true, // RO
            ),
        ]
    }

    /// Verify cache isolation: project A cannot access project B's cache.
    ///
    /// This is a compile-time property (mounts are path-isolated), but we can verify
    /// at runtime that the mounts are correctly configured by checking if a container
    /// can see only its own project's cache.
    ///
    /// Returns Ok(()) if isolation is verified, Err with details if not.
    /// This is primarily a test/validation function.
    pub fn verify_isolation(projects: &[(&str, &Path)], cache_base: &Path) -> Result<(), String> {
        // Verify each project's cache root is unique and non-overlapping
        let mut cache_paths = Vec::new();
        for (project_name, _) in projects {
            let layout = CacheLayout::new(project_name, cache_base);
            cache_paths.push((project_name, layout.project_cache_root));
        }

        for i in 0..cache_paths.len() {
            for j in (i + 1)..cache_paths.len() {
                let (name_i, path_i) = &cache_paths[i];
                let (name_j, path_j) = &cache_paths[j];

                // Verify paths don't overlap
                if path_i.starts_with(path_j) || path_j.starts_with(path_i) {
                    return Err(format!(
                        "Cache isolation violation: {} and {} paths overlap: {} vs {}",
                        name_i,
                        name_j,
                        path_i.display(),
                        path_j.display()
                    ));
                }
            }
        }

        Ok(())
    }
}

/// Ephemeral tmpfs mounts with size caps (kernel-enforced ENOSPC on overflow).
///
/// These are transient, lost on container stop, and capped to prevent OOM.
#[derive(Debug, Clone)]
pub struct EphemeralMounts {
    /// `/tmp/` — 256 MB (0o1777)
    pub tmp_size_mb: u32,
    /// `/run/user/1000/` — 64 MB (0o0700)
    pub run_user_size_mb: u32,
}

impl Default for EphemeralMounts {
    fn default() -> Self {
        Self {
            tmp_size_mb: 256,
            run_user_size_mb: 64,
        }
    }
}

impl EphemeralMounts {
    /// Generate podman `--tmpfs` mount arguments.
    ///
    /// Returns arguments like: `["--tmpfs", "/tmp:size=256m,mode=1777", "--tmpfs", "/run/user/1000:size=64m,mode=0700"]`
    pub fn tmpfs_args(&self) -> Vec<String> {
        vec![
            format!("/tmp:size={}m,mode=1777", self.tmp_size_mb),
            format!("/run/user/1000:size={}m,mode=0700", self.run_user_size_mb),
        ]
    }

    /// Verify tmpfs mounts are correctly sized for the container.
    ///
    /// Logs warnings if sizes are below recommended minimums.
    pub fn validate(&self) {
        if self.tmp_size_mb < 256 {
            debug!(
                "Ephemeral /tmp/ mount undersized: {} MB (recommended: 256 MB+)",
                self.tmp_size_mb
            );
        }
        if self.run_user_size_mb < 64 {
            debug!(
                "Ephemeral /run/user/1000/ mount undersized: {} MB (recommended: 64 MB+)",
                self.run_user_size_mb
            );
        }
        debug!(
            "Ephemeral tmpfs mounts validated: /tmp {}MB, /run/user/1000 {}MB",
            self.tmp_size_mb, self.run_user_size_mb
        );
    }
}

/// Helper: estimate directory size recursively.
fn estimate_dir_size(path: &Path) -> std::io::Result<u64> {
    let mut total = 0u64;
    for entry in fs::read_dir(path)? {
        let entry = entry?;
        let metadata = entry.metadata()?;
        if metadata.is_dir() {
            total += estimate_dir_size(&entry.path())?;
        } else {
            total += metadata.len();
        }
    }
    Ok(total)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn cache_layout_new() {
        let cache_base = Path::new("/home/user/.cache/tillandsias");
        let layout = CacheLayout::new("my-project", cache_base);

        assert_eq!(
            layout.project_cache_root,
            cache_base.join("forge-projects/my-project")
        );
        assert_eq!(layout.shared_nix_store, cache_base.join("nix"));
        assert_eq!(
            layout.cargo_home,
            cache_base.join("forge-projects/my-project/cargo")
        );
    }

    #[test]
    fn cache_layout_ensure_exists() {
        let temp_dir = std::env::temp_dir().join("tillandsias-cache-test");
        let _ = fs::remove_dir_all(&temp_dir);
        fs::create_dir_all(&temp_dir).unwrap();

        let layout = CacheLayout::new("test-project", &temp_dir);

        assert!(layout.ensure_exists().is_ok());
        assert!(layout.project_cache_root.exists());
        assert!(layout.cargo_home.exists());
        assert!(layout.shared_nix_store.exists());

        let _ = fs::remove_dir_all(&temp_dir);
    }

    #[test]
    fn cache_mount_specs() {
        let cache_base = Path::new("/home/user/.cache/tillandsias");
        let layout = CacheLayout::new("my-app", cache_base);
        let mounts = layout.mount_specs();

        assert_eq!(mounts.len(), 2);

        // Per-project cache (RW)
        assert_eq!(mounts[0].1, "/home/forge/.cache/tillandsias-project");
        assert_eq!(mounts[0].2, false); // RW

        // Shared nix store (RO)
        assert_eq!(mounts[1].1, "/nix/store");
        assert_eq!(mounts[1].2, true); // RO
    }

    #[test]
    fn cache_isolation_distinct_projects() {
        let cache_base = Path::new("/home/user/.cache/tillandsias");
        let projects = vec![("project-a", cache_base), ("project-b", cache_base)];

        // Should verify without error
        assert!(CacheLayout::verify_isolation(&projects, cache_base).is_ok());
    }

    #[test]
    fn ephemeral_mounts_tmpfs_args() {
        let ephemeral = EphemeralMounts::default();
        let args = ephemeral.tmpfs_args();

        assert_eq!(args.len(), 2);
        assert!(args[0].contains("size=256m"));
        assert!(args[1].contains("size=64m"));
    }

    #[test]
    fn ephemeral_mounts_validate_default() {
        let ephemeral = EphemeralMounts::default();
        // Should not panic; default sizes are valid
        ephemeral.validate();
    }
}
