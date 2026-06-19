# Build/install smoke E2E findings - 2026-06-19

Status: failed-retryable
Owner: linux
Discovered by: /build-install-and-smoke-test-e2e (linux)

## Summary

Local-build E2E stopped at gate 1 (`./build.sh --ci-full --install`) before
the destructive Podman reset. The pre-build CI checks passed after formatting
the integrated Windows portable smoke test, but the musl install build failed
because Cargo built two native tray binaries with the same output filename:
`tillandsias-tray` from both `tillandsias-macos-tray` and
`tillandsias-windows-tray`.

No runtime substrate was destroyed in this run.

## Packet

- id: `local-smoke/linux-musl-tray-binary-name-collision`
- type: fix
- owner_host: linux
- status: ready
- capability_tags: [rust, build, release, testing]
- severity: high
- source: this smoke report
- next_action: >
    Make the Linux musl install build avoid cross-platform tray binary output
    collisions. Prefer narrowing the musl release build to the Linux
    `tillandsias` binary/package, or otherwise give macOS/Windows tray bins
    unique target names during cross-platform release builds. Then rerun
    `/build-install-and-smoke-test-e2e` from the build/install gate.
- evidence_required:
    - `./build.sh --ci-full --install` exits 0 on Linux
    - no Cargo `output filename collision` warning for `tillandsias-tray`
    - destructive Podman reset, fresh `tillandsias --init --debug`, and Linux
      forge lane are reached or produce their own later finding

## Evidence

- log_dir: `target/build-install-smoke-e2e/20260619T223047Z`
- tested commit at preflight: `5b3058c428e91c3c35d6e588e2277618f4f08d7d`
- preflight status: dirty by expected local smoke artifacts and the
  `cargo fmt --all` fix for
  `crates/tillandsias-windows-tray/tests/portable_smoke.rs`
- build/install exit: `build_install_exit=101`
- version bump attempted by build: `0.3.260619.3`
- key log lines:
  - `01-build-install.log:2147`: `warning: output filename collision at .../target/x86_64-unknown-linux-musl/release/tillandsias-tray`
  - `01-build-install.log:2152`: `warning: output filename collision at .../target/x86_64-unknown-linux-musl/release/tillandsias-tray.dwp`
  - `01-build-install.log:2162`: `error: failed to remove file .../target/x86_64-unknown-linux-musl/release/tillandsias-tray`
  - `01-build-install.log:2166`: `warning: build failed, waiting for other jobs to finish...`

## Notes

- The first build/install attempt in
  `target/build-install-smoke-e2e/20260619T222820Z` failed earlier with
  `build_install_exit=1` because the merged Windows portable smoke test needed
  `cargo fmt --all`. That formatting fix is included in this checkpoint.
- Because the failure occurred before the build/install success gate, the skill
  correctly did not run `podman system reset --force`.
