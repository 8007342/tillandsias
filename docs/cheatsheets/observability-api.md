# Observability API Surface

Comprehensive observability API surface completing all logging/observability interfaces.

**Use when**: Building observability features, querying logs, sampling traces, enforcing budgets, or aggregating multi-container logs.

## Provenance

- [Tillandsias logging specification](../specs/logging.md) — Core logging design
- [Structured query language](../specs/query.md) — Query syntax and execution
- [Cost-aware sampling](../specs/sampling.md) — Probabilistic sampling for high-volume traces
- [Budget enforcement](../specs/budget-enforcement.md) — Per-spec and global cost limits
- [Log aggregation](../specs/log-aggregation.md) — Multi-container log merging
- **Last updated:** 2026-05-14

## Overview

@trace gap:OBS-023

The `ObservabilityAPI` provides a unified, type-safe surface that integrates four observability subsystems:

1. **LogQuery** — Structured log query language (OBS-002)
2. **CostAwareSampler** — Probabilistic sampling for high-volume traces (OBS-006)
3. **BudgetEnforcer** — Trace cost budget enforcement (OBS-011)
4. **LogAggregator** — Multi-container log aggregation (OBS-013)

### Design Principles

- **Type Safety**: Rust types prevent invalid queries and budget states
- **Composability**: Each subsystem works independently or through the unified API
- **Non-Breaking**: Integrates existing implementations without API changes
- **Observable**: Query history and budget tracking for visibility into observability operations

## API Surface

### Core Types

```rust
pub struct ObservabilityAPI {
    sampler: Arc<RwLock<CostAwareSampler>>,
    budget_enforcer: Arc<BudgetEnforcer>,
    aggregator: Arc<LogAggregator>,
    query_history: Arc<RwLock<Vec<QueryHistoryEntry>>>,
}

pub struct SamplingStatus {
    pub should_emit: bool,
    pub sampling_rate: f64,
    pub trace_cost_bytes: usize,
}

pub struct BudgetStatus {
    pub within_budget: bool,
    pub current_cost_bytes: usize,
    pub max_cost_bytes: u64,
    pub budget_percentage: f32,
}

pub struct QueryResult {
    pub data: Value,
    pub matches: usize,
    pub elapsed_ms: u64,
}

pub struct AggregationResult {
    pub entries: Vec<AggregatedLogEntry>,
    pub source_counts: HashMap<String, usize>,
    pub time_range: Option<(String, String)>,
}
```

### Creating the API

```rust
use tillandsias_logging::{
    ObservabilityAPI, CostAwareSampler, BudgetEnforcer, LogAggregator
};
use std::sync::Arc;
use parking_lot::RwLock;

// Create components
let sampler = Arc::new(RwLock::new(CostAwareSampler::new()));
let budget_enforcer = Arc::new(BudgetEnforcer::default_config());
let aggregator = Arc::new(LogAggregator::new());

// Create unified API
let api = ObservabilityAPI::new(sampler, budget_enforcer, aggregator)?;
```

### Querying Logs

Query logs using structured query language inspired by Loki:

```rust
// Simple filter
let result = api.query(r#"{spec="foo"}"#, entries)?;
println!("Matched {} entries", result.matches);

// Count by spec
let result = api.query(r#"{level="error"} | count"#, entries)?;
if let Some(count) = result.data.get("count") {
    println!("Error count: {}", count);
}

// Statistics
let result = api.query(
    r#"{component="proxy"} | stats avg(latency_ms) by spec"#,
    entries
)?;

// JSON filtering
let result = api.query(
    r#"{spec="proxy"} | json | .latency_ms > 100"#,
    entries
)?;

// Query history
let history = api.query_history(10);  // Last 10 queries
for (query_str, matches, elapsed_ms) in history {
    println!("{}: {} matches in {}ms", query_str, matches, elapsed_ms);
}
```

Query syntax:

```
# Label matching (required)
{spec="value", level="error"}

# Aggregations (optional)
| count
| stats count() by spec
| stats avg(latency_ms) by spec
| stats sum(requests) by component
| stats max(latency_ms) by spec
| stats min(latency_ms) by spec

# JSON filtering (optional)
| json | .field > 100
| json | .field < 50
| json | .field == 42
| json | .message contains "error"
```

### Sampling Traces

Check if a trace should be sampled based on cost thresholds:

```rust
use tillandsias_logging::LogEntry;
use chrono::Utc;

let entry = LogEntry::new(
    Utc::now(),
    "info".to_string(),
    "proxy".to_string(),
    "request processed".to_string(),
);

let status = api.should_sample(&entry)?;

if status.should_emit {
    // Emit trace
} else {
    // Drop trace (cost threshold exceeded)
}

println!("Sampling rate: {}", status.sampling_rate);
println!("Trace cost: {} bytes", status.trace_cost_bytes);
```

Sampling is probabilistic when cost threshold exceeded:
- Below threshold: 100% sample rate
- Above threshold: 50% sample rate (half traces dropped)
- Based on hourly rolling window

### Enforcing Budgets

Check if a trace is within per-spec budget:

```rust
let status = api.check_budget("spec:browser-isolation", 1500)?;

if status.within_budget {
    // Emit trace
} else {
    // Warn or skip trace
}

println!(
    "Budget: {}/{} bytes ({}%)",
    status.current_cost_bytes,
    status.max_cost_bytes,
    status.budget_percentage
);
```

Per-spec budgets:
- Default: 5MB per spec per hour
- Global default: 10MB across all specs per hour
- Configurable per spec

### Unified Emit Decision

Combine sampling and budget checks into a single decision:

```rust
let should_emit = api.should_emit(&entry, "spec:runtime-logging")?;

if should_emit {
    // Emit trace
}
```

