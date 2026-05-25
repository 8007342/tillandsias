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
- 2026-05-24 (later still): **Phase 1 grounded, scoped, scheduled for next session.** Cheatsheets `runtime/vz-framework-provisioning.md`, `runtime/vsock-transport.md`, `runtime/macos-vz-gui-research-v2.md` confirm the architecture. `objc2-virtualization 0.2.2` API surveyed: `VZVirtioSocketConnection::fileDescriptor() -> c_int` is the macOS-host-side bridge hook for the vsock connector; wrap with `tokio::io::unix::AsyncFd`. Required features: `VZSocketDeviceConfiguration`, `VZSocketDevice`, `VZVirtioSocketListener`, plus the bootloader/storage/network feature flags. Phase 1 implementation order (committed individually for FF-pull granularity):
  1. `crates/tillandsias-vm-layer/examples/vz-spike.rs` — minimal VZVirtualMachineConfiguration that calls `validate()`. Proves the toolchain + entitlement story end-to-end before the larger refactor.
  2. `crates/tillandsias-control-wire/src/transport_vsock_macos.rs` — `VZVirtioSocketDevice::connectToPort:completionHandler:` → `Retained<VZVirtioSocketConnection>` → `fileDescriptor()` → `AsyncFd<RawFd>` → `(impl AsyncRead, impl AsyncWrite)`. Documented as "macOS host always *connects*; never *binds* — guest binds VMADDR_CID_ANY:42420 inside its own kernel."
  3. Refactor `VzRuntime` to hold an `Arc<RwLock<Option<Retained<VZVirtualMachine>>>>` for VM-handle storage across `&self` method calls.
  4. Implement `VzRuntime::start` — full config builder (EFI + NVRAM, virtio-blk root disk, virtio-net NAT, virtio-console serial → host stdout, **virtio-vsock with guest_cid**, virtio-fs share, entropy, balloon), `validate()`, `start(completionHandler:)`.
  5. Implement `VzRuntime::stop` — `requestStop` then force-stop after `drain_timeout`.
  6. Implement `VzRuntime::wait_ready` — host-side polls `VZVirtioSocketDevice::connectToPort(42420)` with the existing 250ms/500ms/1s/2s/4s backoff; success once the connection lands and the Hello/HelloAck handshake completes.
  7. Leave `VzRuntime::exec` as a clear "Phase 5" stub (PTY-over-vsock).
  8. Update `crates/tillandsias-vm-layer/Cargo.toml` to pin `objc2-virtualization` to `=0.2.2` exact.
  9. Tests: `examples/vz-spike.rs` smoke (boots placeholder image, console log written); unit tests for the AsyncFd wrapper (loopback unix pair stand-in on Linux).

  Phase 1 is **not single-session work**. Estimated 3 working days as planned. Next session continues here.

## Done-when

- `Tillandsias.app` installed via `install-macos.sh` on a clean macOS 14+ Apple Silicon host
- Menubar icon appears within 500 ms of double-click
- "GitHub login" opens a host Terminal.app with the in-VM `gh auth login` device-code flow
- "Open Shell" opens a host Terminal.app with `/bin/bash` running inside the VM
- Stop-VM menu item gracefully drains in ≤ 30 s
- Release pipeline publishes `tillandsias-tray-<version>-macos-arm64.tar.gz` as a release asset
- This file's status flips to `completed`
