---
title: Ollama Model Management — Pulling, Caching, and Tier Mapping
since: "2026-05-03"
last_verified: "2026-05-03"
tags: [ollama, model-management, inference, caching, llm]
tier: bundled
bundled_into_image: true
summary_generated_by: hand-curated
---

# Ollama Model Management — Pulling, Caching, and Tier Mapping

@trace spec:inference-host-side-pull, spec:zen-default-with-ollama-analysis-pool

**Version baseline**: Ollama 0.1.32+ (bundled in tillandsias-inference image)  
**Use when**: Pre-pulling LLM models into containers, checking model cache, implementing resumable downloads, handling network failures in model pulls.

## Provenance

- https://github.com/ollama/ollama/blob/main/README.md — Ollama overview and model zoo
- https://ollama.ai/library — Official Ollama model library (searchable registry)
- https://github.com/ollama/ollama/blob/main/docs/modelfile.md — Modelfile format and custom model packaging
- https://github.com/ollama/ollama/blob/main/docs/api.md — Ollama HTTP API (pull, generate, list models)
- https://docs.docker.com/storage/volumes/ — Docker/Podman volume management for model caching
- **Last updated:** 2026-05-03

## Quick reference: Ollama Commands

| Command | Effect | Use Case |
|---------|--------|----------|
| `ollama list` | Show all downloaded models | Check what's cached locally |
| `ollama pull <model>` | Download model from registry | Pre-cache before container start |
| `ollama show <model>` | Display model metadata (size, parameters) | Verify before pulling |
| `ollama run <model> "prompt"` | Load model + run inference | Test inference quality |
| `curl http://localhost:11434/api/pull` | HTTP API for pulling (async) | Scripted/container-based pulls |
| `ollama serve --models-dir <path>` | Custom model cache directory | Override default `~/.ollama/models` |

## Model tier mapping (Tillandsias)

**Builtin tiers (always available):**
- T0: `qwen2.5:0.5b` (352 MB) — embedded in forge
- T1: `llama3.2:3b` (1.9 GB) — embedded in forge

**Lazy-pulled tiers (background task post-startup):**

| GPU Tier | Models to Pull | Total VRAM | Download Time | Notes |
|----------|----------------|-----------|----------------|-------|
| None / Low | (none) | 2.2 GB | N/A | Baked models only |
| Mid | `qwen2.5-coder:7b` | 6.7 GB | 8–15 min | 7B parameter model; 4.5 GB VRAM when loaded |
| High | `qwen2.5-coder:7b`, `qwen2.5-coder:14b` | 15.7 GB | 15–30 min | Both models cached; one loaded at a time |
| Ultra | `qwen2.5-coder:7b`, `qwen2.5-coder:14b`, `qwen2.5-coder:32b` | 35.7 GB | 25–45 min | All cached; flexible loading strategy |

@trace spec:inference-host-side-pull

## Model cache structure

```
~/.ollama/
├── models/
│   ├── manifests/
│   │   ├── registry.ollama.ai/
│   │   │   ├── library/
│   │   │   │   ├── qwen2.5-coder/
│   │   │   │   │   └── 7b              ← Manifest blob (JSON metadata)
│   │   │   │   └── llama3.2/
│   │   │   │       └── 3b
│   │   │   └── [other registries]/
│   ├── blobs/
│   │   ├── sha256-abc123...           ← Model weights (GGUF format)
│   │   ├── sha256-def456...
│   │   └── [indexed by SHA256 hash]
│   └── migrations/
```

### Cache Check: Model Already Downloaded?

```bash
# Check if a specific model's manifest exists locally
if [ -f "$HOME/.ollama/models/manifests/registry.ollama.ai/library/qwen2.5-coder/7b" ]; then
  echo "✓ qwen2.5-coder:7b is cached locally"
else
  echo "✗ Not cached; needs download"
fi

# List all cached models
ollama list
# Output:
# NAME                           ID              SIZE      MODIFIED
# qwen2.5:0.5b                   <sha256>        352MB     2 hours ago
# llama3.2:3b                    <sha256>        1.9GB     10 days ago
```

### Model Manifest Format

