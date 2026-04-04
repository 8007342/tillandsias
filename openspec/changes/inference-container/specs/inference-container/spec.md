## ADDED Requirements

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
