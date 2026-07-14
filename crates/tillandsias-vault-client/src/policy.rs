//! Vault ACL policy taxonomy.
//!
//! Each enum variant maps to a named policy on the Vault server. Container
//! startup paths request a token scoped to exactly one policy; cross-policy
//! reads return 403 by design.
//!
//! The HCL templates are embedded via [`include_str!`] from
//! `images/vault/policies/*.hcl` so the client and the container image stay
//! in lock-step. A unit test (and the spec litmus) asserts byte equality.
//!
//! @trace spec:tillandsias-vault
//! @cheatsheet runtime/hashicorp-vault-tillandsias.md

use serde::{Deserialize, Serialize};

const GIT_MIRROR_HCL: &str = include_str!("../../../images/vault/policies/git-mirror.hcl");
const FORGE_HCL: &str = include_str!("../../../images/vault/policies/forge.hcl");
const TRAY_HCL: &str = include_str!("../../../images/vault/policies/tray.hcl");
const INFERENCE_HCL: &str = include_str!("../../../images/vault/policies/inference.hcl");
const GITHUB_LOGIN_HCL: &str = include_str!("../../../images/vault/policies/github-login.hcl");
const CLAUDE_LOGIN_HCL: &str = include_str!("../../../images/vault/policies/claude-login.hcl");
const CODEX_LOGIN_HCL: &str = include_str!("../../../images/vault/policies/codex-login.hcl");
const CODEX_FORGE_HCL: &str = include_str!("../../../images/vault/policies/codex-forge.hcl");
const ANTIGRAVITY_LOGIN_HCL: &str =
    include_str!("../../../images/vault/policies/antigravity-login.hcl");

/// Named policy bound to a Vault token.
///
/// - `GitMirror` — read-only on `secret/data/github/token`.
/// - `Forge` — read-only on `secret/data/ca/proxy-cert` only; never sees tokens.
/// - `Tray` — full CRUD on `secret/*` for rotation flows.
/// - `Inference` — empty placeholder (no secrets needed today).
/// - `GithubLogin` — write-capable policy for the one-shot github-login container.
/// - `ClaudeLogin`/`CodexLogin`/`AntigravityLogin` — write-capable policies for
///   the one-shot provider-login containers (`run_provider_login` mints role
///   `<provider>-login`); scoped to `secret/data/<provider>/oauth` only.
/// - `CodexForge` — read-only on the opaque Codex OAuth document for restore.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
pub enum Policy {
    GitMirror,
    Forge,
    Tray,
    Inference,
    GithubLogin,
    ClaudeLogin,
    CodexLogin,
    CodexForge,
    AntigravityLogin,
}

