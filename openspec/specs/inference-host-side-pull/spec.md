<!-- @trace spec:inference-host-side-pull -->

## Status

status: active
promoted-from: openspec/changes/archive/inference-host-side-pull-completed-2026-04-27/
annotation-count: 7

---

# Spec: inference-host-side-pull

## Feature

Automatic lazy model pulling for inference container, spawned after inference startup completes. Host-side `ollama pull` bypasses proxy, lands models in `~/.cache/tillandsias/models/` which the inference container bind-mounts and discovers on next `/api/tags` call.

## Behavior

### Triggering

- After inference container health check passes (curl to `/api/version` succeeds)
- Tray calls `gpu::detect_gpu_tier()` once
- Spawns background task via `inference_lazy_pull::spawn_model_pull_task(tier)`
- Fire-and-forget; no await

### Model Selection by Tier

| Tier | VRAM | Models to Pull |
|------|------|---|
| None | 0GB | None (T0/T1 baked) |
| Low | ≤4GB | None (T0/T1 baked) |
| Mid | 4-8GB | qwen2.5-coder:7b |
| High | 8-12GB | qwen2.5-coder:7b, qwen2.5-coder:14b |
| Ultra | ≥12GB | qwen2.5-coder:7b, qwen2.5-coder:14b, qwen2.5-coder:32b |

### Caching

- Before pulling, check if manifest exists at `~/.ollama/models/manifests/registry.ollama.ai/library/<name>/<tag>`
- If exists → skip (already cached)
- If missing → spawn `ollama pull <model>` on host

### Error Handling

- **ollama binary not found**: log `DEGRADED: host-side ollama not found`, skip all pulls
- **Pull fails**: log warning with stderr, continue to next model
- **Manifest check fails**: benign, log debug, skip

### No UX

- No tray menu item
- No notification
- No progress bar
- No user prompt
- Background-only operation

## Implementation

### Module: `src-tauri/src/inference_lazy_pull.rs`

```rust
pub fn spawn_model_pull_task(tier: GpuTier)
  → async fn run_model_pull(tier: GpuTier)
    → async fn pull_model_host_side(model: &str)
       → tokio::task::spawn_blocking(|| Command::new("ollama").arg("pull")...)

fn is_model_cached(model_name: &str) -> bool
  → checks ~/.ollama/models/manifests/.../library/{name}/{tag}

fn model_tier_map() -> HashMap<GpuTier, Vec<&'static str>>
  → static tier → model mapping
```

### Wiring: `src-tauri/src/handlers.rs`

Line ~354 in `ensure_inference_running()`, after health check passes:

```rust
let gpu_tier = crate::gpu::detect_gpu_tier();
crate::inference_lazy_pull::spawn_model_pull_task(gpu_tier);
```

### GPU Tier: `src-tauri/src/gpu.rs`

- Added `Hash` derive to `GpuTier` enum (required for HashMap key)
- Reused existing `detect_gpu_tier()` function
- Reused existing tier classification logic (0-3GB, 4-7GB, 8-11GB, 12+GB)

## Telemetry

All log events use `spec = "inference-host-side-pull"`:

- **Task start**: `info!(..., tier = %tier, model_count = ..., "Starting lazy model pull task")`
- **Per-model start**: `info!(..., model = ..., "Starting model pull from ollama registry")`
- **Cached skip**: `debug!(..., model = ..., "Model already cached — skipping")`
- **Pull complete**: `info!(..., elapsed_secs = ..., "Model pull completed successfully")`
- **Pull fail**: `warn!(..., error = %stderr, elapsed_secs = ..., "Model pull failed")`
- **Ollama missing**: `warn!(..., category = "capability", safety = "DEGRADED: host-side ollama not found", ...)`
- **Task complete**: `info!(..., tier = %tier, "Model pull task completed")`

## Cache Integration

Inference container mount (handlers.rs line 289-295):
```
-v ~/.cache/tillandsias/models/:/home/ollama/.ollama/models:rw
```

Ollama auto-rescans at next `/api/tags` call → newly pulled models appear.

## Assumptions

- Host has `ollama` binary in PATH (checked via `which ollama`)
- `~/.ollama/models/manifests/` directory structure exists (created by ollama on first run)
- HOME env var is set (used to find cache path)
- `gpu::detect_gpu_tier()` is fast (<100ms) and cached if called multiple times

## Future Extensions

- Track model pull metrics (bytes, time, tier distribution)
- Expose via `tillandsias --download-stats` CLI
- Consider background queuing if multiple tiers pull simultaneously
- Pre-pull models on first install (before user launches inference)

## Sources of Truth

- `cheatsheets/runtime/forge-paths-ephemeral-vs-persistent.md` — cache path management pattern
- `cheatsheets/runtime/ollama-model-management.md` — ollama pull semantics (resumable, manifest checking)
