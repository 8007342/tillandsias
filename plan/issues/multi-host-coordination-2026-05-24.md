# Multi-Host Coordination - 2026-05-24

## Status

Active. This issue is the repo-local coordination record for concurrent Linux,
Windows, and macOS host work.

## Context

Claudia aligned these remote branches to the Phase 6 Vault tip `ddf52dff`:

- `origin/linux-next`
- `origin/windows-next`
- `origin/osx-next`
- `origin/main`

The branches were pure ancestors of the shared tip at the time of alignment, so
the fast-forwards did not discard platform work. Future hosts may advance their
platform branch independently, so every session must re-check current remote
state.

## Branch Convention

- Linux host checkpoints to `linux-next`.
- Windows host checkpoints to `windows-next`.
- macOS host checkpoints to `osx-next`.
- Shared, stable, cross-cutting work lands on `main` or the declared shared
  integration source, then fast-forwards to platform branches only after an
  ancestry check.
- Platform-specific tray wrapper work stays on the owning platform branch until
  stable enough to merge back.
- Shared protocol and orchestration stay in `crates/tillandsias-host-shell`,
  `crates/tillandsias-core`, and `crates/tillandsias-headless`.

## Required Start-of-Session Checks

```bash
git fetch origin
git pull --ff-only
git ls-remote origin refs/heads/main refs/heads/linux-next refs/heads/windows-next refs/heads/osx-next
git status --short --branch
```

Record observed sibling heads in the active step or issue before editing shared
files.

## Fast-Forward Guard

Before fast-forwarding a remote platform branch from a shared source:

```bash
git merge-base --is-ancestor origin/<platform-branch> <source-ref>
```

If the ancestry check fails, stop. Another host has independent work. Create or
update a plan issue with the conflicting branch heads and coordinate explicitly
before pushing.

## Plan Ledger Rules

- Include `host_id`, `platform`, `branch`, `upstream_commit`, and
  `observed_sibling_heads` in cross-host handoffs.
- Update existing stable graph nodes instead of duplicating work by host.
- Treat `plan.yaml`, `plan/index.yaml`, `plan/steps`, and `plan/issues` as the
  durable ledger.
- Use `plan/localwork` only for disposable scratch.
- Never delete another host's note to resolve a conflict; tombstone, supersede,
  or merge by stable ID.

## Current Handoff

The methodology and plan have been updated to make the workflow durable:

- `methodology/multi-host-development.yaml`
- `methodology/between-commits-work-discipline.yaml`
- `methodology/agent-observability.yaml`
- `methodology/event/030-multi-host-branch-coordination.yaml`
- `plan/steps/20-recent-work-spec-doc-methodology-audit.md`

Next agents should adopt this as the first coordination step before resuming
platform implementation.

## Coordination Audit - 2026-05-25T17:10Z

host_id: linux-tlatoani-fedora · platform: linux · branch: linux-next

Observed remote heads at audit start:

- `main`: ddf52dff
- `linux-next`: 201c76ea
- `windows-next`: d3d4cede
- `osx-next`: 201c76ea

Ledger corrections made in this audit:

- `methodology/distributed-work.yaml` now defines explicit status transitions,
  stale/stalled handling, ping rules, prioritization, and completion hygiene.
- `plan/issues/windows-next-work-queue-2026-05-25.md` now marks w1, w2, and
  w3 as `done` in the item headers, matching their terminal events. At this
  audit point Windows had no cleanly unblocked tray item left; the 18:25Z
  audit below supersedes this after l3/l4 shipped.
- `plan/issues/osx-next-work-queue-2026-05-25.md` now marks m1, m2, and m3 as
  `done` in the item headers and mirrors m1b as the next `ready` macOS item.
  The 18:25Z audit below supersedes m1b to an active lease.
- `plan.yaml` and `plan/index.yaml` now describe step 21 as active/in-progress
  rather than ready-but-unclaimed.

Current cross-host gates:

- Linux l7 `§3-materializer-driver` is claimed by Linux and blocks Windows w5
  plus macOS m5.
