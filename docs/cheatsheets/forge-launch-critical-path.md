# Forge Launch Critical Path

@trace spec:layered-tools-overlay, spec:proxy-container, spec:enclave-network

## Overview

Every forge launch (CLI `--bash` / `--attach`, or tray "Attach Here") follows this critical path. A failure at any step blocks the user from getting a working environment. This cheatsheet maps each step, what can break, and how to debug.

## Initialization Phase (--init or tray startup)

Tools overlay is now built during initialization, not deferred to first container launch.

| # | Step | Code | Blocks on | Failure symptom |
|---|------|------|-----------|-----------------|
| I1 | Build images (proxy, forge, git, inference) | `init.rs` / `main.rs` | Podman, buildah, network | "Build failed" |
| I2 | **Build tools overlay** | `init.rs:build_overlay_for_init()` / `main.rs:ensure_tools_overlay()` | Forge image exists + network (proxy if enclave up) | Logged warning, fallback to inline install at launch |
| I3 | Prune old images | `init.rs` | — | — |

## Launch Phase (CLI --bash/--attach or tray "Attach Here")

| # | Step | Code | Blocks on | Failure symptom |
|---|------|------|-----------|-----------------|
| 1 | Parse CLI / tray action | `cli.rs`, `handlers.rs` | — | Immediate exit / error dialog |
| 2 | Check/build forge image | `runner.rs:342-411` | `podman image exists` | "Image not found" error |
| 3 | Start proxy container | `handlers.rs:ensure_infrastructure_ready()` | Podman socket | Hang or "proxy failed" |
| 4 | Generate ephemeral CA chain | `ca.rs:generate_ca_chain()` | rcgen crate | "CA chain generation failed" |
| 5 | Start inference container | `handlers.rs:ensure_enclave_ready()` via `tokio::spawn` | Proxy ready (queues on BUILD_MUTEX) | Non-fatal, logs warning. **Async since `async-inference-launch`** — does NOT block subsequent steps. |
| 6 | Ensure tools overlay (safety net) | `handlers.rs:handle_attach_here()` | Forge image + proxy + CA | Fast no-op if init already built it |
| 7 | Start git service | `handlers.rs` | Enclave network | "Git service failed" |
| 8 | Create git mirror | `handlers.rs` | Git service running | "Mirror creation failed" |
| 9 | Select profile (bash/claude/opencode) | `runner.rs:451-462` | — | — |
| 10 | Build podman args + inject CA mounts | `runner.rs:472`, `handlers.rs:inject_ca_chain_mounts()` | CA chain file exists | Missing CA = SSL failures inside forge |
| 11 | Launch forge container | `runner.rs:523-532` (CLI) or `handlers.rs` (tray) | All above | Container exits immediately |
| 12 | Entrypoint: CA trust setup | `entrypoint-forge-*.sh` | `/run/tillandsias/ca-chain.crt` mounted | npm/curl SSL failures |
| 13 | Entrypoint: git clone from mirror | `entrypoint-forge-*.sh` | Git service + mirror ready | "Could not clone project" |
| 14 | Entrypoint: install tools (overlay or inline) | `entrypoint-forge-*.sh`, `lib-common.sh` | Proxy + CA trust + npm registry | Timeout or SSL error (inline only) |
| 15 | Entrypoint: exec into agent/shell | `entrypoint-forge-*.sh` | Tool binary exists | "ERROR: OpenCode failed to install" |

## CA Certificate Trust Chain

@trace spec:proxy-container

The MITM proxy intercepts HTTPS. Forge containers must trust the ephemeral CA.

### Trust delivery (two mechanisms)

| Mechanism | Set by | Env var | Trusts | Used by |
|-----------|--------|---------|--------|---------|
| `NODE_EXTRA_CA_CERTS` | Rust (`inject_ca_chain_mounts`) | `/run/tillandsias/ca-chain.crt` | Proxy CA (additive to Node built-in CAs) | npm, yarn, pnpm, Node.js |
| Combined CA bundle | Entrypoint script | `/tmp/tillandsias-combined-ca.crt` | System CAs + proxy CA | curl, pip, Go, rustls, OpenSSL tools |

### How the combined bundle is created (entrypoint)

