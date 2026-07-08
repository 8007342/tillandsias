# Implementation Proposal: Watchdog & Progress UI for Silent Failures

## Architecture Changes

### 1. Augment `BuildProgress` with Timestamps
In `crates/tillandsias-core/src/state.rs`, the `BuildProgress` struct tracks the status (`InProgress`, `Completed`, `Failed`). We must add a `started_at: Instant` and `last_updated_at: Instant` to track staleness.

```rust
pub struct BuildProgress {
    pub status: BuildStatus,
    pub started_at: std::time::Instant,
    pub last_updated_at: std::time::Instant,
    pub description: Option<String>,
}
```

### 2. Introduce `BuildStatus::Stalled`
Extend `BuildStatus` to include a `Stalled(Duration)` variant. 

### 3. Tray UI Watchdog (Event Loop)
In `src-tauri/src/event_loop.rs`, during the standard event tick, implement a watchdog over `state.active_builds`. 
- If a build has been `InProgress` for > 3 minutes with no heartbeat, transition it to `Stalled`.
- This ensures the UI is no longer passively waiting, but actively surfacing the delay.

### 4. Contextual Status Line Updates
Update `status_text` truth table in `crates/tillandsias-core/src/state.rs`:
- When `(active_builds, stage)` contains a `Stalled` build, output `Setting up... (taking longer than expected)`.
- If multiple builds stall, show `Setup stalled — check network`.

### 5. Backend Heartbeats
To prevent false-positive stalls during long but successful builds, the `--init` execution must stream incremental progress via the control wire (e.g. reading from `build-*-progress.jsonl`).
- Forward JSONL metrics (like "Step X/Y") as `BuildProgressEvent::Update(description)` back to the tray to update `last_updated_at`.

## Rollout Plan
1. **Phase 1 (UI Only)**: Implement the UI Watchdog based purely on time (e.g. 5 minute warning). This immediately stops indefinite hangs from being silent.
2. **Phase 2 (Telemetry sync)**: Bridge the JSONL progress logs from the VM to the macOS tray host, supplying real-time heartbeats.
