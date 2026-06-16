---
id: rust-async
title: Rust Async Programming & Tokio
category: lang/rust
tags: [rust, async, tokio, select, spawn, channels, pinning, futures]
upstream: https://doc.rust-lang.org/std/future/trait.Future.html
version_pinned: "1.85"
last_verified: "2026-03-29"
authority: official
---

# Rust Async Programming & Tokio

## Quick Reference

```rust
tokio::spawn(async { work().await });           // Spawn concurrent task
tokio::spawn_blocking(|| cpu_heavy());          // Offload blocking work
tokio::join!(a(), b());                         // Run concurrently, await all
tokio::select! { v = a() => {}, v = b() => {} } // Race, take first
tokio::time::timeout(dur, fut).await            // Timeout a future
```

## Async Fundamentals

Rust futures are **lazy** -- they do nothing until polled. `async fn` desugars to a
function returning `impl Future<Output = T>`. The executor (tokio) drives futures by
calling `poll()`, which returns `Poll::Ready(T)` or `Poll::Pending` (registering a waker).

```rust
// Desugaring (conceptual):
async fn fetch() -> String { ... }
// becomes roughly:
fn fetch() -> impl Future<Output = String> { ... }
```

**Rust 1.85+**: `async || {}` closures are stable. They return futures when called and
capture from the environment. New traits: `AsyncFn`, `AsyncFnMut`, `AsyncFnOnce` (in
prelude). `Future` and `IntoFuture` are also in the 2024 edition prelude.

```rust
let urls = vec!["https://a.com", "https://b.com"];
let fetch = async |url: &str| -> String { reqwest::get(url).await?.text().await? };
```

## Tokio Runtime

```rust
#[tokio::main]                              // Multi-thread (default)
#[tokio::main(flavor = "current_thread")]   // Single-thread event loop
async fn main() { ... }

// Manual construction
let rt = tokio::runtime::Builder::new_multi_thread()
    .worker_threads(4)
    .enable_all()
    .build()?;
rt.block_on(async { ... });                 // Bridge sync -> async
```

Use `current_thread` for lightweight tools, CLI apps, or when `!Send` futures are needed.

## Task Spawning

```rust
// Spawned tasks run independently -- the future must be Send + 'static
let handle: JoinHandle<u32> = tokio::spawn(async { 42 });
let result = handle.await?;  // JoinError if task panics

// Blocking work -- runs on a separate thread pool, never starves async workers
let val = tokio::spawn_blocking(|| expensive_sync_computation()).await?;

// Cancel a task by dropping its JoinHandle or calling .abort()
handle.abort();
assert!(handle.await.unwrap_err().is_cancelled());
```

## select! Macro

Races branches; **first to complete wins, others are dropped** (cancelled).

```rust
tokio::select! {
    msg = rx.recv() => handle(msg),
    _ = tokio::signal::ctrl_c() => break,
    _ = tokio::time::sleep(Duration::from_secs(30)) => timeout(),
}
```

**Cancellation safety** -- if a branch is dropped mid-`.await`, will data be lost?

| Safe                        | NOT safe                    |
|-----------------------------|-----------------------------|
| `mpsc::Receiver::recv`      | `AsyncReadExt::read`        |
| `oneshot::Receiver`         | `AsyncWriteExt::write_all`  |
| `broadcast::Receiver::recv` | `tokio::io::Lines::next`    |
| `tokio::time::sleep`        | Buffered I/O operations     |

**Reuse pinned futures** when cancel safety matters:

```rust
let sleep = tokio::time::sleep(dur);
tokio::pin!(sleep);
loop {
    tokio::select! {
        _ = &mut sleep => { break; }
        msg = rx.recv() => { handle(msg); }
    }
}
```

Use `biased;` as the first token to poll branches in order (useful for priority draining).

## Channels

| Channel     | Producers | Consumers | Values | Use case                              |
|-------------|-----------|-----------|--------|---------------------------------------|
| `mpsc`      | Many      | One       | Many   | Work queues, event pipelines          |
| `oneshot`   | One       | One       | One    | Request-response, single result       |
| `broadcast` | Many      | Many      | Many   | Fan-out, all receivers see all values |
| `watch`     | Many      | Many      | Latest | Config reload, state broadcasting     |

