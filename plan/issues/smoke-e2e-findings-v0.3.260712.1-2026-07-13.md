# Smoke E2E Findings — release v0.3.260712.1 — 2026-07-13 (host yolanda, fresh Fedora Silverblue)

- skill: `/smoke-curl-install-and-test-e2e` (run inside an operator-directed `/meta-orchestration` full cycle)
- release_under_test: `v0.3.260712.1` (published 2026-07-12T19:28:18Z) — **first curl-install e2e of this release**
- host: yolanda (pristine Fedora Silverblue 44, linux_immutable), agent `linux-yolanda-fable5-20260713T1058Z`
- rate limit: `allow:full-meta` checked, `recorded:full-meta` stamped 2026-07-13T11:44Z

## PASS summary

**PASS — install clean, reset clean, cold init clean, forge full-cycle clean, 4b egress assertion clean.**

| Step | Result | Evidence |
|---|---|---|
| 1 install | PASS | `target/smoke-e2e/01-install.log` rc=0; `01-version.txt` = `Tillandsias v0.3.260712.1` == release tag |
| 2 reset | PASS | `target/smoke-e2e/02-reset.log` rc=0; ps/volumes/images all empty |
| 3 cold init | PASS | `target/smoke-e2e/03-init.log` `init exit: 0`; all 10 images built; vault bootstrap complete + healthy; no real error signatures |
| 4 forge run | PASS | `target/smoke-e2e/04-opencode.log` `opencode lane exit: 0`; OpenCode on `opencode/big-pickle`; full `/meta-orchestration` in-forge cycle |
| 4b egress | PASS | `target/smoke-e2e/04b-containers.txt`: `egress assertion: proxy alive alongside lane` — order-298 regression NOT present; the `no active lane containers; cleaning project + shared stack` trace appeared only as benign startup/teardown cleanup |
| in-forge drain | PASS | agent claimed order 313 (`claimed:inference-firstrun-install-resilience`), implemented, ran litmus, committed+pushed `4281ce4e` through the enclave mirror to origin/linux-next in one push; packet honestly left `in_progress` with residual exit criteria routed to capable hosts |

The in-forge agent's own cycle products (stream 1 of Step 5): commit `4281ce4e`
(inference Containerfile + entrypoint + order-313 ledger events). It filed no
separate issues; its residuals are recorded as events on order 313. No
`target/forge-diagnostics/` was produced.

## Findings (work packets)

### Work Packet: smoke-finding/forge-liveness-probe-exact-name-mismatch

- id: `smoke-finding/forge-liveness-probe-exact-name-mismatch`
- owner_host: linux
- capability_tags: [scripts, e2e, observability]
- status: ready
- discovered_by: `/smoke-curl-install-and-test-e2e` on release `v0.3.260712.1`
- evidence:
  - `scripts/forge-liveness-probe.sh:88` — `podman inspect --format ... "$FORGE_CONTAINER_PATTERN"` is an EXACT-name inspect, but the default "pattern" is `tillandsias-forge` while lane containers are named `tillandsias-<project>-forge` (this run: `tillandsias-tillandsias-forge`)
  - live repro 2026-07-13T11:50Z: probe printed `dead_crashed` while the lane was up and the agent was mid-implementation
- repro:
  - launch any forge lane; run `scripts/forge-liveness-probe.sh status` with defaults
- next_action: >
    Make the container probe a real pattern match (podman ps --filter
    name=... or a --format scan), or default the "pattern" to the actual
    tillandsias-<project>-forge shape; the smoke runbook tells operators to
    monitor with this probe, and with defaults it always reports a live
    forge as dead_crashed.
- events:
  - type: discovered
    ts: `2026-07-13T11:50:00Z`
    agent_id: `linux-yolanda-fable5-20260713T1058Z`
    host: linux_immutable

### Work Packet: smoke-finding/forge-liveness-probe-dead-air-without-heartbeat

- id: `smoke-finding/forge-liveness-probe-dead-air-without-heartbeat`
- owner_host: linux
- capability_tags: [scripts, e2e, observability]
- status: ready
- discovered_by: `/smoke-curl-install-and-test-e2e` on release `v0.3.260712.1`
- evidence:
  - with the exact container name supplied, the probe still classified an actively-working agent as `dead_air`: no `.forge-heartbeat` exists anywhere (order 265's heartbeat signal is unimplemented), so container-up + no-heartbeat + no-HEAD-change = dead_air and `wait` exits immediately
- repro:
  - `scripts/forge-liveness-probe.sh wait --container tillandsias-tillandsias-forge` during a live cycle — returns dead within seconds
- next_action: >
    Either land order 265's heartbeat emission (agent-side touch of
    .forge-heartbeat) so the probe has its signal, or make `wait` treat
    container-running-without-heartbeat as alive_quiet with a grace budget
    instead of dead_air; as shipped the probe cannot be used as the smoke
    runbook's wait gate.
- events:
  - type: discovered
    ts: `2026-07-13T11:52:00Z`
    agent_id: `linux-yolanda-fable5-20260713T1058Z`
    host: linux_immutable

### Work Packet: smoke-finding/proxy-teardown-sigsegv-139

- id: `smoke-finding/proxy-teardown-sigsegv-139`
- owner_host: linux
- capability_tags: [podman, proxy, runtime]
- status: ready
- discovered_by: `/smoke-curl-install-and-test-e2e` on release `v0.3.260712.1`
- evidence:
  - pre-reset `podman ps -a` (2026-07-13T10:44Z): `tillandsias-proxy ... Exited (139)` from the installer-init run torn down at 10:26Z
  - `podman logs tillandsias-proxy` from that run: squid received shutdown, wrote clean logs, printed `Squid Cache (Version 6.9): Exiting normally.` — yet the container exit code was 139 (SIGSEGV)
