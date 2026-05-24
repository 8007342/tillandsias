# windows-next — Windows thin-tray bring-up (resumable plan)

Status: in_progress
Branch: windows-next (checkpoint to origin/windows-next, NOT linux-next)
Owner handoff: cold-start readable — the next agent may be a fresh elevated session.

Authoritative decision + rationale: `plan/issues/windows-next-architecture-decision-2026-05-24.md`.
Governing specs: host-shell-architecture, windows-native-tray, vm-idiomatic-layer,
vm-provisioning-lifecycle, vsock-transport.

## Architecture (committed 2026-05-24)

Thin Win32 NotifyIcon tray (`tillandsias-windows-tray` → `tillandsias-tray.exe`)
drives ONE Fedora 44 WSL2 distro via `tillandsias-vm-layer::WslRuntime` (only
crate allowed to call `wsl.exe`). That single VM runs the existing
`tillandsias-headless` + the full podman enclave INSIDE the VM. Host ↔ in-VM
headless over vsock. Podman never on the Windows host. Older 6-distro
`windows-wsl-runtime` / `src-tauri` line is superseded inspiration only.

## Current scaffolding state (what exists vs. gaps)

- `crates/tillandsias-windows-tray/notify_icon.rs` — Win32 tray UI implemented
  (message-only window, icon, WM_TASKBARCREATED re-add, right-click popup from
  host-shell menu model). GAP: menu actions only log; nothing wired.
- `crates/tillandsias-vm-layer/src/wsl.rs` — WslRuntime provision/start/stop/
  exec/wait_ready implemented as real wsl.exe shell-outs (Windows-gated).
  GAP: no snapshot/clone method on the VmRuntime trait.
- `crates/tillandsias-windows-tray/wsl_lifecycle.rs` — bootstrap sequence
  sketched. GAP: rootfs + binary downloads are PLACEHOLDERS (no HTTP, no SHA).
- `tillandsias-host-shell`, `tillandsias-control-wire` + vsock transport: present.

## Phased plan

- Phase 0 — Host enablement (IN PROGRESS): install Rust MSVC toolchain +
  VS C++ Build Tools + WSL2; verify cargo / link.exe / wsl.
- Phase 1 — Green build on host: `cargo build -p tillandsias-windows-tray
  --target x86_64-pc-windows-msvc`; fix real-Windows compile breakage; tray
  icon renders.
- Phase 2 — Real provisioning: replace placeholder downloads with reqwest+rustls
  fetch + SHA-256 verify against a pinned assets/provisioning-manifest.json;
  wire into WslRuntime::provision.
- Phase 3 — Snapshot / fast-boot: extend VmRuntime (seal_base +
  clone_from_base/reset_to_base); implement on WslRuntime via VHDX clone +
  `wsl --import-in-place`; update vm-idiomatic-layer + vm-provisioning-lifecycle
  specs + litmus. Default = sealed golden base VHDX + fast per-launch clone
  (WSL2 analog of macOS VZ snapshot). Ephemerality holds because user code is
  bind-mounted and secrets live in the Vault podman volume.
- Phase 4 — Wire tray actions + vsock E2E: Attach Here, GitHub login,
  Quit→graceful drain through host-shell to in-VM headless; prove Hello/HelloAck.
- Phase 5 — Smoke + checkpoint to origin/windows-next.
- Paperwork (woven in): archive superseded windows-wsl-runtime / windows-native-build
  changes with tombstone → decision note; keep OpenSpec/litmus bindings clean.

## Host state (this box, French Windows 11)

- WSL2: NOT yet installed at decision time (`wsl --status` → "n'est pas installé").
- Rust: NOT installed (no ~/.cargo).
- podman: not on host (correct).
- Present: git-bash (C:\Program Files\Git\bin\bash.exe), winget.

## NEXT ACTION (resume here after reboot, in ELEVATED prompt)

User already ran (admin):
  winget install --id Microsoft.VisualStudio.2022.BuildTools --override "--quiet --add Microsoft.VisualStudio.Workload.VCTools --includeRecommended"
User is rebooting Windows, then restarting the agent in an elevated prompt to
install the REST of the toolchain.

On resume, in the elevated session:
1. Install Rust (user scope): `winget install --id Rustlang.Rustup` then
   `rustup default stable-x86_64-pc-windows-msvc`.
2. Install WSL2 (admin): `wsl --install --no-distribution` (already needs the
   reboot that just happened; re-run / verify).
3. Verify: `cargo --version`, `link.exe` discoverable (VS Build Tools), `wsl --status`.
4. Proceed to Phase 1: build tillandsias-windows-tray for x86_64-pc-windows-msvc.

Verified so far: branch switched to windows-next; decision + plan recorded.
Blocked on: toolchain install (Phase 0) requiring elevation + reboot.
