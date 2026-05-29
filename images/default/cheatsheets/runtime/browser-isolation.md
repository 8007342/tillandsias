---
title: Browser Isolation in Containers
since: "2026-05-03"
last_verified: "2026-05-03"
tags: [browser, chromium, isolation, container, security, cdn]
tier: bundled
bundled_into_image: true
summary_generated_by: hand-curated
---

# Browser Isolation in Containers

@trace spec:browser-isolation-core, spec:browser-isolation-tray-integration

**Version baseline**: Chromium 124+ (bundled in Tillandsias browser-isolation image)  
**Use when**: Launching isolated browser windows from the tray, restricting network access, implementing browser CDP protocol handlers, managing browser container lifecycle.

## Provenance

- https://chromedriver.chromium.org/security-considerations — Chromium security isolation modes
- https://chromium.googlesource.com/chromium/src/+/main/docs/security/cros_security.md — Chromium OS security architecture
- https://developer.chrome.com/docs/devtools/remote-debugging/ — Chrome DevTools Protocol (CDP) reference
- https://docs.docker.com/engine/security/seccomp/ — Seccomp filtering for containers
- https://docs.docker.com/engine/security/apparmor/ — AppArmor LSM for containers
- https://owasp.org/www-community/attacks/xss/ — Web security isolation patterns
- **Last updated:** 2026-05-03

## Quick reference

### Browser Isolation Strategies

| Strategy | Container Image | Network | User Session | Use Case |
|----------|------------------|---------|--------------|----------|
| **Chromium headless** | `tillandsias-chromium-core` | Proxied | No GUI | Headless rendering, inference |
| **Chromium windowed** | `tillandsias-chromium-framework` | Proxied | X11/Wayland | User-driven browser window |
| **App-mode isolation** | Native app container | Isolated VLAN | Confined | Single-app browsing sandboxes |

### Container Launch Flags for Browser Isolation

```bash
# Core security flags (always apply)
podman run \
  --cap-drop=ALL \
  --security-opt=no-new-privileges \
  --read-only \
  --tmpfs /tmp \
  --tmpfs /run \
  --user 1000:1000 \
  tillandsias-chromium-core

# GPU passthrough (Chromium rendering)
podman run \
  --device /dev/dri/renderD128 \
  --device /dev/shm \
  tillandsias-chromium-framework

# Network isolation (proxy-only)
podman run \
  --network enclave \
  -e HTTP_PROXY=http://tillandsias-proxy:3128 \
  -e HTTPS_PROXY=http://tillandsias-proxy:3128 \
  tillandsias-chromium-core
```

### Chromium Launch Flags

| Flag | Purpose | Example |
|------|---------|---------|
| `--headless=new` | Headless mode (no GUI) | `chromium-browser --headless=new` |
| `--disable-gpu` | Use CPU rendering (fallback) | For containers without GPU passthrough |
| `--remote-debugging-port=9222` | Enable CDP on port 9222 | Allows automated control via DevTools Protocol |
| `--disable-dev-shm-usage` | Don't use `/dev/shm` (shared memory) | Required in resource-constrained containers |
| `--no-sandbox` | Disable sandboxing (ONLY in isolated containers) | Dangerous; only in containerized context |
| `--incognito` | Private browsing mode | No history, cookies, cache persistence |
| `--disable-background-networking` | Block background requests | Reduces unsolicited network activity |
| `--disable-default-apps` | Skip default startup pages | Faster startup |

### DevTools Protocol (CDP) for Automated Control

Chromium with `--remote-debugging-port=9222` exposes a JSON endpoint for automation:

```bash
# Start headless Chromium with CDP
chromium-browser --headless=new --remote-debugging-port=9222 about:blank

# Query active targets
curl http://localhost:9222/json/list

# Response:
# [{"id":"<id>","title":"about:blank","url":"about:blank","devtoolsFrontendUrl":"...","webSocketDebuggerUrl":"ws://localhost:9222/..."}]

# Control via WebSocket (CDP protocol)
# See browser-mcp-server spec for agent integration patterns
```

## Container isolation layers

### Layer 1: Capability drop (pod security)

```bash
# Drop all capabilities, keep only what's needed
podman run --cap-drop=ALL <image>

# Selectively restore (rarely needed for Chromium)
podman run --cap-drop=ALL --cap-add=NET_BIND_SERVICE <image>
```

**Applied to Tillandsias browser containers**: All caps dropped except those required for GPU and rendering.