- repro:
  - run the stack, tear it down, inspect `podman ps -a` exit code for tillandsias-proxy
- next_action: >
    Find which process in the proxy container segfaults after squid's clean
    exit (suspects: security_file_certgen helper, PID-1 signal handling).
    Exit 139 is a smoke failure signature, so a benign-teardown 139 poisons
    that signal for every future run.
- events:
  - type: discovered
    ts: `2026-07-13T10:44:30Z`
    agent_id: `linux-yolanda-fable5-20260713T1058Z`
    host: linux_immutable

### Work Packet: smoke-finding/vault-approle-reenable-error-noise

- id: `smoke-finding/vault-approle-reenable-error-noise`
- owner_host: linux
- capability_tags: [vault, runtime, logging]
- status: ready
- discovered_by: `/smoke-curl-install-and-test-e2e` on release `v0.3.260712.1`
- evidence:
  - pre-reset `podman logs tillandsias-vault` (installer-init run, 2026-07-13T10:18Z): entrypoint reports `vault is fully configured` then vault core logs `[ERROR] ... error occurred during enable credential: path=approle/ error="path is already in use at approle/"`
  - also observed this run: `podman stop tillandsias-vault` needed SIGKILL after the 10s SIGTERM grace (slow/absent TERM handling in the entrypoint wrapper)
- repro:
  - run the stack twice against a persisted vault volume; watch vault logs on the second run
- next_action: >
    Make the entrypoint's ensure-approle step check-before-enable (or treat
    already-in-use as success) so healthy re-runs log no ERROR, and handle
    SIGTERM so the container stops inside the grace period.
- events:
  - type: discovered
    ts: `2026-07-13T10:44:30Z`
    agent_id: `linux-yolanda-fable5-20260713T1058Z`
    host: linux_immutable

### Work Packet: smoke-finding/stress-mock-timing-ratio-flaky

- id: `smoke-finding/stress-mock-timing-ratio-flaky`
- owner_host: macos
- capability_tags: [rust, tests, portability]
- status: ready
- discovered_by: order 285 verification during this cycle
- evidence:
  - `crates/tillandsias-headless/tests/stress_concurrent_operations.rs` `test_stress_container_scaling` asserts `time_ratio < count_ratio * 2.0` over pure-mock Mutex ops that finish in nanoseconds — scheduler noise dominates the ratios
  - order-285 empirical sweep (2026-07-13): the file has zero podman shell-outs, so the macOS cycle-7 reds on these tests were misattributed to podman gating in `plan/issues/headless-integration-tests-not-macos-gated-2026-07-10.md`
- repro:
  - loop `cargo test -p tillandsias-headless --test stress_concurrent_operations` on a loaded host; observe intermittent non-linear-scaling panics
- next_action: >
    Give the mock ops a deterministic floor or assert on counts instead of
    wall-clock ratios; macOS host to confirm whether its cycle-7 reds match
    this signature and update the order-285 trail.
- events:
  - type: discovered
    ts: `2026-07-13T11:15:00Z`
    agent_id: `linux-yolanda-fable5-20260713T1058Z`
    host: linux_immutable

### Work Packet: smoke-finding/installer-init-discarded-by-smoke-reset

- id: `smoke-finding/installer-init-discarded-by-smoke-reset`
- owner_host: linux
- capability_tags: [build-script, e2e, optimization]
- status: ready
- discovered_by: `/smoke-curl-install-and-test-e2e` on release `v0.3.260712.1`
- evidence:
  - `scripts/install.sh:245-246` unconditionally runs `"$INSTALL_PATH" --init --debug`
  - `target/smoke-e2e/01-install.log`: full image-build + vault provisioning during Step 1, all destroyed minutes later by Step 2's `podman system reset --force`
- repro:
  - time the smoke skill's Step 1; the installer's init duplicates the entire Step 3 build (~10 min + full image bandwidth per smoke run, wasted)
- next_action: >
    Add TILLANDSIAS_INSTALL_SKIP_INIT=1 (honored by install.sh) and use it
    in the smoke skill's Step 1; keep default installer behavior unchanged
    for real users.
- events:
  - type: discovered
    ts: `2026-07-13T11:23:00Z`
    agent_id: `linux-yolanda-fable5-20260713T1058Z`
    host: linux_immutable

## Minor observations (bundled; not packet-worthy alone)

- `--debug` init prints `[tillandsias] podman image failed: status=1 stderr=`
  for each absent-image existence probe on the cold path — reads like an
  error on a healthy first build; consider "image not present (will build)".
- `with-tillandsias-builder.sh` MARKER_FILE is written but never read (dead
  code; the live rustup probe decides) — clean up with the next wrapper touch.
- Order-129 evidence preserved: the installer-init run's proxy access log had
  exactly one denied CONNECT, `edge.openspec.dev:443` (TCP_DENIED) — an
  OpenSpec CLI phone-home from the forge lane; input for the order-129/130
  allowlist research.
- Harness self-finding (not a product defect): the orchestrating host agent's
  first Step-3 init attempt was killed by its own background-task machinery
  mid vault-build; recovery = setsid-detached relaunch, incremental build
  resumed cleanly (`03-init-attempt1-killed-by-harness.log` retained locally).

## Drain context (same cycle, already pushed)

Pre-e2e worker drain on this host: `79682b9f` (4 builder-wrapper
fresh-Silverblue fixes; order-239 criterion falsified+fixed), `10671807`
(clippy 1.97 drift + `rust-toolchain-unpinned-clippy-drift-2026-07-13.md`),
`d877e199` (order 285 done). In-forge drain: `4281ce4e` (order 313 slice 1).
