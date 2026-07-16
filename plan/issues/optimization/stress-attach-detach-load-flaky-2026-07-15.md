# test_stress_concurrent_attach_detach is load-flaky on darwin (52/100 failures under full-workspace parallel test load)

- Date: 2026-07-15
- Class: optimization (test reliability; red gates on slower/loaded hosts)
- Filed by: macos-osx-next coordination cycle 2026-07-15T23:14Z
- Pickup: linux

## Observed

On linux-next @ 1380a4e1 merged into osx-next, `cargo test --workspace`
failed once: `tillandsias-headless/tests/stress_concurrent_operations.rs:188`
"Too many failures: 52 / 100" (test_stress_concurrent_attach_detach). The
same test passes 3/3 when run standalone and passed in a subsequent full
run — the failure correlates with full-workspace parallel test load on a
10-core machine also running a VM.

## Fix shape

Either bound the test's failure budget by observed scheduling jitter
(deadline-based instead of fixed 100-iteration count), serialize it
(`#[serial]` / a dedicated test binary with `--test-threads=1`), or gate the
strict threshold behind a CI env var. A stress test that fails under
load-you-didn't-create is measuring the host, not the code.