```json
{
  "config": "sha256:<blob>",
  "layers": [
    { "digest": "sha256:<blob>", "size": <bytes>, "mediaType": "application/vnd.ollama.image.model" },
    { "digest": "sha256:<blob>", "size": <bytes>, "mediaType": "application/vnd.ollama.image.params" }
  ],
  "mediaType": "application/vnd.ollama.image.manifest",
  "schemaVersion": 2
}
```

Blobs are typically GGUF format (ML model compression).

## Pulling models: Methods and Resumability

### Method 1: `ollama pull` (CLI, simple)

```bash
# Pull and cache locally
ollama pull qwen2.5-coder:7b

# Output:
# pulling manifest
# pulling 2bf72e72d00b... ▪▪▪▪▪▪▪▪ [=====>        ] 50% 2.3GB/4.6GB

# Resume on network failure: just run again
ollama pull qwen2.5-coder:7b  # Resumes if partial; skips if complete
```

**Resumability**: Ollama uses SHA256 checksums for each blob. Partial blobs are validated; if incomplete, the pull resumes from the last chunk. Full re-download is rare.

### Method 2: HTTP API pull (container-friendly)

```bash
# From tray (host-side, no proxy needed)
curl -s -X POST http://localhost:11434/api/pull \
  -H "Content-Type: application/json" \
  -d '{"name": "qwen2.5-coder:7b"}' | jq '.'

# Output (streaming JSON objects, one per event):
# {"status":"pulling manifest","total":2048}
# {"status":"pulling 2bf72e72d00b","digest":"sha256:...","total":4800000000,"completed":2400000000}
# {"status":"success"}

# Monitor progress in real-time
curl -s -X POST http://localhost:11434/api/pull \
  -H "Content-Type: application/json" \
  -d '{"name": "qwen2.5-coder:7b"}' | \
  jq -r 'select(.status=="pulling") | "\(.status): \(.completed / .total * 100 | floor)%"'
```

**Resumability**: Same as CLI — partial blobs resume on retry.

## Network Resilience: Host-Side Pull Strategy

**Problem** (per `project_squid_ollama_eof.md`): Squid 6.x proxy closes connection on large manifest pulls (EOFError during streaming).

**Solution** (inference-host-side-pull): Pull models **host-side** via native ollama CLI, bypassing proxy entirely.

```bash
#!/bin/bash
# @trace spec:inference-host-side-pull

set -euo pipefail

GPU_TIER=$1  # Provided by tray after detecting GPU

function pull_model() {
  local model=$1
  echo "[Model] Pulling $model..."

  # Check if already cached
  if [ -f "$HOME/.ollama/models/manifests/registry.ollama.ai/library/${model%:*}/${model#*:}" ]; then
    echo "[Cache] $model already cached; skipping pull"
    return 0
  fi

  # Pull from host (NOT through proxy)
  if ollama pull "$model"; then
    echo "[✓] $model pulled successfully"
    return 0
  else
    echo "[✗] Failed to pull $model" >&2
    return 1
  fi
}

# Pull based on GPU tier (fire-and-forget, no blocking)
case "$GPU_TIER" in
  mid)
    pull_model "qwen2.5-coder:7b" || true
    ;;
  high)
    pull_model "qwen2.5-coder:7b" || true
    pull_model "qwen2.5-coder:14b" || true
    ;;
  ultra)
    pull_model "qwen2.5-coder:7b" || true
    pull_model "qwen2.5-coder:14b" || true
    pull_model "qwen2.5-coder:32b" || true
    ;;
esac

echo "[Info] Model pulling phase complete"
```

**Why host-side?**
1. Host's native `ollama` binary pulls directly from registry (no proxy involvement)
2. No Squid manifest EOF errors
3. Model cache (`~/.ollama/models`) is mounted RW into inference container
4. 100% success rate vs. variable proxy-mediated results

**When to pull:**
- During enclave startup, after inference container health check passes
- In background task (async spawn); doesn't block forge launch
- Fail gracefully (log warning if pull fails; T0/T1 models still available)

## Model Manifest Checking (Before Pull)

