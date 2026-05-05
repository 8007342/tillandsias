---
title: Enclave Diagnostics — Health Check Debugging
since: 2026-05-04
last_verified: 2026-05-04
tags: [enclave, diagnostics, debugging, health-check, podman, troubleshooting]
tier: bundled
bundled_into_image: true
summary_generated_by: hand-curated
---

# Enclave Diagnostics — Health Check Debugging

@trace spec:socket-container-orchestration

**Version baseline**: Podman 4.0+  
**Use when**: Debugging enclave startup failures, health check timeouts, orchestration hangs, or container state anomalies; interpreting health state transitions.

## Provenance

- https://docs.podman.io/en/latest/markdown/podman-inspect.1.html — Querying container state, health status, and health logs
- https://docs.podman.io/en/latest/markdown/podman-logs.1.html — Container stdout/stderr logs (note: health probe output is NOT here)
- https://docs.podman.io/en/latest/markdown/podman-events.1.html — Real-time container state events
- **Last updated:** 2026-05-04

## Quick Diagnostics Checklist

### Is the container running?

```bash
podman ps -a | grep tillandsias-
# Shows: CONTAINER ID, IMAGE, STATUS, NAMES
# STATUS values: Up X seconds, Exited (1), etc.
```

| Status | Meaning | Action |
|--------|---------|--------|
| `Up X seconds` | Container is running | Check health status next |
| `Up X days` | Container has been running a long time | Expected for persistent services |
| `Exited (0)` | Container exited cleanly (completed task) | Normal for one-shot work |
| `Exited (1)` | Container exited with error | Check logs: `podman logs <id>` |
| `Restarting` | Container is in restart loop | Image or entrypoint has a bug |
| `Not present` | Container doesn't exist | Recreate it |

### What is the health status?

```bash
# Quick check
podman inspect tillandsias-proxy --format '{{.State.Health.Status}}'
# Output: healthy, unhealthy, starting, or <nil> (no healthcheck)

# Full details
podman inspect tillandsias-proxy | jq '.State.Health'
```

| Status | Meaning | What to do |
|--------|---------|-----------|
| `healthy` | Container passed the last health check | ✓ OK; container is ready |
| `unhealthy` | Container failed health check N consecutive times | ❌ FAIL; see health logs below |
| `starting` | Container is in `--start-period` grace window | ⏱️ WAIT; checks disabled during grace period |
| `<nil>` (no health object) | No HEALTHCHECK in image | ⚠️ OLD IMAGE; must add HEALTHCHECK and rebuild |

### Why is the container unhealthy?

Check the health check log (NOT container logs):

```bash
# Health check probe logs (last 10 checks)
podman inspect tillandsias-proxy | jq '.State.Health.Log'

# Output:
# [
#   {
#     "Start": "2026-05-04T14:30:10.123Z",
#     "End": "2026-05-04T14:30:11.456Z",
#     "ExitCode": 1,
#     "Output": "curl: (7) Failed to connect to 127.0.0.1 port 3128: Connection refused"
#   },
#   ...
# ]
```

**Exit codes:**
- `0` = Health check passed
- `1` = Health check failed (app returned error)
- `124` = Health check command timed out (exceeded `--timeout`)
- Other = System error (e.g., command not found)

**Analysis:**
```bash
# If all ExitCode == 1:
# → App is running but probe failed
# → Check app logs: podman logs tillandsias-proxy

# If ExitCode == 124 (timeout):
# → Probe took longer than --timeout (e.g., 5s)
# → Increase --timeout in Containerfile HEALTHCHECK

# If Output has "Connection refused":
# → App hasn't started listening yet
# → Increase --start-period in Containerfile

# If Output has "curl: command not found":
# → Image is missing curl (or other dependency)
# → Rebuild image with dependency installed
```

### What does FailingStreak mean?

```bash
podman inspect tillandsias-proxy | jq '.State.Health.FailingStreak'
# Output: 3
```

