# inference-container Specification

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

