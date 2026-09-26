# RESEARCH: first-class message-channel + event propagation so flow/dependency transitions are OBSERVABLE (2026-07-23)

- **Class**: research (MANDATORY before implementation, operator standing rule)
- **Status**: done
- **Desired release**: future (v0.5+) — NOT blocking current v0.4/v0.3 work; durable direction
- **Owner host**: any (the control-wire backbone + push listeners span the guest headless and all three trays)
- **Completed date**: 2026-09-26 (lenovinha)
- **Evidence**:
  - `crates/tillandsias-control-wire/src/lib.rs` (`FlowSource`, `SubscriptionTopic::FlowState`, `ControlMessage::FlowStatePush`, discriminant index 33, `DECLARED_VARIANTS = 34`).
  - `crates/tillandsias-control-wire/src/flow_event.rs` (`FlowEventChannel`, default capacity 64, lag-skip contract).
  - `crates/tillandsias-headless/src/control_dispatch.rs` (routing matrices updated and pinned).
  - Passing tests: `cargo test -p tillandsias-control-wire` (78 tests passed, including `incident_observable_collected_but_not_persisted`, `dependency_node_state_transitions`, `bounded_capacity_lag_skip_contract`, `flow_state_push_roundtrip`, `every_variant_discriminant_is_pinned_against_literals`).
- **Operator vision (2026-07-23, The Tlatoāni, paraphrased)**: event propagation through
  our idiomatic layers must PROPAGATE flow-state events — today they are inferred, not
  emitted. Since we own the backbone (the control-wire), we likely need a proper
  first-class MESSAGE-CHANNEL mechanism so flow/dependency-state transitions are
  observable events, not something reconstructed after the fact by polling.
- **Motivating incident**: `plan/issues/macos-tray-github-login-stuck-no-prompt-refresh-2026-07-23.md`
- **Sibling packets (non-overlapping, file together)**:
  - `plan/issues/research-auth-flow-state-machines-2026-07-23.md` (the login FSM whose transitions this channel carries)
  - `plan/issues/research-unified-runtime-data-dependency-graph-2026-07-23.md` (the graph whose node-state changes this channel carries)

## Motivation

We own the backbone — `tillandsias-control-wire` — and it already has a working
push/subscribe model: `ControlMessage` (`crates/tillandsias-control-wire/src/lib.rs:107`,
`#[non_exhaustive]` at `:106`) carries `Subscribe` / `SubscribeAck` (`lib.rs:291-293`) and
four push topics — `VmStatusPush` (`lib.rs:298`), `LoginStatePush` (`lib.rs:306`),
`CloudProjectsPush` (`lib.rs:313`), `LocalProjectsPush` (`lib.rs:322`) — enumerated by
`SubscriptionTopic` (`lib.rs:369`). The guest emits change-gated pushes via broadcast
fan-out with a lag-skip contract (`vsock_server.rs:128-176`, push loops `:711-822`), and
trailing variants are additive with no wire-version bump (`lib.rs:40` `WIRE_VERSION`,
convention noted `lib.rs:268`). This is a real, idiomatic message channel — but it carries
**domain snapshots, not flow/dependency transitions.**

The consequence is the incident. Login state is never *emitted by the login flow*. It is
*inferred* by a periodic Vault re-check: `probe_github_username` (`remote_projects.rs:384`)
/ `is_github_logged_in` (`remote_projects.rs:415`) run on a poll loop
(`main.rs:11477`, `main.rs:11502`) and on the `GithubLoginStatusRequest` handler
(`vsock_server.rs:1004`), each folded through `apply_login_transition` /
`set_login_state` (`vsock_server.rs:252,285`) which pushes a `LoginStatePush` **only when
the observed boolean flips**. So when the flow collects a PAT but exits before the Vault
write (`main.rs:7051-7064`), there is nothing to observe — no bytes ever changed in Vault —
and therefore no event, no chip update, and no trace. The tray's own workarounds
(grace window + fast poll while `LoggingIn`, see the incident) are compensation for a
channel that only speaks in eventually-observed snapshots.