- Linux l3 `in-vm-headless-pty-handler` shipped after this audit and no
  longer blocks Windows w4 or macOS m4; see 18:25Z below.
- Linux l4 `replace-vsock-stub-handlers` shipped after this audit and no
  longer blocks Windows w6 verification; see 18:25Z below.
- macOS-owned l5 `recipe-smoke-ci-publish` / CI-fetch work blocks the final
  recipe artifact path after l7 lands.
- macOS m1b `transport-macos-vsock-connector` was ready at this audit point;
  it is now in progress under lease `7c2a9f1eb083`.

Next audit action:

- If l7 has not produced a checkpoint by the next integration cycle, append a
  ping to `plan/issues/cross-host-blocker-roundup-2026-05-25.md` with the
  last known lease and the smallest reclaimable scope.

## Coordination Audit - 2026-05-25T18:25Z

host_id: linux-tlatoani-fedora · platform: linux · branch: linux-next

Observed remote heads via read-only remote query:

- `main`: ddf52dff
- `linux-next`: 8dc0d129
- `windows-next`: d3d4cede
- `osx-next`: 8f3db7f

Ledger corrections made in this audit:

- `plan/issues/windows-next-work-queue-2026-05-25.md` now mirrors Linux l3 and
  l4 as done; Windows w4 is active under the shared PtySession/ConPTY lease
  and w6 is ready for verification.
- `plan/issues/osx-next-work-queue-2026-05-25.md` now folds the m1b sub-task A
  terminal event into the item header as an active lease, marks macOS m4 ready
  for host-side PTY wiring, and marks m6 ready after m1+m2 completion.
- `plan/issues/cross-host-blocker-roundup-2026-05-25.md` now has a current
  blocker fold: l3/l4 resolved; l7 and macOS-owned l5 remain the recipe gates.
- `plan.yaml` and `plan/index.yaml` now describe step 21 with l3/l4 cleared
  instead of treating PTY/vsock as current blockers.

Current cross-host gates:

- Linux l7 `§3-materializer-driver` is still claimed by Linux and blocks
  Windows w5 plus macOS m5. Ping/reclaim decision is due around
  2026-05-25T19:00Z if no checkpoint appears.
- macOS-owned l5 `recipe-smoke-ci-publish` / CI-fetch work blocks the final
  recipe artifact path after l7 lands.
- macOS m1b remains in progress under lease `7c2a9f1eb083`; it no longer
  blocks m4 coding, but it does block end-to-end wait_ready/HelloAck smoke.

## Coordination Audit - 2026-05-26T00:18Z

host_id: linux-tlatoani-fedora · platform: linux · branch: linux-next

Observed remote heads after fetch/pull:

- `main`: ddf52dff
- `linux-next`: fd7d904e
- `windows-next`: ae8789ff
- `osx-next`: effbfbf4

Ledger corrections made in this audit:

- `plan/issues/osx-next-work-queue-2026-05-25.md` now folds the terminal
  m1b/m6 events into headers: m1b is done and released, m6 is done, m7 is ready,
  and m4 remains ready for the user-facing `terminal_attach` half after the
  Unix PTY foundation.
- `plan/issues/windows-next-work-queue-2026-05-25.md` now records that
  `origin/windows-next` is ahead of `linux-next` with w4 launch/menu commits
  at `ae8789ff` (w4 code delta through `93427ed9`). The latest Windows merge
  absorbed macOS PTY foundation work but not this coordination commit.
- `plan/issues/cross-host-blocker-roundup-2026-05-25.md` now pings stale Linux
  l7 materializer lease `linux-l-mat-2026-05-25T15Z`.

Current cross-host gates:

- Windows w4 remains active; its next needed coordination action is Linux
  integration-loop merge/test of `origin/windows-next` against the current
  `linux-next` tip.
- Linux l7 `§3-materializer-driver` is stale and blocks Windows w5, macOS m5,
  and live-VM verification for w6 / PTY attach smoke. Renew, release, or reclaim
  the smallest materializer API/cache/export slice after a fresh read.
