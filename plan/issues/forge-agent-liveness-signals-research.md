# Order 265 — Forge Agent Liveness Signals: Research Verdict

**Status**: Draft v1
**Author**: opencode/big-pickle
**Date**: 2026-07-10T07:00Z
**Spec reference**: order 265 exit criteria (research verdict + fixture-level prototype)

## Problem Statement

When a forge agent crashes, hangs, or hits an API quota inside its 90-minute
cycle, the host cannot distinguish "alive and progressing" from "dead air" until
the hard timeout fires. The operator's direction (The Tlatoāni, 2026-07-10):
*"Perhaps we could later add better heartbeat and alive signals so we don't rely
on timeouts."*

The current architecture has three timeout layers, all fire-only:

| Layer | Value | Source | Gap |
|-------|-------|--------|-----|
| Litmus STEP 3 | 600s | `run-litmus-test.sh` → `timeout` | Binary pass/fail; no progress signal |
| `repeat` cycle | 5400s (90m) | `repeat:191-239` | Hard kill; no early warning |
| Smoke lock | 7200s (2h) | `with-smoke-lock.sh:16` | Serializes tests; no agent-level signal |

If the agent completes in 10 minutes, the remaining 80 minutes of the
90-minute budget are wasted. If the agent dies at minute 11, the gate waits
until minute 600 (litmus) or minute 5400 (repeat) before detecting it.

## Current Observable Signals (Inventory)

### A. Container lifecycle events (Rust-side, `--debug`)

**Source**: `diagnostic_event_emitter.rs` + `client.rs:emit_launch_event()`
**Signal**: `event:container_launch stage=<x> state=<y>` and
`event:container_exit container=<x> exit_code=<n>`
**Reliability**: HIGH for container start/crash/exit. Does NOT observe in-process
health — a container running but an agent hung inside it looks identical to an
agent progressing.

### B. Git commit detection (host-side, shell)

**Source**: `litmus-git-delta-wait.sh` — probes `git rev-parse HEAD`,
`git rev-list --count <before>..HEAD -- plan/`, `git ls-remote origin <branch>`
**Reliability**: HIGH for confirming work happened. Latency: depends on git-mirror
relay (typically 5-30s). Only fires after a commit+push — dead air between
commits is invisible.

### C. Podman container health (host-side, Rust)

**Source**: `container_deps.rs:LivenessProbe::run_check()` — periodic Vault/Proxy
re-ensure check.
**Reliability**: N/A for forge — `LivenessProbe` only covers Vault and Proxy, NOT
the forge agent container. This is the gap order 265 targets.

### D. stderr event stream (host-side, Rust)

**Source**: `DiagnosticsHandle::start_typed_event_stream()` — captures
`event:container_stderr` lines from support containers.
**Reliability**: HIGH for support container output. Does NOT capture forge agent
stdout/stderr — the forge runs attached (stdio inherited), so its output goes
to the `repeat` script's stdout capture, not the diagnostics stream.

### E. Filesystem progress (host-side, shell)

**Source**: None implemented. The in-forge agent does not write heartbeat files,
progress markers, or periodic checkpoints to the shared mount
(`/home/forge/src/<project>`).

## Candidate Signals Evaluated

### Candidate 1: Heartbeat file on shared mount

| Aspect | Assessment |
|--------|-----------|
| Mechanism | Agent touches `<project>/.forge-heartbeat` every N seconds |
| Reliability | HIGH — file mtime is deterministic, no network required |
| Latency | O(N) seconds (heartbeat interval) |
| Invasiveness | LOW — single `touch` in agent loop |
| Cross-host | Yes — same mount visible on all platforms |
| Failure mode | Missing/stale mtime = dead air |
| Risk | Agent must cooperate; if agent process dies mid-touch, the file is stale |

**Verdict**: Best primary signal. Minimal implementation: one `touch` command in
the agent's main loop, host polls mtime.

### Candidate 2: Git commit cadence

| Aspect | Assessment |
|--------|-----------|
| Mechanism | Host probes `git rev-parse HEAD` at intervals |
| Reliability | HIGH — already implemented in `litmus-git-delta-wait.sh` |
| Latency | 5-30s (git-mirror relay) |
| Invasiveness | ZERO — no changes needed |
| Cross-host | Yes |
| Failure mode | No commits = indistinguishable from slow progress |
| Risk | Agents may go long stretches without committing (research, exploration) |

