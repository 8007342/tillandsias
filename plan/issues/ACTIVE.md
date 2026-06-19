# Active Plan Frontier

Last updated: 2026-06-19T23:36Z

This file is the first stop for agents inspecting `plan/issues/`. Historical
issue reports remain in this directory for evidence and auditability, but only
the items below are immediate work.

## Immediate

### local-smoke/linux-musl-tray-binary-name-collision

- status: in-progress
- owner_host: linux
- source: `plan/issues/build-install-smoke-e2e-findings-2026-06-19.md`
- severity: high — blocks local-build E2E and therefore release confidence for
  integrated `linux-next`
- next_action: Make the Linux musl install build avoid cross-platform tray
  binary output collisions, then rerun `/build-install-and-smoke-test-e2e` from
  the destructive reset/init/forge gate.
- blocker: none
- lease: `lease-linux-musl-tray-collision-20260619T2325Z` (expires
  2026-06-20T03:25:53Z)
- progress: >
    `./build.sh --ci-full --install` now exits 0 with a package-scoped Linux
    musl launcher build and no `tillandsias-tray` output collision. Full
    destructive local-build E2E rerun remains before closure.
- evidence_required:
  - `./build.sh --ci-full --install` exits 0 on Linux
  - no Cargo `output filename collision` warning for `tillandsias-tray`
  - destructive Podman reset, fresh `tillandsias --init --debug`, and Linux
    forge lane are reached or produce their own later finding

### release/version-tag-sequence-mismatch

- status: done
- owner_host: linux
- source: `plan/issues/release-version-tag-sequence-mismatch-2026-06-17.md`
- next_action: No worker action; the packet is closed. `/merge-to-main-and-release`
  can now preserve the current `VERSION` when it is already ahead of the
  tag-derived sequence for the UTC day.
- blocker: cleared by `764e8745` (`fix(release): preserve VERSION if ahead of
  tag sequence`).
- evidence_required:
  - release PR/tag/workflow uses a version that matches the accepted smoke
    evidence, or fresh smoke evidence is captured for the lower version
  - no `main` VERSION downgrade occurs during release

### nanoclawv2-orchestration

- status: stalled (lease expired 2026-06-18T02:07Z; reclaimable)
- owner_host: linux
- source: `plan/issues/nanoclawv2-orchestration.md`
- next_action: Draft the NanoClawV2 implementation task graph from the new
  spec, then wire the launcher leaf, broker surface, and smoke hooks.
- lease: `nanoclawv2-orchestration-202606172207` (EXPIRED at 2026-06-18T02:07Z)
- blocker: none
- evidence_required:
  - NanoClawV2 launch leaf exists and is branch-aware
  - only approved orchestration actions are reachable
  - smoke coverage proves launch and one approved action

### github-login/enclave-egress-regression

- status: ADDRESSED 2026-06-18 — root cause fixed under `bug/github-login-failure` (runtime validation pending)
- reopened_reason: >
    The Tlatoani reports `--github-login` still fails from both CLI and tray
    across the last several builds. The `d3f4e2f3` fix only renamed the network
    constant and was never live-validated (release smoke never ran
    `--github-login`). Investigation found a likely deeper root cause:
    `run_github_login` launches the helper on the enclave+egress networks but
    never calls `ensure_enclave_network`/`ensure_egress_network`, so the
    `podman run --network …` fails on a clean store. Tracked in the new packet
    `bug/github-login-failure` (see below).
- owner_host: linux
- source: `plan/issues/github-login-enclave-egress-regression-2026-06-17.md`
- prior_fix_commit: `d3f4e2f3` on `linux-next` (insufficient)
- fix_summary: >
    Changed the GitHub login helper container from single-homed `ENCLAVE_NET`
    to dual-homed `ENCLAVE_EGRESS_NETS` (tillandsias-enclave,tillandsias-egress).
    The gh helper now reaches api.github.com through the managed egress network,
    consistent with the proxy and git-service pattern. Added source-level
    regression test `github_login_helper_dual_homes_onto_managed_egress_network`.
- blocker: none
- evidence_required:
  - `tillandsias --debug --github-login` completes after a valid token on a
    clean post-init install (e2e gate, next release)
  - token is persisted into Vault for the forge/git-mirror path
  - direct external curl from an ordinary enclave-only container still fails
  - forge/proxy egress smoke remains green
