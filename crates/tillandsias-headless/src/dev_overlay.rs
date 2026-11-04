//! ORDER 1991-dovl: a development overlay over the compiled-in studio
//! tables, so a node class, a model pin or a folder mapping takes effect on
//! the next tool call without rebuilding the tray.
//!
//! Operator (first-hand, lenovinha session 2026-11-04): "Yes, dev builds only".
//!
//! - DEVELOPMENT BUILDS ONLY: [`enabled`] is `cfg!(debug_assertions)`, so a
//!   release build never reads the overlay (it is compiled to `false`).
//! - `~/.tillandsias/dev-overlay/`: `node-classes.tsv` and `models.tsv` rows
//!   are APPENDED to the compiled tables; `extra_model_paths.yaml` REPLACES
//!   the compiled folder map. Nothing else is read.
//! - It can never admit a licence by itself: a model runs only when the
//!   compiled-in licence register admits it (the register is not overlaid),
//!   and a node class of a package custom-nodes.toml does not pin still admits
//!   nothing. It touches no hardening (no run argument is read from it).
//! - [`active_entries`] names every active file, for the tray's startup
//!   warning, so an overlay is made durable (committed) and deleted.
//!
//! @trace order:1991-dovl
// Its readers are the studio tools and the tray (host-services and tray builds).
#![cfg_attr(
    not(all(feature = "host-services", feature = "tray")),
    allow(dead_code)
)]

use std::path::PathBuf;

/// The overlay files this reads (nothing else in the directory is used).
pub const NODE_CLASSES: &str = "node-classes.tsv";
pub const MODELS: &str = "models.tsv";
pub const MODEL_PATHS: &str = "extra_model_paths.yaml";

/// Whether this build reads the overlay at all: development builds only.
pub const fn enabled() -> bool {
    cfg!(debug_assertions)
}

#[cfg(test)]
thread_local! {
    static TEST_DIR: std::cell::RefCell<Option<PathBuf>> = const { std::cell::RefCell::new(None) };
}

/// Tests point the overlay at a scratch dir for this thread only.
#[cfg(test)]
pub fn set_test_dir(dir: Option<PathBuf>) {
    TEST_DIR.with(|d| *d.borrow_mut() = dir);
}

/// `~/.tillandsias/dev-overlay`.
pub fn dir() -> Option<PathBuf> {
    #[cfg(test)]
    if let Some(d) = TEST_DIR.with(|d| d.borrow().clone()) {
        return Some(d);
    }
    #[cfg(test)]
    return None;
    #[cfg(not(test))]
    std::env::var_os("HOME").map(|h| PathBuf::from(h).join(".tillandsias").join("dev-overlay"))
}

/// The overlay file `name`, when this build reads overlays and it exists.
pub fn read(name: &str) -> Option<String> {
    read_if(enabled(), name)
}

/// [`read`] with the build switch explicit, so a test can show a release
/// build (`false`) ignores a present overlay.
pub fn read_if(enabled: bool, name: &str) -> Option<String> {
    if !enabled {
        return None;
    }
    std::fs::read_to_string(dir()?.join(name))
        .ok()
        .filter(|s| !s.trim().is_empty())
}

/// The compiled `base` table with the overlay's rows appended.
pub fn append(base: &str, overlay: Option<String>) -> String {
    match overlay {
        Some(o) => format!("{base}\n# --- dev overlay (1991-dovl) ---\n{o}\n"),
        None => base.to_string(),
    }
}

/// The active overlay files (for the startup warning); empty in a release.
pub fn active_entries() -> Vec<String> {
    [NODE_CLASSES, MODELS, MODEL_PATHS]
        .iter()
        .filter_map(|n| {
            read(n).map(|s| {
                let rows = s
                    .lines()
                    .filter(|l| !l.trim().is_empty() && !l.trim_start().starts_with('#'))
                    .count();
                format!("{n} ({rows} line(s))")
            })
        })
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_release_build_ignores_a_present_overlay() {
        let d = tempfile::tempdir_in(std::env::current_exe().unwrap().parent().unwrap()).unwrap();
        std::fs::write(d.path().join(NODE_CLASSES), "comfyui-core\tSomeNode\n").unwrap();
        set_test_dir(Some(d.path().to_path_buf()));
        let dev = read_if(true, NODE_CLASSES);
        let release = read_if(false, NODE_CLASSES);
        set_test_dir(None);
        assert!(dev.is_some());
        assert_eq!(release, None, "a release build never reads the overlay");
    }
}
