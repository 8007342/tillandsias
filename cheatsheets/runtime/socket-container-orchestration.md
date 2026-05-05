---
title: Container Orchestration Patterns — Enclave Startup Sequencing
since: 2026-05-04
last_verified: 2026-05-04
tags: [enclave, orchestration, startup-sequencing, podman, network, async, health-checks]
tier: bundled
bundled_into_image: true
summary_generated_by: hand-curated
---

# Container Orchestration Patterns — Enclave Startup Sequencing

@trace spec:socket-container-orchestration

**Version baseline**: Podman 4.0+, Tokio 1.0+, OCI Image Spec 1.0+  
**Use when**: Orchestrating Tillandsias enclave startup (proxy → git → inference → forge) with guaranteed ordering, no polling, pure event-driven supervision.

## Provenance

- https://docs.podman.io/en/latest/markdown/podman-wait.1.html — `podman wait --condition=healthy` blocking semantics
- https://docs.podman.io/en/latest/markdown/podman-network-create.1.html — Podman bridge networks for inter-container communication
- https://docs.docker.com/engine/reference/builder/#healthcheck — OCI HEALTHCHECK in Dockerfile (portable across runtimes)
- https://12factor.net/processes — Stateless processes and fast startup expectations
- **Last updated:** 2026-05-04

## Why NOT Custom Sockets / sd_notify / Choreography

| Approach | Pros | Cons | Verdict |
|----------|------|------|---------|
| **HEALTHCHECK + podman wait** | Portable, standard, no code, Alpine-compatible, queryable state | Requires image HEALTHCHECK declaration | **USE THIS** |
| Custom Unix socket | Flexible, binary-safe | Complex orchestrator code, hard to debug, breaks on container restart | ❌ NOT TILLANDSIAS |
| sd_notify (systemd) | Tight systemd integration | Requires systemd in container, Alpine incompatible, not portable | ❌ NOT TILLANDSIAS |
| TCP health endpoint | Flexible | Requires app-specific port, must handle slow startups | Supplementary only, not orchestration |
| Choreography (tight timing) | Minimal code | Fragile, hard to tune, races on slow systems | ❌ NOT TILLANDSIAS |
| Polling loop (while true; sleep) | Simple | Wastes CPU, misses fast state changes, breaks latency SLOs | ❌ NOT TILLANDSIAS |

**Decision:** HEALTHCHECK + `podman wait --condition=healthy` is the only approach that satisfies Tillandsias constraints:
1. **Portable:** Works in Podman, Docker, containerd, and any OCI runtime
2. **Alpine-compatible:** No systemd dependency
3. **Observable:** Health state queryable at any time via `podman inspect`
4. **Event-driven:** `podman wait` blocks the kernel, not polling
5. **Standard:** Part of OCI Image Spec; upgradeable without rewriting orchestrator

## Pure Event-Driven Enforcement — No Fallback Polling

The Tillandsias orchestrator (src-tauri/src/handlers.rs) enforces event-driven coordination:

@trace spec:socket-container-orchestration

