# RESEARCH: unified dependency graph — runtime states AND data states as first-class nodes, with FSM guardrails (2026-07-23)

- **Class**: research (MANDATORY before implementation, operator standing rule)
- **Status**: proposed
- **Desired release**: future (v0.5+) — NOT blocking current v0.4/v0.3 work; durable direction
- **Owner host**: any (extends the shared `tillandsias-headless::container_deps` graph consumed by every launch path on all hosts)
- **Operator vision (2026-07-23, The Tlatoāni, paraphrased)**: dependencies should be
  modeled as BOTH runtime states (a container is running) AND data states (e.g. "GitHub
  token present in Vault", "git identity configured"). The unified dependency + state
  graph should provide safe GUARDRAILS so we can quickly tweak and tune containers and
  add features/gates WITHOUT regressions — ending the current whack-a-mole of figuring
  out "what needs to survive where."
- **Motivating incident**: `plan/issues/macos-tray-github-login-stuck-no-prompt-refresh-2026-07-23.md`
- **Sibling packets (non-overlapping, file together)**:
  - `plan/issues/research-auth-flow-state-machines-2026-07-23.md` (the login FSM whose guards read this graph's DATA nodes)
  - `plan/issues/research-flow-state-event-channel-2026-07-23.md` (the channel that emits node-state transitions as observable events)

## Motivation

The runtime dependency graph already exists and is mature:
`crates/tillandsias-headless/src/container_deps.rs` declares a `Service` node set
(`container_deps.rs:27-44`: `EnclaveNetwork`, `EgressNetwork`, `CaBundle`, `Vault`,
`Proxy`, `GitLogin`, `ForgeLaunch`), an explicit edge table (`DEPS`,
`container_deps.rs:67-99`), a topological driver with cycle detection (`topo_order` /
`visit`, `container_deps.rs:117-145`), a `Satisfier` trait + `RealSatisfier`
(`container_deps.rs:244-329`), a compile-time `Up<T>` typestate witness so a launch that
skips a prerequisite is a **compile** error (`container_deps.rs:158-226`), a
`LivenessProbe` that re-ensures stopped containers (`container_deps.rs:349-388`), and a
drift litmus that fails any launch skipping a node (`launch_skipping_prerequisite_fails`,
`container_deps.rs:628`). It was born from four consecutive P0s
(orders 116/118/119/120) caused by implicit, runtime-discovered container dependencies —
most directly order 120, where standalone GitHub login never started the enclave proxy it
needed (`container_deps.rs:4-8`).

**But every node is a *running container / network / file*. There is no node for a *data
state*.** `GitLogin` depends on `Vault` being **running** (`container_deps.rs:81-83`) — but
NOT on the token being **present** in Vault. So `run_provider_login` can satisfy the entire
graph (`ensure_git_login`, `main.rs:6890`), collect the PAT, and still exit before the
Vault write (`main.rs:7051-7064`) — and the graph is perfectly "satisfied" the whole time,
because *token present* was never a node. Downstream, a forge launch requires the Vault
*container* but the git-mirror-relay credential being *present* is enforced ad hoc at
launch (`container_deps.rs:91-96` comment), not as a graph node. That is precisely the
whack-a-mole: "what must survive where" is scattered across imperative checks
(`check_auth_required_services`, `main.rs:6903`; `vault_bootstrap::is_github_key_present`;
`remote_projects::is_github_logged_in`, `remote_projects.rs:415`) instead of being nodes
with edges and a single satisfier.

Modeling data states as first-class nodes turns "did we remember to check the token here?"
into a graph-completeness property the existing acyclic/complete litmus already knows how
to enforce (`dependency_graph_is_complete_and_acyclic`, `container_deps.rs:409`).

## Proposed model

Extend the `container_deps` graph from a **service graph** to a **resource graph** whose
nodes are of two kinds:

1. **Runtime nodes** (today's `Service`): a container/network/file is *up*. Satisfied by
   the existing `RealSatisfier` (start/create, idempotent).
2. **Data nodes** (new): a piece of state *exists / is valid*, e.g.
   - `GithubTokenPresent` — `secret/github/token` populated + accepted (backed by
     `remote_projects::is_github_logged_in`, `remote_projects.rs:415`).
   - `GitIdentityConfigured` — name/email set for commit attribution.
   - `MirrorRelayCredentialPresent` — the git-mirror relay token minted (today a hard,
     ad-hoc launch requirement, `container_deps.rs:91-96`).
   - `CaBundleValid` — distinct from the CA *file existing*: the bundle verifies.

Data nodes have **edges** like service nodes: `GithubTokenPresent` depends on
`Service::Vault` (running) + `Service::Proxy` (egress to reach GitHub for validation).
`ForgeLaunch` then depends on `MirrorRelayCredentialPresent` (a data node) instead of
re-checking imperatively.

**Node satisfiers split into two idempotent flavors:**
- runtime satisfy = "start it" (as today);
- data satisfy = "ensure the datum exists / is valid" — for `GithubTokenPresent` this is
  *not* auto-satisfiable (it requires the operator's PAT). So the graph needs a node
  **kind**: `AutoSatisfiable` vs `OperatorGated`. An `OperatorGated` unsatisfied node is
  not an error to *self-heal* — it is a `blocked` state to *surface* (feeds the sibling-i
  login FSM and the sibling-iii event channel). This distinction is the missing concept
  today: the liveness probe (`container_deps.rs:363`) re-ensures runtime nodes forever,
  but you cannot "re-ensure" an operator's credential.

**FSM guardrails (the "tweak containers safely" goal).** Each node carries a small state
machine — `Absent → Satisfying → Present → Degraded → Absent` — and the graph enforces
invariants across transitions:
- **No regression on add.** Adding a container/gate = adding one node + its edges (the
  existing "one row in `DEPS`" ergonomic, `container_deps.rs:62-66`). The completeness
  litmus then *forces* every consumer of that node to declare the edge — you cannot add a
  gate that some launch path silently skips, because the `Up<T>` typestate makes the skip
  a compile error and the drift litmus makes it a test failure
  (`container_deps.rs:628-676`). This is the guardrail: the graph tells you exactly "what
  needs to survive where" mechanically.
- **Survive-what-where becomes queryable.** "What must remain Present for a forge to keep
  running?" = the transitive closure of `ForgeLaunch`'s node set. A teardown/self-heal
  (the `container_mutations_allowed()` gate, `container_deps.rs:296`) can consult it
  instead of hard-coding which containers survive a drain.

This packet defines the **graph model (nodes, edges, satisfier kinds, per-node FSM,
guardrail invariants)**. It does NOT define the login flow that walks these guards
(sibling i) nor the wire transport for node transitions (sibling iii).

## Investigate / prototype

- **Enumerate the data nodes** actually needed for v0.5 gates. Start from the imperative
  checks that exist today and hoist each into a candidate node: `check_auth_required_services`
  (`main.rs:6903`), `vault_bootstrap::is_github_key_present`, `is_github_logged_in`
  (`remote_projects.rs:415`), the mirror-relay credential requirement
  (`container_deps.rs:91-96`), git identity. Which are true prerequisites vs. UI signals?
- **Node kind taxonomy.** Formalize `AutoSatisfiable` vs `OperatorGated` (and possibly
  `ExternallyProvided`). Prototype the `Satisfier` trait split: `satisfy()` for auto nodes,
  `probe() -> Present | Absent | Degraded` for gated ones (never auto-created). Confirm the
  existing `RealSatisfier` (`container_deps.rs:291`) cleanly extends without breaking the
  service arms.
- **Typestate for data nodes.** Can `Up<T>` (`container_deps.rs:158`) extend to prove a
  *data* precondition at compile time (e.g. a forge launch fn that requires
  `Up<MirrorCredentialPresent>`), or is a runtime witness the ceiling for operator-gated
  state? Prototype both and compare ergonomics against the current `Up<GitLoginReady>` /
  `Up<ForgeLaunchReady>` pattern.
- **Per-node FSM vs. binary present/absent.** Is `Degraded` worth modeling (e.g. token
  present but provider-rejected = expired PAT)? The mirror-relay-token expiry class
  (recent commit `plan(424)` re: max-TTL vault-renewer expiry) suggests yes — a Present→
  Degraded transition is exactly the "token silently stopped working" signal.
- **Liveness for data nodes.** The `LivenessProbe` (`container_deps.rs:349`) currently
  re-ensures `[Vault, Proxy]`. Should it also *probe* (not re-ensure) `GithubTokenPresent`
  so a token that expires mid-session flips a node to `Degraded` and emits an event
  (sibling iii)? Bound the probe cost (each probe launches a short-lived container today,
  `is_github_logged_in` → `probe_github_username`, `remote_projects.rs:384`).
- **Interaction with the drain/shutdown gate.** `container_mutations_allowed()`
  (`container_deps.rs:296`) blocks satisfies while draining. Confirm data-node probes are
  safe during drain (read-only) and that OperatorGated nodes are never "satisfied" by a
  self-heal loop.
- **Graph well-formedness with mixed kinds.** Re-run the completeness/acyclicity proof
  (`dependency_graph_is_complete_and_acyclic`, `container_deps.rs:409`) over the mixed
  node set. Does a data node ever create a cycle with a runtime node (e.g. token needs
  Proxy, Proxy needs nothing — fine; but watch for a service that needs a datum that needs
  that service)?
- **Regression-guardrail spike.** Add a *deliberately-skipping* launch path in a test and
  prove the extended drift litmus (`launch_skipping_prerequisite_fails`,
  `container_deps.rs:628`) catches a skipped **data** node the same way it catches a
  skipped service.

## Exit criteria

- A written node catalog: every runtime node (existing) + every proposed data node, each
  with kind (`AutoSatisfiable` / `OperatorGated`), edges, and satisfy/probe semantics.
- The extended graph passes an updated completeness + acyclicity litmus over the **mixed**
  node set (falsifiable: the test compiles and fails if a referenced node is undeclared or
  a cycle exists — same shape as `container_deps.rs:409`).
- A prototype proving the incident as a graph property: `GithubTokenPresent` exists as an
  `OperatorGated` node depending on `Vault`+`Proxy`; a run that satisfies all *service*
  nodes but exits before the Vault write leaves `GithubTokenPresent = Absent`, and a test
  asserts a consumer that requires it is `blocked`, not "ready".
- A guardrail demonstration: adding a new gated node forces (via compile error on `Up<T>`
  and/or drift-litmus failure) every existing launch path that should depend on it to
  declare the edge — shown by a test that fails before the edge is added and passes after.
- A decision record on: node-kind taxonomy, typestate-vs-runtime-witness for data nodes,
  whether `Degraded` is modeled, and the liveness-probe policy for gated nodes.
- An explicit "survive-what-where" query API sketch (transitive closure of a target's node
  set) that a teardown/self-heal path could consult.

## Existing-code references

- `crates/tillandsias-headless/src/container_deps.rs:1-17` — module doc: declarative graph, born from orders 116/118/119/120 P0s.
- `crates/tillandsias-headless/src/container_deps.rs:27-44` — `Service` node enum (all runtime today; the set to extend with data nodes).
- `crates/tillandsias-headless/src/container_deps.rs:67-99` — `DEPS` edge table (the "one row per node" ergonomic to preserve).
- `crates/tillandsias-headless/src/container_deps.rs:81-83` — `GitLogin` depends on `Vault` **running**, NOT on `token present` (the exact gap).
- `crates/tillandsias-headless/src/container_deps.rs:91-96` — mirror-relay credential enforced ad hoc at launch (a data prerequisite that should be a node).
- `crates/tillandsias-headless/src/container_deps.rs:117-145` — `topo_order`/`visit` cycle-detecting driver (must stay valid over mixed nodes).
- `crates/tillandsias-headless/src/container_deps.rs:158-226` — `Up<T>` typestate + `ensure_git_login`/`ensure_forge_launch` witnesses (extend to data preconditions).
- `crates/tillandsias-headless/src/container_deps.rs:244-329` — `Satisfier` trait + `RealSatisfier` (split into satisfy vs probe).
- `crates/tillandsias-headless/src/container_deps.rs:296` — `container_mutations_allowed()` drain gate (data-node probes must respect it).
- `crates/tillandsias-headless/src/container_deps.rs:349-388` — `LivenessProbe::run_check` re-ensures `[Vault, Proxy]` (candidate to also probe data nodes).
- `crates/tillandsias-headless/src/container_deps.rs:409` — completeness + acyclicity litmus (re-run over mixed nodes).
- `crates/tillandsias-headless/src/container_deps.rs:628-676` — drift litmus: skipping a prerequisite fails (the regression guardrail to extend).
- `crates/tillandsias-headless/src/main.rs:6890` — `ensure_git_login` call in the login flow (satisfies services; misses the data node).
- `crates/tillandsias-headless/src/main.rs:6903` — `check_auth_required_services` (imperative check that should be graph edges).
- `crates/tillandsias-headless/src/main.rs:7051-7064` — Vault write: the step whose absence leaves the (missing) data node Absent.
- `crates/tillandsias-headless/src/remote_projects.rs:384,415` — `probe_github_username` / `is_github_logged_in` backing a `GithubTokenPresent` node.
- `openspec/specs/socket-container-orchestration/spec.md` — existing "readiness ≠ creation" principle (data-node readiness is the generalization).
- `plan/issues/macos-tray-github-login-stuck-no-prompt-refresh-2026-07-23.md` — motivating incident.

## Non-goals / scope

- NOT the login flow that walks these guards — that is sibling i
  (`research-auth-flow-state-machines-2026-07-23.md`).
- NOT the wire/event transport for node transitions — that is sibling iii
  (`research-flow-state-event-channel-2026-07-23.md`).
- NOT a rewrite of `container_deps.rs` — the design must be **additive** (extend the node
  set + satisfier), preserving the existing service graph, `Up<T>` witnesses, and litmus.
- NOT auto-creating credentials — `OperatorGated` nodes are surfaced, never fabricated;
  no self-heal loop may "satisfy" a missing operator secret.
- NOT ZeroClaw / agent↔agent messaging; NOT changing the Vault security boundary.
- NOT a v0.4 change — durable v0.5+ architecture; current launches keep working unchanged.
