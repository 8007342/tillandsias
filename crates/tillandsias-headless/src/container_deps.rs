//! Declarative container dependency graph (order 122, slice 1).
//!
//! Single source of truth for "what must be satisfied before launching X".
//! Four consecutive P0s (orders 116/118/119/120) were all caused by an implicit,
//! runtime-discovered container dependency — most directly order 120, where the
//! standalone GitHub-login flow never started the enclave proxy it needs for
//! egress. This module makes those edges explicit and machine-checkable.
//!
//! Slice 1 is intentionally additive and behavior-free: it declares the graph
//! and proves it well-formed (acyclic + complete) and topologically orderable.
//! Later slices (per the order-121 verdict) add the `ensure::<S>()` topological
//! bring-up, typestate `Up<S>` launch witnesses (so omitting a prerequisite is a
//! compile error), runtime liveness probing, and a drift litmus.
//!
//! @trace plan/issues/container-dependency-graph-impl-2026-06-27.md
//! @trace plan/issues/container-dependency-graph-research-2026-06-27.md

#![allow(dead_code)] // Wired into launch paths in order-122 slices 2+.

/// A managed enclave prerequisite that a container launch can depend on.
///
/// Network/CA-bundle/service nodes are modeled uniformly as graph nodes so the
/// single acyclic check covers every prerequisite kind (the order-121 taxonomy's
/// `NetworkPresent`, `CaBundle`, `ServiceRunning`, `ProxyEgress`, `VaultUnsealed`).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum Service {
    /// `tillandsias-enclave` (internal) podman network.
    EnclaveNetwork,
    /// `tillandsias-egress` (NAT) podman network.
    EgressNetwork,
    /// Materialized CA bundle under `/tmp/tillandsias-ca`.
    CaBundle,
    /// `tillandsias-vault` running, initialized, and unsealed.
    Vault,
    /// `tillandsias-proxy` (squid) — the only external egress path.
    Proxy,
    /// The `tillandsias-git` container used by `--github-login` and
    /// `--list-cloud-projects` (reads/writes Vault, egresses via Proxy).
    GitLogin,
}

impl Service {
    /// Stable identifier (container/network name where applicable).
    pub fn name(self) -> &'static str {
        match self {
            Service::EnclaveNetwork => "tillandsias-enclave",
            Service::EgressNetwork => "tillandsias-egress",
            Service::CaBundle => "ca-bundle",
            Service::Vault => "tillandsias-vault",
            Service::Proxy => "tillandsias-proxy",
            Service::GitLogin => "tillandsias-git-login",
        }
    }
}

/// The declared dependency edges: each node maps to the prerequisites that must
/// be satisfied (and brought up, in later slices) before it.
///
/// This is the ONLY place container prerequisites are declared. Adding a new
/// container adds one row here and inherits correct topological bring-up
/// everywhere `ensure()` is used (slice 2+).
const DEPS: &[(Service, &[Service])] = &[
    (Service::EnclaveNetwork, &[]),
    (Service::EgressNetwork, &[]),
    (Service::CaBundle, &[]),
    (Service::Vault, &[Service::EnclaveNetwork]),
    (
        Service::Proxy,
        &[
            Service::EnclaveNetwork,
            Service::EgressNetwork,
            Service::CaBundle,
        ],
    ),
    (
        Service::GitLogin,
        &[Service::Vault, Service::Proxy, Service::CaBundle],
    ),
];

/// Direct prerequisites of `service`.
pub fn deps(service: Service) -> &'static [Service] {
    DEPS.iter()
        .find(|(node, _)| *node == service)
        .map(|(_, d)| *d)
        .unwrap_or(&[])
}

/// Whether `service` is declared as a node in the graph.
fn is_declared(service: Service) -> bool {
    DEPS.iter().any(|(node, _)| *node == service)
}

/// Topological bring-up order to satisfy `target` (dependencies first, `target`
/// last). Returns `Err` if a cycle is encountered. This is the order
/// `ensure::<target>()` will follow in slice 2.
pub fn topo_order(target: Service) -> Result<Vec<Service>, String> {
    let mut order = Vec::new();
    let mut visiting = Vec::new();
    visit(target, &mut order, &mut visiting)?;
    Ok(order)
}

fn visit(
    node: Service,
    order: &mut Vec<Service>,
    visiting: &mut Vec<Service>,
) -> Result<(), String> {
    if order.contains(&node) {
        return Ok(());
    }
    if visiting.contains(&node) {
        return Err(format!(
            "container dependency cycle detected at {}",
            node.name()
        ));
    }
    visiting.push(node);
    for &dep in deps(node) {
        visit(dep, order, visiting)?;
    }
    visiting.pop();
    order.push(node);
    Ok(())
}

/// Brings a single [`Service`] up (idempotently). Implemented by the headless
/// runtime in slice 3 (wrapping `ensure_enclave_network` / `ensure_vault_running`
/// / `ensure_proxy_running` / `ensure_ca_bundle`); the driver below calls
/// `satisfy` for each node in topological order.
///
/// Kept as a trait so the topological driver is unit-testable with a recording
/// fake — the order-120 class of bug (a prerequisite simply never started) is
/// then a graph property we can assert, not a runtime surprise.
pub trait Satisfier {
    /// Bring `service` up, or return why it could not. MUST be idempotent and
    /// cheap when already satisfied.
    fn satisfy(&mut self, service: Service) -> Result<(), String>;
}

