# research: `build.sh --check` emits no timing record, so `timing:` reads `source=absent` forever — the cycle's slowest step stays unmeasured

- **Filed**: 2026-08-12
- **Host**: macos (Tlatoani's MacBook Air)
- **Class**: `research/` — the mechanism is not yet identified; the two obvious
  hypotheses are already REFUTED below, so this needs a look, not a guess.
- **Order**: 697-s3by
- **Status**: open

## Symptom

`scripts/cycle-metrics.sh` reports:

```
timing: steps=0 build_check_ms_avg=- litmus_ms_avg=- slowest=-:- source=absent
```

on every cycle of this session, after `./build.sh --check` ran **five times**
to completion (green, gate stamp recorded). `/tmp/tillandsias-timing.jsonl` did
not exist at any point.

This matters more than a missing counter. The meta-orchestration skill names
this metric's purpose explicitly — *"where does the cycle's wall-clock go?"* —
and calls building/testing "the most likely bottleneck". `slowest` is supposed
to name the one step to attack first. While it reads `absent`, the single most
expensive part of every cycle on every host is unmeasured, and packet 682-emvg's
deliverable is not actually in effect where it matters most.

Concretely, this session paid the gate FIVE times (695-nvnd covers one avoidable
cause) with no record of what that cost.

## The wiring looks correct, which is why this is `research/`

- `build.sh:66` sources `scripts/timing-log.sh`; `:67` installs no-op stubs if
  that fails.
- `build.sh:988` captures `_CHECK_T0`, `:989` sets `trap 'timing_emit
  build-check check "$_CHECK_T0" $?' EXIT`, `:1047` emits explicitly.
- `scripts/local-ci.sh:429` emits per phase.
- `scripts/timing-log.sh:40-58` `timing_emit` shells out to
  `cycle-metrics.sh --emit-timing`.

## Hypotheses already REFUTED — do not re-chase these

1. **"The emitter is broken."** No. Called directly it works and creates the
   log:
   `bash scripts/cycle-metrics.sh --emit-timing step=probe phase=probe duration_ms=42 exit=0 host=macos`
   → `/tmp/tillandsias-timing.jsonl` created, 102 bytes. (The probe record was
   removed after the test so it cannot pollute a real rolling average.)
2. **"bash 3.2 can't parse `timing-log.sh`, so macOS silently gets the no-op
   stubs."** This was my leading theory — the host is bash 3.2 and `build.sh:66`
   swallows a source failure with `2>/dev/null || true`, which would degrade
   silently and invisibly. It is WRONG:
   `/bin/bash -n scripts/timing-log.sh` parses clean, and
   `/bin/bash -c '. scripts/timing-log.sh; command -v timing_emit'` reports the
   real function, not the stub.

## Where to look next

The emitter works and the function is defined, so the gap is between them:
whether `timing_emit` is actually reached during a `--check` run, and whether
`cycle-metrics.sh` resolves from `${BASH_SOURCE[0]%/*}` inside the function when
`timing-log.sh` was sourced by an absolute path from a different CWD. Add a
one-line trace at the `timing_emit` call site and run one gate — that
distinguishes "never called" from "called but the shell-out failed silently"
in a single run. Note `timing_emit` swallows every error by design (`|| true`,
`2>/dev/null`, `return 0`) so it can never disturb the wrapped step's exit code:
correct for safety, and exactly why this failed invisibly.

## Verifiable closure

`./build.sh --check` appends exactly one `build-check` duration record per run,
and `cycle-metrics.sh` reports a non-`absent` `timing:` line naming a real
`slowest` step. Plus a **negative control**: a step that fails must still emit
its record with a non-zero `exit=`, so the instrumentation cannot be "fixed" by
only recording successes — the slow path that matters most is usually the one
that failed.
