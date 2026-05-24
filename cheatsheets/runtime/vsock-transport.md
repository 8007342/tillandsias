---
tags: [vsock, virtio, transport, ipc, vm, control-wire, host-shell]
languages: [rust, bash]
since: 2026-05-23
last_verified: 2026-05-23
sources:
  - openspec/specs/vsock-transport/spec.md
  - openspec/specs/host-shell-architecture/spec.md
  - crates/tillandsias-control-wire/src/lib.rs
  - https://man7.org/linux/man-pages/man7/vsock.7.html
  - https://docs.kernel.org/networking/af_vsock.html
authority: medium
status: proposed
tier: bundled
---

# virtio-vsock transport for the Tillandsias control wire

@trace spec:vsock-transport
@cheatsheet runtime/idiomatic-vm-exec.md

**Use when**: wiring the Windows/macOS host shell to the in-VM `tillandsias-headless`, debugging host↔VM control traffic, or extending `tillandsias-control-wire` with a new message type that must traverse the hypervisor boundary.

## Provenance

- Linux `vsock(7)` — `AF_VSOCK` socket family, addressing model
- kernel.org `af_vsock` networking docs — CID semantics, port allocation
- `openspec/specs/vsock-transport/spec.md` — Tillandsias contract
- `crates/tillandsias-control-wire/src/lib.rs` — wire framing and message envelopes (extended by this spec)

## What is vsock and why it matters here

virtio-vsock is a hypervisor-level socket family that lets a host process and a guest VM process exchange data **without involving any TCP/IP stack**. The pipe is two virtio rings shared between host and guest; there is no NAT, no bridge, no DHCP, and no DNS — addresses are stable integers assigned at VM-config time.

For Tillandsias' Windows + macOS native shells the relevant property is **transport invariance**: the existing `tillandsias-control-wire` framing (`4-byte BE u32 length || postcard(ControlEnvelope)`) survives unchanged. Only the listener/connector changes. The wire stays portable.

## The CID model in one paragraph

Every vsock endpoint is `(CID, port)`. CID = "context ID", a 32-bit integer that identifies a VM (or the host).

| CID | Meaning |
|---|---|
| `0` | reserved / hypervisor (do not use) |
| `1` | local / loopback inside a single VM (rare; Linux-only) |
| `2` | the host |
| `3+` | guest VMs, assigned at VM creation |

On Windows + WSL2 the Hyper-V root partition is CID 2; each WSL distro gets a CID auto-assigned at launch. On macOS, the Virtualization.framework guest CID is set **explicitly** when building `VZVirtioSocketDeviceConfiguration`, so Tillandsias chooses it deterministically (e.g. `42`).

The control-wire port for Tillandsias is the stable constant **`42420`**. Both sides agree on this at build time; there is no service discovery.

## End-to-end flow

```
┌─────────────────────────────┐               ┌──────────────────────────────┐
│ Host (Win11 / macOS)        │  vsock        │ Fedora 44 VM                 │
│                             │  CID host=2   │                              │
│ tillandsias-tray            │ <───────────> │ tillandsias-headless         │
│  └─ vsock_client::connect() │   port 42420  │  └─ vsock_server::bind()     │
│       cid: <vm-cid>         │               │       cid: VMADDR_CID_ANY    │
│       port: 42420           │               │       port: 42420            │
└─────────────────────────────┘               └──────────────────────────────┘
```

The host **connects** to `(vm_cid, 42420)`. The guest **binds** on `(VMADDR_CID_ANY, 42420)` — the kernel routes the guest's accept to whichever host opens the connection.

## Rust — idiomatic snippets

