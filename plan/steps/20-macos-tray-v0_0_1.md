# Step 20 — macOS Tray v0.0.1

Status: in_progress
Owner: Tlatoani-MacBook-Air (Claude Opus 4.7, **`osx-next` worker** — local branch renamed from `macos-next` per canon `plan/issues/branch-and-coordination-canon-2026-05-25.md`)
Started: 2026-05-24
Branch contract (per canon, effective 2026-05-25T06Z):
  - **Code commits** (`crates/tillandsias-macos-tray/**`, `crates/tillandsias-vm-layer/src/vz.rs`, `crates/tillandsias-vm-layer/Cargo.toml` macOS bits, `crates/tillandsias-control-wire/src/transport_macos.rs`): push to `origin/osx-next`; integration loop merges into `linux-next`.
  - **`plan/`, `methodology/`, `openspec/`, `cheatsheets/` writes**: push directly to `origin/linux-next`.
  - **Local branch**: `osx-next` (was `macos-next`).

## Goal

Ship `tillandsias-tray.app` as a thin AppKit menu-bar wrapper that boots a Fedora 44 Core VM via Apple's Virtualization.framework, opens a virtio-vsock control-wire to the in-VM `tillandsias-headless` on port 42420, and surfaces the same menu UX as the Linux GNOME/KDE tray — including `GitHub login` and `Open Shell` routed through the inner tillandsias via a host-PTY-over-vsock attach. Distribution: `curl install-macos.sh | bash`. Cold-boot Fedora is acceptable for v0.0.1 (~20 s); save-state-restore is v0.0.2.

## Multi-host coordination

This step is being implemented by the `macos-next` worker on a single Apple Silicon host. Other agents (codex on a separate machine; an eventual Windows-tray builder) will FF-pull this branch and may concurrently edit the workspace. The user's Linux host additionally runs a **periodic integration loop** that merges sibling-branch progress into `linux-next` and writes outcomes to `plan/issues/multi-host-integration-loop-<date>.md`. Every cron-fired iteration of THIS step MUST `tail -200` that ledger after FF-pull and respond to any **`### Spec-drift watch`** or **`### Open Recommendations`** lines that mention the macOS crates (`tillandsias-vm-layer`, `tillandsias-control-wire`, `tillandsias-host-shell`, `tillandsias-macos-tray`). The ledger is a two-way feedback channel, not just an audit log.

To minimize stomping:

- **Files this builder will edit aggressively (do not touch concurrently):**
  - `crates/tillandsias-vm-layer/src/vz.rs` *(body only)*
  - `crates/tillandsias-macos-tray/src/{status_item,vz_lifecycle,terminal_attach,menu_disabled_v2,installation_uuid}.rs`
  - `crates/tillandsias-macos-tray/assets/{Info.plist.template,Tillandsias.entitlements,icon.icns}`
  - `crates/tillandsias-control-wire/src/transport_vsock_macos.rs` *(new file)*
  - `scripts/build-macos-tray.sh` *(new)*
  - `scripts/install-macos.sh` *(new)*
  - `openspec/changes/macos-tray-build-and-release/*`

- **Files this builder will edit conservatively (additive only, coordinate first):**
  - `crates/tillandsias-control-wire/src/{lib.rs,transport.rs}` — only adding macOS-cfg-gated `pub use` lines + Pty\* variants once `control-wire-pty-attach` merges. Will rebase aggressively on FF-pull.
  - `crates/tillandsias-vm-layer/src/lib.rs` — trait signatures are the shared contract; this builder will NOT change them.
  - `crates/tillandsias-control-wire/Cargo.toml` — only adding `[target.'cfg(target_os = "macos")'.dependencies] objc2-virtualization = "..."`.
  - `crates/tillandsias-vm-layer/src/{recipe,materialize,cache}.rs` — new modules per `vm-recipe-provisioning` once that proposal merges; coordinate with Windows builder who will share the same modules.
  - `.github/workflows/{ci,release}.yml` — additive `macos-*` jobs only; Linux/Windows jobs untouched.

- **Files this builder will NOT touch:**
  - `crates/tillandsias-vm-layer/src/wsl.rs`
  - `crates/tillandsias-windows-tray/**`
  - `crates/tillandsias-headless/src/main.rs` (only register the new `pty_handler` module via mod statement)
  - `methodology/versioning.yaml` (the `m`-prefix change is deferred per owner 2026-05-24)

