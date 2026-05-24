---
tags: [macos, virtualization-framework, vz, fedora, provisioning, apple-silicon, vsock]
languages: [rust, swift, bash]
since: 2026-05-23
last_verified: 2026-05-23
sources:
  - openspec/specs/macos-native-tray/spec.md
  - openspec/specs/vm-provisioning-lifecycle/spec.md
  - https://developer.apple.com/documentation/virtualization
  - https://developer.apple.com/documentation/virtualization/vzvirtualmachineconfiguration
  - https://developer.apple.com/documentation/virtualization/vzvirtiosocketdeviceconfiguration
  - https://developer.apple.com/documentation/virtualization/vzlinuxbootloader
authority: medium
status: proposed
tier: bundled
---

# Apple Virtualization.framework provisioning (macOS)

@trace spec:macos-native-tray, spec:vm-provisioning-lifecycle
@cheatsheet runtime/vsock-transport.md, runtime/macos-vz-gui-research-v2.md

**Use when**: building the macOS arm of the Tillandsias VM lifecycle, debugging VZ boot failures on Apple Silicon, or porting a working WSL2 provisioning step to the macOS guest.

## Provenance

- Apple Developer — `Virtualization` framework reference (macOS 13+)
- `VZVirtualMachineConfiguration` — top-level VM config object
- `VZVirtioSocketDeviceConfiguration` — virtio-vsock device wiring
- `VZLinuxBootLoader` — direct kernel + initrd boot
- `objc2-virtualization` crate — Rust bindings used by `tillandsias-vm-layer`
- `openspec/specs/macos-native-tray/spec.md` — Tillandsias contract

## Framework basics

Virtualization.framework (`/System/Library/Frameworks/Virtualization.framework`) ships with macOS 13 (Ventura) and is the supported way for a non-Apple-employee process to run a Linux guest on macOS, including on Apple Silicon. Tillandsias uses it via the `objc2-virtualization` Rust crate; no Swift or Objective-C source in the workspace.

| macOS | Status |
|---|---|
| 13.0 (Ventura) | Minimum; basic guests work |
| 14.x (Sonoma) | Improved virtio-fs, stable virtio-vsock |
| 15.x (Sequoia) | Better Rosetta integration for x86_64 binaries on Apple Silicon guests |
| 16.x (next) | Tillandsias does not depend on 16-only features |

The framework is **entitlement-gated**: a process must hold `com.apple.security.virtualization` to instantiate `VZVirtualMachine`. Tillandsias' macOS tray binary embeds this entitlement at sign time; unsigned local builds work only with the development codesign profile.

## Boot ingredients

A Linux guest boots from three artifacts, all delivered by the Tillandsias install:

| Ingredient | Source | Where it lives |
|---|---|---|
| **Kernel (`vmlinuz`)** | Extracted from Fedora 44 container rootfs at provision time | `~/Library/Application Support/tillandsias/vm/vmlinuz` |
| **Initrd (`initramfs.img`)** | Extracted from the same rootfs (Fedora kernel package) | `~/Library/Application Support/tillandsias/vm/initramfs.img` |
| **Root disk (`rootfs.img`)** | Raw `ext4` image generated from the rootfs tarball | `~/Library/Application Support/tillandsias/vm/rootfs.img` |

VZ does **not** support qcow2. The root disk must be a raw file mapped via `VZDiskImageStorageDeviceAttachment`. A typical size budget for the design phase is 32 GiB sparse; macOS APFS handles sparse-file growth efficiently.

### Converting Fedora 44 to a VZ-bootable image

The high-level steps performed at provision time:

