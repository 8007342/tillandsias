# Pretty events in the status menu — ordered, human-readable FlowState transition feed in all three trays (2026-07-24)

- **Date**: 2026-07-24
- **Class**: feature (presentation half; the transport is deliberately a separate packet)
- **Area**: tray UX / status menu / control-wire push consumption
- **Severity**: P2 enhancement — nothing is broken; this turns invisible transitions into visible, ordered history
- **Owner**: any host, cross-tray (shared fold/renderer lands in `tillandsias-host-shell`; each tray adds one thin adapter)
- **Discovered-by**: operator directive (The Tlatoāni, 2026-07-24): "pretty events in our status menu item"
- **Status**: proposed
- **Desired release**: v0.5 (operator may pull the first slice forward)
- **Sibling (transport, NON-overlapping)**: `plan/issues/research-flow-state-event-channel-2026-07-23.md` —
  that packet defines `FlowStatePush {seq, source, from_state, to_state, reason, ts_unix}` over the
  control-wire and EXPLICITLY excludes presentation. This packet is that excluded half: rendering the feed.

## What the operator asked for

An ordered, human-readable transition feed inside the tray status area, in all three trays. Today the
status surface is a single mutable chip line: `menu_state.rs:294` (`status_text: String`) rendered
through `clamp_tray_status_chip` (`crates/tillandsias-host-shell/src/menu_state.rs:96,445`). History is
destroyed on every update — when "Connecting" replaces "Starting Fedora Linux" the prior state is gone,
and a user who opens the menu after a failure sees only the final chip, not how it got there.

## Precedent

Commit `a4512c9d` (macOS status-UX parity, 2026-07-23) proved the pattern this feed generalizes:
boot/connect chips emitted around `vz.start()` (`crates/tillandsias-macos-tray/src/action_host.rs:1295-1297`),
tooltip build version, and phases synced into `menu_state.status_text` via `set_status_text`
(`action_host.rs:1568`). Windows folds phases the same way (`crates/tillandsias-windows-tray/src/notify_icon.rs:205-206,221`);
Linux via `status_label` (`crates/tillandsias-headless/src/tray/mod.rs:183`). Those are per-phase
chip REPLACEMENTS; this packet renders the last-N transitions as an ordered feed instead.

## Design sketch

- A collapsible "Events" section under the status chip: last-N transitions (N≈8), newest first, each
  line `<severity glyph> <human phrase> · <relative ts>` (e.g. "🔴 Sign-in interrupted · 2m ago").
- Zero polling: the feed is folded EXCLUSIVELY from `FlowStatePush` subscription frames (sibling
  packet), ordered by wire `seq` — no timer re-derives state.
- One shared vocabulary: the human phrase is a lookup from the dotted `StateCode`/`ReasonCode` table
  (`plan/issues/stable-state-codes-research-2026-07-05.md`) — the SAME codes the wire carries. No
  parallel taxonomy; an unknown code renders a neutral fallback glyph + generic phrase.
- One shared fold/renderer in `tillandsias-host-shell` (next to `menu_state::build`,
  `menu_state.rs:445`); the three trays consume its output verbatim, mirroring the byte-identical
  helper discipline pinned by `openspec/litmus-tests/litmus-tray-status-text-helpers-symmetric.yaml`.
- Reuse the existing text hygiene: every rendered line passes the clamp/sanitize path
  (`menu_state.rs:96`, `tray/mod.rs:259,271`) so a multi-KB reason cannot blow up the menu.

## HARD GATE — UX curation governance

