# Mirror startup retry-push is atomic over ALL refs — one stale ref blocks the whole sweep (2026-07-20)

- **Class**: optimization (robustness / self-healing)
- **Severity**: medium — degrades startup self-sync; does NOT block live agent pushes
- **Found**: live, during the 2026-07-20 attended meta-orchestration cycle, watching
  the running `tillandsias-git-tillandsias` mirror after a fresh build+install
- **Spec**: git-mirror-service
- **Owner host**: linux

## Observation

The mirror's startup retry-push (`images/git/entrypoint.sh`, the
`Startup retry-push` sweep) fabricates synthetic receive records for EVERY ref
and pipes them into `tillandsias-relay-refs` in a single invocation. relay-refs
pushes them with `git push --atomic`. Live log:

```
[git-mirror] Startup retry-push FAILED: [relay] Relaying 216 update(s) ...
[relay] Atomic push ... FAILED: ... 216 refs including refs/heads/audit,
        refs/heads/release/*, refs/tags/v0.0.* ...
error: failed to push some refs to 'https://github.com/8007342/tillandsias.git'
[relay] Attempting non-forced reconcile fetch from upstream...
[relay] Reconcile fetch non-fast-forward (expected if locally stranded)
```

Because the push is `--atomic`, a SINGLE non-fast-forward ref (here, stale
`release/*` branches the mirror retained on its persistent named volume across
rebuilds, which upstream has since moved) rejects the ENTIRE transaction. None
of the many fast-forwardable refs get flushed either.

## Why it happens

The mirror stores refs on a persistent named volume
(`tillandsias-mirror-<project>`), so it retains OLD heads/tags across image
rebuilds. When upstream has force-moved or the mirror's copy of any ancient
branch diverges, the all-refs atomic startup sweep can never succeed until that
one ref is reconciled — which the sweep itself does not do per-ref.

## Why it is only medium severity

The startup sweep is a RECOVERY mechanism (flush refs received while upstream
was unreachable). It is not on the live push path: an agent pushing a single
branch (`linux-next`) produces a targeted single-ref relay that succeeds
independently. Verified live this cycle — the Vault renewer is healthy and
targeted pushes are expected to work. So this degrades startup self-healing,
not active development.

## The fix (verifiable closure for the promoted packet)

Make the startup sweep per-ref tolerant instead of all-or-nothing: relay each
ref (or each independent group) separately so a fast-forwardable ref is flushed
even when a sibling ref is stranded, and a stranded ref is logged by name rather
than silently taking down the whole sweep. Preserve the live path's atomicity —
a single agent push transaction must stay atomic; only the STARTUP recovery
sweep changes.

Verifiable: a fixture that seeds a mirror with one diverged ref plus several
fast-forwardable refs, runs the startup sweep, and asserts the ff-able refs
reached upstream while the diverged one is reported by name. That fixture must
REPRODUCE the current all-atomic failure before proving the per-ref behaviour,
in the fail-loud style established 2026-07-19.

## Non-goals

Do NOT weaken the live single-push atomicity, and do NOT touch the explicit
non-`--mirror`/`--all` refspec invariant (a `--mirror` push once deleted 133
tags from upstream). This is only about the startup recovery sweep's granularity.