- latest_evidence_note: >
    Local build/install smoke for `v0.3.260618.1` passed on 2026-06-18:
    `./build.sh --ci-full --install`, destructive Podman reset, clean
    `tillandsias --init --debug`, direct enclave-only HTTPS denial to
    `api.github.com`, and `tillandsias --status-check --debug` all passed.
    The actual `tillandsias --debug --github-login` token paste remains open:
    a noninteractive timed PTY attempt was aborted because it can echo the host
    `gh` token before the hidden container prompt. Next run must be
    operator-attended with a fresh/rotated token.

### bug/github-login-failure

- status: fix-landed (runtime validation pending) — 2026-06-18,
  commit `62e73c70` on `linux-next` (linux-tlatoani-opus-worker2-20260618T043347Z)
- owner_host: linux
- source: `plan/issues/github-login-failure-regression-2026-06-18.md`
- severity: high — blocks GitHub auth from both CLI and tray across recent builds
- fix_summary: >
    Added `ensure_enclave_network(debug)?;` at the top of run_github_login
    (after ensure_image_exists, before the helper podman run). This idempotently
    ensures BOTH tillandsias-enclave and tillandsias-egress exist before the
    dual-homed helper launch, matching every sibling enclave-bootstrap flow.
    Root cause confirmed: the helper launched on ENCLAVE_EGRESS_NETS but the
    networks were never ensured, so on a clean store `podman run --network
    tillandsias-enclave,tillandsias-egress …` failed. Added regression test
    `github_login_ensures_networks_before_helper_launch`. Build/clippy/fmt/
    ./build.sh --check all clean.
- runtime_validation_pending: >
    Operator/e2e gate still required — `tillandsias --debug --github-login` on a
    clean post-init store (no Error:/exit 1), token persisted to Vault, and the
    tray GitHub Login click. Not demonstrated in the worker context (no runtime
    podman login available). Keep acceptance_evidence open.
- next_action: Live-validate `tillandsias --debug --github-login` on a clean
  post-init install; confirm token persists to Vault and the tray path surfaces
  inner errors. If login still fails after the networks exist, audit rootless
  dual-home egress NAT (checklist items 4/6/7 in the source packet).
- supersedes: `github-login/enclave-egress-regression`
- blocker: none
- evidence_required:
  - `tillandsias --debug --github-login` completes on a clean store
  - tray GitHub-login flow succeeds (or surfaces the real error)

### bug/clone-tray-ux-not-refreshed

- status: fix-landed (runtime validation pending) — commit `8e9fa2d9` on
  linux-next
- owner_host: linux
- source: `plan/issues/clone-tray-ux-not-refreshed-2026-06-18.md`
- severity: medium — clone succeeds on disk but tray stayed on "Cloning…" and
  `~/src` never refreshed
- fix: `tray/mod.rs` `handle_launch_cloud_project` now, on clone success, sets a
  "✓ Cloned <name>" status, calls the new `TrayService::refresh_local_projects()`
  (re-scans `~/src` into `state.projects` + bumps revision — the missing
  post-startup writer), then `rebuild_after_state_change()`. Regression test
  `refresh_local_projects_picks_up_new_checkout` added.
- blocker: none
- evidence_required:
  - [open] runtime: actually clone a not-yet-on-disk repo from `☁️ Cloud >` on a
    live tray and observe the status clears AND `🏠 ~/src` lists the new checkout
    without a restart (needs an operator with a logged-in GitHub session)

### enclave/network-level-egress-deny

- status: done
- owner_host: linux
- source: `plan/issues/enclave-egress-network-enforcement-gap-2026-06-16.md`
- completed_evidence:
  - Implementation landed in `e11ff704` (adds `--internal` to enclave network,
    dual-homes git-service) and `4c6d11d8` (replaces nonexistent `bridge` egress
    leg with managed `tillandsias-egress`).
  - Litmus updated in `8d50c134`; existing `litmus:enclave-network-source-shape`
    pins the `--internal` const and dual-homed ENCLAVE_EGRESS_NETS.
  - Live verification on 2026-06-17: `podman network inspect tillandsias-enclave`
    confirms `Internal=true`; direct (`--noproxy`) curl returns HTTP=000 (FAILED).
  - Local-build e2e gate passed (build/install/reset/init/forge lane).

