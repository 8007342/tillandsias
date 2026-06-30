# windows-next architecture decision (2026-05-24)

Cold-start note for the next agent: this file records the authoritative
direction for the Windows host so nobody re-litigates it from chat history.

## Decision

`windows-next` commits to the **host-shell thin-tray architecture** (the
"newt" plan). On Windows:

- A thin native Win32 `NotifyIcon` binary (`tillandsias-windows-tray` →
  `tillandsias-tray.exe`) runs on the host.
- It drives **one** Fedora 44 Core WSL2 distro via `tillandsias-vm-layer`
  (`WslRuntime`, the only crate allowed to invoke `wsl.exe`).
- That single VM runs the **existing** `tillandsias-headless` + the full
  podman enclave **inside the VM**. Podman stays in the VM; it is NOT
  installed on the Windows host and is NOT replaced by per-service distros.
- Host ↔ in-VM headless communication is **vsock** (`vsock-transport`
  extends `tillandsias-control-wire`). The wire protocol is unchanged.
- All portable logic (project scanner, menu modelling, provisioning phases,
  vsock client, lifecycle) lives in `tillandsias-host-shell`, shared with
  the macOS `NSStatusItem` sibling.

Governing specs: `host-shell-architecture`, `windows-native-tray`,
`vm-idiomatic-layer`, `vm-provisioning-lifecycle`, `vsock-transport`.

## Superseded line (do NOT revive without a new decision)

The older Windows line is **superseded inspiration only**:

- `src-tauri/` Tauri app on Windows.
- OpenSpec change `windows-wsl-runtime` ("replace podman entirely with 6
  per-service WSL distros": proxy/forge/git/inference/router/enclave-init).
- OpenSpec changes `windows-native-build`, `windows-git-mirror-cred-isolation`.
- Branches `wsl-on-windows`, and the `osx-next` peer for macOS.

These captured useful prototype findings (image→distro conversion is
mechanical; shared netns between distros; uid-based egress firewall; drvfs
ownership / GCM credential-prompt pitfalls). Harvest those findings as
cheatsheet/spec inputs, but the per-service-distro runtime is **not** the
windows-next runtime. Recommend archiving `windows-wsl-runtime` (and peers)
under `openspec/changes/archive/` with a tombstone pointing here.

## Host state at decision time

This Windows host (`C:\Users\bullo\src\tillandsias`, French Windows 11) was
bare for this work:

- WSL2 **not installed** (`wsl --status` → "n'est pas installé").
- Rust **not installed** (no `~/.cargo`, nothing on PATH).
- No podman on host (correct for this architecture).
- Git-bash (`C:\Program Files\Git\bin\bash.exe`) and `winget` present.

User approved installing the Rust MSVC toolchain + WSL2 (admin + reboot) on
this host so the tray can be built and a real Fedora VM provisioned.

## Snapshot / fast-boot decision (recommended default)

"Blazing fast start" on WSL2 is implemented as a **sealed golden base +
fast per-launch clone**, the WSL2-idiomatic analog of the macOS VZ snapshot:

1. Provision once into an immutable base distro `tillandsias-base`: import
   the Fedora 44 rootfs, install the headless binary + systemd vsock unit,
   bake the enclave service images (proxy/git/inference/router) + T0/T1
   models into podman storage, then `wsl --terminate` and treat its
   `ext4.vhdx` as the golden image.
2. Each launch creates the runtime distro by **copying the golden VHDX**
   (block-clone on ReFS / sparse copy on NTFS) and `wsl --import-in-place`,
   skipping re-provisioning and image re-pull.
3. Ephemerality holds because user code lives in bind-mounted host dirs and
   durable secrets live in the Vault podman volume — so resetting the
   runtime distro to the golden VHDX per launch is safe and gives the
   "fresh from snapshot" property. Heavy models lazy-pull post-boot
   (existing inference design).

This requires extending the `VmRuntime` trait (e.g. `seal_base()` +
`clone_from_base()` / `reset_to_base()`) and updating `vm-idiomatic-layer`
+ `vm-provisioning-lifecycle`. The trait currently has no snapshot surface.

## Branch / checkpoint discipline

- Work and checkpoints for this host land on `origin/windows-next`
  (not `linux-next`). `linux-next` remains the primary source of progress;
  peek at `osx-next`/`macos-next` for the VZ sibling for inspiration.
- Methodology refinements still do not push directly to `main`.