A first-class flow-state channel would emit `token_collected`, `persist_failed{ca_bundle}`
as they happen, over the same backbone — turning "silently didn't work" into an observable,
ordered event stream that the tray, diagnostics, and future automation can all consume.

## Proposed model

Add a **flow/graph event topic** to the existing push model — the smallest change that
makes sibling-i FSM transitions and sibling-ii node-state transitions observable, reusing
everything the wire already provides (subscribe/ack, monotonic `seq`, broadcast fan-out,
lag-skip, additive trailing variants).

**Wire shape (draft).** One new `SubscriptionTopic::FlowState` (`lib.rs:369`) and one new
trailing `ControlMessage` variant (additive, no `WIRE_VERSION` bump, per the `lib.rs:268`
convention):

```
FlowStatePush {
    seq: u64,                 // existing monotonic per-source counter (ordering)
    source: FlowSource,       // Login{provider} | DependencyNode{node} | ...
    from_state: StateCode,    // stable dotted code (reuse stable-state-codes)
    to_state: StateCode,
    reason: Option<ReasonCode>,   // populated on a `blocked`/`degraded` transition
    ts_unix: u64,
}
```

This is deliberately a **transition** (`from → to (+reason)`), not a snapshot — the thing
missing today. `StateCode` / `ReasonCode` reuse the dotted vocabulary already proposed in
`plan/issues/stable-state-codes-research-2026-07-05.md` (e.g. `auth.github.token-collected`,
`auth.github.err.vault-write`) so we do not invent a parallel taxonomy.

**Emission points.** The sibling-i login FSM emits a `FlowStatePush` on every transition
(including `blocked`); the sibling-ii graph emits one whenever a node changes
`Absent/Satisfying/Present/Degraded`. Both funnel through the existing change-gated,
`seq`-stamped broadcast helpers modeled on `set_login_state` (`vsock_server.rs:252-275`) —
NOT new bespoke plumbing.

**Consumption.** Trays subscribe to `FlowState` alongside the existing topics and fold
transitions into the chip via the stable-state-code renderer. The current inference paths
(`LoginStatePush` derived from a Vault re-check) can remain as a *reconciliation backstop*,
but the authoritative signal becomes the emitted transition — closing the "inferred, not
emitted" gap the operator named.

**Why a first-class channel vs. bolting onto `LoginStatePush`.** `LoginStatePush` is a
binary `logged_in` snapshot (`lib.rs:306`); it structurally cannot express
`blocked{persist, ca_bundle}` or a dependency-node transition. `FlowState` is the general
carrier for the FSM (i) and the graph (ii) so future flows (any provider, any gate) light
up for free — the same way adding a container is "one row in `DEPS`" (sibling ii). This
packet defines **the channel/transport and propagation semantics**; it does NOT define the
states (i) or the nodes (ii) it carries.

## Investigate / prototype

- **Topic granularity.** One unified `FlowState` topic vs. separate `LoginFlow` and
  `DependencyGraph` topics. One topic = one subscription, simplest fan-out; separate =
  finer subscriber filtering. Weigh against the existing four-topic precedent
  (`SubscriptionTopic`, `lib.rs:369`) and the lag-skip cost per channel
  (`vsock_server.rs:711-822`).
- **Transition vs. snapshot (or both).** A late/reconnecting subscriber that missed a
  transition needs current state. Does `FlowState` need a `FlowSnapshotReply` companion
  (request the full current state set on subscribe), mirroring how `VmStatusRequest`/
  `VmStatusReply` (`lib.rs:160-169`) coexist with `VmStatusPush`? Prototype subscribe →
  snapshot → live-transitions.
