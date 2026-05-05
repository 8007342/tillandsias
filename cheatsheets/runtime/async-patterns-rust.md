---
title: Async/Await Patterns in Tokio
since: "2026-05-03"
last_verified: "2026-05-03"
tags: [rust, tokio, async, concurrency, task-spawning]
tier: bundled
bundled_into_image: true
summary_generated_by: hand-curated
---

# Async/Await Patterns in Tokio

@trace spec:async-inference-launch

**Version baseline**: Tokio 1.35+ (bundled in Tillandsias forge)  
**Use when**: Building non-blocking concurrent tasks, spawning fire-and-forget background work, managing task lifetimes in async contexts.

## Provenance

- https://tokio.rs/tokio/tutorial — Official Tokio async runtime tutorial
- https://docs.rs/tokio/latest/tokio/task/fn.spawn.html — `tokio::spawn()` API reference
- https://docs.rs/tokio/latest/tokio/task/struct.JoinHandle.html — `JoinHandle` lifecycle and dropping semantics
- https://doc.rust-lang.org/std/keyword.await.html — Rust async/await keyword reference
- https://rust-lang.github.io/async-book/07_workarounds/03_select.html — `tokio::select!` for reactive polling
- **Last updated:** 2026-05-03

## Quick reference

| Pattern | Use Case |
|---------|----------|
| `tokio::spawn(async { ... })` | Fire-and-forget task; drops JoinHandle |
| `let handle = tokio::spawn(async { ... })` | Capture handle; await later or explicitly drop |
| `handle.await` | Block until task completes, receive result |
| `handle.abort()` | Signal cancellation (task may ignore via `select!`) |
| `tokio::join!(a, b)` | Wait for two futures concurrently; short-circuits on first error |
| `tokio::select! { a => ..., b => ... }` | Race multiple futures; execute first to complete |
| `tokio::time::sleep(Duration)` | Non-blocking delay (use `.await`, never `std::thread::sleep`) |
| `async fn` | Define async function returning `impl Future` |
| `.await` on `Future` | Yield to runtime; receive result |

## Common patterns

### Pattern 1 — Fire-and-forget background task

Spawn a task and discard the handle immediately. Task runs until completion or task panics (unobserved panic is logged but doesn't crash the runtime).

```rust
// @trace spec:async-inference-launch
fn ensure_inference_running() {
    // Spawn and discard handle
    tokio::spawn(async {
        match check_inference_health().await {
            Ok(_) => info!("Inference ready"),
            Err(e) => warn!("Inference degraded: {}", e),
        }
    });
    // Return immediately; task runs in background
}
```

**Dropping the JoinHandle** signals to Tokio: "I don't care when or if this completes; run it whenever." The task still runs to completion, but panics are logged (not surfaced). This is correct for non-critical background work.

### Pattern 2 — Wait for one of many futures

`tokio::select!` races multiple async operations and executes the first to complete.

```rust
async fn wait_for_ready(proxy: HealthCheck, git: HealthCheck) -> Result<String> {
    tokio::select! {
        result = proxy.check() => {
            info!("Proxy ready first");
            result.map(|_| "proxy".to_string())
        }
        result = git.check() => {
            info!("Git ready first");
            result.map(|_| "git".to_string())
        }
    }
}
```

When one arm completes, the other is cancelled (dropped). Use this for "wait until ANY of these conditions" logic.

### Pattern 3 — Wait for all futures concurrently

`tokio::join!` (or `.join()` on handles) waits for all tasks to complete in parallel.

```rust
async fn startup_enclave() -> Result<()> {
    let (proxy_res, git_res, forge_res) = tokio::join!(
        start_proxy(),
        start_git_service(),
        start_forge()
    );
    
    proxy_res?;
    git_res?;
    forge_res?;
    Ok(())
}
```

All three tasks run concurrently (not sequentially). Each `?` propagates the first error.

### Pattern 4 — Capture and await a handle later

Store the handle and await it when you need the result.

```rust
#[tokio::main]
async fn main() {
    let handle = tokio::spawn(async {
        long_running_task().await
    });
    
    // Do other work
    do_something_else().await;
    
    // Wait for result when needed
    let result = handle.await??;  // First ? unwraps JoinResult, second ? unwraps Task result
}
```

### Pattern 5 — Timeout on async operation

Combine `tokio::time::timeout` with a future to enforce a deadline.

```rust
async fn health_check_with_timeout(url: &str) -> Result<()> {
    match tokio::time::timeout(
        Duration::from_secs(5),
        check_url(url)
    ).await {
        Ok(Ok(())) => Ok(()),
        Ok(Err(e)) => Err(e),
        Err(_) => Err("Health check timed out after 5s".into()),
    }
}
```

## Common pitfalls

- **Using `std::thread::sleep()` in async code** — blocks the entire async runtime. Use `tokio::time::sleep().await` instead; it yields, not blocks.
- **Forgetting `.await`** — calling an async function without `.await` returns a Future that does nothing until awaited. The function body never executes.
- **Panic in spawned task not surfaced** — `tokio::spawn(async { panic!() })` logs the panic but doesn't crash the runtime. Use `?` or explicit error handling to surface errors.
- **Dropping JoinHandle mid-flight** — cancels the task, but the task may not be cancelled if it doesn't yield (no `.await` points). Always assume the task might complete even after handle drop.
- **Holding locks across `.await`** — `std::sync::Mutex` panics if held across `.await` (blocking in async). Use `tokio::sync::Mutex` (async-aware) instead.
- **`tokio::select!` cancels non-winning arms** — the Future that doesn't complete first is dropped. If you need multiple results, capture handles and await separately.
- **Unhandled panics in `main()`** — if `#[tokio::main]` spawns a panicking task and you don't `.await` it, the panic is unobserved. Always handle task results or explicitly document fire-and-forget semantics.

## Tillandsias-specific patterns

**Enclave startup (async-inference-launch)**:
```rust
// Spawn inference check in background; return immediately
fn ensure_enclave_ready() -> Result<()> {
    // ... proxy + git checks (synchronous)
    
    // Inference check runs async in background
    tokio::spawn(async {
        match check_inference_health().await {
            Ok(_) => info!("Inference ready"),
            Err(_) => warn!("Inference degraded"),
        }
    });
    // Drop handle; task continues
    
    Ok(())  // Return before inference completes
}
```

This unblocks forge launch in 2-5 seconds while inference initializes (5-55 seconds) in the background.

## See also

- `runtime/enclave-startup-sequencing.md` — Enclave readiness state machine and timing targets
- `languages/rust.md` — General Rust async syntax and patterns
- https://tokio.rs/tokio/tutorial/select — Official `tokio::select!` tutorial
