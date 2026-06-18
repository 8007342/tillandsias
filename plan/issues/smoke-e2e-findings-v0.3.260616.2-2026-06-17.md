# Smoke E2E Findings - Release v0.3.260616.2 - 2026-06-17

Discovered by `/smoke-curl-install-and-test-e2e`.

Run summary: the published installer passed, the installed binary reported
`Tillandsias v0.3.260616.2`, and `podman system reset --force` left an empty
store. Fresh `tillandsias --debug --init` rebuilt all runtime images and
bootstrapped Vault successfully. The final OpenCode forge lane then failed
before starting the forge because the proxy spawn used
`--network tillandsias-enclave,bridge`, but the clean rootless Podman store had
no network named `bridge`.

## Result: HALTED at OpenCode forge launch

Init is healthy; the release-smoke failure is in the checkpointed
`enclave/network-level-egress-deny` implementation shipped in this release.
The dual-homing design assumes a Podman network named `bridge` exists. That
assumption is false on this clean Linux rootless runtime after
`podman system reset --force`.

### Evidence trail (`target/smoke-e2e/`)

- `01-version.txt` - installed binary reports `Tillandsias v0.3.260616.2`.
- `02-reset-verify.txt` - clean-room reset left no containers, volumes, or
  images.
- `03-init-exit.txt` - fresh init exited `0`.
- `03-init.log` - Vault reached `vault healthy (initialized=true sealed=false
  v=1.18.5)` and completed policy/AppRole bootstrap.
- `04-opencode.log:1` - OpenCode mode failed while starting `tillandsias-proxy`.
- `04-opencode.log:3` - proxy spawn command used
  `--network tillandsias-enclave,bridge`.
- `04-opencode.log:4` - Podman rejected the launch with
  `Error: unable to find network with name or ID bridge: network not found`.
- `04-opencode-exit.txt` - OpenCode smoke exited `1`.

### Work Packet: smoke-finding/rootless-bridge-network-missing

- id: `smoke-finding/rootless-bridge-network-missing`
- owner_host: linux
- capability_tags: [rust, podman, networking, enclave, release]
- status: runtime-accepted on local build v0.3.260617.2; ready for release
- discovered_by: `/smoke-curl-install-and-test-e2e` on release `v0.3.260616.2`
- related_packet: `enclave/network-level-egress-deny`
- severity: high - blocks the published Linux forge lane after a clean
  install/reset, so the network-level egress checkpoint cannot be accepted.
- evidence:
  - `target/smoke-e2e/04-opencode.log:3` - proxy launch uses
    `--network tillandsias-enclave,bridge`.
  - `target/smoke-e2e/04-opencode.log:4` - Podman reports
    `unable to find network with name or ID bridge`.
  - `target/smoke-e2e/03-init-exit.txt:1` - init itself was clean (`init exit: 0`),
    isolating the failure to the post-init forge/proxy launch path.
- repro:
  - `curl -fsSL https://github.com/8007342/tillandsias/releases/latest/download/install.sh | bash`
  - `podman system reset --force`
  - `tillandsias --debug --init`
  - `tillandsias . --opencode --prompt "Use the /forge-continuous-enhancement skill"`
- next_action: >
    Ship the managed `tillandsias-egress` fix in the next release. Keep the
    broader `enclave/network-level-egress-deny` direct-egress probe as its own
    follow-up packet.