- macOS m4 and m7 are both ready; macOS m5 remains blocked on l7 plus
  macOS-owned l5 recipe-publish/CI-fetch.

## Coordination Audit - 2026-05-26T01:13Z

host_id: linux-tlatoani-fedora · platform: linux · branch: linux-next

Observed remote heads after fetch/pull:

- `main`: ddf52dff
- `linux-next`: cabf9c9f
- `windows-next`: cb39cb7c
- `osx-next`: 4aa42c6a

Ledger corrections made in this audit:

- Folded terminal events into `plan/issues/windows-next-work-queue-2026-05-25.md`:
  Windows w4 is done/integrated at `95e4714`, l7 is done at `9dca2c47`, and
  `origin/windows-next` is now ahead only with the w5 `tar_to_wsl_import`
  converter slice at `cb39cb7c`.
- Folded terminal events into `plan/issues/osx-next-work-queue-2026-05-25.md`:
  macOS m7 is done at `c9341fa6`, m4 remains ready for action-host wiring, and
  m5 is unblocked from the Linux materializer API but still waits on
  recipe-publish/CI-fetch plus the macOS converter.
- Updated `plan.yaml`, `plan/index.yaml`, and the work-shaping note so fresh
  agents no longer treat l7 as stale or w4/m7 as ready work.

Current cross-host gates:

- `origin/windows-next` commit `cb39cb7c` needs Linux integration-loop
  merge/test before its w5 converter code is consumed from `linux-next`.
- macOS-owned recipe-publish/CI-fetch and `tar_to_vfr_img` work gate the
  default non-Linux rootfs path and the final m5/w5 provisioning smoke.
- Linux materializer follow-up should fix the reported `cache.rs:134`
  `collapsible_if` and record strict clippy evidence.
- Recurring rustfmt version skew between Windows and macOS-owned files needs a
  workspace pin or agreed Linux fmt pass.

## Coordination Audit - 2026-05-26T02:04Z

host_id: linux-tlatoani-fedora · platform: linux · branch: linux-next

Observed remote heads after fetch/pull:

- `main`: ddf52dff
- `linux-next`: fad97244
- `windows-next`: d937e761
- `osx-next`: fad97244

Ledger corrections made in this audit:

- Folded integration-loop cycle `b3ae21a`: Windows §3.7.2
  `tar_to_wsl_import` and w6 diagnostics are now integrated/tested into
  `linux-next`; the stale `cb39cb7c needs merge/test` blocker is closed.
- Folded macOS recipe events through `55ff55c6`/`fad97244`: recipe scaffold,
  `tar_to_vfr_img`, and `recipe-publish.yml` scaffolding landed.
- Corrected the live provisioning status in the Windows/macOS queues: the
  workflow scaffold exists, but production artifact generation is still blocked
  because `BuildahExec` returns its scaffold error, manifest SHAs are
  `pending-ci`, and runtime provisioning paths have not flipped to the
  recipe-published artifacts.
- Added/surfaced `l8/buildah-exec-recipe-publish-smoke` in the blocker roundup
  as the Linux-owned packet that unblocks first real rootfs artifacts.

Current cross-host gates:

- Linux l8 should implement or narrow production `BuildahExec`, run
  recipe-publish/buildah evidence, fix the materialize cache clippy warning,
  and produce first artifact SHAs for `images/vm/manifest.toml`.
- Windows should sync `origin/windows-next` `d937e761` with latest
  `linux-next`, or the integration loop should merge/test it and record
  conflicts. This is diagnostic-only and should not block l8.
- Windows w5 and macOS m5 runtime provisioning flips remain blocked on l8
  artifact SHAs; m4 action-host wiring remains ready for macOS.

## Coordination Audit - 2026-05-26T07:54Z

host_id: linux-tlatoani-fedora · platform: linux · branch: linux-next

Observed remote heads after fetch/pull:

- `main`: ddf52dff
- `linux-next`: 89de6219
- `windows-next`: 35cbdb16
- `osx-next`: 89de6219

