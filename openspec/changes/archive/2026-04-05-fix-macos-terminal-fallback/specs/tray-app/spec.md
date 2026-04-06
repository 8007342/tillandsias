## ADDED Requirements

### Requirement: macOS terminal fallback chain
The `open_terminal()` function on macOS SHALL try multiple terminal emulators in a deterministic order, falling back to the next on failure, rather than hardcoding a single terminal.

#### Scenario: CLI terminal available (Ghostty)
- **WHEN** the user clicks "Attach Here" on macOS and `which ghostty` succeeds
- **THEN** Ghostty is launched with the podman command and the fallback chain stops

#### Scenario: CLI terminal available (Kitty)
- **WHEN** the user clicks "Attach Here" on macOS and Ghostty is not found but `which kitty` succeeds
- **THEN** Kitty is launched with the podman command and the fallback chain stops

#### Scenario: No CLI terminal, iTerm2 installed
- **WHEN** the user clicks "Attach Here" on macOS, no CLI terminal is found, and `/Applications/iTerm.app` exists
- **THEN** iTerm2 is launched via AppleScript and the fallback chain stops

#### Scenario: Only Terminal.app available
- **WHEN** the user clicks "Attach Here" on macOS and no CLI terminal or iTerm2 is found
- **THEN** Terminal.app is launched via AppleScript as the last resort

#### Scenario: All terminals fail
- **WHEN** every terminal in the fallback chain fails (including Terminal.app)
- **THEN** `open_terminal()` returns an error with the last failure message and the container is cleaned up

### Requirement: AppleScript error detection
AppleScript-based terminal launches SHALL use `.output()` to capture the exit code and stderr, not `.spawn()` which cannot detect AppleScript failures.

#### Scenario: AppleScript fails with error -2740
- **WHEN** Terminal.app's AppleScript returns error `-2740` (property mismatch)
- **THEN** the error is logged with the stderr content and the launch is reported as failed

#### Scenario: AppleScript fails with TCC denial
- **WHEN** the user has denied Automation permission and osascript returns error `-1743`
- **THEN** the error is logged and the next terminal in the chain is tried

### Requirement: Terminal selection logging
Each terminal launch attempt SHALL log which terminal was selected and whether it succeeded or failed.

#### Scenario: Successful CLI terminal launch
- **WHEN** a CLI terminal is found and spawned successfully
- **THEN** a `debug` log line records the terminal name

#### Scenario: Failed terminal, trying next
- **WHEN** a terminal fails to launch
- **THEN** a `warn` log line records the terminal name and error before trying the next option
