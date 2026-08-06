# Linux Local-Build E2E Smoke Findings 2026-08-01

- **Host**: `linux_mutable` (`macuahuitl`)
- **Branch**: `linux-next`
- **Commit tested**: `c46502c8`
- **Discovered by**: `/build-install-and-smoke-test-e2e` (linux)
- **Evidence**: `target/build-install-smoke-e2e/20260801T062002Z/`
- **Verdict**: FAIL at gate 1; install, destructive reset, cold init, and forge
  launch were not reached.

## Gate Results

- Build and install: **FAIL** (`build_install_exit=1`).
- Destructive Podman reset: **NOT REACHED**, as required after a failed build.
- Cold `tillandsias --init --debug`: **NOT REACHED**.
- In-forge meta-orchestration: **NOT REACHED**.

## Finding 584-2qq2: Trace Regeneration Moved Behind CI Gates

`litmus:build-trace-index-dispatch-coverage` step 4 failed for all three
gate-bearing modes. The stubbed call order was `gate,` for `--ci-full
--install`, `--ci --install`, and `--release`; the pinned order-495 contract is
`traces,gate`. The focused quick litmus reproduces 2 passed / 1 failed.

Evidence: `01-build-install.log:1768-1778`.

## Finding 584-e8pe: Launch-Marker Test Still Races in the Full Tray Suite

The tray-feature run failed
`tests::shared_stack_launch_marker_lifecycle_and_own_exclusion` after 680
seconds with `dropped marker must stop blocking teardown`; 385 sibling tests
passed. The exact test passes immediately when rerun alone with `--features
tray`, confirming a suite-level race or shared-state contamination rather than
a deterministic unit failure. This recurs after the 2026-07-24 shared-flock
repair recorded in `plan/issues/smoke-e2e-findings-local-build-linux-2026-07-24.md`.

Evidence: `01-build-install.log:1552-1566`.

## Smallest Next Actions

- For 584-2qq2, inspect `build.sh` dispatch ordering and restore exactly one
  `generate-traces.sh` call before each CI gate; rerun the focused quick litmus.
- For 584-e8pe, run the tray-feature suite under repeated shuffled/concurrent
  execution while inventorying the marker directory and process-global test
  locks; make the fixture hermetic before retrying the full E2E gate.

## Resolution checkpoint — 2026-08-06

Order 584-e8pe now runs the launch-marker lifecycle assertion in an exact
self-reexecuted child with a private temporary `XDG_RUNTIME_DIR`. This removes
the host-global lock directory, unrelated suite forks, and process-global env
mutation from the fixture while preserving the immediate post-drop assertion.
The parent requires the child transcript to report one passed test, and
explicit TempDir removal proves no marker/lock state survives. Verification:

```text
cargo test -p tillandsias-headless --bin tillandsias --features tray \
  tests::shared_stack_launch_marker_lifecycle_and_own_exclusion -- --exact --nocapture
=> 1 passed, 0 failed, 389 filtered out

5 × cargo test -p tillandsias-headless --bin tillandsias --features tray
=> each: 388 passed, 0 failed, 2 ignored (18.90–19.19s)
```

Order 584-2qq2's original regeneration-before-CI behavior was already present
at the retry checkpoint. Its uncovered residual was stamp authority:
`./build.sh --check` could certify a tree without asking the non-mutating trace
freshness question. `_write_gate_stamp` now requires
`generate-traces.sh --check` and fails closed before writing when stale,
regardless of the writer-suppression override. The existing six-step
`litmus:build-trace-index-dispatch-coverage` now pins clean
`trace-check,stamp` and stale `trace-check`-only transcripts while preserving
the `traces,gate` order; all six steps pass.
