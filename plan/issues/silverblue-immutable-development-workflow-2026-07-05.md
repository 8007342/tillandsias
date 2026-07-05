# Research: Fedora Silverblue Immutable Host Development Parity — 2026-07-05

- class: research+infra
- filed: 2026-07-05
- owner: linux
- status: ready
- related:
  - plan/issues/embedded-guest-binary-linux-build-2026-07-05.md (done)
  - plan/issues/vault-selinux-label-rootless-crash-2026-07-02.md (done)

## Context & Objective

We prefer **immutable Linux hosts** (Fedora Silverblue) for our development and worker agents over mutable Workstations. While rootless container execution works natively out of the box, building the full project on Silverblue has historically encountered package-layer limits and cross-compilation roadblocks.

This document inventories the findings from native building and container bootstrap trials, identifies remaining gaps, and outlines a concrete roadmap to support 100% of the tillandsias dev workflow on Silverblue.

---

## 1. Current Gaps & Blockers

### A. Guest Binary Cross-Compilation (x86_64 → aarch64)
* **Status**: BLOCKED (Host-Native) / SOLVED (via Nix/Container)
* **Detail**: The tray bundles both `x86_64` and `aarch64` static Linux binaries. Compiling `aarch64` on an `x86_64` host requires a cross-toolchain (`gcc-aarch64-linux-gnu`) or Nix. Note that even after layering `gcc-aarch64-linux-gnu` via `rpm-ostree` and rebooting, host-native compilation still fails on C-based library dependencies (such as `ring`) with `assert.h` missing errors. This is because Fedora's official cross-compiler package is designed for bare-metal/kernel builds and does not include standard target C library (glibc) headers or development files.
* **Impact**: Developers on Silverblue cannot natively build the matching `aarch64` guest binary contract for macOS hosts unless they manually maintain a custom sysroot/header path on the host, or delegate to a mutable builder container (Toolbx/Distrobox) where cross-compilation toolchains with headers can be safely configured.

### B. Rootless SELinux Constraints
* **Status**: SOLVED (Graceful Fallback)
* **Detail**: The project uses custom SELinux modules (`vault_container.cil`) to confine Vault. Loading policies via `semodule -i` requires host root privileges.
* **Impact**: On a rootless host execution path, `semodule` returns `Permission denied`. We have successfully implemented a fallback that silences these warnings and degrades to `container_t` with `label=disable` (unconfined on host but isolated via container namespaces), which is secure-safe for local development.

### C. Host-to-Container DNS Resolution & Ports
* **Status**: PARTIAL
* **Detail**: Headless and tray services resolve container identities (like `vault`) using Podman's internal Aardvark DNS. Without root on the host, modifying `/etc/hosts` or systemd-resolved to route single-label domains (like `vault:8200`) into the Podman bridge gateway fails.
* **Impact**: Standalone CLI flows like `--github-login` must publish ports (e.g. `-p 127.0.0.1:8201:8200`) and map localhost instead of routing directly to the container alias, which creates differences in network topology between local Linux dev and the macOS VM guest environments.

---

## 2. Findings: What Works Natively on Silverblue

During our validation, we verified the following compiles and executes directly from the host userland:
1. **Native host-musl build**:
   By using `rust-lld` (packaged in the Rust toolchain) and standard `gcc` with self-contained musl linkage, we can build the native `x86_64-unknown-linux-musl` target on the host without `rpm-ostree` layers:
   ```bash
   CC_x86_64_unknown_linux_musl=gcc \
   CARGO_TARGET_X86_64_UNKNOWN_LINUX_MUSL_LINKER=rust-lld \
   CARGO_TARGET_X86_64_UNKNOWN_LINUX_MUSL_RUSTFLAGS="-C link-self-contained=yes" \
   cargo build --release --target x86_64-unknown-linux-musl
   ```
2. **Status Smoke Checks**:
   Once container images are tagged, the local status verification runs successfully:
   ```bash
   tillandsias --status-check # Pass
   ```
3. **Tray GUI Daemonization**:
   The native launcher successfully initializes Vault and daemonizes to the background under Wayland/X11:
   ```bash
   tillandsias --tray # Runs in Wayland session
   ```

---

## 3. The Proposed Path: Standardizing on Toolbx/Distrobox

To run 100% of the development and build workflow on an immutable host without system modification, we should standardize the dev loop inside a **Toolbx (or Distrobox)** container.

### Why Toolbx?
1. **Mutable Userland**: Toolbx runs a mutable Fedora container sharing the host's home directory, Wayland/X11 sockets, SSH agents, and Podman socket.
2. **Zero System Pollution**: We can install cross-compilers, Nix, and debug packages (`dnf install gcc-aarch64-linux-gnu`) inside the Toolbx container without ever modifying the host's immutable `/usr` or requiring reboots.
3. **Identical Execution**: Commands run inside Toolbx see the host's user podman daemon (via `/run/user/1000/podman/podman.sock` mount), meaning they launch and control the same rootless containers.

---

## 4. Proposed Action Plan

### Step 1: Create a canonical `tillandsias-dev` Toolbx/Distrobox Profile
* Add a `Containerfile` and script under `scripts/setup-toolbx.sh` to:
  * Spin up a Toolbx image.
  * Install `rustup`, `gcc-aarch64-linux-gnu`, `nix`, `git`, and build tools.
  * Map the user's Podman socket inside the container.

### Step 2: Update `build.sh` to auto-detect and support Toolbx
* Detect if running inside a Toolbx container (checks `/run/.containerenv`).
* If inside Toolbx, build guest binaries using the system cross-compiler by default.

### Step 3: Implement rootless DNS proxying
* Integrate a rootless DNS forwarder (like `gvproxy` or a dnsmasq sidecar container) so host/Toolbx applications can resolve `vault` and `inference` aliases without editing the host's `/etc/hosts` or `/etc/resolv.conf`.
