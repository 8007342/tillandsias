## Delta: Valid OpenCode config format

### Requirement: OpenCode config uses valid schema
The embedded `opencode.json` SHALL use valid OpenCode configuration keys and format.

#### Scenario: OpenCode starts without settings error
- **WHEN** the container starts and OpenCode reads `/home/forge/.config/opencode/config.json`
- **THEN** OpenCode launches successfully without config parse errors

#### Scenario: Auto-update disabled in config
- **WHEN** OpenCode reads the config
- **THEN** `autoupdate` is `false` (updates managed by entrypoint `ensure_opencode()`)

#### Scenario: Security via mount topology, not config
- **WHEN** the container runs
- **THEN** sensitive directories (`~/.config/gh`, `~/.claude`) are protected by container mount strategy, not by OpenCode config deny rules
