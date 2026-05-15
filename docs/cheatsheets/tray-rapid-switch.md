# Tray Rapid Project Switch Benchmarking

**Use when**: Testing project switch performance, validating menu consistency under high switching rates, or diagnosing latency regressions in the tray UI project list.

## Provenance

- [Tillandsias project CLAUDE.md - Tray Mode & GTK Tray](https://github.com/machiyotl/tillandsias/blob/main/CLAUDE.md) — Tray architecture and lifecycle
- [Linux kernel select() / poll() documentation](https://man7.org/linux/man-pages/man2/select.2.html) — Event loop primitives
- [GTK4 main loop integration](https://docs.gtk.org/gtk4/struct.MainLoop.html) — GTK thread safety model
- **Last updated:** 2026-05-14

## Overview

Project switching in the tray UI is a high-frequency operation. Users often switch between multiple projects (5–20+) in rapid succession when evaluating workspaces or moving between tasks. The tray must:

1. **Update project state** — Load the new project's config, containers, and logs
2. **Refresh the menu** — Repaint menu items and consistency state
3. **Prevent stale cached data** — Ensure old project data doesn't bleed into new context
4. **Maintain thread safety** — Handle concurrent read/write access to project state

## Performance Targets

| Metric | Target | Rationale |
|--------|--------|-----------|
| **Per-switch time** | < 500ms | User perception: snappy, not laggy |
| **Menu consistency check** | < 20ms | Validation overhead must be negligible |
| **State transition** | < 50ms | Mutex lock + clone + update |
| **Stale data detection** | < 30ms | Generation counter check |
| **Stress (20 switches)** | All < 500ms | No degradation under load |
| **Concurrent threads (4x4)** | All < 500ms | Thread-safe locks don't degrade perf |

## Timing Breakdown

### 1. Project State Transition (< 50ms)

```rust
// Lock acquisition + state clone + generation update
let mut current = current_project.lock().unwrap();  // < 10ms
*current = next_project.clone();                     // < 30ms (includes deep clone)
current.update_generation();                         // < 5ms
```

**Why it matters**: Mutex contention is the main bottleneck. If many threads contend for the lock, latency grows. Monitor lock hold times during testing.

**Optimization**: Use `Arc<RwLock<>>` if readers vastly outnumber writers; use `Arc<Mutex<>>` if access is balanced.

### 2. Menu Consistency Check (< 20ms)

```rust
let state = current_project.lock().unwrap().clone();
let consistency = MenuConsistency::validate(&state);
// Checks: state.id, state.menu_items.len(), state.generation
```

**Why it matters**: Consistency validation must not slow down the switch. A simple check (3–4 assertions) should be < 20ms.

**Optimization**: Cache the last-known generation; only revalidate if generation changed.

### 3. Stale Data Detection (< 30ms)

```rust
// Verify generation counter matches current project
assert_eq!(actual_generation, expected_generation);
// Verify no old project ID lingering
assert_eq!(state.id, expected_project_id);
```

**Why it matters**: Stale data (old project ID, old menu items) causes silent bugs. Detection must be fast.

**Optimization**: Use monotonically increasing generation counters; avoid expensive deep equality checks.

## Test Scenarios

### Scenario 1: Stress Test — 20 Rapid Switches (< 500ms each)

```bash
cargo test test_stress_20_rapid_switches_under_500ms -- --nocapture
```

**What it tests**:
- Rapid sequential switches (10 different projects, 20 switches total)
- Each switch measured individually
- Menu consistency verified after each switch
- No panics, no assertion failures

**Expected output**:
```
Stress test results (20 switches):
  Average: 85.23ms per switch
  Maximum: 127.45ms per switch
  All switches: OK (< 500ms)
```

### Scenario 2: Menu Consistency with Varied Configurations (15 switches)

```bash
cargo test test_menu_consistency_with_varied_projects -- --nocapture
```

**What it tests**:
- Projects with different menu item counts
- Rapid cycling between projects
- No stale menu data from previous project

**Expected output**:
```
Menu consistency test: 15 switches, all valid
```

### Scenario 3: Stale Cache Detection (30 switches)

```bash
cargo test test_no_stale_cache_across_rapid_switches -- --nocapture
```

**What it tests**:
- Generation counter advances on each switch
- Project ID never reverts to old value
- No cached state from 2+ switches ago

**Expected output**:
```
Stale cache test: 30 switches, zero stale data detected
```

### Scenario 4: Concurrent Thread Safety (4 threads × 10 switches)

```bash
cargo test test_concurrent_rapid_switches_thread_safe -- --nocapture
```

**What it tests**:
- 4 threads switching projects concurrently
- Each thread performs 10 rapid switches
- All switches < 500ms under concurrent load
- Final state is consistent

**Expected output**:
```
Concurrent thread test: 4 threads × 10 switches = 40 total, all < 500ms
```

### Scenario 5: Menu Item Integrity (12 switches)

```bash
cargo test test_menu_item_integrity_across_switches -- --nocapture
```

**What it tests**:
- Projects with custom menu item counts (2, 3, 1)
- Menu items never get mixed between projects
- Item counts remain stable per project

**Expected output**:
```
Menu integrity test: 12 switches, all items intact
```

## Full Test Run

```bash
cargo test --test rapid_project_switch_v2 -- --nocapture
```

This runs all 5 unit tests + 1 stress test scenario. Expected total time: < 2 seconds.

## Interpreting Results

### Good Results
- All switch durations < 500ms
- "All switches: OK" message
- No assertion failures
- Concurrent threads show < 500ms per switch even under contention

### Bad Results
- Any switch takes > 500ms → investigate mutex contention
- Stale cache test fails → generation counter logic broken or not being updated
- Menu consistency fails → inconsistent state after switch
- Concurrent test slower than sequential → lock design needs review (consider RwLock)

## Regression Detection

**Baseline** (as of 2026-05-14):
```
Average: ~85ms per switch
Maximum: ~130ms per switch (worst case)
```

**Red flags**:
- Average jumps > 150ms → possible regression in state clone or lock contention
- Maximum jumps > 250ms → possible new allocation or I/O during switch
- Concurrent test shows max > sequential → lock fairness issue

## Debugging Slow Switches

If a switch exceeds 500ms:

1. **Check mutex contention** — Add timing around lock acquisition:
   ```rust
   let lock_start = Instant::now();
   let mut current = current_project.lock().unwrap();
   eprintln!("Lock acquired in {:.2}ms", lock_start.elapsed().as_secs_f64() * 1000.0);
   ```

2. **Check clone cost** — Measure project state clone time:
   ```rust
   let clone_start = Instant::now();
   let cloned = next_project.clone();
   eprintln!("Clone took {:.2}ms", clone_start.elapsed().as_secs_f64() * 1000.0);
   ```

3. **Check for hidden allocations** — Profile with `perf` or `flamegraph`:
   ```bash
   cargo bench --test rapid_project_switch_v2
   ```

4. **Check for I/O** — If any file I/O happens during switch, move it out-of-band:
   ```rust
   // ✅ DO: Load config after switch, not during
   // ❌ DON'T: Read project config during switch
   ```

## Related Specs

- `@trace spec:tray-app` — Tray application lifecycle
- `@trace spec:project-management` — Project state and switching
- `@trace spec:tray-concurrency` — Thread-safe concurrent access
- `@trace gap:TR-007` — This benchmark and test suite

## References

- Test implementation: `crates/tillandsias-headless/tests/rapid_project_switch_v2.rs`
- Original test: `crates/tillandsias-headless/tests/rapid_project_switch.rs`
- Main tray code: `crates/tillandsias-headless/src/tray/mod.rs`
