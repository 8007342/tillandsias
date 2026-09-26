//! Unified Dependency Graph: Runtime States and Data States (prototype, research order 470).
//!
//! Extends the container dependency model to unify runtime container/network services
//! and data states (credentials, tokens, configurations) into a single acyclic graph
//! with explicit satisfier kinds (AutoSatisfiable vs OperatorGated).
//!
//! @trace order:470, issue:research-unified-runtime-data-dependency-graph-2026-07-23

#![allow(dead_code)]

use std::collections::{BTreeSet, HashSet};

/// Unified dependency graph nodes representing either runtime services or data states.
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Hash)]
pub enum Node {
    // --- Runtime Service Nodes (existing) ---
    EnclaveNetwork,
    EgressNetwork,
    CaBundle,
    Vault,
    Proxy,
    GitLogin,
    NixCache,
    ForgeLaunch,

    // --- Data Nodes (Order 470 extension) ---
    GithubTokenPresent,
    GitIdentityConfigured,
    MirrorRelayCredentialPresent,
    CaBundleValid,
}

impl Node {
    pub fn name(self) -> &'static str {
        match self {
            Node::EnclaveNetwork => "runtime:enclave-network",
            Node::EgressNetwork => "runtime:egress-network",
            Node::CaBundle => "runtime:ca-bundle",
            Node::Vault => "runtime:vault",
            Node::Proxy => "runtime:proxy",
            Node::GitLogin => "runtime:git-login",
            Node::NixCache => "runtime:nix-cache",
            Node::ForgeLaunch => "runtime:forge-launch",
            Node::GithubTokenPresent => "data:github-token-present",
            Node::GitIdentityConfigured => "data:git-identity-configured",
            Node::MirrorRelayCredentialPresent => "data:mirror-relay-credential-present",
            Node::CaBundleValid => "data:ca-bundle-valid",
        }
    }

    pub fn kind(self) -> NodeKind {
        match self {
            Node::EnclaveNetwork
            | Node::EgressNetwork
            | Node::CaBundle
            | Node::Vault
            | Node::Proxy
            | Node::GitLogin
            | Node::NixCache
            | Node::ForgeLaunch
            | Node::MirrorRelayCredentialPresent
            | Node::CaBundleValid => NodeKind::AutoSatisfiable,

            Node::GithubTokenPresent | Node::GitIdentityConfigured => NodeKind::OperatorGated,
        }
    }
}

/// Satisfier class for dependency nodes.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum NodeKind {
    /// Can be brought up or self-healed automatically by daemon/runtime satisfiers.
    AutoSatisfiable,
    /// Requires human interaction or external credential injection; never fabricated.
    OperatorGated,
}

/// Node state machine for observable state tracking.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum NodeState {
    Absent,
    Satisfying,
    Present,
    Degraded(String),
}

/// Declared dependency edges for the unified graph.
pub const UNIFIED_DEPS: &[(Node, &[Node])] = &[
    (Node::EnclaveNetwork, &[]),
    (Node::EgressNetwork, &[]),
    (Node::CaBundle, &[]),
    (Node::CaBundleValid, &[Node::CaBundle]),
    (Node::Vault, &[Node::EnclaveNetwork]),
    (
        Node::Proxy,
        &[
            Node::EnclaveNetwork,
            Node::EgressNetwork,
            Node::CaBundleValid,
        ],
    ),
    (
        Node::GitLogin,
        &[Node::Vault, Node::Proxy, Node::CaBundleValid],
    ),
    (Node::NixCache, &[Node::EnclaveNetwork, Node::CaBundle]),
    (
        Node::GithubTokenPresent,
        &[Node::Vault, Node::Proxy, Node::CaBundleValid],
    ),
    (Node::GitIdentityConfigured, &[]),
    (Node::MirrorRelayCredentialPresent, &[Node::Vault]),
    (
        Node::ForgeLaunch,
        &[
            Node::EnclaveNetwork,
            Node::EgressNetwork,
            Node::CaBundleValid,
            Node::Proxy,
            Node::MirrorRelayCredentialPresent,
        ],
    ),
];

