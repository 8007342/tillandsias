# Order 155 "zero-sleep transport path" exit criteria vs the accepted fallback-poll design (2026-07-10)

- class: exploration (definition-of-done clarification — Tlatoāni-gated)
- filed by: macOS overnight cycle 6/8
- affects: plan/index.yaml order 155 (macos-tray-stream-refactor) exit_criteria,
  and by symmetry order 144/154 (windows) if the same wording is mirrored

## Observation

Order 155's exit criteria include:

- "No tokio::time::sleep in macOS tray transport path (SC-01, SC-02)"
- "If macOS tray has action_host.rs polling, it is eliminated"

But the architecture that all three trays converged on (slices 1-4 + the
shared subscription_health module) DELIBERATELY keeps a fallback poll with a
`tokio::time::sleep` (inside `wait_tick_or_subscription_drop`). The push
subscription is primary; the timer-driven poll runs ONLY while the
subscription is down (SC-07 gate) and covers VM boot, reconnect windows, and
any guest that predates a push topic. Windows adopted the identical shared
helper (order 154 slice 4), so it has the same fallback sleep by design.

So a literal reading of "no tokio::time::sleep in the transport path" is
**unsatisfiable without removing the fallback poll entirely** — which would
trade a proven, self-healing design for total reliance on the subscription +
reconnect logic never missing an update. That is a real risk increase, not an
obvious win.

## Why this matters

The packet cannot reach `done` against a literal exit criterion that the
agreed design intentionally violates. Either:

- (A) the criteria should be reworded to the achieved invariant — e.g. "no
  timer drives status/projects freshness while the push subscription is
  healthy (SC-07); the only remaining sleep is the down-subscription fallback
  poll" — which the current code SATISFIES and is verifiable; or
- (B) the fallback poll really should be removed (zero-sleep), which is a
  deliberate reliability-posture decision with its own risk, and a much
  larger slice.

## Proposal (NOT self-approved — bar/definition change is Tlatoāni-gated)

Recommend (A): reword order 155 (and mirror 144/154) exit criteria to the
SC-07 "no timer while healthy" invariant that the converged design achieves,
and close the packet's stream-refactor body as done, leaving any true
zero-sleep push as a separately-scoped reliability packet if desired. This is
a definition-of-done change, so it needs The Tlatoāni's explicit call — filed
here as a proposal, not applied. Until then order 155 stays `ready` with its
current criteria and the watch-channel-menu-listeners slice as its nominal
residual.
