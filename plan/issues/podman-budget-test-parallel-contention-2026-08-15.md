# podman budget test is killed by parallel-phase contention, not by podman (754-3jht)

- Date: 2026-08-15
- Host: linux_mutable (coordinator)
- Class: optimization/ (test scheduling)
- Packet: 754-3jht (`podman-budget-test-contention`), filed in
  `plan/index.d/20260815t0545z-754-gate-skew-linux-mutable.yaml`

## What happened

`backend::tests::a_prompt_podman_still_succeeds_under_the_same_budget`
(`crates/tillandsias-podman/src/backend.rs:470`) runs a REAL `podman ps` under
the 30s operation budget. During `./build.sh --ci-full` run
`local-ci-20260815T051005Z` the call was killed at 30.001s — while the parallel
litmus-pre-build phase was building images and running containers against the
same podman store. Idle, the same call takes 0.018s (measured immediately
after).

This is the 638-ehzi class (parallel checks racing on shared host state —
there it was `$HOME` and a fixture dir; here it is the podman socket/store).
The test asserts a real-time property of a SHARED resource while a sibling
phase is deliberately saturating that resource, so it fails exactly on the
cycles that run the full gate — an intermittent failure with a schedule.

## Fix directions (packet exit criteria pick one)

1. Schedule: run `rust-tests` and `litmus-pre-build` in disjoint phases of
   `local-ci.sh` (serialize the two podman-heavy consumers), or
2. Isolate: point the budget test at an isolated podman state
   (`--root/--runroot` tmpdir) so sibling load cannot starve it, or
3. Scope: mark the budget assertion as measuring CONTENDED latency and raise
   the budget for the test lane only (weakest option — the 30s budget is a
   real runtime contract; prefer 1 or 2).

## Evidence

- `/tmp/test-check.log` (run 20260815T051005Z): `stderr: "podman container
  operation exceeded its 30s budget and was killed: podman ps"`,
  `duration: 30.001534079s`
- Idle: `time podman ps` → real 0m0.018s (this host, same tree, minutes later)
- Prior art: 638-ehzi (rust-tests vs tray-contract racing on `$HOME`)
