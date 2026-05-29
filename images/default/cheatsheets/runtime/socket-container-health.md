---
title: Container Health Checks — OCI HEALTHCHECK Standard
since: 2026-05-04
last_verified: 2026-05-04
tags: [container, health-check, oci, podman, docker, readiness, supervision]
tier: bundled
bundled_into_image: true
summary_generated_by: hand-curated
---

# Container Health Checks — OCI HEALTHCHECK Standard

@trace spec:socket-container-orchestration

**Version baseline**: Podman 4.0+, Docker 1.13+, OCI Image Spec v1.0.0+  
**Use when**: Implementing health supervision in Tillandsias enclave (proxy, git, inference, forge); coordinating startup sequences; detecting and recovering from hung containers.

## Provenance

- https://docs.podman.io/en/latest/markdown/podman-wait.1.html — `podman wait --condition=healthy` for blocking on health state
- https://docs.docker.com/engine/reference/builder/#healthcheck — OCI HEALTHCHECK instruction syntax, interval/timeout/retries semantics, exit code meanings
- https://github.com/opencontainers/image-spec/blob/v1.0.0/config.md#healthcheck — OCI standard for health check structure and state values
- **Last updated:** 2026-05-04

## Why NOT sd_notify or socket activation

Alpine containers (used in Tillandsias images) lack `systemd` entirely. Solutions like `sd_notify` only work in systemd host contexts. HEALTHCHECK is portable across all container runtimes and works in Alpine, Fedora, Debian, and any OCI image without systemd.

| Mechanism | Works in Alpine | Works in Podman | State queryable | Reason excluded |
|-----------|-----------------|-----------------|-----------------|-----------------|
| **HEALTHCHECK** | ✅ YES | ✅ YES | ✅ YES (via inspect) | **STANDARD — use this** |
| sd_notify | ❌ NO | ❌ NO | ❌ NO | Requires systemd |
| containerd events | ✅ YES | ⚠️ Partial | ❌ NO | Only signals state change, not queryable state |
| Custom socket | ✅ YES | ✅ YES | ⚠️ Manual | Adds complexity; HEALTHCHECK is the standard |

## OCI HEALTHCHECK Structure

```dockerfile
HEALTHCHECK [OPTIONS] CMD <command>

# Example:
HEALTHCHECK --interval=30s --timeout=5s --retries=3 --start-period=10s \
  CMD curl --fail http://localhost:3000/health || exit 1
```

| Flag | Default | Meaning |
|------|---------|---------|
| `--interval` | 30s | Time between health checks |
| `--timeout` | 10s | Max time to wait for check result (exit code 124 if exceeded) |
| `--retries` | 3 | Consecutive failures before marking `unhealthy` |
| `--start-period` | 0s | Grace period after start; failures during this period do NOT count |

**Exit codes:**
- `0` — Container is healthy
- `1` — Container is unhealthy
- `124` — Command timed out (counted as unhealthy)
- Other — System error (not counted as failure)

## Health Check Tiers in Tillandsias Enclave

@trace spec:socket-container-orchestration

### Tier 0: Image Definition

Every Tillandsias image MUST declare a HEALTHCHECK in its Dockerfile:

```dockerfile
# tillandsias-proxy/Containerfile
HEALTHCHECK --interval=5s --timeout=2s --retries=3 \
  CMD curl --fail http://localhost:3128 || exit 1

# tillandsias-git/Containerfile
HEALTHCHECK --interval=5s --timeout=2s --retries=3 \
  CMD git --version >/dev/null 2>&1 || exit 1

# tillandsias-inference/Containerfile
HEALTHCHECK --interval=10s --timeout=3s --retries=5 --start-period=30s \
  CMD curl --fail http://localhost:11434/api/version || exit 1

# tillandsias-forge/Containerfile
HEALTHCHECK --interval=5s --timeout=3s --retries=3 --start-period=15s \
  CMD test -f /tmp/forge-ready || exit 1
```