- events:
  - type: discovered
    ts: "2026-06-17T00:34:41Z"
    agent_id: "linux-tlatoani-codex-20260617T003441Z"
    host: linux
    release: "v0.3.260616.2"
    evidence_refs:
      - "target/smoke-e2e/04-opencode.log"
      - "target/smoke-e2e/04-opencode-exit.txt"
  - type: reproduced
    ts: "2026-06-17T06:51:14Z"
    agent_id: "linux-tlatoani-claude-opus-4-8"
    host: linux
    release: "v0.3.260616.2"
    note: >
      Independently reproduced on a second clean-room run (curl-install +
      `podman system reset --force` + fresh `--debug --init` exit 0, Vault
      healthy/unsealed). Step 4 aborted identically. Confirmed the mechanism by
      inspecting the live Podman network state: `tillandsias-enclave` exists and
      is `internal=true` (created this release with `--internal`), and NO network
      named `bridge` exists — the rootless default is named `podman`
      (driver bridge, interface `podman0`). So the proxy's
      `--network tillandsias-enclave,bridge` second leg can never resolve after a
      reset. Suggest the egress leg target the existing default `podman` network
      (or an init-created managed egress network) rather than the literal name
      `bridge`.
    evidence_refs:
      - "target/smoke-e2e/04-opencode.log:3"
      - "target/smoke-e2e/04-opencode.log:4"
  - type: fix-implemented
    ts: "2026-06-17T19:55:00Z"
    agent_id: "linux-tlatoani-claude-opus-4-8-meta-orchestration"
    host: linux
    note: >
      Replaced the hard-coded `bridge` egress leg with a self-contained managed
      egress network `tillandsias-egress`. New `ensure_egress_network()` creates
      a normal (NAT-capable) bridge network with Podman-allocated IPAM, invoked
      from `ensure_enclave_network()` BEFORE its enclave-exists early return so
      the egress network is guaranteed on every bootstrap path. Both dual-homed
      launch sites (proxy main.rs:1697, git-service main.rs:1833) and both
      remote_projects git launches (run_git_image_shell, clone_project_from_github)
      now attach `tillandsias-enclave,tillandsias-egress` via the shared
      `ENCLAVE_EGRESS_NETS` const (literal in remote_projects). Added two
      drift-protection unit tests: `enclave_egress_dual_home_targets_managed_egress_network`
      (proxy+git dual-home to egress, never `bridge`) and
      `ensure_enclave_network_also_ensures_egress_network` (egress ensured before
      the early return). `cargo fmt --check`, `./build.sh --check`, and the full
      `tillandsias-headless` suite (84 passed / 1 ignored / 0 failed) are green.
      Acceptance (clean init → direct enclave egress denied + proxy egress +
      git-mirror push + forge lane start) pending the local-build e2e gate.
    evidence_refs:
      - "crates/tillandsias-headless/src/main.rs (EGRESS_NET, ENCLAVE_EGRESS_NETS, ensure_egress_network)"
      - "crates/tillandsias-headless/src/remote_projects.rs:291,523"
  - type: e2e-blocked
    ts: "2026-06-17T20:12:00Z"
    agent_id: "linux-tlatoani-claude-opus-4-8-meta-orchestration"
    host: linux
    note: >
      Ran the local-build e2e gate (`/build-install-and-smoke-test-e2e`) to get
      runtime acceptance (clean init → egress network created → forge lane starts
      past proxy spawn). The fix also (correctly) broke the drift-protection
      litmus `litmus:enclave-network-source-shape` STEP 5, which pinned the old
      `tillandsias-enclave,bridge` literal in container_profile.rs; updated that
      step to pin the new `ENCLAVE_EGRESS_NETS` const + `ensure_egress_network`
      (verified passing). HOWEVER `./build.sh --ci-full --install` HALTS before
      install on TWO PRE-EXISTING, unrelated cheatsheet CI failures from order-53
      (`cheatsheet-tiers` invalid tier `committed`, `litmus:cheatsheet-host-image-sync`
      tree drift). So runtime acceptance for this bridge fix is BLOCKED behind
      that gate. Filed `cheatsheet/reconcile-committed-tier`
      (plan/issues/cheatsheet-tier-committed-ci-blocker-2026-06-17.md). Code-level
      verification for THIS fix is complete (type-check + unit tests
      `enclave_egress_dual_home_targets_managed_egress_network`,
      `ensure_enclave_network_also_ensures_egress_network` + the updated litmus);
      runtime acceptance resumes once the cheatsheet packet lands and CI-full goes
      green.
    blocked_on: "cheatsheet/reconcile-committed-tier"
    smallest_next_action: >
      Land cheatsheet/reconcile-committed-tier (recommend Option A: retier to
      bundled + sync image tree), then rerun `/build-install-and-smoke-test-e2e`
      on linux to capture init/forge-lane acceptance for the bridge fix.
  - type: runtime-accepted
    ts: "2026-06-17T20:40:00Z"
    agent_id: "linux-tlatoani-codex-meta-orchestration"
    host: linux
    tested_commit: "6a44f4c618150cc30c9a1764e86455059c608764"
    installed_version: "Tillandsias v0.3.260617.2"
    evidence_dir: "target/build-install-smoke-e2e/20260617T201922Z"
    note: >
      Local build/install e2e passed after the cheatsheet CI blocker landed:
      `./build.sh --ci-full --install` exited 0, destructive
      `podman system reset --force` exited 0, clean `tillandsias --init
      --debug` exited 0, and the prompted OpenCode forge lane exited 0. Init
      created `tillandsias-egress` (`podman network create --driver bridge
      tillandsias-egress`) before the internal `tillandsias-enclave`, removing
      the clean-rootless dependency on nonexistent `bridge`. Forge diagnostics
      for the same installed build reported 25/25 checks passed and no failed
      container launch events.
    evidence_refs:
      - "target/build-install-smoke-e2e/20260617T201922Z/01-build-install-exit.txt"
      - "target/build-install-smoke-e2e/20260617T201922Z/02-reset-exit.txt"
      - "target/build-install-smoke-e2e/20260617T201922Z/03-init-exit.txt"
      - "target/build-install-smoke-e2e/20260617T201922Z/03-init.log:4006"
      - "target/build-install-smoke-e2e/20260617T201922Z/04-forge-exit.txt"
      - "plan/diagnostics/diagnostics_20260617T202340Z-summary.md"

