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

## Slice 5 — exit criterion 1: the declared CA transition table (yoga, 2026-09-28)

`flow_sink::CA_TRANSITIONS` declares the three transitions `ca_transition` can
announce: `absent → current` (`minted`), `current → current` (`rotated`),
`current → absent` (`lost`). Two tests in `flow_sink.rs` enforce it over the
whole input space: every announcement is a declared row, and every declared row
is announced for some input (no dead rows). The emit site in `main.rs`
(`ensure_ca_bundle`) `debug_assert!`s the same predicate, so a debug build
refuses an undeclared transition before it reaches the wire.

Mutation controls, both run: renaming the rotation reason (`rotated` →
`renewed`) fails with "undeclared CA transition current:aa -> current:bb
(renewed)"; adding an unreachable row (`absent → absent`, `vanished`) fails
with "declared CA transition never announced".

The node catalog half of criterion 1 already exists: `unified_deps.rs`'s
`unified_graph_is_complete_and_acyclic` covers the mixed node set including
`CaBundle` and `CaBundleValid` (the module is still `#![allow(dead_code)]`,
with no production caller).

**Gap left on purpose, and the next slice:** `unreadable` is refused host-side
(slice 4, `container_deps::ca_bundle_trustable`), but `ca_generation` cannot
tell an unreadable certificate from an absent one, so the wire reports it as
`absent`. It is not in the table because no code path can announce it. Adding
it means making the generation read return a three-way answer first; the test
above then fails until the row is declared, which is the order to do it in.

## Slice 6 — `unreadable` is a state of its own (yoga, 2026-10-12)