Emits trace if:
- Sampling pass OR
- Budget permits

### Aggregating Logs

Aggregate logs from multiple containers:

```rust
use tillandsias_logging::AggregatedLogEntry;

let entries = vec![
    AggregatedLogEntry::new("proxy", "proxy-id-1", proxy_entry),
    AggregatedLogEntry::new("git", "git-id-1", git_entry),
    AggregatedLogEntry::new("forge", "forge-id-1", forge_entry),
];

let result = api.aggregate(entries).await?;

// Access aggregated entries (sorted by timestamp)
for entry in &result.entries {
    println!("{}: {}", entry.container, entry.entry.message);
}

// View source counts
for (container, count) in &result.source_counts {
    println!("{}: {} logs", container, count);
}

// View time range
if let Some((start, end)) = &result.time_range {
    println!("Time range: {} to {}", start, end);
}
```

### Filtering Aggregated Logs

Filter aggregated logs by container or spec:

```rust
let filtered = api.filter_by_container("proxy", entries);
println!("Proxy logs: {}", filtered.len());

let filtered = api.filter_by_spec("network", entries);
println!("Network spec logs: {}", filtered.len());
```

### Budget Monitoring

Get global and per-spec budget status:

```rust
// Global budget
let (cost, violations, warning_issued) = api.global_budget_status();
println!(
    "Global: {} bytes, {} violations, warning: {}",
    cost, violations, warning_issued
);

// Per-spec costs
let costs = api.per_spec_costs();
for (spec, cost) in costs {
    println!("{}: {} bytes", spec, cost);
}
```

## Integration Examples

### Log Processing Pipeline

```rust
async fn process_logs(
    api: &ObservabilityAPI,
    entries: Vec<AggregatedLogEntry>,
) -> Result<()> {
    // Aggregate multi-container logs
    let result = api.aggregate(entries).await?;

    // Query aggregated logs
    let json_entries: Vec<Value> = result.entries
        .iter()
        .map(|e| serde_json::to_value(e).unwrap())
        .collect();

    let query_result = api.query(
        r#"{level="error"} | stats count() by component"#,
        json_entries,
    )?;

    println!("Error counts by component: {:?}", query_result.data);

    Ok(())
}
```

### Trace Emission Decision

```rust
async fn emit_trace(
    api: &ObservabilityAPI,
    entry: LogEntry,
    spec: &str,
) -> Result<()> {
    // Check all observability constraints
    if api.should_emit(&entry, spec)? {
        // Actually emit the trace
        // (implementation: write to log file, send to backend, etc.)
        println!("Trace emitted for {}", spec);
    } else {
        // Sampled or budget exceeded
        println!("Trace dropped for {}", spec);
    }

    Ok(())
}
```

### Observability Dashboard

```rust
fn print_observability_status(api: &ObservabilityAPI) {
    let (global_cost, violations, warning) = api.global_budget_status();
    let costs = api.per_spec_costs();
    let history = api.query_history(5);

    println!("\n=== Observability Status ===");
    println!("Global Budget: {} bytes, {} violations", global_cost, violations);
    println!("Warning Issued: {}\n", warning);

    println!("Per-Spec Costs:");
    for (spec, cost) in costs {
        println!("  {}: {} bytes", spec, cost);
    }

    println!("\nRecent Queries:");
    for (query, matches, elapsed) in history {
        println!("  {}: {} matches in {}ms", query, matches, elapsed);
    }
}
```

## Cost Estimation

Trace cost is estimated as:

```
cost = message_size + context_size + spec_trace_size + 256 (overhead)
```

Example costs:

- Simple log entry: ~300 bytes
- With JSON context: ~500-1000 bytes
- Large context: 2000+ bytes

## Performance Characteristics

| Operation | Time Complexity | Space Complexity |
|-----------|------------------|------------------|
| Query execution | O(n) where n = entry count | O(result size) |
| Budget check | O(1) | O(specs) for state |
| Sample decision | O(1) | O(1) |
| Aggregation | O(n log n) for sort | O(n) |
| Filter | O(n) | O(matches) |

## Error Handling

All operations return `Result<T>` for error handling:

```rust
match api.query(query_str, entries) {
    Ok(result) => println!("Matched: {}", result.matches),
    Err(e) => eprintln!("Query failed: {}", e),
}
```

Common errors:
- `ParseError::InvalidSyntax` — Query string malformed
- `ParseError::MissingFilter` — Query must start with `{}`
- `LoggingError::WriteError` — Sampling or budget check failed

## Testing

Unit tests verify:
- Query parsing and execution (12+ tests)
- Sampling behavior (8+ tests)
- Budget enforcement (8+ tests)
- Log aggregation (15+ tests)
- API integration (11+ tests)
- Filter correctness (6+ tests)

Run tests:

```bash
cargo test --package tillandsias-logging --lib surface
cargo test --package tillandsias-logging
```

## Related Specs

- `spec:structured-query-language` — Log query syntax and execution
- `spec:cost-aware-sampling` — Probabilistic sampling mechanism
- `spec:trace-budget-enforcement` — Budget tracking and warnings
- `spec:log-aggregation` — Multi-container log merging
- `spec:runtime-logging` — Core logging infrastructure

## See Also

- `crates/tillandsias-logging/src/surface.rs` — Implementation
- `crates/tillandsias-logging/src/query.rs` — Query language
- `crates/tillandsias-logging/src/sampler.rs` — Sampling mechanism
- `crates/tillandsias-logging/src/budget_enforcer.rs` — Budget enforcement
- `crates/tillandsias-logging/src/aggregator.rs` — Log aggregation