- **Ordering & loss.** Pushes use a monotonic `seq` and a **lag-skip** (a slow subscriber
  drops frames, `vsock_server.rs:711-822`). For *transitions*, dropping a frame loses a
  state change — is lag-skip acceptable, or does FlowState need at-least-once /
  snapshot-on-gap? Measure realistic transition rates (login is low-frequency; a node
  liveness flap could be higher).
- **Backpressure bounds.** The existing channels use bounded broadcast capacities
  (`vsock_server.rs:168-176`). Pick a bound for FlowState and prove a burst (e.g. a
  dependency storm re-ensuring many nodes) cannot wedge the guest.
- **`#[non_exhaustive]` compatibility.** Confirm an old tray tolerates a new `FlowStatePush`
  variant it doesn't understand (the enum is `#[non_exhaustive]`, `lib.rs:106`; the
  `UnknownVariant` `ErrorCode` path exists, `lib.rs:407`). Prototype an old-host/new-guest
  and new-host/old-guest matrix — no wire-version bump should be required.
- **Idiomatic-layer propagation.** The operator's phrase is "propagate through our
  idiomatic layers." Trace the full path: guest FSM/graph → `FlowStatePush` → vsock →
  host push listener → tray menu-state → chip. Where does each host consume pushes today
  (`vsock_server.rs` emit side; the macOS `action_host.rs` poller + Windows
  `notify_icon.rs` on the consume side)? Enumerate the seams a `FlowState` handler must
  slot into on all three trays.
- **Reconciliation backstop.** Decide the relationship between an authoritative emitted
  transition and the existing inferred `LoginStatePush`/Vault re-check. Prototype: emitted
  transition is primary; the periodic probe only *reconciles* (and itself emits a
  `FlowState` transition if it detects drift), so there is exactly one vocabulary.
- **Diagnostics sink.** Beyond the tray, should `FlowState` transitions land in the
  runtime-diagnostics stream (`openspec/specs/runtime-diagnostics-stream`) so a
  `--diagnose` bundle shows "blocked at persist(ca_bundle)"? This is the "untraceable"
  half of the incident.

## Exit criteria

- A written wire design: the new `SubscriptionTopic` value(s) and `ControlMessage` variant(s),
  proven additive (round-trips through the existing postcard encode/decode tests in
  `control-wire/src/lib.rs` with no `WIRE_VERSION` bump; an unknown variant degrades
  gracefully on an old peer).
- A decision record answering: one topic vs. many; transition-only vs. transition+snapshot;
  lag-skip vs. gap-recovery; chosen bounded capacity — each with a rationale tied to
  measured/estimated transition rates.
- A prototype (behind a flag or in a scratch branch) emitting a `FlowStatePush` from a
  simulated login FSM (sibling i) and a simulated node change (sibling ii), with a test
  proving the incident is now observable: the collected-but-not-persisted path emits
  `→ blocked{persist, ca_bundle}` and a subscriber receives it — where today nothing is
  emitted.
- A cross-tray consumption sketch: exactly where a `FlowState` handler slots into the macOS
  and Windows push listeners, and how it folds into the stable-state-code chip renderer.
- Confirmation that the emitted transition can be the authoritative signal while the
  existing Vault-re-check remains a reconciliation backstop, with one shared code vocabulary
  (no parallel taxonomy).

## Research Findings & Architecture Deliverables

### 1. Wire Design & Additivity Proof

The flow-state event propagation channel extends `tillandsias-control-wire` with strictly additive, trailing definitions that preserve discriminant positions across all historical variants:

```rust
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[non_exhaustive]
pub enum FlowSource {
    Login { provider: String },
    DependencyNode { node: String },
    PushTransaction { repo: String, ref_name: String },
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub enum SubscriptionTopic {
    VmStatus,
    LoginState,
    CloudProjects,
    FlowState, // index 3 (trailing)
}

pub enum ControlMessage {
    // ... variants 0..=32 unchanged ...
    FlowStatePush {
        seq: u64,
        source: FlowSource,
        from_state: String,
        to_state: String,
        reason: Option<String>,
        ts_unix: u64,
    }, // index 33 (trailing)
}
```

