# Secure-channel hardening: PSK parity, release-secret enforcement, readiness probes — 2026-07-05

- class: security+release hardening
- owner: any, with macOS evidence where VZ probes are involved
- status: ready
- order: 194
- trace: plan/issues/secure-channel-maturity-ladder-2026-07-04.md,
  plan/issues/secure-channel-flag-and-maturity-metrics-2026-07-04.md

## Finding

The secure-channel primitive and guest responder exist, but the M1 evidence still
has several hardening gaps:

- macOS user action paths use the workspace `VERSION` for PSK input, while at least
  one diagnostic path derives from `CARGO_PKG_VERSION`.
- VM readiness probes still use raw control-wire streams in places, so flag-ON
  guests can fail readiness even though user actions use the secure opener.
- Release build paths must prove `TILLANDSIAS_RELEASE_SECRET` is injected; otherwise
  release artifacts can silently use the public dev seed.
- The plan says unauthenticated peers receive `Unauthorized`, but a Noise failure
  before control envelopes exist can only fail closed by closing the stream. The
  requirement should be phrased as "no HelloAck/no PtyOpen; close before envelope"
  unless a pre-handshake error frame is explicitly designed.

## Work

1. Normalize all host initiator PSK inputs to the same workspace `VERSION`.
2. Route `wait_phase_ready` / `probe_vm_phase` through the same secure-or-plain
   opener used by user actions.
3. Add release CI/litmus evidence that release artifacts cannot build with the
   public dev seed.
4. Update secure-channel plan text where needed so failure-closed semantics match
   the implementable handshake boundary.

## Acceptance Evidence

- `psk-input-parity` litmus proves all secure openers use the same version source.
- `secure-wait-phase-ready` litmus proves readiness probes work in flag-ON mode.
- `release-secret-required` litmus or CI step fails release builds without
  `TILLANDSIAS_RELEASE_SECRET`.
- Flag-ON plaintext/wrong-version peers receive no `HelloAck` and cannot trigger
  `PtyOpen`.
