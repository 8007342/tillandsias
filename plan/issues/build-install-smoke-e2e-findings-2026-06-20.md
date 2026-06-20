# Build/install smoke E2E findings - 2026-06-20

Status: completed
Owner: linux
Discovered by: /build-install-and-smoke-test-e2e (linux)

## Summary

Initial local-build E2E stopped at gate 3 (`tillandsias --init --debug`) after a successful build/install and destructive Podman reset. The initialization failed because the recently introduced `wasmtime` migration from curl+tar to DNF package management broke the container image build. Specifically, `registry.fedoraproject.org/fedora-minimal:44` does not contain the `wasmtime` package in its default microdnf repositories, yielding `No match for argument: wasmtime` and halting the `forge-base` build.

## Packets

### local-smoke/wasmtime-dnf-migration-failure

- id: `local-smoke/wasmtime-dnf-migration-failure`
- type: fix
- owner_host: linux
- status: claimed
- capability_tags: [containerfiles, dnf, images, testing]
- severity: high
- source: this smoke report
- next_action: >
    Revert the wasmtime migration to DNF in `images/default/Containerfile.base`
    and restore the curl+tar extraction with SHA256 verification, or identify a
    reliable repository/COPR supplying wasmtime for Fedora minimal 44.
- lease_id: "wasmtime-revert-20260620T101400Z"
- agent_id: "linux-tlatoani-gemini-20260620T101400Z"
- expires_at: "2026-06-20T14:14:00Z"
- evidence_required:
    - `tillandsias --init --debug` completes successfully on a pristine store.
    - `podman run --rm localhost/tillandsias-forge-base:latest wasmtime --version` returns a valid version.
    - E2E gate 3 passes.

## Events

- type: claim
  ts: "2026-06-20T10:14:00Z"
  agent_id: "linux-tlatoani-gemini-20260620T101400Z"
  host: linux
  lease_id: "wasmtime-revert-20260620T101400Z"
  expires_at: "2026-06-20T14:14:00Z"

- type: progress
  ts: "2026-06-20T08:59:38Z"
  agent_id: "linux-tlatoani-gemini-20260620T085600Z"
  host: "linux"
  state: "failed"
  evidence:
    - "target/build-install-smoke-e2e/20260620T084136Z/01-build-install-exit.txt: build_install_exit=0"
    - "target/build-install-smoke-e2e/20260620T084136Z/02-reset-exit.txt: reset_exit=0"
    - "target/build-install-smoke-e2e/20260620T084136Z/03-init-exit.txt: init_exit=1"
  notes:
    - "The build-install and destructive reset gates succeeded. The init gate failed at build-forge-base."

## Evidence

### Failure log excerpt

- log_dir: `target/build-install-smoke-e2e/20260620T084136Z`
- tested commit at preflight: `36980e423573130e2f31f02b624f9cd8b896217f`
- installed version: `Tillandsias v0.3.260620.1`
- build/install exit: `build_install_exit=0`
- destructive reset exit: `reset_exit=0`
- init exit: `init_exit=1`
- key log lines from `03-init.log`:
  ```
  [tillandsias] build-forge-base: STEP 2/32: RUN microdnf install -y --setopt=install_weak_deps=0 ... wasmtime ...
  [tillandsias] build-forge-base: Repositories loaded.
  [tillandsias] build-forge-base: Failed to resolve the transaction:
  [tillandsias] build-forge-base: No match for argument: wasmtime
  [tillandsias] build-forge-base: You can try to add to command line:
  [tillandsias] build-forge-base:   --skip-unavailable to skip unavailable packages
  [tillandsias] build-forge-base: Error: building at STEP "RUN microdnf install -y ...": while running runtime: exit status 1
  FAILED forge-base: Build exited with status exit status: 1
  ...
  Error: Unknown image type: nanoclawv2
  init_exit=1
  ```

## Notes

- This failure confirms that `wasmtime` is not packaged in Fedora's standard minimal repositories for F44. The migration performed in commit `7293c902` must be reverted or fixed.
- The error `Error: Unknown image type: nanoclawv2` also occurred during the failure teardown/cleanup path because the recent `nanoclawv2` image configuration update (commit `58996d8f`) registered it as an image target, but the initialization fails when querying its status or building it (since it's a new image type that might not have a corresponding Containerfile or directory structure, or it was not fully implemented). This should be verified during the fix.
