//! Order 998-qrwu — the enclave CA bundle directory, declared once.
//!
//! The path lives in `images/default/ca-path.txt` and travels INSIDE the
//! artifact via `include_str!`, the same discipline `tillandsias-plan`'s
//! capability manifest uses: a binary cannot disagree with a file it compiled
//! in. `tillandsias-core` is a dependency of BOTH `tillandsias-headless` and
//! `tillandsias-macos-tray`, which is what lets one declaration serve both.
//!
//! See the file's own header for why this is single-sourced before 975-rsgm
//! moves it: a path written in 38 places moves partially, and the misses fail
//! only on a recovery path.

const CA_PATH_MANIFEST: &str = include_str!("../../../images/default/ca-path.txt");

/// The enclave CA bundle directory.
///
/// Returns the first non-comment, non-empty line of the manifest. Panics only
/// if the manifest is empty, which is a build-time authoring error rather than
/// a runtime condition — a caller has no sensible fallback here, and inventing
/// one would reintroduce exactly the second literal this exists to remove.
pub fn ca_dir() -> &'static str {
    CA_PATH_MANIFEST
        .lines()
        .map(str::trim)
        .find(|l| !l.is_empty() && !l.starts_with('#'))
        .expect("images/default/ca-path.txt declares no path")
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn manifest_declares_exactly_one_path() {
        let entries: Vec<&str> = CA_PATH_MANIFEST
            .lines()
            .map(str::trim)
            .filter(|l| !l.is_empty() && !l.starts_with('#'))
            .collect();
        assert_eq!(
            entries.len(),
            1,
            "ca-path.txt must declare exactly one path; a second would be the \
             drift this file exists to remove"
        );
    }

    #[test]
    fn ca_dir_is_absolute_and_unslashed() {
        let d = ca_dir();
        assert!(d.starts_with('/'), "CA dir must be absolute, got {d:?}");
        assert!(
            !d.ends_with('/'),
            "CA dir must not end in a slash — callers join onto it, and a \
             trailing slash yields a double separator in bind-mount specs"
        );
    }
}