### policy/no-python-runtime-scripts

- status: in-progress (reclaimable for next slice)
- owner_host: linux
- source: `plan/issues/no-python-runtime-policy-2026-06-16.md`
- progress: `check-cheatsheet-tiers.sh` is Rust-backed via
  `tillandsias-policy check-cheatsheet-tiers`; `bind-provenance-local-paths.sh`,
  `regenerate-source-index.sh`, `refresh-cheatsheet-sources.sh` are tombstone-only;
  `check-convergence-velocity` retired. Consolidation DONE (2026-06-18): `sources`
  and `audit` validators are now re-homed into `tillandsias-policy` as the
  `check-cheatsheet-sources` and `audit-cheatsheet-sources` subcommands, both
  byte-for-byte parity-verified; the `tillandsias-cheatsheet-tools` crate has been
  deleted and removed from the workspace. A single policy crate now owns all
  cheatsheet validation (tiers + sources + audit).
  `distill-forge-diagnostics.sh` DONE (2026-06-18,
  `linux-tlatoani-opus-meta1-20260618T230426Z`): ported to a
  `tillandsias-policy distill-forge-diagnostics` subcommand and reduced to a
  thin build+exec wrapper; 45/45 target/forge-diagnostics logs verified
  byte-for-byte identical vs the former CPython extractor.
- next_action: Port the remaining 2 Python-runtime scripts
  (`fetch-cheatsheet-source.sh` — 6 python3 sites, large;
  `regenerate-cheatsheet-index.sh` — 1 python3 site), then make
  `scripts/check-no-python-scripts.sh` pass.
- blocker: those two scripts still execute Python; each needs a Rust
  replacement or explicit Tlatoani approval.
- evidence_required:
  - `scripts/check-no-python-scripts.sh` exits 0
  - no `*.py` executable scripts remain under `scripts/`
  - no harness, skill, litmus, or repeat path shells out to `python`/`python3`

### local-smoke/forge-pty-stopped-before-container-start

- status: done
- owner_host: linux
- source: `plan/issues/build-install-smoke-e2e-findings-2026-06-14.md`
- fix_commit: `d761b418` on `linux-next`
- fix_summary: >
    In `build_opencode_forge_args`, skip `--interactive --tty` when a
    prompt is provided via `--prompt`, because the entrypoint execs
    `opencode run --dangerously-skip-permissions` which is non-interactive.
    Podman no longer attempts to claim the terminal, avoiding the
    SIGTTIN/SIGTTOU / stopped T state in harness PTYs.
- blocker: cleared by `d761b418`.
- evidence_required:
  - final local-smoke forge lane exits 0 or emits actionable runtime logs
  - expected forge container is visible while the lane is active
  - no stopped `T` process state in the harness

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

## This Cycle (2026-06-18T20:50Z, linux)

- **Release-smoke priority**: fetched origin, fast-forwarded `linux-next`, and
  found GitHub latest release `v0.3.260618.2` newer than recorded curl-install
  smoke evidence.
- **Curl-install e2e**: installed the published Linux artifact, verified
  `Tillandsias v0.3.260618.2`, ran destructive `podman system reset --force`,
  confirmed empty container/volume/image inventories, and completed fresh
  `tillandsias --debug --init` with Vault healthy/unsealed.
- **Forge lane**: prompted `tillandsias . --opencode --prompt "Use the
  /forge-continuous-enhancement skill"` exited 0.
- **New ready findings**: filed
  `smoke-finding/forge-ripgrep-missing`,
  `smoke-finding/forge-marksman-missing`, and
  `smoke-finding/forge-nix-store-missing` in
  `plan/issues/smoke-e2e-findings-v0.3.260618.2-2026-06-18.md`.
  Detailed forge proposals were committed in `62964f02` and pushed to GitHub.
- **Sibling audit**: `origin/windows-next` (`e332afb6`) and `origin/osx-next`
  (`c7d32fb9`) remain ancestors of `linux-next`; no branch drift, deadlock,
  thrash, or wrong-direction progress detected.
