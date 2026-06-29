# vsock-in-vsock: Fedora 44 Guest → Podman Container Channel Design

**Filed:** 2026-06-29  
**Kind:** architecture research  
**Status:** research (no implementation yet)  
**Trace:** `spec:vsock-transport`, `openspec/changes/control-wire-pty-attach`, `spec:vm-idiomatic-layer`

---

## Executive Summary

**Is vsock-in-vsock (container → Fedora 44 via vsock) feasible in WSL2?**

**Yes, conditionally.** The mechanism is vsock loopback (Linux `vsock_loopback` driver, kernel >= 5.14), NOT "CID 2" as one might assume. Critical correction:

> `VMADDR_CID_HOST` (2) inside a podman container on Fedora 44 WSL2 routes to the **Windows Hyper-V host**, not to Fedora 44. CID 2 is always the hypervisor's host side. Container → Fedora 44 communication via AF_VSOCK must use `VMADDR_CID_LOCAL` (1) or the VM's own assigned CID, routed internally by the `vsock_loopback` kernel driver.

**Blocker to verify**: whether the WSL2 custom kernel (microsoft/WSL2-Linux-Kernel) includes `CONFIG_VSOCKETS_LOOPBACK`. This driver was added upstream in 5.14 but is NOT guaranteed in the WSL2 kernel config. This is the single most important open question before committing to a vsock-in-vsock approach.

---

## CID Topology — Corrected Model

```
Windows host (CID 2, VMADDR_CID_HOST)
    │
    │  AF_HYPERV (hvsocket)
    │
Fedora 44 WSL2 guest (CID = N, assigned by Hyper-V, e.g. CID 7)
    │  Runs: tillandsias-headless, listening on VMADDR_CID_ANY:42420
    │
    │  Inside the VM kernel:
    │
    ├── container: tillandsias-vault-forge
    │     network namespace: separate
    │     vsock CID: NONE (shares the VM's CID = N)
    │     /dev/vsock: must be explicitly passed (--device /dev/vsock)
    │
    └── container: tillandsias-<project>-forge
          vsock CID: NONE (same — shares CID N)
```

**Key invariants:**
- No podman container gets its own vsock CID. CIDs are VM-level, not container-level.
- `VMADDR_CID_HOST` (2) from inside a container = Windows, always.
- `VMADDR_CID_LOCAL` (1) = vsock loopback — routes to the local VM's own listeners.
- To reach `tillandsias-headless` on the Fedora 44 rootfs from inside a container, a process must connect to `VMADDR_CID_LOCAL:42421` (loopback port distinct from the host control wire port 42420).

---

## Kernel / Runtime Prerequisites Checklist

| Prerequisite | Minimum version | How to check in WSL2 | Status |
|---|---|---|---|
| `AF_VSOCK` in kernel | Linux 4.8 | `cat /proc/net/protocols \| grep VSOCK` | Expected present (WSL2 ≥ 5.10) |
| `hv_vsock` Hyper-V driver | Kernel build with `CONFIG_HYPERV_VSOCKETS=y` | `lsmod \| grep hv_sock` | Expected present |
| `vsock_loopback` driver | Linux 5.14 | `lsmod \| grep vsock_loopback` OR `zcat /proc/config.gz \| grep VSOCK_LOOPBACK` | **Unknown — must verify** |
| `/dev/vsock` accessible to rootless podman | Kernel + device perms | `ls -la /dev/vsock && podman run --device /dev/vsock alpine ls /dev/vsock` | **Unknown** |
| `VMADDR_CID_LOCAL` (1) loopback connect works | `vsock_loopback` loaded | `socat VSOCK-LISTEN:42421,fork - & socat - VSOCK-CONNECT:1:42421` | **Must test** |
| SELinux vsock policy hooks available | Fedora 44 SELinux + targeted policy | `sestatus && getsebool allow_socket_connect` | Expected on Fedora 44 |

**Action before any implementation**: run the following inside the WSL2 distro:

```bash
# Check vsock_loopback
zcat /proc/config.gz 2>/dev/null | grep -E 'VSOCK|LOOPBACK' || \
  grep -E 'VSOCK|LOOPBACK' /boot/config-$(uname -r) 2>/dev/null

# Test loopback connectivity
socat VSOCK-LISTEN:59999,fork STDOUT &
sleep 1
echo "test" | socat - VSOCK-CONNECT:1:59999
# Expected output: "test" if vsock_loopback works
```

---

## Option Comparison

