<!-- @trace spec:mcp-on-demand -->

# mcp-on-demand Specification

## Status

active

## Purpose

MCP servers (filesystem, resource tools, inference) are started on-demand when first invoked by an agent, not eagerly at container startup. Reduces boot time, memory footprint, and startup complexity. Servers are destroyed on container shutdown (ephemeral lifecycle).

This spec ensures:
- Faster forge container startup (no wait for MCP health checks)
- Lower memory footprint (unused servers not running)
- Graceful degradation if an MCP server fails
- Clean lifecycle: startup on first use, shutdown on container exit

## Requirements

### Requirement: On-demand MCP server startup

MCP servers MUST NOT be started during container initialization. Instead, they are spawned lazily when an agent first invokes a server operation.

#### Scenario: Container startup without MCP
- **WHEN** a forge container starts
- **THEN** no MCP servers (filesystem, resource, inference) MUST be launched
- **AND** the container MUST enter ready state without waiting for MCP health checks
- **AND** container boot time MUST be measured in seconds, not minutes

#### Scenario: MCP server spawned on first use
- **WHEN** an agent inside the forge invokes a filesystem operation (e.g., `list_directory`)
- **THEN** the tray MUST detect that the filesystem MCP server is not running
- **AND** MUST spawn the server process (if defined for the container image)
- **AND** MUST wait for health check to pass (max 5 seconds)
- **AND** MUST then forward the agent's request to the server

#### Scenario: MCP server remains running
- **WHEN** the first MCP server is started successfully
- **THEN** it MUST remain running for the container's lifetime
- **AND** subsequent operations MUST NOT re-spawn the server
- **AND** the server MUST use a persistent connection (not restart per RPC)

#### Scenario: MCP server startup failure
- **WHEN** an MCP server fails to start (health check timeout or crash)
- **THEN** the tray MUST log `mcp_startup_failed = true, server = "filesystem", reason = "timeout"`
- **AND** MUST return an error to the agent (e.g., "MCP server unavailable")
- **AND** MUST NOT retry automatically; the next operation re-attempts

### Requirement: Multiple MCP servers coexist

If multiple MCP servers are configured, each MUST be started independently on-demand.

#### Scenario: Filesystem MCP started first
- **WHEN** an agent calls `read_file`
- **THEN** the filesystem MCP server MUST be spawned

#### Scenario: Resource MCP started later
- **WHEN** an agent later calls `get_system_info`
- **THEN** the resource MCP server MUST be spawned independently
- **AND** MUST NOT affect the filesystem server

#### Scenario: Inference MCP only if configured
- **WHEN** the container image does NOT include inference tools
- **THEN** no inference MCP server SHOULD be attempted
- **AND** agents MUST receive a "not available" response if they query it

### Requirement: Health check and readiness

Before accepting requests, an MCP server MUST pass a health check proving it is ready to accept connections.

#### Scenario: Health check passes
- **WHEN** an MCP server process starts
- **THEN** the tray MUST wait for the server to bind to its socket/port
- **AND** MUST send a simple ping or version query
- **AND** MUST wait up to 5 seconds for a successful response
- **AND** if successful, MUST mark the server as ready

#### Scenario: Health check timeout
- **WHEN** the health check does not receive a response within 5 seconds
- **THEN** the tray MUST kill the server process
- **AND** MUST log `mcp_health_check_failed = true, timeout_seconds = 5`
- **AND** MUST return error to the agent without retrying

#### Scenario: Health check response parsing
- **WHEN** the server responds to health check
- **THEN** the tray MUST verify the response format matches expected protocol
- **AND** if malformed, MUST treat it as a failed check

### Requirement: Ephemeral lifecycle — servers destroyed on shutdown

MCP servers are children of the container process. On container exit, all MCP servers MUST be terminated.

#### Scenario: Container graceful shutdown
- **WHEN** the tray sends SIGTERM to the container
- **THEN** the container's init process MUST receive SIGTERM
- **AND** all MCP server processes (children) MUST be terminated as part of the container's shutdown
- **AND** resources MUST be cleaned up

#### Scenario: Container forced kill
- **WHEN** the tray sends SIGKILL to the container
- **THEN** all container processes (including MCP servers) MUST be killed immediately
- **AND** resources MUST be reclaimed by the kernel

#### Scenario: No MCP server persistence
- **WHEN** the container stops and is removed
- **THEN** all MCP server state MUST be lost
- **AND** next container start MUST create fresh processes
- **AND** no socket files or IPC state MUST persist

### Requirement: MCP server communication channel

MCP servers MUST communicate with agents via a channel (socket, pipe, or stdio).

#### Scenario: Unix socket communication
- **WHEN** the MCP server uses a Unix socket
- **THEN** the socket MUST be created in a tmpfs directory (e.g., `/tmp/mcp-<server>.sock`)
- **AND** the socket MUST be cleaned up when the server exits

#### Scenario: Stdio-based communication
- **WHEN** the MCP server uses stdio for RPC
- **THEN** the tray MUST connect to the server's stdin/stdout
- **AND** MUST send requests as JSON-RPC and read responses

