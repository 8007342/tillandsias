## Why

The enclave architecture isolates forge containers from the network and credentials. For AI-assisted development with local models, we need a dedicated inference container running ollama. This container is offline (enclave-only), shares models via a persistent volume, and requests model downloads through the host app.

## What Changes

- Build `tillandsias-inference` container image with ollama pre-configured
- Inference container runs on enclave network, reachable by forge containers
- `OLLAMA_HOST` env var in forge containers points to the inference service
- Shared model cache at `~/.cache/tillandsias/models/`
- Model download flow: inference requests → host app unix socket → proxy container → ollama.com
- Inference container is shared across projects, on-demand lifecycle

## Capabilities

### New Capabilities
- `inference-container`: Local LLM inference via ollama, model management, download orchestration

### Modified Capabilities
- `environment-runtime`: Forge containers gain `OLLAMA_HOST` env var pointing to inference service
- `podman-orchestration`: Inference container lifecycle management

## Impact

- **New files**: `images/inference/Containerfile`, `images/inference/entrypoint.sh`
- **Modified crates**: `tillandsias-core` (inference profile), `tillandsias-podman` (none)
- **Modified binaries**: `src-tauri/src/handlers.rs` (inference lifecycle)
- **Image**: `tillandsias-inference:v{VER}`, ~200MB (ollama binary + base)