| Value | Meaning |
|-------|---------|
| `0` | Last check passed; all good |
| `1-2` | Recent failures, but not yet "unhealthy" |
| `3+` | Threshold reached (default `--retries=3`); status = "unhealthy" |

**Use:** If FailingStreak is 1-2, container is failing but not yet officially unhealthy. Waiting another check cycle may recover.

### How long has the container been running?

```bash
podman inspect tillandsias-proxy --format '{{.State.StartedAt}}'
# Output: 2026-05-04T14:30:05.123456789Z

# Calculate age
start=$(podman inspect tillandsias-proxy --format '{{.State.StartedAt}}' | cut -d'T' -f2)
echo "Started at UTC: $start"
```

Compare startup time to `--start-period`:

```
If StartedAt is 2 seconds ago, but --start-period is 10s:
→ Checks are disabled (in grace period)
→ Status might be "starting"
→ Wait 8 more seconds for grace period to expire
```

## Health State Meanings

### State: `healthy`

```
✓ Container is ready to serve traffic
✓ Last health check passed (ExitCode 0)
✓ FailingStreak is 0
✓ Orchestrator can proceed (wait_for_healthy returns)

Example:
podman inspect tillandsias-proxy | jq '.State.Health'
{
  "Status": "healthy",
  "FailingStreak": 0,
  "Log": [{..., "ExitCode": 0}]
}
```

**Action:** Container is ready. Use it.

### State: `unhealthy`

```
❌ Container failed health check N consecutive times (FailingStreak >= --retries)
❌ App may be hung, crashed, or misconfigured
❌ Orchestrator aborts startup (wait_for_healthy times out after N retries)

Example:
podman inspect tillandsias-proxy | jq '.State.Health'
{
  "Status": "unhealthy",
  "FailingStreak": 3,
  "Log": [
    {..., "ExitCode": 1, "Output": "curl: (7) Connection refused"},
    {..., "ExitCode": 1, "Output": "curl: (7) Connection refused"},
    {..., "ExitCode": 1, "Output": "curl: (7) Connection refused"}
  ]
}
```

**Action:** Check app logs and health probe output. Fix the issue, then recreate container.

### State: `starting`

```
⏱️ Container is in --start-period grace period
⏱️ Health checks are DISABLED (failures don't count)
⏱️ Orchestrator waits (may appear to hang)

Example (container started 3s ago, --start-period=10s):
podman inspect tillandsias-proxy | jq '.State.Health'
{
  "Status": "starting",
  "FailingStreak": 0,
  "Log": []  # No checks run yet
}
```

**Action:** Wait. Checks will resume after grace period expires.

### State: `<nil>` (no health object)

```
⚠️ Image has no HEALTHCHECK declared
⚠️ Orchestrator cannot wait for readiness
⚠️ Old image; must add HEALTHCHECK and rebuild

Example:
podman inspect old-container | jq '.State.Health'
null
```

**Action:** Rebuild image with HEALTHCHECK:

```dockerfile
HEALTHCHECK --interval=5s --timeout=2s --retries=3 \
  CMD curl --fail http://localhost:3000/health || exit 1
```

## Timeout Interpretation

### Scenario: `podman wait --condition=healthy` timeout

```bash
# Command times out after 15 seconds
timeout 15 podman wait --condition=healthy tillandsias-proxy
# → Timeout! Container did not become healthy within 15s
```

**Diagnosis flowchart:**

```
┌─ Is the container running?
│  ├─ podman ps -a | grep tillandsias-proxy
│  │  No → Container exited or was never created
│  │  Yes → Check step 2
│  │
├─ What is the health status?
│  ├─ podman inspect tillandsias-proxy --format '{{.State.Health.Status}}'
│  │  "starting" → In grace period; wait longer
│  │  "healthy" → Already healthy; podman wait should return immediately
│  │  "unhealthy" → Failed health check; check step 3
│  │  <nil> → No HEALTHCHECK; old image
│  │
├─ Why is it unhealthy?
│  ├─ podman inspect tillandsias-proxy | jq '.State.Health.Log[-1]'
│  │  ExitCode 0 → Last check passed (race condition; wait again)
│  │  ExitCode 1 → App returned error; check app logs
│  │  ExitCode 124 → Probe timed out; increase --timeout
│  │
├─ Check app logs
│  ├─ podman logs tillandsias-proxy
│  │  "Address already in use" → Port conflict; stop other services
│  │  "Connection refused" → App not listening; check entrypoint
│  │  "Error: ..." → Fix app error, rebuild image
│  │
└─ If still stuck:
   ├─ Recreate container: podman rm -f tillandsias-proxy
   ├─ Rebuild image: scripts/build-image.sh proxy
   ├─ Try again
```

