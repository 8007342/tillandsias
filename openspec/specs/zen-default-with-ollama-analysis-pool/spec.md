<!-- @trace spec:zen-default-with-ollama-analysis-pool -->
# zen-default-with-ollama-analysis-pool Specification

## Status

status: active
promoted-from: openspec/changes/archive/2026-04-25-zen-default-with-ollama-analysis-pool/
annotation-count: 3

## Purpose

Split agent responsibilities between cloud-based Zen models (for tool-calling and plan execution) and local ollama models (for analysis-only tasks like summarization, error classification, and commit message generation). Default to Zen; reserve ollama for privacy-critical analysis workloads.

## Requirements

### Requirement: Default model routing

The bundled `config.json` overlay (in `images/default/config-overlay/opencode/`) SHALL set:

1. `model: "opencode/big-pickle"` — the default Zen provider, tool-capable and free
2. `small_model: "opencode/gpt-5-nano"` (or equivalent) — fast non-reasoning Zen model for titles, classifications
3. `provider.ollama` — enumerated in config with all available local models (for explicit `--model ollama/<name>` usage)

The user MAY override to `--model ollama/<name>` for offline analysis, but the out-of-box experience defaults to cloud-routed Zen.

#### Scenario: Default config ships Zen as primary

- **WHEN** the forge launches with no user override
- **THEN** the agent SHALL use `opencode/big-pickle` (Zen) for primary reasoning
- **AND** the agent MAY use `opencode/gpt-5-nano` for fast, non-tool tasks
- **AND** the agent MAY delegate analysis to `ollama/<model>` only if explicitly requested

#### Scenario: User can opt into offline analysis

- **WHEN** a user launches the forge with `--model ollama/qwen2.5-coder:7b`
- **THEN** the agent SHALL use the local qwen model for analysis tasks
- **AND** no cloud API calls are made for the agent loop itself

### Requirement: Tier-tagged tool-capable model pre-pulls

The inference container's entrypoint SHALL pre-pull tool-capable models bucketed by host capability. Models are baked (T0, T1) or pulled at runtime (T2+).

| Tier | Trigger | Model | Size | Tool-call capable? | Baked or pulled? |
|------|---------|-------|------|-------------------|------------------|
| T0 | Always (CPU baseline) | `qwen2.5:0.5b` | 397MB | yes (weak) | Baked |
| T1 | Always (CPU) | `llama3.2:3b` | 2.0GB | yes | Baked |
| T2 | GPU ≥4GB OR RAM ≥16GB | `qwen2.5:7b` | 4.7GB | yes | Pulled at runtime |
| T3 | GPU ≥8GB OR RAM ≥32GB | `qwen2.5-coder:7b` | 4.7GB | yes | Pulled at runtime |
| T4 | GPU ≥16GB | `qwen2.5:14b` | 9GB | yes | Pulled at runtime |
| T5 | GPU ≥32GB | `qwen2.5-coder:32b` | 20GB | yes | Pulled at runtime |

T0 and T1 are baked into the inference image at build time so the first attach has a usable analysis model with zero network overhead. T2+ pull at runtime in the inference container entrypoint.

#### Scenario: CPU-only system gets T0/T1 without network

- **WHEN** the forge initializes on a CPU-only host
- **THEN** the inference container already has `qwen2.5:0.5b` and `llama3.2:3b` baked in
- **AND** the agent MAY immediately use them for analysis without any pull
- **AND** no network overhead on first attach

#### Scenario: High-end GPU auto-pulls larger models

- **WHEN** the host has GPU with 8GB VRAM
- **THEN** the inference container SHALL detect tier T3 capability
- **AND** SHALL spawn a background pull for `qwen2.5-coder:7b` at inference startup
- **AND** the user may see "Downloading model..." telemetry, but it does not block attach

### Requirement: Squid proxy workaround for ollama manifests

Until the Squid SSL-bump EOF failure on ollama manifest pulls is root-caused, the spec documents a fallback:

1. Image builds (build-time) pull directly without proxy (sidestep EOF entirely)
2. Runtime pulls happen in the inference container entrypoint, which remains non-blocking for attach

The spec SHALL NOT block on a Squid fix — it acknowledges the issue and provides the bypass path.

#### Scenario: Build-time pulls bypass proxy

- **WHEN** `scripts/build-image.sh inference` pre-pulls T0/T1 models during the Nix build
- **THEN** the pull commands run directly on the host (not through Squid)
- **AND** the Squid SSL-bump EOF does not affect the build

#### Scenario: Runtime pulls happen in the inference entrypoint

- **WHEN** a T2+ model is selected at inference startup
- **THEN** the inference entrypoint spawns a background `ollama pull`
- **AND** it does NOT block attach
- **AND** the model lands in `~/.cache/tillandsias/models/` and is discovered by the container

## Litmus Tests

Bind to tests in `openspec/litmus-bindings.yaml`:
- `litmus:inference-readiness-probe-shape` — default model routing, tier-tagged pre-pulls, Squid proxy bypass

Gating points:
- Default config ships `opencode/big-pickle` as primary Zen model (not ollama)
- User can opt into offline analysis via `--model ollama/<name>` CLI flag
- T0/T1 models baked into inference image; zero network overhead on first attach
- T2+ models pulled at runtime via host-side ollama (bypasses Squid); detect GPU tier correctly
- Build-time pulls do not route through Squid proxy (sidestep EOF failure)
- Model tiers match capability matrix: T0/T1 on CPU, T2/T3 on 4-8GB GPU, T4/T5 on 16GB+ GPU
- All tool-capable models tagged as such in tier table

## Sources of Truth

- `cheatsheets/runtime/ollama-model-management.md` — model manifest structure, cache checking, pull semantics
- `cheatsheets/runtime/gpu-tier-detection.md` — host VRAM/GPU capability classification algorithm
- `cheatsheets/runtime/opencode-zen-models.md` — Zen model routing, tool-calling protocol, free tier limits
