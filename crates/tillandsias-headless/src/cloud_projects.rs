// @trace spec:host-shell-architecture, spec:tillandsias-vault
// @trace plan/issues/control-socket-protocol-convergence-2026-05-25.md (Q4)
//! Shared cloud-projects fetcher for `CloudRefreshRequest` across both
//! transports.
//!
//! Per the convergence packet's Q4 answer, each host invokes `gh` from
//! its OWN context:
//!
//!   * vsock (in-VM): reads a token from
//!     `/run/secrets/tillandsias-github-token` and sets `GH_TOKEN`
//!     env explicitly — the in-VM environment doesn't have the user's
//!     local `gh auth` config.
//!   * unix (Linux native host): passes `token: None` — the user's
//!     local `gh auth` setup provides credentials and `gh` finds
//!     them via its own config search path.
//!
//! Both transports then parse the same `gh repo list --json
//! nameWithOwner,defaultBranchRef` output via the shared
//! `parse_gh_repo_list` function. Tolerant: skips entries missing
//! `nameWithOwner`; a repo with no `defaultBranchRef` (e.g. empty
//! repo) gets `default_branch=""` rather than being dropped;
//! malformed JSON yields an empty list. Failure to invoke `gh`
//! (binary missing, exit non-zero, no auth) also yields an empty
//! list — `CloudRefreshReply` is always well-formed.

use tillandsias_control_wire::CloudProjectEntry;
use tracing::{debug, warn};

/// Fetch the user's cloud (GitHub) project list via `gh`.
///
/// `token: Some(t)` sets `GH_TOKEN=t` on the spawned process — used by
/// the vsock (in-VM) path that reads the mounted secret. `token: None`
/// lets `gh` use its own auth config search path — used by the unix
/// (Linux native) path.
///
/// Always returns a well-formed `Vec` — empty on missing binary,
/// missing auth, non-zero exit, malformed JSON, or any other
/// transient failure. Callers reply with a `CloudRefreshReply`
/// carrying whatever this returns.
///
/// @trace spec:host-shell-architecture, spec:tillandsias-vault
pub fn fetch_cloud_projects(token: Option<&str>) -> Vec<CloudProjectEntry> {
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
                "CloudRefreshRequest: gh repo list failed; returning empty cloud list"
            );
            return Vec::new();
        }
        Err(e) => {
            warn!(
                spec = "host-shell-architecture",
                error = %e,
                token_kind = if token.is_some() { "explicit" } else { "host-auth" },
                "CloudRefreshRequest: gh not available; returning empty cloud list"
            );
            return Vec::new();
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
    parsed
}

/// Pure parser for `gh repo list --json nameWithOwner,defaultBranchRef`
/// output. Tolerant: skips entries missing nameWithOwner; a repo with
/// no defaultBranchRef (e.g. an empty repo) gets an empty
/// default_branch rather than being dropped. Malformed JSON yields an
/// empty list.
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
