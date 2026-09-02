# `delegated_result_fake_podman_covers_fresh_status_and_exact_timeout_reap` fails only under the full parallel run

Classification: **research/**
Filed: 2026-09-02 · Host: lenovinha (linux_immutable, linux-next)
Found during: order 793-qr4t / 793-qc6q implementation

## What happens

`cargo test --release -p tillandsias-headless` fails one test:

```
test tests::delegated_result_fake_podman_covers_fresh_status_and_exact_timeout_reap ... FAILED
[forge-result] codex FAILED: exit 37 (transcript said: succeeded: looks successful)
panicked in the delegated-result assertion in crates/tillandsias-headless/src/main.rs
test result: FAILED. 462 passed; 1 failed; 1 ignored
```

Run alone it passes, every time:

```
cargo test --release -p tillandsias-headless delegated_result_fake_podman
test result: ok. 1 passed; 0 failed
```

## It is NOT caused by the work that found it

Verified by stashing the 793-qr4t/793-qc6q changes and running the full suite
on the clean tree at `9098a41fd`: the same test fails there, with the same
message. It is pre-existing, and this record exists so the next agent to see it
does not spend the cycle I nearly spent deciding whether they broke it.

## Why it is worth a record rather than a shrug

This is the 638-ehzi shape again — two tests racing on shared state, which that
order found by reading `target/convergence/check-logs.jsonl` after two cycles
of calling an intermittent failure "unexplained". An intermittent failure is a
defect with a schedule, not noise, and the cheapest moment to write down that
it is schedule-shaped is the moment someone observes both halves of the
contrast. I have observed both halves; I have not diagnosed the shared state.

Note that `./build.sh --check` is GREEN on this tree, so the gate does not run
this test in the configuration that fails it. That is the part worth someone's
attention: a test that fails only under the full parallel run is invisible to
the only trunk protection this project has.

## Smallest next action

Someone with the time to bisect: run the suite under `--test-threads=1` to
confirm it is contention rather than ordering, then find what
`delegated_result_fake_podman_*` shares with its neighbours — 638-ehzi's pair
raced on `$HOME` and a shared fixture directory, and the fake-podman seam here
sets a process-wide env var (`TILLANDSIAS_PODMAN_BIN`), which is exactly the
kind of state a parallel neighbour can move underneath it. The accel_probe
tests guard that same variable with a mutex (`podman_seam()`); this test may
not.
