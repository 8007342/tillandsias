//! Cross-crate contract pin: the macOS host's `--github-login` expect script
//! must ask for things in the SAME ORDER the guest prompts for them.
//!
//! `DynamicExpect` is strictly sequential, so a mismatch is not a cosmetic
//! nit — it is a silent deadlock (host scanning for a needle the guest will
//! not print until the host answers a different prompt first), and with the
//! guest's 30s PTY heartbeat resetting the exec idle deadline it is an
//! UNBOUNDED one. That is exactly what happened when operator directive
//! 2026-07-29 moved the guest to credential-first and this host list was not
//! updated: 70-minute silent wedges on 2026-08-10/11.
//!
//! The two sides live in different crates, so nothing but a test like this
//! couples them. Source-scanning is the point here — the contract IS the
//! order of the prompt strings in the two files.
//!
//! @trace spec:macos-native-tray, spec:gh-auth-script, plan 663-acdw

#![cfg(target_os = "macos")]

const HOST: &str = include_str!("../src/diagnose.rs");
const GUEST: &str = include_str!("../../tillandsias-headless/src/main.rs");

/// Order of first appearance of each marker in `haystack`.
/// Returns None for any marker that is absent, so a renamed prompt fails
/// loudly here instead of silently reordering the comparison.
fn order_of(haystack: &str, markers: &[&str]) -> Vec<(String, usize)> {
    markers
        .iter()
        .map(|m| {
            let at = haystack.find(m).unwrap_or_else(|| {
                panic!(
                    "marker {m:?} no longer appears — prompt text changed; \
                                           update BOTH sides and this pin together"
                )
            });
            ((*m).to_string(), at)
        })
        .collect()
}

/// THE PIN. Both sides must sequence token → name → email.
#[test]
fn host_expect_order_matches_guest_prompt_order() {
    // Host side: the order the needles appear in the `expects` vec literal.
    let host_needles = order_of(
        HOST,
        &[
            "b\"authentication token\"",
            "b\"author name\"",
            "b\"author email\"",
        ],
    );
    let host_sequence: Vec<&str> = {
        let mut v = host_needles.clone();
        v.sort_by_key(|(_, at)| *at);
        v.iter()
            .map(|(m, _)| {
                if m.contains("token") {
                    "token"
                } else if m.contains("name") {
                    "name"
                } else {
                    "email"
                }
            })
            .collect()
    };

    // Guest side: the token is collected by the login container exec, and the
    // git identity is prompted afterwards by prompt_and_store_git_identity.
    let guest_needles = order_of(
        GUEST,
        &[
            "GitHub authentication token",
            "\"Git author name\"",
            "\"Git author email\"",
        ],
    );
    let guest_sequence: Vec<&str> = {
        let mut v = guest_needles.clone();
        v.sort_by_key(|(_, at)| *at);
        v.iter()
            .map(|(m, _)| {
                if m.contains("token") {
                    "token"
                } else if m.contains("name") {
                    "name"
                } else {
                    "email"
                }
            })
            .collect()
    };

    assert_eq!(
        host_sequence, guest_sequence,
        "macOS --github-login expect order {host_sequence:?} does not match the guest's prompt \
         order {guest_sequence:?}. DynamicExpect is sequential, so this mismatch deadlocks the \
         login silently and (with the PTY heartbeat resetting the idle deadline) unboundedly. \
         Reorder the `expects` vec in crates/tillandsias-macos-tray/src/diagnose.rs to match \
         crates/tillandsias-headless/src/main.rs."
    );
}

/// NEGATIVE CONTROL (bar-raise 634-39ik). The test above compares two derived
/// sequences; if the extraction were broken — say both sides collapsed to the
/// same constant, or the markers matched nothing meaningful — it would pass
/// vacuously. Assert the extraction actually discriminates: the guest really
/// does put the token FIRST (the whole point of the 2026-07-29 directive), so
/// a hardcoded name-first expectation must FAIL to match it.
#[test]
fn extraction_actually_discriminates_order() {
    let guest_needles = order_of(
        GUEST,
        &[
            "GitHub authentication token",
            "\"Git author name\"",
            "\"Git author email\"",
        ],
    );
    let token_at = guest_needles[0].1;
    let name_at = guest_needles[1].1;
    let email_at = guest_needles[2].1;

    assert!(
        token_at < name_at && name_at < email_at,
        "guest prompt order is no longer token({token_at}) < name({name_at}) < email({email_at}). \
         If the guest deliberately changed order again, update the host `expects` vec FIRST, \
         then this control — never the other way around."
    );
}