- **Next useful Linux actions**: operator-attended
  `tillandsias --debug --github-login`, claim one new forge tool packet, or
  continue the expired no-Python cleanup lease.

## This Cycle (2026-06-18T16:00Z, linux)

- **Meta-orchestration audit**: fetched origin on a clean mutable-Linux
  `linux-next` checkout and confirmed local HEAD is up to date at `87d2201f`.
- **Sibling audit**: `origin/windows-next` (`e332afb6`) and `origin/osx-next`
  (`c7d32fb9`) are both ancestors of `origin/linux-next`; each has 0 commits
  ahead of linux-next, with no branch drift, deadlock, thrash, or wrong-direction
  progress detected.
- **Worker drain**: no implementation packet was claimed. `policy/no-python-runtime-scripts`
  remains actively leased until 2026-06-18T18:17Z; `nanoclawv2-orchestration`
  remains reclaimable (~4h) and `local-smoke/evidence-bundle-litmus-count-regression`
  is ready (~3h) but both exceed the meta-orchestration cycle budget.
- **Release/e2e freshness**: `gh release view` reports latest release
  `v0.3.260618.1`, published 2026-06-18T01:34:43Z from `b0dba63e`; existing
  release-smoke evidence for the same version passed at 2026-06-18T03:31:55Z.
- **E2E gates**: skipped. This cycle changed only plan ledger text and found no
  runtime, image, installer, or release artifact delta since the current smoke.
- **Next useful Linux actions**: operator-attended
  `tillandsias --debug --github-login`, continue no-Python cleanup after the
  active lease checkpoints/expires, or reclaim NanoClawV2 in a longer worker
  cycle.

## This Cycle (2026-06-18T14:19Z, linux)

- **Worker drain**: reclaimed expired
  `policy/no-python-runtime-scripts` lease as
  `no-python-slice-3-202606181417` and completed a narrow tombstone cleanup.
- **No-Python slice 3**: replaced
  `scripts/bind-provenance-local-paths.sh` with a compact tombstone-only
  wrapper. The wrapper still exits 0 with the replacement notice, and the
  unreachable Python legacy body no longer appears in
  `./scripts/check-no-python-scripts.sh`.
- **Verification**: `scripts/bind-provenance-local-paths.sh` PASS, `bash -n`
  PASS, `cargo test -p tillandsias-policy` PASS, `git diff --check` PASS.
  The no-Python checker still fails on the remaining active
  cheatsheet/provenance/diagnostics/source-index scripts.
- **E2E gates**: skipped. This cycle changed an already-retired maintenance
  wrapper and plan ledgers only; no runtime, image, installer, or release
  artifact behavior changed.

## This Cycle (2026-06-18T13:26Z, linux)

- **Merged osx-next plan-only cycle**: integrated `origin/osx-next` commit
  `c7d32fb9` into `linux-next`. It recorded a macOS no-eligible-work
  meta-orchestration cycle and touched only `plan/issues/osx-next-work-queue-2026-05-25.md`
  plus `plan/loop_status.md`.
- **Worker drain**: no small unclaimed Linux implementation packet was claimed.
  `policy/no-python-runtime-scripts` remains leased until 2026-06-18T14:01Z;
  `nanoclawv2-orchestration` remains reclaimable, but the next implementation
  slice is estimated at 4h and should be picked up by a dedicated worker cycle.
- **E2E gates**: skipped. No implementation/runtime/image/installer files
  changed, and release `v0.3.260618.1` already has current curl-install smoke
  evidence.
- **Next useful Linux evidence**: operator-attended
  `tillandsias --debug --github-login` on a clean post-init install with a
  fresh/rotated token.

## This Cycle (2026-06-18T13:31Z, linux)

- **Meta-orchestration audit**: `/meta-orchestration` was requested, but the
  local available skill is `coordinate-multihost-work`; used that workflow and
  recorded the mismatch in `plan/loop_status.md`.
- **Sibling audit**: `origin/windows-next` (`e332afb6`) and `origin/osx-next`
  (`c7d32fb9`) are both ancestors of `origin/linux-next` (`41a3fab1`), 0 drift.
  No deadlock, thrash, wrong-direction progress, or pending runtime-litmus
  marker was found.
