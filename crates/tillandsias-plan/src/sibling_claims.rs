//! ORDER 1947-pnst — rows another branch already holds are not offered.
//!
//! lenovinha 2026-11-01: plan_next offered 776-jcf3 as claimable while a
//! sibling platform branch held it in_progress under another host's claim;
//! only scripts/check-claims-across-branches.sh, run afterwards, said so. The
//! ledger is a G-Set of fragments, so a sibling's view is this checkout's
//! corpus plus the fragments that sibling has and HEAD lacks. Folding those
//! and reading each READY row's status there answers "does a sibling hold
//! it?" with the same fold every reader uses, never a text scan.
//!
//! Read-only: every sibling file is read out of the object store with
//! `git show`; nothing is checked out or fetched. A sibling ref that is not
//! fetched contributes nothing, and nothing is claimed about it.
// @trace order:1947-pnst, spec:spec-traceability

use crate::fragments::{Fragment, fold, load_all};
use crate::gitref::GitView;
use crate::{Ledger, str_field};
use std::collections::{BTreeMap, BTreeSet};
use std::path::{Path, PathBuf};

/// The platform branches whose claims a linux selector must respect.
pub const DEFAULT_SIBLING_REFS: &[&str] = &[
    "refs/remotes/origin/linux-next",
    "refs/remotes/origin/windows-next",
    "refs/remotes/origin/osx-next",
];

/// READY rows of `ledger` that a sibling ref holds in another status, keyed
/// by packet id, valued by `<ref>:<status>`. `index` is the ledger's
/// `plan/index.yaml`; `root` its checkout.
pub fn held_on_siblings(
    ledger: &Ledger,
    index: &Path,
    root: &Path,
    refs: &[&str],
) -> BTreeMap<String, String> {
    let mut held = BTreeMap::new();
    let view = GitView::new(root);
    let Some(head) = view.head() else {
        return held;
    };
    let ready: BTreeSet<String> = ledger.ready(None).iter().map(|p| ledger.id_of(p)).collect();
    if ready.is_empty() {
        return held;
    }
    let Ok(raw) = std::fs::read_to_string(index) else {
        return held;
    };
    let Ok(base_doc) = serde_yaml::from_str::<serde_yaml::Value>(&raw) else {
        return held;
    };
    let rel_dir = index
        .parent()
        .and_then(|d| d.strip_prefix(root).ok())
        .map(|d| d.join("index.d").to_string_lossy().replace('\\', "/"))
        .unwrap_or_else(|| "plan/index.d".to_string());
    let mut head_frags: Option<Vec<Fragment>> = None;
    for r in refs {
        let Some(sha) = view.resolve_commit(r) else {
            continue;
        };
        if sha == head {
            continue;
        }
        let Some(added) = view.added_paths(&head, &sha, &rel_dir) else {
            continue;
        };
        let extra: Vec<Fragment> = added
            .iter()
            .filter(|p| p.ends_with(".yaml"))
            .filter_map(|p| {
                let raw = view.file_at(&sha, p)?;
                let doc = serde_yaml::from_str(&raw).ok()?;
                Some(Fragment {
                    name: Path::new(p).file_name()?.to_string_lossy().to_string(),
                    path: PathBuf::from(p),
                    doc,
                    raw,
                })
            })
            .collect();
        if extra.is_empty() {
            continue;
        }
        let mut all = head_frags.get_or_insert_with(|| load_all(index)).clone();
        all.extend(extra);
        all.sort_by(|a, b| a.name.cmp(&b.name));
        let merged = fold(&base_doc, &all);
        let Ok(theirs) = Ledger::from_doc("", &merged, BTreeSet::new()) else {
            continue;
        };
        for p in &theirs.packets {
            let id = theirs.id_of(p);
            if !ready.contains(&id) || held.contains_key(&id) {
                continue;
            }
            match str_field(p, "status") {
                Some("ready") | None => {}
                Some(other) => {
                    let short = r.rsplit('/').next().unwrap_or(r);
                    held.insert(id, format!("{short}:{other}"));
                }
            }
        }
    }
    held
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::gitref::testrepo;

    const BASE: &str = "packets:\n- packet_id: free-row\n  order: 1-free\n  status: ready\n  pickup_role: linux\n- packet_id: held-row\n  order: 2-held\n  status: ready\n  pickup_role: linux\n";

    fn claim(id: &str, ts: &str) -> String {
        // The shape `tillandsias-plan set-field` writes.
        format!(
            "status:\n  - packet_id: {id}\n    field: status\n    value: in_progress\n    ts: \"{ts}\"\n    host: yoga\n"
        )
    }

    /// The 2026-11-01 shape: HEAD's ledger shows both rows ready; a sibling
    /// branch carries a fragment claiming one. Only the free row stays
    /// claimable. Pre-fix nothing consulted the sibling.
    #[test]
    fn a_row_a_sibling_holds_is_found_and_a_free_one_is_not() {
        let r = testrepo::repo("pnst-sib");
        r.write("plan/index.yaml", BASE);
        let head = r.commit("ledger");
        r.git(&["checkout", "-q", "-b", "osx"]);
        r.write(
            "plan/index.d/20261101t000000z-claim-yoga.yaml",
            &claim("held-row", "2026-11-01T00:00:00Z"),
        );
        let sib = r.commit("yoga claims held-row on its branch");
        r.git(&["update-ref", "refs/remotes/origin/osx-next", &sib]);
        r.checkout(&head);

        let index = r.path().join("plan/index.yaml");
        let ledger = Ledger::load_with_fragments(&index).unwrap();
        assert_eq!(ledger.ready(None).len(), 2, "HEAD alone sees both ready");
        let refs = ["refs/remotes/origin/osx-next", "refs/remotes/origin/absent"];
        let held = held_on_siblings(&ledger, &index, r.path(), &refs);
        assert_eq!(held.len(), 1, "{held:?}");
        assert_eq!(
            held.get("held-row").map(String::as_str),
            Some("osx-next:in_progress")
        );

        // The selector hides it through the same exclusion set as overlays.
        let ids: BTreeSet<String> = held.keys().cloned().collect();
        let env = crate::answer::answer_next_excluding(
            &ledger,
            Some("linux"),
            Some("v9"),
            None,
            "plan/index.yaml",
            &ids,
        );
        assert!(!env.answer().contains("held-row"), "{}", env.answer());
    }

    #[test]
    fn no_sibling_ref_or_no_extra_fragment_holds_nothing() {
        let r = testrepo::repo("pnst-sib-none");
        r.write("plan/index.yaml", BASE);
        let head = r.commit("ledger");
        r.git(&["update-ref", "refs/remotes/origin/osx-next", &head]);
        let index = r.path().join("plan/index.yaml");
        let ledger = Ledger::load_with_fragments(&index).unwrap();
        assert!(held_on_siblings(&ledger, &index, r.path(), DEFAULT_SIBLING_REFS).is_empty());
    }
}
