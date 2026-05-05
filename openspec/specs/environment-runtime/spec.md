<!-- @trace spec:environment-runtime -->
## Status

status: active

## Requirements

### Requirement: Global and per-project configuration
The configuration system MUST support a two-level hierarchy: global defaults at a platform-specific path and per-project overrides at `<project>/.tillandsias/config.toml`.

#### Scenario: Platform-specific config paths
- **WHEN** the application runs on macOS
- **THEN** the global config MUST be located at `~/Library/Application Support/tillandsias/config.toml`

#### Scenario: Platform-specific config paths (Windows)
- **WHEN** the application runs on Windows
- **THEN** the global config MUST be located at `%APPDATA%\tillandsias\config.toml`

#### Scenario: Platform-specific config paths (Linux)
- **WHEN** the application runs on Linux
- **THEN** the global config MUST be located at `~/.config/tillandsias/config.toml`

### Requirement: User-facing files must be verbose and non-technical

All configuration files, log directories, and data files that a user
may discover on their filesystem MUST include clear, non-technical
documentation explaining:
- What the file/directory is for
- Whether it is safe to delete
- What each setting does in plain language
- That security settings cannot be weakened

Users MUST NOT feel alarmed or confused by Tillandsias artifacts
on their system. Transparency and accountability are non-negotiable.

### Requirement: Accountable uninstall

The uninstall script MUST:
- Print a list of files and directories that will be removed BEFORE deletion
- Remove all Tillandsias artifacts: binary, libraries, data, settings, and logs
- Report what was cleaned after deletion
- Confirm that project files were NOT touched
- Support `--wipe` for cache and container image removal


### Requirement: TILLANDSIAS_AGENT accepts opencode-web

The runtime environment contract MUST recognise `TILLANDSIAS_AGENT=opencode-web` as a valid agent value in addition to `opencode`, `claude`, and `terminal`.

#### Scenario: Dispatcher routes opencode-web to the new entrypoint
- **WHEN** a forge container starts with `TILLANDSIAS_AGENT=opencode-web`
- **THEN** `entrypoint.sh` MUST exec `/usr/local/bin/entrypoint-forge-opencode-web.sh`
- **AND** MUST NOT invoke the CLI OpenCode entrypoint

#### Scenario: Unknown values fall through safely
- **WHEN** `TILLANDSIAS_AGENT` is any value not in the recognised set
- **THEN** existing fallback behaviour MUST remain unchanged

## Litmus Tests

### test_linux_config_path (binding: litmus:enclave-isolation)
**Setup**: Run Tillandsias on Linux; check for config file
**Signal**: Global config location
**Pass**: Config file exists or can be created at `~/.config/tillandsias/config.toml`
**Fail**: Config stored elsewhere (e.g., XDG_CONFIG_HOME not respected, or path is wrong)

### test_project_config_override (binding: litmus:enclave-isolation)
**Setup**: Create `.tillandsias/config.toml` in a project directory; run Tillandsias on that project
**Signal**: Configuration values from per-project config
**Pass**: Project config overrides global config settings (e.g., project-specific agent value overrides global default)
**Fail**: Per-project config ignored or global config always takes precedence

### test_config_file_user_friendly (binding: litmus:ephemeral-guarantee)
**Setup**: Open `~/.config/tillandsias/config.toml` in a text editor
**Signal**: File content and comments
**Pass**: File includes plain-language comments explaining each setting, deletion safety, security non-negotiable note
**Fail**: File contains unexplained technical jargon; user cannot understand purpose of settings

### test_uninstall_script_lists_before_delete (binding: litmus:enclave-isolation)
**Setup**: Run uninstall script (without `--wipe`)
**Signal**: Script output BEFORE deletion begins
**Pass**: Script prints list of files/dirs to be removed; user can review before proceeding
**Fail**: Deletion happens without prior list; user cannot review what will be deleted

### test_uninstall_reports_cleanup (binding: litmus:enclave-isolation)
**Setup**: Run uninstall script to completion
**Signal**: Script output AFTER deletion completes
**Pass**: Script confirms what was cleaned (binary, libs, data, settings, logs removed; project files untouched)
**Fail**: No confirmation printed; user unsure if uninstall succeeded

### test_uninstall_wipe_flag_behavior (binding: litmus:enclave-isolation)
**Setup**: Run uninstall script with `--wipe` flag
**Signal**: Script removes cache and container images in addition to standard cleanup
**Pass**: Cache directories and image artifacts deleted; user can verify with `podman images | grep tillandsias` returns empty
**Fail**: Cache or images still present after `--wipe`

### test_tillandsias_agent_opencode_web_value (binding: litmus:ephemeral-guarantee)
**Setup**: Launch a forge container with `TILLANDSIAS_AGENT=opencode-web`
**Signal**: Entrypoint routing decision
**Pass**: `entrypoint.sh` execs `/usr/local/bin/entrypoint-forge-opencode-web.sh` (not CLI opencode path)
**Fail**: Env var not recognized; default CLI opencode entrypoint runs instead

### test_unknown_agent_fallback (binding: litmus:ephemeral-guarantee)
**Setup**: Launch a forge container with `TILLANDSIAS_AGENT=unknown-agent`
**Signal**: Entrypoint routing decision
**Pass**: Fallback behavior remains unchanged (likely defaults to terminal or CLI opencode)
**Fail**: Entrypoint crashes or ignores unknown value without safe fallback

### test_config_hierarchy_resolution (binding: litmus:ephemeral-guarantee)
**Setup**: Create both global and per-project config files with conflicting values for a setting (e.g., `timeout`)
**Signal**: Which value is used at runtime
**Pass**: Per-project value takes precedence over global value
**Fail**: Global always wins or per-project config is ignored

## Sources of Truth

- `cheatsheets/runtime/podman.md` — Podman reference and patterns
- `cheatsheets/runtime/container-health-checks.md` — Container Health Checks reference and patterns

## Observability

Annotations referencing this spec can be found by:
```bash
grep -rn "@trace spec:environment-runtime" src-tauri/ scripts/ crates/ images/ --include="*.rs" --include="*.sh"
```