- **No implementation work claimed**: `policy/no-python-runtime-scripts` remains
  leased until 2026-06-18T14:01Z; `nanoclawv2-orchestration` remains reclaimable
  for a longer worker cycle.
- **Next useful evidence unchanged**: operator-attended
  `tillandsias --debug --github-login`; Windows Smart App Control decision;
  macOS step 49d / m8 interactive smoke.

## Achieved This Cycle (2026-06-18T10:15Z, macos)

- **meta-orchestration sync**: Fast-forwarded `osx-next` to current shared
  `linux-next` state (`2e7a53b6`) so macOS has the latest plan/code frontier.
- **startup hygiene finding**: Tracked worktree was clean, but untracked
  artifacts remain: `build-osx-tray.sh`,
  `plan/issues/macos-windows-tray-ux-parity-audit-2026-06-13.md`,
  `research/`, and `src-tauri/`. They are not ignored and appear meaningful, so
  this cycle left them untouched and skipped new autonomous implementation work.
- **advance-work-from-plan drain**: No eligible autonomous macOS work was
  claimed. The active macOS item remains step 49d / m8 interactive smoke, which
  is user-attended and not suitable for unattended validation.
- **E2E gates**: Skipped; this checkpoint changed only plan ledger text and
  branch sync state.

## Previous macOS Cycle (2026-06-17T22:57Z, macos)

- **repeat**: Added macOS-compatible timeout fallback (`run_with_timeout`) so the
  repeat loop works on stock macOS without GNU coreutils. Commit `807f95f9`.
- **advance-work-from-plan drain**: No eligible autonomous macOS work found.
  All plan items are completed or blocked-on-user (step 49d = user-attended m8
  smoke). Ready macOS bugfix packets in m8 failures file remain but require
  a running VM or interactive session to verify.

## Previous Cycle (2026-06-16T23:16–23:35Z, macos)

- **Step 49a**: Design decision (Option 1 — cloud-init installs podman).
- **Step 49b**: Implemented — `dnf install -y podman` + `podman.socket` in vz.rs cloud-init (b7321f50). E2E gate PASS (build+install+provision+diagnose).
- **Step 49c**: Verified — headless reaches `phase=Ready podman_ready=true` ~32s post-boot (was ~84s `Failed`). Enclave provisioning resolved.
- **Step 49e**: Automated assertion — `scripts/diagnose-macos-enclave.sh`, polls tray log for Ready within 120s. Validated.
- **Step 49d**: Remaining — user-attended m8 interactive smoke.

## This Cycle (2026-06-18T04:19Z, linux)

- **Merged osx-next plan-ledger commit** `c8a6fef9` into `linux-next`:
  macOS meta-orchestration cycle entry (no eligible autonomous macOS work).
  Resolved conflict in `plan/loop_status.md` — kept linux-next's current 04:10Z
  content and updated for this cycle.
- **Reclaimable packets unchanged**: `nanoclawv2-orchestration` and
  `policy/no-python-runtime-scripts` remain available for Linux claim.
- **No e2e gate run**: no runtime crate/image delta since released v0.3.260618.1.

## This Cycle (2026-06-18T10:23Z, windows)

- **Recovered 13 stranded commits**: a prior Windows cycle committed the
  07:25Z meta-orchestration record, the forge PTY fix (`d761b418`), and the
  `v0.3.260618.1` plan/TRACES batch but never pushed. Pushed
  `7674f823..8ab39e97` to `origin/windows-next` (ff-safe).
- **Synced `linux-next`**: merged `origin/linux-next` (`2e7a53b6`, incl.
  `fix(policy): port cheatsheet tier check to Rust`) into `windows-next`;
  resolved `plan/loop_status.md` by taking the newer Linux coordinator content.
- **Added `repeat.ps1`**: committed the Windows launcher that locates bash and
  delegates to `./repeat` (parse-validated). Previously untracked local-only.
- **Worker drain**: No Windows-owned ready work in `plan/index.yaml`; all
  Windows-owned packets are `done`/`completed`. Yielded.