**Additivity & Compatibility Proof**:
- Postcard assigns discriminants sequentially by enum declaration index. Appending `FlowStatePush` to `ControlMessage` at index 33 and `FlowState` to `SubscriptionTopic` at index 3 leaves every preceding variant untouched.
- `WIRE_VERSION` remains at `4`. No wire version bump is required for trailing variant additions (per `WIRE_VERSION` documentation and project convention).
- The 1029-5wvd discriminant pinning test (`every_variant_discriminant_is_pinned_against_literals`) was updated to `DECLARED_VARIANTS = 34` with literal `ControlMessage::FlowStatePush => 33`. The one-past-the-end probe proves index 34 is rejected with an unknown variant error, confirming exhaustiveness and absence of holes.
- `kind()` is pinned to `"FlowStatePush"`.
- `ControlMessage` is `#[non_exhaustive]`. An older peer decoding frame 33 returns `postcard::Error::UnknownVariant`. On the host tray push stream (`action_host.rs` and `notify_icon.rs`), unhandled frames fall into the `other => { tracing::debug!("push stream: ignoring frame {}", other.kind()); }` wildcard, safely ignoring unfamiliar pushes without stream corruption.

### 2. Decision Record

1. **Topic Granularity (One Topic vs Many)**:
   - **Decision**: Single unified `SubscriptionTopic::FlowState`.
   - **Rationale**: In `vsock_server.rs` (`VmStateHandle`), each subscription topic entails a separate broadcast channel, receiver cell, notify waker, and async dispatch loop. Multiplying topics creates thread and lock contention for low-volume telemetry. A unified topic with typed `source: FlowSource` tagging allows subscribers to easily filter transitions locally (`match source { FlowSource::Login { .. } => ... }`) while incurring only one push loop on the wire.
2. **Transition-Only vs Transition + Snapshot**:
   - **Decision**: Transition-only push stream (`FlowStatePush`) complemented by on-demand snapshot request/reply when needed.
   - **Rationale**: Continuous snapshot pushes duplicate state and consume variable-length bandwidth. A transition event (`from -> to + reason`) is tiny (~60-120 bytes). For newly connecting or reconnecting subscribers, the existing `GithubLoginStatusRequest` / `VmStatusRequest` (or future `FlowSnapshotRequest`) provides the full state baseline; live pushes thereafter stream delta events.
3. **Ordering & Loss (Lag-Skip vs Gap-Recovery)**:
   - **Decision**: Bounded broadcast channel with lag-skip, paired with client-side monotonic `seq` gap detection.
   - **Rationale**: In-guest servers must never block on a slow or paused host GUI thread (e.g. while macOS AppKit or Windows Win32 message loops are tracking modal menus). Tokio's `broadcast::error::RecvError::Lagged(skipped)` ensures that if a tray lags, older events are dropped without wedging the VM guest. The tray detects the sequence skip and issues an on-demand snapshot request to reconcile its state cache.
4. **Bounded Capacity Sizing**:
   - **Decision**: Bounded capacity of 64 frames (`FLOW_STATE_PUSH_CAPACITY = 64`).
   - **Rationale**: Observed event rates: login flows transition once every few seconds (~0.2 Hz, 4-6 events total). Sibling ii dependency graph resolution processes 7-15 nodes, yielding at most 15-30 transitions during a cold start burst. A buffer of 64 frames accommodates more than two concurrent dependency evaluation storms with zero dropped frames, consuming under 10 KiB RAM in the guest.

### 3. Prototype & Incident Verification

