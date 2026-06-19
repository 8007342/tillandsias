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
- status: in-progress
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

## Events

- type: claim
  ts: "2026-06-19T23:25:53Z"
  agent_id: "linux-macuahuitl-codex-20260619T232553Z"
  host: "linux"
  lease_id: "lease-linux-musl-tray-collision-20260619T2325Z"
  expires_at: "2026-06-20T03:25:53Z"
  note: >
    Claiming the Linux musl tray binary-name collision blocker so the
    local-build E2E gate can resume from the build/install phase.
- type: progress
  ts: "2026-06-19T23:36:54Z"
  agent_id: "linux-macuahuitl-codex-20260619T232553Z"
  host: "linux"
  lease_id: "lease-linux-musl-tray-collision-20260619T2325Z"
  state: "progress"
  current_plan:
    - "Checkpoint the package-scoped musl build fix and regression litmus."
    - "Rerun `/build-install-and-smoke-test-e2e` for destructive reset/init/forge evidence."
  files_touched:
    - "build.sh"
    - "openspec/litmus-tests/litmus-build-ci-dispatch-shape.yaml"
    - "VERSION"
    - "docs/convergence/centicolon-dashboard.md"
    - "docs/convergence/centicolon-dashboard.json"
    - "plan/metrics-dashboard.md"
    - "plan/diagnostics/diagnostics_20260619T233230Z-summary.md"
  evidence:
    - "bash -n build.sh"
    - "./scripts/run-litmus-test.sh --spec dev-build --size instant -> printed PASS for 2/2 executed; runner exited 143 after process-group cleanup"
    - "cargo build --package tillandsias-headless --bin tillandsias --release --target x86_64-unknown-linux-musl --features tray --manifest-path Cargo.toml -> pass"
    - "./build.sh --ci-full --install -> pass; installed musl-static tillandsias 0.3.260619.4; post-build 6/6 and runtime 5/5 e2e litmus pass; evidence bundle target/convergence/evidence-bundle-20260619-233602.tar.gz"
  next_checkpoint: "Run the destructive local-build E2E skill from the reset/init/forge gate."
  lease_intent: "continue"

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