impl Policy {
    /// Vault-side policy name, used when minting a token via
    /// `vault token create -policy=<name>` or as the JSON `policies[]` entry.
    pub fn name(&self) -> &'static str {
        match self {
            Policy::GitMirror => "git-mirror-policy",
            Policy::Forge => "forge-policy",
            Policy::Tray => "tray-policy",
            Policy::Inference => "inference-policy",
            Policy::GithubLogin => "github-login-policy",
            Policy::ClaudeLogin => "claude-login-policy",
            Policy::CodexLogin => "codex-login-policy",
            Policy::CodexForge => "codex-forge-policy",
            Policy::AntigravityLogin => "antigravity-login-policy",
        }
    }

    /// Repository-relative path to the HCL file that defines this policy.
    /// The image's `entrypoint.sh` loads from this same path inside the
    /// container.
    pub fn hcl_path(&self) -> &'static str {
        match self {
            Policy::GitMirror => "images/vault/policies/git-mirror.hcl",
            Policy::Forge => "images/vault/policies/forge.hcl",
            Policy::Tray => "images/vault/policies/tray.hcl",
            Policy::Inference => "images/vault/policies/inference.hcl",
            Policy::GithubLogin => "images/vault/policies/github-login.hcl",
            Policy::ClaudeLogin => "images/vault/policies/claude-login.hcl",
            Policy::CodexLogin => "images/vault/policies/codex-login.hcl",
            Policy::CodexForge => "images/vault/policies/codex-forge.hcl",
            Policy::AntigravityLogin => "images/vault/policies/antigravity-login.hcl",
        }
    }

    /// The HCL body, embedded at compile time. Used by tray-side
    /// provisioning to assert the running vault has loaded the exact
    /// policy text we ship.
    pub fn hcl(&self) -> &'static str {
        match self {
            Policy::GitMirror => GIT_MIRROR_HCL,
            Policy::Forge => FORGE_HCL,
            Policy::Tray => TRAY_HCL,
            Policy::Inference => INFERENCE_HCL,
            Policy::GithubLogin => GITHUB_LOGIN_HCL,
            Policy::ClaudeLogin => CLAUDE_LOGIN_HCL,
            Policy::CodexLogin => CODEX_LOGIN_HCL,
            Policy::CodexForge => CODEX_FORGE_HCL,
            Policy::AntigravityLogin => ANTIGRAVITY_LOGIN_HCL,
        }
    }

    /// All policies, in deterministic order.
    pub fn all() -> &'static [Policy] {
        &[
            Policy::GitMirror,
            Policy::Forge,
            Policy::Tray,
            Policy::Inference,
            Policy::GithubLogin,
            Policy::ClaudeLogin,
            Policy::CodexLogin,
            Policy::CodexForge,
            Policy::AntigravityLogin,
        ]
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::fs;
    use std::path::PathBuf;

    fn repo_root() -> PathBuf {
        // crates/tillandsias-vault-client/ -> repo root
        let manifest = PathBuf::from(env!("CARGO_MANIFEST_DIR"));
        manifest.parent().unwrap().parent().unwrap().to_path_buf()
    }

    #[test]
    fn embedded_hcl_matches_image_files_on_disk() {
        // Locks the client to the image. If someone edits the HCL on one
        // side only, this test fails loud — preventing client/server drift.
        for policy in Policy::all() {
            let path = repo_root().join(policy.hcl_path());
            let on_disk = fs::read_to_string(&path)
                .unwrap_or_else(|e| panic!("failed to read {}: {e}", path.display()));
            assert_eq!(
                policy.hcl(),
                on_disk,
                "embedded HCL for {:?} drifted from {}",
                policy,
                path.display()
            );
        }
    }

    #[test]
    fn policy_names_match_spec() {
        assert_eq!(Policy::GitMirror.name(), "git-mirror-policy");
        assert_eq!(Policy::Forge.name(), "forge-policy");
        assert_eq!(Policy::Tray.name(), "tray-policy");
        assert_eq!(Policy::Inference.name(), "inference-policy");
        assert_eq!(Policy::GithubLogin.name(), "github-login-policy");
        assert_eq!(Policy::ClaudeLogin.name(), "claude-login-policy");
        assert_eq!(Policy::CodexLogin.name(), "codex-login-policy");
        assert_eq!(Policy::CodexForge.name(), "codex-forge-policy");
        assert_eq!(Policy::AntigravityLogin.name(), "antigravity-login-policy");
    }

    #[test]
    fn forge_policy_does_not_mention_github_token() {
        // Invariant: tillandsias-vault.invariant.forge-policy-has-no-token-read
        let hcl = Policy::Forge.hcl();
        assert!(
            !hcl.contains("github/token"),
            "forge policy must not grant any path under github/token; got:\n{hcl}"
        );
        assert!(
            !hcl.contains("\"create\"")
                && !hcl.contains("\"update\"")
                && !hcl.contains("\"delete\""),
            "forge policy must be read-only; got:\n{hcl}"
        );
    }

    #[test]
    fn codex_forge_policy_is_session_write_capable_and_provider_scoped() {
        let hcl = Policy::CodexForge.hcl();
        assert!(hcl.contains("secret/data/codex/oauth"));
        assert!(hcl.contains("capabilities = [\"create\", \"update\", \"read\"]"));
        assert!(!hcl.contains("github/token"));
        assert!(!hcl.contains("claude/oauth") && !hcl.contains("antigravity/oauth"));
    }
}
