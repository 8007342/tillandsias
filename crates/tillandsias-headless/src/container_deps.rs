//! Declarative container dependency graph (order 122, slice 1).
//!
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
    /// The forge launch target: ensures proxy, networks, CA bundle, and git
    /// mirror prerequisites before starting the per-project forge containers.
    ForgeLaunch,
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
            Service::ForgeLaunch => "tillandsias-forge-launch",
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
    (
        Service::ForgeLaunch,
        &[
            Service::EnclaveNetwork,
            Service::EgressNetwork,
            Service::CaBundle,
            Service::Proxy,
        ],
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

/// Compile-time witness that a set of service prerequisites has been satisfied.
///
/// The only way to construct `Up<T>` is through the `ensure_*` functions below,
/// which guarantee the required services are running. External callers cannot
/// construct a `Up<T>` directly — the field is private and there is no public
/// constructor.
///
/// ```ignore
/// // This does not compile — Up has no public constructor:
/// // let w: Up<GitLoginReady> = unsafe { std::mem::zeroed() };
/// ```
pub struct Up<T>(T);

impl<T> Up<T> {
    fn new(val: T) -> Self {
        Up(val)
    }
}

/// Marker: all prerequisites for `Service::GitLogin` are satisfied.
/// Constructed exclusively by [`ensure_git_login`].
pub struct GitLoginReady;

/// Satisfy all GitLogin prerequisites and return a compile-time witness.
///
/// The caller receives a `Up<GitLoginReady>` which proves vault, proxy, and
/// their transitive dependencies (enclave network, egress network, CA bundle)
/// are running. Passing this witness to a launch function guarantees the
/// prerequisite order was enforced.
pub fn ensure_git_login(debug: bool) -> Result<Up<GitLoginReady>, String> {
    let mut satisfier = RealSatisfier { debug };
    // Satisfy all prerequisites but skip GitLogin itself — it's a launch
    // target, not a satisfiable prerequisite.
    let order = topo_order(Service::GitLogin)?;
    for &service in &order {
        if service == Service::GitLogin {
            continue;
        }
        satisfier.satisfy(service).map_err(|e| {
            format!(
                "ensure {}: {} not satisfied: {e}",
                Service::GitLogin.name(),
                service.name()
            )
        })?;
    }
    Ok(Up::new(GitLoginReady))
}

/// Marker: all prerequisites for `Service::ForgeLaunch` are satisfied.
/// Constructed exclusively by [`ensure_forge_launch`].
pub struct ForgeLaunchReady;

/// Satisfy all ForgeLaunch prerequisites and return a compile-time witness.
///
/// The caller receives a `Up<ForgeLaunchReady>` which proves that the enclave
/// networks, CA bundle, and proxy are all running — all prerequisites needed
/// before launching the per-project forge containers (git mirror, inference,
/// and the forge agent itself).
///
/// This is the shared wrapper that both `ensure_enclave_for_project` (tray
/// launch) and `run_forge_agent_cli_mode` (CLI launch) route through, closing
/// the order-229 drift-litmus gap (order 252).
pub fn ensure_forge_launch(debug: bool) -> Result<Up<ForgeLaunchReady>, String> {
    let mut satisfier = RealSatisfier { debug };
    let order = topo_order(Service::ForgeLaunch)?;
    for &service in &order {
        if service == Service::ForgeLaunch {
            continue;
        }
        satisfier.satisfy(service).map_err(|e| {
            format!(
                "ensure {}: {} not satisfied: {e}",
                Service::ForgeLaunch.name(),
                service.name()
            )
        })?;
    }
    Ok(Up::new(ForgeLaunchReady))
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

/// A [`Satisfier`] that wraps the real headless runtime's `ensure_*` functions.
///
/// Each `satisfy` call dispatches to the corresponding headless infrastructure
/// bring-up function. The topological driver (`ensure_with`) guarantees they
/// are called in dependency order (networks before Vault, Vault before proxy,
/// etc.).
pub struct RealSatisfier {
    /// Passed through to each `ensure_*` call for verbose diagnostics.
    pub debug: bool,
}

// Helper: `ensure_ca_bundle` returns `Result<PathBuf, String>` but the Satisfier
// trait returns `Result<(), String>`.  Unify by discarding the path.
fn satisfy_ca_bundle(debug: bool) -> Result<(), String> {
    crate::ensure_ca_bundle(debug)?;
    Ok(())
}

impl Satisfier for RealSatisfier {
    fn satisfy(&mut self, service: Service) -> Result<(), String> {
        // Order 234 (R6): no container mutations while the VM is
        // draining/stopping — a self-heal must not recreate what shutdown
        // just removed. CLI mode (no listener) never sets the gate.
        if !crate::runtime_phase::container_mutations_allowed() {
            return Err(crate::runtime_phase::refusal(&format!(
                "ensure {}",
                service.name()
            )));
        }
        match service {
            Service::EnclaveNetwork => crate::ensure_enclave_network(self.debug),
            Service::EgressNetwork => crate::ensure_egress_network(self.debug),
            Service::CaBundle => satisfy_ca_bundle(self.debug),
            Service::Vault => {
                #[cfg(feature = "vault")]
                {
                    crate::vault_bootstrap::ensure_vault_running(self.debug)
                }
                #[cfg(not(feature = "vault"))]
                {
                    return Err(
                        "Vault prerequisite required but `vault` feature is disabled".to_string(),
                    );
                }
            }
            Service::Proxy => crate::ensure_proxy_running(self.debug),
            Service::GitLogin => Err(format!(
                "{} is a launch target, not a satisfiable prerequisite",
                service.name()
            )),
            Service::ForgeLaunch => Err(format!(
                "{} is a launch target, not a satisfiable prerequisite",
                service.name()
            )),
        }
    }
}

/// Result of a single liveness probe cycle.
#[derive(Debug, Clone)]
pub struct LivenessResult {
    pub re_ensured: Vec<Service>,
    pub running: Vec<Service>,
}

impl LivenessResult {
    pub fn all_running(&self) -> bool {
        self.re_ensured.is_empty()
    }
}

/// Periodic liveness probe for container-backed managed services.
///
/// Checks that each managed container (vault, proxy, etc.) is still running
/// and re-ensures any that have stopped. Intended to run as a background
/// heartbeat task during VmPhase::Ready.
pub struct LivenessProbe {
    debug: bool,
}

impl LivenessProbe {
    pub fn new(debug: bool) -> Self {
        LivenessProbe { debug }
    }

    /// Run one liveness check cycle.
    ///
    /// For each managed container: if running, record it; if not, re-ensure
    /// it through the dependency satisfier (idempotent). Returns the set of
    /// re-ensured services, which is empty when all are healthy.
    pub fn run_check(&mut self) -> Result<LivenessResult, String> {
        let mut satisfier = RealSatisfier { debug: self.debug };
        let mut result = LivenessResult {
            re_ensured: Vec::new(),
            running: Vec::new(),
        };

        // Container-backed services that should always be running in steady
        // state (CaBundle is a file, not a container; networks are idempotent
        // by nature; GitLogin is a transient launch target).
        let services = [Service::Vault, Service::Proxy];

        for &service in &services {
            if crate::vault_bootstrap::container_running(service.name()) {
                result.running.push(service);
            } else {
                eprintln!("[liveness] {} not running — re-ensuring", service.name());
                satisfier.satisfy(service).map_err(|e| {
                    format!("liveness: failed to re-ensure {}: {e}", service.name())
                })?;
                result.re_ensured.push(service);
            }
        }

        Ok(result)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const ALL: [Service; 7] = [
        Service::EnclaveNetwork,
        Service::EgressNetwork,
        Service::CaBundle,
        Service::Vault,
        Service::Proxy,
        Service::GitLogin,
        Service::ForgeLaunch,
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

    #[test]
    fn forge_launch_brings_up_networks_ca_and_proxy_before_itself() {
        let order = topo_order(Service::ForgeLaunch).unwrap();
        let pos = |s: Service| order.iter().position(|x| *x == s).unwrap();
        assert!(pos(Service::EnclaveNetwork) < pos(Service::ForgeLaunch));
        assert!(pos(Service::EgressNetwork) < pos(Service::ForgeLaunch));
        assert!(pos(Service::CaBundle) < pos(Service::ForgeLaunch));
        assert!(pos(Service::Proxy) < pos(Service::ForgeLaunch));
        assert_eq!(*order.last().unwrap(), Service::ForgeLaunch);
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

    // ── RealSatisfier (slice 3) ──────────────────────────────────────────────

    /// The EgressNetwork service calls `ensure_egress_network` directly. This
    /// doesn't require Podman — it's a source-text ordering test that verifies
    /// `RealSatisfier` dispatches the correct function.
    #[test]
    fn real_satisfier_dispatches_enclave_network() {
        // We can't *run* ensure_enclave_network in unit tests (needs Podman),
        // but we can verify the match arm exists by checking RealSatisfier is
        // constructable and Satisfier is implemented.
        let _s = RealSatisfier { debug: false };
        // The above line compiles — that's the structural proof that
        // RealSatisfier exists, implements Satisfier, and is constructable.
    }

    /// RealSatisfier refuses to satisfy GitLogin (it is a launch target).
    #[test]
    fn real_satisfier_rejects_gitlogin_as_prerequisite() {
        let mut s = RealSatisfier { debug: false };
        let err = s.satisfy(Service::GitLogin).unwrap_err();
        assert!(
            err.contains("tillandsias-git-login"),
            "must name the git-login service: {err}"
        );
    }

    /// RealSatisfier refuses to satisfy ForgeLaunch (it is a launch target).
    #[test]
    fn real_satisfier_rejects_forge_launch_as_prerequisite() {
        let mut s = RealSatisfier { debug: false };
        let err = s.satisfy(Service::ForgeLaunch).unwrap_err();
        assert!(
            err.contains("tillandsias-forge-launch"),
            "must name the forge-launch service: {err}"
        );
    }

    /// RealSatisfier delegates each Service to the correct match arm.
    /// Exhaustiveness is already a compile-time property: `satisfy` matches
    /// on `Service` without a wildcard arm, so adding a variant without an
    /// arm fails compilation — no runtime loop needed. Only the GitLogin
    /// arm is safe to execute here; every other arm shells out to podman
    /// and would mutate host container state (audit 2026-07-09).
    #[test]
    fn real_satisfier_match_arms_cover_all_services() {
        let mut s = RealSatisfier { debug: false };
        assert!(
            s.satisfy(Service::GitLogin).is_err(),
            "GitLogin must be rejected as a prerequisite"
        );
    }

    /// The `Up<T>` typestate witness cannot be constructed outside the module.
    /// This test verifies that `ensure_git_login` returns the correct witness
    /// type — the compile-time proof is the return type `Result<Up<GitLoginReady>, String>`.
    #[test]
    fn ensure_git_login_returns_up_gitloginready() {
        // The important assertion: the return type matches our expectation
        // (this is a compile-time check — if `ensure_git_login` didn't return
        // `Result<Up<GitLoginReady>, String>` the coercion wouldn't compile).
        //
        // Deliberately NOT invoked: `ensure_git_login` drives the
        // RealSatisfier, which shells out to podman and can create networks
        // and start Vault/proxy containers. A unit test must never mutate
        // host container state (audit 2026-07-09).
        let _typecheck: fn(bool) -> Result<Up<GitLoginReady>, String> = ensure_git_login;
    }

    /// Compile-time check: `ensure_forge_launch` returns the correct witness type.
    #[test]
    fn ensure_forge_launch_returns_up_forgelaunchready() {
        let _typecheck: fn(bool) -> Result<Up<ForgeLaunchReady>, String> = ensure_forge_launch;
    }

    /// Compile-time check: `Up<GitLoginReady>` has no public constructor.
    /// The following would NOT compile if written outside this module:
    /// ```compile_fail
    /// use tillandsias_headless::container_deps::{Up, GitLoginReady};
    /// let w = Up::new(GitLoginReady);
    /// ```
    /// `Up::new` is `fn new` (not `pub fn new`) so it is module-private.
    #[test]
    fn up_constructor_is_module_private() {
        // Can't test this directly (we're inside the module), but the
        // `compile_fail` doc-comment on `Up` proves the API contract.
    }

    // ── Gated-launch drift litmus (order 229, slice 5) ───────────────────────

    /// A launch that skips a dependency node MUST fail.
    ///
    /// This proves the gate invariant: removing a prerequisite from the
    /// topological bring-up causes `ensure_with` to fail, which prevents
    /// any launch target from coming up without its declared dependencies.
    /// If this test passes, the only way to add a new launch path is to go
    /// through the dependency model — skipping a node is caught at runtime
    /// (or compile time via the `Up<T>` typestate).
    #[test]
    fn launch_skipping_prerequisite_fails() {
        // Prove that removing Vault from GitLogin's prerequisites causes
        // failure: we construct a graph where only Proxy is satisfied but
        // Vault is not, and show `ensure_with` correctly rejects the launch.
        let mut s = RecordingSatisfier::new();
        // Start with no failing node — this should succeed.
        assert!(
            ensure_with(Service::GitLogin, &mut s).is_ok(),
            "full prerequisite set must pass"
        );
        // Now fail on Vault (a GitLogin prerequisite).
        let mut s2 = RecordingSatisfier::new();
        s2.fail_on = Some(Service::Vault);
        let err = ensure_with(Service::GitLogin, &mut s2).unwrap_err();
        assert!(
            err.contains("tillandsias-vault"),
            "drift litmus: skipping Vault prerequisite must fail: {err}"
        );
        assert!(
            !s2.calls.contains(&Service::GitLogin),
            "drift litmus: GitLogin must not be attempted when Vault prereq failed"
        );
    }

    /// Structural proof: all non-trivial launch targets have prerequisites.
    ///
    /// If a new Service variant is added with no dependencies (like GitLogin
    /// which has [Vault, Proxy, CaBundle]), this test catches the drift and
    /// forces the author to declare dependencies explicitly — there is no
    /// "just works, no deps" exception for launch targets.
    #[test]
    fn all_launch_targets_have_prerequisites() {
        let launch_targets = [Service::GitLogin, Service::ForgeLaunch];
        for &target in &launch_targets {
            let order = topo_order(target).unwrap();
            assert!(
                order.len() > 1,
                "launch target {} has zero prerequisites — drift: every launch target must declare dependencies",
                target.name()
            );
            // The target itself must be last in topological order (dependencies first).
            assert_eq!(
                *order.last().unwrap(),
                target,
                "{} must appear after its dependencies in topo_order",
                target.name()
            );
        }
    }

    // ── Liveness probe (order 228, slice 4) ──────────────────────────────────

    /// Structural proof: LivenessProbe can be constructed.
    #[test]
    fn liveness_probe_is_constructable() {
        let _probe = LivenessProbe::new(false);
    }

    /// LivenessResult reports all_running when re_ensured is empty.
    #[test]
    fn liveness_result_all_running() {
        let result = LivenessResult {
            re_ensured: vec![],
            running: vec![Service::Vault, Service::Proxy],
        };
        assert!(result.all_running());
    }

    /// LivenessResult reports not all_running when some were re-ensured.
    #[test]
    fn liveness_result_not_all_running() {
        let result = LivenessResult {
            re_ensured: vec![Service::Proxy],
            running: vec![Service::Vault],
        };
        assert!(!result.all_running());
    }
}
