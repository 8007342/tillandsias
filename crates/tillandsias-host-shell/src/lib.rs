//! Portable host-side logic shared by the Windows and macOS native trays.
//!
//! The Linux tray (zbus/SNI/DBusMenu) keeps its dedicated implementation in
//! `tillandsias-headless`. The Windows (Win32 NotifyIcon) and macOS (AppKit
//! NSStatusItem) trays consume the modules here so the OS-specific bins
//! stay thin: each is a UI shell that delegates project discovery, VM
//! lifecycle, menu modelling, and control-wire communication to this crate.
//!
//! Phase-4 status: the portable modules below are implemented and unit-tested
//! against Linux (the dev box). The OS-specific tray bins wire them up under
//! `#[cfg(target_os = "windows")]` / `#[cfg(target_os = "macos")]` blocks.
//!
//! @trace spec:host-shell-architecture

#![allow(dead_code)]

pub mod lifecycle;

/// Shared tray strings, generated from `locales/en.toml` at build time
/// (792-cf5x, first slice of 628-c7qd).
///
/// Nothing resolves through this module yet — converting call sites is a
/// later slice, and deliberately so: every user-visible byte in the trays
/// must move under the byte-identical rule, and the corpus does not yet
/// agree with what ships (only 9 of 168 keys render verbatim today, which
/// is what 792-77bt exists to fix). The generator ships first so the
/// mechanism is proven and gated before any string moves.
///
/// Runtime locale SELECTION is not here either, and that is a recorded
/// deferral rather than an oversight: shipping all 17 locales embeds
/// ~177 KB into a 3.8 MB binary (+4.8%), which is a product decision, and
/// `locales/` reaches no artifact today. The `en` consts cost ~11 KB and
/// carry the build-time gate on their own.
pub mod locale_strings {
    include!(concat!(env!("OUT_DIR"), "/locale_strings_generated.rs"));
}

/// A corpus that silently collapsed — truncated file, a parse that yielded
/// nothing — must not build. This is a CONST assertion on purpose: it fails
/// at compile time, so an empty string layer is unrepresentable rather than
/// merely detectable by a test someone has to run (792-cf5x).
const _: () = assert!(
    locale_strings::EN_KEY_COUNT > 100,
    "locales/en.toml collapsed: the generated string layer has almost no keys"
);
pub mod menu_action;
pub mod menu_state;
pub mod provisioning;
/// Host-side PTY-over-vsock session multiplexing (control-wire-pty-attach §3),
/// cross-platform core. OS backends (ConPTY / openpty) layer on top.
pub mod pty;
pub mod scanner;
pub mod subscription_health;
pub mod vsock_client;

/// Host shell crate version — returns the workspace release version
/// (e.g. `0.2.260528.1`) baked at build time from the repo-root
/// `VERSION` file by `build.rs`.
///
/// Pre-fix this returned `CARGO_PKG_VERSION` which resolves to
/// `tillandsias-host-shell/Cargo.toml`'s `version = "0.1.0"` —
/// crate versions don't get bumped per release, so callers were
/// silently getting a string that:
///   * mismatched what the user actually installed (`v0.2.260528.1`),
///   * made the WSL/VZ provisioning paths fetch a non-existent
///     `v0.1.0` release artifact, and
///   * made downstream UI surfaces (notably [`crate::menu_state::
///     MenuState`] `version` field) render `v0.1.0 — By Tlatoāni`
///     instead of the workspace version in all three trays.
///
/// Fix from windows-host's `tray-convergence-coordination.md`
/// 2026-05-30T11:00Z ASK block: a `build.rs` reads `../../VERSION`
/// and exposes the value as the `WORKSPACE_VERSION` env var. Callers
/// keep using `version()`; the change is transparent.
///
/// @trace spec:vm-provisioning-lifecycle, spec:tray-app
pub fn version() -> &'static str {
    env!("WORKSPACE_VERSION")
}

#[cfg(test)]
mod locale_strings_tests {
    use super::locale_strings;

    /// 792-cf5x: the generated layer carries the values `en.toml` actually
    /// holds. (Non-emptiness is enforced one level up by a const assertion,
    /// which fails the BUILD rather than a test run.)
    #[test]
    fn generated_layer_carries_the_en_corpus() {
        assert_eq!(locale_strings::APP_NAME, "Tillandsias");
        // A key whose value contains an emoji and a placeholder, to prove the
        // escaper round-trips both.
        assert_eq!(locale_strings::MENU_SIGN_IN_GITHUB, "🔑 GitHub Login");
        assert_eq!(locale_strings::MENU_STATUS_READY_ONE, "{image} OK");
    }