Ledger corrections made in this audit:

- Folded integration-loop cycle `a1e1df1`: Windows' shared forge-container
  `launch_spec` / `intent_for_action` amendment is integrated and tested, so the
  old "Windows volunteered launch_spec" watch is closed.
- Folded macOS events through `9578691d`: m4 has the pty-vsock bridge and
  `VzRuntime::open_vsock_stream` foundation, m8 produced autonomous no-VM
  build/process evidence, and m8 now waits on user-attended button-click smoke.
- Added macOS m9 as the ready no-VM adapter-wiring packet so macOS has useful
  work while l9/m5 gate live runtime provisioning.
- Updated `plan.yaml`, `plan/index.yaml`, the per-host queues, blocker roundup,
  integration ledger, and `plan/loop_status.md` to current heads.

Current cross-host gates:

- Linux l9 `recipe-artifact-url-and-publish-smoke` is still the highest-impact
  ready packet. It gates artifact URLs, first green recipe-publish artifacts,
  manifest SHA pins, Windows w5, macOS m5, and live PTY proof.
- Windows w7 remains ready: branch-sync `windows-next` to `linux-next`
  `89de6219` and run diagnostics against the l9 artifact gate.
- macOS m9 remains ready: wire no-VM-testable PTY attach adapters without
  claiming live E2E. macOS m4 live attach remains blocked on m5, and m8's
  residual acceptance is user-attended interactive smoke.

## Coordination Audit - 2026-05-26T09:47Z

host_id: linux-tlatoani-fedora · platform: linux · branch: linux-next

Observed remote heads after fetch/pull:

- `main`: ddf52dff
- `linux-next`: e60afe93
- `windows-next`: 83e2cd51
- `osx-next`: dddd3eb8

Ledger corrections made in this audit:

- Folded l9 dynamic-loop slices through `74b1d78d`: artifact URL template,
  `Manifest::artifact_url`, `materialize-cli --publish-tag`, and the w5/m5
  consumer contract are done.
- Folded Windows w5 `RemoteArtifact` resolver: `83e2cd51` has been
  merged/tested into `linux-next` at `150d8a14`, so there is no unmerged
  Windows delta.
- Folded macOS m4 terminal events through `41ea02e1`: Open Shell and GitHub
  Login live PTY-over-vsock attach paths are structurally complete. The m9
  no-VM adapter packet is superseded and should not be re-claimed.
- Updated `plan.yaml`, `plan/index.yaml`, the per-host queues, blocker roundup,
  and `plan/loop_status.md` to current heads.

Current cross-host gates:

- Linux l9 is narrowed to first green `recipe-publish` artifacts plus real
  manifest SHA pins. The URL contract is done; `"pending-ci"` SHA pins should
  be treated as recoverable by consumers.
- Windows w7 remains ready: branch-sync `windows-next` to `linux-next`
  `e60afe93` and run diagnostics against the remaining SHA-pin gate.
- macOS m5 remains blocked on SHA pins before live provisioning; macOS live PTY
  proof remains blocked on m5, not on another m4/m9 implementation packet.
- m8's residual acceptance remains user-attended interactive smoke.

## Coordination Audit - 2026-05-26T11:47Z

host_id: linux-tlatoani-fedora · platform: linux · branch: linux-next

Observed remote heads after rebase:

- `main`: ddf52dff
- `linux-next`: 1d8217d3
- `windows-next`: a675e814
- `osx-next`: bdb7f9cb

Ledger corrections made in this audit:

- Folded Step 15 dynamic-loop slices through `14a8bd77`: OpenCode,
  observatorium, and tray Forge launch paths now start router before project
  containers, and the new tray-network-bootstrap litmus asserts the ordering.
  Step 15 is marked complete; Step 16 observatorium readiness is ready.
- Folded macOS m5 terminal evidence from `origin/osx-next`: `ec76e63a`
  implements `VzRuntime::fetch_recipe_artifact` against the l9 artifact URL
  contract, and `f8a3ec07` recorded the status packet. The integration loop
  merged/tested both into `linux-next` during the 11:43Z cycle.