**Why every image:** Without a declared HEALTHCHECK, `podman wait --condition=healthy` has no health state to query. Old images without HEALTHCHECK are incomplete and must upgrade.

### Tier 1: Runtime Blocking (Orchestrator)

The Tillandsias tray handler (`src-tauri/src/handlers.rs`) blocks on health state using `podman wait`:

```bash
# Block until container becomes healthy (returns immediately if already healthy)
podman wait --condition=healthy tillandsias-proxy

# With timeout (Rust async wrapper):
timeout 15 podman wait --condition=healthy tillandsias-proxy || {
  log::error!("Proxy failed to become healthy after 15s");
  exit 1
}
```

@trace spec:socket-container-orchestration

```rust
// In handlers.rs::ensure_enclave_ready()
use tokio::process::Command;
use tokio::time::timeout;

async fn wait_for_container_healthy(
    container_name: &str,
    timeout_sec: u64,
) -> Result<(), Box<dyn std::error::Error>> {
    // podman wait --condition=healthy blocks until state changes
    let mut cmd = Command::new("podman")
        .args(&["wait", "--condition=healthy", container_name])
        .spawn()?;
    
    // Wrap in tokio timeout to prevent infinite hang
    match timeout(
        std::time::Duration::from_secs(timeout_sec),
        cmd.wait()
    ).await {
        Ok(Ok(status)) if status.success() => Ok(()),
        Ok(Ok(status)) => Err(format!("Container {} unhealthy", container_name).into()),
        Ok(Err(e)) => Err(Box::new(e)),
        Err(_) => Err(format!("Timeout waiting for {} ({}s)", container_name, timeout_sec).into()),
    }
}
```

**Key point:** `podman wait --condition=healthy` is not polling. It blocks the kernel-level event queue until the health state changes, then returns immediately. No polling loop, zero wasted CPU cycles.

### Tier 2: Queries and Introspection

Once a container is running, query its current health state via `podman inspect`:

```bash
# Get entire health object
podman inspect tillandsias-proxy | jq '.State.Health'

# Output:
# {
#   "Status": "healthy",
#   "FailingStreak": 0,
#   "Log": [
#     {
#       "Start": "2026-05-04T14:30:00.123456789Z",
#       "End": "2026-05-04T14:30:01.234567890Z",
#       "ExitCode": 0,
#       "Output": ""
#     },
#     ...
#   ]
# }

# Just the status
podman inspect tillandsias-proxy --format '{{.State.Health.Status}}'
# Output: healthy, unhealthy, or starting

# FailingStreak (how many consecutive failures so far)
podman inspect tillandsias-proxy --format '{{.State.Health.FailingStreak}}'
```

## Practical Patterns with Interval/Timeout/Retries Tuning

### Pattern 1: Proxy Container (Fast, Reliable)

```dockerfile
# Squid starts instantly; health check is just a TCP connect
HEALTHCHECK --interval=5s --timeout=2s --retries=3 \
  CMD curl --fail http://localhost:3128 || exit 1
```

**Why these values:**
- `interval=5s`: Quick detection of failures; Squid is stateless
- `timeout=2s`: Squid responds in <200ms under normal load
- `retries=3`: Three consecutive failures = ~15s total, acceptable for a critical service
- `start-period=0s`: Squid is ready by the time the container starts; no grace period needed

### Pattern 2: Git Service (Moderate Complexity)

```dockerfile
# git daemon needs to initialize repositories
HEALTHCHECK --interval=5s --timeout=3s --retries=3 --start-period=5s \
  CMD git --version >/dev/null 2>&1 || exit 1
```

**Why these values:**
- `start-period=5s`: git daemon needs a few seconds to bind sockets
- `interval=5s`: Detect hung git daemon quickly
- `timeout=3s`: git --version is instant but include buffer
- `retries=3`: Acceptable grace period for initialization

### Pattern 3: Inference Container (Slow, Non-Critical)