| | Option A: vsock-loopback (CID 1) | Option B: Per-container ports | Option C: Unix socket passthrough | Option D: socat bridge |
|---|---|---|---|---|
| **Mechanism** | Container → VMADDR_CID_LOCAL (1) → Fedora 44 listener | Same as A, different port per container | Container writes to shared Unix socket | socat VSOCK-LISTEN → podman exec |
| **"vsock at every boundary"** | Yes (host→VM + VM→container) | Yes | No (last hop is Unix socket) | No (last hop is podman exec) |
| **Kernel requirement** | vsock_loopback (5.14), must verify in WSL2 | Same | None beyond existing | None |
| **CID isolation** | No — any container with /dev/vsock can connect | No — same | No — filesystem ACL only | N/A |
| **SELinux enforceable** | Yes — vsock port labels | Yes — per-port labels | Yes — socket file labels | Minimal |
| **Port namespace** | Per VM (not per container) | Per VM, per service | Per container (filesystem) | N/A |
| **podman exec eliminated** | Yes, for data path | Yes | No — still uses exec or UDS | No |
| **Complexity** | Medium (kernel dep + container vsock listener) | Medium-high (listener per service) | Low | Very low |
| **Security boundary** | Weak — shared CID, application-layer only | Weak — same | Medium — filesystem ownership | Weak — exec injection risk |
| **Risk** | High — WSL2 kernel support unknown | High — same | Low | Low |
| **Effort** | 2-3 weeks | 3-4 weeks | 1 week | Days |

---

## Recommended Design Path

### Phase 1 (Immediate, 1 week): Option C — Unix Socket Passthrough

While `vsock_loopback` support in WSL2 is verified, implement the secure data path using Unix domain sockets shared via a tmpfs volume. This eliminates `podman exec -it` for the PTY data path without any kernel dependency.

Architecture:
```
Windows host
    │ HvSocket (AF_HYPERV)
    ▼
Fedora 44: tillandsias-headless (port 42420)
    │ Unix socket: /run/tillandsias/containers/<name>/pty.sock
    ▼
Container: tillandsias-<project>-forge
    │ reads/writes /run/tillandsias/containers/my-project/pty.sock
    │ (bind-mounted from Fedora 44 tmpfs)
    ▼
PTY subprocess (bash, coding agent)
```

- Headless creates `/run/tillandsias/containers/<project>/pty.sock`
- Container image runs `tillandsias-container-agent` which listens on that socket
- PTY session negotiated via the same postcard framing (new `ContainerPtyRequest` message)
- ACL: socket owned by container UID, mode 0600

This is already the idiomatic model used by Lima/Colima (guest agent over Unix socket bridged from host).

### Phase 2 (After kernel verification, 2-3 weeks): Option A — vsock Loopback

If `CONFIG_VSOCKETS_LOOPBACK=y` is confirmed in the WSL2 kernel:

```
Windows host
    │ AF_HYPERV port 42420 (HvSocket)
    ▼
Fedora 44: tillandsias-headless
    │ AF_VSOCK VMADDR_CID_LOCAL (1) port 42421
    ▼
Container: tillandsias-<project>-forge
    │ (given --device /dev/vsock)
    │ connects to CID 1:42441 (per-container port)
    ▼
Container vsock listener → PTY subprocess
```

The headless listens on:
- Port 42420: host control wire (Windows HvSocket connections)
- Port 42421: container control wire dispatcher (accepts loopback vsock from containers)

Each container type gets a port assignment (see Port Allocation below).

### Phase 3 (Long-term): SELinux policy enforcement at every boundary

---

## Port Allocation Table

All ports are per-VM-CID (not per-process, not per-network-namespace). These are the vsock port assignments for the `tillandsias` distro:

| Service | Purpose | vsock port | Container name pattern |
|---|---|---|---|
| `CONTROL_WIRE_VSOCK_PORT` | Host ↔ Fedora 44 control wire | 42420 | — (VM rootfs) |
| `CONTAINER_WIRE_VSOCK_PORT` | Fedora 44 ↔ container dispatcher | 42421 | — (VM rootfs listener) |
| `VAULT_VSOCK_PORT` | Vault container API | 42430 | `tillandsias-vault` |
| `GIT_MIRROR_VSOCK_PORT` | Git mirror container | 42431 | `tillandsias-git-mirror` |
| `INFERENCE_VSOCK_PORT` | Inference/Ollama container | 42450 | `tillandsias-inference` |
| Forge (per project) | Project forge containers | 42440–42439+N | `tillandsias-<project>-forge` |

Port constants should be exported from `tillandsias-control-wire::transport` alongside `CONTROL_WIRE_VSOCK_PORT`.

For forge containers, since there can be many projects, allocate by hash:
```rust
pub fn forge_vsock_port(project_name: &str) -> u32 {
    // 200 port range: 42440..42639
    let h = crc32fast::hash(project_name.as_bytes());
    42440 + (h % 200)
}
```

