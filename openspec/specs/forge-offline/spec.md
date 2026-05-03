<!-- @trace spec:forge-offline -->
# forge-offline Specification

## Status

status: active

## Purpose

Forge containers operate offline -- no credentials, no project mounts, no direct internet. Code comes from git clone, packages come through the proxy, secrets live exclusively in the git service.

## Requirements

### Requirement: Forge containers have zero credentials
Forge containers SHALL NOT have any credential mounts. No GitHub token file, no Claude directory, no D-Bus socket. Credentials are exclusively owned by the git service container.

@trace spec:forge-offline

#### Scenario: Forge launched without credentials
- **WHEN** a forge container is launched
- **THEN** no volume mount SHALL contain tokens, keys, or authentication files
- **AND** the environment SHALL NOT contain `GIT_ASKPASS`, `ANTHROPIC_API_KEY`, or `GH_TOKEN`

#### Scenario: Agent attempts to read secrets
- **WHEN** an AI agent inside the forge attempts to access `/run/secrets/` or `~/.config/gh/`
- **THEN** these paths SHALL NOT exist
- **AND** the agent SHALL receive a "file not found" error

### Requirement: Forge containers have no direct project mount
Forge containers SHALL NOT have the host project directory mounted. Source code SHALL be obtained exclusively via `git clone` from the git mirror service. All changes MUST be committed to persist.

@trace spec:forge-offline

#### Scenario: Forge starts with clone only
- **WHEN** a forge container starts
- **THEN** `/home/forge/src/<project>` SHALL contain a git clone from the mirror
- **AND** there SHALL be no bind mount from the host project directory

#### Scenario: Uncommitted changes lost on stop
- **WHEN** a forge container stops
- **AND** there are uncommitted changes in the working tree
- **THEN** those changes SHALL be lost
- **AND** committed changes SHALL persist in the mirror

### Requirement: Forge containers are enclave-only
Forge containers SHALL be attached to the `tillandsias-enclave` internal network only. They SHALL NOT have access to the default bridge network. All HTTP/HTTPS traffic SHALL go through the proxy.

@trace spec:forge-offline, spec:enclave-network

#### Scenario: Direct internet access blocked
- **WHEN** a forge container attempts `curl https://evil.com` without using the proxy
- **THEN** the connection SHALL fail (no route to host)

#### Scenario: Package install through proxy works
- **WHEN** a forge container runs `npm install` with proxy env vars
- **THEN** the install SHALL succeed through the proxy

## Sources of Truth

- `cheatsheets/runtime/forge-container.md` — Forge Container reference and patterns
- `cheatsheets/security/owasp-top-10-2021.md` — Owasp Top 10 2021 reference and patterns

## Observability

Annotations referencing this spec can be found by:
```bash
grep -rn "@trace spec:forge-offline" src-tauri/ scripts/ crates/ images/ --include="*.rs" --include="*.sh"
```
