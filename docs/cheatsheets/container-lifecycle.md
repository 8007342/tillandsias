# container-lifecycle — Container State and Lifecycle Management

**Use when**: Debugging container state issues, understanding initialization sequence, managing container startup/shutdown, troubleshooting unexpected container removal.

## Provenance

- https://github.com/opencontainers/runtime-spec — OCI Container Runtime Specification (state machine)
- https://docs.podman.io/en/latest/markdown/podman-run.1.html — Podman run and container lifecycle
- https://github.com/opencontainers/image-spec — OCI Image Specification (image vs. container distinction)
- **Last updated:** 2026-05-02

@trace spec:init-command, spec:observability-convergence

## Container State Machine

Every container transitions through these states:

```
created → running → paused ↔ running → stopped → removed
  ↓                                      ↓
[ready to start]                  [can restart]

Tillandsias containers are always started immediately after creation,
skipping the idle "created" state.
```

| State | Meaning | Visible? | Logs Available? |
|-------|---------|----------|-----------------|
| **created** | Image loaded, container config applied, not yet started | `podman ps -a` | No; container never ran |
| **running** | Container process executing (entrypoint + app) | `podman ps` | Yes; streaming or buffered |
| **paused** | Container frozen (rare in Tillandsias) | `podman ps` with status | Limited; app is paused |
| **stopped** | Container exited (graceful or crash) | `podman ps -a` | Yes; full exit log available |
| **removed** | Container deleted from system | Not visible | Lost forever |

## Checking Container Status

```bash
# Show all running containers (including Tillandsias)
podman ps

# Show ALL containers (running + stopped)
podman ps -a

# Show full status of a container
podman inspect tillandsias-proxy | jq '.[] | {State, Name, Image}'

# Useful inspect fields:
#   .State.Running (boolean)
#   .State.Status (string: "running", "exited", "paused")
#   .State.ExitCode (integer: 0 = success, non-zero = error)
#   .State.StartedAt / .State.FinishedAt (timestamps)
```

## Container Lifecycle in Tillandsias

### Startup Sequence

1. **Image Check** (`tillandsias --init` or on-demand)
   - Container image must exist locally: `podman images | grep tillandsias`
   - If missing, build from Containerfile: `scripts/build-image.sh <image-name>`

2. **Container Creation & Start**
   - `podman run --name <container-name> <image-tag>`
   - Tillandsias applies security flags: `--cap-drop=ALL`, `--security-opt=no-new-privileges`, `--userns=keep-id`
   - Entrypoint runs immediately (e.g., `/opt/entrypoint.sh`)

3. **Initialization Phase** (first 10-30 seconds)
   - Container sets up runtime directories
   - Services bind to ports (proxy → :3128, inference → :11434)
   - Applications emit startup logs
   - Observable via: `podman logs -f <container>`

4. **Ready Phase**
   - Services accept connections
   - Health checks pass (if configured)
   - Logs stabilize (no more "initializing..." messages)

### Shutdown Sequence

1. **Stop Signal** (`podman stop <container>` or `tillandsias --clean`)
   - SIGTERM sent to container process (graceful shutdown)
   - Container has 10 seconds to clean up

2. **Cleanup Phase**
   - Process flushes buffers, closes files
   - Logs final messages (if any)
   - Process exits with code 0 (success) or non-zero (error)

3. **Stopped State**
   - Container still exists on disk: `podman ps -a` shows it
   - Logs preserved: `podman logs <container>` still works
   - Can restart: `podman start <container>`

4. **Removal** (optional, Tillandsias does this automatically)
   - `podman rm <container>` — delete container from disk
   - Logs lost: `podman logs <container>` now fails
   - Image still exists: `podman images | grep tillandsias`

## Staleness Detection (Init Builds)

Tillandsias uses hash-based staleness detection to avoid rebuilding unchanged images:

| Trigger | Action | Result |
|---------|--------|--------|
| Image sources changed (Containerfile, etc.) | Hash mismatch | Image rebuilt |
| Image sources unchanged | Hash match + image exists | Build skipped (fast) |
| `tillandsias --init` re-run | Staleness checked for each image | Each image built only if needed |
| `tillandsias --init --force` | Force flag set | All images rebuilt regardless of staleness |

```bash
# View cached hashes (internal use)
ls ~/.cache/tillandsias/build-hashes/

# Force rebuild (if staleness detection fails)
tillandsias --init --force
```

## Health Checks and Readiness

| Container | Health Check | Ready Signal |
|-----------|--------------|--------------|
| **proxy** | Port 3128 responds to CONNECT | `[init] proxy ready` in logs |
| **git** | SSH key generated, daemon bound | `[init] git-mirror ready` in logs |
| **inference** | Model pull completes, API responds | `/api/version` succeeds |
| **forge** | Entrypoint runs, depends on enclave | `OpenCode listening on :4096` |
| **browser-core** | Chromium process started | `[browser] core ready` in logs |

Debug mode speeds up readiness checks:
```bash
tillandsias --init --debug    # Extended timeouts, verbose startup logs
```

## Cleanup and Orphaned Containers

Tillandsias automatically cleans up:
- Stopped containers (older than N days, hardcoded)
- Failed build containers (intermediate images, no `tillandsias-` prefix)
- Dangling images (no container references them)

Manual cleanup:
```bash
# Remove a specific container
podman rm <container>

# Remove all stopped tillandsias containers
podman ps -a --filter "name=tillandsias" --filter "status=exited" --quiet | xargs podman rm

# Clean up dangling images (safe)
podman image prune
```

**Important**: Tillandsias startup fails if a container with the same name already exists and is stopped. The automatic cleanup prevents this.

## Debugging Container Lifecycle Issues

**Container exits immediately:**
```bash
podman inspect <container> | jq '.[] | .State'
# Check ExitCode and Logs keys
podman logs <container> | tail -20
```

**Container hangs during startup:**
```bash
podman logs -f <container>
# Watch logs for stuck "Initializing..." messages
# If stuck for > 30s, kill container and check image / entrypoint
```

**"Container name already exists" error:**
```bash
podman ps -a | grep <name>
podman rm <name>    # Remove the old container
```

**Port already in use:**
```bash
podman port <container>        # See port mappings
lsof -i :<port>                # See what's using the port
```
