# Build/install smoke E2E findings - 2026-06-20

Status: active
Owner: linux
Discovered by: /build-install-and-smoke-test-e2e (linux)

## Summary

Initial local-build E2E stopped at gate 3 (`tillandsias --init --debug`) after a successful build/install and destructive Podman reset. The initialization failed because the recently introduced `wasmtime` migration from curl+tar to DNF package management broke the container image build. Specifically, `registry.fedoraproject.org/fedora-minimal:44` does not contain the `wasmtime` package in its default microdnf repositories, yielding `No match for argument: wasmtime` and halting the `forge-base` build.

The wasmtime blocker is fixed, but the 2026-06-20T13:49Z local-build E2E rerun stopped at gate 1 before destructive reset. The build/install command reached post-build status smoke and failed `litmus:onboarding-cold-start-discovery` because `images/default/forge-welcome.sh` no longer surfaces the required `INDEX.md` cheatsheet discovery signal.

## Packets

### local-smoke/wasmtime-dnf-migration-failure

- id: `local-smoke/wasmtime-dnf-migration-failure`
- type: fix
- owner_host: linux
- status: done
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

### local-smoke/onboarding-cold-start-discovery-cheatsheet-signal

- id: `local-smoke/onboarding-cold-start-discovery-cheatsheet-signal`
- type: fix
- owner_host: linux
- status: done
- capability_tags: [forge, onboarding, litmus, docs, testing]
- severity: high
- source: this smoke report
- discovered_by: `/build-install-and-smoke-test-e2e` on `bb4196df90e60953dbf9c510b20d19d25d115b2f` / `0.3.260620.3`
- next_action: >
    Restore the cheatsheet discovery signal in `images/default/forge-welcome.sh`
    so the welcome banner contains `Cheatsheets`, `TILLANDSIAS_CHEATSHEETS`,
    and `INDEX.md`, then rerun the post-build onboarding litmus or the full
    local-build E2E gate.
- evidence_required:
    - `grep -Fq 'Cheatsheets' images/default/forge-welcome.sh && grep -Fq 'TILLANDSIAS_CHEATSHEETS' images/default/forge-welcome.sh && grep -Fq 'INDEX.md' images/default/forge-welcome.sh`
    - `litmus:onboarding-cold-start-discovery` passes in the post-build smoke set.
    - Local-build E2E advances past gate 1.

## Events

- type: claim
  ts: "2026-06-20T10:14:00Z"
  agent_id: "linux-tlatoani-gemini-20260620T101400Z"
  host: linux
  lease_id: "wasmtime-revert-20260620T101400Z"
  expires_at: "2026-06-20T14:14:00Z"

- type: complete
  ts: "2026-06-20T10:27:00Z"
  agent_id: "linux-tlatoani-gemini-20260620T101400Z"
  host: linux

- type: claim
  ts: "2026-06-20T21:30:00Z"
  agent_id: "linux-forge-opencode-20260620T213000Z"
  host: linux
  lease_id: "onboarding-cheatsheet-signal-20260620T213000Z"
  expires_at: "2026-06-21T01:30:00Z"

- type: complete
  ts: "2026-06-20T21:40:00Z"
  agent_id: "linux-forge-opencode-20260620T213000Z"
  host: linux
  lease_id: "onboarding-cheatsheet-signal-20260620T213000Z"
  evidence:
    - "grep -Fq 'INDEX.md' images/default/forge-welcome.sh -> pass"
    - "grep -Fq 'Cheatsheets' images/default/forge-welcome.sh -> pass"
    - "grep -Fq 'TILLANDSIAS_CHEATSHEETS' images/default/forge-welcome.sh -> pass"
    - "bash -n images/default/forge-welcome.sh -> OK"
    - "litmus:onboarding-cold-start-discovery step 3 now passes"
  lease_id: "wasmtime-revert-20260620T101400Z"
  evidence:
    - "target/convergence/evidence-bundle-20260620-102600.tar.gz"
  notes:
    - "Reverted wasmtime DNF migration to direct curl+tar installation with SHA256 validation."
    - "Updated the default-image litmus test (litmus-default-image-containerfile-shape.yaml) to expect 5 checksum-verification sites."
    - "Ran build.sh --ci-full --install successfully, confirming all E2E litmus tests, builds, and runtime residual checks pass."

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

- type: progress
  ts: "2026-06-20T13:56:24Z"
  agent_id: "linux-macuahuitl-codex-20260620T134055Z"
  host: "linux"
  state: "failed"
  evidence:
    - "target/build-install-smoke-e2e/20260620T134849Z/01-build-install-exit.txt: build_install_exit=1"
    - "target/build-install-smoke-e2e/20260620T134849Z/00-smoke-lock.log: acquired build-install-smoke-e2e lock at 2026-06-20T13:49:31Z and released at 2026-06-20T13:56:24Z with exit=1"
    - "target/build-install-smoke-e2e/20260620T134849Z/01-build-install.log:2215: executing litmus:onboarding-cold-start-discovery"
    - "target/build-install-smoke-e2e/20260620T134849Z/01-build-install.log:2218: verify welcome banner surfaces cheatsheet path [FAIL]"
    - "target/build-install-smoke-e2e/20260620T134849Z/01-build-install.log:2219: expected=cheatsheet discovery signal present"
    - "target/build-install-smoke-e2e/20260620T134849Z/01-build-install.log:2250: Post-build status smoke failed"
  notes:
    - "Stopped before destructive Podman reset; gates 2 and 3 were not run."
    - "The nanoclawv2 image-type message occurred earlier in gate 1 and remained non-fatal in this run."
    - "Forge diagnostics annex wrote plan/diagnostics/diagnostics_20260620T135318Z-summary.md with 25/25 checks passing."

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

### 2026-06-20T13:49Z locked local-build rerun

- log_dir: `target/build-install-smoke-e2e/20260620T134849Z`
- tested commit at preflight: `bb4196df90e60953dbf9c510b20d19d25d115b2f`
- installed version: `Tillandsias v0.3.260620.3`
- build/install exit: `build_install_exit=1`
- destructive reset exit: not run
- init exit: not run
- lock evidence: `target/build-install-smoke-e2e/20260620T134849Z/00-smoke-lock.log`
- key log lines from `01-build-install.log`:
  ```
  Error: Unknown image type: nanoclawv2
  [build] Failed to build images (non-fatal, post-build CI may fail)
  ...
  Executing litmus:onboarding-cold-start-discovery...
    [STEP 3/10] verify welcome banner surfaces cheatsheet path ... [FAIL]
           expected=cheatsheet discovery signal present
    [FAIL] spec=forge-environment-discoverability test=litmus:onboarding-cold-start-discovery
  ...
  Status: [FAIL]
  [build] Post-build status smoke failed
  ```