```dockerfile
# Ollama pulls models on first run; can take 30-60 seconds
HEALTHCHECK --interval=10s --timeout=5s --retries=10 --start-period=30s \
  CMD curl --fail http://localhost:11434/api/version || exit 1
```

**Why these values:**
- `start-period=30s`: Ollama needs time to initialize and pull T0/T1 models
- `interval=10s`: Less frequent checks to reduce noise during model pull
- `timeout=5s`: Ollama may be slow under pull load; 5s is safe
- `retries=10`: ~100 seconds total (~10s + 10*10s) before "unhealthy" — covers typical model pulls

**Important:** Inference is a soft failure (non-critical path). If it fails to become healthy, the tray logs DEGRADED but enclave is still usable. See pattern 4 below.

### Pattern 4: Forge Container (Project-Specific)

```dockerfile
# Forge entrypoint compiles code or sets up environment
HEALTHCHECK --interval=5s --timeout=5s --retries=5 --start-period=15s \
  CMD test -f /tmp/forge-ready || exit 1
```

**Project-specific health check examples:**

```bash
# Option A: File marker (simplest)
test -f /tmp/forge-ready

# Option B: Language server on port
curl -f http://localhost:8080/health

# Option C: Process presence
pgrep -f "bash|zsh|python" >/dev/null

# Option D: Multiple checks (all must pass)
git status >/dev/null 2>&1 && \
  cargo --version >/dev/null 2>&1 && \
  test -d /workspace
```

**Why these values:**
- `start-period=15s`: Forge compile/setup time varies; 15s covers most projects
- `interval=5s`: Detect hung shells quickly
- `timeout=5s`: Project startup is slow; 5s is reasonable
- `retries=5`: ~40 seconds total (15s start + 5*5s retries); covers compilation

## Common Gotchas

### Gotcha 1: `--start-period` does NOT apply at runtime

The `--start-period` flag is **only** part of the Dockerfile `HEALTHCHECK` instruction. If you try to override at runtime:

```bash
# WRONG: --start-period is not a podman run flag
podman run --healthcheck-start-period=30s my-app  # IGNORED

# CORRECT: start-period only works in Dockerfile
# In Dockerfile:
HEALTHCHECK --start-period=30s CMD ...
```

If you need a grace period at runtime, add a startup script that sleeps:

```bash
#!/bin/bash
# entrypoint.sh
sleep 10  # Grace period before app startup
exec /app/myapp
```

### Gotcha 2: Exit code 124 is immediate failure

If the probe command times out (exceeds `--timeout`), exit code is 124, which counts as ONE failure toward `--retries`. This is different from a slow response:

```bash
# Slow response (takes 4s)
timeout 5 curl http://localhost:3000/health
# → Takes 4s, returns 0, health status OK

# Timeout (takes 6s, exceeds 5s timeout)
timeout 5 curl http://localhost:3000/health
# → Killed after 5s, exit code 124, counts as 1 failure
```

**Fix:** Set `--timeout` higher than your typical response time:

```dockerfile
# If curl typically takes 1-2s:
HEALTHCHECK --timeout=5s CMD curl http://localhost:3000/health
```

### Gotcha 3: Health check probe logs are NOT in `podman logs`

Probe output goes to `podman inspect`, NOT `podman logs`. Don't look for debug output in logs:

```bash
# WRONG: Health check output is not here
podman logs my-app | grep -i health  # Nothing

# CORRECT: Health check output is here
podman inspect my-app | jq '.State.Health.Log'
```

### Gotcha 4: Environment variables NOT expanded in HEALTHCHECK CMD

The CMD string does NOT get bash environment variable expansion:

```dockerfile
ENV MY_PORT=8080

# WRONG: $MY_PORT not expanded
HEALTHCHECK CMD curl http://localhost:$MY_PORT/health

# CORRECT: Use bash -c to enable expansion
HEALTHCHECK CMD bash -c 'curl http://localhost:$MY_PORT/health || exit 1'
```