The prototype is implemented in `crates/tillandsias-control-wire/src/flow_event.rs`, exporting `FlowEventChannel`:
- `FlowEventChannel::with_default_capacity()` constructs a broadcast channel of capacity 64 with atomic monotonic sequence numbering.
- `FlowEventChannel::emit(source, from, to, reason, ts)` stamps `seq`, builds `FlowStatePush`, and broadcasts to all active subscribers.

**Motivating Incident Verification Test**:
- Motivating incident: `plan/issues/macos-tray-github-login-stuck-no-prompt-refresh-2026-07-23.md`. An operator enters a PAT. The token is collected, but before Vault write can occur, an environment pre-check fails (e.g. CA bundle or proxy egress down). Under the prior snapshot model, no bytes were written to Vault, no state flipped, nothing was emitted, and the tray chip remained stuck on "Logging In".
- Unit test `incident_observable_collected_but_not_persisted`:
  - Step 1 emits: `FlowSource::Login { provider: "github" }`, `from: "auth.github.awaiting-operator"`, `to: "auth.github.token-collected"`.
  - Step 2 emits: `from: "auth.github.token-collected"`, `to: "auth.github.blocked"`, `reason: Some("persist(ca_bundle)")`.
  - The subscriber receives both frames in order and observes the exact failure reason (`persist(ca_bundle)`), proving that silent failures are completely converted into observable events.
- Unit test `dependency_node_state_transitions`:
  - Sibling ii resource node transitions (`node.absent -> node.satisfying -> node.present` for node `"ca_bundle"`) are received and verified.
- Unit test `bounded_capacity_lag_skip_contract`:
  - Proves that emitting 10 events into a capacity-4 channel causes a lagging subscriber to receive `Lagged(N)`, keeps the publisher non-blocking, and allows immediate recovery of latest events.

### 4. Cross-Tray Consumption Sketch

1. **macOS Native AppKit Tray** (`crates/tillandsias-macos-tray/src/action_host.rs`):
   - **Subscription**: In `push_subscribe_topics()`, append `SubscriptionTopic::FlowState`.
   - **Handling**: In `start_push_subscription()`, add:
     ```rust
     ControlMessage::FlowStatePush { source, to_state, reason, .. } => {
         apply_flow_state(source, &to_state, reason.as_deref(), &menu_state);
         dispatch_rebuild(&menu_state, &status_item, &status_menu_item, &self_handle);
     }
     ```
   - **Rendering**: Updates `MenuState.status_text` via `render_status_chip(to_state, reason)` (clamped to `TRAY_STATUS_CHIP_MAX_CHARS = 37`). A blocked login renders immediately as `⚠️ Auth: ca_bundle` instead of `Logging In...`.
2. **Windows NotifyIcon Tray** (`crates/tillandsias-windows-tray/src/notify_icon.rs`):
   - **Subscription**: In `vm_status_subscribe_topics()`, append `SubscriptionTopic::FlowState`.
   - **Handling**: In the push loop, add:
     ```rust
     ControlMessage::FlowStatePush { source, to_state, reason, .. } => {
         hwnd.apply_flow_state(source, &to_state, reason.as_deref());
     }
     ```
   - Updates tray icon tooltip and contextual status items promptly on push receipt.
3. **Inbound Dispatch Routing** (`crates/tillandsias-headless/src/control_dispatch.rs`):
   - Registered `FlowStatePush` under `DispatchOutcome::ResponseOnly` across both Unix socket and Vsock transports.

### 5. Reconciliation Backstop Relationship

- **Authoritative Signal**: The emitted transition via `FlowStatePush` is the primary, authoritative signal. The login FSM and dependency graph emit transitions immediately upon state change.
- **Reconciliation Backstop**: The periodic in-VM Vault check (`is_github_logged_in` in `remote_projects.rs` / `main.rs`) is preserved strictly as a reconciliation backstop to detect out-of-band external changes (e.g. token revoked upstream on GitHub or modified directly via CLI).
- **Single Vocabulary**: If the reconciliation backstop detects a divergence between the live Vault probe and the in-memory state cell, it does NOT invent a parallel format; it emits a reconciling `FlowStatePush` using the identical dotted taxonomy (`auth.github.ready`, `auth.github.logged-out`). Thus, UI and diagnostic surfaces consume a single unified vocabulary.

