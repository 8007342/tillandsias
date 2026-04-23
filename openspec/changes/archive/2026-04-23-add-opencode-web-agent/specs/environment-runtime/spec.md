## ADDED Requirements

### Requirement: TILLANDSIAS_AGENT accepts opencode-web

The runtime environment contract SHALL recognise `TILLANDSIAS_AGENT=opencode-web` as a valid agent value in addition to `opencode`, `claude`, and `terminal`.

#### Scenario: Dispatcher routes opencode-web to the new entrypoint
- **WHEN** a forge container starts with `TILLANDSIAS_AGENT=opencode-web`
- **THEN** `entrypoint.sh` execs `/usr/local/bin/entrypoint-forge-opencode-web.sh`
- **AND** does not invoke the CLI OpenCode entrypoint

#### Scenario: Unknown values fall through safely
- **WHEN** `TILLANDSIAS_AGENT` is any value not in the recognised set
- **THEN** existing fallback behaviour remains unchanged
