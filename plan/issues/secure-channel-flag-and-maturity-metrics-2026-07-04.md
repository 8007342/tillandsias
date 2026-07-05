# Research: secure-channel runtime flag propagation + maturity-gate metrics — 2026-07-04

- class: research (security)
- filed: 2026-07-04
- owner: linux (coordinator)
- status: ready
- depends_on: secure-channel-maturity-ladder-2026-07-04.md
- trace: order 141 (primitive), order 145 (cutover), spec:control-wire

## Q1 — flag propagation (boot-time, enclave-wide, NOT per-connection)

The ladder's safety rests on the mode being one coordinated boot-time setting, not a
per-connection negotiation (no downgrade surface). Research + decide:

- **Single source of truth:** `TILLANDSIAS_SECURE_CONTROL_WIRE ∈ {off,on}` read once
  at enclave bring-up. Where is it authoritatively set (tray → headless → guest →
  container), and how does each initiator + responder learn the SAME value for a boot?
- **Propagation path:** env var through the launch chain vs. a value baked into the
  bring-up handshake/Hello vs. derived from WIRE_VERSION. It must be impossible for
  the guest to be "on" while an initiator is "off" for the same boot (that bricks the
  wire) — so propagation + a pre-flight agreement check are required.
- **Interaction with WIRE_VERSION:** the PSK already binds build+wire version; confirm
  a mixed-version pair fails closed (rejected), never silently downgrades.
- **Failure mode:** if propagation is ambiguous, the enclave must refuse to start
  (fail-closed) rather than come up half-encrypted.

## Q2 — quantitative maturity-gate metrics (ratify the ladder's N/D/M/E)

The master ladder uses placeholder targets; this packet ratifies them + defines HOW
each is measured:

| Gate | Condition | Proposed target | How measured |
|---|---|---|---|
| M1→M2 | flag-ON e2e green per platform + failure-closed litmus green | all 3 platforms, 1 green smoke each | per-host VM smoke evidence in the ledger |
| M2→M3 | opt-in soak stable | N=3 releases AND D=14 days, 0 encrypted-path regressions | release tags + a soak counter in loop_status / a metrics field |
| M3→M4 | secure-default soak, escape hatch unused | M=4 releases AND E=30 days, 0 fallback invocations | telemetry counter on flag=off invocations + operator attestation |
| M4 | plaintext removed, downgrade impossible | n/a | litmus: plaintext peer cannot connect on any hop |

Decide: are N/D/M/E right for this project's release cadence? What telemetry actually
exists to count "encrypted-path regressions" and "escape-hatch invocations" (does the
metrics crate expose a counter, or must one be added)? A gate that can't be measured
can't be a gate.

## Q3 — observability for the gates
- What log/metric proves "handshake succeeded on hop X, platform Y, build Z"?
- A soak dashboard row (per platform, per rung) so advancing a gate is evidence-based.
- Reuse `tillandsias-metrics` / `tillandsias-logging`? What's the minimal counter set?

## Verifiable closure
- Flag propagation mechanism chosen + a pre-flight agreement check specified
  (fail-closed on disagreement).
- N/D/M/E ratified with a measurement method for each; telemetry gaps filed as impl
  sub-packets.
- The master ladder updated with the ratified numbers + the observability plan.