## Second-run additional finding (2026-06-17T06:51Z)

### Work Packet: smoke-finding/proxy-spawn-error-misattributes-enclave-network

- id: `smoke-finding/proxy-spawn-error-misattributes-enclave-network`
- owner_host: linux
- capability_tags: [rust, podman, networking, enclave, diagnostics, testing]
- status: ready
- discovered_by: `/smoke-curl-install-and-test-e2e` on release `v0.3.260616.2`
- related_packet: `smoke-finding/rootless-bridge-network-missing`
- severity: low — does not change the blocker, but the error message points a
  debugger at the wrong subsystem.
- evidence:
  - `target/smoke-e2e/04-opencode.log:2` — the spawn fails with `typed-error: enclave network missing — ensure_enclave_network must run before this spawn; this is a Step 15 ordering regression (see plan/steps/15-tray-network-bootstrap.md)`
  - `target/smoke-e2e/04-opencode.log:4` — but the underlying `stderr` is `Error: unable to find network with name or ID bridge: network not found`, i.e. the MISSING network is `bridge`, not the enclave network.
  - live state confirms `tillandsias-enclave` exists and is healthy (`internal=true`); `podman network exists bridge` → false. The enclave network is NOT missing and this is NOT a Step-15 ordering problem.
- repro:
  - `tillandsias . --opencode --prompt "..."` on a clean `v0.3.260616.2` init; read line 2 vs line 4 of `04-opencode.log`.
- next_action: >
    Fix the typed-error mapping so a `podman run --network a,b` failure naming a
    specific missing network surfaces THAT network name, instead of
    unconditionally attributing any proxy-spawn network failure to "enclave
    network missing / ensure_enclave_network ordering / Step 15". The current
    message sends a debugger down the enclave-network-bootstrap path when the
    real fix (see `smoke-finding/rootless-bridge-network-missing`) is the
    nonexistent `bridge` egress leg. Gate the Step-15 attribution on actually
    checking `podman network exists tillandsias-enclave` first.
- events:
  - type: discovered
    ts: "2026-06-17T06:51:14Z"
    agent_id: "linux-tlatoani-claude-opus-4-8"
    host: linux
    release: "v0.3.260616.2"
    evidence_refs:
      - "target/smoke-e2e/04-opencode.log:2"
      - "target/smoke-e2e/04-opencode.log:4"

## Clean observations before the failure

- Published installer and checksum path succeeded.
- `podman system reset --force` was destructive and clean.
- Fresh init built all required images from an empty store and completed Vault
  bootstrap.
- The OpenCode prompt-consumption fix was not reached; failure occurred before
  OpenCode could start inside the forge container.
- Second run (2026-06-17T06:51Z, `linux-tlatoani-claude-opus-4-8`) confirms init
  now creates `tillandsias-enclave` with `--internal` (egress denied at the
  enclave leg) — the network-level-egress-deny checkpoint is partially in place;
  only the egress (`bridge`) leg resolution is broken.
