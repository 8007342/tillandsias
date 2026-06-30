# optimization: back credential-channel check with a tillandsias-policy subcommand (parity)

- class: optimization
- filed: 2026-06-21T00:10:00Z
- agent: linux-mutable-opus-cowork-20260621T0004Z
- host: linux_mutable
- related: plan/index.yaml order 61 (credential-channel-check, done),
  litmus:credential-channel-check-shape

## Observation

Order 61 closed with a standalone `scripts/check-credential-channel.sh` that is
executable, falsifiable, and litmus-bound. The original handoff note preferred a
`tillandsias-policy credential-channel` Rust subcommand *dispatched* by the thin
script. The script-only path was chosen because:

1. it fully satisfies the order's outcome (executable pass/fail check, CI-bindable,
   fails loud on its own), and
2. it mirrors the already-shipped order-60 `scripts/e2e-preflight.sh`, which is
   likewise script-only with no policy-binary backing.

So the Rust subcommand is not required for closure; it is a parity/uniformity
nicety, not a correctness gap.

## Why it might still be worth doing

- A single validated implementation in `tillandsias-policy` would let CI invoke
  the verdict without shelling a repo script, and would centralize the verdict
  grammar next to other policy checks.
- Tension: more surface area / build dependency for a check that bash already
  expresses in ~30 lines. Likely low ROI until other guards also migrate to the
  policy binary, at which point doing them together amortizes the cost.

## Smallest verifiable next step (if promoted)

Add `tillandsias-policy credential-channel` emitting the identical grammar
`^(ok:[a-z0-9-]+|missing:no-credential-channel)$` with the same exit semantics;
have `scripts/check-credential-channel.sh` dispatch to it when the binary is on
PATH and fall back to the inline bash otherwise; extend
`litmus:credential-channel-check-shape` with a step asserting binary/script
verdict equivalence. Pickup role: build-capable host (Rust toolchain).

Status: open, not promoted. Bar-raise not implied; this is a parity optimization
at the current bar.
