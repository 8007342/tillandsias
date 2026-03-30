---
id: podman-machine
title: Podman Machine (macOS/Windows VM Layer)
category: infra/containers
tags: [podman, machine, macos, windows, vm, gvproxy, virtio, apple-hv]
upstream: https://docs.podman.io/en/latest/markdown/podman-machine.1.md
version_pinned: "5.4"
last_verified: "2026-03-30"
authority: official
---

# Podman Machine

On non-Linux hosts, Podman runs containers inside a managed Linux VM.
`podman machine` controls this VM layer. On native Linux, it is not needed.

## Architecture

```
Host (macOS / Windows)
+--------------------------+
| podman CLI               |  <-- talks to VM via SSH + API socket
| gvproxy (user-mode net)  |  <-- port forwarding, DNS
+--------------------------+
        |  API socket + SSH
        v
+------------------------------+
| Linux VM (Fedora CoreOS)     |
|  podman engine (rootless)    |
|  containers run here         |
+------------------------------+
        |  virtiofs / 9p
        v
  Host filesystem (mounts)
```

The CLI on the host forwards commands over SSH to the podman engine inside
the VM. There is no persistent daemon on the host -- each CLI invocation
connects, executes, and disconnects.

## Hypervisor Providers

| Platform | Default Provider | Alternatives |
|----------|-----------------|--------------|
| macOS    | Apple Hypervisor Framework (`applehv`) | `libkrun` (experimental) |
| Windows  | WSL 2 (`wsl`)   | Hyper-V (`hyperv`) |
| Linux    | Not applicable  | QEMU (for testing only) |

Podman 5+ deprecated QEMU on macOS in favor of the native Apple Hypervisor,
which supports both Apple Silicon and Intel. On Windows, WSL 2 is the default;
Hyper-V requires `podman machine init --provider hyperv` and admin privileges.

## Core Commands

```bash
# Lifecycle
podman machine init                     # Create default VM
podman machine init myvm                # Named VM
podman machine init --now               # Create and start immediately
podman machine start [name]             # Boot the VM
podman machine stop [name]              # Graceful shutdown
podman machine rm [name]                # Delete VM and its disk

# Inspection
podman machine list                     # Show all machines + status
podman machine inspect [name]           # Full JSON details
podman machine info                     # Provider, paths, defaults

# Configuration (requires stopped machine)
podman machine set --cpus 4
podman machine set --memory 8192        # MiB
podman machine set --disk-size 100      # GiB
podman machine set --rootful            # Switch to rootful mode

# SSH into the VM
podman machine ssh [name]
```

Default machine name: `podman-machine-default`.

## Init Options

```bash
podman machine init \
  --cpus 4 \
  --memory 8192 \
  --disk-size 100 \
  --volume /host/path:/vm/path \
  --rootful \
  --now
```

Defaults (vary by version): 1-2 CPUs, 2048 MiB RAM, 100 GiB disk.
The `--volume` flag mounts host directories into the VM (not directly into
containers -- container `-v` mounts reference VM paths).

## Rootful vs Rootless

Rootless is the default and matches Podman behavior on native Linux.

```bash
podman machine set --rootful            # Enable rootful (requires restart)
podman machine set --rootful=false      # Back to rootless
```

Rootful and rootless are isolated namespaces -- images, containers, and
volumes do not overlap. Rootful is needed for binding ports below 1024
or certain storage drivers.

## Networking: gvproxy

`gvproxy` is a user-mode networking stack that runs on the host. It handles:

- **Port forwarding**: Container ports mapped with `-p` are automatically
  forwarded from the host through gvproxy to the VM. No manual iptables.
- **DNS resolution**: Containers can resolve host addresses.
- **API forwarding**: The podman API socket in the VM is exposed on the host.

Port forwarding is automatic for rootful machines. For rootless, ports
are forwarded when containers explicitly publish them (`-p`).

## Volume Mounts

### macOS (applehv)

Default mount technology is **virtiofs** (via Apple Virtualization.framework).
Home directory is mounted by default.

```bash
# Default: ~/ mounted into VM
podman machine init --volume /Users/me/src:/Users/me/src

# Read-only mount
podman machine init --volume /host:/vm:ro
```

virtiofs is significantly faster than the legacy 9p protocol. On older setups
using QEMU, 9p was the only option and had poor performance (slow stat calls,
no proper caching). If you see sluggish I/O in containers on macOS, confirm
the machine uses `applehv` + virtiofs, not QEMU + 9p.

### Windows (WSL 2)

WSL 2 auto-mounts all Windows drives at `/mnt/c/`, `/mnt/d/`, etc.
The `--volume` flag is redundant on WSL -- paths are already available.
Performance is best when files live inside the WSL filesystem rather
than on a Windows-mounted drive.

### Performance Tips

- Keep project files on the VM filesystem or virtiofs mount, not 9p.
- For node_modules / build artifacts, use a named volume instead of a bind mount.
- On macOS, virtiofs handles symlinks and metadata correctly; 9p often does not.

## API Socket

The host-side API socket enables remote clients (Podman Desktop, VS Code
extensions, etc.) to talk to the engine inside the VM.

```
# Typical socket locations
macOS:  ~/.local/share/containers/podman/machine/podman.sock
        /run/user/<uid>/podman/podman.sock  (inside VM)
Windows (WSL): \\.\pipe\podman-machine-default
```

```bash
# Verify socket
podman machine inspect --format '{{.ConnectionInfo.PodmanSocket.Path}}'
```

## Connection Management

`podman system connection` manages multiple machines or remote engines.

```bash
podman system connection list
podman system connection default myvm   # Switch active machine
podman system connection add remote \
  ssh://user@host/run/podman/podman.sock
```

## Key Differences from Docker Desktop

| Aspect | Podman Machine | Docker Desktop |
|--------|---------------|----------------|
| Daemon | None (fork-exec per command) | Persistent dockerd daemon |
| Licensing | Apache 2.0, free for all use | Paid subscription for enterprises |
| Rootless | Default, first-class | Opt-in, less mature |
| VM technology (macOS) | Apple HV + virtiofs | Apple HV + VirtioFS |
| VM technology (Windows) | WSL 2 or Hyper-V | WSL 2 or Hyper-V |
| Idle resource usage | Minimal (no daemon) | Higher (daemon + extensions) |
| Kubernetes | `podman generate kube` | Built-in single-node K8s |
| Docker compat | `podman-docker` package / alias | Native |
| Compose | `podman compose` (wrapper) | `docker compose` (integrated) |

To use Docker Compose files with Podman, install `podman-compose` or
set `alias docker=podman` and use `docker compose` with the podman socket.

## Troubleshooting

```bash
# Machine will not start
podman machine rm && podman machine init --now

# Reset everything
podman machine reset

# Check provider and VM state
podman machine info
podman machine inspect

# Logs (macOS)
cat ~/Library/Logs/podman-machine-*.log

# Verify connectivity
podman machine ssh "podman info"
```
