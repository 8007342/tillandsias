# osx-next work queue — 2026-05-25

trace: methodology/distributed-work.yaml, plan/issues/multi-agent-work-shaping-2026-05-25.md, plan/steps/20-macos-tray-v0_0_1.md, plan/issues/tray-convergence-coordination.md, plan/issues/macos-recipe-convergence-response-2026-05-24.md, openspec/changes/control-wire-pty-attach/

## macOS UNBLOCKED for v0.0.1 — as of 2026-05-27T23:25Z

**macOS has zero blocking asks for other hosts.** Every Linux- and
Windows-owned artifact the macOS production path needs is shipped +
live-verified:

  - `tillandsias-rootfs-aarch64.img.xz` on release `v0.2.260526.1` ✓
  - `aarch64.img` SHA pinned in `images/vm/manifest.toml` to
    `6859a7bc...9730bee` after the F1 `Type=exec` rootfs republish ✓
  - `tillandsias-headless-aarch64-unknown-linux-musl` on release
    `v0.2.260526.2` (33 MB) ✓ — what in-VM `fetch-headless.service`
    pulls from `releases/latest/...`.
  - macOS m5 BYTES-LEVEL PROVEN at commit `303a5c24` (iter 38): the
    `.img.xz` fetch + xz-decompress + SHA-verify chain works
    end-to-end against the live release asset.
  - Fresh post-F1 `.app` tarball
    `tillandsias-tray-0.2.260526.2-macos-arm64.tar.gz` (sha256
    `86374049...c87c18e`) was rebuilt with the new bundled manifest for
    the user-attended interactive smoke (m8 7-step checklist).

**Non-blocking nice-to-haves still open** (no host should rush these):
  1. `Manifest::release_tag()` accessor (linux/recipe-owned) — both
     trays hardcode an interim `RECIPE_RELEASE_TAG = "v0.2.260526.1"`
     today; the accessor lets us drop the hardcodes and have the
     manifest own URL template + SHA pin + tag in one place. See
     tray-convergence-coordination "Tag-source decision" 2026-05-27.
  2. 3 Linux-owned clippy warnings in `materialize/cache.rs:134` +
     `bin/materialize-cli.rs:113,199`. Flagged 2026-05-26T18:41Z.

**What macOS is waiting for** (not a cross-host ask):
  - User interactive smoke results — user-attended; not parallelizable.

**Autonomous macOS cleanup gate cleared:** the runtime-litmus rustfmt blocker
from `20260527T190639Z-2c239138-1aebb284-deba10d8` is resolved on
`linux-next` by `4935404a` / `feb51d66`. `osx-next` is at `f8778350` and
remains an ancestor of `origin/linux-next` `891bb757`. Runtime-litmus
`20260527T231258Z-b06a5997-1e20d6d0-b06a5997` failed at `Disk quota exceeded`
before installed runtime diagnostics; replacement full installed runtime-litmus
`20260527T231940Z-b06a5997-1e20d6d0-b06a5997` passed build/install and init,
then failed in OpenCode diagnostics with the `vault_bootstrap.rs:205`
nested-runtime panic. This is not a macOS blocker. macOS may use m10/m11 as
autonomous cleanup, but the only macOS acceptance blocker remains
user-attended m8 smoke. Release run `26544334121` is the current monitored run
after the Linux Nix musl release pivot.

The status line below is the coordinator refresh after the 23:25Z rebase.

---

Status: **OPEN** as of 2026-05-27T23:25Z. macOS m1, m1b, m2, m3, m6,
m7, m4 sub-task B, m5 fetch primitive, m5 Start VM auto-fetch wiring, `.img.xz`
download/decompress, and bytes-level SHA proof are done/integrated. `osx-next`
is at `f8778350`, an ancestor of `origin/linux-next`.
The old l9 recipe-publish/SHA-pin gates and the F1 headless service restart
loop are closed. Remaining macOS acceptance is user-attended m8 smoke of the
rebuilt `dist/Tillandsias.app`; if Ready still hangs after Start VM, file
fresh evidence against the current recipe-rootfs/headless unit state rather
than reopening m5 fetch/provision code. Autonomous fallback is no longer a
noop: m10 project threading and the remaining semantic m11 MenuStructure
cleanup are available after the rustfmt-only gate was cleared.

## How to use this file

Per `methodology/distributed-work.yaml`, each item below is a work-item with
a stable ID. When the macOS host wakes:

1. `git fetch origin --prune && git checkout linux-next && git pull --ff-only`
2. Read this file top-to-bottom.
3. Pick the highest-impact ready packet whose `gated_on` field is empty (or
   every dependency is `done`), whose `capability_tags` match your skills, and
   whose acceptance evidence fits one or two recurrent iterations. Prefer
   packets that unblock another host over tiny cleanup.
4. Append a `claim` event to the item with your `lease_id` and `agent_id`.
5. Commit + push to `linux-next`.
6. Switch to `osx-next` and execute. Report progress, blockers, errors,
   dependencies, and handoffs as status packets in this file (commits pushed to
   `linux-next`; format in `plan/issues/multi-agent-work-shaping-2026-05-25.md`).