- **E2E gates**: BLOCKED. Smart App Control is enforcing on this host
  (`VerifiedAndReputablePolicyState=1`) and blocks execution of unsigned cargo
  build-script binaries (`os error 4551`), so the native local-build e2e cannot
  run. Curl-install e2e skipped (latest release `v0.3.260618.1` == latest
  tested). Production WSL2 substrate verified healthy via non-destructive probe
  (`wsl -l -v`: `tillandsias` registered, VERSION 2).
  Finding: `plan/issues/windows-smart-app-control-build-block-2026-06-18.md`.

## This Cycle (2026-06-18T07:25Z, windows)

- **Worker drain**: No Windows-owned ready work found in `plan/index.yaml`;
  yielded.
- **E2E gates**: Windows build/install, destructive WSL unregister, and cold
  re-provision PASS.
  Evidence: `plan/issues/build-install-smoke-e2e-findings-2026-06-18.md`.

## This Cycle (2026-06-18T05:38Z, linux)

- **Fixed stale no-Python litmus drift**:
  `litmus:observability-convergence-script-shape` no longer requires the
  retired `scripts/check-convergence-velocity.py`; it now pins the 5 active
  shell surfaces and the explicit Python-retired/no-op wrapper warning.
- **Local build smoke evidence**: `./scripts/run-litmus-test.sh --spec
  observability-convergence --phase pre-build` PASS (2/2), then
  `./build.sh --ci-full --install` PASS (pre-build 129/129, post-build 6/6,
  runtime residual 5/5), installing `Tillandsias v0.3.260618.1`.
- **Clean runtime evidence**: destructive `podman system reset --force` PASS,
  pristine `tillandsias --init --debug` PASS, direct enclave-only HTTPS to
  `api.github.com` denied, and `tillandsias --status-check --debug` PASS.
- **Blocked probes**: `tillandsias --debug --github-login` remains
  operator-attended because timed PTY token injection is unsafe; the forge
  continuous-enhancement lane entered stopped `T` state before container
  startup in this harness (`forge_exit=blocked-stopped-pty`).

## This Cycle (2026-06-18T09:08Z, linux)

- **Merged osx-next plan-ledger commit** `965fc1ae` into `linux-next`:
  macOS meta-orchestration cycle entry (no eligible autonomous macOS work,
  step 49d remains user-attended).
- **Resolved plan cache conflict** in `plan/loop_status.md` by keeping the
  latest Linux smoke/forge PTY evidence and adding the macOS no-work cycle as
  integrated sibling state.
- **Reclaimable packets unchanged**: `nanoclawv2-orchestration` and
  `policy/no-python-runtime-scripts` remain available for Linux claim.
- **No e2e gate run**: this was a plan-only coordination merge with no crate,
  script, image, or release artifact delta.

## This Cycle (2026-06-18T02:28Z, linux)

- **Completed `github-login/enclave-egress-regression`**: code fix in
  `d3f4e2f3` — changed `ENCLAVE_NET` → `ENCLAVE_EGRESS_NETS` for the
  GitHub login helper container. The gh helper now dual-homes onto the
  managed egress network (tillandsias-enclave,tillandsias-egress) so
  `gh auth login` can reach `api.github.com`. Added regression test
  `github_login_helper_dual_homes_onto_managed_egress_network`.
- **Expired leases**: `nanoclawv2-orchestration` (02:07Z) and
  `policy/no-python-runtime-scripts` (02:15Z) are now reclaimable.
- **No e2e gate run**: code fix targets the next release; published
  `v0.3.260618.1` still has the regression (as expected).

## Recently Closed This Coordination Pass

- **Completed `release/version-tag-sequence-mismatch`**: commit `764e8745`
  updated `/merge-to-main-and-release` so a current-day `VERSION` that is ahead
  of the tag-derived sequence is preserved instead of being downgraded.
  The packet header is now `done`; there are no remote `v0.3.260617.*` tags,
  no open `linux-next -> main` PR, and no in-flight `release.yml` run.
- **Completed `enclave/network-level-egress-deny`**: implementation was already
  landed in commits `e11ff704` and `4c6d11d8`. Verified live on 2026-06-17:
  `tillandsias-enclave` is `Internal=true`; direct egress from enclave
  container FAILS (HTTP=000). Litmus `litmus:enclave-network-source-shape`
  pins the implementation surfaces. Marked `done` in ACTIVE.md and issue file.
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