    /// 792-77bt: en.toml describes a UI that does not ship, and that fact
    /// must not be able to change silently in either direction.
    ///
    /// 628-c7qd asks for a BYTE-IDENTICAL refactor resolving every tray
    /// string from en.toml. That is only possible if en.toml already holds
    /// what the trays render — and it does not: the overwhelming majority of
    /// its values appear NOWHERE in any tray source. So the corpus has to be
    /// regenerated FROM the shipped literals; adopting it as written would
    /// restyle the tray wholesale and needs operator sign-off under
    /// spec:tray-ux.
    ///
    /// This asserts the DIRECTION, not an exact count, so ordinary edits do
    /// not churn it — but a real convergence (or a further collapse) trips it
    /// and forces the packet family to be re-read rather than assumed.
    ///
    /// It reads PRODUCTION text only — `//` comments stripped, each file cut
    /// at its first `#[cfg(test)]`. That is not fussiness: the first version
    /// counted comments and test code, so the sibling pin in this very module
    /// (`APP_NAME == "Tillandsias"`) made the corpus look one key closer to
    /// the shipped tray. A measurement that reads its own assertions is not a
    /// measurement.
    #[test]
    fn en_corpus_does_not_describe_the_shipped_tray() {
        let root = std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("../..");
        let en = std::fs::read_to_string(root.join("locales/en.toml"))
            .expect("locales/en.toml must be readable");

        let mut haystack = String::new();
        for dir in [
            "crates/tillandsias-macos-tray/src",
            "crates/tillandsias-windows-tray/src",
            "crates/tillandsias-host-shell/src",
            "crates/tillandsias-headless/src/tray",
        ] {
            collect_rs(&root.join(dir), &mut haystack);
        }
        assert!(
            haystack.len() > 100_000,
            "tray sources did not load — the measurement would be vacuous"
        );

        let (mut total, mut rendered) = (0usize, 0usize);
        for line in en.lines() {
            let line = line.trim();
            if line.starts_with('#') || line.starts_with('[') || !line.contains(" = ") {
                continue;
            }
            let Some((_, raw)) = line.split_once(" = ") else {
                continue;
            };
            let Some(value) = raw.strip_prefix('"').and_then(|v| v.strip_suffix('"')) else {
                continue;
            };
            if value.is_empty() {
                continue;
            }
            total += 1;
            // The QUOTED literal, so `Maintenance` does not count as rendered
            // because `🔧 Maintenance` contains it.
            if haystack.contains(&format!("\"{value}\"")) {
                rendered += 1;
            }
        }

        assert!(total > 100, "en.toml parsed to only {total} values");
        let pct = rendered * 100 / total;
        assert!(
            pct < 50,
            "en.toml now matches {pct}% of what the trays render ({rendered}/{total}). \
             If the corpora genuinely converged, 628-c7qd's byte-identical refactor may \
             finally be possible — re-read 792-77bt and retire this test deliberately \
             rather than loosening it."
        );
    }

    /// Production text only: `//` comments dropped and each file truncated at
    /// its first column-0 `#[cfg(test)]`. Conservative by construction — it
    /// can only under-count matches, never invent them.
    fn collect_rs(dir: &std::path::Path, out: &mut String) {
        let Ok(entries) = std::fs::read_dir(dir) else {
            return;
        };
        for entry in entries.flatten() {
            let path = entry.path();
            if path.is_dir() {
                collect_rs(&path, out);
            } else if path.extension().and_then(|e| e.to_str()) == Some("rs")
                && let Ok(src) = std::fs::read_to_string(&path)
            {
                for line in src.lines() {
                    if line.starts_with("#[cfg(test)]") {
                        break;
                    }
                    if line.trim_start().starts_with("//") {
                        continue;
                    }
                    out.push_str(line);
                    out.push('\n');
                }
            }
        }
    }

    /// 792-cf5x: a SPARSE locale must not fail the build — only an EXTRA key
    /// may. 14 of the 17 locales are ~25 keys behind `en` and fall back to
    /// it; a gate that demanded full coverage would fail on day one and be
    /// switched off within the hour.
    ///
    /// This test asserts the policy from the other side: the build you are
    /// running right now succeeded, and the corpus it read is provably
    /// sparse. If someone tightens the generator to require coverage, the
    /// build breaks before this test can even run — which is the loudest
    /// possible signal, and why this reads as a comment-with-teeth rather
    /// than a runtime assertion.
    #[test]
    fn sparse_locales_are_normal_and_do_not_break_the_build() {
        let dir = std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("../../locales");
        let count_keys = |name: &str| -> usize {
            let src = std::fs::read_to_string(dir.join(name)).unwrap_or_default();
            src.lines()
                .filter(|l| {
                    let t = l.trim_start();
                    !t.starts_with('#') && !t.starts_with('[') && t.contains(" = ")
                })
                .count()
        };
        let en = count_keys("en.toml");
        let fr = count_keys("fr.toml");
        assert!(en > 0 && fr > 0, "both corpora must parse");
        assert!(
            fr < en,
            "fr.toml is expected to be sparse relative to en.toml (fr={fr}, en={en}); \
             if it caught up, this test is stale rather than wrong"
        );
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    // @trace spec:vm-provisioning-lifecycle (regression guard for the
    //   CARGO_PKG_VERSION anti-pattern flagged in tray-convergence-
    //   coordination.md 2026-05-30T11:00Z ASK)
    #[test]
    fn version_reports_workspace_release_not_crate_static_zero_dot_one() {
        let v = version();
        assert_ne!(
            v, "0.1.0",
            "host-shell::version() returned the crate-static \"0.1.0\" — \
             build.rs's WORKSPACE_VERSION injection regressed; fix it before \
             provisioning fetches a non-existent v0.1.0 artifact and the tray \
             menu renders the wrong version footer."
        );
        // Workspace VERSION follows the 0.MAJOR.YYMMDD.SEQ shape (e.g.
        // `0.2.260528.1`). A 2-segment "X.Y" string is the unmistakable
        // signature of a crate-static fallback regression.
        assert!(
            v.matches('.').count() >= 2,
            "host-shell::version() = {v:?} doesn't look like a workspace VERSION \
             (expected at least 3 dot-segments e.g. 0.2.260528.1)"
        );
    }
}