- Checked GitHub Actions for l9: `recipe-publish.yml` is not registered because
  it is absent from default branch `main`; `gh run list --workflow
  recipe-publish.yml` returns 404 and there are no `linux-next` runs.

Current cross-host gates:

- l9 is now blocked first on workflow registration/release-path diagnosis,
  then on first green recipe-publish artifacts and manifest SHA pins.
- Windows w7 remains ready: branch-sync `windows-next` to `linux-next`
  `1d8217d3` and run diagnostics against the workflow/SHA-pin gate.
- macOS m5 has useful fetch code integrated; the next macOS packet is wiring
  that primitive into `startVm:` without claiming live E2E until SHA pins.
- Step 16 is the next Linux dynamic-loop packet: observatorium readiness should
  prove the real page and surface logs/inspect data on failure.

## Coordination Audit - 2026-05-26T13:39Z

host_id: linux-tlatoani-fedora · platform: linux · branch: linux-next

Observed remote heads after fetch/pull:

- `main`: ddf52dff
- `linux-next`: 72aa7917
- `windows-next`: 7e95c7e2
- `osx-next`: bdb7f9cb

Ledger corrections made in this audit:

- Folded Step 16 slice 1 into the plan graph: observatorium readiness now polls
  the real HTTPS page and attaches container log tail on failure
  (`3d75eeef`), so Step 16 is in progress rather than merely ready.
- Folded the pty_handler AsyncFd rewrite (`65980b02`): the echo-pump test is
  no longer ignored; the remaining pty_handler follow-up is the SIGTERM-HUP
  cancellation corner.
- Refreshed Windows and macOS queue branch-sync targets to current
  `linux-next` `72aa7917`. No unmerged sibling code delta exists.

Current cross-host gates:

- l9 remains blocked first on workflow registration/release-path diagnosis,
  then on first green recipe-publish artifacts and manifest SHA pins.
- Windows w7 remains ready: branch-sync `windows-next` to `72aa7917` and run
  diagnostics against the workflow/SHA-pin gate.
- macOS m5 should wire the integrated fetch primitive into `startVm:` while
  preserving the recoverable `"pending-ci"` state; live E2E waits on real
  artifacts.
- Linux can continue Step 16 OpenCode-web readiness parity or close the final
  pty_handler ignored test.

## Coordination Audit - 2026-05-26T15:29Z

host_id: linux-tlatoani-fedora · platform: linux · branch: linux-next

Observed remote heads after fetch/pull:

- `main`: ddf52dff
- `linux-next`: aa8fc2b9
- `windows-next`: 7e95c7e2
- `osx-next`: bdb7f9cb

Ledger corrections made in this audit:

- Folded the pty_handler pump-cancel slice (`617a04b3` / plan checkpoint
  `aa8fc2b9`): host-initiated close now wakes the pump task through an explicit
  oneshot instead of relying on a kernel HUP readiness edge.
- Reconciled Step 15 against the latest dynamic-loop intent. Router ordering
  remains complete and covered by `litmus-tray-network-bootstrap`, but Step 15
  has one reopened UX residual: collapse exit-125 project-container cascades
  into a single actionable diagnostic.
- Refreshed Windows and macOS queue branch-sync targets to current
  `linux-next` `aa8fc2b9`. No unmerged sibling code delta exists.

Current cross-host gates:

- l9 remains blocked first on workflow registration/release-path diagnosis,
  then on first green recipe-publish artifacts and manifest SHA pins.
- Windows w7 remains ready: branch-sync `windows-next` to `aa8fc2b9` and run
  diagnostics against the workflow/SHA-pin gate.
- macOS m5 should wire the integrated fetch primitive into `startVm:` while
  preserving the recoverable `"pending-ci"` state; live E2E waits on real
  artifacts.
- Linux should close the Step 15 exit-125 cascade UX residual, then continue
  Step 16 OpenCode-web readiness parity.

