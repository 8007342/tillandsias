# Tray Performance Profiling

**Use when**: Analyzing tray responsiveness, identifying menu latency regressions, or debugging slow UI operations.

## Provenance

- [Rust timing API](https://doc.rust-lang.org/std/time/) — `std::time::Instant` and `Duration` for precise measurements
- **Last updated:** 2026-05-14

## Overview

The tray profiler tracks latencies for five critical operations:

| Operation | Description | Latency Goal |
|-----------|-------------|--------------|
| **MenuOpen** | Initial menu render from closed state | < 50ms |
| **MenuSwitch** | Switching between menu sections (projects, agents) | < 30ms |
| **MenuSelect** | Executing a menu item selection | < 20ms |
| **MenuRebuild** | Rebuilding menu after state change (project list, status) | < 100ms |
| **IconUpdate** | Updating tray icon and tooltip | < 20ms |

A **hotspot** is detected automatically when:
- Average latency exceeds 50ms, OR
- 99th percentile latency exceeds 100ms

## API Usage

### Basic Profiling

```rust
use tillandsias_headless::tray::profiler::{TrayProfiler, OperationKind};

// Create profiler (thread-safe, cloneable)
let profiler = TrayProfiler::new();

// Time an operation
{
    let _timer = profiler.start(OperationKind::MenuOpen);
    // ... menu rendering code ...
} // Timer automatically records latency on drop

// Export metrics
let metrics = profiler.export_metrics();
println!("MenuOpen: {:.2}ms avg, {:.2}ms p99", 
    metrics.operation_latencies["MenuOpen"].avg_ms,
    metrics.operation_latencies["MenuOpen"].p99_ms);

// Check for hotspots
if !metrics.hotspots.is_empty() {
    eprintln!("Detected hotspots: {:?}", metrics.hotspots);
}
```

### Statistics Provided

Each operation tracks six statistics:

```rust
pub struct LatencyStats {
    pub count: u64,      // Total samples collected
    pub min_ms: f64,     // Minimum latency
    pub max_ms: f64,     // Maximum latency
    pub avg_ms: f64,     // Mean latency
    pub p95_ms: f64,     // 95th percentile latency
    pub p99_ms: f64,     // 99th percentile latency
}

// Check if operation is a hotspot
if stats.is_hotspot() {
    println!("Hotspot detected!");
}
```

### Export Metrics

```rust
pub struct PerfMetrics {
    pub operation_latencies: HashMap<String, LatencyStats>,
    pub total_ops: u64,
    pub hotspots: Vec<String>,
}

// Export JSON for dashboards
let metrics = profiler.export_metrics();
let json = serde_json::to_string(&metrics)?;

// Analyze hotspots
for hotspot in &metrics.hotspots {
    println!("Hotspot: {}", hotspot);
}
```

## Integration Points

### Tray Service Initialization

Add profiler to `TrayService`:

```rust
pub struct TrayService {
    profiler: TrayProfiler,
    // ... other fields ...
}

impl TrayService {
    pub fn new(root: PathBuf, version: String, projects: Vec<ProjectEntry>) -> Self {
        Self {
            profiler: TrayProfiler::new(),
            // ... initialize other fields ...
        }
    }
}
```

### Wrapping Menu Operations

```rust
// In build_menu()
async fn build_menu(&self) -> MenuNode {
    let _timer = self.profiler.start(OperationKind::MenuRebuild);
    // ... menu building logic ...
}

// In context_menu() handler
async fn context_menu(&self) -> zbus::Result<OwnedObjectPath> {
    let _timer = self.profiler.start(OperationKind::MenuOpen);
    // ... context menu logic ...
}

// In emit_refresh()
async fn emit_refresh(&self, include_menu: bool) -> zbus::Result<()> {
    let _timer = self.profiler.start(OperationKind::IconUpdate);
    // ... icon/status update ...
}
```

### Metrics Export

Export metrics on shutdown or via a debug endpoint:

```rust
fn shutdown(&self) {
    let metrics = self.profiler.export_metrics();
    info!("Tray metrics: {:?}", metrics);
    
    // Could also export to JSON for analysis
    if let Ok(json) = serde_json::to_string(&metrics) {
        fs::write("/tmp/tray-metrics.json", json).ok();
    }
}
```

## Interpreting Results

### Normal Operations (No Hotspots)

```json
{
  "operation_latencies": {
    "MenuOpen": {
      "count": 245,
      "min_ms": 8.2,
      "max_ms": 42.5,
      "avg_ms": 22.3,
      "p95_ms": 35.8,
      "p99_ms": 41.2
    },
    "MenuSelect": {
      "count": 892,
      "min_ms": 2.1,
      "max_ms": 15.7,
      "avg_ms": 8.9,
      "p95_ms": 12.4,
      "p99_ms": 14.8
    }
  },
  "total_ops": 1137,
  "hotspots": []
}
```

### Hotspot Detected

```json
{
  "operation_latencies": {
    "MenuRebuild": {
      "count": 45,
      "min_ms": 35.2,
      "max_ms": 167.8,
      "avg_ms": 78.4,
      "p95_ms": 142.3,
      "p99_ms": 165.5
    }
  },
  "total_ops": 45,
  "hotspots": ["MenuRebuild"]
}
```

**Action**: MenuRebuild exceeds the 50ms threshold. Investigate:
- Are we rendering too many menu items?
- Is project discovery slow?
- Can we cache parts of the menu structure?

## Performance Tuning Workflow

### Step 1: Establish Baseline

```bash
./target/release/tillandsias --tray /path/to/project &
# Use tray for 5 minutes normally
# Export metrics
```

### Step 2: Identify Hotspots

```rust
let metrics = profiler.export_metrics();
if !metrics.hotspots.is_empty() {
    eprintln!("WARNING: Hotspots detected: {:?}", metrics.hotspots);
}
```

### Step 3: Profile the Hotspot

Add targeted timing around suspect code paths:

```rust
// Before optimization
fn build_menu(state: &TrayUiState) -> MenuNode {
    let _timer = profiler.start(OperationKind::MenuRebuild);
    
    let mut items = Vec::new();
    for project in &state.projects {
        // This might be slow
        items.push(build_project_submenu(project));
    }
    // ...
}

// After optimization (e.g., caching)
fn build_menu(state: &TrayUiState) -> MenuNode {
    let _timer = profiler.start(OperationKind::MenuRebuild);
    
    // Use cached items if projects haven't changed
    if state.projects == self.cached_projects {
        return self.cached_menu.clone();
    }
    
    let mut items = Vec::new();
    for project in &state.projects {
        items.push(build_project_submenu(project));
    }
    // ...
}
```

### Step 4: Verify Improvement

Export metrics again and verify the hotspot is resolved:

```bash
# Should show p99_ms < 100ms and avg_ms < 50ms
let metrics = profiler.export_metrics();
assert!(!metrics.operation_latencies["MenuRebuild"].is_hotspot());
```

## Debugging Tips

### Check Measurement Count

```rust
let metrics = profiler.export_metrics();
let stats = &metrics.operation_latencies["MenuOpen"];
println!("Samples: {}", stats.count);

// If count is too low (<10), more data is needed
if stats.count < 10 {
    eprintln!("Warning: Only {} samples, results may be noisy", stats.count);
}
```

### Monitor Percentiles

High p99 latency with low average suggests occasional spikes:

```
avg_ms: 25.0
p95_ms: 45.0
p99_ms: 120.0  // <-- Huge spike in 1% of cases
```

**Cause**: Periodic garbage collection, disk I/O, or lock contention.

**Fix**: 
- Pre-allocate vectors to avoid reallocation
- Cache expensive computations
- Profile with `perf` to see what's blocking

### Reset and Re-profile

To clear old measurements and start fresh:

```rust
profiler.reset();
// ... use tray normally for 5 minutes ...
let metrics = profiler.export_metrics();
```

## Testing

The profiler includes unit tests for measurement accuracy:

```bash
cargo test --lib tray::profiler
```

Tests verify:
- ✅ Operations are recorded
- ✅ Statistics are calculated correctly
- ✅ Hotspots are detected
- ✅ Multiple operation kinds are tracked independently
- ✅ Reset clears measurements

## Limitations

- **Memory**: Keeps a rolling window of 1000 samples per operation type (configurable). Older measurements are dropped.
- **Precision**: Uses `Instant::now()` which is platform-dependent (nanosecond precision on Linux).
- **Overhead**: Timer creation + drop is ~0.5µs per operation (negligible).
- **Statistics**: Percentiles are approximate for small sample sizes (<100 samples).

## Roadmap

Future enhancements:

- [ ] Export to OpenTelemetry format for integration with centralized monitoring
- [ ] Automatic regression detection (alert if avg increases >10% from baseline)
- [ ] Per-operation custom thresholds (e.g., MenuSelect target = 15ms)
- [ ] Correlation analysis (e.g., MenuRebuild slowness vs. project count)
- [ ] Flamegraph-compatible output for detailed profiling

## See Also

- `crates/tillandsias-metrics/` — System metrics (CPU, memory, disk)
- `@trace spec:tray-app` — Tray architecture
- `@trace spec:tray-progress-and-icon-states` — Icon state machine (used by profiler)