## Cross-host versioning convention (per owner 2026-05-24)

All three trays + headless ship under the **same** Tillandsias CalVer string (no `m`/`w`/`v` prefix yet). The `artifact-namespace-prefix-versioning` proposal remains drafted but is non-blocking for v0.0.1.

## Phases

| Phase | Subject | Gated on | Est |
|---|---|---|---|
| 0 | This file + `openspec/changes/macos-tray-build-and-release` proposal | — | 0.5 d |
| 1 | `VzRuntime` body in `vz.rs` + new `transport_vsock_macos.rs` | — | 3 d |
| 2 | `.app` bundle + ad-hoc codesign + `install-macos.sh` | Phase 1 | 2 d |
| 3 | macOS CI job + first releasable `.tar.gz` | Phase 2 | 1 d |
| 4 | Recipe materializer wired into `VzRuntime::provision` | `vm-recipe-provisioning` merging | 3 d |
| 5 | PtyAttach + Open Shell + GitHub login routed via PTY-over-vsock | `control-wire-pty-attach` merging | 3 d |
| 6 | End-to-end smoke + tagged release | Phases 1–5 | 1 d |

Plan reference: `~/.claude/plans/partitioned-wobbling-babbage.md`.

## Status updates

- 2026-05-24: Step opened; Phase 0 in progress. Three opsx:proposes already pushed in commit `37b36cd4`. 4th proposal `macos-tray-build-and-release` to follow shortly.
- 2026-05-24 (later): **Phase 0 complete** (commit `527ee207`). 4th proposal pushed; plan/steps/20 visible to other hosts. Phase 1 starting.
- 2026-05-24 (later still): **Phase 1 grounded, scoped, scheduled.** Cheatsheets `runtime/vz-framework-provisioning.md`, `runtime/vsock-transport.md`, `runtime/macos-vz-gui-research-v2.md` confirm the architecture. `objc2-virtualization 0.2.2` API surveyed: `VZVirtioSocketConnection::fileDescriptor() -> c_int` is the macOS-host-side bridge hook for the vsock connector; wrap with `tokio::io::unix::AsyncFd`. Required features: `VZSocketDeviceConfiguration`, `VZSocketDevice`, `VZVirtioSocketListener`, plus the bootloader/storage/network feature flags. Phase 1 implementation order (committed individually for FF-pull granularity):
  1. `crates/tillandsias-vm-layer/examples/vz-spike.rs` — minimal VZVirtualMachineConfiguration that calls `validate()`. Proves the toolchain + entitlement story end-to-end before the larger refactor.
  2. `crates/tillandsias-control-wire/src/transport_vsock_macos.rs` — `VZVirtioSocketDevice::connectToPort:completionHandler:` → `Retained<VZVirtioSocketConnection>` → `fileDescriptor()` → `AsyncFd<RawFd>` → `(impl AsyncRead, impl AsyncWrite)`. Documented as "macOS host always *connects*; never *binds* — guest binds VMADDR_CID_ANY:42420 inside its own kernel."
  3. Refactor `VzRuntime` to hold an `Arc<RwLock<Option<Retained<VZVirtualMachine>>>>` for VM-handle storage across `&self` method calls.
  4. Implement `VzRuntime::start` — full config builder (EFI + NVRAM, virtio-blk root disk, virtio-net NAT, virtio-console serial → host stdout, **virtio-vsock with guest_cid**, virtio-fs share, entropy, balloon), `validate()`, `start(completionHandler:)`.
  5. Implement `VzRuntime::stop` — `requestStop` then force-stop after `drain_timeout`.
  6. Implement `VzRuntime::wait_ready` — host-side polls `VZVirtioSocketDevice::connectToPort(42420)` with the existing 250ms/500ms/1s/2s/4s backoff; success once the connection lands and the Hello/HelloAck handshake completes.
  7. Leave `VzRuntime::exec` as a clear "Phase 5" stub (PTY-over-vsock).
  8. Update `crates/tillandsias-vm-layer/Cargo.toml` to pin `objc2-virtualization` to `=0.2.2` exact.
  9. Tests: `examples/vz-spike.rs` smoke (boots placeholder image, console log written); unit tests for the AsyncFd wrapper (loopback unix pair stand-in on Linux).

  Phase 1 is **not single-session work**. Estimated 3 working days as planned.

