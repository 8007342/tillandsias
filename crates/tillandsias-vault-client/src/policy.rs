//! Vault ACL policy taxonomy.
//!
//! Each enum variant maps to a named policy on the Vault server. Container
//! startup paths request a token scoped to exactly one policy; cross-policy
//! reads return 403 by design.
//!
//! @trace spec:tillandsias-vault

#![allow(dead_code)]
#![allow(unused)]

use serde::{Deserialize, Serialize};

/// Named policy bound to a Vault token.
///
/// `GitMirror` — read-only on `secret/github/token`.
/// `Forge` — read-only on `secret/ca/proxy-cert` only; never sees tokens.
/// `Tray` — full read/write on `secret/*` for rotation flows.
/// `Inference` — empty placeholder (no secrets needed today).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub enum Policy {
    GitMirror,
    Forge,
    Tray,
    Inference,
}

impl Policy {
    /// Return the Vault-side policy name. Used by `issue_token`.
    pub fn name(&self) -> &'static str {
        match self {
            Policy::GitMirror => "git-mirror-policy",
            Policy::Forge => "forge-policy",
            Policy::Tray => "tray-policy",
            Policy::Inference => "inference-policy",
        }
    }
}
