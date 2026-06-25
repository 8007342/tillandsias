//! Action allowlist for the ZeroClaw host control surface.
//!
//! Enforces that every tool call targets the project the server was locked to
//! at startup, and that the requested action is one of the five approved verbs.
//!
//! @trace spec:zeroclaw-orchestration

use std::path::{Path, PathBuf};
use thiserror::Error;

/// The five approved orchestration verbs.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ApprovedAction {
    /// Run `/advance-work-from-plan` on the locked project.
    AdvanceWork,
    /// Run `./build.sh --check` or `--test` on the locked project.
    Build { full_test: bool },
    /// Launch a named local service from the hardcoded service allowlist.
    ServiceLaunch { service_name: String },
    /// Delegate to a forge container for the locked project.
    ForgeDelegate { prompt: String },
    /// Return current plan status for the locked project.
    Status,
}

/// Approved service names for `ServiceLaunch`.
const APPROVED_SERVICES: &[&str] = &["dev-proxy", "inference", "vault", "router"];

/// Denial reason for an action request.
#[derive(Debug, Clone, PartialEq, Eq, Error)]
pub enum AllowlistDeny {
    #[error("unknown tool: {0}")]
    UnknownTool(String),

    #[error("project mismatch: expected {expected}, got {actual}")]
    ProjectMismatch { expected: String, actual: String },

    #[error("service not approved: {0}")]
    ServiceNotApproved(String),

    #[error("missing required parameter: {0}")]
    MissingParam(String),
}

/// Project-scoped allowlist.
///
/// Created once at server startup with the locked project path. All incoming
/// tool calls must pass `check` before being dispatched.
pub struct ZeroClawAllowlist {
    locked_project: PathBuf,
}

impl ZeroClawAllowlist {
    /// Create a new allowlist locked to `project_path`.
    pub fn new(project_path: impl Into<PathBuf>) -> Self {
        Self {
            locked_project: project_path.into(),
        }
    }

    /// Locked project path.
    pub fn project(&self) -> &Path {
        &self.locked_project
    }

    /// Validate a tool call and return the parsed `ApprovedAction`, or a denial.
    pub fn check(
        &self,
        tool_name: &str,
        params: &serde_json::Value,
    ) -> Result<ApprovedAction, AllowlistDeny> {
        if let Some(requested) = params.get("project_path").and_then(|v| v.as_str()) {
            let requested_canon = PathBuf::from(requested)
                .canonicalize()
                .unwrap_or_else(|_| PathBuf::from(requested));
            let locked_canon = self
                .locked_project
                .canonicalize()
                .unwrap_or_else(|_| self.locked_project.clone());
            if requested_canon != locked_canon {
                return Err(AllowlistDeny::ProjectMismatch {
                    expected: locked_canon.display().to_string(),
                    actual: requested_canon.display().to_string(),
                });
            }
        }

        match tool_name {
            "zeroclaw.advance_work" => Ok(ApprovedAction::AdvanceWork),

            "zeroclaw.build" => {
                let full_test = params
                    .get("full_test")
                    .and_then(|v| v.as_bool())
                    .unwrap_or(false);
                Ok(ApprovedAction::Build { full_test })
            }

            "zeroclaw.service_launch" => {
                let service_name = params
                    .get("service_name")
                    .and_then(|v| v.as_str())
                    .ok_or_else(|| AllowlistDeny::MissingParam("service_name".to_string()))?
                    .to_string();
                if !APPROVED_SERVICES.contains(&service_name.as_str()) {
                    return Err(AllowlistDeny::ServiceNotApproved(service_name));
                }
                Ok(ApprovedAction::ServiceLaunch { service_name })
            }

            "zeroclaw.forge_delegate" => {
                let prompt = params
                    .get("prompt")
                    .and_then(|v| v.as_str())
                    .ok_or_else(|| AllowlistDeny::MissingParam("prompt".to_string()))?
                    .to_string();
                Ok(ApprovedAction::ForgeDelegate { prompt })
            }

            "zeroclaw.status" => Ok(ApprovedAction::Status),

            other => Err(AllowlistDeny::UnknownTool(other.to_string())),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    fn list() -> ZeroClawAllowlist {
        ZeroClawAllowlist::new("/home/forge/src/myproject")
    }

    #[test]
    fn approved_advance_work() {
        let a = list().check("zeroclaw.advance_work", &json!({}));
        assert_eq!(a.unwrap(), ApprovedAction::AdvanceWork);
    }

    #[test]
    fn approved_build_default() {
        let a = list().check("zeroclaw.build", &json!({}));
        assert_eq!(a.unwrap(), ApprovedAction::Build { full_test: false });
    }

    #[test]
    fn approved_build_full() {
        let a = list().check("zeroclaw.build", &json!({ "full_test": true }));
        assert_eq!(a.unwrap(), ApprovedAction::Build { full_test: true });
    }

    #[test]
    fn approved_service_launch() {
        let a = list().check(
            "zeroclaw.service_launch",
            &json!({ "service_name": "vault" }),
        );
        assert_eq!(
            a.unwrap(),
            ApprovedAction::ServiceLaunch {
                service_name: "vault".to_string()
            }
        );
    }

    #[test]
    fn denied_unapproved_service() {
        let a = list().check(
            "zeroclaw.service_launch",
            &json!({ "service_name": "postgres" }),
        );
        assert!(matches!(a, Err(AllowlistDeny::ServiceNotApproved(_))));
    }

    #[test]
    fn denied_unknown_tool() {
        let a = list().check("podman.run", &json!({}));
        assert!(matches!(a, Err(AllowlistDeny::UnknownTool(_))));
    }

    #[test]
    fn denied_project_mismatch() {
        let a = list().check(
            "zeroclaw.advance_work",
            &json!({ "project_path": "/home/forge/src/otherproject" }),
        );
        assert!(matches!(a, Err(AllowlistDeny::ProjectMismatch { .. })));
    }

    #[test]
    fn approved_forge_delegate() {
        let a = list().check(
            "zeroclaw.forge_delegate",
            &json!({ "prompt": "Use /advance-work-from-plan" }),
        );
        assert!(matches!(a, Ok(ApprovedAction::ForgeDelegate { .. })));
    }

    #[test]
    fn approved_status() {
        let a = list().check("zeroclaw.status", &json!({}));
        assert_eq!(a.unwrap(), ApprovedAction::Status);
    }
}
