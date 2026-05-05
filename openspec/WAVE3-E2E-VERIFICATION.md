# Wave 3 — End-to-End Observability Chain Verification

This document specifies the end-to-end test case for verifying the observability-chain fixes complete the convergence from specs to implementation.

## Test Prerequisites

- Tillandsias built and installed: `./build.sh --install`
- Podman available and configured
- Linux host (chromium images only build on Linux)

## Test Case: Full Observability Chain

### Setup Phase
```bash
# Clean state — remove any running containers from a previous test
tillandsias /tmp/test-project --clean 2>/dev/null || true
tillandsias /tmp/test-project --destroy 2>/dev/null || true

# Verify no stale containers
podman ps -a | grep -c "tillandsias-.*-test-project" || true
```

### Phase 1: Binary Build and Installation
**Spec**: `openspec/specs/dev-build/spec.md` — Install exits with deterministic exit codes

```bash
./build.sh --install
EXIT_CODE=$?
```

**Expected Behavior**:
- Exit code: 0
- Message visible: `[build] SUCCESS` (or similar success indicator)
- Binary installed to `~/.local/bin/tillandsias`
- Can chain safely: `./build.sh --install && echo "next step"`

**Verification**:
```bash
[ $EXIT_CODE -eq 0 ] || echo "FAIL: build.sh --install failed"
which tillandsias || echo "FAIL: binary not on PATH"
```

### Phase 2: Image Pre-Build
**Spec**: `openspec/specs/init-command/spec.md` — Exit code contract + Debug mode + All images built

```bash
tillandsias --init --debug
EXIT_CODE=$?
```

**Expected Behavior**:
- Attempts to build all 6 images in order: proxy, forge, git, inference, chromium-core, chromium-framework
- Exit code: 0 (all images built or already cached)
- Terminal output shows progress: `[init] building proxy...`, `[init] image ready...`
- Debug logs written to `/tmp/tillandsias-init-*.log` for each image
- If any image fails:
  - Last 10 lines of failed log displayed to stderr
  - Exit code: 1
  - Chain breaks safely: `./build.sh --install && tillandsias --init || echo "init failed"`

**Verification**:
```bash
[ $EXIT_CODE -eq 0 ] || echo "FAIL: tillandsias --init failed"

# Verify all images exist (or at least were attempted)
podman images | grep "tillandsias-" | wc -l
# Should be ≥ 6 (or ≥ 4 on non-Linux where chromium skipped)

# Verify debug logs exist
ls -la /tmp/tillandsias-init-*.log 2>/dev/null || true
```

### Phase 3: Diagnostics with Containers Running
**Spec**: `openspec/specs/cli-diagnostics/spec.md` — Exit code contract + Container discovery + Log streaming

#### Step 1: Attach a project (brings up containers)
```bash
tillandsias /tmp/test-project --debug &
ATTACH_PID=$!

# Wait for containers to start (5 seconds)
sleep 5
```

#### Step 2: Stream diagnostics in separate terminal
```bash
timeout 3 tillandsias /tmp/test-project --diagnostics --debug
EXIT_CODE=$?
```

**Expected Behavior**:
- Discovers running containers for `/tmp/test-project`
- Exit code: 0 (Ctrl+C after 3 seconds = clean exit)
- Output to stderr includes:
  - `[diagnostics] SUCCESS: monitoring N containers`
  - `[diagnostics:debug] monitoring: tillandsias-test-project-forge` (in debug mode)
  - Live log lines prefixed: `[forge:test-project] ...`, `[proxy:shared] ...`
- Container logs stream in real-time

**Verification**:
```bash
[ $EXIT_CODE -eq 0 ] || echo "FAIL: diagnostics exit code not 0"
```

#### Step 3: Test error case — no containers
```bash
# Kill the attach process
kill $ATTACH_PID 2>/dev/null || true
sleep 2

# Verify no containers running
tillandsias /tmp/test-project --diagnostics
EXIT_CODE=$?
```

**Expected Behavior**:
- Exit code: 1 (failure)
- Message to stderr: `ERROR: no containers found for project: /tmp/test-project`
- Does NOT crash or hang

**Verification**:
```bash
[ $EXIT_CODE -ne 0 ] || echo "FAIL: diagnostics should exit 1 when no containers"
```

### Phase 4: Chaining End-to-End
**Spec**: Cross-spec integration — exit codes enable safe chaining

```bash
# Full chain with error handling
./build.sh --install && \
  tillandsias --init --debug && \
  echo "SUCCESS: all commands succeeded" || \
  echo "FAILURE: one or more commands failed"
```

**Expected Behavior**:
- Each command exits deterministically (0 or 1)
- Success message printed if all exit with 0
- Chain breaks safely at first failure
- Exit codes compose correctly in bash && and || chains

## Observable Behavior Summary

### SUCCESS Indicators
- `./build.sh --install` → exits 0
- `tillandsias --init --debug` → exits 0, all images built/cached
- `tillandsias /path --diagnostics` → exits 0 (when containers running), logs stream
- `/tmp/tillandsias-init-*.log` files exist in debug mode
- `[diagnostics] SUCCESS: monitoring N containers` visible on stderr

### FAILURE Indicators
- Any command exits 1
- Error messages on stderr (`ERROR: ...`)
- Failed build logs displayed inline in debug mode
- No diagnostics found message when no containers

## Traceability

- `@trace spec:dev-build` — ./build.sh --install
- `@trace spec:init-command` — tillandsias --init
- `@trace spec:cli-diagnostics` — tillandsias --diagnostics
- `@trace spec:observability-convergence` — overall chain convergence

## Cleanup

```bash
# Remove test artifacts
tillandsias /tmp/test-project --destroy 2>/dev/null || true
rm -rf /tmp/test-project
rm -f /tmp/tillandsias-init-*.log
```