**Verdict**: Good complementary signal. Already partially implemented. Cannot be
the sole liveness signal because research/exploration cycles produce no commits
for extended periods.

### Candidate 3: Podman container exec probe

| Aspect | Assessment |
|--------|-----------|
| Mechanism | `podman exec <forge> <probe-cmd>` at intervals |
| Reliability | HIGH — confirms container is alive and responsive |
| Latency | O(1s) per probe |
| Invasiveness | MEDIUM — requires a probe command in the container |
| Cross-host | Yes (podman is universal) |
| Failure mode | Exec failure = container hung or crashed |
| Risk | Exec into the agent's namespace may interfere with its work; race conditions on shared resources |

**Verdict**: Useful as a secondary signal but higher risk. A simpler variant
(podman `inspect` for state) can detect container exit without exec.

### Candidate 4: Vsock control wire pulse

| Aspect | Assessment |
|--------|-----------|
| Mechanism | Agent sends a heartbeat frame over the vsock control wire |
| Reliability | HIGH — bidirectional, typed |
| Latency | O(1s) |
| Invasiveness | MEDIUM — requires protocol extension |
| Cross-host | Depends on transport backend availability |
| Failure mode | No pulse = dead |
| Risk | Only works when VM substrate is running (not CLI/forge-container mode) |

**Verdict**: Overkill for the current scope. The control wire is not active
during CLI-mode forge launches (the most common e2e path). Defer to order 153
(VM headless persistent listener).

### Candidate 5: Process-level watchdog (podman events stream)

| Aspect | Assessment |
|--------|-----------|
| Mechanism | Host monitors `podman events --filter container=<forge>` for Died/Stop |
| Reliability | HIGH — kernel-level signal |
| Latency | <1s |
| Invasiveness | ZERO — already exists via diagnostic event emitter |
| Cross-host | Yes |
| Failure mode | Only detects container exit, not in-process hang |
| Risk | None |

**Verdict**: Already implemented (diagnostic_event_emitter.rs). Sufficient for
detecting container crash but NOT in-process hang. Combine with heartbeat file
for full coverage.

## Chosen Minimal Design

**Design principle**: Layer three signals — container exit (already exists), agent
heartbeat file (new), git commit cadence (already exists) — into a single
`forge-liveness-probe.sh` script that the litmus runner and `repeat` wrapper can
call.

### Signal hierarchy (most to least immediate)

1. **Container exit** (podman events): immediate crash detection. Already emitted
   by `diagnostic_event_emitter.rs` when `--debug` is on. The host-side probe
   polls `podman inspect --format '{{.State.Status}}'` — O(1s), zero-dependency.

2. **Heartbeat file mtime** (shared mount): in-process liveness. The agent
   touches `.forge-heartbeat` every 30s. The host-side probe checks
   `stat --format='%Y' .forge-heartbeat` — O(1s). If mtime is older than
   `HEARTBEAT_DEADLINE` (default 120s = 4 missed heartbeats), the agent is
   considered dead-air.

3. **Git commit cadence** (git rev-parse): progress confirmation. Already
   implemented in `litmus-git-delta-wait.sh`. The host-side probe checks
   `git rev-parse HEAD` every `POLL_S` seconds. If HEAD changes within the
   window, the agent is actively producing work.

### Liveness states

```
ALIVE_PROGRESSING  — heartbeat fresh AND (container running OR HEAD advanced recently)
ALIVE_QUIET         — heartbeat fresh BUT no commits AND container running
DEAD_AIR            — heartbeat stale (>120s) AND no commits AND container running
DEAD_CRASHED        — container exited (podman state != running)
DEAD_KILLED         — timeout signal received (TERM/SIGKILL from repeat/litmus)
```

### Host-side probe script: `scripts/forge-liveness-probe.sh`

