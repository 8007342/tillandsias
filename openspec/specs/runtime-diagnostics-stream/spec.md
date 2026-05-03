<!-- @trace spec:runtime-diagnostics-stream -->

# runtime-diagnostics-stream Specification

## Status

status: active

## Purpose

Live streaming of container events and diagnostics to the user's terminal when running with `--debug` flag. Events flow from container (exit, signal, resource events) → podman → tray → terminal in near-real-time. Stream is ephemeral and scoped to the current session; no persistence across runs.

This spec ensures:
- Real-time visibility into container execution for debugging
- Structured event format (timestamps, event type, container name, details)
- Graceful degradation if streaming fails
- Zero persistence on disk
- Easy filtering/grepping for developers

## Requirements

### Requirement: Stream activation on --debug flag

When the tray is launched with `--debug`, diagnostic streaming SHALL be enabled and connected to stdout/stderr.

#### Scenario: Debug flag activates streaming
- **WHEN** the user runs `tillandsias --debug`
- **THEN** the tray parses the `--debug` flag
- **AND** initializes the diagnostic event stream
- **AND** connects the stream to the terminal

#### Scenario: Streaming disabled by default
- **WHEN** the tray runs without `--debug`
- **THEN** container events are logged but NOT streamed to terminal
- **AND** events are available via log files for post-mortem analysis

#### Scenario: Debug output to stderr
- **WHEN** the stream is active
- **THEN** events are written to stderr (not stdout)
- **AND** stdout remains clean for user-facing text

### Requirement: Event structure and formatting

Each diagnostic event SHALL have a consistent, parseable structure with timestamp, event type, container, and payload.

#### Scenario: Container start event
- **WHEN** a container transitions to running state
- **THEN** the stream emits:
  ```
  [2026-05-03T14:23:45.123Z] event:container_start container=tillandsias-myproject-foo status=running
  ```
- **AND** the timestamp is in ISO 8601 UTC
- **AND** the event type is prefixed with `event:`

#### Scenario: Container exit event
- **WHEN** a container exits
- **THEN** the stream emits:
  ```
  [2026-05-03T14:24:10.456Z] event:container_exit container=tillandsias-myproject-foo exit_code=0 duration_seconds=25
  ```
- **AND** exit code and duration are included

#### Scenario: Container signal event
- **WHEN** a container receives a signal (SIGTERM, SIGSEGV, OOM)
- **THEN** the stream emits:
  ```
  [2026-05-03T14:24:12.789Z] event:container_signal container=tillandsias-myproject-foo signal=SIGSEGV
  ```

#### Scenario: Resource event (OOM, disk)
- **WHEN** resource exhaustion is detected
- **THEN** the stream emits:
  ```
  [2026-05-03T14:24:15.012Z] event:resource_exhaustion container=tillandsias-myproject-foo resource=memory_oom limit_bytes=2147483648
  ```

#### Scenario: Stderr line pass-through
- **WHEN** a container writes to stderr
- **THEN** the stream emits:
  ```
  [2026-05-03T14:24:16.345Z] event:container_stderr container=tillandsias-myproject-foo line="error: compilation failed"
  ```
- **AND** the line is truncated or escaped to fit on one line
- **AND** only the last N lines are streamed (e.g., 1000, to prevent noise)

### Requirement: Event filtering and control

The user SHALL be able to control which events are streamed via command-line or environment variables.

#### Scenario: Filter by event type
- **WHEN** the user runs `tillandsias --debug --debug-filter=event:container_exit,event:container_signal`
- **THEN** only exit and signal events are streamed
- **AND** other events (stderr, resource) are logged but not printed

#### Scenario: Filter by container name
- **WHEN** the user runs `tillandsias --debug --debug-container=tillandsias-myproject-*`
- **THEN** only events from matching containers are streamed
- **AND** other containers' events are logged but not streamed

#### Scenario: Debug level control
- **WHEN** the user sets `TILLANDSIAS_DEBUG_LEVEL=verbose`
- **THEN** additional internal events (network, mounts, cgroup) are streamed
- **AND** the default level is `normal` (container events only)

### Requirement: Ephemeral stream lifecycle

The diagnostic stream exists only for the duration of the current tray session and is NOT persisted.

#### Scenario: Stream created on tray start
- **WHEN** the tray starts with `--debug`
- **THEN** the event stream is initialized from a fresh queue
- **AND** no historical events from previous runs are replayed

#### Scenario: Stream destroyed on tray exit
- **WHEN** the tray shuts down
- **THEN** the event stream is flushed and closed
- **AND** any buffered events are discarded
- **AND** the next tray session starts with an empty queue

#### Scenario: No stream file on disk
- **WHEN** checking the tray's runtime directory
- **THEN** no `.stream` or `.events` files persist after tray exit
- **AND** events are available only in the scrollback terminal history or log files

### Requirement: Backpressure and flow control

