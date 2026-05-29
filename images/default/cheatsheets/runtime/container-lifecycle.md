---
title: Container Lifecycle — Startup, Health Checks, Shutdown
since: "2026-05-03"
last_verified: "2026-05-03"
tags: [container, lifecycle, podman, health-check, startup, shutdown]
tier: bundled
bundled_into_image: true
summary_generated_by: hand-curated
---

# Container Lifecycle — Startup, Health Checks, Shutdown

@trace spec:git-mirror-service, spec:tray-ux, spec:browser-isolation-tray-integration

**Version baseline**: Podman 4.5+ (Fedora 43+)  
**Use when**: Launching containers and waiting for readiness, implementing health checks, cleaning up containers on shutdown, managing container state transitions.

## Provenance

- https://docs.podman.io/en/latest/markdown/podman-run.1.html#healthcheck — `--healthcheck` flag documentation
- https://docs.podman.io/en/latest/markdown/podman-container-wait.1.html — `podman wait` synchronization
- https://docs.podman.io/en/latest/markdown/podman-stop.1.html — Container stop semantics and timeout
- https://docs.docker.com/engine/reference/builder/#healthcheck — HEALTHCHECK instruction reference
- https://linux.die.net/man/7/cgroups — Linux cgroups (resource management in containers)
- **Last updated:** 2026-05-03

## Quick reference

### Container Lifecycle States

```
┌─────────┐
│ Created │  podman run ... (image pulled, container configured)
└────┬────┘
     │ [entrypoint runs]
     ↓
┌─────────────┐
│   Running   │  HEALTHCHECK passes if defined
└────┬────────┘
     │
     ├─ [healthy] → app is serving requests
     ├─ [unhealthy] → entrypoint died or health check failed
     │
     │ [user stops container or timeout]
     ↓
┌──────────────┐
│   Stopped    │  SIGTERM sent; grace period (default 10s)
└──────┬───────┘
       │ [process exits]
       ↓
┌──────────────┐
│   Exited     │  No cleanup: use --rm to auto-delete
└──────────────┘
```

### Launch and Wait for Readiness

```bash
# Launch container in background
CONTAINER=$(podman run -d \
  --name my-service \
  --healthcheck-cmd="curl -f http://localhost:8080/health || exit 1" \
  --healthcheck-interval=3s \
  --healthcheck-timeout=1s \
  --healthcheck-retries=5 \
  my-image)

# Wait for health check to pass (blocking)
podman healthcheck run $CONTAINER

# Or: poll manually with timeout
timeout 30s bash -c "until curl -f http://localhost:8080/health 2>/dev/null; do sleep 1; done"

# Or: use podman wait + inspect (more control)
podman wait --condition=running $CONTAINER
sleep 1  # Give app a moment to bind port
```

### Health Check Definition

**In Containerfile:**

```dockerfile
FROM ubuntu:24.04

# Explicit health check
HEALTHCHECK --interval=5s --timeout=3s --start-period=10s --retries=3 \
  CMD curl -f http://localhost:9222/json/version || exit 1

ENTRYPOINT ["/app/service", "--port=9222"]
```

**Flags:**
- `--interval=5s` — check every 5 seconds (once running)
- `--timeout=3s` — health check must complete within 3 seconds
- `--start-period=10s` — grace period before first check (app startup time)
- `--retries=3` — unhealthy after 3 consecutive failures

**Exit codes:**
- `0` → healthy
- `1` → unhealthy (container marked unhealthy, tray logs warning)
- `2` → reserved (not used in practice)

### Stopping a Container Gracefully

```bash
# Graceful shutdown (SIGTERM → 10s grace → SIGKILL)
podman stop --time=10 $CONTAINER

# Forceful shutdown (immediate SIGKILL)
podman kill $CONTAINER

# Implicit via --rm (auto-cleanup)
podman run --rm ... <image>  # Container deleted when process exits
```

**Shutdown sequence:**
1. `podman stop <name>` sends SIGTERM to PID 1
2. Entrypoint has 10s to exit gracefully (configurable via `--time`)
3. If still running after timeout, SIGKILL is sent
4. If `--rm` is set, container and volumes are deleted immediately

### Query Container State

```bash
# Get state
podman inspect $CONTAINER --format '{{.State.Status}}'
# Output: running | exited | paused | ...

# Get health status
podman inspect $CONTAINER --format '{{.State.Health.Status}}'
# Output: healthy | unhealthy | starting

# Get exit code (if exited)
podman inspect $CONTAINER --format '{{.State.ExitCode}}'
# Output: 0 (success) | 1 (failure) | 137 (SIGKILL) | 143 (SIGTERM)

# Watch state changes with podman events
podman events --filter type=container --filter container=$CONTAINER
```

