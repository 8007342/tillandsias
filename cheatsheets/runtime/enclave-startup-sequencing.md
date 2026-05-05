---
title: Enclave Startup Sequencing — Multi-Container Orchestration
since: "2026-05-03"
last_verified: "2026-05-03"
tags: [enclave, orchestration, podman, network, startup, sequencing]
tier: bundled
bundled_into_image: true
summary_generated_by: hand-curated
---

# Enclave Startup Sequencing — Multi-Container Orchestration

@trace spec:async-inference-launch, spec:enclave-network

**Version baseline**: Podman 4.5+ with custom bridge networking  
**Use when**: Starting the Tillandsias enclave (proxy → git → forge → inference), managing inter-container dependencies, observing startup timing, handling soft-fail services.

## Provenance

- https://docs.podman.io/en/latest/markdown/podman-network-create.1.html — Podman network creation and configuration
- https://docs.podman.io/en/latest/markdown/podman-run.1.html#network — Container network connection options
- https://linux.die.net/man/7/cgroups — Resource isolation and ordering
- https://www.rfc-editor.org/rfc/rfc7231#section-6.3 — HTTP status codes (health check conventions)
- **Last updated:** 2026-05-03

## Startup sequence diagram

```
Phase 1 (Sequential, <5s total)
┌─────────────────────┐
│ Network Setup       │ Create tillandsias-enclave bridge
│ (0.1s)              │ → pods can reach each other
└──────────┬──────────┘
           │
           ↓
┌─────────────────────┐
│ Proxy Container     │ Launch tillandsias-proxy (port 3128)
│ START (0.5s)        │ Health: curl http://localhost:3128
└──────────┬──────────┘
           │ [wait until healthy]
           ↓
┌─────────────────────┐
│ Git Service         │ Launch tillandsias-git (git daemon + push)
│ START (1.0s)        │ Network: tillandsias-enclave
│                     │ Health: git --version
└──────────┬──────────┘
           │ [wait until healthy]
           ↓
┌─────────────────────┐
│ Forge Container     │ Launch tillandsias-forge-<genus>
│ START (2-3s)        │ Network: tillandsias-enclave
│                     │ CRITICAL PATH: wait here before returning to user
└──────────┬──────────┘
           │ [forge shell ready = user can start coding]
           │
           │ CRITICAL PATH ENDS; return to tray
           │
           ↓ (BACKGROUND, async)
┌─────────────────────┐
│ Inference Container │ Launch tillandsias-inference (ollama)
│ START (5-55s async) │ Network: tillandsias-enclave
│ NON-BLOCKING        │ SOFT FAILURE: if unreachable, log DEGRADED
└─────────────────────┘

Legend:
───────
[wait]  = blocking health check; tray waits for completion
(async) = fire-and-forget; tray does NOT wait
```

## Startup timing targets

| Phase | Target | Min | Max | Notes |
|-------|--------|-----|-----|-------|
| Proxy creation | <0.5s | 0.2s | 1.0s | Minimal setup; no dependencies |
| Proxy health | <1s | 0.1s | 2.0s | curl to port 3128 |
| Git service creation | <1.0s | 0.5s | 2.0s | Depends on proxy health |
| Git service health | <1s | 0.1s | 1.5s | git --version (fast) |
| Forge creation | <2s | 1s | 3s | Depends on proxy + git |
| Forge health check | <3s | 1s | 5s | Forge entrypoint ready (compile time varies) |
| **Critical path total** | **<5s** | 4s | 8s | Tray waits until here |
| Inference async start | — | 0s | — | Fire-and-forget; not on critical path |
| Inference health (async) | <60s | 5s | 60s | Can take 5-55s; tray logs when ready |

## Dependency graph

```
Host
 ├─ Network: tillandsias-enclave (bridge)
 │
 ├─ Proxy (tillandsias-proxy:3128)
 │   └─ Health: curl http://localhost:3128
 │
 ├─ Git (tillandsias-git)
 │   └─ Depends on: Proxy (for HTTP_PROXY env)
 │   └─ Health: git --version
 │
 ├─ Forge (tillandsias-forge-<genus>)
 │   └─ Depends on: Proxy + Git (network access)
 │   └─ Network: enclave bridge
 │   └─ Health: /app/health-check (project-specific)
 │   └─ **CRITICAL**: User waits here
 │
 └─ Inference (tillandsias-inference, async)
     └─ Depends on: Proxy (optional, for model pulls)
     └─ Network: enclave bridge (optional)
     └─ Health: curl http://localhost:11434/api/version
     └─ **NON-CRITICAL**: Background task; can fail
```

## Implementation pattern

