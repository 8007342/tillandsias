# Runtime Logging Integration Guide

@trace spec:runtime-logging, spec:logging-levels, spec:external-logs-layer

## Overview

The `tillandsias-logging` crate provides structured JSON logging with:
- Async file writing with non-blocking design
- Structured LogEntry with timestamp, level, component, message, context, spec_trace
- File rotation: 7-day TTL, 10MB per file
- Dual log sinks: host (~/.local/state/tillandsias/) and per-project (.tillandsias/logs/)
- TILLANDSIAS_LOG environment variable for runtime filtering
- Accountability event tagging with spec trace links

## Integration Points

### 1. Headless Launcher (`tillandsias-headless`)

Add logging initialization at application startup in `main.rs`:

```rust
use tillandsias_logging;

async fn main() {
    // Initialize logging at startup
    let logger = tillandsias_logging::init_logging(None, None)
        .await
        .expect("failed to initialize logging");
    
    // Use throughout the application
    let entry = tillandsias_logging::LogEntry::new(
        chrono::Utc::now(),
        "INFO".to_string(),
        "headless".to_string(),
        "application started".to_string(),
    )
    .with_spec_trace("spec:linux-native-portable-executable");
    
    logger.log(&entry).await.ok();
}
```

### 2. Container Lifecycle Events

Log all container operations with spec traces:

```rust
// When starting a container
let entry = LogEntry::new(
    Utc::now(),
    "INFO".to_string(),
    "podman".to_string(),
    format!("container started: {}", container_name),
)
.with_context("container", json!(container_name))
.with_context("project", json!(project_name))
.with_context("genus", json!(genus_name))
.with_spec_trace("spec:container-lifecycle");

// When stopping a container
let entry = LogEntry::new(
    Utc::now(),
    "INFO".to_string(),
    "podman".to_string(),
    format!("container stopped: {}", container_name),
)
.with_context("container", json!(container_name))
.with_context("duration_secs", json!(elapsed.as_secs()))
.with_spec_trace("spec:container-lifecycle");

// On container error
let entry = LogEntry::new(
    Utc::now(),
    "ERROR".to_string(),
    "podman".to_string(),
    format!("container operation failed: {}", error),
)
.with_context("container", json!(container_name))
.with_context("operation", json!("start|stop|inspect"))
.with_context("error", json!(error.to_string()))
.with_spec_trace("spec:container-lifecycle");
```

### 3. Accountability Events (Proxy, Enclave, Git)

Enable via flags and emit detailed accountability events:

```rust
// Check if enabled
if logger.is_proxy_logging_enabled() {
    let entry = LogEntry::new(
        Utc::now(),
        "INFO".to_string(),
        "proxy".to_string(),
        format!("cache hit for {}", domain),
    )
    .with_context("domain", json!(domain))
    .with_context("size", json!(request_size))
    .with_context("status", json!("allow"))
    .with_context("cache", json!("hit"))
    .as_accountability("proxy")
    .with_spec_trace("spec:proxy-container");
    
    logger.log(&entry).await.ok();
}

if logger.is_enclave_logging_enabled() {
    let entry = LogEntry::new(
        Utc::now(),
        "INFO".to_string(),
        "enclave".to_string(),
        "network created".to_string(),
    )
    .with_context("network", json!("tillandsias-enclave"))
    .as_accountability("network")
    .with_spec_trace("spec:enclave-network");
    
    logger.log(&entry).await.ok();
}

if logger.is_git_logging_enabled() {
    let entry = LogEntry::new(
        Utc::now(),
        "INFO".to_string(),
        "git-service".to_string(),
        "mirror updated from remote".to_string(),
    )
    .with_context("remote", json!("github.com/user/repo"))
    .as_accountability("git")
    .with_spec_trace("spec:git-mirror-service");
    
    logger.log(&entry).await.ok();
}
```

### 4. Log Rotation and Cleanup

Periodically check and rotate logs:

```rust
// In a background task or on exit
logger.rotate_if_needed().await.ok();
logger.cleanup_expired().await.ok();
```

## Environment Variables

- `TILLANDSIAS_LOG` — Module-level filtering (default: `tillandsias=info`)
  - Example: `TILLANDSIAS_LOG=tillandsias_podman=debug,tillandsias_proxy=trace`
  
- `TILLANDSIAS_LOG_PROXY` — Enable proxy accountability logging
- `TILLANDSIAS_LOG_ENCLAVE` — Enable enclave accountability logging  
- `TILLANDSIAS_LOG_GIT` — Enable git accountability logging

## Log Entry API

### Creation
```rust
let entry = LogEntry::new(timestamp, level, component, message);
```

### Adding context
```rust
entry
    .with_context("key", json!("value"))
    .with_context("number", json!(42))
```

### Spec tracing
```rust
entry.with_spec_trace("spec:enclave-network")
```

### Accountability events
```rust
entry
    .as_accountability("category")
    .with_safety("sensitive operation details")
```

## Log Locations

- **Host logs**: `~/.local/state/tillandsias/tillandsias.log`
- **Project logs**: `.tillandsias/logs/project.log` (optional)
- **Rotation**: 7-day TTL, 10MB file size limit
- **Format**: Compact text with ANSI colors when stderr is a TTY

## Log Format Examples

### Regular event
```
2026-05-14T12:34:56Z INFO proxy: cache hit {domain=api.github.com, size=1024}
```

### Accountability event
```
2026-05-14T12:34:56Z WARN git-service: push failed to remote {error=network timeout}
  [git]
  -> safety note: credentials were not exposed
  @trace spec:git-mirror-service: https://github.com/8007342/tillandsias/search?q=%40trace+spec%3Agit-mirror-service
```

## Testing

Unit tests in `crates/tillandsias-logging/src/`:
- `log_entry.rs` — LogEntry creation and serialization
- `formatter.rs` — Compact formatting with accountability metadata
- `rotation.rs` — File rotation and cleanup
- `logger.rs` — Logger initialization and filtering

Run with:
```bash
cargo test -p tillandsias-logging
```

## References

- `openspec/specs/runtime-logging/spec.md` — Full specification
- `cheatsheets/runtime/runtime-logging.md` — Logging patterns and redaction
- `cheatsheets/runtime/logging-levels.md` — Level reference
- `cheatsheets/runtime/external-logs.md` — External log architecture
