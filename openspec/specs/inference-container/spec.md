<!-- @trace spec:inference-container -->
# inference-container Specification

## Status

status: active

## Purpose

Shared ollama inference container on the enclave network. Forge containers query it via OLLAMA_HOST. Models persist in a host-mounted cache volume. Downloads route through the proxy.
## Requirements
### Requirement: Local LLM inference via ollama
The system SHALL run an inference container with ollama on the enclave network. Forge containers SHALL access it via `OLLAMA_HOST=http://inference:11434`. The inference container SHALL use the proxy for model downloads.

@trace spec:inference-container

#### Scenario: Forge queries local model
- **WHEN** a forge container runs an ollama query via `OLLAMA_HOST`
- **THEN** the request SHALL reach the inference container over the enclave network
- **AND** the response SHALL be returned to the forge container

#### Scenario: Model download through proxy
- **WHEN** ollama needs to download a model
- **THEN** it SHALL use `HTTP_PROXY`/`HTTPS_PROXY` to route through the proxy container
- **AND** the proxy SHALL allow traffic to ollama.com

### Requirement: Shared model cache
Models SHALL be stored in a persistent volume at `~/.cache/tillandsias/models/` on the host, mounted into the inference container at `/home/ollama/.ollama/models/`.

@trace spec:inference-container

#### Scenario: Model persists across restarts
- **WHEN** the inference container is stopped and restarted
- **THEN** previously downloaded models SHALL be available immediately

### Requirement: Inference container lifecycle
The inference container SHALL be started on-demand and shared across all projects. It SHALL be stopped on app exit.

@trace spec:inference-container

#### Scenario: Inference auto-start
- **WHEN** a forge container is launched and the inference container is not running
- **THEN** the system SHALL start the inference container on the enclave network

#### Scenario: Inference cleanup on exit
- **WHEN** the Tillandsias application exits
- **THEN** the inference container SHALL be stopped

### Requirement: Inference NO_PROXY covers loopback + enclave peers

The inference container SHALL have `NO_PROXY` (and the lowercase `no_proxy`)
env variable set to a value that includes `localhost,127.0.0.1,0.0.0.0,::1`
plus every enclave-internal peer (`inference,proxy,git-service`). Without this,
ollama's own loopback health probes and peer probes hairpin through the Squid
proxy and fail with `TCP_DENIED/403`, causing model load stalls.

#### Scenario: Ollama boot health probe succeeds
- **WHEN** ollama inside the inference container probes its own listen
  address at startup (`HEAD http://0.0.0.0:11434/` or
  `GET http://127.0.0.1:11434/api/version`)
- **THEN** the Go HTTP client sees the destination match `NO_PROXY`
- **AND** the probe connects directly to ollama's socket (does not traverse the
  proxy)
- **AND** the proxy log records no `HEAD http://0.0.0.0:11434/` or
  `GET http://127.0.0.1:11434/*` denial

#### Scenario: Inference profile has NO_PROXY set
- **WHEN** the host constructs the `podman run` args for the inference
  container
- **THEN** the profile includes `NO_PROXY=localhost,127.0.0.1,0.0.0.0,::1,inference,proxy,git-service`
  (or a superset) as an `-e` arg
- **AND** the lowercase `no_proxy` is set to the same value
- **AND** both are passed to ollama alongside the existing `HTTP_PROXY` /
  `HTTPS_PROXY` entries

### Requirement: Tier-tagged tool-capable model pre-pulls

The inference container SHALL pre-pull a tier-tagged set of tool-capable
ollama models bucketed by available CPU/GPU capacity. Tinyllama and
other non-tool-call-supporting models MUST NOT appear in any tier.

| Tier | Trigger                | Model              | Approx size |
|------|------------------------|--------------------|-------------|
| T0   | Always                 | `qwen2.5:0.5b`     | 397MB       |
| T1   | Always                 | `llama3.2:3b`      | 2.0GB       |
| T2   | GPU ≥4GB OR RAM ≥16GB  | `qwen2.5:7b`       | 4.7GB       |
| T3   | GPU ≥8GB OR RAM ≥32GB  | `qwen2.5-coder:7b` | 4.7GB       |
| T4   | GPU ≥16GB              | `qwen2.5:14b`      | 9GB         |
| T5   | GPU ≥32GB              | `qwen2.5-coder:32b`| 20GB        |

T0 and T1 SHALL be baked into the inference image at build time so the
first container start has them locally with zero network. T2+ MAY be
pulled at runtime; failures SHALL log "[inference] T<N> pull failed"
and continue (not fatal).

#### Scenario: T0 + T1 ready immediately on first attach
- **WHEN** the inference container starts for the first time
- **THEN** `ollama list` SHALL show `qwen2.5:0.5b` and `llama3.2:3b`
- **AND** they SHALL come from the image (no network call required)
- **AND** the entrypoint SHALL log "[inference] T0 (qwen2.5:0.5b) ready"
  and "[inference] T1 (llama3.2:3b) ready"

#### Scenario: Higher tiers pulled in background
- **WHEN** the host has GPU detected with ≥8GB VRAM
- **THEN** the entrypoint SHALL pull `qwen2.5:7b` and `qwen2.5-coder:7b`
  in the background
- **AND** ollama SHALL be available for inference while these pull

#### Scenario: Squid manifest-pull EOF is non-fatal
- **WHEN** runtime tier pulls hit the Squid SSL-bump EOF
- **THEN** the entrypoint SHALL log the failure with tier label and
  continue
- **AND** the inference container SHALL stay up serving whatever models
  ARE present (T0 + T1 minimum)

### Requirement: Tier classification logged once at boot

On startup the inference entrypoint SHALL log a single line summarizing
which tier was selected for runtime pulls based on detected CPU/GPU/RAM,
e.g. `[inference] tier=T1 (CPU only, 16GB RAM)` or
`[inference] tier=T3 (GPU 8GB)`. The tier label SHALL match the table
above.

#### Scenario: User reading the log knows what got pulled
- **WHEN** an operator runs `podman logs tillandsias-inference | head`
- **THEN** they SHALL see one `tier=` line that maps to the table
- **AND** subsequent `[inference] T<N> ...` lines correspond to that
  tier or below


## Litmus Tests

Bind to tests in `openspec/litmus-bindings.yaml`:
- `litmus:enclave-isolation` — Verify inference container is enclave-only with no external network access

Gating points:
- Container named `tillandsias-inference` starts from `tillandsias-inference` image
- Container attaches to `tillandsias-enclave` network only; no default bridge access
- ollama listens on `http://127.0.0.1:11434` (localhost only, not accessible from forge)
- Forge containers reach ollama via proxy at `http://ollama-proxy:3128` with `OLLAMA_HOST=http://inference:11434`
- GPU tier detection runs on startup and logs `tier=<none|low|mid|high|ultra>`
- T0 models baked into image; T1+ models pulled on demand
- No outbound network access to ollama.ai or huggingface (air-gapped)

## Sources of Truth

- `cheatsheets/runtime/local-inference.md` — Local Inference reference and patterns
- `cheatsheets/runtime/container-gpu.md` — Container Gpu reference and patterns

## Observability

Annotations referencing this spec can be found by:
```bash
grep -rn "@trace spec:inference-container" src-tauri/ scripts/ crates/ images/ --include="*.rs" --include="*.sh"
```
