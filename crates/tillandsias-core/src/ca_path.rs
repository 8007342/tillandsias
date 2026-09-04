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
    expand_home(&ca_dir_template_owned(), &home)
}

/// The CA directory as a TEMPLATE: the declared root with this consumer's leaf
/// appended, `${HOME}` still unexpanded.
///
/// ORDER 1027-539s. The manifest now declares the ROOT, so composing the leaf
/// is this module's job. Every accessor goes through here rather than each one
/// remembering to append `/ca` — a leaf appended in two places is the same
/// defect one directory down.
fn ca_dir_template_owned() -> String {
    format!("{}/ca", ca_template())
}

/// The substitution itself, over an explicit base.
///
/// SPLIT OUT SO IT CAN BE TESTED WITHOUT MUTATING THE PROCESS (order
/// 1002-9xmb). `HOME` is process-global and cargo runs tests concurrently in
/// one process, so three tests calling `set_var("HOME", ...)` raced: on
/// osx-next at 724691251 the agreement test failed on every full-suite run,
/// reading `/home/probe` — the OTHER test's value — against its own
/// `/home/agreement-probe`. Passing the base in removes the shared mutable
/// state rather than serialising access to it, and removes the `unsafe` the
/// tests needed to reach it.
fn expand_home(template: &str, home: &str) -> String {
    template.replace("${HOME}", home)
}

/// The declared state ROOT with `${HOME}` substituted (1027-539s).
///
/// Exposed so `guest_bin_path` derives its root from the SAME manifest instead
/// of holding a second copy — the N=2 duplication 1027-539s exists to remove.
pub fn state_root_expanded(home: &str) -> String {
    expand_home(ca_template(), home)
}

/// The UNEXPANDED template, for a caller that emits a string to be executed on
/// a DIFFERENT filesystem than the one this process runs on.
///
/// ORDER 1002-9xmb. `ca_dir()` substitutes the CALLING process's `HOME`, which
/// is right for a caller that will itself touch the directory and wrong for one
/// that is composing a shell command for somewhere else. The macOS tray is the
/// second kind: its proxy preamble runs IN THE GUEST, where it sets
/// `HOME=/root`, but the path was being expanded on the host — so a Mac emitted
/// `/Users/<you>/.local/state/tillandsias/ca` for the guest to create.
///
/// MEASURED IN A LIVE GUEST 2026-09-04: that wrong path SUCCEEDS. mkdir -p as
/// root creates it, openssl writes into it, perms 600, owner root, exit 0. So
/// nothing fails, nothing logs, and the CA simply lives in a directory named
/// after the host user, at a path that differs per developer. A silent success
/// is why this needs a distinct accessor rather than a comment telling callers
/// to be careful.
///
/// The RECEIVING shell is the expander here. That is a third expander only in
/// appearance: it is the only one standing in the filesystem the path names.
///
/// ORDER 1027-539s: this now COMPOSES the leaf. The manifest declares the ROOT,
/// so returning `ca_template()` raw would hand callers `${HOME}/.local/state/
/// tillandsias` where they mean the CA directory — and the guest would create
/// it and write intermediate.key there, succeeding exactly as the 1002-9xmb bug
/// above succeeded. Pinned by `template_composes_the_ca_leaf`.
pub fn ca_dir_template() -> String {
    ca_dir_template_owned()
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
        let d = expand_home(ca_template(), "/home/probe");
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
        let d = expand_home(ca_template(), "/home/probe");
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
        // 1027-539s: compare the COMPOSED CA directory, not the bare root. The
        // manifest declares the root and each runtime appends its own leaf, so
        // the agreement this test exists to prove now covers COMPOSITION as
        // well as expansion — two ways for one declaration to mean two things
        // instead of one.
        let rust = expand_home(&ca_dir_template(), home);

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

#[cfg(test)]
mod root_composition_tests {
    use super::*;

    /// THE MANIFEST DECLARES THE ROOT, NOT THE CA DIRECTORY (1027-539s).
    #[test]
    fn manifest_declares_the_root_not_the_leaf() {
        assert!(
            !ca_template().ends_with("/ca"),
            "the manifest value must be the ROOT; a value ending in /ca means \
             someone re-appended the leaf to the declaration and every consumer \
             now doubles it: {:?}",
            ca_template()
        );
    }

    /// THE TEMPLATE ACCESSOR MUST COMPOSE THE LEAF.
    ///
    /// Its callers emit shell for another filesystem (the macOS tray's guest
    /// preamble). Returning the bare root would have them create
    /// `${HOME}/.local/state/tillandsias` and write intermediate.key there — and
    /// in the guest, running as root, that SUCCEEDS: mkdir works, openssl
    /// writes, perms 600, exit 0. Identical shape to the 1002-9xmb bug this
    /// accessor was added to fix, one directory up.
    #[test]
    fn template_composes_the_ca_leaf() {
        let t = ca_dir_template();
        assert!(
            t.ends_with("/ca"),
            "ca_dir_template() must return the CA directory, not the root: {t:?}"
        );
        assert!(
            t.starts_with("${HOME}/"),
            "it must stay UNEXPANDED — the receiving shell is the expander: {t:?}"
        );
    }

    /// NO MIGRATION: the composed CA path is byte-identical to what the manifest
    /// declared before 1027-539s.
    ///
    /// This is the property that let this land alone. 998-3z6g had to MOVE a
    /// directory, which meant recreating every container that had bound the old
    /// path; root + "/ca" reproduces the same string, so nothing rebinds.
    /// Asserted against a literal rather than trusting concatenation.
    #[test]
    fn the_ca_path_is_byte_identical_to_the_pre_split_value() {
        assert_eq!(
            ca_dir_template(),
            "${HOME}/.local/state/tillandsias/ca",
            "the CA directory changed — that is a MIGRATION (containers bind the \
             old path in stored definitions and must be recreated), not a refactor"
        );
        assert_eq!(
            expand_home(&ca_dir_template(), "/home/probe"),
            "/home/probe/.local/state/tillandsias/ca"
        );
    }
}