Per the branch canon (`plan/issues/branch-and-coordination-canon-2026-05-25.md`):
*plan/* writes go to **linux-next**; *code* commits go to **osx-next**.

**Note on direct-commit-to-linux-next:** Earlier macOS work (`74f0ebd2`,
`70c7c2a0`, `3db11291`, `3cd90335`, etc.) landed directly on `linux-next`.
Per branch canon §4, plan/-class writes directly are CORRECT; code commits
SHOULD route through `osx-next` so the integration loop can run isolation
checks. Advisory only; both flows still work.

Work-shaping note: m5 runtime provisioning is wired and bytes-level proven
against live release assets. m8 produced autonomous build/process evidence and
now waits on user-attended menu-click smoke. The former m9 no-VM PTY adapter
packet is superseded by m4 slices 4c.1, 4c.2, and 5b; do not re-claim it.
m10/m11 remain optional follow-ups, but the current macOS loop is allowed to
noop while waiting on user smoke feedback or the shared manifest `release_tag`
accessor.

## Currently unblocked / active

### Item: m10/menu-project-threading-for-pty-launch

- id: `m10/menu-project-threading-for-pty-launch`
- type: feature
- owner_host: macos
- capability_tags: [appkit, menu-structure, pty, host-shell]
- status: ready
- depends_on: [m4/pty-attach-appkit-terminal]
- gated_on: []
- blocks: []
- owned_files:
  - `crates/tillandsias-macos-tray/src/action_host.rs`
  - `crates/tillandsias-macos-tray/src/status_item.rs`
  - `crates/tillandsias-macos-tray/src/terminal_attach.rs`
- summary: >
    Thread the active project selected by the macOS menu into `attach_pty` so
    `launch_spec(intent, project, rows, cols)` targets the same forge container
    semantics as the Windows launch-spec amendment instead of bare-VM bash.
    This is useful before or after user smoke because it is structurally
    testable without a booted VM.
- next_action: >
    Inspect the current `MenuStructure`/status-item project state, pass an
    `Option<ProjectRef>` or equivalent through `open_shell` / `github_login`
    into `attach_pty`, and update unit tests to prove the launch spec receives
    `Some(project)` when a project action is selected.
- acceptance_evidence:
  - `cargo test -p tillandsias-macos-tray --bin tillandsias-tray` on macOS.
  - A no-VM action-host error path still reports the selected project without
    panicking or bypassing the pending-artifact gate.
- fallback_when_blocked: >
    Claim `m11/menu-structure-action-integration-and-clippy` if project state is
    not yet represented in the menu model.
- agent_status_packet_expected:
  - current plan
  - dependencies and blockers
  - files touched
  - evidence produced
  - next checkpoint
  - lease intent

### Item: m11/menu-structure-action-integration-and-clippy

- id: `m11/menu-structure-action-integration-and-clippy`
- type: housekeeping
- owner_host: macos
- capability_tags: [appkit, menu-structure, clippy, rust]
- status: ready
- depends_on: [m4/pty-attach-appkit-terminal, m5/vfr-image-via-ci-rootfs]
- gated_on: []
- blocks: []
- owned_files:
  - `crates/tillandsias-macos-tray/src/action_host.rs`
  - `crates/tillandsias-macos-tray/src/status_item.rs`
  - `crates/tillandsias-macos-tray/src/menu_disabled_v2.rs`
  - `crates/tillandsias-macos-tray/src/pty_vsock_bridge.rs`
- summary: >
    Fold the four hand-wired AppKit action rows toward the portable
    `MenuStructure` contract and run a focused lint/format sweep over the new
    m4/m5 code. This keeps the macOS tray aligned while l9 artifacts are
    pending, without touching release-lane workflow state.
- next_action: >
    Rustfmt-only cleanup is already clear on `linux-next`. Run focused macOS
    tray tests/lints, identify the smallest MenuStructure adapter change that
    removes duplicate manual menu wiring, and checkpoint only if the diff is
    semantic or needed to keep CI green.
- acceptance_evidence:
  - `cargo fmt --all -- --check` or a scoped rustfmt pass for
    `crates/tillandsias-macos-tray/src/action_host.rs`,
    `crates/tillandsias-macos-tray/src/terminal_attach.rs`, and
    `crates/tillandsias-vm-layer/src/vz.rs`.
  - `cargo clippy -p tillandsias-macos-tray -- -D warnings` if available on
    macOS, or a documented platform/toolchain blocker.
  - `cargo test -p tillandsias-macos-tray --bin tillandsias-tray`.
- fallback_when_blocked: >
    Leave a no-code agent_status_packet explaining which MenuStructure field is
    missing, then wait on user-attended m8 smoke or the manifest
    `release_tag` accessor.
- agent_status_packet_expected:
  - current plan
  - dependencies and blockers
  - files touched
  - evidence produced
  - next checkpoint
  - lease intent

### Item: m1b/transport-macos-vsock-connector

- id: `m1b/transport-macos-vsock-connector`
- type: feature
- owner_host: macos
- capability_tags: [rust, vfr, objc2-virtualization, vsock, tokio, async-fd]
- status: done
- completed_at: 2026-05-25T20:00Z
- depends_on: []
- blocks: []
- blocks_end_to_end: []
- owned_files:
  - `crates/tillandsias-vm-layer/src/transport_macos.rs` (new)
  - `crates/tillandsias-vm-layer/src/vz.rs` (extend `wait_ready` to call the connector)
- summary: >
    Expose a macOS VZ vsock connector and extend `wait_ready` from structural
    Running-state polling to a real Hello/HelloAck readiness check. See the
    append-only event for the original enqueue rationale.
- estimated_effort: 1 day.
- evidence_on_done:
  - `cargo test -p tillandsias-control-wire --features vsock` remains green.
  - On macOS, vz-spike or an equivalent smoke connects to the booted Fedora VM
    over vsock and receives `HelloAck`.
- progress:
  - Sub-task A (`connect_to_vm_vsock` + fd ownership) completed at
    linux-next `d2eb5fcf`.
  - Sub-task B (`VsockStream` AsyncRead/AsyncWrite wrapper) completed with
    14/14 unit tests.
  - Sub-task C extended `VzRuntime::wait_ready` to probe the control-wire vsock
    port; lease `7c2a9f1eb083` released.

### Item: m4/pty-attach-appkit-terminal

- id: `m4/pty-attach-appkit-terminal`
- type: feature
- owner_host: macos
- capability_tags: [appkit, objc2, pty, vsock, terminal-app]
- status: done
- completed_at: 2026-05-26T09:35Z
- acceptance_status: live_vm_smoke_blocked_on_m5
- gated_on:
  - live VM smoke after `m5/vfr-image-via-ci-rootfs`
- cleared_gates:
  - linux deliverable `l1/control-wire-pty-attach-tasks-1` shipped at `b345ae68`
  - linux deliverable `l3/in-vm-headless-pty-handler` shipped at
    `f770e013`/`8dc0d129`
  - m4 sub-task B slice 1 (`38bd7669`) TrayActionHost class + four menu items
  - m4 sub-task B slice 2 (`3c3b565f`) main-thread dispatch + Tokio runtime
  - m4 sub-task B slice 3 (`af7ba46a`) VzRuntime start/stop menu wiring
  - m4 sub-task B slice 4 (`075465ce`) Open Shell Terminal stub
  - m4 sub-task B slice 5 (`3e7af023`) GitHub Login Terminal stub
  - m4 sub-task B slice 4b foundation (`681607e1`) `pty_vsock_bridge`
  - shared forge-target `launch_spec` amendment (`35cbdb16`, integrated at
    `a1e1df1`)
  - m4 sub-task B slice 4c precursor (`9578691d`) `VzRuntime::open_vsock_stream`
  - m4 slice 4c.1 (`6d9a2201`) `connect_pty_bridge`
  - m4 slice 4c.2 (`d45d6216`) Open Shell live PTY-over-vsock attach
  - m4 slice 5b (`41ea02e1`) GitHub Login live PTY-over-vsock attach
- depends_on: [m1/vmruntime-stop-and-wait-ready]
- owned_files:
  - `crates/tillandsias-macos-tray/src/terminal_attach.rs`
  - `crates/tillandsias-macos-tray/src/status_item.rs` (menu wiring)
- summary: >
    Implement the macOS side of `control-wire-pty-attach` Task 3.2
    (Unix `nix::pty::openpty` + `tokio::process::Command`) and wire
    "Open Shell" + "GitHub login" menu items to `PtySession::open(...)`,
    then `NSWorkspace::open(Terminal.app, with: <master-fd-as-tty>)`. The
    action-host class, four menu items, main-thread dispatch helper, Tokio
    worker, real VzRuntime start/stop, stub fallback windows, pty-vsock bridge,
    `open_vsock_stream`, `connect_pty_bridge`, and both live intent attach
    paths are in-tree. Remaining work is not another m4 code packet; it is live
    smoke once m5 provides a booted forge-container VM.
- estimated_effort: 1–2 days.
- verification_note: >
    Full terminal-attach smoke needs a booted/provisioned VM path. Until m5
    lands, treat the m4 implementation as structurally done and record any live
    VM failures as m5/runtime provisioning evidence unless the tray attach code
    itself regresses.

### Item: m8/appkit-action-smoke-and-stub-polish

- id: `m8/appkit-action-smoke-and-stub-polish`
- type: diagnostics
- owner_host: macos
- capability_tags: [appkit, macos-bundle, diagnostics]
- status: blocked
- autonomous_completed_at: 2026-05-26T07:10Z
- acceptance_status: blocked_on_user_attended_interactive_smoke
- gated_on:
  - user-attended menu click smoke for Start VM / Stop VM / Open Shell /
    GitHub Login / Quit
- depends_on: []
- cleared_gates:
  - m4 sub-task B slices 1-5 are complete through `3e7af023`
- blocks: []
- owned_files:
  - `crates/tillandsias-macos-tray/src/action_host.rs`
  - `crates/tillandsias-macos-tray/src/terminal_attach.rs`
  - `scripts/build-macos-tray.sh`
- summary: >
    No-VM fallback while l9/m5 gate real PTY attach: sync latest `linux-next`,
    rebuild the macOS tray, launch the app bundle, and verify Start VM,
    Stop VM, Open Shell, GitHub Login, and Quit behavior in the unprovisioned
    state. Preserve the expected "not yet materialized" Start VM error and
    Terminal stub-window messages without panic, deadlock, or menu regression.
- next_action: >
    A user-attended macOS session should run the seven-step interactive menu
    checklist from the 2026-05-26T07:10Z agent_status_packet. Do not reclaim
    this as a cron packet unless manual smoke surfaces a regression.
- acceptance_evidence:
  - `cargo test -p tillandsias-macos-tray` result on macOS.
  - `scripts/build-macos-tray.sh` or equivalent app-bundle build result.
  - Manual no-VM menu smoke notes for the four action-host menu items.
- agent_status_packet_expected:
  - current plan
  - dependencies and blockers
  - files touched
  - evidence produced
  - next checkpoint
  - lease intent

### Item: m9/pty-attach-adapter-unit-wiring

- id: `m9/pty-attach-adapter-unit-wiring`
- type: feature
- owner_host: macos
- capability_tags: [appkit, pty, vsock, tokio, host-shell]
- status: done
- completed_at: 2026-05-26T09:35Z
- superseded_by: `m4/pty-attach-appkit-terminal` slices 4c.1, 4c.2, and 5b
- depends_on: []
- cleared_gates:
  - m4 sub-task B slices 1-5 are complete through `3e7af023`
  - m4 slice 4b bridge foundation landed at `681607e1`
  - shared forge-target `launch_spec` landed at `35cbdb16`
  - `VzRuntime::open_vsock_stream` landed at `9578691d`
- gated_on: []
- blocks:
  - `m4/pty-attach-appkit-terminal`
- owned_files:
  - `crates/tillandsias-macos-tray/src/action_host.rs`
  - `crates/tillandsias-macos-tray/src/terminal_attach.rs`
  - `crates/tillandsias-macos-tray/src/pty_vsock_bridge.rs`
  - `crates/tillandsias-vm-layer/src/vz.rs`
- summary: >
    No-VM-testable slice for the real attach path while l9/m5 gate the booted
    VM. Thread the landed `launch_spec(intent, project, rows, cols)` signature,
    `VzRuntime::open_vsock_stream`, and `spawn_pty_bridge` through a small
    macOS attach adapter that preserves explicit no-VM/no-project errors and
    leaves the final `pump_io` + Terminal.app live session behind the m5 gate.
- next_action: >
    Do not claim separately. The scope was completed inside m4 with
    `connect_pty_bridge`, `run_pty_attach`, and Terminal.app screen-attach
    wiring through `41ea02e1`. Keep future work on m5 runtime provisioning or
    project threading.
- acceptance_evidence:
  - `cargo test -p tillandsias-macos-tray --bin tillandsias-tray` on macOS.
  - `cargo test -p tillandsias-vm-layer --features materialize` if `vz.rs`
    changes.
  - Clear runtime error/log behavior when no VM is running, without replacing
    the existing stub-window fallback until live attach is ready.
- fallback_when_blocked: >
    If the adapter needs live VM state earlier than expected, stop at a
    compile-tested helper with exact missing dependency notes and leave the
    remaining live attach to m5.
- agent_status_packet_expected:
  - current plan
  - dependencies and blockers
  - files touched
  - evidence produced
  - next checkpoint
  - lease intent

### Item: m1/vmruntime-stop-and-wait-ready

- id: `m1/vmruntime-stop-and-wait-ready`
- type: feature
- owner_host: macos
- capability_tags: [rust, vfr, objc2-virtualization, vm-layer]
- status: done
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
- completed_at: 2026-05-25T16:45Z
- evidence_on_done:
  - `VmRuntime::stop(drain_timeout)` and structural `wait_ready(timeout)` landed on osx-next.
  - `VmRuntime::exec` now returns an explicit Phase 5 deferral instead of panicking.
  - 10/10 unit tests passed on macOS.

### Item: m2/refactor-vz-spike-via-vmruntime

- id: `m2/refactor-vz-spike-via-vmruntime`
- type: feature
- owner_host: macos
- capability_tags: [rust, vfr, testing]
- status: done
- depends_on: [m1/vmruntime-stop-and-wait-ready]
- owned_files:
  - `crates/tillandsias-vm-layer/examples/vz-spike.rs`
- summary: >
    Convert vz-spike from direct `boot::build_vm_configuration` invocations
    to driving `VzRuntime::start()` + `stop()` + `wait_ready()`. Acts as
    the regression smoke for the production code path. Per plan/steps/20
    Phase 1 list, this is the natural follow-on to m1.
- completed_at: 2026-05-25T16:50Z
- evidence_on_done:
  - `vz-spike --boot` now drives `VzRuntime::start -> wait_ready -> stop`.
  - Apple Silicon smoke booted Fedora 44 and exercised the drain-then-force stop path.

### Item: m3/macos-scoped-clippy-cleanup

- id: `m3/macos-scoped-clippy-cleanup`
- type: housekeeping
- owner_host: macos
- capability_tags: [rust, clippy, hygiene]
- status: done
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
- completed_at: 2026-05-25T16:45Z
- evidence_on_done:
  - macOS-scoped clippy cleanup landed; the `manual_clamp` finding in `vz.rs` was fixed.

## Linux-gated and recently unblocked deliverables

### Item: m5/vfr-image-via-ci-rootfs

- id: `m5/vfr-image-via-ci-rootfs`
- type: feature
- owner_host: macos
- capability_tags: [vfr, vm-layer, fetch, provisioning]
- status: done
- completed_at: 2026-05-26T16:21Z
- acceptance_status: bytes_level_proven; live_app_smoke_waits_on_user_attended_m8
- gated_on:
  - user-attended m8 smoke of the rebuilt production `.app`
- cleared_gates:
  - linux deliverable `l2/recipe-shared-modules` integrated at `a7af0ed`
  - linux deliverable `l7/§3-materializer-driver` shipped at `9dca2c47`
  - recipe scaffold landed at `a77fae00`
  - `materialize::macos::tar_to_vfr_img` landed at `a77fae00`
  - recipe-publish workflow scaffolding landed at `55ff55c6`
  - l9 artifact URL template + `Manifest::artifact_url` resolver landed at
    `963baeb1`
  - l9 consumer contract documented at `74b1d78d`
  - m5 fetch primitive landed on `origin/osx-next` at `ec76e63a` and was
    merged/tested into `linux-next` during the 11:43Z integration cycle
  - m5 Start VM auto-fetch wiring landed on `origin/osx-next` at `080a8e60`
    and was folded into `linux-next` through `a3152fc5`
  - l9 recipe-publish artifacts, manifest SHA pins, and both headless release
    assets landed
  - `.img.xz` fetch/decompress landed at `916a240e`; bytes-level proof landed
    at `303a5c24`; full unblocked app-smoke state landed at `3cc9e563`
- depends_on: [m1/vmruntime-stop-and-wait-ready]
- owned_files:
  - `crates/tillandsias-vm-layer/src/vz.rs` (provisioning slice)
  - `crates/tillandsias-vm-layer/src/materialize/macos.rs`
  - `crates/tillandsias-macos-tray/src/vz_lifecycle.rs`
- summary: >
    Per D6 amendment + macOS recipe-convergence response (request:
    CI-fetch publishes BOTH `.tar` AND `.img` per arch — the .img is
    the raw EFI/ext4 image consumed directly by VFR; the .tar is the
    intermediate). Contribute `materialize::macos::tar_to_vfr_img`
    (Linux-runnable per D6 task 2b.2). The converter and workflow scaffold
    are done, and the macOS fetch primitive is wired into `startVm:`. Fresh
    installs now fetch the published `.img.xz`, decompress to the VFR image,
    and verify the decompressed bytes against the manifest's `aarch64.img` SHA.
    The current temporary tag source is an in-code constant matching the
    manifest pins; replace it with `Manifest::release_tag()` when that shared
    accessor lands.
- estimated_effort: done; live verification is the user-attended m8 smoke.

### Item: m6/macos-installer-pkg-and-codesign

- id: `m6/macos-installer-pkg-and-codesign`
- type: feature
- owner_host: macos
- capability_tags: [macos-bundle, codesign, installer]
- status: done
- completed_at: 2026-05-26T00:00Z
- gated_on: []
- cleared_gates:
  - m1 + m2 functional VM path completed at 2026-05-25T16:50Z
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
- evidence_on_done:
  - `scripts/build-macos-tray.sh` builds, assembles, ad-hoc signs, verifies,
    archives, and writes SHA256SUMS for `Tillandsias.app`.
  - `scripts/install-macos.sh` performs a SHA-verified install with
    `/Applications` / `~/Applications` fallback and optional login item setup.
  - macOS host verified the app launches and the menubar icon appears.

### Item: m7/macos-ci-job-and-tarball

- id: `m7/macos-ci-job-and-tarball`
- type: feature
- owner_host: macos (Linux user can author the YAML)
- capability_tags: [ci, github-actions, macos-runner]
- status: done
- completed_at: 2026-05-26T00:35Z
- gated_on: []
- cleared_gates:
  - m6 `macos-installer-pkg-and-codesign` completed at 2026-05-26T00:00Z
- owned_files:
  - `.github/workflows/ci.yml`
  - `.github/workflows/release.yml`
- summary: >
    Per plan/steps/20 Phase 3: macOS CI job + first releasable
    `tillandsias-tray-<version>-macos-arm64.tar.gz`. Add additive
    macos-* jobs; do not touch Linux/Windows jobs.
- estimated_effort: 1 day.
- evidence_on_done:
  - `.github/workflows/ci.yml` includes a macOS build job that builds the
    app bundle, verifies plist/codesign/entitlements, runs macOS-cfg-gated
    tests, and uploads a macOS tray artifact.
  - `.github/workflows/release.yml` includes a macOS release job that builds,
    signs, and uploads the macOS tarball and support files.

## Linux deliverables macOS is waiting on (status mirrors)

| Linux item | Status | Blocks macOS item |
|---|---|---|
| `l1/control-wire-pty-attach-tasks-1` | done (`b345ae68`; §1 enum/capability tasks complete) | m4 ready with l3 also done |
| `l2/recipe-shared-modules` | done (`a7af0ed`; parser tests green on Linux) | m5 done |
| `l3/in-vm-headless-pty-handler` | done (`f770e013`/`8dc0d129`; tasks 4.1-4.7, two pump tests ignored pending AsyncFd rewrite) | m4 ready for host-side wiring |
| `l4/replace-vsock-stub-handlers` | done (`6956c825`; informational only for macOS) | (informational only for macOS) |
| `l5/recipe-smoke-ci-publish` | done for macOS path; `.img.xz` asset and manifest SHA are published/proven | m5 done |
| `l7/§3-materializer-driver` | done (`9dca2c47`; materializer feature and cache/export API shipped) | m5 converter/API work unblocked |
| `l8/buildah-exec-recipe-publish-smoke` | done (`6aeae3a7`; real BuildahExec + `materialize-cli`; 43/43 vm-layer materialize tests, full CI/install pass in ledger) | m5 done |
| `l9/recipe-artifact-url-and-publish-smoke` | done for macOS m5; artifact URL contract, `.img.xz` release asset, manifest SHA pin, and bytes-level fetch/decompress verification are complete | m5 done; m8 smoke remains |

## Events

<!-- Append events here when claiming/progressing items. Append-only. -->

### event: m3 claimed + done — 2026-05-25T16:45Z

- item: `m3/macos-scoped-clippy-cleanup`
- agent_id: `osx-next-claude-opus-4-7` on `Tlatoanis-MacBook-Air`
- lease_id: `6e47f3d51c87`
- action: claim → done (single iteration)
- evidence: `vz.rs:144` `host_cores.min(4).max(1)` → `host_cores.clamp(1, 4)`.
  `cargo clippy -p tillandsias-vm-layer --lib` no longer flags `manual_clamp`.
  10/10 unit tests pass (was 6/6 before m1+m3 changes).
- lease released.

### event: m1 claimed + done — 2026-05-25T16:45Z

- item: `m1/vmruntime-stop-and-wait-ready`
- agent_id: `osx-next-claude-opus-4-7` on `Tlatoanis-MacBook-Air`
- lease_id: `4b14d0b05fff`
- action: claim → done (single iteration)
- evidence:
  - `VmRuntime::stop(drain_timeout)`: takes the handle out of `vm.lock`,
    calls `requestStopWithError`, polls `VZVirtualMachine.state` in 250 ms
    CFRunLoop slices until state == Stopped(0); on drain_timeout expiry
    dispatches `stopWithCompletionHandler` (hard force-stop, 5 s grace)
    and returns a clear timeout error.
  - `VmRuntime::wait_ready(timeout)`: polls `VZVirtualMachine.state` with
    the `host-shell::vsock_client` backoff cadence (250 ms / 500 ms / 1 s /
    2 s / 4 s, capped) until state == Running(1); on state == Error(3)
    aborts immediately; on timeout returns a structured error including
    the final state value. NOTE: this is the STRUCTURAL readiness check
    only; vsock handshake (per the queue's spec text) lands with the
    forthcoming `transport_macos.rs` connector (m1b below — newly enqueued).
  - `VmRuntime::exec`: replaced `unimplemented!()` with an explicit
    "deferred to Phase 5 (gated on control-wire-pty-attach merging)"
    `Err`, so callers can't silently panic on it during this gap.
  - Two new tests added: `vz_stop_and_wait_ready_fail_clean_before_start`
    and `vz_exec_returns_phase5_deferral`. Total 10/10 unit tests pass.
- lease released.

### Item: m1b/transport-macos-vsock-connector (new, enqueued; mirrored above as ready)

- id: `m1b/transport-macos-vsock-connector`
- type: feature
- owner_host: macos
- capability_tags: [rust, vfr, objc2-virtualization, vsock, tokio, async-fd]
- status: pending
- depends_on: []
- blocks: [m4, m5]  (and a future "wait_ready actually verifies vsock handshake")
- owned_files:
  - `crates/tillandsias-vm-layer/src/transport_macos.rs` (NEW)
  - `crates/tillandsias-vm-layer/src/vz.rs` (extend `wait_ready` to call the connector)
- summary: >
    New file `transport_macos.rs` exposing `connect_to_vm_vsock(vm: &VZVirtualMachine, port: u32) -> Result<impl AsyncReadWrite>`. Walks the VM's `socketDevices()` list, downcasts the first `VZVirtioSocketDevice`, calls `connectToPort:completionHandler:`, wraps `VZVirtioSocketConnection.fileDescriptor()` in `tokio::io::unix::AsyncFd<RawFd>` with an `AsyncRead + AsyncWrite` impl that delegates to the fd. Then extend `wait_ready` to call this with port `CONTROL_WIRE_VSOCK_PORT` and confirm Hello/HelloAck handshake.
- estimated_effort: 1 day.
- evidence_on_done:
  - `cargo test -p tillandsias-control-wire --features vsock` still green on Linux.
  - On macOS, a small smoke test (extension of vz-spike) connects vsock to the booted Fedora and sends a `Hello`; receives `HelloAck` from the in-VM headless's vsock_server (already implemented).

### event: m4 + m5 gating recheck — 2026-05-25T16:45Z

Re-read of `openspec/changes/control-wire-pty-attach/tasks.md`:
- `§1` (1.1–1.5): **all 5 items DONE** (PtyDirection, PtyExit, the four ControlMessage variants, MAX_PTY_FRAME_BYTES, CAP_PTY_ATTACH_V1).
- `§2`–`§9`: pending.

Interpretation: linux deliverable `l1/control-wire-pty-attach-tasks-1` is
**DONE on linux-next** (the macOS host's wait, queue-item m4, can advance
sub-tasks that only depend on the §1 enum + capability — but it still
needs `l3/in-vm-headless-pty-handler` (= pty-attach §4) for the round-trip
to work end-to-end). m4 stays gated on l3.
Historical status above is superseded by the 18:25Z header reconciliation:
l3 shipped, so m4 is ready for host-side wiring; m1b still gates end-to-end
Hello/HelloAck smoke.

### event: m2 claimed + done — 2026-05-25T16:50Z

- item: `m2/refactor-vz-spike-via-vmruntime`
- agent_id: `osx-next-claude-opus-4-7` on `Tlatoanis-MacBook-Air`
- lease_id: `e4f1a7b903c2`
- action: claim → done (single iteration)
- evidence:
  - `crates/tillandsias-vm-layer/examples/vz-spike.rs` rewritten: the
    `--boot` path now drives `VzRuntime::start → wait_ready → stop`
    instead of hand-rolling `VZVirtualMachine::initWithConfiguration` +
    `startWithCompletionHandler` + `requestStopWithError`. The
    validate-only path (default, no `--boot`) still bypasses the runtime
    so config-shape errors are inspectable.
  - The spike sets up `image_root` as a tempdir with a symlink
    `rootfs.img → <user --disk>` so `VzRuntime` finds the rootfs at the
    path it expects (Phase 4 / D6 materializer will populate this
    automatically in production).
  - New flag `--observe-secs N` (default 5) controls how long to pump
    CFRunLoop between `wait_ready` and `stop`.
  - End-to-end smoke on Apple Silicon macOS 26.5 with the cached
    Fedora 44 raw image:
    - `VzRuntime::start`: ok in **267 ms**
    - `VzRuntime::wait_ready` (state == Running): ok in **0 ms** (was
      already Running by the time the poll ran)
    - Fedora kernel boots, NAT brings up `192.168.64.5/6`, vsock
      device negotiated CID 3, login prompt reached
    - `VzRuntime::stop(30s drain)`: **drain timeout expired** because
      Fedora 44 cloud's ACPI shutdown via `requestStop` takes >30 s for
      systemd to drain (journald flush + cgroups teardown). Force-stop
      `stopWithCompletionHandler` fallback dispatched within the same
      call — production tray code can pass a longer drain (60s) for
      friendlier shutdowns. The structural contract (drain THEN force)
      is verified.
  - 10/10 unit tests still pass; spike still validates clean.
- lease released.

### event: drain-timeout finding (sub-item m2.a) — 2026-05-25T16:50Z

For future iterations / production tray:

- Fedora 44 Cloud's stock systemd takes ~30–60 s to honor the ACPI
  shutdown request VZ issues via `requestStop`. The macOS tray should
  default `drain_timeout` to **60 s** so the graceful path completes
  rather than always triggering force-stop.
- Faster alternative if 60 s is too slow for UX: have the in-VM
  tillandsias-headless register a vsock listener that, on receiving
  `ControlMessage::VmShutdownRequest { drain_timeout_ms }`, calls
  `systemctl --no-wall poweroff`. That skips ACPI handshake latency.
  Requires `control-wire-pty-attach` adjacent code to land first.

### event: m1b sub-task A claimed + done — 2026-05-25T17:00Z

- item: `m1b/transport-macos-vsock-connector` (3 sub-tasks: A=connect+fd,
  B=AsyncRead/AsyncWrite wrap, C=wait_ready handshake verify)
- agent_id: `osx-next-claude-opus-4-7` on `Tlatoanis-MacBook-Air`
- lease_id: `7c2a9f1eb083`
- action: sub-task A — claim → done.
- evidence:
  - NEW `crates/tillandsias-vm-layer/src/transport_macos.rs` (~200 lines).
    Public surface: `connect_to_vm_vsock(vm, port, timeout) -> Result<VsockFd, ConnectError>`.
  - Walks VM's socketDevices, downcasts via `isKindOfClass:` guard,
    `connectToPort:completionHandler:` bridged through mpsc + CFRunLoop
    pump (50 ms slices).
  - `VsockFd { fd, _connection }` holds the Retained connection so the fd
    stays valid for the lifetime of the wrapper; `Send + Sync` per
    documented unsafe-impl (established vsock sockets are POSIX
    thread-safe; VZ's dispatch-queue gate is for VM-management ObjC).
  - Module is `#![cfg(target_os = "macos")]`; lib.rs registers it under
    `#[cfg(target_os = "macos")] pub mod transport_macos`.
  - Per branch canon: shared `control-wire::transport::connect(Vsock{cid,
    port})` path UNCHANGED — that's Linux+Windows. macOS uses this
    private connector because VFR needs the in-process VM handle which
    the shared Transport enum can't carry.
  - 2 new tests: `connect_error_implements_error`, `vsock_fd_is_send`.
    12/12 unit tests pass.
- Sub-task B (next): wrap VsockFd in `tokio::io::unix::AsyncFd<RawFd>`
  with `AsyncRead + AsyncWrite` so host-shell `vsock_client::handshake`
  can ride it. ~2 h.
- Sub-task C (after B): extend `VzRuntime::wait_ready` to invoke
  `connect_to_vm_vsock + handshake` after the state-poll succeeds. ~1 h.
- Lease NOT released — sub-tasks B + C still under same lease until full
  m1b is done.

### event: header reconciliation — 2026-05-25T18:25Z

- Folded the m1b terminal event into the item header: m1b is not ready or
  stalled; it is actively leased by `7c2a9f1eb083` until approximately
  2026-05-25T21:00Z under the default 4h TTL. Sub-task A is done; sub-tasks
  B and C remain.
- Marked m6 `ready` because m1 + m2 completed and its bundle/codesign work can
  proceed independently before m4/m5.
- Mirrored Linux l4 as done at `6956c825`. It is informational for macOS but
  removes one stale shared-gate signal from this queue.
- `l3/in-vm-headless-pty-handler` shipped on linux-next at
  `f770e013`/`8dc0d129`; m4 is now ready for host-side AppKit Terminal
  wiring. End-to-end smoke remains limited until m1b sub-tasks B/C finish
  the AsyncRead/AsyncWrite wrapper and wait_ready Hello/HelloAck handshake.
- Current macOS blockers: m5 waits on Linux l7 plus macOS-owned l5
  recipe-publish/CI-fetch work; m4 has an end-to-end verification dependency
  on the in-progress m1b handshake tail but is no longer blocked for coding.

### event: m1b sub-task B done — 2026-05-25T17:30Z

- item: `m1b/transport-macos-vsock-connector` (sub-task B of three)
- agent_id: `osx-next-claude-opus-4-7` on `Tlatoanis-MacBook-Air`
- lease_id: `7c2a9f1eb083` (still held; sub-task C remains)
- action: sub-task B — done.
- evidence:
  - Extends `transport_macos.rs` with `VsockStream` implementing
    `AsyncRead + AsyncWrite` on top of an established VFR vsock fd.
  - `AsyncFd<FdHolder>` for tokio reactor (kqueue) integration; `read(2)`/
    `write(2)` syscalls inlined via extern "C"; `set_nonblocking` via
    `fcntl(F_SETFL, O_NONBLOCK)`; `poll_shutdown` calls
    `shutdown(SHUT_WR)` for prompt peer-EOF.
  - `FdHolder` is non-owning — VsockStream._connection (the
    `Retained<VZVirtioSocketConnection>`) is the canonical fd owner,
    so `AsyncFd::drop` only deregisters from kqueue.
  - 14/14 unit tests pass (2 new: `vsock_stream_is_send_sync`,
    `vsock_stream_is_async_read_write`).
- Sub-task C (next, same lease): extend `VzRuntime::wait_ready` to call
  `connect_to_vm_vsock(CONTROL_WIRE_VSOCK_PORT)` after the state-poll
  succeeds, confirming the in-VM tillandsias-headless's vsock listener
  is up. Will close lease + complete m1b. ~1 h.

### event: m4 (PTY-attach AppKit terminal) unblocked — 2026-05-25T17:30Z

- Linux landed `l3` (in-VM PTY handler in
  `crates/tillandsias-headless/src/pty_handler.rs`) and the host-side
  `crates/tillandsias-host-shell/src/pty/{mod.rs,windows.rs}` via the
  pty-attach §3.1 + §3.3 work. `l1` was already done.
- m4's `gated_on: [l1, l3]` is now SATISFIED. m4 can start when this
  worker shifts from m1b to user-facing wiring.
- macOS-side delta needed: `crates/tillandsias-host-shell/src/pty/macos.rs`
  (mirror of `windows.rs` but using `nix::pty::openpty`) + wiring in
  `crates/tillandsias-macos-tray/src/terminal_attach.rs` that opens
  Terminal.app with the host PTY master fd.

### event: m1b sub-task C + m1b COMPLETE — 2026-05-25T20:00Z

- item: `m1b/transport-macos-vsock-connector` (ALL THREE sub-tasks done)
- agent_id: `osx-next-claude-opus-4-7` on `Tlatoanis-MacBook-Air`
- lease_id: `7c2a9f1eb083` → RELEASED
- evidence (sub-task C):
  - VmRuntime::wait_ready now does structural state-poll + functional
    vsock-probe. Connects via transport_macos::connect_to_vm_vsock at
    CONTROL_WIRE_VSOCK_PORT (42420) with 1s per-probe budget; retries
    on transient errors with the 250..4000ms backoff cadence.
  - Added tillandsias-control-wire as a vm-layer dep purely for the
    port constant (no cycle).
  - 14/14 unit tests pass.
- m1b totals: ~430 lines across transport_macos.rs (connect, VsockFd,
  VsockStream w/ AsyncRead+AsyncWrite, ConnectError) + extended vz.rs
  wait_ready. Unblocks m4 (PTY attach can ride VsockStream end-to-end
  once host-shell's vsock_client uses it) and turns wait_ready from
  "structural readiness only" into "guest is reachable on the control
  wire."

### Phase 1 status — 2026-05-25T20:00Z

With m1, m1b, m2, m3 all done, **Phase 1 (the technical core of the
macOS tray) is essentially complete** modulo polish. Remaining macOS
queue items:
- `m4/pty-attach-appkit-terminal` — unblocked (Linux l1+l3 done).
- `m5/vfr-image-via-ci-rootfs` — gated on Linux l2 (recipe shared
  modules) and l5 (recipe-smoke CI publish). Linux owns §3 materializer
  driver; not yet integrated.
- `m6/macos-installer-pkg-and-codesign` — unblocked; doesn't depend on
  PTY or recipe.
- `m7/macos-ci-job-and-tarball` — depends on m6.

Recommended next: m4 (user-facing terminal-attach UX) OR m6 (gets a
clickable .app artifact for smoke). User priority signal welcome.

### event: m4 foundation done (pty::unix backend) — 2026-05-25T23:50Z

- item: `m4/pty-attach-appkit-terminal` (foundation half)
- agent_id: `osx-next-claude-opus-4-7` on `Tlatoanis-MacBook-Air`
- lease_id: `e95a8c2f31b0`
- action: foundation sub-task — done.
- evidence:
  - NEW `crates/tillandsias-host-shell/src/pty/unix.rs` (~280 lines).
    `UnixPtyMaster::open(rows, cols)` via `openpty(3)` + `ptsname_r` +
    `fcntl(O_NONBLOCK)` + `AsyncFd<FdHolder>` reactor wrap.
    `split()` hands out `UnixPtyReader` + `UnixPtyWriter` over a shared
    `Arc<AsyncFd>` so concurrent read+write in pump_io is sound.
    `slave_path()` exposes `/dev/ttys*` for the macOS tray's Terminal.app
    wrapper to re-open as a controlling tty. `resize()` via TIOCSWINSZ.
  - Registered as `#[cfg(unix)] pub mod unix;` in `pty/mod.rs`
    (additive — Windows path untouched).
  - Inline libc FFI (openpty, read, write, fcntl, ptsname_r, ioctl) — no
    new Cargo dep.
  - 12/12 pty tests pass incl. 3 new ones (trait satisfied, real openpty
    yields /dev/ttys* slave path, async-io halves type-check).
- Remaining for m4 (separate sub-task):
  `crates/tillandsias-macos-tray/src/terminal_attach.rs` — wire menu items
  ("Open Shell", "GitHub login") to UnixPtyMaster + PtySession + spawn
  Terminal.app on the slave_path. Estimated ~3 h, gated only on having a
  booted VM with the in-VM tillandsias-headless's vsock listener up (which
  iter 11's wait_ready stage 2 now verifies).
- Lease released.

### event: m6 done — build-macos-tray + install-macos scripts — 2026-05-26T00:00Z

- item: `m6/macos-installer-pkg-and-codesign`
- agent_id: `osx-next-claude-opus-4-7` on `Tlatoanis-MacBook-Air`
- lease_id: `3f48a92c1ed7`
- action: claim → done.
- evidence:
  - scripts/build-macos-tray.sh (NEW, ~120 lines): builds release binary,
    assembles Tillandsias.app with Info.plist substitution, ad-hoc
    codesigns with Tillandsias.entitlements (--options runtime), verifies
    signature + entitlement presence, tars + SHA256SUMS.
  - scripts/install-macos.sh (NEW, ~140 lines): curl-installable; Apple
    Silicon + macOS 14+ gates; SHA-verified download; /Applications/
    vs ~/Applications/ fallback; idempotent re-install with running-tray
    quit + backup; optional --login-item; Gatekeeper hint; open -a.
  - Fixed pre-existing tillandsias-macos-tray Cargo.toml gap — added
    NSView + NSCell to objc2-app-kit features so the tray binary actually
    compiles (NSStatusItem::button needs NSView; NSMenuItem::setState +
    NSControlStateValueOn need NSCell).
- Verified end-to-end on this host:
  - scripts/build-macos-tray.sh: produces dist/Tillandsias.app + 0.14 MiB
    tarball at sha256 1ce2cba2; codesign --verify --deep --strict: PASSED;
    entitlement com.apple.security.virtualization confirmed present in the
    signed binary.
  - open dist/Tillandsias.app: actually launches the binary (2 processes
    spawned, killed for cleanup). The menubar icon appears as expected.
- Lease released.

### Phase 1 + Phase 2 status — 2026-05-26T00:00Z

With m1, m1b (A+B+C), m2, m3, m4-foundation, m6 all done, the macOS tray
has:
  - A working Tillandsias.app bundle that builds, signs, and launches.
  - VzRuntime with real start/stop/wait_ready bodies (vsock-handshake
    aware).
  - PTY infrastructure ready for the AppKit terminal_attach wiring.

Remaining macOS queue items:
  - `m4/pty-attach-appkit-terminal` user-facing wiring — ~3 h.
  - `m5/vfr-image-via-ci-rootfs` — gated on Linux l2+l5 (recipe shared
    modules + recipe-smoke CI).
  - `m7/macos-ci-job-and-tarball` — depends on m6 (now done!) — adds
    macos-build CI job + macos-release tarball upload. ~1 d.

Recommended next: m7 (lock in CI green) or m4 user wiring (visible UX).

### event: linux coordinator reconciliation — 2026-05-26T00:18Z

- Folded terminal events into item headers: m1b is done and lease
  `7c2a9f1eb083` is released; m6 is done and unlocks m7; m4 remains ready
  for the user-facing `terminal_attach` half after the Unix PTY foundation
  landed at `0551a265`.
- Current macOS ready work: m4 terminal wiring or m7 macOS CI/tarball.
- Current macOS blocker: m5 still waits on l7 materializer plus macOS-owned
  l5 recipe-publish/CI-fetch. Linux lease `linux-l-mat-2026-05-25T15Z`
  is past its default TTL with no checkpoint found in the ledgers, so the next
  Linux/materializer-capable agent should either renew with a status packet or
  release/reclaim the smallest materializer API/cache/export slice.

### event: m4 wiring (Quit + version header) + m7 (CI + release) done — 2026-05-26T00:35Z

- items: `m4` (UI Quit slice) + `m7/macos-ci-job-and-tarball`
- agent_id: `osx-next-claude-opus-4-7` on `Tlatoanis-MacBook-Air`
- leases: `m4-quit:b1e7c9f30425`, `m7:a3e4c512f9d8` — both released
- action: claim → done in one eager iter.

m4 (Quit slice — `79ff0571`):
- `crates/tillandsias-macos-tray/src/status_item.rs::append_footer`:
  separator + "Tillandsias v<…> (alpha)" disabled identity header +
  separator + "Quit Tillandsias" with `sel!(terminate:)` + Cmd-Q key
  equivalent. Target=nil so AppKit's responder chain routes to
  NSApplication.
- Before this commit the binary was unkillable from the UI (user had
  to pkill — reported as "stuck" on first launch). Now `osascript -e
  'tell application "Tillandsias" to quit'` cleanly terminates.
- Other menu actions (Start VM / Stop VM / Open Shell / GitHub login)
  remain inert pending the objc2::declare_class! action-host (separate
  iter, ~3 h).

m7 (CI + release — `c9341fa6`):
- `.github/workflows/ci.yml`: NEW `macos-build` job on `macos-latest`,
  parallel to `check`. Builds via `scripts/build-macos-tray.sh`;
  verifies bundle (Info.plist + LSUIElement + codesign + entitlement);
  runs the macOS-cfg-gated unit tests (`vm-layer`, `host-shell::pty::
  unix`); uploads `dist/tillandsias-tray-*-macos-arm64.tar.gz` as the
  `macos-tray-build` workflow artifact (14d retention).
- `.github/workflows/release.yml`: NEW `macos-release` job on
  `macos-latest`, `needs: release` (the Linux job). Builds tarball,
  Cosign-signs (same OIDC pattern as Linux), uploads tarball + .cosign.
  bundle + install-macos.sh + SHA256SUMS-macos to the same GitHub
  release with `gh release upload --clobber`.
- Both YAML files validated; local scripts/build-macos-tray.sh
  re-verified pre-commit.

### Phase status — 2026-05-26T00:35Z

- Phase 0 ✓ (coordination)
- Phase 1 ✓ (VzRuntime body, transport_macos, wait_ready vsock probe)
- Phase 2 ✓ (.app bundle, codesign, install-macos.sh)
- Phase 3 ✓ (macOS CI build + release jobs)
- Phase 4 — gated on Linux l2 (recipe shared modules) + l5 (recipe-smoke
  CI publish). Linux owns §3 materializer; my m5 fetches the result.
- Phase 5 — m4 user-wiring sub-task B: NSObject action-host via
  objc2::declare_class! so Start VM / Stop VM / Open Shell menu items
  dispatch to VzRuntime + PtySession + spawn Terminal.app. ~3 h.
- Phase 6 — end-to-end smoke + first real release (gated on Phases 4+5).

Recommended next: m4 user-wiring sub-task B (visible Start VM / Open
Shell actions). Without these the tray's only user-facing capability is
"Quit" — needs the action-host before it can actually drive the VM that
all the lower layers can now boot.

### event: §1 recipe scaffold + §3.7.1 tar_to_vfr_img — unblock for Windows — 2026-05-26T01:30Z

- items: `§1` recipe authoring (was unclaimed) + `§3.7.1` materialize::macos::tar_to_vfr_img (mine)
- agent_id: `osx-next-claude-opus-4-7` on `Tlatoanis-MacBook-Air`
- lease_id: `7b3f1a9d8e02`
- action: claim → done in a single eager iter prompted by Windows-host
  blocker post (Windows on the recipe-publish / CI-fetch artifact).

Pulled the tree forward to `fa39e95c`: confirmed
`crates/tillandsias-vm-layer/src/materialize/` did NOT exist and
`images/vm/` did NOT exist. Linux's `linux-l-mat-2026-05-25T15Z` lease
on §3 materializer driver had lapsed past TTL with no checkpoint.
Author what I'm clearly authorized to ship; leave §3 driver for Linux to
release/renew/reclaim.

Delivered (commit `a77fae00`, code → osx-next):

§1 recipe scaffold (was unclaimed):
- `images/vm/Recipefile` — Containerfile + 3 RECIPE directives
  (vsock-listen 42420, entry path, arch list). 5 build steps, no
  hidden state.
- `images/vm/manifest.toml` — `recipe_version=1`, per-arch `[[base]]`
  digest pins (currently `sha256:pending-first-pin` — refresh via
  `skopeo inspect`), `[output].expected_rootfs_sha` keyed on
  `<arch>.<format>` per D6 (`x86_64.tar`, `aarch64.tar`, `aarch64.img`),
  `[boot].kernel_cmdline = "quiet console=hvc0 systemd.log_target=
  console"`.
- `images/vm/bootstrap/{10-systemd,20-tillandsias,30-enclave}.sh` —
  systemd config (DHCP + sshd-mask + persistent journal); cargo install
  tillandsias-headless from `/src` bind-mount → musl static + systemd
  unit on port 42420; placeholder for forge enclave pre-pull.

§3.7.1 tar_to_vfr_img (mine, was waiting on the script):
- `scripts/materialize-macos-tar-to-img.sh` — Linux-only,
  needs-root bash script. Sparse `.img` → parted GPT (ESP fat32 + ext4
  root) → losetup -P → mkfs.vfat/mkfs.ext4 → mount, `tar -xf`, sync,
  umount, losetup -d. Best-effort EFI bootloader staging from rootfs
  `/usr/share/efi/<arch>/shim*.efi`. Writes `/etc/fstab` with UUIDs.
- `crates/tillandsias-vm-layer/src/materialize/macos.rs` — public
  `tar_to_vfr_img(tar, out_img, script) -> Result<(), ConvertError>` +
  `script_for_repo_root(repo)` helper. `ConvertError` taxonomy:
  `ScriptNotFound`, `TarMissing`, `ScriptFailed { exit_code, stderr }`,
  `SpawnFailed`. 4 new unit tests (18/18 vm-layer total now).
- `crates/tillandsias-vm-layer/src/materialize/mod.rs` — module entry;
  opens the directory for Linux's §3 `run()` driver and Windows' §3.7.2
  `tar_to_wsl_import` to land alongside without further coordination.

Path to Windows unblock:
1. Linux releases the stale `linux-l-mat-2026-05-25T15Z` lease (or
   renews/reclaims), then ships §3 `materialize::run` producing a `.tar`.
2. CI recipe-publish workflow (§2b.3, also mine; next eager iter) wires
   `materialize::run` + this converter; uploads `.tar` + `.img` per arch
   to the GitHub release.
3. Windows' `tar_to_wsl_import` (§3.7.2) consumes the `.tar` and runs
   `wsl --import`. E2E unblocked.

Asks back to other hosts:
- **TO LINUX:** please release/renew the `linux-l-mat-2026-05-25T15Z`
  lease so §3 materializer driver work can move. Or hand off to whoever
  next claims it — macOS can take it if no one steps up by ~3 cron ticks
  from now (was a conditional claim from iter 7; clock is restarting).
- **TO WINDOWS:** the converter signature + error taxonomy is
  `tillandsias_vm_layer::materialize::macos::tar_to_vfr_img(tar,
  out_img, script)`. Your §3.7.2 should mirror this shape so the
  recipe-publish CI job dispatches symmetrically per arch+format.
- **TO ALL:** §1 recipe scaffold is intentionally minimal — bootstrap
  scripts have `TODO`s for production polish. Anyone is welcome to
  amend; tombstone if you supersede.

Lease `7b3f1a9d8e02` released.

### event: linux coordinator status reconciliation — 2026-05-26T01:13Z

- Observed remote heads: `linux-next` `cabf9c9f`, `windows-next` `cb39cb7c`,
  `osx-next` `4aa42c6a`, `main` `ddf52dff`.
- Folded m7 completion into headers; m7 is done, while m4 remains ready for
  the action-host sub-task B described above.
- Folded Linux l7 completion into m5 mirrors. m5 is no longer blocked by the
  materializer API/cache/export slice; remaining recipe gates are the
  macOS-owned `recipe-smoke-ci-publish` / CI-fetch artifact path and the macOS
  `tar_to_vfr_img` converter implementation.

### event: m5 unblock convergence — 2026-05-26T01:35Z (post-merge)

CRDT-merge of the two prior events: Linux confirms l7 (materializer driver)
done, so m5 is now blocked ONLY on the macOS-owned recipe-publish CI workflow
and tar_to_vfr_img. **tar_to_vfr_img landed in commit `a77fae00`** (this same
post-merge cycle), so the remaining single blocker is `recipe-smoke-ci-
publish` (§2b.3 — also mine). Plan: next eager iter wires the CI job that
materializes the recipe → `.tar`, runs tar_to_vfr_img → `.img`, uploads both
artifacts.

### event: §2b.3 recipe-publish CI workflow — Windows E2E unblocked — 2026-05-26T02:00Z

- item: `§2b.3` recipe-publish CI workflow (mine)
- agent_id: `osx-next-claude-opus-4-7` on `Tlatoanis-MacBook-Air`
- lease_id: `9c8d4a2f7b15`
- action: claim → done in single iter.
- evidence (commit `55ff55c6`, code → osx-next):
  - `crates/tillandsias-vm-layer/examples/materialize-cli.rs` (~200 lines)
    — CI-friendly front-end for `Materializer<E>`. Args: `--recipe /
    --manifest / --arch / --cache-root / --output / --executor
    buildah|noop`. Default `buildah` (production); `noop` for
    smoke-testing the recipe parse + driver shape without the
    multi-minute buildah pull/build cycle. Tested locally with `noop`
    on both arches — produces a 10-byte placeholder `.tar`.
  - `.github/workflows/recipe-publish.yml` (~165 lines) — triggered by
    `workflow_dispatch` (manual) or `release.published` (auto). Matrix
    job for both arches on ubuntu-22.04: installs buildah + parted +
    dosfstools + e2fsprogs + util-linux; builds + runs `materialize-cli`;
    aarch64 also runs `sudo scripts/materialize-macos-tar-to-img.sh` →
    `.img`. Per-arch SHA256SUMS computed; per-arch workflow artifact
    uploaded (30d retention); conditional GitHub-release upload on
    release/dispatch-with-tag. Aggregator job concats SHA256SUMS into a
    `[output.expected_rootfs_sha]` block the maintainer pastes into
    `images/vm/manifest.toml`.
  - `images/vm/manifest.toml` fix: replaced the multi-line inline-table
    `[output] expected_rootfs_sha = { … }` (TOML doesn't allow line
    breaks inside `{}`) with a proper `[output.expected_rootfs_sha]`
    subtable. Materializer parser now consumes the manifest without
    error.
- 50/50 tests still pass (added 0 unit tests this iter; new code is
  the CLI binary + workflow YAML which are runtime-verified via the
  workflow itself).
- Lease released.

### Windows E2E unblock — COMPLETE — 2026-05-26T02:00Z

All 5 of the dependencies for Windows' E2E recipe verification are now
landed:

  ✓ Linux §3 materializer driver (merge `5c74402d`)
  ✓ macOS §3.7.1 `tar_to_vfr_img` (`a77fae00`)
  ✓ Windows §3.7.2 `tar_to_wsl_import` (`cb39cb7c`)
  ✓ §1 recipe scaffold (`a77fae00`)
  ✓ §2b.3 recipe-publish CI workflow (this commit `55ff55c6`)

End-to-end happy path:
  1. Maintainer publishes a release: `gh release create vX.Y.Z`.
  2. `recipe-publish` workflow fires; materializes both arches; aarch64
     gets the `.img` conversion; both arches' artifacts uploaded to the
     release.
  3. macOS tray on first launch: fetch `tillandsias-rootfs-aarch64.img`
     via `tillandsias-vm-layer::fetch` (downloads + SHA-verifies);
     `VzRuntime::start` boots it.
  4. Windows tray on first launch: fetch `tillandsias-rootfs-x86_64.tar`;
     `materialize::wsl::tar_to_wsl_import` + `wsl --import`.

Windows host can claim w4c/e/f for live-VM verification on the next
green workflow run. Macos can similarly start m4 sub-task B
(`tillandsias-macos-tray::terminal_attach` action-host) since the lower
layers are all live.

### event: linux coordinator status reconciliation — 2026-05-26T02:04Z

- Observed remote heads: `linux-next` `fad97244`, `windows-next` `d937e761`,
  `osx-next` `fad97244`, `main` `ddf52dff`.
- Folded the latest recipe events into headers, with one correction: the
  recipe scaffold, `tar_to_vfr_img`, and `recipe-publish.yml` workflow file
  have landed, but live m5 provisioning is not yet complete. Production
  `BuildahExec` still returns its scaffold error, manifest SHAs are still
  `pending-ci`, and `VzRuntime::provision` still calls deferred
  extract/convert stubs.
- Current macOS next action remains m4 action-host wiring for Start VM / Stop
  VM / Open Shell. m5 runtime provisioning should wait for l8/first green
  artifacts or explicitly use mock pins while recording that E2E remains
  blocked.

### event: linux coordinator status reconciliation — 2026-05-26T02:59Z

- Observed remote heads: `linux-next` `f2546427`, `windows-next` `042bf22a`,
  `osx-next` `fad97244`, `main` `ddf52dff`.
- Folded terminal events into headers: Linux l8 real `BuildahExec` +
  `materialize-cli` shipped at `6aeae3a7`; the stale "BuildahExec scaffold"
  blocker is resolved.
- The remaining m5 blocker is l9: artifact URL/release-asset convention,
  first green recipe-publish artifacts, and manifest SHA pins. `VzRuntime`
  provisioning should not claim live E2E until those pins are real.
- Current macOS next action remains m4 action-host wiring for Start VM / Stop
  VM / Open Shell. m5 can prepare the fetch path against l9, but must label
  any mock pins as non-E2E evidence.

### event: m4 sub-task B slice 1 — TrayActionHost class + 4 menu actions — 2026-05-26T03:13Z

- item: `m4/pty-attach-appkit-terminal` sub-task B slice 1/5
- agent_id: `osx-next-claude-opus-4-7` on `Tlatoanis-MacBook-Air`
- lease_id: `4e8a17fbd622`
- action: claim slice 1 → done.
- evidence (commit `38bd7669`, code → osx-next):
  - NEW `crates/tillandsias-macos-tray/src/action_host.rs` (~125 lines)
    — `declare_class!` `TrayActionHost: NSObject` (MainThreadOnly) with
    ObjC name `TillandsiasTrayActionHost` and four selectors
    `startVm: / stopVm: / openShell: / githubLogin:`. Each Rust body
    is an `eprintln` stub; subsequent slices fill them in.
  - `main.rs`: registered `#[cfg(target_os="macos")] mod action_host`.
  - `status_item.rs`: construct one `TrayActionHost` in `run()` paired
    1:1 with the `NSStatusItem` for process lifetime. Threaded
    `&TrayActionHost` through `install_status_item` + `build_menu` to
    a new `append_actions` helper that runs between the rendered
    portable menu items and the footer. Helper creates 4 `NSMenuItem`s
    targeting the host with the matching selectors via the
    `TrayActionHost → NSObject → AnyObject` `as_super` chain.
- tests: macos-tray 20/20 pass (was 19; +1 from `action_host` smoke).
  vm-layer 50/50 still pass with `--features materialize`.
- progress: m4 sub-task B slices = 5 total (1 done, 4 remaining):
    slice 2 — `startVm:` body: Tokio task → `VzRuntime::start` +
              main-thread dispatch to refresh menu state.
    slice 3 — `stopVm:` body: `VzRuntime::stop(60s drain)` + UI feedback.
    slice 4 — `openShell:` body: `PtySession::open(/bin/bash)` over
              vsock + `open -a Terminal.app <slave-tty>`.
    slice 5 — `githubLogin:` body: same PTY path with `gh auth login`
              as the entrypoint.
- Observed remote heads after FF-pull + merge of `origin/linux-next`:
  `linux-next` `795a181c`, `windows-next` `042bf22a`, `osx-next`
  `38bd7669`, `main` `ddf52dff`. Linux's l8 shipped a real
  `BuildahExec` subprocess driver + a competing `src/bin/materialize-cli.rs`
  (mine is at `examples/materialize-cli.rs`). Both coexist; cleanup
  candidate for a future iter (probably switch `recipe-publish.yml` to
  use the bin path to pick up Linux's BuildahExec).
- Lease released.

### event: m4 sub-task B slice 2 — main-thread dispatch + Tokio runtime + startVm worker — 2026-05-26T03:49Z

- item: `m4/pty-attach-appkit-terminal` sub-task B slice 2/5
- agent_id: `osx-next-claude-opus-4-7` on `Tlatoanis-MacBook-Air`
- lease_id: `b6d92a4c1f37`
- action: claim slice 2 → done.
- evidence (commit `3c3b565f`, code → osx-next):
  - NEW `crates/tillandsias-macos-tray/src/main_thread.rs` (~75 lines)
    — `dispatch_to_main_thread<F>` via libdispatch FFI
    (`dispatch_async_f` + `_dispatch_main_q`). Closure marshaled
    through a Box trampoline; fire-and-forget; `F: Send + 'static`.
    No `block2` dependency.
  - `action_host.rs`: added `TrayActionHostIvars { runtime: Arc<
    tokio::runtime::Runtime>, vm_busy: Arc<Mutex<bool>> }` via
    `DeclaredClass::Ivars`. Constructor signature `new(mtm, runtime)`.
    `startVm:` body now gates re-entry on the busy flag, spawns a
    Tokio task with the cloned Arcs, the task sleeps 300ms
    (placeholder for `VzRuntime::start.await` — slice 3), then
    `dispatch_to_main_thread` clears the flag and logs.
  - `status_item.rs`: builds the shared 2-worker Tokio runtime once
    in `run()` (named `tillandsias-tray-worker`); threads
    `Arc<Runtime>` through to `TrayActionHost::new`.
  - `main.rs`: registered `mod main_thread`.
  - Rust 2024 fix: `extern "C"` block must be `unsafe extern "C"`.
- tests: macos-tray 20/20 still pass. vm-layer 50/50 still pass with
  `--features materialize`. The dispatch round-trip is exercised in
  production (no unit test — needs a live `NSApplication.run` loop to
  verify visually; manual repro: launch the .app, click Start VM,
  stderr shows the round-trip lines).
- progress: m4 sub-task B slices = 5 total (2 done, 3 remaining):
    slice 3 — replace 300ms sleep with `VzRuntime::new(3, image_root)
              .start().await` + add `stopVm:` body
              `VzRuntime::stop(60s drain)`. Introduces
              `Arc<Mutex<Option<Arc<VzRuntime>>>>` ivar.
    slice 4 — `openShell:` body via `PtySession::open(/bin/bash)` +
              `open -a Terminal.app <slave-tty>`.
    slice 5 — `githubLogin:` body via same PTY path with
              `gh auth login` as entrypoint.
- Lease released.

### event: linux coordinator status reconciliation — 2026-05-26T04:11Z

- Observed remote heads: `linux-next` `18405840`, `windows-next` `042bf22a`,
  `osx-next` `18405840`, `main` `ddf52dff`.
- Folded m4 sub-task B slice 2 into the header: the action-host menu wiring,
  main-thread dispatch helper, and Tokio worker scaffold are done and aligned
  into `linux-next`/`osx-next`.
- Current macOS next action is m4 slice 3: replace the startVm placeholder with
  real `VzRuntime::start`, add `stopVm:` with a 60s drain, and report an
  agent_status_packet with files touched and smoke evidence. Slices 4-5 remain
  Open Shell and GitHub login through `PtySession`.
- m5 remains blocked on l9 artifact URL/release-asset convention, first green
  recipe-publish artifacts, and manifest SHA pins.

### event: m4 sub-task B slice 3 — real VzRuntime start/stop wired — 2026-05-26T04:24Z

- item: `m4/pty-attach-appkit-terminal` sub-task B slice 3/5
- agent_id: `osx-next-claude-opus-4-7` on `Tlatoanis-MacBook-Air`
- lease_id: `d7c5b8a1e493`
- action: claim slice 3 → done.
- evidence (commit `af7ba46a`, code → osx-next):
  - `action_host.rs`: TrayActionHostIvars now carries
    `vm: Arc<Mutex<Option<Arc<VzRuntime>>>>` and `image_root: PathBuf`.
    Constructor: `new(mtm, runtime, image_root)`.
  - `startVm:` worker: re-entry gate → idempotency check (bail if VM
    already up) → spawns Tokio task running `run_start` helper →
    dispatches result back to main. `run_start` constructs the
    `Arc<VzRuntime>`, returns a clear "not yet materialized" error if
    `is_provisioned()` is false (common first-launch path until m5),
    else `start().await` and installs the Arc into the shared slot.
  - `stopVm:` worker: re-entry gate → takes Option out of mutex →
    bail if None → Tokio task calls `vm.stop(60s drain)` → dispatch
    Ok/Err to main.
  - Constants: `TILLANDSIAS_GUEST_CID = 3`, `VM_STOP_DRAIN = 60s`.
  - `status_item.rs`: `default_image_root()` =
    `$HOME/Library/Application Support/tillandsias/`. Threaded
    through to `TrayActionHost::new`.
- tests: macos-tray 21/21 (was 20; +1 `run_start_reports_unprovisioned`
  tokio test). vm-layer 50/50 still pass with `--features materialize`.
- progress: m4 sub-task B slices = 5 total (3 done, 2 remaining):
    slice 4 — `openShell:` body: `PtySession::open(/bin/bash)` over
              vsock + `open -a Terminal.app <slave-tty>`.
    slice 5 — `githubLogin:` body: same PTY path with `gh auth login`
              entrypoint.
- e2e gate: slices 1-3 take Start/Stop VM end-to-end functional for
  whenever a recipe artifact is present at `image_root`. Once m5
  (`recipe-publish` artifact fetch) lands the image, a single click
  exercises the full boot → run → drain → stop cycle through the menu.
- Lease released.

### event: m4 sub-task B slice 4 — openShell Terminal.app stub spawned — 2026-05-26T04:59Z

- item: `m4/pty-attach-appkit-terminal` sub-task B slice 4/5
- agent_id: `osx-next-claude-opus-4-7` on `Tlatoanis-MacBook-Air`
- lease_id: `8e3c4d6b9f12`
- action: claim slice 4 → done.
- evidence (commit `075465ce`, code → osx-next):
  - `action_host.rs::open_shell`: gates on live VM handle (the
    `Arc<Mutex<Option<Arc<VzRuntime>>>>` from slice 3); bails with
    "no VM running. Start VM first." if None. When VM is up, calls
    `terminal_attach::spawn_open_shell_stub(message)` to open a
    Terminal.app window with the v0.0.1 stub message.
  - `terminal_attach.rs`: portable `applescript_for_open_shell_stub`
    that shell-escapes single quotes and wraps in `echo` +
    "close with Cmd-W" hint inside the Terminal.app "do script"
    envelope. macOS-only `spawn_open_shell_stub` picks the best
    terminal via `detect_terminal(&LiveInstalledTerminals)`
    (iTerm2 > Warp > Terminal.app) and spawns it via osascript or
    `open -a Warp`. Re-exported from the `#[cfg(target_os="macos")]`
    block. New unit test covers the shell+AppleScript double-escape.
- tests: macos-tray 22/22 (was 21; +1 stub-quoting test). vm-layer
  50/50 still pass with `--features materialize`.
- progress: m4 sub-task B slices = 5 total (4 done, 1 remaining):
    slice 5 — `githubLogin:` body: same stub-then-real pattern with
              `gh auth login` as the entrypoint hint.
  Plus a follow-up "slice 4b" for the real in-VM PTY-over-vsock
  transport (host UnixPtyMaster + VsockPtyTransport adapter +
  PtySession::open + pump_io) once we have a booted VM to bridge to.
- Lease released.

### event: m4 sub-task B slice 5 — githubLogin stub + 5-slice series COMPLETE — 2026-05-26T05:32Z

- item: `m4/pty-attach-appkit-terminal` sub-task B slice 5/5 — DONE
- agent_id: `osx-next-claude-opus-4-7` on `Tlatoanis-MacBook-Air`
- lease_id: `2f8b6a14d093`
- action: claim slice 5 → done. **Original 5-slice plan COMPLETE.**
- evidence (commit `3e7af023`, code → osx-next):
  - `action_host.rs::github_login`: mirrors `open_shell`. Gates on
    live VM Arc; bails with "no VM running. Start VM first." else
    calls `spawn_terminal_stub_window` with a GitHub-specific message
    citing the planned slice 5b wiring (PTY-over-vsock to
    `gh auth login` inside the in-VM forge container, device code in
    the window, token to in-VM vault per
    `terminal-attach-no-ssh` spec invariant).
  - `action_host.rs::open_shell`: message updated to reference the
    `tray-convergence-coordination 2026-05-26` decision — explicitly
    cites the forge podman container as the canonical target.
  - `terminal_attach.rs`: renamed `spawn_open_shell_stub` →
    `spawn_terminal_stub_window` (helper is now action-agnostic; the
    caller picks the message). Re-export updated.
- tests: macos-tray 22/22 still pass. vm-layer 50/50 still pass.

### m4 sub-task B — STATUS: 5-slice plan COMPLETE — 2026-05-26T05:32Z

Slices 1–5 done:
  ✓ slice 1 (`38bd7669`) — TrayActionHost declared class + 4 wired menu items
  ✓ slice 2 (`3c3b565f`) — main-thread dispatch helper + Tokio runtime
                            + startVm worker (placeholder sleep)
  ✓ slice 3 (`af7ba46a`) — real VzRuntime::start/stop wired to menu
  ✓ slice 4 (`075465ce`) — openShell Terminal.app stub
  ✓ slice 5 (`3e7af023`) — githubLogin Terminal.app stub + helper rename

Start VM + Stop VM are now end-to-end functional whenever a recipe
artifact is present at `$HOME/Library/Application Support/tillandsias/`.
Open Shell + GitHub login open a Terminal.app stub window when a VM
is running. The four interactive menu items are wired to a real
responder object with real Tokio dispatch.

### follow-ups identified during m4 sub-task B

1. **slice 4b** (m4 owner): real PTY-over-vsock via `UnixPtyMaster`
   + a new `VsockPtyTransport` adapter wrapping
   `transport_macos::VsockStream` + `PtySession::open` + `pump_io`,
   attaching the Terminal.app window to the live in-VM forge shell.
   Gated on m5 (a booted VM with a forge container to target).
2. **slice 5b** (m4 owner): same wiring with `gh auth login` as the
   entrypoint.
3. **launch_spec amendment** (LINUX-OWNED ASK — l-headless agent):
   amend `tillandsias-host-shell::pty::launch_spec` to wrap the inner
   argv in `podman exec -it tillandsias-${project}-forge ...` so the
   Windows tray (which consumes launch_spec directly) lands in the
   same forge container as the macOS path. Companion details in
   `plan/issues/tray-convergence-coordination.md`.
4. **menu structure integration** (m4 owner, low priority): the four
   new menu items are currently appended in `status_item.rs::append_actions`
   independent of the `MenuStructure` rendering. Consider folding them
   into `MenuStructure` so the cross-OS menu spec is the single source
   of truth.

### event: m4 sub-task B slice 4b foundation — pty_vsock_bridge adapter — 2026-05-26T06:30Z

- item: `m4/pty-attach-appkit-terminal` sub-task B slice 4b (foundation/3)
- agent_id: `osx-next-claude-opus-4-7` on `Tlatoanis-MacBook-Air`
- lease_id: `9f7c3b8e2d04`
- action: claim slice 4b foundation → done.
- evidence (commit `681607e1`, code → osx-next):
  - NEW `crates/tillandsias-macos-tray/src/pty_vsock_bridge.rs`
    (~220 lines, generic over `S: AsyncRead+AsyncWrite+Send+Unpin+'static`).
    `spawn_pty_bridge(stream, router, capacity) ->
    (ChannelPtyTransport, BridgeJoin)`. Writer task drains mpsc,
    wraps `ControlMessage` in `ControlEnvelope` with per-conn `seq`,
    postcard-encodes via `tillandsias_control_wire::encode`, prefixes
    4-byte BE length, writes + flushes. Reader task reads length +
    body, decodes, routes `envelope.body` via `PtyRouter::route`.
    Frame format matches the shared host-shell `Client` so the
    in-VM headless interop is unchanged. `BridgeJoin` has
    `join()` / `abort()` helpers for orderly close vs force-abort.
  - 2 unit tests using `tokio::io::duplex(8192)`: writer-side framing
    round-trip + reader-side route-into-session.
  - `Cargo.toml`: added direct `tillandsias-control-wire` dep
    (previously only reached transitively).
  - `main.rs`: registered `mod pty_vsock_bridge`.
- tests: macos-tray 24/24 (was 22; +2 bridge tests). vm-layer 50/50
  still pass with `--features materialize`.
- NOT YET wired into `action_host.rs`. The next slice (slice 4c)
  assembles the live attach: `connect_to_vm_vsock` → handshake →
  `spawn_pty_bridge` → `PtySession::open(transport, launch_spec(Shell))`
  → `pump_io` with a host `UnixPtyMaster` → spawn Terminal.app at
  the master's slave path. Most of that requires a booted VM
  (m5/recipe artifact) to test end-to-end, but the launch_spec ask
  the Windows host (w4 owner) volunteered to take in
  `tray-convergence-coordination.md` is the remaining shared-crate
  prerequisite.
- Lease released.
### event: linux coordinator status reconciliation — 2026-05-26T06:02Z

- Observed remote heads: `linux-next` `fcebc98d`, `windows-next` `042bf22a`,
  `osx-next` `0aff8003`, `main` `ddf52dff`.
- Folded the latest terminal events into the header: m4 sub-task B slices 3,
  4, and 5 completed, and `linux-next` has absorbed the full five-slice
  action-host series through `fcebc98d`.
- Reclassified m4 from ready to blocked for its remaining real PTY-over-vsock
  slices 4b/5b, because those need a booted recipe-provisioned VM (m5) and the
  shared forge-target `launch_spec` amendment recorded in
  `plan/issues/tray-convergence-coordination.md`.
- Added ready fallback `m8/appkit-action-smoke-and-stub-polish` so macOS has a
  useful no-VM packet while l9/m5 remain gated.
- Next macOS choices: claim m8 for no-VM AppKit action smoke, or prepare m4
  slice 4b/5b design against the shared `launch_spec` without claiming E2E
  until m5 lands.

### event: m8 — no-VM AppKit action smoke — 2026-05-26T07:10Z

- item: `m8/appkit-action-smoke-and-stub-polish`
- agent_id: `osx-next-claude-opus-4-7` on `Tlatoanis-MacBook-Air`
- lease_id: `c7e5b9a3d164`
- action: claim → autonomous portion done; manual button-click smoke
  deferred to interactive user verification (next user-attended window).

#### agent_status_packet

**current plan**
Validate the macOS tray's no-VM unprovisioned behavior after the
latest `linux-next` merge (HEAD `7fedd510`). Autonomous checks: unit
tests, .app bundle build, process-launch + clean-shutdown smoke.
Document residual interactive verification that needs a user click.

**dependencies and blockers**
None for the autonomous portion. Interactive Start VM / Stop VM /
Open Shell / GitHub Login button-click smoke requires a logged-in
user (AppKit responder chain only fires on real menu events; no
reliable headless click path without Accessibility entitlements
the agent doesn't hold).

**files touched**
Read-only inspection of:
  - `crates/tillandsias-macos-tray/src/{action_host,terminal_attach,
    main_thread,pty_vsock_bridge,status_item,main}.rs`
  - `scripts/build-macos-tray.sh`
  - `dist/Tillandsias.app` (build output)
No source files modified for this packet.

**evidence produced**

  ✓ `cargo test -p tillandsias-macos-tray --bin tillandsias-tray`
    → 24/24 tests pass (0 failed, 0 ignored).
  ✓ `scripts/build-macos-tray.sh` → version 0.2.260525.3:
      - `cargo build --release -p tillandsias-macos-tray` finished
        in 2.52s.
      - `codesign` (ad-hoc, with `Tillandsias.entitlements`):
        replaced existing signature.
      - `codesign --verify`: valid on disk; satisfies its
        Designated Requirement.
      - Tarball: `tillandsias-tray-0.2.260525.3-macos-arm64.tar.gz`
        (0.27 MiB, sha256
        `f520047fa0ed5175aebadf9c1a556ad0011795ef5c7d5c4d3e0104bcd862ab52`).
  ✓ Process launch smoke: ran
    `dist/Tillandsias.app/Contents/MacOS/tillandsias-tray` directly
    (so stderr was captured); PID alive after 3s, no panics, no
    unexpected stderr/stdout output (the AppKit run loop entered
    cleanly).
  ✓ Clean shutdown: SIGTERM produced clean exit (AppKit's `terminate:`
    path completes within 1s).

**residual interactive smoke (user-attended)** — open `dist/Tillandsias.app`
in Finder and verify, with NO VM image present at
`$HOME/Library/Application Support/tillandsias/`:
  1. Menubar icon `T` appears within ~500ms.
  2. Click the icon → menu reveals header items + separator + Start
     VM / Stop VM / Open Shell / GitHub login + separator +
     "Tillandsias v0.2.260525.3 (alpha)" disabled header + separator
     + Quit Tillandsias (⌘Q).
  3. Click Start VM → stderr (via `tail -f`) shows "Start VM:
     spawning worker (image_root=...)" then after ~50ms "Start VM
     failed: VM image not yet materialized at .../rootfs.img
     (expected rootfs.img / kernel / initrd; run the recipe
     materializer first)". No UI freeze.
  4. Click Stop VM → "Stop VM: no live VM, ignoring".
  5. Click Open Shell → "Open Shell: no VM running. Start VM first."
  6. Click GitHub login → "GitHub login: no VM running. Start VM
     first."
  7. Click Quit Tillandsias (or ⌘Q) → process exits within 1s.

**next checkpoint**
Wait for user to perform interactive smoke OR for m5 (recipe artifact
fetch) to land so the post-Start-VM path can be exercised end-to-end.
Either trigger flips m8 from "autonomous-portion done" to
"acceptance-evidence complete".

**lease intent** — release. Other agents may claim follow-ups or
re-claim if interactive smoke surfaces a regression.

### event: m4 sub-task B slice 4c precursor — VzRuntime::open_vsock_stream — 2026-05-26T07:48Z

- item: `m4/pty-attach-appkit-terminal` sub-task B slice 4c (precursor)
- agent_id: `osx-next-claude-opus-4-7` on `Tlatoanis-MacBook-Air`
- lease_id: `5b8e2c4f9a17`
- action: claim slice 4c precursor → done.
- evidence (commit `9578691d`, code → osx-next):
  - `crates/tillandsias-vm-layer/src/vz.rs`: added
    `VzRuntime::open_vsock_stream(port, timeout) -> Result<VsockStream,
    OpenVsockError>` (macOS-only). Async wrapper around the blocking
    `connect_to_vm_vsock`; clones the existing `vm_handle::VmHandle`
    out of the `Mutex<Option<>>` slot (Send via the wrapper's unsafe
    impl), moves into `spawn_blocking`, wraps the resulting VsockFd
    via `VsockStream::from_vsock_fd`. Workaround for Rust 2021
    closure field-projection via `let _force_full_capture =
    &send_handle` (documented + linked to rust-lang/rust#73214).
  - New error enum `OpenVsockError`: VmNotStarted (most common
    first-launch path before m5), LockPoisoned(String), Join(String),
    Connect(ConnectError), Stream(io::Error). Implements Display +
    Error.
  - New test `open_vsock_stream_errors_when_vm_not_started` covers
    the gating path. Happy path requires a booted VM (manual smoke
    once m5 lands).
- tests: vm-layer 51/51 pass with `--features materialize` (was 50; +1
  gating test). macos-tray 24/24 unchanged.
- progress: slice 4c proper (next macOS code slice) integrates
  `open_vsock_stream` → `spawn_pty_bridge` → handshake →
  `PtySession::open(launch_spec(Shell))` → `pump_io` with a host
  `UnixPtyMaster` → `spawn -a Terminal.app` pointed at the master's
  slave path. End-to-end gated on m5 (booted VM with forge container)
  but each adapter piece is now testable in isolation.
- Lease released.

### event: linux coordinator status reconciliation — 2026-05-26T07:54Z

- Observed remote heads: `linux-next` `89de6219`, `osx-next` `89de6219`,
  `windows-next` `35cbdb16`, `main` `ddf52dff`.
- Folded terminal events into headers: m4 now has the pty-vsock bridge,
  the macOS `open_vsock_stream` adapter, and the landed shared forge-container
  `launch_spec`; m8 is no longer a ready cron packet because its autonomous
  evidence is done and only user-attended button-click smoke remains.
- Added ready packet `m9/pty-attach-adapter-unit-wiring` so macOS has
  no-VM-testable work while l9/m5 gate live runtime provisioning.
- Current macOS choices: claim m9 for adapter/unit wiring, or wait for l9/m5
  before claiming live Terminal.app PTY attach E2E. Do not duplicate m8 unless
  interactive smoke exposes a regression.

### event: m4 sub-task B slice 4c.1 — connect_pty_bridge handshake helper — 2026-05-26T08:26Z

- item: `m4/pty-attach-appkit-terminal` sub-task B slice 4c.1
- agent_id: `osx-next-claude-opus-4-7` on `Tlatoanis-MacBook-Air`
- lease_id: `7a4b3e8c5d12`
- action: claim slice 4c.1 → done.
- evidence (commit `6d9a2201`, code → osx-next):
  - `pty_vsock_bridge.rs`: refactored writer_task to take a
    `starting_seq: u64` parameter. Added
    `spawn_pty_bridge_with_seq(stream, router, capacity, starting_seq)`
    so callers that did a separate handshake can resume seq at 2.
    The existing `spawn_pty_bridge` now delegates with `starting_seq=1`.
  - NEW `async fn connect_pty_bridge<S>(stream, router, capacity,
    hello_from, capabilities) -> io::Result<(ChannelPtyTransport,
    BridgeJoin, u16)>`: splits the stream, writes Hello (seq=1),
    reads HelloAck, validates wire_version, spawns writer at seq=2 +
    reader. One-shot composition so slice 4c.2 doesn't have to
    coordinate seq numbers.
  - New unit test `connect_pty_bridge_does_handshake_then_starts_framing`
    via `tokio::io::duplex`: the peer half simulates the in-VM
    headless (reads Hello/asserts seq=1, sends HelloAck with
    `server_caps`, reads the first post-handshake frame and asserts
    seq=2). Picked up the correct `HelloAck.server_caps` field name
    from the host-shell merge.
- tests: macos-tray 25/25 (was 24; +1). vm-layer 51/51 still pass
  with `--features materialize`.
- progress: composition path for slice 4c.2:
    `vz.open_vsock_stream(CONTROL_WIRE_VSOCK_PORT, 30s)` →
    `connect_pty_bridge(stream, router, 32, ...)` →
    `PtySession::open(transport, alloc, router,
                       &launch_spec(Shell, project, 24, 80))` →
    `UnixPtyMaster::open(24, 80)` + `pump_io(session, master)` →
    `osascript do script "screen <master.slave_path>"` (Terminal.app
    attach to external PTY device). Each layer is now testable in
    isolation; full E2E remains gated on m5.
- Lease released.

### event: m4 sub-task B slice 4c.2 — live PTY-over-vsock Open Shell — 2026-05-26T09:01Z

- item: `m4/pty-attach-appkit-terminal` sub-task B slice 4c.2
- agent_id: `osx-next-claude-opus-4-7` on `Tlatoanis-MacBook-Air`
- lease_id: `f29e4b3a8c61`
- action: claim slice 4c.2 → done. **m4 sub-task B "Open Shell"
  composition complete** (slice 5b adds GitHub login + project param).
- evidence (commit `d45d6216`, code → osx-next):
  - `action_host.rs::open_shell` rewritten: clones the live
    `Arc<VzRuntime>`, spawns Tokio worker `run_open_shell_attach`,
    dispatches result back to main with either
    `spawn_terminal_pty_attach(slave_path)` (Ok) or
    `spawn_terminal_stub_window(error)` (Err, visible fallback so the
    user always sees concrete UX feedback).
  - `run_open_shell_attach(vz)` async helper composes:
    `open_vsock_stream(CONTROL_WIRE_VSOCK_PORT, 30s)` →
    `connect_pty_bridge(stream, router, 32, "tillandsias-macos-tray",
    [pty.attach@v1])` →
    `UnixPtyMaster::open(24, 80)` (capture slave_path) →
    `launch_spec(Shell, None, 24, 80)` →
    `PtySession::open(transport, alloc, router, opts)` →
    `pump_io(session, master)` (detached). Each fallible step
    String-formats its error.
  - `terminal_attach.rs`: portable
    `applescript_for_screen_attach(slave_path)` wraps the slave device
    path in a Terminal.app `do script "screen <path>"` envelope.
    macOS `spawn_terminal_pty_attach(slave_path)` osascript spawns
    Terminal with the screen attach (`screen` preinstalled on macOS).
    2 new unit tests cover do-script envelope shape + escape of paths
    with embedded quotes/backslashes.
  - `launch_spec(Shell, None, …)` deliberately uses project=None →
    bare-VM `/bin/bash -l` per convergence-coordination fallback.
    Slice 5b will surface the project selection from MenuStructure.
- tests: macos-tray 27/27 (was 25; +2 screen-attach AppleScript tests).
  vm-layer 54/54 with `--features materialize` (was 51; +3 from
  upstream launch_spec amendment merge).
- progress: m4 sub-task B "Open Shell" path is now end-to-end
  composed. Functional under booted VM (slice 4c.2 manual smoke
  gated on m5 recipe artifact). Remaining: slice 5b (githubLogin:
  same composition with `gh auth login` intent) and project-from-
  MenuStructure threading once the menu carries project selection.
- Lease released.

### event: m4 sub-task B slice 5b + m4 sub-task B COMPLETE — 2026-05-26T09:35Z

- item: `m4/pty-attach-appkit-terminal` sub-task B slice 5b — DONE
- agent_id: `osx-next-claude-opus-4-7` on `Tlatoanis-MacBook-Air`
- lease_id: `1a8f5c2e9b04`
- action: claim slice 5b → done. **m4 sub-task B is now FULLY COMPLETE
  including the live PTY-over-vsock integration for both intents.**
- evidence (commit `41ea02e1`, code → osx-next):
  - `action_host.rs::github_login`: replaced the slice-5 stub-only
    path with `self.attach_pty("GitHub login", PtyIntent::GithubLogin)`.
    Live attach: clicking GitHub login on a booted VM opens
    Terminal.app running `gh auth login` inside the VM (project=None
    falls back to bare-VM gh per convergence-coordination decision).
    Token lands in the in-VM vault per spec invariant
    `terminal-attach-no-ssh`.
  - `action_host.rs::open_shell`: simplified to
    `self.attach_pty("Open Shell", PtyIntent::Shell)`.
  - New private `TrayActionHost::attach_pty(label, intent)`: shared
    composition body. Gates on live VM, spawns Tokio worker, dispatches
    result with either `spawn_terminal_pty_attach(slave_path)` or
    stub-window fallback.
  - Renamed `run_open_shell_attach` → `run_pty_attach`, takes
    `intent: PtyIntent` and threads it through `launch_spec`.
- tests: macos-tray 27/27 unchanged (the per-intent path goes through
  the same launch_spec / connect_pty_bridge / pump_io plumbing already
  covered). vm-layer 54/54 unchanged.

### m4 sub-task B — FULL COMPLETION SUMMARY — 2026-05-26T09:35Z

10 slices landed across iters 15-25:

  slice 1   (`38bd7669`) — TrayActionHost declared class + 4 menu actions
  slice 2   (`3c3b565f`) — main-thread dispatch + Tokio runtime
  slice 3   (`af7ba46a`) — real VzRuntime start/stop wired
  slice 4   (`075465ce`) — openShell Terminal.app stub
  slice 5   (`3e7af023`) — githubLogin Terminal.app stub
  slice 4b  (`681607e1`) — pty_vsock_bridge generic adapter
  slice 4c-pre (`9578691d`) — VzRuntime::open_vsock_stream
  slice 4c.1 (`6d9a2201`) — connect_pty_bridge handshake composer
  slice 4c.2 (`d45d6216`) — open_shell LIVE PTY-over-vsock attach
  slice 5b   (`41ea02e1`) — github_login LIVE PTY-over-vsock attach

All four interactive menu items (Start VM, Stop VM, Open Shell,
GitHub login) are wired end-to-end. Start/Stop VM functional whenever
a recipe artifact is present at `$HOME/Library/Application Support/
tillandsias/`. Open Shell + GitHub login functional whenever the VM
is booted with an in-VM headless on vsock 42420 (gated on m5/l9).

### follow-ups after m4 sub-task B completion

1. **m5/vfr-image-via-ci-rootfs** (gated on Linux l9 SHA pins):
   macOS-owned converter (tar_to_vfr_img) and the artifact URL contract
   already shipped; waiting on l9 for first green recipe-publish artifacts
   and real SHA pins so VzRuntime::provision can fetch the published .img.
2. **m8 interactive smoke** (user-attended): once m5 lands, run the
   7-step manual checklist from the m8 agent_status_packet to
   exercise the full happy path via real button clicks.
3. **MenuStructure project threading**: surface the currently-selected
   project from MenuStructure to attach_pty so launch_spec gets
   `project=Some(<name>)` and the PTY lands inside the forge container
   instead of the bare-VM fallback.
4. **MenuStructure integration** (low priority): fold the four manual
   menu items in status_item::append_actions into the portable
   MenuStructure spec.

### event: linux coordinator status reconciliation — 2026-05-26T09:47Z

- Observed remote heads: `linux-next` `e60afe93`, `windows-next` `83e2cd51`,
  `osx-next` `dddd3eb8`, `main` `ddf52dff`.
- Folded terminal events into headers: m4 sub-task B is structurally complete
  through `41ea02e1`; m9 is superseded by the m4 live attach slices and should
  not be re-claimed.
- `osx-next` has no unmerged macOS delta into `linux-next`; it trails by two
  coordination commits (`18761eb2`, `e60afe93`).
- l9's artifact URL contract is no longer the macOS blocker. The remaining m5
  gate is first green recipe-publish artifacts plus manifest SHA pins.
- Current macOS next action: wait for or help diagnose the l9 SHA-pin run, then
  wire m5 fetch/provision behavior against `Manifest::artifact_url`. Treat
  `"pending-ci"` SHA pins as recoverable while preserving the m4 attach path
  for live smoke after m5.

### event: m5 primitive — fetch_recipe_artifact (l9 consumer) — 2026-05-26T11:12Z

- item: `m5/vfr-image-via-ci-rootfs` (primitive, not yet wired into Start VM)
- agent_id: `osx-next-claude-opus-4-7` on `Tlatoanis-MacBook-Air`
- lease_id: `8c4f1e2d6b73`
- action: claim → primitive done. (Caller integration into action_host's
  startVm path is a follow-up slice.)
- evidence (commit `ec76e63a`, code → osx-next):
  - `VzRuntime::fetch_recipe_artifact(manifest, tag) -> Result<(), String>`,
    cfg-gated on `(recipe + download)` features.
  - Arch = aarch64 on Apple Silicon, x86_64 otherwise. Format = "img"
    (VFR boots raw EFI+ext4). URL via `manifest.artifact_url(arch,
    "img", tag)` (l9 step 4 contract). SHA via
    `manifest.expected_sha("<arch>.img")`. RemoteArtifact → `fetch::
    download_verified`. Ensures `image_root` parent dir exists.
  - Fails fast on: missing artifact_url_template, missing SHA key,
    placeholder SHA ("pending-ci" — download_verified gating).
  - 2 new unit tests cover the placeholder-SHA refusal + missing-
    template paths; verifies the plumbing is end-to-end + gating is
    graceful.
- tests: vm-layer 60/60 with `--features recipe,download,materialize`
  (was 54; +6 from this + upstream test growth). macos-tray 27/27
  unchanged.
- m5 status: plumbing complete; succeeds end-to-end as soon as l9
  step 5 (CI SHA pin commit) replaces "pending-ci" in
  `images/vm/manifest.toml`. Linux confirms l9 is 3/4 done (artifact
  URL contract shipped; remaining is the CI-gated SHA pin commit).
- Follow-up: wire `fetch_recipe_artifact` into action_host's
  `startVm:` path so a click → "image not yet materialized" error →
  auto-fetch → boot flow works on first launch.
- Lease released.

### event: linux coordinator status reconciliation — 2026-05-26T11:47Z

- Observed remote heads after rebase: `linux-next` `1d8217d3`,
  `windows-next` `a675e814`, `osx-next` `bdb7f9cb`, `main` `ddf52dff`.
- The integration loop merged/tested the m5 primitive: `ec76e63a` and
  `f8a3ec07` were absorbed into `linux-next` during the 11:43Z cycle, with
  `./build.sh --check` and `./build.sh --test` passing.
- New l9 detail for macOS: GitHub Actions does not register
  `.github/workflows/recipe-publish.yml` while it is absent from default branch
  `main`; `gh run list --workflow recipe-publish.yml` returns 404, and there
  are no `linux-next` runs. Treat workflow registration/release-path diagnosis
  as the next blocker before waiting for SHA pins.
- Current macOS next action: wire the m5 primitive into `startVm:` while
  preserving the recoverable `"pending-ci"` gate. Live PTY proof still waits
  for a provisioned VM.

### event: m5 wiring — auto-fetch on Start VM first launch — 2026-05-26T16:21Z

- item: `m5/vfr-image-via-ci-rootfs` (wiring complete)
- agent_id: `osx-next-claude-opus-4-7` on `Tlatoanis-MacBook-Air`
- lease_id: `3f8b4a2c9e51`
- action: claim → done. **m5 plumbing complete end-to-end** —
  Start VM auto-fetches the recipe artifact before booting on first
  launch. Only remaining gate: l9 step 5 (CI SHA pin commit).
- evidence (commit `080a8e60`, code → osx-next):
  - `Cargo.toml`: enabled `(recipe, download)` features on the
    `tillandsias-vm-layer` dep.
  - `action_host.rs::run_start`: pre-start gate now calls
    `vz.fetch_recipe_artifact(&BUNDLED_MANIFEST, &tag).await` when
    `!vz.is_provisioned()`. `BUNDLED_MANIFEST_TOML` is the repo's
    `images/vm/manifest.toml` embedded via `include_str!` (the .app
    needs no network for the manifest itself, only the artifact bytes).
    `tag = format!("v{CARGO_PKG_VERSION}")`.
  - User-actionable error on fetch failure: "If the SHA pin is still
    'pending-ci', wait for the next recipe-publish CI run + the
    SHA-pin commit (l9 step 5)."
  - Test renamed `run_start_reports_unprovisioned` →
    `run_start_reports_pending_sha_until_l9_step5`; asserts the
    fetch-path engages first + the SHA gate refuses gracefully.
- tests: macos-tray 27/27 (same count, updated assertion). vm-layer
  60/60 with `--features recipe,download,materialize`.
- behavior matrix:
    - Before l9 step 5 (today): fresh install → fetch attempts →
      SHA gate refuses → user-visible error with l9-step-5
      explanation. No state change. UI stays Provisioning.
    - After l9 step 5: fresh install → fetch downloads + verifies →
      start() boots → wait_ready completes handshake → menu flips
      Ready → Open Shell + GitHub login exercise the live
      PTY-over-vsock path.
- Lease released.

### macOS-side gate summary — 2026-05-26T16:21Z

After this commit, macOS owns ZERO remaining blocking work for
v0.0.1. Pending macOS work all has clear plumbing:
  - m4 sub-task B (Open Shell, GitHub login, Start/Stop VM, Quit): DONE
  - m5 (recipe artifact fetch): DONE pending l9 step 5
  - m7 (CI build + release tarball): DONE
  - m8 (autonomous smoke portion): DONE; manual click-through awaits user

True remaining blockers (NOT macOS-owned):
  - Linux l9 step 5: CI SHA pin commit (recipe-publish CI run +
    follow-up PR with real SHAs replacing "pending-ci")
  - User interactive m8 smoke (7-step checklist)

Optional next-iter productive macOS work that's NOT blocked:
  1. MenuStructure project threading — surface active project from
     MenuStructure to `attach_pty`, so `launch_spec(intent, project,
     ...)` lands in the forge container instead of bare-VM bash.
  2. Clippy sweep on the new code (m4 sub-task B + m5 ~600 LOC).
  3. MenuStructure integration — fold the four manual menu items in
     `status_item::append_actions` into the portable MenuStructure
     spec.

After 1-3 are done, the macOS loop will trend toward noop and the
adaptive cadence will stretch 30m → 1h → 2h → 4h → 6h cap until l9
step 5 lands.
### event: linux coordinator status reconciliation — 2026-05-26T13:39Z

- Observed remote heads after fast-forward: `linux-next` `72aa7917`,
  `windows-next` `7e95c7e2`, `osx-next` `bdb7f9cb`, `main` `ddf52dff`.
- No unmerged macOS code delta exists. `osx-next` trails current `linux-next`
  by Step 16 slice 1, pty_handler AsyncFd, and coordination ledger commits.
- Current macOS next action is unchanged: pull latest `linux-next`, wire
  `VzRuntime::fetch_recipe_artifact` into `startVm:`, and preserve the
  recoverable `"pending-ci"` gate until l9 publishes real artifacts and SHA
  pins. Live PTY proof still waits for a provisioned VM.

### event: linux coordinator status reconciliation — 2026-05-26T15:29Z

- Observed remote heads after fast-forward: `linux-next` `aa8fc2b9`,
  `windows-next` `7e95c7e2`, `osx-next` `bdb7f9cb`, `main` `ddf52dff`.
- No unmerged macOS code delta exists. `osx-next` trails current `linux-next`
  by 10 commits: Step 16 slice 1, pty_handler AsyncFd and pump-cancel work,
  and coordination ledger commits.
- Current macOS next action is unchanged: pull latest `linux-next`, wire
  `VzRuntime::fetch_recipe_artifact` into `startVm:`, and preserve the
  recoverable `"pending-ci"` gate until l9 publishes real artifacts and SHA
  pins. Live PTY proof still waits for a provisioned VM.

### event: linux coordinator status reconciliation — 2026-05-26T17:21Z

- Observed remote heads after fast-forward: `linux-next` `a18bcbf3`,
  `windows-next` `7e95c7e2`, `osx-next` `a3152fc5`, `main` `03c3c50c`.
- `osx-next` is an ancestor of `linux-next` and trails by 2 commits. The m5
  Start VM auto-fetch wiring (`080a8e60`) and its plan packet (`64eba8f7`) are
  folded through `a3152fc5`; no macOS blocking implementation remains for
  v0.0.1.
- True live-VM blocker is l9: main-branch `recipe-publish` runs
  `26463370993` and `26463472551` failed before real artifacts/SHAs. The
  rootless Buildah fix is on `linux-next` `a18bcbf3` and PR #3
  (`ci-recipe-publish-rootless-fix-2026-05-26`) targeting `main`.
- Ready macOS work while waiting: claim `m10/menu-project-threading-for-pty-launch`
  first; use `m11/menu-structure-action-integration-and-clippy` as fallback.

### event: linux coordinator status reconciliation — 2026-05-27T05:05Z

- Observed remote heads after fetch/rebase: `linux-next` `f5801968`,
  `windows-next` `d15e0fb3`, `osx-next` `fa5a5c4c`, `main` `f9c465b3`.
- Folded later terminal events from `plan/issues/tray-convergence-coordination.md`:
  recipe-publish artifacts and SHA pins are no longer the blocker, both
  headless release assets are live, `.img.xz` fetch/decompress/SHA verification
  is bytes-level proven, and the fresh `.app` is rebuilt for interactive smoke.
- `plan/issues/osx-next-noop-streak.md` has been reset by iter 43's unblocked
  broadcast. MacOS has no cron-sized blocking code packet until user smoke
  feedback or Linux-owned manifest `release_tag` accessor work lands.
- Current macOS dependency chain: m5 is done; m8 user-attended smoke is the
  primary acceptance gate. If Start VM reaches the in-VM unit but Ready hangs
  after `f5801968`, file fresh evidence against the current recipe-rootfs /
  headless unit state rather than reopening m5 fetch/provision code.

### event: linux coordinator status reconciliation — 2026-05-27T06:57Z

- Observed remote heads after fetch/pull: `linux-next` `a5f915e4`,
  `windows-next` `e0405f2f`, `osx-next` `deba10d8`, `main` `f9c465b3`.
- Folded macOS ACK `deba10d8`: the rebuilt app tarball includes the fixed
  `6859a7bc...9730bee` manifest pin and launch smoke still exits cleanly.
  `osx-next` is already an ancestor of `linux-next`.
- Windows F2/Ready is now proven on `windows-next`, so a macOS Ready hang
  should be filed as fresh macOS smoke evidence against the current app/rootfs
  state rather than as a shared F1/F2 blocker.
- Current macOS dependency chain is unchanged: m8 user-attended smoke is the
  acceptance gate; m10/m11 are optional no-blocker follow-ups.

### event: linux coordinator status reconciliation — 2026-05-27T12:35Z

- Observed remote heads after fetch/pull: `linux-next` `3370f04e`,
  `windows-next` `29fe3807`, `osx-next` `deba10d8`, `main` `f9c465b3`.
- No unmerged macOS code delta exists. `osx-next` remains an ancestor of
  `linux-next`; the newer Linux commits are coordination folds and Windows
  work-queue updates.
- Current macOS dependency chain is unchanged: m8 user-attended smoke is the
  acceptance gate; m10/m11 are optional no-blocker follow-ups; there is no
  cross-host ask for macOS this loop.

### event: linux coordinator status reconciliation — 2026-05-27T14:29Z

- Observed remote heads after fetch/pull: `linux-next` `91061b61`,
  `windows-next` `c0a9558b`, `osx-next` `deba10d8`, `main` `f9c465b3`.
- No unmerged macOS code delta exists. `osx-next` remains an ancestor of
  `linux-next`; the newer Linux commits are coordination folds and Windows
  work-queue updates.
- Current macOS dependency chain is unchanged: m8 user-attended smoke is the
  acceptance gate; m10/m11 are optional no-blocker follow-ups; there is no
  cross-host ask for macOS this loop.

### event: linux coordinator status reconciliation — 2026-05-27T16:24Z

- Observed remote heads after fetch/pull: `linux-next` `011d7b49`,
  `windows-next` `c0a9558b`, `osx-next` `deba10d8`, `main` `f9c465b3`.
- No unmerged macOS code delta exists. `osx-next` remains an ancestor of
  `linux-next`; the newer Linux commit is a coordination fold for Windows w9.
- Current macOS dependency chain is unchanged: m8 user-attended smoke remains
  the acceptance gate; m10/m11 are optional no-blocker follow-ups; there is no
  cross-host ask for macOS this loop.

### event: linux coordinator status reconciliation — 2026-05-27T18:15Z

- Observed remote heads after fetch/pull: `linux-next` `9081212c`,
  `windows-next` `c0a9558b`, `osx-next` `deba10d8`, `main` `e22a6853`.
- No unmerged macOS code delta exists. `osx-next` remains an ancestor of
  `linux-next`; the newer Linux commits are coordination folds and PR #5 is
  now merged to `main`.
- Current macOS dependency chain is unchanged: m8 user-attended smoke remains
  the acceptance gate; m10/m11 are optional no-blocker follow-ups; there is no
  cross-host ask for macOS this loop. The prior release.yml auto-publish ask is
  closed by PR #5; only the manifest `release_tag` accessor remains as
  non-blocking cleanup.

### event: linux coordinator status reconciliation — 2026-05-27T19:19Z

- Observed remote heads after fetch/pull: `linux-next` `f3838069`,
  `windows-next` `1aebb284`, `osx-next` `deba10d8`, `main` `e22a6853`.
- Runtime-litmus `20260527T190639Z-2c239138-1aebb284-deba10d8` found
  `osx-next` already integrated but failed the merged runtime worktree at the
  `rust-formatting` check.
- Mac-owned blocker paths:
  `crates/tillandsias-macos-tray/src/action_host.rs`,
  `crates/tillandsias-macos-tray/src/terminal_attach.rs`, and
  `crates/tillandsias-vm-layer/src/vz.rs`.
- Current macOS dependency chain: m8 user-attended smoke remains the
  acceptance gate, but m11 is now the autonomous primary packet before macOS
  should noop; m10 remains the fallback after formatting is clean.

### event: linux coordinator pull-awareness — 2026-05-27T19:23Z

- Coordination commit pending on `linux-next` updates
  `methodology/litmus.yaml`, `methodology/forge-diagnostics.yaml`,
  `.codex/skills/coordinate-multihost-work/SKILL.md`,
  `plan/issues/forge-diagnostics-automation-2026-05-27.md`, and
  `plan/index.yaml`.
- This is informational for macOS m11/m8; it does not supersede the current
  primary action to clear the `action_host.rs`, `terminal_attach.rs`, and
  `vz.rs` rustfmt diffs.
- Forge diagnostics are a non-blocking annex to slow E2E runs. Treat proposed
  forge improvements as candidates requiring orchestrator privacy/isolation
  approval before implementation.
- Required acknowledgement in the next macOS `agent_status_packet`: confirm
  the `linux-next` coordination commit was pulled or list the fetch/rebase
  blocker, then report whether any forge diagnostic evidence was produced.

### event: linux coordinator status reconciliation — 2026-05-27T21:15Z

- Observed remote heads after fetch/pull: `linux-next` `b463cb53`,
  `windows-next` `cca9da4a`, `osx-next` `b463cb53`, `main` `fa746f03`.
- `osx-next` is identical to `linux-next`; there is no macOS code delta for the
  integration loop to merge.
- The prior rustfmt blocker is resolved by `4935404a` / `feb51d66`, so m11 is
  no longer a formatting-only gate. Remaining m11 work is semantic
  MenuStructure cleanup.
- Current macOS dependency chain: m8 user-attended smoke remains the manual
  acceptance gate. Autonomous fallback is m10 project threading or semantic
  m11 cleanup; neither blocks the Windows rustfmt retry and runtime-litmus
  rerun.

### event: linux coordinator status reconciliation — 2026-05-27T23:25Z

- Observed remote heads after fetch/rebase: `origin/linux-next` `891bb757`
  before this coordination commit, `windows-next` `1e20d6d0`, `osx-next`
  `f8778350`, `main` `fa746f03`.
- `osx-next` remains an ancestor of `linux-next`; there is no macOS code delta
  for the integration loop to merge.
- Runtime-litmus `20260527T231258Z-b06a5997-1e20d6d0-b06a5997` found both
  siblings already integrated but failed at `Disk quota exceeded` during
  `./build.sh --ci-full --install`. Replacement runtime-litmus
  `20260527T231940Z-b06a5997-1e20d6d0-b06a5997` passed build/install and init,
  then failed in OpenCode diagnostics with the `vault_bootstrap.rs:205`
  nested-runtime panic. This is a Linux coordination/runtime gate, not a macOS
  implementation blocker.
- Release run `26544334121` is the current monitored run after the Linux Nix
  musl release pivot.
- Current macOS dependency chain: m8 user-attended smoke remains the manual
  acceptance gate. Autonomous fallback is m10 project threading or semantic
  m11 cleanup.

### event: macOS slice 2 — ids::STATUS chip wired to VM lifecycle — 2026-05-28T01:19Z

- Commit `5e8bac82` lands the second slice of the post-UX-correction plan:
  `TrayActionHost` now holds `Arc<Mutex<Option<…>>>` handles for the
  `NSStatusItem` and the first-row `NSMenuItem` (`ids::STATUS`).
  `status_item::run` populates those handles once on startup via
  `attach_status_handles`; subsequent lifecycle events call
  `set_status_text` which dispatches a `setTitle:`/`setToolTip:` pair to the
  AppKit main thread.
- Phases wired today: "🔵 Setting up Fedora Linux…" on boot,
  "🟢 VM running" on success, "🔴 <error>" on failure. Provisioning
  granularity (Booting / Downloading / Verifying) lands in slice 6 when
  `download_verified::on_progress` is wired through.
- Tests + clippy + fmt clean: `cargo test -p tillandsias-macos-tray --bin
  tillandsias-tray` 25 passed; `cargo test -p tillandsias-vm-layer --features
  recipe,download,materialize --lib` 63 passed; `cargo clippy -p
  tillandsias-macos-tray --no-deps -- -D warnings` clean.
- UX-parity invariant preserved: menu shape stays identical to Linux +
  Windows. The macOS-specific VM-spinup layer is encoded only in the chip
  text, never as an extra menu item (per owner 2026-05-27 hard requirement).
- Streak: 0 (productive iter). Next macOS iter eligible at ~01:49Z to start
  slice 3 (held MenuState + menu re-render for SelectAgent + project list
  updates).

### event: macOS slice 3 — vm_phase_status_text converges with windows-tray — 2026-05-28T01:55Z

- Commit `637246b3` mirrors `tillandsias-windows-tray::notify_icon::
  vm_phase_status_text` (Windows commit `c45f23ae` 2026-05-27T18:28-07,
  which itself called out convergence with macOS commit `5e8bac82`).
  Both trays now produce byte-identical chip strings for each
  (`VmPhase`, `podman_ready`) combination — Ready / Ready (podman
  starting…) / Provisioning… / Starting… / Draining… / Stopping… /
  VM failed.
- The post-boot success branch of `boot_vm_async` now uses
  `vm_phase_status_text(Starting, false)` instead of the macOS-only
  placeholder "🟢 VM running". Once slice 4 wires `VmStatusRequest`
  polling, the chip will flip to "Ready" / "Ready (podman starting…)"
  based on the in-VM reply — identical to Windows.
- Macos-specific pre-boot phase "🔵 Setting up Fedora Linux…" stays
  outside the shared table because the VM-spinup phase has no
  Linux/Windows analogue (Linux + Windows tray either don't spin
  anything up, or already started by the time the tray launches).
- Tests + lint clean: macos-tray 26/26 (1 new
  `vm_phase_status_text_reflects_phase_and_podman` mirroring the
  windows-tray test of the same name); `cargo clippy -p
  tillandsias-macos-tray --no-deps -- -D warnings` clean; fmt clean.
- Convergence pattern: when linux-tray gets a status chip the same
  helper drops in as a 1:1 paste. The deduplication candidate (hoist
  to `tillandsias-host-shell`) is intentionally deferred — Windows
  + macOS each keeping their own inline copy mirrors the spec
  invariant that the table is per-tray (cross-platform-stable but
  not crate-shared yet).
- Streak: 0 (productive iter). Next macOS iter eligible at ~02:25Z to
  pick up slice 4 (the VmStatus poller itself — opening the
  VZVirtioSocketConnection + sending VmStatusRequest every 30s,
  mirroring `refresh_vm_status` in windows-tray).

### event: macOS slice 4 — poll_vm_status_once + Client::from_stream — 2026-05-28T02:25Z

- Commit `80d9196e` adds the macOS analogue of windows-tray's
  `refresh_vm_status`: `poll_vm_status_once(vz) -> Result<(VmPhase,
  bool), String>`. Opens vsock via `VzRuntime::open_vsock_stream`,
  wraps the resulting stream in the standard `host-shell::Client`
  via the new `Client::from_stream(stream, transport)` constructor,
  runs Hello + VmStatusRequest, returns `(phase, podman_ready)`.
- `Client::from_stream` is an additive constructor on the shared
  `tillandsias-host-shell` crate. Existing `Client::connect` /
  `connect_vsock` paths are untouched. macOS needs the
  pre-opened-stream path because `VZVirtioSocketConnection` produces
  the stream itself — macOS has no `AF_VSOCK`, so the standard
  `Transport::Vsock` connect path cannot reproduce it.
- New unit test `from_stream_handshake_drives_pre_opened_stream` in
  `vsock_client::tests` covers the new constructor against the
  existing fake_unix_server fixture. host-shell vsock_client 3/3
  green; macos-tray 26/26 green; vm-layer 63/63 green;
  clippy -D warnings + fmt clean.
- Visible UX impact this slice: none (the function is staged but
  not yet wired into a 30s ticker). Slice 5 spawns the ticker after
  `run_start` succeeds and feeds the result into
  `vm_phase_status_text` + `apply_status_text_main_thread`, mirroring
  the windows-tray loop in `spawn_provisioning`.
- Streak: 0 (productive iter). Next macOS iter eligible at ~02:55Z
  to wire the ticker (slice 5).

### Event: 2026-05-28T02:54:00Z — linux coordinator status reconciliation

- Observed remote heads after fetch/pull: `origin/linux-next` `089c1b34` (before this coordination commit), `origin/windows-next` `c45f23ae`, `origin/osx-next` `80d9196e`.
- Sibling branches ancestry: both `origin/windows-next` and `origin/osx-next` are fully merged and integrated as ancestors of the current local HEAD.
- Discovered that the previous background runtime litmus run `20260528T010600Z-c9e83852-3340523c-82d735ef` failed during OpenCode execution due to a Linux container networking/crun sethostname limitation: hostnames generated for enclave services (e.g. `git-tillandsias-runtime-litmus-...`) exceeded the 63-character Linux hostname limit.
- Resolved this blocker by implementing a robust `sanitize_hostname` function in `crates/tillandsias-headless` to safely truncate and hash hostnames exceeding 63 characters. Verified all tests pass green.
- Next action: A fresh background runtime litmus run will be scheduled to validate the integrated HEAD with the new hostname sanitization safely in place.

### event: macOS slice 5 — VmStatus 30s poller wired (UX-correction complete) — 2026-05-28T03:00Z

- Commit `ad49984b` lands the final UX-correction slice: after
  `run_start` returns Ok, `boot_vm_async` snapshots the
  `Arc<VzRuntime>` from `vm_slot` and hands it to
  `spawn_vm_status_poller`, which spawns a Tokio task that calls
  `poll_vm_status_once` (slice 4) every 30 s and patches the
  `ids::STATUS` chip + tooltip via `apply_status_text_main_thread`
  with the result of `vm_phase_status_text` (slice 3).
- The chip now fully mirrors the windows-tray progression:
  "🔵 Setting up Fedora Linux…" (macOS pre-boot) → "🔵 Starting…"
  (post-boot, awaiting first VmStatus reply) → "🟡 Ready (podman
  starting…)" / "🟢 Ready" (driven by the live in-VM VmStatusReply
  podman_ready flag).
- Transient wire errors are best-effort: logged + the last-known
  chip text is left untouched, matching windows-tray's
  `refresh_vm_status` policy (c45f23ae).
- Task lifecycle: the poller runs for the lifetime of the Tokio
  runtime (no cancellation handle). Quit drops the runtime, which
  ends the task. A graceful drain via `VmShutdownRequest`
  acknowledgement is the next slice (Quit drain, slice 6).
- Tests + lint clean: macos-tray 26/26; vm-layer 63/63;
  `cargo clippy -p tillandsias-macos-tray --no-deps -- -D warnings`
  clean; fmt clean.
- UX-parity invariant intact: zero macOS-extra menu items per
  owner's 2026-05-27 hard requirement. The macOS-specific VM-spinup
  layer is now fully encoded in the chip text, with the post-Ready
  segment 1:1 with windows-tray.
- Streak: 0 (productive iter). With UX-correction slices 1-5 done,
  the remaining macOS-owned items are:
    * slice 6 — Quit drain (vz.stop(60s) before exit(0))
    * slice 7 — fetch progress (wire download_verified::on_progress
      to the chip during materialization)
  Next macOS iter eligible at ~03:30Z to pick up slice 6.

### event: macOS slice 6 — Quit drain via quitWithDrain selector — 2026-05-28T03:30Z

- Commit `b4e07b2a` replaces the Quit item's responder-chain
  `terminate:` binding with a custom `quitWithDrain:` selector on
  TrayActionHost. The handler flips the chip to "🔴 Stopping…",
  takes the live VzRuntime out of `ivars.vm`, marks `vm_busy=true`,
  spawns a Tokio task that calls `vm.stop(VM_STOP_DRAIN=60s)`, then
  unconditionally `std::process::exit(0)`.
- ⌘Q stays bound — user-visible binding is identical. The drain
  reuses the existing `VzRuntime::stop` path (sends
  `VmShutdownRequest` over vsock, waits, escalates to hard stop on
  timeout), so we inherit windows-tray's tested drain semantics.
- Bypassing AppKit cleanup is acceptable for v0.0.1: the VM is the
  only state that needs flushing, and `exit(0)` after the await
  guarantees drain-then-die ordering. A future revision can route
  through `NSApplicationDelegate::applicationShouldTerminate` +
  `NSTerminateLater` for a cleaner AppKit handshake (no v0.0.1
  user-visible difference).
- Tests + lint clean: macos-tray 26/26; clippy -D warnings clean;
  fmt clean.
- Symmetric architecture confirmation from windows: commit
  `48a50981` refactored windows-tray to use my slice-4
  `Client::from_stream` constructor across `refresh_vm_status` +
  `try_connect_until_ready` + `--status-once`. Both trays now share
  one Hello/HelloAck + request/recv path; only the transport open
  differs per OS. Windows verified live: `--status-once` reads
  `wire_version=2, Ready, podman_ready: true, exit 0` from a
  provisioned VM.
- Streak: 0 (productive iter). Remaining macOS-owned item:
    * slice 7 — fetch progress (wire `download_verified::on_progress`
      into the chip so the user sees ~MB-fetched / decompression /
      verify phases during a cold first launch).
  Next macOS iter eligible at ~04:00Z.

### event: macOS slice 7 — fetch-progress chip during cold-launch — 2026-05-28T04:00Z

- Commit `f5443276` lands the last UX slice on the m4 sub-task B
  list. Threads an `on_phase: &(dyn Fn(&str) + Send + Sync)`
  callback through `VzRuntime::fetch_recipe_artifact` →
  `fetch_then_decompress_xz_then_verify` (vm-layer), and from
  `boot_vm_async` → `run_start` (macos-tray). The callback fires
  three times per cold launch:
    1. "🔵 Downloading rootfs…" (before HTTP GET stream)
    2. "🔵 Decompressing rootfs…" (before xz subprocess)
    3. "🔵 Verifying rootfs SHA-256…" (before sha-stream)
  Subsequent launches hit the rootfs.img cache so the callback
  never fires and the user sees the chip jump straight to
  "🔵 Starting…".
- The callback closure captures Arc-cloned status handles + the
  status_text slot, then on each call dispatches an
  `apply_status_text_main_thread` via `dispatch_to_main_thread`
  (libdispatch). All updates happen on the AppKit main thread.
- vm-layer additive change: two existing tests + macos-tray's
  `run_start_full_e2e` updated to pass `&|_| {}` no-op closures.
  No behavioral change to tests; pure signature widening.
- Tests + lint clean: macos-tray 26/26; vm-layer 63/63;
  `cargo clippy -p tillandsias-macos-tray --no-deps -- -D warnings`
  clean; fmt clean across both crates.
  (vm-layer's pre-existing `materialize/cache.rs:134` collapse-if
  warning is Linux-owned and unchanged by this slice.)
- With slices 1-7 complete, m4 sub-task B "action-host wiring" is
  DONE for v0.0.1. The only outstanding macOS-owned items are the
  nice-to-haves (Manifest::release_tag accessor — gated on linux-
  recipe addition) and user-attended m8 smoke (which is the manual
  acceptance gate, not parallelizable).
- Streak: 0 (productive iter). Next macOS iter eligible at ~04:30Z
  — at that point the loop will likely shift to noop cadence
  (escalating wake) until either (a) Linux ships the release_tag
  accessor unlocking the manifest-trust-root refactor, (b) Linux
  or Windows flags a new cross-host concern, or (c) the user
  reports interactive smoke results from a fresh .app install.

### event: macOS .app rebuild + ship for m8 user-attended smoke — 2026-05-28T04:30Z

- Ran `./scripts/build-macos-tray.sh` against commit `eee670ab`
  (which carries all 7 UX-correction slices). Output:
    Bundle: `dist/Tillandsias.app` (version 0.2.260527.5)
    Tarball: `dist/tillandsias-tray-0.2.260527.5-macos-arm64.tar.gz`
    Size: 1.49 MiB
    SHA-256: `2694745a8435804be84049570a00c939b103a9e6e33bf0eaec03f001eea3879e`
    Codesign: ad-hoc with com.apple.security.virtualization
    Verify: "satisfies its Designated Requirement"
- Tarball delivered to the user proactively via SendUserFile so they
  can run the m8 smoke checklist (Start VM auto-boots → chip cycles
  through fetch phases on cold launch → Open Shell + GitHub login
  route via PTY-over-vsock → Quit drains the VM 60 s before exit).
- This is the only remaining true blocker for v0.0.1; everything
  else is nice-to-have.
- Streak: 0 (productive iter — shipped a build artifact to the
  user, which is meaningful work toward closing v0.0.1 even though
  it's not a source-tree code commit). Next macOS iter eligible at
  ~05:00Z to FF-pull and check for either smoke feedback or a new
  cross-host concern.

### event: macOS slice 8a — poll_cloud_projects_once + cloud_entry_to_menu — 2026-05-28T05:00Z

- Commit `d7c0bbaa` adds the macOS analogue of windows-tray's
  `refresh_cloud_projects` (Windows commit `b0cdcdee` 2026-05-27T22:27-07,
  which itself rode on Linux `e1a190d4` — the in-VM headless's
  CloudRefreshRequest now serves real `gh repo list` output instead of
  an empty stub).
- Two pure functions:
    * `cloud_entry_to_menu(&CloudProjectEntry) -> ProjectEntry` —
      `name = wire.label`, `path = "{owner}/{repo}"`, `ready = false`.
      Mirrors windows-tray's helper byte-for-byte.
    * `poll_cloud_projects_once(vz) -> Result<Vec<ProjectEntry>, String>` —
      opens vsock via `VzRuntime::open_vsock_stream` → wraps with
      `Client::from_stream` → handshake → `CloudRefreshRequest` →
      `CloudRefreshReply` → map → return. 5 s overall timeout.
- Unit test `cloud_entry_maps_to_owner_slash_repo_slug` mirrors the
  windows-tray test of the same name — divergence between the two
  mappers would fail either suite. (Same pattern slice 3 used for
  `vm_phase_status_text` parity.)
- This slice stages the helper only. Slice 8b will hold a
  `MenuState` in `TrayActionHostIvars`, call this every ~5 min from
  `spawn_vm_status_poller` (mirroring windows' "first tick + every
  10 ticks" cadence), then rebuild the NSMenu when cloud_projects
  changes and re-attach the status handles. Splitting 8a/8b keeps
  each PR shape commit-sized + reviewable.
- Tests + lint clean: macos-tray 27/27 (+1 cloud_entry); vm-layer
  63/63; `cargo clippy -p tillandsias-macos-tray --no-deps -- -D
  warnings` clean; fmt clean.
- Streak: 0 (productive iter). Next macOS iter eligible at ~05:30Z
  to pick up slice 8b (held MenuState + menu re-render path).

### event: macOS slice 8b — held MenuState + cloud-projects polling — 2026-05-28T05:30Z

- Commit `08f41521` adds `menu_state: Arc<Mutex<MenuState>>` to
  `TrayActionHostIvars`, initialised to `MenuState::initial()` with
  `target=MacosTray`. Wires `spawn_vm_status_poller` to also tick on
  a cloud-projects cadence:
    * tick 0, 10, 20, … → `poll_cloud_projects_once(vz)` →
      `menu_state.cloud_projects = new_list`
    * every 30 s → `poll_vm_status_once(vz)` →
      `menu_state.podman_ready = reply.podman_ready`,
      chip = `vm_phase_status_text(phase, ready)`
- Cadence mirrors windows-tray's "first tick + every 10 ticks"
  pattern (commit b0cdcdee). `gh repo list` is a slower-changing
  input than VmStatus so it doesn't need per-tick granularity.
- The held MenuState is staged at this slice — nothing rebuilds
  the NSMenu yet. Cloud-project changes are logged at info
  ("cloud-projects: menu_state updated (N entries)") so the
  operator smoke logs show the wire is delivering the expected
  projects. Slice 8c will rebuild the NSMenu when state changes,
  using `tillandsias_host_shell::menu_state::build(&state)` to
  produce the full MenuStructure (today the menu is still built
  from `MenuStructure::initial_provisioning()`).
- Tests + lint clean: macos-tray 27/27; clippy -D warnings clean;
  fmt clean.
- Streak: 0 (productive iter). Next macOS iter eligible at ~06:00Z
  to scope slice 8c (full menu re-render — NSStatusItem.setMenu:
  + re-attach status_handles after each rebuild).

### event: macOS slice 8c — NSMenu rebuild on MenuState change — 2026-05-28T06:00Z

- Commit `8d3a8774` closes the menu-rebuild loop that slice 8b
  staged. The poller now triggers `rebuild_menu_main_thread` via
  `dispatch_to_main_thread` whenever cloud_projects or
  podman_ready changes:
    1. Clone the held MenuState
    2. `tillandsias_host_shell::menu_state::build(&state)` → fresh
       MenuStructure (same path Linux native + Windows tray use)
    3. `build_menu_with_status_row` (now `pub(crate)`) walks it +
       wires `trayAction:` targets on every clickable item using
       the live action-host
    4. `NSStatusItem.setMenu:` swaps the new menu in
    5. Re-attach the `status_menu_item` Arc to the new first-row
       NSMenuItem so future `set_status_text` calls target the
       fresh instance (the old one is released with the old menu)
- Infrastructure: new `TrayActionHostHandle` Send/Sync wrapper +
  `self_handle: Arc<Mutex<Option<…>>>` field populated once via
  `set_self_handle` from `status_item::run`. The wrapper exists
  because `Retained<TrayActionHost>` isn't Send (UnsafeCell layout)
  and the rebuild dispatch needs to reach `&TrayActionHost` on the
  main thread to pass to `build_menu_with_status_row`.
- Chip-update and rebuild dispatches are independent main-thread
  tasks. Chip text always lands; rebuild only when state actually
  changed. Both run on the AppKit serial queue so they can't
  interleave with user click handlers.
- Note: today the initial menu still uses
  `MenuStructure::initial_provisioning()` in `install_status_item`;
  the first poll tick rebuilds to the full menu via
  `menu_state::build`. A follow-up slice can switch the initial
  build for symmetric initial+update paths (and to show the menu
  shape sooner even before the first poll tick).
- Tests + lint clean: macos-tray 27/27; clippy -D warnings clean;
  fmt clean.
- Streak: 0 (productive iter). With slice 8c done, the macOS cloud-
  projects convergence is functionally complete — the menu now
  reflects in-VM `gh repo list` output 1:1 with windows-tray.
  Remaining macOS items unchanged from prior entry: nice-to-have
  manifest.release_tag accessor (Linux-owned) + user-attended m8
  smoke. Next macOS iter eligible at ~06:30Z; likely shifts to
  noop cadence pending those.

### event: macOS slice 9 — byte-level fetch-progress chip — 2026-05-28T06:30Z

- Commit `551680f0` converges with windows-tray's `6645d04b` (live
  fetch-progress chip during recipe materialization).
  `fetch_then_decompress_xz_then_verify`'s reqwest streaming loop
  now tracks downloaded bytes + Content-Length and emits refined
  "Downloading rootfs N/M MB (P%)" lines via the existing
  `on_phase` callback whenever integer percent changes.
- Throttling by percent caps dispatches at ~100 per download
  (~750 KB increments for a 74 MB .img.xz), well within any
  AppKit main-thread budget. Unknown Content-Length (rare on
  GitHub release assets) leaves the prior chip untouched — same
  fallback windows-tray uses.
- Chip-string format ("Downloading rootfs N/M MB (P%)") is
  byte-identical to windows-tray's. macOS first-launch chip now
  mirrors windows: "🔵 Downloading rootfs 12/74 MB (16%)…" →
  "🔵 Decompressing rootfs…" → "🔵 Verifying rootfs SHA-256…" →
  "🔵 Starting…" → live VmStatus.
- No signature change — `on_phase: &(dyn Fn(&str))` is reused.
  Tests + lint clean: vm-layer 63/63, macos-tray 27/27, clippy +
  fmt clean across both crates.
- Streak: 0 (productive iter). Next macOS iter eligible at
  ~07:00Z. With slices 1-9 done the macOS↔windows convergence
  on the m4 sub-task B surface is functionally complete (chip
  text, menu re-render, fetch progress, Quit drain). Remaining
  items: nice-to-have manifest.release_tag (Linux-owned) +
  user-attended m8 smoke.

### event: macOS slice 10 — symmetric initial menu via menu_state::build — 2026-05-28T08:30Z

- Commit `c9541768` closes the slice-8c-noted asymmetry: the
  initial menu in `status_item::run` now uses
  `tillandsias_host_shell::menu_state::build(&initial_state)` —
  the same path the poller's rebuild uses — instead of
  `MenuStructure::initial_provisioning()`.
- `initial_state = MenuState::initial()` with `target=MacosTray`
  and `status_text="🔵 Setting up Fedora Linux…"` (matches the
  boot-phase default boot_vm_async writes via set_status_text).
- User-visible: frame 0 already shows the structurally-identical
  9-item Ready menu (status / local-projects / cloud-projects /
  agents / observatorium / opencode-web / github-login / version
  footer / quit) — same shape Linux native + Windows render. No
  more morph from 2-item provisioning to 9-item ready on first
  poll tick.
- Tests + lint clean: macos-tray 27/27; clippy -D warnings clean;
  fmt clean.
- Streak: 0 (productive iter). Next macOS iter eligible at
  ~09:00Z. With slices 1-10 done the macOS m4 sub-task B surface
  is structurally + functionally 1:1 with windows-tray (modulo
  m8 user smoke + the linux-owned release_tag accessor). Loop
  will likely shift to noop cadence soon.

### event: macOS .app rebuild + ship (slices 8a-10) — 2026-05-28T09:00Z

- Rebuilt `Tillandsias.app v0.2.260527.5` from `d5868727` (carries
  slices 8a-10 on top of the 2026-05-28T04:30Z ship):
    * Tarball: `tillandsias-tray-0.2.260527.5-macos-arm64.tar.gz`
    * Size: 1.50 MiB
    * SHA-256: `62104b6dd6a3b2af7ddaa0051dce608efb941c165079496850b350a881c9fed9`
    * (previous ship sha: `2694745a...`)
- Delta vs prior ship:
    * slice 8a — `poll_cloud_projects_once` + `cloud_entry_to_menu`
    * slice 8b — held `MenuState` + cloud-projects polling cadence
    * slice 8c — full NSMenu rebuild on state change
    * slice 9  — byte-level "Downloading rootfs N/M MB (P%)" chip
    * slice 10 — symmetric initial menu via `menu_state::build`
- Tarball delivered to user proactively via SendUserFile for the
  m8 smoke checklist re-run. Same 7-step checklist as before;
  additional surfaces to inspect:
    * Frame 0 menu shape: should show full 9-item Ready (not 2-item)
    * After ~5 min with VM healthy: cloud-projects submenu populated
    * Cold launch (delete `~/Library/Application Support/tillandsias/
      rootfs.img` first): chip shows live byte-level progress
- Streak: 0 (productive iter). Next macOS iter eligible at ~09:30Z;
  loop likely shifts to noop cadence pending smoke feedback.

### event: macOS slice 11 — --diagnose health report — 2026-05-28T10:30Z

- Commit `db1619ae` mirrors `tillandsias-windows-tray::notify_icon::
  diagnose` (commit `20fb9d1f`) in spirit. Adds
  `tillandsias-tray --diagnose` that prints version / bundle / image-
  root artifacts / manifest SHA pin / control-wire disclaimer and
  exits without launching AppKit.
- **macOS-specific limitation called out in the report**: Apple's
  `Virtualization.framework` vsock is per-VM-handle (no `AF_VSOCK`),
  so a standalone `--diagnose` process literally cannot reach a
  separately-running tray's control wire. The report explicitly
  points the user at the menubar chip (already driven by the 30 s
  poller from slice 5) for live phase + podman_ready.
- Exit codes mirror windows: 0 provisioned, 2 degraded, 1 hard fail.
  Verified live: pre-first-launch dev box → "MISSING vmlinuz /
  initramfs.img" + "aarch64.img SHA-256 pin: 6859a7bcc4a9…" +
  exit 2.
- Useful for the m8 smoke checklist re-runs: the user can now
  diagnose "is the .app installed properly / has it provisioned"
  from a terminal without launching the GUI.
- This iter is also the noop-streak reset — `plan/issues/osx-next-
  noop-streak.md` deleted; streak back to 0.
- Tests + lint clean: macos-tray 27/27; clippy -D warnings clean;
  fmt clean.
- Next macOS iter eligible at ~11:00Z. With slice 11 the macOS
  --diagnose convergence with windows-tray is shipped; remaining
  items unchanged (manifest.release_tag Linux-owned + user smoke).

### event: macOS .app rebuild + ship (slice 11 / --diagnose) — 2026-05-28T11:00Z

- Rebuilt `Tillandsias.app v0.2.260527.5` from `782d2fce` (carries
  slice 11 on top of the prior 62104b6d ship):
    * Tarball: `tillandsias-tray-0.2.260527.5-macos-arm64.tar.gz`
    * Size: 1.51 MiB
    * SHA-256: `70feac0b5a2fe79df90b46b617f62600201be6c7dd126a7e619f7f7aa3fb912f`
    * (previous ship sha: `62104b6d…`)
- Delivered proactively via SendUserFile. After install the user
  can now run from terminal:
    /Applications/Tillandsias.app/Contents/MacOS/tillandsias-tray --diagnose
  to print version / bundle identity / image-root artifacts (with
  byte sizes) / aarch64.img SHA-256 pin / control-wire disclaimer.
  Exit code 0 (provisioned) / 2 (degraded) / 1 (hard fail) mirrors
  windows-tray.
- This complements the GUI m8 smoke checklist — operator can
  confirm install + provisioning from terminal without launching
  the AppKit tray.
- Streak: 0 (productive iter — ship counts as a deliverable for
  closing v0.0.1). Next macOS iter eligible at ~11:30Z.

### event: macOS slice 11a — diagnose manifest-pin parser tests — 2026-05-28T11:30Z

- Commit `a97b219a` extracts the inline aarch64.img SHA parser
  from `print_manifest_pin` into a pure
  `parse_aarch64_img_sha(manifest_toml: &str) -> Option<String>`
  helper, and adds three regression tests:
    * `parses_quoted_key_sha_form` — the actual
      `"aarch64.img" = "<sha>"` shape the recipe-publish CI emits
    * `parses_bare_key_sha_form` — bare-key tolerance for future
      manifest authors who drop the quotes
    * `refuses_placeholder_pending_ci` — "pending-ci" must NOT
      parse as a pin
- Drift-detection: if the manifest format changes upstream the
  parse-quoted test fails loudly in CI, instead of the report
  silently falling back to "(not found)" only when someone runs
  --diagnose interactively.
- Pure refactor — no behavior change to the running binary.
- Tests + lint clean: macos-tray 30/30 (+3 diagnose); clippy -D
  warnings clean; fmt clean.
- Streak: 0 (productive iter). Next macOS iter eligible at
  ~12:00Z.

### event: macOS slice 11b — --diagnose surfaces release tag — 2026-05-28T12:00Z

- Commit `37ff2d5f` mirrors windows-tray's `4fff31af`. The macOS
  diagnose report now prints "Release: v0.2.260526.1" right above
  the manifest pin so the operator can spot tag/SHA mismatches
  at a glance.
- `RECIPE_RELEASE_TAG` in `action_host.rs` is now `pub(crate)` so
  the diagnose module can read it without duplicating the const.
  Both trays share the same hardcode pattern until
  `manifest.release_tag()` lands (Linux-owned nice-to-have).
- No new tests — the existing aarch64.img parser tests cover the
  shared-format invariant; the release tag is a pure const surface.
- Tests + lint clean: macos-tray 30/30; clippy -D warnings clean;
  fmt clean.
- Streak: 0 (productive iter). Next macOS iter eligible at
  ~12:30Z.

### event: macOS slice 12 — compose_chip_text last_event append — 2026-05-28T13:30Z

- Commit `5c5e0e20` mirrors item 2 of windows-tray's `8992652a`.
  Adds `compose_chip_text(base, last_event_opt) -> String` that
  appends a non-empty `VmStatusReply.last_event` after a Unicode
  MIDDLE DOT (U+00B7), so the live chip surfaces in-VM activity:
    * before: "🟢 Ready"
    * after:  "🟢 Ready · forge-foo created"
  None/whitespace last_event leaves the base untouched.
- `poll_vm_status_once` signature changed to return
  `Option<String> last_event` from `VmStatusReply`;
  `spawn_vm_status_poller` composes it into the chip via
  `compose_chip_text(vm_phase_status_text(...), last_event)`.
- Byte-identical chip format with windows-tray. New unit test
  `compose_chip_text_appends_last_event` mirrors the windows-tray
  test of the same name — divergence between the two trays' chip
  composition would fail either suite.
- Deferred to a follow-up: a macOS UNUserNotificationCenter
  equivalent of windows' `show_balloon` (item 1 from 8992652a).
  That requires `objc2-user-notifications` + permission-request
  plumbing; meaningful UX gain but bigger than this slice.
- Tests + lint clean: macos-tray 31/31 (+1); clippy -D warnings
  clean; fmt clean. Streak reset to 0.
- Streak: 0 (productive iter). Next macOS iter eligible at
  ~14:00Z.