The recommended crate is `tokio-vsock` (re-exports `AF_VSOCK` over tokio's `AsyncRead`/`AsyncWrite`). On Windows, vsock support is layered over Hyper-V sockets; `tokio-vsock` abstracts over the difference on supported platforms. macOS host support requires the host process to use `VZVirtioSocketDevice::connect` via `objc2-virtualization` — see `vz-framework-provisioning.md`.

### Guest-side bind (runs inside the VM as `tillandsias-headless`)

```rust
use tokio_vsock::{VsockListener, VsockStream, VMADDR_CID_ANY};

pub async fn run_control_listener(port: u32) -> std::io::Result<()> {
    let listener = VsockListener::bind(VMADDR_CID_ANY, port)?;
    loop {
        let (stream, addr) = listener.accept().await?;
        tracing::info!(?addr, "accepted control-wire client");
        tokio::spawn(handle_control_session(stream));
    }
}
```

### Host-side connect (Windows tray; macOS uses the VZ-specific path)

```rust
use tokio_vsock::VsockStream;

pub async fn connect_to_vm(vm_cid: u32) -> std::io::Result<VsockStream> {
    // 42420 = the stable Tillandsias control-wire port
    VsockStream::connect(vm_cid, 42420).await
}
```

### Framing (unchanged from the Unix-socket variant)

```rust
// Wire: u32-BE length || postcard(ControlEnvelope)
// Same code path used for Unix and vsock — the transport is just
// an AsyncRead + AsyncWrite.
async fn write_envelope<W: tokio::io::AsyncWrite + Unpin>(
    w: &mut W,
    env: &ControlEnvelope,
) -> Result<()> {
    let bytes = postcard::to_allocvec(env)?;
    let len = u32::try_from(bytes.len())?;
    w.write_all(&len.to_be_bytes()).await?;
    w.write_all(&bytes).await?;
    w.flush().await?;
    Ok(())
}
```

## CID discovery — how the host learns the guest CID

This is the part that differs per backend.

### Windows / WSL2

WSL2 distros run as Hyper-V utility VMs. Each distro gets a CID at start time, surfaced via the Hyper-V VM ID. Discovery options, in order of preference:

1. **`wsl.exe --list -v --verbose-export`** (Windows 11 22H2+) — emits a JSON document including the Hyper-V VM ID per distro. Map the VM ID to a CID via the Hyper-V API.
2. **Hyper-V Compute API** (`HCS`) — `HcsEnumerateComputeSystems` plus `HcsGetComputeSystemProperties`. Stable but heavier.
3. **Convention**: keep a single distro named `tillandsias`. Each tray launch re-resolves its CID.

### macOS / Virtualization.framework

Tillandsias chooses the guest CID when building the VM config. The macOS host shell stores the chosen CID in memory for the VM's lifetime; restart picks the same value (e.g. constant `42`) — there are no collisions because each Tillandsias install has at most one VM.

### Inside the guest

`/proc/sys/net/vmaddr/host_cid` reports the host CID (always `2`). `cat /proc/sys/net/vmaddr/local_cid` reports the guest's own CID. Useful for logging during early-boot diagnostics.

## Debugging with socat

`socat` ships a `VSOCK-LISTEN` / `VSOCK-CONNECT` address pair on most distros (Fedora 44 includes it in the default `socat` package). Two recipes:

### Listen inside the VM, type from the host

```bash
# Inside the VM
socat -d -d VSOCK-LISTEN:42420,reuseaddr,fork -
```

```bash
# From the host (Linux with vsock module loaded)
socat - VSOCK-CONNECT:<vm-cid>:42420
# Type anything; it appears on the VM stdout.
```

### Listen on the host, type from inside the VM

```bash
# Host
socat -d -d VSOCK-LISTEN:42420,reuseaddr,fork -
```

```bash
# Guest
socat - VSOCK-CONNECT:2:42420   # 2 is always the host CID
```

If nothing is received, check the failure-mode list below before suspecting Tillandsias code.

## Failure modes

### `Cannot assign requested address` on bind

The host or guest kernel does not have the vsock module loaded.

```bash
lsmod | grep -E 'vsock|vhost_vsock'
# Expected on host:  vhost_vsock + vmw_vsock_virtio_transport_common
# Expected on guest: vsock + vmw_vsock_virtio_transport
sudo modprobe vhost_vsock     # host side
sudo modprobe vsock           # guest side (almost always already loaded)
```

On WSL2, `vhost_vsock` is built into the Microsoft kernel; no modprobe needed. On macOS, vsock support comes from the Virtualization.framework binding — there is no host-side kernel module.

### `Connection refused` on the host

Guest is up, but `tillandsias-headless` is not listening yet (boot race) or the guest CID is wrong. Verify with `socat - VSOCK-CONNECT:<cid>:42420`. If `socat` connects but Tillandsias does not, the guest port is wrong.

### CID collision on macOS

If two Tillandsias installs ever ran on the same host (test machine) and both used CID `42`, the second VM start fails with `EADDRINUSE`. Pick a different constant in the VM config; `tillandsias-vm-layer` defaults to `42` but accepts an override env (`TILLANDSIAS_VM_CID=<n>`).

### WSL2 CID changes across `wsl --shutdown`

The CID is allocated at VM start. After `wsl --shutdown` the next start picks a new CID. The host shell **must not cache** the CID across VM lifecycle transitions; always re-resolve on `VmRuntime::start` completion.

### `Permission denied` on `VsockListener::bind` (guest)

Some kernels gate `AF_VSOCK` bind to `CAP_NET_BIND_SERVICE` for ports below 1024. Tillandsias uses `42420` to side-step this. If you ever lower the port, expect to need a capability or a setuid wrapper.

### Mirrored networking interference

WSL2 in `networkingMode = mirrored` does NOT affect vsock — vsock is below the IP stack. If the control wire is broken but TCP works (or vice versa), the symptom is not "mirrored vs NAT"; it is either CID mismatch or the vsock module is missing.

## Wire-version handshake

The first frame after a fresh connect MUST be `ControlEnvelope::Hello { wire_version: WIRE_VERSION }`. The peer replies `HelloAck { wire_version, accepted: bool }`. If `accepted == false`, the connection is closed with a `VersionMismatch` envelope before close. This is the same as the Unix-socket variant; the transport change does NOT relax the handshake.

## When to use vsock vs Unix socket

| Scenario | Transport |
|---|---|
| Single-process Linux tray talking to its own `tillandsias-headless` | Unix socket at `$XDG_RUNTIME_DIR/tillandsias/control.sock` |
| Windows tray → in-VM headless | vsock `(vm_cid, 42420)` |
| macOS tray → in-VM headless | vsock `(vm_cid, 42420)` via VZVirtioSocketDevice |
| Inside-VM client talking to in-VM headless | Unix socket (avoid vsock loopback complexity) |

## See also

- `runtime/idiomatic-vm-exec.md` — process-exec layer that rides on top of this transport
- `runtime/wsl2-provisioning.md` — how the WSL2 distro is brought up before the vsock listener starts
- `runtime/vz-framework-provisioning.md` — macOS VZ-side vsock device wiring
- `openspec/specs/vsock-transport/spec.md` — normative contract
- `openspec/specs/host-shell-architecture/spec.md` — the shared host-shell contract that consumes this transport