## Coordination Audit - 2026-05-27T06:57Z

host_id: linux-tlatoani-fedora · platform: linux · branch: linux-next

Observed remote heads after fetch/pull:

- `main`: f9c465b3
- `linux-next`: a5f915e4
- `windows-next`: e0405f2f
- `osx-next`: deba10d8

Ledger corrections made in this audit:

- Folded terminal events from `plan/issues/tray-convergence-coordination.md`
  and `origin/windows-next`: F1 is fixed and republished in the rootfs,
  Windows F2 is no longer blocked, Hello/HelloAck is proven over HvSocket, and
  `e0405f2f` flips the Windows tray to Ready on handshake success.
- Marked `w8/hvsocket-control-wire-ready` done in the Windows queue and added
  `w9/control-wire-session-menu-routing` as the next Windows packet.
- Refreshed macOS queue status to the post-F1 manifest SHA
  `6859a7bc...9730bee` and the fresh app tarball
  `86374049...c87c18e`; macOS remains blocked only on user-attended m8 smoke.

Current cross-host gates:

- Integration loop should merge/test `origin/windows-next` through `e0405f2f`
  into `linux-next`, preserving the newer `13cf3af0` manifest repin if the
  Windows branch presents its older manifest block.
- macOS m8 is user-attended and not parallelizable.
- Release cleanup remains useful but non-blocking: land durable
  `release.yml` headless auto-publish on `main` and add
  `Manifest::release_tag()` so both trays can drop hardcoded recipe tags.

## Coordination Audit - 2026-05-27T08:50Z

host_id: linux-tlatoani-fedora · platform: linux · branch: linux-next

Observed remote heads after fetch/pull:

- `main`: f9c465b3
- `linux-next`: 46ef33b1
- `windows-next`: 5188dce6
- `osx-next`: deba10d8

Ledger corrections made in this audit:

- Folded new Windows w9 transport evidence from `origin/windows-next`:
  `8b785ced` proves VmStatus request/reply over HvSocket, `791c0187` gates
  provisioning on VM phase `Ready`, and `5188dce6` proves
  PtyOpen/PtyData/PtyClose over HvSocket for the Open Shell mechanism.
- Updated the Windows queue: w9 is `in_progress` with transport primitives
  proven, not done. Remaining Windows work is menu/session UX wiring from
  `launch_spec`/PtyOpen to ConPTY or `wt.exe`, plus GitHub Login and agent
  attach over the live transport.
- Advanced the integration-loop watch from `e0405f2f` to `5188dce6`.

Current cross-host gates:

- Integration loop should merge/test `origin/windows-next` through `5188dce6`
  into `linux-next`, preserving the newer `13cf3af0` manifest repin and newer
  `linux-next` plan entries if the Windows branch presents older blocks.
- Windows w9 UX/session wiring remains the next Windows-owned packet.
- macOS m8 is user-attended and not parallelizable.
- Release cleanup remains useful but non-blocking: land durable
  `release.yml` headless auto-publish on `main` and add
  `Manifest::release_tag()` so both trays can drop hardcoded recipe tags.

## Coordination Audit - 2026-05-27T10:43Z

host_id: linux-tlatoani-fedora · platform: linux · branch: linux-next

Observed remote heads after fetch/pull:

- `main`: f9c465b3
- `linux-next`: 732603b1
- `windows-next`: c997fc43
- `osx-next`: deba10d8

Ledger corrections made in this audit:

- Folded new Windows w9 evidence from `origin/windows-next`: `fc7d0b74`
  proves bidirectional PTY stdin/stdout, `531bcce4` holds the WSL VM/control
  wire warm, `bc23a529` drains the VM on Quit, and `c997fc43` launches the
  resolved forge argv in Windows Terminal / `wsl.exe`.
- Updated the Windows queue: w9 remains `in_progress`, but the remaining work
  is now integration-loop merge/test plus terminal-click smoke/status, not the
  old transport primitive or ConPTY bridge wording.