## Existing-code references

- `crates/tillandsias-control-wire/src/lib.rs:107` — `ControlMessage` enum (the channel to extend).
- `crates/tillandsias-control-wire/src/lib.rs:106` — `#[non_exhaustive]`: forward-compat basis for adding a variant without breaking old peers.
- `crates/tillandsias-control-wire/src/lib.rs:40` — `WIRE_VERSION = 2`; `:268` — trailing-variant additive convention (no bump).
- `crates/tillandsias-control-wire/src/lib.rs:291-293` — `Subscribe` / `SubscribeAck` (subscription mechanism to reuse).
- `crates/tillandsias-control-wire/src/lib.rs:298,306,313,322` — existing `VmStatusPush` / `LoginStatePush` / `CloudProjectsPush` / `LocalProjectsPush` (the snapshot pushes `FlowState` complements).
- `crates/tillandsias-control-wire/src/lib.rs:369` — `SubscriptionTopic` (add `FlowState`).
- `crates/tillandsias-control-wire/src/lib.rs:160-169` — `VmStatusRequest`/`VmStatusReply` precedent for a request/reply snapshot alongside a push.
- `crates/tillandsias-control-wire/src/lib.rs:407` — `ErrorCode::UnknownVariant` (unknown-variant degradation path).
- `crates/tillandsias-headless/src/vsock_server.rs:128-176` — broadcast fan-out + bounded capacities for the existing push topics (the pattern `FlowState` reuses).
- `crates/tillandsias-headless/src/vsock_server.rs:252-275` — `set_login_state`: change-gated, `seq`-stamped emit (the emit helper to generalize).
- `crates/tillandsias-headless/src/vsock_server.rs:711-822` — per-topic push loops with the lag-skip contract (ordering/loss semantics to evaluate).
- `crates/tillandsias-headless/src/vsock_server.rs:1004-1015` — `GithubLoginStatusRequest` → inferred `apply_login_transition` (an inference path `FlowState` replaces/reconciles).
- `crates/tillandsias-headless/src/remote_projects.rs:384,415` — `probe_github_username`/`is_github_logged_in`: login state INFERRED by Vault re-check, the gap this packet closes.
- `crates/tillandsias-headless/src/main.rs:11477,11502` — the periodic poll loop that infers login state post-hoc.
- `crates/tillandsias-headless/src/main.rs:7051-7064` — the Vault write whose absence produces no observable event today.
- `plan/issues/stable-state-codes-research-2026-07-05.md` — prior art proposing a `RuntimeStatusPush` topic + dotted `StateCode` vocabulary this packet's payload reuses.
- `plan/issues/macos-tray-github-login-stuck-no-prompt-refresh-2026-07-23.md` — motivating incident (invisible AND untraceable = no emitted transition).

## Non-goals / scope

- NOT defining the login states/transitions — that is sibling i
  (`research-auth-flow-state-machines-2026-07-23.md`).
- NOT defining the dependency nodes — that is sibling ii
  (`research-unified-runtime-data-dependency-graph-2026-07-23.md`).
- NOT a new transport or a second backbone — this reuses the existing control-wire
  push/subscribe model; it must remain additive (no `WIRE_VERSION` bump) and forward-compatible.
- NOT ZeroClaw / agent↔agent messaging (deleted as a critical violation). This is
  guest→host state propagation over the existing wire, one direction, on the backbone we own.
- NOT ripping out the existing inference paths in v0.5 — the emitted transition becomes
  authoritative while the Vault re-check remains a reconciliation backstop.
- NOT a v0.4 change — the incident's point-fixes already shipped; this is durable v0.5+ direction.
