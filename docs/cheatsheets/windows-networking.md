---
tags: [windows, macos, networking, enclave, podman-machine, nat, hyper-v]
languages: [powershell, rust]
since: 2024-01-01
last_verified: 2026-04-27
sources:
  - https://learn.microsoft.com/en-us/virtualization/hyper-v-on-windows/user-guide/setup-nat-network
  - https://docs.podman.io/en/stable/
authority: high
status: current
---

# Windows/macOS Enclave Networking

@trace spec:enclave-network

## Problem

On Linux, `podman network create --internal tillandsias-enclave` creates an internal network with aardvark-dns. Containers resolve aliases like `proxy`, `git-service`, `inference` via internal DNS.

On Windows and macOS (podman machine / WSL2), the internal DNS **does not work** through gvproxy. All health checks fail and containers get `unable to look up git-service` errors.

## Solution: Localhost Port Mapping

When running on podman machine, Tillandsias skips the enclave network entirely and uses the default podman network with explicit port mapping.

| Linux (enclave DNS) | podman machine (port mapping) |
|---------------------|-------------------------------|
| `--network=tillandsias-enclave:alias=proxy` | No `--network` flag + `-p 3128:3128 -p 3129:3129` |
| `--network=tillandsias-enclave:alias=git-service` | No `--network` flag + `-p 9418:9418` |
| `--network=tillandsias-enclave:alias=inference` | No `--network` flag + `-p 11434:11434` |
| `HTTP_PROXY=http://proxy:3128` | `HTTP_PROXY=http://localhost:3128` |
| `TILLANDSIAS_GIT_SERVICE=git-service` | `TILLANDSIAS_GIT_SERVICE=localhost` |
| `OLLAMA_HOST=http://inference:11434` | `OLLAMA_HOST=http://localhost:11434` |

## Detection

The detection is automatic via `Os::detect().needs_podman_machine()`:

- **Linux**: `false` -- uses enclave network with DNS aliases
- **macOS**: `true` -- uses localhost port mapping
- **Windows**: `true` -- uses localhost port mapping

## Verification

On Windows/macOS, after launching an enclave, verify connectivity:

```bash
# Proxy is reachable
podman exec tillandsias-proxy sh -c "nc -z localhost 3128"

# Git service is reachable
podman exec tillandsias-git-<project> sh -c "nc -z localhost 9418"

# Inference is reachable
podman exec tillandsias-inference curl -sf http://localhost:11434/api/version
```

From a forge container:

```bash
# Proxy responds (via localhost port mapping)
curl -x http://localhost:3128 http://example.com

# Git clone works (via localhost port mapping)
git clone git://localhost/<project>

# Ollama responds (via localhost port mapping)
curl http://localhost:11434/api/version
```

## Health Check Timeouts

Podman machine containers take longer to start than native Linux containers. Health check timeouts are doubled on podman machine:

| Service | Linux | podman machine |
|---------|-------|----------------|
| Proxy | 15 attempts (15s) | 30 attempts (30s) |
| Git service | 10 attempts (5s) | 20 attempts (10s) |
| Inference | 30 attempts (30s) | 60 attempts (60s) |

## Known Limitations

- **Less isolation**: On podman machine, all containers share the default network. On Linux, the enclave network provides true network isolation (forge containers cannot reach the internet directly).
- **Port conflicts**: Service ports (3128, 3129, 9418, 11434) are published to the host. Other applications using these ports will conflict.
- **Single instance**: Only one enclave can run at a time on podman machine (port conflicts between instances).

## Implementation

Key files:

| File | What it does |
|------|-------------|
| `crates/tillandsias-core/src/state.rs` | `Os::needs_podman_machine()` detection |
| `crates/tillandsias-core/src/container_profile.rs` | `LaunchContext.use_port_mapping` field |
| `src-tauri/src/handlers.rs` | Enclave network skip, port mapping, health check timeouts |
| `src-tauri/src/launch.rs` | `rewrite_enclave_env()` for env var rewriting |
| `src-tauri/src/runner.rs` | CLI mode port mapping support |
| `scripts/build-tools-overlay.sh` | `TILLANDSIAS_PORT_MAPPING=1` env var |

## Provenance

- https://learn.microsoft.com/en-us/virtualization/hyper-v-on-windows/user-guide/setup-nat-network — Hyper-V NAT setup: `New-VMSwitch -SwitchType Internal`, `New-NetIPAddress` for NAT gateway, `New-NetNat` for NAT network; only one NAT network (WinNAT) supported per host; Windows 10 Anniversary Update or later
- https://docs.podman.io/en/stable/ — Podman overview: daemonless, rootless, OCI-compliant; `podman machine` provides the Linux VM on Windows/macOS; network aliasing via gvproxy is why enclave DNS does not work on podman machine (port mapping is required instead)
- **Last updated:** 2026-04-27