#### Scenario: Concurrent requests
- **WHEN** multiple agents invoke the same MCP server concurrently
- **THEN** the server MUST handle multiple connections (or multiplex requests)
- **AND** MUST NOT deadlock or drop requests

### Requirement: Litmus test — on-demand MCP lifecycle

Critical verification paths:

#### Test: No MCP on startup
```bash
# Start forge container
podman run --rm -d --name test-mcp-startup tillandsias-forge sleep 3600

# Check running processes
sleep 2
podman exec test-mcp-startup ps aux | grep -i mcp
# Expected: no mcp processes listed (only "ps" itself)

podman stop test-mcp-startup
```

#### Test: MCP spawned on demand
```bash
# Start forge with agent that uses MCP
podman run --rm -d --name test-mcp-demand tillandsias-forge /opt/start-dev-shell

# Simulate agent filesystem call
sleep 1
podman exec test-mcp-demand sh -c "echo 'list /tmp' | nc -U /tmp/mcp-filesystem.sock" &
AGENT_PID=$!

# Wait for MCP to spawn
sleep 2

# Check that filesystem MCP is now running
podman exec test-mcp-demand ps aux | grep -i "mcp.*filesystem"
# Expected: mcp-filesystem process listed

wait $AGENT_PID 2>/dev/null
podman stop test-mcp-demand
```

#### Test: Health check timeout recovery
```bash
# Start container
podman run --rm -d --name test-mcp-health tillandsias-forge sleep 3600

sleep 1

# Try to access MCP server that's not running
timeout 6 podman exec test-mcp-health /opt/mcp-client filesystem list /
# Expected: error after ~5 seconds (health check timeout)

# Verify tray logs show health check failure
grep -i "mcp_health.*timeout" ~/.config/tillandsias/logs/
# Expected: log line present

podman stop test-mcp-health
```

#### Test: Concurrent MCP requests
```bash
# Start forge
podman run --rm -d --name test-mcp-concurrent tillandsias-forge /opt/start-dev-shell

sleep 2

# Send multiple filesystem requests in parallel
for i in 1 2 3; do
  (podman exec test-mcp-concurrent /opt/mcp-client filesystem list /tmp &)
done

# Wait for all to complete
wait

# Check that all succeeded (no deadlocks)
grep -i "mcp.*error\|mcp.*deadlock" ~/.config/tillandsias/logs/ | wc -l
# Expected: 0 errors

podman stop test-mcp-concurrent
```

#### Test: Ephemeral cleanup
```bash
# Run container with MCP
podman run --rm -d --name test-mcp-cleanup tillandsias-forge /opt/start-dev-shell

# Use MCP to ensure it's spawned
sleep 2
podman exec test-mcp-cleanup /opt/mcp-client filesystem list / >/dev/null

# Get MCP server PIDs while running
PIDS=$(podman exec test-mcp-cleanup pgrep -f 'mcp-filesystem' | tr '\n' ' ')
echo "Running MCP PIDs: $PIDS"

# Stop container
podman stop test-mcp-cleanup

# Verify PIDs are gone
sleep 1
ps -p $PIDS 2>&1
# Expected: "no such process" or similar (all cleaned up)

# Verify socket is gone
ls /tmp/mcp-*.sock 2>&1
# Expected: no such file (cleaned up)
```

## Litmus Tests

Bind to tests in `openspec/litmus-bindings.yaml`:
- pending — test binding required for S2→S3 progression

Gating points:
- MCP server spins up on first tool/resource request; health check passes within timeout
- Server listens on Unix socket at `/tmp/mcp-<server>-<project>.sock`
- Requests while server is starting are queued and retried after health check
- Health check verifies `initialize` RPC succeeds and includes required fields
- Server exits cleanly when forge container stops; socket file cleaned up
- Second request to same server reuses socket (no restart)
- Server crash is detected on next request attempt; new server spawned on retry
- Latency for first request includes startup overhead (logged as `mcp_request_latency_ms`)
- Subsequent requests skip startup (latency is <10ms typical)

## Observability

Annotations referencing this spec can be found by:
```bash
grep -rn "@trace spec:mcp-on-demand" src-tauri/ scripts/ crates/ images/ --include="*.rs" --include="*.sh"
```

Log events SHALL include:
- `spec = "mcp-on-demand"` on all MCP lifecycle events
- `mcp_server = "<name>"` identifying which server (filesystem, resource, inference)
- `mcp_spawned = true` when server is started
- `mcp_health_check_passed = true` on successful health check
- `mcp_health_check_failed = true` on timeout or error
- `mcp_server_shutdown = true` on container exit
- `mcp_request_latency_ms = N` tracking startup overhead per request

## Sources of Truth

- `cheatsheets/runtime/event-driven-monitoring.md` — process spawning and lifecycle events
- `cheatsheets/observability/cheatsheet-metrics.md` — instrumentation for health check latency
- `cheatsheets/runtime/forge-hot-cold-split.md` — startup overhead and lazy loading patterns
- `cheatsheets/runtime/cheatsheet-frontmatter-spec.md` — MCP server protocol and integration patterns

