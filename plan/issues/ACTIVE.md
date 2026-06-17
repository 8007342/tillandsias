# Active Plan Frontier

Last updated: 2026-06-17T20:40:00Z

This file is the first stop for agents inspecting `plan/issues/`. Historical
issue reports remain in this directory for evidence and auditability, but only
the items below are immediate work.

## Immediate

### nanoclawv2-orchestration

- status: ready
- owner_host: linux
- source: `plan/issues/nanoclawv2-orchestration.md`
- next_action: Draft the NanoClawV2 implementation task graph from the new
  spec, then wire the launcher leaf, broker surface, and smoke hooks.
- blocker: none
- evidence_required:
  - NanoClawV2 launch leaf exists and is branch-aware
  - only approved orchestration actions are reachable
  - smoke coverage proves launch and one approved action

### enclave/network-level-egress-deny

- status: ready
- owner_host: linux
- source: `plan/issues/enclave-egress-network-enforcement-gap-2026-06-16.md`
- next_action: Make `tillandsias-enclave` `--internal` so forge containers have
  no NAT egress; route allowlisted egress only through the dual-homed proxy.
- blocker: none
- latest_smoke: >
    Local build/install smoke on 2026-06-17 passed build/install, destructive
    reset, clean init, and the OpenCode forge lane on installed
    v0.3.260617.2. Init created managed `tillandsias-egress` before internal
    `tillandsias-enclave`, and forge diagnostics reported 25/25 checks passed
    with no failed container launches. The separate direct-egress-denied probe
    remains required for this packet.
- evidence_required:
  - direct (`--noproxy`) external curl from an enclave container FAILS on a clean init
  - allowlisted proxy egress + forge→proxy/inference/git-service still work
  - new litmus pins direct-egress-denied on the live enclave network
- note: corrects the cycle-1 rejection below — enclave egress is
  proxy-cooperative, not network-enforced (empirically: direct curl reaches the
  internet, HTTP 200). Verify-heavy (rebuild + reinit), so its own cycle.

### policy/no-python-runtime-scripts

- status: active
- owner_host: linux
- source: `plan/issues/no-python-runtime-policy-2026-06-16.md`
- next_action: Rewrite or retire the remaining Python-backed repository scripts
  in Rust, then make `scripts/check-no-python-scripts.sh` pass.
- blocker: existing cheatsheet/provenance maintenance scripts still execute
  Python; each needs a Rust replacement or explicit Tlatoani approval.
- evidence_required:
  - `scripts/check-no-python-scripts.sh` exits 0
  - no `*.py` executable scripts remain under `scripts/`
  - no harness, skill, litmus, or repeat path shells out to `python`/`python3`

## Triaged 2026-06-16 (no longer needs triage)

The 2026-06-16 critical/high forge proposals were triaged in
`coord/critical-forge-proposal-triage-20260616` (now done). Dispositions:

- `2026-06-16-git-pii-scrub.md` → **accepted**, promoted to the Immediate
  packet above (order 53).
- `2026-06-16-network-isolation-regression.md` → **REOPENED / reframed**
  (supersedes the original "rejected"). The rejection was based on the
  proxy-cooperative `external_curl` probe + `--network=none` litmus, neither of
  which tests direct egress. On re-test, a direct connection from an enclave
  container reaches the internet (HTTP 200): enclave egress is proxy-cooperative,
  not network-enforced. Reshaped as the `enclave/network-level-egress-deny`
  packet above (`enclave-egress-network-enforcement-gap-2026-06-16.md`).
- `2026-06-16-podman-in-forge.md` → **deferred** — rootless podman-in-forge is
  infeasible under `--cap-drop=ALL`/`--userns=keep-id`/`no-new-privileges`
  without weakening isolation; kept in the forge backlog.

## Manual Or Deferred

### m8/appkit-action-smoke-and-stub-polish

- status: unblocked (was blocked on step 49)
- owner_host: macos
- source: `plan/issues/osx-next-work-queue-2026-05-25.md`
- next_action: user-attended macOS interactive smoke — enclave now reaches Ready
- blocker: user-attended click smoke; not claimable by unattended agent

### macOS in-VM enclave (step 49)