- 2026-05-24 (later still): **Phase 1 milestone — full objc2-virtualization integration proven end-to-end.** Step 1 (`vz-spike`) compiles, runs, and reaches `VZVirtualMachineConfiguration::validateWithError()` after ad-hoc codesigning with the new `crates/tillandsias-macos-tray/assets/Tillandsias.entitlements` (which also lands a Phase-2 task early). Validate currently fails with `"variableStore" is nil` — the EXPECTED next-blocker, since the spike's EFI bootloader is unconfigured. Confirms: (1) Cargo deps + 35 VZ features compile clean, (2) `objc2::ClassType::alloc()` + `Retained::into_super` pattern is correct, (3) `codesign --force --sign - --entitlements <file>` grants `com.apple.security.virtualization` to an ad-hoc binary, (4) full config-builder pipeline (CPU/RAM/platform/EFI/storage/network/serial/entropy/balloon/vsock) builds without crashing. Subsequent loop iterations: add NVRAM, add real disk image, swap into VzRuntime::start, then implement vsock connector. Switching to slow-paced /loop (hourly) for continued progress without monopolising the session.
- 2026-05-24 (loop iter 1): **vz-spike now validates clean.** Default behavior auto-creates an EFI variable store at `target/vz-spike-nvram.bin` if `--nvram` not passed, so `cargo run -p tillandsias-vm-layer --example vz-spike` (after sign) prints `validate(): OK`. NVRAM is 128KB, idempotent across runs. Next loop iteration: convert the Fedora qcow2 in `research/images/` to a raw image and try `--boot` to actually launch the VM. Cron `08207697` set hourly at :17.
- 2026-05-24 (loop iter 2): **Fedora 44 boots end-to-end via vz-spike --boot.** Discovered the main thread needs to pump CFRunLoop or the VZ start completion handler never fires (VM stuck in `starting` state); added `run_cf_loop_for(Duration)` using `CFRunLoopRunInMode(kCFRunLoopDefaultMode, ...)`. With that fix: validate OK, start completion fires in 81 ms, Fedora kernel 6.19.10-300.fc44.aarch64 (arm64) writes its full early-boot serial to host stderr, NAT brings up `enp0s1: 192.168.64.3`, and Fedora's stock systemd-ssh@vsock prints `Try contacting this VM's SSH server via 'ssh vsock%3' from host` (CID auto-allocated by VFR to 3 since spike didn't request a specific one). `localhost login:` reached, then `requestStop` cleanly dispatched. The whole VM lifecycle takes ~10s wall-clock. Pre-conversion: `qemu-img convert -O raw research/images/Fedora-Cloud-Base-Generic-44-1.7.aarch64.qcow2 target/vz-images/fedora44.raw && qemu-img resize -f raw target/vz-images/fedora44.raw 30G`. Phase 1 core is now de-risked; next iteration: refactor vz-spike's config-builder + boot-and-observe loops into `VzRuntime::start` and `VzRuntime::stop`.
- 2026-05-24 (loop iter 3): **Extracted vz::boot public module — shared between spike and VzRuntime.** Added `pub mod boot` to `crates/tillandsias-vm-layer/src/vz.rs` (macOS-only) exposing `VzBootConfig`, `build_vm_configuration(&VzBootConfig)`, and `pump_cf_loop_for(Duration)`. `vz-spike` refactored from 295 lines of inline glue to 165 lines that drive the public API. Spike re-verified end-to-end: validate OK, boot completes in 58 ms, Fedora kernel + NAT IP `192.168.64.4` + vsock CID 3 + clean stop. The next iteration wires `VmRuntime::start` to call `build_vm_configuration` + `pump_cf_loop_for` directly (need to solve VZVirtualMachine handle storage on `&self` for the subsequent `stop`/`wait_ready` to find).
- 2026-05-24 (loop iter 4 — feedback response): **Integration ledger surfaced an URGENT cross-host coordination ask** (cycle 03:43Z, commit `5b945e30`): "macOS host: please respond in plan/issues/macos-recipe-convergence-response-2026-05-24.md … Without a macOS response by ~2026-05-29 the 2026-05-31 deadline is at risk." Responded by authoring that file (700+ lines) endorsing Path B + the D6 amendment shape + a macOS-specific format-matrix request (CI-fetch should publish both `.tar` and `.img` per arch). Also merged origin/linux-next (now includes windows-next Phase 0–4 + tray-convergence-coordination doc). VmRuntime::start body work deferred to next iter — answering the ledger was the higher-priority deliverable per the codified feedback contract.
- 2026-05-24 (loop iter 4 — D6 amendment, owner-authorized): User authorized **co-owner mode** ("author amendments + push, then wait for Linux + Windows ledger acknowledgement before each landing") + **amend-in-place** + **shared-first impl order** + **Linux-CI builds both `.tar` and `.img`**. Authored the D6 amendment as a single commit on `openspec/changes/vm-recipe-provisioning/`: renumbered existing D6/D7 to D7/D8, inserted new "D6: CI-materialized rootfs as first-class dual path, default for non-Linux hosts" in design.md; added matching "What Changes" entries in proposal.md; added new "## 2b. CI-fetch path artifacts (D6 amendment 2026-05-25)" section in tasks.md with 5 tasks (manifest.toml schema bump, `materialize::macos::tar_to_vfr_img` Linux-runnable conversion, `recipe-publish` CI job, host-side fetch-vs-local selector, `--materialize-local` flag + trust model docs). Change still validates clean. **Now waiting for next Linux integration-loop cycle (every ~2h) to acknowledge the amendment before starting implementation on shared `tillandsias-vm-layer::{recipe,materialize,cache}` modules.** Meanwhile, next iteration unblocks on the model-independent Phase 1 work (`VmRuntime::start` body + `transport_macos.rs` vsock connector).
- 2026-05-24 (loop iter 5 — VmRuntime::start lands; push backlog flushed): **Auth restored**, all 11 accumulated commits pushed (`15432b7b..361e4d28 macos-next -> linux-next`). Merged origin/linux-next (cycle 02:00Z + 03:43Z integration cycles + new `plan/issues/control-socket-protocol-convergence-2026-05-25.md`). Replaced `VzRuntime::start`'s `unimplemented!()` with a real body: `VmHandle` Send+Sync wrapper around `Retained<VZVirtualMachine>` (unsafe-impl per VZ's single-dispatch-queue contract); `Mutex<Option<VmHandle>>` field on `VzRuntime` for cross-method coordination; full pipeline = `boot::build_vm_configuration` → `validateWithError` → `initWithConfiguration` → `startWithCompletionHandler` with a `mpsc::channel` + `pump_cf_loop_for(250ms)` poll loop bounded at 30 s. Refuses double-start. Two new tests: `vz_runtime_is_send_and_sync` (compile-time check) and `vz_start_fails_clean_when_rootfs_missing` (async behaviour). 8/8 tests pass. Vz-spike still boots cleanly. Next iteration: refactor vz-spike to drive VzRuntime::start (proves the production path works against a real VM), then implement `VmRuntime::stop` + `wait_ready`.
- 2026-05-25 (iter 6 — branch-name canon adoption): **Owner published `plan/issues/branch-and-coordination-canon-2026-05-25.md` + `methodology/distributed-work.yaml`.** Canon ratifies `osx-next` (not `macos-next`) as the macOS branch and rules that **macOS code commits SHOULD route through `osx-next`** (integration loop merges into linux-next). `plan/` writes still go directly to linux-next. Earlier this iter I FF-aligned `origin/osx-next` to the current linux-next tip (`ddf52dff..b0951b7c`) — that action was correct and gives me a current launchpad. Renamed my local branch `macos-next` → `osx-next` to match the canon. The "tombstone osx-next forever" angle in `plan/issues/osx-next-tombstoned-2026-05-25.md` is now marked SUPERSEDED at the top of that doc.
- 2026-05-25 (iter 7 — m1 + m3 from work queue, integration loop alive again): Linux integration loop resumed (`9f16f1ad` 15:00Z, `03fe2971` 16:00Z) — CRDT methodology validated. Linux claimed §3 materializer driver (`653be7d1`), Windows shipped w1+w2 (`cef326e1`, `832871d9`), recipe parser §2 landed with new `recipe` Cargo feature, pty-attach §1 (l1) all 5 tasks **DONE**. Linux authored `plan/issues/osx-next-work-queue-2026-05-25.md` listing my unblocked items. Claimed and finished **m3** (clippy clamp lint fix in `vz.rs:144`) and **m1** (VmRuntime::stop body with `requestStop` + state poll + 5 s force-stop fallback; wait_ready body with state-polling + backoff cadence matching `vsock_client::BACKOFF_SCHEDULE`; exec body explicit Phase-5-deferred error). Two new tests: `vz_stop_and_wait_ready_fail_clean_before_start` + `vz_exec_returns_phase5_deferral`. **10/10 unit tests pass.** Enqueued new item **m1b/transport-macos-vsock-connector** (Phase 1 step 1.5) — the next CODE iteration. m4 + m5 still gated on Linux deliverables l3 + l2+l5 respectively.
- 2026-05-25 (iter 8 — m2 done, spike now drives production code path): **`vz-spike --boot` rewritten to drive `VzRuntime::start → wait_ready → stop` instead of hand-rolling VZ method calls.** Validate-only mode (default) still bypasses runtime for inspectable config errors. New `--observe-secs N` flag; spike sets up image_root tempdir with `rootfs.img → <--disk>` symlink so VzRuntime finds the rootfs at the path it expects (Phase 4/D6 will populate this automatically). End-to-end smoke confirmed: start 267 ms, wait_ready 0 ms (state already Running), Fedora kernel + NAT IP 192.168.64.5/6 + vsock CID 3 + login prompt reached. **Finding**: Fedora 44 Cloud's stock systemd ACPI shutdown takes >30 s, so the spike's 30 s drain hit timeout and force-stop fallback dispatched — verifies the drain-THEN-force contract. Production tray should pass 60 s `drain_timeout`. Next iter: m1b (transport_macos.rs vsock connector) — the chunky one that unblocks m4 + m5.
- 2026-05-25 (iter 9 — m1b sub-task A): **`crates/tillandsias-vm-layer/src/transport_macos.rs` lands** (NEW macOS-only file, ~200 lines incl. tests). Public surface: `connect_to_vm_vsock(vm: &VZVirtualMachine, port: u32, timeout: Duration) -> Result<VsockFd, ConnectError>` plus `VsockFd { fd, _connection }` + `ConnectError` (NoSocketDevice / UnexpectedSocketDeviceKind / Timeout / VzError / NullConnection). Implementation walks `vm.socketDevices()`, downcasts the first entry to `VZVirtioSocketDevice` (verified via `isKindOfClass:`), calls `connectToPort:completionHandler:` with a `block2::RcBlock` that bridges the result through a `std::sync::mpsc` channel, pumps `CFRunLoop` in 50 ms slices until the result arrives or `timeout` elapses, then extracts `connection.fileDescriptor()` and returns the keep-alive `Retained<VZVirtioSocketConnection>` wrapper so the fd stays valid for the lifetime of `VsockFd`. `Send + Sync` via documented unsafe-impl (the fd is OS-level thread-safe; VZ doesn't gate established sockets to a queue). 2 new tests: `connect_error_implements_error` + `vsock_fd_is_send`. **12/12 tests pass.** **Next iter (m1b sub-task B)**: wrap `VsockFd.fd` in `tokio::io::unix::AsyncFd<RawFd>` with an `AsyncRead + AsyncWrite` impl so the host-shell `vsock_client::handshake` can ride it. **Sub-task C**: extend `VzRuntime::wait_ready` to call `connect_to_vm_vsock(self.guest_cid_irrelevant, CONTROL_WIRE_VSOCK_PORT)` after the state-poll succeeds, confirming the in-VM tillandsias-headless's vsock listener is alive.

## Done-when

- `Tillandsias.app` installed via `install-macos.sh` on a clean macOS 14+ Apple Silicon host
- Menubar icon appears within 500 ms of double-click
- "GitHub login" opens a host Terminal.app with the in-VM `gh auth login` device-code flow
- "Open Shell" opens a host Terminal.app with `/bin/bash` running inside the VM
- Stop-VM menu item gracefully drains in ≤ 30 s
- Release pipeline publishes `tillandsias-tray-<version>-macos-arm64.tar.gz` as a release asset
- This file's status flips to `completed`
