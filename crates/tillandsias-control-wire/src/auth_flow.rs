//! Auth / Login Finite State Machine (prototype, research order 469).
//!
//! Reifies provider login flows (GitHub, Codex, OpenCode, Antigravity) as an explicit
//! finite state machine with observable states, discrete transitions, and guard predicates
//! expressed over runtime and data dependency nodes.
//!
//! @trace order:469, issue:research-auth-flow-state-machines-2026-07-23

use serde::{Deserialize, Serialize};

/// Provider identifier for auth flows.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
pub enum AuthProvider {
    GitHub,
    Codex,
    OpenCode,
    Antigravity,
}

/// Sibling-II dependency graph node states relevant to auth flow guards.
#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub struct AuthPrerequisites {
    pub enclave_network_up: bool,
    pub egress_network_up: bool,
    pub ca_bundle_valid: bool,
    pub vault_running: bool,
    pub vault_reachable: bool,
    pub proxy_running: bool,
    pub git_identity_configured: bool,
}

/// Named stages of a login flow.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
pub enum LoginStage {
    EnsurePrereqs,
    Collect,
    VerifySession,
    Persist,
    VerifyPersisted,
    StoreIdentity,
}

/// Stable reason codes for blocked states.
#[derive(Debug, Clone, PartialEq, Eq, Hash, Serialize, Deserialize)]
pub enum BlockedReason {
    NoDesktopSession,
    GitIdentityMissing,
    RuntimeAssetsMissing,
    ImageUnavailable,
    DependencyDown(String),
    ServiceUnhealthy(String),
    VaultLease,
    CaBundle,
    HelperStart,
    HelperUnhealthy,
    OperatorAbandoned,
    EmptyToken,
    ProviderReject,
    Deadline,
    SessionInvalid,
    VaultWrite(String),
    VaultReadback,
    NoVaultFeature,
    IdentityInvalid,
}

/// Guard check verdict for a transition.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum GuardVerdict {
    Possible,
    Blocked(BlockedReason),
}

/// Explicit states of the login FSM.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub enum LoginState {
    Idle,
    PrereqsPending,
    AwaitingOperator,
    TokenCollected,
    TokenPersisted,
    TokenVerified,
    Blocked {
        stage: LoginStage,
        reason: BlockedReason,
    },
    Abandoned,
}

impl LoginState {
    pub fn is_terminal(&self) -> bool {
        matches!(
            self,
            LoginState::Idle
                | LoginState::TokenVerified
                | LoginState::Blocked { .. }
                | LoginState::Abandoned
        )
    }

    /// User-visible state representation for tray chips.
    pub fn user_visible_chip_status(&self) -> &'static str {
        match self {
            LoginState::Idle => "Logged Out",
            LoginState::PrereqsPending => "Preparing Enclave...",
            LoginState::AwaitingOperator => "Awaiting Input...",
            LoginState::TokenCollected => "Saving Credentials...",
            LoginState::TokenPersisted => "Verifying Token...",
            LoginState::TokenVerified => "Logged In",
            LoginState::Blocked { .. } => "Login Failed",
            LoginState::Abandoned => "Login Cancelled",
        }
    }
}

/// The login flow finite state machine.
#[derive(Debug, Clone)]
pub struct LoginFlow {
    provider: AuthProvider,
    state: LoginState,
}

impl LoginFlow {
    pub fn new(provider: AuthProvider) -> Self {
        Self {
            provider,
            state: LoginState::Idle,
        }
    }

    pub fn state(&self) -> &LoginState {
        &self.state
    }

    pub fn provider(&self) -> AuthProvider {
        self.provider
    }

    /// Evaluate whether a transition stage is possible against the current graph prerequisites.
    pub fn is_possible(&self, stage: LoginStage, prereqs: &AuthPrerequisites) -> GuardVerdict {
        match stage {
            LoginStage::EnsurePrereqs => {
                if !prereqs.enclave_network_up {
                    GuardVerdict::Blocked(BlockedReason::DependencyDown("enclave_network".into()))
                } else {
                    GuardVerdict::Possible
                }
            }
            LoginStage::Collect => {
                if !prereqs.proxy_running {
                    GuardVerdict::Blocked(BlockedReason::ServiceUnhealthy("proxy".into()))
                } else {
                    GuardVerdict::Possible
                }
            }
            LoginStage::VerifySession => {
                if !prereqs.egress_network_up {
                    GuardVerdict::Blocked(BlockedReason::DependencyDown("egress_network".into()))
                } else {
                    GuardVerdict::Possible
                }
            }
            LoginStage::Persist => {
                if !prereqs.ca_bundle_valid {
                    GuardVerdict::Blocked(BlockedReason::CaBundle)
                } else if !prereqs.vault_running || !prereqs.vault_reachable {
                    GuardVerdict::Blocked(BlockedReason::DependencyDown("vault".into()))
                } else {
                    GuardVerdict::Possible
                }
            }
            LoginStage::VerifyPersisted => {
                if !prereqs.vault_reachable {
                    GuardVerdict::Blocked(BlockedReason::VaultReadback)
                } else {
                    GuardVerdict::Possible
                }
            }
            LoginStage::StoreIdentity => {
                if !prereqs.git_identity_configured {
                    GuardVerdict::Blocked(BlockedReason::GitIdentityMissing)
                } else {
                    GuardVerdict::Possible
                }
            }
        }
    }

