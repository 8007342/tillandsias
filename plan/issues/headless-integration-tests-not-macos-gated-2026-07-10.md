# Headless podman-integration tests fail on macOS hosts without a podman machine (2026-07-10)

- class: enhancement (test-suite hermeticity / portability)
- found by: macOS overnight cycle 7/8 full-workspace `cargo test` sweep (the
  macOS host is the ONLY host that compiles+runs the macOS-specific code, and
  a full sweep is the trunk-health check no other CI can do)
- promoted: plan/index.yaml order 283 (linux-owned — tillandsias-headless
  integration tests)

## Symptom

`cargo test --workspace` on a bare macOS dev host (no `podman machine start`)
fails a class of `tillandsias-headless` integration tests that shell out to
`podman`. The podman CLI is present but has no reachable daemon, so it returns
a connection error ("Cannot connect to Podman … dial tcp 127.0.0.1:PORT
connect: connection refused") instead of the podman-semantic error the test
asserts on. Confirmed failing:

- `error_recovery::test_missing_image_error_handling` — FIXED this cycle (see
  below) as the reference pattern.
- `stress_concurrent_operations::test_stress_container_scaling`
- `stress_concurrent_operations::test_stress_concurrent_attach_detach`

`cargo test` stops at the first failing binary, so the following test
binaries were NOT reached and likely share the gap: `rapid_project_switch`,
`rapid_project_switch_v2`, `network_validation`, `e2e_user_flow`,
`signal_handling`, `cache_peer_routing`, `singleton_coexistence`.

## Why this matters

The macOS host is the only place the macOS tray + shared crates get compiled
and unit-tested. A wall of podman-integration failures on this host MASKS real
macOS regressions in the same sweep (this cycle's real find — the keyring
hermeticity bug, fixed separately — was nearly buried under them). The
integration tests are Linux/podman-scoped and should skip gracefully when no
podman daemon is reachable, exactly like they already skip when `podman` is
absent entirely (the `Err` arm).

## Reference fix applied this cycle

`error_recovery::test_missing_image_error_handling` now treats a
podman-unreachable stderr ("Cannot connect to Podman" / "connection refused" /
"unable to connect to Podman socket") as the same graceful-skip case as
`podman` being absent — it cannot exercise image semantics without a daemon.

## Proposed reduction (order 283)

Extract a shared test helper, e.g. `podman_daemon_reachable() -> bool` (run
`podman info` once; false on connect error), and gate every podman-integration
test in tillandsias-headless on it — skip-with-eprintln when unreachable,
mirroring the `ssh_keygen_available()` pattern in tillandsias-core's
gh_auth_deploy_key test. Then `cargo test --workspace` is green on a bare
macOS host and the sweep can catch real regressions. Verifiable: the named
tests skip (not fail) with no podman machine, and still assert fully when one
is running.
