## ADDED Requirements

### Requirement: Proxy egress is transparent to opencode

OpenCode Web SHALL reach its default external dependencies (model registry at
`models.dev`, OpenRouter, Helicone, and the provider APIs already covered by the
Squid allowlist) without observing any proxy-induced failure. Transparency here
means: no `TCP_DENIED` responses for intended egress, no TLS errors under the
enclave CA, and no retry storms caused by intra-enclave hostnames hairpinning
through Squid.

#### Scenario: First prompt reaches the selected provider
- **WHEN** the user attaches to a project in OpenCode Web mode and sends the
  first prompt after selecting a provider (Anthropic, OpenAI, OpenRouter,
  Helicone, or any already-allowlisted provider)
- **THEN** the provider's HTTPS endpoint resolves through the proxy (CONNECT
  succeeds)
- **AND** the TLS handshake against the provider certificate completes
- **AND** the proxy log shows `TCP_TUNNEL/200` (not `TCP_DENIED/*`) for that
  destination

#### Scenario: Model registry fetch succeeds
- **WHEN** OpenCode requests the model registry from `models.dev`
- **THEN** the request reaches `models.dev:443` via the proxy CONNECT tunnel
- **AND** the response is served to OpenCode in full
- **AND** no subsequent prompt stalls on model-list resolution

### Requirement: Intra-enclave hostnames bypass the proxy

The forge container's `NO_PROXY` env SHALL include every service name reachable
on the enclave network (`inference`, `git-service`, `proxy`) plus loopback
variants (`localhost`, `127.0.0.1`, `0.0.0.0`, `::1`). Requests to any of these
destinations MUST NOT traverse Squid.

#### Scenario: Inference probe never hits the proxy
- **WHEN** OpenCode (or its wrapper) probes `http://inference:11434/api/version`
- **THEN** the Bun HTTP client sees `inference` matching `NO_PROXY` and connects
  directly on the enclave network
- **AND** the proxy log records no entry for `inference:11434`

#### Scenario: Ollama's own loopback health check stays local
- **WHEN** ollama inside the inference container probes its own listen address
  `http://0.0.0.0:11434/` or `http://127.0.0.1:11434/`
- **THEN** `NO_PROXY` in the inference container matches and the probe stays
  inside the container
- **AND** no `TCP_DENIED/403` for `0.0.0.0:11434` appears in the proxy log
