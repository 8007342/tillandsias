## ADDED Requirements

### Requirement: Forge image ships an OpenCode Web entrypoint

The default forge image SHALL include `/usr/local/bin/entrypoint-forge-opencode-web.sh`, installed with executable permissions, alongside the existing OpenCode and Claude entrypoints.

#### Scenario: Script is present and executable
- **WHEN** the built forge image is inspected
- **THEN** the file `/usr/local/bin/entrypoint-forge-opencode-web.sh` exists and is executable
- **AND** the file is owned consistently with the other entrypoints

### Requirement: OpenCode Web entrypoint runs opencode serve

The web entrypoint SHALL terminate by `exec`-ing `opencode serve --hostname 0.0.0.0 --port 4096`, binding inside the container only, after the standard setup (CA trust, git clone, OpenSpec init, OpenCode install).

#### Scenario: Final exec targets opencode serve
- **WHEN** a web-mode container starts to steady state
- **THEN** the container's PID 1 is an `opencode serve` process listening on `0.0.0.0:4096` inside the container's netns
- **AND** no terminal UI is launched
