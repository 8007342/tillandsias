# Step 20 — macOS Tray v0.0.1

Status: in_progress
Owner: Tlatoani-MacBook-Air (Claude Opus 4.7, "macos-next" worker)
Started: 2026-05-24

## Goal

Ship `tillandsias-tray.app` as a thin AppKit menu-bar wrapper that boots a Fedora 44 Core VM via Apple's Virtualization.framework, opens a virtio-vsock control-wire to the in-VM `tillandsias-headless` on port 42420, and surfaces the same menu UX as the Linux GNOME/KDE tray — including `GitHub login` and `Open Shell` routed through the inner tillandsias via a host-PTY-over-vsock attach. Distribution: `curl install-macos.sh | bash`. Cold-boot Fedora is acceptable for v0.0.1 (~20 s); save-state-restore is v0.0.2.

## Multi-host coordination

This step is being implemented by the `macos-next` worker on a single Apple Silicon host. Other agents (codex on a separate machine; an eventual Windows-tray builder) will FF-pull this branch and may concurrently edit the workspace. To minimize stomping:

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

## Done-when

- `Tillandsias.app` installed via `install-macos.sh` on a clean macOS 14+ Apple Silicon host
- Menubar icon appears within 500 ms of double-click
- "GitHub login" opens a host Terminal.app with the in-VM `gh auth login` device-code flow
- "Open Shell" opens a host Terminal.app with `/bin/bash` running inside the VM
- Stop-VM menu item gracefully drains in ≤ 30 s
- Release pipeline publishes `tillandsias-tray-<version>-macos-arm64.tar.gz` as a release asset
- This file's status flips to `completed`