`openspec/specs/tray-ux/spec.md:13` ("UX curation governance — Tlatoāni approval is MANDATORY for
every UX change"): no agent may add or alter ANY menu surface without EXPLICIT prior operator
approval recorded in the plan ledger (`spec.md:26-30`); precedent: the unapproved reset-guest leaf
was reverted by operator order (`spec.md:39-46`, commit `66761da2`). Additionally, internals
vocabulary (VM, WSL, enclave, mirror, vault, container, podman, provisioning) MUST NOT appear in
end-user text (`spec.md:31-32`). Therefore this packet ships the feed logic DARK: the fold/renderer
and adapters land behind a default-off gate, and the menu leaf is only emitted after an
operator-attributed approval event is recorded on this packet for the exact surface (placement,
label, N, glyph set).

## Implementation slices

1. Shared fold/renderer in `tillandsias-host-shell`: `FlowStatePush` frames → bounded ordered feed
   model → rendered lines (code→phrase table, severity glyph, relative timestamp). Gate default-off.
2. Per-tray adapters: subscribe alongside existing topics and hand frames to the shared fold —
   Linux `tray/mod.rs`, macOS `action_host.rs` push listener, Windows `notify_icon.rs`.
3. Operator review of a rendered mock (screenshot or text dump per tray); on recorded approval,
   flip the gate, emit the leaf, and add the parity-matrix row.

## Exit criteria (each backed by a VERIFIABLE constraint)

1. **Governance gate holds while dark**: a pin test in `tillandsias-host-shell` asserts
   `menu_state::build` emits NO events leaf/section in the default configuration; the commit that
   flips the gate MUST carry the operator-approval event in this packet's plan-ledger node.
   Check: `cargo test -p tillandsias-host-shell` (pin test named for the events leaf) stays green
   before and after; approval event grep-able in `plan/index.yaml` under this packet_id.
2. **Ordered, bounded, event-driven fold**: a unit test feeds >N synthetic `FlowStatePush` frames
   (out-of-order `seq` included) and asserts the model holds exactly the last N, ordered by `seq`
   descending, with correct relative-timestamp buckets. Check: `cargo test -p tillandsias-host-shell`.
3. **Zero polling**: a litmus shape test (pattern: `litmus-tray-status-text-helpers-symmetric.yaml`)
   asserts the feed module contains no timer/interval/poll construct — the only input is the
   subscription frame handler. Check: `scripts/run-litmus-test.sh <new litmus id> --size instant`.
4. **Cross-tray parity**: identically-named fold/render pin tests pass in all three tray crates
   (the shared renderer is the single source; adapters only route frames). Check:
   `cargo test -p tillandsias-headless -p tillandsias-macos-tray -p tillandsias-windows-tray`
   (macOS/Windows bodies cross-typechecked per commit `e621c20b`).
5. **Curated vocabulary, no internals leakage**: a test iterates the ENTIRE code→phrase table and
   asserts no rendered line contains any `spec.md:31-32` forbidden term, every line survives
   `clamp_tray_status_chip` unchanged, and an unknown dotted code renders the fallback (never a
   panic, never the raw code). Check: `cargo test -p tillandsias-host-shell`.
6. **Parity matrix row (on implementation)**: `openspec/tray-parity-matrix.yaml` gains a
   `capability: "Status events feed (last-N FlowState transitions)"` row with `parity: "required"`
   and per-OS status. Check: a YAML-parse assertion (litmus or `python -c 'yaml.safe_load'`) that
   the row exists and carries the `parity` key — not prose.

## Existing-code references

- `crates/tillandsias-host-shell/src/menu_state.rs:294,324,445` — `status_text` chip + `build()` render path the feed extends.
- `crates/tillandsias-host-shell/src/menu_state.rs:96` — `clamp_tray_status_chip` (text hygiene to reuse).
- `crates/tillandsias-headless/src/tray/mod.rs:183,259,271` — Linux `status_label` + hard-cap + `sanitize_status_text`.
- `crates/tillandsias-macos-tray/src/action_host.rs:790,1568,1295-1297` — chip constants, `set_status_text`, phase emits (commit `a4512c9d`).
- `crates/tillandsias-windows-tray/src/notify_icon.rs:205-206,221` — `on_phase` → `update_status_text` fold.
- `crates/tillandsias-control-wire/src/lib.rs:369` — `SubscriptionTopic` (the `FlowState` topic the feed subscribes to; sibling packet).
- `openspec/specs/tray-ux/spec.md:13,26-32,39-46` — the governance gate this packet is built around.
- `openspec/litmus-tests/litmus-tray-status-text-helpers-symmetric.yaml` — cross-tray symmetric-helper litmus pattern to extend.
- `plan/issues/stable-state-codes-research-2026-07-05.md` — the dotted code vocabulary the phrases key off.

## Non-goals / scope

- NOT the transport: `FlowStatePush` wire shape, topics, lag-skip vs gap-recovery, snapshot-on-subscribe
  are the sibling packet. If it decides transitions can be dropped, this feed renders a gap marker —
  it does NOT add its own recovery protocol.
- NOT defining login FSM states or dependency-graph nodes (those siblings feed the vocabulary).
- NOT a notification/toast system, and NOT a diagnostics surface — `--diagnose`/logs remain the
  agent-facing channel (`spec.md:33-35`); this is the curated end-user menu only.
- NOT shipped visible without the recorded operator approval — dark until sign-off, per the hard gate.
