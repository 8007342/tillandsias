# Design: async-inference-launch

## Where the change lands

`src-tauri/src/handlers.rs:1497–1518` — the `match ensure_inference_running(state, build_tx.clone()).await { ... }` block.

Replace with:

```rust
// @trace spec:inference-container, spec:async-inference-launch
// Inference is the slowest enclave service to come up (15-30s ollama init
// + up to 55s health-check backoff). It is a soft requirement — the forge
// launches without it. Spawn it fire-and-forget so the launch path can
// proceed to git mirror + forge start while inference warms up.
//
// BUILD_MUTEX (handlers.rs:54) still serializes concurrent podman builds,
// so spawning here does not race with the forge or proxy builds.
let inference_state = state.clone();          // assumes TrayState: Clone or Arc-shared
let inference_build_tx = build_tx.clone();
tokio::spawn(async move {
    match ensure_inference_running(&inference_state, inference_build_tx).await {
        Ok(()) => info!(
            accountability = true,
            category = "inference",
            spec = "inference-container, async-inference-launch",
            "Inference container ready (async)"
        ),
        Err(e) => warn!(
            accountability = true,
            category = "capability",
            safety = "DEGRADED: no local LLM inference — AI features unavailable in containers",
            spec = "inference-container, async-inference-launch",
            error = %e,
            "Inference setup failed (async) — containers will launch without local inference"
        ),
    }
});
```

## State sharing

If `TrayState` is not `Clone`, it is almost certainly held inside an `Arc<Mutex<...>>` or `Arc<RwLock<...>>` somewhere up the call stack. In that case, take an `Arc` clone of the wrapper, not the inner state, and pass it into the spawned task.

If `TrayState` requires `&self`-style access only, the inference handler may need a small refactor to accept `Arc<TrayState>` instead of `&TrayState`. That refactor is in scope for this change.

## Forge tolerance

The forge entrypoints that touch inference:

1. `images/default/entrypoint-forge-claude.sh` — confirm whether claude-code is launched with any inference URL or just runs without local LLM by default. Likely no change needed (cloud Claude is the default).
2. `images/default/entrypoint-forge-opencode.sh` — opencode supports local Ollama via env vars. If inference is not yet ready, `OPENCODE_…` connection attempts must time out fast (<1s) and fall back, not hang.

Add a short connect probe at the top of opencode's prelude: `curl -m 1 -sf http://inference:11434/api/version` — on failure, unset the local-LLM env vars so opencode uses cloud or no-LLM mode.

## Empirical timer

Add `let inference_spawn_at = std::time::Instant::now();` outside the spawn, then inside the spawned task on Ok: `info!(spec = "async-inference-launch", elapsed_secs = inference_spawn_at.elapsed().as_secs_f64(), "inference ready")`. Lets us see the savings versus the synchronous baseline in the logs.

## Tray menu reflection

Optional: add a one-line "AI: warming up / ready / unavailable" status to the tray menu, refreshed on the same `BuildProgressEvent` channel the inference task already sends to. Out of scope for the minimal change, but a natural follow-on.

## Out of scope

- The same treatment for git mirror service. Git mirror IS on the critical path (the forge clones from it on first launch). Detaching git mirror requires a more involved redesign — separate change.
- Optimizing the inference health check itself (current 10-attempt exponential backoff is fine for a background task; tighten only if it causes resource contention).
- The tools-overlay caching optimizations — separate change (`tools-overlay-fast-reuse`).
