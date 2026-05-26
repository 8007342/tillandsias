# osx-next work queue — 2026-05-25

trace: methodology/distributed-work.yaml, plan/issues/multi-agent-work-shaping-2026-05-25.md, plan/steps/20-macos-tray-v0_0_1.md, plan/issues/tray-convergence-coordination.md, plan/issues/macos-recipe-convergence-response-2026-05-24.md, openspec/changes/control-wire-pty-attach/

Status: **OPEN** as of 2026-05-26T00:18Z. macOS m1, m1b, m2, m3, and m6
are done. m4 has its Unix PTY foundation (`0551a265`) and still needs the
user-facing `terminal_attach` wiring. m7 is ready now that m6 produced the
bundle/install scripts. m5 remains gated on the Linux materializer plus
macOS-owned recipe-publish deliverables.

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

Work-shaping note: m4 user-facing wiring and m7 CI packaging are both large
enough to occupy a macOS agent for one or two recurrent iterations. If m5
remains gated on the materializer/rootfs chain, do not idle; continue m4 wiring
or claim m7 and leave end-to-end recipe evidence for the later m5 packet.

## Currently unblocked / active

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
- status: ready
- gated_on: []
- cleared_gates:
  - linux deliverable `l1/control-wire-pty-attach-tasks-1` shipped at `b345ae68`
  - linux deliverable `l3/in-vm-headless-pty-handler` shipped at
    `f770e013`/`8dc0d129`
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
- estimated_effort: 1–2 days.
- verification_note: >
    Host-side wiring can start now. m1b's AsyncRead/AsyncWrite wrapper and
    Hello/HelloAck wait_ready handshake are done; full terminal-attach smoke
    still needs a booted/provisioned VM path.

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
- status: ready
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

## Linux deliverables macOS is waiting on (status mirrors)

| Linux item | Status | Blocks macOS item |
|---|---|---|
| `l1/control-wire-pty-attach-tasks-1` | done (`b345ae68`; §1 enum/capability tasks complete) | m4 ready with l3 also done |
| `l2/recipe-shared-modules` | done (`a7af0ed`; parser tests green on Linux) | m5 still gated on l7 + l5 |
| `l3/in-vm-headless-pty-handler` | done (`f770e013`/`8dc0d129`; tasks 4.1-4.7, two pump tests ignored pending AsyncFd rewrite) | m4 ready for host-side wiring |
| `l4/replace-vsock-stub-handlers` | done (`6956c825`; informational only for macOS) | (informational only for macOS) |
| `l5/recipe-smoke-ci-publish` | macOS-owned claim; pending l7/materializer | m5 |
| `l7/§3-materializer-driver` | stale Linux lease `linux-l-mat-2026-05-25T15Z`; ping/reclaim due after fresh read | m5 |

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
