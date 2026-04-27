# Design: Inference Host-Side Pull

## Architecture Overview

The tray detects GPU VRAM tier at inference startup and spawns a background task that automatically pulls higher-tier models to the host cache. This approach bypasses proxy issues entirely and requires zero user interaction.

## Module Structure

### `inference_lazy_pull.rs` (200 LOC)

- `model_tier_map()` — HashMap of GpuTier → Vec<models>
  - T0/T1: baked in image (qwen2.5:0.5b, llama3.2:3b)
  - T2: qwen2.5-coder:7b
  - T3: qwen2.5-coder:7b + 14b
  - T4: T3 + gpt-oss:20b
  - T5: T4 + qwen2.5-coder:32b

- `is_model_cached(model_name: &str) -> bool`
  - Checks if manifest exists at `~/.ollama/models/manifests/registry.ollama.ai/library/<name>/<tag>`
  - Returns true if already pulled locally

- `spawn_model_pull_task(tier: GpuTier)`
  - Entry point; spawns tokio::spawn async task
  - Fire-and-forget from handlers.rs

- `run_model_pull(tier: GpuTier)` (async)
  - Main sequence: get models for tier, filter cached, pull each

- `pull_model_host_side(model: &str)` (async)
  - Spawns blocking task for `ollama pull`
  - Logs progress + error messages
  - Handles missing ollama gracefully (logs degraded capability)

### Wiring in `handlers.rs`

After inference health check passes (successful curl to `/api/version`):
```rust
let gpu_tier = crate::gpu::detect_gpu_tier();
crate::inference_lazy_pull::spawn_model_pull_task(gpu_tier);
```

Location: After `info!("Inference health check passed")` in `ensure_inference_running()`.

### GPU Tier Detection

Uses existing `gpu::detect_gpu_tier()` → `GpuTier` enum:
- None: CPU only (0 GB)
- Low: ≤4 GB
- Mid: 4-8 GB (add 7b coder)
- High: 8-12 GB (add 14b coder)
- Ultra: ≥12 GB (add 32b coder + others)

## Data Flow

1. Tray calls `ensure_inference_running()`
2. Inference container starts + health check succeeds
3. Call `detect_gpu_tier()` once (cached or fresh nvidia-smi)
4. Spawn `inference_lazy_pull::spawn_model_pull_task(tier)`
5. Task runs async:
   - For each model in tier:
     - If already cached (manifest exists), skip
     - Else: run `ollama pull <model>` on host
   - Log start/completion + any errors
6. Container's next `/api/tags` call picks up newly cached models

## Error Handling

- `ollama` binary missing on host → logs DEGRADED capability, skips
- `ollama pull` fails (network, registry issue) → logs warning with stderr, continues
- Manifest check fails → logs debug, skips (benign)

## No UX Surface

- No tray menu item
- No notifications
- No progress indicator
- Background only
- Power user can inspect via `tillandsias --download-stats` (future)

## Cache Path

- Host: `~/.cache/tillandsias/models/` (manager via tray)
- Container bind-mount: `-v ~/.cache/tillandsias/models/:/home/ollama/.ollama/models:rw`
- Already set up in handlers.rs line 289-295

## Telemetry

Log events tagged with `spec = "inference-host-side-pull"`:
- Task start: model_count, tier
- Per-model: model name, cached/pulled, elapsed_secs
- Errors: category = "capability", safety = "DEGRADED: ..."
- Completion: summary stats (future)

## Tie-In to Existing Code

- `gpu.rs::GpuTier` — already has all tiers defined
- `gpu.rs::detect_gpu_tier()` — called once per inference startup
- `handlers.rs::ensure_inference_running()` — wiring point (line ~354)
- `handlers.rs` model cache mount (line 289-295) — already in place
- Cache dir: `cache_dir().join("models")` — already available