## Tillandsias-specific lifecycle patterns

### Pattern 1: Enclave Startup Sequencing

Tillandsias launches multiple containers in dependency order:

```bash
# 1. Proxy (no dependencies)
podman run -d --name tillandsias-proxy \
  --healthcheck-cmd="curl http://localhost:3128" \
  tillandsias-proxy
podman healthcheck run tillandsias-proxy

# 2. Git service (depends on proxy for package installs)
podman run -d --name tillandsias-git \
  --network enclave \
  -e HTTP_PROXY=http://tillandsias-proxy:3128 \
  --healthcheck-cmd="git --version" \
  tillandsias-git
podman healthcheck run tillandsias-git

# 3. Forge (depends on both for network access)
podman run -d --name tillandsias-forge-<genus> \
  --network enclave \
  -e HTTP_PROXY=http://tillandsias-proxy:3128 \
  tillandsias-forge
# Forge health check: custom (project-specific)

# 4. Inference (soft requirement; can fail)
podman run -d --name tillandsias-inference \
  --network enclave \
  -e OLLAMA_NUM_GPU=1 \
  --healthcheck-cmd="curl http://localhost:11434/api/version" \
  tillandsias-inference &  # Run in background; tray doesn't wait
```

@trace spec:enclave-startup-sequencing

### Pattern 2: Health Check with Exponential Backoff

For services that need time to become ready:

```bash
# Retry with exponential backoff (manual)
MAX_ATTEMPTS=10
ATTEMPT=1
DELAY=1

while [ $ATTEMPT -le $MAX_ATTEMPTS ]; do
  if curl -f http://localhost:9222/json/version 2>/dev/null; then
    echo "✓ Service ready"
    exit 0
  fi
  
  echo "Attempt $ATTEMPT/$MAX_ATTEMPTS; waiting ${DELAY}s..."
  sleep $DELAY
  
  DELAY=$((DELAY * 2))  # Exponential backoff
  ATTEMPT=$((ATTEMPT + 1))
done

echo "✗ Service did not become ready after ${MAX_ATTEMPTS} attempts"
exit 1
```

Use in `HEALTHCHECK` or as a startup probe.

### Pattern 3: Cleanup on Shutdown

Tillandsias enclave cleanup (`/cleanup-enclave`):

```bash
# Stop all enclave containers (preserve exit codes)
CONTAINERS=$(podman ps --filter "label=tillandsias.enclave" -q)

for container in $CONTAINERS; do
  echo "Stopping $container..."
  podman stop --time=10 "$container"
done

# Remove stopped containers and cleanup secrets
podman container prune --force

# Remove ephemeral secrets
podman secret rm tillandsias-github-token 2>/dev/null || true
podman secret rm tillandsias-ca-cert 2>/dev/null || true

# Remove volumes (only if --rm was NOT used at launch)
# CAUTION: may delete persistent data
podman volume prune --force
```

@trace spec:git-mirror-service

## Common pitfalls

- **No health check** — container marked `running` immediately; app still initializing. Use `HEALTHCHECK` in Containerfile or `podman wait --condition=healthy`.
- **Health check timeout too short** — intermittent failures on slow systems. Increase `--timeout` or add `--start-period` grace window.
- **SIGTERM not handled** — process ignores SIGTERM, gets SIGKILL after timeout. Add signal handlers in entrypoint: `trap 'cleanup_and_exit' SIGTERM`.
- **Grace period too short** — app doesn't finish cleanup before SIGKILL. Increase `podman stop --time` to match app shutdown time.
- **Forgetting `--rm`** — stopped containers litter the system. Use `--rm` for ephemeral containers (most Tillandsias use cases).
- **Health check command returns wrong exit code** — always use `exit 0` (healthy) or `exit 1` (unhealthy); exit codes 2+ are ignored.
- **Startup race condition** — tray checks host port before container is ready. Use `podman healthcheck run` or poll manually with retry; never assume port is bound immediately.

## See also

- `runtime/enclave-startup-sequencing.md` — Multi-container enclave readiness timing and ordering
- `runtime/container-health-checks.md` — Deep dive on health check implementations
- `runtime/forge-container.md` — Forge-specific lifecycle (ephemeral project containers)
