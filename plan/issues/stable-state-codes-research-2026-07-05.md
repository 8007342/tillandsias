# Stable state codes for host/vm/guest/podman event-driven status — research packet

- class: research
- filed: 2026-07-05
- owner: any
- pickup_role: any
- status: claimed
- trace: spec:runtime-diagnostics-stream, spec:headless-mode, spec:macos-native-tray, spec:podman-idiomatic-patterns

events:
  - type: claim
    ts: "2026-07-06T18:07:02Z"
    agent_id: "macos-Tlatoanis-MacBook-Air-codex-20260706T1807Z"
    host: macos
    lease_id: "stable-state-codes-research-20260706T1807Z"
    expires_at: "2026-07-06T22:07:02Z"

## Problem

Tillandsias currently has too many ad hoc UI strings and error renderings:

- tray chip text can describe the same failure differently depending on host
- VM, guest, and podman state are not represented by one stable finite model
- some surfaces still infer state from repeated probes or stale labels
- user-facing text and machine-facing state are coupled too tightly

The user requirement here is:

- no polling loops for state discovery
- state must arrive through observable stream channels
- the user-facing chip must stay tiny
- stable codes must exist so finite-state transitions are unambiguous
- a single state code should map to a short curated message on each host

## Research scope

Define a cross-layer status model that covers:

- host tray
- VM lifecycle
- guest headless
- podman lifecycle
- Linux podman backend states where relevant

The research needs to identify:

1. The minimal finite set of canonical state codes.
2. Which layer owns each code.
3. Which codes are terminal versus transitional.
4. Which codes are user-visible versus internal-only.
5. Which codes should emit events on state change.
6. How error codes should remain stable across releases.
7. How the tray should translate codes into short, curated text.

## Desired properties

- Codes are stable and documented.
- Codes are finite and enumerable.
- Codes are layered, not overloaded.
- State changes are event-driven and observable.
- UI strings are derived from codes, not from raw error text.
- Short messages can include emoji, but remain terse.
- The same code should render consistently on macOS, Windows, and Linux.

## Candidate taxonomy to validate

- host/bootstrap states
- VM materialization states
- guest boot states
- guest auth/login states
- podman/container readiness states
- transport states
- terminal / menu rendering states
- failure states with stable error codes

## Exit criteria

- A finite state machine is proposed for host/vm/guest/podman.
- Stable error-code naming is proposed.
- The proposed codes map cleanly onto observable stream events.
- The proposal specifies how the tray converts codes into <=37-char messages.
- The proposal calls out any states that should remain internal-only.
- A follow-on implementation packet can consume the result without guessing.