Collision probability for a single user with typical project counts (<10) is negligible.

---

## The "Idiomatic Exec" Pivot — What Changes

Current `launch_spec` in `crates/tillandsias-host-shell/src/pty/mod.rs`:
```rust
// When project is Some(p), wraps inner command in:
vec!["podman", "exec", "-it", "tillandsias-<p>-forge", <inner>]
```

This sends the full `podman exec -it` invocation as the argv in `PtyOpen` to `tillandsias-headless`. The headless then runs `podman exec` as a subprocess with PTY allocation — awkward signal handling, CTRL+C quirks, and no vsock isolation.

**Target design** (Phase 2):

1. **New `PtyOpen` field**: `container_vsock_port: Option<u32>` — when set, the headless dials the container's vsock listener instead of spawning `podman exec`.

2. **New container agent**: each forge image ships `tillandsias-container-agent`, a small binary that:
   - Listens on `/dev/vsock` (via `--device /dev/vsock` passed at launch) on its assigned port
   - Accepts connections from CID 1 (VMADDR_CID_LOCAL) only — enforced at application level and by SELinux
   - Spawns a PTY subprocess for `PtyOpen` messages, using the same control-wire framing
   - Returns `PtyData` / `PtyClose` over vsock back to `tillandsias-headless`

3. **`tillandsias-headless` dispatch change**: on receiving `PtyOpen` with `container_vsock_port: Some(p)`:
   - Opens AF_VSOCK connection to `VMADDR_CID_LOCAL:p`
   - Performs the mini container-agent handshake
   - Bridges the PTY frames bidirectionally between the host control wire and the container vsock connection

4. **`launch_spec` change**: `PtyOpenOpts` gains `target: PtyTarget` where:
   ```rust
   pub enum PtyTarget {
       VmRootfs,
       Container { vsock_port: u32 },
   }
   ```
   The `Container` variant replaces the `podman exec -it` argv wrapper.

**Cargo work needed:**
- `tillandsias-control-wire`: add `container_vsock_port: Option<u32>` to `PtyOpen` message (postcard-stable, additive)
- `tillandsias-host-shell/src/pty/mod.rs`: add `PtyTarget` enum, update `PtyOpenOpts`, update `launch_spec`
- `tillandsias-headless/src/pty_handler.rs`: dispatch `PtyOpen` to container vsock when `container_vsock_port` is set
- New crate (or module) `tillandsias-container-agent`: vsock listener for forge/service containers
- Container images: install `tillandsias-container-agent` binary, launch it as a service

---

## Security Model

### Boundary 1: Windows host → Fedora 44 (AF_HYPERV)
- **Isolation**: Hyper-V GUID ACL — only processes on the Windows host with access to the WSL utility VM GUID can connect.
- **Authentication**: control-wire Hello/HelloAck with `WIRE_VERSION` check.
- **What this protects**: no process on Windows can hijack the headless connection without Hyper-V VM access (administrator level).
- **Current gap**: no per-connection credential beyond the `installation_uuid` delivery at connect time.

### Boundary 2: Fedora 44 → Container (AF_VSOCK loopback, CID 1)
- **Isolation**: vsock_loopback is intra-VM only — no Hyper-V traversal.
- **Authentication**: container-agent Hello variant with container-identity token (short-lived, AppRole-minted by headless at container launch, never in vsock frames).
- **What this protects**: a rogue process that gains `/dev/vsock` in a compromised container cannot connect to a container-agent on port 42440 without presenting the valid AppRole token — the handshake rejects unauthenticated peers.
- **Remaining concern**: vsock is not namespace-isolated by CID (all containers with /dev/vsock share the VM CID). Port-level isolation is the only vsock-level boundary. SELinux vsock port labels (`vsock_port_t`) enforce which container's security domain can bind or connect to which vsock port.

### Boundary 3: Credential path (Vault tokens)
- Vault tokens are NEVER in vsock frames. The control wire `ControlMessage` invariant `no-tokens-in-messages` applies to both the host control wire and the container control wire.
- Vault token delivery to containers uses short-lived podman secrets (mounted at container start) or `podman exec vault kv get` (exec isolation). Neither path transits vsock.

### SELinux Labels (target policy)
```
# Container-agent vsock listener domain
type tillandsias_container_agent_t;

# Allow container-agent to bind its assigned vsock port
allow tillandsias_container_agent_t { vsock_port_t:vsock_socket name_bind };

# Allow headless to connect to container-agent vsock ports
allow tillandsias_headless_t { vsock_port_t:vsock_socket name_connect };

# Restrict /dev/vsock access to only authorized domains
allow tillandsias_container_agent_t vsock_device_t:chr_file { read write open ioctl };
deny ~{ tillandsias_container_agent_t tillandsias_headless_t } vsock_device_t:chr_file { read write };
```

