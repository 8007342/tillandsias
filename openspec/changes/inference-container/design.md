## Context

Phases 1-3 established the enclave with proxy, git mirror, and offline forge. Phase 4 adds local LLM inference via ollama so AI-assisted development workflows can use local models without network access from forge containers.

@trace spec:inference-container

## Goals / Non-Goals

**Goals:**
- Inference container running ollama on the enclave network
- Forge containers can query local models via `OLLAMA_HOST`
- Shared model cache volume persisted on host
- Model download orchestrated through host app and proxy

**Non-Goals:**
- GPU passthrough into inference container (future — currently host-only GPU)
- Multiple inference containers (one shared instance is sufficient)
- Custom model training or fine-tuning
- Remote inference API (all local)

## Decisions

### D1: Fedora minimal base with ollama binary
**Choice**: Fedora minimal (matching forge base) with ollama installed via official install script.
**Rationale**: Consistent with forge image. Ollama binary is self-contained (~200MB).

### D2: Shared model cache volume
**Choice**: Mount `~/.cache/tillandsias/models/` as the ollama models directory.
**Rationale**: Models persist across container restarts. Same cache directory pattern.

### D3: On-demand lifecycle, shared across projects
**Choice**: Start inference container when first requested (e.g., forge container tries to connect). Shared across all projects.
**Rationale**: Not all projects need inference. Starting on demand saves resources. One ollama instance serves all projects.

### D4: Model downloads via host orchestration
**Choice**: Inference container requests model downloads via a Unix socket message to the host app. Host app pulls the model via the proxy container.
**Rationale**: Inference container has no direct network access. Host mediates all external operations.

Actually, simpler approach for Phase 4: ollama inside the container can pull models through the proxy (HTTP_PROXY is set). The proxy allowlist includes ollama.com. No unix socket needed for downloads.

**Revised**: Ollama in the inference container uses HTTP_PROXY to download models through the proxy. The proxy already allows ollama.com.

## Risks / Trade-offs

- **[Large image]** → ~200MB with ollama. Acceptable — it's a one-time download.
- **[Model download time]** → First model pull can be slow. Cached after that.
- **[No GPU in container]** → Phase 4 uses CPU inference. GPU passthrough is a future enhancement.
- **[Memory usage]** → Ollama loads models into RAM. Small models (qwen2:0.5b, llama3.2:1b) fit in 1-2GB.
