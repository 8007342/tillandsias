// @trace order:815-gdjk, spec:cross-platform
//! The ONE cache-root resolution.
//!
//! The project decided this long ago — `${XDG_CACHE_HOME:-$HOME/.cache}` is
//! spelled by 29 shell sites, `init_cache_dir()`, and the forge gitconfig
//! resolver — but six Rust sites read `$HOME` directly and appended `.cache`,
//! so a host that sets `XDG_CACHE_HOME` split its cache in two. MEASURED on
//! lenovinha 2026-08-23 before the fix: with the variable set, the accel
//! probe wrote `capabilities.json` under `$HOME/.cache/tillandsias` while
//! every shell consumer resolved under `$XDG_CACHE_HOME/tillandsias`.
//!
//! Everything cache-shaped resolves through [`cache_root`]. The pure half
//! ([`cache_root_from`]) is the unit-tested contract; the env wrapper stays
//! one line so there is nothing in it to get wrong.

use std::path::PathBuf;

/// `<cache-base>/tillandsias`, where cache-base is `$XDG_CACHE_HOME`, else
/// `$HOME/.cache` (or `%USERPROFILE%\.cache` — the pre-existing Windows
/// spelling in the packages cache), else the system temp dir. Resolution
/// only: no directory is created and no writability is probed — callers with
/// stronger needs (init_cache_dir's writable-candidate walk) layer them on
/// top of the same ordering.
pub fn cache_root() -> PathBuf {
    cache_root_from(
        std::env::var_os("XDG_CACHE_HOME").map(PathBuf::from),
        std::env::var_os("HOME")
            .or_else(|| std::env::var_os("USERPROFILE"))
            .map(PathBuf::from),
    )
}

/// The pure resolution, in the project's decided order.
pub fn cache_root_from(xdg_cache_home: Option<PathBuf>, home: Option<PathBuf>) -> PathBuf {
    if let Some(xdg) = xdg_cache_home.filter(|p| !p.as_os_str().is_empty()) {
        return xdg.join("tillandsias");
    }
    if let Some(home) = home.filter(|p| !p.as_os_str().is_empty()) {
        return home.join(".cache").join("tillandsias");
    }
    std::env::temp_dir().join("tillandsias")
}

/// Adopt a pre-XDG cache directory instead of orphaning it (order 815-gdjk:
/// "the model-cache move handled rather than orphaning an existing
/// download" — 1.5 GB on the CPU tier today, tens of GB once the GPU tier
/// pulls larger models).
///
/// Returns the directory the caller should USE:
/// * paths equal (the unset-XDG common case) → `new`;
/// * only the legacy dir exists → try a rename; if the rename cannot move it
///   (cross-device, permissions) KEEP USING the legacy dir and say so — a
///   working cache in the old place beats a silent re-download to the new;
/// * both exist → `new` wins, loudly, so the split is visible and an operator
///   can merge or delete the remainder deliberately.
pub fn adopt_legacy_cache(legacy: &std::path::Path, new: &std::path::Path) -> PathBuf {
    if legacy == new || !legacy.exists() {
        return new.to_path_buf();
    }
    if !new.exists() {
        if let Some(parent) = new.parent() {
            let _ = std::fs::create_dir_all(parent);
        }
        match std::fs::rename(legacy, new) {
            Ok(()) => return new.to_path_buf(),
            Err(e) => {
                eprintln!(
                    "[tillandsias] cache adoption: could not move {} -> {} ({e}); continuing to use the legacy path",
                    legacy.display(),
                    new.display()
                );
                return legacy.to_path_buf();
            }
        }
    }
    eprintln!(
        "[tillandsias] cache adoption: both {} and {} exist; using the XDG-resolved path — merge or remove the legacy dir deliberately",
        legacy.display(),
        new.display()
    );
    new.to_path_buf()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn xdg_wins_home_falls_back_temp_is_last() {
        let root = cache_root_from(Some(PathBuf::from("/x")), Some(PathBuf::from("/h")));
        assert_eq!(root, PathBuf::from("/x/tillandsias"));
        let root = cache_root_from(None, Some(PathBuf::from("/h")));
        assert_eq!(root, PathBuf::from("/h/.cache/tillandsias"));
        let root = cache_root_from(Some(PathBuf::new()), Some(PathBuf::from("/h")));
        assert_eq!(
            root,
            PathBuf::from("/h/.cache/tillandsias"),
            "an EMPTY XDG_CACHE_HOME is unset, not a root at cwd"
        );
        assert!(cache_root_from(None, None).ends_with("tillandsias"));
    }

    #[test]
    fn adoption_moves_a_lone_legacy_and_keeps_it_on_failure_paths() {
        let t = tempfile_dir();
        let legacy = t.join("old/models");
        let new = t.join("xdg/models");
        std::fs::create_dir_all(&legacy).unwrap();
        std::fs::write(legacy.join("model.bin"), b"weights").unwrap();

        let chosen = adopt_legacy_cache(&legacy, &new);
        assert_eq!(chosen, new, "a lone legacy dir is moved to the new root");
        assert!(new.join("model.bin").exists(), "the download came along");
        assert!(!legacy.exists(), "nothing was left to re-download into");

        // Second run: idempotent (legacy gone, new exists).
        assert_eq!(adopt_legacy_cache(&legacy, &new), new);

        // Both exist: new wins, legacy untouched (operator merges).
        std::fs::create_dir_all(&legacy).unwrap();
        std::fs::write(legacy.join("stale.bin"), b"x").unwrap();
        assert_eq!(adopt_legacy_cache(&legacy, &new), new);
        assert!(legacy.join("stale.bin").exists(), "never silently deleted");

        std::fs::remove_dir_all(&t).ok();
    }

    #[test]
    fn adoption_equal_paths_is_a_no_op() {
        let p = PathBuf::from("/same/models");
        assert_eq!(adopt_legacy_cache(&p, &p), p);
    }

    fn tempfile_dir() -> PathBuf {
        let d = std::env::temp_dir().join(format!(
            "tillandsias-cache-root-test-{}",
            std::process::id()
        ));
        std::fs::create_dir_all(&d).unwrap();
        d
    }
}