---

## Implementation Task List

Ordered from least to most dependent:

| # | Task | File(s) | Effort | Depends on |
|---|---|---|---|---|
| 1 | **Verify vsock_loopback in WSL2** | WSL2 kernel config | 1h | Nothing — do immediately |
| 2 | **Verify /dev/vsock rootless podman** | Manual test in distro | 1h | Nothing |
| 3 | **Port constants in control-wire** | `tillandsias-control-wire/src/transport.rs` | 1h | Nothing |
| 4 | **Phase 1: Unix socket passthrough** (interim) | `tillandsias-headless/src/container_dispatch.rs` (new), container images | 1 week | Nothing |
| 5 | **Add `PtyTarget` to `PtyOpenOpts`** | `tillandsias-host-shell/src/pty/mod.rs` | 2h | Port constants |
| 6 | **Add `container_vsock_port` to `PtyOpen`** | `tillandsias-control-wire/src/lib.rs` | 2h | Needs postcard-stable slot |
| 7 | **tillandsias-container-agent binary** | New crate | 1 week | Port constants, vsock_loopback confirmed |
| 8 | **Headless container dispatch** | `tillandsias-headless/src/pty_handler.rs` | 3 days | Container-agent binary, vsock_loopback |
| 9 | **Update container images** | Containerfiles for forge/git-mirror/vault | 2 days | Container-agent binary |
| 10 | **Update launch_spec** | `tillandsias-host-shell/src/pty/mod.rs` | 1 day | PtyTarget, container dispatch |
| 11 | **SELinux policy for vsock** | SELinux policy module in images | 1 week | All above |
| 12 | **Remove `podman exec -it` from PTY path** | `pty/mod.rs` launch_spec | 1h | Tasks 8-10 proven |

---

## Open Questions

1. **Does WSL2's kernel ship `CONFIG_VSOCKETS_LOOPBACK=y`?**
   Run: `zcat /proc/config.gz | grep VSOCKETS_LOOPBACK` in the `tillandsias` distro.
   - If NO: vsock-in-vsock via loopback is unavailable. Phase 2 is blocked. Use Unix socket passthrough indefinitely or patch the WSL2 kernel.
   - If YES: proceed to Phase 2.

2. **Can rootless podman pass `/dev/vsock` to a container?**
   Run: `podman run --rm --device /dev/vsock alpine ls /dev/vsock`
   - If NO: containers cannot use vsock directly. Must use Unix socket passthrough.
   - Workaround: if rootless blocks device pass-through, can headless (running as root in systemd service) pass the vsock fd to containers at launch via socket activation?

3. **What is the Fedora 44 WSL2 distro's assigned CID?**
   Run: `cat /sys/class/vsock/vsock*/local_cid` OR `ioctl(fd, IOCTL_VM_SOCKETS_GET_LOCAL_CID)`.
   This determines what CID the container must connect to if CID 1 (loopback) doesn't work.

4. **Does `VMADDR_CID_LOCAL` (1) work for intra-VM vsock in WSL2's hv_sock driver?**
   The `vsock_loopback` transport hooks into the CID 1 routing. If `hv_vsock` intercepts CID 1 first, the loopback transport may not activate. This depends on the kernel's `vsock_core_get_transport` dispatch order.

5. **Podman exec PTY signal semantics**: before we eliminate `podman exec`, confirm the exact SIGWINCH and SIGTERM delivery semantics differ in a way that justifies the complexity. The current path works; the vsock path is better but not worth breaking for.

6. **Port collision for forge containers**: if two forge containers hash to the same port (42440+h%200), one container-agent cannot bind. The headless must detect this and either pick an alternate port or refuse to launch the second container. Resolve before implementing port allocation.

---

## Notes for Cross-Host Parity

- **macOS VZ**: `VZVirtioSocketDeviceConfiguration` already provides a true AF_VSOCK device to the guest. The container→guest vsock loopback question is the same: containers inside the VZ guest need the same verification. But VZ's vsock implementation may differ from `hv_vsock` in CID semantics.
- **Linux native tray**: no VM boundary. Containers talk to the headless via the existing Unix socket or podman network. vsock-in-vsock is a Windows/macOS concern only.
- The `PtyTarget::Container { vsock_port }` abstraction must be cross-host: macOS sends the same `PtyOpen` with `container_vsock_port: Some(42441)` and the VZ-hosted headless resolves it identically.
