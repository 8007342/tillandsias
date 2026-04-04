## ADDED Requirements

### Requirement: Inference container managed as shared service
The system SHALL manage the inference container (`tillandsias-inference`) as a shared service on the enclave network with network alias `inference`. The model cache volume SHALL be bind-mounted from the host.

@trace spec:inference-container, spec:podman-orchestration

#### Scenario: Inference container started
- **WHEN** the inference container is started
- **THEN** it SHALL be on `tillandsias-enclave` network with alias `inference`
- **AND** the models volume SHALL be mounted at `/home/ollama/.ollama/models/`
- **AND** `HTTP_PROXY` and `HTTPS_PROXY` SHALL be set for model downloads
