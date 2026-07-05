# macOS tray status UX: 37-char curated messages and state-code rendering

- class: enhancement (macOS tray UX)
- filed: 2026-07-05
- owner: macos
- pickup_role: macos
- status: claimed
- trace: spec:macos-native-tray, spec:runtime-diagnostics-stream, plan/issues/stable-state-codes-research-2026-07-05.md

events:
  - type: claim
    ts: "2026-07-05T18:00:03Z"
    agent_id: "macos-Tlatoanis-MacBook-Air.local-codex-20260705T180003Z"
    host: macos
    lease_id: "macos-tray-state-code-status-ux-20260705T180003Z"
    expires_at: "2026-07-05T22:00:03Z"
  - type: progress
    ts: "2026-07-05T18:04:01Z"
    agent_id: "macos-Tlatoanis-MacBook-Air.local-codex-20260705T180003Z"
    commits: []
    summary: >
      Added a shared 37-char tray-chip cap in host-shell, switched the
      macOS tray's boot seed text to a shorter BOOTING state, and wired the
      macOS status render path through the shared clamp helper. Updated the
      menu-disabled parity test to expect the new short boot label. Next:
      map the remaining stable state-code taxonomy into richer login/project
      states once the research packet lands.

## Problem

The macOS tray currently exposes an overly coarse setup label while the VM is
already running. That makes the app feel hung even when the runtime is healthy.

The status surface needs to become a real state machine:

- update on observable events, not timer polls
- render finite state codes as short curated messages
- keep the visible chip under a 37-character budget
- prefer meaningful emoji over raw stack traces
- show actionable failure states instead of generic "Setting up" text

## Scope

Implement the macOS tray side of the curated state machine:

1. Consume stable state codes emitted by host/vm/guest/podman layers.
2. Map those codes to short, curated menu-chip messages.
3. Enforce a 37-character hard cap on chip text.
4. Allow multiline / verbose details only in logs or diagnostics, not in the chip.
5. Replace stale setup labels with live state transitions.

## UX constraints

- Chip text hard cap: 37 characters
- Multiline content: never on chip
- Stack traces: never on chip
- Messages should be terse and recognizable at a glance
- Emoji are encouraged when they clarify state
- Failure codes should still feel intentional and teachable

## Example surfaces to support

- starting / booting
- provisioned but waiting on guest readiness
- VM ready but auth missing
- VM ready and projects available
- podman not yet ready
- guest transport unavailable
- auth failed
- guest bootstrap failed
- container launch failed

## Delivery notes

- The implementation should follow the state-code taxonomy from the research
  packet, not invent a second taxonomy.
- The tray should subscribe to state changes via event streams and watch-like
  channels where appropriate.
- Any curated string table should be centralized so Windows/Linux can mirror it.

## Exit criteria

- The macOS tray renders state transitions from codes, not raw error strings.
- Chip text never exceeds 37 characters.
- No multiline stack trace or raw error dump reaches the chip.
- The visible status changes promptly when the VM/guest/podman state changes.
- The tray continues to surface meaningful login/project/forge states when ready.
