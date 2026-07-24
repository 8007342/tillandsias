# RESEARCH+IMPL: certificate lifecycle as first-class state in the unified dependency+state graph (2026-07-24)

- **Date**: 2026-07-24
- **Class**: research+impl (research gate MANDATORY before implementation, operator standing rule)
- **Area**: CA/cert trust propagation / unified dependency graph / FlowState channel
- **Severity**: P2 durable-direction (the incident class it retires has produced repeated P1s)
- **Owner**: linux (graph + emit side live in `tillandsias-headless`; tray consumption follows)
- **Discovered-by**: operator synthesis 2026-07-23/24 — CA chain "historically propagated awkwardly";
  containers crash or silently degrade on stale/missing CA state
- **Status**: proposed
- **Desired release**: v0.5
- **Cross-refs**: `plan/issues/research-unified-runtime-data-dependency-graph-2026-07-23.md` (graph
  this specializes), `plan/issues/research-flow-state-event-channel-2026-07-23.md` (channel that
  carries the transitions), `plan/issues/forge-enclave-isolation-uniform-principle-2026-07-23.md`,
  order 424 (git-mirror credential lifecycle — same lifecycle-awareness class), order 463 (vault
  host-endpoint fragility — same "consumer discovers staleness by crashing" class)

## Motivation

CA/cert material is the most incident-dense *data* dependency in the runtime, yet the graph models
it as a binary file-exists node and every consumer discovers staleness by failing:

- `container_deps.rs:33,70` — `Service::CaBundle` exists but is edge-less and satisfied once by
  `satisfy_ca_bundle` → `ensure_ca_bundle` (`container_deps.rs:286-289`); success is terminal.
- `container_deps.rs:373` — the `LivenessProbe` re-ensures only `[Vault, Proxy]`; the comment at
  `:370-372` says "CaBundle is a file, not a container" — so a tmpfs wipe (`CA_DIR =
  /tmp/tillandsias-ca`, `main.rs:1022`) or a 30-day rotation (`main.rs:2186-2187`) after first
  satisfy is INVISIBLE to the graph.
- `main.rs:4743-4747` — the forge CA mount is added unconditionally with no readiness gate; the
  only check is inside the container and soft-degrades to vendor roots
  (`images/default/lib-common.sh:34,47`) — the silent-fallback gap traced in
  `plan/issues/forge-trust-ca-source-readiness-gap-2026-07-23.md`.
- Commit `1dda3032` (`main.rs:6941,6948`) — the SELinux `relabel=shared` login-container fix: a
  PRESENT cert that was UNREADABLE, i.e. "mounted" and "trusted" are distinct states we currently
  cannot express.
- `plan/issues/forge-runtime-ca-trust-convergence-2026-07-14.md` — running containers pin the OLD
  mounted CA inode after rotation until restarted; nothing restarts them.

Each incident is the same shape: a cert-lifecycle transition happened (wiped, rotated, not yet
mounted, unreadable) and orchestration neither observed it nor reacted — consumers crash-and-retry
or silently degrade.

## Proposed model

Specialize the sibling unified-graph design for cert material. `CaBundle` (and per-consumer trust
nodes) become lifecycle nodes carrying an FSM:

    minted -> mounted -> propagating -> trusted -> expiring -> rotated -> (re-enters at minted)

with `absent` and `unreadable` as off-path states. Two reaction rules make orchestration REACT
instead of crash-and-retry:

1. **Defer-until-trusted**: a consumer create (forge, login container, proxy) that declares a
   trust edge is NOT started until its cert node reaches `trusted` — replacing the lib-common
   soft fallback and the unconditional mount with a host-side gate (extends the `Up<T>` typestate,
   `container_deps.rs:158-226`, to `Up<CaTrusted>`).
2. **Restart-on-rotation**: a `trusted -> rotated` transition enumerates consumers via the graph's
   transitive closure and re-ensures them, retiring the pinned-inode class from the convergence doc.

Every transition is emitted as a `FlowStatePush` on the sibling channel (dotted codes, e.g.
`trust.ca.mounted`, `trust.ca.err.unreadable`), so trays/diagnostics observe cert state instead of
inferring it post-hoc.

## Investigate / prototype

- **State set**: is `propagating` (minted-but-not-yet-mounted-in-all-consumers) a real state or a
  per-edge property? Map each historical incident (relabel, tmpfs wipe, rotation pin, forge
  fallback) onto the FSM and reject states no incident needs.
- **Probe cost/cadence**: extending `LivenessProbe` to PROBE (not re-ensure) cert nodes — PEM
  validity + expiry via one `openssl x509 -checkend` per cycle; bound the cost.
- **Rotation fan-out safety**: restart-on-rotation must respect `container_mutations_allowed()`
  (`container_deps.rs:296`) and must not thrash on a rotation storm; design a debounce.
- **Per-consumer trust edges vs one global node**: the login container needed `relabel=shared`,
  the forge runs `label=disable` (`main.rs:4668`) — trust is per-consumer; decide edge shape.
- **Order-424 generalization**: confirm the same node FSM fits the git-mirror credential (mint /
  present / expiring / renewed) so credentials and certs share one lifecycle vocabulary.

## Exit criteria (each VERIFIABLE)

1. **Node catalog + FSM decision record**, enforced by an updated completeness+acyclicity litmus
   over the mixed node set including cert-lifecycle nodes (same falsifiable shape as
   `dependency_graph_is_complete_and_acyclic`, `container_deps.rs:409`: test fails on any
   undeclared node, cycle, or FSM transition not in the declared table).
2. **Defer-until-trusted litmus**: a test deletes `/tmp/tillandsias-ca` (simulated tmpfs wipe)
   before a forge create and asserts (a) no container create is issued until the node re-reaches
   `trusted`, and (b) the vendor-roots WARNING string from `lib-common.sh:47` does NOT appear for
   a stack-connected forge. Negative path proven: reverting the gate makes the test fail.
3. **Restart-on-rotation check**: an executable check rotates the CA, then compares the CA inode
   mounted inside each declared consumer (`stat` in-container) against the new source inode —
   pass only when they match post-reaction; today's pinned-inode behavior fails it.
4. **Emission proof**: `FlowStatePush` cert transitions round-trip through the existing postcard
   encode/decode tests in `control-wire/src/lib.rs` with NO `WIRE_VERSION` bump, and a subscriber
   test observes `absent -> minted -> mounted -> trusted` in order for a cold start.
5. **Drift guardrail**: the skip litmus (`launch_skipping_prerequisite_fails`,
   `container_deps.rs:628`) extended so a launch path mounting `ca-chain.crt` without the
   `Up<CaTrusted>` witness is a compile error or test failure — demonstrated by a deliberately
   skipping test path that fails before the edge is declared and passes after.

## Non-goals / scope

- NOT the general graph model (sibling: `research-unified-runtime-data-dependency-graph-2026-07-23.md`)
  nor the channel transport (sibling: `research-flow-state-event-channel-2026-07-23.md`) — this
  packet consumes both and contributes the cert-lifecycle node family + reaction rules.
- NOT the point-fix for the forge vendor-roots fallback — that ships independently via
  `forge-trust-ca-source-readiness-gap-2026-07-23.md`; this retires the CLASS.
- NOT changing the Vault security boundary, squid bump/splice policy, or CA generation crypto.
- NOT a v0.4 change — durable v0.5 architecture; current launches keep working unchanged.
