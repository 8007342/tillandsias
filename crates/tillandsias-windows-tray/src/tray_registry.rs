//! `HKCU\Control Panel\NotifyIconSettings` reconciliation at tray startup.
//!
//! WHY THIS EXISTS (order 663-64xi, operator field report 2026-08-10 during the
//! 646-qde5 verification: *"there's pollution in Windows Registry, there are
//! multiple tillandsias app (different versions) in Windows Settings"*).
//!
//! Windows keys this hive **by executable path**, so every distinct location the
//! tray has ever run from earns a permanent entry — a portable build, a
//! `target/release` build, an installed build. Two defects compose:
//!
//! 1. `install-windows.ps1` prunes correctly, but only **at install**. The
//!    portable flow never runs it, so entries accumulate with no cleanup path.
//! 2. The surviving entry's `InitialTooltip` is written once and never
//!    refreshed.
//!
//! **The interaction is the sharp part: prune-on-install plus never-refresh
//! means the ONE entry guaranteed to survive is also the one guaranteed to go
//! stale.** Measured on yolanda 2026-08-26 — `InitialTooltip = "Tillandsias
//! 0.4.260728.1"` (28 July) against an installed binary of `0.4.260826.1`, a
//! month's drift, and the same value the operator reported sixteen days earlier.
//!
//! The decision is factored into [`classify_entry`] so all three exit criteria
//! are testable without a registry — the same split `apply_login_state` uses in
//! `notify_icon.rs`, and the reason the negative case (criterion 3) can be
//! pinned at all.
//!
//! @trace order:663-64xi, spec:windows-native-tray

/// What startup reconciliation should do with one `NotifyIconSettings` entry.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum EntryAction {
    /// This entry is the running build's own: rewrite `InitialTooltip` so the
    /// Settings list tracks the running version rather than the first one ever
    /// registered.
    RefreshTooltip,
    /// A tillandsias entry whose executable is gone. Nothing can ever launch
    /// from it again, so it is pure residue.
    Prune,
    /// Leave it alone. Either it is not ours, or its executable still exists at
    /// a different path.
    Leave,
}

/// Decide what to do with a single entry.
///
/// `entry_path` is the entry's recorded `ExecutablePath`, `current_exe` is the
/// running tray's own path, and `target_exists` is whether `entry_path` is still
/// present on disk (injected rather than probed, so the decision is testable).
///
/// **Criterion 3 is the one that needs care, and it is why `Leave` is not the
/// same as "not ours".** A user may legitimately run a portable build *and* an
/// installed build; deleting the other one's entry because it is not the
/// running binary would break a working setup. Only an entry whose target is
/// GONE is residue.
///
/// Path comparison is case-insensitive because Windows paths are, and a
/// `C:\` vs `c:\` difference between the registry's copy and `current_exe()`
/// would otherwise make the running build prune itself and then re-register —
/// churning the entry it exists to stabilise.
///
/// @trace order:663-64xi
pub fn classify_entry(entry_path: &str, current_exe: &str, target_exists: bool) -> EntryAction {
    if !is_tillandsias_tray(entry_path) {
        return EntryAction::Leave;
    }
    if paths_equal_ignoring_case(entry_path, current_exe) {
        return EntryAction::RefreshTooltip;
    }
    if target_exists {
        // Another tillandsias build that still exists — a portable copy beside
        // an installed one is a supported setup, not pollution.
        EntryAction::Leave
    } else {
        EntryAction::Prune
    }
}

/// Is this entry one of ours? Matched on the executable FILE NAME rather than a
/// directory, because the whole defect is that the same binary appears under
/// many different directories.
fn is_tillandsias_tray(entry_path: &str) -> bool {
    entry_path
        .rsplit(['\\', '/'])
        .next()
        .map(|f| f.eq_ignore_ascii_case("tillandsias-tray.exe"))
        .unwrap_or(false)
}

fn paths_equal_ignoring_case(a: &str, b: &str) -> bool {
    let norm = |s: &str| s.replace('/', "\\").to_ascii_lowercase();
    norm(a) == norm(b)
}

/// The tooltip the running build should publish into the Settings list.
/// Deliberately the same shape the operator saw (`Tillandsias <version>`), so
/// a refresh changes the version and nothing else.
pub fn settings_tooltip(version: &str) -> String {
    format!("Tillandsias {version}")
}

#[cfg(test)]
mod tests {
    use super::*;

    const CUR: &str = r"C:\Users\me\AppData\Local\Programs\Tillandsias\tillandsias-tray.exe";

    /// Exit criterion 2 — the running build's own entry is refreshed on every
    /// start, which is what stops the one guaranteed survivor going stale.
    #[test]
    fn the_running_builds_own_entry_is_refreshed() {
        assert_eq!(
            classify_entry(CUR, CUR, true),
            EntryAction::RefreshTooltip,
            "the entry matching the running exe must be refreshed"
        );
    }

    /// Exit criterion 1 — an entry whose binary is gone is residue and nothing
    /// can ever launch from it again.
    #[test]
    fn an_entry_whose_target_is_gone_is_pruned() {
        assert_eq!(
            classify_entry(r"C:\repo\target\release\tillandsias-tray.exe", CUR, false),
            EntryAction::Prune
        );
    }

    /// Exit criterion 3 — THE NEGATIVE CONTROL, and the one that makes this a
    /// reconciliation rather than a purge. A portable build beside an installed
    /// build is a supported setup; deleting the other entry would break it.
    #[test]
    fn another_tillandsias_that_still_exists_is_left_alone() {
        assert_eq!(
            classify_entry(r"D:\portable\tillandsias-tray.exe", CUR, true),
            EntryAction::Leave,
            "a live portable build beside an installed one must survive"
        );
    }

    /// Somebody else's tray icon is never ours to touch, present or absent.
    #[test]
    fn foreign_entries_are_never_touched() {
        for exists in [true, false] {
            assert_eq!(
                classify_entry(r"C:\Program Files\Other\other-tray.exe", CUR, exists),
                EntryAction::Leave,
                "a non-tillandsias entry must be left alone (target_exists={exists})"
            );
        }
    }

    /// Windows paths are case-insensitive. Without this the running build would
    /// classify its OWN entry as a foreign one, prune it, and re-register —
    /// churning the entry this code exists to stabilise.
    #[test]
    fn own_entry_is_matched_case_insensitively_and_across_separators() {
        let shouty = CUR.to_ascii_uppercase();
        assert_eq!(
            classify_entry(&shouty, CUR, true),
            EntryAction::RefreshTooltip
        );
        let forward = CUR.replace('\\', "/");
        assert_eq!(
            classify_entry(&forward, CUR, true),
            EntryAction::RefreshTooltip
        );
    }

    /// A directory named like the binary must not match — the test is the file
    /// name, not a substring of the path.
    #[test]
    fn a_directory_that_merely_contains_the_name_is_not_ours() {
        assert_eq!(
            classify_entry(r"C:\tillandsias-tray.exe\something-else.exe", CUR, false),
            EntryAction::Leave
        );
    }

    #[test]
    fn settings_tooltip_carries_the_version() {
        assert_eq!(settings_tooltip("0.4.260826.1"), "Tillandsias 0.4.260826.1");
    }
}
