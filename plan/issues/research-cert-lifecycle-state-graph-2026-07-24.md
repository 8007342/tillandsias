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

## Research gate, slice 1 — citations re-verified against d0454b3d4 (lenovinha, 2026-09-27)

The packet was written against a July tree. Before any FSM is designed, each
motivating citation was re-read on today's trunk. Four of the six premises have
moved; one new hazard appeared that the original text did not name, and it is
the strongest argument this row has.

### What changed since 2026-07-24

| Premise (July) | Today | Consequence |
|---|---|---|
| `CA_DIR = /tmp/tillandsias-ca` (tmpfs; a wipe is routine) | `ca_dir()` = `${HOME}/.local/state/tillandsias/ca` via the `images/default/ca-path.txt` manifest (1027-539s, `crates/tillandsias-core/src/ca_path.rs`) | The tmpfs-wipe incident is no longer routine. Exit criterion 2's fixture (delete the dir before a forge create) still tests the gate, but it stops being a model of an everyday event. `absent` stays in the FSM for first run and for manual deletion, not as the main path |
| `CaBundle` is edge-less and satisfied once | Still true in `container_deps.rs` (`(Service::CaBundle, &[])`, line 76). Proxy, GitLogin and ForgeLaunch all declare it, so presence is already a precondition for every consumer | "Defer until PRESENT" already exists. What is missing is "defer until VALID/CURRENT" |
| No data-state nodes | `unified_deps.rs` (order 470) adds `CaBundleValid` with edges from Proxy, GitLogin, GithubTokenPresent and ForgeLaunch, but the module is `#![allow(dead_code)]`, and only `mod unified_deps;` references it | The node the design needs exists as a prototype with no production caller. This row should extend it rather than add a third graph |
| LivenessProbe re-ensures `[Vault, Proxy]` only | Unchanged (`container_deps.rs` `run_check`; the comment "CaBundle is a file, not a container") | Probe gap confirmed |
| FlowState channel is a proposal | `ControlMessage::FlowStatePush { seq, source, from_state, to_state, reason, ts_unix }` is on the wire (`control-wire/src/lib.rs`, additive, no `WIRE_VERSION` bump) and dispatched in `control_dispatch.rs` | Exit criterion 4 needs no wire change; cert transitions are values of `from_state`/`to_state` |
| Forge soft-degrades to vendor roots | Unchanged: `lib-common.sh` prints `[trust] WARNING: runtime proxy CA is not mounted; using vendor roots only` and continues | Criterion 2(b) is still falsifiable as written |

### NEW: rotation opens a split-trust window between the proxy and new consumers

Measured by reading the code path, not by a live run yet:

1. `ensure_ca_bundle` rotates when either file is older than 25 days
   (`ca_bundle_needs_refresh`, `max_age = 25d`) and publishes by
   `fs::rename(tmp, crt)`, so the rotated certificate has a NEW inode.
2. Every consumer mounts `intermediate.crt` as a FILE bind mount
   (`target=/run/tillandsias/ca-chain.crt`, eight call sites in `main.rs`). A
   file bind mount pins the inode, so running consumers keep the OLD
   certificate. The forge also composes its trust bundle once at start
   (`init_runtime_ca_trust` in `lib-common.sh`), so a directory mount would not
   fix this either: **a rotation reaches a consumer only through a restart.**
3. The proxy receives the CA key as a podman secret (755-qcxh), created only
   at proxy launch. `ensure_proxy_running` returns early when
   `tillandsias-proxy` is already running, without comparing the key it was
   started with to the key on disk.
4. `ForgeLaunch` depends on both `CaBundle` and `Proxy`. So the first forge
   launch after day 25 ROTATES the CA (CaBundle satisfier), finds the proxy
   running (early return), and starts a forge that trusts ONLY the new
   certificate while the proxy still signs bumped leaves with the OLD key.

The predicted symptom is TLS verification failure inside a fresh forge for
every bumped (non-spliced) host, while older forges keep working. That points
the operator away from the cause. A proxy restart at the next host boot clears
it, which would explain why it has not been filed as its own incident on hosts
that reboot within the window.

This changes the priority order inside this row. Restart-on-rotation is no
longer about stale consumers slowly converging. It is an ORDERING requirement
with a correctness failure when it is violated: **the proxy must be re-ensured
from the rotated key BEFORE any consumer that mounts the rotated certificate
starts.** The minimum sound rule:

- The CaBundle node records a generation (the certificate's fingerprint or
  inode) when it is satisfied.
- The Proxy node records the generation it was started with.
- `Proxy` is satisfied only when the two match. A mismatch re-ensures the
  proxy (`--replace`, respecting `container_mutations_allowed()`) before the
  consumer's create proceeds.

That is one edge property (generation equality on CaBundle→Proxy), not the
full FSM, and it closes the correctness hole on its own. The full FSM (defer
until trusted, fan-out restart of long-running forges) remains the rest of the
row.

### State-set decision (investigation item 1)

Mapping each incident onto the proposed FSM:

| Incident | State needed |
|---|---|
| first run / manual deletion | `absent` |
| SELinux relabel, 1dda3032 (present but unreadable) | `unreadable` |
| split-trust window (above) | `rotated`, plus a per-edge generation |
| pinned inode in long-running forges | `rotated`, plus a per-edge generation |
| vendor-roots fallback | `mounted` vs `trusted` (the consumer's own verdict) |

`propagating` is not needed as a node state. It is exactly "some edge's
generation lags the node's generation", which is per-edge data. `expiring` is
not needed either: the 25-day refresh makes expiry a scheduled rotation, and no
incident has been an expiry. **Proposed node states: `absent`, `unreadable`,
`current(gen)`, plus per-edge `consumer_gen`; a transition is a generation
change.** That is smaller than the July FSM, and every state maps to an
incident.

### Next slice

1. Live confirmation of the split-trust window on a disposable enclave: age
   the CA files past 25 days (`touch -d`), launch a forge with the proxy
   already running, and check TLS through the proxy from the new forge. The
   prediction is a failure; the control is the same run with the proxy
   restarted first.
2. The CaBundle→Proxy generation-equality edge, with a unit test in
   `container_deps.rs` that fails on today's early return.
