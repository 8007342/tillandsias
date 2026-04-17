# Delta: enclave-network (host-gateway aliases on podman machine)

## MODIFIED Requirements

### Requirement: Forge container can reach enclave services via friendly aliases on podman machine

On podman machine (Windows/macOS), the forge container SHALL reach the proxy, git-service, and inference services via the friendly aliases `proxy`, `git-service`, and `inference`. The system SHALL inject `--add-host alias:host-gateway` for each enclave alias when port mapping is enabled. Container env vars SHALL use the friendly alias names — `HTTP_PROXY=http://proxy:3128`, `TILLANDSIAS_GIT_SERVICE=git-service`, `OLLAMA_HOST=http://inference:11434` — rather than `localhost`. Inside the container, `localhost` is the container's loopback and is not where the enclave services are reachable.

@trace spec:enclave-network, spec:fix-podman-machine-host-aliases

#### Scenario: Forge clones from git mirror via the alias
- **WHEN** the forge container starts on Windows under podman machine
- **AND** the entrypoint runs `git clone git://git-service:9418/<project>`
- **THEN** `git-service` SHALL resolve to the host gateway IP (e.g. `169.254.1.2`)
- **AND** the connection SHALL reach the published port 9418 on the host
- **AND** the clone SHALL succeed (or report "empty repository" if the mirror has no commits, NOT "Connection refused")

#### Scenario: Forge fetches packages via the proxy alias
- **WHEN** the forge container has `HTTP_PROXY=http://proxy:3128` set
- **AND** the entrypoint runs `curl http://example.com`
- **THEN** `proxy` SHALL resolve to the host gateway IP
- **AND** the request SHALL reach the published port 3128 on the host (the squid proxy)
- **AND** squid SHALL apply the allowlist policy (HTTP 403 for non-allowlisted, HTTP 200 for allowlisted)

#### Scenario: Forge talks to local LLM via the inference alias
- **WHEN** an LLM-using tool inside the forge probes `http://inference:11434/api/version`
- **THEN** `inference` SHALL resolve to the host gateway IP
- **AND** the request SHALL reach the published port 11434 on the host (ollama)

#### Scenario: rewrite_enclave_env passes through unchanged
- **WHEN** `rewrite_enclave_env` is called with any name/value pair
- **THEN** it SHALL return the original value unchanged
- **AND** the function SHALL remain in the codebase as a hook for hypothetical future setups