```bash
# 1. Download the same rootfs tarball used on Windows
ROOTFS_URL='https://dl.fedoraproject.org/pub/fedora/linux/releases/44/Container/aarch64/images/Fedora-Container-Base-Generic.44-1.5.aarch64.tar.xz'
curl -L "$ROOTFS_URL" -o ~/Library/Caches/tillandsias/fedora-44-arm64.tar.xz

# 2. Create the raw root disk
ROOT_IMG="$HOME/Library/Application Support/tillandsias/vm/rootfs.img"
truncate -s 32G "$ROOT_IMG"
mkfs.ext4 -F "$ROOT_IMG"

# 3. Populate it with the rootfs
MNT=$(mktemp -d)
hdiutil attach -nomount "$ROOT_IMG"             # macOS — yields /dev/diskX
# (For brevity: in practice we use a sidecar Linux container via Apple's
#  Containerization or a small VZ "installer" guest to do the mkfs/extract.
#  The macOS host cannot mount ext4 directly.)

# 4. Drop a /boot kernel and initramfs out for VZLinuxBootLoader
#    (extracted from the kernel-core RPM inside the rootfs)

# 5. Bake /etc/wsl.conf-equivalent settings:
#    enable systemd, install tillandsias-headless as a systemd unit listening
#    on vsock :42420 (same payload as the Windows side)
```

The "macOS cannot mount ext4" problem is real; the production flow uses a tiny Apple `Containerization`-style or `virtio-fs`-only installer-VM to do the mkfs + populate step inside Linux, then writes the resulting raw image to the host filesystem. This is research item #5 in the plan (`openspec/specs/vm-provisioning-lifecycle/spec.md`).

### Phase 5 implementation status (rootfs conversion)

`crates/tillandsias-vm-layer/src/vz.rs::vz_real::convert_rootfs_to_disk_image` and `extract_kernel_artifacts` are intentionally `unimplemented!()` in Phase 5. Three viable production paths, ranked by Tillandsias preference:

1. **CI-baked image (preferred for v1)** — bake the populated `rootfs.img` + `vmlinuz` + `initramfs.img` triplet into a release asset published alongside the `tillandsias-linux-x86_64` binary. Provisioning then becomes a plain HTTP fetch + SHA verify, no mkfs at all on the user's machine. Costs: one extra GitHub Actions runner step (linux-arm64) producing the ext4 image inside a Fedora container.
2. **Installer-VM sidecar (fallback)** — on first run, spin up a tiny rust-vmm or `Containerization.framework` Linux VM that mounts the tarball, runs `mkfs.ext4 -F /dev/vda && tar -xf /work/rootfs.tar.xz -C /mnt`, then writes the resulting `rootfs.img` back to the host. Adds 2-3 GB to first-run download (`fedora-minimal` initramfs + kernel for the installer).
3. **`hdiutil` + helper container** — `hdiutil create -fs ExFAT` does not get us ext4. macOS ships `newfs_exfat` and `newfs_msdos` only. Treat this option as not viable for ext4.

The Phase 5 macOS-host follow-up wave wires option #1 by extending `.github/workflows/release.yml`'s release job. Until then, the `unimplemented!()` call in `vz.rs` is the explicit signal that nobody can boot a VZ guest on macOS yet.

### Phase 5 implementation status (status item)

`crates/tillandsias-macos-tray/src/status_item.rs` implements the real `NSStatusItem` + `NSMenu` wiring against `objc2 0.5` + `objc2-app-kit 0.2`. The key surface:

- `install_status_item(mtm, structure) -> Retained<NSStatusItem>` — constructs the bar item, sets its title to the placeholder "T" (replaced by `assets/icon.pdf` at packaging time), and sets the tooltip from the menu's `status` line so the user sees the current condensed phase on hover.
- `build_menu(mtm, structure) -> Retained<NSMenu>` — walks `menu_disabled_v2::render(structure)` and produces one `NSMenuItem` per spec. Disabled items get `setEnabled(false)` + `setToolTip(reason)`; checked items get `setState(NSControlStateValueOn)`; nested children become a recursive `NSMenu` submenu.
- All AppKit calls are gated by a `MainThreadMarker` obtained at entry; off-thread calls panic with a clear message.

The Linux dev box cannot validate the AppKit run-loop end-to-end; manual repro on a macOS 14+ box is:

```bash
# On a macOS 14+ host with Xcode CLT installed:
git checkout main
cargo build -p tillandsias-macos-tray --release --target aarch64-apple-darwin
./target/aarch64-apple-darwin/release/tillandsias-tray
# Expect: menu-bar icon (the "T" placeholder) appears within 500ms.
# Click → menu opens with:
#   Setting up Fedora Linux… (disabled, italic)
#   ❌ Quit Tillandsias
# Click Quit → process exits cleanly.
```

