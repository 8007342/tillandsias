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
/// The raw template line, before expansion — the manifest as authored.
fn ca_template() -> &'static str {
    CA_PATH_MANIFEST
        .lines()
        .map(str::trim)
        .find(|l| !l.is_empty() && !l.starts_with('#'))
        .expect("images/default/ca-path.txt declares no path")
}

/// The enclave CA bundle directory, with `` expanded.
///
/// ORDER 998-3z6g made the manifest a TEMPLATE, because no static path serves
/// both lanes: /var/lib works in the macOS guest precisely because it runs as
/// root, and is unwritable on a rootless Linux host for the same reason;
/// /tmp works everywhere and is the bug. See the manifest for the two
/// measurements.
///
/// EXPANSION MUST MATCH scripts/lib-ca-path.sh exactly. A template with two
/// expanders is a new way for one declaration to mean two things — the defect
/// this file exists to remove. A test pins the agreement.
pub fn ca_dir() -> String {
    let home = std::env::var("HOME").unwrap_or_default();
    ca_template().replace("${HOME}", &home)
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
        // SAFETY: single-threaded test; HOME is restored by the process exit.
        unsafe { std::env::set_var("HOME", "/home/probe") };
        let d = ca_dir();
        assert!(d.starts_with('/'), "CA dir must be absolute, got {d:?}");
        assert!(
            !d.ends_with('/'),
            "CA dir must not end in a slash — callers join onto it, and a \
             trailing slash yields a double separator in bind-mount specs"
        );
    }
}

#[cfg(test)]
mod expansion_tests {
    use super::*;

    /// THE TEMPLATE MUST ACTUALLY EXPAND. A manifest that still contained a
    /// literal `${HOME}` after expansion would produce a directory called
    /// `${HOME}` — created silently, durable, and wrong, on whatever cwd the
    /// process happened to have.
    #[test]
    fn expansion_leaves_no_placeholder() {
        unsafe { std::env::set_var("HOME", "/home/probe") };
        let d = ca_dir();
        assert!(
            !d.contains("${"),
            "unexpanded placeholder survived into the path: {d:?}"
        );
        assert!(
            d.starts_with("/home/probe/"),
            "HOME was not substituted: {d:?}"
        );
    }

    /// RUST AND SHELL MUST AGREE. Two expanders over one template is a new way
    /// for a single declaration to mean two things — precisely the defect
    /// 998-qrwu removed, and exactly what making it a template risks
    /// reintroducing. Asserted against the real shell reader rather than a
    /// reimplementation of it, because a second implementation of the
    /// comparison would have the same failure mode as a second declaration.
    #[test]
    fn rust_and_shell_expand_to_the_same_path() {
        let home = "/home/agreement-probe";
        unsafe { std::env::set_var("HOME", home) };
        let rust = ca_dir();

        let root = concat!(env!("CARGO_MANIFEST_DIR"), "/../..");
        let out = std::process::Command::new("bash")
            .arg("-c")
            .arg(". \"$0/scripts/lib-ca-path.sh\"; printf %s \"$TILLANDSIAS_CA_DIR\"")
            .arg(root)
            .env("HOME", home)
            .env_remove("TILLANDSIAS_CA_DIR")
            .output()
            .expect("run the shell reader");
        let shell = String::from_utf8_lossy(&out.stdout).to_string();

        assert_eq!(
            rust, shell,
            "Rust and shell disagree about the CA directory — one declaration, \
             two meanings, which is the defect the single-sourcing removed"
        );
    }
}