`ca_generation` now answers `flow_sink::CaBundleState`: `Absent` (no
`intermediate.crt`), `Unreadable` (the file exists but cannot be read, or is
not a PEM certificate by `container_deps::is_pem_certificate`, the predicate
slice 4's `ca_bundle_trustable` refuses on, now shared by both), or
`Current(generation)`. The wire state is `unreadable`. Before this slice it was
`absent`, which names the wrong remedy for the SELinux-relabel incident
(1dda3032): a re-mint where a repair of the existing file was what it needed.

`CA_TRANSITIONS` gained four rows: `unreadable → current` (`repaired`),
`unreadable → absent` (`lost`), `absent → unreadable` and `current →
unreadable` (both `corrupted`). The exhaustive test now enumerates `[Absent,
Unreadable, Current(aa), Current(bb)]`. `repaired` is reachable in practice
only through the 25-day refresh, because `ca_bundle_needs_refresh` reads
mtimes: a young unreadable certificate is not refreshed, stays `unreadable`,
the satisfier refuses consumers, and nothing is announced, which is the
correct silence. The two `corrupted` rows and `unreadable → absent` are
reachable by the pure function and, in practice, only by another writer
changing the file between the two reads, the kind of event the wire exists to
show.

The proxy edge is unchanged in effect: an unreadable certificate is `None` to
`proxy_ca_check` (`Unknown`, the serving proxy is kept) and labels no proxy,
exactly as an absent one did.

Mutation controls, both run on yoga: dropping the `repaired` row fails
`every_announced_transition_is_declared_and_every_row_is_reachable` with
"undeclared CA transition unreadable -> current:aa (repaired)"; making the read
accept a non-PEM file as current fails
`a_present_but_untrustable_certificate_reads_unreadable_not_absent` with
`left: Current("0fa00ca59cbbed9c") right: Unreadable`. Both files were
restored byte-identical afterwards.

Remaining on the row: criterion 3 (restart-on-rotation fan-out for
long-running forges), criterion 5 (the drift guardrail), and the live arms of
criterion 2. The split-trust TLS failure is still read-from-code.

## Slice 7 — exit criterion 5: the CA-trust witness on the forge-agent lanes (yoga, 2026-10-12)

`container_deps::CaTrusted` is a new marker. `Up<CaTrusted>` has no
constructor of its own: it is a projection, `ca_trusted()`, of the two launch
witnesses `Up<ForgeLaunchReady>` and `Up<GitLoginReady>`, whose targets both
reach `CaBundle` in `DEPS` (pinned by
`ca_trusted_projects_only_from_targets_that_reach_ca_bundle`). So holding one
means the certificate a consumer is about to mount is the one
`satisfy_ca_bundle` checked — current by `ensure_ca_bundle`, trustable by
`ca_bundle_trustable` (slice 4) — and that the proxy came up after that check.
`ensure_enclave_for_project` now returns the projection as a third element.
On the forge-agent lanes the forge-side CA mount
(`/run/tillandsias/ca-chain.crt`) is built by one function,
`forge_ca_chain_mount(certs_dir, &Up<CaTrusted>)`, and nowhere else;
`build_forge_agent_run_args_with_vault`, `build_forge_agent_run_args` and
`build_forge_agent_run_argv` take the witness as their last parameter, and
`run_forge_agent_cli_mode` and `launch_forge_agent` pass what the bring-up
returned. Unit tests mint it through `ca_trusted_for_tests`, which exists under
`cfg(test)` only.

Criterion 5 asks for the skip litmus "extended so a launch path mounting
`ca-chain.crt` without the witness is a compile error or test failure". Both
arms exist, each with its mutation control run on yoga:

- Compile arm. A lane that never ran the dependency model has no
  `Up<CaTrusted>` to pass. Control: replacing `run_forge_agent_cli_mode`'s
  `ensure_enclave_for_project` call with the bare `ensure_ca_bundle` chain →
  `error[E0425]: cannot find value `ca_trusted` in this scope` at the builder
  call.
- Test arm, for what a type cannot see (a NEW emitter written without the
  parameter): `every_forge_ca_mount_emitter_takes_the_ca_trusted_witness`
  attributes every production line naming the in-container path to its
  top-level fn and requires `Up<container_deps::CaTrusted>` in that fn's
  signature, with a RATCHET for the lanes still outside the model. Controls:
  dropping the helper's witness parameter → "forge_ca_chain_mount must build
  the forge-agent CA mount against the witness; witnessed=[]"; a stale ratchet
  entry (`build_router_run_args`) → "ratchet: build_router_run_args (…) no
  longer names /run/tillandsias/ca-chain.crt unwitnessed; remove it from
  OUTSIDE_THE_MODEL".
- The skip litmus the criterion names, `launch_skipping_prerequisite_fails`,
  gained the CaBundle arm for both launch targets (the error names
  `ca-bundle`, neither the proxy nor the target is attempted). Control:
  making `CaBundle` unreachable from `ForgeLaunch` — its direct edge, Proxy's
  and NixCache's, since it reaches the target three ways — fails the arm
  (`unwrap_err` on an `Ok`) and the projection pin: "tillandsias-forge-launch
  projects a CaTrusted witness but does not reach CaBundle: [EnclaveNetwork,
  EgressNetwork, Proxy, Vault, NixCache, ForgeLaunch]".

All mutated files were restored byte-identical (`cmp`) between arms.

**Finding — the drift this guardrail exists for was already there.** Three
lanes mount the CA into a forge OUTSIDE the dependency model, by the bare
`ensure_ca_bundle` + `ensure_enclave_network` chain: `run_opencode_mode` and
`run_opencode_web_mode` (through `build_opencode_forge_args`) and
`run_status_check` (through `build_stack_common_args`). None of them runs
slice 4's `ca_bundle_trustable`, so on those lanes an unreadable certificate
still reaches the container as a `[trust] WARNING` and vendor roots — the
failure slice 4 closed for the forge-agent lanes only. They are ratcheted in
the scan test's `OUTSIDE_THE_MODEL` with the lane that reaches each, so the
list cannot grow silently and cannot outlive its reason. Closing it is slice
8 and is a decision, not a mechanical change: routing those lanes through
`ensure_forge_launch` brings Vault and the proxy up on paths that today start
neither (a behaviour change on the OpenCode and status-check lanes), while the
smaller alternative — call `ca_bundle_trustable` on those lanes and project a
witness from a GitLogin/ForgeLaunch-independent check — would need a third
witness source and its own soundness pin.

Collateral: `liveness_steady_state_containers` (the order-477 helper in
main.rs) anchored container_deps.rs's test boundary on the first
`#[cfg(test)]` text in the file; the `cfg(test)` constructor above
`run_check` made two order-477 agreement tests read the steady-state set as
test scaffolding, and clippy's `items_after_test_module` refused the
alternative of placing it after the module. The helper now anchors on
`#[cfg(test)]\nmod tests`, which is what it meant.

Unchanged on purpose: `forge_ca_chain_mount` keeps the pre-existing
`exists()` gate, so a certificate the model checked at bring-up and that
vanished before the run is still skipped silently on this lane. That is
criterion 3's territory (reaction to rotation and loss), named here so it is
not mistaken for closed.

Status of criterion 5: met for the forge-agent lanes (both arms, both
controlled); OPEN for the three ratcheted lanes (slice 8). Remaining on the
row: slice 8, criterion 3, the live arms of criterion 2. The split-trust TLS
failure is still read-from-code.

Verification on yoga (2026-10-12): `cargo test -p tillandsias-headless --bin tillandsias --features tray,listen-vsock` 986 passed, 0 failed, 25 ignored; `cargo clippy -p tillandsias-headless --bin tillandsias --tests -- -D warnings` rc 0 under no features, `tray`, and `tray,listen-vsock`; `cargo fmt --all` clean.

## Slice 8 — criterion 5 on every lane: the ratchet empties (yoga, 2026-10-12)

Slice 7 left three lanes outside the model, ratcheted: `run_status_check`
(through `build_stack_common_args`), `run_opencode_mode` and
`run_opencode_web_mode` (through `build_opencode_forge_args`). Each brought
the CA up by the bare `ensure_ca_bundle` + `ensure_enclave_network` chain,
which checks that the certificate EXISTS and nothing else, so slice 4's
`ca_bundle_trustable` refusal never ran there and an unreadable certificate
still reached the container as vendor roots plus a `[trust] WARNING` line.
Slice 7 named the closing as a decision because routing those lanes through
`ensure_forge_launch` would bring Vault and the proxy up on paths that
sequence both themselves.

**Decision: a third witness source, not a reroute.** `CaBundle` is a node of
`DEPS` with no prerequisites and a satisfier (`satisfy_ca_bundle`) that is
exactly `ensure_ca_bundle` + `ca_bundle_trustable`. So
`container_deps::ensure_ca_trusted(debug)` runs `ensure_with(Service::CaBundle)`
on the real satisfier and returns `Up<CaTrusted>`: the same refusal and the
same witness as the launch lanes, touching the one node and nothing above it.
The three lanes call it where they called the bare chain (the `ensure_ca_bundle`
call stays, as the idempotent read of `certs_dir`), the two builders take the
witness as their last parameter, and the forge-side mount literal now lives in
one function, `forge_ca_chain_mount_spec(certs_dir, &Up<CaTrusted>)`, which the
gated `forge_ca_chain_mount` (forge-agent lanes, `exists()` gate unchanged)
and the two unconditional builders (unchanged: a missing source stays podman's
refusal on those lanes) both call. `OUTSIDE_THE_MODEL` is deleted rather than
left empty — an empty allowlist is a list nobody can fail — and the scan test
now asserts the total property: no production fn names
`/run/tillandsias/ca-chain.crt` without the witness in its signature.

What the direct witness promises is narrower than a projection, and the
`CaTrusted` doc says so: the certificate the consumer mounts is the one the
model checked; nothing about the proxy having come up after that check, which
is criterion 3's territory. `all_launch_paths_route_through_dependency_model`
gains the three lanes, each pinned to `container_deps::ensure_ca_trusted(debug)?`.

Behaviour change on the three lanes, and the one the row exists for: an
unreadable or non-PEM `intermediate.crt` now refuses before any container is
created (`ca-bundle unreadable: … refusing to start a consumer that would
silently fall back to vendor roots`), where it previously mounted and warned.
In a forge (`TILLANDSIAS_HOST_KIND=forge`) the satisfier exempts the check as
before. The model's drain gate (`container_mutations_allowed`) now also covers
the OpenCode Web lane's CA step, which is the correct answer under a stopping
VM and was never reachable on the CLI lanes.

Mutation controls, four arms, each restored byte-identical (`cmp`) before the
next:

- Compile arm: deleting the `ensure_ca_trusted` call in `run_status_check` →
  `error[E0425]: cannot find value `ca_trusted` in this scope` at the
  probe-forge builder call.
- Scan arm: a new production fn naming the path without the witness →
  `every_forge_ca_mount_emitter_takes_the_ca_trusted_witness` fails with
  `drift guardrail (472 criterion 5): ["mutant_unwitnessed_ca_mount"] name
  /run/tillandsias/ca-chain.crt without a Up<container_deps::CaTrusted>
  parameter`.
- Mint arm: `ensure_ca_trusted_with` returning the witness without
  `ensure_with` → `ca_trusted_is_minted_only_after_the_ca_bundle_node_is_satisfied`
  panics "a failed CaBundle node must not mint the witness".
- Node arm: satisfying `ForgeLaunch` instead of `CaBundle` → the same test
  fails on the recorded calls (`[EnclaveNetwork, EgressNetwork, CaBundle]`
  against `[CaBundle]`).

Status of criterion 5: MET on every lane that mounts the forge-side CA. The
projection pin gains the direct constructor as a third fn-pointer pin.
Remaining on the row: criterion 3 (reaction to rotation; the split-trust
window is still read-from-code) and the live arms of criterion 2.

Verification on yoga (2026-10-12): `cargo test -p tillandsias-headless --bin
tillandsias --features tray,listen-vsock` 987 passed, 0 failed, 25 ignored;
`cargo clippy -p tillandsias-headless --bin tillandsias --tests -- -D warnings`
rc 0 under no features, `tray`, and `tray,listen-vsock`; `cargo fmt --all`
clean.