### Common Timeout Reasons

| Symptom | Cause | Fix |
|---------|-------|-----|
| `podman wait` hangs forever | Container hasn't declared HEALTHCHECK | Add HEALTHCHECK to Containerfile |
| `podman wait` times out after N seconds | Probe still failing after retries | Check app logs; fix app error |
| Status is "starting" for >60s | `--start-period` is too long | Reduce it in Containerfile |
| Intermittent timeouts | Slow system under load | Increase timeout values in orchestrator |
| Port 3128 in use (proxy case) | Another Squid is running | `lsof -i :3128` and kill it |

## Practical Diagnosis Session

### Example 1: Proxy fails to start

```bash
# User reports: "Enclave startup hangs for 15s then fails"

# Step 1: Is proxy running?
$ podman ps -a | grep tillandsias-proxy
abc123   tillandsias-proxy:v0.1.37.25   "squid -N -f /etc..."   Up 2 seconds

# Step 2: What is its health status?
$ podman inspect tillandsias-proxy --format '{{.State.Health.Status}}'
unhealthy

# Step 3: Why is it unhealthy?
$ podman inspect tillandsias-proxy | jq '.State.Health.Log'
[
  {
    "Start": "2026-05-04T14:30:10.123Z",
    "End": "2026-05-04T14:30:11.456Z",
    "ExitCode": 1,
    "Output": "curl: (7) Failed to connect to 127.0.0.1 port 3128: Connection refused"
  },
  { ... same error x2 ... }
]

# Step 4: Check proxy logs (NOT health logs)
$ podman logs tillandsias-proxy
2026-05-04 14:30:10 [E] (4) Address already in use [::]:3128
2026-05-04 14:30:10 Squid is shutting down gracefully...

# Analysis: Port 3128 is already in use!

# Step 5: Find what's using port 3128
$ lsof -i :3128
COMMAND     PID    USER   FD   TYPE             DEVICE SIZE/OFF NODE NAME
squid     12345    root   15u  IPv4 0x12345678  0t0  TCP *:3128 (LISTEN)

# Step 6: Kill old Squid and retry
$ kill -9 12345
$ podman rm -f tillandsias-proxy  # Clean up failed container
# Orchestrator will restart proxy in next enclave startup
```

### Example 2: Forge takes too long to compile

```bash
# User reports: "Forge startup times out after 60s; I have a big project"

# Step 1: Check forge status
$ podman inspect tillandsias-forge-mygenus --format '{{.State.Health.Status}}'
unhealthy

# Step 2: Check health logs
$ podman inspect tillandsias-forge-mygenus | jq '.State.Health.Log'
[
  {"ExitCode": 1, "Output": "test: /tmp/forge-ready: No such file or directory"},
  ... (3 times; hit --retries=3 limit)
]

# Step 3: Check forge logs (the real compilation output)
$ podman logs tillandsias-forge-mygenus
Loading workspace... 30%
Checking dependencies... 60%
Building binaries... (still running)

# Analysis: Cargo is still compiling; 60s wasn't enough.

# Solution: Increase --start-period in forge Containerfile
HEALTHCHECK --interval=5s --timeout=3s --retries=5 --start-period=60s \
  CMD test -f /tmp/forge-ready || exit 1

# Or wait longer manually:
$ for i in {1..120}; do
    podman inspect tillandsias-forge-mygenus --format '{{.State.Health.Status}}' && break
    sleep 1
  done
```