```rust
// "Send the sender" pattern -- request-response via mpsc + oneshot
let (cmd_tx, mut cmd_rx) = mpsc::channel(32);
tokio::spawn(async move {
    while let Some((req, reply_tx)) = cmd_rx.recv().await {
        let result = process(req).await;
        let _ = reply_tx.send(result);
    }
});
let (reply_tx, reply_rx) = oneshot::channel();
cmd_tx.send((request, reply_tx)).await?;
let response = reply_rx.await?;
```

## Pinning

Async blocks produce self-referential types. Moving them in memory would invalidate
internal pointers, so they must be pinned before polling.

```rust
// Heap-pinning
let fut: Pin<Box<dyn Future<Output = ()>>> = Box::pin(async { ... });

// Stack-pinning (tokio macro)
let fut = async { ... };
tokio::pin!(fut);
// Now `fut` is Pin<&mut impl Future> and can be polled / used in select!

// std::pin::pin! (stabilized 1.68) -- same idea, no tokio dep
let fut = std::pin::pin!(async { ... });
```

You rarely need explicit pinning unless storing futures in structs or using `select!`
with reusable futures.

## Common Patterns

**Graceful shutdown** (CancellationToken from `tokio_util`):

```rust
use tokio_util::sync::CancellationToken;
let token = CancellationToken::new();
let child = token.child_token();
tokio::spawn(async move {
    tokio::select! {
        _ = child.cancelled() => { cleanup().await; }
        _ = do_work() => {}
    }
});
// Later:
token.cancel();  // All children notified
```

**Retry with exponential backoff**:

```rust
let mut delay = Duration::from_millis(100);
for attempt in 0..5 {
    match try_connect().await {
        Ok(conn) => return Ok(conn),
        Err(_) if attempt < 4 => {
            tokio::time::sleep(delay).await;
            delay = delay.mul_f64(2.0).min(Duration::from_secs(30));
        }
        Err(e) => return Err(e),
    }
}
```

**Async drop workaround** (async Drop does not exist):

```rust
impl MyStruct {
    async fn shutdown(self) { /* flush, close connections */ }
}
// Call explicitly before drop -- or use a shutdown channel
```

## Gotchas

**Holding MutexGuard across .await** -- the future becomes `!Send`, won't compile with
`tokio::spawn`. Fix: scope the lock so the guard drops before `.await`.

```rust
// BAD                              // GOOD
let val = mutex.lock().await;       {
do_something(&val).await;               let val = mutex.lock().await;
                                        data = val.clone();
                                    } // guard dropped
                                    do_something(&data).await;
```

Prefer `std::sync::Mutex` for short critical sections (no `.await` inside). Use
`tokio::sync::Mutex` only when you must hold the lock across `.await` points.

**Blocking in async** -- `std::thread::sleep`, CPU-heavy loops, or synchronous I/O will
block the entire tokio worker thread. Use `spawn_blocking` or `block_in_place`.

**Send + 'static bounds** -- `tokio::spawn` requires the future to be `Send + 'static`.
Borrowing local data across `.await` won't compile. Clone or `Arc` instead.

**Forgetting to .await** -- `async fn` calls return futures that do nothing unless
awaited. The compiler warns but it's easy to miss in chains.

## Upstream Sources

- [The Rust Async Book](https://rust-lang.github.io/async-book/)
- [Tokio Tutorial](https://tokio.rs/tokio/tutorial)
- [Tokio API Docs](https://docs.rs/tokio/latest/tokio/)
- [Rust 1.85 Release Notes](https://blog.rust-lang.org/2025/02/20/Rust-1.85.0/)
- [Tokio select! docs](https://docs.rs/tokio/latest/tokio/macro.select.html)
- [Tokio Graceful Shutdown Guide](https://tokio.rs/tokio/topics/shutdown)