```bash
# System CA path varies by distro:
#   Fedora/RHEL: /etc/pki/tls/certs/ca-bundle.crt
#   Debian/Ubuntu: /etc/ssl/certs/ca-certificates.crt
cat "$SYSTEM_CA" "$CA_CHAIN" > /tmp/tillandsias-combined-ca.crt
export SSL_CERT_FILE="/tmp/tillandsias-combined-ca.crt"
export REQUESTS_CA_BUNDLE="/tmp/tillandsias-combined-ca.crt"
```

### What does NOT work (and why)

| Approach | Why it fails |
|----------|-------------|
| `update-ca-trust` / `update-ca-certificates` | Requires root; forge runs as non-root (`--userns=keep-id`, `--cap-drop=ALL`) |
| `SSL_CERT_FILE` pointing to system bundle only | System bundle doesn't include ephemeral proxy CA |
| `SSL_CERT_FILE` pointing to proxy CA only | Loses all system CAs (breaks non-proxied connections) |
| `SSL_CERT_FILE` pointing to Debian path on Fedora image | File doesn't exist; OpenSSL trusts nothing |

## Tools Overlay

@trace spec:layered-tools-overlay

The tools overlay pre-installs Claude Code, OpenSpec, and OpenCode so forge containers don't need to `npm install` on every launch.

### Build trigger

Overlay rebuilds when forge image tag changes (version mismatch in `.manifest.json`).

### Build flow

1. Rust detects mismatch in `ensure_tools_overlay()` (`tools_overlay.rs`)
2. Calls `build-tools-overlay.sh` via `std::process::Command::output()` (**blocking**)
3. Script launches a temporary forge container on enclave network
4. Container runs `npm install -g` for Claude Code + OpenSpec, `curl` installer for OpenCode
5. Tools installed into bind-mounted host directory (`~/.cache/tillandsias/tools-overlay/vN/`)
6. Manifest written, `current` symlink swapped atomically

### What can break the overlay build

| Issue | Symptom | Fix |
|-------|---------|-----|
| No CA chain passed to script | npm/curl hang on SSL through proxy | Fixed: Rust passes `CA_CHAIN_PATH` env var (v0.1.131+) |
| Forge image doesn't exist yet | "No tillandsias-forge image found" | Fixed: overlay build moved after image confirmed (v0.1.131+) |
| Proxy not ready | npm timeout | Ensure proxy container is running before overlay build |
| npm registry unreachable | npm install fails | Check proxy allowlist, DNS, network |
| OpenCode installer (`curl opencode.ai/install`) fails | OpenCode missing from overlay | Non-fatal; forge falls back to inline install |

### Overlay mount path

The overlay is mounted at `/home/forge/.tools:ro` inside forge containers. The npm prefix paths must match exactly — npm records absolute paths in `.bin/` wrapper scripts.

## OpenSpec Install Flow

@trace spec:forge-shell-tools

| Method | When | Code |
|--------|------|------|
| Tools overlay (preferred) | Overlay exists with valid OpenSpec | `entrypoint-forge-*.sh` checks `$TOOLS_DIR/openspec/bin/openspec` |
| Inline install (fallback) | No overlay, or overlay missing OpenSpec | `lib-common.sh:install_openspec()` runs `npm install -g --prefix $CACHE/openspec @fission-ai/openspec` |

### Inline install requirements

- Node.js 20.19.0+ (in forge image)
- npm registry reachable through proxy
- `NODE_EXTRA_CA_CERTS` set (for HTTPS through MITM proxy)
- Writable `$CACHE/openspec/` directory

## OpenCode Install Flow

@trace spec:forge-shell-tools

| Method | When | Code |
|--------|------|------|
| Tools overlay (preferred) | Overlay exists with valid OpenCode binary | `entrypoint-forge-opencode.sh` checks `$TOOLS_DIR/opencode/bin/opencode` |
| Inline install (fallback) | No overlay | `ensure_opencode()` runs `curl -fsSL https://opencode.ai/install \| bash` |

### Inline install requirements

- curl (in forge image)
- `SSL_CERT_FILE` set to combined CA bundle (for HTTPS through MITM proxy)
- `opencode.ai` in proxy allowlist
- Writable `$CACHE/opencode/` directory

