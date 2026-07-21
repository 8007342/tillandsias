# Flaky: spawn_terminal_and_reap_does_not_leave_zombies fails in full-suite runs (precondition sees another test's unreaped child)

- Date: 2026-07-20
- Class: test-hygiene (flaky test / cross-test leakage) — NOT a product bug
- Filed by: linux coordinator cycle (v0.4 stabilization, fresh-checkout invariant work)
- Spec: tray-ux (test lives in crates/tillandsias-headless/src/tray/mod.rs ~4064)

## Symptom (reproduced 2026-07-20 at c5708f79, pristine tree)

`cargo test -p tillandsias-headless --all-features` fails
`tray::tests::spawn_terminal_and_reap_does_not_leave_zombies` with
"test harness started with stray zombies" — in BOTH parallel and
`--test-threads=1` full-suite runs. The same test PASSES when run in
isolation (`cargo test -- spawn_terminal_and_reap`). 334/336 other tests pass.
Attribution run on pristine HEAD c5708f79 shows the identical failure, so this
pre-dates the 2026-07-20 mirror/checkout fixes.

## Root cause (leading hypothesis, confirmed shape)

The test PRECONDITION asserts the test process has zero zombie children by
scanning /proc PPid entries. Under a full-suite run, some EARLIER test in the
same binary spawns a child it never `wait()`s; the zombie persists on the
shared test process until exit, so this test's clean-slate precondition trips
on ANOTHER test's leak. Single-threaded failure rules out concurrent-sibling
racing; the leak is order-dependent, not parallelism-dependent.

## Why it matters

- A red full-suite signal on every linux dev host masks real regressions and
  trains agents to ignore failures (the exact "false signal" class the
  issue-filing mandate exists for).
- The leaked zombie itself indicates some test spawns without reaping — a
  real hygiene defect in whatever test leaks it.

## Smallest fix (exit_criteria)

1. Identify the leaking test: run the suite `--test-threads=1` with a
   process-table dump on precondition failure (or bisect test order) and name
   the test that leaves the unreaped child.
2. Fix that test to reap (or spawn via the same reaping helper under test).
3. Precondition hardening: the zombie test's clean-slate assert should REAP
   pre-existing zombies (waitpid WNOHANG loop) instead of failing on them —
   its contract is "spawn_terminal_and_reap leaves no NEW zombies", which the
   post-condition already measures.
- Exit: 3 consecutive full-suite runs (parallel + single-threaded) green on a
  quiet host.

## Non-goals

Do not delete or `#[ignore]` the test — the reap behavior it pins is real
(tray popup terminals must not accumulate zombies).