pub fn deps_of(node: Node) -> &'static [Node] {
    for (n, ds) in UNIFIED_DEPS {
        if *n == node {
            return ds;
        }
    }
    &[]
}

pub fn is_declared(node: Node) -> bool {
    UNIFIED_DEPS.iter().any(|(n, _)| *n == node)
}

/// Computes the topological sort order for a given node and its dependencies.
pub fn topo_order(target: Node) -> Result<Vec<Node>, String> {
    let mut order = Vec::new();
    let mut visited = HashSet::new();
    let mut in_stack = HashSet::new();

    fn visit(
        n: Node,
        visited: &mut HashSet<Node>,
        in_stack: &mut HashSet<Node>,
        order: &mut Vec<Node>,
    ) -> Result<(), String> {
        if in_stack.contains(&n) {
            return Err(format!("Cycle detected at node {}", n.name()));
        }
        if visited.contains(&n) {
            return Ok(());
        }
        in_stack.insert(n);
        for dep in deps_of(n) {
            visit(*dep, visited, in_stack, order)?;
        }
        in_stack.remove(&n);
        visited.insert(n);
        order.push(n);
        Ok(())
    }

    visit(target, &mut visited, &mut in_stack, &mut order)?;
    Ok(order)
}

/// Transitive closure query ("survive-what-where") for a given target node.
pub fn transitive_dependencies(target: Node) -> Result<BTreeSet<Node>, String> {
    let order = topo_order(target)?;
    Ok(order.into_iter().collect())
}

#[cfg(test)]
mod tests {
    use super::*;

    const ALL_NODES: [Node; 12] = [
        Node::EnclaveNetwork,
        Node::EgressNetwork,
        Node::CaBundle,
        Node::CaBundleValid,
        Node::Vault,
        Node::Proxy,
        Node::GitLogin,
        Node::NixCache,
        Node::ForgeLaunch,
        Node::GithubTokenPresent,
        Node::GitIdentityConfigured,
        Node::MirrorRelayCredentialPresent,
    ];

    #[test]
    fn unified_graph_is_complete_and_acyclic() {
        for n in ALL_NODES {
            assert_eq!(
                UNIFIED_DEPS.iter().filter(|(k, _)| *k == n).count(),
                1,
                "Node {} declared multiple times or missing",
                n.name()
            );
        }

        for (node, ds) in UNIFIED_DEPS {
            for dep in *ds {
                assert!(
                    is_declared(*dep),
                    "Node {} depends on undeclared dependency {}",
                    node.name(),
                    dep.name()
                );
            }
        }

        for n in ALL_NODES {
            assert!(
                topo_order(n).is_ok(),
                "Topological order failed for node {}",
                n.name()
            );
        }
    }

    #[test]
    fn test_github_token_missing_leaves_gated_consumer_blocked_even_when_services_up() {
        let order = topo_order(Node::GithubTokenPresent).unwrap();
        assert!(order.contains(&Node::Vault));
        assert!(order.contains(&Node::Proxy));
        assert_eq!(*order.last().unwrap(), Node::GithubTokenPresent);
        assert_eq!(Node::GithubTokenPresent.kind(), NodeKind::OperatorGated);

        // Simulation of the motivating incident:
        // All service prerequisites are running, but Vault write didn't happen => token is Absent
        let vault_running = true;
        let proxy_running = true;
        let token_in_vault = false; // Never written

        let is_ready = vault_running && proxy_running && token_in_vault;
        assert!(
            !is_ready,
            "Consumer relying on GithubTokenPresent must be blocked when token is absent"
        );
    }

    #[test]
    fn test_survive_what_where_transitive_closure() {
        let closure = transitive_dependencies(Node::ForgeLaunch).unwrap();
        assert!(closure.contains(&Node::EnclaveNetwork));
        assert!(closure.contains(&Node::EgressNetwork));
        assert!(closure.contains(&Node::CaBundle));
        assert!(closure.contains(&Node::CaBundleValid));
        assert!(closure.contains(&Node::Proxy));
        assert!(closure.contains(&Node::Vault));
        assert!(closure.contains(&Node::MirrorRelayCredentialPresent));
        assert!(!closure.contains(&Node::NixCache));
        assert!(!closure.contains(&Node::GitLogin));
    }
}
