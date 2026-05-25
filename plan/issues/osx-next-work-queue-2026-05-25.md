# osx-next work queue — 2026-05-25

trace: methodology/distributed-work.yaml, plan/steps/20-macos-tray-v0_0_1.md, plan/issues/tray-convergence-coordination.md, plan/issues/macos-recipe-convergence-response-2026-05-24.md, openspec/changes/control-wire-pty-attach/

Status: **OPEN** as of 2026-05-25T14:00Z. Authored by linux-host while
sibling laptops dormant.

## How to use this file

Per `methodology/distributed-work.yaml`, each item below is a work-item with
a stable ID. When the macOS host wakes:

1. `git fetch origin --prune && git checkout linux-next && git pull --ff-only`
2. Read this file top-to-bottom.
3. Pick the earliest item whose status is `pending`, whose `gated_on` field
   is empty (or every dependency is `done`), and whose `capability_tags`
   match your skills.
4. Append a `claim` event to the item with your `lease_id` and `agent_id`.
5. Commit + push to `linux-next`.
6. Switch to `osx-next` and execute. Report progress via further events
   in this file (commits pushed to `linux-next`).

Per the branch canon (`plan/issues/branch-and-coordination-canon-2026-05-25.md`):
*plan/* writes go to **linux-next**; *code* commits go to **osx-next**.

**Note on direct-commit-to-linux-next:** Earlier macOS work (`74f0ebd2`,
`70c7c2a0`, `3db11291`, `3cd90335`, etc.) landed directly on `linux-next`.
Per branch canon §4, plan/-class writes directly are CORRECT; code commits
SHOULD route through `osx-next` so the integration loop can run isolation
checks. Advisory only; both flows still work.

## Currently unblocked (pick these first)

### Item: m1/vmruntime-stop-and-wait-ready

- id: `m1/vmruntime-stop-and-wait-ready`
- type: feature
- owner_host: macos
- capability_tags: [rust, vfr, objc2-virtualization, vm-layer]
- status: pending
- depends_on: []
- blocks: []
- owned_files:
  - `crates/tillandsias-vm-layer/src/vz.rs` (body only)
- summary: >
    Per plan/steps/20-macos-tray-v0_0_1.md "loop iter 5", VmRuntime::start
    body has landed. Next iterations: implement VmRuntime::stop
    (`requestStop` then force-stop after `drain_timeout`) and
    VmRuntime::wait_ready (host-side polls
    `VZVirtioSocketDevice::connectToPort(42420)` with the existing
    250ms/500ms/1s/2s/4s backoff; success once the connection lands and
    the Hello/HelloAck handshake completes).
- estimated_effort: 1 day.
- evidence_on_done:
  - vz-spike refactored to drive VzRuntime::start + stop + wait_ready
  - End-to-end smoke: boot → handshake → graceful stop in ≤30s

### Item: m2/refactor-vz-spike-via-vmruntime

- id: `m2/refactor-vz-spike-via-vmruntime`
- type: feature
- owner_host: macos
- capability_tags: [rust, vfr, testing]
- status: pending
- depends_on: [m1/vmruntime-stop-and-wait-ready]
- owned_files:
  - `crates/tillandsias-vm-layer/examples/vz-spike.rs`
- summary: >
    Convert vz-spike from direct `boot::build_vm_configuration` invocations
    to driving `VzRuntime::start()` + `stop()` + `wait_ready()`. Acts as
    the regression smoke for the production code path. Per plan/steps/20
    Phase 1 list, this is the natural follow-on to m1.
- estimated_effort: 2–3 h.

### Item: m3/macos-scoped-clippy-cleanup

- id: `m3/macos-scoped-clippy-cleanup`
- type: housekeeping
- owner_host: macos
- capability_tags: [rust, clippy, hygiene]
- status: pending
- depends_on: []
- blocks: []
- owned_files:
  - `crates/tillandsias-vm-layer/src/vz.rs`
  - `crates/tillandsias-macos-tray/**`
- summary: >
    `cargo clippy -p tillandsias-vm-layer -p tillandsias-macos-tray -- -D
    warnings` on the macOS host. There's at least one pre-existing
    `manual_clamp` lint in `vz.rs:113` (`host_cores.min(4).max(1)` →
    `host_cores.clamp(1, 4)`). Fix in place; trivial.
- estimated_effort: 30 min.

## Gated on Linux deliverables (queued for after Linux lands)

### Item: m4/pty-attach-appkit-terminal

- id: `m4/pty-attach-appkit-terminal`
- type: feature
- owner_host: macos
- capability_tags: [appkit, objc2, pty, vsock, terminal-app]
- status: pending
- gated_on:
  - linux deliverable `l1/control-wire-pty-attach-tasks-1` (control-wire enum + constants)
  - linux deliverable `l3/in-vm-headless-pty-handler` (host-side library + in-VM handler)
- depends_on: [m1/vmruntime-stop-and-wait-ready]
- owned_files:
  - `crates/tillandsias-macos-tray/src/terminal_attach.rs`
  - `crates/tillandsias-macos-tray/src/status_item.rs` (menu wiring)
- summary: >
    Implement the macOS side of `control-wire-pty-attach` Task 3.2
    (Unix `nix::pty::openpty` + `tokio::process::Command`) and wire
    "Open Shell" + "GitHub login" menu items to `PtySession::open(...)`,
    then `NSWorkspace::open(Terminal.app, with: <master-fd-as-tty>)`.
    Per plan/steps/20 Phase 5 and the macOS-tray spec's "Open Terminal"
    UX requirement.
- estimated_effort: 1–2 days after Linux deliverables.

### Item: m5/vfr-image-via-ci-rootfs

- id: `m5/vfr-image-via-ci-rootfs`
- type: feature
- owner_host: macos
- capability_tags: [vfr, vm-layer, fetch, provisioning]
- status: pending
- gated_on:
  - linux deliverable `l2/recipe-shared-modules` (recipe parser + Manifest::load)
  - linux deliverable `l5/recipe-smoke-ci-publish` (CI publishes both `.tar` AND `.img` per arch per macOS preference)
- depends_on: [m1/vmruntime-stop-and-wait-ready]
- owned_files:
  - `crates/tillandsias-vm-layer/src/vz.rs` (provisioning slice)
  - `crates/tillandsias-vm-layer/src/materialize/macos.rs` (new — Linux-runnable per D6)
- summary: >
    Per D6 amendment + macOS recipe-convergence response (request:
    CI-fetch publishes BOTH `.tar` AND `.img` per arch — the .img is
    the raw EFI/ext4 image consumed directly by VFR; the .tar is the
    intermediate). Contribute `materialize::macos::tar_to_vfr_img`
    (Linux-runnable per D6 task 2b.2). Wire VzRuntime::provision to
    fetch-and-verify the CI-published .img by default; respect
    `--materialize-local` flag for the dev path.
- estimated_effort: 2 days after Linux deliverables.

### Item: m6/macos-installer-pkg-and-codesign

- id: `m6/macos-installer-pkg-and-codesign`
- type: feature
- owner_host: macos
- capability_tags: [macos-bundle, codesign, installer]
- status: pending
- gated_on:
  - m1 + m2 (functional VM)
- owned_files:
  - `scripts/build-macos-tray.sh`
  - `scripts/install-macos.sh`
  - `crates/tillandsias-macos-tray/assets/{Info.plist.template,Tillandsias.entitlements,icon.icns}`
- summary: >
    Per plan/steps/20 Phase 2: `.app` bundle + ad-hoc codesign +
    `install-macos.sh`. Could start before m4/m5 since it doesn't
    depend on PTY or recipe modules; the result will need re-signing
    once PTY/recipe land, but the bundle structure can be set up now.
- estimated_effort: 1–2 days.

### Item: m7/macos-ci-job-and-tarball

- id: `m7/macos-ci-job-and-tarball`
- type: feature
- owner_host: macos (Linux user can author the YAML)
- capability_tags: [ci, github-actions, macos-runner]
- status: pending
- gated_on: [m6/macos-installer-pkg-and-codesign]
- owned_files:
  - `.github/workflows/ci.yml`
  - `.github/workflows/release.yml`
- summary: >
    Per plan/steps/20 Phase 3: macOS CI job + first releasable
    `tillandsias-tray-<version>-macos-arm64.tar.gz`. Add additive
    macos-* jobs; do not touch Linux/Windows jobs.
- estimated_effort: 1 day.

## Linux deliverables macOS is waiting on (status mirrors)

| Linux item | Status | Blocks macOS item |
|---|---|---|
| `l1/control-wire-pty-attach-tasks-1` | in_progress (this session) | m4 |
| `l2/recipe-shared-modules` | pending | m5 |
| `l3/in-vm-headless-pty-handler` | pending (after l1) | m4 |
| `l4/replace-vsock-stub-handlers` | pending | (informational only for macOS) |
| `l5/recipe-smoke-ci-publish` | pending (gated on l2) | m5 |

## Events

<!-- Append events here when claiming/progressing items. Append-only. -->