### Nix image compatibility

On Nix-based forge images, the OpenCode binary needs a linker wrapper because Nix uses non-standard library paths. `_make_opencode_wrapper()` creates a shell wrapper that invokes the Nix dynamic linker.

## Debugging

```bash
# Check if CA chain is mounted
ls -la /run/tillandsias/ca-chain.crt

# Check env vars inside forge
echo $NODE_EXTRA_CA_CERTS
echo $SSL_CERT_FILE
echo $REQUESTS_CA_BUNDLE

# Test HTTPS through proxy
curl -v https://registry.npmjs.org/ 2>&1 | head -30

# Test npm connectivity
npm ping

# Check tools overlay status
ls -la ~/.cache/tillandsias/tools-overlay/current/
cat ~/.cache/tillandsias/tools-overlay/current/.manifest.json

# Check overlay from host
ls -la ~/.cache/tillandsias/tools-overlay/
cat ~/.cache/tillandsias/tools-overlay/current/.manifest.json
```

## Measured Latency (Windows 11 + podman 5.8.2 / WSL machine)

@trace spec:async-inference-launch, spec:fix-windows-image-routing, spec:persistent-git-service, spec:overlay-mount-cache

Numbers from a clean-install verification run (podman machine wiped + reinitialized):

| Scenario | Mode | Time | Notes |
|----------|------|------|-------|
| First-ever install + init | CLI `--init` | ~4 min | Downloads fedora-minimal:43 (136 MB) + alpine:3.20 (8 MB), builds 4 distinct enclave images, builds tools overlay |
| Cold launch (images cached, no containers) | CLI `--bash` | ~18 s | Proxy ~6 s + git-service ~6 s; inference launches async (~3 s in parallel) — does NOT add to this number |
| Warm launch (containers up, fresh process) | CLI `--bash` | ~6.5 s | Inference snapshot-cache hit (`elapsed_secs=0.29`), but git-service still rebuilds because CLI's `EnclaveCleanupGuard` stops it on every CLI exit |
| Warm launch (containers up, tray mode) | Tray "Attach Here" | not measured here | **persistent-git-service** keeps git-service alive across forge teardowns in tray mode → expected ~1-2 s on second + later attaches in same tray session |

**CLI vs tray distinction**: CLI mode is one-shot — `runner.rs:EnclaveCleanupGuard::drop()` tears down proxy + inference + git-service on every exit so each `tillandsias <project>` invocation is essentially cold. The tray hosts the persistent services for its lifetime; warm-relaunch performance in CLI is bounded by the cleanup guard, not the launch path.

**Wave-4 architectural wins (shipped)**:
- `tools-overlay-fast-reuse` + `overlay-mount-cache` — process-lifetime snapshot cache for the overlay path; sub-millisecond lookup on the warm path; avoids `exists()` syscall + manifest JSON read in both `ensure_tools_overlay` and `resolve_mount_source`.
- `persistent-git-service` — per-project git-service is tray-session-scoped (was: stopped when last forge for project dies). Eliminates the ~3 s git-service rebuild on every relaunch in tray mode.
- `async-inference-launch` — inference fires off the critical path; verified `elapsed_secs=0.29` on the async-ready log line on warm launch.

**Path to <2 s warm launch (remaining)**:
1. **Forge-already-running early-exit** — when the user re-attaches to a project whose forge is still alive, the existing `state.running` guard catches it but is fragile if state out-of-sync. Enhancing it to also scan podman + open a `podman exec` terminal into the existing container instead of failing would give a sub-100 ms re-attach. Tracked as task #11.
2. **Manual tray-mode measurement** — the persistent-git-service win is verified by code path but not yet stopwatched in tray mode (CLI cleanup guard masks it). Need a brief tray manual test.

## Related

- `docs/cheatsheets/mitm-proxy-design.md` — Full MITM proxy architecture and cert lifecycle
- `docs/cheatsheets/secrets-management.md` — Credential delivery (separate from CA trust)
- `docs/cheatsheets/enclave-architecture.md` — Network topology and container roles
- `openspec/specs/proxy-container/spec.md` — Proxy container spec
- `openspec/specs/layered-tools-overlay/spec.md` — Tools overlay spec