```bash
#!/bin/bash
set -euo pipefail

# @trace spec:enclave-startup-sequencing, spec:async-inference-launch

# === CRITICAL PATH (blocking, tray waits) ===

# 1. Create network
echo "Setting up network..."
podman network create tillandsias-enclave 2>/dev/null || true

# 2. Launch proxy
echo "Starting proxy..."
podman run -d \
  --name tillandsias-proxy \
  --network tillandsias-enclave \
  --healthcheck-cmd="curl -f http://localhost:3128 || exit 1" \
  --healthcheck-interval=1s --healthcheck-timeout=1s --healthcheck-retries=5 \
  tillandsias-proxy

# 3. Wait for proxy
echo "Waiting for proxy..."
PROXY_HEALTHY=0
for attempt in {1..30}; do
  if curl -f http://127.0.0.1:3128 2>/dev/null; then
    PROXY_HEALTHY=1
    break
  fi
  sleep 0.5
done

if [ $PROXY_HEALTHY -ne 1 ]; then
  echo "ERROR: Proxy failed to become ready after 15s"
  exit 1
fi

# 4. Launch git service
echo "Starting git service..."
podman run -d \
  --name tillandsias-git \
  --network tillandsias-enclave \
  -e HTTP_PROXY=http://tillandsias-proxy:3128 \
  --healthcheck-cmd="git --version" \
  --healthcheck-interval=1s --healthcheck-timeout=1s --healthcheck-retries=3 \
  tillandsias-git

# 5. Wait for git
echo "Waiting for git service..."
GIT_HEALTHY=0
for attempt in {1..30}; do
  if podman exec tillandsias-git git --version >/dev/null 2>&1; then
    GIT_HEALTHY=1
    break
  fi
  sleep 0.5
done

if [ $GIT_HEALTHY -ne 1 ]; then
  echo "ERROR: Git service failed after 15s"
  exit 1
fi

# 6. Launch forge (critical path continues)
GENUS="my-genus"
echo "Starting forge ($GENUS)..."
podman run -d \
  --name tillandsias-forge-$GENUS \
  --network tillandsias-enclave \
  -e HTTP_PROXY=http://tillandsias-proxy:3128 \
  -e TILLANDSIAS_PROJECT=$(pwd) \
  tillandsias-forge

# 7. Wait for forge (tray waits here)
echo "Waiting for forge..."
FORGE_HEALTHY=0
for attempt in {1..60}; do
  if podman exec tillandsias-forge-$GENUS test -f /tmp/forge-ready 2>/dev/null; then
    FORGE_HEALTHY=1
    break
  fi
  sleep 0.5
done

if [ $FORGE_HEALTHY -ne 1 ]; then
  echo "ERROR: Forge failed after 30s"
  exit 1
fi

echo "✓ Enclave ready in ~$((attempt * 500 / 1000))s"

# === BACKGROUND TASK (async, tray returns immediately) ===

# 8. Launch inference (fire-and-forget, non-blocking)
(
  podman run -d \
    --name tillandsias-inference \
    --network tillandsias-enclave \
    -e HTTP_PROXY=http://tillandsias-proxy:3128 \
    --healthcheck-cmd="curl -f http://localhost:11434/api/version || exit 1" \
    --healthcheck-interval=5s --healthcheck-timeout=3s --healthcheck-retries=10 \
    tillandsias-inference

  # Wait for inference (up to 60s) but don't block the main handler
  INFERENCE_HEALTHY=0
  for attempt in {1..120}; do
    if curl -f http://127.0.0.1:11434/api/version 2>/dev/null; then
      INFERENCE_HEALTHY=1
      break
    fi
    sleep 0.5
  done

  if [ $INFERENCE_HEALTHY -eq 1 ]; then
    echo "ℹ Inference ready after $(($attempt * 500 / 1000))s"
  else
    echo "⚠ Inference unavailable (DEGRADED state); inference requests will fail"
  fi
) &

# Tray handler returns here (no wait for inference)
exit 0
```

## Health check implementations

### Proxy health check

```bash
# Inside tillandsias-proxy entrypoint
curl -f http://localhost:3128 || exit 1
```

Squid responds with HTTP 200 on CONNECT; exit 0 = healthy.

### Git service health check

```bash
# Inside tillandsias-git entrypoint
git --version > /dev/null 2>&1 || exit 1
```

Git daemon is running if `git --version` works.

### Forge health check (project-specific)

```bash
# Inside tillandsias-forge entrypoint or /app/health-check script
# Examples (project-dependent):

# Option A: File-based (explicit readiness marker)
test -f /tmp/forge-ready

# Option B: Port-based (e.g., language server)
curl -f http://localhost:8080/health

# Option C: Process-based
pgrep -f "bash|zsh|fish"  # Shell is running

# Return 0 = healthy, 1 = not ready
```

### Inference health check

```bash
# Inside tillandsias-inference entrypoint (ollama)
curl -f http://localhost:11434/api/version || exit 1
```

Ollama responds with version JSON; exit 0 = ready for model pulls + inference.

## Soft failure pattern (inference)

Inference is a **soft requirement**: if it fails to start or becomes unhealthy, the tray logs `DEGRADED` but forge remains usable. This is implemented via background async spawn:

```rust
// In handlers.rs::ensure_enclave_ready()

// ... proxy + git checks (blocking, on critical path)

// Inference check runs async (non-blocking)
tokio::spawn(async {
    match check_inference_health().await {
        Ok(_) => info!("Inference ready"; spec="async-inference-launch"),
        Err(e) => warn!("Inference degraded: {}", e; safety="DEGRADED", spec="async-inference-launch"),
    }
});

// Return immediately (don't await the handle)
Ok(())
```

@trace spec:async-inference-launch

## Monitoring startup

```bash
# Watch all events during startup
podman events --filter type=container --filter container="tillandsias-*" &

# In another terminal, trigger startup
./scripts/attach-project.sh /path/to/project

# In the event stream, watch for:
# - container start events (one per service)
# - container health_status changes
# - timing between events
```

## See also

- `runtime/container-lifecycle.md` — Individual container startup/shutdown phases
- `runtime/async-patterns-rust.md` — Tokio spawn patterns for background tasks
- `runtime/container-health-checks.md` — Deep dive on health check semantics
- `openspec/specs/enclave-network/spec.md` — Enclave network design