- Advanced the integration-loop watch from `5188dce6` to `c997fc43`.

Current cross-host gates:

- Integration loop should merge/test `origin/windows-next` through `c997fc43`
  into `linux-next`, preserving the newer `13cf3af0` manifest repin and newer
  `linux-next` plan entries if the Windows branch presents older blocks.
- Windows should append post-merge smoke/status for Open Shell, Attach,
  Maintain, and GitHub Login native-terminal launches, or patch any missing
  action found by that smoke.
- macOS m8 is user-attended and not parallelizable.
- Release cleanup remains useful but non-blocking: land durable
  `release.yml` headless auto-publish on `main` and add
  `Manifest::release_tag()` so both trays can drop hardcoded recipe tags.

## Coordination Audit - 2026-05-27T12:35Z

host_id: linux-tlatoani-fedora · platform: linux · branch: linux-next

Observed remote heads after fetch/pull:

- `main`: f9c465b3
- `linux-next`: 3370f04e
- `windows-next`: 29fe3807
- `osx-next`: deba10d8

Ledger corrections made in this audit:

- Folded new Windows w9 evidence from `origin/windows-next`: `8e84df7d`
  proves Open Shell terminal-click smoke on real hardware, `0626a318` adds
  file-based tray logging and working Open Log, `41c32174` syncs the tracing
  lockfile entries, and `29fe3807` refreshes the Windows thin-tray next-action
  cache to the current scope.
- Updated the Windows queue: w9 remains `in_progress`, but Open Shell
  terminal-click smoke is now resolved. Remaining Windows work is
  integration-loop merge/test, forge-container Open Shell E2E against a live
  provisioned VM, Retry wiring, and optional wire EnumerateLocalProjects.
- Advanced the integration-loop watch from `c997fc43` to `29fe3807`.

Current cross-host gates:

- Integration loop should merge/test `origin/windows-next` through `29fe3807`
  into `linux-next`, preserving the newer `13cf3af0` manifest repin and newer
  `linux-next` plan entries if the Windows branch presents older blocks.
- Windows should continue w9 with forge-container Open Shell E2E and Retry
  wiring after merge/test, using w7 diagnostics only if branch/manifest state is
  stale.
- macOS m8 is user-attended and not parallelizable.
- Release cleanup remains useful but non-blocking: land durable
  `release.yml` headless auto-publish on `main` and add
  `Manifest::release_tag()` so both trays can drop hardcoded recipe tags.

## Coordination Audit - 2026-05-27T14:29Z

host_id: linux-tlatoani-fedora · platform: linux · branch: linux-next

Observed remote heads after fetch/pull:

- `main`: f9c465b3
- `linux-next`: 91061b61
- `windows-next`: c0a9558b
- `osx-next`: deba10d8

Ledger corrections made in this audit:

- Folded new Windows w9 evidence from `origin/windows-next`: `f4c3d70f`
  wires Retry to re-trigger guarded provisioning after failure, and
  `c0a9558b` proves the forge-container Open Shell argv through `wsl.exe` into
  a running `tillandsias-<name>-forge` container.
- Updated the Windows queue: w9 remains `in_progress`, but Retry and both Open
  Shell launch legs are now resolved. Remaining Windows work is
  integration-loop merge/test, optional full live-provision dress rehearsal,
  and optional wire EnumerateLocalProjects.
- Advanced the integration-loop watch from `29fe3807` to `c0a9558b`.

Current cross-host gates:

- Integration loop should merge/test `origin/windows-next` through `c0a9558b`
  into `linux-next`, preserving the newer `13cf3af0` manifest repin and newer
  `linux-next` plan entries if the Windows branch presents older blocks.
- Windows should use w7 diagnostics only if branch/manifest state is stale;
  otherwise remaining Windows work is optional verification/polish.
- macOS m8 is user-attended and not parallelizable.
- Release cleanup remains useful but non-blocking: land durable
  `release.yml` headless auto-publish on `main` and add
  `Manifest::release_tag()` so both trays can drop hardcoded recipe tags.
