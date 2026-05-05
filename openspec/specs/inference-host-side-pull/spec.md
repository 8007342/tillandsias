<!-- @trace spec:inference-host-side-pull -->

## Status

status: active
promoted-from: openspec/changes/archive/inference-host-side-pull-completed-2026-04-27/
annotation-count: 7

## Requirements

### Requirement: Automatic model pulling on inference startup
After inference container health check passes, tray MUST detect GPU tier and spawn a background model pull task. The pull task SHALL be fire-and-forget with no await or blocking.

#### Scenario: Health check triggers pull
- **WHEN** inference container `/api/version` health check succeeds
- **THEN** tray calls `gpu::detect_gpu_tier()` once and spawns `inference_lazy_pull::spawn_model_pull_task(tier)`

#### Scenario: Fire-and-forget execution
- **WHEN** spawn_model_pull_task is called
- **THEN** control returns immediately without awaiting task completion

### Requirement: GPU tier-driven model selection
The pull task MUST select models based on detected GPU VRAM tier. Model selection follows a static tier-to-models mapping that MUST be immutable at runtime.

#### Scenario: Mid-tier GPU models
- **WHEN** detected tier is Mid (4-8GB VRAM)
- **THEN** pull task SHALL attempt to pull `qwen2.5-coder:7b`

#### Scenario: High-tier GPU models
- **WHEN** detected tier is High (8-12GB VRAM)
- **THEN** pull task SHALL attempt to pull `qwen2.5-coder:7b` and `qwen2.5-coder:14b`

#### Scenario: Ultra-tier GPU models
- **WHEN** detected tier is Ultra (≥12GB VRAM)
- **THEN** pull task SHALL attempt to pull `qwen2.5-coder:7b`, `qwen2.5-coder:14b`, and `qwen2.5-coder:32b`

#### Scenario: No additional models for low tiers
- **WHEN** detected tier is None or Low (≤4GB VRAM)
- **THEN** pull task SHALL skip pulling (T0/T1 models already baked in image)

### Requirement: Cache-aware manifest checking
Before attempting each model pull, the pull task MUST check if the model manifest already exists locally. If present, the model pull MUST be skipped.

#### Scenario: Model already cached
- **WHEN** manifest exists at `~/.ollama/models/manifests/registry.ollama.ai/library/<name>/<tag>`
- **THEN** pull task SHALL skip pulling and log at debug level

#### Scenario: Model not cached, pull spawned
- **WHEN** manifest does not exist
- **THEN** pull task SHALL spawn `ollama pull <model>` as a blocking task on host

### Requirement: Graceful error handling with degradation
The pull task MUST handle missing ollama binary, failed pulls, and manifest check failures without crashing or blocking inference. Errors MUST be logged with appropriate severity.

#### Scenario: Ollama binary not found
- **WHEN** `which ollama` returns empty or error
- **THEN** pull task SHALL log warning with `safety = "DEGRADED: host-side ollama not found"` and skip all pulls

#### Scenario: Individual model pull fails
- **WHEN** `ollama pull <model>` exits non-zero
- **THEN** pull task SHALL log warning with stderr and continue to next model (not fatal)

#### Scenario: Manifest check fails
- **WHEN** manifest existence check encounters I/O error
- **THEN** pull task SHALL log at debug level and benignly continue

### Requirement: Host-side pull via native ollama binary
Model pulls MUST occur via the host-side `ollama` binary, NOT through the inference container or proxy. This bypass is critical because Squid 6.x manifests EOF on large ollama pull streams.

#### Scenario: Pull bypasses proxy
- **WHEN** pull task spawns `ollama pull <model>`
- **THEN** command runs on host (not inside inference container), using native `ollama` binary with direct registry access

### Requirement: Cache path binding to inference container
The inference container MUST bind-mount `~/.cache/tillandsias/models/` as `{OLLAMA_HOME}/models` (read-write). Ollama MUST auto-rescan and discover newly pulled models on next `/api/tags` call.

#### Scenario: Cache mount and discovery
- **WHEN** pull task completes and inference container runs `GET /api/tags`
- **THEN** newly pulled models appear in the tags list without restart

### Requirement: Silent background operation with no UX
The pull task MUST NOT show tray menu items, notifications, progress bars, or user prompts. Operation is entirely background-only.

#### Scenario: No user-facing UI
- **WHEN** model pull task is running
- **THEN** no tray menu changes, no notifications sent, no progress displayed

### Requirement: Comprehensive telemetry with spec tracing
All log events from the pull task MUST include `spec = "inference-host-side-pull"` field. Telemetry MUST cover task lifecycle, per-model progress, and error conditions.

#### Scenario: Task start logging
- **WHEN** pull task begins
- **THEN** log at info level: `tier = <tier>, model_count = <count>, "Starting lazy model pull task"`

#### Scenario: Model pull start logging
- **WHEN** individual model pull begins
- **THEN** log at info level: `model = <name>, "Starting model pull from ollama registry"`

#### Scenario: Cached model skip logging
- **WHEN** model manifest is found and pull skipped
- **THEN** log at debug level: `model = <name>, "Model already cached — skipping"`

#### Scenario: Pull success logging
- **WHEN** model pull completes successfully
- **THEN** log at info level: `elapsed_secs = <duration>, "Model pull completed successfully"`

#### Scenario: Pull failure logging
- **WHEN** model pull fails
- **THEN** log at warn level: `error = <stderr>, elapsed_secs = <duration>, "Model pull failed"`

#### Scenario: Task completion logging
- **WHEN** all models processed
- **THEN** log at info level: `tier = <tier>, "Model pull task completed"`

## Litmus Tests

Bind to tests in `openspec/litmus-bindings.yaml`:
- pending — test binding required for S2→S3 progression

Gating points:
- Host-side ollama pulls models asynchronously after inference health check passes
- Pull bypasses proxy entirely (uses host-side native ollama binary)
- Models cached at `~/.cache/tillandsias/models/` and bind-mounted RW into container
- Before pulling, checks if model already in local ollama manifest (skips if cached)
- Pull failures log at warn level with error message and elapsed time; not fatal
- GPU tier detection determines which T2-T5 models to pull
- Task logs completion with tier and success/failure count at info level
- Pull is non-blocking; forge operations proceed while models download

## Sources of Truth

- `cheatsheets/runtime/forge-paths-ephemeral-vs-persistent.md` — cache path management pattern
- `cheatsheets/runtime/ollama-model-management.md` — ollama pull semantics (resumable, manifest checking)

## Observability

Annotations referencing this spec can be found by:
```bash
grep -rn "@trace spec:inference-host-side-pull" src-tauri/ scripts/ crates/ images/ --include="*.rs" --include="*.sh"
```
