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
  host-shell menu model). SelectAgent, Quit, Open Log, native-terminal launch
  for PTY-backed actions, and Retry reprovisioning are wired.
- `crates/tillandsias-vm-layer/src/wsl.rs` — WslRuntime provision/start/stop/
  exec/wait_ready implemented as real wsl.exe shell-outs (Windows-gated).
  GAP: no snapshot/clone method on the VmRuntime trait.
- `crates/tillandsias-windows-tray/wsl_lifecycle.rs` — bootstrap sequence
  drives recipe rootfs download, SHA verification, WSL import, systemd
  configuration, HvSocket handshake, keepalive, and graceful shutdown.
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
- Phase 2b — OCI flatten + real import (DROPPED): superseded by the owner's
  vm-recipe-provisioning model, which exports a flat rootfs tar from CI. Do NOT
  build an OCI-flatten path.
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
  - DONE (2026-05-25): host-side `~/src` (USERPROFILE\src) project scan wired
    into the tray via host-shell `scanner::watch_projects` — the menu lists
    local projects from first paint, no VM needed. `apply_project_event_to`
    (dedup by basename, name-sorted, removal) factored + unit-tested; tray
    builds + launches clean with the live scanner. 2 new tray tests.
  - DONE (2026-05-26/27): recipe provisioning, HvSocket Hello/HelloAck,
    Ready-state gating, VmStatus over HvSocket, PTY open/data/close,
    bidirectional PTY data, VM keepalive, Quit drain, native-terminal Open
    Shell launch, Retry reprovisioning, and forge-container Open Shell smoke
    are proven. Remaining w9 scope is integration-loop merge/test, optional
    full live-provision dress rehearsal, and optional wire
    EnumerateLocalProjects.
  - WIRE-DISPATCH CONTRACT (advisory from `plan/issues/control-socket-protocol-
    convergence-2026-05-25.md`): when the Win32 tray finally calls into the
    control wire, target the SAME `ControlMessage` variants over both transports
    (unix on Linux, vsock on Windows-in-WSL); the in-VM headless will dispatch
    via a shared `control_dispatch.rs` and reply `Error{Unsupported}` (not a
    silent drop) for unhandled variants. If a needed variant isn't shared-
    implemented yet, file it in that doc — do NOT fork a Windows-local handler.
    The shared `tillandsias-control-wire` enum is unchanged; dispatcher work is
    Linux-side (PR #2).
  - DONE (2026-05-25): added `assets/tillandsias.rc` embedding the existing
    `tillandsias.manifest` (per-monitor-v2 DPI awareness + requireAdministrator
    =false) — previously NOT embedded (no .rc), so the tray ran DPI-unaware.
    Build warning cleared, no duplicate-manifest link error, liveness smoke
    clean. ICON line is present-but-commented: real genus art is SVG-only
    (assets/icons/<genus>/*.svg) and the host has no SVG->ICO rasterizer, so
    the .ico is DEFERRED until art/rasterizer lands (runtime falls back to
    IDI_APPLICATION; build tolerates it).
- Phase 5 — Smoke + checkpoint to origin/windows-next.
- Paperwork (woven in): archive superseded windows-wsl-runtime / windows-native-build
  changes with tombstone → decision note; keep OpenSpec/litmus bindings clean.

## Host state (this box, French Windows 11)

- WSL2: NOT yet installed at decision time (`wsl --status` → "n'est pas installé").
- Rust: NOT installed (no ~/.cargo).
- podman: not on host (correct).
- Present: git-bash (C:\Program Files\Git\bin\bash.exe), winget.

## NEXT ACTION (resume here)

Phase 0/1/2 DONE; Phase 4 portable slice DONE; w5 recipe-provisioning + w9
control-wire/PTY/Open-Shell/Retry PROVEN E2E (2026-05-26/27). Cargo at
`%USERPROFILE%\.cargo\bin` — prepend each PowerShell session:
`$env:Path = "$env:USERPROFILE\.cargo\bin;$env:Path"`.

FIRST, re-sync shared ./plan: `git fetch --all`, then read
`plan/issues/tray-convergence-coordination.md` and the integration-loop ledger
for new cross-host signal (merge conflicts, build/test failures, shared-contract
changes). The recipe-convergence decision (CI-materialized rootfs as the Windows
default) has LANDED and is implemented; the provisioning path is no longer
blocked on it.

NOTE: Phase 2b OCI-flatten is DROPPED — the owner's vm-recipe-provisioning
model exports a flat rootfs tar from the recipe (no shipped binary, no OCI
flatten). Do NOT build OCI-flatten.

Model-independent menu/install work (WITHOUT a booted VM):
- DONE (2026-05-25): Host-side `~/src` scan via host-shell `scanner` populates
  menu local_projects from first paint (wired in `notify_icon::run`).
- DONE (2026-05-25): real tray icon shipped (`assets/tillandsias.ico`, 7 sizes
  from `bloom.svg`) + embedded via `.rc` — no more placeholder warning.
- DONE (2026-05-25): **installable + interactively testable locally**.
  `scripts/build-windows-tray.ps1` (release / `-DebugBuild`) +
  `scripts/install-windows.ps1` (installs to `%LOCALAPPDATA%\Programs\Tillandsias`,
  Start Menu shortcut, `-Startup`/`-Launch`/`-Uninstall`) — windows-owned
  parallel to `scripts/install-macos.sh`, but builds from source (no published
  Windows release artifact yet). A `--no-provision` / `TILLANDSIAS_NO_PROVISION`
  dev-mode gate in `run()` skips WSL bootstrap so the menu comes up clean for
  local testing.
- DONE (2026-05-27): **file-based tray logging** — `run()` installs a
  `tracing-subscriber` file writer at startup
  (`%LOCALAPPDATA%\tillandsias\logs\tray.log`, honors `RUST_LOG`); a
  GUI-subsystem tray has no console otherwise. `Open Log` reveals it in
  Explorer. (`0626a318`)
- OBSERVED (2026-05-25): windows-host rustfmt produces drift on
  macOS-owned siblings (`pty/unix.rs`, etc.) — rustfmt-version skew. Reverted,
  never staged; flag for a pinned-rustfmt reconciliation.

PROVISIONING + CONTROL WIRE — PROVEN E2E on real hardware (2026-05-26/27), no
longer blocked:
- DONE: `provision_via_recipe` (w5) — recipe rootfs from embedded
  `manifest.toml` -> `download_verified` ->
  `materialize::wsl::tar_to_wsl_import` -> `configure_recipe_distro`
  (systemd) -> headless self-installs on first boot.
- DONE (F2): HvSocket transport (`hvsocket.rs`) — WSL2 is a Hyper-V guest, so
  the host reaches the guest's AF_VSOCK listener via `AF_HYPERV`
  `(VmId, ServiceId)`. Proven: `Hello`/`HelloAck`,
  `VmStatusRequest`->`Ready`, PTY-attach both directions (one-shot +
  bidirectional stdin). Flips menu Provisioning->Ready.
- DONE: **VM keepalive** (`531bcce4`) — WSL2 idles the utility VM down without
  a host-side session; `spawn_keepalive` (`wsl --exec sleep infinity`,
  kill_on_drop) is held for the tray's lifetime so the control wire stays warm.
- DONE: **Quit -> graceful drain** (`bc23a529`) — bounded `wsl --terminate` on
  Quit tears down VM + keepalive (no orphaned child).
- DONE: **clickable Open Shell** (`c997fc43`) — Attach/Maintain/GitHubLogin
  resolve `intent_for_action` -> `launch_spec` to the forge-wrapped in-VM argv,
  opened in a native terminal via `wt.exe`/`wsl.exe -d tillandsias -- <argv>`
  (per the per-OS-terminal agreement; only the shell argv converges with
  macOS). Smoke PASSED (`8e84df7d`): `wt.exe` + `wsl.exe` bridge + bare-VM
  `/bin/bash -l` + spaced-title quoting all verified.
- DONE: **Retry** (`f4c3d70f`) — Retry sets "Retrying provisioning..." and
  re-runs guarded `provision_via_recipe` after failure without duplicating an
  active task or interrupting Ready state.
- DONE: **forge-container Open Shell smoke** (`c0a9558b`) — the exact
  `wsl -d <distro> -- podman exec -it tillandsias-<name>-forge <cmd>` shape
  runs into a forge-named container and returns `FORGE-EXEC-OK`.
- DONE: **full live-provision dress rehearsal** (`9c7b30ce`) — added
  `tillandsias-tray --provision-once` (headless console-progress provision; exit
  0=Ready/1=fail, for CI/diagnostics) and ran it on real hardware: SettingUp ->
  DownloadingRootfs (downloaded + SHA-verified against the REPINNED `13cf3af0`
  manifest -> confirms the embedded manifest matches the live published rootfs)
  -> `tar_to_wsl_import` -> systemd -> first-boot headless self-install ->
  HvSocket handshake -> **VM Ready, exit 0**. The entire production provisioning
  flow is now proven end-to-end against live published assets. (Benign: WSL warns
  "Failed to start systemd user session for root" — per-user session, not the
  system service running the headless; control wire came up regardless.)

NEXT (remaining w9 — all optional, nothing mechanism-blocking):
- Optional: in-container production Open Shell via a real headless-created forge
  (the `podman exec` mechanism + bare-VM shell are already proven; this is the
  forge image/name supplied by a live headless rather than a throwaway alpine).
- Optional: `EnumerateLocalProjects` over the wire (in-VM projects) — today the
  menu is populated by the host-side `~/src` scan, which already works.

Checkpoint to origin/windows-next after each meaningful batch.