The stream SHALL handle high event rates gracefully without overwhelming the terminal.

#### Scenario: Event rate limit
- **WHEN** a container produces > 1000 events per second (pathological case)
- **THEN** the stream buffers events and emits them at a controlled rate
- **AND** logs `event_buffer_depth = N` when the buffer exceeds 100 events
- **AND** does not drop events but may batch them: `[...truncated N events...]`

#### Scenario: Terminal blocked
- **WHEN** the terminal is slow to read (e.g., over a slow SSH connection)
- **THEN** the event stream does not block the tray's event loop
- **AND** buffered events are kept in a ring buffer (max 10K events)
- **AND** oldest events are dropped if the buffer overflows

#### Scenario: Streaming failure
- **WHEN** the stream writer encounters an error (broken pipe, disk full)
- **THEN** the tray logs the error but continues running
- **AND** container operations are not affected
- **AND** events can still be found in log files

### Requirement: Litmus test — diagnostic streaming activation and lifecycle

Critical verification paths:

#### Test: Stream activation
```bash
# Run tray with debug flag
./tillandsias-tray --debug 2>&1 | head -20 &
TRAY_PID=$!

# Create a container to trigger events
sleep 1
podman run --rm --name test-stream-event alpine sleep 5

# Wait for container to exit and check stream
sleep 6

# Should see event lines on stderr
kill $TRAY_PID 2>/dev/null
# Expected: output shows "[...] event:container_start" and "[...] event:container_exit"
```

#### Test: Event structure parsing
```bash
# Capture debug output
TILLANDSIAS_DEBUG=1 ./tillandsias-tray --debug 2>debug.log &
TRAY_PID=$!

sleep 1
podman run --rm --name test-parse alpine echo "test output" >&2
sleep 5

kill $TRAY_PID 2>/dev/null

# Verify event format
grep -E '^\[.*Z\] event:' debug.log
# Expected: lines matching ISO timestamp + event: prefix

# Verify event type variety
grep -o 'event:[a-z_]*' debug.log | sort -u
# Expected: container_start, container_exit, container_stderr, etc.
```

#### Test: Event filtering
```bash
# Run with filter to show only exits
./tillandsias-tray --debug --debug-filter=event:container_exit 2>filtered.log &
TRAY_PID=$!

sleep 1
for i in 1 2 3; do
  podman run --rm --name test-filter-$i alpine sleep 1
  sleep 1
done

sleep 3
kill $TRAY_PID 2>/dev/null

# Count event types
grep -o 'event:[a-z_]*' filtered.log | sort | uniq -c
# Expected: only container_exit lines (no start, no stderr)
```

#### Test: Ephemeral stream
```bash
# Run tray once
./tillandsias-tray --debug 2>run1.log &
TRAY_PID=$!
sleep 1
podman run --rm alpine sleep 1
sleep 3
kill $TRAY_PID 2>/dev/null
COUNT1=$(grep -c 'event:' run1.log || echo 0)

# Run tray again
./tillandsias-tray --debug 2>run2.log &
TRAY_PID=$!
sleep 1
# Should NOT replay events from first run
sleep 3
kill $TRAY_PID 2>/dev/null
COUNT2=$(grep -c 'event:' run2.log || echo 0)

# Each run should have roughly the same event count (not cumulative)
echo "Run 1 events: $COUNT1, Run 2 events: $COUNT2"
# Expected: both counts similar, no historical replay in run2
```

#### Test: No stream persistence
```bash
# Complete tray lifecycle
./tillandsias-tray --debug 2>/dev/null &
TRAY_PID=$!
sleep 1
podman run --rm alpine sleep 1
sleep 3
kill $TRAY_PID 2>/dev/null

# Check for stream files
find ~/.config/tillandsias -name "*.stream" -o -name "*.events"
# Expected: no files found

# Check runtime directory
ls $XDG_RUNTIME_DIR/tillandsias-*.stream 2>&1
# Expected: no such file
```

## Observability

Annotations referencing this spec can be found by:
```bash
grep -rn "@trace spec:runtime-diagnostics-stream" src-tauri/ scripts/ crates/ images/ --include="*.rs" --include="*.sh"
```

Log events SHALL include:
- `spec = "runtime-diagnostics-stream"` on all stream events
- `stream_active = true` when debug flag is detected
- `event_type = "<name>"` for each emitted event
- `event_count = N` on flush
- `buffer_depth = N` on backpressure
- `stream_error = "<reason>"` on failure

## Sources of Truth

- `cheatsheets/runtime/event-driven-monitoring.md` — event capture and streaming patterns
- `cheatsheets/observability/cheatsheet-metrics.md` — structured event format and timestamping
- `cheatsheets/runtime/logging-levels.md` — debug level control and filtering
- `cheatsheets/runtime/cheatsheet-shortcomings.md` — backpressure patterns and flow control for high-throughput streams