```bash
#!/bin/bash
# Check model metadata before deciding to pull

function check_model_size() {
  local model=$1
  
  # Use ollama show (works even if model not downloaded)
  ollama show "$model" --template '{{.parameters}}' 2>/dev/null | while read line; do
    echo "$line"
  done
}

# Example
check_model_size "qwen2.5-coder:7b"
# Output:
# 7.0B parameters
# 4.5GB memory required
```

**Use case**: Before pulling, verify the model fits in available VRAM.

```rust
// Rust version: check before spawning pull task
async fn should_pull_model(model: &str, gpu_tier: GpuTier) -> bool {
    let required_vram = match model {
        "qwen2.5-coder:7b" => 4.5,
        "qwen2.5-coder:14b" => 9.0,
        "qwen2.5-coder:32b" => 20.0,
        _ => 1.0,
    };

    let available_vram = gpu_tier.available_vram();
    
    // Only pull if we have headroom (2 GB safety margin)
    required_vram + 2.0 < available_vram
}
```

## Olympus: Lazy Model Pulling on First Use

Future enhancement: Instead of pre-pulling, pull on first inference request if not cached.

```bash
# Pseudo-code (not yet implemented)
function infer_lazy(model, prompt) {
  if not cached(model):
    log "model not cached; pulling..."
    pull_model(model)  # blocking, but only on first use
  
  inference = ollama.run(model, prompt)
  return inference
}
```

Benefits:
- Faster startup (no pre-pull delay)
- Reduced startup variance
- Models pulled only if actually used

Trade-off: First inference request on uncached model is slow (5-55 seconds).

## Tillandsias Integration Points

### 1. Inference Container Startup

```dockerfile
# images/inference/Containerfile
FROM ollama/ollama:latest

# T0 and T1 models baked in
RUN ollama pull qwen2.5:0.5b && \
    ollama pull llama3.2:3b

# Expose API port
EXPOSE 11434

HEALTHCHECK --interval=5s --timeout=3s --retries=3 \
  CMD curl -f http://localhost:11434/api/version || exit 1

CMD ["ollama", "serve"]
```

### 2. Host-Side Pull (GPU Tier-Aware)

```rust
// In handlers.rs::ensure_enclave_ready()
// After forge health check passes

let gpu_tier = gpu::detect_gpu_tier();
let models_to_pull = gpu_tier.models_to_pull();

// Spawn async pull task (non-blocking)
tokio::spawn(async move {
    for model in models_to_pull {
        if let Err(e) = pull_model_host_side(model).await {
            warn!("Model pull failed: {}; continuing", e; model=model, spec="inference-host-side-pull");
        }
    }
});

// Return immediately; pulls continue in background
```

### 3. Model Selection (Runtime)

Inference agents select T0/T1 for quick response or T2-T5 if available:

```bash
# Check cached models before inference
if ollama list | grep -q "qwen2.5-coder:14b"; then
    MODEL="qwen2.5-coder:14b"  # Use T5 if available
elif ollama list | grep -q "qwen2.5-coder:7b"; then
    MODEL="qwen2.5-coder:7b"   # Fall back to T2
else
    MODEL="qwen2.5:0.5b"       # Fall back to T0 (always available)
fi

ollama run "$MODEL" "$PROMPT"
```

## Troubleshooting

| Issue | Cause | Fix |
|-------|-------|-----|
| `Error: manifest not found` | Model doesn't exist on registry or typo | Verify model name at https://ollama.ai/library |
| `Error: connection refused` | Ollama server not running | Start ollama: `ollama serve` |
| Pull hangs or timeouts | Large model + slow network | Increase timeout or split into smaller parts |
| `curl: (52) Empty reply from server` | Squid proxy closing connection (EOF) | Use host-side pull instead of proxy-mediated |
| Out of VRAM during load | Model too large for GPU | Check `ollama show <model>` and available VRAM |
| Model cached but stale | Local manifest doesn't match registry | Delete and re-pull: `rm ~/.ollama/models/manifests/...<model>; ollama pull <model>` |

## See also

- `runtime/gpu-tier-detection.md` — Detecting GPU VRAM and classification logic
- `runtime/container-gpu.md` — GPU passthrough for inference containers
- `runtime/local-inference.md` — Ollama inference server setup and tuning
- `openspec/specs/inference-host-side-pull/spec.md` — Host-side pull spec and design rationale
