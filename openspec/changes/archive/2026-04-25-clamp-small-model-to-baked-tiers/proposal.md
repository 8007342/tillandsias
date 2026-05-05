## Why

The prior change (`zen-default-with-ollama-analysis-pool`) tier-tagged
`small_model` by host capability — Ultra hosts got `ollama/qwen2.5:14b`,
Mid/High got `ollama/qwen2.5-coder:7b`, etc. But only T0 (`qwen2.5:0.5b`)
and T1 (`llama3.2:3b`) are baked into the inference image at build time.
T2+ models pull at runtime through the Squid SSL-bump proxy and hit the
known manifest-EOF problem (project memory: `project_squid_ollama_eof`).

Result on a fresh Ultra-tier host: `small_model: ollama/qwen2.5:14b` in
config, but the model isn't in cache. Opencode's sub-tasks silently fail
or stall when they try to use it.

Clamp `small_model` to models we actually bake into the image, regardless
of host GPU tier. Users with faster hardware benefit from running the
same baked model faster; they can opt into bigger models per-prompt with
`--model ollama/<name>` once they've pulled them.

## What Changes

- `GpuTier::model_pair()` in `src-tauri/src/gpu.rs`:
  - `None` → `(opencode/big-pickle, ollama/qwen2.5:0.5b)` — T0 baked.
  - `Low|Mid|High|Ultra` → `(opencode/big-pickle, ollama/llama3.2:3b)` — T1 baked.
- Tests updated.
- Spec delta documents the clamp + why.

## Capabilities

### Modified Capabilities

- `default-image`: adds the baked-tier clamp requirement.

## Impact

- **Rust**: one-function change in `gpu.rs` plus test updates.
- **No image changes.**
- **No user-visible behavior change** for hosts that were already on T0/T1
  defaults; Mid+ users get a working analysis model instead of a broken one.
