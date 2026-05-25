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

- Phase 0 — Host enablement (DONE 2026-05-24): WSL2 2.7.3.0 (kernel 6.6.114.1)
  installed; VS 2022 C++ Build Tools installed; Rust stable-x86_64-pc-windows-msvc
  (cargo 1.95.0) installed via winget Rustlang.Rustup. cargo/rustc verified.
- Phase 1 — Green build on host (DONE 2026-05-24): `cargo build -p
  tillandsias-windows-tray` builds clean on the MSVC host and produces
  `target/debug/tillandsias-tray.exe` (1.66 MB). Fixed one real-Windows
  breakage: `tillandsias-core/src/image_builder.rs` used compile-time
  `env!("HOME")` (no HOME at compile time on Windows) → now a runtime
  HOME-or-USERPROFILE-or-temp_dir fallback (behavior-preserving on Linux).
  Liveness smoke: launched the exe, message loop + NotifyIcon stayed up 3s,
  stopped cleanly. NOTE: non-fatal build warning — `assets/tillandsias.rc`
  missing, so a placeholder icon is used (follow-up: ship the .rc + icon).
- Phase 2 — Real provisioning (DONE 2026-05-24): verified, resumable downloader
  landed in `tillandsias-vm-layer::fetch` (behind a `download` feature; shared
  with the macOS tray). `crates/tillandsias-windows-tray/assets/provisioning-
  manifest.json` is the committed source of truth (resolves the version() gap):
  Fedora 44 Generic Base OCI archive (sha 75200f57…, 70 MB) + headless binary
  `tillandsias-linux-x86_64` @ v0.2.260523.6 (sha 5734e74f…). `wsl_lifecycle.rs`
  bootstrap now fetches+verifies both. Tests: 10 unit pass (sha-hex validation,
  cache-hit-skips-network, unpinned-sha-refused, pins-parse) + 1 live test that
  downloads the REAL release binary and verifies its SHA (passed, 2s).
- Phase 2b — OCI flatten + real import (NEXT): the pinned rootfs is a Fedora
  OCI *image archive*, not a flat rootfs. `WslRuntime::provision` must flatten
  the layer(s) (parse index.json -> manifest -> layer blob -> extract) into a
  rootfs tar before `wsl --import`. Until then, bootstrap downloads+verifies
  both artifacts but the import step will reject the OCI archive.
- Phase 3 — Snapshot / fast-boot: extend VmRuntime (seal_base +
  clone_from_base/reset_to_base); implement on WslRuntime via VHDX clone +
  `wsl --import-in-place`; update vm-idiomatic-layer + vm-provisioning-lifecycle
  specs + litmus. Default = sealed golden base VHDX + fast per-launch clone
  (WSL2 analog of macOS VZ snapshot). Ephemerality holds because user code is
  bind-mounted and secrets live in the Vault podman volume.
- Phase 4 — Wire tray actions + vsock E2E (IN PROGRESS):
  - DONE: portable menu-click resolver `tillandsias-host-shell::menu_action`
    (`MenuAction` + `resolve()`, handles dynamic project.<scope>.<name>.<verb>
    ids incl. dotted names) — SHARED with macOS tray, additive, no trait change.
    Windows tray `handle_menu_command` now resolves to typed actions and
    dispatches (Quit→WM_DESTROY wired; VM/control-wire actions logged pending
    the vsock-attach slice). 5 new unit tests; 17/17 host-shell tests green ON
    WINDOWS.
  - Also fixed a pre-existing Windows portability gap: `vsock_client` +
    `provisioning` test modules used tokio UnixListener (Unix-only) and broke
    `cargo test` on Windows — now `#[cfg(all(test, unix))]`-gated (Linux/macOS
    still run them).
  - REMAINING: connect vsock client to a live in-VM headless (needs a booted
    VM, i.e. Phase 2b/recipe), flip menu Provisioning→Ready from a real
    handshake + EnumerateLocalProjects, Quit→graceful VM drain (VmShutdownRequest
    then stop), and route Attach/GitHubLogin/agents over the wire
    (control-wire-pty-attach for Open Shell + login).
- Phase 5 — Smoke + checkpoint to origin/windows-next.
- Paperwork (woven in): archive superseded windows-wsl-runtime / windows-native-build
  changes with tombstone → decision note; keep OpenSpec/litmus bindings clean.

## Host state (this box, French Windows 11)

- WSL2: NOT yet installed at decision time (`wsl --status` → "n'est pas installé").
- Rust: NOT installed (no ~/.cargo).
- podman: not on host (correct).
- Present: git-bash (C:\Program Files\Git\bin\bash.exe), winget.

## NEXT ACTION (resume here)

Phase 0/1/2 DONE; Phase 4 portable slice DONE. Cargo at `%USERPROFILE%\.cargo\bin`
— prepend each PowerShell session:
`$env:Path = "$env:USERPROFILE\.cargo\bin;$env:Path"`.

FIRST, re-sync shared ./plan: `git fetch --all`, then read
`plan/issues/tray-convergence-coordination.md` and check origin/linux-next +
origin/osx-next for responses to the windows-next recipe-convergence
preferences (CI-materialized rootfs as the Windows default). The provisioning
path depends on that cross-host decision.

NOTE: Phase 2b OCI-flatten is DROPPED — the owner's vm-recipe-provisioning
model exports a flat rootfs tar from the recipe (no shipped binary, no OCI
flatten). Do NOT build OCI-flatten.

Provisioning thread is BLOCKED on the cross-host recipe decision. While
blocked, model-independent work available WITHOUT a booted VM:
- Host-side `~/src` (USERPROFILE\src) project scan via host-shell `scanner` ->
  populate menu local_projects before the VM is ready.
- Ship a real tray icon (.rc + .ico) to clear the build.rs placeholder warning.

Once a VM can boot (recipe lands, or interim path agreed): connect vsock client
-> handshake -> flip menu Provisioning->Ready + EnumerateLocalProjects, Quit->
graceful drain, route Attach/GitHubLogin over the wire (control-wire-pty-attach).
Contribute `materialize::wsl::tar_to_wsl_import` to the shared recipe module.
Checkpoint to origin/windows-next after each meaningful batch.
