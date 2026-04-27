## ADDED Requirements

### Requirement: Forge image bakes the cheatsheets directory at /opt/cheatsheets/

The forge image (`images/default/Containerfile`) SHALL `COPY cheatsheets/ /opt/cheatsheets/` near the end of the build (after the `/opt/agents/` layer, before the locale-files COPY) and SHALL set `ENV TILLANDSIAS_CHEATSHEETS=/opt/cheatsheets` so agent runtimes can discover the path without hardcoding it. Ownership SHALL be `root:root` and permissions SHALL be world-readable, so the forge user (UID 1000) can read but not modify any cheatsheet.

#### Scenario: Image build succeeds with cheatsheets present
- **WHEN** the forge image is built via `scripts/build-image.sh forge`
- **THEN** the resulting image contains `/opt/cheatsheets/INDEX.md` and the seven category subdirectories
- **AND** `podman run --rm <image> ls /opt/cheatsheets/` lists `INDEX.md` plus `runtime/`, `languages/`, `utils/`, `build/`, `web/`, `test/`, `agents/`

#### Scenario: Environment variable is exported
- **WHEN** an agent inside a running forge container runs `printenv TILLANDSIAS_CHEATSHEETS`
- **THEN** the output is `/opt/cheatsheets`

#### Scenario: Forge user cannot mutate cheatsheets
- **WHEN** the forge user (UID 1000) runs `touch /opt/cheatsheets/INDEX.md`
- **THEN** the call fails with EACCES — `/opt/cheatsheets/` is image-state, not user-state

### Requirement: Forge entrypoint surfaces TILLANDSIAS_CHEATSHEETS to agents

Every forge entrypoint script (`entrypoint-forge-claude.sh`, `entrypoint-forge-opencode.sh`, `entrypoint-forge-opencode-web.sh`, `entrypoint-terminal.sh`) SHALL ensure `TILLANDSIAS_CHEATSHEETS` is in the agent's environment. The image-level `ENV` already covers this; entrypoints SHALL NOT unset or shadow it.

#### Scenario: Variable survives entrypoint
- **WHEN** any forge entrypoint launches its agent
- **THEN** the launched agent's process environment contains `TILLANDSIAS_CHEATSHEETS=/opt/cheatsheets`

### Requirement: forge-welcome.sh prints the cheatsheet location once per session

`forge-welcome.sh` SHALL print a single line of the form `📚 Cheatsheets: /opt/cheatsheets/INDEX.md (cat or rg this file first)` near the top of its output, so agents and humans alike see the discovery path on first attach.

#### Scenario: Welcome line is present
- **WHEN** `forge-welcome.sh` runs at agent startup
- **THEN** its stdout contains the single-line cheatsheet hint

## ADDED Requirements (optional tool additions)

### Requirement: Forge ships shellcheck and shfmt for shell script work

The forge image SHALL install `ShellCheck` and `shfmt` so agents writing or modifying shell scripts have linting and formatting available without resorting to runtime `pip install` or `npm install` workarounds. Both packages are available from Fedora's `dnf` repository.

#### Scenario: shellcheck is available
- **WHEN** an agent runs `shellcheck --version` inside the forge
- **THEN** the command succeeds

#### Scenario: shfmt is available
- **WHEN** an agent runs `shfmt --version` inside the forge
- **THEN** the command succeeds

### Requirement: Forge ships yq for YAML manipulation

The forge image SHALL install `yq` (the Go-based mikefarah/yq, NOT the Python kislyuk/yq wrapper around jq). YAML is ubiquitous in modern config (Kubernetes, GitHub Actions, OpenAPI, docker-compose) and agents need first-class YAML manipulation alongside `jq` for JSON.

#### Scenario: yq is available
- **WHEN** an agent runs `yq --version` inside the forge
- **THEN** the command succeeds and reports `yq (https://github.com/mikefarah/yq/) version 4.x` or higher

### Requirement: Forge ships protobuf-compiler and grpcurl for gRPC work

The forge image SHALL install `protobuf-compiler` (the `protoc` binary) and `grpcurl`. Both are widely needed for any service-mesh / API project the agent might encounter; their absence has been a recurring "I need to install this" failure mode.

#### Scenario: protoc is available
- **WHEN** an agent runs `protoc --version` inside the forge
- **THEN** the command succeeds

#### Scenario: grpcurl is available
- **WHEN** an agent runs `grpcurl -version` inside the forge
- **THEN** the command succeeds