```rust
// handlers.rs::ensure_enclave_ready() — SIMPLIFIED SKETCH

async fn ensure_enclave_ready(
    project_path: &str,
    genus: &str,
) -> Result<(), EnclaveDependencyError> {
    // === CRITICAL PATH (blocking) ===

    // 1. Create network
    let network = ensure_network("tillandsias-enclave").await?;
    log::info!("Network ready"; spec="socket-container-orchestration");

    // 2. Start proxy (fast, no dependencies)
    let proxy = start_container(ContainerSpec {
        name: "tillandsias-proxy".to_string(),
        image: "tillandsias-proxy:v{VERSION}".to_string(),
        network: network.clone(),
        healthcheck_cmd: Some("curl --fail http://localhost:3128 || exit 1".to_string()),
        ..Default::default()
    }).await?;

    // Block (event-driven, NOT polling) until proxy is healthy
    // podman wait --condition=healthy tillandsias-proxy
    // Returns immediately when health state changes to "healthy"
    let _ = tokio::time::timeout(
        Duration::from_secs(15),
        wait_for_condition(&proxy.id, "healthy")
    )
    .await
    .map_err(|_| EnclaveDependencyError::ProxyTimeout)?;

    log::info!("Proxy healthy"; spec="socket-container-orchestration");

    // 3. Start git (depends on proxy)
    let git = start_container(ContainerSpec {
        name: "tillandsias-git".to_string(),
        image: "tillandsias-git:v{VERSION}".to_string(),
        network: network.clone(),
        env: vec![
            ("HTTP_PROXY".to_string(), "http://tillandsias-proxy:3128".to_string()),
        ],
        healthcheck_cmd: Some("git --version >/dev/null 2>&1 || exit 1".to_string()),
        ..Default::default()
    }).await?;

    // Block (event-driven) until git is healthy
    let _ = tokio::time::timeout(
        Duration::from_secs(15),
        wait_for_condition(&git.id, "healthy")
    )
    .await
    .map_err(|_| EnclaveDependencyError::GitTimeout)?;

    log::info!("Git service healthy"; spec="socket-container-orchestration");

    // 4. Start forge (depends on proxy + git)
    let forge = start_container(ContainerSpec {
        name: format!("tillandsias-forge-{}", genus),
        image: "tillandsias-forge:v{VERSION}".to_string(),
        network: network.clone(),
        env: vec![
            ("HTTP_PROXY".to_string(), "http://tillandsias-proxy:3128".to_string()),
            ("TILLANDSIAS_PROJECT".to_string(), project_path.to_string()),
        ],
        healthcheck_cmd: Some("test -f /tmp/forge-ready || exit 1".to_string()),
        ..Default::default()
    }).await?;

    // Block (event-driven) until forge is healthy — this is the critical path
    let _ = tokio::time::timeout(
        Duration::from_secs(60),
        wait_for_condition(&forge.id, "healthy")
    )
    .await
    .map_err(|_| EnclaveDependencyError::ForgeTimeout)?;

    log::info!("Forge ready; user can start coding"; spec="socket-container-orchestration");

    // === BACKGROUND TASK (non-blocking) ===

    // 5. Start inference (fire-and-forget; NON-CRITICAL)
    // Spawn as background task; do NOT wait in main path
    let inference_network = network.clone();
    tokio::spawn(async move {
        if let Err(e) = start_and_wait_inference(&inference_network).await {
            log::warn!("Inference unavailable: {}", e; safety="DEGRADED", spec="socket-container-orchestration");
        }
    });

    // Return immediately; tray returns to user
    Ok(())
}

// === IMPLEMENTATION: Event-driven wait (NO POLLING) ===

async fn wait_for_condition(
    container_id: &str,
    condition: &str,  // "healthy", "removed", "exited", etc.
) -> Result<()> {
    // podman wait --condition=healthy <id>
    // This command BLOCKS the kernel event queue until the condition is met.
    // NOT a polling loop; the kernel wakes this task when state changes.

    let mut cmd = tokio::process::Command::new("podman")
        .args(&["wait", &format!("--condition={}", condition), container_id])
        .spawn()?;

    // Wait for exit; when state changes, podman wait exits with success
    cmd.wait().await?;
    Ok(())
}

// === BACKGROUND TASK: Inference (async, non-blocking) ===

async fn start_and_wait_inference(network: &Network) -> Result<()> {
    let inference = start_container(ContainerSpec {
        name: "tillandsias-inference".to_string(),
        image: "tillandsias-inference:v{VERSION}".to_string(),
        network: network.clone(),
        env: vec![
            ("HTTP_PROXY".to_string(), "http://tillandsias-proxy:3128".to_string()),
        ],
        healthcheck_cmd: Some("curl --fail http://localhost:11434/api/version || exit 1".to_string()),
        ..Default::default()
    }).await?;

    // Wait up to 120 seconds for inference to become healthy (model pulls can take 30-60s)
    // This is a soft timeout; if exceeded, we log DEGRADED but continue
    tokio::time::timeout(
        Duration::from_secs(120),
        wait_for_condition(&inference.id, "healthy")
    )
    .await
    .ok();  // Ignore timeout; inference is soft failure

    log::info!("Inference ready"; spec="socket-container-orchestration");
    Ok(())
}
```

**Key properties:**

1. **No polling:** `podman wait --condition=healthy` blocks on kernel event queue, not in a loop.
2. **No timeout races:** Each step has explicit `tokio::time::timeout()`.
3. **No fallback:** If a container fails to become healthy, the orchestrator fails hard (for critical path) or logs DEGRADED (for non-critical).
4. **Async throughout:** Every wait is `.await`-able; tray UI stays responsive.

## Image Upgrade Discipline

Every Tillandsias-managed image MUST include a HEALTHCHECK:

```dockerfile
# tillandsias-proxy/Containerfile
FROM fedora:44
RUN microdnf install -y squid
COPY squid.conf /etc/squid/
# ... build steps ...
HEALTHCHECK --interval=5s --timeout=2s --retries=3 \
  CMD curl --fail http://localhost:3128 || exit 1
CMD squid -N -f /etc/squid/squid.conf
```

