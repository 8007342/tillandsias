# Enclave Network

@trace spec:enclave-network, spec:proxy-egress-allowlist

**Purpose**: Tillandsias multi-container enclave with security isolation, credential isolation, and curated external egress through a caching proxy.

## MODIFIED Requirements

### Requirement: Proxy egress allowlist for Codex (NEW SCENARIO ADDED)

The caching HTTP/S proxy SHALL maintain an allowlist of domains that Codex containers are permitted to access. This extends the existing allowlist framework for agents.

#### Scenario: Codex egress is allowlisted
- **WHEN** a Codex container attempts to access an external service
- **THEN** the request is routed through the proxy container (enclave-local)
- **AND** the request is permitted if the target domain matches the Codex allowlist
- **AND** the request is logged with source (codex) and target domain

#### Scenario: Codex allowlist includes code analysis services
- **WHEN** the proxy allowlist is configured during enclave startup
- **THEN** it includes domains needed for code analysis:
  - `api.github.com` (GitHub API for repository inspection)
  - `pypi.org` and `files.pythonhosted.org` (Python package resolution)
  - Custom code analysis service endpoints (if configured)

#### Scenario: Codex cannot access forge containers or host
- **WHEN** a Codex container attempts to connect to another container on the enclave
- **THEN** the request succeeds only if the target is explicitly permitted (proxy, git, inference)
- **AND** the Codex container has zero access to the host filesystem or credentials
- **AND** this is enforced by the proxy allowlist and container networking

#### Scenario: Proxy allowlist for Codex is separate from other agents
- **WHEN** multiple agents (Claude, OpenCode, Codex) run concurrently
- **THEN** each agent's allowlist is independent
- **AND** Codex allowlist does not include agent-specific domains (e.g., no OpenCode Web browser isolation traffic)
- **AND** the proxy routing logic directs requests based on source container

## Sources of Truth

- `cheatsheets/runtime/enclave-network.md` — Multi-container network topology and container roles
- `cheatsheets/runtime/proxy-allowlist.md` — Proxy domain allowlist patterns and configuration
- `cheatsheets/utils/github-api-access.md` — GitHub API endpoints and authentication (token-less patterns)
