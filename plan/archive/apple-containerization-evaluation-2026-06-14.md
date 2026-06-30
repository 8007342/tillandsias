# Apple `container` / `Containerization` evaluation for the macOS substrate — 2026-06-14

Generated from a research dive requested on the macOS host. Question on the
table: should Tillandsias re-orient the Apple Silicon runtime onto Apple's
open-source `apple/container` framework — i.e. **"WSL2 for Windows,
Apple/container for Apple Silicon"** — instead of the current approach of
driving `Virtualization.framework` directly?

trace: skills/build-install-and-smoke-test-e2e/SKILL.md (consumer of this decision)
       crates/tillandsias-macos-tray/src/vz_lifecycle.rs (current VFR VM driver)
       crates/tillandsias-vm-layer/src/transport_macos.rs (current vsock control wire)
       openspec/specs/macos-native-tray/spec.md

---

## TL;DR verdict — **do NOT adopt `apple/container`; keep Virtualization.framework directly**

`apple/container` runs **one lightweight Linux VM per container** and gates the
host↔guest channel behind an XPC daemon (`container-apiserver`) with **no
vsock exposed at the CLI level**. Tillandsias wants the opposite: **one
long-lived guest VM with a vsock control wire**. We already build exactly that
on `Virtualization.framework` directly (`VZVirtualMachine` + `VZVirtioSocketDevice`),
which is the same primitive `apple/container` is itself built on. Adopting
`apple/container` would mean fighting its grain (per-container VMs, XPC daemon,
macOS-26 floor) to get *less* control than we already have. **Recommendation:
stay on `Virtualization.framework` directly; optionally mine the `Containerization`
Swift package for image/ext4/kernel plumbing ideas, but not as a runtime
dependency.**

This confirms the existing architecture is correctly oriented — the "WSL2 +
Apple/container" framing should be amended to **"WSL2 (single VM) on Windows,
Virtualization.framework (single VM) on Apple Silicon"**, which is what the code
already does.

---

## Architecture (what `apple/container` actually is)

- A Swift CLI that runs Linux OCI containers as lightweight VMs on Apple
  Silicon, built on the open-source **`Containerization`** Swift package.
- **Per-VM model (confirmed):** `container-apiserver` is the daemon; for *each*
  container it launches a `container-runtime-linux` helper plus XPC helpers
  (`container-core-images`, `container-network-vmnet`). It uses
  Virtualization.framework for the VM, vmnet for networking, XPC for host IPC.
- **`vminitd`** is a minimal Swift init (PID 1) inside each VM exposing a gRPC
  API over **vsock (port 1024)**; `vmexec` runs the container entrypoint.
- Contrast with Docker Desktop / Podman / Lima / Colima, which run **one shared
  VM hosting many containers**. Apple inverts this to **one micro-VM per
  container** for stronger isolation.

## Requirements & constraints

- **Apple Silicon only.**
- **Officially macOS 26 (Tahoe).** README: not supported on older macOS, and
  maintainers "typically will not address issues that cannot be reproduced on
  macOS 26."
- **macOS 15 (Sequoia) is degraded:** installable via Homebrew but with a
  documented, load-bearing networking gap — on 15 all containers attach to the
  default vmnet network and **cannot reach each other**; `--network` and the
  network subcommands are unavailable. Per-container isolated networking is a
  macOS-26 feature.
- Ships/optimizes a Linux kernel (`--kernel`, `--init-image` hooks). Rosetta 2
  for linux/amd64 supported.

## Programmatic / Rust embedding

- Two surfaces: the **`container` CLI** (stable: `run|build|create|exec`,
  `system start|stop`, `machine`, `network`) and the **`Containerization` Swift
  package** (the actual library; `cctl` is the reference client).
- **Host↔daemon transport is XPC** — there is **no documented stable
  gRPC/REST API for non-Swift clients** to drive `container-apiserver`. The only
  gRPC is *inside* the VM (`vminitd` over vsock).
- A Rust host could shell out to the CLI, **but the CLI does not expose a raw
  vsock channel to the guest** (`--publish-socket`, `--ssh`, `-p` TCP, volumes
  only). Programmatic vsock requires linking the Swift package via FFI
  (UniFFI / cargo-swift / C-ABI shim).
- Images are OCI; builds are Dockerfile/Containerfile-compatible.

## vsock support (the decisive question)

- **Yes, virtio-vsock to the guest is first-class — via Virtualization.framework's
  `VZVirtioSocketDevice`, surfaced by the `Containerization` package.**
  `vminitd` serves gRPC on vsock port 1024; the VM-management layer exposes
  `dial(_:)` (arbitrary guest port), `listen(_:)` (inbound `VsockListener`),
  backed by `VZVirtioSocketConnection`.