/// Topologically satisfy `target` and all its prerequisites, dependencies first.
///
/// Returns the bring-up order actually executed. Stops at the first `satisfy`
/// error (a prerequisite failing means the target cannot come up). This is the
/// single entry point all launch paths will route through (slice 3), replacing
/// the ad-hoc `ensure_*` call chains.
pub fn ensure_with<S: Satisfier>(
    target: Service,
    satisfier: &mut S,
) -> Result<Vec<Service>, String> {
    let order = topo_order(target)?;
    for &service in &order {
        satisfier.satisfy(service).map_err(|e| {
            format!(
                "ensure {}: {} not satisfied: {e}",
                target.name(),
                service.name()
            )
        })?;
    }
    Ok(order)
}

#[cfg(test)]
mod tests {
    use super::*;

    const ALL: [Service; 6] = [
        Service::EnclaveNetwork,
        Service::EgressNetwork,
        Service::CaBundle,
        Service::Vault,
        Service::Proxy,
        Service::GitLogin,
    ];

    /// Verifiable closure for slice 1: the graph is complete (every node and
    /// every referenced dependency is a declared node) and acyclic (every node
    /// has a valid topological order).
    #[test]
    fn dependency_graph_is_complete_and_acyclic() {
        // Every variant is declared exactly once.
        for s in ALL {
            assert_eq!(
                DEPS.iter().filter(|(n, _)| *n == s).count(),
                1,
                "{} must be declared exactly once",
                s.name()
            );
        }
        // Every referenced dependency is itself a declared node.
        for (node, ds) in DEPS {
            for d in *ds {
                assert!(
                    is_declared(*d),
                    "{} depends on undeclared node {}",
                    node.name(),
                    d.name()
                );
            }
        }
        // Acyclic: every node yields a topological order.
        for s in ALL {
            assert!(topo_order(s).is_ok(), "{} is not orderable", s.name());
        }
    }

    #[test]
    fn gitlogin_brings_up_vault_and_proxy_before_itself() {
        // The order-120 regression in graph form: launching the git-login
        // container requires Vault AND Proxy (and their network/CA prerequisites)
        // to come up first.
        let order = topo_order(Service::GitLogin).unwrap();
        let pos = |s: Service| order.iter().position(|x| *x == s).unwrap();

        assert!(pos(Service::Vault) < pos(Service::GitLogin));
        assert!(pos(Service::Proxy) < pos(Service::GitLogin));
        assert!(pos(Service::EnclaveNetwork) < pos(Service::Vault));
        assert!(pos(Service::EnclaveNetwork) < pos(Service::Proxy));
        assert!(pos(Service::EgressNetwork) < pos(Service::Proxy));
        assert!(pos(Service::CaBundle) < pos(Service::Proxy));
        assert_eq!(*order.last().unwrap(), Service::GitLogin);
    }

    #[test]
    fn leaf_nodes_have_no_dependencies() {
        for s in [
            Service::EnclaveNetwork,
            Service::EgressNetwork,
            Service::CaBundle,
        ] {
            assert!(deps(s).is_empty(), "{} should be a leaf", s.name());
            assert_eq!(topo_order(s).unwrap(), vec![s]);
        }
    }

    /// Records every `satisfy` call so tests can assert bring-up order; can be
    /// told to fail on a specific node to prove error propagation.
    struct RecordingSatisfier {
        calls: Vec<Service>,
        fail_on: Option<Service>,
    }
    impl RecordingSatisfier {
        fn new() -> Self {
            Self {
                calls: Vec::new(),
                fail_on: None,
            }
        }
    }
    impl Satisfier for RecordingSatisfier {
        fn satisfy(&mut self, service: Service) -> Result<(), String> {
            self.calls.push(service);
            if self.fail_on == Some(service) {
                return Err("forced failure".to_string());
            }
            Ok(())
        }
    }

    #[test]
    fn ensure_with_satisfies_prerequisites_before_target() {
        // The order-120 fix as an executable invariant: ensure(GitLogin) brings up
        // its network/ca/vault/proxy prerequisites — in dependency order — before
        // GitLogin itself.
        let mut s = RecordingSatisfier::new();
        let order = ensure_with(Service::GitLogin, &mut s).unwrap();
        assert_eq!(order, s.calls, "ensure must satisfy in the returned order");
        let pos = |x: Service| s.calls.iter().position(|c| *c == x).unwrap();
        assert!(pos(Service::Vault) < pos(Service::GitLogin));
        assert!(pos(Service::Proxy) < pos(Service::GitLogin));
        assert_eq!(*s.calls.last().unwrap(), Service::GitLogin);
    }

    #[test]
    fn ensure_with_stops_and_reports_on_unsatisfied_prerequisite() {
        // If a prerequisite can't come up, the target must not be attempted.
        let mut s = RecordingSatisfier::new();
        s.fail_on = Some(Service::Proxy);
        let err = ensure_with(Service::GitLogin, &mut s).unwrap_err();
        assert!(
            err.contains("tillandsias-proxy"),
            "err names the failed node: {err}"
        );
        assert!(
            !s.calls.contains(&Service::GitLogin),
            "GitLogin must not be satisfied after a prerequisite failed"
        );
    }
}
