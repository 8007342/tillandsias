// @trace spec:host-shell-architecture, spec:tillandsias-vault
// @trace plan/issues/control-socket-protocol-convergence-2026-05-25.md (Q4)
//! Shared cloud-projects fetcher for `CloudRefreshRequest` across both
//! transports.
//!
//! Per the convergence packet's Q4 answer, each host invokes `gh` from
//! its OWN context:
//!
//!   * vsock (in-VM): fetches the GitHub token from Vault
//!     (`vault-cli read -field=token secret/github/token`) and sets
//!     `GH_TOKEN` env explicitly — the in-VM environment doesn't
//!     have the user's local `gh auth` config.
//!   * unix (Linux native host): passes `token: None` — the user's
//!     local `gh auth` setup provides credentials and `gh` finds
//!     them via its own config search path.
//!
//! Both transports then parse the same `gh repo list --json
//! nameWithOwner,defaultBranchRef` output via the shared
//! `parse_gh_repo_list` function. Tolerant: skips entries missing
//! `nameWithOwner`; a repo with no `defaultBranchRef` (e.g. empty
//! repo) gets `default_branch=""` rather than being dropped.
//!
//! 731-eupn: the list is accompanied by a `CloudRefreshOutcome`. This module
//! previously ended "malformed JSON yields an empty list. Failure to invoke
//! `gh` (binary missing, exit non-zero, no auth) also yields an empty list —
//! `CloudRefreshReply` is always well-formed", which was true and was the
//! defect: well-formed is not the same as informative. Four distinct outcomes
//! shared one representation, so the tray could not tell a repo-less account
//! from a broken `gh` and rendered a confident `(no repos)` for both. Each
//! failure now reports itself.

use tillandsias_control_wire::{CloudProjectEntry, CloudRefreshOutcome};
use tracing::{debug, warn};

/// Fetch the user's cloud (GitHub) project list via `gh`.
///
/// `token: Some(t)` sets `GH_TOKEN=t` on the spawned process — used by
/// the vsock (in-VM) path that reads the mounted secret. `token: None`
/// lets `gh` use its own auth config search path — used by the unix
/// (Linux native) path.
///
/// Returns the list AND whether it is an ANSWER (731-eupn). It used to
/// return a bare `Vec` that was "always well-formed" — empty on missing
/// binary, missing auth, non-zero exit, malformed JSON, OR a genuinely
/// repo-less account. Four outcomes, one representation, and the tray had no
/// way to tell the last one from the first three, so it rendered a confident
/// `(no repos)` for a broken `gh`.
///
/// The list is still always well-formed; what is new is that an empty list now
/// arrives with the reason it is empty.
///
/// @trace spec:host-shell-architecture, spec:tillandsias-vault, order:731-eupn
#[allow(dead_code)]
pub fn fetch_cloud_projects(token: Option<&str>) -> (Vec<CloudProjectEntry>, CloudRefreshOutcome) {
    let mut cmd = std::process::Command::new("gh");
    cmd.args([
        "repo",
        "list",
        "--json",
        "nameWithOwner,defaultBranchRef",
        "--limit",
        "100",
    ]);
    if let Some(t) = token {
        cmd.env("GH_TOKEN", t);
    }

    let output = cmd.output();

    let stdout = match output {
        Ok(out) if out.status.success() => out.stdout,
        Ok(out) => {
            warn!(
                spec = "host-shell-architecture",
                status = ?out.status.code(),
                stderr = %String::from_utf8_lossy(&out.stderr).trim(),
                token_kind = if token.is_some() { "explicit" } else { "host-auth" },
                "CloudRefreshRequest: gh repo list failed; reporting FAILED, not empty"
            );
            return (
                Vec::new(),
                CloudRefreshOutcome::Failed {
                    reason: format!(
                        "gh repo list exited {}",
                        out.status
                            .code()
                            .map(|c| c.to_string())
                            .unwrap_or_else(|| "by signal".to_string())
                    ),
                },
            );
        }
        Err(e) => {
            warn!(
                spec = "host-shell-architecture",
                error = %e,
                token_kind = if token.is_some() { "explicit" } else { "host-auth" },
                "CloudRefreshRequest: gh not available; reporting FAILED, not empty"
            );
            return (
                Vec::new(),
                CloudRefreshOutcome::Failed {
                    reason: format!("gh could not be run: {e}"),
                },
            );
        }
    };

    let parsed = parse_gh_repo_list(&String::from_utf8_lossy(&stdout));
    debug!(
        spec = "host-shell-architecture",
        count = parsed.len(),
        token_kind = if token.is_some() {
            "explicit"
        } else {
            "host-auth"
        },
        "CloudRefreshRequest: gh repo list parsed"
    );
    // THE THIRD COLLAPSED OUTCOME. A successful `gh` whose output did not
    // parse is not a confirmed empty account either — parse_gh_repo_list
    // returns an empty Vec for malformed JSON. Only an actual empty JSON array
    // is an answer of "zero repos".
    if parsed.is_empty() && !is_empty_json_array(&String::from_utf8_lossy(&stdout)) {
        warn!(
            spec = "host-shell-architecture",
            "CloudRefreshRequest: gh succeeded but its output did not parse as a repo list; \
             reporting FAILED, not empty"
        );
        return (
            Vec::new(),
            CloudRefreshOutcome::Failed {
                reason: "gh output did not parse as a repo list".to_string(),
            },
        );
    }
    (parsed, CloudRefreshOutcome::Ok)
}