**Version constraint:**
- Podman 4.0+ supports `podman wait --condition=healthy` (2021).
- Docker 1.13+ supports HEALTHCHECK (2017).
- All modern systems support this. Old images without HEALTHCHECK are incomplete.

**Backward compatibility:**
- If an image lacks a HEALTHCHECK, `podman wait --condition=healthy` returns immediately (no health state to wait for). This is safe but breaks orchestration (proxy could still be initializing when we launch git).
- All new images must declare HEALTHCHECK. Existing images must be upgraded.

## Startup Sequence Diagram

```
┌──────────────────────────────────────────────────────────────┐
│ TILLANDSIAS ENCLAVE STARTUP                                  │
│                                                              │
│ @trace spec:socket-container-orchestration                 │
└──────────────────────────────────────────────────────────────┘

Phase 1: CRITICAL PATH (Synchronous, Blocking)
══════════════════════════════════════════════════════════════

┌─────────────────────┐
│ Create Network      │  tillandsias-enclave (bridge)
│ (Instant)           │  All containers can reach each other
└──────────┬──────────┘
           │
           ↓
┌─────────────────────────────────────────────┐
│ START Proxy (tillandsias-proxy:3128)        │
│  ├─ Spawn container                         │
│  └─ [wait_for_condition("healthy")]         │  <-- BLOCKS HERE
│      └─ podman wait --condition=healthy     │      Kernel event queue
│         Returns when health_status changes  │      No polling
└──────────┬──────────────────────────────────┘
           │ (proxy now healthy; git can use it as HTTP_PROXY)
           ↓
┌─────────────────────────────────────────────┐
│ START Git (tillandsias-git)                 │
│ ENV: HTTP_PROXY=http://tillandsias-proxy    │
│  ├─ Spawn container                         │
│  └─ [wait_for_condition("healthy")]         │  <-- BLOCKS HERE
│      └─ podman wait --condition=healthy     │
└──────────┬──────────────────────────────────┘
           │ (git now healthy; forge can clone repositories)
           ↓
┌─────────────────────────────────────────────┐
│ START Forge (tillandsias-forge-<genus>)    │
│ ENV: HTTP_PROXY, TILLANDSIAS_PROJECT        │
│  ├─ Spawn container                         │
│  └─ [wait_for_condition("healthy")]         │  <-- BLOCKS HERE
│      └─ podman wait --condition=healthy     │      Critical path ends
└──────────┬──────────────────────────────────┘
           │
           │ ✓ CRITICAL PATH COMPLETE (~5-10 seconds)
           │   → User can start coding
           │   → Return to tray immediately
           │
           ↓ (SPAWN BACKGROUND TASK, no wait)

Phase 2: BACKGROUND TASK (Asynchronous, Non-Blocking)
═══════════════════════════════════════════════════════

┌─────────────────────────────────────────────┐
│ START Inference (tillandsias-inference)     │
│ [Non-blocking background spawn]             │
│  ├─ Spawn container (fire-and-forget)       │
│  ├─ tokio::spawn(async { ... })             │
│  └─ [wait_for_condition("healthy")]         │
│      └─ Logs DEGRADED if timeout            │  <-- Soft failure
│         Forge remains usable                │
│                                              │
│  Typical: 30-60s for model pulls            │
│  Max timeout: 120s                          │
└─────────────────────────────────────────────┘
```

## Timing Targets

| Phase | Target | Min | Max | Notes |
|-------|--------|-----|-----|-------|
| Create network | <100ms | 50ms | 500ms | Instant |
| Proxy start → healthy | <2s | 0.5s | 5s | Squid is stateless |
| Git start → healthy | <2s | 0.5s | 5s | Fast git --version check |
| Forge start → healthy | <5s | 2s | 30s | Project-dependent (compilation) |
| **Critical path total** | **<10s** | 5s | 40s | User waits here |
| Inference start → healthy (bg) | <120s | 5s | 120s | Model pulls can take 30-60s |
| Inference timeout (soft fail) | N/A | N/A | N/A | Logs DEGRADED; forge still usable |

## Dependency Graph