- **Caveat 1:** the `container` *CLI* does not expose vsock — you must go
  through the Swift package or Virtualization.framework directly.
- **Caveat 2:** macOS has **no host `AF_VSOCK`** — Virtualization.framework
  brokers vsock via `VZVirtioSocketDevice` (FD-based), not a Linux-style
  `AF_VSOCK` connect. **This is exactly the constraint Tillandsias already
  handles** in `crates/tillandsias-vm-layer/src/transport_macos.rs` (the
  in-process `VZVirtualMachine` connector).

## Maturity & risk

- **License: Apache-2.0** (both repos). Apple-backed, announced WWDC 2025.
- `container` hit **1.0.0 on 2026-06-09** (introducing the single-persistent-VM
  **"container machine"**); `Containerization` is still 0.x. ~Monthly cadence.
- **~240 open issues**, clustered on networking (DNS, "no route to host", port
  publishing), storage/volumes, registry auth — core paths still stabilizing.
- The underlying Virtualization.framework substrate is mature (used by Lima,
  UTM, vfkit) — the risk is in `apple/container`'s young per-container product
  layer, not the primitive we already use.

## Why this confirms the current Tillandsias design

`crates/tillandsias-macos-tray/Cargo.toml` already declares the macOS tray
"drives a Virtualization.framework-hosted headless tillandsias VM", and
`tillandsias-vm-layer` already abstracts "wsl --exec on Windows,
Virtualization.framework spawn on macOS." That is precisely the
research-recommended path (single long-lived VM + vsock agent). Adopting
`apple/container` would regress us to a per-container model behind an XPC daemon
with a macOS-26 floor — strictly worse for our use case.

### Convergence signal to watch (not adopt)

Apple's new **"container machine"** (1.0.0) is a *single persistent shared Linux
VM* — conceptually the model we want. It's brand-new, CLI-driven, and does not
surface a vsock control channel today. Treat as a signal that Apple is moving
toward our model, not as an API to depend on yet.

---

## Key citations

- apple/container README (macOS 26 floor, Apple Silicon, OCI): https://github.com/apple/container
- Technical overview (apiserver, XPC, per-VM helpers, vmnet): https://github.com/apple/container/blob/main/docs/technical-overview.md
- container-machine (single persistent VM): https://github.com/apple/container/blob/main/docs/container-machine.md
- command-reference (CLI surface; no vsock; `--kernel`/`--init-image`): https://github.com/apple/container/blob/main/docs/command-reference.md
- apple/containerization README (vminitd, gRPC over vsock, Rosetta, cctl): https://github.com/apple/containerization
- VM management / vsock internals (`dial`/`listen`, `VZVirtioSocketConnection`, port 1024): https://deepwiki.com/apple/containerization/2.3-virtual-machine-management
- macOS 15 networking limitation: https://github.com/apple/container/issues/345 , https://github.com/apple/container/discussions/1170
- 1.0.0 release (date, container machine): https://github.com/apple/container/releases/tag/1.0.0
- libkrun / krunkit (single-VM C-library alternative; vsock↔UNIX proxy): https://github.com/containers/libkrun , https://lima-vm.io/docs/config/vmtype/krunkit/

---

## Work Packet: apple-container/spec-amendment

- id: `apple-container/spec-amendment`
- owner_host: macos
- capability_tags: [macos, docs, openspec, vm-layer]
- status: done
- completed_at: 2026-06-15T04:40Z
- completion_note: >
    Amended openspec/specs/macos-native-tray/spec.md under the
    "Virtualization.framework guest lifecycle is owned by this binary"
    requirement: added the 2026-06-14 substrate decision (single long-lived VFR
    VM + vsock, NOT apple/container per-container) and a new scenario
    "Substrate is Virtualization.framework directly, not apple/container"
    asserting zero runtime dependency on the apple/container product and a
    macOS-26 floor. Links back to this evaluation file.
- discovered_by: `/build-install-and-smoke-test-e2e` research dive (2026-06-14)
- evidence:
  - this file (verdict: keep Virtualization.framework directly; do not adopt apple/container)
  - `crates/tillandsias-vm-layer/Cargo.toml:7` — already "Virtualization.framework spawn on macOS"
- next_action: >
    Amend the macOS-substrate narrative in `openspec/specs/macos-native-tray/`
    (and any "WSL2 + Apple/container" framing in methodology) to state the
    decision explicitly: **single-VM Virtualization.framework, NOT
    apple/container per-container**, with the macOS-26 floor + no-CLI-vsock
    rationale recorded. Keep `apple/container`'s "container machine" on a
    watch-list note.
- events:
  - type: discovered
    ts: `2026-06-14T00:00:00Z`
    agent_id: macos-claude-opus
    host: macos
</content>
