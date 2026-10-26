//! Order 1883-c8xr: the curated sentences every approval window shows.
//!
//! One table, read by the Linux dialog and both trays, so a gated action says
//! the same thing on every OS. Each action kind has a fixed pair, what happens
//! and what it costs, and the cost names the way back. Nothing here is
//! generated text. `{name}` placeholders are filled from the request; a
//! placeholder with no value is a caller bug, not something to paper over.
//!
//! DRAFT WORDING: awaiting the operator's approval (relayed through the
//! coordinator). No dialog may show these until that approval is recorded.
//!
//! Design: openspec/changes/os-verified-approval-gates (D8, approval-dialog).

/// One gated action kind and its two sentences.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct ActionSentences {
    /// The gate-table key (1882-kkww names its rows by these).
    pub kind: &'static str,
    /// What happens, in one sentence.
    pub happens: &'static str,
    /// What it costs and the way back, in one or two sentences.
    pub costs: &'static str,
}

/// Every cost-bearing action kind named by the approval-gate spec.
pub const ACTIONS: &[ActionSentences] = &[
    ActionSentences {
        kind: "workflow-dispatch",
        happens: "GitHub will run the {workflow} workflow on {branch}.",
        costs: "This uses about {minutes} minutes of your GitHub Actions time. You can cancel the run on GitHub while it runs.",
    },
    ActionSentences {
        kind: "push-integration",
        happens: "Your changes on {source} will be sent to {branch} on GitHub.",
        costs: "This starts the checks for {branch}, about {minutes} minutes of GitHub Actions time. A later commit can undo the change.",
    },
    ActionSentences {
        kind: "merge-integration",
        happens: "{source} will be merged into {branch}.",
        costs: "This starts the checks for {branch}, about {minutes} minutes of GitHub Actions time. The merge can be reverted with a later commit.",
    },
    ActionSentences {
        kind: "open-pull-request",
        happens: "A pull request from {source} into {branch} will be opened on GitHub.",
        costs: "This starts its checks, about {minutes} minutes of GitHub Actions time. You can close the pull request at any time.",
    },
    ActionSentences {
        kind: "promote-stable",
        happens: "Release {version} will become the stable release that new installs download.",
        costs: "Everyone who installs or updates gets this version. You can promote an earlier release back the same way.",
    },
    ActionSentences {
        kind: "extra-build",
        happens: "Tillandsias will run one more build today than your daily allowance.",
        costs: "This uses about {minutes} minutes of GitHub Actions time beyond the {allowance} builds you set. Tomorrow's allowance is not affected.",
    },
    ActionSentences {
        kind: "remote-worker",
        happens: "A remote worker named {name} will start on {provider}.",
        costs: "It is billed by {provider} while it runs. You can stop it from the tray, and billing stops when it does.",
    },
    ActionSentences {
        kind: "cloudflare-resource",
        happens: "Tillandsias will create or update {resource} in your Cloudflare account.",
        costs: "This may count against your Cloudflare plan's limits. You can remove it from the Cloudflare dashboard.",
    },
    ActionSentences {
        kind: "cloudflare-deploy",
        happens: "Version {revision} of {worker} will go live on Cloudflare.",
        costs: "Visitors see the new version within a minute. You can roll back to the previous version from the Cloudflare dashboard.",
    },
];

/// One button in the approval window.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct GrantButton {
    pub scope: &'static str,
    pub label: &'static str,
}

/// The four grant scopes plus the refusal, in window order.
pub const GRANT_BUTTONS: &[GrantButton] = &[
    GrantButton {
        scope: "once",
        label: "Approve this time",
    },
    GrantButton {
        scope: "10m",
        label: "Approve for 10 minutes",
    },
    GrantButton {
        scope: "2h",
        label: "Approve for 2 hours",
    },
    GrantButton {
        scope: "session",
        label: "Approve until the tray quits",
    },
    GrantButton {
        scope: "decline",
        label: "Not now",
    },
];

/// The line the operating system shows in its own check, per mechanism.
/// macOS appends it to "Tillandsias is trying to"; it must read on its own too.
pub const REASON_TOUCH_ID: &str = "approve the action shown in the Tillandsias window";
pub const REASON_WINDOWS_HELLO: &str =
    "Confirm it's you to approve the action shown in the Tillandsias window.";
pub const REASON_FIDO: &str =
    "Touch your security key to approve the action shown in the Tillandsias window.";

/// Look up an action's sentences by gate-table key.
pub fn sentences(kind: &str) -> Option<&'static ActionSentences> {
    ACTIONS.iter().find(|a| a.kind == kind)
}

/// Every operator-visible string in this table, for the lint.
pub fn all_text() -> Vec<&'static str> {
    let mut v: Vec<&'static str> = ACTIONS.iter().flat_map(|a| [a.happens, a.costs]).collect();
    v.extend(GRANT_BUTTONS.iter().map(|b| b.label));
    v.extend([REASON_TOUCH_ID, REASON_WINDOWS_HELLO, REASON_FIDO]);
    v
}

#[cfg(test)]
mod tests {
    use super::*;

    /// The action kinds approval-gate/spec.md lists as cost-bearing.
    const SPEC_KINDS: &[&str] = &[
        "workflow-dispatch",
        "push-integration",
        "merge-integration",
        "open-pull-request",
        "promote-stable",
        "extra-build",
        "remote-worker",
        "cloudflare-resource",
        "cloudflare-deploy",
    ];

    #[test]
    fn every_gated_action_has_a_sentence_pair() {
        for k in SPEC_KINDS {
            let s = sentences(k).unwrap_or_else(|| panic!("no sentences for {k}"));
            assert!(!s.happens.is_empty() && !s.costs.is_empty(), "{k}");
        }
        assert_eq!(ACTIONS.len(), SPEC_KINDS.len(), "a row with no spec kind");
    }

    #[test]
    fn the_window_offers_four_scopes_and_not_now() {
        let scopes: Vec<_> = GRANT_BUTTONS.iter().map(|b| b.scope).collect();
        assert_eq!(scopes, ["once", "10m", "2h", "session", "decline"]);
    }

    fn lint(s: &str) -> Result<(), String> {
        if s.contains('!') {
            return Err(format!("exclamation mark: {s}"));
        }
        let lower = s.to_lowercase();
        for w in [
            "warning",
            "danger",
            "critical",
            "irreversible",
            "urgent",
            "immediately",
        ] {
            if lower.contains(w) {
                return Err(format!("alarm word {w}: {s}"));
            }
        }
        for word in s.split(|c: char| !c.is_alphanumeric()) {
            if word.len() > 1 && word.chars().all(|c| c.is_ascii_uppercase()) {
                return Err(format!("all-caps word {word}: {s}"));
            }
        }
        Ok(())
    }

    #[test]
    fn every_sentence_passes_the_calm_lint() {
        for s in all_text() {
            lint(s).unwrap();
        }
    }

    #[test]
    fn the_lint_rejects_a_panicky_sentence() {
        assert!(lint("WARNING this deletes everything").is_err());
        assert!(lint("Done!").is_err());
        assert!(lint("This is critical.").is_err());
    }

    #[test]
    fn every_cost_names_a_way_back_or_a_bound() {
        for a in ACTIONS {
            let c = a.costs.to_lowercase();
            assert!(
                [
                    "cancel",
                    "undo",
                    "revert",
                    "close",
                    "stop",
                    "roll back",
                    "remove",
                    "earlier",
                    "not affected"
                ]
                .iter()
                .any(|w| c.contains(w)),
                "{}: no way back in {:?}",
                a.kind,
                a.costs
            );
        }
    }
}
