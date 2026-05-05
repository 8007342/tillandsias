## ADDED Requirements

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