A more complete macOS pilot will land in the Phase 5 macOS-host follow-up — at that point, the placeholder icon is replaced with the real green tillandsia, and the provisioning thread starts feeding the menu state machine.

## `VZVirtualMachineConfiguration` shape

Tillandsias' VM config is built once at provision time and persisted as a serialized blob. On each tray launch the config is reconstructed and handed to `VZVirtualMachine::new`.

```rust
// Pseudocode against `objc2-virtualization` bindings.
let config = VZVirtualMachineConfiguration::new();

// CPU + memory (sensible defaults; user-tunable in v2)
config.setCPUCount(4);                          // logical cores
config.setMemorySize(8 * 1024 * 1024 * 1024);   // 8 GiB

// Bootloader (direct kernel boot, no UEFI)
let boot = VZLinuxBootLoader::new(kernel_url);
boot.setInitialRamdiskURL(Some(initrd_url));
boot.setCommandLine("console=hvc0 root=/dev/vda1 rw quiet systemd.unified_cgroup_hierarchy=1");
config.setBootLoader(boot);

// Root disk
let attachment = VZDiskImageStorageDeviceAttachment::new(rootfs_img_url, /*readOnly*/ false)?;
let block = VZVirtioBlockDeviceConfiguration::new(attachment);
config.setStorageDevices(vec![block]);

// Serial console (early-boot diagnostics → file on host)
let serial = VZVirtioConsoleDeviceConfiguration::new();
serial.setAttachment(VZFileSerialPortAttachment::new(console_log_url, /*append*/ true)?);
config.setSerialPorts(vec![serial]);

// virtio-vsock — control-wire transport
let vsock = VZVirtioSocketDeviceConfiguration::new();
config.setSocketDevices(vec![vsock]);
// Note: VZ chooses the guest CID at start; we read it back from
// VZVirtualMachine::socketDevices()[0].listener(...) after the VM is running.

// virtio-fs — share ~/src/ into /home/forge/src
let share = VZVirtioFileSystemDeviceConfiguration::new("home-src");
share.setShare(VZSingleDirectoryShare::new(home_src_url, /*readOnly*/ false));
config.setDirectorySharingDevices(vec![share]);

// Network (for proxy egress to GitHub etc.) — NAT mode
let net = VZVirtioNetworkDeviceConfiguration::new();
net.setAttachment(VZNATNetworkDeviceAttachment::new());
config.setNetworkDevices(vec![net]);

config.validate()?;
let vm = VZVirtualMachine::new(config, /*queue*/ dispatch_queue);
vm.start()?;
```

## virtio-vsock specifics on macOS

Two important deviations from the Linux/Windows model:

1. **Guest CID is announced**, not assigned by the host shell. After `VZVirtualMachine::start`, query `vm.socketDevices()[0]` to read the live CID. Persist it in the host shell's in-memory VM state.
2. **Host-side `connect`** goes through `VZVirtioSocketDevice::connect_to_port(port)`, which returns a file descriptor; that fd is then handed to `tokio` for async I/O. There is no `AF_VSOCK` socket family on macOS proper — `tokio-vsock` cannot be used directly. The `tillandsias-vm-layer` crate's `vz` backend wraps the fd into a `tokio::net::unix::UnixStream`-shaped adapter.

See `vsock-transport.md` for the port (`42420`) and message framing.

## virtio-fs share for `~/src/`

The macOS host's `~/src/` directory is shared into the VM at `/home/forge/src` via `VZVirtioFileSystemDeviceConfiguration`. Inside the guest, the mount is performed early in systemd:

```ini
# /etc/systemd/system/home-src.mount
[Unit]
DefaultDependencies=no
Before=tillandsias-headless.service

[Mount]
What=home-src
Where=/home/forge/src
Type=virtiofs
Options=defaults

[Install]
WantedBy=multi-user.target
```

The tag (`home-src`) MUST match the string passed to `VZVirtioFileSystemDeviceConfiguration::new`. Mismatched tags fail at mount time with a confusing `No such device` error in the guest's journal.

## Hardware acceleration on Apple Silicon

