# RESEARCH: first-class message-channel + event propagation so flow/dependency transitions are OBSERVABLE (2026-07-23)

- **Class**: research (MANDATORY before implementation, operator standing rule)
- **Status**: proposed
- **Desired release**: future (v0.5+) — NOT blocking current v0.4/v0.3 work; durable direction
- **Owner host**: any (the control-wire backbone + push listeners span the guest headless and all three trays)
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
