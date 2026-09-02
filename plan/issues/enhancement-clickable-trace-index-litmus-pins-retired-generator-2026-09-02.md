# enhancement: two clickable-trace-index litmus tests pin a retired generator and a live stack (2026-09-02)

Found on macuahuitl during the meta-orchestration cycle of 2026-09-02T07:08Z
while widening the ghost-trace gate to markdown (867-vd4z). Both tests under
`spec: clickable-trace-index` FAIL through the real runner
(`scripts/litmus-run-one.sh`), on causes that predate the change:

- `litmus:clickable-trace-index-generation` step 1 runs
  `test -x scripts/generate-traces.sh` — that script was retired when
  `scripts/trace-coverage.sh` replaced the rendered `TRACES.md` (its header
  records the retirement). The test pins a file the tree no longer has, so it
  has been red since the retirement and unobserved because it was never run by
  a scoped selection (the runner's stdin defect hid whole spec lists until
  8438cbf2b, and the instant sweep now reaches it only if its size/phase match).
- `litmus:clickable-trace-index-observatorium-skeleton` step 1 launches the
  observatorium (`[run-observatorium] NOTE: localhost/tillandsias-web:v56.8.31.3
  not built yet; using ...v56.9.1.2`) — an environmental precondition (a built
  web image at the tree's VERSION, a running stack) that the test asserts as a
  failure instead of a `skip:` with a reason (the 956-llei precondition-gating
  class).

Neither is a regression of the markdown rung: `scripts/trace-coverage.sh
--gate` is green (`baseline=18 current=18`, annotations 4963 over 1585 files).

## Disposition

- generation: re-pin step 1 to the live instrument (`scripts/trace-coverage.sh`
  present and executable, and the spec naming it) or retire the test if the
  clickable index is itself retired — the spec `clickable-trace-index/spec.md`
  still names `generate-traces.sh`, so the spec is stale too (freshness class,
  order 372).
- observatorium-skeleton: convert the missing-image / no-stack case to a
  typed `skip:` precondition so the test is a verdict about the skeleton, not
  about whether this host happens to have the stack up.

Owner: whoever next drains `clickable-trace-index` (linux). Not claimed here —
the cycle's story was convergence-velocity (911/867/890) and this is a
different spec's debt.
