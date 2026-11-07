//! ORDER 1975-istp: a per-image success stamp, so a warm launch whose images
//! are all current spends no detached ensure helper and no source hashing.
//!
//! Measured on yoga (1968-psy9, 2026-11-03): every warm launch paid ~250-300 ms
//! per image outside podman (helper detach + source hashing) even when nothing
//! needed building, about 1.5 s across five images.
//!
//! The stamp is written after an ensure succeeds and records the embedded
//! assets digest (the binary's compiled-in image sources, so every source and
//! build arg is a function of it), the tag, and the image id. It is current
//! only when all three still match: the same binary assets, the same tag, and
//! podman still holding that exact image id under the tag. Anything else
//! (another binary, a removed or rebuilt image, a developer checkout via
//! TILLANDSIAS_ROOT, a forced retry) takes the full ensure path.
//! @trace order:1975-istp (related: 1920-lnch, 1968-psy9)

use std::path::{Path, PathBuf};

/// The stamp directory under the init cache dir.
pub const STAMP_DIR: &str = "image-ok";

/// What a stamp must match.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Key {
    pub image: String,
    pub tag: String,
    /// The embedded assets digest of this binary.
    pub assets: String,
}

fn stamp_path(dir: &Path, image: &str) -> PathBuf {
    dir.join(format!("{image}.ok"))
}

fn render(key: &Key, image_id: &str) -> String {
    format!("{}\n{}\n{}\n", key.assets, key.tag, image_id)
}

/// Whether `key`'s image is current by its stamp. `image_id` reads the id
/// podman holds under a tag (one `podman image inspect`); it is asked only
/// when the stamp's assets and tag already match.
pub fn is_current(dir: &Path, key: &Key, image_id: &dyn Fn(&str) -> Option<String>) -> bool {
    let Ok(text) = std::fs::read_to_string(stamp_path(dir, &key.image)) else {
        return false;
    };
    let mut lines = text.lines();
    let (Some(assets), Some(tag), Some(id)) = (lines.next(), lines.next(), lines.next()) else {
        return false;
    };
    if assets != key.assets || tag != key.tag || id.is_empty() {
        return false;
    }
    image_id(&key.tag).is_some_and(|held| held == id)
}

/// Record a successful ensure. Best effort: a stamp that cannot be written
/// only costs the next launch the full path.
pub fn record(dir: &Path, key: &Key, image_id: &str) {
    if image_id.trim().is_empty() || std::fs::create_dir_all(dir).is_err() {
        return;
    }
    let path = stamp_path(dir, &key.image);
    let tmp = path.with_extension("ok.tmp");
    if std::fs::write(&tmp, render(key, image_id.trim())).is_ok() {
        let _ = std::fs::rename(&tmp, &path);
    }
}

/// Drop a stamp (an ensure that failed or is being forced).
pub fn clear(dir: &Path, image: &str) {
    let _ = std::fs::remove_file(stamp_path(dir, image));
}

/// How `ensure_image_exists` proceeds for one image.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Route {
    /// The stamp says current: no helper, no hashing, no lock.
    Current,
    /// Spawn the session-surviving helper (order 270).
    Detach,
    /// Run the locked identity/decision/build path in this process.
    InProcess,
}

/// The route: a current stamp wins before the detach decision is asked.
pub fn route(stamp_current: bool, detach: bool) -> Route {
    if stamp_current {
        Route::Current
    } else if detach {
        Route::Detach
    } else {
        Route::InProcess
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn key() -> Key {
        Key {
            image: "forge".into(),
            tag: "tillandsias-forge:v1".into(),
            assets: "a1".into(),
        }
    }

    /// 1975-istp: a warm launch with every image current takes no helper.
    /// Pre-fix: FAILS, every ensure detached a helper (route did not exist;
    /// the parent always asked image_build_detach_decision first).
    #[test]
    fn a_current_image_spawns_no_ensure_helper() {
        let dir = tempfile::tempdir_in(std::env::current_exe().unwrap().parent().unwrap()).unwrap();
        let held = |_: &str| Some("sha256:abc".to_string());
        assert!(!is_current(dir.path(), &key(), &held), "no stamp yet");
        assert_eq!(route(false, true), Route::Detach, "cold: the helper runs");
        record(dir.path(), &key(), "sha256:abc");
        assert!(is_current(dir.path(), &key(), &held));
        assert_eq!(route(true, true), Route::Current, "warm: no helper");
    }

    /// Anything that could make the image stale takes the full path.
    #[test]
    fn a_stamp_is_current_only_for_the_same_assets_tag_and_image_id() {
        let dir = tempfile::tempdir_in(std::env::current_exe().unwrap().parent().unwrap()).unwrap();
        record(dir.path(), &key(), "sha256:abc");
        let held = |_: &str| Some("sha256:abc".to_string());
        let other_binary = Key {
            assets: "a2".into(),
            ..key()
        };
        assert!(!is_current(dir.path(), &other_binary, &held));
        let other_tag = Key {
            tag: "tillandsias-forge:v2".into(),
            ..key()
        };
        assert!(!is_current(dir.path(), &other_tag, &held));
        assert!(!is_current(dir.path(), &key(), &|_| None), "image removed");
        assert!(
            !is_current(dir.path(), &key(), &|_| Some("sha256:new".into())),
            "rebuilt under the tag"
        );
        clear(dir.path(), "forge");
        assert!(!is_current(dir.path(), &key(), &held));
        record(dir.path(), &key(), "  ");
        assert!(!is_current(dir.path(), &key(), &held), "no id, no stamp");
    }
}