| Feature | Apple Silicon (M-series) | Intel Mac |
|---|---|---|
| Hypervisor.framework backend | hvf (native arm64) | hvf (x86_64) |
| Architecture match for Linux guest | arm64 → use Fedora aarch64 rootfs | x86_64 → use Fedora x86_64 rootfs |
| Rosetta for x86 binaries in guest | macOS 13+: `VZLinuxRosettaDirectoryShare` makes the host's Rosetta visible at `/Library/Apple/usr/libexec/oah/...` inside the guest | N/A (already x86_64) |
| Performance | Near-native; VZ uses hvf | Near-native; VZ uses hvf |

For Tillandsias the practical effect is: **on Apple Silicon, we ship the aarch64 Fedora rootfs**; on Intel Macs (rare in our target demo), we ship the x86_64 rootfs. The host shell detects the architecture via `sysctlbyname("hw.optional.arm64")` and selects the rootfs URL accordingly.

If a forge container needs to run an x86_64 binary on an arm64 guest, we mount the Rosetta directory share and add a `binfmt_misc` registration in the guest. This is a v2 nice-to-have, not part of the Phase-1 design.

## What VZ does NOT give us natively

Three gaps to be aware of:

1. **No display passthrough out of the box.** VZ does not include a Wayland/X11 compositor on the host side. `VZGraphicsDeviceConfiguration` is macOS-guest-only. For a Linux guest, displaying a GUI requires VNC, virtio-gpu + Spice, or a custom path. **Deferred to v2** per the host-shell plan (decision #9). See `macos-vz-gui-research-v2.md`.
2. **No `virtio-balloon`.** VZ uses a different mechanism (`VZMemoryBalloonDeviceConfiguration`). Tillandsias does not enable ballooning in Phase 1.
3. **Snapshots are not supported.** VZ has no `vm.snapshot()` equivalent. Persistent state must live on the root disk; the host's expectation is "VM disk survives reboots; in-VM state survives `vm.stop()` + `vm.start()`".

## Lifecycle commands (Rust shorthand)

| Phase | Call | Effect |
|---|---|---|
| Provision (first run) | Build rootfs.img + write config | One-time, ~30s on M-series |
| Start | `vm.start()` | ~10s to systemd ready |
| Stop graceful | `vm.requestStop()` | Sends ACPI poweroff; honor with up to 30s |
| Stop force | `vm.stop()` | Equivalent to pulling power; safe for ephemeral state |
| Restart | stop → start | No native "reset" call |

The tray's "Tray exit" contract (graceful drain, 30s hard-stop) is implemented as `requestStop` with a 30s timer; on expiry, `stop`.

## Common pitfalls

- **`VZErrorInternal` at validate-time** — usually a CPU/memory budget outside the host's available pool. VZ requires `cpuCount >= 1`, `memorySize >= 128 MiB`; in practice keep memory ≤ half the host RAM.
- **Guest hangs at "Waiting for /dev/vda1"** — the `root=/dev/vda1` kernel arg doesn't match the partition layout in `rootfs.img`. Our rootfs has a single ext4 filesystem with no partition table; use `root=/dev/vda` (no partition suffix).
- **virtio-fs mount fails with `No such device`** — share tag mismatch between host config and `/etc/fstab` or `.mount` unit.
- **vsock returns `EHOSTUNREACH`** — VM not started yet, or the host shell is connecting to a stale CID from a previous run. Re-read `vm.socketDevices()[0]`.
- **Codesigning broken on local dev** — VZ refuses to start without the `com.apple.security.virtualization` entitlement. Use the development codesign in `Cargo.toml` `[package.metadata.bundle]`.
- **Rosetta share absent on Intel Macs** — `VZLinuxRosettaDirectoryShare` only exists on Apple Silicon; guard the share addition with an arch check.

## See also

- `runtime/vsock-transport.md` — the control-wire that activates after VZ boot
- `runtime/macos-vz-gui-research-v2.md` — v2 GUI passthrough research
- `runtime/idiomatic-vm-exec.md` — process-exec layer on top of VZ
- `runtime/wsl2-provisioning.md` — sibling architecture on Windows
- `openspec/specs/macos-native-tray/spec.md` — normative contract
- `openspec/specs/vm-provisioning-lifecycle/spec.md` — shared provisioning contract