- status: in_progress (49d remaining — user-attended)
- owner_host: macos
- source: `plan/steps/49-macos-in-vm-enclave.md`, `plan/index.yaml` order 55
- next_action: 49d — user-attended m8 interactive smoke (projects populate, github-login, attach shell)
- completed: 49a (design), 49b (cloud-init podman install, b7321f50), 49c (headless reached Ready ~32s), 49e (automated assertion script, diagnose-macos-enclave.sh)
- blocker: user-attention required — 49d cannot be validated unattended
- lease: `step49-macos-vm-enclave-20260616T231619Z` (expires 2026-06-17T03:16Z)
- evidence_required:
  - [x] cargo test passes
  - [x] build-osx-tray produces a valid bundle (E2E gate PASS)
  - [x] VM reaches Ready phase after provisioning (49c verified)
  - [ ] m8 interactive smoke passes (49d) — user-attended

## Achieved This Cycle (2026-06-16T23:16–23:35Z, macos)

- **Step 49a**: Design decision (Option 1 — cloud-init installs podman).
- **Step 49b**: Implemented — `dnf install -y podman` + `podman.socket` in vz.rs cloud-init (b7321f50). E2E gate PASS (build+install+provision+diagnose).
- **Step 49c**: Verified — headless reaches `phase=Ready podman_ready=true` ~32s post-boot (was ~84s `Failed`). Enclave provisioning resolved.
- **Step 49e**: Automated assertion — `scripts/diagnose-macos-enclave.sh`, polls tray log for Ready within 120s. Validated.
- **Step 49d**: Remaining — user-attended m8 interactive smoke.

## Recently Closed This Coordination Pass

- Completed `smoke-finding/rootless-bridge-network-missing`: local
  `/build-install-and-smoke-test-e2e` on 2026-06-17 tested commit `6a44f4c6`
  with installed `Tillandsias v0.3.260617.2`; build/install, destructive Podman
  reset, clean init, and prompted OpenCode forge lane all exited 0. Evidence:
  `target/build-install-smoke-e2e/20260617T201922Z`; init log shows
  `podman network create --driver bridge tillandsias-egress` followed by
  internal `tillandsias-enclave`, and forge diagnostics summary
  `plan/diagnostics/diagnostics_20260617T202340Z-summary.md` reports 25/25
  checks passed.
- Completed `cheatsheet/reconcile-committed-tier` (release-pipeline blocker) on
  2026-06-17T20:30Z via Option A: retiered order-53
  `cheatsheets/concurrent-git/commit-attribution.md` from invalid `tier:
  committed` to `bundled` (`bundled_into_image: true`), synced it into
  `images/default/cheatsheets/concurrent-git/`, and regenerated/synced both
  INDEX.md trees byte-identical (commit `0eef1443`). Acceptance:
  `check-cheatsheet-tiers.sh` exits 0 (210 validated); host-image-sync litmus
  critical_path passes; `./build.sh --ci-full` → ALL CHECKS PASSED (14/14).
  Unblocks the local-build e2e gate and `/merge-to-main-and-release` for all
  hosts.
- Completed `privacy/forge-git-identity-anonymization` / order 53: implementation
  commit `e31792e8` preserves real Git author identity and appends machine-parseable
  agent/model trailers. Acceptance fixture verified Codex and OpenCode trailers
  differ, including local-model params; shell syntax and `./build.sh --check`
  passed on 2026-06-16T23:29Z.
- Completed `coord/critical-forge-proposal-triage-20260616`: triaged all three
  2026-06-16 critical/high forge proposals (1 accepted → order 53, 1 rejected
  with evidence, 1 deferred with rootless-feasibility rationale). Decisions
  recorded in each proposal file and `plan/index.yaml`.
- Integrated `origin/osx-next` commits `21f62c3a` and `534e1aeb` into
  `linux-next`: macOS provision progress throttling plus clean smoke evidence.
- Closed stale `multihost-smoke-followups-20260615` rows in `plan/index.yaml`;
  macOS cold-boot suppression, local UX-parity reconciliation, substrate
  spec-amendment, and Windows sync/verify are all completed.
- Archived completed step deliverables from `plan/steps/` to
  `plan/archive/2026-06-16/steps/`.
- Completed `local-smoke/full-build-install-reset-init-forge`: local
  build/install, destructive Podman reset, pristine init, and prompted forge
  run all passed on 2026-06-16. Evidence:
  `target/build-install-smoke-e2e/20260616T072454Z`.