/// True when `gh` legitimately reported zero repos — an empty JSON array.
///
/// This is what separates the FOURTH outcome (an account that genuinely has no
/// visible repos, which IS an answer) from the third (output that merely
/// parses to nothing). Without it, "empty list" would still be ambiguous after
/// all the other work in this change.
fn is_empty_json_array(s: &str) -> bool {
    serde_json::from_str::<serde_json::Value>(s)
        .ok()
        .and_then(|v| v.as_array().map(|a| a.is_empty()))
        .unwrap_or(false)
}

/// Pure parser for `gh repo list --json nameWithOwner,defaultBranchRef`
/// output. Tolerant: skips entries missing nameWithOwner; a repo with
/// no defaultBranchRef (e.g. an empty repo) gets an empty
/// default_branch rather than being dropped. Malformed JSON yields an
/// empty list.
#[allow(dead_code)]
pub fn parse_gh_repo_list(json: &str) -> Vec<CloudProjectEntry> {
    let Ok(value) = serde_json::from_str::<serde_json::Value>(json) else {
        return Vec::new();
    };
    let Some(array) = value.as_array() else {
        return Vec::new();
    };
    let mut out = Vec::new();
    for item in array {
        let Some(name_with_owner) = item.get("nameWithOwner").and_then(|v| v.as_str()) else {
            continue;
        };
        let (owner, repo) = match name_with_owner.split_once('/') {
            Some((o, r)) if !o.is_empty() && !r.is_empty() => (o.to_string(), r.to_string()),
            _ => continue,
        };
        let default_branch = item
            .get("defaultBranchRef")
            .and_then(|v| v.get("name"))
            .and_then(|v| v.as_str())
            .unwrap_or("")
            .to_string();
        out.push(CloudProjectEntry {
            label: name_with_owner.to_string(),
            owner,
            repo,
            default_branch,
        });
    }
    out
}

/// Fetch the user's GitHub username (handle) via `gh api user --jq .login`.
///
/// `token: Some(t)` sets `GH_TOKEN=t` on the spawned process. `token: None`
/// lets `gh` use its own auth config.
///
/// Kept for API completeness; may be used by future tray or vsock callers.
#[cfg(feature = "listen-vsock")]
#[allow(dead_code)]
pub fn fetch_github_username(token: Option<&str>) -> Option<String> {
    let mut cmd = std::process::Command::new("gh");
    cmd.args(["api", "user", "--jq", ".login"]);
    if let Some(t) = token {
        cmd.env("GH_TOKEN", t);
    }
    let output = cmd.output().ok()?;
    if output.status.success() {
        let username = String::from_utf8_lossy(&output.stdout).trim().to_string();
        if !username.is_empty() {
            return Some(username);
        }
    } else {
        warn!(
            spec = "host-shell-architecture",
            status = ?output.status.code(),
            stderr = %String::from_utf8_lossy(&output.stderr).trim(),
            "fetch_github_username: gh api user failed"
        );
    }
    None
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parse_gh_repo_list_maps_name_owner_and_branch() {
        let json = r#"[
            {"nameWithOwner":"8007342/tillandsias","defaultBranchRef":{"name":"main"}},
            {"nameWithOwner":"acme/widgets","defaultBranchRef":{"name":"trunk"}}
        ]"#;
        let out = parse_gh_repo_list(json);
        assert_eq!(out.len(), 2);
        assert_eq!(out[0].label, "8007342/tillandsias");
        assert_eq!(out[0].owner, "8007342");
        assert_eq!(out[0].repo, "tillandsias");
        assert_eq!(out[0].default_branch, "main");
        assert_eq!(out[1].default_branch, "trunk");
    }

    #[test]
    fn parse_gh_repo_list_tolerates_missing_branch_and_bad_entries() {
        // Repo with no defaultBranchRef survives with empty default_branch.
        // Entry missing nameWithOwner is silently skipped.
        // Entry with a name that doesn't split on '/' is skipped.
        let json = r#"[
            {"nameWithOwner":"x/empty-repo"},
            {"defaultBranchRef":{"name":"main"}},
            {"nameWithOwner":"no-slash"},
            {"nameWithOwner":"x/y","defaultBranchRef":{"name":"main"}}
        ]"#;
        let out = parse_gh_repo_list(json);
        assert_eq!(out.len(), 2);
        assert_eq!(out[0].label, "x/empty-repo");
        assert_eq!(out[0].default_branch, "");
        assert_eq!(out[1].label, "x/y");
    }

    #[test]
    fn parse_gh_repo_list_empty_on_malformed_or_non_array() {
        assert!(parse_gh_repo_list("").is_empty());
        assert!(parse_gh_repo_list("not json").is_empty());
        assert!(parse_gh_repo_list("{}").is_empty());
        assert!(parse_gh_repo_list("[]").is_empty());
    }
}
