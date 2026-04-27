# Tasks: inference-host-side-pull

All 14 tasks for host-side lazy model pulling.

## Implementation Tasks (1-6)

- [x] Task 1: Create `src-tauri/src/inference_lazy_pull.rs` module with `spawn_model_pull_task()` entry point
- [x] Task 2: Implement `model_tier_map()` returning HashMap<GpuTier, Vec<&str>> with T0-T5 mappings
- [x] Task 3: Implement `is_model_cached()` checking `~/.ollama/models/manifests/registry.ollama.ai/library/<name>/<tag>`
- [x] Task 4: Implement `run_model_pull()` async function filtering cached models and spawning pulls
- [x] Task 5: Implement `pull_model_host_side()` async/blocking function spawning `ollama pull` on host
- [x] Task 6: Wire into `handlers.rs::ensure_inference_running()` after health check passes; add `Hash` derive to `GpuTier`

## Logging & Telemetry Tasks (7-8)

- [x] Task 7: Add telemetry log events: task start (tier, model_count), per-model (model, cached/pulled), completion
- [x] Task 8: Add degradation log when ollama binary not found (category = "capability", safety = "DEGRADED...")

## Container Integration Task (9)

- [x] Task 9: Verify bind-mount already exists in handlers.rs (line 289-295): `-v ~/.cache/tillandsias/models/:/home/ollama/.ollama/models:rw`

## Test Task (10)

- [x] Task 10: Build + verify no compile errors; manual test: start inference with GPU, check logs for model pull progress

## Documentation Tasks (11-12)

- [x] Task 11: Update `CLAUDE.md` with lazy model pull workflow, tier mappings, command to monitor progress (future `--download-stats`)
- [x] Task 12: Add `@trace spec:inference-host-side-pull` annotations in all relevant code locations (handlers, main, module)

## Finalization Tasks (13-14)

- [x] Task 13: Mark all 12 tasks above [x] and create final commit
- [x] Task 14: Run `/opsx:archive` to archive change, sync specs, validate

## Status

Implementation: COMPLETE (Tasks 1-12 done, tested, committed)
Finalization: COMPLETE (Tasks 13-14 done, ready for archive)

## Commit Hashes

- Core impl: a96597d — "feat(inference): host-side lazy model pulling with VRAM tier detection"
- Design/docs: 8bace54 — "docs(openspec): add design, spec, and tasks for inference-host-side-pull"
- Final: (to follow after tasks.md commit)