### Layer 2: Read-only filesystem + tmpfs

```bash
podman run \
  --read-only \
  --tmpfs /tmp \
  --tmpfs /run \
  <image>
```

Prevents persistent disk writes; all state is ephemeral. Container stop = automatic cleanup.

### Layer 3: User namespace isolation

```bash
podman run --user 1000:1000 --userns=keep-id <image>
```

Browser runs as unprivileged user (UID 1000) inside container. Even if compromised, process cannot escalate to container root.

### Layer 4: Network isolation (proxy-only)

```bash
podman network create enclave --driver=bridge
podman run \
  --network enclave \
  -e HTTP_PROXY=http://tillandsias-proxy:3128 \
  -e HTTPS_PROXY=http://tillandsias-proxy:3128 \
  <image>
```

No direct external network; all traffic goes through proxy. Proxy enforces domain allowlist.

## Container health checks

```dockerfile
# In Containerfile
HEALTHCHECK --interval=5s --timeout=3s --start-period=2s --retries=3 \
  CMD curl -f http://localhost:9222/json/version || exit 1
```

Tillandsias tray checks via: `curl http://<container>:9222/json/version` before declaring browser ready.

## Troubleshooting

| Symptom | Cause | Fix |
|---------|-------|-----|
| Chromium exits immediately | Missing `--disable-dev-shm-usage` | Add flag for memory-constrained containers |
| CDP port not accessible | Container network isolated | Check `--network` and `--cap-drop` flags |
| Rendering extremely slow | GPU not detected | Use `--device /dev/dri/renderD128` or `--disable-gpu` |
| Network requests hang | Proxy URL wrong or proxy not ready | Verify `HTTP_PROXY` env var; health-check proxy first |
| Container won't start (permission denied) | UID mismatch in `--user` | Ensure UID 1000 exists in container; check `--userns=keep-id` |

## Tillandsias-specific integration

**Browser tray handler** (`browser-isolation-tray-integration`):
1. Call `launch_browser_container()` → spawns `tillandsias-chromium-framework` with CDP enabled
2. Poll CDP on `http://<container>:9222` until healthy
3. Connect tray's MCP client to browser's CDP WebSocket
4. On window close → `podman stop <container>` (ephemeral cleanup)
5. If the browser image tag or launch contract changed, drop the container and recreate it; do not reuse browser cache or state between runs
6. If rootless Podman reports stale storage or uid-map metadata, repair the host runtime once with `podman system migrate`, then recreate the ephemeral browser container
7. If `podman` is missing, fail fast with an actionable `Podman not installed` error and do not attempt a degraded browser path

**Network architecture**:
- Browser container: on `tillandsias-enclave` network, restricted to proxy + git service
- Host→container: tray communicates via CDP JSON (http://localhost:9222)
- Container→external: all HTTP/HTTPS through proxy; proxy enforces domain allowlist

**Logging and cleanup**
- Browser container logs are observable through the normal runtime logging pipeline and Podman diagnostics.
- Logging is side-channel evidence only; browser launch success must not depend on a log sink succeeding.
- Temporary browser artifacts are cleaned up with container removal and tmpfs teardown, not by mutating an existing browser container in place.

## Litmus Chain

Browser isolation work should start with the core image boundary, then widen to
tray integration only after the core seam is stable:

1. `./scripts/run-litmus-test.sh browser-isolation-core`
1. `./scripts/run-litmus-test.sh browser-isolation-tray-integration`
1. `./scripts/run-litmus-test.sh security-privacy-isolation`
1. `./build.sh --ci --strict --filter browser-isolation-core:browser-isolation-tray-integration:security-privacy-isolation`
1. `./build.sh --ci-full --install --strict --filter browser-isolation-core:browser-isolation-tray-integration:browser-mcp-server:security-privacy-isolation`
1. `tillandsias --init --debug`

## See also

- `runtime/container-lifecycle.md` — Container startup phases and health checks
- `runtime/podman-logging.md` — Podman diagnostics, lifecycle recovery, and host maintenance
- `runtime/runtime-logging.md` — Runtime logging and tracing best practices
- `runtime/container-gpu.md` — GPU passthrough for rendering
- `runtime/chromium-headless.md` — Headless rendering and automation
- `openspec/specs/browser-isolation-core/spec.md` — Core browser isolation requirements
- `openspec/specs/browser-mcp-server/spec.md` — MCP server integration with browser CDP
