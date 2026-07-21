# The destructive e2e gate can wipe a live operator/agent forge (2026-07-20)

- **Class**: enhancement (safety guard)
- **Severity**: high — silent destruction of concurrent operator/agent work
- **Found**: live, during the 2026-07-20 attended meta-orchestration cycle. The
  operator had a forge running (BigPickle mid-cycle inside it) while asking for a
  host meta-orchestration cycle.
- **Spec**: litmus-framework / e2e gates
- **Owner host**: linux

## Observation

`scripts/e2e-preflight.sh eligibility` returned `eligible` while a live forge
(`tillandsias-tillandsias-forge`) plus its mirror, vault, proxy, router, and
inference containers were running and an agent (BigPickle) was executing a
meta-orchestration cycle inside it.

The meta-orchestration runbook then says local-build e2e uses
`/build-install-and-smoke-test-e2e`, whose FIRST step is
`podman system reset --force`. Had this cycle followed the probe verdict
literally, it would have **destroyed the operator's live forge and BigPickle's
in-flight cycle without warning.** This cycle overrode the probe by hand.

## Root cause

The eligibility probe only skips on `smoke-lock-held` — i.e. it detects another
SMOKE run holding the host lock. An operator- or agent-launched forge does NOT
hold the smoke lock, so a concurrent forge is invisible to the probe. The
destructive reset therefore treats "no competing smoke" as "safe to wipe
everything", which is false whenever a human is running the product.

`TILLANDSIAS_DESTRUCTIVE_RESET_OK` gates the reset, but it defaults to
"proceed" (unset or 1). The default assumes an unattended smoke host with
nothing worth keeping. That assumption breaks the moment the same host is also
where an operator runs the app — which is exactly the attended mode the operator
asked for here.

## The fix (verifiable closure)

Before the destructive reset, the gate must detect a live Tillandsias runtime it
did not itself create and REFUSE rather than wipe it. Concretely: if any
`tillandsias-*-forge*` (or the shared stack) is running and was not launched by
this smoke run, emit a `skip:live-runtime-present` verdict from
`e2e-preflight.sh eligibility` and do not reset. An explicit operator override
(`TILLANDSIAS_DESTRUCTIVE_RESET_OK=1` set for THIS invocation) may still force
it, but the default must fail safe.

Verifiable: a fixture that starts a marker container matching the forge naming
pattern, runs the eligibility probe, and asserts `skip:live-runtime-present`
(exit non-eligible); and asserts `eligible` again once the marker is removed.
Reproduce the current `eligible`-despite-live-forge behaviour first.

## Why this matters beyond this cycle

The whole automation direction is toward operators and agents running forges on
the same hosts that also run unattended smoke cycles. A destructive gate that
cannot see a live forge is a data-loss path for that model — the same class as
the two forge data-loss paths closed 2026-07-19, but at the substrate level.