    /// Advance the FSM with an event or action.
    pub fn start(&mut self, prereqs: &AuthPrerequisites) -> &LoginState {
        if self.state != LoginState::Idle {
            return &self.state;
        }
        match self.is_possible(LoginStage::EnsurePrereqs, prereqs) {
            GuardVerdict::Possible => {
                self.state = LoginState::PrereqsPending;
            }
            GuardVerdict::Blocked(reason) => {
                self.state = LoginState::Blocked {
                    stage: LoginStage::EnsurePrereqs,
                    reason,
                };
            }
        }
        &self.state
    }

    pub fn prompt_opened(&mut self) -> &LoginState {
        if self.state == LoginState::PrereqsPending {
            self.state = LoginState::AwaitingOperator;
        }
        &self.state
    }

    pub fn token_input_received(&mut self, token: &str) -> &LoginState {
        if self.state != LoginState::AwaitingOperator {
            return &self.state;
        }
        if token.trim().is_empty() {
            self.state = LoginState::Blocked {
                stage: LoginStage::Collect,
                reason: BlockedReason::EmptyToken,
            };
        } else {
            self.state = LoginState::TokenCollected;
        }
        &self.state
    }

    pub fn cancel(&mut self) -> &LoginState {
        self.state = LoginState::Abandoned;
        &self.state
    }

    pub fn persist_token(&mut self, prereqs: &AuthPrerequisites) -> &LoginState {
        if self.state != LoginState::TokenCollected {
            return &self.state;
        }
        match self.is_possible(LoginStage::Persist, prereqs) {
            GuardVerdict::Possible => {
                self.state = LoginState::TokenPersisted;
            }
            GuardVerdict::Blocked(reason) => {
                self.state = LoginState::Blocked {
                    stage: LoginStage::Persist,
                    reason,
                };
            }
        }
        &self.state
    }

    pub fn verify_token(&mut self, prereqs: &AuthPrerequisites) -> &LoginState {
        if self.state != LoginState::TokenPersisted {
            return &self.state;
        }
        match self.is_possible(LoginStage::VerifyPersisted, prereqs) {
            GuardVerdict::Possible => {
                self.state = LoginState::TokenVerified;
            }
            GuardVerdict::Blocked(reason) => {
                self.state = LoginState::Blocked {
                    stage: LoginStage::VerifyPersisted,
                    reason,
                };
            }
        }
        &self.state
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_collected_not_persisted_incident_lands_in_blocked_persist_not_idle() {
        let mut flow = LoginFlow::new(AuthProvider::GitHub);
        let prereqs = AuthPrerequisites {
            enclave_network_up: true,
            egress_network_up: true,
            ca_bundle_valid: false, // CA bundle breaks before vault write
            vault_running: true,
            vault_reachable: true,
            proxy_running: true,
            git_identity_configured: true,
        };
        flow.start(&prereqs);
        assert_eq!(*flow.state(), LoginState::PrereqsPending);
        flow.prompt_opened();
        assert_eq!(*flow.state(), LoginState::AwaitingOperator);
        flow.token_input_received("ghp_test_token_12345");
        assert_eq!(*flow.state(), LoginState::TokenCollected);

        // Attempting persist with invalid CA bundle
        flow.persist_token(&prereqs);
        match flow.state() {
            LoginState::Blocked { stage, reason } => {
                assert_eq!(*stage, LoginStage::Persist);
                assert_eq!(*reason, BlockedReason::CaBundle);
            }
            other => panic!("expected Blocked(Persist, CaBundle), got {:?}", other),
        }
        assert_ne!(*flow.state(), LoginState::Idle);
    }

    #[test]
    fn test_is_possible_persist_returns_blocked_ca_bundle_when_ca_unsatisfied() {
        let flow = LoginFlow::new(AuthProvider::GitHub);
        let prereqs = AuthPrerequisites {
            enclave_network_up: true,
            egress_network_up: true,
            ca_bundle_valid: false, // unsatisfied
            vault_running: true,
            vault_reachable: true,
            proxy_running: true,
            git_identity_configured: true,
        };
        let verdict = flow.is_possible(LoginStage::Persist, &prereqs);
        assert_eq!(verdict, GuardVerdict::Blocked(BlockedReason::CaBundle));
    }

    #[test]
    fn test_full_happy_path_reaches_token_verified() {
        let mut flow = LoginFlow::new(AuthProvider::GitHub);
        let prereqs = AuthPrerequisites {
            enclave_network_up: true,
            egress_network_up: true,
            ca_bundle_valid: true,
            vault_running: true,
            vault_reachable: true,
            proxy_running: true,
            git_identity_configured: true,
        };
        flow.start(&prereqs);
        assert_eq!(*flow.state(), LoginState::PrereqsPending);
        flow.prompt_opened();
        assert_eq!(*flow.state(), LoginState::AwaitingOperator);
        flow.token_input_received("ghp_valid_token_xyz");
        assert_eq!(*flow.state(), LoginState::TokenCollected);
        flow.persist_token(&prereqs);
        assert_eq!(*flow.state(), LoginState::TokenPersisted);
        flow.verify_token(&prereqs);
        assert_eq!(*flow.state(), LoginState::TokenVerified);
    }
}
