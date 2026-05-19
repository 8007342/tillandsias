# transparent-mode-detection Specification

@trace spec:transparent-mode-detection

## Status

active

## Requirements

### Requirement: Launcher mode is detected from invocation context

The Linux launcher MUST distinguish direct CLI, tray, transparent wrapper, and install/runtime modes from explicit arguments and executable context.

#### Scenario: Transparent wrapper invocation is detected

- **WHEN** the executable is invoked through its transparent-mode wrapper path or equivalent launch context
- **THEN** the launcher MUST select transparent behavior
- **AND** it MUST still honor explicit CLI flags that intentionally override defaults

## Sources of Truth

- `cheatsheets/runtime/portable-executable-transparent-mode.md` - Transparent mode behavior
- `cheatsheets/runtime/linux-user-session-podman.md` - Linux launcher runtime context