### Gotcha 5: `podman wait --condition=healthy` after container stop

If a container is already stopped, `podman wait` returns immediately (container state is known). This is safe:

```bash
podman stop my-app
podman wait --condition=healthy my-app  # Returns immediately (already unhealthy/stopped)
```

## Orchestrator Integration — Tillandsias Enclave

@trace spec:socket-container-orchestration

The tray handler uses `podman wait` to coordinate startup:

```rust
// Pseudo-code from handlers.rs::ensure_enclave_ready()

// 1. Start proxy (critical path)
log::info!("Starting proxy"; spec="socket-container-orchestration");
start_container("tillandsias-proxy")?;
wait_for_healthy("tillandsias-proxy", 15)?;  // Block until healthy

// 2. Start git (depends on proxy)
log::info!("Starting git"; spec="socket-container-orchestration");
start_container("tillandsias-git")?;
wait_for_healthy("tillandsias-git", 15)?;  // Block until healthy

// 3. Start forge (depends on proxy + git)
log::info!("Starting forge"; spec="socket-container-orchestration");
start_container(&format!("tillandsias-forge-{}", genus))?;
wait_for_healthy(&format!("tillandsias-forge-{}", genus), 60)?;  // Longer timeout for compilation

// User can start coding here; tray returns

// 4. Start inference (non-critical, async background task)
tokio::spawn(async {
    // Fire-and-forget; don't block tray
    if let Err(e) = wait_for_healthy("tillandsias-inference", 120).await {
        log::warn!("Inference unavailable: {}", e; safety="DEGRADED");
    }
});
```

**Key property:** No polling. Each `wait_for_healthy()` blocks the kernel event queue until state change. Timeout is enforced via `tokio::time::timeout()` to prevent infinite hangs.

## Observability — Monitoring Health State Changes

@trace spec:socket-container-orchestration

Listen for health state changes via `podman events`:

```bash
# Stream health check events (JSON)
podman events \
  --type container \
  --filter event=health_status \
  --format json | \
  jq 'select(.Actor.Attributes.name | startswith("tillandsias-"))'

# Output:
# {
#   "Type": "container",
#   "Event": "health_status",
#   "Actor": {
#     "ID": "abc123...",
#     "Attributes": {
#       "name": "tillandsias-proxy",
#       "health_status": "healthy"
#     }
#   },
#   "Time": 1714252800,
#   "TimeNano": 1714252800123456789
# }
```

In Rust, combine with event subscription for logging:

```rust
// Subscribe to health events and emit telemetry
#[tokio::main]
async fn monitor_health() -> Result<()> {
    let mut cmd = Command::new("podman")
        .args(&[
            "events",
            "--type", "container",
            "--filter", "event=health_status",
            "--format", "json"
        ])
        .stdout(Stdio::piped())
        .spawn()?;

    let reader = BufReader::new(cmd.stdout.take().unwrap());
    let mut lines = tokio::io::AsyncBufReadExt::lines(reader);

    while let Some(line) = lines.next_line().await? {
        let event: serde_json::Value = serde_json::from_str(&line)?;
        let name = event["Actor"]["Attributes"]["name"].as_str().unwrap_or("unknown");
        let status = event["Actor"]["Attributes"]["health_status"].as_str().unwrap_or("unknown");

        log::info!("{} → {}", name, status; spec="socket-container-orchestration");

        // Emit telemetry event
        telemetry::emit("container_health_change", json!({
            "container": name,
            "status": status,
            "spec": "socket-container-orchestration"
        }));
    }

    Ok(())
}
```

## See also

- `runtime/socket-container-orchestration.md` — Enclave startup sequence using health checks
- `runtime/socket-enclave-diagnostics.md` — Debugging health check failures and timeouts
- `runtime/event-driven-monitoring.md` — Subscribing to health state changes via events
- `runtime/enclave-startup-sequencing.md` — Full orchestration flow with timing targets