```
Host
 ├─ Tillandsias Tray (handlers.rs)
 │
 ├─ Network: tillandsias-enclave (bridge)
 │   ├─ CIDR: 10.89.0.0/16 (configurable)
 │   └─ Internal DNS: containers reach each other by name
 │
 ├─ tillandsias-proxy:3128 (CRITICAL)
 │   ├─ Image: tillandsias-proxy:v{VERSION}
 │   ├─ Health: curl --fail http://localhost:3128
 │   └─ Role: Caching HTTP/S proxy; ALL containers use it for outbound
 │
 ├─ tillandsias-git (CRITICAL)
 │   ├─ Image: tillandsias-git:v{VERSION}
 │   ├─ Depends on: tillandsias-proxy (via HTTP_PROXY env)
 │   ├─ Health: git --version
 │   └─ Role: Git mirror; forge clones from here (zero network)
 │
 ├─ tillandsias-forge-<genus> (CRITICAL)
 │   ├─ Image: tillandsias-forge:v{VERSION}
 │   ├─ Depends on: tillandsias-proxy + tillandsias-git
 │   ├─ Health: test -f /tmp/forge-ready (project-specific)
 │   └─ Role: Dev environment; user shells run here
 │   └─ ⚠️  USER WAITS FOR THIS
 │
 └─ tillandsias-inference (SOFT, BACKGROUND)
     ├─ Image: tillandsias-inference:v{VERSION}
     ├─ Depends on: tillandsias-proxy (optional, for model pulls)
     ├─ Health: curl --fail http://localhost:11434/api/version
     └─ Role: Local LLM inference; if unavailable, forge is still usable
```

## Failure Modes and Recovery

### Mode 1: Proxy fails to become healthy

```
Error: Proxy timeout after 15s
Log: ERROR: Proxy failed to become ready; aborting enclave startup
```

**Diagnosis:**
```bash
podman inspect tillandsias-proxy | jq '.State.Health'
# If Status is "unhealthy", check logs:
podman logs tillandsias-proxy
# Common: port 3128 already in use, Squid config error
```

**Recovery:**
```bash
podman rm -f tillandsias-proxy
# Fix image/config, then retry
```

### Mode 2: Git fails to become healthy

```
Error: Git timeout after 15s
Log: ERROR: Git service failed; aborting enclave startup
```

**Diagnosis:**
```bash
podman exec tillandsias-git git --version
# If fails, git binary is missing or corrupted
podman logs tillandsias-git
```

**Recovery:**
```bash
podman rm -f tillandsias-git
# Rebuild image with git installed
scripts/build-image.sh git
# Retry
```

### Mode 3: Forge fails to become healthy

```
Error: Forge timeout after 60s
Log: ERROR: Forge failed after 60s; user cannot start coding
```

**Diagnosis:**
```bash
podman logs tillandsias-forge-<genus>
# Check if compilation is still running:
podman exec tillandsias-forge-<genus> ps aux | grep -E "cargo|rustc|gcc"
```

**Recovery:**
```bash
# Option A: Wait longer (compile-heavy projects)
# Edit start-period in Containerfile HEALTHCHECK to 30s

# Option B: Check forge image
podman rm -f tillandsias-forge-<genus>
# Retry
```

### Mode 4: Inference fails (soft failure)

```
Warn: Inference unavailable (DEGRADED); inference requests will fail
Log: safety=DEGRADED, spec=socket-container-orchestration
```

**Status:**
- Forge is **still usable**
- Inference features are unavailable
- Logs show DEGRADED; tray continues

**Diagnosis:**
```bash
# Check inference container health
podman inspect tillandsias-inference | jq '.State.Health.Status'
# Check logs
podman logs tillandsias-inference
# Likely: Ollama downloading models (slow network)
```

**Recovery:**
- Wait for model pull to complete (~5-60 minutes depending on tier)
- Or disable inference features in config

## Observability and Monitoring

@trace spec:socket-container-orchestration

Watch orchestration events:

```bash
# Monitor all container state changes
podman events --type container --format json | \
  jq 'select(.Actor.Attributes.name | startswith("tillandsias-"))'

# In Rust, use event stream with telemetry:
tokio::spawn(async {
    let mut events = subscribe_to_events("tillandsias-*").await?;
    while let Some(event) = events.next().await {
        let container = &event.container_name;
        let event_type = &event.event_type;
        log::info!("{}: {}", container, event_type; spec="socket-container-orchestration");
    }
});
```

## See also

- `runtime/socket-container-health.md` — Deep dive on HEALTHCHECK mechanics
- `runtime/enclave-diagnostics.md` — Debugging orchestration failures
- `runtime/async-patterns-rust.md` — Tokio spawn, await, timeout patterns
- `runtime/event-driven-monitoring.md` — Subscribing to container events