```
Usage: forge-liveness-probe.sh <mode> [options]

Modes:
  status    — print one of: alive_progressing, alive_quiet, dead_air, dead_crashed, dead_killed
  wait      — poll until state changes from alive_* to dead_*, exit non-zero on dead
  deadline  — print the wall-clock deadline given a start time and budget

Options:
  --project-dir <path>    project directory (default: current dir)
  --heartbeat-file <path> heartbeat file (default: .forge-heartbeat)
  --heartbeat-deadline <s> stale threshold (default: 120)
  --poll-interval <s>     polling interval (default: 10)
  --budget <s>            total budget in seconds (default: 5400)
  --start-time <epoch>    cycle start time (default: now)
```

### Agent-side heartbeat (one-liner, added to forge entrypoint)

```bash
# Background heartbeat — touches .forge-heartbeat every 30s
(while true; do touch "${PROJECT_DIR}/.forge-heartbeat" 2>/dev/null; sleep 30; done) &
```

This is added to the forge container's entrypoint script (not the agent process
itself), so it survives agent restarts within the container.

### Integration points

1. **`repeat` script** (line 191-239): Replace the fixed `timeout` with a
   `forge-liveness-probe.sh wait --budget $TIMEOUT_SECONDS --start-time $START`
   alongside the `timeout` wrapper. The probe provides the exit reason (dead_air
   vs dead_crashed vs dead_killed).

2. **litmus STEP 3** (`litmus-opencode-prompt-e2e-shape.yaml`): The 600s step
   timeout stays as hard backstop. The litmus runner logs the liveness state at
   timeout for diagnostics (was it dead_air or still progressing?).

3. **`with-smoke-lock.sh` waiters**: Log the liveness state of the locked
   process when the lock wait exceeds a soft threshold.

### Hard-cap preservation

- The 90-minute `repeat` timeout is the hard backstop and is NOT removed.
- The 600s litmus STEP 3 timeout is the litmus hard backstop and is NOT removed.
- The liveness probe provides EARLY DETECTION and PROGRESS VISIBILITY, not
  replacement of hard timeouts.

## Fixture-Level Prototype Plan

The prototype validates that the host-side probe correctly distinguishes the
five liveness states using a controlled test setup:

### Test fixture: `scripts/test-forge-liveness-probe.sh`

```
Test 1: alive_progressing
  - Create .forge-heartbeat (fresh mtime)
  - Start a background process that does `git commit --allow-empty` every 5s
  - Run probe → expect: alive_progressing

Test 2: alive_quiet
  - Create .forge-heartbeat (fresh mtime)
  - No git commits
  - Run probe → expect: alive_quiet

Test 3: dead_air
  - Create .forge-heartbeat with mtime 200s ago (stale)
  - Run probe → expect: dead_air

Test 4: dead_crashed
  - No .forge-heartbeat file
  - No running container (or mock podman)
  - Run probe → expect: dead_crashed

Test 5: deadline calculation
  - Start time = now, budget = 5400
  - Run probe deadline → expect wall-clock timestamp in 90 minutes
```

Each test is a litmus STEP with a stdout pattern assertion (pass/fail).

## Files to Create/Modify

| File | Action | Purpose |
|------|--------|---------|
| `scripts/forge-liveness-probe.sh` | CREATE | Host-side liveness probe script |
| `scripts/test-forge-liveness-probe.sh` | CREATE | Fixture test for the probe |
| `openspec/litmus-tests/litmus-forge-liveness-probe-shape.yaml` | CREATE | Litmus binding for the probe shape |
| `images/forge/entrypoint.sh` | MODIFY | Add background heartbeat touch loop |

## Exit Criteria Mapping

| Criterion | Status |
|-----------|--------|
| Research verdict comparing candidate signals | THIS DOCUMENT |
| Chosen minimal design with signal hierarchy | Section "Chosen Minimal Design" |
| Fixture-level prototype plan | Section "Fixture-Level Prototype Plan" |
| Hard-cap backstop preserved | YES — 90m repeat + 600s litmus unchanged |

## Next Steps

1. Implement `scripts/forge-liveness-probe.sh` (the probe script itself)
2. Add heartbeat touch to forge entrypoint
3. Write litmus test `litmus-forge-liveness-probe-shape.yaml`
4. Wire `repeat` script to log liveness state at timeout
5. Run fixture tests on linux_mutable host