### Example 3: Inference never becomes healthy (soft failure)

```bash
# User reports: "Forge works, but inference is degraded"

# Step 1: Check inference status
$ podman ps -a | grep tillandsias-inference
def456   tillandsias-inference:v0.1.37.25   "ollama serve"   Up 45 seconds

$ podman inspect tillandsias-inference --format '{{.State.Health.Status}}'
starting

# Step 2: Check health logs
$ podman inspect tillandsias-inference | jq '.State.Health.Log'
[
  {
    "Start": "2026-05-04T14:30:35.123Z",
    "End": "2026-05-04T14:30:37.456Z",
    "ExitCode": 1,
    "Output": "curl: (7) Failed to connect to 127.0.0.1 port 11434: Connection refused"
  },
  ... (still initializing)
]

# Step 3: Check inference logs
$ podman logs tillandsias-inference
Ollama initializing...
Pulling T0 model: qwen2.5:0.5b... (3 minutes remaining)
Pulling T1 model: llama3.2:3b... (4 minutes remaining)

# Analysis: Inference is still pulling models (60+ seconds expected)
# This is SOFT FAILURE; forge is still usable

# Solution: Wait (or check back later)
$ sleep 300  # Wait 5 minutes for models to pull
$ podman inspect tillandsias-inference --format '{{.State.Health.Status}}'
healthy
```

## Event Stream Monitoring

@trace spec:socket-container-orchestration

Watch health state changes in real-time:

```bash
# Stream all Tillandsias container health events
podman events \
  --type container \
  --filter event=health_status \
  --filter container=tillandsias-* \
  --format 'json' | \
  jq '{
    time: .Time,
    container: .Actor.Attributes.name,
    status: .Actor.Attributes.health_status
  }'

# Output:
# {
#   "time": 1714252810,
#   "container": "tillandsias-proxy",
#   "status": "healthy"
# }
# {
#   "time": 1714252815,
#   "container": "tillandsias-git",
#   "status": "healthy"
# }
```

This shows the exact moment each container becomes healthy during orchestration.

## Debug Commands Summary

```bash
# Quick health snapshot
for c in tillandsias-proxy tillandsias-git tillandsias-forge-* tillandsias-inference; do
  STATUS=$(podman inspect "$c" --format '{{.State.Health.Status}}' 2>/dev/null || echo "not-found")
  echo "$c: $STATUS"
done

# Full health log for container
podman inspect tillandsias-proxy | jq '.State.Health'

# Last health check result
podman inspect tillandsias-proxy | jq '.State.Health.Log[-1]'

# How many failures so far
podman inspect tillandsias-proxy | jq '.State.Health.FailingStreak'

# Container uptime
podman inspect tillandsias-proxy --format 'Started: {{.State.StartedAt}}'

# App logs (NOT health check output)
podman logs tillandsias-proxy

# Watch for state changes
podman events --type container --filter container=tillandsias-proxy

# If container is stuck:
podman stop tillandsias-proxy
podman rm -f tillandsias-proxy
# Orchestrator will restart
```

## No Polling Fallback

This cheatsheet does NOT mention polling loops like:

```bash
# ❌ WRONG: Don't do this
while true; do
  if podman inspect tillandsias-proxy --format '{{.State.Health.Status}}' | grep -q healthy; then
    echo "Ready!"
    break
  fi
  sleep 1
done
```

**Why:** Polling wastes CPU, adds latency, and misses fast transitions. Always use:

```bash
# ✓ CORRECT: Event-driven
podman wait --condition=healthy tillandsias-proxy
# Returns immediately when state changes (via kernel event queue)
```

The orchestrator uses `podman wait`, not polling.

## See also

- `runtime/socket-container-health.md` — HEALTHCHECK mechanics and tuning
- `runtime/socket-container-orchestration.md` — Orchestration flow and timing
- `runtime/event-driven-monitoring.md` — Event stream patterns
- `runtime/container-lifecycle.md` — Container states and transitions
